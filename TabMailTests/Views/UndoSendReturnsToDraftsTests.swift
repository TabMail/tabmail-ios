/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A confirmed Undo Send returns the message to Drafts at once (ADR-IOS-065, as
/// superseded on v3): with no further gesture the words are in a Drafts entry
/// and a server save of them is queued, and a copy saved to the server before
/// Send gets the words that were sent. The reopened compose then edits that
/// same draft, with no second Drafts entry.
///
/// Runs production throughout: the row write Send makes (`DraftStore.saveAsync`
/// through a `ComposeGenerationCursor`), the real Outbox row and
/// `PendingSendService.present` / `undoAndReturnToDrafts` (the entry the Undo
/// button calls), `UndoReopenCompose.composeView(for:)`, and the compose's own
/// save (cursor from the loaded row, `saveAsync`, `queueDraftSave`). Assertions
/// are on what the user can reach, never on the route.
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
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func draft(_ id: String, _ fixture: Fixture, body: String, updatedAt: Double) -> Draft {
        Draft(
            id: id, accountId: fixture.accountId,
            toJSON: Draft.encodeStringArray(["recipient@example.com"]),
            ccJSON: Draft.encodeStringArray([]), bccJSON: Draft.encodeStringArray([]),
            subject: "Quarterly plan", body: body,
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: updatedAt, updatedAt: updatedAt)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft {
        try #require(try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) })
    }

    /// Send: the row written through the compose's cursor, then the held Outbox
    /// row and its Undo toast. Then Undo, as the button does.
    private func sendThenUndo(
        _ fixture: Fixture, _ sent: Draft, cursor: ComposeGenerationCursor
    ) async throws -> PendingSendService.ReopenSnapshot {
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
        let snapshot = try #require(await PendingSendService.shared.undoAndReturnToDrafts(),
                                    "precondition: the Undo was confirmed")
        let outboxLeft = try await fixture.pool.read { db in try OutboxMessage.fetchOne(db, key: held.id) }
        try #require(outboxLeft == nil, "precondition: the Outbox row is gone")
        return snapshot
    }

    /// Every Drafts-folder entry for the draft, with its body.
    private func draftsEntries(_ fixture: Fixture, draftId: String) async throws -> [(MessageHeader, MessageBody?)] {
        let bare = PendingOperation.draftPlaceholderMessageId(draftId: draftId, instanceEpoch: nil)
        return try await fixture.pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == fixture.draftsFolderId)
                .fetchAll(db)
                .filter { $0.messageId.hasPrefix(bare) }
                .map { header in
                    (header, try MessageBody.filter(Column("id") == header.id).fetchOne(db))
                }
        }
    }

    /// The message is in Drafts with `words` (one entry), and a server save of
    /// the row, which holds `words` and is pushable, is queued.
    private func expectInDraftsAndQueuedForServer(
        _ fixture: Fixture, draftId: String, words: String
    ) async throws {
        let saved = try await row(fixture, draftId)
        #expect(saved.body == words)
        #expect(saved.serverPushStatus == nil || saved.serverPushStatus == "dirty",
                "the row must be pushable, got \(saved.serverPushStatus ?? "nil")")
        let entries = try await draftsEntries(fixture, draftId: draftId)
        #expect(entries.count == 1, "expected one Drafts entry, got \(entries.count)")
        guard entries.count == 1 else { return }
        #expect(entries[0].0.snippet.contains(words))
        #expect(entries[0].1?.htmlContent?.contains(words) == true)
        let serverSaves = try await fixture.pool.read { db in
            try PendingOperation.fetchAll(db).filter { $0.draftId == draftId && $0.type == .saveDraft }
        }
        #expect(!serverSaves.isEmpty, "no server save queued for the message")
        #expect(serverSaves.allSatisfy { $0.instanceEpoch == saved.instanceEpoch })
    }

    @Test("After a confirmed Undo, a message never saved to the server is in Drafts and queued for the server")
    func neverSavedMessageReturnsToDrafts() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let words = "Here are the numbers for next quarter."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        _ = try await sendThenUndo(
            fixture, draft(draftId, fixture, body: words, updatedAt: Date().timeIntervalSince1970),
            cursor: cursor)
        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: words)
    }

    @Test("After a confirmed Undo, a copy saved to the server before Send gets the words that were sent")
    func serverCopyGetsLatestWords() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let older = "First version of the plan."
        let latest = "Final version of the plan, with the new dates."
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let start = Date().timeIntervalSince1970

        // Saved and pushed before Send: a Drafts entry and a server copy of `older`.
        let first = draft(draftId, fixture, body: older, updatedAt: start)
        _ = try await cursor.admit { epoch, predecessor in
            try await DraftStore.shared.saveAsync(first, epoch: epoch, expectedPredecessor: predecessor)
        }
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: fixture.accountId))
        try await fixture.pool.write { db in
            try PendingOperation.filter(Column("draftId") == draftId).deleteAll(db)
            try db.execute(
                sql: "UPDATE draft SET serverPushStatus = 'pushed', serverDraftId = ? WHERE id = ?",
                arguments: ["server-copy-1", draftId])
        }

        // Edited, then sent: Send writes `latest`, keeping the server linkage.
        var sent = draft(draftId, fixture, body: latest, updatedAt: start + 1)
        sent.serverDraftId = "server-copy-1"
        sent.serverPushStatus = "pushed"
        _ = try await sendThenUndo(fixture, sent, cursor: cursor)

        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: latest)
        #expect(try await row(fixture, draftId).serverDraftId == "server-copy-1",
                "the save must update the existing server copy")
    }

    @Test("The compose reopened by Undo edits that same draft, with no second Drafts entry")
    func reopenedComposeEditsTheSameDraft() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draftId = "draft-\(UUID().uuidString)"
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        let snapshot = try await sendThenUndo(
            fixture,
            draft(draftId, fixture, body: "Sent words.", updatedAt: Date().timeIntervalSince1970),
            cursor: cursor)

        // The reopened compose binds the kept row and builds its cursor from it,
        // as its loader does; the user edits and saves.
        let compose = UndoReopenCompose.composeView(for: snapshot)
        let loaded = try await row(fixture, draftId)
        #expect(compose.retainedDraftAuthority?.matches(loaded) == true)
        #expect(compose.prefillDraftId == draftId)
        let observed = loaded.instanceEpoch.flatMap { $0.isEmpty ? nil : $0 }
        let composeCursor = ComposeGenerationCursor(
            newEpoch: observed ?? UUID().uuidString, initialExpectedPredecessor: observed)
        var edited = loaded
        edited.body = "Edited after Undo."
        edited.updatedAt = max(loaded.updatedAt, Date().timeIntervalSince1970) + 1
        let editedSnapshot = edited
        let result = try await composeCursor.admit { epoch, predecessor in
            try await DraftStore.shared.saveAsync(editedSnapshot, epoch: epoch, expectedPredecessor: predecessor)
        }
        #expect(result == .applied)
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: fixture.accountId))

        try await expectInDraftsAndQueuedForServer(fixture, draftId: draftId, words: "Edited after Undo.")
    }
}
