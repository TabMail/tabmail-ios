/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// `IOS-NSE-005` — the NSE staging key is `"<accountId>:<messageId>"`, with no
/// folder, no epoch and no generation in it, and on IMAP a UIDVALIDITY turnover
/// can reissue the same UID to a DIFFERENT message. `NSEStagingDB.stageHeader`
/// overwrote the identity columns while deliberately RETAINING the body/AI
/// payload, so the predecessor's content ended up beside the successor's
/// identity — and nothing downstream could tell.
///
/// **THE INVARIANT UNDER TEST, stated as a system property:** *staged content
/// produced for one message is never delivered, indexed, cached or put on the
/// wire under a different message's identity.*
///
/// Every assertion here is written as "no artifact of the predecessor appears
/// anywhere", never as "the clear-arm ran". A test that asserted
/// `htmlContent == nil` after a conflicting stage would pin the fix's MECHANISM
/// and stay green on a re-broken system (`MIS-015`), so the predecessor's
/// content carries a unique token and the durable side is swept for it — header
/// fields, `messageBody`, `messageAICache` and the `pendingOperation` queue that
/// would put an action tag on the WIRE against the wrong message.
///
/// **Two-sided by construction.** Two of the four tests are ANCHORS: they hold
/// the OPPOSITE direction, because retention is CORRECT for a re-push of the
/// same message and for the `AIOwnershipLease` placeholder. A "fix" that simply
/// cleared the payload on every conflict would satisfy the first two tests and
/// fail both anchors — which is the mirror image the real bug invites
/// (`MIS-005`), and the "could not determine ⇒ act anyway" collapse
/// (`MIS-IOS-004`) in its other direction.
///
/// Drives the REAL `NSEStagingDB` writers (compiled into this target — see the
/// `TabMailTests` sources list in `project.yml`) and the REAL
/// `NSEDataBridge.mergeNSEStagingData` via its `stagingPathOverride` seam. A
/// hand-mirrored staging row could not red-prove any of this: the fix lives
/// inside `stageHeader`, upstream of the row.
@Suite("NSE staging identity splicing (IOS-NSE-005)", .serialized, .processGlobalState)
@MainActor
struct NSEStagingIdentitySplicingTests {

    /// Every artifact the PREDECESSOR message produced carries this string, so a
    /// splice is detectable by sweeping durable state rather than by inspecting
    /// the columns the fix happens to clear.
    private static let predecessorToken = "PREDECESSORONLYTOKEN"

    private static let accountId = "acc1"
    /// The recycled address: one UID, two different messages across a turnover.
    private static let recycledUid = "42"
    private static let predecessorRfc = "rfc-predecessor@example.com"
    private static let successorRfc = "rfc-successor@example.com"
    private static let epochBefore = 100
    private static let epochAfter = 200

    // MARK: - Harness

