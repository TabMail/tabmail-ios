/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A draft already uploaded has one Drafts entry, under its server copy's key.
/// Saving it again before the next upload lands, by an Undo Send or by an edit
/// made offline, keeps that ONE entry with the latest words, and the next upload
/// sends those words to the same server copy.
///
/// The first upload runs the production push (`DraftStore.pushDraftToServer`)
/// against `MockEmailProvider`, which moves the Drafts entry to the server key.
/// Every header in the Drafts folder is counted, native and placeholder alike.
/// IMAP and demo name the moved entry by the row's server id; Gmail does not
/// and is tracked separately.
///
/// `.serialized` + `.processGlobalState`: rebinds `AppDatabase.shared` and uses
/// `PendingSendService.shared`. example.com addresses only; every instant
/// derives from `Date()`.
@Suite("An uploaded draft keeps one Drafts entry", .serialized, .processGlobalState)
@MainActor
struct UploadedDraftSingleEntryTests {
    enum Kind: String, CaseIterable, Sendable {
        case imap, demo

        var runtimeKind: DraftRuntimeIdentityKind { self == .imap ? .imap : .demo }

        func accountId() -> String {
            self == .demo ? DemoSeed.demoAccountId : "uploaded-imap-\(UUID().uuidString)"
        }

        var created: DraftCreatedAddress {
            switch self {
            case .imap: .imap(folder: UploadedDraftSingleEntryTests.draftsPath,
                              uidValidity: UploadedDraftSingleEntryTests.imapEpoch, uid: 4242)
            case .demo: .demo(localId: "demo-draft-4242")
            }
        }

        var serverId: String { self == .imap ? "4242" : "demo-draft-4242" }

        /// The address a replacement upload returns: the old copy is deleted and
        /// the new one appended under a different id.
        var replacement: DraftCreatedAddress {
            switch self {
            case .imap: .imap(folder: UploadedDraftSingleEntryTests.draftsPath,
                              uidValidity: UploadedDraftSingleEntryTests.imapEpoch, uid: 4343)
            case .demo: .demo(localId: "demo-draft-4343")
            }
        }

        var replacementServerId: String { self == .imap ? "4343" : "demo-draft-4343" }

        var identity: DraftDeleteIdentity {
            switch self {
            case .imap: .imap(folder: UploadedDraftSingleEntryTests.draftsPath,
                              uidValidity: UploadedDraftSingleEntryTests.imapEpoch, uid: 4242)
            case .demo: .demo(localId: "demo-draft-4242")
            }
        }
    }

