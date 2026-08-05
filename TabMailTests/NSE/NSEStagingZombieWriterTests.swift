/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// `IOS-NSE-006` — the remainder `IOS-NSE-005` (`5813e44b1`) named and
/// deliberately left open. `stageHeader` now re-proves identity before REUSING
/// payload already on the row; these are the writers that ADD payload to it, and
/// they carried no identity term at all: `stageBody` and `stageSummary` were bare
/// `UPDATE … WHERE id = ?`, and `persistProcessedMessage` a bare
/// `INSERT OR REPLACE`.
///
/// The staging key is `"<accountId>:<messageId>"` and on IMAP `messageId` is the
/// UID — an ADDRESS, not an identity. A predecessor NSE run resuming from its
/// body fetch or its LLM await, after a UIDVALIDITY turnover reissued that UID
/// and a successor run re-headed the row, therefore wrote the predecessor's
/// content onto the successor.
///
/// **THE INVARIANT UNDER TEST, stated as a system property:** *content computed
/// for one message is never merged, indexed, cached or put on the wire under a
/// different message's identity, and a message's own staged row is never
/// destroyed by a run that no longer holds its address.*
///
/// Assertions sweep durable state for a token unique to the predecessor rather
/// than inspecting the columns the guard happens to suppress — a test asserting
/// "the refusal arm ran" would pin the MECHANISM and stay green on a re-broken
/// system (`MIS-015`).
///
/// **Two-sided by construction.** Two of the five tests are ANCHORS holding the
/// OPPOSITE direction. The fail direction here is the mirror of `stageHeader`'s:
/// there the question is *may I KEEP payload*, here it is *may I ADD payload*, so
/// an unanswerable identity must WRITE. A "fix" that suppressed the write unless
/// identity positively AGREED would satisfy the three defect tests and fail
/// `unanswerableIdentityWritesRatherThanRefuses` — that is the mirror image
/// (`MIS-005`) and `MIS-IOS-004`'s "could not determine ⇒ act anyway" collapse in
/// its other direction.
///
/// Drives the REAL `NSEStagingDB` writers (compiled into this target — see the
/// `TabMailTests` sources list in `project.yml`) and the REAL
/// `NSEDataBridge.mergeNSEStagingData` via its `stagingPathOverride` seam.
@Suite("NSE staging zombie writers (IOS-NSE-006)", .serialized, .processGlobalState)
@MainActor
struct NSEStagingZombieWriterTests {

