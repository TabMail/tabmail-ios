/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The engine around the IMAP change reader (ADR-IOS-111, IMAP half), driven
/// through the engine's own entry points against `FakeIMAPServer`, with the work
/// queue the ADR-IOS-051 count walk runs on registered: an untracked folder is
/// re-listed and its ghosts walked away; an armed turnover is re-driven after the
/// pass's read, within its budget; a provider that cannot say which ids exist deletes nothing; a
/// tracked folder gets no count walk and no self-heal. Each case asserts the
/// stored rows (or, for a skip, that the folder was never touched on the wire).
@Suite("IMAP change engine", .serialized, .processGlobalState)
struct IMAPChangeEngineTests {

    static let epoch = 61_200
    static let path = "INBOX"
    static let qresync = FakeIMAPServer.defaultCapabilities + ["ENABLE", "CONDSTORE", "QRESYNC"]
    /// CONDSTORE without QRESYNC or UIDPLUS: no change reader, so every folder
    /// is untracked (with UIDPLUS a CONDSTORE server is read, #755).
    static let condstoreOnly = FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" } + ["CONDSTORE"]
    /// A custom folder the server renumbered (`epoch` + 1 over the stored
    /// `epoch`), with its turnover reaction armed: the server holds 201 and 202,
    /// the device the old numbering's 1 to 3.
    static let armedPath = "Renumbered"

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let account: Account
        var folderId: String { "\(account.id):\(IMAPChangeEngineTests.path)" }

