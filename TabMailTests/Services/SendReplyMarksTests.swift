/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A reply or forward marks the ORIGINAL at Send, and a send that never goes out
/// takes back exactly what it changed (#1490).
///
/// Queuing a send (`AccountManager.persistQueuedSend`) sets `isReplied` (or
/// `isForwarded` for a forward) on an original the server can be asked to mark,
/// and clears a reply's `reply` action tag, in the queuing write. The outbox row
/// records what it changed (`OutboxMessage.originalChangesAtQueue`). No server op
/// is queued then. The send's completion
/// (`AccountManager.deleteCompletedSendAtomic`) queues the server's mark, and the
/// tag clear while Send's clear still stands. A send that never goes out, undone
/// inside its hold, undone back to Drafts, or discarded from the Outbox after it
/// failed, runs `AccountManager.cancelHeldOutboxRow`, which takes back only that
/// row's own record: the mark goes back to unset, and the tag goes back to Reply
/// while it is still Send's none. No provider's sync clears
/// `isReplied`/`isForwarded`, so a mark nothing took back would outlive an undone
/// send for good (#1468). An original re-keyed by a move while the send is held
/// is found at its new address: the re-key carries the queued send's pointer
/// (#1479), and so does a listing's re-key on the provider's own id, which
/// re-keys a Gmail original after an archive (#1500).
///
/// The world tests drive the real queue, cancel and completion paths against the
/// stateful Gmail, IMAP and Outlook fakes, and run the provider's passes while
/// the send is held and after its outcome: a change pass, a foreground pass with
/// the full sync due, and, after the outcome, a change pass after another client
/// changed the original (so the change reader reads it again). The original's
/// marks are checked after every step.
///
/// `.serialized, .processGlobalState`: the worlds replace `AppDatabase.shared`,
/// and the Undo test uses `PendingSendService.shared`.
@Suite("Reply and forward marks are written at Send and taken back with an unsent send", .serialized, .processGlobalState)
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

    static func header(_ pool: DatabasePool, headerId: String) throws -> MessageHeader {
        let stored = try pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        return try #require(stored)
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

    /// The queued ops that mark or tag a message, in queue order.
    static func markOps(_ pool: DatabasePool) throws -> [PendingOperation] {
        let types = [OperationType.markReplied, .markForwarded, .setTag].map(\.rawValue)
        return try pool.read { db in
            try PendingOperation.filter(types.contains(Column("type")))
                .order(Column("queuePosition")).fetchAll(db)
        }
    }

    /// The `.setTag` values queued, in queue order.
    static func queuedTags(_ pool: DatabasePool) throws -> [String?] {
        try markOps(pool).filter { $0.type == .setTag }.map(\.tagValue)
    }

    static func queuedCount(_ pool: DatabasePool, _ type: OperationType) throws -> Int {
        try markOps(pool).filter { $0.type == type }.count
    }

    /// A queued send, and the original as it was right before the queue.
    struct Queued {
        let outboxId: String
        let originalRow: [String: DatabaseValue]
        let operations: Int
        /// The original whose row queuing changed, as `persistQueuedSend` reported it.
        let changedOriginalHeaderId: String?
        /// The queued row as stored.
        let row: OutboxMessage
    }

    /// Queue a reply (or forward) to `original` from a live draft, as Send does.
    /// Nothing has drained when it returns. Queuing never queues an operation:
    /// the server is told only when the send goes out.
    static func queue(
        pool: DatabasePool, accountId: String, original: MessageHeader, isForward: Bool,
        draftId explicitDraftId: String? = nil
    ) async throws -> Queued {
        let draftId = explicitDraftId ?? "\(isForward ? "forward" : "reply"):\(accountId):\(original.stableId)"
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

        let queued = try await AccountManager.persistQueuedSend(
            draft: try await Self.outgoing(pool: pool, accountId: accountId, original: original, isForward: isForward),
            accountId: accountId, replyToHeaderId: originalId,
            isForward: isForward, serverDraftId: nil,
            draftId: draftId, instanceEpoch: Self.draftEpoch)
        let outboxId = queued.outboxId
        let stored = try await pool.read { db in try OutboxMessage.fetchOne(db, key: outboxId) }
        let row = try #require(stored, "precondition: the send is queued")
        #expect(row.originalMessageHeaderId == originalId, "precondition: the queued send names its original")
        #expect(row.originalChangesAtQueue != nil, "a send queued now records what it changed, even nothing")

        let operationsAfter = try Self.operationCount(pool)
        #expect(operationsAfter == operationsBefore, "queuing must queue no operation")
        return Queued(
            outboxId: outboxId, originalRow: rowBefore, operations: operationsBefore,
            changedOriginalHeaderId: queued.changedOriginalHeaderId, row: row)
    }

    /// The message Send builds: the thread headers exactly as Send derives them
    /// (ComposeView). A reply names the original in In-Reply-To, a forward only
    /// as its last References id (#1483).
    static func outgoing(
        pool: DatabasePool, accountId: String, original: MessageHeader, isForward: Bool
    ) async throws -> DraftMessage {
        #expect(original.rfc822MessageId != nil, "precondition: the original has a Message-ID")
        let stored = try await pool.read { db in try Account.fetchOne(db, key: accountId) }
        let account = try #require(stored, "precondition: the account is stored")
        let sendSubject = "\(isForward ? "Fwd" : "Re"): \(original.subject)"
        let thread = ThreadUtils.outgoingThreadHeaders(
            replyTo: original, isForward: isForward, sendAccountId: accountId,
            sendSubject: sendSubject, providerKind: account.provider)
        return DraftMessage(
            to: ["sender@example.com"], subject: sendSubject, body: "Answer",
            inReplyTo: thread.inReplyTo, references: thread.references, threadId: thread.threadId)
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

    /// The unsent send is removed through the write every removal runs (Undo,
    /// Undo to Drafts and the Outbox discard all call it).
    @discardableResult
    static func cancel(
        pool: DatabasePool, outboxId: String, failedFirst: Bool = false
    ) async throws -> AccountManager.HeldOutboxCancellation {
        if failedFirst {
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
        return cancelled
    }

    /// The action drain is not part of these worlds. A queued `.setTag` (the
    /// completion's clear, or an Undo's restored Reply) shields the row's read
    /// and flag state from the server until it drains
    /// (`PendingOperationSnapshot.flag`), so the other client's change below could
    /// not land. Before that change, retire the queued mark and tag ops as their
    /// successful drain does. The passes before it run with the shield in place.
    static func retireMarkOps(_ pool: DatabasePool, expected: Int) async throws {
        let types = [OperationType.markReplied, .markForwarded, .setTag].map(\.rawValue)
        let retired = try await pool.write { db in
            try PendingOperation.filter(types.contains(Column("type"))).deleteAll(db)
        }
        #expect(retired == expected, "precondition: \(expected) mark or tag op(s) were queued, found \(retired)")
    }

    /// An IMAP account whose INBOX epoch is known, with no server behind it: for
    /// the steps that need no sync.
    static func localAccount(
        _ pool: DatabasePool, prefix: String, provider: AccountProvider = .imap
    ) throws -> String {
        let accountId = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: provider, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.imapPath, role: .inbox, pool: pool,
            lastKnownUidValidity: provider == .imap ? Self.imapEpoch : nil)
        return accountId
    }

    /// A stored original in the INBOX. On IMAP it is addressable on the server
    /// only when `observed` is the folder's epoch.
    static func storedOriginal(
        _ pool: DatabasePool, accountId: String, rfc: String, messageId: String = "57",
        observed: Int? = SendReplyMarksTests.imapEpoch, tag: ActionTag? = nil, isReplied: Bool = false
    ) throws -> MessageHeader {
        var parent = MessageHeader(
            messageId: messageId, subject: "Original", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
            snippet: "original",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.imapPath),
            accountId: accountId, folderPath: Self.imapPath, isInInbox: true)
        parent.rfc822MessageId = rfc
        parent.headerComplete = true
        parent.observedUidValidity = observed
        parent.isReplied = isReplied
        if let tag { parent.setActionTag(tag, at: Date().addingTimeInterval(-3_600)) }
        let row = parent
        try pool.write { db in try row.insert(db) }
        return row
    }

    /// The marks Send writes on an addressable original.
    static func held(before: Marks, isForward: Bool) -> Marks {
        var held = before
        if isForward {
            held.isForwarded = true
        } else {
            held.isReplied = true
            if before.actionTag == .reply { held.actionTag = ActionTag.none }
        }
        return held
    }

    /// The marks the original must show once `outcome` has happened.
    static func expected(before: Marks, isForward: Bool, outcome: Outcome) -> Marks {
        outcome == .completed ? held(before: before, isForward: isForward) : before
    }

    /// The mark and tag ops queued once `outcome` has happened to a send that
    /// marked an addressable original: the completion's server mark and, for a
    /// reply whose Reply tag Send cleared, its clear; an unsent removal's
    /// restored Reply.
    static func expectedMarkOps(before: Marks, isForward: Bool, outcome: Outcome) -> Int {
        let clearedTag = !isForward && before.actionTag == .reply
        switch outcome {
        case .completed: return 1 + (clearedTag ? 1 : 0)
        case .undone, .discardedAfterFailure: return clearedTag ? 1 : 0
        }
    }

    /// Queue a reply (or forward) to an addressable `original` from a live
    /// draft, as Send does, and check what Send wrote: the mark at once, the
    /// Reply tag cleared on a reply, the row's record of both, no operation.
    static func queueAndCheckHeld(
        pool: DatabasePool, accountId: String, original: MessageHeader, isForward: Bool, before: Marks
    ) async throws -> Queued {
        let originalId = original.id
        let queued = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: isForward)
        #expect(queued.changedOriginalHeaderId == originalId, "Send must report the original it marked")
        let heldNow = try Self.marks(pool, headerId: originalId)
        let want = Self.held(before: before, isForward: isForward)
        #expect(heldNow == want, "Send must mark the original at once: \(heldNow), want \(want)")
        var recorded: OutboxMessage.QueuedOriginalChanges = [.setMark]
        if !isForward, before.actionTag == .reply { recorded.insert(.clearedReplyTag) }
        let changes = queued.row.queuedOriginalChanges
        #expect(changes == recorded, "the row records exactly what Send changed: \(changes.rawValue), want \(recorded.rawValue)")
        if recorded.contains(.clearedReplyTag) {
            let stamped = try Self.header(pool, headerId: originalId).actionTagSetAt
            #expect(stamped == queued.row.createdAt, "Send's none carries the row's own stamp")
        }
        return queued
    }

    /// Let `outcome` happen to a queued send. An unsent removal takes back what
    /// Send changed and queues the restored Reply; a completed send keeps the
    /// marks and queues the server's mark.
    static func apply(
        _ outcome: Outcome, queued: Queued, pool: DatabasePool, original: MessageHeader,
        isForward: Bool, before: Marks
    ) async throws {
        let originalId = original.id
        let restoresTag = !isForward && before.actionTag == .reply
        switch outcome {
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(
                pool: pool, outboxId: queued.outboxId, failedFirst: outcome == .discardedAfterFailure)
            #expect(cancelled.revertedOriginalHeaderId == originalId,
                    "\(outcome.rawValue): the removal must report the original it restored")
            let tags = try Self.queuedTags(pool)
            let wantTags: [String?] = restoresTag ? [ActionTag.reply.rawValue] : []
            #expect(tags == wantTags, "\(outcome.rawValue): the restored Reply queues its setTag: \(tags)")
            let marks = try Self.queuedCount(pool, isForward ? .markForwarded : .markReplied)
            #expect(marks == 0, "\(outcome.rawValue): no server mark for a send that never went out")
        case .completed:
            try await Self.complete(pool: pool, outboxId: queued.outboxId)
            let opType = isForward ? OperationType.markForwarded : OperationType.markReplied
            let serverOps = try Self.queuedCount(pool, opType)
            #expect(serverOps == 1, "the completed send must queue the server's \(opType.rawValue)")
            let tags = try Self.queuedTags(pool)
            let wantTags: [String?] = restoresTag ? [ActionTag.none.rawValue] : []
            #expect(tags == wantTags, "the completion queues the setTag for Send's tag clear: \(tags)")
        }
        let afterOutcome = try Self.marks(pool, headerId: originalId)
        let want = Self.expected(before: before, isForward: isForward, outcome: outcome)
        #expect(afterOutcome == want, "\(outcome.rawValue): \(afterOutcome), want \(want)")
    }

    // MARK: - Gmail

    @Test("Gmail: Send marks the original, the passes keep it, and only a send that went out keeps it",
          arguments: [false, true], Outcome.allCases)
    func gmail(isForward: Bool, outcome: Outcome) async throws {
        let seed = GmailDeltaApplyInvariantTests.seed("marks-1", labels: ["INBOX", "UNREAD"])
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: [seed]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let stored = try w.row("marks-1", in: w.inbox)
            let original = try #require(stored, "precondition: the full pass stored the original")
            try await Self.tagReply(w.pool, headerId: original.id)
            let before = try Self.marks(w.pool, headerId: original.id)

            let queued = try await Self.queueAndCheckHeld(
                pool: w.pool, accountId: w.accountId, original: original, isForward: isForward, before: before)
            let held = Self.held(before: before, isForward: isForward)
            try await w.delta()
            let heldAfterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(heldAfterDelta == held, "a change pass during the hold: \(heldAfterDelta)")
            try await w.foregroundPassWithFullSyncDue()
            let heldAfterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(heldAfterFull == held, "a full pass during the hold: \(heldAfterFull)")

            try await Self.apply(
                outcome, queued: queued, pool: w.pool, original: original, isForward: isForward, before: before)
            let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

            try await w.delta()
            let afterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(afterDelta == want, "after a change pass: \(afterDelta)")
            try await w.foregroundPassWithFullSyncDue()
            let afterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(afterFull == want, "after a full pass: \(afterFull)")
            try await Self.retireMarkOps(
                w.pool, expected: Self.expectedMarkOps(before: before, isForward: isForward, outcome: outcome))
            w.server.applyLabelChange(providerMessageId: "marks-1", remove: ["UNREAD"])
            try await w.delta()
            let afterReread = try Self.marks(w.pool, headerId: original.id)
            #expect(afterReread == want, "after a re-read: \(afterReread)")
            let landed = try Self.otherChangeLanded(w.pool, headerId: original.id, .read)
            #expect(landed, "precondition: the last pass re-read the original")
        }
    }

    // MARK: - Outlook

    @Test("Outlook: Send marks the original, the passes keep it, and only a send that went out keeps it",
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

            let queued = try await Self.queueAndCheckHeld(
                pool: w.pool, accountId: w.accountId, original: original, isForward: isForward, before: before)
            let held = Self.held(before: before, isForward: isForward)
            try await w.delta()
            let heldAfterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(heldAfterDelta == held, "a change pass during the hold: \(heldAfterDelta)")
            try await w.foregroundPass()
            let heldAfterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(heldAfterFull == held, "a full pass during the hold: \(heldAfterFull)")

            try await Self.apply(
                outcome, queued: queued, pool: w.pool, original: original, isForward: isForward, before: before)
            let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

            try await w.delta()
            let afterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(afterDelta == want, "after a change pass: \(afterDelta)")
            try await w.foregroundPass()
            let afterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(afterFull == want, "after a full pass: \(afterFull)")
            try await Self.retireMarkOps(
                w.pool, expected: Self.expectedMarkOps(before: before, isForward: isForward, outcome: outcome))
            w.server.setFlagFromOtherClient(providerMessageId: "marks-1", isFlagged: true)
            try await w.delta()
            let afterReread = try Self.marks(w.pool, headerId: original.id)
            #expect(afterReread == want, "after a re-read: \(afterReread)")
            let landed = try Self.otherChangeLanded(w.pool, headerId: original.id, .flagged)
            #expect(landed, "precondition: the last pass re-read the original")
        }
    }

    // MARK: - IMAP

    @Test("IMAP: Send marks the original, the passes keep it, and only a send that went out keeps it",
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

        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)
        let held = Self.held(before: before, isForward: isForward)
        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let heldAfterDelta = try Self.marks(pool, headerId: original.id)
        #expect(heldAfterDelta == held, "a change pass during the hold: \(heldAfterDelta)")
        try await fullPass()
        let heldAfterFull = try Self.marks(pool, headerId: original.id)
        #expect(heldAfterFull == held, "a full pass during the hold: \(heldAfterFull)")

        try await Self.apply(
            outcome, queued: queued, pool: pool, original: original, isForward: isForward, before: before)
        let want = Self.expected(before: before, isForward: isForward, outcome: outcome)

        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let afterDelta = try Self.marks(pool, headerId: original.id)
        #expect(afterDelta == want, "after a change pass: \(afterDelta)")
        try await fullPass()
        let afterFull = try Self.marks(pool, headerId: original.id)
        #expect(afterFull == want, "after a full pass: \(afterFull)")
        try await Self.retireMarkOps(
            pool, expected: Self.expectedMarkOps(before: before, isForward: isForward, outcome: outcome))
        server.setFlags(["\\Flagged"], in: Self.imapPath, uid: 1)
        _ = try await engine.performDeltaSync(account: try account(), provider: provider)
        let afterReread = try Self.marks(pool, headerId: original.id)
        #expect(afterReread == want, "after a re-read: \(afterReread)")
        let landed = try Self.otherChangeLanded(pool, headerId: original.id, .flagged)
        #expect(landed, "precondition: the last pass re-read the original")

        #expect(server.wrongMessageViolations().isEmpty)
        await engine.remove(accountId: accountId)
    }

    // MARK: - What Send marks

    /// Send marks only an original the server can be asked to mark (the same
    /// admission the completion's server op needs), so the local mark never
    /// claims a flag the server will not get. A reply's Reply tag is local, so
    /// it is cleared either way, and the completion sends that clear.
    @Test("Send marks only an addressable original, clears a reply's Reply tag either way, and the completion sends what Send changed",
          arguments: [false, true], [false, true])
    func sendMarksOnlyAnAddressableOriginal(isForward: Bool, addressable: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-admit")
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "admit-parent@example.com",
            observed: addressable ? Self.imapEpoch : nil, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)

        let queued = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: isForward)
        var recorded: OutboxMessage.QueuedOriginalChanges = []
        var held = before
        if addressable { recorded.insert(.setMark) }
        if isForward {
            held.isForwarded = addressable
        } else {
            held.isReplied = addressable
            held.actionTag = ActionTag.none
            recorded.insert(.clearedReplyTag)
        }
        let heldNow = try Self.marks(pool, headerId: original.id)
        #expect(heldNow == held, "Send: \(heldNow), want \(held)")
        let changes = queued.row.queuedOriginalChanges
        #expect(changes == recorded, "recorded \(changes.rawValue), want \(recorded.rawValue)")
        let reported = queued.changedOriginalHeaderId
        if recorded.isEmpty {
            #expect(reported == nil, "Send changed nothing, so it reports no original")
            let rowAfter = try Self.rowSnapshot(pool, headerId: original.id)
            #expect(rowAfter == queued.originalRow, "Send changed nothing, so the original stays byte-identical")
        } else {
            #expect(reported == original.id, "Send must report the original it changed")
        }

        try await Self.complete(pool: pool, outboxId: queued.outboxId)
        let after = try Self.marks(pool, headerId: original.id)
        #expect(after == held, "the completion keeps what Send wrote: \(after), want \(held)")
        let serverMarks = try Self.queuedCount(pool, isForward ? .markForwarded : .markReplied)
        #expect(serverMarks == (addressable ? 1 : 0), "the server's mark is queued exactly when it can be addressed")
        let tags = try Self.queuedTags(pool)
        let wantTags: [String?] = isForward ? [] : [ActionTag.none.rawValue]
        #expect(tags == wantTags, "the completion queues the setTag for Send's tag clear whatever the admission: \(tags)")
    }

    // MARK: - The production entry points

    /// How the user removes a send that has not gone out.
    enum Removal: String, CaseIterable, Sendable {
        /// The toast's Undo (`PendingSendService.undo`), which returns the kept
        /// draft to Drafts in the same write.
        case undoToDrafts
        /// The Outbox's discard of a held send (`discardOutboxMessageConfirmed`).
        case outboxDiscard
        /// The Outbox's discard of a send that failed.
        case outboxDiscardAfterFailure
    }

    /// The whole path: Send through `queueSend`, then each production removal,
    /// for a reply and a forward. Both tell the open email screen and the inbox
    /// that the original changed, since it shows the mark at once and loses it
    /// again.
    @MainActor
    @Test("Send refreshes the original's screen, and every unsent removal takes back its mark and Reply tag and refreshes it again",
          arguments: Removal.allCases, [false, true])
    func productionRemovalsTakeBackTheMarks(_ removal: Removal, isForward: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            PendingSendService.shared.dismiss()
            PendingSendService.shared.dismissUndoFailure()
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = try Self.localAccount(pool, prefix: "marks-entry")
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Drafts", role: .drafts, pool: pool, lastKnownUidValidity: 1)
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "entry-parent@example.com", tag: .reply)
        let originalId = original.id
        let before = try Self.marks(pool, headerId: originalId)
        let draftId = "\(isForward ? "forward" : "reply"):\(accountId):\(original.stableId)"
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: accountId,
                toJSON: Draft.encodeStringArray(["sender@example.com"]), ccJSON: "[]", bccJSON: "[]",
                subject: isForward ? "Fwd: Original" : "Re: Original", body: "Answer", replyToId: originalId,
                isForward: isForward, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = Self.draftEpoch
            try draft.insert(db)
        }

        let posts = Mutex(0)
        let token = NotificationCenter.default.addObserver(
            forName: .messageDataDidChange, object: nil, queue: nil
        ) { note in
            if note.object as? String == originalId { posts.withLock { $0 += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let stored = try await pool.read { db in try Account.fetchOne(db, key: accountId) }
        let account = try #require(stored)
        let message = try await Self.outgoing(pool: pool, accountId: accountId, original: original, isForward: isForward)
        let queued = try await AccountManager.shared.queueSend(
            draft: message, from: account, replyToHeaderId: originalId, isForward: isForward,
            draftId: draftId, instanceEpoch: Self.draftEpoch)
        let heldNow = try Self.marks(pool, headerId: originalId)
        let held = Self.held(before: before, isForward: isForward)
        #expect(heldNow == held, "Send marks the original at once: \(heldNow)")
        let postedAtSend = posts.withLock { $0 }
        #expect(postedAtSend >= 1, "Send must tell the open email screen its message changed")
        posts.withLock { $0 = 0 }

        switch removal {
        case .undoToDrafts:
            PendingSendService.shared.present(
                outboxId: queued.outboxId, draftId: draftId, instanceEpoch: Self.draftEpoch,
                toSummary: "To: sender@example.com", holdUntil: queued.holdUntil)
            let snapshot = PendingSendService.shared.tapToastUndo()
            #expect(snapshot != nil, "precondition: the Undo was confirmed")
        case .outboxDiscard, .outboxDiscardAfterFailure:
            if removal == .outboxDiscardAfterFailure {
                try await pool.write { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                        arguments: [OutboxStatus.failed.rawValue, queued.outboxId])
                }
            }
            let discarded = AccountManager.shared.discardOutboxMessageConfirmed(queued.outboxId)
            #expect(discarded, "precondition: the discard was confirmed")
        }

        let remaining = try await pool.read { db in try OutboxMessage.fetchOne(db, key: queued.outboxId) }
        #expect(remaining == nil, "precondition: the send was removed")
        let after = try Self.marks(pool, headerId: originalId)
        #expect(after == before, "\(removal.rawValue): \(after), want \(before)")
        let tags = try Self.queuedTags(pool)
        let wantTags: [String?] = isForward ? [] : [ActionTag.reply.rawValue]
        #expect(tags == wantTags, "\(removal.rawValue): the restored Reply queues its setTag: \(tags)")
        let postedAtRemoval = posts.withLock { $0 }
        #expect(postedAtRemoval >= 1, "\(removal.rawValue): the open email screen must be told its message changed back")
    }

    // MARK: - A tag set after Send

    /// What the tag became after Send cleared it.
    enum LaterTag: String, CaseIterable, Sendable {
        /// The user filed it.
        case archive
        /// The user's Reply again (or a Reply a pass wrote, where a provider reports tags).
        case reply
        /// The user's own none, a gesture after Send.
        case userNone
    }

    /// A tag set after Send is a newer intention than Send's clear: an Undo
    /// keeps it, and the completion sends no clear for it (a Reply is still
    /// cleared, as any completed reply clears one).
    @Test("A tag set after Send is kept by an unsent removal, and the completion sends no clear of its own for it",
          arguments: LaterTag.allCases, [Outcome.undone, .completed])
    func laterTagWins(_ later: LaterTag, outcome: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-later")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "later-parent@example.com", tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)

        let tag: ActionTag = switch later {
        case .archive: .archive
        case .reply: .reply
        case .userNone: ActionTag.none
        }
        let laterStamp = queued.row.createdAt.addingTimeInterval(1)
        let originalId = original.id
        var retagged = try Self.header(pool, headerId: originalId)
        retagged.setActionTag(tag, at: laterStamp)
        let retaggedRow = retagged
        try await pool.write { db in try retaggedRow.update(db) }

        switch outcome {
        case .completed:
            try await Self.complete(pool: pool, outboxId: queued.outboxId)
            let after = try Self.marks(pool, headerId: originalId)
            let wantTag: ActionTag = later == .reply ? ActionTag.none : tag
            #expect(after == Marks(isReplied: true, isForwarded: false, actionTag: wantTag), "\(after)")
            let tags = try Self.queuedTags(pool)
            let wantTags: [String?] = later == .reply ? [ActionTag.none.rawValue] : []
            #expect(tags == wantTags, "only a Reply's clear is queued: \(tags)")
            let serverMarks = try Self.queuedCount(pool, .markReplied)
            #expect(serverMarks == 1)
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(pool: pool, outboxId: queued.outboxId)
            #expect(cancelled.revertedOriginalHeaderId == originalId, "the mark was taken back")
            let after = try Self.marks(pool, headerId: originalId)
            #expect(after == Marks(isReplied: false, isForwarded: false, actionTag: tag),
                    "the later tag stays, the mark goes: \(after)")
            let tags = try Self.queuedTags(pool)
            #expect(tags.isEmpty, "nothing restores a tag set after Send: \(tags)")
        }
    }

    // MARK: - A second reply

    /// An original already replied (by another device, or an earlier send) is
    /// not marked again, so an Undo of a second reply leaves it replied. Send's
    /// Reply tag clear is still its own, and goes back, although the earlier
    /// reply is in Sent: that reply was known before Send, so the Reply tag the
    /// user set after it is theirs.
    @Test("Undo of a second reply to an already-replied original leaves it replied",
          arguments: [AccountProvider.gmail, .imap], [false, true])
    func undoOfASecondReplyLeavesTheOriginalReplied(provider: AccountProvider, reTagged: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-second", provider: provider)
        let rfc = "second-parent@example.com"
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: rfc,
            tag: reTagged ? .reply : nil, isReplied: true)
        try Self.storeReply(pool, accountId: accountId, path: "Sent", inReplyTo: rfc)
        let before = try Self.marks(pool, headerId: original.id)

        let queued = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: false)
        let changes = queued.row.queuedOriginalChanges
        let recorded: OutboxMessage.QueuedOriginalChanges = reTagged ? [.clearedReplyTag] : []
        #expect(changes == recorded, "Send records no mark it did not set: \(changes.rawValue)")
        let held = try Self.marks(pool, headerId: original.id)
        #expect(held == Marks(isReplied: true, isForwarded: false, actionTag: reTagged ? ActionTag.none : nil), "\(held)")

        try await Self.cancel(pool: pool, outboxId: queued.outboxId)
        let after = try Self.marks(pool, headerId: original.id)
        #expect(after == before, "the Undo leaves the original replied: \(after), want \(before)")
        if !reTagged {
            let rowAfter = try Self.rowSnapshot(pool, headerId: original.id)
            #expect(rowAfter == queued.originalRow, "Send and its Undo changed nothing")
        }
    }

    // MARK: - Two pending replies

    /// Each unsent removal takes back exactly what its own row recorded. The
    /// first reply marks the original and clears its tag; the second finds it
    /// marked and records nothing. Undoing the first therefore leaves no reply
    /// arrow while the second is still pending (a registered gap: the second's
    /// completion marks it again).
    @Test("Two pending replies: undoing the first takes back its own changes; the second's Undo or completion settles the original",
          arguments: [Outcome.undone, .completed])
    func twoPendingReplies(second: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-two")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "two-parent@example.com", tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)

        let first = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)
        let replyB = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: false, draftId: "reply-b-\(accountId)")
        let secondChanges = replyB.row.queuedOriginalChanges
        #expect(secondChanges.isEmpty, "the second reply finds the original marked: \(secondChanges.rawValue)")
        #expect(replyB.changedOriginalHeaderId == nil)

        try await Self.cancel(pool: pool, outboxId: first.outboxId)
        let gap = try Self.marks(pool, headerId: original.id)
        #expect(gap == before, "undoing the first takes back its changes, the second still pending: \(gap)")

        switch second {
        case .completed:
            try await Self.complete(pool: pool, outboxId: replyB.outboxId)
            let after = try Self.marks(pool, headerId: original.id)
            #expect(after == Marks(isReplied: true, isForwarded: false, actionTag: ActionTag.none),
                    "the second reply went out: marked, its tag cleared: \(after)")
            let tags = try Self.queuedTags(pool)
            #expect(tags == [ActionTag.reply.rawValue, ActionTag.none.rawValue],
                    "the queued tags end with the clear, after the first Undo's restore: \(tags)")
            let serverMarks = try Self.queuedCount(pool, .markReplied)
            #expect(serverMarks == 1)
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(pool: pool, outboxId: replyB.outboxId)
            #expect(cancelled.revertedOriginalHeaderId == nil, "the second recorded nothing to take back")
            let after = try Self.marks(pool, headerId: original.id)
            #expect(after == before, "both undone: the original is as it was: \(after), want \(before)")
            let tags = try Self.queuedTags(pool)
            #expect(tags == [ActionTag.reply.rawValue], "\(tags)")
        }
    }

    // MARK: - A failed send, then another to the same original that went out

    /// The send that went out after a first one failed and stayed in the Outbox.
    enum SecondSend: String, CaseIterable, Sendable {
        /// The same kind (a reply again after a failed reply), and its
        /// completion can address the original.
        case sameKind
        /// The other kind (a forward after a failed reply, a reply after a
        /// failed forward).
        case otherKind
        /// The same kind, but by its completion the original can no longer be
        /// addressed on the server, so no server mark is queued. No copy of it
        /// is stored in Sent (the account has no Sent folder).
        case sameKindUnaddressable
        /// As `sameKindUnaddressable`, with the copy of the send that went out
        /// stored in Sent as the send writes it (`insertOptimisticSentHeader`):
        /// the usual case.
        case sameKindUnaddressableSentCopy
    }

    /// A send that went out stands for what it applied: a failed send to the
    /// same original, discarded after it, must not take that back. The
    /// completion takes a reply's cleared Reply tag off the failed send's
    /// record always, and the mark when it can address the original. A send of
    /// the other kind leaves that record. A mark the completion could not
    /// queue goes back with the failed send, unless a reply to the original is
    /// stored in Sent: the copy of the reply that went out.
    @Test("A failed send discarded after another to the same original went out leaves the original as that send left it",
          arguments: [false, true], SecondSend.allCases)
    func failedSendDiscardedAfterAnotherWentOut(isForward: Bool, second: SecondSend) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-resend")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "resend-parent@example.com", tag: .reply)
        let originalId = original.id
        let before = try Self.marks(pool, headerId: originalId)

        let failed = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)
        let failedId = failed.outboxId
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.failed.rawValue, failedId])
        }
        let secondIsForward = second == .otherKind ? !isForward : isForward
        let again = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: secondIsForward,
            draftId: "again-\(accountId)")
        let unaddressable = second == .sameKindUnaddressable || second == .sameKindUnaddressableSentCopy
        if unaddressable {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET observedUidValidity = NULL WHERE id = ?",
                    arguments: [originalId])
            }
        }
        if second == .sameKindUnaddressableSentCopy {
            try Self.storeSentCopy(pool, of: again.row)
        }
        try await Self.complete(pool: pool, outboxId: again.outboxId)

        let stored = try await pool.read { db in try OutboxMessage.fetchOne(db, key: failedId) }
        let failedRow = try #require(stored, "precondition: the failed send is still in the Outbox")
        let kept = failedRow.queuedOriginalChanges
        let recorded = failed.row.queuedOriginalChanges
        var wantKept = recorded
        switch second {
        case .sameKind: wantKept = []
        case .otherKind: break
        case .sameKindUnaddressable, .sameKindUnaddressableSentCopy: wantKept.remove(.clearedReplyTag)
        }
        #expect(kept == wantKept, "the failed send's record once the other went out: \(kept.rawValue), want \(wantKept.rawValue)")
        let afterSecond = try Self.marks(pool, headerId: originalId)
        let operationsBeforeDiscard = try Self.markOps(pool).count

        let cancelled = try await Self.cancel(pool: pool, outboxId: failedId, failedFirst: true)
        let after = try Self.marks(pool, headerId: originalId)
        switch second {
        case .sameKind:
            #expect(cancelled.revertedOriginalHeaderId == nil, "the discard has nothing left to take back")
            let want = Self.held(before: before, isForward: isForward)
            #expect(afterSecond == want, "precondition: the send that went out marked it: \(afterSecond)")
            #expect(after == want, "the discard leaves what the send that went out stands for: \(after), want \(want)")
            let operationsAfter = try Self.markOps(pool).count
            #expect(operationsAfter == operationsBeforeDiscard, "the discard queues no tag")
        case .otherKind:
            #expect(cancelled.revertedOriginalHeaderId == originalId, "the failed send takes back its own kind's mark")
            let want = Self.held(before: before, isForward: secondIsForward)
            #expect(after == want, "only the other kind's mark stays: \(after), want \(want)")
        case .sameKindUnaddressable:
            #expect(cancelled.revertedOriginalHeaderId == originalId, "no server mark was queued, so the failed send's mark goes back")
            var want = before
            if !isForward { want.actionTag = ActionTag.none }
            #expect(after == want, "the mark goes back, a reply's cleared tag stays cleared: \(after), want \(want)")
            let tags = try Self.queuedTags(pool)
            #expect(!tags.contains(ActionTag.reply.rawValue), "no Reply is restored: \(tags)")
        case .sameKindUnaddressableSentCopy:
            if isForward {
                #expect(cancelled.revertedOriginalHeaderId == originalId, "a forward has no such evidence: its mark goes back")
                #expect(after == before, "\(after), want \(before)")
            } else {
                #expect(cancelled.revertedOriginalHeaderId == nil, "the reply's copy in Sent keeps the mark")
                let want = Self.held(before: before, isForward: false)
                #expect(after == want, "\(after), want \(want)")
                let operationsAfter = try Self.markOps(pool).count
                #expect(operationsAfter == operationsBeforeDiscard, "the discard queues no tag")
            }
        }
    }

    /// The copy of `sent` the send writes into the account's Sent folder before
    /// the send is finalized, as `insertOptimisticSentHeader` writes it: its
    /// In-Reply-To normalized from the row's (none on a forward, #1483).
    static func storeSentCopy(_ pool: DatabasePool, of sent: OutboxMessage) throws {
        try Self.storeReply(
            pool, accountId: sent.accountId, path: "Sent",
            inReplyTo: sent.inReplyTo.map(EmailFilter.normalizeMessageId))
    }

    /// How the first send stands when another of its kind to the same original
    /// goes out, and how it then leaves the Outbox unsent.
    enum FirstSend: String, CaseIterable, Sendable {
        /// Still held in its Undo window; the user taps Undo.
        case heldThenUndone
        /// Going out; it then fails and the user discards it.
        case sendingThenDiscarded
    }

    /// The completion releases the other sends' records whatever their status:
    /// a held send undone, or one that was going out and then failed and is
    /// discarded, after another of its kind went out leaves the original as that
    /// send left it.
    @Test("A held or sending send removed unsent after another of its kind to the same original went out leaves the original as that send left it",
          arguments: [false, true], FirstSend.allCases)
    func unsentSendRemovedAfterAnotherWentOut(isForward: Bool, first: FirstSend) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-held")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "held-parent@example.com", tag: .reply)
        let originalId = original.id
        let before = try Self.marks(pool, headerId: originalId)

        let firstSend = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)
        let firstId = firstSend.outboxId
        let statusAtCompletion = first == .heldThenUndone ? OutboxStatus.queued : .sending
        if first == .sendingThenDiscarded {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, firstId])
            }
        }
        let again = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: isForward,
            draftId: "again-\(accountId)")
        try await Self.complete(pool: pool, outboxId: again.outboxId)

        let stored = try await pool.read { db in try OutboxMessage.fetchOne(db, key: firstId) }
        let firstRow = try #require(stored, "precondition: the first send is still in the Outbox")
        #expect(firstRow.status == statusAtCompletion.rawValue, "precondition: the first send is \(statusAtCompletion.rawValue)")
        let kept = firstRow.queuedOriginalChanges
        #expect(kept.isEmpty, "the send that went out took its kind's changes off the first send's record: \(kept.rawValue)")
        let want = Self.held(before: before, isForward: isForward)
        let afterSecond = try Self.marks(pool, headerId: originalId)
        #expect(afterSecond == want, "precondition: the send that went out marked it: \(afterSecond)")
        let operationsBeforeRemoval = try Self.markOps(pool).count

        let cancelled = try await Self.cancel(
            pool: pool, outboxId: firstId, failedFirst: first == .sendingThenDiscarded)
        #expect(cancelled.revertedOriginalHeaderId == nil, "the removal has nothing left to take back")
        let after = try Self.marks(pool, headerId: originalId)
        #expect(after == want, "the removal leaves what the send that went out stands for: \(after), want \(want)")
        let operationsAfter = try Self.markOps(pool).count
        #expect(operationsAfter == operationsBeforeRemoval, "the removal queues no tag")
    }

    /// An original the server cannot address at either Send: the first reply
    /// clears the Reply tag and records only that, fails, and the user replies
    /// again. That reply's completion clears tags whatever the admission, so it
    /// takes the clear off the failed reply's record, and discarding the failed
    /// reply leaves the tag cleared on a message the user has answered.
    @Test("A reply's tag clear on an unaddressable original stays cleared when the failed reply is discarded after another went out")
    func tagOnlyClearReleasedByAnUnaddressableCompletion() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-tagonly")
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "tagonly-parent@example.com", observed: nil, tag: .reply)
        let originalId = original.id
        let before = try Self.marks(pool, headerId: originalId)

        let failed = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: false)
        let recorded = failed.row.queuedOriginalChanges
        #expect(recorded == [.clearedReplyTag], "precondition: Send recorded only the tag clear: \(recorded.rawValue)")
        let failedId = failed.outboxId
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.failed.rawValue, failedId])
        }
        let again = try await Self.queue(
            pool: pool, accountId: accountId, original: original, isForward: false,
            draftId: "again-\(accountId)")
        let againChanges = again.row.queuedOriginalChanges
        #expect(againChanges.isEmpty, "precondition: the second reply found the tag cleared: \(againChanges.rawValue)")
        try await Self.complete(pool: pool, outboxId: again.outboxId)

        let stored = try await pool.read { db in try OutboxMessage.fetchOne(db, key: failedId) }
        let failedRow = try #require(stored, "precondition: the failed reply is still in the Outbox")
        let kept = failedRow.queuedOriginalChanges
        #expect(kept.isEmpty, "the completion took the tag clear off the failed reply's record: \(kept.rawValue)")

        let cancelled = try await Self.cancel(pool: pool, outboxId: failedId, failedFirst: true)
        #expect(cancelled.revertedOriginalHeaderId == nil, "the discard has nothing to take back")
        let after = try Self.marks(pool, headerId: originalId)
        var want = before
        want.actionTag = ActionTag.none
        #expect(after == want, "not replied (no server mark could be queued), its Reply tag cleared: \(after), want \(want)")
        let tags = try Self.queuedTags(pool)
        #expect(!tags.contains(ActionTag.reply.rawValue), "no Reply is restored: \(tags)")
    }

    // MARK: - A reply sent from another client while the send waited

    /// Where a reply to the original is stored when the send is removed unsent.
    enum StoredReply: String, CaseIterable, Sendable {
        /// In the account's Sent folder, its In-Reply-To normalized, as every
        /// writer stores it.
        case sent
        /// In the account's Inbox: someone else's reply, which says nothing
        /// about the user's.
        case inbox
        /// In the account's Drafts folder: a reply not sent.
        case drafts
        /// In another account's Sent folder.
        case otherAccountSent
        /// In the account's Sent folder, but a forward: another app's forward
        /// that names the original in In-Reply-To too (as Thunderbird's does).
        case sentForward
        /// That forward with an upper-case `FW:` prefix (as Outlook writes it).
        case sentUpperCaseForward
        /// In the account's Sent folder, a reply whose subject carries a forward
        /// prefix after its `Re:` (`Re: Fwd: Original`): a reply all the same.
        case sentReplyWithForwardInSubject
        /// In the account's Sent folder, that forward stored first and a reply
        /// after it.
        case sentForwardAndReply
        /// In the account's Sent folder, a reply stored first and that forward
        /// after it.
        case sentReplyAndForward

        /// Whether a reply (not a forward) is stored in the account's Sent
        /// folder: what keeps Send's changes on the original.
        var storesAReplyInSent: Bool {
            switch self {
            case .sent, .sentReplyWithForwardInSubject, .sentForwardAndReply, .sentReplyAndForward: true
            case .inbox, .drafts, .otherAccountSent, .sentForward, .sentUpperCaseForward: false
            }
        }
    }

    /// A message per subject in `subjects`, each naming `inReplyTo` in its
    /// In-Reply-To, stored in the folder at `path` of `accountId` in that order
    /// (a folder with `role` is added for them when `path` is not the INBOX).
    static func storeReply(
        _ pool: DatabasePool, accountId: String, path: String, role: FolderRole = .sent, inReplyTo: String?,
        subjects: [String] = ["Re: Original"]
    ) throws {
        if path != Self.imapPath {
            try FolderEpochTestFixture.insertFolder(
                accountId: accountId, path: path, role: role, pool: pool,
                lastKnownUidValidity: Self.imapEpoch + 2)
        }
        for (index, subject) in subjects.enumerated() {
            var reply = MessageHeader(
                messageId: "\(90 + index)", subject: subject, from: "Me",
                fromAddress: "me@example.com", to: "sender@example.com", date: Date(),
                snippet: "reply",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: path),
                accountId: accountId, folderPath: path, isInInbox: path == Self.imapPath)
            reply.rfc822MessageId = "stored-reply-\(index)-\(accountId)@example.com"
            reply.inReplyTo = inReplyTo
            reply.headerComplete = true
            let row = reply
            try pool.write { db in try row.insert(db) }
        }
    }

    /// A reply already in the account's Sent folder (sent from another client
    /// while TabMail's reply waited) keeps the original replied and its Reply tag
    /// cleared when TabMail's reply is removed unsent. Only a reply in Sent, in
    /// the same account, counts. Another app's forward there, which names the
    /// original in In-Reply-To as a reply does, is no reply (the rule
    /// `ReplyParentResolver` marks the original forwarded by, whatever the
    /// prefix's case), so alone it keeps nothing; stored before or after a
    /// reply, it does not hide that reply. A forward from TabMail asks for no
    /// such evidence, and its mark goes back as before.
    @Test("A reply the user sent elsewhere keeps the original replied when TabMail's reply is removed unsent",
          arguments: StoredReply.allCases, [false, true])
    func storedReplyKeepsTheMark(_ storedReply: StoredReply, isForward: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-stored")
        let rfc = "stored-parent@example.com"
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: rfc, tag: .reply)
        let originalId = original.id
        let before = try Self.marks(pool, headerId: originalId)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)

        switch storedReply {
        case .sent:
            try Self.storeReply(pool, accountId: accountId, path: "Sent", inReplyTo: rfc)
        case .inbox:
            try Self.storeReply(pool, accountId: accountId, path: Self.imapPath, inReplyTo: rfc)
        case .drafts:
            try Self.storeReply(pool, accountId: accountId, path: "Drafts", role: .drafts, inReplyTo: rfc)
        case .otherAccountSent:
            let otherAccountId = try Self.localAccount(pool, prefix: "marks-other")
            try Self.storeReply(pool, accountId: otherAccountId, path: "Sent", inReplyTo: rfc)
        case .sentForward:
            try Self.storeReply(pool, accountId: accountId, path: "Sent", inReplyTo: rfc, subjects: ["Fwd: Original"])
        case .sentUpperCaseForward:
            try Self.storeReply(pool, accountId: accountId, path: "Sent", inReplyTo: rfc, subjects: ["FW: Original"])
        case .sentReplyWithForwardInSubject:
            try Self.storeReply(pool, accountId: accountId, path: "Sent", inReplyTo: rfc, subjects: ["Re: Fwd: Original"])
        case .sentForwardAndReply:
            try Self.storeReply(
                pool, accountId: accountId, path: "Sent", inReplyTo: rfc, subjects: ["Fwd: Original", "Re: Original"])
        case .sentReplyAndForward:
            try Self.storeReply(
                pool, accountId: accountId, path: "Sent", inReplyTo: rfc, subjects: ["Re: Original", "Fwd: Original"])
        }

        let cancelled = try await Self.cancel(pool: pool, outboxId: queued.outboxId, failedFirst: true)
        let after = try Self.marks(pool, headerId: originalId)
        let tags = try Self.queuedTags(pool)
        let keeps = !isForward && storedReply.storesAReplyInSent
        if keeps {
            #expect(cancelled.revertedOriginalHeaderId == nil, "the stored reply keeps what Send changed")
            let want = Self.held(before: before, isForward: false)
            #expect(after == want, "\(storedReply.rawValue): \(after), want \(want)")
            #expect(tags.isEmpty, "no Reply is restored: \(tags)")
        } else {
            #expect(cancelled.revertedOriginalHeaderId == originalId, "\(storedReply.rawValue): Send's changes go back")
            #expect(after == before, "\(storedReply.rawValue): \(after), want \(before)")
        }
    }

    /// The whole path on Gmail, which reports no replied flag: the user replies
    /// on the web while TabMail's reply waits (it failed), then discards
    /// TabMail's reply. Only the web reply's copy in Sent tells, whether it syncs
    /// before the discard or after it.
    @Test("Gmail: a reply sent on the web while TabMail's waited keeps the original replied when TabMail's is discarded",
          arguments: [true, false])
    func gmailWebReplyWhileTheSendWaited(copySyncedFirst: Bool) async throws {
        let seed = GmailDeltaApplyInvariantTests.seed("web-1", labels: ["INBOX"])
        try await GmailDeltaApplyInvariantTests.withWorld(seeds: [seed]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let stored = try w.row("web-1", in: w.inbox)
            let original = try #require(stored, "precondition: the full pass stored the original")
            let originalRfc = try #require(original.rfc822MessageId)
            try await Self.tagReply(w.pool, headerId: original.id)
            let before = try Self.marks(w.pool, headerId: original.id)
            let queued = try await Self.queueAndCheckHeld(
                pool: w.pool, accountId: w.accountId, original: original, isForward: false, before: before)
            let replied = Self.held(before: before, isForward: false)

            func webReplySyncs() async throws {
                w.server.addMessage(GmailDeltaApplyInvariantTests.seed(
                    "web-reply", labels: ["SENT"],
                    headers: ["In-Reply-To": "<\(originalRfc)>", "References": "<\(originalRfc)>"]))
                try await w.completedDelta()
                let copy = try w.row("web-reply", in: w.sent)
                #expect(copy != nil, "precondition: the web reply's copy synced")
            }

            if copySyncedFirst {
                try await webReplySyncs()
                let held = try Self.marks(w.pool, headerId: original.id)
                #expect(held == replied, "the web reply's copy keeps Send's marks: \(held)")
            }
            let cancelled = try await Self.cancel(pool: w.pool, outboxId: queued.outboxId, failedFirst: true)
            if copySyncedFirst {
                #expect(cancelled.revertedOriginalHeaderId == nil, "the web reply keeps what Send changed")
                let tags = try Self.queuedTags(w.pool)
                #expect(tags.isEmpty, "no Reply is restored: \(tags)")
            } else {
                let gap = try Self.marks(w.pool, headerId: original.id)
                #expect(gap == before, "before the web reply is known, the discard takes Send's changes back: \(gap)")
                try await webReplySyncs()
            }
            let afterRemoval = try Self.marks(w.pool, headerId: original.id)
            #expect(afterRemoval == replied, "replied, its Reply tag cleared: \(afterRemoval), want \(replied)")

            try await w.delta()
            let afterDelta = try Self.marks(w.pool, headerId: original.id)
            #expect(afterDelta == replied, "after a change pass: \(afterDelta)")
            try await w.foregroundPassWithFullSyncDue()
            let afterFull = try Self.marks(w.pool, headerId: original.id)
            #expect(afterFull == replied, "after a full pass: \(afterFull)")
        }
    }

    // MARK: - A send queued before Send marked the original

    /// A row queued by an earlier version recorded nothing (NULL): Send did not
    /// mark the original then, so its removal changes nothing.
    @Test("Removing a send queued before this version changes nothing on its original")
    func removalOfAnOlderRowChangesNothing() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-older")
        let parentRfc = "older-parent@example.com"
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: parentRfc, tag: .reply)
        var older = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(
                to: ["sender@example.com"], subject: "Re: Original", body: "text",
                inReplyTo: "<\(parentRfc)>", references: [parentRfc]),
            originalMessageHeaderId: original.id)
        older.holdUntil = Date().addingTimeInterval(SyncConfig.outboxUndoHoldSeconds)
        #expect(older.originalChangesAtQueue == nil, "precondition: the row recorded nothing")
        let olderRow = older
        try await pool.write { db in try olderRow.insert(db) }
        let rowBefore = try Self.rowSnapshot(pool, headerId: original.id)
        let operationsBefore = try Self.operationCount(pool)

        let cancelled = try await Self.cancel(pool: pool, outboxId: olderRow.id)
        #expect(cancelled.revertedOriginalHeaderId == nil)
        let rowAfter = try Self.rowSnapshot(pool, headerId: original.id)
        #expect(rowAfter == rowBefore, "the original stays byte-identical")
        let operationsAfter = try Self.operationCount(pool)
        #expect(operationsAfter == operationsBefore, "no operation may be queued")
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
    /// naming it (`MessageDetailViewModel`). A send queued before this version
    /// (no record, inserted here directly) marks its original only when it
    /// completes, so the completion must post whenever it changed the original:
    /// a mark (reply, reply-all, forward), or only the cleared Reply tag. When it
    /// changed nothing it must not post.
    @Test("Completing a send refreshes the original's open screen exactly when it changed the original",
          arguments: CompletionChange.allCases)
    func completionRefreshesTheOpenOriginal(_ change: CompletionChange) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-post")
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

    // MARK: - An AI tag written while the send is held

    /// The AI tags an email Reply unless it is already replied. Send marks an
    /// addressable original replied, so the AI writes none during the hold and
    /// the completion has nothing to clear. An original the server cannot be
    /// asked to mark is not marked, so the AI's Reply lands and the completion
    /// clears it.
    @Test("An AI tag written while the reply is held: none on a marked original, a Reply the completion clears on an unmarked one",
          arguments: [true, false])
    func aiTagWrittenDuringTheHold(addressable: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-ai")
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "ai-parent@example.com",
            observed: addressable ? Self.imapEpoch : nil)
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
        let wantHeld = Marks(
            isReplied: addressable, isForwarded: false, actionTag: addressable ? ActionTag.none : .reply)
        #expect(held == wantHeld, "during the hold: \(held), want \(wantHeld)")

        try await Self.complete(pool: pool, outboxId: queued.outboxId)
        let after = try Self.marks(pool, headerId: original.id)
        #expect(after == Marks(isReplied: addressable, isForwarded: false, actionTag: ActionTag.none),
                "the completion leaves no Reply tag: \(after)")
        let tags = try Self.queuedTags(pool)
        let wantTags: [String?] = addressable ? [] : [ActionTag.none.rawValue]
        #expect(tags == wantTags, "only the AI's Reply clear is queued: \(tags)")
    }

    // MARK: - The original moved before the send went out

    static let archivePath = "Archive"
    static let archiveEpoch = SendReplyMarksTests.imapEpoch + 1

    /// An Archive folder with a known epoch, for an original moved there.
    static func insertArchive(_ pool: DatabasePool, accountId: String) throws {
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.archivePath, role: .archive, pool: pool,
            lastKnownUidValidity: Self.archiveEpoch)
    }

    /// The move gesture's local write (`AccountManager`'s move): the row moves to
    /// `path` and keeps its key until the move lands. Leaving the Inbox clears
    /// its action tag in the same write (tags are local-only, ADR-IOS-036).
    static func moveLocally(
        _ pool: DatabasePool, headerId: String, accountId: String, to path: String
    ) async throws {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: path)
        try await pool.write { db in
            let stored = try MessageHeader.fetchOne(db, key: headerId)
            let leavingInbox = stored?.isInInbox ?? false
            if leavingInbox {
                try db.execute(
                    sql: """
                        UPDATE messageHeader
                        SET folderPath = ?, folderId = ?, isInInbox = 0, observedUidValidity = NULL,
                            actionTag = NULL, tagSortOrder = 99
                        WHERE id = ?
                        """,
                    arguments: [path, folderId, headerId])
            } else {
                try db.execute(
                    sql: "UPDATE messageHeader SET folderPath = ?, folderId = ?, isInInbox = 0, observedUidValidity = NULL WHERE id = ?",
                    arguments: [path, folderId, headerId])
            }
        }
    }

    /// The move of `providerId` from `source` to `destination` lands, and the
    /// server names the copy `newProviderId` (on IMAP in `epoch`; Graph has no
    /// epoch), as the drain's retirement runs it.
    static func landMove(
        _ pool: DatabasePool, accountId: String, providerId: String,
        from source: String, to destination: String, newProviderId: String,
        epoch: Int?, accountScopedIds: Bool = false
    ) async throws -> MoveFinishResult {
        let move = PendingOperation(
            type: .move, messageIds: [providerId], accountId: accountId,
            folderPath: source, destinationPath: destination,
            observedUidValidity: accountScopedIds ? nil : Self.imapEpoch)
        let proven = ProvenDestinationAddress(
            sourceProviderId: providerId, destinationProviderId: newProviderId,
            destinationUidValidity: epoch.map { UInt32($0) })
        return try await pool.write { db in
            try MessageHeaderRekey.finishMove(
                move, destinations: [proven],
                addressChangesOnMove: true, accountScopedIds: accountScopedIds, copiedNothing: false, db: db)
        }
    }

    /// The original the queued send names.
    static func pointer(_ pool: DatabasePool, outboxId: String) throws -> String? {
        try pool.read { db in try OutboxMessage.fetchOne(db, key: outboxId)?.originalMessageHeaderId }
    }

    /// Archiving the original while its send is held gives it a new address (on
    /// IMAP a UID in Archive; the row is re-keyed when the move lands), and the
    /// queued send follows it (#1479): the completion marks the moved original
    /// and queues the server's mark at its Archive address, and an unsent
    /// removal takes Send's marks back from it. Leaving the Inbox cleared the
    /// tag, so neither queues a tag.
    @Test("An original archived while its reply or forward is held: the completion marks it at its Archive address, and an Undo takes Send's marks back from it",
          arguments: [false, true], [Outcome.completed, .undone])
    func originalArchivedWhileTheSendIsHeld(isForward: Bool, outcome: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-moved")
        try Self.insertArchive(pool, accountId: accountId)
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "moved-parent@example.com", tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)

        // The archive gesture moves the row locally and clears its tag; it keeps its key until the move lands ...
        try await Self.moveLocally(pool, headerId: original.id, accountId: accountId, to: Self.archivePath)
        // ... and when it lands, the row takes the Archive copy's address the server named.
        let finished = try await Self.landMove(
            pool, accountId: accountId, providerId: original.messageId,
            from: Self.imapPath, to: Self.archivePath, newProviderId: "9", epoch: Self.archiveEpoch)
        #expect(finished.applied.count == 1, "precondition: the move re-keyed the original")
        let movedId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.archivePath, messageId: "9")
        let moved = try Self.marks(pool, headerId: movedId)
        var archived = Self.held(before: before, isForward: isForward)
        archived.actionTag = nil
        #expect(moved == archived, "the moved original keeps Send's marks, its tag cleared by the archive: \(moved)")
        let outboxId = queued.outboxId
        let pointer = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointer == movedId, "the queued send follows its original to the Archive address: \(pointer ?? "nil")")

        let markType = isForward ? OperationType.markForwarded : OperationType.markReplied
        switch outcome {
        case .completed:
            let disposition = try await Self.complete(pool: pool, outboxId: outboxId)
            #expect(disposition.changedOriginalHeaderId == movedId, "the completion finds the moved original")
            let serverMarks = try Self.markOps(pool).filter { $0.type == markType }
            #expect(serverMarks.count == 1, "the completed send queues the server's \(markType.rawValue)")
            guard serverMarks.count == 1 else { return }
            #expect(serverMarks[0].messageIds == ["9"], "the server's mark names the Archive copy: \(serverMarks[0].messageIds)")
            let markEpoch = serverMarks[0].observedUidValidity
            #expect(markEpoch == Self.archiveEpoch, "the server's mark carries the Archive epoch: \(String(describing: markEpoch))")
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(
                pool: pool, outboxId: outboxId, failedFirst: outcome == .discardedAfterFailure)
            #expect(cancelled.revertedOriginalHeaderId == movedId, "the Undo finds the moved original")
            let serverMarks = try Self.queuedCount(pool, markType)
            #expect(serverMarks == 0, "no server mark for a send that never went out")
        }
        let tags = try Self.queuedTags(pool)
        #expect(tags.isEmpty, "the archive cleared the tag, so there is no clear to queue and no Reply to restore: \(tags)")
        let folders = try Self.markOps(pool).map(\.folderPath)
        let wantOps = outcome == .completed ? 1 : 0
        #expect(folders.count == wantOps, "\(outcome.rawValue): mark and tag ops queued: \(folders)")
        let archivePath = Self.archivePath
        let allInArchive = folders.allSatisfy { $0 == archivePath }
        #expect(allInArchive, "every queued mark names the Archive copy: \(folders)")
        let after = try Self.marks(pool, headerId: movedId)
        var want = Self.expected(before: before, isForward: isForward, outcome: outcome)
        want.actionTag = nil
        #expect(after == want, "\(outcome.rawValue): \(after), want \(want)")
    }

    /// The held send's row when its original's move lands.
    enum SendAtLanding: String, CaseIterable, Sendable {
        /// Waiting in the Outbox (held, or offline); the user undoes it after.
        case queued
        /// The send failed; the user discards it from the Outbox after.
        case failed
        /// Going out; it completes after.
        case sending
        /// Sent, its copy not yet appended to Sent; it is finalized after.
        case sentNotFinalized
    }

    /// The landing carries every outbox row that names the moved original, in
    /// any state, and no other: a reply and a forward to it both follow it,
    /// and a reply to another message keeps its own original.
    @Test("A landed move carries every send to the moved original, whatever its state, and no send to another message",
          arguments: SendAtLanding.allCases)
    func landedMoveCarriesEverySendToTheOriginal(_ state: SendAtLanding) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-carry")
        try Self.insertArchive(pool, accountId: accountId)
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "carry-parent@example.com", tag: .reply)
        let other = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "carry-other@example.com", messageId: "60", tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let otherBefore = try Self.marks(pool, headerId: other.id)
        let reply = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)
        let forward = try await Self.queue(pool: pool, accountId: accountId, original: original, isForward: true)
        let bystander = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: other, isForward: false, before: otherBefore)

        let replyId = reply.outboxId
        try await pool.write { db in
            switch state {
            case .queued:
                break
            case .failed:
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.failed.rawValue, replyId])
            case .sending:
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, replyId])
            case .sentNotFinalized:
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, sentAt = ?, appendedToSent = 0 WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, Date(), replyId])
            }
        }

        try await Self.moveLocally(pool, headerId: original.id, accountId: accountId, to: Self.archivePath)
        let finished = try await Self.landMove(
            pool, accountId: accountId, providerId: original.messageId,
            from: Self.imapPath, to: Self.archivePath, newProviderId: "9", epoch: Self.archiveEpoch)
        #expect(finished.applied.count == 1, "precondition: the move re-keyed the original")
        let movedId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.archivePath, messageId: "9")
        let replyPointer = try Self.pointer(pool, outboxId: replyId)
        #expect(replyPointer == movedId, "\(state.rawValue): the reply follows its original: \(replyPointer ?? "nil")")
        let forwardPointer = try Self.pointer(pool, outboxId: forward.outboxId)
        #expect(forwardPointer == movedId, "the forward to the same original follows it: \(forwardPointer ?? "nil")")
        let bystanderPointer = try Self.pointer(pool, outboxId: bystander.outboxId)
        #expect(bystanderPointer == other.id, "a reply to another message keeps its original: \(bystanderPointer ?? "nil")")

        switch state {
        case .queued, .failed:
            let cancelled = try await Self.cancel(pool: pool, outboxId: replyId)
            #expect(cancelled.revertedOriginalHeaderId == movedId, "\(state.rawValue): the removal finds the moved original")
        case .sending, .sentNotFinalized:
            let disposition = try await Self.complete(pool: pool, outboxId: replyId)
            #expect(disposition.changedOriginalHeaderId == movedId, "\(state.rawValue): the completion finds the moved original")
            let serverMarks = try Self.markOps(pool).filter { $0.type == .markReplied }.map(\.messageIds)
            #expect(serverMarks == [["9"]], "the server's mark names the Archive copy: \(serverMarks)")
        }
        let forwardCancelled = try await Self.cancel(pool: pool, outboxId: forward.outboxId)
        #expect(forwardCancelled.revertedOriginalHeaderId == movedId, "the forward's Undo finds the moved original")
        let after = try Self.marks(pool, headerId: movedId)
        let replied = state == .sending || state == .sentNotFinalized
        let want = Marks(isReplied: replied, isForwarded: false, actionTag: nil)
        #expect(after == want, "\(state.rawValue): \(after), want \(want)")

        let bystanderCancelled = try await Self.cancel(pool: pool, outboxId: bystander.outboxId)
        #expect(bystanderCancelled.revertedOriginalHeaderId == other.id, "the other reply's Undo finds its own original")
        let otherAfter = try Self.marks(pool, headerId: other.id)
        #expect(otherAfter == otherBefore, "the other original is as it was: \(otherAfter), want \(otherBefore)")
    }

    static let projectsPath = "Projects"

    /// On an account-scoped provider (Graph) the landing finds the row by its
    /// provider id wherever it sits, and the row's key can name another folder
    /// than the move's source: here the original was archived and then moved on
    /// to Projects before either move landed. The send follows the row's own
    /// key at each landing.
    @Test("Graph: a move that lands after the original moved on carries the send from the row's own key")
    func graphMoveCarriesTheSendFromTheRowsKey() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-graph", provider: .outlook)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.archivePath, role: .archive, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.projectsPath, role: .custom, pool: pool)
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "graph-parent@example.com", observed: nil, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)

        try await Self.moveLocally(pool, headerId: original.id, accountId: accountId, to: Self.archivePath)
        try await Self.moveLocally(pool, headerId: original.id, accountId: accountId, to: Self.projectsPath)
        // The archive lands first: Graph names the message "58", and the row, now
        // in Projects, takes that id there.
        let first = try await Self.landMove(
            pool, accountId: accountId, providerId: original.messageId,
            from: Self.imapPath, to: Self.archivePath, newProviderId: "58", epoch: nil, accountScopedIds: true)
        #expect(first.applied.count == 1, "precondition: the archive re-keyed the original")
        let firstId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.projectsPath, messageId: "58")
        let firstPointer = try Self.pointer(pool, outboxId: queued.outboxId)
        #expect(firstPointer == firstId, "the send follows the first landing: \(firstPointer ?? "nil")")
        // The move to Projects lands next, under the id the archive's landing gave it.
        let sourceShapedId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.archivePath, messageId: "58")
        #expect(sourceShapedId != firstId, "precondition: the row's key is not the one the move's source names")
        let second = try await Self.landMove(
            pool, accountId: accountId, providerId: "58",
            from: Self.archivePath, to: Self.projectsPath, newProviderId: "59", epoch: nil, accountScopedIds: true)
        #expect(second.applied.count == 1, "precondition: the second move re-keyed the original")
        let movedId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.projectsPath, messageId: "59")
        let pointer = try Self.pointer(pool, outboxId: queued.outboxId)
        #expect(pointer == movedId, "the send follows the row's own key: \(pointer ?? "nil")")

        let disposition = try await Self.complete(pool: pool, outboxId: queued.outboxId)
        #expect(disposition.changedOriginalHeaderId == movedId, "the completion finds the moved original")
        let serverMarks = try Self.markOps(pool).filter { $0.type == .markReplied }.map(\.messageIds)
        #expect(serverMarks == [["59"]], "the server's mark names the message's current id: \(serverMarks)")
    }

    /// An original moved in another client while its send is held: sync drops the
    /// INBOX row and stores the Archive copy as a new row. Only the Message-ID
    /// links that row to the queued send, and the Message-ID never selects a
    /// message to change (ADR-IOS-068 D4), so neither the completion nor an Undo
    /// finds it, and neither changes it or queues anything for it
    /// (`IOS-OUTBOX-012`).
    @Test("An original moved in another client while its reply or forward is held: neither the completion nor an Undo touches the copy sync stored",
          arguments: [false, true], [Outcome.completed, .undone])
    func originalMovedElsewhereWhileTheSendIsHeld(isForward: Bool, outcome: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-elsewhere")
        try Self.insertArchive(pool, accountId: accountId)
        let parentRfc = "elsewhere-parent@example.com"
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: parentRfc, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)

        // Sync finds the original gone from INBOX and a new message in Archive,
        // with the server's state: no mark (Send never reached the server) and
        // the Reply tag.
        let originalId = original.id
        let copy = try await pool.write { db -> MessageHeader in
            _ = try MessageHeader.deleteOne(db, key: originalId)
            var copy = MessageHeader(
                messageId: "9", subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
                snippet: "original",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.archivePath),
                accountId: accountId, folderPath: Self.archivePath, isInInbox: false)
            copy.rfc822MessageId = parentRfc
            copy.headerComplete = true
            copy.observedUidValidity = Self.archiveEpoch
            copy.setActionTag(.reply, at: Date().addingTimeInterval(-3_600))
            try copy.insert(db)
            return copy
        }
        let copyBefore = try Self.rowSnapshot(pool, headerId: copy.id)
        #expect(!copyBefore.isEmpty, "precondition: sync stored the Archive copy")

        switch outcome {
        case .completed:
            let disposition = try await Self.complete(pool: pool, outboxId: queued.outboxId)
            #expect(disposition.changedOriginalHeaderId == nil, "the completion finds no original")
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(
                pool: pool, outboxId: queued.outboxId, failedFirst: outcome == .discardedAfterFailure)
            #expect(cancelled.revertedOriginalHeaderId == nil, "the Undo finds no original")
        }
        let queuedTypes = try Self.markOps(pool).map(\.type.rawValue)
        #expect(queuedTypes.isEmpty, "nothing is queued for the copy: \(queuedTypes)")
        let copyAfter = try Self.rowSnapshot(pool, headerId: copy.id)
        #expect(copyAfter == copyBefore, "\(outcome.rawValue): the copy sync stored is unchanged")
    }

    /// The archive lands on an address sync has already stored a row for: the
    /// re-key's collision arm drops the moved row (with Send's marks) and keeps
    /// the stored one. That row is not the row Send marked, and its numbering is
    /// not proven by this move, so the queued send is not carried to it: the
    /// completion finds no original and changes nothing on it (`IOS-OUTBOX-012`).
    @Test("An archive that lands on a row sync already stored: the send is not carried to it, and its completion changes nothing")
    func originalArchivedOntoAStoredCopy() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-collide")
        try Self.insertArchive(pool, accountId: accountId)
        let parentRfc = "collide-parent@example.com"
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: parentRfc, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)

        // The archive gesture moves the row locally, and sync stores the Archive
        // copy at the address the move will report before the move lands.
        let originalId = original.id
        let archiveFolderId = MessageIdentity.folderId(accountId: accountId, folderPath: Self.archivePath)
        try await Self.moveLocally(pool, headerId: originalId, accountId: accountId, to: Self.archivePath)
        let stored = try await pool.write { db -> MessageHeader in
            var copy = MessageHeader(
                messageId: "9", subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
                snippet: "original", folderId: archiveFolderId,
                accountId: accountId, folderPath: Self.archivePath, isInInbox: false)
            copy.rfc822MessageId = parentRfc
            copy.headerComplete = true
            copy.observedUidValidity = Self.archiveEpoch
            copy.setActionTag(.reply, at: Date().addingTimeInterval(-3_600))
            try copy.insert(db)
            return copy
        }
        let storedBefore = try Self.rowSnapshot(pool, headerId: stored.id)
        let finished = try await Self.landMove(
            pool, accountId: accountId, providerId: original.messageId,
            from: Self.imapPath, to: Self.archivePath, newProviderId: "9", epoch: Self.archiveEpoch)
        #expect(finished.applied.isEmpty, "precondition: the re-key collided")
        #expect(finished.removedOldHeaderIds == [originalId], "precondition: the moved row was dropped: \(finished.removedOldHeaderIds)")
        let outboxId = queued.outboxId
        let pointer = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointer == originalId, "the queued send is not carried to the stored row: \(pointer ?? "nil")")

        let disposition = try await Self.complete(pool: pool, outboxId: outboxId)
        #expect(disposition.changedOriginalHeaderId == nil, "the completion finds no original")
        let queuedTypes = try Self.markOps(pool).map(\.type.rawValue)
        #expect(queuedTypes.isEmpty, "nothing is queued for the stored row: \(queuedTypes)")
        let storedAfter = try Self.rowSnapshot(pool, headerId: stored.id)
        #expect(storedAfter == storedBefore, "the stored row is unchanged")
    }

    /// Sync's re-keys of a row on Message-ID evidence (the UID remap, and the body
    /// backfill's re-key) go through `MessageHeaderRekey.apply` and do not carry
    /// the queued send's pointer. So the completion finds no original and queues
    /// nothing, and an unsent removal finds none either and leaves Send's marks
    /// on the re-keyed row (`IOS-OUTBOX-012`). Only a landed move's proven re-key
    /// (`finishMove`) and a listing's re-key on the provider's own id
    /// (`canonicalizeLocalRows`, below) carry it.
    @Test("Sync's own re-key of a held reply's original does not carry the send to it: the completion finds nothing, and an Undo leaves Send's marks",
          arguments: [Outcome.completed, .undone])
    func syncRekeyDoesNotCarryTheSend(outcome: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-remap")
        let original = try Self.storedOriginal(pool, accountId: accountId, rfc: "remap-parent@example.com", tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)

        let originalId = original.id
        let remappedId = MessageIdentity.headerId(accountId: accountId, folderPath: Self.imapPath, messageId: "58")
        let rekeyed = try await pool.write { db -> Bool in
            guard let row = try MessageHeader.fetchOne(db, key: originalId) else { return false }
            var migrated = row
            migrated.id = remappedId
            migrated.messageId = "58"
            return try MessageHeaderRekey.apply(from: row, to: migrated, db: db)
        }
        #expect(rekeyed, "precondition: sync's re-key moved the row")
        let outboxId = queued.outboxId
        let pointer = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointer == originalId, "the queued send still names the old id: \(pointer ?? "nil")")

        switch outcome {
        case .completed:
            let disposition = try await Self.complete(pool: pool, outboxId: outboxId)
            #expect(disposition.changedOriginalHeaderId == nil, "the completion finds no original")
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(
                pool: pool, outboxId: outboxId, failedFirst: outcome == .discardedAfterFailure)
            #expect(cancelled.revertedOriginalHeaderId == nil, "the Undo finds no original")
            let after = try Self.marks(pool, headerId: remappedId)
            let held = Self.held(before: before, isForward: false)
            #expect(after == held, "Send's marks stay on the re-keyed row (IOS-OUTBOX-012): \(after), want \(held)")
        }
        let queuedTypes = try Self.markOps(pool).map(\.type.rawValue)
        #expect(queuedTypes.isEmpty, "nothing is queued for the re-keyed row: \(queuedTypes)")
    }

    // MARK: - Gmail: the All Mail listing re-keys the archived original

    static let gmailMessageId = "18c0a1b2c3d4e5f6"
    static let gmailOtherMessageId = "18c0a1b2c3d4e5f7"

    /// A listing of `path` reports the message `messageId`, and sync
    /// canonicalizes its local rows as `runSyncMessages` does on a stable-id
    /// provider (no epoch). Returns the re-key it made, if any.
    static func listingCanonicalizes(
        _ pool: DatabasePool, accountId: String, path: String, messageId: String
    ) async throws -> (oldId: String, newId: String)? {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: path)
        return try await pool.write { db in
            try SyncEngine.canonicalizeLocalRows(
                accountId: accountId, folderPath: path, folderId: folderId,
                messageId: messageId, isInInbox: false, windowMode: .date,
                sourceBoundEpoch: nil, incomingRfc822Identity: nil, db: db
            ).ftsRekey
        }
    }

    /// On Gmail an archive does not change the message's address, so the landed
    /// move re-keys nothing and the row keeps its Inbox-shaped key until the next
    /// listing of All Mail re-keys it on Gmail's own id
    /// (`SyncEngine.canonicalizeLocalRows`). The provider's id proves that re-key
    /// (the Message-ID plays no part), so the queued send follows its original
    /// (#1500): the completion marks it at its All Mail address, and an unsent
    /// removal takes Send's marks back from it. A send to another message keeps
    /// its own original.
    @Test("Gmail: an original archived while its reply or forward waits, then re-keyed by the All Mail listing: the send follows it, and an unsent removal takes Send's marks back",
          arguments: [false, true], Outcome.allCases)
    func gmailAllMailRekeyCarriesTheSend(isForward: Bool, outcome: Outcome) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-gmail-rekey", provider: .gmail)
        let allMail = GmailProvider.archivePath
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: allMail, role: .archive, pool: pool)
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "gmail-parent@example.com",
            messageId: Self.gmailMessageId, observed: nil, tag: .reply)
        let other = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "gmail-other@example.com",
            messageId: Self.gmailOtherMessageId, observed: nil, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let otherBefore = try Self.marks(pool, headerId: other.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: isForward, before: before)
        let bystander = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: other, isForward: false, before: otherBefore)
        let outboxId = queued.outboxId

        // The archive moves the row to All Mail and clears its tag; the row keeps its Inbox-shaped key.
        let originalId = original.id
        try await Self.moveLocally(pool, headerId: originalId, accountId: accountId, to: allMail)
        let pointerAfterMove = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointerAfterMove == originalId, "precondition: the archive alone does not re-key the row")

        // The All Mail listing reports the message under Gmail's id and re-keys the row.
        let rekey = try await Self.listingCanonicalizes(
            pool, accountId: accountId, path: allMail, messageId: Self.gmailMessageId)
        let movedId = MessageIdentity.headerId(accountId: accountId, folderPath: allMail, messageId: Self.gmailMessageId)
        let rekeyed = rekey.map { $0.oldId == originalId && $0.newId == movedId } ?? false
        #expect(rekeyed, "precondition: the listing re-keyed the row: \(String(describing: rekey))")
        let pointer = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointer == movedId, "the send follows its original to the All Mail key: \(pointer ?? "nil")")
        let bystanderPointer = try Self.pointer(pool, outboxId: bystander.outboxId)
        #expect(bystanderPointer == other.id, "a reply to another message keeps its original: \(bystanderPointer ?? "nil")")

        let markType = isForward ? OperationType.markForwarded : OperationType.markReplied
        switch outcome {
        case .completed:
            let disposition = try await Self.complete(pool: pool, outboxId: outboxId)
            #expect(disposition.changedOriginalHeaderId == movedId, "the completion finds the re-keyed original")
            let serverMarks = try Self.markOps(pool).filter { $0.type == markType }
            #expect(serverMarks.count == 1, "the completed send queues the server's \(markType.rawValue)")
            guard serverMarks.count == 1 else { return }
            let markIds = serverMarks[0].messageIds
            #expect(markIds == [Self.gmailMessageId], "the server's mark names the message's Gmail id: \(markIds)")
            let markFolder = serverMarks[0].folderPath
            #expect(markFolder == allMail, "the server's mark names All Mail: \(markFolder)")
        case .undone, .discardedAfterFailure:
            let cancelled = try await Self.cancel(
                pool: pool, outboxId: outboxId, failedFirst: outcome == .discardedAfterFailure)
            #expect(cancelled.revertedOriginalHeaderId == movedId, "the removal finds the re-keyed original")
            let serverMarks = try Self.queuedCount(pool, markType)
            #expect(serverMarks == 0, "no server mark for a send that never went out")
        }
        let tags = try Self.queuedTags(pool)
        #expect(tags.isEmpty, "the archive cleared the tag, so there is no clear to queue and no Reply to restore: \(tags)")
        let after = try Self.marks(pool, headerId: movedId)
        var want = Self.expected(before: before, isForward: isForward, outcome: outcome)
        want.actionTag = nil
        #expect(after == want, "\(outcome.rawValue): \(after), want \(want)")

        let bystanderCancelled = try await Self.cancel(pool: pool, outboxId: bystander.outboxId)
        #expect(bystanderCancelled.revertedOriginalHeaderId == other.id, "the other reply's Undo finds its own original")
        let otherAfter = try Self.marks(pool, headerId: other.id)
        #expect(otherAfter == otherBefore, "the other original is as it was: \(otherAfter), want \(otherBefore)")
    }

    /// The listing skips the re-key when another row already holds the All Mail
    /// key (a row moved out of All Mail keeps its key). The archived row then
    /// keeps its own key, so the send must keep naming it: the Undo takes Send's
    /// mark back from that row and leaves the row holding the key as it was.
    @Test("Gmail: a listing that skips the re-key because another row holds the All Mail key leaves the send naming its original")
    func gmailSkippedRekeyKeepsTheSend() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = try Self.localAccount(pool, prefix: "marks-gmail-skip", provider: .gmail)
        let allMail = GmailProvider.archivePath
        let trash = "TRASH"
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: allMail, role: .archive, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: trash, role: .trash, pool: pool)
        let original = try Self.storedOriginal(
            pool, accountId: accountId, rfc: "gmail-skip-parent@example.com",
            messageId: Self.gmailMessageId, observed: nil, tag: .reply)
        let before = try Self.marks(pool, headerId: original.id)
        let queued = try await Self.queueAndCheckHeld(
            pool: pool, accountId: accountId, original: original, isForward: false, before: before)
        let outboxId = queued.outboxId

        // A row in Trash holds the All Mail key: it was moved out of All Mail and kept its key.
        let allMailKey = MessageIdentity.headerId(accountId: accountId, folderPath: allMail, messageId: Self.gmailMessageId)
        try await pool.write { db in
            var holder = MessageHeader(
                messageId: Self.gmailMessageId, subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
                snippet: "original",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: trash),
                accountId: accountId, folderPath: trash, isInInbox: false)
            holder.id = allMailKey
            holder.rfc822MessageId = "gmail-skip-parent@example.com"
            holder.headerComplete = true
            try holder.insert(db)
        }
        let holderBefore = try Self.rowSnapshot(pool, headerId: allMailKey)
        #expect(!holderBefore.isEmpty, "precondition: the All Mail key is held")

        let originalId = original.id
        try await Self.moveLocally(pool, headerId: originalId, accountId: accountId, to: allMail)
        let rekey = try await Self.listingCanonicalizes(
            pool, accountId: accountId, path: allMail, messageId: Self.gmailMessageId)
        #expect(rekey == nil, "precondition: the listing skipped the re-key: \(String(describing: rekey))")
        let pointer = try Self.pointer(pool, outboxId: outboxId)
        #expect(pointer == originalId, "the send keeps naming the row that kept its key: \(pointer ?? "nil")")

        let cancelled = try await Self.cancel(pool: pool, outboxId: outboxId)
        #expect(cancelled.revertedOriginalHeaderId == originalId, "the Undo finds the archived original")
        let after = try Self.marks(pool, headerId: originalId)
        let want = Marks(isReplied: false, isForwarded: false, actionTag: nil)
        #expect(after == want, "the Undo takes Send's mark back; the archive cleared the tag: \(after), want \(want)")
        let holderAfter = try Self.rowSnapshot(pool, headerId: allMailKey)
        #expect(holderAfter == holderBefore, "the row holding the All Mail key is unchanged")
    }
}
