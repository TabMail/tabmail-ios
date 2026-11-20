/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

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
/// `PendingSendService.present` and `undo()` (what the toast's Undo button
/// calls, synchronously), `UndoReopenCompose.composeView(for:)`, and the close
/// decision's own functions (`ComposeDraftGuards.baseline`, `.hasChanges`,
/// `.hasContent`, `.closeAction`).
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
    /// row and its Undo toast. Returns the Outbox row's id.
    private func send(_ fixture: Fixture, _ sent: Draft, cursor: ComposeGenerationCursor) async throws -> String {
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
            toSummary: "To: recipient@example.com", holdUntil: held.holdUntil)
        return held.id
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
    /// without typing: its fields are exactly the kept row.
    private func closeWithoutTyping(
        _ compose: ComposeView, loaded: Draft
    ) -> ComposeDraftGuards.CloseAction {
        let current = ComposeDraftGuards.Baseline(
            subject: loaded.subject, body: loaded.body,
            to: loaded.toArray, cc: loaded.ccArray, bcc: loaded.bccArray,
            attachmentsFingerprint: [])
        let baseline = ComposeDraftGuards.baseline(
            afterLoading: current, treatAsUnsavedChanges: compose.prefillTreatAsUnsavedChanges)
        return ComposeDraftGuards.closeAction(
            readState: .loaded,
            hasContent: ComposeDraftGuards.hasContent(
                subject: loaded.subject, body: loaded.body,
                to: loaded.toArray, cc: loaded.ccArray, bcc: loaded.bccArray,
                toInput: "", ccInput: "", bccInput: "", hasAttachments: false),
            hasChanges: ComposeDraftGuards.hasChanges(current: current, baseline: baseline))
    }

    // MARK: - The confirmed Undo returns the message to Drafts

    @Test("Undo of a message never saved to the server puts it in Drafts and queues the server copy, and Close just closes")
    func undoReturnsNeverSavedMessageToDrafts() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Here are the numbers for next quarter."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let outboxId = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor)

        let snapshot = try #require(PendingSendService.shared.undo(), "the Undo was not confirmed")

        #expect(try await outboxRow(fixture, outboxId) == nil)
        #expect(snapshot.returnedToDrafts)
        #expect(try await row(fixture, draftId).instanceEpoch == cursor.newEpoch,
                "the return to Drafts must keep the row's generation")
        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: words)
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

        let snapshot = try #require(PendingSendService.shared.undo(), "the Undo was not confirmed")
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

        #expect(PendingSendService.shared.undo() != nil)
        #expect(PendingSendService.shared.undo() == nil)

        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: words)
        #expect(try await serverSaves(fixture, draftId).count == 1)
    }

    // MARK: - A failed return keeps the words reachable

    @Test("If the return to Drafts fails, the Undo still stands and Close asks to save the message")
    func failedReturnOpensUnsavedAndCloseAsksToSave() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Words that must not be lost."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let outboxId = try await send(fixture, draft(draftId, fixture, body: words), cursor: cursor)
        let before = try await row(fixture, draftId)
        // The admission's server save cannot be written.
        try await fixture.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_draft_save BEFORE INSERT ON pendingOperation
                BEGIN SELECT RAISE(ABORT, 'refused for the test'); END
                """)
        }

        let snapshot = try #require(PendingSendService.shared.undo(), "the cancellation must still stand")

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

        let snapshot = PendingSendService.shared.undo()
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

    @Test("A compose opened as unsaved asks to save unchanged content; one opened as saved closes")
    func unsavedBaselineDrivesTheClosePrompt() {
        let loaded = ComposeDraftGuards.Baseline(
            subject: "Quarterly plan", body: "Words.", to: ["recipient@example.com"], cc: [], bcc: [],
            attachmentsFingerprint: [])
        for (unsaved, expected) in [(true, ComposeDraftGuards.CloseAction.promptSave), (false, .dismiss)] {
            let baseline = ComposeDraftGuards.baseline(afterLoading: loaded, treatAsUnsavedChanges: unsaved)
            let action = ComposeDraftGuards.closeAction(
                readState: .loaded, hasContent: true,
                hasChanges: ComposeDraftGuards.hasChanges(current: loaded, baseline: baseline))
            #expect(action == expected, "treatAsUnsavedChanges: \(unsaved)")
        }
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
    // MARK: - The compose applies the flag where it records its baseline

    /// Source fence on the one call that turns the reopen flag into the close
    /// decision: `ComposeView.snapshotInitialState` must pass the compose's own
    /// `prefillTreatAsUnsavedChanges` to `ComposeDraftGuards.baseline`, so a
    /// failed return opens with unsaved changes and Close asks to save.
    /// The decision that baseline feeds is tested below against the real Undo.
    @Test("The compose records its baseline with its own unsaved-changes flag")
    func composeBaselineUsesTheReopenFlag() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: projectRoot
            .appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func snapshotInitialState() {"))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "private func currentBaseline()"))
        let body = tail[..<end.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(body.contains(
            "initialBaseline = ComposeDraftGuards.baseline( afterLoading: currentBaseline(), treatAsUnsavedChanges: prefillTreatAsUnsavedChanges)"),
            "snapshotInitialState reads: \(body)")
        #expect(source.contains("ComposeDraftGuards.hasChanges(current: currentBaseline(), baseline: initialBaseline)"),
                "hasChanges must compare against the recorded baseline")
        // Both load outcomes record the baseline through that function: the
        // loaded-row branch, and the prefill branch when no row is found.
        let loadedBranch = try #require(source.range(of: "[ComposeView] Loaded draft: id="))
        let afterLoaded = source[loadedBranch.upperBound...]
        let loadedReturn = try #require(afterLoaded.range(of: "return"))
        #expect(afterLoaded[..<loadedReturn.lowerBound].contains("snapshotInitialState()"),
                "the loaded-row branch must record its baseline with snapshotInitialState()")
        // The prefill branch calls `prepopulate()`, which records it at its end.
        let prefill = try #require(source.range(of: "private func prepopulate() {"))
        let afterPrefill = source[prefill.upperBound...]
        let prefillEnd = try #require(afterPrefill.range(of: "\n    }\n"))
        #expect(afterPrefill[..<prefillEnd.lowerBound].contains("snapshotInitialState()"),
                "prepopulate() must record its baseline with snapshotInitialState()")
        let assignments = source.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("initialBaseline = ") }.count
        #expect(assignments == 1, "only snapshotInitialState may set the baseline, found \(assignments)")
    }

    // MARK: - The decision Close reads, after the real Undo

    /// Close compares the compose's fields with the baseline it recorded on
    /// loading (`ComposeDraftGuards.hasChanges`). After the real Undo, with the
    /// compose the Undo reopens and the row it loads: a failed return (the
    /// savepoint refused) reports changes, so Close asks to save; a return that
    /// landed reports none, so Close just closes.
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
        let snapshot = try #require(PendingSendService.shared.undo(), "the Undo was not confirmed")
        try #require(snapshot.returnedToDrafts == returned,
                     "precondition: the return \(returned ? "landed" : "failed")")

        let compose = UndoReopenCompose.composeView(for: snapshot)
        let loaded = try await row(fixture, draftId)
        let fields = ComposeDraftGuards.Baseline(
            subject: loaded.subject, body: loaded.body,
            to: loaded.toArray, cc: loaded.ccArray, bcc: loaded.bccArray,
            attachmentsFingerprint: [])
        let baseline = ComposeDraftGuards.baseline(
            afterLoading: fields, treatAsUnsavedChanges: compose.prefillTreatAsUnsavedChanges)
        let changes = ComposeDraftGuards.hasChanges(current: fields, baseline: baseline)
        let decision = closeWithoutTyping(compose, loaded: loaded)
        if returned {
            #expect(compose.prefillTreatAsUnsavedChanges == false)
            #expect(changes == false)
            #expect(decision == .dismiss)
        } else {
            #expect(compose.prefillTreatAsUnsavedChanges == true)
            #expect(changes == true)
            #expect(decision == .promptSave)
        }
    }
}
