/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Where the user taps Undo: the undo-send toast, or the chat's Sending bubble. Both run
/// `PendingSendService.undoAndReopen`, so both must return the message to Drafts the same way.
enum UndoSendPresenterTap: String, Sendable {
    case toast
    case bubble

    /// The presenter the send's Undo belongs to, given at Send.
    var owner: PendingSendService.UndoOwner { self == .toast ? .toast : .bubble }
}

/// After Undo Send, Close without typing never drops the words (ADR-IOS-065, as
/// superseded on v3). The confirmed Undo returns the message to Drafts in the
/// cancellation's own write: a Drafts entry and a queued server save exist at
/// once, with no further gesture. If that return fails, the cancellation still
/// stands and the reopened compose holds the message as unsaved, so Close asks
/// to save it. No committed state has the Outbox row gone with the return
/// half-written.
///
/// Production throughout: the row write Send makes (`DraftStore.saveAsync`
/// through a `ComposeGenerationCursor`), the real held Outbox row,
/// `PendingSendService.present` and `undoAndReopen()` (what the toast's Undo
/// button calls, synchronously; through `tapToastUndo()`, which returns the
/// compose it queued to reopen), the chat's Sending bubble's Undo
/// (`ChatUnsentReply.undo()`, the same path with the bubble's own row),
/// `UndoReopenCompose.composeView(for:)`, and the close decision Close calls
/// (`ComposeDraftGuards.closeDecision`, with `.hasContent`).
///
/// `.serialized` + `.processGlobalState`: rebinds `AppDatabase.shared` and uses
/// `PendingSendService.shared`. example.com addresses only; every instant
/// derives from `Date()`.
@Suite("Undo Send returns the message to Drafts", .serialized, .processGlobalState)
@MainActor
struct UndoSendReturnsToDraftsTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        var draftsFolderId: String { "\(accountId):Drafts" }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let accountId = "undo-drafts-\(UUID().uuidString)"
        try pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            account.id = accountId
            try account.insert(db)
            var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: accountId)
            drafts.lastKnownUidValidity = 1
            try drafts.insert(db)
        }
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    private func finish(_ fixture: Fixture) {
        PendingSendService.shared.dismiss()
        PendingSendService.shared.dismissUndoFailure()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func draft(_ id: String, _ fixture: Fixture, body: String) -> Draft {
        let now = Date().timeIntervalSince1970
        return Draft(
            id: id, accountId: fixture.accountId,
            toJSON: Draft.encodeStringArray(["recipient@example.com"]),
            ccJSON: Draft.encodeStringArray([]), bccJSON: Draft.encodeStringArray([]),
            subject: "Quarterly plan", body: body,
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft {
        try #require(try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) })
    }

    /// Send: the row written through the compose's cursor, then the held Outbox
    /// row and its Undo on `owner` (the toast unless given). Returns the Outbox row's id.
    private func send(
        _ fixture: Fixture, _ sent: Draft, cursor: ComposeGenerationCursor,
        owner: PendingSendService.UndoOwner = .toast
    ) async throws -> String {
        _ = try await cursor.admit { epoch, predecessor in
            try await DraftStore.shared.saveAsync(sent, epoch: epoch, expectedPredecessor: predecessor)
        }
        var outbox = OutboxMessage(
            accountId: fixture.accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: sent.subject, body: sent.body))
        outbox.draftId = sent.id
        outbox.instanceEpoch = cursor.newEpoch
        outbox.holdUntil = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds)
        let held = outbox
        try await fixture.pool.write { db in try held.insert(db) }
        PendingSendService.shared.present(
            outboxId: held.id, draftId: sent.id, instanceEpoch: cursor.newEpoch,
            toSummary: "To: recipient@example.com", holdUntil: held.holdUntil, owner: owner)
        return held.id
    }

    /// The user's Undo on `tap`'s presenter; returns the compose it queued to reopen, or nil.
    /// The toast's is `tapToastUndo()`. The bubble's is `ChatUnsentReply.undo()` on the held row,
    /// built from its columns as `ChatUnsentReply.fetch` builds it, with the reopen queue emptied
    /// before and after as `tapToastUndo()` does.
    private func tapUndo(
        _ tap: UndoSendPresenterTap, _ fixture: Fixture, outboxId: String
    ) async throws -> PendingSendService.ReopenSnapshot? {
        let service = PendingSendService.shared
        switch tap {
        case .toast:
            return service.tapToastUndo()
        case .bubble:
            let row = try await outboxRow(fixture, outboxId)
            let held = try #require(row, "control: the send is held")
            let bubble = ChatUnsentReply(
                outboxId: held.id, status: held.outboxStatus, sentAt: held.sentAt, holdUntil: held.holdUntil,
                draftId: held.draftId, instanceEpoch: held.instanceEpoch, filed: false, textMessage: nil)
            while service.reopenSnapshot != nil { service.finishReopen() }
            bubble.undo()
            let snapshot = service.reopenSnapshot
            while service.reopenSnapshot != nil { service.finishReopen() }
            return snapshot
        }
    }

    private func outboxRow(_ fixture: Fixture, _ id: String) async throws -> OutboxMessage? {
        try await fixture.pool.read { db in try OutboxMessage.fetchOne(db, key: id) }
    }

    /// Every header in the Drafts folder, native or placeholder, with its body.
    private func allDraftsEntries(_ fixture: Fixture) async throws -> [(MessageHeader, MessageBody?)] {
        try await fixture.pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == fixture.draftsFolderId)
                .fetchAll(db)
                .map { header in (header, try MessageBody.filter(Column("id") == header.id).fetchOne(db)) }
        }
    }

    private func serverSaves(_ fixture: Fixture, _ draftId: String) async throws -> [PendingOperation] {
        try await fixture.pool.read { db in
            try PendingOperation.fetchAll(db).filter { $0.draftId == draftId && $0.type == .saveDraft }
        }
    }

    /// The message is in exactly one Drafts entry with `words`, and a server save
    /// of the row, which holds `words` and is pushable, is queued.
    private func expectInDraftsAndQueuedForServer(
        _ fixture: Fixture, draftId: String, words: String
    ) async throws {
        let saved = try await row(fixture, draftId)
        #expect(saved.body == words)
        #expect(saved.serverPushStatus == nil || saved.serverPushStatus == "dirty",
                "the row must be pushable, got \(saved.serverPushStatus ?? "nil")")
        let entries = try await allDraftsEntries(fixture)
        #expect(entries.count == 1, "expected one Drafts entry, got \(entries.count)")
        guard entries.count == 1 else { return }
        #expect(entries[0].0.snippet.contains(words))
        #expect(entries[0].1?.htmlContent?.contains(words) == true)
        let saves = try await serverSaves(fixture, draftId)
        #expect(!saves.isEmpty, "no server save queued for the message")
        #expect(saves.allSatisfy { $0.instanceEpoch == saved.instanceEpoch })
    }

    /// The close decision the reopened compose makes when the user closes it
    /// without typing: what it loaded and what it holds are the kept row.
    private func closeWithoutTyping(
        _ compose: ComposeView, loaded: Draft
    ) -> ComposeDraftGuards.CloseAction {
        let fields = ComposeDraftGuards.Baseline(
            subject: loaded.subject, body: loaded.body,
            to: loaded.toArray, cc: loaded.ccArray, bcc: loaded.bccArray,
            attachmentsFingerprint: [])
        return ComposeDraftGuards.closeDecision(ComposeDraftGuards.CloseState(
            readState: .loaded, loaded: fields, current: fields,
            loadedIsUnsaved: compose.prefillTreatAsUnsavedChanges,
            hasContent: ComposeDraftGuards.hasContent(
                subject: loaded.subject, body: loaded.body,
                to: loaded.toArray, cc: loaded.ccArray, bcc: loaded.bccArray,
                toInput: "", ccInput: "", bccInput: "", hasAttachments: false),
            hasUnsettledWork: false))
    }

    // MARK: - The confirmed Undo returns the message to Drafts

    @Test("Undo of a message never saved to the server, from the toast or the chat's Sending bubble, puts it in Drafts and queues the server copy, and Close just closes",
          arguments: [UndoSendPresenterTap.toast, .bubble])
    func undoReturnsNeverSavedMessageToDrafts(tap: UndoSendPresenterTap) async throws {
        let fixture = try makeFixture()
        defer {
            PendingSendService.shared.resetUndoOwnersForTesting()
            finish(fixture)
        }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Here are the numbers for next quarter."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let outboxId = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor, owner: tap.owner)

        let undone = try await tapUndo(tap, fixture, outboxId: outboxId)
        let snapshot = try #require(undone, "the Undo was not confirmed")

        #expect(try await outboxRow(fixture, outboxId) == nil)
        #expect(snapshot.returnedToDrafts)
        #expect(try await row(fixture, draftId).instanceEpoch == cursor.newEpoch,
                "the return to Drafts must keep the row's generation")
        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: words)
        let saves = try await serverSaves(fixture, draftId)
        #expect(saves.count == 1, "one server save, got \(saves.count)")
        let compose = UndoReopenCompose.composeView(for: snapshot)
        #expect(closeWithoutTyping(compose, loaded: try await row(fixture, draftId)) == .dismiss)
    }

    @Test("Undo of a draft saved to the server before Send gives its Drafts entry and server save the words that were sent")
    func undoGivesTheSentWordsToAnEarlierSavedDraft() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let older = "First version of the plan."
        let latest = "Final version of the plan, with the new dates."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)

        // Saved to Drafts before Send, through the normal save.
        let first = draft(draftId, fixture, body: older)
        _ = try await cursor.admit { epoch, predecessor in
            try await DraftStore.shared.saveAsync(first, epoch: epoch, expectedPredecessor: predecessor)
        }
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: fixture.accountId))

        // Edited, then sent.
        var sent = draft(draftId, fixture, body: latest)
        sent.updatedAt = max(sent.updatedAt, try await row(fixture, draftId).updatedAt) + 1
        _ = try await send(fixture, sent, cursor: cursor)

        let snapshot = try #require(PendingSendService.shared.tapToastUndo(), "the Undo was not confirmed")
        #expect(snapshot.returnedToDrafts)
        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: latest)
    }

    @Test("A second Undo tap changes nothing: one Drafts entry, one server save")
    func doubleTapReturnsOnce() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "One copy only."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        _ = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor)

        #expect(PendingSendService.shared.tapToastUndo() != nil)
        #expect(PendingSendService.shared.tapToastUndo() == nil)

        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: words)
        #expect(try await serverSaves(fixture, draftId).count == 1)
    }

    // MARK: - A failed return keeps the words reachable

    @Test("If the return to Drafts fails, the Undo from the toast or the chat's Sending bubble still stands and Close asks to save the message",
          arguments: [UndoSendPresenterTap.toast, .bubble])
    func failedReturnOpensUnsavedAndCloseAsksToSave(tap: UndoSendPresenterTap) async throws {
        let fixture = try makeFixture()
        defer {
            PendingSendService.shared.resetUndoOwnersForTesting()
            finish(fixture)
        }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Words that must not be lost."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let outboxId = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor, owner: tap.owner)
        let before = try await row(fixture, draftId)
        // The admission's server save cannot be written.
        try await fixture.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_draft_save BEFORE INSERT ON pendingOperation
                BEGIN SELECT RAISE(ABORT, 'refused for the test'); END
                """)
        }

        let undone = try await tapUndo(tap, fixture, outboxId: outboxId)
        let snapshot = try #require(undone, "the cancellation must still stand")

        #expect(!snapshot.returnedToDrafts)
        #expect(try await outboxRow(fixture, outboxId) == nil)
        let after = try await row(fixture, draftId)
        #expect(after.body == words)
        #expect(after.instanceEpoch == before.instanceEpoch)
        #expect(after.updatedAt == before.updatedAt, "the failed save must roll back whole")
        #expect(try await allDraftsEntries(fixture).isEmpty, "a half-written Drafts entry remained")
        let compose = UndoReopenCompose.composeView(for: snapshot)
        #expect(compose.prefillTreatAsUnsavedChanges)
        #expect(closeWithoutTyping(compose, loaded: after) == .promptSave,
                "Close without typing would drop the words")
    }

    @Test("An Undo whose write does not commit changes nothing: the Send stays, no Drafts entry, no server save")
    func uncommittedUndoIsAllOrNothing() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let outboxId = try await send(fixture, draft(draftId, fixture, body: "Still queued."), cursor: cursor)
        let before = try await row(fixture, draftId)
        // The process ends before the write commits: the commit is refused after
        // the cancellation and the return to Drafts both ran inside it.
        let refuser = CommitRefuser()
        fixture.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        let snapshot = PendingSendService.shared.tapToastUndo()
        fixture.pool.remove(transactionObserver: refuser)

        #expect(snapshot == nil)
        #expect(refuser.refusals.withLock { $0 } == 1)
        #expect(refuser.sawDraftsWrite.withLock { $0 }, "the return to Drafts did not run inside the write")
        #expect(try await outboxRow(fixture, outboxId) != nil, "the Send must still be held")
        #expect(try await allDraftsEntries(fixture).isEmpty)
        #expect(try await serverSaves(fixture, draftId).isEmpty)
        #expect(try await row(fixture, draftId).updatedAt == before.updatedAt)
    }

    /// Refuses the commit of a write that deletes an Outbox row, recording
    /// whether that same write also wrote a Drafts header.
    private final class CommitRefuser: TransactionObserver, Sendable {
        struct Refused: Error {}
        private let deletingOutbox = Mutex(false)
        let sawDraftsWrite = Mutex(false)
        let refusals = Mutex(0)
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            switch eventKind {
            case .delete(let table): return table == OutboxMessage.databaseTableName
            case .insert(let table): return table == MessageHeader.databaseTableName
            default: return false
            }
        }
        func databaseDidChange(with event: DatabaseEvent) {
            if event.tableName == OutboxMessage.databaseTableName {
                deletingOutbox.withLock { $0 = true }
            } else {
                sawDraftsWrite.withLock { $0 = true }
            }
        }
        func databaseWillCommit() throws {
            if deletingOutbox.withLock({ $0 }) {
                refusals.withLock { $0 += 1 }
                throw Refused()
            }
        }
        func databaseDidCommit(_ db: Database) { deletingOutbox.withLock { $0 = false } }
        func databaseDidRollback(_ db: Database) { deletingOutbox.withLock { $0 = false } }
    }

    // MARK: - The close decision behind a failed return

    private static let loadedFields = ComposeDraftGuards.Baseline(
        subject: "Quarterly plan", body: "Words.", to: ["recipient@example.com"], cc: [], bcc: [],
        attachmentsFingerprint: [])

    private static func close(
        current: ComposeDraftGuards.Baseline, loadedIsUnsaved: Bool,
        readState: ComposeDraftGuards.ReadState = .loaded, hasContent: Bool = true,
        hasUnsettledWork: Bool = false
    ) -> ComposeDraftGuards.CloseAction {
        ComposeDraftGuards.closeDecision(ComposeDraftGuards.CloseState(
            readState: readState, loaded: loadedFields, current: current,
            loadedIsUnsaved: loadedIsUnsaved, hasContent: hasContent, hasUnsettledWork: hasUnsettledWork))
    }

    @Test("Close of a compose emptied to nothing asks before deleting a loaded draft and deletes a new one")
    func closeOfEmptiedCompose() {
        #expect(Self.close(current: .empty, loadedIsUnsaved: false, hasContent: false) == .promptDelete)
        #expect(Self.close(current: .empty, loadedIsUnsaved: false, readState: .notFound, hasContent: false)
                == .deleteThenDismiss)
    }

    @Test("Close of loaded content left unchanged asks to save only when the content is unsaved")
    func closeOfUnchangedContentFollowsTheUnsavedFlag() {
        #expect(Self.close(current: Self.loadedFields, loadedIsUnsaved: true) == .promptSave)
        #expect(Self.close(current: Self.loadedFields, loadedIsUnsaved: false) == .dismiss)
    }

    @Test("Close compares against what was loaded: an edit asks to save, unchanged content closes")
    func closeComparesAgainstTheLoadedContent() {
        var edited = Self.loadedFields
        edited.body = "Words, edited."
        #expect(Self.close(current: edited, loadedIsUnsaved: false) == .promptSave)
        #expect(Self.close(current: edited, loadedIsUnsaved: true) == .promptSave)
        #expect(Self.close(current: Self.loadedFields, loadedIsUnsaved: false, hasUnsettledWork: true) == .promptSave)
        #expect(Self.close(current: Self.loadedFields, loadedIsUnsaved: true, readState: .error) == .promptDiscardEdits)
        #expect(Self.close(current: Self.loadedFields, loadedIsUnsaved: false, readState: .error) == .dismiss)
    }

    @Test("The reopened compose opens as unsaved exactly when the return to Drafts failed")
    func reopenFlagFollowsTheReturn() {
        let authority = PendingSendService.RetainedDraftAuthority(
            draftId: "draft-\(UUID().uuidString)", accountId: "account-\(UUID().uuidString)",
            instanceEpoch: UUID().uuidString)
        for returned in [true, false] {
            let compose = UndoReopenCompose.composeView(for: PendingSendService.ReopenSnapshot(
                id: "outbox-\(UUID().uuidString)", authority: authority, returnedToDrafts: returned))
            #expect(compose.prefillTreatAsUnsavedChanges == !returned)
            #expect(compose.retainedDraftAuthority == authority)
        }
    }
    // MARK: - Close is wired to the decision

    /// Source fence on the wiring only: the compose's Close hands the decision
    /// its recorded load, its current fields and its own unsaved-content flag,
    /// and the load is recorded from the fields. The decision itself is tested
    /// above by behaviour.
    @Test("The compose's Close calls the close decision with its own state")
    func closeCallsTheDecision() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: projectRoot
            .appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func closeCompose() async {"))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = tail[..<end.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for wiring in [
            "switch ComposeDraftGuards.closeDecision(ComposeDraftGuards.CloseState(",
            "loaded: loadedBaseline,",
            "current: currentBaseline(),",
            "loadedIsUnsaved: prefillTreatAsUnsavedChanges,",
            "readState: draftReadState,",
            "hasContent: hasContent,",
            "hasUnsettledWork: attachmentPreparationIsUnsettled || hasVisibleSuggestion",
        ] {
            #expect(body.contains(wiring), "closeCompose() lacks `\(wiring)`")
        }
        let record = try #require(source.range(of: "private func snapshotInitialState() {"))
        let recordBody = source[record.upperBound...].prefix(200)
        #expect(recordBody.contains("loadedBaseline = currentBaseline()"),
                "snapshotInitialState() must record the loaded fields")
    }

    // MARK: - The decision Close reads, after the real Undo

    /// After the real Undo, with the compose the Undo reopens and the row it
    /// loads, closed without typing: a failed return (the savepoint refused)
    /// asks to save; a return that landed just closes.
    @Test("After a failed return the reopened compose reports changes and Close asks to save; after a return that landed it reports none",
          arguments: [true, false])
    func closeDecisionFollowsTheReturn(returned: Bool) async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Words the reopened compose shows."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        _ = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor)
        if !returned {
            try await fixture.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER refuse_draft_save BEFORE INSERT ON pendingOperation
                    BEGIN SELECT RAISE(ABORT, 'refused for the test'); END
                    """)
            }
        }
        let snapshot = try #require(PendingSendService.shared.tapToastUndo(), "the Undo was not confirmed")
        try #require(snapshot.returnedToDrafts == returned,
                     "precondition: the return \(returned ? "landed" : "failed")")

        let compose = UndoReopenCompose.composeView(for: snapshot)
        let decision = closeWithoutTyping(compose, loaded: try await row(fixture, draftId))
        if returned {
            #expect(decision == .dismiss)
        } else {
            #expect(decision == .promptSave)
        }
    }
}
