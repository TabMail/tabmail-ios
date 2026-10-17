/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Issue #217. THE INVARIANT: **a Drafts header written by another mail app becomes
/// an editable draft that owns EXACTLY that server copy** — so reopening finds it,
/// the first save replaces that copy and nothing else, and no second local row is
/// ever created for it. Anything without an exact address stays closed.
@Suite("External draft adoption (#217)")
struct ExternalDraftAdoptionTests {
    private static let accountId = "acc-imap"
    private static let draftsPath = "Drafts"
    private static let liveEpoch = 900_001

    /// Account + Drafts folder + one synced Drafts header written by another app.
    private func makeImapFixture(
        _ db: DatabaseQueue,
        folderEpoch: Int? = ExternalDraftAdoptionTests.liveEpoch,
        observedEpoch: Int? = ExternalDraftAdoptionTests.liveEpoch,
        headerUid: String = "7",
        inReplyTo: String? = nil
    ) throws -> (MessageHeader, Folder) {
        try TestDatabase.insertAccount(
            db, id: Self.accountId, email: "imap@example.com", provider: .imap)
        var folder = Folder(
            name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: Self.accountId)
        folder.lastKnownUidValidity = folderEpoch
        try db.write { try folder.insert($0) }
        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: headerUid,
            subject: "Started elsewhere",
            to: "Alice <alice@example.com>, bob@example.com",
            folderId: folder.id,
            accountId: Self.accountId,
            folderPath: Self.draftsPath,
            isInInbox: false,
            rfc822MessageId: "other-app@example.com")
        header.cc = "carol@example.com"
        header.observedUidValidity = observedEpoch
        header.inReplyTo = inReplyTo
        try db.write { try header.update($0) }
        return (header, folder)
    }

    private func adopt(
        _ db: DatabaseQueue,
        _ header: MessageHeader,
        body: String = "Hello from the other app"
    ) throws -> String? {
        try db.write { db in
            guard let address = try ExternalDraftAdoption.adoptableAddress(
                db: db, header: header, runtimeKind: .imap) else { return nil }
            return try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: address, runtimeKind: .imap,
                body: body, attachmentsDirName: nil)
        }
    }

    private func resolve(
        _ db: DatabaseQueue, _ header: MessageHeader
    ) throws -> LocallyAuthoredDraftOpenAuthority? {
        try db.read { db in
            try LocallyAuthoredDraftOpenAuthority.resolve(
                db: db, header: header, runtimeKind: .imap)
        }
    }

    // MARK: - Opens, and owns exactly that copy

    @Test("A draft from another app becomes an editable draft that owns that exact server copy")
    func foreignImapDraftIsAdopted() throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(db)
        #expect(try resolve(db, header) == nil, "precondition: no local owner before adoption")

        let draftId = try adopt(db, header)

        let authority = try resolve(db, header)
        #expect(draftId != nil && authority?.draftId == draftId,
                "the other app's draft is still unopenable after adoption — issue #217")
        #expect(authority?.address == .imap(
            folderPath: Self.draftsPath, uidValidity: Self.liveEpoch, uid: "7"),
                "the adopted row must own the COMPLETE provider-native address")
        let row = try db.read { try Draft.fetchOne($0, key: draftId ?? "") }
        #expect(row?.serverPushStatus == "pushed",
                "an adopted row IS the server copy — 'dirty' would claim an edit nobody made")
        #expect(row?.toArray == ["alice@example.com", "bob@example.com"])
        #expect(row?.ccArray == ["carol@example.com"])
        #expect(row?.subject == "Started elsewhere")
        #expect(row?.body == "Hello from the other app")
        #expect(row?.instanceEpoch?.isEmpty == false)
        #expect(row.map { ExternalDraftAdoption.isAdoptedKey($0.id) } == true)
    }

    @Test("Opening the same draft twice never creates a second local row")
    func adoptionIsNotDuplicated() throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(db)

        let first = try adopt(db, header)
        let second = try adopt(db, header)

        #expect(first != nil)
        #expect(second == nil, "a second adoption of an owned address inserted another row")
        #expect(try db.read { try Draft.fetchCount($0) } == 1)
        #expect(try resolve(db, header)?.draftId == first,
                "two rows owning one address would make the resolver refuse the draft")
    }

    @Test("A draft this device already owns is never adopted over")
    func locallyOwnedDraftIsLeftAlone() throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(db)
        var local = Draft(
            id: "new:local", accountId: Self.accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "authored here", body: "local text", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: "7", serverPushStatus: "dirty",
            rfc822MessageId: "other-app@example.com", attachmentsDirName: nil)
        local.instanceEpoch = "E1"
        local.serverDraftFolderPath = Self.draftsPath
        local.serverDraftUidValidity = Self.liveEpoch
        try db.write { try local.insert($0) }

        #expect(try adopt(db, header) == nil)
        #expect(try db.read { try Draft.fetchOne($0, key: "new:local") }?.body == "local text",
                "adoption must never touch a row this device authored")
    }

    // MARK: - No exact address, no adoption

    @Test("An IMAP draft whose numbering space is not proven stays closed",
          arguments: [
            (Optional(900_001), Optional<Int>.none),   // header epoch never observed
            (Optional<Int>.none, Optional(900_001)),   // folder epoch unknown
            (Optional(900_002), Optional(900_001)),    // folder renumbered since sync
          ])
    func unprovenEpochIsNotAdopted(folderEpoch: Int?, observedEpoch: Int?) throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(
            db, folderEpoch: folderEpoch, observedEpoch: observedEpoch)

        #expect(try adopt(db, header) == nil,
                "a bare UID without its proven UIDVALIDITY was adopted — the first save would replace whatever message now sits at that slot")
        #expect(try db.read { try Draft.fetchCount($0) } == 0)
    }

    @Test("A quarantined Drafts folder is not adopted from")
    func quarantinedFolderIsNotAdopted() throws {
        let db = try TestDatabase.make()
        var (header, folder) = try makeImapFixture(db)
        folder.uidValidityResetPendingAt = Date()
        try db.write { try folder.update($0) }
        header = try db.read { try MessageHeader.fetchOne($0, key: header.id) } ?? header

        #expect(try adopt(db, header) == nil)
    }

    @Test("A header that changed after it was opened adopts nothing")
    func changedHeaderIsNotAdopted() throws {
        let db = try TestDatabase.make()
        let (header, folder) = try makeImapFixture(db)
        let address = try #require(try db.read { db in
            try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
        })
        // The server renumbered the folder while the body was being fetched.
        var renumbered = folder
        renumbered.lastKnownUidValidity = 900_002
        try db.write { try renumbered.update($0) }

        let inserted = try db.write { db in
            try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: address, runtimeKind: .imap,
                body: "text", attachmentsDirName: nil)
        }
        #expect(inserted == nil,
                "the insert transaction must re-prove the address it is about to own")
    }

    @Test("Placeholder ids and non-Drafts folders are never an address")
    func placeholderIsNotAnAddress() {
        let folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc-o")
        var header = MessageHeader(
            messageId: "draft-abc:E1:2", subject: "s", from: "a@example.com",
            fromAddress: "a@example.com", to: "", date: Date(), snippet: "",
            folderId: folder.id, accountId: "acc-o", folderPath: "Drafts", isInInbox: false)
        #expect(ExternalDraftAdoption.nativeAddress(
            header: header, folder: folder, runtimeKind: .outlook) == nil)

        header.messageId = "AAMkGraphId"
        #expect(ExternalDraftAdoption.nativeAddress(
            header: header, folder: folder, runtimeKind: .outlook) == .outlook(graphId: "AAMkGraphId"))

        let inbox = Folder(name: "Inbox", path: "Drafts", role: .inbox, accountId: "acc-o")
        #expect(ExternalDraftAdoption.nativeAddress(
            header: header, folder: inbox, runtimeKind: .outlook) == nil)
    }

    // MARK: - Body

    @Test("An unconfirmed empty body never opens an editor that could blank the server draft")
    func editableBodyFailsClosedOnUnconfirmedEmpty() {
        #expect(ExternalDraftAdoption.editableBody(
            html: "<p>Hi</p>", bodyEmptyConfirmed: false, hasAttachments: false) == "Hi")
        #expect(ExternalDraftAdoption.editableBody(
            html: nil, bodyEmptyConfirmed: false, hasAttachments: false) == nil)
        #expect(ExternalDraftAdoption.editableBody(
            html: "<div><br></div>", bodyEmptyConfirmed: false, hasAttachments: false) == nil)
        #expect(ExternalDraftAdoption.editableBody(
            html: nil, bodyEmptyConfirmed: true, hasAttachments: false) == "")
        #expect(ExternalDraftAdoption.editableBody(
            html: nil, bodyEmptyConfirmed: false, hasAttachments: true) == "")
    }

    // MARK: - Reply threading

    @Test("A reply drafted elsewhere stays threaded to its original")
    func replyParentIsResolved() throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(db, inReplyTo: "original@example.com")
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId)
        inbox.lastKnownUidValidity = 5
        try db.write { try inbox.insert($0) }
        var parent = try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: inbox.id, accountId: Self.accountId,
            folderPath: "INBOX", rfc822MessageId: "original@example.com")
        parent.observedUidValidity = 5
        try db.write { try parent.update($0) }

        let draftId = try #require(try adopt(db, header))
        let row = try #require(try db.read { try Draft.fetchOne($0, key: draftId) })
        let resolved = try db.read { db in
            try Draft.resolveReplyToHeader(
                draftKey: row.id, replyToId: row.replyToId, isForward: row.isForward,
                expectedProviderMessageId: row.replyToProviderMessageId,
                expectedUidValidity: row.replyToUidValidity, db: db)
        }
        #expect(resolved?.id == parent.id,
                "the adopted reply would be sent as a new, unthreaded message")
    }

    @Test("An ambiguous or unprovable original leaves the draft unthreaded, never blocked")
    func unprovableParentIsNotClaimed() throws {
        let db = try TestDatabase.make()
        let (header, _) = try makeImapFixture(db, inReplyTo: "original@example.com")
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId)
        inbox.lastKnownUidValidity = 5
        try db.write { try inbox.insert($0) }
        // RFC-less IMAP-style parent with no observed epoch: nothing proves the copy.
        try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: inbox.id, accountId: Self.accountId,
            folderPath: "INBOX", rfc822MessageId: "original@example.com")

        let draftId = try #require(try adopt(db, header))
        let row = try db.read { try Draft.fetchOne($0, key: draftId) }
        #expect(row?.replyToId == nil,
                "claiming a parent that reopen cannot prove would block Send from the start")
    }

    @Test("Adopted keys are recognised and ordinary keys are not")
    func adoptedKeyPrefix() {
        #expect(ExternalDraftAdoption.isAdoptedKey("adopted:1234"))
        #expect(!ExternalDraftAdoption.isAdoptedKey("reply:acc:msg@example.com"))
        #expect(!ExternalDraftAdoption.isAdoptedKey("new:1234"))
    }
}