    static let draftsPath = "Drafts"
    static let imapEpoch = 7

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let kind: Kind
        var draftsFolderId: String { "\(accountId):\(UploadedDraftSingleEntryTests.draftsPath)" }
    }

    private func makeFixture(_ kind: Kind) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let accountId = kind.accountId()
        try pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            account.id = accountId
            try account.insert(db)
            var drafts = Folder(name: Self.draftsPath, path: Self.draftsPath, role: .drafts, accountId: accountId)
            // Only an IMAP mailbox has a UIDVALIDITY; a demo folder never does.
            if kind == .imap { drafts.lastKnownUidValidity = Self.imapEpoch }
            try drafts.insert(db)
        }
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId, kind: kind)
    }

    private func finish(_ fixture: Fixture) {
        PendingSendService.shared.dismiss()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft {
        try #require(try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) })
    }

    private func allDraftsEntries(_ fixture: Fixture) async throws -> [(MessageHeader, MessageBody?)] {
        try await fixture.pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == fixture.draftsFolderId)
                .fetchAll(db)
                .map { header in (header, try MessageBody.filter(Column("id") == header.id).fetchOne(db)) }
        }
    }

    /// Writes `body` through `cursor` as the compose does, at a time after the
    /// row's own.
    private func write(
        _ fixture: Fixture, draftId: String, body: String, cursor: ComposeGenerationCursor
    ) async throws {
        let now = Date().timeIntervalSince1970
        var draft = try await fixture.pool.read { db in try Draft.fetchOne(db, key: draftId) }
            ?? Draft(
                id: draftId, accountId: fixture.accountId,
                toJSON: Draft.encodeStringArray(["recipient@example.com"]),
                ccJSON: Draft.encodeStringArray([]), bccJSON: Draft.encodeStringArray([]),
                subject: "Quarterly plan", body: body,
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: now, updatedAt: now)
        draft.body = body
        draft.updatedAt = max(draft.updatedAt + 1, now)
        let snapshot = draft
        let result = try await cursor.admit { epoch, predecessor in
            try await DraftStore.shared.saveAsync(snapshot, epoch: epoch, expectedPredecessor: predecessor)
        }
        #expect(result == .applied)
    }

    private func push(
        _ fixture: Fixture, draftId: String, mock: MockEmailProvider
    ) async throws -> DraftStore.PushDisposition {
        let epoch = try #require(try await row(fixture, draftId).instanceEpoch)
        return try await DraftStore.shared.pushDraftToServer(
            draftId: draftId, expectedInstanceEpoch: epoch, provider: mock,
            runtimeKind: fixture.kind.runtimeKind, draftsFolderPath: Self.draftsPath)
    }

    /// A draft saved and uploaded through production: one Drafts entry, now
    /// under the server copy's key.
    private func uploadedDraft(
        _ fixture: Fixture, mock: MockEmailProvider
    ) async throws -> (draftId: String, cursor: ComposeGenerationCursor, serverHeaderId: String) {
        let draftId = "draft-\(UUID().uuidString)"
        let cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        try await write(fixture, draftId: draftId, body: "First version of the plan.", cursor: cursor)
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: fixture.accountId))
        #expect(try await push(fixture, draftId: draftId, mock: mock) == .completed)

        let serverHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: Self.draftsPath, messageId: fixture.kind.serverId)
        let entries = try await allDraftsEntries(fixture)
        try #require(entries.map(\.0.id) == [serverHeaderId],
                     "precondition: the upload left \(entries.map(\.0.id))")
        #expect(try await row(fixture, draftId).serverDraftId == fixture.kind.serverId)
        return (draftId, cursor, serverHeaderId)
    }

    /// Exactly one Drafts entry, the server copy's, showing `words`; and the next
    /// upload sends `words` to that same server copy.
    private func expectOneEntryAndUpload(
        _ fixture: Fixture, draftId: String, serverHeaderId: String,
        mock: MockEmailProvider, words: String
    ) async throws {
        let entries = try await allDraftsEntries(fixture)
        #expect(entries.count == 1, "Drafts shows \(entries.count) entries: \(entries.map(\.0.id))")
        guard entries.count == 1 else { return }
        #expect(entries[0].0.id == serverHeaderId)
        #expect(entries[0].0.snippet.contains(words))
        #expect(entries[0].1?.htmlContent?.contains(words) == true)
        #expect(try await row(fixture, draftId).serverDraftId == fixture.kind.serverId)

        #expect(try await push(fixture, draftId: draftId, mock: mock) == .completed)
        let payloads = await mock.savedDraftPayloads
        let last = try #require(payloads.last)
        #expect(last.draft.body.contains(words), "the upload sent \(last.draft.body)")
        #expect(last.existingIdentity == fixture.kind.identity,
                "the upload named \(String(describing: last.existingIdentity))")
    }

    /// After a replacement upload that returned a new id: exactly one Drafts
    /// entry, under the new id, and it is this draft's (its words, its message
    /// id and the row's RFC Message-ID).
    private func expectOneEntryAfterReplacement(
        _ fixture: Fixture, draftId: String, words: String
    ) async throws {
        let newHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: Self.draftsPath,
            messageId: fixture.kind.replacementServerId)
        let draft = try await row(fixture, draftId)
        #expect(draft.serverDraftId == fixture.kind.replacementServerId)
        let entries = try await allDraftsEntries(fixture)
        #expect(entries.count == 1, "Drafts shows \(entries.count) entries: \(entries.map(\.0.id))")
        guard entries.count == 1 else { return }
        #expect(entries[0].0.id == newHeaderId)
        #expect(entries[0].0.messageId == fixture.kind.replacementServerId)
        #expect(entries[0].0.rfc822MessageId == draft.rfc822MessageId)
        #expect(entries[0].0.snippet.contains(words))
        #expect(entries[0].1?.htmlContent?.contains(words) == true)
    }

    @Test("Undo Send of an uploaded draft keeps one Drafts entry with the words sent", arguments: Kind.allCases)
    func undoOfUploadedDraftKeepsOneEntry(_ kind: Kind) async throws {
        let fixture = try makeFixture(kind)
        defer { finish(fixture) }
        let mock = MockEmailProvider(saveDraftResult: .created(kind.created))
        let uploaded = try await uploadedDraft(fixture, mock: mock)
        let latest = "Final version of the plan, with the new dates."

        // Edited offline, then sent; Undo.
        try await write(fixture, draftId: uploaded.draftId, body: latest, cursor: uploaded.cursor)
        var outbox = OutboxMessage(
            accountId: fixture.accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Quarterly plan", body: latest))
        outbox.draftId = uploaded.draftId
        outbox.instanceEpoch = uploaded.cursor.newEpoch
        outbox.holdUntil = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds)
        let held = outbox
        try await fixture.pool.write { db in try held.insert(db) }
        PendingSendService.shared.present(
            outboxId: held.id, draftId: uploaded.draftId, instanceEpoch: uploaded.cursor.newEpoch,
            toSummary: "To: recipient@example.com", holdUntil: held.holdUntil)
        let snapshot = try #require(PendingSendService.shared.undo(), "the Undo was not confirmed")
        #expect(snapshot.returnedToDrafts)

        try await expectOneEntryAndUpload(
            fixture, draftId: uploaded.draftId, serverHeaderId: uploaded.serverHeaderId,
            mock: mock, words: latest)
    }

    @Test("A replacement upload with a new id leaves one Drafts entry, this draft's", arguments: Kind.allCases)
    func replacementUploadMovesTheOneEntry(_ kind: Kind) async throws {
        let fixture = try makeFixture(kind)
        defer { finish(fixture) }
        let mock = MockEmailProvider(saveDraftResult: .created(kind.created))
        let uploaded = try await uploadedDraft(fixture, mock: mock)
        let edited = "Edited before the replacement upload."

        try await write(fixture, draftId: uploaded.draftId, body: edited, cursor: uploaded.cursor)
        #expect(await AccountManager.shared.queueDraftSave(
            draftId: uploaded.draftId, accountId: fixture.accountId))
        await mock.setSaveDraftResult(.created(kind.replacement))
        #expect(try await push(fixture, draftId: uploaded.draftId, mock: mock) == .completed)

        try await expectOneEntryAfterReplacement(fixture, draftId: uploaded.draftId, words: edited)
    }

    @Test("After a UIDVALIDITY reset, saving an uploaded draft leaves the message now at its UID unchanged")
    func uidValidityResetLeavesOtherMessageUnchanged() async throws {
        let fixture = try makeFixture(.imap)
        defer { finish(fixture) }
        let mock = MockEmailProvider(saveDraftResult: .created(Kind.imap.created))
        let uploaded = try await uploadedDraft(fixture, mock: mock)

        // The mailbox is renumbered; UID 4242 now belongs to another message.
        let otherSubject = "Another message"
        let otherBody = "<p>Words of another message.</p>"
        let newEpoch = Self.imapEpoch + 1
        try await fixture.pool.write { db in
            var folder = try #require(try Folder.fetchOne(db, key: fixture.draftsFolderId))
            folder.lastKnownUidValidity = newEpoch
            try folder.update(db)
            var other = try #require(try MessageHeader.fetchOne(db, key: uploaded.serverHeaderId))
            other.subject = otherSubject
            other.snippet = "Words of another message."
            other.observedUidValidity = newEpoch
            try other.update(db)
            try MessageBody(contentKey: ContentKey(rawValue: uploaded.serverHeaderId), htmlContent: otherBody).save(db)
        }

        let edited = "Edited after the reset."
        try await write(fixture, draftId: uploaded.draftId, body: edited, cursor: uploaded.cursor)
        #expect(await AccountManager.shared.queueDraftSave(
            draftId: uploaded.draftId, accountId: fixture.accountId))

        let entries = try await allDraftsEntries(fixture)
        let other = try #require(entries.first { $0.0.id == uploaded.serverHeaderId })
        #expect(other.0.subject == otherSubject)
        #expect(other.0.snippet == "Words of another message.")
        #expect(other.0.observedUidValidity == newEpoch)
        #expect(other.1?.htmlContent == otherBody)
        let own = entries.filter { $0.0.id != uploaded.serverHeaderId }
        #expect(own.count == 1, "the draft's own entry: \(own.map(\.0.id))")
        guard own.count == 1 else { return }
        #expect(own[0].1?.htmlContent?.contains(edited) == true)
    }

    @Test("An offline edit-save of an uploaded draft keeps one Drafts entry with the new words", arguments: Kind.allCases)
    func offlineEditOfUploadedDraftKeepsOneEntry(_ kind: Kind) async throws {
        let fixture = try makeFixture(kind)
        defer { finish(fixture) }
        let mock = MockEmailProvider(saveDraftResult: .created(kind.created))
        let uploaded = try await uploadedDraft(fixture, mock: mock)
        let edited = "Edited while offline."

        // The reopened draft's compose builds its cursor from the row, as its loader does.
        let loaded = try await row(fixture, uploaded.draftId)
        let observed = loaded.instanceEpoch.flatMap { $0.isEmpty ? nil : $0 }
        let composeCursor = ComposeGenerationCursor(
            newEpoch: observed ?? UUID().uuidString, initialExpectedPredecessor: observed)
        try await write(fixture, draftId: uploaded.draftId, body: edited, cursor: composeCursor)
        #expect(await AccountManager.shared.queueDraftSave(
            draftId: uploaded.draftId, accountId: fixture.accountId))

        try await expectOneEntryAndUpload(
            fixture, draftId: uploaded.draftId, serverHeaderId: uploaded.serverHeaderId,
            mock: mock, words: edited)
    }
}
