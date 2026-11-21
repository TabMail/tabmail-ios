/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The wall limit of each test (and each test case) in this suite: a wait
/// that is never resumed fails its test instead of hanging the run. At file
/// scope because a trait of `@Suite` cannot name a member of its own type.
let imapMissingByUIDTestTimeLimit: TimeLimitTrait.Duration = .minutes(5)

/// A message the server holds in a folder, inside the UID range the device holds
/// that folder in, but with no local row, is found BY UID and loaded by the
/// older-mail check (ADR-IOS-107), whatever its date. The system property every
/// case asserts: after the normal sync path (a foreground `sync`, then the
/// backfill worker's catch-up run), every message the server holds in the held
/// range is held locally exactly once, under the server's UID. Driven end to end
/// against `FakeIMAPServer` (wire oracle on). Every message is dated two years
/// ago: UID and date are decorrelated, so no date reach may be what finds it.
@Suite("IMAP missing messages are found by UID", .serialized, .processGlobalState,
       .timeLimit(imapMissingByUIDTestTimeLimit))
struct IMAPMissingByUIDTests {

    static let epoch = 31
    static let path = "Archive"
    static let qresync = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
    /// Two years ago, in days.
    static let ageInDays = 730
    /// Reaching rest (`World.reachRest`): foreground syncs that re-drive a
    /// pending reset reaction, 10 ms polls waiting for an in-flight one,
    /// catch-up runs until one changes nothing, and older-mail walk passes.
    static let restRedrivePasses = 10
    static let restReactionPolls = 500
    static let restCatchUpPasses = 40
    static let restBackfillPasses = 20
    /// Requests a new listing spends before its first range (#1062): with no
    /// change bookmark and no stored top, the listing's first call reads the
    /// folder's UIDNEXT (`IMAPCatchUpState.Listing.top`). A setup that gives a
    /// new listing's first call a request budget for named steps adds this, so
    /// the budget still reaches those steps.
    static let newListingStartRequests = 1
    /// A catch-up request timeout no answer of these fixtures reaches, however
    /// loaded the machine: for runs whose test times nothing. The production
    /// value (`SyncConfig.catchUpRequestTimeoutSeconds`) is wall-clock time, and
    /// a listing FETCH of a few thousand records can take longer than that on a
    /// busy simulator, which leaves a listing unfinished that the test assumed
    /// complete.
    static let untimedRequestTimeout: TimeInterval = 60

    static func message(_ uid: Int) -> FakeIMAPServer.Message {
        message(uid, date: TestFixtureDate.rfc2822(daysFromAnchor: -ageInDays - (uid % 7)))
    }

    /// The message `id` names (its Message-ID), stored at `uid`, with a `Date:`
    /// header of `date` (any text: a header that is not a date makes the client
    /// unable to read the record when INTERNALDATE is left out).
    static func message(_ uid: Int, date: String, id: Int? = nil) -> FakeIMAPServer.Message {
        let id = id ?? uid
        return FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: missing by uid \(id)\r
        Date: \(date)\r
        Message-ID: <missing-by-uid-\(id)@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let accountId: String
        /// About how many messages one listing range holds in this world's
        /// catch-up (`CatchUpContext.listingRangeMessages`).
        let rangeMessages: Int
        var folderId: String { "\(accountId):\(IMAPMissingByUIDTests.path)" }

        func account() throws -> Account {
            try #require(try pool.read { db in try Account.fetchOne(db, key: accountId) })
        }

        func folder() throws -> Folder {
            try #require(try pool.read { db in try Folder.fetchOne(db, key: folderId) })
        }

        func changeState() throws -> FolderChangeState { FolderChangeState(raw: try folder().changeState) }

        /// The folder's local rows by UID, with how many rows each message has.
        func held() throws -> [Int] {
            let folderId = folderId
            return try pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            }.compactMap(Int.init).sorted()
        }