/// The first save of an adopted draft must REPLACE the other app's copy — by its
/// exact address — rather than leave it behind as a duplicate (what the pre-v1.7
/// open did) or replace something else.
@Suite("External draft adoption — first save replaces the server copy (#217)", .serialized, .processGlobalState)
@MainActor
struct ExternalDraftAdoptionSaveTests {
    @Test("Editing an adopted IMAP draft replaces exactly the other app's copy")
    func firstSaveReplacesTheAdoptedCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-adoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        defer {
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }

        let draftId: String = try await pool.write { db in
            var account = Account(
                emailAddress: "imap@example.com", displayName: "Test", provider: .imap)
            account.id = "acc-imap"
            try account.insert(db)
            var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc-imap")
            folder.lastKnownUidValidity = 900_001
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "7", subject: "Started elsewhere", from: "imap@example.com",
                fromAddress: "imap@example.com", to: "alice@example.com", date: Date(),
                snippet: "", folderId: folder.id, accountId: "acc-imap",
                folderPath: "Drafts", isInInbox: false)
            header.observedUidValidity = 900_001
            try header.insert(db)
            let address = try #require(try ExternalDraftAdoption.adoptableAddress(
                db: db, header: header, runtimeKind: .imap))
            return try #require(try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: address, runtimeKind: .imap,
                body: "text from the other app", attachmentsDirName: nil))
        }

        // The user edits on this device.
        try await pool.write { db in
            var edited = try #require(try Draft.fetchOne(db, key: draftId))
            edited.body = "edited on this device"
            edited.updatedAt += 1
            _ = try DraftStore.applySave(edited, db: db)
        }
        let epoch = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) }?.instanceEpoch)

        let provider = MockEmailProvider(
            saveDraftResult: .created(.imap(folder: "Drafts", uidValidity: 900_001, uid: 8)))
        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: draftId, expectedInstanceEpoch: epoch, provider: provider,
            runtimeKind: .imap, draftsFolderPath: "Drafts")

        let calls = await provider.callLog
        #expect(result == .completed)
        #expect(calls.contains {
            $0.contains("existingIdentity:Optional(TabMail.DraftDeleteIdentity.imap(folder: \"Drafts\", uidValidity: 900001, uid: 7))")
        }, "the save did not replace the other app's copy at Drafts/900001/7: \(calls)")
        let live = try await pool.read { try Draft.fetchOne($0, key: draftId) }
        #expect(live?.serverDraftId == "8", "after the save the row must own the NEW copy")
    }
}