        func uids() throws -> Set<String> {
            let folderId = folderId
            return Set(try pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ?", arguments: [folderId])
            })
        }

        func folder() throws -> Folder {
            let folderId = folderId
            return try #require(try pool.read { db in try Folder.fetchOne(db, key: folderId) })
        }

        /// Commands the server received from `start` on that name the folder.
        func commandsNamingFolder(since start: Int) -> [String] {
            server.recordedCommands().dropFirst(start).filter {
                let upper = $0.uppercased()
                return (upper.contains("SELECT") || upper.contains("EXAMINE") || upper.contains("UID SEARCH"))
                    && upper.contains(IMAPChangeEngineTests.path)
            }
        }
    }

    static func withWorld(
        _ name: String, capabilities: [String], serverUIDs: [Int], localUIDs: [Int],
        serverEpoch: Int = IMAPChangeEngineTests.epoch, storedEpoch: Int? = IMAPChangeEngineTests.epoch,
        tracked: Bool = false, withArmedFolder: Bool = false,
        _ body: (World) async throws -> Void
    ) async throws {
        var mailboxes = [path: serverUIDs.map(IMAPChangeReaderTests.message)]
        if withArmedFolder { mailboxes[armedPath] = [201, 202].map(IMAPChangeReaderTests.message) }
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: mailboxes)
        server.setUidValidity(serverEpoch, for: path)
        if withArmedFolder { server.setUidValidity(epoch + 1, for: armedPath) }
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let account = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: name, path: path, role: .inbox, pool: pool,
            totalCount: localUIDs.count, lastKnownUidNext: (localUIDs.max() ?? 0) + 1, lastKnownUidValidity: storedEpoch)
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: path, uids: localUIDs, pool: pool)
        if withArmedFolder {
            try FolderEpochTestFixture.insertFolder(
                accountId: name, path: armedPath, role: .custom, pool: pool,
                totalCount: 3, lastKnownUidNext: 4, lastKnownUidValidity: epoch)
            try FolderEpochTestFixture.insertHeaders(accountId: name, path: armedPath, uids: [1, 2, 3], pool: pool)
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?",
                               arguments: [Date(), "\(name):\(armedPath)"])
            }
        }
        if tracked {
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            let encodedState = state.encoded
            // The bookmark a real read would have stored: the server's HIGHESTMODSEQ
            // now, before the test changes anything (a change made later moves it).
            let modSeq = server.qresyncHighestModSeq(for: path)
            let cursor = IMAPChangeCursor(uidValidity: UInt32(serverEpoch), highestModSeq: UInt64(modSeq), uidNext: UInt32((serverUIDs.max() ?? 0) + 1)).encoded
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, changeState = ? WHERE id = ?",
                               arguments: [cursor, encodedState, "\(name):\(path)"])
            }
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: name, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        try await body(World(server: server, provider: provider, engine: engine, pool: pool, account: account))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - Untracked folders through the engine

    @Test("Untracked, changed: the change pass re-lists the folder, stores its counters, and walks a ghost away")
    func untrackedChangedFolderIsRelisted() async throws {
        try await Self.withWorld("eng-untracked", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3, 4, 5], localUIDs: [1, 2, 3, 4, 5, 6]) { w in
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            #expect(try w.uids() == ["1", "2", "3", "4", "5"], "the ghost 6 is gone, nothing else")
            let folder = try w.folder()
            #expect(folder.totalCount == 5)
            #expect(folder.lastKnownUidNext == 6)
            #expect(folder.changeCursor == nil)
        }
    }

    @Test("Untracked, unchanged: the change pass reads STATUS only and lists nothing")
    func untrackedUnchangedFolderIsNotListed() async throws {
        try await Self.withWorld("eng-quiet", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { w in
            // Unchanged means the folder holds the server's whole tuple from an
            // earlier listing: count, UIDNEXT and MODSEQ.
            let folderId = w.folderId
            let modSeq = w.server.qresyncHighestModSeq(for: Self.path)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET totalCount = 3, lastKnownUidNext = 4, lastKnownHighestModSeq = ? WHERE id = ?",
                               arguments: [modSeq, folderId])
            }
            let start = w.server.recordedCommands().count
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let fetches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("FETCH") }
            #expect(fetches.isEmpty, "an unchanged untracked folder is not listed: \(Array(fetches))")
            #expect(try w.uids() == ["1", "2", "3"])
        }
    }

    // MARK: - Turnover re-drive

    @Test("An armed turnover is re-driven by the change pass: old-epoch rows go, the new epoch is stored, the arm is cleared")
    func armedTurnoverIsRedriven() async throws {
        try await Self.withWorld("eng-redrive", capabilities: Self.condstoreOnly,
                                 serverUIDs: [201, 202], localUIDs: [1, 2, 3],
                                 serverEpoch: Self.epoch + 1, storedEpoch: Self.epoch) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), folderId])
            }
            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performChangePass(account: w.account, provider: w.provider)
            }
            let folder = try w.folder()
            #expect(folder.uidValidityResetPendingAt == nil, "the re-drive completed the reaction")
            #expect(folder.lastKnownUidValidity == Self.epoch + 1)
            #expect(try w.uids().isDisjoint(with: ["1", "2", "3"]), "no old-epoch row survives")
        }
    }

    /// RED before #1287: the pass re-drove every armed folder before it read,
    /// so a reaction that could not finish kept the account's new mail unread.
    /// The pass reads first: by the time the armed folder's reaction purges, the
    /// new message is already stored.
    @Test("A change pass stores the account's new mail before it re-drives an armed folder's turnover")
    func changePassReadsBeforeTheRedrive() async throws {
        try await Self.withWorld("eng-redrive-order", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3, 4], localUIDs: [1, 2, 3], withArmedFolder: true) { w in
            let armedId = "\(w.account.id):\(Self.armedPath)"
            let inboxId = w.folderId
            let pool = w.pool
            // nil until the reaction reaches its purge: a hook that never runs fails.
            let storedAtReaction = Mutex<Bool?>(nil)
            AccountManager.uidValidityResetCheckpointHooksForTesting.withLock {
                $0[.afterPurgeBeforeStamp(folderId: armedId)] = {
                    let stored = try await pool.read { db in
                        try MessageHeader.filter(Column("folderId") == inboxId && Column("messageId") == "4").fetchCount(db)
                    }
                    storedAtReaction.withLock { $0 = stored == 1 }
                }
            }
            defer { AccountManager.uidValidityResetCheckpointHooksForTesting.withLock { $0 = [:] } }

            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performChangePass(account: w.account, provider: w.provider)
            }

            let seen = storedAtReaction.withLock { $0 }
            let armedRow = try await pool.read { db in try Folder.fetchOne(db, key: armedId) }
            let armed = try #require(armedRow)
            #expect(seen == true, "the turnover reaction ran before the pass stored the new mail (nil: it never ran)")
            #expect(try w.uids().contains("4"), "the pass did not store the new mail")
            #expect(armed.uidValidityResetPendingAt == nil, "the re-drive after the read did not complete the reaction")
        }
    }

    /// RED before #1287: the re-drive had no budget of its own, so a pass that
    /// reached its turn with no time left still ran every armed folder's
    /// reaction. Now it starts none; the folder stays armed, and the next pass
    /// with time left completes it.
    @Test("A pass with no read budget left re-drives no turnover; the next pass with time does")
    func spentReadBudgetStartsNoRedrive() async throws {
        try await Self.withWorld("eng-redrive-budget", capabilities: Self.condstoreOnly,
                                 serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3], withArmedFolder: true) { w in
            let armedId = "\(w.account.id):\(Self.armedPath)"
            let pool = w.pool
            func armed() async throws -> Folder {
                let row = try await pool.read { db in try Folder.fetchOne(db, key: armedId) }
                return try #require(row)
            }

            // A pass that gets its turn at its deadline: its read budget is spent.
            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performChangePass(account: w.account, provider: w.provider, deadline: Date())
            }
            let afterSpentPass = try await armed()
            #expect(afterSpentPass.uidValidityResetPendingAt != nil, "a pass with no read budget left ran the turnover reaction")
            #expect(afterSpentPass.lastKnownUidValidity == Self.epoch, "a pass with no read budget left stamped the new epoch")

            await TestProviderRegistry.withRegisteredProvider(accountId: w.account.id, provider: w.provider) {
                _ = try? await w.engine.performChangePass(account: w.account, provider: w.provider)
            }
            let afterNextPass = try await armed()
            #expect(afterNextPass.uidValidityResetPendingAt == nil, "the next pass with time left did not re-drive the folder")
            #expect(afterNextPass.lastKnownUidValidity == Self.epoch + 1)
        }
    }

    // MARK: - A bookmark started with no listing

    @Test("A bookmark a pass with no listing starts still gets its whole-folder check: an older message read elsewhere before it is read here after the next foreground sync")
    func bookmarkStartedWithoutListingKeepsItsCatchUp() async throws {
        // More than one window: the device holds every UID, the window listing
        // reaches only the newest, so only the catch-up reaches UID 1000.
        let uids = Array(1000..<(1000 + SyncConfig.syncMessageLimit + 10))
        try await Self.withWorld("eng-catchup", capabilities: Self.qresync, serverUIDs: uids, localUIDs: uids) { w in
            let accountId = w.account.id
            func account() throws -> Account { try #require(try w.pool.read { db in try Account.fetchOne(db, key: accountId) }) }
            func oldest() throws -> MessageHeader? {
                let folderId = w.folderId
                return try w.pool.read { db in
                    try MessageHeader.filter(Column("folderId") == folderId && Column("messageId") == "1000").fetchOne(db)
                }
            }
            // The folder's catch-up has completed once, as an untracked folder's has.
            _ = await w.engine.runCatchUpRun(account: try account(), run: .snapshot(deadline: Date().addingTimeInterval(30)))
            #expect(IMAPCatchUpState.decode(try w.folder().catchUpState)?.lastCompletedAt != nil, "setup: the catch-up completed")
            #expect(try oldest()?.isRead == false, "setup: unread here")
            // Another device reads the oldest message, then a pass with no listing
            // (a background pass) starts the bookmark after that change.
            w.server.setFlags(["\\Seen"], in: Self.path, uid: 1000)
            _ = try await w.engine.performChangePass(account: try account(), provider: w.provider, inboxOnly: true)
            #expect(IMAPChangeCursor.decode(try w.folder().changeCursor) != nil, "setup: the bookmark is stored")
            #expect(!FolderChangeState(raw: try w.folder().changeState).tracking, "setup: not tracked yet")
            // The next foreground sync and catch-up run.
            _ = try? await w.engine.sync(account: try account())
            _ = await w.engine.runCatchUpRun(account: try account(), run: .snapshot(deadline: Date().addingTimeInterval(30)))
            #expect(FolderChangeState(raw: try w.folder().changeState).tracking, "setup: the foreground sync tracks the folder")
            #expect(try oldest()?.isRead == true, "the change made before the bookmark reaches the row")
        }
    }

    // MARK: - The held range comes from the older-mail walk

    @Test("The oldest held message, deleted elsewhere and then un-deleted, is shown on the device again on the next pass")
    func undeletedOldestMessageComesBack() async throws {
        try await Self.withWorld("eng-undelete", capabilities: Self.qresync,
                                 serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3], tracked: true) { w in
            let accountId = w.account.id
            let folderId = w.folderId
            func account() throws -> Account { try #require(try w.pool.read { db in try Account.fetchOne(db, key: accountId) }) }
            // The older-mail walk has downloaded the whole folder.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 1, backfillUidCursor = NULL WHERE id = ?", arguments: [folderId])
            }
            _ = try await w.engine.performChangePass(account: try account(), provider: w.provider, inboxOnly: true)
            #expect(try w.uids() == ["1", "2", "3"], "setup: the bookmark is current")
            w.server.setFlags(["\\Deleted"], in: Self.path, uid: 1)
            _ = try await w.engine.performChangePass(account: try account(), provider: w.provider, inboxOnly: true)
            #expect(try w.uids() == ["2", "3"], "setup: the deleted message left the device")
            w.server.setFlags([], in: Self.path, uid: 1)
            _ = try await w.engine.performChangePass(account: try account(), provider: w.provider, inboxOnly: true)
            #expect(try w.uids() == ["1", "2", "3"], "the un-deleted message is shown again")
        }
    }

    @Test("Keyword labels set elsewhere on a held message: added, kept through a flag-only change, and removed")
    func keywordLabelsFollowTheServer() async throws {
        try await Self.withWorld("eng-keywords", capabilities: Self.qresync,
                                 serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3], tracked: true) { w in
            let accountId = w.account.id
            let folderId = w.folderId
            func account() throws -> Account { try #require(try w.pool.read { db in try Account.fetchOne(db, key: accountId) }) }
            func pass() async throws {
                _ = try await w.engine.performChangePass(account: try account(), provider: w.provider, inboxOnly: true)
            }
            func labels(_ uid: Int) throws -> [String] {
                try w.pool.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT ul.providerLabelId FROM messageUserLabel mul
                        JOIN userLabel ul ON ul.id = mul.userLabelId
                        JOIN messageHeader h ON h.id = mul.messageId
                        WHERE h.folderId = ? AND h.messageId = ? ORDER BY ul.providerLabelId
                        """, arguments: [folderId, String(uid)])
                }
            }
            func isRead(_ uid: Int) throws -> Bool? {
                try w.pool.read { db in
                    try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                      arguments: [folderId, String(uid)])
                }
            }
            try await pass()
            #expect(try labels(2).isEmpty, "setup: no label yet")
            w.server.setFlags(["project"], in: Self.path, uid: 2)
            try await pass()
            #expect(try labels(2) == ["project"], "a keyword added elsewhere is the message's label")
            w.server.setFlags(["project", "\\Seen"], in: Self.path, uid: 2)
            try await pass()
            #expect(try isRead(2) == true, "setup: the flag-only change applied")
            #expect(try labels(2) == ["project"], "a flag-only change keeps the label")
            w.server.setFlags(["\\Seen"], in: Self.path, uid: 2)
            try await pass()
            #expect(try labels(2).isEmpty, "a keyword removed elsewhere removes the label")
            #expect(try isRead(2) == true, "the read state is untouched by the label removal")
            #expect(try labels(1).isEmpty && labels(3).isEmpty, "no other message gains a label")
        }
    }

    // MARK: - The count walk's presence answer

    @Test("A provider that cannot say which ids exist: the count walk deletes nothing")
    func noPresenceAnswerDeletesNothing() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let name = "eng-nopresence"
        _ = try FolderEpochTestFixture.makeAccount(id: name, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: name, path: Self.path, role: .inbox, pool: pool,
                                                totalCount: 3, lastKnownUidNext: 4, lastKnownUidValidity: Self.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: name, path: Self.path, uids: [1, 2, 3], pool: pool)
        let mock = MockEmailProvider()
        let engine = SyncEngine()
        await engine.register(accountId: name, provider: mock, workQueue: ProviderWorkQueue(provider: mock, maxConcurrency: 1))
        let folder = try #require(try FolderEpochTestFixture.readFolder(accountId: name, path: Self.path, pool: pool))
        await engine.reconcileExternallyDeletedMessages(folder: folder, provider: mock, expectedGhosts: 3)
        #expect(try FolderEpochTestFixture.headerCount(accountId: name, path: Self.path, pool: pool) == 3,
                "no answer is never read as 'gone'")
    }

    // MARK: - Tracked folders skip the timers

    @Test("The full sync's count walk skips a tracked folder; the same folder untracked is walked")
    func fullSyncCountWalkSkipsTrackedFolder() async throws {
        for tracked in [true, false] {
            try await Self.withWorld("eng-walk-\(tracked)", capabilities: Self.qresync,
                                     serverUIDs: [1, 2, 3, 4, 5], localUIDs: [1, 2, 3, 4, 5, 6], tracked: tracked) { w in
                _ = try await w.engine.fullSync(account: w.account, provider: w.provider)
                let held = try w.uids()
                if tracked {
                    #expect(held.contains("6"), "a tracked folder's removals arrive through the change read, not the walk")
                } else {
                    #expect(!held.contains("6"), "control: the untracked folder's ghost is walked away")
                }
            }
        }
    }

    // MARK: - No arrival is lost across background passes

    /// Background passes (inbox only, no full sync) on a tracked folder: one pass
    /// the server cannot track it (`glitch(true)`), then it can again. Every
    /// message that arrived on the server meanwhile is on the device after the
    /// later background passes, with no foreground sync in between.
    static func noArrivalLostAcrossBackgroundPasses(
        _ name: String, glitch: @escaping (FakeIMAPServer, Bool) -> Void
    ) async throws {
        try await withWorld(name, capabilities: qresync, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3], tracked: true) { w in
            let accountId = w.account.id
            func background() async throws {
                let account = try #require(try await w.pool.read { db in try Account.fetchOne(db, key: accountId) })
                _ = try await w.engine.performChangePass(account: account, provider: w.provider, inboxOnly: true)
            }
            try await background()
            // The glitch pass: a message arrives while the folder cannot be tracked.
            await w.provider.markDirty()
            glitch(w.server, true)
            w.server.setMessages([1, 2, 3, 4].map(IMAPChangeReaderTests.message), in: path)
            try await background()
            // Tracking works again; X arrives before the next pass, Y after it.
            await w.provider.markDirty()
            glitch(w.server, false)
            w.server.setMessages([1, 2, 3, 4, 5].map(IMAPChangeReaderTests.message), in: path)
            try await background()
            w.server.setMessages([1, 2, 3, 4, 5, 6].map(IMAPChangeReaderTests.message), in: path)
            try await background()
            let held = try w.uids()
            for uid in 1...6 {
                #expect(held.contains(String(uid)), "message \(uid) arrived on the server and is missing on the device after the background passes")
            }
        }
    }

    @Test("No arrival is lost across background passes when one session's ENABLE QRESYNC is not acknowledged")
    func noArrivalLostWhenEnableIsNotAcknowledged() async throws {
        try await Self.noArrivalLostAcrossBackgroundPasses("eng-enable-ignored") { server, on in
            server.setIgnoresEnableQResync(on)
        }
    }

    @Test("No arrival is lost across background passes when one QRESYNC SELECT leaves out HIGHESTMODSEQ")
    func noArrivalLostWhenSelectOmitsModSeq() async throws {
        try await Self.noArrivalLostAcrossBackgroundPasses("eng-nomodseq") { server, on in
            server.setNoModSeq(on, for: Self.path)
        }
    }

}
