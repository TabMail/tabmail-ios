/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R13-U14 — the page cursor must name the deepest row, not the last one
//
// INVARIANT (system property): **scrolling past a page whose rows were re-tagged
// after they were loaded still yields a full page of NEW rows.** Nothing here
// asserts which expression computes the cursor; what is pinned is the outcome
// the loose cursor destroyed — the next page is full, contains no row already on
// screen, and leaves `hasMoreMessages` true with ~140 rows still unread.
//
// The mechanism, for whoever reads a failure: `loadedMessages` is sorted when
// BUILT and does not stay that way. `tagSortOrder` is not immutable for a loaded
// row — the AI queue, delta sync, full sync and manual tagging all change it —
// and `reloadMessages` Pass 1 writes the fresh row into the STALE row's index
// without repositioning it (deliberately: repositioning is @Observable churn and
// jumps the scroll position). So the array's LAST element stops being its
// MAXIMUM. A cursor read from the last element then sits ABOVE rows already on
// screen; the SQL keyset predicate re-admits them, they burn `LIMIT` slots, and
// `excludeIds` drops them AFTER the limit. The page comes back short and
// `hasMoreMessages` flips false with the rest of the mailbox unreachable.
//
// Triage-only by construction: in `.normal` neither the comparator nor the SQL
// predicate reads `tagSortOrder`, so the array cannot go out of order this way.
// The `.normal` control below states that positively rather than assuming it.

@Suite("R13-U14 — pagination survives rows re-tagged after loading", .serialized, .processGlobalState)
struct InboxPaginationCursorTests {

