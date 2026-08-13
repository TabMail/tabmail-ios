/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// INVARIANT: **a message whose move destination is a folder the displayed list
/// renders is VISIBLE in that list after the move.**
///
/// Owner report (2026-08-11): *"i moved a mail from archive to inbox, by searching for
/// it and then opening, and moving, but then it didn't appear in inbox until i exited
/// and re-entered inbox."*
///
/// `InboxView` hides a row by inserting its id into the `@State` set
/// `dismissedMessages`, and renders `visibleGroups = displayGroups − dismissedMessages`.
/// Every insert asserts *"the action took this message OUT of the folders this list
/// renders"*. That premise is structurally true for archive and delete — their
/// destination is a fixed archive/trash-role folder — and **false for a move whose
/// destination is one of the rendered folders**. There is no un-dismiss path for a row
/// that simply came back, so the row stayed invisible for the life of the `@State`;
/// destroying it by leaving and re-entering the list was the only recovery.
///
/// These tests assert on the **visible set**, not on the predicate's boolean or on the
/// dismissal set's contents, so they stay valid if the mechanism is replaced. The
/// dismissal bookkeeping below is `InboxView`'s, reproduced at the two decision sites:
///  - the `.messageDismissedFromDetail` receiver (the owner's path — a move from a
///    search-opened detail view, which posts its destination folder id), and
///  - `performSingleMove`, the in-list move sheet (`moveDestinationIsDisplayed`).
///
/// Both directions are pinned: a destination INSIDE the displayed set must NOT hide the
/// row, and a destination OUTSIDE it still MUST (otherwise "never dismiss" would pass).
///
/// `.serialized` / `.processGlobalState`: swaps `AppDatabase.shared` and touches the
/// `AccountManager.shared` overlay, mirroring `InboxListBehaviorPinningTests`.
@Suite("Move into a displayed folder keeps the row visible", .serialized, .processGlobalState)
@MainActor
struct InboxMoveIntoDisplayedFolderVisibilityTests {

