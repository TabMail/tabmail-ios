/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The catch-up's cost, its range bounds, its load floor before the older-mail
/// walk starts, and its load failures (#1062). Same world as
/// `IMAPMissingByUIDTests`.
extension IMAPMissingByUIDTests {

    /// The listing requests (`UID FETCH ... (UID FLAGS)`, no ENVELOPE) and the
    /// SEARCHes among `commands`.
    static func listingCost(_ commands: some Collection<String>) -> (fetches: Int, searches: Int) {
        let upper = commands.map { $0.uppercased() }
        let fetches = upper.filter { $0.contains("FETCH") && $0.contains("FLAGS") && !$0.contains("ENVELOPE") }.count
        let searches = upper.filter { $0.contains("SEARCH") }.count
        return (fetches, searches)
    }

    // MARK: - a listing's cost scales with the folder, not its UID space

    /// UIDNEXT 2,000,001, 300 messages in three clusters. A listing sized from
    /// EXISTS and UIDNEXT is one range: one listing FETCH and one membership
    /// SEARCH, whatever the UID span.
    static let sparseServer = Array(1...100) + Array(1_000_001...1_000_100) + Array(1_999_901...2_000_000)

    @Test("A sparse folder (UIDNEXT 2,000,001, 300 messages): a full listing costs a few requests, not one per thousand UIDs, and loads what was missing")
    @MainActor
    func sparseFolderListingCostScalesWithMessages() async throws {
        let server = Self.sparseServer
        try await Self.withWorld("a1-sparse", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let missing = [50, 1_000_050, 1_999_950]
            try await w.dropLocal(missing)
            try w.expectNotHeld(missing, "#1062")
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            try await w.workerRun()
            let cost = Self.listingCost(w.server.recordedCommands().dropFirst(start))
            // Ceiling: the ranges EXISTS / catchUpListingRangeMessages calls for
            // (one here), each a FETCH and a SEARCH, plus one header load's SEARCH.
            let ranges = (server.count + SyncConfig.catchUpListingRangeMessages - 1) / SyncConfig.catchUpListingRangeMessages
            #expect(cost.fetches >= 1, "#1062: setup: the listing ran")
            #expect(cost.fetches <= ranges, "#1062: one listing FETCH per sized range, not per 1000 UIDs: \(cost.fetches)")
            #expect(cost.searches <= ranges + 1, "#1062: one membership SEARCH per sized range: \(cost.searches)")
            try w.expectHeldExactly(server, "#1062")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled")
        }
    }