    /// Rank 1 is the NEWEST. `date` is strictly decreasing in rank, so a row's
    /// rank is its position in a pure date-descending order.
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func date(rank: Int) -> Date { base.addingTimeInterval(TimeInterval(-rank * 600)) }

    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, folder: Folder, dir: URL, previous: AppDatabase?) {
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
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = folder; try f.insert(db) }
        return (pool, folder, dir, previous)
    }

    /// 190 rows, laid out so the first triage page is `[R1…R40, U1…U10]`:
    ///
    ///   * ranks  1–10  — `U1…U10`,  untagged (`tagSortOrder` 99), NEWEST dates
    ///   * ranks 11–50  — `R1…R40`,  `.reply` (`tagSortOrder` 0)
    ///   * ranks 51–190 — `U11…U150`, untagged
    ///
    /// Triage orders by `(tagSortOrder ASC, date DESC)`, so the 40 reply rows
    /// come first and the 10 newest untagged rows finish the 50-row page. The
    /// dates are the point: when `R1…R40` lose their tag they land in bucket 99
    /// at ranks 11–50, i.e. immediately BELOW the page's last row — near the top
    /// of everything a cursor at that row admits, which is what lets them eat a
    /// whole `LIMIT`.
    @MainActor
    private func seed(_ pool: DatabasePool, folder: Folder) throws -> (replies: [String], newest: [String]) {
        var replies: [String] = []
        var newest: [String] = []
        for rank in 1...190 {
            let isReply = (11...50).contains(rank)
            var h = MessageHeader(
                messageId: String(format: "%04d", rank),
                subject: "Msg \(rank)", from: "s@example.com", fromAddress: "s@example.com",
                to: "me@example.com", date: date(rank: rank), snippet: "s",
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true)
            if isReply { h.setActionTag(.reply) }
            // `headerComplete` defaults to FALSE in the model and the inbox
            // reader's predicate requires it — without this the VM loads nothing.
            h.headerComplete = true
            try pool.writeWithoutTransaction { [h] db in try h.insert(db) }
            if isReply { replies.append(h.id) }
            if rank <= 10 { newest.append(h.id) }
        }
        return (replies, newest)
    }

    @Test("R13-U14 — a page whose rows were re-tagged after loading still pages forward into new rows")
    @MainActor
    func retaggedRowsDoNotEatTheNextPage() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let (replies, newest) = try seed(pool, folder: folder)

        let vm = InboxViewModel(folders: [folder])
        vm.mode = .triage
        vm.start()
        // NOT `loadInitialPage()` — `InboxViewModel.init` already ran it (with the
        // default `.normal` mode) and its `hasLoadedInitialPage` guard makes a
        // second call a no-op, so the mode set above would never reach a fetch.
        vm.resetMessages()

        #expect(vm.loadedMessages.count == SyncConfig.inboxPageSize, "setup: one full triage page")
        #expect(vm.loadedMessages.prefix(40).map(\.id) == replies, "setup: the reply bucket leads the page")
        #expect(vm.loadedMessages.last?.id == newest.last, "setup: the page ends on the 10th-newest untagged row")
        #expect(vm.hasMoreMessages)

        // THE MUTATION — the 40 loaded reply rows lose their tag (an AI
        // re-classification, a delta sync, or the user clearing them). They move
        // to bucket 99 at ranks 11–50: BELOW the page's last row (rank 10).
        try await pool.write { db in
            for id in replies {
                try db.execute(sql: "UPDATE messageHeader SET actionTag = NULL, tagSortOrder = 99, actionTagSetAt = NULL WHERE id = ?",
                               arguments: [id])
            }
        }
        await vm.reloadMessages()

        // THE PREMISE, ASSERTED RATHER THAN ASSUMED. If Pass 1 ever starts
        // repositioning, these two stop holding and this test would otherwise go
        // quietly vacuous — it would pass while pinning nothing (`MIS-030`).
        #expect(vm.loadedMessages.count == SyncConfig.inboxPageSize, "the reload kept the same 50 rows")
        let keys = vm.loadedMessages.map(InboxOrdering.key)
        let sorted = zip(keys, keys.dropFirst()).allSatisfy { !InboxOrdering.areInIncreasingOrder($1, $0, mode: .triage) }
        #expect(!sorted, "premise: the in-place reload left `loadedMessages` out of order — if it no longer does, this test proves nothing")
        #expect(vm.loadedMessages.last?.id == newest.last,
                "premise: the array's LAST element is no longer its MAXIMUM — that gap is the defect")

        // THE INVARIANT.
        let before = Set(vm.loadedMessages.map(\.id))
        vm.loadMoreMessages()
        let added = vm.loadedMessages.filter { !before.contains($0.id) }

        #expect(added.count == SyncConfig.inboxPageSize,
                "the next page came back short (\(added.count)) — rows already on screen were re-admitted by the keyset predicate, burned the SQL LIMIT, and were dropped by excludeIds after it")
        #expect(vm.loadedMessages.count == 2 * SyncConfig.inboxPageSize)
        #expect(Set(vm.loadedMessages.map(\.id)).count == vm.loadedMessages.count, "no row was loaded twice")
        #expect(vm.hasMoreMessages,
                "with 140 rows still unfetched, exhaustion here strands the rest of the mailbox: a later page never asks for them and a refresh rebuilds the same window")
    }

    /// CONTROL — the same fixture in `.normal` mode never reaches the defect,
    /// because neither the comparator nor the SQL predicate reads
    /// `tagSortOrder` there. Without this, "pagination works" could be a
    /// property of the fixture rather than of the cursor.
    @Test("CONTROL — .normal pagination is unaffected by the same re-tagging, since its order never reads tagSortOrder")
    @MainActor
    func normalModePagesForwardRegardless() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let (replies, _) = try seed(pool, folder: folder)

        let vm = InboxViewModel(folders: [folder])
        vm.mode = .normal
        vm.start()
        // NOT `loadInitialPage()` — `InboxViewModel.init` already ran it (with the
        // default `.normal` mode) and its `hasLoadedInitialPage` guard makes a
        // second call a no-op, so the mode set above would never reach a fetch.
        vm.resetMessages()
        #expect(vm.loadedMessages.count == SyncConfig.inboxPageSize)

        try await pool.write { db in
            for id in replies {
                try db.execute(sql: "UPDATE messageHeader SET actionTag = NULL, tagSortOrder = 99, actionTagSetAt = NULL WHERE id = ?",
                               arguments: [id])
            }
        }
        await vm.reloadMessages()

        let before = Set(vm.loadedMessages.map(\.id))
        vm.loadMoreMessages()
        let added = vm.loadedMessages.filter { !before.contains($0.id) }
        #expect(added.count == SyncConfig.inboxPageSize)
        #expect(vm.hasMoreMessages)
    }
}
