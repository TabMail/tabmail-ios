/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// ADR-IOS-107: the catch-up of server-side changes to OLDER mail (run by the
/// backfill worker after the folders' walk since #766; before it, by the full sync) —
/// a read/flag change or a removal on a message no sync window reaches again.
///
/// Every case drives the real `IMAPProvider.catchUp` against `FakeIMAPServer` (the
/// wire oracle) and applies through the real `SyncEngine.runCatchUp`, then asserts
/// what the user would see: the local rows' read/flag state and which rows exist.
/// The mechanism (which request ran, what the state string holds) is asserted only
/// where the invariant IS about the wire (no request when nothing is due).
///
/// `.serialized, .processGlobalState` — every case binds a listening socket and
/// swaps `AppDatabase.shared`; the trait also clears `recentlyCompleted`
/// (`IOS-TEST-006`), which is keyed by bare UIDs these fixtures reuse.
@Suite("ADR-IOS-107 — IMAP catch-up of older mail", .serialized, .processGlobalState)
struct IMAPCatchUpTests {

    private static let epoch: UInt32 = 71_404
    private static let path = "Archive"
    private static let capabilities = FakeIMAPServer.defaultCapabilities + ["CONDSTORE"]

    private static func message(_ uid: Int) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: catch-up fixture \(uid)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -uid))\r
        Message-ID: <catch-up-\(uid)@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    /// One prepared world: a server holding `serverUIDs` in Archive, and a local
    /// Archive folder holding `localUIDs`, all unread and unflagged locally.
    private struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let accountId: String
        var folderId: String { "\(accountId):\(IMAPCatchUpTests.path)" }
    }

    private static func withWorld(
        _ name: String, serverUIDs: [Int], localUIDs: [Int],
        storedEpoch: UInt32? = IMAPCatchUpTests.epoch,
        otherMailboxes: [String: [Int]] = [:],
        capabilities: [String] = IMAPCatchUpTests.capabilities,
        _ body: (World) async throws -> Void
    ) async throws {
        var mailboxes: [String: [FakeIMAPServer.Message]] = ["INBOX": [], path: serverUIDs.map(message)]
        for (name, uids) in otherMailboxes { mailboxes[name] = uids.map(message) }
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: mailboxes)
        server.setUidValidity(Int(epoch), for: path)
        for name in otherMailboxes.keys { server.setUidValidity(Int(epoch), for: name) }
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        _ = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: name, path: path, role: .archive, pool: pool,
            totalCount: serverUIDs.count, lastKnownUidValidity: storedEpoch.map { Int($0) })
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: path, uids: localUIDs, pool: pool)

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let world = World(server: server, provider: provider, engine: SyncEngine(), pool: pool, accountId: name)
        try await refreshModSeq(world)
        try await body(world)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// What the full sync's folder upsert does before the catch-up runs: write this
    /// pass's STATUS HIGHESTMODSEQ to the folder row.
    private static func refreshModSeq(_ world: World, path: String = IMAPCatchUpTests.path) async throws {
        let infos = try await world.provider.fetchFolders()
        let modseq = try #require(infos.first { $0.path == path }?.highestModSeq,
                                  "precondition: a CONDSTORE server reports HIGHESTMODSEQ in STATUS")
        let folderId = "\(world.accountId):\(path)"
        try await world.pool.write { db in
            try db.execute(sql: "UPDATE folder SET lastKnownHighestModSeq = ? WHERE id = ?", arguments: [modseq, folderId])
        }
    }

    private static func pass(_ world: World, context: CatchUpContext = unlimited()) async {
        await world.engine.runCatchUp(provider: world.provider, folderIds: [world.folderId], context: context)
    }

    /// About how many messages one listing range holds here: 1, so every range
    /// has the minimum width (`SyncConfig.catchUpListingMinRangeSpan` UIDs), the
    /// layout these fixtures place their messages across (#1062).
    static let rangeMessages = 1

    /// A budget that never runs out.
    private static func unlimited() -> CatchUpContext {
        CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: rangeMessages)
    }

    /// A budget of exactly ONE listing request per pass: the clock advances one
    /// second per `UID FETCH` the server has seen since the pass began.
    private static func oneRangePerPass(_ server: FakeIMAPServer) -> CatchUpContext {
        let start = Date()
        let fetchesBefore = fetchCount(server)
        return CatchUpContext(
            deadline: start.addingTimeInterval(1),
            clock: { start.addingTimeInterval(Double(fetchCount(server) - fetchesBefore)) },
            listingRangeMessages: rangeMessages)
    }

    /// Runs `body` with NetworkMonitor's cached expensive flag set to `expensive`
    /// (its debug-only test hook), restoring the prior value afterwards, so a test
    /// never depends on the network of the machine it runs on.
    private static func withNetwork(expensive: Bool, _ body: () async throws -> Void) async throws {
        let saved = NetworkMonitor.checkExpensiveIfKnown()
        NetworkMonitor.setExpensiveForTesting(expensive)
        defer { NetworkMonitor.setExpensiveForTesting(saved) }
        try await body()
    }

    private static func fetchCount(_ server: FakeIMAPServer) -> Int {
        server.recordedCommands().filter { $0.uppercased().hasPrefix("UID FETCH") }.count
    }

    private static func rows(_ world: World, path: String = IMAPCatchUpTests.path) throws -> [String: (isRead: Bool, isFlagged: Bool)] {
        let folderId = "\(world.accountId):\(path)"
        return try world.pool.read { db in
            var out: [String: (isRead: Bool, isFlagged: Bool)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT messageId, isRead, isFlagged FROM messageHeader WHERE folderId = ?", arguments: [folderId]) {
                out[row["messageId"]] = (row["isRead"], row["isFlagged"])
            }
            return out
        }
    }

    private static func state(_ world: World) throws -> IMAPCatchUpState? {
        let folderId = world.folderId
        let raw = try world.pool.read { db in
            try String.fetchOne(db, sql: "SELECT catchUpState FROM folder WHERE id = ?", arguments: [folderId])
        }
        return IMAPCatchUpState.decode(raw)
    }

    private static func setState(_ state: IMAPCatchUpState?, _ world: World) throws {
        let folderId = world.folderId
        let raw = state?.encoded()
        try world.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    private static func storedModSeq(_ world: World) throws -> Int? {
        let folderId = world.folderId
        return try world.pool.read { db in try Folder.fetchOne(db, key: folderId)?.lastKnownHighestModSeq }
    }

    // MARK: - Wiring

    /// The step runs in the backfill worker (#766): after one `fullSync`, a
    /// foreground backfill call (`runBackfill`, the worker's cycle) leaves every
    /// syncable folder with a known epoch with a completed catch-up state.
    /// *Superseded (#1063):* "Enabled only on a non-expensive network, because the
    /// first listing of a folder is a full check, which waits for one."
    /// *Superseded:* "The step sits at the end of
    /// the real full sync: after one `fullSync`, every syncable folder [...]".
    @Test("A backfill cycle after the full sync runs the catch-up")
    func backfillCycleRunsTheCatchUp() async throws {
        try await Self.withNetwork(expensive: false) { () async throws in
            try await Self.withWorld("cu-wiring", serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { world in
                let accountId = world.accountId
                let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
                await world.engine.register(
                    accountId: world.accountId, provider: world.provider,
                    workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
                try await world.engine.fullSync(account: account, provider: world.provider)
                _ = await world.engine.runBackfill(account: account)

                let state = try #require(try Self.state(world), "the backfill cycle wrote the folder's catch-up state")
                #expect(state.epoch == Self.epoch && state.listing == nil && state.lastCompletedAt != nil)
                #expect(try Self.rows(world).count == 3, "every message is still on the server; nothing is removed")
            }
        }
    }

    /// A folder the full sync itself creates (here INBOX, which no fixture
    /// pre-inserts) must be on the cheap check from its first listing.
    @Test("A folder the full sync created follows an older-mail change on the next pass")
    func newFolderIsOnTheCheapCheck() async throws {
        try await Self.withNetwork(expensive: false) { () async throws in
            try await Self.withWorld("cu-new-folder", serverUIDs: [1], localUIDs: [1], otherMailboxes: ["INBOX": [1, 2, 3]]) { world in
                let accountId = world.accountId
                let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
                await world.engine.register(
                    accountId: world.accountId, provider: world.provider,
                    workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
                try await world.engine.fullSync(account: account, provider: world.provider)
                _ = await world.engine.runBackfill(account: account)
                #expect(try Self.rows(world, path: "INBOX")["1"]?.isRead == false, "precondition: the full sync brought INBOX in, unread")
                let inboxId = "\(accountId):INBOX"
                let inboxState = IMAPCatchUpState.decode(try await world.pool.read { db in try Folder.fetchOne(db, key: inboxId)?.catchUpState })
                #expect(inboxState?.lastCompletedAt != nil, "precondition: the backfill cycle completed INBOX's first listing")

                world.server.setFlags(["\\Seen"], in: "INBOX", uid: 1)
                try await Self.refreshModSeq(world, path: "INBOX")
                await world.engine.runCatchUp(provider: world.provider, folderIds: ["\(accountId):INBOX"], context: Self.unlimited())

                #expect(try Self.rows(world, path: "INBOX")["1"]?.isRead == true,
                        "the change moved HIGHESTMODSEQ past the first listing's stamp, so the folder is listed again")
            }
        }
    }

    // MARK: - The headline

    @Test("A read/flag change on older mail is applied")
    func olderMailFlagChangeIsApplied() async throws {
        try await Self.withWorld("cu-flags", serverUIDs: [1, 2, 3, 4], localUIDs: [1, 2, 3, 4]) { world in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            world.server.setFlags(["\\Flagged"], in: Self.path, uid: 4)
            await Self.pass(world)

            let rows = try Self.rows(world)
            #expect(rows["2"]?.isRead == true, "another client read UID 2; the local row must follow")
            #expect(rows["4"]?.isFlagged == true, "another client flagged UID 4; the local row must follow")
            #expect(rows["1"]?.isRead == false && rows["3"]?.isRead == false, "unchanged messages stay unchanged")
            #expect(rows.count == 4, "a flags pass removes nothing that is present")
            let state = try #require(try Self.state(world))
            #expect(state.listing == nil && state.lastCompletedAt != nil, "the listing completed and says so")
        }
    }

    @Test("A removal applies only when the server proves it; a short FETCH removes nothing")
    func removalOnlyWhenProven() async throws {
        // Server holds 1, 2, 4, 5. UID 3 was expunged elsewhere. UID 5 is present but
        // its FETCH record goes missing (the `[IMAP-FETCH-GAP]` shape).
        try await Self.withWorld("cu-remove", serverUIDs: [1, 2, 4, 5], localUIDs: [1, 2, 3, 4, 5]) { world in
            world.server.suppressFetchRecord(in: Self.path, uids: [5])
            await Self.pass(world)

            let rows = try Self.rows(world)
            #expect(rows["3"] == nil, "UID 3 is gone from the server; its local row must go")
            #expect(rows["5"] != nil, "UID 5 is still on the server; a short FETCH is not proof it left")
            #expect(Set(rows.keys) == ["1", "2", "4", "5"])
        }
    }

    @Test("A queued flag op wins over the server's value")
    func pendingOpWins() async throws {
        try await Self.withWorld("cu-pending", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            // The user marked UID 2 unread locally; the op has not drained yet, and the
            // server still says read.
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            let accountId = world.accountId
            try await world.pool.write { db in
                var op = PendingOperation(type: .markUnread, messageIds: ["2"], accountId: accountId, folderPath: Self.path)
                try op.insert(db)
            }
            await Self.pass(world)

            let rows = try Self.rows(world)
            #expect(rows["2"]?.isRead == false, "the user's queued action is newer than the server's state")
            #expect(rows["1"]?.isRead == true, "the protection is per message, not per folder")
        }
    }

    /// The race the in-transaction read exists for: the user's op drained (so it is
    /// no longer pending) after the listing read the server's older value.
    @Test("A just-completed user action wins over a stale listing")
    func recentCompletionWins() async throws {
        try await Self.withWorld("cu-recent", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["2"])
            await Self.pass(world)

            let rows = try Self.rows(world)
            #expect(rows["2"]?.isRead == false, "the user's completed action is newer than the listing")
            #expect(rows["1"]?.isRead == true, "the protection is per message, not per folder")
        }
    }

    // MARK: - The catch-up is not the backfill

    /// A folder with a partial backfill: the device holds UIDs 4...6 of a mailbox
    /// that runs from 1 to 10. The catch-up loads nothing below the load floor and
    /// still reconciles the flags and removals of the rows the device holds.
    @Test("With a partial backfill, nothing below the load floor is inserted and cached rows are still reconciled")
    func staysInsideTheLocalRange() async throws {
        try await Self.withWorld("cu-frontier", serverUIDs: [1, 2, 3, 4, 6, 7, 8, 9, 10], localUIDs: [4, 5, 6]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 6)
            let before = world.server.recordedCommands().count
            await Self.pass(world)

            let sent = world.server.recordedCommands().dropFirst(before)
                .filter { $0.uppercased().hasPrefix("UID FETCH") || $0.uppercased().hasPrefix("UID SEARCH") }
            #expect(sent.contains { $0.uppercased().hasPrefix("UID FETCH") }, "precondition: the folder was listed")
            #expect(sent.contains { $0.uppercased().hasPrefix("UID SEARCH") }, "precondition: the removal proof ran")
            let rows = try Self.rows(world)
            // Nothing below the load floor (the lowest UID the device holds) is inserted.
            let belowFloor = rows.keys.compactMap { Int($0) }.filter { $0 < 4 }
            #expect(belowFloor.isEmpty, "a message below the load floor was inserted: \(belowFloor.sorted())")
            // Cached reconciliation still runs: UID 5's removal is proven and UID 6's flag is updated.
            #expect(rows["5"] == nil, "the cached row the server expunged is removed")
            #expect(Set(rows.keys) == ["4", "6"], "UID 5 is gone from the server; no other row appears: \(rows.keys.sorted())")
            #expect(rows["6"]?.isRead == true)
        }
    }

    // MARK: - Resume, restart, and the first-stamp invariant

    @Test("No request starts after the budget is spent, the removal proof included")
    func removalProofWaitsForBudget() async throws {
        // UID 2 is gone from the server. The budget ends after the range's FETCH.
        try await Self.withWorld("cu-proof-budget", serverUIDs: [1], localUIDs: [1, 2]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            let before = world.server.recordedCommands().count
            await Self.pass(world, context: Self.oneRangePerPass(world.server))

            let searches = world.server.recordedCommands().dropFirst(before).filter { $0.uppercased().hasPrefix("UID SEARCH") }
            #expect(searches.isEmpty, "the removal proof is a request; it must not start after the budget: \(searches)")
            #expect(try Self.rows(world)["2"] != nil, "an unproven removal applies nothing")
            #expect(try Self.rows(world)["1"]?.isRead == true, "the range's flags still count")
            #expect(try Self.state(world)?.listing?.nextUid == 1, "the cursor stays, so the range is listed again")

            await Self.pass(world)
            #expect(try Self.rows(world)["2"] == nil, "the next pass proves and applies the removal")
        }
    }

    // MARK: - A request that stalls or fails

    /// The budget is checked before a request starts; only the per-request timeout
    /// bounds one that does not come back.
    @Test("A stalled listing request is abandoned at the request timeout and applies nothing")
    func stalledListingIsAbandoned() async throws {
        try await Self.withWorld("cu-stall-fetch", serverUIDs: [1, 2], localUIDs: [1, 2]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            let timeout = SyncConfig.catchUpRequestTimeoutSeconds
            world.server.stallNextCommand(containing: "UID FETCH", seconds: timeout * 2)

            let started = Date()
            await Self.pass(world)
            let elapsed = Date().timeIntervalSince(started)

            #expect(elapsed < timeout * 1.5, "the pass waited \(elapsed) s for a request whose timeout is \(timeout) s")
            #expect(try Self.rows(world)["1"]?.isRead == false, "an unanswered listing applies nothing")
            #expect(try Self.state(world)?.lastCompletedAt == nil, "and completes nothing")
        }
    }

    @Test("A stalled removal proof is abandoned at the request timeout and removes nothing")
    func stalledRemovalProofIsAbandoned() async throws {
        try await Self.withWorld("cu-stall-search", serverUIDs: [1], localUIDs: [1, 2]) { world async throws in
            let timeout = SyncConfig.catchUpRequestTimeoutSeconds
            world.server.stallNextCommand(containing: "UID SEARCH", seconds: timeout * 2)

            let started = Date()
            await Self.pass(world)
            let elapsed = Date().timeIntervalSince(started)

            #expect(elapsed < timeout * 1.5, "the pass waited \(elapsed) s for a request whose timeout is \(timeout) s")
            #expect(try Self.rows(world)["2"] != nil, "an unanswered proof removes nothing")
            #expect(try Self.state(world)?.lastCompletedAt == nil)
        }
    }

    @Test("A failed listing request keeps what earlier ranges proved and resumes at the failed range")
    func failedListingKeepsProvenRanges() async throws {
        try await Self.withWorld("cu-fail-fetch", serverUIDs: [1, 2001], localUIDs: [1, 2001]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2001)
            world.server.failCommand(containing: "UID FETCH", onMatch: 2)
            await Self.pass(world)

            #expect(world.server.consumedInjectedFailureCount() == 1, "precondition: the second range's request failed")
            #expect(try Self.rows(world)["1"]?.isRead == true, "the first range's result is applied")
            #expect(try Self.rows(world)["2001"]?.isRead == false, "the failed range applies nothing")
            let state = try #require(try Self.state(world))
            #expect(state.lastCompletedAt == nil && state.completionStamp == nil, "a failed listing is not a completed one")
            let cursor = try #require(state.listing?.nextUid)
            #expect(cursor > 1 && cursor <= 2001, "the cursor sits at the failed range: \(cursor)")

            await Self.pass(world)
            #expect(try Self.rows(world)["2001"]?.isRead == true, "the next pass finishes the listing")
            #expect(try Self.state(world)?.lastCompletedAt != nil)
        }
    }

    @Test("A failed removal proof removes nothing, keeps the range's flags, and is retried")
    func failedRemovalProofRemovesNothing() async throws {
        try await Self.withWorld("cu-fail-search", serverUIDs: [1], localUIDs: [1, 2]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.failNextCommand(containing: "UID SEARCH")
            await Self.pass(world)

            #expect(world.server.consumedInjectedFailureCount() == 1, "precondition: the proof failed")
            #expect(try Self.rows(world)["2"] != nil, "a failed proof removes nothing")
            #expect(try Self.rows(world)["1"]?.isRead == true, "the range's flags still count")
            let state = try #require(try Self.state(world))
            #expect(state.listing?.nextUid == 1 && state.lastCompletedAt == nil, "the range is listed again")

            await Self.pass(world)
            #expect(try Self.rows(world)["2"] == nil, "the next pass proves and applies the removal")
        }
    }

    @Test("One folder's failed request does not cost the next folder its pass")
    func failureInOneFolderLeavesTheNext() async throws {
        let other = "Older"
        try await Self.withWorld("cu-fail-next", serverUIDs: [1], localUIDs: [1], otherMailboxes: [other: [1]]) { world async throws in
            try FolderEpochTestFixture.insertFolder(
                accountId: world.accountId, path: other, role: .custom, pool: world.pool,
                totalCount: 1, lastKnownUidValidity: Int(Self.epoch))
            try FolderEpochTestFixture.insertHeaders(accountId: world.accountId, path: other, uids: [1], pool: world.pool)
            let otherId = "\(world.accountId):\(other)"
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            // The caller's order holds for two folders never listed: Older goes first.
            world.server.failNextCommand(containing: "UID FETCH")
            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [otherId, world.folderId], context: Self.unlimited())

            #expect(world.server.consumedInjectedFailureCount() == 1, "precondition: the first folder's request failed")
            #expect(try Self.rows(world)["1"]?.isRead == true, "the second folder was still listed in the same pass")
        }
    }

    @Test("Under budget pressure the folder whose listing was tried longest ago goes first")
    func oldestCompletedFolderFirst() async throws {
        let other = "Older"
        try await Self.withWorld("cu-order", serverUIDs: [1], localUIDs: [1], otherMailboxes: [other: [1]]) { world in
            try FolderEpochTestFixture.insertFolder(
                accountId: world.accountId, path: other, role: .custom, pool: world.pool,
                totalCount: 1, lastKnownUidValidity: Int(Self.epoch))
            try FolderEpochTestFixture.insertHeaders(accountId: world.accountId, path: other, uids: [1], pool: world.pool)
            let otherId = "\(world.accountId):\(other)"
            let day = SyncConfig.catchUpFullCheckIntervalSeconds
            try Self.setState(IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-2 * day), listing: nil,
                lastAttemptAt: Date().addingTimeInterval(-2 * day)), world)
            let older = IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-3 * day), listing: nil,
                lastAttemptAt: Date().addingTimeInterval(-3 * day)).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [older, otherId])
            }
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.setFlags(["\\Seen"], in: other, uid: 1)

            // The caller names the newer-completed folder first; the budget allows one listing.
            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [world.folderId, otherId], context: Self.oneRangePerPass(world.server))

            #expect(try Self.rows(world, path: other)["1"]?.isRead == true, "the folder that waited longest was listed")
            #expect(try Self.rows(world)["1"]?.isRead == false, "the budget ended before the other folder")
        }
    }

    /// The bound on every folder's catch-up holds only if one folder cannot keep
    /// the front of the queue: each pass's budget goes to the folder that has
    /// waited longest since its last ATTEMPT.
    @Test("A folder whose request fails on every pass does not hold back the folder behind it")
    func failingFolderGoesToTheBack() async throws {
        let other = "Older"
        try await Self.withWorld("cu-starve", serverUIDs: [7], localUIDs: [7], otherMailboxes: [other: [1]]) { world async throws in
            try FolderEpochTestFixture.insertFolder(
                accountId: world.accountId, path: other, role: .custom, pool: world.pool,
                totalCount: 1, lastKnownUidValidity: Int(Self.epoch))
            try FolderEpochTestFixture.insertHeaders(accountId: world.accountId, path: other, uids: [1], pool: world.pool)
            let otherId = "\(world.accountId):\(other)"
            world.server.setFlags(["\\Seen"], in: other, uid: 1)
            // Both folders completed a listing before and are due again; the one that
            // will fail was tried longest ago, so it goes first.
            let day = SyncConfig.catchUpFullCheckIntervalSeconds
            try Self.setState(IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-3 * day), listing: nil,
                lastAttemptAt: Date().addingTimeInterval(-3 * day)), world)
            let behind = IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-2 * day), listing: nil,
                lastAttemptAt: Date().addingTimeInterval(-2 * day)).encoded()
            try await world.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [behind, otherId])
            }

            // Each pass's budget allows one listing request, and the first folder's fails.
            world.server.failNextCommand(containing: "UID FETCH 7")
            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [world.folderId, otherId], context: Self.oneRangePerPass(world.server))
            #expect(world.server.consumedInjectedFailureCount() == 1, "precondition: the first folder's request failed")
            #expect(try Self.rows(world, path: other)["1"]?.isRead == false, "precondition: the budget ended before the second folder")

            world.server.failNextCommand(containing: "UID FETCH 7")
            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [world.folderId, otherId], context: Self.oneRangePerPass(world.server))
            #expect(try Self.rows(world, path: other)["1"]?.isRead == true, "the folder behind the failing one got the next pass")
        }
    }

    @Test("A folder that completes a listing goes behind one not yet listed, even when it is due again")
    func completedFolderGoesToTheBack() async throws {
        let other = "Older"
        try await Self.withWorld("cu-rotate", serverUIDs: [7], localUIDs: [7], otherMailboxes: [other: [1]]) { world async throws in
            try FolderEpochTestFixture.insertFolder(
                accountId: world.accountId, path: other, role: .custom, pool: world.pool,
                totalCount: 1, lastKnownUidValidity: Int(Self.epoch))
            try FolderEpochTestFixture.insertHeaders(accountId: world.accountId, path: other, uids: [1], pool: world.pool)
            let otherId = "\(world.accountId):\(other)"
            world.server.setFlags(["\\Seen"], in: other, uid: 1)
            try await Self.refreshModSeq(world)

            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [world.folderId, otherId], context: Self.oneRangePerPass(world.server))
            #expect(try Self.state(world)?.lastCompletedAt != nil, "precondition: the first folder's listing completed")
            #expect(try Self.rows(world, path: other)["1"]?.isRead == false, "precondition: the budget ended before the second folder")

            // The first folder changes again, so it is due on the next pass too.
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 7)
            try await Self.refreshModSeq(world)
            await world.engine.runCatchUp(
                provider: world.provider, folderIds: [world.folderId, otherId], context: Self.oneRangePerPass(world.server))
            #expect(try Self.rows(world, path: other)["1"]?.isRead == true, "the folder not yet listed got the next pass")
        }
    }

    @Test("Budget exhaustion resumes on the next pass")
    func budgetExhaustionResumes() async throws {
        // Two listing ranges: [1, 1000] and [2001, 3000].
        try await Self.withWorld("cu-budget", serverUIDs: [1, 2001], localUIDs: [1, 2001]) { world in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2001)

            await Self.pass(world, context: Self.oneRangePerPass(world.server))
            #expect(try Self.rows(world)["2001"]?.isRead == false, "precondition: the budget ended the pass before the second range")
            let midway = try #require(try Self.state(world)?.listing, "an unfinished listing is recorded")
            #expect(midway.nextUid > 1, "the cursor advanced past the listed range")

            await Self.pass(world, context: Self.oneRangePerPass(world.server))
            #expect(try Self.rows(world)["2001"]?.isRead == true, "the next pass resumed where the last one stopped")
            #expect(try Self.state(world)?.listing == nil)
        }
    }

    @Test("A state from another UIDVALIDITY restarts the listing from the beginning")
    func uidValidityChangeRestartsListing() async throws {
        try await Self.withWorld("cu-restart", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            // A listing left half-way under an OLD epoch, past UID 1.
            try Self.setState(IMAPCatchUpState(
                epoch: Self.epoch - 1, completionStamp: nil, lastCompletedAt: nil,
                listing: .init(firstStamp: nil, nextUid: 2)), world)
            await Self.pass(world)

            #expect(try Self.rows(world)["1"]?.isRead == true, "the listing started again at UID 1")
            #expect(try Self.state(world)?.epoch == Self.epoch)
        }
    }

    @Test("A UIDVALIDITY turnover on the wire applies nothing and raises the reaction")
    func turnoverAppliesNothing() async throws {
        let raised = Mutex<[UInt32]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, observed in
            raised.withLock { $0.append(observed) }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        // The server renumbered: none of the local UIDs exists under the new epoch,
        // which is exactly the state in which a careless listing deletes everything.
        try await Self.withWorld("cu-turnover", serverUIDs: [7], localUIDs: [1, 2, 3]) { world async throws in
            world.server.setUidValidity(Int(Self.epoch + 1), for: Self.path)
            await Self.pass(world)

            #expect(try Self.rows(world).count == 3, "no row may be removed under a turned-over epoch (C3)")
            #expect(try Self.state(world) == nil, "nothing is written for the folder")
            #expect(raised.withLock { $0 } == [Self.epoch + 1], "the turnover reaction is raised")
        }
    }

    /// The same UIDs exist under the new epoch, so the range has no removal
    /// candidate and only the listing's own epoch check stands between the new
    /// numbering's flags and the old numbering's rows.
    @Test("A turnover that reuses the same UIDs applies no flags")
    func turnoverWithReusedUIDsAppliesNoFlags() async throws {
        let raised = Mutex<[UInt32]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, observed in
            raised.withLock { $0.append(observed) }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        try await Self.withWorld("cu-turnover-reuse", serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { world async throws in
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.setUidValidity(Int(Self.epoch + 1), for: Self.path)
            await Self.pass(world)

            #expect(try Self.rows(world)["1"]?.isRead == false, "a flag from another numbering is another message's (C3)")
            #expect(try Self.state(world) == nil, "nothing is written for the folder")
            #expect(raised.withLock { $0 } == [Self.epoch + 1], "the turnover reaction is raised")
        }
    }

    /// A listing in progress already knows the folder's top, so its call reads
    /// no UIDNEXT first: the range's own listing FETCH is the first request to
    /// see the new numbering, and its epoch check alone keeps that numbering's
    /// flags off the old rows.
    @Test("A turnover first seen by a resumed listing's range FETCH applies no flags")
    func turnoverSeenByAResumedListingAppliesNoFlags() async throws {
        let raised = Mutex<[UInt32]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, observed in
            raised.withLock { $0.append(observed) }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        let uids = [1, 2, 3]
        try await Self.withWorld("cu-turnover-resumed", serverUIDs: uids, localUIDs: uids) { world async throws in
            var listing = IMAPCatchUpState.Listing(firstStamp: nil, nextUid: 1)
            listing.top = uids.last
            let resumed = IMAPCatchUpState(epoch: Self.epoch, completionStamp: nil, lastCompletedAt: nil, listing: listing)
            try Self.setState(resumed, world)
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)
            world.server.setUidValidity(Int(Self.epoch + 1), for: Self.path)
            await Self.pass(world)

            #expect(try Self.rows(world)["1"]?.isRead == false, "a flag from another numbering is another message's (C3)")
            #expect(try Self.state(world) == resumed, "the listing in progress is left as it was")
            #expect(raised.withLock { $0 } == [Self.epoch + 1], "the turnover reaction is raised")
        }
    }

    @Test("A turnover between a range's listing and its removal proof removes nothing")
    func turnoverBeforeTheRemovalProofRemovesNothing() async throws {
        let raised = Mutex<[UInt32]>([])
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, observed in
            raised.withLock { $0.append(observed) }
        }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }
        // UID 3 is missing from the listing, so it is a removal candidate. The
        // mailbox turns over right after the FETCH answers.
        try await Self.withWorld("cu-turnover-proof", serverUIDs: [1, 2], localUIDs: [1, 2, 3]) { world async throws in
            world.server.resetMailboxAfterNextSuccessfulResponse(
                containing: "UID FETCH", mailbox: Self.path, uidValidity: Int(Self.epoch + 1),
                messages: [Self.message(1), Self.message(2)])
            await Self.pass(world)

            #expect(try Self.rows(world)["3"] != nil, "absence under another numbering proves nothing")
            #expect(try Self.state(world) == nil, "nothing is written for the folder")
            #expect(raised.withLock { $0 } == [Self.epoch + 1], "the turnover reaction is raised")
        }
    }

    @Test("An unknown epoch is never acted on")
    func unknownEpochIsNotActedOn() async throws {
        try await Self.withWorld("cu-unknown", serverUIDs: [1], localUIDs: [1, 2], storedEpoch: nil) { world async throws in
            await Self.pass(world)
            #expect(try Self.rows(world).count == 2)
            #expect(Self.fetchCount(world.server) == 0, "no listing for a folder whose numbering is unproven")
        }
    }

    /// The required test of the FIRST-stamp invariant. A change made, mid-listing, to
    /// a range the listing already passed must still reach the device. With the
    /// completion stamp taken from the LAST range's pass, the cheap check would read
    /// "unchanged" afterwards and skip the folder until the next daily check.
    @Test("A flag change to an already-listed range, mid-listing, is applied")
    func firstStampInvariant() async throws {
        try await Self.withWorld("cu-first-stamp", serverUIDs: [1, 2001], localUIDs: [1, 2001]) { world in
            // Pass 1 lists [1, 1000] and stops.
            await Self.pass(world, context: Self.oneRangePerPass(world.server))
            #expect(try Self.state(world)?.listing != nil, "precondition: the listing spans passes")

            // Another client reads UID 1 — in the range already listed.
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 1)

            // Pass 2 (fresh STATUS) finishes the listing at [2001, 3000].
            try await Self.refreshModSeq(world)
            await Self.pass(world, context: Self.oneRangePerPass(world.server))
            #expect(try Self.state(world)?.listing == nil, "precondition: the listing completed")

            // Pass 3: nothing else changed on the server.
            try await Self.refreshModSeq(world)
            await Self.pass(world)
            #expect(try Self.rows(world)["1"]?.isRead == true,
                    "the change landed after the listing's first stamp, so the counter moved past it and the folder was listed again")
        }
    }

    // MARK: - When nothing may run

    @Test("No request when MODSEQ is unchanged and the daily check is not due")
    func noListingWhenUnchanged() async throws {
        try await Self.withWorld("cu-quiet", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            let modseq = try Self.storedModSeq(world)
            let quiet = IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: modseq,
                lastCompletedAt: Date().addingTimeInterval(-SyncConfig.catchUpFullCheckIntervalSeconds / 2), listing: nil)
            try Self.setState(quiet, world)
            let commandsBefore = world.server.recordedCommands().count

            await Self.pass(world)
            #expect(world.server.recordedCommands().count == commandsBefore, "the cheap check costs no request")
            #expect(try Self.state(world) == quiet, "and writes nothing")
        }
    }

    /// The catch-up ignores the Wi-Fi-only setting and every other download gate
    /// (ADR-IOS-107, #1063): on a cellular network with Wi-Fi-only on, the backfill
    /// call the worker and the background job make (walk held back) runs the due
    /// daily listing at once. *Superseded (#1063):* it ran no daily listing on
    /// cellular and waited for a non-expensive network.
    @Test("With Wi-Fi-only on and only cellular, a backfill cycle runs the due IMAP daily listing")
    func wifiOnlyCellularRunsTheDailyListing() async throws {
        try await Self.withWorld("cu-wifi-only-cellular", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            await world.engine.register(
                accountId: world.accountId, provider: world.provider,
                workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            let modseq = try #require(try Self.storedModSeq(world))
            // Daily check overdue, nothing else signals a change.
            let overdue = IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: modseq,
                lastCompletedAt: Date().addingTimeInterval(-2 * SyncConfig.catchUpFullCheckIntervalSeconds),
                listing: nil)
            try Self.setState(overdue, world)

            try await DownloadGateHarness.withNetwork(expensive: true) { () async throws in
                _ = await world.engine.runBackfill(account: account, walkAllowed: false)
                #expect(Self.fetchCount(world.server) > 0, "the daily listing runs on cellular")
                #expect(try Self.rows(world)["2"]?.isRead == true, "the read reaches the device")
                #expect(try Self.state(world) != overdue, "the daily check is no longer due")
            }
            await world.engine.remove(accountId: world.accountId)
        }
    }

    // MARK: - Scans never wait for a download gate (#1063)

    /// The daily check is due and the server marked UID 2 read; UID 1 is on the
    /// server below every local row, so only the walk would load it. Under every
    /// download gate, in the worker's cycle and in the background job, the daily
    /// listing runs in that one call and the read reaches the device; the walk
    /// stays held (except the job under a low battery, which has no battery gate).
    @Test("A due IMAP scan runs under every download gate, in the worker and the job; the walk stays held",
          arguments: DownloadGate.allCases, BackfillRunner.allCases)
    func scanRunsUnderEveryDownloadGate(gate: DownloadGate, runner: BackfillRunner) async throws {
        try await Self.withWorld("cu-gate-\(gate.rawValue)-\(runner.rawValue)", serverUIDs: [1, 2, 3], localUIDs: [2, 3]) { world in
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            await world.engine.register(
                accountId: accountId, provider: world.provider,
                workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            let modseq = try #require(try Self.storedModSeq(world))
            // Daily check overdue, nothing else signals a change.
            try Self.setState(IMAPCatchUpState(
                epoch: Self.epoch, completionStamp: modseq,
                lastCompletedAt: Date().addingTimeInterval(-2 * SyncConfig.catchUpFullCheckIntervalSeconds),
                listing: nil), world)
            let commandsBefore = world.server.recordedCommands().count

            try await DownloadGateHarness.runOnce(world.engine, account: account, gate: gate, runner: runner)
            let walkHeld = !DownloadGateHarness.walkExpected(gate, runner)
            await world.engine.remove(accountId: accountId)

            #expect(try Self.rows(world)["2"]?.isRead == true, "the scan applied the server's read under \(gate)")
            let state = try Self.state(world)
            #expect(state?.lastCompletedAt.map { $0 > Date().addingTimeInterval(-60) } == true, "the daily listing completed")
            if walkHeld {
                let searches = world.server.recordedCommands().dropFirst(commandsBefore)
                    .filter { $0.uppercased().hasPrefix("UID SEARCH") }
                #expect(searches.isEmpty, "the held walk sent no range SEARCH: \(searches)")
                #expect(try Self.rows(world)["1"] == nil, "the held walk loaded nothing below the local rows")
            } else {
                let searches = world.server.recordedCommands().dropFirst(commandsBefore)
                    .filter { $0.uppercased().hasPrefix("UID SEARCH") }
                #expect(!searches.isEmpty, "the allowed walk sent its range SEARCH")
                #expect(try Self.rows(world)["1"] != nil, "the allowed walk loaded the message below the local rows")
            }
        }
    }

    /// A folder the catch-up has never seen lists at once on an expensive network:
    /// its first listing is a scan, not a download.
    @Test("A folder never listed lists at once on an expensive network")
    func firstListingRunsAtOnceOnAnExpensiveNetwork() async throws {
        try await Self.withWorld("cu-first-on-cellular", serverUIDs: [1, 2], localUIDs: [1, 2]) { world in
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            await world.engine.register(
                accountId: accountId, provider: world.provider,
                workQueue: ProviderWorkQueue(provider: world.provider, maxConcurrency: 1))
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            #expect(try Self.state(world) == nil, "precondition: no state")

            try await DownloadGateHarness.withNetwork(expensive: true) { () async throws in
                _ = await world.engine.runBackfillCycle(account: account, walkAllowed: false)
            }
            await world.engine.remove(accountId: accountId)

            #expect(try Self.rows(world)["2"]?.isRead == true, "the first listing ran on the expensive network")
            #expect(try Self.state(world)?.lastCompletedAt != nil)
        }
    }

    /// Account removal invalidates the account's work queue. A catch-up run that
    /// is waiting between two slices when that happens ends without sending
    /// another request.
    @Test("A catch-up run stops when its account is removed between two slices")
    func runStopsWhenTheAccountIsRemoved() async throws {
        // Two listing ranges: [1, 1000] and [2001, 3000]; each slice lists one.
        try await Self.withWorld("cu-removed-mid-run", serverUIDs: [1, 2001], localUIDs: [1, 2001]) { world in
            let accountId = world.accountId
            let account = try #require(try await world.pool.read { db in try Account.fetchOne(db, key: accountId) })
            let queue = ProviderWorkQueue(provider: world.provider, maxConcurrency: 1)
            await world.engine.register(accountId: accountId, provider: world.provider, workQueue: queue)
            let server = world.server
            let fetchesBefore = Self.fetchCount(server)
            let base = Date()
            // Long enough that the removal always lands before the second slice;
            // the run exits on its next wake, so this does not slow the test.
            let interval: TimeInterval = 30
            // One second per UID FETCH: a slice lists one range. The deadline is far
            // away, so only the removal can end the run before the second range.
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: false,
                deadline: base.addingTimeInterval(1_000), sliceSeconds: 1, intervalSeconds: interval,
                clock: { base.addingTimeInterval(Double(Self.fetchCount(server) - fetchesBefore)) })
            run.listingRangeMessages = Self.rangeMessages
            let engine = world.engine
            let catchUp = Task { await engine.runCatchUpRun(account: account, run: run) }

            // Wait for the first slice to save its listing; the run is then waiting
            // out the slice window before the second.
            let end = Date().addingTimeInterval(interval)
            var midway = false
            while Date() < end, !midway {
                midway = (try Self.state(world)?.listing) != nil
                if !midway { try? await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(midway, "precondition: the first slice listed one range and saved the listing")
            let fetchesAtRemoval = Self.fetchCount(server)

            // What account removal does to the sync engine.
            await queue.invalidate()
            await engine.remove(accountId: accountId)

            _ = await catchUp.value
            #expect(Self.fetchCount(server) == fetchesAtRemoval, "no request is sent after the account's queue is invalidated")
            let after = try Self.state(world)
            #expect(after?.listing != nil && after?.lastCompletedAt == nil, "the second range was never listed")
        }
    }

    @Test("The plan for a folder its change bookmark covers: listed only first, while a listing runs, or after a lapse (ADR-IOS-111)")
    func planTrackedFolder() {
        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let stale = now.addingTimeInterval(-2 * SyncConfig.catchUpFullCheckIntervalSeconds)
        typealias P = IMAPProvider
        func state(_ completed: Date?, lapses: Int? = nil, listed: Int? = nil,
                   listing: IMAPCatchUpState.Listing? = nil) -> IMAPCatchUpState {
            var s = IMAPCatchUpState(epoch: 1, completionStamp: 5, lastCompletedAt: completed, listing: listing)
            s.lapseCount = lapses
            s.listedLapseCount = listed
            return s
        }
        // Neither a moved MODSEQ nor the daily interval lists a tracked folder.
        #expect(P.catchUpPlan(state: state(fresh), freshModSeq: 9, now: now, isTracked: true) == .none)
        #expect(P.catchUpPlan(state: state(stale), freshModSeq: 5, now: now, isTracked: true) == .none)
        // Its first listing still runs.
        #expect(P.catchUpPlan(state: state(nil), freshModSeq: 5, now: now, isTracked: true)
                == .list(.init(firstStamp: 5, nextUid: 1)))
        // A listing in progress continues.
        let resuming = IMAPCatchUpState.Listing(firstStamp: 3, nextUid: 2001)
        #expect(P.catchUpPlan(state: state(fresh, listing: resuming), freshModSeq: 5, now: now, isTracked: true)
                == .list(resuming))
        // A lapse after the last completed listing lists it, recording the lapse count it covers.
        #expect(P.catchUpPlan(state: state(fresh, lapses: 2, listed: 1), freshModSeq: 5, now: now, isTracked: true)
                == .list(.init(firstStamp: 5, nextUid: 1, lapseCountAtStart: 2)))
        #expect(P.catchUpPlan(state: state(fresh, lapses: 2, listed: 2), freshModSeq: 5, now: now, isTracked: true) == .none,
                "a lapse already covered by a completed listing lists nothing")
        // An untracked folder lists on a lapse too, inside the daily interval.
        #expect(P.catchUpPlan(state: state(fresh, lapses: 1, listed: 0), freshModSeq: 5, now: now)
                == .list(.init(firstStamp: 5, nextUid: 1, lapseCountAtStart: 1)))
    }

    @Test("Over the arrivals limit: the bookmark drops, and the folder's catch-up applies an older flag change and expunge made meanwhile")
    func tooFarBehindArmsTheCatchUp() async throws {
        let caps = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
        try await Self.withWorld("cu-too-far-behind", serverUIDs: [1, 2, 3, 4, 5], localUIDs: [1, 2, 3, 4, 5], capabilities: caps) { world in
            // The folder's catch-up has completed once (its state exists).
            await Self.pass(world)
            #expect(try Self.state(world)?.lastCompletedAt != nil, "precondition: a completed catch-up")

            let local = IMAPChangeReaderTests.LocalRows()
            local.set(world.folderId, [1, 2, 3, 4, 5])
            func read() async throws -> FolderChanges {
                let cursor = try await world.pool.read { db in try Folder.fetchOne(db, key: world.folderId)?.changeCursor }
                let request = ChangeRequest(
                    folders: [ChangeFolder(id: world.folderId, path: Self.path, role: .archive,
                                           cursor: cursor, isSynced: true, addressEpoch: Int(Self.epoch))],
                    scope: .all, recheck: [:], context: ChangeContext(onProgress: { _ in }), localRows: local)
                let set = try #require(try await world.provider.fetchChanges(since: ChangeCursor(account: nil), request: request))
                return try #require(set.folders.first)
            }
            func apply(_ changes: FolderChanges) throws {
                _ = try world.pool.write { db in try SyncEngine.applyFolderChanges(changes, db: db) }
            }
            // The bookmark starts.
            try apply(try await read())
            let started = try await world.pool.read { db in try Folder.fetchOne(db, key: world.folderId)?.changeCursor }
            #expect(started != nil)

            // Another client: over 100 arrivals, a read on 2 and an expunge of 3.
            let arrivals = Array(6...(6 + SyncConfig.imapChangeArrivalsLimit))
            world.server.setMessages(([1, 2, 4, 5] + arrivals).map(Self.message), in: Self.path)
            world.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            let refused = try await read()
            guard case .refused(.tooFarBehind) = refused.status else {
                Issue.record("expected tooFarBehind, got \(refused.status)"); return
            }
            try apply(refused)

            // The catch-up (its MODSEQ check left out: the stored HIGHESTMODSEQ is
            // not refreshed here, so only the arming can list the folder).
            await Self.pass(world)
            let rows = try Self.rows(world)
            #expect(rows["2"]?.isRead == true, "the older flag change is applied")
            #expect(rows["3"] == nil, "the older expunge is applied")
        }
    }

    @Test("The plan: cheap check, interval")
    func planDecision() {
        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let stale = now.addingTimeInterval(-2 * SyncConfig.catchUpFullCheckIntervalSeconds)
        func state(
            _ stamp: Int?, _ completed: Date?, listing: IMAPCatchUpState.Listing? = nil
        ) -> IMAPCatchUpState {
            IMAPCatchUpState(epoch: 1, completionStamp: stamp, lastCompletedAt: completed, listing: listing)
        }
        typealias P = IMAPProvider
        #expect(P.catchUpPlan(state: state(5, fresh), freshModSeq: 5, now: now) == .none)
        #expect(P.catchUpPlan(state: state(5, fresh), freshModSeq: 6, now: now)
                == .list(.init(firstStamp: 6, nextUid: 1)))
        #expect(P.catchUpPlan(state: state(5, stale), freshModSeq: 5, now: now)
                == .list(.init(firstStamp: 5, nextUid: 1)))
        #expect(P.catchUpPlan(state: nil, freshModSeq: 5, now: now)
                == .list(.init(firstStamp: 5, nextUid: 1)), "a first-ever listing runs at once")
        #expect(P.catchUpPlan(state: nil, freshModSeq: nil, now: now)
                == .list(.init(firstStamp: nil, nextUid: 1)), "a server without CONDSTORE still gets the daily check")
        let resuming = IMAPCatchUpState.Listing(firstStamp: 3, nextUid: 2001)
        #expect(P.catchUpPlan(state: state(3, fresh, listing: resuming), freshModSeq: 9, now: now)
                == .list(resuming), "a listing in progress keeps its first stamp")
    }
}

