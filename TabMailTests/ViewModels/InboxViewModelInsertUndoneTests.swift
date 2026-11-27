/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Observation
import Synchronization
@testable import TabMail

private enum Config {
    /// Main-actor turns a test yields while it waits for the list's deferred
    /// eviction; the wait ends as soon as the eviction has run.
    static let evictionSettleYields = 100
}

/// Set once by an observation `onChange`, read by the test afterwards.
private final class ChangeFlag: Sendable {
    private let fired = Mutex(false)
    func set() { fired.withLock { $0 = true } }
    var value: Bool { fired.withLock { $0 } }
}

/// Regression test for commit 00cbdb8: `insertUndoneMessages` must apply the
/// optimistic overlay before the folder-membership guard.
///
/// Undo archive/move calls `AccountManager.registerMutation(folderId: originalFolderId)`
/// synchronously, then posts `.messagesUndone`. The DB restore write is
/// deferred via enqueueWrite. Without the overlay, `insertUndoneMessages`
/// reads the header directly — header.folderId is still the destination
/// (e.g. Archive), fails the `folderIds.contains(header.folderId)` check,
/// and the undone row never reappears until the next full reload.
/// ⚠️ `.processGlobalState` is REQUIRED, not decorative. `makeTestDB` replaces
/// `AppDatabase.shared` (and the tests clear `AccountManager.shared`'s optimistic
/// overlay), and `.serialized` orders cases only WITHIN this suite — it does not
/// join the cross-suite `ProcessGlobalTestState` lock. Without the trait, a
/// concurrently running suite's `AccountManager.dbPool` (which re-resolves
/// `AppDatabase.shared` at every access) can execute its `UPDATE … SET isRead=1`
/// against THIS suite's fixture: zero rows touched, nothing thrown, and the
/// victim then reads its own pool and sees `isRead == false`. That was task #91,
/// the `SearchLocalResultIdentityTests.identityPreservingMidFlightWriteStillMarksRead`
/// flake — a harness defect, not a product race. Of the suites that write the
/// global, this was the single genuine outlier.
@Suite("InboxViewModel insertUndoneMessages overlay", .serialized, .processGlobalState)
struct InboxViewModelInsertUndoneTests {

    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)

            let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            let archive = Folder(name: "Archive", path: "[Gmail]/All Mail", role: .archive, accountId: "acc1")
            try inbox.insert(db)
            try archive.insert(db)
        }

        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "[Gmail]/All Mail", role: .archive, accountId: "acc1")
        return (pool, inbox, archive, dir, previous)
    }

    @MainActor
    private func insertHeader(
        _ pool: DatabasePool,
        messageId: String,
        folderId: String,
        folderPath: String,
        isInInbox: Bool,
        subject: String = "Test"
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "me@example.com",
            date: Date(),
            snippet: "body",
            folderId: folderId,
            accountId: "acc1",
            folderPath: folderPath,
            isInInbox: isInInbox
        )
        header.headerComplete = true
        try pool.writeWithoutTransaction { db in
            try header.insert(db)
        }
        let stored = try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)
        }
        return stored!.id
    }

    private func clearOverlay() {
        // snapshotOverlay / removeOverlayEntries are both nonisolated on the
        // AccountManager actor. Snapshot the current keys and remove them —
        // avoids direct access to the (actor-isolated) Mutex property.
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    @Test("Overlay redirects header back to visible inbox → message reappears")
    @MainActor func overlayRerouteInsertsMessage() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        // DB state after archive: header.folderId = archive, isInInbox = false.
        // This is exactly the state insertUndoneMessages sees between the undo
        // trigger and the deferred DB restore write.
        let id = try insertHeader(
            pool,
            messageId: "m-undone-1",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        // VM created BEFORE the overlay mutation exists (the unified inbox read (ADR-IOS-055)
        // Phase 3: `InboxViewModel(folders:)` -> resetMessages() -> fetchPage(before: nil)
        // now routes through InboxListReader, whose P-step fetches ANY
        // overlay-pinned row by id on every read — see §2.1/§4.1's "improvement".
        // Ordering the overlay registration BEFORE VM creation (as this test
        // originally did) would have the reader's P-step surface the row during
        // `init` itself, making line "loadedMessages is empty" below false before
        // `insertUndoneMessages` is ever called — that's real Phase-3 behavior,
        // not a bug, but it defeats what THIS test is isolating (insertUndoneMessages'
        // own overlay-reroute logic). Mirroring the real call order (UndoService
        // registers the overlay, THEN posts .messagesUndone -> insertUndoneMessages)
        // keeps the test meaningful: no reader-backed fetch runs between VM
        // creation and the mutation, so the pre-condition still holds.
        let vm = InboxViewModel(folders: [inbox])
        // Archive message never loaded into inbox VM — loadedMessages is empty.
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        // The undo path registers this mutation synchronously before posting
        // .messagesUndone — overlay now says "this message belongs in Inbox".
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                isRead: nil,
                folderId: inbox.id,
                folderPath: inbox.path,
                isInInbox: true,
                isFlagged: nil,
                actionTag: nil
            )
        )
        // Registering the mutation alone doesn't trigger a VM refetch — still empty.
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        vm.insertUndoneMessages([id])

        #expect(vm.loadedMessages.contains(where: { $0.id == id }))
    }

    @Test("No overlay → header still in archive, insert is a silent no-op")
    @MainActor func noOverlayDropsInsert() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        // Same archive-state header, but this time no overlay is registered —
        // mimics the pre-fix behavior. The message stays dropped.
        let id = try insertHeader(
            pool,
            messageId: "m-undone-2",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        let vm = InboxViewModel(folders: [inbox])
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        vm.insertUndoneMessages([id])

        // Without the overlay, folder-membership check fails and the row is
        // silently dropped. (This is the bug the commit fixes — the fix kicks
        // in when an overlay IS present, but this test locks in the "no
        // overlay → conservative drop" semantics so future refactors don't
        // accidentally start inserting messages from arbitrary folders.)
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))
    }

    @Test("Undo insertion projects the restored action tag immediately instead of an AI spinner")
    @MainActor func overlayProjectsRestoredActionTag() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        let id = try insertHeader(
            pool,
            messageId: "m-undone-action-tag",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )
        let vm = InboxViewModel(folders: [inbox])
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        // Exact state installed synchronously by UndoService before it posts
        // `.messagesUndone`: durable row still lives outside Inbox and has no
        // tag, while the optimistic row belongs in Inbox with its old tag.
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                folderId: inbox.id,
                folderPath: inbox.path,
                isInInbox: true,
                actionTag: .some(.delete)
            )
        )

        vm.insertUndoneMessages([id])

        let restored = vm.loadedMessages.first { $0.id == id }
        #expect(restored?.actionTag == .delete)
        #expect(restored?.tagSortOrder == ActionTag.delete.sortOrder)
        #expect(restored.flatMap(ActionTagDisplay.displayedTag(for:)) == .delete)
    }

    @Test("Overlay without folderId change → still gated by real folderId")
    @MainActor func overlayWithoutFolderIdChange() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        let id = try insertHeader(
            pool,
            messageId: "m-undone-3",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        // Overlay only changes isRead — folder guard still sees archive.
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                isRead: true,
                folderId: nil,
                folderPath: nil,
                isInInbox: nil,
                isFlagged: nil,
                actionTag: nil
            )
        )

        let vm = InboxViewModel(folders: [inbox])
        vm.insertUndoneMessages([id])

        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))
    }

    /// The list's rows as "id subject", in list order.
    @MainActor
    private func rows(_ vm: InboxViewModel) -> [String] {
        vm.loadedMessages.map { "\($0.id) \($0.subject)" }
    }

    /// The ids of every member of every displayed group.
    @MainActor
    private func groupMemberIds(_ vm: InboxViewModel) -> [String] {
        vm.displayGroups.flatMap { $0.members.map(\.id) }
    }

    private func move(_ from: String, _ to: String) -> MailPointerMove {
        .row(HeaderRekeyRecord(oldHeaderId: from, newHeaderId: to, newProviderMessageId: to))
    }

    /// Whether the list or its groups were written while `body` ran.
    /// Observation calls `onChange` synchronously on the actor that writes.
    @MainActor
    private func listWritten(_ vm: InboxViewModel, during body: () -> Void) -> Bool {
        let flag = ChangeFlag()
        withObservationTracking {
            _ = vm.loadedMessages
            _ = vm.displayGroups
        } onChange: {
            flag.set()
        }
        body()
        return flag.value
    }

    /// A post that names no row the list holds leaves the list and its groups
    /// unwritten: any write to them re-renders the inbox, also mid-gesture. A
    /// post that names a shown row does write them.
    @Test("A post naming no shown row leaves the list and its groups unwritten")
    @MainActor func postNamingNoShownRowLeavesTheListUnwritten() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let shownId = try insertHeader(
            pool, messageId: "601", folderId: inbox.id, folderPath: inbox.path, isInInbox: true)
        let notShownId = MessageIdentity.headerId(accountId: "acc1", folderPath: inbox.path, messageId: "602")
        let elsewhereId = MessageIdentity.headerId(accountId: "acc1", folderPath: inbox.path, messageId: "603")
        let vm = InboxViewModel(folders: [inbox])
        let before = rows(vm)
        #expect(before == ["\(shownId) Test"], "setup: the list shows the row")

        let unrelated = MailPointerMoves([
            move(notShownId, elsewhereId),
            .sent(outboxId: "outbox-1", copyHeaderId: elsewhereId),
        ])
        let writtenByUnrelated = listWritten(vm) { vm.applyHeaderRekeys(unrelated) }
        #expect(!writtenByUnrelated)
        let afterUnrelated = rows(vm)
        #expect(afterUnrelated == before)

        let writtenByRename = listWritten(vm) {
            vm.applyHeaderRekeys(MailPointerMoves([move(shownId, elsewhereId)]))
        }
        #expect(writtenByRename, "control: a post naming a shown row writes the list")
    }

    /// A move whose new id is a row the list already shows (the server's copy
    /// stored before its placeholder went) leaves that row once: the list never
    /// holds one id twice. The shown copy stays as it was, where it was, and
    /// the groups follow.
    @Test("A move onto a row the list already shows leaves one row with that id")
    @MainActor func moveOntoAShownRowLeavesOneRow() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let movedId = try insertHeader(
            pool, messageId: "201", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "Placeholder")
        let shownId = try insertHeader(
            pool, messageId: "202", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "Server copy")
        let vm = InboxViewModel(folders: [inbox])
        let before = rows(vm)
        #expect(before.sorted() == ["\(movedId) Placeholder", "\(shownId) Server copy"].sorted(),
                "setup: the list shows both rows")

        vm.applyHeaderRekeys(MailPointerMoves([move(movedId, shownId)]))

        let expected = before.filter { $0 != "\(movedId) Placeholder" }
        let after = rows(vm)
        #expect(after == expected)
        let members = groupMemberIds(vm)
        let membersWithShownId = members.filter { $0 == shownId }.count
        #expect(membersWithShownId == 1)
        #expect(!members.contains(movedId))
    }

    /// The rows a move would collide with are the ones the list holds, not the
    /// ids it has loaded: a row evicted from the list keeps its id in the
    /// loaded set, and a move onto that id renames the moved row.
    @Test("A move onto an evicted row's id renames the moved row")
    @MainActor func moveOntoAnEvictedRowRenamesTheRow() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let maxLoaded = SyncConfig.maxLoadedMessages
        let rowCount = maxLoaded + SyncConfig.inboxPageSize
        let now = Date()
        try await pool.write { db in
            for n in 0..<rowCount {
                var header = MessageHeader(
                    messageId: "\(1000 + n)", subject: "Row \(n)",
                    from: "sender@example.com", fromAddress: "sender@example.com",
                    to: "me@example.com", date: now.addingTimeInterval(-Double(n) * 60),
                    snippet: "body", folderId: inbox.id, accountId: "acc1",
                    folderPath: inbox.path, isInInbox: true)
                header.headerComplete = true
                try header.insert(db)
            }
        }
        let vm = InboxViewModel(folders: [inbox])
        while vm.loadedMessages.count < rowCount, vm.hasMoreMessages {
            let loaded = vm.loadedMessages.count
            vm.loadMoreMessages()
            if vm.loadedMessages.count == loaded { break }
        }
        let loadedCount = vm.loadedMessages.count
        #expect(loadedCount == rowCount, "setup: every page is loaded before the eviction runs")
        // The eviction trims the newest rows on a later main-actor turn.
        let evicted = try #require(vm.loadedMessages.first)
        let moved = try #require(vm.loadedMessages.last)
        for _ in 0..<Config.evictionSettleYields where vm.loadedMessages.count > maxLoaded {
            await Task.yield()
        }
        let evictedStillShown = vm.loadedMessages.contains { $0.id == evicted.id }
        #expect(!evictedStillShown, "setup: the eviction removed the newest row")
        let countBefore = vm.loadedMessages.count

        vm.applyHeaderRekeys(MailPointerMoves([move(moved.id, evicted.id)]))

        let renamed = vm.loadedMessages.filter { $0.id == evicted.id }.map(\.subject)
        #expect(renamed == [moved.subject])
        let movedStillShown = vm.loadedMessages.contains { $0.id == moved.id }
        #expect(!movedStillShown)
        let countAfter = vm.loadedMessages.count
        #expect(countAfter == countBefore)
    }

    /// A move that names its own id keeps the row.
    @Test("A move onto its own id keeps the row")
    @MainActor func moveOntoItsOwnIdKeepsTheRow() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let id = try insertHeader(
            pool, messageId: "301", folderId: inbox.id, folderPath: inbox.path, isInInbox: true)
        let vm = InboxViewModel(folders: [inbox])
        let before = rows(vm)
        #expect(before == ["\(id) Test"], "setup: the list shows the row")

        vm.applyHeaderRekeys(MailPointerMoves([move(id, id)]))

        let after = rows(vm)
        #expect(after == before)
        let members = groupMemberIds(vm)
        #expect(members == [id])
    }

    /// Two moves of one post onto one id the list does not show: the first
    /// row in the list takes the id, the other is dropped.
    @Test("Two moves of one post onto one new id leave one row with that id")
    @MainActor func twoMovesOntoOneIdLeaveOneRow() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let firstId = try insertHeader(
            pool, messageId: "401", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "First")
        let secondId = try insertHeader(
            pool, messageId: "402", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "Second")
        let newId = MessageIdentity.headerId(accountId: "acc1", folderPath: inbox.path, messageId: "403")
        let vm = InboxViewModel(folders: [inbox])
        let before = vm.loadedMessages.map(\.id)
        #expect(before.sorted() == [firstId, secondId].sorted(), "setup: the list shows both rows")
        let leading = try #require(vm.loadedMessages.first)

        vm.applyHeaderRekeys(MailPointerMoves([move(firstId, newId), move(secondId, newId)]))

        let after = rows(vm)
        #expect(after == ["\(newId) \(leading.subject)"])
        let members = groupMemberIds(vm)
        #expect(members == [newId])
    }

    /// A post that moves one shown row onto another while that one moves on
    /// keeps both emails: each takes its new id.
    @Test("A chain of moves in one post keeps every email")
    @MainActor func chainOfMovesInOnePostKeepsEveryEmail() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        let firstId = try insertHeader(
            pool, messageId: "501", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "First")
        let secondId = try insertHeader(
            pool, messageId: "502", folderId: inbox.id, folderPath: inbox.path, isInInbox: true,
            subject: "Second")
        let lastId = MessageIdentity.headerId(accountId: "acc1", folderPath: inbox.path, messageId: "503")
        let vm = InboxViewModel(folders: [inbox])
        let before = vm.loadedMessages.map(\.id)
        #expect(before.sorted() == [firstId, secondId].sorted(), "setup: the list shows both rows")

        vm.applyHeaderRekeys(MailPointerMoves([move(firstId, secondId), move(secondId, lastId)]))

        let after = rows(vm).sorted()
        #expect(after == ["\(secondId) First", "\(lastId) Second"].sorted())
        let members = groupMemberIds(vm).sorted()
        #expect(members == [secondId, lastId].sorted())
    }

    @Test("Provider re-key immediately updates the visible row and dismissed identity")
    @MainActor func providerRekeyKeepsVisibleRowActionable() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
            MessageHeaderRekey.clearAddressHandoffsForTesting()
        }
        clearOverlay()
        MessageHeaderRekey.clearAddressHandoffsForTesting()

        let oldId = try insertHeader(
            pool,
            messageId: "101",
            folderId: inbox.id,
            folderPath: inbox.path,
            isInInbox: true)
        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.contains { $0.id == oldId })

        let newId = MessageIdentity.headerId(
            accountId: "acc1", folderPath: inbox.path, messageId: "102")
        let record = HeaderRekeyRecord(
            oldHeaderId: oldId,
            newHeaderId: newId,
            newProviderMessageId: "102",
            newObservedUidValidity: 41)
        try await pool.write { db in
            var row = try MessageHeader.fetchOne(db, key: oldId)!
            _ = try row.delete(db)
            row.id = newId
            row.messageId = "102"
            row.observedUidValidity = 41
            try row.insert(db)
            MessageHeaderRekey.publishAddressHandoffsAfterCommit([record], in: db)
        }

        #expect(vm.lookupMessage(oldId)?.id == newId,
                "the provider handoff must be visible before slower mirror publication")
        vm.applyHeaderRekeys(MailPointerMoves([.row(record)]))

        #expect(!vm.loadedMessages.contains { $0.id == oldId })
        #expect(vm.loadedMessages.contains {
            $0.id == newId && $0.messageId == "102" && $0.observedUidValidity == 41
        })
        #expect(vm.lookupMessage(newId)?.id == newId,
                "a second Delete now resolves the provider-proven row immediately")
        // The list knows the row as loaded under its new id: an undo insert
        // of that id adds no second row.
        vm.insertUndoneMessages([newId])
        let rowsWithNewId = vm.loadedMessages.filter { $0.id == newId }.count
        #expect(rowsWithNewId == 1)
        #expect(MailPointerMoves([.row(record)]).following(headers: [oldId, "unrelated"])
            == [newId, "unrelated"],
            "dismissed/fading sets must follow the same key so hidden moves stay hidden")
    }

    @Test("Weak re-key follows navigation without carrying optimistic action state")
    @MainActor func weakRekeyKeepsActionStateOnTheUnprovenKey() {
        let oldId = "acc1:INBOX:weak-old"
        let newId = "acc1:INBOX:weak-new"
        let record = HeaderRekeyRecord(
            oldHeaderId: oldId,
            newHeaderId: newId,
            newProviderMessageId: "weak-new",
            carriesProviderAuthority: false)
        var dismissed: Set<String> = [oldId]
        var fading: Set<String> = [oldId]
        var selected: String? = oldId

        HeaderRekeyReceiver.apply(
            MailPointerMoves([.row(record)]),
            dismissedMessages: &dismissed,
            swipeFadingMessages: &fading,
            selectedMessageId: &selected)

        #expect(dismissed == [oldId])
        #expect(fading == [oldId])
        #expect(selected == newId)
    }

    @Test("Provider-proven re-key carries action and navigation state")
    @MainActor func providerRekeyCarriesAllPresentationState() {
        let oldId = "acc1:INBOX:proved-old"
        let newId = "acc1:INBOX:proved-new"
        let record = HeaderRekeyRecord(
            oldHeaderId: oldId,
            newHeaderId: newId,
            newProviderMessageId: "proved-new")
        var dismissed: Set<String> = [oldId]
        var fading: Set<String> = [oldId]
        var selected: String? = oldId

        HeaderRekeyReceiver.apply(
            MailPointerMoves([.row(record)]),
            dismissedMessages: &dismissed,
            swipeFadingMessages: &fading,
            selectedMessageId: &selected)

        #expect(dismissed == [newId])
        #expect(fading == [newId])
        #expect(selected == newId)
    }
}
