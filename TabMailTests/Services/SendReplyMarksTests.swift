/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A reply or forward marks the ORIGINAL only when the send goes out.
///
/// Queuing a send (`AccountManager.persistQueuedSend`) leaves the original as it
/// was. The send's completion (`AccountManager.deleteCompletedSendAtomic`) sets
/// `isReplied` (or `isForwarded` for a forward), clears a `reply` action tag on a
/// reply, and queues the matching server op. A send that never goes out, undone
/// inside its hold or discarded from the Outbox after it failed
/// (`AccountManager.cancelHeldOutboxRow`), therefore leaves nothing to revert. No
/// provider's sync clears `isReplied`/`isForwarded` or brings back a local action
/// tag, so a mark written before the send could outlive an undone send for good.
///
/// Each test drives the real queue, cancel and completion paths against the
/// stateful Gmail, IMAP and Outlook fakes, then runs the provider's passes: a
/// change pass, a foreground pass with the full sync due, and a change pass after
/// another client changed the original (so the change reader reads it again). The
/// original's marks are checked after every step, and a send that never goes
/// out must leave the original's row byte-identical and queue no operation.
///
/// `.serialized, .processGlobalState`: the worlds replace `AppDatabase.shared`.
@Suite("Reply and forward marks are written when the send goes out, never at queue time", .serialized, .processGlobalState)
struct SendReplyMarksTests {

    static let imapEpoch = 71_400
    static let imapPath = "INBOX"
    static let imapCapabilities = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
    static let draftEpoch = "E1"

    /// What happens to the queued send.
    enum Outcome: String, CaseIterable, Sendable {
        /// The toast's Undo, inside the hold.
        case undone
        /// The send failed and the user discarded it from the Outbox.
        case discardedAfterFailure
        /// The send went out and was appended to Sent.
        case completed
    }

    /// The original's marks the user sees.
    struct Marks: Equatable, CustomStringConvertible {
        var isReplied: Bool
        var isForwarded: Bool
        var actionTag: ActionTag?

        var description: String {
            "isReplied=\(isReplied) isForwarded=\(isForwarded) actionTag=\(actionTag?.rawValue ?? "nil")"
        }
    }

    enum OtherChange { case read, flagged }

    enum FixtureError: Error { case outboxRowMissing }

    static func marks(_ pool: DatabasePool, headerId: String) throws -> Marks {
        let stored = try pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        let header = try #require(stored)
        return Marks(isReplied: header.isReplied, isForwarded: header.isForwarded, actionTag: header.actionTag)
    }

    /// Whether the other client's change reached the row: proves the last pass
    /// really re-read the original.
    static func otherChangeLanded(_ pool: DatabasePool, headerId: String, _ other: OtherChange) throws -> Bool {
        let stored = try pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        let header = try #require(stored)
        return other == .read ? header.isRead : header.isFlagged
    }