    @Test("A sparse untracked folder on a CONDSTORE server without QRESYNC, listed again after each HIGHESTMODSEQ change: every repeat costs a few requests")
    @MainActor
    func condstoreRepeatListingStaysCheap() async throws {
        let server = Self.sparseServer
        let condstore = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE"]
        try await Self.withWorld("a1-condstore", capabilities: condstore, server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let ranges = (server.count + SyncConfig.catchUpListingRangeMessages - 1) / SyncConfig.catchUpListingRangeMessages
            // The world's warm-up listing ran with no stored HIGHESTMODSEQ, so it
            // recorded no completion stamp and the MODSEQ check has nothing to
            // compare. The foreground sync stores the server's HIGHESTMODSEQ;
            // the owed listing that follows records it as its stamp.
            try await w.foregroundSync()
            try await w.markOwed()
            try await w.workerRun()
            let warmServerModSeq = w.server.qresyncHighestModSeq(for: Self.path)
            let warmStored = try w.folder().lastKnownHighestModSeq
            let warmStamp = try IMAPCatchUpState.decode(w.folder().catchUpState)?.completionStamp
            #expect(warmStamp == warmServerModSeq,
                    "setup: the warm-up listing records the stored HIGHESTMODSEQ as its stamp: stamp \(String(describing: warmStamp)), stored \(String(describing: warmStored)), server \(warmServerModSeq)")
            for (repeatIndex, uid) in [10, 1_000_010, 1_999_910].enumerated() {
                // Another client reads a message: HIGHESTMODSEQ moves.
                w.server.setFlags(["\\Seen"], in: Self.path, uid: uid)
                // Diagnostic (#1062): the stored HIGHESTMODSEQ the catch-up's
                // MODSEQ check compares, before and after the foreground sync.
                let storedBefore = try w.folder().lastKnownHighestModSeq
                let serverModSeq = w.server.qresyncHighestModSeq(for: Self.path)
                try await w.foregroundSync()
                let storedAfter = try w.folder().lastKnownHighestModSeq
                let stamp = try IMAPCatchUpState.decode(w.folder().catchUpState)?.completionStamp
                #expect(storedAfter == serverModSeq,
                        "#1062 repeat \(repeatIndex): the foreground sync stores the server's HIGHESTMODSEQ: before \(String(describing: storedBefore)), after \(String(describing: storedAfter)), server \(serverModSeq), completion stamp \(String(describing: stamp))")
                let start = w.server.recordedCommands().count
                try await w.workerRun()
                let cost = Self.listingCost(w.server.recordedCommands().dropFirst(start))
                // Diagnostic (#1062): what the catch-up's plan saw: the change
                // bookmark (a tracked folder skips the MODSEQ check, ADR-IOS-111)
                // and the completion stamp the cheap check compares.
                let bookmark = try w.folder().changeCursor
                let tracked = IMAPChangeCursor.decode(bookmark) != nil
                let stampAfter = try IMAPCatchUpState.decode(w.folder().catchUpState)?.completionStamp
                #expect(cost.fetches >= 1, "#1062 repeat \(repeatIndex): setup: the MODSEQ change listed the folder again (tracked \(tracked), bookmark \(bookmark ?? "nil"), stamp before the run \(String(describing: stamp)), after \(String(describing: stampAfter)), stored MODSEQ \(String(describing: storedAfter)), server \(serverModSeq))")
                #expect(cost.fetches <= ranges && cost.searches <= ranges,
                        "#1062 repeat \(repeatIndex): a few requests per listing: \(cost)")
            }
            try w.expectHeldExactly(server, "#1062 repeat")
        }
    }

    // MARK: - a FETCH record outside the range is not part of the listing

    @Test("An unsolicited FETCH for a missing message beyond the range being listed, whose header cannot be read, does not move the listing past a missing message in between")
    @MainActor
    func unsolicitedFetchBeyondTheRangeIsIgnored() async throws {
        let server = Array(1...20) + Array(1001...1060)
        let between = 1005, beyond = 1050
        try await Self.withWorld("c1-unsolicited", server: server, local: server) { w in
            var messages = server.map(Self.message)
            messages[server.firstIndex(of: beyond)!] = Self.message(beyond, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [beyond])
            try await w.dropLocal([between, beyond])
            try await w.markOwed()
            // The first range is 1:1000; another client's change to UID 1050 rides on its FETCH.
            w.server.injectUnsolicitedFetch(in: Self.path, uid: beyond, flags: [])
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            #expect(try w.held().contains(between),
                    "#1062: the message between the range and the unsolicited UID is reached and loaded in the same slice")
            #expect(!(try w.held()).contains(beyond), "#1062: setup: the unreadable one is not loaded")
        }
    }

    // MARK: - before the older-mail walk starts

    @Test("Wi-Fi-only on cellular, the older-mail walk not started: 120 arrivals beyond the window are all held after one catch-up")
    @MainActor
    func arrivalsBeyondTheWindowLoadBeforeTheWalkStarts() async throws {
        let arrivals = 120
        try #require(arrivals > SyncConfig.syncMessageLimit, "setup: more arrivals than the window lists")
        let all = Array(1...(20 + arrivals))
        try await Self.withWorld("c2-walk-not-started", server: Array(1...20), local: Array(1...20), walkStarted: false) { w in
            // The rows came from a window listing, which records how far down it reached.
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == 1, "setup: the window listing recorded its floor")
            w.server.setMessages(all.map(Self.message), in: Self.path)
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            let afterWindow = Set(try w.held())
            #expect(!Set(all).isSubset(of: afterWindow), "#1062: setup: the window listing alone leaves a gap")
            // The backfill cycle with the walk held back (Wi-Fi-only off Wi-Fi):
            // the catch-up is a scan and runs anyway.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runBackfillCycle(account: try w.account(), walkAllowed: false)
            try w.expectHeldExactly(all, "#1062")
            let folder = try w.folder()
            #expect(!folder.backfillComplete && folder.backfillUidCursor == nil, "#1062: setup: the walk has still not started")
        }
    }

    // MARK: - a header batch that fails as a whole

    /// Which header batch fails.
    enum FailedBatch: Int, CaseIterable, Sendable {
        /// The first: nothing loads, so the range is held.
        case first = 1
        /// The second: the first batch's messages load, so the listing moves
        /// to the failed batch without starting a hold.
        case second = 2
    }

    @Test("A header batch whose FETCH fails as a whole: earlier batches keep what they loaded, the listing resumes at the failed batch, and the next slice loads the rest and settles",
          arguments: FailedBatch.allCases)
    @MainActor
    func failedHeaderBatchResumesThere(_ failed: FailedBatch) async throws {
        let server = Array(1...60) + Array(1001...1060)
        let missing = Array(11...50)
        try #require(missing.count > SyncConfig.catchUpLoadBatchSize, "setup: more than one header batch")
        try await Self.withWorld("t5-\(failed)", server: server, local: server) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            w.server.failCommand(containing: "ENVELOPE", onMatch: failed.rawValue)
            await w.slice(clock: clock)
            w.server.stopFailingCommands(containing: "ENVELOPE")
            let held = Set(try w.held())
            let firstBatch = Array(missing.prefix(SyncConfig.catchUpLoadBatchSize))
            let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing is in progress")
            switch failed {
            case .first:
                #expect(held.isDisjoint(with: missing), "#1062: nothing loaded")
                #expect(listing.nextUid == missing[0], "#1062: the listing resumes at the failed batch")
                #expect(listing.loadHeldSince != nil, "#1062: a stop with nothing loaded is held, so it is bounded")
            case .second:
                #expect(Set(firstBatch).isSubset(of: held), "#1062: the first batch's messages stay loaded")
                #expect(listing.nextUid == missing[SyncConfig.catchUpLoadBatchSize], "#1062: the listing resumes at the failed batch")
                #expect(listing.loadHeldSince == nil, "#1062: loads that moved before the stop start no hold")
            }
            #expect((try w.changeState()).selfHealDue, "#1062: still owed")
            await w.slice(clock: clock)
            try w.expectHeldExactly(server, "#1062 \(failed)")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing that loaded everything settles the mark")
        }
    }

    // MARK: - an owed folder outside the syncable set

    @Test("A folder outside the syncable set that is owed a check is listed by the catch-up, its missing message loaded and its mark cleared")
    @MainActor
    func owedNonSyncableFolderIsCheckedAndSettled() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("t2-non-syncable", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET role = ?, isFavorite = 0 WHERE id = ?",
                               arguments: [FolderRole.custom.rawValue, folderId])
            }
            let folder = try w.folder()
            #expect(!SyncEngine.isSyncable(role: folder.role, isFavorite: folder.isFavorite), "#1062: setup: not syncable")
            try await w.dropLocal([7])
            try await w.markOwed()
            try await w.workerRun()
            try w.expectHeldExactly(server, "#1062")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the owed mark clears")
        }
    }

    // MARK: - unanswered, and gone by SEARCH

    @Test("A missing message expunged between the listing and its header load: counted done, not held, and the listing completes clean")
    @MainActor
    func unansweredAndGoneCountsAsDone() async throws {
        let server = Array(1...20) + Array(1001...1060)
        let expunged = 12
        try await Self.withWorld("t4-gone", server: server, local: server) { w in
            try await w.dropLocal([expunged])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            // The listing FETCH reads the mailbox with UID 12 in it; before it
            // answers, another client expunges 12, so its header load answers
            // nothing and the SEARCH finds it gone.
            w.server.holdNextFetchAfterSnapshot(in: Self.path)
            let slice = Task { @MainActor in await w.slice(clock: clock) }
            var polls = 0
            while !w.server.isHoldingFetchAfterSnapshot(in: Self.path), polls < Self.suspensionPolls {
                try await Task.sleep(for: .milliseconds(10))
                polls += 1
            }
            let suspended = w.server.isHoldingFetchAfterSnapshot(in: Self.path)
            let remaining = server.filter { $0 != expunged }
            if suspended { w.server.setMessages(remaining.map(Self.message), in: Self.path) }
            w.server.releaseFetchAfterSnapshot(in: Self.path)
            await slice.value
            try #require(suspended, "#1062: setup: the listing FETCH was suspended")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completes; the gone message holds nothing")
            #expect(!(try w.changeState()).selfHealDue, "#1062: a message gone from the server counts as done: the completion is clean")
            try w.expectHeldExactly(remaining, "#1062")
        }
    }

    // MARK: - the storage prune keeps a clean UID floor on IMAP

    /// A date `uid` maps to, decorrelated from the UID: a permutation of the
    /// last `count` days, so the newest-dated message is not the highest UID.
    static func decorrelatedDate(_ uid: Int, count: Int) -> Date {
        Date().addingTimeInterval(-Double((uid * 37) % count + 1) * 86_400)
    }

    @Test("Under a storage limit, an IMAP Archive whose dates and UIDs are decorrelated is pruned to its top UIDs, and one catch-up afterwards neither lists for load nor fetches any pruned UID; a Gmail folder in the same prune keeps date order")
    @MainActor
    func storagePruneKeepsTheTopUIDsAndTheCatchUpDoesNotReloadThem() async throws {
        let count = 120
        let server = Array(1...count)
        try await Self.withWorld("r2-prune", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                for uid in server {
                    let date = Self.decorrelatedDate(uid, count: count)
                    try db.execute(sql: "UPDATE messageHeader SET date = ?, providerDate = ? WHERE folderId = ? AND messageId = ?",
                                   arguments: [date, date, folderId, "\(uid)"])
                }
            }
            // The Gmail control: the same shape, pruned in its own order (date).
            let gmailId = "missing-by-uid-r2-prune-gmail"
            _ = try FolderEpochTestFixture.makeAccount(id: gmailId, provider: .gmail, pool: w.pool)
            try FolderEpochTestFixture.insertFolder(accountId: gmailId, path: "Label_1", role: .archive, pool: w.pool)
            try FolderEpochTestFixture.insertHeaders(accountId: gmailId, path: "Label_1", uids: server, pool: w.pool)
            let gmailFolderId = "\(gmailId):Label_1"
            try await w.pool.write { db in
                for uid in server {
                    let date = Self.decorrelatedDate(uid, count: count)
                    try db.execute(sql: "UPDATE messageHeader SET date = ?, providerDate = ? WHERE folderId = ? AND messageId = ?",
                                   arguments: [date, date, gmailFolderId, "\(uid)"])
                }
            }
            let gmail = MockEmailProvider(staleWindowMode: .date)
            await w.engine.register(accountId: gmailId, provider: gmail,
                                    workQueue: ProviderWorkQueue(provider: gmail, maxConcurrency: 1))
            // An account whose provider is not registered: the prune has no order
            // for it and prunes it oldest date first, as before #1062.
            let unregisteredId = "missing-by-uid-r2-prune-unregistered"
            _ = try FolderEpochTestFixture.makeAccount(id: unregisteredId, provider: .imap, pool: w.pool)
            try FolderEpochTestFixture.insertFolder(accountId: unregisteredId, path: Self.path, role: .archive, pool: w.pool)
            try FolderEpochTestFixture.insertHeaders(accountId: unregisteredId, path: Self.path, uids: server, pool: w.pool)
            let unregisteredFolderId = "\(unregisteredId):\(Self.path)"
            // A body for every IMAP row: the body pass prunes in the same order.
            try await w.pool.write { db in
                let ids = try String.fetchAll(db, sql: "SELECT id FROM messageHeader WHERE folderId = ?", arguments: [folderId])
                for id in ids {
                    try db.execute(sql: """
                        INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                        VALUES (?, '<p>body</p>', NULL, ?, NULL)
                        """, arguments: [id, Date()])
                }
            }

            // Over the limit whatever this store's size: a padding file larger
            // than the limit, so the prune runs to its floor in every folder.
            let savedBudget = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
            defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }
            StorageEstimator.budgetMB = 1
            let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let padding = appSupport.appendingPathComponent("prune-test-padding-\(UUID().uuidString)")
            try Data(count: 2 * 1024 * 1024).write(to: padding)
            defer { try? FileManager.default.removeItem(at: padding) }
            try #require(StorageEstimator.isOverBudget(), "setup: the store is over the limit, so the prune runs to its floor")

            // The prune, in each account's order as the engine resolves it.
            let order = await w.engine.pruneOrderByAccount()
            #expect(order[w.accountId] == .uid && order[gmailId] == .date, "setup: each account's order comes from its provider")
            SyncEngine.runPruneIfOverBudget(dbPool: AppDatabase.backgroundPool, pruneOrder: order)

            let floor = StorageEstimator.floorPerFolder
            let newestDated = server.sorted {
                Self.decorrelatedDate($0, count: count) > Self.decorrelatedDate($1, count: count)
            }
            let held = try w.held()
            let gmailHeld = try await w.pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [gmailFolderId])
            }.compactMap(Int.init)
            let bodiesKept = try await w.pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT h.messageId FROM messageBody b JOIN messageHeader h ON h.id = b.id WHERE h.folderId = ?
                    """, arguments: [folderId])
            }.compactMap(Int.init).sorted()

            // How many: each folder keeps exactly `floorPerFolder`. The header
            // pass deletes whole chunks while over the limit and ends below the
            // floor (tabmail-ios#1112); this fails until that is fixed.
            withKnownIssue("#1112: the header prune deletes whole chunks and ends below the per-folder floor") {
                #expect(held == Array((count - floor + 1)...count), "#1062: the IMAP folder keeps exactly its top \(floor) UIDs")
                #expect(Set(gmailHeld) == Set(newestDated.prefix(floor)), "#1062 control: the Gmail folder keeps its newest-dated \(floor) messages")
                #expect(bodiesKept == Array((count - floor + 1)...count), "#1062: the top \(floor) UIDs keep their bodies")
            }

            // Which, whatever the count: a UID-ordered folder keeps a top run of
            // UIDs (a clean floor), a date-ordered one its newest-dated, and the
            // bodies kept are a top run of UIDs too.
            try #require(!held.isEmpty && held.count < count, "setup: the prune removed some and kept some: \(held.count)")
            let topUIDs = Array((count - held.count + 1)...count)
            #expect(held == topUIDs, "#1062: the IMAP folder keeps a top run of UIDs: \(held)")
            let pruned = Set(server).subtracting(topUIDs)
            #expect(!gmailHeld.isEmpty && Set(gmailHeld) == Set(newestDated.prefix(gmailHeld.count)),
                    "#1062 control: the Gmail folder keeps its newest-dated \(gmailHeld.count) messages")
            #expect(!bodiesKept.isEmpty && bodiesKept == Array((count - bodiesKept.count + 1)...count),
                    "#1062: bodies are pruned in the same UID order: a top run of UIDs keeps theirs: \(bodiesKept)")
            let unregisteredHeld = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ?", arguments: [unregisteredFolderId]) ?? 0
            }
            #expect(order[unregisteredId] == nil && unregisteredHeld < count,
                    "#1062: an account with no registered provider is still pruned: \(unregisteredHeld) of \(count) kept")

            // One catch-up under the limit, owed a full listing.
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: true, deadline: Date().addingTimeInterval(60),
                sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
                clock: { Date() })
            run.listingRangeMessages = w.rangeMessages
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
            let headerFetches = w.server.recordedCommands().dropFirst(start).filter {
                $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            let fetchedAgain = pruned.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            #expect(fetchedAgain.isEmpty, "#1062: no pruned UID's header is downloaded again: \(fetchedAgain.sorted().prefix(20))")
            #expect(try w.held() == topUIDs, "#1062: the held set is still the top \(topUIDs.count) UIDs")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled")
        }
    }

    // MARK: - a later scroll page does not reopen what the prune removed

    /// Rows of `uids` cached by another path (an infinite scroll page by date):
    /// the server's messages, under the folder's epoch.
    @MainActor
    static func cacheScrolledRows(_ w: World, _ uids: [Int]) async throws {
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: path, uids: uids, pool: w.pool)
        let folderId = w.folderId
        try await w.pool.write { db in
            for uid in uids {
                try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = ?, observedUidValidity = ? WHERE folderId = ? AND messageId = ?",
                               arguments: ["<missing-by-uid-\(uid)@example.com>", epoch, folderId, "\(uid)"])
            }
        }
    }

    /// One catch-up run under a storage limit; the header FETCHes it sent.
    @MainActor
    static func runUnderTheLimit(_ w: World) async throws -> [String] {
        let start = w.server.recordedCommands().count
        var run = SyncEngine.CatchUpRun(
            storageLimitInForce: true, deadline: Date().addingTimeInterval(60),
            sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
            clock: { Date() })
        run.listingRangeMessages = w.rangeMessages
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
        return w.server.recordedCommands().dropFirst(start).filter {
            $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
        }
    }

    @Test("Under a storage limit, after the prune with the older-mail walk complete, a sparse scroll page caches two low pruned UIDs: a catch-up loads none of the UIDs pruned between them and the kept rows, and still applies a flag change and an expunge on the cached rows")
    @MainActor
    func scrollPageAfterThePruneDoesNotReopenThePrunedRange() async throws {
        let count = 120
        let server = Array(1...count)
        try await Self.withWorld("prune-scroll", server: server, local: server) { w in
            #expect(try w.folder().backfillComplete, "setup: the older-mail walk is complete")
            // Over the limit whatever this store's size: a padding file larger
            // than the limit, so the prune runs to its floor.
            let savedBudget = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
            defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }
            StorageEstimator.budgetMB = 1
            let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let padding = appSupport.appendingPathComponent("prune-test-padding-\(UUID().uuidString)")
            try Data(count: 2 * 1024 * 1024).write(to: padding)
            defer { try? FileManager.default.removeItem(at: padding) }
            try #require(StorageEstimator.isOverBudget(), "setup: the store is over the limit, so the prune runs")
            SyncEngine.runPruneIfOverBudget(dbPool: AppDatabase.backgroundPool, pruneOrder: await w.engine.pruneOrderByAccount())

            let kept = try w.held()
            try #require(!kept.isEmpty && kept.count < count && kept == Array(kept[0]...count),
                         "setup: the prune kept a top run of UIDs: \(kept)")
            let pruned = Array(1..<kept[0])
            try #require(pruned.count > 4, "setup: the prune removed enough to leave a pruned range above the scroll page")
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == pruned.last,
                    "#1062: the prune recorded where it reached, with the folder's epoch")

            // A sparse scroll page caches two low pruned UIDs; another client
            // reads one and expunges the other.
            let flagged = pruned[0], expunged = pruned[2]
            try await Self.cacheScrolledRows(w, [flagged, expunged])
            w.server.setMessages(server.filter { $0 != expunged }.map(Self.message), in: Self.path)
            w.server.setFlags(["\\Seen"], in: Self.path, uid: flagged)
            try await w.markOwed()
            let headerFetches = try await Self.runUnderTheLimit(w)

            let reopened = pruned.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            #expect(reopened.isEmpty, "#1062: no pruned UID is downloaded again: \(reopened.prefix(20))")
            try w.expectHeldExactly([flagged] + kept, "#1062: the expunged cached row is gone, and nothing pruned is loaded")
            let folderId = w.folderId
            let isRead = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                  arguments: [folderId, "\(flagged)"])
            }
            #expect(isRead == true, "#1062: the flag change on the cached row below the cutoff is applied")
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == pruned.last,
                    "#1062: the catch-up's state write carries the cutoff")
        }
    }

    @Test("Under a storage limit with a cached row below the prune cutoff, a catch-up loads nothing at or below a cutoff recorded in the folder's epoch, and ignores one recorded in another epoch",
          arguments: [true, false])
    @MainActor
    func pruneCutoffCountsOnlyInItsEpoch(sameEpoch: Bool) async throws {
        let scrolled = 5, cutoff = 20
        let server = Array(1...40)
        let kept = Array((cutoff + 1)...40)
        try await Self.withWorld("prune-epoch-\(sameEpoch)", server: server, local: server) { w in
            // The prune took everything below the cutoff; a scroll page cached one row back.
            try await w.dropLocal(server.filter { $0 != scrolled && $0 <= cutoff })
            let folderId = w.folderId
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpPruneCutoff(
                    folderId: folderId, highest: cutoff, epoch: sameEpoch ? Self.epoch : Self.epoch + 1, db: db)
            }
            try await w.markOwed()
            _ = try await Self.runUnderTheLimit(w)
            let between = Array((scrolled + 1)...cutoff)
            try w.expectHeldExactly([scrolled] + (sameEpoch ? [] : between) + kept,
                                    sameEpoch ? "#1062: nothing at or below the cutoff loads, the cached row is kept"
                                              : "#1062: a cutoff of another epoch is not read: the missing mail above the first local UID loads")
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == (sameEpoch ? cutoff : scrolled - 1),
                    sameEpoch ? "#1062: the catch-up carries the cutoff under its epoch"
                              : "#1062: the other epoch's cutoff is never rebound; the folder gets its one-time cutoff in this epoch, below its first local UID")
        }
    }

    @Test("With no storage limit a prune cutoff loads nothing differently: the missing mail at or below it loads, and no cutoff is seeded")
    @MainActor
    func pruneCutoffCountsOnlyUnderALimit() async throws {
        let scrolled = 5, cutoff = 20
        let server = Array(1...40)
        try await Self.withWorld("prune-no-limit", server: server, local: server) { w in
            try await w.dropLocal(server.filter { $0 != scrolled && $0 <= cutoff })
            let folderId = w.folderId
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: cutoff, epoch: Self.epoch, db: db)
            }
            try await w.markOwed()
            try await w.workerRun()
            try w.expectHeldExactly(server, "#1062: with no limit the cutoff is not a floor: everything missing loads")
        }
    }

    @Test("A folder pruned before the cutoff existed (no cutoff stored): under a storage limit the catch-up seeds ONE cutoff below the first local UID, so nothing pruned loads, and a scroll page cached lower later does not move it; with no limit nothing is seeded and the missing mail loads",
          arguments: [true, false])
    @MainActor
    func legacyPruneIsSeededOnceUnderALimit(limit: Bool) async throws {
        let server = Array(1...40)
        let pruned = Array(1...20), kept = Array(21...40)
        try await Self.withWorld("prune-seed-\(limit)", server: server, local: server) { w in
            try await w.dropLocal(pruned)
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == nil, "setup: no cutoff stored")
            try await w.markOwed()
            guard limit else {
                try await w.workerRun()
                try w.expectHeldExactly(server, "#1062 control: with no limit the missing mail loads")
                #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == nil,
                        "#1062 control: with no limit no cutoff is seeded")
                return
            }
            var loads = try await Self.runUnderTheLimit(w)
            var reloaded = pruned.filter { uid in loads.contains { Self.uidSet($0).contains(uid) } }
            #expect(reloaded.isEmpty, "#1062: nothing pruned before the cutoff existed is downloaded again: \(reloaded)")
            try w.expectHeldExactly(kept, "#1062: the held rows are the kept ones")
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == kept[0] - 1,
                    "#1062: the one-time cutoff is one below the first local UID, in the folder's epoch")

            // A scroll page caches a low pruned row; the seed is not taken again.
            try await Self.cacheScrolledRows(w, [pruned[1]])
            try await w.markOwed()
            loads = try await Self.runUnderTheLimit(w)
            reloaded = pruned.filter { uid in loads.contains { Self.uidSet($0).contains(uid) } }
            #expect(reloaded.isEmpty, "#1062: a later scroll page does not reopen the pruned range: \(reloaded)")
            try w.expectHeldExactly([pruned[1]] + kept, "#1062: only the cached row and the kept rows are held")
            #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == kept[0] - 1,
                    "#1062: the cutoff is seeded once and never re-derived from a lower first local UID")
        }
    }

    @Test("The prune records a cutoff only for a UID prune order, and only from rows it deleted that carry the folder's epoch: a date-order prune records none; rows of no known numbering (one an optimistic move brought in under its source UID, one written before the stamp) never move it",
          arguments: [true, false])
    @MainActor
    func pruneCutoffComesOnlyFromFolderNativeRowsInUIDOrder(uidOrder: Bool) async throws {
        let count = 120
        let server = Array(1...count)
        let stamped = Array(1...3)
        try await Self.withWorld("prune-native-\(uidOrder)", server: server, local: server) { w in
            let folderId = w.folderId
            if uidOrder {
                // Only the three lowest rows carry the folder's epoch.
                try await w.pool.write { db in
                    try db.execute(sql: """
                        UPDATE messageHeader SET observedUidValidity = NULL
                        WHERE folderId = ? AND CAST(messageId AS INTEGER) > ?
                        """, arguments: [folderId, stamped.count])
                }
            }
            let savedBudget = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
            defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }
            StorageEstimator.budgetMB = 1
            let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let padding = appSupport.appendingPathComponent("prune-test-padding-\(UUID().uuidString)")
            try Data(count: 2 * 1024 * 1024).write(to: padding)
            defer { try? FileManager.default.removeItem(at: padding) }
            try #require(StorageEstimator.isOverBudget(), "setup: the store is over the limit, so the prune runs")
            SyncEngine.runPruneIfOverBudget(dbPool: AppDatabase.backgroundPool, pruneOrder: [w.accountId: uidOrder ? .uid : .date])
            let held = try w.held()
            try #require(held.count < count, "setup: the prune deleted rows: \(held.count) of \(count) kept")
            let cutoff = CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch)
            if uidOrder {
                try #require(!held.contains { stamped.contains($0) } && held.first.map { $0 > stamped.count + 1 } == true,
                             "setup: the prune deleted the stamped rows and unstamped ones above them")
                #expect(cutoff == stamped.last,
                        "#1062: only deleted rows carrying the folder's epoch move the cutoff: \(String(describing: cutoff))")
            } else {
                #expect(cutoff == nil, "#1062: a date-order prune records no cutoff: \(String(describing: cutoff))")
            }
        }
    }

    @Test("The prune cutoff's bookkeeping: the highest value recorded in an epoch, never lowered; one of another epoch replaced; a NULL or non-object state becomes an object holding it")
    @MainActor
    func pruneCutoffIsKeptPerEpoch() async throws {
        try await Self.withWorld("prune-books", server: Array(1...10), local: Array(1...10)) { w in
            let folderId = w.folderId
            func record(_ highest: Int, _ epoch: Int) async throws {
                try await w.pool.write { db in
                    try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: highest, epoch: epoch, db: db)
                }
            }
            func cutoff(_ epoch: Int) throws -> Int? { CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: epoch) }
            try await record(7, Self.epoch)
            try await record(4, Self.epoch)
            #expect(try cutoff(Self.epoch) == 7, "#1062: a lower value in the same epoch never lowers the cutoff")
            try await record(9, Self.epoch)
            #expect(try cutoff(Self.epoch) == 9, "#1062: a higher value in the same epoch raises it")
            try await record(3, Self.epoch + 1)
            #expect(try cutoff(Self.epoch + 1) == 3 && cutoff(Self.epoch) == nil,
                    "#1062: a value of another epoch replaces the old one, which is no longer read")
            #expect(IMAPCatchUpState.decode(try w.folder().catchUpState) != nil, "#1062: the provider still reads its own state")
            for raw in [nil, "not json", "[1, 2]"] as [String?] {
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
                }
                try await record(6, Self.epoch)
                #expect(try cutoff(Self.epoch) == 6, "#1062: a state \(raw ?? "NULL") becomes an object holding the cutoff")
            }
        }
    }
}