    // MARK: - Harness (mirrors InboxListBehaviorPinningTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    private func insertHeader(
        _ pool: DatabasePool, folder: Folder, messageId: String, date: Date
    ) throws -> String {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender",
            fromAddress: "s@example.com", to: "me@example.com", date: date, snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        try pool.writeWithoutTransaction { db in try h.insert(db) }
        return h.id
    }

    /// Reproduce what `AccountManagerActions.optimisticMoveToFolder` writes: the row's
    /// `folderId`/`folderPath`/`isInInbox` follow the destination immediately, while its
    /// **primary key keeps naming the source address** until `MessageHeaderRekey.finishMove`
    /// re-keys it at drain time (THE ADDRESS PROBLEM). The owner's log shows exactly this
    /// state — `id=…:Archive:55922 folderId=…:INBOX folderPath=INBOX` — and it is the id
    /// that a dismissal names, so the test must not skip it.
    private func applyOptimisticMove(
        _ pool: DatabasePool, storedId: String, destination: Folder
    ) throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = ? WHERE id = ?",
                arguments: [destination.id, destination.path, destination.role == .inbox, storedId])
        }
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    /// `InboxView`'s `visibleGroups`, verbatim.
    private func visibleIds(_ vm: InboxViewModel, dismissed: Set<String>) -> [String] {
        vm.displayGroups
            .filter { !dismissed.contains($0.representative.id) }
            .map(\.representative.id)
    }

    // MARK: - 1. The owner's gesture: move from a search-opened detail view

    @Test("Archive → Inbox from the detail view leaves the row visible in the inbox list")
    func detailMoveIntoDisplayedInboxStaysVisible() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // The message lives in Archive and is NOT in the inbox list — the owner reached it
        // through search, so the list never had it.
        let storedId = try insertHeader(pool, folder: archive, messageId: "55922", date: Date())
        let vm = InboxViewModel(folders: [inbox], selection: .unified(.inbox))
        await vm.reloadMessages()
        #expect(!visibleIds(vm, dismissed: []).contains(storedId),
                "precondition: the Archive message must not already be in the inbox list")

        // The move records and the durable row follows the destination.
        try applyOptimisticMove(pool, storedId: storedId, destination: inbox)

        // `MessageDetailView.handleMove` → `dismissMessage(destinationFolderId:)` names the
        // destination; `InboxView`'s `.messageDismissedFromDetail` receiver decides from it.
        let destinationFolderId = MessageIdentity.folderId(
            accountId: "acc1", folderPath: inbox.path)
        var dismissed: Set<String> = []
        if !vm.displaysFolder(destinationFolderId) {
            dismissed.insert(storedId)
        }

        // The reader picks the row up in its new folder…
        await vm.reloadMessages()
        #expect(vm.displayGroups.contains { $0.representative.id == storedId },
                "the moved row must be composed into the inbox list")

        // …and the INVARIANT: it is visible, without leaving and re-entering the list.
        #expect(visibleIds(vm, dismissed: dismissed).contains(storedId),
                "a message moved INTO a displayed folder must be visible after the move")
    }

    // MARK: - 2. Negative case: a destination outside the displayed set still hides

    @Test("Inbox → Archive from the detail view still hides the row")
    func detailMoveOutOfDisplayedInboxStillHides() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let storedId = try insertHeader(pool, folder: inbox, messageId: "1001", date: Date())
        let vm = InboxViewModel(folders: [inbox], selection: .unified(.inbox))
        await vm.reloadMessages()
        #expect(visibleIds(vm, dismissed: []).contains(storedId),
                "precondition: the inbox message must start visible")

        // Archive is not a folder this list renders, so the dismissal is correct — the row
        // must disappear at once rather than waiting for the reader to drop it.
        let destinationFolderId = MessageIdentity.folderId(
            accountId: "acc1", folderPath: archive.path)
        var dismissed: Set<String> = []
        if !vm.displaysFolder(destinationFolderId) {
            dismissed.insert(storedId)
        }
        #expect(!visibleIds(vm, dismissed: dismissed).contains(storedId),
                "a message moved OUT of the displayed folders must be hidden immediately")
    }

    // MARK: - 3. The in-list move sheet (`performSingleMove`)

    @Test("The move sheet keeps a row visible when its destination is a displayed folder")
    func moveSheetIntoDisplayedInboxStaysVisible() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // An ADR-IOS-055 "P" row: durably in Archive, pinned into the displayed inbox by an
        // optimistic overlay mutation. `MoveFolderPicker` excludes the DURABLE folder, so it
        // offers this row the very inbox it is already showing in.
        let storedId = try insertHeader(pool, folder: archive, messageId: "55923", date: Date())
        AccountManager.shared.registerMutation(
            id: storedId, mutation: .init(folderId: inbox.id, folderPath: inbox.path, isInInbox: true))
        let vm = InboxViewModel(folders: [inbox], selection: .unified(.inbox))
        await vm.reloadMessages()
        #expect(visibleIds(vm, dismissed: []).contains(storedId),
                "precondition: the overlay-pinned row must start visible in the inbox list")

        // `InboxView.performSingleMove`'s decision.
        var dismissed: Set<String> = []
        if !vm.moveDestinationIsDisplayed(storedId, toFolderPath: inbox.path) {
            dismissed.insert(storedId)
        }
        #expect(visibleIds(vm, dismissed: dismissed).contains(storedId),
                "a move sheet destination inside the displayed folders must not hide the row")
    }

    @Test("The move sheet still hides a row whose destination leaves the displayed folders")
    func moveSheetOutOfDisplayedInboxStillHides() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let storedId = try insertHeader(pool, folder: inbox, messageId: "1002", date: Date())
        let vm = InboxViewModel(folders: [inbox], selection: .unified(.inbox))
        await vm.reloadMessages()
        #expect(visibleIds(vm, dismissed: []).contains(storedId),
                "precondition: the inbox message must start visible")

        var dismissed: Set<String> = []
        if !vm.moveDestinationIsDisplayed(storedId, toFolderPath: archive.path) {
            dismissed.insert(storedId)
        }
        #expect(!visibleIds(vm, dismissed: dismissed).contains(storedId),
                "a move sheet destination outside the displayed folders must hide the row")
    }
}