    /// The original as the AI leaves it: tagged `reply`, an hour ago.
    static func tagReply(_ pool: DatabasePool, headerId: String) async throws {
        let setAt = Date().addingTimeInterval(-3_600)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, actionTagSetAt = ? WHERE id = ?",
                arguments: [ActionTag.reply.rawValue, ActionTag.reply.sortOrder, setAt, headerId])
        }
    }

    /// Every column of the original's row, to show a step wrote nothing to it.
    static func rowSnapshot(_ pool: DatabasePool, headerId: String) throws -> [String: DatabaseValue] {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM messageHeader WHERE id = ?", arguments: [headerId])
            else { return [:] }
            var columns: [String: DatabaseValue] = [:]
            for (column, value) in row { columns[column] = value }
            return columns
        }
    }

    static func operationCount(_ pool: DatabasePool) throws -> Int {
        try pool.read { db in try PendingOperation.fetchCount(db) }
    }

    /// A queued send, and the original as it was right before the queue.
    struct Queued {
        let outboxId: String
        let originalRow: [String: DatabaseValue]
        let operations: Int
    }

    /// Queue a reply (or forward) to `original` from a live draft, as Send does.
    /// Nothing has drained when it returns. Queuing must write nothing to the
    /// original and queue no operation.
    static func queue(
        pool: DatabasePool, accountId: String, original: MessageHeader, isForward: Bool
    ) async throws -> Queued {
        let draftId = "\(isForward ? "forward" : "reply"):\(accountId):\(original.stableId)"
        let originalId = original.id
        let sendSubject = "\(isForward ? "Fwd" : "Re"): \(original.subject)"
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: sendSubject, body: "Answer", replyToId: originalId,
                isForward: isForward, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = Self.draftEpoch
            try draft.insert(db)
        }
        let rowBefore = try Self.rowSnapshot(pool, headerId: originalId)
        #expect(!rowBefore.isEmpty, "precondition: the original is stored")
        let operationsBefore = try Self.operationCount(pool)

        // The thread headers exactly as Send derives them (ComposeView): a reply
        // names the original in In-Reply-To, a forward only as its last
        // References id (#1483).
        #expect(original.rfc822MessageId != nil, "precondition: the original has a Message-ID")
        let stored = try await pool.read { db in try Account.fetchOne(db, key: accountId) }
        let account = try #require(stored, "precondition: the account is stored")
        let thread = ThreadUtils.outgoingThreadHeaders(
            replyTo: original, isForward: isForward, sendAccountId: accountId,
            sendSubject: sendSubject, providerKind: account.provider)
        let message = DraftMessage(
            to: ["sender@example.com"], subject: sendSubject, body: "Answer",
            inReplyTo: thread.inReplyTo, references: thread.references, threadId: thread.threadId)
        let queued = try await AccountManager.persistQueuedSend(
            draft: message, accountId: accountId, replyToHeaderId: originalId,
            isForward: isForward, serverDraftId: nil,
            draftId: draftId, instanceEpoch: Self.draftEpoch)
        let outboxId = queued.outboxId
        let row = try await pool.read { db in try OutboxMessage.fetchOne(db, key: outboxId) }
        let linked = row?.originalMessageHeaderId
        #expect(linked == originalId, "precondition: the queued send names its original")

        let rowAfter = try Self.rowSnapshot(pool, headerId: originalId)
        #expect(rowAfter == rowBefore, "queuing must write nothing to the original")
        let operationsAfter = try Self.operationCount(pool)
        #expect(operationsAfter == operationsBefore, "queuing must queue no operation")
        return Queued(outboxId: outboxId, originalRow: rowBefore, operations: operationsBefore)
    }

    /// The send goes out and is appended to Sent; the completion step runs, as the
    /// drain and the foreground reconcile run it.
    @discardableResult
    static func complete(pool: DatabasePool, outboxId: String) async throws -> CompletedSendCleanupDisposition {
        try await pool.write { db -> CompletedSendCleanupDisposition in
            guard var sent = try OutboxMessage.fetchOne(db, key: outboxId) else {
                throw FixtureError.outboxRowMissing
            }
            sent.status = OutboxStatus.sending.rawValue
            sent.sentAt = Date()
            sent.appendedToSent = true
            try sent.update(db)
            return try AccountManager.deleteCompletedSendAtomic(outboxId: outboxId, db: db)
        }
    }

    /// The action drain is not part of these worlds. A completed reply to a
    /// Reply-tagged original leaves its queued `.setTag(none)`, which shields the
    /// row's read and flag state from the server until it drains
    /// (`PendingOperationSnapshot.flag`), so the other client's change below could
    /// not land. Before that change, retire the completion's queued ops as their
    /// successful drain does. The passes before it run with the shield in place.
    static func retireCompletionOps(_ pool: DatabasePool) async throws {
        let types = [OperationType.markReplied, .markForwarded, .setTag].map(\.rawValue)
        let retired = try await pool.write { db in
            try PendingOperation.filter(types.contains(Column("type"))).deleteAll(db)
        }
        #expect(retired >= 1, "precondition: the completion queued its server ops")
    }

    /// An IMAP account whose INBOX epoch is known, with no server behind it: for
    /// the steps that need no sync.
    static func localIMAPAccount(_ pool: DatabasePool, prefix: String) throws -> String {
        let accountId = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.imapPath, role: .inbox, pool: pool,
            lastKnownUidValidity: Self.imapEpoch)
        return accountId
    }

    /// A stored original in the INBOX. It is addressable on the server only when
    /// `observed` is the folder's epoch.
    static func storedOriginal(
        _ pool: DatabasePool, accountId: String, rfc: String,
        observed: Int? = SendReplyMarksTests.imapEpoch, tag: ActionTag? = nil
    ) throws -> MessageHeader {
        var parent = MessageHeader(
            messageId: "57", subject: "Original", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
            snippet: "original",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.imapPath),
            accountId: accountId, folderPath: Self.imapPath, isInInbox: true)
        parent.rfc822MessageId = rfc
        parent.headerComplete = true
        parent.observedUidValidity = observed
        if let tag { parent.setActionTag(tag, at: Date().addingTimeInterval(-3_600)) }
        let row = parent
        try pool.write { db in try row.insert(db) }
        return row
    }

    /// The marks the original must show once `outcome` has happened.
    static func expected(before: Marks, isForward: Bool, outcome: Outcome) -> Marks {
        guard outcome == .completed else { return before }
        var after = before
        if isForward {
            after.isForwarded = true
        } else {
            after.isReplied = true
            if before.actionTag == .reply { after.actionTag = ActionTag.none }
        }
        return after
    }

    /// Queue a reply (or forward) to `original` from a live draft, as Send does,
    /// then let `outcome` happen to it. A send that never goes out leaves the
    /// original byte-identical and queues no operation; a completed one sets the
    /// marks and queues the server's mark.
    static func queueThen(
        _ outcome: Outcome, pool: DatabasePool, accountId: String, original: MessageHeader,
        isForward: Bool, before: Marks
    ) async throws {
        let originalId = original.id
        let queued = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: isForward)
        let outboxId = queued.outboxId

        switch outcome {
        case .undone, .discardedAfterFailure:
            if outcome == .discardedAfterFailure {
                try await pool.write { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                        arguments: [OutboxStatus.failed.rawValue, outboxId])
                }
            }
            let cancelled = try await pool.write { db in
                try AccountManager.cancelHeldOutboxRow(db: db, messageId: outboxId)
            }
            #expect(cancelled.deleted, "precondition: the send was cancelled")
            let rowAfter = try Self.rowSnapshot(pool, headerId: originalId)
            #expect(rowAfter == queued.originalRow, "\(outcome.rawValue): the original must stay byte-identical")
            let operationsAfter = try Self.operationCount(pool)
            #expect(operationsAfter == queued.operations, "\(outcome.rawValue): no operation may be queued")
        case .completed:
            try await Self.complete(pool: pool, outboxId: outboxId)
            let opType = isForward ? OperationType.markForwarded : OperationType.markReplied
            let serverOps = try await pool.read { db in
                try PendingOperation.filter(Column("type") == opType.rawValue).fetchCount(db)
            }
            #expect(serverOps == 1, "the completed send must queue the server's \(opType.rawValue)")
        }
        let afterOutcome = try Self.marks(pool, headerId: originalId)
        let want = Self.expected(before: before, isForward: isForward, outcome: outcome)
        #expect(afterOutcome == want, "\(outcome.rawValue): \(afterOutcome), want \(want)")
    }

    // MARK: - Gmail

    @Test("Gmail: the original's marks change only when the send goes out, and the passes keep them",
          arguments: [false, true], Outcome.allCases)
    func gmail(isForward: Bool, outcome: Outcome) async throws {
        let seed = GmailDeltaApplyInvariantTests.seed("marks-1", labels: ["INBOX", "UNREAD"])
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: [seed]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let stored = try w.row("marks-1", in: w.inbox)
            let original = try #require(stored, "precondition: the full pass stored the original")
            try await Self.tagReply(w.pool, headerId: original.id)
            let before = try Self.marks(w.pool, headerId: original.id)

            try await Self.queueThen(
                outcome, pool: w.pool, accountId: w.accountId, original: original,
                isForward: isForward, before: before)
            let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

            try await w.delta()
            let afterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(afterDelta == want, "after a change pass: \(afterDelta)")
            try await w.foregroundPassWithFullSyncDue()
            let afterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(afterFull == want, "after a full pass: \(afterFull)")
            if outcome == .completed { try await Self.retireCompletionOps(w.pool) }
            w.server.applyLabelChange(providerMessageId: "marks-1", remove: ["UNREAD"])
            try await w.delta()
            let afterReread = try Self.marks(w.pool, headerId: original.id)
            #expect(afterReread == want, "after a re-read: \(afterReread)")
            let landed = try Self.otherChangeLanded(w.pool, headerId: original.id, .read)
            #expect(landed, "precondition: the last pass re-read the original")
        }
    }

    // MARK: - Outlook

    @Test("Outlook: the original's marks change only when the send goes out, and the passes keep them",
          arguments: [false, true], Outcome.allCases)
    func outlook(isForward: Bool, outcome: Outcome) async throws {
        let seed = OutlookChangeReadingTests.seed("marks-1", in: OutlookChangeReadingTests.inbox)
        try await OutlookChangeReadingTests.withWorld(seeds: [seed]) { w in
            try w.insertRow("marks-1", in: w.inbox)
            try await w.baselineAll()
            let stored = try w.row("marks-1", in: w.inbox)
            let original = try #require(stored, "precondition: the original is held")
            try await Self.tagReply(w.pool, headerId: original.id)
            let before = try Self.marks(w.pool, headerId: original.id)

            try await Self.queueThen(
                outcome, pool: w.pool, accountId: w.accountId, original: original,
                isForward: isForward, before: before)
            let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

            try await w.delta()
            let afterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(afterDelta == want, "after a change pass: \(afterDelta)")
            try await w.foregroundPass()
            let afterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(afterFull == want, "after a full pass: \(afterFull)")
            if outcome == .completed { try await Self.retireCompletionOps(w.pool) }
            w.server.setFlagFromOtherClient(providerMessageId: "marks-1", isFlagged: true)
            try await w.delta()
            let afterReread = try Self.marks(w.pool, headerId: original.id)
            #expect(afterReread == want, "after a re-read: \(afterReread)")
            let landed = try Self.otherChangeLanded(w.pool, headerId: original.id, .flagged)
            #expect(landed, "precondition: the last pass re-read the original")
        }
    }

    // MARK: - IMAP

    @Test("IMAP: the original's marks change only when the send goes out, and the passes keep them",
          arguments: [false, true], Outcome.allCases)
    func imap(isForward: Bool, outcome: Outcome) async throws {
        let server = FakeIMAPServer(
            capabilities: Self.imapCapabilities,
            mailboxes: [Self.imapPath: [IMAPChangeReaderTests.message(1)]])
        server.setUidValidity(Self.imapEpoch, for: Self.imapPath)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "marks-imap-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.imapPath, role: .inbox, pool: pool,
            lastKnownUidValidity: Self.imapEpoch)

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        func account() throws -> Account {
            let stored = try pool.read { db in try Account.fetchOne(db, key: accountId) }
            return try #require(stored)
        }
        func fullPass() async throws {
            try await pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db,
                    Column("lastFullSyncAt").set(to: nil as Date?))
            }
            _ = try await engine.sync(account: try account())
        }

        try await fullPass()
        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let folderId = "\(accountId):\(Self.imapPath)"
        let stored = try await pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "1").fetchOne(db)
        }
        let original = try #require(stored, "precondition: the full pass stored the original")
        try await Self.tagReply(pool, headerId: original.id)
        let before = try Self.marks(pool, headerId: original.id)

        try await Self.queueThen(
            outcome, pool: pool, accountId: accountId, original: original,
            isForward: isForward, before: before)
        let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let afterDelta = try Self.marks(pool, headerId: original.id)
        #expect(afterDelta == want, "after a change pass: \(afterDelta)")
        try await fullPass()
        let afterFull = try Self.marks(pool, headerId: original.id)
        #expect(afterFull == want, "after a full pass: \(afterFull)")
        if outcome == .completed { try await Self.retireCompletionOps(pool) }
        server.setFlags(["\\Flagged"], in: Self.imapPath, uid: 1)
        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let afterReread = try Self.marks(pool, headerId: original.id)
        #expect(afterReread == want, "after a re-read: \(afterReread)")
        let landed = try Self.otherChangeLanded(pool, headerId: original.id, .flagged)
        #expect(landed, "precondition: the last pass re-read the original")

        #expect(server.wrongMessageViolations().isEmpty)
        await engine.remove(accountId: accountId)
    }

    // MARK: - Queuing alone

    @Test("Queuing a reply or forward writes nothing to the original and queues no operation",
          arguments: [false, true])
    func queueingWritesNothingToTheOriginal(isForward: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localIMAPAccount(pool, prefix: "marks-queue")
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "queue-parent@example.com", tag: .reply)

        // `queue` checks that the original's row is unchanged and no operation was queued.
        _ = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: isForward)
    }

    // MARK: - The open email screen

    /// What the completion does to the original.
    enum CompletionChange: String, CaseIterable, Sendable {
        case reply
        case replyAll
        case forward
        /// A reply whose original the server cannot be asked to mark (its epoch is
        /// unknown): no mark, but its Reply tag is cleared.
        case tagOnlyClear
        /// The same reply to an original with no Reply tag: nothing changes.
        case nothingChanged
    }

    /// The email screen re-reads its message only on a `.messageDataDidChange`
    /// naming it (`MessageDetailViewModel`). The replied/forwarded mark is written
    /// only when the send completes, so the completion must post it whenever it
    /// changed the original: a mark (reply, reply-all, forward), or only the
    /// cleared Reply tag. When it changed nothing it must not post.
    @Test("Completing a send refreshes the original's open screen exactly when it changed the original",
          arguments: CompletionChange.allCases)
    func completionRefreshesTheOpenOriginal(_ change: CompletionChange) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localIMAPAccount(pool, prefix: "marks-post")
        let addressable = change == .reply || change == .replyAll || change == .forward
        let parentRfc = "post-parent@example.com"
        let parent = try Self.storedOriginal(
            pool, accountId: accountId, rfc: parentRfc,
            observed: addressable ? Self.imapEpoch : nil,
            tag: change == .tagOnlyClear ? .reply : nil)
        let isForward = change == .forward
        var sent = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(
                to: ["sender@example.com"], subject: isForward ? "Fwd: Original" : "Re: Original",
                body: "text",
                // A forward names its original only as its last References id (#1483).
                inReplyTo: isForward ? nil : "<\(parentRfc)>",
                references: isForward ? [parentRfc] : []),
            originalMessageHeaderId: parent.id,
            isForward: isForward)
        sent.isReplyAll = change == .replyAll
        // Sent and appended to Sent, not yet finished: the foreground reconcile
        // finishes it through the same completion step the drain uses.
        sent.status = OutboxStatus.sending.rawValue
        sent.sentAt = Date().addingTimeInterval(-60)
        sent.appendedToSent = true
        let sentRow = sent
        try await pool.write { db in try sentRow.insert(db) }

        let parentId = parent.id
        let posts = Mutex(0)
        let token = NotificationCenter.default.addObserver(
            forName: .messageDataDidChange, object: nil, queue: nil
        ) { note in
            if note.object as? String == parentId { posts.withLock { $0 += 1 } }
        }
        await AccountManager.shared.reconcileOutboxOnForeground()
        NotificationCenter.default.removeObserver(token)

        let remaining = try await pool.read { db in try OutboxMessage.fetchOne(db, key: sentRow.id) }
        #expect(remaining == nil, "precondition: the completion ran")
        let after = try Self.marks(pool, headerId: parentId)
        let want: Marks
        switch change {
        case .reply, .replyAll:
            want = Marks(isReplied: true, isForwarded: false, actionTag: nil)
        case .forward:
            want = Marks(isReplied: false, isForwarded: true, actionTag: nil)
        case .tagOnlyClear:
            want = Marks(isReplied: false, isForwarded: false, actionTag: ActionTag.none)
        case .nothingChanged:
            want = Marks(isReplied: false, isForwarded: false, actionTag: nil)
        }
        #expect(after == want, "precondition: \(change.rawValue) left \(after), want \(want)")
        let count = posts.withLock { $0 }
        if change == .nothingChanged {
            #expect(count == 0, "the completion changed nothing, so it must not refresh the screen")
        } else {
            #expect(count >= 1, "\(change.rawValue): the open email screen must be told its message changed")
        }
    }

    // MARK: - A Reply tag written while the send is held

    /// The AI tags an email Reply unless it is already replied. While a reply is
    /// held the original is not marked yet, so the AI's Reply lands; the completion
    /// reads the row as it is then and clears it.
    @Test("A Reply tag the AI writes while the reply is held is cleared when the send goes out")
    func aiReplyTagWrittenDuringTheHoldIsClearedByCompletion() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localIMAPAccount(pool, prefix: "marks-ai")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "ai-parent@example.com")
        let queued = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: false)

        // The AI's action write, through the guarded write, with the AI queue's rule:
        // Reply, or none when the email is already replied.
        let outcome = try await pool.write { db -> AIWriteOutcome in
            guard let target = try AIWriteTarget.capture(message: original, db: db) else { return .dropped }
            return try AccountManager.aiGuardedHeaderWrite(db, target: target) { msg, db in
                let resolved = msg.isReplied ? ActionTag.none : ActionTag.reply
                msg.actionTag = resolved
                msg.tagSortOrder = resolved.sortOrder
                try msg.save(db)
            }
        }
        #expect(outcome == .written, "precondition: the AI write landed")
        let held = try Self.marks(pool, headerId: original.id)
        #expect(held == Marks(isReplied: false, isForwarded: false, actionTag: .reply),
                "the original is not replied while the send is held, so the AI's Reply lands: \(held)")

        try await Self.complete(pool: pool, outboxId: queued.outboxId)
        let after = try Self.marks(pool, headerId: original.id)
        #expect(after == Marks(isReplied: true, isForwarded: false, actionTag: ActionTag.none),
                "the completion must clear the Reply tag written during the hold: \(after)")
    }

    // MARK: - The original moved before the send went out

    /// TODAY'S BEHAVIOUR, pinned so that a change to it is deliberate. Archiving
    /// the original while the reply is held gives it a new address (on IMAP a UID
    /// in Archive; the row is re-keyed when the move lands). The queued row still
    /// names the old address, so the completion finds no original: no mark, no
    /// server op, and the Reply tag stays. Once the Sent copy is synced,
    /// `ReplyParentResolver` finds the moved original by its Message-ID, marks it
    /// replied and clears its Reply tag. The server's `\Answered` is not set.
    @Test("A reply whose original is archived before the send goes out: the completion finds no original, and the Sent copy's sync marks it")
    func originalArchivedBeforeTheSendGoesOut() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localIMAPAccount(pool, prefix: "marks-moved")
        let archivePath = "Archive"
        let archiveEpoch = Self.imapEpoch + 1
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: archivePath, role: .archive, pool: pool,
            lastKnownUidValidity: archiveEpoch)
        let parentRfc = "moved-parent@example.com"
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: parentRfc, tag: .reply)
        let queued = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: false)

        // The archive gesture moves the row locally; it keeps its key until the move lands ...
        let archiveFolderId = MessageIdentity.folderId(accountId: accountId, folderPath: archivePath)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderPath = ?, folderId = ?, isInInbox = 0, observedUidValidity = NULL WHERE id = ?",
                arguments: [archivePath, archiveFolderId, original.id])
        }
        // ... and when it lands, the row takes the Archive copy's address the server named.
        let move = PendingOperation(
            type: .move, messageIds: [original.messageId], accountId: accountId,
            folderPath: Self.imapPath, destinationPath: archivePath, observedUidValidity: Self.imapEpoch)
        let finished = try await pool.write { db in
            try MessageHeaderRekey.finishMove(
                move, destinations: [ProvenDestinationAddress(
                    sourceProviderId: original.messageId, destinationProviderId: "9",
                    destinationUidValidity: UInt32(archiveEpoch))],
                addressChangesOnMove: true, accountScopedIds: false, db: db)
        }
        #expect(finished.applied.count == 1, "precondition: the move re-keyed the original")
        let movedId = MessageIdentity.headerId(accountId: accountId, folderPath: archivePath, messageId: "9")
        let moved = try Self.marks(pool, headerId: movedId)
        #expect(moved == Marks(isReplied: false, isForwarded: false, actionTag: .reply), "precondition: \(moved)")

        let disposition = try await Self.complete(pool: pool, outboxId: queued.outboxId)
        #expect(disposition.changedOriginalHeaderId == nil, "the queued row names the address the original left")
        let afterSend = try Self.marks(pool, headerId: movedId)
        #expect(afterSend == Marks(isReplied: false, isForwarded: false, actionTag: .reply),
                "the completion cannot find the moved original: \(afterSend)")
        let serverMarks = try await pool.read { db in
            try PendingOperation.filter(Column("type") == OperationType.markReplied.rawValue).fetchCount(db)
        }
        #expect(serverMarks == 0, "no server mark is queued for an original the completion cannot find")

        // The Sent copy's sync names the original by its Message-ID.
        let marked = try await pool.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [.init(inReplyTo: "<\(parentRfc)>", subject: "Re: Original")], folderRole: .sent,
                accountId: accountId, db: db)
        }
        #expect(marked == [movedId])
        let healed = try Self.marks(pool, headerId: movedId)
        #expect(healed == Marks(isReplied: true, isForwarded: false, actionTag: ActionTag.none),
                "the Sent copy's sync marks the moved original replied and clears its Reply tag: \(healed)")
    }
}