    /// Every artifact the PREDECESSOR run produced carries this string.
    private static let predecessorToken = "ZOMBIEPREDECESSORTOKEN"

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
            // `lastKnownUidValidity` deliberately nil — the nil-folder-epoch
            // population, where the merge's own ARM 1 epoch check is inert.
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId)
                .insert(db)
        }
        return (dir, pool, previous)
    }

    /// A real staging file at a temp path. The unit-test host has no App Group
    /// entitlement, so `NSEStagingDB.open()` — and with it the production
    /// `ensureObservedUidValidityColumn` call — is unreachable; the ALTER below
    /// mirrors it, as `NSEStaleStagedRowInvalidationTests` does, because
    /// `AppDatabase.createNSEStagingDB` deliberately does NOT own that column.
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
        rfc822: String?, epoch: Int?, subject: String, snippet: String,
        messageId: String = NSEStagingZombieWriterTests.recycledUid
    ) -> NSEMessageMetadata {
        NSEMessageMetadata(
            messageId: messageId, threadId: nil, rfc822MessageId: rfc822,
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

    /// NSE run 2's stage-1 write: whatever message now occupies the UID.
    private func stageSuccessorHeader(
        _ queue: DatabaseQueue, rfc822: String? = successorRfc, epoch: Int? = epochAfter
    ) {
        NSEStagingDB.stageHeader(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: metadata(
                rfc822: rfc822, epoch: epoch,
                subject: "Successor subject", snippet: "successor snippet"),
            historyId: nil)
    }

    /// The PREDECESSOR run resuming from its body fetch, long after the address
    /// stopped being its own. It still holds its OWN `msg`.
    private func zombieStagesBody(
        _ queue: DatabaseQueue, rfc822: String? = predecessorRfc, epoch: Int? = epochBefore
    ) {
        NSEStagingDB.stageBody(
            db: queue, accountId: Self.accountId,
            message: metadata(
                rfc822: rfc822, epoch: epoch,
                subject: "\(Self.predecessorToken) subject",
                snippet: "\(Self.predecessorToken) snippet"),
            renderedBody: body("\(Self.predecessorToken) body"))
    }

    /// The PREDECESSOR run resuming from its summary LLM await.
    private func zombieStagesSummary(
        _ queue: DatabaseQueue, rfc822: String? = predecessorRfc, epoch: Int? = epochBefore
    ) {
        let token = Self.predecessorToken
        NSEStagingDB.stageSummary(
            db: queue, accountId: Self.accountId,
            message: metadata(
                rfc822: rfc822, epoch: epoch,
                subject: "\(token) subject", snippet: "\(token) snippet"),
            summaryBlurb: "\(token) summary", summaryTodos: "\(token) todo",
            reminderDate: nil, reminderTime: nil, reminderContent: "\(token) reminder")
    }

    /// The staging row's key and the token pattern are hoisted into locals before
    /// every DB closure in this file: the suite is `@MainActor`, so referencing a
    /// main-actor-isolated static from inside GRDB's Sendable read closure is a
    /// concurrency error rather than a style question.
    private func stagedRowRfc(_ queue: DatabaseQueue) throws -> String? {
        let key = "\(Self.accountId):\(Self.recycledUid)"
        return try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT rfc822MessageId FROM nse_processed_message WHERE id = ?",
                arguments: [key])
        }
    }

    private func stagedTokenHits(_ queue: DatabaseQueue) throws -> Int {
        let pattern = "%\(Self.predecessorToken)%"
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM nse_processed_message
                WHERE COALESCE(htmlContent, '') LIKE :t
                   OR COALESCE(textContent, '') LIKE :t
                   OR COALESCE(summaryBlurb, '') LIKE :t
                   OR COALESCE(summaryTodos, '') LIKE :t
                   OR COALESCE(reminderContent, '') LIKE :t
                   OR COALESCE(subject, '') LIKE :t
                   OR COALESCE(snippet, '') LIKE :t
                """, arguments: ["t": pattern]) ?? -1
        }
    }

    // MARK: - The defect

    @Test("""
        A zombie run's body never becomes the body of the message that now holds \
        its address — and never marks that message body-complete
        """)
    func zombieBodyNeverLandsOnASuccessorsRow() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        let (path, queue) = try makeStagingFile(in: dir)
        ownedQueues.append(queue)

        // ① A turnover has reissued UID 42; NSE run 2 stages the SUCCESSOR.
        stageSuccessorHeader(queue)
        // ② NSE run 1 resumes from its body fetch and writes the PREDECESSOR's body.
        zombieStagesBody(queue)
        // ③ Next foreground: the merge.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let headers = try await pool.read { try MessageHeader.fetchAll($0) }
        #expect(headers.count == 1, "expected exactly the successor's header, got \(headers.count)")
        guard headers.count == 1 else { return }
        #expect(
            MessageIdentity.comparableRfc822Identity(headers[0].rfc822MessageId)
                == MessageIdentity.comparableRfc822Identity(Self.successorRfc),
            "the merged header is not the successor's")

        // `messageBody` stores ONLY the display html (`AppDatabase` v70 recreates it
        // with id/htmlContent/attachmentsJSON/fetchedAt/icsText — there is no
        // `textContent` column). The staged `textContent` goes to FTS and to the
        // header's snippet instead, so both of those are asserted separately below.
        let token = "%\(Self.predecessorToken)%"
        let bodyHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageBody
                WHERE COALESCE(htmlContent, '') LIKE :t OR COALESCE(icsText, '') LIKE :t
                """, arguments: ["t": token]) ?? -1
        }
        #expect(bodyHits == 0, "the predecessor's body is stored under the successor's key")
        // The snippet is the user-VISIBLE face of this misattribution: the merge
        // derives it from the staged `textContent`, so a landed zombie body rewrites
        // the successor's inbox row with the predecessor's first line.
        #expect(
            headers[0].snippet.contains(Self.predecessorToken) == false,
            "the successor's inbox snippet now shows the predecessor's body text")
        // The body queue selects `bodyComplete = 0`, so a wrongly-completed row is
        // never re-fetched — the state that makes this unrecoverable.
        #expect(
            headers[0].bodyComplete == false,
            "the successor was marked body-complete on the predecessor's body — never re-fetched")
    }

    @Test("""
        A zombie run's summary, todos and reminder never become the AI of the \
        message that now holds its address — not on its header, not in the \
        RFC-keyed AI cache, and not as a wire op
        """)
    func zombieSummaryNeverLandsOnASuccessorsRow() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        let (path, queue) = try makeStagingFile(in: dir)
        ownedQueues.append(queue)

        stageSuccessorHeader(queue)
        zombieStagesSummary(queue)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let token = "%\(Self.predecessorToken)%"
        let headerHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE COALESCE(summaryBlurb, '') LIKE :t
                   OR COALESCE(summaryTodos, '') LIKE :t
                   OR COALESCE(reminderContent, '') LIKE :t
                """, arguments: ["t": token]) ?? -1
        }
        #expect(headerHits == 0, "the successor's header carries the predecessor's AI")

        // Keyed on the SUCCESSOR's RFC id, so a poisoned entry survives every
        // later UID re-key and is a permanent HIT.
        let cacheHits = try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageAICache
                WHERE COALESCE(summaryBlurb, '') LIKE :t
                   OR COALESCE(summaryTodos, '') LIKE :t
                   OR COALESCE(reminderContent, '') LIKE :t
                """, arguments: ["t": token]) ?? -1
        }
        #expect(cacheHits == 0, "the AI cache is poisoned under the successor's RFC key")

        // C3: nothing computed for one message may reach the WIRE against another.
        let tagOps = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pendingOperation WHERE type = 'setTag'") ?? -1
        }
        #expect(tagOps == 0, "an IMAP keyword write was queued for the predecessor's tag")
    }

    @Test("""
        A zombie run's terminal write never replaces the staged row of the message \
        that now holds its address
        """)
    func zombieTerminalWriteNeverReplacesTheSuccessorsRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer { TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir) }

        stageSuccessorHeader(queue)
        // NSE run 1 resumes past its LLM await and reaches step 7. Its
        // `INSERT OR REPLACE` rewrites the WHOLE row, so unguarded it destroys
        // the successor's staged push outright.
        let token = Self.predecessorToken
        NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: metadata(
                rfc822: Self.predecessorRfc, epoch: Self.epochBefore,
                subject: "\(token) subject", snippet: "\(token) snippet"),
            renderedBody: body("\(token) body"),
            summaryBlurb: "\(token) summary", summaryTodos: "\(token) todo",
            actionTag: "reply",
            reminderDate: nil, reminderTime: nil, reminderContent: "\(token) reminder",
            historyId: nil, aiCompleted: true, notified: true)

        #expect(
            MessageIdentity.comparableRfc822Identity(try stagedRowRfc(queue))
                == MessageIdentity.comparableRfc822Identity(Self.successorRfc),
            "a zombie terminal write replaced the successor's staged row with its own")
        #expect(
            try stagedTokenHits(queue) == 0,
            "the staged row carries content the predecessor computed")
        // And the successor's own notification must not be served the zombie's AI.
        let cached = NSEStagingDB.getCachedResult(
            db: queue, accountId: Self.accountId, messageId: Self.recycledUid)
        #expect(
            cached == nil,
            """
            the staging cache serves the predecessor's AI as the successor's \
            notification: summary=\(String(describing: cached?.summaryBlurb))
            """)
    }

    // MARK: - Anchors (the opposite direction — the write MUST land)

    @Test("""
        ANCHOR — a legitimate late write by the run that still holds the address \
        lands: same message, same epoch, body and summary both stored
        """)
    func legitimateSameMessageLateWriteStillLands() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer { TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir) }

        // One message throughout — the ordinary NSE run: header, then body, then
        // summary, each a separate write against the same staged row.
        stageSuccessorHeader(queue, rfc822: Self.predecessorRfc, epoch: Self.epochBefore)
        zombieStagesBody(queue)
        zombieStagesSummary(queue)

        #expect(
            try stagedTokenHits(queue) == 1,
            "a same-message late write was refused — the ordinary staging path is broken")
    }

    @Test("""
        ANCHOR — an identity the row cannot adjudicate WRITES rather than refuses: \
        an rfc-less, epoch-less message still accumulates its body and summary
        """)
    func unanswerableIdentityWritesRatherThanRefuses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (_, queue) = try makeStagingFile(in: dir)
        defer { TestDatabaseTeardown.retire(pools: [], queues: [queue], directory: dir) }

        // Neither door can adjudicate: the header carries no RFC id (SwiftMail
        // could not parse it into `localPart@domain`) and the folder never earned
        // an epoch. Absence of evidence must NOT suppress the write, or such a
        // message could never accumulate payload across wakes.
        stageSuccessorHeader(queue, rfc822: nil, epoch: nil)
        zombieStagesBody(queue, rfc822: nil, epoch: nil)
        zombieStagesSummary(queue, rfc822: nil, epoch: nil)

        #expect(
            try stagedTokenHits(queue) == 1,
            "an unanswerable identity was treated as proof of a DIFFERENT message")

        // The same question on the terminal writer, whose refusal would drop the
        // whole run rather than one column group.
        let token = Self.predecessorToken
        NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: Self.accountId, accountEmail: "user@example.com",
            provider: "imap_new_mail",
            message: metadata(
                rfc822: nil, epoch: nil,
                subject: "\(token) subject", snippet: "\(token) snippet"),
            renderedBody: body("\(token) body"),
            summaryBlurb: "\(token) summary", summaryTodos: "\(token) todo",
            actionTag: "reply",
            reminderDate: nil, reminderTime: nil, reminderContent: "\(token) reminder",
            historyId: nil, aiCompleted: true, notified: true)
        let cached = NSEStagingDB.getCachedResult(
            db: queue, accountId: Self.accountId, messageId: Self.recycledUid)
        #expect(
            cached?.summaryBlurb == "\(token) summary",
            "an unanswerable identity suppressed a legitimate terminal write")
    }
}
