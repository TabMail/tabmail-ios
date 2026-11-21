/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// What `AccountManager.queueDraftSave` and
/// `AccountManager.discardOutboxMessageConfirmed` do, pinned before their
/// database writes were split out to be shared with the confirmed Undo Send.
/// The same assertions must hold before and after that split.
///
/// `.serialized` + `.processGlobalState`: rebinds `AppDatabase.shared`.
/// example.com addresses only; every instant derives from `Date()`.
@Suite("Drafts admission and Outbox cancellation behaviour", .serialized, .processGlobalState)
struct DraftsAdmissionAndOutboxCancelBehaviorTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let accountId = "admission-\(UUID().uuidString)"
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
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func insertDraft(_ fixture: Fixture, epoch: String?) throws -> Draft {
        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "draft-\(UUID().uuidString)", accountId: fixture.accountId,
            toJSON: Draft.encodeStringArray(["recipient@example.com"]),
            ccJSON: Draft.encodeStringArray(["copy@example.com"]), bccJSON: Draft.encodeStringArray([]),
            subject: "Status update", body: "The status for this week.",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now)
        draft.instanceEpoch = epoch
        let row = draft
        try fixture.pool.write { db in try row.insert(db) }
        return row
    }

    private func insertOutbox(
        _ fixture: Fixture, status: OutboxStatus = .queued, sentAt: Date? = nil
    ) throws -> OutboxMessage {
        var outbox = OutboxMessage(
            accountId: fixture.accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Held", body: "Held body"))
        outbox.status = status.rawValue
        outbox.sentAt = sentAt
        outbox.holdUntil = Date().addingTimeInterval(SyncConfig.outboxUndoHoldSeconds)
        let row = outbox
        try fixture.pool.write { db in try row.insert(db) }
        return row
    }

    @Test("queueDraftSave writes a visible Drafts header, its body and a server save at the row's generation")
    func queueDraftSaveWritesHeaderBodyAndOperation() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let epoch = UUID().uuidString
        let draft = try insertDraft(fixture, epoch: epoch)

        #expect(await AccountManager.shared.queueDraftSave(draftId: draft.id, accountId: fixture.accountId))

        let headerId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: fixture.accountId, draftsFolderPath: "Drafts", draftId: draft.id, instanceEpoch: epoch)
        let (header, body, ops) = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: headerId),
             try MessageBody.filter(Column("id") == headerId).fetchOne(db),
             try PendingOperation.fetchAll(db).filter { $0.draftId == draft.id })
        }
        let written = try #require(header)
        #expect(written.folderId == "\(fixture.accountId):Drafts")
        #expect(written.subject == "Status update")
        #expect(written.snippet.contains("The status for this week."))
        #expect(written.isRead)
        #expect(written.headerComplete)
        #expect(body?.htmlContent?.contains("The status for this week.") == true)
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .saveDraft)
        #expect(ops[0].instanceEpoch == epoch)
        #expect(ops[0].folderPath == "Drafts")
    }

    @Test("queueDraftSave refuses a row that is absent or has no generation, writing nothing")
    func queueDraftSaveRefusesWithoutRowOrGeneration() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let unstamped = try insertDraft(fixture, epoch: nil)

        #expect(!(await AccountManager.shared.queueDraftSave(draftId: "draft-absent", accountId: fixture.accountId)))
        #expect(!(await AccountManager.shared.queueDraftSave(draftId: unstamped.id, accountId: fixture.accountId)))
        let (headers, ops) = try await fixture.pool.read { db in
            (try MessageHeader.fetchCount(db), try PendingOperation.fetchCount(db))
        }
        #expect(headers == 0)
        #expect(ops == 0)
    }

    @Test("queueDraftSave refuses a row owned by another account")
    func queueDraftSaveRefusesOtherAccount() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let draft = try insertDraft(fixture, epoch: UUID().uuidString)
        #expect(!(await AccountManager.shared.queueDraftSave(draftId: draft.id, accountId: "other-account")))
        #expect(try await fixture.pool.read { db in try PendingOperation.fetchCount(db) } == 0)
    }

    @Test("discardOutboxMessageConfirmed deletes a held row and refuses a sending, sent or absent one")
    func discardOutboxMessageConfirmedCancelsOnlyHeldRows() throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let held = try insertOutbox(fixture)
        let sending = try insertOutbox(fixture, status: .sending)
        let sent = try insertOutbox(fixture, sentAt: Date().addingTimeInterval(-60))

        #expect(AccountManager.shared.discardOutboxMessageConfirmed(held.id))
        #expect(!AccountManager.shared.discardOutboxMessageConfirmed(sending.id))
        #expect(!AccountManager.shared.discardOutboxMessageConfirmed(sent.id))
        #expect(!AccountManager.shared.discardOutboxMessageConfirmed("outbox-absent"))
        let remaining = try fixture.pool.read { db in try OutboxMessage.fetchAll(db).map(\.id) }
        #expect(Set(remaining) == [sending.id, sent.id])
    }
}