    private func makeAppDatabase() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "user@example.com", displayName: "Test", provider: .imap)
            account.id = Self.accountId
            try account.insert(db)
            // `lastKnownUidValidity` deliberately nil — the durable half of
            // `IOS-NSE-005` needs the nil-folder-epoch population, which is where
            // ARM 1 (`uidValidityStagingRowStatus.isOldEpoch`) is inert because
            // it requires BOTH epochs present.
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId)
                .insert(db)
        }
        return (dir, pool, previous)
    }

    /// A real staging file at a temp path — the unit-test host has no App Group
    /// entitlement, so `NSEStagingDB.open()` (and with it the production
    /// `ensureObservedUidValidityColumn` call) is unreachable. The ALTER below
    /// mirrors that function for the same reason
    /// `NSEStaleStagedRowInvalidationTests` does: `AppDatabase
    /// .createNSEStagingDB` deliberately does NOT own that column.
    private func makeStagingFile(in dir: URL) throws -> (path: String, queue: DatabaseQueue) {
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            let columns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
                    .map { $0["name"] as String })
            guard !columns.contains("observedUidValidity") else { return }
            try db.execute(
                sql: "ALTER TABLE nse_processed_message ADD COLUMN observedUidValidity INTEGER")
        }
        return (path, queue)
    }

    private func metadata(
        rfc822: String?, epoch: Int?, subject: String, snippet: String
    ) -> NSEMessageMetadata {
        NSEMessageMetadata(
            messageId: Self.recycledUid, threadId: nil, rfc822MessageId: rfc822,
            senderName: "Sender", senderEmail: "sender@example.com",
            to: "user@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil, references: [],
            subject: subject, snippet: snippet,
            dateString: "", date: Date(timeIntervalSince1970: 1_710_000_000),
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, providerLabels: [],
            folderPath: "INBOX", observedUidValidity: epoch)
    }

    private func body(_ text: String) -> RenderedBody {
        RenderedBody(
            htmlContent: "<p>\(text)</p>", textContent: text, attachments: [],
            icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false)
    }

    /// NSE run 1 reaching its terminal write for the PREDECESSOR message: body,
    /// summary, todos, reminder, action tag and `aiCompleted = 1`, all tokened.
    private func stagePredecessorTerminal(
        _ queue: DatabaseQueue, rfc822: String?, epoch: Int?
    ) {
        let token = Self.predecessorToken
        NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: metadata(
                rfc822: rfc822, epoch: epoch,
                subject: "\(token) subject", snippet: "\(token) snippet"),
            renderedBody: body("\(token) body"),
            summaryBlurb: "\(token) summary", summaryTodos: "\(token) todo",
            actionTag: "reply",
            reminderDate: nil, reminderTime: nil, reminderContent: "\(token) reminder",
            historyId: nil, aiCompleted: true, notified: true)
    }

    /// NSE run 2's stage-1 write for whatever message now occupies the UID.
    private func stageHeaderRun(_ queue: DatabaseQueue, rfc822: String?, epoch: Int?) {
        NSEStagingDB.stageHeader(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: metadata(
                rfc822: rfc822, epoch: epoch,
                subject: "Successor subject", snippet: "successor snippet"),
            historyId: nil)
    }

    private func countMatching(_ queue: DatabaseQueue, sql: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: ["%\(Self.predecessorToken)%"]) ?? -1
        }
    }

    // MARK: - The defect

    @Test("""
        A UID recycled onto a different message never lands the predecessor's body, \
        summary, todos, reminder, snippet or action tag under the successor's header — \
        and never queues the predecessor's tag as a wire op against it
        """)
    func durableMergeCarriesNothingOfThePredecessor() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        let (path, queue) = try makeStagingFile(in: dir)
        ownedQueues.append(queue)

        // ① NSE run 1 completes for the PREDECESSOR at INBOX UID 42, epoch 100.
        stagePredecessorTerminal(queue, rfc822: Self.predecessorRfc, epoch: Self.epochBefore)
        // ② The app stays backgrounded — no merge consumes the row.
        // ③ UIDVALIDITY turns over and reissues UID 42 to a DIFFERENT message.
        // ④ NSE run 2 stages the SUCCESSOR's header at the same staging key.
        stageHeaderRun(queue, rfc822: Self.successorRfc, epoch: Self.epochAfter)

        // ⑥ Next foreground: the merge.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let token = "%\(Self.predecessorToken)%"

        // The successor WAS surfaced, and it is genuinely the successor.
        let headers = try await pool.read { try MessageHeader.fetchAll($0) }
        #expect(headers.count == 1, "expected exactly the successor's header, got \(headers.count)")
        guard headers.count == 1 else { return }
        #expect(
            MessageIdentity.comparableRfc822Identity(headers[0].rfc822MessageId)
                == MessageIdentity.comparableRfc822Identity(Self.successorRfc),
            "the merged header is not the successor's")

        // …carrying NOTHING the predecessor produced.
        let headerHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE COALESCE(summaryBlurb, '') LIKE :t
                   OR COALESCE(summaryTodos, '') LIKE :t
                   OR COALESCE(reminderContent, '') LIKE :t
                   OR COALESCE(snippet, '') LIKE :t
                   OR COALESCE(subject, '') LIKE :t
                """, arguments: ["t": token]) ?? -1
        }
        #expect(headerHits == 0, "the successor's header carries the predecessor's content")
        #expect(headers[0].actionTag == nil, "the successor adopted the predecessor's action tag")

        // The predecessor's body is not readable as the successor's, and the
        // successor stays re-fetchable (the body queue selects bodyComplete = 0,
        // so a wrongly-completed row is never repaired).
        let bodyHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageBody WHERE COALESCE(htmlContent, '') LIKE ?
                """, arguments: [token]) ?? -1
        }
        #expect(bodyHits == 0, "the predecessor's body is stored under the successor's key")
        #expect(
            headers[0].bodyComplete == false,
            "the successor was marked body-complete on the predecessor's body — never re-fetched")

        // The AI cache is keyed on the SUCCESSOR's RFC id, so a poisoned entry
        // survives every later UID re-key and is a permanent HIT.
        let cacheHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageAICache
                WHERE COALESCE(summaryBlurb, '') LIKE :t
                   OR COALESCE(summaryTodos, '') LIKE :t
                   OR COALESCE(reminderContent, '') LIKE :t
                """, arguments: ["t": token]) ?? -1
        }
        #expect(cacheHits == 0, "the AI cache is poisoned under the successor's RFC key")

        // C3: nothing may reach the WIRE against a message it was not computed for.
        let tagOps = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pendingOperation WHERE type = 'setTag'") ?? -1
        }
        #expect(tagOps == 0, "an IMAP keyword write was queued for the predecessor's tag")
    }

    @Test("""
        A UID recycled onto a different message never serves the predecessor's AI \
        as the successor's notification
        """)
    func stagingCacheProbeServesNothingOfThePredecessor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer {
            TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir)
        }

        stagePredecessorTerminal(queue, rfc822: Self.predecessorRfc, epoch: Self.epochBefore)
        stageHeaderRun(queue, rfc822: Self.successorRfc, epoch: Self.epochAfter)

        // This is the half that needs NO nil epoch and is reachable on ANY IMAP
        // account: `NotificationService` probes the staging cache before running
        // AI, and a hit fills the notification and returns.
        let cached = NSEStagingDB.getCachedResult(
            db: queue, accountId: Self.accountId, messageId: Self.recycledUid)
        #expect(
            cached == nil,
            """
            the staging cache served the predecessor's AI as the successor's \
            notification: summary=\(String(describing: cached?.summaryBlurb)) \
            tag=\(String(describing: cached?.actionTag))
            """)
    }

    // MARK: - Anchors (the opposite direction — retention is CORRECT here)

    @Test("""
        ANCHOR — a re-push of the SAME message keeps the body and AI the previous \
        run already paid for
        """)
    func rePushOfTheSameMessageRetainsPreviousWork() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer {
            TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir)
        }

        stagePredecessorTerminal(queue, rfc822: Self.predecessorRfc, epoch: Self.epochBefore)
        // Same message, same epoch — a duplicate push, which is exactly what the
        // UPSERT's retention was written for.
        stageHeaderRun(queue, rfc822: Self.predecessorRfc, epoch: Self.epochBefore)

        let cached = NSEStagingDB.getCachedResult(
            db: queue, accountId: Self.accountId, messageId: Self.recycledUid)
        #expect(
            cached?.summaryBlurb == "\(Self.predecessorToken) summary",
            "a duplicate push discarded the AI the previous run paid for")
        let bodyRows = try countMatching(
            queue,
            sql: "SELECT COUNT(*) FROM nse_processed_message WHERE COALESCE(htmlContent, '') LIKE ?")
        #expect(bodyRows == 1, "a duplicate push discarded the body the previous run rendered")
    }

    @Test("""
        ANCHOR — an identity the row cannot adjudicate RETAINS: an rfc-less, \
        epoch-less re-stage keeps its payload, and an AIOwnershipLease placeholder \
        keeps its claim
        """)
    func unanswerableIdentityRetainsRatherThanClears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer {
            TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir)
        }

        // (1) An rfc-less IMAP message accumulating payload across wakes. Neither
        // door can adjudicate, so absence of evidence must NOT clear.
        stagePredecessorTerminal(queue, rfc822: nil, epoch: nil)
        stageHeaderRun(queue, rfc822: nil, epoch: nil)
        let cached = NSEStagingDB.getCachedResult(
            db: queue, accountId: Self.accountId, messageId: Self.recycledUid)
        #expect(
            cached?.summaryBlurb == "\(Self.predecessorToken) summary",
            "an unanswerable identity was treated as proof of a different message")

        // (2) The `AIOwnershipLease` placeholder — `populated = 0`, both identity
        // columns NULL — must survive the stage-1 write that fills it in, or the
        // NSE and the main app both run the same message's AI.
        let leasedMessageId = "lease-target"
        #expect(
            AIOwnershipLease.tryClaim(
                db: queue, accountId: Self.accountId, messageId: leasedMessageId, owner: .nse),
            "precondition: the lease claim must succeed")
        NSEStagingDB.stageHeader(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: NSEMessageMetadata(
                messageId: leasedMessageId, threadId: nil, rfc822MessageId: Self.successorRfc,
                senderName: "Sender", senderEmail: "sender@example.com",
                to: "user@example.com", cc: "", bcc: "", replyTo: nil,
                inReplyTo: nil, references: [],
                subject: "Leased subject", snippet: "leased snippet",
                dateString: "", date: Date(timeIntervalSince1970: 1_710_000_000),
                isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, providerLabels: [],
                folderPath: "INBOX", observedUidValidity: Self.epochAfter),
            historyId: nil)
        let owner = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT aiOwner FROM nse_processed_message WHERE id = ?",
                arguments: ["\(Self.accountId):\(leasedMessageId)"])
        }
        #expect(
            owner == AIOwnershipLease.Owner.nse.rawValue,
            "stageHeader dropped a live AI-ownership lease it had no evidence against")
    }
}