        /// Every UID in `expected` is held exactly once, and nothing else is.
        func expectHeldExactly(_ expected: [Int], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let held = try held()
            let missing = Set(expected).subtracting(held).sorted()
            let extra = Set(held).subtracting(expected).sorted()
            #expect(missing.isEmpty, "\(label): \(missing.count) message(s) the server holds are missing: \(missing.prefix(20))", sourceLocation: sourceLocation)
            #expect(extra.isEmpty, "\(label): rows the server does not hold: \(extra.prefix(20))", sourceLocation: sourceLocation)
            #expect(held.count == Set(held).count, "\(label): no message is held twice", sourceLocation: sourceLocation)
            let folderId = folderId
            let duplicates = try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM (SELECT rfc822MessageId FROM messageHeader
                    WHERE folderId = ? AND rfc822MessageId IS NOT NULL GROUP BY rfc822MessageId HAVING COUNT(*) > 1)
                    """, arguments: [folderId]) ?? 0
            }
            #expect(duplicates == 0, "\(label): no message is held under two UIDs", sourceLocation: sourceLocation)
            #expect(server.wrongMessageViolations().isEmpty, sourceLocation: sourceLocation)
        }

        /// Every row of the folder is the server's message at its UID (its
        /// RFC identity matches the message the server stores there) and carries
        /// the observed epoch `epoch`; a NULL epoch fails, since a row with no
        /// observed epoch cannot be acted on.
        func expectIdentityAndEpoch(_ epoch: Int, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let folderId = folderId
            let rows = try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT messageId, rfc822MessageId, observedUidValidity FROM messageHeader WHERE folderId = ?",
                                 arguments: [folderId])
            }
            for row in rows {
                let uid: String = row["messageId"]
                let rfc: String? = row["rfc822MessageId"]
                let observed: Int? = row["observedUidValidity"]
                let onServer = Int(uid).map { server.uids(in: IMAPMissingByUIDTests.path, rfc822MessageId: "<missing-by-uid-\($0)@example.com>") } ?? []
                #expect(rfc?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == "missing-by-uid-\(uid)@example.com" && onServer == [Int(uid) ?? -1],
                        "\(label): UID \(uid) holds the server's message at that UID: \(rfc ?? "nil")", sourceLocation: sourceLocation)
                #expect(observed == epoch, "\(label): UID \(uid) carries the observed epoch \(epoch): \(observed.map(String.init) ?? "NULL")", sourceLocation: sourceLocation)
            }
        }

        /// The backfill worker's catch-up run, with
        /// no storage limit, whatever the machine running the test has. Returns
        /// the run's own answer (`SyncEngine.runCatchUpRun`: an applied result made
        /// progress).
        @discardableResult
        /// `clock`: the run's clock (`CatchUpRun.clock`), the wall clock by default.
        /// `deadlineIn` nil: a foreground cycle (`CatchUpRun.deadline` nil).
        func workerRun(maxRequests: Int = SyncConfig.catchUpSliceMaxRequests, deadlineIn: TimeInterval? = 60,
                       requestTimeout: TimeInterval = SyncConfig.catchUpRequestTimeoutSeconds,
                       sliceSeconds: TimeInterval = SyncConfig.catchUpSliceSeconds,
                       intervalSeconds: TimeInterval = SyncConfig.catchUpSliceIntervalSeconds,
                       storageLimit: Bool = false,
                       clock: @escaping @Sendable () -> Date = { Date() }) async throws -> Bool {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: storageLimit, deadline: deadlineIn.map { clock().addingTimeInterval($0) },
                sliceSeconds: sliceSeconds, intervalSeconds: intervalSeconds,
                clock: clock)
            run.sliceMaxRequests = maxRequests
            run.listingRangeMessages = rangeMessages
            run.requestTimeoutSeconds = requestTimeout
            return await engine.runCatchUpRun(account: try account(), run: run)
        }

        /// A foreground sync (its full sync only when due), after the protection of
        /// any completed action has lapsed, as a later sync is.
        func foregroundSync() async throws {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let accountId = accountId
            try await pool.write { db in
                try db.execute(sql: "UPDATE account SET lastSyncedAt = NULL WHERE id = ?", arguments: [accountId])
            }
            _ = try? await engine.sync(account: try account())
            // `SyncEngine.sync` ends by starting the account's backfill worker
            // (`startBackfill`), whose walk and catch-up would run beside the
            // test's own steps, on the machine's real network and power gates.
            // Every worker run here is the test's own: stop it before it walks.
            await engine.stopBackfillWorkerForTesting(accountId: accountId)
        }

        /// The app reaching rest (#1062): a full sync, which re-drives any
        /// reset reaction left pending (ADR-IOS-061 section 4: purge, fresh
        /// stamp, resync of the window); then catch-up runs until one changes
        /// nothing (ADR-IOS-107; a quarantined folder is never listed); then the
        /// older-mail walk to completion, which brings back mail below the
        /// window. Each stage is bounded; reaching its bound is a setup failure.
        func reachRest(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let folderId = folderId
            func resetPending() throws -> Bool { try folder().uidValidityResetPendingAt != nil }
            try await foregroundSync()
            for _ in 0..<IMAPMissingByUIDTests.restRedrivePasses where try resetPending() {
                var polls = 0
                while polls < IMAPMissingByUIDTests.restReactionPolls,
                      await AccountManager.shared.uidValidityReactionInFlight.contains(folderId) {
                    try await Task.sleep(for: .milliseconds(10))
                    polls += 1
                }
                try await foregroundSync()
            }
            #expect(!(try resetPending()), "\(label): setup: the full sync re-drove the pending reset reaction", sourceLocation: sourceLocation)
            var settled = false
            for _ in 0..<IMAPMissingByUIDTests.restCatchUpPasses {
                let before = (try held(), try folder().catchUpState, try folder().changeState)
                try await workerRun()
                let after = (try held(), try folder().catchUpState, try folder().changeState)
                if before == after { settled = true; break }
            }
            #expect(settled, "\(label): setup: a catch-up run changed nothing within the bound", sourceLocation: sourceLocation)
            for _ in 0..<IMAPMissingByUIDTests.restBackfillPasses where !(try folder().backfillComplete) {
                _ = await engine.runBackfillWalk(
                    account: try account(), deadline: Date().addingTimeInterval(SyncConfig.catchUpSliceSeconds))
            }
            #expect(try folder().backfillComplete, "\(label): setup: the older-mail walk completed", sourceLocation: sourceLocation)
        }

        /// The normal path: a foreground sync, then the worker's catch-up run.
        func normalSync() async throws {
            try await foregroundSync()
            try await workerRun()
        }

        /// A change pass alone, as a background (push or refresh) pass runs it.
        func backgroundChangePass() async throws {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = try? await engine.performChangePass(account: try account(), provider: provider)
        }

        /// Take rows away locally (the device lost them; the server still holds them).
        func dropLocal(_ uids: [Int]) async throws {
            let folderId = folderId
            try await pool.write { db in
                for uid in uids {
                    try db.execute(sql: "DELETE FROM messageHeader WHERE folderId = ? AND messageId = ?", arguments: [folderId, "\(uid)"])
                }
            }
        }

        /// Precondition: none of `uids` is held locally.
        func expectNotHeld(_ uids: [Int], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let held = Set(try held())
            let present = uids.filter { held.contains($0) }
            #expect(present.isEmpty, "\(label): setup: these are missing locally: \(present.prefix(20))", sourceLocation: sourceLocation)
        }

        func makeFullSyncDue() async throws {
            let accountId = accountId
            try await pool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [accountId])
            }
        }

        /// A move retired without proof leaves the folder possibly wrong: the
        /// production marking, as `MessageHeaderRekey.finishMove` calls it.
        func markOwed() async throws {
            let folderId = folderId
            try await pool.write { db in
                try SyncEngine.dropChangeBookmark(folderId: folderId, selfHealDue: true, db: db)
            }
        }
    }

    /// The server's Archive holds `server`; the device holds `local` in it, its
    /// older-mail walk complete, and the full sync is not due. `tracked`: the
    /// folder holds the change bookmark a committed baseline leaves.
    /// `olderMailCursor`: the older-mail walk is left unfinished at that UID.
    /// `walkStarted` false: the walk has not started (no cursor, not complete).
    /// `rangeMessages`: by default 1, so every listing range has the minimum
    /// width (`SyncConfig.catchUpListingMinRangeSpan` UIDs), the layout these
    /// fixtures place their messages across; a cost test passes the production
    /// value (`SyncConfig.catchUpListingRangeMessages`).
    @MainActor
    static func withWorld(
        _ name: String, capabilities: [String] = qresync, server serverUIDs: [Int], local: [Int],
        tracked: Bool = false, olderMailCursor: Int? = nil, walkStarted: Bool = true,
        rangeMessages: Int = 1, uidNext: Int? = nil, _ body: (World) async throws -> Void
    ) async throws {
        let mailboxes: [String: [FakeIMAPServer.Message]] = ["INBOX": [], path: serverUIDs.map(message)]
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: mailboxes)
        for mailbox in mailboxes.keys { server.setUidValidity(epoch, for: mailbox) }
        server.honorSearchDateCriteria()
        try server.start()
        defer { server.stop() }

        let accountId = "missing-by-uid-\(name)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
                                                lastKnownUidNext: 1, lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: path, role: .archive, pool: pool,
                                                totalCount: serverUIDs.count, lastKnownUidNext: uidNext ?? ((serverUIDs.max() ?? 0) + 1),
                                                lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: path, uids: local, pool: pool)
        let folderId = "\(accountId):\(path)"
        try await pool.write { db in
            // The local rows are the server's messages, and the walk has loaded
            // everything older: only the older-mail check can find a gap.
            for uid in local {
                try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = ?, observedUidValidity = ? WHERE folderId = ? AND messageId = ?",
                               arguments: ["<missing-by-uid-\(uid)@example.com>", epoch, folderId, "\(uid)"])
            }
            try db.execute(sql: "UPDATE folder SET backfillComplete = 1 WHERE accountId = ?", arguments: [accountId])
            if !walkStarted {
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillUidCursor = NULL WHERE id = ?",
                               arguments: [folderId])
            }
            if let olderMailCursor {
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, backfillUidCursor = ? WHERE id = ?",
                               arguments: [olderMailCursor, folderId])
            }
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), accountId])
        }
        if tracked {
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            let encodedState = state.encoded
            let uidNext = (serverUIDs.max() ?? 0) + 1
            let cursor = IMAPChangeCursor(uidValidity: UInt32(epoch), highestModSeq: UInt64(server.qresyncHighestModSeq(for: path)),
                                          uidNext: UInt32(uidNext)).encoded
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, changeState = ? WHERE id = ?",
                               arguments: [cursor, encodedState, folderId])
            }
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        let engine = SyncEngine()
        await engine.register(accountId: accountId, provider: provider,
                              workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        let world = World(server: server, provider: provider, engine: engine, pool: pool, accountId: accountId,
                          rangeMessages: rangeMessages)
        // The folder's older-mail check has completed once, as it has on a
        // device that has synced before: no first listing hides what a test asks.
        // Untimed: with the production timeout, a large listing range of this
        // setup run could time out on a busy machine and leave its listing
        // unfinished. The test's own runs would then continue that listing,
        // which had already passed the UIDs the test drops after setup: it
        // completes without them, and a second listing (the folder being owed
        // a check marked after the first one started) loads them and asks
        // the timed-out ranges again at full width.
        // The body queue is process-wide: an earlier suite's items whose
        // account has no work queue stay pending forever. Each world starts
        // from an empty queue. Its downloads are then held for the world: a
        // batch download sends a header FETCH byte-identical to a catch-up
        // header load, and its body FETCHes would land in the windows these
        // tests read, which assert exactly what the catch-up sends.
        await BackfillBodyQueue.shared.emptyForTesting()
        await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(true)
        defer { await BackfillBodyQueue.shared.setDispatchSuppressedForTesting(false) }
        try await world.workerRun(requestTimeout: untimedRequestTimeout)
        #expect(try world.catchUpState()?.listing == nil,
                "\(name): setup: the setup catch-up run completed the folder's listing")
        try await body(world)
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        try? await provider.disconnect()
    }

    // MARK: - I1: any date, owed folder

    @Test("A message the server holds below the window, dated two years ago, with no local row: held once after the normal sync, and the folder is no longer owed a check")
    @MainActor
    func oldMissingMessageIsLoaded() async throws {
        let local = (1...20).filter { $0 != 7 }
        try await Self.withWorld("i1", server: Array(1...20) + Array(1001...1060), local: local + Array(1011...1060)) { w in
            // The warm-up loaded UID 7: the device loses it again.
            try await w.dropLocal([7])
            try w.expectNotHeld([7], "I1")
            try await w.markOwed()
            try await w.normalSync()
            try w.expectHeldExactly(Array(1...20) + Array(1001...1060), "I1")
            #expect(!(try w.changeState()).selfHealDue, "I1: the check the folder was owed has run")
        }
    }

    @Test("A message the older-mail check alone loads carries its RFC identity and observed epoch, and a gesture on it changes that message on the server")
    @MainActor
    func catchUpLoadedMessageIsActionable() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("loaded-actionable", server: server, local: server) { w in
            try await w.dropLocal([7])
            try w.expectNotHeld([7], "loaded")
            try await w.markOwed()
            // The catch-up alone: no foreground sync runs.
            try await w.workerRun()
            try w.expectHeldExactly(server, "loaded")
            let folderId = w.folderId
            let recovered = try await w.pool.read { db in
                try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "7").fetchOne(db)
            }
            let row = try #require(recovered, "loaded: UID 7 is held again")
            #expect(row.rfc822MessageId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == "missing-by-uid-7@example.com", "loaded: the recovered row is the server's message at UID 7")
            let epoch = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT observedUidValidity FROM messageHeader WHERE folderId = ? AND messageId = '7'", arguments: [folderId])
            }
            #expect(epoch == Self.epoch, "loaded: the recovered row carries the epoch it was read under, not NULL: \(epoch.map(String.init) ?? "NULL")")
            try w.expectIdentityAndEpoch(Self.epoch, "loaded")

            // A gesture on it, under the wire oracle: the intended message moves.
            w.server.expectMutation(rfc822MessageId: "<missing-by-uid-7@example.com>")
            await AccountManager.shared.move([row], to: "INBOX")
            try await w.drain()
            #expect(w.server.uids(in: "INBOX", rfc822MessageId: "<missing-by-uid-7@example.com>").count == 1,
                    "loaded: the gesture moved the recovered message on the server")
            #expect(w.server.uids(in: Self.path, rfc822MessageId: "<missing-by-uid-7@example.com>").isEmpty,
                    "loaded: the source no longer holds it")
            #expect(w.server.wrongMessageViolations().isEmpty, "loaded: no other message was changed")
        }
    }

    // MARK: - Cached rows below an unfinished walk

    @Test("An unfinished older-mail walk, with rows infinite scroll cached below its cursor: a flag change and an expunge on them are reconciled, and no other mail below the cursor is loaded")
    @MainActor
    func cachedRowsBelowAnUnfinishedWalkAreReconciled() async throws {
        let cursor = 1000
        let flagged = 20, expunged = 21
        let below = Array(1...30)
        let window = Array(1001...1060)
        try await Self.withWorld("below-walk", server: below + window, local: [flagged, expunged] + window,
                                 olderMailCursor: cursor) { w in
            let folder = try w.folder()
            #expect(folder.backfillComplete == false && folder.backfillUidCursor == cursor, "setup: the walk is unfinished")
            // Another client reads one cached row and expunges the other.
            w.server.setMessages((below + window).filter { $0 != expunged }.map(Self.message), in: Self.path)
            w.server.setFlags(["\\Seen"], in: Self.path, uid: flagged)
            try await w.markOwed()
            try await w.workerRun()
            let folderId = w.folderId
            let isRead = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                  arguments: [folderId, "\(flagged)"])
            }
            #expect(isRead == true, "the flag change on the cached row below the cursor is applied")
            try w.expectHeldExactly([flagged] + window, "below-walk: the expunged row is gone; nothing else below the cursor is loaded")
        }
    }

    // MARK: - I2: no request outside the budget

    /// How a slice's budget is spent before it starts.
    enum SpentBudget: String, CaseIterable, Sendable {
        /// No request may be sent (time left).
        case requests
        /// No time is left (requests left).
        case time
    }

    @Test("An owed folder: the foreground sync sends no date search, and a worker slice with no budget (no request left, or no time left) sends nothing and writes nothing, under a storage limit too (no prune cutoff is seeded)",
          arguments: [false, true], SpentBudget.allCases)
    @MainActor
    func owedCheckSpendsOnlyTheCatchUpBudget(limit: Bool, spent: SpentBudget) async throws {
        try await Self.withWorld("i2-\(limit)-\(spent.rawValue)", server: Array(1...20) + Array(1001...1060), local: Array(2...20) + Array(1011...1060)) { w in
            try await w.markOwed()
            // The slice with no budget runs first: work a foreground sync leaves
            // running (body downloads, other folders) would land in its window.
            let before = try w.folder()
            let mid = w.server.recordedCommands().count
            switch spent {
            case .requests: try await w.workerRun(maxRequests: 0, storageLimit: limit)
            case .time: try await w.workerRun(sliceSeconds: 0, storageLimit: limit)
            }
            let sent = w.server.recordedCommands().dropFirst(mid).filter { command in
                ["SELECT", "EXAMINE", "FETCH", "SEARCH"].contains { command.uppercased().contains($0) }
            }
            #expect(sent.isEmpty, "I2: a slice with no budget sends nothing: \(sent)")
            let after = try w.folder()
            #expect(after.catchUpState == before.catchUpState, "I2: the check's progress is unchanged")
            #expect(after.changeState == before.changeState, "I2: what the folder is owed is unchanged")

            let start = w.server.recordedCommands().count
            try await w.foregroundSync()
            let dateSearches = w.server.recordedCommands().dropFirst(start).filter {
                $0.uppercased().contains("SINCE") || $0.uppercased().contains("BEFORE")
            }
            #expect(dateSearches.isEmpty, "I2: the sync sends no date search: \(dateSearches)")
        }
    }

    // MARK: - I3: resumable across slices

    @Test("30 missing messages over three listing ranges, three requests per slice: every slice resumes where the last stopped, all 30 load, and the folder stays owed until the last")
    @MainActor
    func missingMessagesLoadAcrossSlices() async throws {
        let span = SyncConfig.catchUpListingMinRangeSpan
        let held = Array(1...10) + Array((span + 1)...(span + 10)) + Array((2 * span + 1)...(2 * span + 10))
        let missing = Array(11...20) + Array((span + 11)...(span + 20)) + Array((2 * span + 11)...(2 * span + 20))
        try await Self.withWorld("i3", server: (held + missing).sorted(), local: held) { w in
            // The warm-up loaded them: the device loses them again.
            try await w.dropLocal(missing)
            try w.expectNotHeld(missing, "I3")
            try await w.markOwed()
            var slices = 0
            var loadedPerSlice: [Int] = []
            while try Set(w.held()) != Set(held + missing), slices < 20 {
                #expect((try w.changeState()).selfHealDue, "I3: still owed before the last missing message loads (slice \(slices))")
                let before = try w.held().count
                let context = CatchUpContext(deadline: .distantFuture, clock: { Date() }, maxRequests: 3, listingRangeMessages: w.rangeMessages)
                await AccountManager.shared.clearRecentlyCompletedForTesting()
                await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: context)
                loadedPerSlice.append(try w.held().count - before)
                slices += 1
            }
            #expect(slices >= 2, "I3: three requests per slice cannot load all three ranges in one slice (\(slices) slice(s))")
            #expect(loadedPerSlice.filter { $0 > 0 }.count >= 2, "I3: the loads spread over slices that each resume: \(loadedPerSlice)")
            try w.expectHeldExactly((held + missing).sorted(), "I3")
            // One more slice completes the listing if the last load ended it early.
            let context = CatchUpContext(deadline: .distantFuture, clock: { Date() }, maxRequests: 3, listingRangeMessages: w.rangeMessages)
            for _ in 0..<5 where (try w.changeState()).selfHealDue {
                await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: context)
            }
            #expect(!(try w.changeState()).selfHealDue, "I3: the mark clears once the listing completes")
        }
    }

    // MARK: - I4: one message that does not load never blocks the others

    @Test("A missing message a queued action stands on is skipped, the rest load in the same listing, and it loads once the action has gone")
    @MainActor
    func refusedLoadDoesNotBlockTheOthers() async throws {
        try await Self.withWorld("i4", server: Array(1...20) + Array(1001...1060), local: Array(1...4) + Array(1011...1060)) { w in
            let accountId = w.accountId
            try await w.pool.write { db in
                var op = PendingOperation(type: .archive, messageIds: ["5"], accountId: accountId, folderPath: Self.path)
                try op.insert(db)
            }
            try await w.dropLocal(Array(5...20))
            try await w.markOwed()
            try await w.workerRun()
            let held = Set(try w.held())
            #expect(Set(6...20).isSubset(of: held), "I4: the messages after the skipped one load in the same run")
            #expect(!held.contains(5), "I4: the message the queued action stands on is not loaded under it")
            try await w.pool.write { db in _ = try PendingOperation.deleteAll(db) }
            try await w.markOwed()
            try await w.workerRun()
            try w.expectHeldExactly(Array(1...20) + Array(1001...1060), "I4")
        }
    }

    // MARK: - I5(b): a message marked \Deleted is not shown

    @Test("A missing message the server flags \\Deleted is not loaded")
    @MainActor
    func deletedMessageIsNotLoaded() async throws {
        try await Self.withWorld("i5b", server: Array(1...20) + Array(1001...1060), local: Array(1...9) + Array(11...20) + Array(1011...1060)) { w in
            w.server.setFlags(["\\Deleted"], in: Self.path, uid: 10)
            let other = 1001
            try await w.dropLocal([10, other])
            try await w.markOwed()
            try await w.normalSync()
            let held = try w.held()
            #expect(held.contains(other), "I5b: setup: the check ran and loaded the other missing message")
            #expect(!held.contains(10), "I5b: a message marked \\Deleted is not shown")
        }
    }

    // MARK: - I8: storage limit

    @Test("Under a storage limit, nothing below the lowest held UID is loaded or asked for, and a missing message above it loads whatever its date, over three listings")
    @MainActor
    func storageLimitDoesNotReloadOlderMail() async throws {
        // The UID prune keeps the highest UIDs, so the lowest held UID is where
        // kept mail ends: 1...3 are below it (pruned); 10 is above it and older
        // than every kept row (UID and date are decorrelated, ADR-IOS-042).
        let pruned = [1, 2, 3], older = 10
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("i8", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.dropLocal(pruned + [older])
            try w.expectNotHeld(pruned + [older], "I8")
            // The kept rows are ten days old; the missing one is two years old.
            let keptDate = Date().addingTimeInterval(-10 * 24 * 60 * 60)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET date = ?, providerDate = ? WHERE folderId = ?",
                               arguments: [keptDate, keptDate, folderId])
            }
            let expected = server.filter { !pruned.contains($0) }
            let start = w.server.recordedCommands().count
            for listing in 1...3 {
                try await w.markOwed()
                var run = SyncEngine.CatchUpRun(
                    storageLimitInForce: true, deadline: Date().addingTimeInterval(60),
                    sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
                    clock: { Date() })
                run.sliceMaxRequests = SyncConfig.catchUpSliceMaxRequests
                run.listingRangeMessages = w.rangeMessages
                _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
                try w.expectHeldExactly(expected, "I8 listing \(listing): the older missing message above the floor loads, nothing below it")
            }
            let headerFetches = w.server.recordedCommands().dropFirst(start).filter {
                // A header load asks for the ENVELOPE; the flags-only listing does not.
                $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            for uid in pruned {
                #expect(!headerFetches.contains { Self.uidSet($0).contains(uid) },
                        "I8: no header of a UID below the floor is fetched: \(uid)")
            }
        }
    }

    /// The UIDs a recorded `UID FETCH <set> ...` command names.
    static func uidSet(_ command: String) -> Set<Int> {
        let parts = command.split(separator: " ").map(String.init)
        guard let at = parts.firstIndex(where: { $0.uppercased() == "FETCH" }), at + 1 < parts.count else { return [] }
        var uids = Set<Int>()
        for piece in parts[at + 1].split(separator: ",") {
            let bounds = piece.split(separator: ":").compactMap { Int($0) }
            if bounds.count == 2, bounds[0] <= bounds[1] { uids.formUnion(bounds[0]...bounds[1]) }
            else if bounds.count == 1 { uids.insert(bounds[0]) }
        }
        return uids
    }

    // MARK: - I9: a listing that began before the mark

    @Test("An owed mark made while a listing runs is not cleared by that listing, and is cleared by the next")
    @MainActor
    func listingStartedBeforeTheMarkDoesNotClearIt() async throws {
        let span = SyncConfig.catchUpListingMinRangeSpan
        try await Self.withWorld("i9", server: Array(1...20) + Array((span + 1)...(span + 20)), local: Array(1...20) + Array((span + 1)...(span + 20))) { w in
            // A listing starts (one range per slice) before the mark.
            try await w.markOwed()
            try await w.workerRun()
            #expect(!(try w.changeState()).selfHealDue, "I9: setup: a listing started after a mark clears it")
            try await w.makeListingInProgress()
            // A message behind the listing's cursor goes missing, and the mark
            // comes after the listing began: that listing never sees it again.
            let behind = 7
            try await w.dropLocal([behind])
            try w.expectNotHeld([behind], "I9")
            try await w.markOwed()
            // The last range: its FETCH and its membership SEARCH.
            let lastRange = CatchUpContext(deadline: .distantFuture, clock: { Date() }, maxRequests: 2, listingRangeMessages: w.rangeMessages)
            await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: lastRange)
            let state = try #require(IMAPCatchUpState.decode(try w.folder().catchUpState))
            #expect(state.listing == nil, "I9: setup: the listing that began before the mark completed")
            try w.expectNotHeld([behind], "I9: that listing did not reach the message behind its cursor")
            #expect((try w.changeState()).selfHealDue, "I9: the listing that began before the mark does not clear it")
            try await w.workerRun()
            try w.expectHeldExactly(Array(1...20) + Array((span + 1)...(span + 20)), "I9: the next listing loads it")
            #expect(!(try w.changeState()).selfHealDue, "I9: the next listing clears it")
        }
    }

    // MARK: - I10: a held bookmark dropped while far behind

    /// How the held bookmark of a tracked folder is dropped.
    enum DropCause: String, CaseIterable, Sendable {
        /// More arrivals than one read may take.
        case tooFarBehind
        /// The folder's reads have failed for an hour.
        case failingTooLong
        /// The re-read list went over its limit.
        case rereadListCut
    }

    /// Which pass sees the drop first.
    enum PassOrder: String, CaseIterable, Sendable {
        /// A foreground pass: the drop, the same pass's full sync, then the worker.
        case foreground
        /// Background passes see the drop and start a new bookmark, and a worker
        /// slice runs before the first foreground listing.
        case backgroundFirst
    }

    @Test("A tracked folder whose held bookmark is dropped while 150 messages arrived across a listing-range boundary: every message the server holds is held exactly once after the passes and the worker",
          arguments: DropCause.allCases, PassOrder.allCases)
    @MainActor
    func droppedBookmarkLeavesNoGap(_ cause: DropCause, _ order: PassOrder) async throws {
        // Held 1..20; while away the server gains 150 messages at 951..1100, so
        // the window lists 1051..1100 and 951..1050 crosses the 1000 boundary.
        let arrivals = Array(951...1100)
        let all = Array(1...20) + arrivals
        try await Self.withWorld("i10-\(cause.rawValue)-\(order.rawValue)", server: Array(1...20), local: Array(1...20), tracked: true) { w in
            #expect(SyncConfig.imapChangeArrivalsLimit < arrivals.count, "setup: more arrivals than one read takes")
            w.server.setMessages(all.map(Self.message), in: Self.path)
            let folderId = w.folderId
            switch cause {
            case .tooFarBehind:
                break
            case .failingTooLong:
                // The bookmark's reads began failing an hour ago; this one fails too.
                var cursor = try #require(IMAPChangeCursor.decode(try w.folder().changeCursor))
                cursor.failingSince = Date().addingTimeInterval(-SyncConfig.changeReadFailureLapseSeconds - 60)
                let encoded = cursor.encoded
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET changeCursor = ? WHERE id = ?", arguments: [encoded, folderId])
                }
                w.server.failNextCommand(containing: "(QRESYNC", message: "Server busy")
            case .rereadListCut:
                // A pass declines more ids than the re-read list holds.
                let cursor = try w.folder().changeCursor
                var changes = FolderChanges(
                    folderId: folderId, status: .tracked, addressEpoch: Self.epoch,
                    rereadLater: (0...SyncConfig.changeRecheckLimit).map { "\(5_000 + $0)" }, cursor: cursor)
                changes.readFrom = .init(cursor: cursor)
                let toApply = changes
                _ = try await w.pool.write { db in try SyncEngine.applyFolderChanges(toApply, db: db) }
            }
            switch order {
            case .foreground:
                try await w.normalSync()
            case .backgroundFirst:
                try await w.backgroundChangePass()
                try await w.backgroundChangePass()
                try await w.workerRun()
                try await w.normalSync()
            }
            if cause == .rereadListCut {
                // The cut keeps the read tracked with no listing of its own: it
                // converges after the next foreground pass.
                try await w.normalSync()
            }
            try w.expectHeldExactly(all, "I10 \(cause) \(order)")
        }
    }

    // MARK: - I11: the gap trigger

    @Test("An untracked folder on a server without CONDSTORE: a window listing that leaves a gap below it has the gap loaded by the next worker run")
    @MainActor
    func windowGapIsLoadedByTheNextWorkerRun() async throws {
        let all = Array(1...100)
        try await Self.withWorld("i11", capabilities: FakeIMAPServer.defaultCapabilities, server: Array(1...20), local: Array(1...20)) { w in
            w.server.setMessages(all.map(Self.message), in: Self.path)
            try await w.makeFullSyncDue()
            try await w.normalSync()
            try w.expectHeldExactly(all, "I11")
        }
    }
}

extension IMAPMissingByUIDTests.World {
    /// Leave a listing in progress past the first range: the folder's check is
    /// due (a lapse), and one slice of two requests after the listing's start
    /// (`newListingStartRequests`; then the first range's FETCH and its
    /// membership SEARCH, for the unused UID space in it) lists that range
    /// without completing the listing.
    func makeListingInProgress() async throws {
        let folderId = folderId
        try await pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
        let oneRange = CatchUpContext(deadline: .distantFuture, clock: { Date() },
                                      maxRequests: IMAPMissingByUIDTests.newListingStartRequests + 2, listingRangeMessages: rangeMessages)
        await engine.runCatchUp(provider: provider, folderIds: [folderId], context: oneRange)
        let state = try #require(IMAPCatchUpState.decode(try folder().catchUpState))
        let listing = try #require(state.listing, "setup: a listing is in progress")
        #expect(listing.nextUid > SyncConfig.catchUpListingMinRangeSpan, "setup: the listing is past its first range")
        #expect(listing.loadHeldSince == nil, "setup: nothing in the first range is held")
    }
}

extension SyncEngine {
    /// Cancel the account's backfill worker, if one runs, and wait for it to end.
    func stopBackfillWorkerForTesting(accountId: String) async {
        guard let task = headerBackfillTasks.removeValue(forKey: accountId) else { return }
        task.cancel()
        await task.value
    }
}
