/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T2.4 — system-level proofs for provider-native ordinary-action admission.
///
/// PORT/SUBTRACT/INVENT: the direct construction sites are v3-only adaptations
/// (⚑ NO REFERENCE — INVENTED) after an exact census of `v2final`'s inverse
/// provider→RFC re-key (`a75196398`) and `MessageHeader.stableId`.  The tests
/// deliberately pin observable queue/local-state behavior, not a new helper.
@Suite("T2.4 — provider-native ordinary-action admission", .serialized, .processGlobalState)
struct ProviderNativeActionAdmissionTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
    }

    @MainActor
    private func fixture(
        accounts: [(String, AccountProvider)] = [("imap-1", .imap)],
        folders: [(String, String, FolderRole, Int?)] = [
            ("imap-1", "INBOX", .inbox, 101),
            ("imap-1", "Archive", .archive, 202),
            ("imap-1", "Trash", .trash, 303),
            ("imap-1", "Sent", .sent, 404),
        ]
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            for (id, provider) in accounts {
                var account = Account(
                    emailAddress: "\(id)@example.com", displayName: id, provider: provider)
                account.id = id
                try account.insert(db)
            }
            for (accountId, path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous)
    }

    @MainActor
    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        let overlay = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(overlay.keys))
    }

    private func message(
        accountId: String = "imap-1",
        folder: String = "INBOX",
        uid: String,
        rfc: String? = nil,
        epoch: Int?,
        isRead: Bool = false
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid,
            subject: "subject \(uid)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "\(accountId):\(folder)",
            accountId: accountId,
            folderPath: folder,
            isInInbox: folder == "INBOX"
        )
        header.isRead = isRead
        header.headerComplete = true
        header.rfc822MessageId = rfc ?? "rfc-\(accountId)-\(folder)-\(uid)@example.com"
        header.observedUidValidity = epoch
        return header
    }

    private func insert(_ headers: [MessageHeader], into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            for header in headers { try header.insert(db) }
        }
    }

    private func operations(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    private func stored(_ header: MessageHeader, in pool: DatabasePool) throws -> MessageHeader? {
        try pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
    }

    /// ⚠️ RE-SCOPED (`IOS-QUEUE-003` item 7). **Previous display name: *"Every
    /// ordinary IMAP producer persists the native UID and its source
    /// UIDVALIDITY"*.** That name was universally quantified over "every ordinary
    /// IMAP producer", but the body constructs and asserts exactly FOUR of them —
    /// `markRead`, `markUnread`, `markFlagged` and `move`, all entered through
    /// `AccountManagerActions`. The producer set is strictly larger: `archive` and
    /// `delete` are covered by `archiveDeleteUseMove` below, and
    /// `AppDelegate`'s two `NotificationActionRouter` cold-queue sites and
    /// `AccountManager`'s `markReplied` / `markForwarded` are NOT covered
    /// here at all — they stamp their epoch through
    /// `AccountManager.admissionEpochForNewGesture` and `flagAdmission
    /// .observedUidValidity` respectively, and each is proved by its own suite.
    /// A universally-quantified name that enumerates a subset reads to a later
    /// reader as a proof it is not — the same hazard as `IOS-TEST-002`,
    /// `IOS-TEST-005` and the `ActiveAIQueueTests` unstamped-row name, and it is
    /// cited as the canonical example of that hazard in
    /// `NeverDropExitClosureTests` and `ActiveAIQueueTests`; the retired text is
    /// kept above so those citations stay greppable.
    @Test("markRead, markUnread, markFlagged and move each persist the native UID and its source UIDVALIDITY")
    @MainActor
    func everyOrdinaryProducer() async throws {
        let f = try fixture()
        defer { finish(f) }
        let read = message(uid: "11", epoch: 101)
        let unread = message(uid: "12", epoch: 101, isRead: true)
        let flag = message(uid: "13", epoch: 101)
        let move = message(uid: "14", epoch: 101)
        try insert([read, unread, flag, move], into: f.pool)

        await AccountManager.shared.markRead([read])
        await AccountManager.shared.markUnread([unread])
        await AccountManager.shared.markFlagged([flag], flagged: true)
        await AccountManager.shared.move([move], to: "Archive")

        let ops = try operations(f.pool)
        #expect(Set(ops.map(\.type)) == [.markRead, .markUnread, .markFlagged, .move])
        #expect(Set(ops.flatMap(\.messageIds)) == ["11", "12", "13", "14"])
        #expect(ops.allSatisfy { $0.observedUidValidity == 101 })
    }

    @Test("A stale E1 on-screen target cannot mutate or enqueue against UID reused in E2")
    @MainActor
    func staleSnapshotRefused() async throws {
        let f = try fixture(folders: [("imap-1", "INBOX", .inbox, 2)])
        defer { finish(f) }
        let stale = message(uid: "41", rfc: "old-occupant@example.com", epoch: 1)
        try insert([stale], into: f.pool)

        await AccountManager.shared.markRead([stale])

        #expect(try operations(f.pool).isEmpty)
        #expect(try stored(stale, in: f.pool)?.isRead == false)
    }

    @Test("Missing, zero, or mismatched IMAP source epochs fail closed before local mutation")
    @MainActor
    func unusableSourceEpochsRefused() async throws {
        let f = try fixture(folders: [("imap-1", "INBOX", .inbox, 8)])
        defer { finish(f) }
        let missing = message(uid: "51", epoch: nil)
        let zero = message(uid: "52", epoch: 0)
        let mismatch = message(uid: "53", epoch: 7)
        try insert([missing, zero, mismatch], into: f.pool)

        await AccountManager.shared.markFlagged([missing, zero, mismatch], flagged: true)

        #expect(try operations(f.pool).isEmpty)
        #expect(try [missing, zero, mismatch].allSatisfy { try stored($0, in: f.pool)?.isFlagged == false })
    }

    @Test("An IMAP batch never mixes UIDVALIDITY epochs in one pending operation")
    @MainActor
    func batchDoesNotMixEpochs() async throws {
        let f = try fixture(folders: [("imap-1", "INBOX", .inbox, 10)])
        defer { finish(f) }
        let live = message(uid: "61", epoch: 10)
        let stale = message(uid: "62", epoch: 9)
        try insert([live, stale], into: f.pool)

        await AccountManager.shared.markRead([live, stale])

        let ops = try operations(f.pool)
        #expect(ops.count == 1)
        #expect(ops.first?.messageIds == ["61"])
        #expect(ops.first?.observedUidValidity == 10)
        #expect(try stored(live, in: f.pool)?.isRead == true)
        #expect(try stored(stale, in: f.pool)?.isRead == false)
    }

    @Test("Cross-account and cross-mailbox members produce separate provider-address-space operations")
    @MainActor
    func providerAddressPartition() async throws {
        let f = try fixture(
            accounts: [("imap-1", .imap), ("imap-2", .icloud)],
            folders: [
                ("imap-1", "INBOX", .inbox, 11),
                ("imap-1", "Archive", .archive, 12),
                ("imap-2", "INBOX", .inbox, 21),
            ])
        defer { finish(f) }
        let a = message(accountId: "imap-1", folder: "INBOX", uid: "71", epoch: 11)
        let b = message(accountId: "imap-1", folder: "Archive", uid: "72", epoch: 12)
        let c = message(accountId: "imap-2", folder: "INBOX", uid: "73", epoch: 21)
        try insert([a, b, c], into: f.pool)

        await AccountManager.shared.markFlagged([a, b, c], flagged: true)

        let ops = try operations(f.pool)
        #expect(ops.count == 3)
        #expect(Set(ops.map { "\($0.accountId)|\($0.folderPath)|\($0.observedUidValidity ?? -1)|\($0.messageIds.joined())" }) == [
            "imap-1|INBOX|11|71", "imap-1|Archive|12|72", "imap-2|INBOX|21|73",
        ])
    }

    @Test("Duplicate RFC Message-IDs do not expand one IMAP gesture to a sibling UID")
    @MainActor
    func duplicateRfcDoesNotExpand() async throws {
        let f = try fixture()
        defer { finish(f) }
        let inbox = message(folder: "INBOX", uid: "81", rfc: "duplicate@example.com", epoch: 101)
        let sent = message(folder: "Sent", uid: "82", rfc: "duplicate@example.com", epoch: 404)
        try insert([inbox, sent], into: f.pool)

        await AccountManager.shared.markRead([inbox])

        let ops = try operations(f.pool)
        #expect(ops.count == 1)
        #expect(ops.first?.messageIds == ["81"])
        #expect(try stored(inbox, in: f.pool)?.isRead == true)
        #expect(try stored(sent, in: f.pool)?.isRead == false)
    }

    @Test("Gmail and Graph actions persist native resource IDs with no IMAP epoch")
    @MainActor
    func stableProvidersUseNativeIds() async throws {
        let f = try fixture(
            accounts: [("gmail-1", .gmail), ("graph-1", .outlook)],
            folders: [
                ("gmail-1", "INBOX", .inbox, nil),
                ("graph-1", "Inbox", .inbox, nil),
            ])
        defer { finish(f) }
        let gmail = message(accountId: "gmail-1", folder: "INBOX", uid: "9001", epoch: nil)
        let graph = message(accountId: "graph-1", folder: "Inbox", uid: "9002", epoch: nil)
        try insert([gmail, graph], into: f.pool)

        await AccountManager.shared.markFlagged([gmail, graph], flagged: true)

        let ops = try operations(f.pool)
        #expect(ops.count == 2)
        #expect(Set(ops.flatMap(\.messageIds)) == ["9001", "9002"])
        #expect(ops.allSatisfy { $0.observedUidValidity == nil })
    }

    @Test("Archive and delete produce provider-ID move operations; legacy archive/delete types remain unproduced")
    @MainActor
    func archiveDeleteUseMove() async throws {
        let f = try fixture()
        defer { finish(f) }
        let archive = message(uid: "91", epoch: 101)
        let delete = message(uid: "92", epoch: 101)
        try insert([archive, delete], into: f.pool)

        await AccountManager.shared.archive([archive])
        await AccountManager.shared.delete([delete])

        let ops = try operations(f.pool)
        #expect(ops.count == 2)
        #expect(ops.allSatisfy { $0.type == .move })
        #expect(Set(ops.flatMap(\.messageIds)) == ["91", "92"])
        #expect(ops.allSatisfy { $0.observedUidValidity == 101 })
        #expect(!ops.contains { $0.type == .archive || $0.type == .delete })
    }

    @Test("Action tags remain local-only and create no PendingOperation")
    @MainActor
    func actionTagsStayLocal() async throws {
        let f = try fixture(accounts: [("gmail-1", .gmail)], folders: [("gmail-1", "INBOX", .inbox, nil)])
        defer { finish(f) }
        var header = message(accountId: "gmail-1", folder: "INBOX", uid: "tag-native", epoch: nil)
        header.rfc822MessageId = "tag-rfc@example.com"
        try insert([header], into: f.pool)

        await AccountManager.shared.applyManualTag(header, tag: .reply)

        #expect(try operations(f.pool).isEmpty)
        #expect(try stored(header, in: f.pool)?.actionTag == .reply)
    }

    @Test("A locally moved IMAP row is unaddressable until sync assigns its destination UID and epoch")
    @MainActor
    func movedRowNeedsDestinationObservation() async throws {
        let f = try fixture()
        defer { finish(f) }
        let source = message(uid: "101", epoch: 101)
        try insert([source], into: f.pool)

        await AccountManager.shared.move([source], to: "Archive")
        _ = try await f.pool.writeWithoutTransaction { db in try PendingOperation.deleteAll(db) }
        let moved = try #require(try stored(source, in: f.pool))
        #expect(moved.folderPath == "Archive")
        #expect(moved.observedUidValidity == nil)

        await AccountManager.shared.markRead([moved])

        #expect(try operations(f.pool).isEmpty)
        #expect(try stored(moved, in: f.pool)?.isRead == false)
    }
}