/// The generic apply path and the provider-blind seam (ADR-IOS-107), on stub results.
@Suite("ADR-IOS-107 — generic catch-up apply", .serialized, .processGlobalState)
struct CatchUpApplyTests {

    private static let epoch: UInt32 = 51_002

    private static func world(_ name: String, storedEpoch: UInt32?) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?, folderId: String) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: name, path: "Archive", role: .archive, pool: pool,
            totalCount: 3, lastKnownUidValidity: storedEpoch.map { Int($0) })
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: "Archive", uids: [1, 2, 3], pool: pool)
        return (pool, dir, previous, "\(name):Archive")
    }

    private static func catchUpState(_ pool: DatabasePool, _ folderId: String) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT catchUpState FROM folder WHERE id = ?", arguments: [folderId]) }
    }

    @Test("Results and the new state land together")
    func resultsAndStateLandTogether() async throws {
        let w = try Self.world("cua-land", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }

        var result = CatchUpFolderResult(folderId: w.folderId, epoch: Self.epoch)
        result.flagUpdates = [CatchUpFlagUpdate(messageId: "1", isRead: true, isFlagged: true)]
        result.removedIds = ["3"]
        result.newState = "opaque-state"
        let outcome = await SyncEngine().applyCatchUpResult(result, windowMode: .uid, readStartedAt: CatchUpWallClock.now())

        #expect(outcome == .applied(updatedFlags: 1, removedIds: ["\(w.folderId):3"]))
        let folderId = w.folderId
        let ids = try await w.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId]))
        }
        #expect(ids == ["1", "2"], "the removal went, and nothing else changed which rows exist")
        let one = try await w.pool.read { db in try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "1").fetchOne(db) }
        #expect(one?.isRead == true && one?.isFlagged == true)
        #expect(try Self.catchUpState(w.pool, w.folderId) == "opaque-state")
    }

    @Test("A result from another epoch applies nothing; an unknown epoch applies nothing")
    func epochGate() async throws {
        let w = try Self.world("cua-epoch", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        AccountManager.shared.setUidValidityChangeHandlerForTesting { _, _, _, _ in }
        defer { AccountManager.shared.resetUidValidityChangeHandlerForTesting() }

        var other = CatchUpFolderResult(folderId: w.folderId, epoch: Self.epoch + 1)
        other.removedIds = ["1", "2", "3"]
        other.newState = "must-not-land"
        let turned = await SyncEngine().applyCatchUpResult(other, windowMode: .uid, readStartedAt: CatchUpWallClock.now())
        #expect(turned == .turnover(accountId: "cua-epoch", folderPath: "Archive", stored: Self.epoch, observed: Self.epoch + 1))

        var unbound = CatchUpFolderResult(folderId: w.folderId, epoch: nil)
        unbound.removedIds = ["1", "2", "3"]
        unbound.newState = "must-not-land"
        #expect(await SyncEngine().applyCatchUpResult(unbound, windowMode: .uid, readStartedAt: CatchUpWallClock.now()) == .skipped,
                "an IMAP result that names no epoch is unproven")

        #expect(try FolderEpochTestFixture.headerCount(accountId: "cua-epoch", path: "Archive", pool: w.pool) == 3)
        #expect(try Self.catchUpState(w.pool, w.folderId) == nil)
    }

    @Test("A folder whose numbering is being reset accepts nothing, even from its stored epoch")
    func quarantinedFolder() async throws {
        let w = try Self.world("cua-quarantine", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        let folderId = w.folderId
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), folderId])
        }
        var result = CatchUpFolderResult(folderId: w.folderId, epoch: Self.epoch)
        result.flagUpdates = [CatchUpFlagUpdate(messageId: "1", isRead: true, isFlagged: false)]
        result.removedIds = ["3"]
        result.newState = "must-not-land"
        #expect(await SyncEngine().applyCatchUpResult(result, windowMode: .uid, readStartedAt: CatchUpWallClock.now()) == .skipped)
        #expect(try FolderEpochTestFixture.headerCount(accountId: "cua-quarantine", path: "Archive", pool: w.pool) == 3)
        #expect(try Self.catchUpState(w.pool, w.folderId) == nil)
    }

    @Test("A folder with an unknown stored epoch accepts nothing")
    func unknownStoredEpoch() async throws {
        let w = try Self.world("cua-unknown", storedEpoch: nil)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        var result = CatchUpFolderResult(folderId: w.folderId, epoch: Self.epoch)
        result.removedIds = ["1"]
        #expect(await SyncEngine().applyCatchUpResult(result, windowMode: .uid, readStartedAt: CatchUpWallClock.now()) == .skipped)
        #expect(try FolderEpochTestFixture.headerCount(accountId: "cua-unknown", path: "Archive", pool: w.pool) == 3)
    }

    @Test("A provider without catch-up returns nothing and nothing is written")
    func defaultProviderDoesNothing() async throws {
        let w = try Self.world("cua-default", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        let provider = MockEmailProvider(staleWindowMode: .uid)
        let folder = try #require(try FolderEpochTestFixture.readFolder(accountId: "cua-default", path: "Archive", pool: w.pool))
        let results = await provider.catchUp(
            folders: [folder], localRows: SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool),
            context: CatchUpContext(deadline: .distantFuture, clock: { Date() }))
        #expect(results.isEmpty)
        await SyncEngine().runCatchUp(
            provider: provider, folderIds: [w.folderId],
            context: CatchUpContext(deadline: .distantFuture, clock: { Date() }))
        #expect(try Self.catchUpState(w.pool, w.folderId) == nil)
        #expect(try FolderEpochTestFixture.headerCount(accountId: "cua-default", path: "Archive", pool: w.pool) == 3)
    }

    @Test("Under a storage limit, a provider that orders by date never gets the one-time UID prune cutoff seed: its catch-up runs as it does with no limit; the same folder under a UID-order provider is seeded")
    func dateOrderProviderIsNeverSeeded() async throws {
        let w = try Self.world("cua-date-seed", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        let folderId = w.folderId
        let seed = try await w.pool.read { db in try SyncEngine.catchUpPruneCutoffSeed(folderId: folderId, db: db) }
        #expect(seed?.uid == 0 && seed?.epoch == Int(Self.epoch),
                "setup: the folder is seed-eligible (known epoch, no cutoff, local rows): \(String(describing: seed))")
        func context(limit: Bool) -> CatchUpContext {
            var context = CatchUpContext(deadline: .distantFuture, clock: { Date() })
            context.storageLimitInForce = limit
            return context
        }

        let dateOrder = MockEmailProvider(staleWindowMode: .date)
        await SyncEngine().runCatchUp(provider: dateOrder, folderIds: [folderId], context: context(limit: false))
        let withoutLimit = try Self.catchUpState(w.pool, folderId)
        await SyncEngine().runCatchUp(provider: dateOrder, folderIds: [folderId], context: context(limit: true))
        let underLimit = try Self.catchUpState(w.pool, folderId)
        #expect(!(underLimit ?? "").contains(CatchUpPruneCutoff.key),
                "#1062: a date-order provider's folder gets no UID prune cutoff seed: \(String(describing: underLimit))")
        #expect(underLimit == withoutLimit, "#1062: its catch-up under the limit leaves what it leaves with no limit")
        #expect(try FolderEpochTestFixture.headerCount(accountId: "cua-date-seed", path: "Archive", pool: w.pool) == 3,
                "#1062: and its rows are untouched")

        await SyncEngine().runCatchUp(
            provider: MockEmailProvider(staleWindowMode: .uid), folderIds: [folderId], context: context(limit: true))
        #expect(CatchUpPruneCutoff.read(try Self.catchUpState(w.pool, folderId), epoch: Int(Self.epoch)) == 0,
                "setup: the same folder under a UID-order provider is seeded, so the check above can see a seed")
    }

    @Test("The local-row reader reads by range, by ids and in order")
    func reader() async throws {
        let w = try Self.world("cua-reader", storedEpoch: Self.epoch)
        defer { AppDatabase.shared.withLock { $0 = w.previous }; TestDatabaseTeardown.retire(pool: w.pool, directory: w.dir) }
        try FolderEpochTestFixture.insertHeaders(accountId: "cua-reader", path: "Archive", uids: [10, 200], pool: w.pool)
        let reader = SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool)

        #expect(try await reader.rows(folderId: w.folderId, numericIdsFrom: 2, through: 10).map(\.messageId) == ["2", "3", "10"],
                "numeric order, not text order")
        #expect(try await reader.firstNumericId(folderId: w.folderId, atLeast: 11) == 200)
        #expect(try await reader.firstNumericId(folderId: w.folderId, atLeast: 201) == nil)
        #expect(Set(try await reader.rows(folderId: w.folderId, ids: ["3", "200", "404"]).map(\.messageId)) == ["3", "200"])
        let first = try await reader.rows(folderId: w.folderId, after: nil, limit: 2).map(\.messageId)
        let rest = try await reader.rows(folderId: w.folderId, after: first.last, limit: 10).map(\.messageId)
        #expect(first + rest == ["1", "10", "2", "200", "3"], "an ordered scan visits every row once")
    }
}
