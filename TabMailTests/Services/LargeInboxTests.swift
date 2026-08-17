/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the large inbox support feature (matching TB's inboxManagement):
/// 1. SyncConfig constants exist and are reasonable
/// 2. Automatic AI membership is the deterministic newest configured population
///    in each inbox, selected before cached-work filtering
/// 3. Durable direct events bypass that population and survive queue loss/relaunch
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

    // MARK: - AI queue backlog selection and direct-event execution

    @Test("Automatic membership is the newest configured population, not the newest unfinished rows")
    func automaticPopulationPrecedesCachedWorkFilter() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            if i == 0 {
                header.summaryBlurb = "Summary"
                header.actionTag = ActionTag.none
                header.cachedReply = "No reply needed"
            }
            try db.write { try header.update($0) }
        }

        let candidates = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }

        #expect(candidates.count == SyncConfig.maxRecentEmails - 1)
        #expect(!candidates.contains { $0.headerId.hasSuffix(":msg0") })
        #expect(candidates.last?.headerId.hasSuffix(":msg99") == true)
        #expect(!candidates.contains { $0.headerId.hasSuffix(":msg100") })
    }

    @Test("Each inbox receives its own automatic population")
    func automaticPopulationIsIndependentPerInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@example.com")
        let folder1 = try TestDatabase.insertFolder(db, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, accountId: "acc2")

        let now = Date()
        for i in 0..<SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "a\(i)", date: now.addingTimeInterval(Double(-i)),
                folderId: folder1.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            try db.write { try header.update($0) }
        }
        var accountB = try TestDatabase.insertMessageHeader(
            db, messageId: "only-b", date: now.addingTimeInterval(-10_000),
            folderId: folder2.id, accountId: "acc2", folderPath: "INBOX",
            isInInbox: true)
        accountB.bodyComplete = true
        try db.write { try accountB.update($0) }

        let candidates = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }

        #expect(candidates.count == SyncConfig.maxRecentEmails + 1)
        #expect(candidates.contains { $0.headerId == accountB.id && $0.accountId == "acc2" })
    }

    @Test("Equal-date automatic membership is stable, and only direct authority admits the omitted row")
    func equalDateBoundaryIsDeterministicAndDirectlyRecoverable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let date = Date()
        var allIds: [String] = []
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: String(format: "msg%03d", i), date: date,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            try db.write { try header.update($0) }
            allIds.append(header.id)
        }

        let firstBatch = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }
        let expectedFirst = Array(allIds.sorted {
            $1.utf8.lexicographicallyPrecedes($0.utf8)
        }.prefix(SyncConfig.maxRecentEmails))
        #expect(firstBatch.map(\.headerId) == expectedFirst)

        try db.write { db in
            for id in expectedFirst {
                guard var header = try MessageHeader.fetchOne(db, key: id) else { continue }
                header.summaryBlurb = "Summary"
                header.actionTag = .reply
                header.cachedReply = "Reply"
                try header.update(db)
            }
        }

        let secondBatch = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }
        let firstIds = Set(expectedFirst)
        let omitted = allIds.filter { !firstIds.contains($0) }
        #expect(omitted.count == 1)
        #expect(secondBatch.isEmpty,
                "automatic membership stays the newest configured population")

        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: omitted, db: db)
        }
        let directRecovery = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }
        #expect(directRecovery.map(\.headerId) == omitted,
                "an explicit direct event is durable and uncapped")
    }

    @Test("An old direct event survives queue loss and clears only after every durable output lands")
    func oldDirectEventIsDurableUntilComplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        var target: MessageHeader?
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            if i == SyncConfig.maxRecentEmails {
                target = header
            }
            try db.write { try header.update($0) }
        }

        guard let target else {
            Issue.record("Expected the directly selected target")
            return
        }
        let before = try db.read { try ActiveAIQueue.repopulationCandidates(db: $0) }
        #expect(!before.contains { $0.headerId == target.id })

        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: [target.id], db: db)
        }
        let afterRelaunch = try db.read { db -> ([ActiveAIQueue.Candidate], Int) in
            let candidates = try ActiveAIQueue.repopulationCandidates(db: db)
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [target.id]) ?? 0
            return (candidates, pending)
        }
        #expect(afterRelaunch.0.contains { $0.headerId == target.id })
        #expect(afterRelaunch.1 == 1)
        #expect(ActiveAIQueue.jobStartDisposition(
            message: target, jobType: .summary, admission: .admissible) == .execute)

        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: target.id) else { return }
            header.summaryBlurb = "Summary"
            try header.update(db)
            try ActiveAIQueue.clearDirectPendingIfComplete(headerId: target.id, db: db)
        }
        let afterPartial = try db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [target.id]) ?? 0
        }
        #expect(afterPartial == 1)

        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: target.id) else { return }
            header.actionTag = ActionTag.none
            header.cachedReply = "No reply needed"
            try header.update(db)
            try ActiveAIQueue.clearDirectPendingIfComplete(headerId: target.id, db: db)
        }
        let complete = try db.read { db -> (Int, Bool) in
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [target.id]) ?? 0
            let selected = try ActiveAIQueue.repopulationCandidates(db: db)
                .contains { $0.headerId == target.id }
            return (pending, selected)
        }
        #expect(complete.0 == 0)
        #expect(complete.1 == false)
    }

    @Test("Drain recovery preserves full, partial, and body-pending direct events across relaunch")
    func productionDrainRecoveryPreservesEveryNonterminalDirectShape() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let oldDate = try #require(Calendar.current.date(
            byAdding: .day, value: -(SyncConfig.archiveAgeDays + 1), to: Date()))

        var full = try TestDatabase.insertMessageHeader(
            db, messageId: "direct-full", date: oldDate,
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true, rfc822MessageId: "direct-full@example.com")
        full.bodyComplete = true

        var partial = try TestDatabase.insertMessageHeader(
            db, messageId: "direct-partial", date: oldDate.addingTimeInterval(1),
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true, rfc822MessageId: "direct-partial@example.com")
        partial.bodyComplete = true
        partial.summaryBlurb = "Already summarized"

        var bodyPending = try TestDatabase.insertMessageHeader(
            db, messageId: "direct-body-pending", date: oldDate.addingTimeInterval(2),
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true, rfc822MessageId: "direct-body-pending@example.com")
        bodyPending.headerComplete = true
        bodyPending.bodyComplete = false

        try db.write { db in
            try full.update(db)
            try partial.update(db)
            try bodyPending.update(db)
            try ActiveAIQueue.markDirectPending(
                headerIds: [full.id, partial.id, bodyPending.id], db: db)
        }

        func recover() throws -> ([String: ActiveAIQueue.Candidate.Authority], [String: Int]) {
            try db.write { db in
                let candidates = try ActiveAIQueue.drainRecoveryCandidates(db: db)
                let authorities = Dictionary(uniqueKeysWithValues:
                    candidates.map { ($0.headerId, $0.authority) })
                let markers = try Row.fetchAll(db, sql: """
                    SELECT id, aiDirectPending FROM messageHeader
                    WHERE id IN (?, ?, ?)
                    """, arguments: [full.id, partial.id, bodyPending.id])
                return (authorities, Dictionary(uniqueKeysWithValues: markers.map {
                    (($0["id"] as String), ($0["aiDirectPending"] as Int))
                }))
            }
        }

        let firstLaunch = try recover()
        #expect(firstLaunch.0[full.id] == .direct)
        #expect(firstLaunch.0[partial.id] == .direct)
        #expect(firstLaunch.0[bodyPending.id] == nil,
                "body-incomplete direct work remains discoverable by ActiveBodyQueue first")
        #expect(firstLaunch.1.values.allSatisfy { $0 == 1 })
        #expect(try db.read { try ActiveBodyQueue.repopulationCandidates(db: $0) }
            .contains { $0.headerId == bodyPending.id })

        let secondLaunch = try recover()
        #expect(secondLaunch.0[full.id] == .direct)
        #expect(secondLaunch.0[partial.id] == .direct)
        #expect(secondLaunch.0[bodyPending.id] == nil)
        #expect(secondLaunch.1.values.allSatisfy { $0 == 1 },
                "production pruning cannot age out a valid direct event")
    }

    @Test("All automatic body producers refuse the 101st row until a direct marker exists")
    func automaticBodyProducerScopesShareTheBoundedAdmission() throws {
        // These labels are the three production origins that reach
        // `.automaticRecentWindow`: ActiveBodyQueue (including provider-delta
        // body work), and InboxViewModel's list-snippet fetch. They intentionally
        // converge on the same production finalizer and candidate selector.
        for producer in ["active-body", "provider-delta", "list-snippet"] {
            let db = try TestDatabase.make()
            try TestDatabase.insertAccount(db)
            let folder = try TestDatabase.insertFolder(db)
            let now = Date()
            var target: MessageHeader?
            for i in 0...SyncConfig.maxRecentEmails {
                var header = try TestDatabase.insertMessageHeader(
                    db, messageId: "\(producer)-\(i)",
                    date: now.addingTimeInterval(Double(-i)),
                    folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                    isInInbox: true)
                header.bodyComplete = i != SyncConfig.maxRecentEmails
                if i < SyncConfig.maxRecentEmails {
                    header.summaryBlurb = "Complete"
                    header.actionTag = ActionTag.none
                    header.cachedReply = "Complete"
                } else {
                    target = header
                }
                try db.write { try header.update($0) }
            }
            let old = try #require(target)
            let processed = BodyFetchProcessor.ProcessedItem(
                contentKey: ContentKey(rawValue: old.id), headerId: old.id,
                accountId: old.accountId, isInInbox: true,
                body: "body", snippet: "snippet")

            let unmarked = try db.write { db -> [BodyFetchProcessor.AIEnqueueCandidate] in
                let durable = try BodyFetchProcessor.finalizeConfirmedItems(
                    [processed], aiEnqueueScope: .automaticRecentWindow, db: db)
                return try BodyFetchProcessor.automaticAIEnqueueCandidates(
                    from: durable, db: db)
            }
            #expect(unmarked.isEmpty,
                    "\(producer) must not turn an out-of-window body into automatic AI work")

            let marked = try db.write { db -> [BodyFetchProcessor.AIEnqueueCandidate] in
                try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
                return try BodyFetchProcessor.automaticAIEnqueueCandidates(
                    from: [processed], db: db)
            }
            #expect(marked.map { $0.item.headerId } == [old.id])
            #expect(marked.first?.candidate.authority == .direct,
                    "a separate direct event admits the exact same physical row")
        }
    }

    @Test("A marked old row crosses production body discovery and AI admission selectors")
    func markedOldBodyFlowsFromBodyFetchToAI() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let now = Date()
        var target: MessageHeader?
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "body\(i)", date: now.addingTimeInterval(Double(-i)),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true)
            header.headerComplete = true
            header.bodyComplete = i != SyncConfig.maxRecentEmails
            try db.write { try header.update($0) }
            if i == SyncConfig.maxRecentEmails { target = header }
        }
        let old = try #require(target)
        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
        }
        let bodyCandidates = try db.read { db in
            try ActiveBodyQueue.repopulationCandidates(db: db)
        }
        #expect(bodyCandidates.contains { $0.headerId == old.id },
                "incomplete-body discovery must stay uncapped for a durable direct event")
        #expect(try db.read { try ActiveAIQueue.repopulationCandidates(db: $0) }
            .contains { $0.headerId == old.id } == false)

        let processed = BodyFetchProcessor.ProcessedItem(
            contentKey: ContentKey(rawValue: old.id), headerId: old.id,
            accountId: old.accountId, isInInbox: true,
            body: "direct body", snippet: "direct body")
        let admitted = try db.write { db -> [BodyFetchProcessor.AIEnqueueCandidate] in
            try db.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                arguments: [old.id])
            return try BodyFetchProcessor.automaticAIEnqueueCandidates(
                from: [processed], db: db)
        }
        #expect(admitted.map { $0.item.headerId } == [old.id])
    }

    @Test("Provider-confirmed empty wins a race with body finalization")
    func confirmedEmptyRefusesLateBodyFinalization() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "empty-finalization", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.bodyComplete = false
        header.bodyEmptyConfirmed = true
        try db.write { try header.update($0) }

        let processed = BodyFetchProcessor.ProcessedItem(
            contentKey: ContentKey(rawValue: header.id), headerId: header.id,
            accountId: header.accountId, isInInbox: true,
            body: "stale nonempty body", snippet: "stale snippet")
        let durable = try db.write { db in
            try BodyFetchProcessor.finalizeConfirmedItems(
                [processed], aiEnqueueScope: .automaticRecentWindow, db: db)
        }
        let stored = try db.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }

        #expect(durable.isEmpty)
        #expect(stored?.bodyEmptyConfirmed == true)
        #expect(stored?.bodyComplete == false,
                "a late flush must not overturn the provider's terminal empty result")
        #expect(stored?.snippet != "stale snippet")
    }

    @Test("The durable direct marker and sparse recovery index ship in the migrated schema")
    func directPendingSchemaExists() throws {
        let db = try TestDatabase.make()
        let evidence = try db.read { db -> (String?, String?, String?, [String], Set<String>) in
            let defaultValue = try String.fetchOne(db, sql: """
                SELECT dflt_value FROM pragma_table_info('messageHeader')
                WHERE name = 'aiDirectPending'
            """)
            let cacheDefault = try String.fetchOne(db, sql: """
                SELECT dflt_value FROM pragma_table_info('messageAICache')
                WHERE name = 'aiDirectPending'
            """)
            let indexSQL = try String.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master
                WHERE type = 'index' AND name = 'messageHeader_directAIPending'
            """)
            let prunePlan = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN \(ActiveAIQueue.pruneDirectPendingSQL)"
            ).compactMap { $0["detail"] as String? }
            let triggers = Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND name LIKE 'messageHeader_%DirectPending%'
            """))
            return (defaultValue, cacheDefault, indexSQL, prunePlan, triggers)
        }
        #expect(evidence.0 == "0")
        #expect(evidence.1 == "0")
        #expect(evidence.2?.hasSuffix("WHERE aiDirectPending = 1") == true)
        #expect(evidence.3.contains { $0.contains("messageHeader_directAIPending") },
                "terminal cleanup must seek the sparse pending-only index")
        #expect(evidence.4 == [
            "messageHeader_clearDirectPendingOnInboxExit",
            "messageHeader_clearDirectPendingCache",
            "messageHeader_clearDirectPendingCacheOnDelete",
            "messageHeader_restoreDirectPendingAfterInsert",
        ])
    }

    @Test("RFC-bearing direct intent survives UID reset delete and re-arms the resynced row")
    func directPendingSurvivesUIDResetThroughAICacheIdentity() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)
        folder.uidValidityResetPendingAt = Date()
        try db.write { try folder.update($0) }

        var original = try TestDatabase.insertMessageHeader(
            db, messageId: "old-uid", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        original.rfc822MessageId = "same-message@example.com"
        try db.write { db in
            try original.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [original.id], db: db)
        }
        let cacheKey = try #require(MessageAICache.cacheKey(
            accountId: original.accountId, folderPath: original.folderPath,
            rfc822MessageId: original.rfc822MessageId))
        #expect(try db.read {
            try Bool.fetchOne($0, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?", arguments: [cacheKey])
        } == true)

        _ = try db.write { db in try original.delete(db) }
        #expect(try db.read {
            try Bool.fetchOne($0, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?", arguments: [cacheKey])
        } == true, "the reset-pending delete must retain RFC-keyed direct intent")

        var resynced = MessageHeader(
            messageId: "new-uid", subject: "Resynced", from: "Sender",
            fromAddress: "sender@example.com", to: "user@example.com", date: Date(),
            snippet: "", folderId: folder.id, accountId: "acc1",
            folderPath: "INBOX", isInInbox: true)
        resynced.rfc822MessageId = original.rfc822MessageId
        resynced.headerComplete = true
        try db.write { try resynced.insert($0) }
        #expect(try db.read {
            try Int.fetchOne($0, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?", arguments: [resynced.id])
        } == 1)
        #expect(try db.read { try ActiveBodyQueue.repopulationCandidates(db: $0) }
            .contains { $0.headerId == resynced.id })

        resynced.summaryBlurb = "Summary"
        resynced.actionTag = ActionTag.none
        resynced.cachedReply = ""
        try db.write { db in
            try resynced.update(db)
            try ActiveAIQueue.clearDirectPendingIfComplete(
                headerId: resynced.id, db: db)
        }
        let cleared = try db.read { db -> (Int, Bool?) in
            let header = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [resynced.id]) ?? -1
            let cache = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [cacheKey])
            return (header, cache)
        }
        #expect(cleared.0 == 0)
        #expect(cleared.1 == false)
    }

    @Test("Clearing one duplicate does not retire another row's RFC-keyed direct intent")
    func directPendingCacheClearsOnlyAfterTheLastLiveDuplicate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        var first = try TestDatabase.insertMessageHeader(
            db, messageId: "dup-a", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        var second = try TestDatabase.insertMessageHeader(
            db, messageId: "dup-b", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        first.rfc822MessageId = "duplicate@example.com"
        second.rfc822MessageId = first.rfc822MessageId
        try db.write { db in
            try first.update(db)
            try second.update(db)
            try ActiveAIQueue.markDirectPending(
                headerIds: [first.id, second.id], db: db)
        }
        let key = try #require(MessageAICache.cacheKey(
            accountId: first.accountId, folderPath: first.folderPath,
            rfc822MessageId: first.rfc822MessageId))

        _ = try db.write { db in try first.delete(db) }
        #expect(try db.read {
            try Bool.fetchOne($0, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?", arguments: [key])
        } == true)

        _ = try db.write { db in try second.delete(db) }
        #expect(try db.read {
            try Bool.fetchOne($0, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?", arguments: [key])
        } == false)
    }

    @Test("A selected direct candidate cannot authorize a replacement at the same address")
    func selectedCandidateRetainsPhysicalIdentityThroughQueueMapping() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        var original = try TestDatabase.insertMessageHeader(
            db, messageId: "reused", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        original.rfc822MessageId = "original@example.com"
        original.bodyComplete = true
        try db.write { db in
            try original.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [original.id], db: db)
        }
        let candidate = try db.read {
            try #require(try ActiveAIQueue.directCandidate(headerId: original.id, db: $0))
        }

        var replacement = original
        replacement.rfc822MessageId = "replacement@example.com"
        replacement.summaryBlurb = nil
        replacement.actionTag = nil
        replacement.cachedReply = nil
        try db.write { db in
            try original.delete(db)
            try replacement.insert(db)
        }
        let job = try #require(
            ActiveAIQueue.jobs(for: candidate, includeAction: true)
                .first { $0.jobType == .summary })
        #expect(job.target == candidate.target)
        #expect(job.requiresDirectMarker)
        let evidence = try db.read { db -> (MessageHeader?, MessageHeader?) in
            let bare = try MessageHeader.fetchOne(db, key: replacement.id)
            let guarded = try ActiveAIQueue.resolveSelectedJobMessage(job, db: db)
            return (bare, guarded)
        }
        #expect(evidence.0?.rfc822MessageId == "replacement@example.com",
                "non-vacuity: a live replacement really occupies the address")
        #expect(evidence.1 == nil,
                "the selected candidate must not be recaptured from the replacement")
    }

    @Test("Direct authority upgrades the same target without duplicating its jobs")
    func directAndAutomaticJobsDeduplicateForTheSamePhysicalMessage() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "authority-upgrade", folderId: folder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        let target = try db.read { db in
            try #require(try AIWriteTarget.capture(message: header, db: db))
        }
        let automatic = ActiveAIQueue.AIJob(
            headerId: header.id, accountId: header.accountId,
            jobType: .summary, target: target, requiresDirectMarker: false)
        let direct = ActiveAIQueue.AIJob(
            headerId: header.id, accountId: header.accountId,
            jobType: .summary, target: target, requiresDirectMarker: true)

        #expect(automatic == direct)
        #expect(Set([automatic, direct]).count == 1,
                "adding a direct marker must not launch a second model call for the same target")
    }

    @Test("Leaving Inbox atomically retires direct authority before any re-entry")
    func inboxScopeExitClearsDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "scope-exit", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.bodyComplete = true
        try db.write { db in
            try header.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [header.id], db: db)
            try db.execute(
                sql: "UPDATE messageHeader SET isInInbox = 0 WHERE id = ?",
                arguments: [header.id])
            try db.execute(
                sql: "UPDATE messageHeader SET isInInbox = 1 WHERE id = ?",
                arguments: [header.id])
        }
        let evidence = try db.read { db -> (Int, ActiveAIQueue.Candidate.Authority?) in
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? 0
            let authority = try ActiveAIQueue.repopulationCandidates(db: db)
                .first { $0.headerId == header.id }?.authority
            return (pending, authority)
        }
        #expect(evidence.0 == 0)
        #expect(evidence.1 == .automatic,
                "re-entry may qualify automatically, but cannot reactivate stale direct authority")
    }

    @Test("Inbox role loss atomically retires only that folder's direct authority")
    func folderRoleLossClearsMarkerAndMirrorWithoutResurrection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com")
        let affectedFolder = try TestDatabase.insertFolder(db, accountId: "acc1")
        let bystanderFolder = Folder(
            name: "Focused", path: "Focused", role: .inbox, accountId: "acc1")
        try db.write { try bystanderFolder.insert($0) }

        var affected = try TestDatabase.insertMessageHeader(
            db, messageId: "affected", folderId: affectedFolder.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: "affected@example.com")
        affected.bodyComplete = true
        var bystander = try TestDatabase.insertMessageHeader(
            db, messageId: "bystander", folderId: bystanderFolder.id,
            accountId: "acc1", folderPath: "Focused", isInInbox: true,
            rfc822MessageId: "bystander@example.com")
        bystander.bodyComplete = true
        var foreignAccount = try TestDatabase.insertMessageHeader(
            db, messageId: "foreign-account", folderId: affectedFolder.id,
            accountId: "acc2", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: "foreign-account@example.com")
        foreignAccount.bodyComplete = true

        let affectedKey = try #require(MessageAICache.cacheKey(
            accountId: affected.accountId, folderPath: affected.folderPath,
            rfc822MessageId: affected.rfc822MessageId))
        let bystanderKey = try #require(MessageAICache.cacheKey(
            accountId: bystander.accountId, folderPath: bystander.folderPath,
            rfc822MessageId: bystander.rfc822MessageId))
        let foreignKey = try #require(MessageAICache.cacheKey(
            accountId: foreignAccount.accountId, folderPath: foreignAccount.folderPath,
            rfc822MessageId: foreignAccount.rfc822MessageId))

        try db.write { db in
            try affected.update(db)
            try bystander.update(db)
            try foreignAccount.update(db)
            try ActiveAIQueue.markDirectPending(
                headerIds: [affected.id, bystander.id], db: db)

            // This intentionally inconsistent row proves the trigger validates
            // account as well as folder identity. messageHeader.folderId has no FK;
            // a bulk role cleanup must not treat the bare folder id as authority.
            try db.execute(
                sql: "UPDATE messageHeader SET aiDirectPending = 1 WHERE id = ?",
                arguments: [foreignAccount.id])
            var foreignMirror = MessageAICache(
                key: foreignKey, rfc822MessageId: foreignAccount.rfc822MessageId)
            foreignMirror.aiDirectPending = true
            try foreignMirror.insert(db)

            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [FolderRole.archive.rawValue, affectedFolder.id])
        }

        let afterLoss = try db.read { db -> ([String: Int], [String: Bool?], Bool) in
            let markers = try Row.fetchAll(db, sql: """
                SELECT id, aiDirectPending FROM messageHeader
                WHERE id IN (?, ?, ?)
                """, arguments: [affected.id, bystander.id, foreignAccount.id])
            let markerById = Dictionary(uniqueKeysWithValues: markers.map {
                (($0["id"] as String), ($0["aiDirectPending"] as Int))
            })
            let mirrors = [affectedKey, bystanderKey, foreignKey]
            let mirrorByKey = Dictionary(uniqueKeysWithValues: try mirrors.map { key in
                (key, try Bool.fetchOne(
                    db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                    arguments: [key]))
            })
            let staleInboxBit = try Bool.fetchOne(
                db, sql: "SELECT isInInbox FROM messageHeader WHERE id = ?",
                arguments: [affected.id]) ?? false
            return (markerById, mirrorByKey, staleInboxBit)
        }
        #expect(afterLoss.0[affected.id] == 0)
        #expect(afterLoss.1[affectedKey] == false,
                "the nested header trigger must retire the RFC mirror in the same transaction")
        #expect(afterLoss.2,
                "the role trigger must not depend on the stale denormalized isInInbox bit")
        #expect(afterLoss.0[bystander.id] == 1)
        #expect(afterLoss.1[bystanderKey] == true)
        #expect(afterLoss.0[foreignAccount.id] == 1)
        #expect(afterLoss.1[foreignKey] == true)

        try db.write { db in
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [FolderRole.inbox.rawValue, affectedFolder.id])
        }
        let afterReassignment = try db.write { db -> (Int, Bool?, ActiveAIQueue.Candidate.Authority?) in
            let candidates = try ActiveAIQueue.drainRecoveryCandidates(db: db)
            let marker = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [affected.id]) ?? -1
            let mirror = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [affectedKey])
            return (marker, mirror,
                    candidates.first { $0.headerId == affected.id }?.authority)
        }
        #expect(afterReassignment.0 == 0)
        #expect(afterReassignment.1 == false)
        #expect(afterReassignment.2 == .automatic,
                "role reassignment may restore automatic eligibility, never the retired direct event")
    }

    @Test("Inbox exit clears the source-path mirror before an old-path reinsert")
    func inboxExitCannotResurrectFromTheOldCacheKey() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        let archive = Folder(
            name: "Archive", path: "Archive", role: .archive,
            accountId: "acc1")
        try db.write { try archive.insert($0) }
        var moved = try TestDatabase.insertMessageHeader(
            db, messageId: "scope-key", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        moved.rfc822MessageId = "scope-key@example.com"
        try db.write { db in
            try moved.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [moved.id], db: db)
            try db.execute(sql: """
                UPDATE messageHeader
                SET folderId = ?, folderPath = 'Archive', isInInbox = 0
                WHERE id = ?
            """, arguments: [archive.id, moved.id])
        }
        let fresh = try TestDatabase.insertMessageHeader(
            db, messageId: "fresh-old-path", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: moved.rfc822MessageId)
        let oldKey = try #require(MessageAICache.cacheKey(
            accountId: moved.accountId, folderPath: "INBOX",
            rfc822MessageId: moved.rfc822MessageId))
        let evidence = try db.read { db -> (Bool?, Int) in
            let mirror = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [oldKey])
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [fresh.id]) ?? 0
            return (mirror, pending)
        }
        #expect(evidence.0 == false)
        #expect(evidence.1 == 0,
                "a later message at the departed path cannot inherit the old event")
    }

    @Test("A live Inbox path change relocates the reset-survival mirror")
    func inboxPathChangeCarriesDirectMirrorAcrossReset() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let first = try TestDatabase.insertFolder(db)
        var second = Folder(
            name: "Focused", path: "Focused", role: .inbox,
            accountId: "acc1")
        try db.write { try second.insert($0) }
        var moved = try TestDatabase.insertMessageHeader(
            db, messageId: "path-change", folderId: first.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        moved.rfc822MessageId = "path-change@example.com"
        try db.write { db in
            try moved.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [moved.id], db: db)
            try db.execute(sql: """
                UPDATE messageHeader
                SET folderId = ?, folderPath = 'Focused', isInInbox = 1
                WHERE id = ?
            """, arguments: [second.id, moved.id])
        }
        let oldKey = try #require(MessageAICache.cacheKey(
            accountId: moved.accountId, folderPath: "INBOX",
            rfc822MessageId: moved.rfc822MessageId))
        let newKey = try #require(MessageAICache.cacheKey(
            accountId: moved.accountId, folderPath: "Focused",
            rfc822MessageId: moved.rfc822MessageId))
        let carried = try db.read { db -> (Bool?, Bool?) in
            (try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [oldKey]),
             try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [newKey]))
        }
        #expect(carried.0 == false)
        #expect(carried.1 == true)

        second.uidValidityResetPendingAt = Date()
        try db.write { db in
            try second.update(db)
            try MessageHeader.deleteOne(db, key: moved.id)
        }
        let resynced = try TestDatabase.insertMessageHeader(
            db, messageId: "path-change-new-uid", folderId: second.id,
            accountId: "acc1", folderPath: "Focused", isInInbox: true,
            rfc822MessageId: moved.rfc822MessageId)
        let restored = try db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [resynced.id]) ?? 0
        }
        #expect(restored == 1)
    }

    @Test("RFC enrichment and replacement relocate the reset-survival mirror")
    func rfcIdentityChangeCarriesDirectMirrorAcrossReset() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var inbox = try TestDatabase.insertFolder(db)
        let pending = try TestDatabase.insertMessageHeader(
            db, messageId: "rfc-enrichment", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: [pending.id], db: db)
            try db.execute(
                sql: "UPDATE messageHeader SET rfc822MessageId = ? WHERE id = ?",
                arguments: ["enriched-a@example.com", pending.id])
        }
        let firstKey = try #require(MessageAICache.cacheKey(
            accountId: pending.accountId, folderPath: pending.folderPath,
            rfc822MessageId: "enriched-a@example.com"))
        #expect(try db.read {
            try Bool.fetchOne(
                $0, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [firstKey])
        } == true, "nil-to-RFC enrichment must create the reset-survival mirror")

        try db.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET rfc822MessageId = ? WHERE id = ?",
                arguments: ["enriched-b@example.com", pending.id])
        }
        let finalKey = try #require(MessageAICache.cacheKey(
            accountId: pending.accountId, folderPath: pending.folderPath,
            rfc822MessageId: "enriched-b@example.com"))
        let relocated = try db.read { db -> (Bool?, Bool?) in
            (try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [firstKey]),
             try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [finalKey]))
        }
        #expect(relocated.0 == false)
        #expect(relocated.1 == true,
                "an accepted RFC replacement must move rather than duplicate authority")

        inbox.uidValidityResetPendingAt = Date()
        try db.write { db in
            try inbox.update(db)
            try MessageHeader.deleteOne(db, key: pending.id)
        }
        let resynced = try TestDatabase.insertMessageHeader(
            db, messageId: "rfc-enrichment-new-uid", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: "enriched-b@example.com")
        #expect(try db.read {
            try Int.fetchOne(
                $0, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [resynced.id])
        } == 1, "the enriched identity must survive reset deletion and resync")
    }

    @Test("A coordinate change cannot re-arm authority cleared by the same update")
    func coordinateChangeWithTerminalClearDoesNotResurrect() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var inbox = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "coordinate-clear", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: "coordinate-old@example.com")
        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: [header.id], db: db)
            try db.execute(sql: """
                UPDATE messageHeader
                SET rfc822MessageId = ?, aiDirectPending = 0
                WHERE id = ?
            """, arguments: ["coordinate-new@example.com", header.id])
        }
        let oldKey = try #require(MessageAICache.cacheKey(
            accountId: header.accountId, folderPath: header.folderPath,
            rfc822MessageId: "coordinate-old@example.com"))
        let newKey = try #require(MessageAICache.cacheKey(
            accountId: header.accountId, folderPath: header.folderPath,
            rfc822MessageId: "coordinate-new@example.com"))
        let cleared = try db.read { db -> (Int, Bool?, Bool?) in
            let live = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? -1
            let oldMirror = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [oldKey])
            let newMirror = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [newKey])
            return (live, oldMirror, newMirror)
        }
        #expect(cleared.0 == 0)
        #expect(cleared.1 == false)
        #expect(cleared.2 != true,
                "the coordinate trigger cannot resurrect terminally cleared authority")

        inbox.uidValidityResetPendingAt = Date()
        try db.write { db in
            try inbox.update(db)
            try MessageHeader.deleteOne(db, key: header.id)
        }
        let resynced = try TestDatabase.insertMessageHeader(
            db, messageId: "coordinate-clear-new-uid", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: "coordinate-new@example.com")
        #expect(try db.read {
            try Int.fetchOne(
                $0, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [resynced.id])
        } == 0)
    }

    @Test("Folder removal retires direct authority before deterministic-id recreation")
    func vanishedInboxFolderClearsDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "vanished-folder", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.bodyComplete = true
        try db.write { db in
            try header.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [header.id], db: db)
            try SyncEngine.retireDirectAIForVanishedFolder(inbox, db: db)
            try inbox.delete(db)
            try inbox.insert(db)
        }
        let evidence = try db.read { db -> (Int, ActiveAIQueue.Candidate.Authority?) in
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? 0
            let authority = try ActiveAIQueue.repopulationCandidates(db: db)
                .first { $0.headerId == header.id }?.authority
            return (pending, authority)
        }
        #expect(evidence.0 == 0)
        #expect(evidence.1 == .automatic,
                "folder recreation may qualify automatically, but cannot reactivate the old event")
    }

    @Test("Drain recovery prunes a legacy orphaned direct marker")
    func drainRecoveryPrunesVanishedFolderMarker() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "legacy-orphan", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.bodyComplete = true
        let recovered = try db.write { db in
            try header.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [header.id], db: db)
            try inbox.delete(db)
            return try ActiveAIQueue.drainRecoveryCandidates(db: db)
        }
        let pending = try db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? 0
        }
        #expect(pending == 0)
        #expect(!recovered.contains { $0.headerId == header.id })
    }

    @Test("A re-key out of Inbox does not carry direct authority")
    func rekeyOutOfInboxClearsDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        let archive = try TestDatabase.insertFolder(
            db, name: "Archive", path: "Archive", role: .archive)
        var old = try TestDatabase.insertMessageHeader(
            db, messageId: "move-out", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        old.bodyComplete = true
        try db.write { db in
            try old.update(db)
            try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
        }
        var migrated = old
        migrated.id = MessageIdentity.headerId(
            accountId: "acc1", folderPath: "Archive", messageId: old.messageId)
        migrated.folderId = archive.id
        migrated.folderPath = "Archive"
        migrated.isInInbox = false

        let evidence = try db.write { db -> (Bool, Int) in
            let applied = try MessageHeaderRekey.apply(from: old, to: migrated, db: db)
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [migrated.id]) ?? 0
            return (applied, pending)
        }
        #expect(evidence.0)
        #expect(evidence.1 == 0, "Inbox exit is terminal for the direct event")
    }

    @Test("A header re-key carries direct authority to the new key")
    func rekeyCarriesDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        var old = try TestDatabase.insertMessageHeader(
            db, messageId: "old", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        old.bodyComplete = true
        try db.write { try old.update($0) }
        var migrated = old
        migrated.messageId = "new"
        migrated.id = MessageIdentity.headerId(
            accountId: "acc1", folderPath: "INBOX", messageId: "new")

        let evidence = try db.write { db -> (Bool, Int, Int, Int) in
            try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
            let applied = try MessageHeaderRekey.apply(from: old, to: migrated, db: db)
            let oldPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [old.id]) ?? 0
            let newPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [migrated.id]) ?? 0
            let newBodyComplete = try Int.fetchOne(
                db, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [migrated.id]) ?? 1
            return (applied, oldPending, newPending, newBodyComplete)
        }
        #expect(evidence.0 == true)
        #expect(evidence.1 == 0)
        #expect(evidence.2 == 1)
        #expect(evidence.3 == 0,
                "a marked re-key stays body-recoverable until cross-database FTS catches up")
    }

    @Test("A re-key collision never transfers direct authority without identity proof")
    func rekeyCollisionRetainsUnprovenDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db)
        let old = try TestDatabase.insertMessageHeader(
            db, messageId: "old", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        let survivor = try TestDatabase.insertMessageHeader(
            db, messageId: "new", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        var migrated = old
        migrated.messageId = survivor.messageId
        migrated.id = survivor.id

        try db.write { db in
            try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
        }
        var refused = false
        do {
            _ = try db.write { db in
                try MessageHeaderRekey.apply(from: old, to: migrated, db: db)
            }
        } catch is DirectAIRekeyCollisionUnproven {
            refused = true
        }
        let evidence = try db.read { db -> (Int, Int, Int) in
            let oldCount = try MessageHeader.filter(Column("id") == old.id).fetchCount(db)
            let oldPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [old.id]) ?? 0
            let survivorPending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [survivor.id]) ?? 0
            return (oldCount, oldPending, survivorPending)
        }
        #expect(refused)
        #expect(evidence.0 == 1, "unknown identity retains the marked source row")
        #expect(evidence.1 == 1)
        #expect(evidence.2 == 0, "the unrelated survivor receives no authority")
    }

    @Test("A provider-proved collision keeps the sole RFC identity and reset mirror")
    func provedCollisionPreservesRFCBackedDirectPending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        var inbox = try TestDatabase.insertFolder(db)
        inbox.lastKnownUidValidity = 42
        let archive = Folder(
            name: "Archive", path: "Archive", role: .archive,
            accountId: "acc1")
        try db.write { db in
            try inbox.update(db)
            try archive.insert(db)
        }
        var old = try TestDatabase.insertMessageHeader(
            db, messageId: "old-rfc", folderId: archive.id,
            accountId: "acc1", folderPath: "Archive", isInInbox: false)
        old.rfc822MessageId = "proved-collision@example.com"
        try db.write { db in
            try old.update(db)
            try db.execute(sql: """
                UPDATE messageHeader
                SET folderId = ?, folderPath = 'INBOX', isInInbox = 1
                WHERE id = ?
            """, arguments: [inbox.id, old.id])
            try ActiveAIQueue.markDirectPending(headerIds: [old.id], db: db)
        }
        var survivor = try TestDatabase.insertMessageHeader(
            db, messageId: "stable-destination", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        survivor.observedUidValidity = 42
        try db.write { try survivor.update($0) }
        let op = PendingOperation(
            type: .move, messageIds: [old.messageId], accountId: old.accountId,
            folderPath: "Archive", destinationPath: "INBOX",
            observedUidValidity: 41)
        try db.write { db in
            _ = try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: old.messageId,
                    destinationProviderId: survivor.messageId,
                    destinationUidValidity: 42)],
                addressChangesOnMove: true, db: db)
        }
        let cacheKey = try #require(MessageAICache.cacheKey(
            accountId: old.accountId, folderPath: "INBOX",
            rfc822MessageId: old.rfc822MessageId))
        let carried = try db.read { db -> (Bool, String?, Int, Bool?) in
            let oldExists = try MessageHeader.fetchOne(db, key: old.id) != nil
            let current = try MessageHeader.fetchOne(db, key: survivor.id)
            let pending = try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [survivor.id]) ?? 0
            let mirror = try Bool.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageAICache WHERE key = ?",
                arguments: [cacheKey])
            return (oldExists, current?.rfc822MessageId, pending, mirror)
        }
        #expect(!carried.0)
        #expect(carried.1 == old.rfc822MessageId)
        #expect(carried.2 == 1)
        #expect(carried.3 == true)

        inbox.uidValidityResetPendingAt = Date()
        try db.write { db in
            try inbox.update(db)
            try MessageHeader.deleteOne(db, key: survivor.id)
        }
        let resynced = try TestDatabase.insertMessageHeader(
            db, messageId: "renumbered-destination", folderId: inbox.id,
            accountId: "acc1", folderPath: "INBOX", isInInbox: true,
            rfc822MessageId: old.rfc822MessageId)
        let restored = try db.read { db in
            try Int.fetchOne(
                db, sql: "SELECT aiDirectPending FROM messageHeader WHERE id = ?",
                arguments: [resynced.id]) ?? 0
        }
        #expect(restored == 1,
                "the actual collision proof must survive UIDVALIDITY delete and resync")
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
        try TestDatabase.insertAccount(db, id: "acc1", email: "archive-a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "archive-b@example.com")
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

}
