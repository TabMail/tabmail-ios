/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the large inbox support feature (matching TB's inboxManagement):
/// 1. SyncConfig constants exist and are reasonable
/// 2. AI queue repopulate only considers the N most recent inbox messages
/// 3. AI queue recency gate skips old messages in large inboxes for SYNC-ORIGIN
///    admission and for the durable recovery sweep (since ADR-IOS-078 the gate no
///    longer applies to arrival/user-intent offers — those are window-exempt)
/// 4. Large inbox detection logic (total >= maxRecentEmails AND old > 0)
/// 5. Bulk archive query selects correct messages by age cutoff
@Suite("Large Inbox Support")
struct LargeInboxTests {

    // MARK: - SyncConfig constants

    @Test("maxRecentEmails matches TB default of 100")
    func maxRecentEmailsValue() {
        #expect(SyncConfig.maxRecentEmails == 100)
    }

    @Test("archiveAgeDays matches TB default of 14")
    func archiveAgeDaysValue() {
        #expect(SyncConfig.archiveAgeDays == 14)
    }

    @Test("maxRecentEmails is positive")
    func maxRecentEmailsPositive() {
        #expect(SyncConfig.maxRecentEmails > 0)
    }

    @Test("archiveAgeDays is positive")
    func archiveAgeDaysPositive() {
        #expect(SyncConfig.archiveAgeDays > 0)
    }

    // MARK: - AI queue repopulate cap (query pattern)

    @Test("Repopulate query returns at most maxRecentEmails messages")
    func repopulateQueryCap() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        // Insert 150 inbox messages (more than maxRecentEmails), all missing AI data
        let now = Date()
        for i in 0..<150 {
            let date = now.addingTimeInterval(Double(-i) * 3600) // 1hr apart
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: date,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // Query matching repopulateFromDatabase: top N by date, then filter missing AI
        let recentHeaders = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").desc)
                .limit(SyncConfig.maxRecentEmails)
                .fetchAll(db)
        }

        #expect(recentHeaders.count == SyncConfig.maxRecentEmails)
        guard let oldestRecent = recentHeaders.last?.date else { return }

        // Verify the oldest message in results is newer than the oldest overall
        let oldestOverall = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").asc)
                .fetchOne(db)?.date
        }
        guard let oldestOverall else {
            Issue.record("Expected at least one message in database")
            return
        }
        #expect(oldestRecent > oldestOverall)
    }

    @Test("Repopulate query filters to messages missing AI data within recent window")
    func repopulateQueryFiltersAI() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // 5 recent messages: 3 missing summary, 2 fully processed
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "missing\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<2 {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "done\(i)", date: now.addingTimeInterval(Double(-(i + 3)) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true, actionTag: .reply
            )
            header.summaryBlurb = "Summary"
            header.cachedReply = "Reply"
            try db.write { try header.update($0) }
        }

        // Repopulate pattern: fetch recent, filter in Swift
        let recentHeaders = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").desc)
                .limit(SyncConfig.maxRecentEmails)
                .fetchAll(db)
        }

        let needsAI = recentHeaders.filter { h in
            h.summaryBlurb == nil || h.summaryBlurb?.isEmpty == true ||
            h.actionTag == nil || h.cachedReply == nil
        }

        #expect(recentHeaders.count == 5)
        #expect(needsAI.count == 3)
    }

    // MARK: - Recency gate — driven through the PRODUCTION admission policy
    //
    // ⚠️ iOS #70. The five `recencyGate*` tests that used to live here (and at
    // "Edge cases" below) called no production symbol at all: each re-implemented
    // the window query inline as
    // `MessageHeader.filter(isInInbox).filter(date > x).fetchCount(db)` and then
    // asserted arithmetic on its own result. They would have stayed green with
    // `ActiveAIQueue.enqueue` deleted outright — absent coverage presenting as
    // present, in exactly the namespace a maintainer checks before changing
    // admission policy (MIS-014 instance 12 already recorded `recencyGateRejects`
    // as having BLESSED the pre-ADR-IOS-078 unconditional gate).
    //
    // They now drive the two production symbols that ARE the policy:
    //   • `ActiveAIQueue.recentInboxWindowContains` — window MEMBERSHIP;
    //   • `ActiveAIQueue.windowRetires(job:inRecentWindow:)` — the origin-aware
    //     ADMISSION outcome, `!inRecentWindow && !job.windowExempt`
    //     (ADR-IOS-078 pathway regating, owner directive 2026-08-19).
    // Nothing below re-derives either one, and no production API was widened for
    // testability — both symbols were already internal and already called by
    // `productionRecentWindowAdmission` below.
    //
    // Each replacement records its retired symbol and display name in its own doc
    // comment, so a `rg recencyGatePasses` (or any of the other four) still lands
    // on the test that took over the property — matching how `IOS-TEST-005`
    // recorded a re-scoped name inline.
    //
    // DIVISION OF LABOUR — read this before adding admission coverage here.
    // `TabMailTests/Services/WindowExemptAdmissionTests.swift` already drives the
    // ACTOR path end-to-end (a real `ActiveAIQueue` over a swapped
    // `AppDatabase.shared`, dispatch suppressed): `enqueue` refusing/admitting,
    // the exemption being carried on the admitted jobs, the `replacePending`
    // dedupe upgrade, and the real open / move-into-inbox / `flushBatch`
    // producers. That is where a new *pathway* assertion belongs.
    // This suite is the LARGE-INBOX layer: it pins the window predicate itself at
    // scale — the exact partition, the cardinality, the boundary and its
    // displacement, and the Inbox-only population — properties a fixture holding
    // one in-window and one out-of-window row cannot express.

    /// Window membership straight out of production, for a whole id set, in one
    /// read. Returns one entry per id, in the same order — deliberately NOT a
    /// dictionary with a defaulted lookup, because a `?? false` default is
    /// fail-open on the reject side of every sweep below.
    private func windowMembership(of ids: [String], db: DatabaseQueue) throws -> [Bool] {
        try db.read { connection in
            try ids.map {
                try ActiveAIQueue.recentInboxWindowContains(headerId: $0, db: connection)
            }
        }
    }

    /// The production admission outcome for one row, composed exactly the way
    /// `ActiveAIQueue.executeJob` / `readJobOutcome` compose it:
    /// `guard !Self.windowRetires(job:inRecentWindow:)`. The `AIJob` is the
    /// production type and `windowRetires` is the production predicate.
    private func productionAdmits(
        headerId: String, inRecentWindow: Bool, windowExempt: Bool
    ) -> Bool {
        let job = ActiveAIQueue.AIJob(
            headerId: headerId, accountId: "acc1", jobType: .summary,
            windowExempt: windowExempt
        )
        return !ActiveAIQueue.windowRetires(job: job, inRecentWindow: inRecentWindow)
    }

    /// ⚠️ REWRITTEN (iOS #70). **Retired symbol: `recencyGatePasses`, display name
    /// *"Recency gate: message within top N passes"*.** That test called no
    /// production symbol: it counted `MessageHeader.filter(isInInbox).filter(date >
    /// x)` itself and asserted on its own count, so "passes" described its
    /// arithmetic rather than any admission decision. This one asks production.
    @Test("sync-origin AI admission accepts exactly the newest maxRecentEmails Inbox rows and rejects every older one")
    func syncOriginAdmissionAcceptsTheNewestWindowAndRejectsOlderRows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let beyondWindow = 20
        let total = SyncConfig.maxRecentEmails + beyondWindow
        var ids: [String] = []
        for i in 0..<total {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "admission-\(i)",
                date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            ids.append(header.id)
        }
        #expect(ids.count == total)
        guard ids.count == total else { return }

        let membership = try windowMembership(of: ids, db: db)
        #expect(membership.count == total)
        guard membership.count == total else { return }

        let admitted = Set(zip(ids, membership)
            .filter { productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: false) }
            .map(\.0))
        let rejected = Set(ids).subtracting(admitted)

        // Two-sided by construction: a non-zero accepted count kills "always
        // reject", a non-zero rejected count kills "always accept", and the exact
        // partition kills any off-by-one in the LIMIT.
        #expect(admitted.count == SyncConfig.maxRecentEmails)
        #expect(rejected.count == beyondWindow)
        #expect(admitted == Set(ids.prefix(SyncConfig.maxRecentEmails)))
        #expect(rejected == Set(ids.suffix(beyondWindow)))
    }

    /// ⚠️ REWRITTEN (iOS #70). **Retired symbol: `recencyGateRejects`, display name
    /// *"Recency gate: message outside top N is rejected"*.** That name asserted an
    /// UNCONDITIONAL rejection, which ADR-IOS-078 removed: since pathway regating an
    /// out-of-window row is rejected only for a sync-origin job and admitted for a
    /// window-exempt one. `MIS-014` instance 12 records this exact test as having
    /// BLESSED the pre-ADR-IOS-078 gate — it stayed green on the suppression the ADR
    /// exists to remove, because it re-derived the window instead of calling
    /// `windowRetires`. The origin axis it missed is now the subject of the test.
    @Test("out-of-window retirement is ORIGIN-dependent: a sync-origin job retires, a window-exempt job — and the action chained after it — does not (ADR-IOS-078)")
    func outOfWindowRetirementIsOriginDependent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let beyondWindow = 10
        let total = SyncConfig.maxRecentEmails + beyondWindow
        var ids: [String] = []
        for i in 0..<total {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "origin-\(i)",
                date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            ids.append(header.id)
        }
        #expect(ids.count == total)
        guard ids.count == total else { return }

        let membership = try windowMembership(of: ids, db: db)
        #expect(membership.count == total)
        guard membership.count == total, let oldest = ids.last,
              let oldestInWindow = membership.last else { return }

        let syncOriginAdmitted = Set(zip(ids, membership)
            .filter { productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: false) }
            .map(\.0))
        let exemptAdmitted = Set(zip(ids, membership)
            .filter { productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: true) }
            .map(\.0))

        // The sync bucket keeps the bound end-to-end: 100 in, 10 out.
        #expect(syncOriginAdmitted.count == SyncConfig.maxRecentEmails)
        #expect(Set(ids).subtracting(syncOriginAdmitted).count == beyondWindow)
        // The arrival/user-intent bucket is exempt end-to-end: every row admitted,
        // including the ones the sync bucket just retired. This is the half that
        // ADR-IOS-078's pathway regating added, and the half the old
        // `recencyGateRejects` blessed away (MIS-014 instance 12).
        #expect(exemptAdmitted.count == total)
        #expect(exemptAdmitted.isSuperset(of: syncOriginAdmitted))

        #expect(!oldestInWindow)
        #expect(!syncOriginAdmitted.contains(oldest))
        #expect(exemptAdmitted.contains(oldest))

        // The action job chained after a summary inherits its parent's exemption —
        // an exempt summary's action must not be killed by the window the summary
        // was exempted from.
        let exemptSummary = ActiveAIQueue.AIJob(
            headerId: oldest, accountId: "acc1", jobType: .summary, windowExempt: true)
        let syncOriginSummary = ActiveAIQueue.AIJob(
            headerId: oldest, accountId: "acc1", jobType: .summary, windowExempt: false)
        #expect(!ActiveAIQueue.windowRetires(
            job: ActiveAIQueue.chainedActionJob(after: exemptSummary),
            inRecentWindow: oldestInWindow))
        #expect(ActiveAIQueue.windowRetires(
            job: ActiveAIQueue.chainedActionJob(after: syncOriginSummary),
            inRecentWindow: oldestInWindow))
    }

    /// ⚠️ REWRITTEN (iOS #70). **Retired symbol: `recencyGateSkipsNonInbox`, display
    /// name *"Recency gate: non-inbox messages are not subject to the gate"*.** That
    /// name was not merely unproven, it was false — see the body comment below.
    @Test("the recent-window population counts ONLY Inbox rows — newer non-Inbox rows never displace an Inbox row, and a non-Inbox row is never a member")
    func theRecentWindowPopulationCountsOnlyInboxRows() throws {
        // ⚠️ The retired name `recencyGateSkipsNonInbox` claimed "non-inbox messages
        // are not subject to the gate", which production contradicts: a non-Inbox row is
        // not in the window at ALL, so a sync-origin job naming it is
        // window-retired. What is actually true — and what is asserted here — is
        // that the window POPULATION is Inbox-scoped, so non-Inbox rows cannot
        // consume window slots. Inbox scope at execution is a separate,
        // unconditional `message.isInInbox` re-check.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let now = Date()
        // Every non-Inbox row is NEWER than every Inbox row, and there are more of
        // them than the window holds. If `recentInboxWindowContains` ever lost its
        // `WHERE isInInbox = 1`, the window would be entirely Sent rows and both
        // sides of this test flip at once.
        let sentCount = SyncConfig.maxRecentEmails + 50
        var sentIds: [String] = []
        for i in 0..<sentCount {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "sent-\(i)", date: now.addingTimeInterval(Double(-i)),
                folderId: "acc1:Sent", accountId: "acc1", folderPath: "Sent",
                isInInbox: false
            )
            sentIds.append(header.id)
        }
        // Derived from the config, and guarded before anything is built from it:
        // the red run is precisely where a derived size can go degenerate
        // (MIS-IOS-014).
        let inboxCount = SyncConfig.maxRecentEmails / 2
        #expect(inboxCount > 0)
        guard inboxCount > 0 else { return }
        var inboxIds: [String] = []
        for i in 0..<inboxCount {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "inbox-\(i)",
                date: now.addingTimeInterval(Double(-(i + 1)) * 3600),
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            inboxIds.append(header.id)
        }

        let inboxMembership = try windowMembership(of: inboxIds, db: db)
        let sentMembership = try windowMembership(of: sentIds, db: db)
        #expect(inboxMembership.count == inboxCount)
        #expect(sentMembership.count == sentCount)
        guard inboxMembership.count == inboxCount, sentMembership.count == sentCount else { return }

        // (b) a non-zero accepted count: every Inbox row keeps its slot …
        #expect(inboxMembership.filter { $0 }.count == inboxCount)
        // … and (a) the side that must reject: no Sent row is ever a member,
        // however new it is.
        #expect(sentMembership.filter { $0 }.count == 0)

        let inboxAdmitted = zip(inboxIds, inboxMembership)
            .filter { productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: false) }
        let sentAdmitted = zip(sentIds, sentMembership)
            .filter { productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: false) }
        #expect(inboxAdmitted.count == inboxCount)
        #expect(sentAdmitted.isEmpty)
    }

    // MARK: - Large inbox detection

    @Test("Inbox with 100+ messages and old messages is detected as large")
    func largeInboxDetected() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 80 recent + 30 old = 110 total
        for i in 0..<80 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<30 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == true)
        #expect(totalCount == 110)
        #expect(oldCount == 30)
    }

    @Test("Inbox with fewer than 100 messages is not large")
    func smallInboxNotLarge() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 50 recent + 20 old = 70 total (< 100)
        for i in 0..<50 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<20 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == false)
        #expect(totalCount == 70)
    }

    @Test("Inbox with 100+ messages but none old is not large")
    func largeButNoOldNotLarge() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // 120 messages, all within last 2 days (well within archiveAgeDays)
        for i in 0..<120 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!
        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == false)
        #expect(totalCount == 120)
        #expect(oldCount == 0)
    }

    // MARK: - Bulk archive query

    @Test("Bulk archive selects only messages older than cutoff")
    func bulkArchiveSelectsOldOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 5 recent, 3 old
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<3 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }

        #expect(oldMessages.count == 3)
        for msg in oldMessages {
            #expect(msg.messageId.hasPrefix("old"))
            #expect(msg.date < archiveCutoff)
        }
    }

    @Test("Bulk archive groups messages by account")
    func bulkArchiveGroupsByAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        let folder1 = try TestDatabase.insertFolder(db, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, accountId: "acc2")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc2")

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!
        let oldDate = archiveCutoff.addingTimeInterval(-86400)

        try TestDatabase.insertMessageHeader(
            db, messageId: "acc1msg", date: oldDate,
            folderId: folder1.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "acc2msg", date: oldDate,
            folderId: folder2.id, accountId: "acc2", folderPath: "INBOX",
            isInInbox: true
        )

        // Simulate the grouping logic from archiveOldMessages
        let inboxFolderIds: Set<String> = [folder1.id, folder2.id]
        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(inboxFolderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }

        let byAccount = Dictionary(grouping: oldMessages, by: \.accountId)
        #expect(byAccount.count == 2)
        #expect(byAccount["acc1"]?.count == 1)
        #expect(byAccount["acc2"]?.count == 1)

        // Verify archive folders exist for both accounts
        for accountId in byAccount.keys {
            let archiveFolder = try db.read { db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue).fetchOne(db)
            }
            #expect(archiveFolder != nil)
        }
    }

    @Test("Bulk archive returns empty when no messages older than cutoff")
    func bulkArchiveEmptyWhenNoOld() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // All recent
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchAll(db)
        }

        #expect(oldMessages.isEmpty)
    }

    // MARK: - Edge cases

    /// ⚠️ REWRITTEN (iOS #70). **Retired symbol: `recencyGateExactLimit`, display name
    /// *"Recency gate with exactly maxRecentEmails messages — all pass"*.** "All pass"
    /// claimed an admission outcome the body never obtained; it counted its own rows.
    /// The displacement half is new: a boundary test that only fills the window
    /// cannot tell an inclusive bound from one that is merely large enough.
    @Test("at exactly maxRecentEmails every Inbox row is inside the window, and one newer arrival displaces exactly the oldest")
    func exactlyMaxRecentEmailsAdmitsEveryRowAndOneMoreDisplacesTheOldest() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        var ids: [String] = []
        for i in 0..<SyncConfig.maxRecentEmails {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "boundary-\(i)",
                date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            ids.append(header.id)
        }
        #expect(ids.count == SyncConfig.maxRecentEmails)
        guard ids.count == SyncConfig.maxRecentEmails, let oldest = ids.last else { return }

        // Inclusive boundary: at exactly the limit nothing is outside the window,
        // and nothing is window-retired for a sync-origin job.
        let before = try windowMembership(of: ids, db: db)
        #expect(before.count == ids.count)
        guard before.count == ids.count else { return }
        #expect(before.filter { $0 }.count == SyncConfig.maxRecentEmails)
        #expect(zip(ids, before).allSatisfy {
            productionAdmits(headerId: $0.0, inRecentWindow: $0.1, windowExempt: false)
        })

        // One newer arrival, and the window must shed exactly one row — the
        // oldest. This is the reject side of the same test: an off-by-one LIMIT
        // fails one half or the other whichever way it drifts.
        let arrival = try TestDatabase.insertMessageHeader(
            db, messageId: "boundary-arrival", date: now.addingTimeInterval(3600),
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true
        )
        let after = try windowMembership(of: ids + [arrival.id], db: db)
        #expect(after.count == ids.count + 1)
        // Asserted, never guarded on: a `guard after.last == true else { return }`
        // would silently swallow the failure it exists to catch.
        guard after.count == ids.count + 1, let arrivalInWindow = after.last else { return }
        #expect(arrivalInWindow)
        #expect(after.filter { $0 }.count == SyncConfig.maxRecentEmails)

        let stillInWindow = Array(after.dropLast())
        let displaced = zip(ids, zip(before, stillInWindow))
            .filter { $0.1.0 && !$0.1.1 }
            .map(\.0)
        #expect(displaced == [oldest])

        guard let oldestNowInWindow = stillInWindow.last else { return }
        #expect(!oldestNowInWindow)
        #expect(!productionAdmits(
            headerId: oldest, inRecentWindow: oldestNowInWindow, windowExempt: false))
        #expect(productionAdmits(
            headerId: oldest, inRecentWindow: oldestNowInWindow, windowExempt: true))
    }

    /// ⚠️ REWRITTEN (iOS #70). **Retired symbol: `recencyGateOnePastLimit`, display
    /// name *"Recency gate with maxRecentEmails + 1 — oldest is rejected"*.**
    /// "Rejected" named an admission outcome; the body only counted rows, and after
    /// ADR-IOS-078 rejection is no longer a property of the row alone — the same
    /// oldest row is admitted for a window-exempt job, which this test now asserts.
    @Test("at maxRecentEmails + 1 exactly one row — the oldest — is outside the window; a sync-origin job for it retires while a window-exempt one is admitted")
    func atOnePastTheLimitExactlyTheOldestRowIsOutsideTheWindow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let total = SyncConfig.maxRecentEmails + 1
        var ids: [String] = []
        for i in 0..<total {
            let header = try TestDatabase.insertMessageHeader(
                db, messageId: "past-limit-\(i)",
                date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            ids.append(header.id)
        }
        #expect(ids.count == total)
        guard ids.count == total else { return }

        let membership = try windowMembership(of: ids, db: db)
        #expect(membership.count == total)
        guard membership.count == total,
              let oldest = ids.last, let newest = ids.first,
              let oldestInWindow = membership.last, let newestInWindow = membership.first
        else { return }

        // Exact cardinality, both sides non-zero.
        #expect(membership.filter { $0 }.count == SyncConfig.maxRecentEmails)
        #expect(membership.filter { !$0 }.count == 1)
        #expect(zip(ids, membership).filter { !$0.1 }.map(\.0) == [oldest])

        #expect(newestInWindow)
        #expect(!oldestInWindow)
        #expect(productionAdmits(
            headerId: newest, inRecentWindow: newestInWindow, windowExempt: false))
        #expect(!productionAdmits(
            headerId: oldest, inRecentWindow: oldestInWindow, windowExempt: false))
        // ADR-IOS-078: the row the sync bound excludes is still processed when the
        // offer comes from an arrival/user-intent origin.
        #expect(productionAdmits(
            headerId: oldest, inRecentWindow: oldestInWindow, windowExempt: true))
    }

    @Test("the production recent-window MEMBERSHIP predicate includes the newest 100 and excludes the oldest (admission outcome is origin-dependent since ADR-IOS-078: windowRetires = !inRecentWindow && !windowExempt)")
    func productionRecentWindowAdmission() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let now = Date()
        var ids: [String] = []

        for i in 0...SyncConfig.maxRecentEmails {
            let header = try TestDatabase.insertMessageHeader(
                db,
                messageId: "window-\(i)",
                date: now.addingTimeInterval(TimeInterval(-i)),
                folderId: folder.id,
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            ids.append(header.id)
        }

        let membership = try db.read { connection in
            (
                try ActiveAIQueue.recentInboxWindowContains(
                    headerId: ids[0], db: connection),
                try ActiveAIQueue.recentInboxWindowContains(
                    headerId: ids[SyncConfig.maxRecentEmails - 1], db: connection),
                try ActiveAIQueue.recentInboxWindowContains(
                    headerId: ids[SyncConfig.maxRecentEmails], db: connection)
            )
        }
        #expect(membership.0)
        #expect(membership.1)
        #expect(!membership.2)
    }

    @Test("automatic population selects recent window before filtering completed work")
    func productionPopulationDoesNotReachPastCompletedRecentRows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let now = Date()

        for i in 0...SyncConfig.maxRecentEmails {
            let header = try TestDatabase.insertMessageHeader(
                db,
                messageId: "population-\(i)",
                date: now.addingTimeInterval(TimeInterval(-i)),
                folderId: folder.id,
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            try db.write { conn in
                if i < SyncConfig.maxRecentEmails {
                    try conn.execute(sql: """
                        UPDATE messageHeader
                        SET bodyComplete = 1,
                            summaryBlurb = 'done',
                            actionTag = 'none',
                            cachedReply = 'done'
                        WHERE id = ?
                    """, arguments: [header.id])
                } else {
                    try conn.execute(
                        sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                        arguments: [header.id]
                    )
                }
            }
        }

        let candidates = try db.read { connection in
            try ActiveAIQueue.repopulationCandidates(db: connection)
        }
        #expect(candidates.isEmpty)
    }

    @Test("small inbox recovery remains admitted and bounded")
    func smallInboxRecoveryPositiveControl() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let now = Date()
        var expectedIds = Set<String>()

        for i in 0..<8 {
            let header = try TestDatabase.insertMessageHeader(
                db,
                messageId: "small-recovery-\(i)",
                date: now.addingTimeInterval(TimeInterval(-i)),
                folderId: folder.id,
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            expectedIds.insert(header.id)
            try db.write {
                try $0.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                    arguments: [header.id]
                )
            }
        }

        // Positive control: the rollback must not suppress ordinary small
        // inboxes. Repeated recovery is finite and does not grow hidden work.
        for _ in 0..<12 {
            let ids = try db.read {
                try ActiveAIQueue.recoveryCandidateHeaderIdsForTesting(db: $0)
            }
            #expect(ids.count == expectedIds.count)
            #expect(Set(ids) == expectedIds)
        }
    }

    @Test("an old direct AI offer creates no DURABLE recovery work (the sweep bucket stays window-bounded; the offer itself is exempt since ADR-IOS-078)")
    func oldDirectOfferCannotBecomeDurableRecoveryWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabmail-ai-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("mail.sqlite").path
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        var oldestId = ""

        do {
            let initialQueue = try DatabaseQueue(
                path: path, configuration: configuration)
            try AppDatabase.runMigrations(on: initialQueue)
            try TestDatabase.insertAccount(initialQueue)
            let folder = try TestDatabase.insertFolder(initialQueue)
            let now = Date()

            // The newest 100 already have complete AI output. The 101st message has
            // a body and missing derived output, exactly the row the retired durable
            // direct marker used to resurrect after an open/push/move event.
            for i in 0...SyncConfig.maxRecentEmails {
                let header = try TestDatabase.insertMessageHeader(
                    initialQueue,
                    messageId: "durable-regression-\(i)",
                    date: now.addingTimeInterval(TimeInterval(-i)),
                    folderId: folder.id,
                    accountId: "acc1",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                try initialQueue.write { db in
                    if i < SyncConfig.maxRecentEmails {
                        try db.execute(sql: """
                            UPDATE messageHeader
                            SET bodyComplete = 1,
                                summaryBlurb = 'done',
                                actionTag = 'none',
                                cachedReply = 'done'
                            WHERE id = ?
                        """, arguments: [header.id])
                    } else {
                        oldestId = header.id
                        try db.execute(
                            sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                            arguments: [header.id]
                        )
                    }
                }
            }

            // When this exact test is run against the pre-rollback schema, set
            // the retired bit exactly as its open/push/move producers did. On
            // the post-rollback schema there is deliberately no such column.
            let columns = try initialQueue.read {
                try String.fetchAll(
                    $0, sql: "SELECT name FROM pragma_table_info('messageHeader')")
            }
            if columns.contains("aiDirectPending") {
                try initialQueue.write {
                    try $0.execute(
                        sql: "UPDATE messageHeader SET aiDirectPending = 1 WHERE id = ?",
                        arguments: [oldestId]
                    )
                }
            }

            // Recovery/sweep candidates stay window-bounded; recovery must reach
            // an empty fixed point, not resurrect the row with a fresh retry
            // budget on every drain. (Since ADR-IOS-078's pathway regating,
            // direct open/push/move events process the row EPHEMERALLY via
            // window-exempt enqueue — but they still create no durable state, so
            // this fixed point is unchanged: nothing here may resurrect the row.)
            for _ in 0..<12 {
                let ids = try initialQueue.read {
                    try ActiveAIQueue.recoveryCandidateHeaderIdsForTesting(db: $0)
                }
                #expect(ids.isEmpty)
                #expect(!ids.contains(oldestId))
            }
        }

        // Dropping and reopening the queue models a process relaunch. With no
        // durable exception, launch recovery still cannot rediscover the row.
        let reopened = try DatabaseQueue(path: path, configuration: configuration)
        for _ in 0..<12 {
            let ids = try reopened.read {
                try ActiveAIQueue.recoveryCandidateHeaderIdsForTesting(db: $0)
            }
            #expect(ids.isEmpty)
            #expect(!ids.contains(oldestId))
        }
    }
}
