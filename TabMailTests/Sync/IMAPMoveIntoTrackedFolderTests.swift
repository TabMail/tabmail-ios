/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Moves that end without destination proof, into or out of folders the IMAP
/// change reader tracks (ADR-IOS-111, exit rule). The system property: after
/// the normal sync path (a foreground `sync`, whose full sync runs only when it
/// is due, and the catch-up run), the user's message is held exactly ONCE, in
/// the folder where the server holds it, under the UID the server gave it.
/// Driven end to end: the real action queue drains against `FakeIMAPServer`
/// (wire oracle on), then the engine syncs. Never asserts the mechanism.
///
/// Red-first: the mutants recorded in the mutation ledger revert the gate
/// (UIDPLUS), the exit rule (the `dropChangeBookmark` loop in
/// `MessageHeaderRekey.finishMove`), each of `dropChangeBookmark`'s three
/// effects, and each retirement path's use of `deleteRetiringOperation`.
@Suite("IMAP move without destination proof, tracked folders", .serialized, .processGlobalState)
struct IMAPMoveIntoTrackedFolderTests {

    static let epoch = 10
    static let target = "tracked-move@example.com"
    static let qresync = ["ENABLE", "CONDSTORE", "QRESYNC"]

    static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: tracked move \(uid)\r
        Date: \(TestFixtureDate.rfc2822(daysFromAnchor: -(uid % 900)))\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        body\r

        """)
    }

    static func filler(_ uid: Int) -> FakeIMAPServer.Message { message(uid: uid, id: "tracked-filler-\(uid)@example.com") }

    struct World {
        let server: FakeIMAPServer
        let provider: IMAPProvider
        let engine: SyncEngine
        let pool: DatabasePool
        let accountId: String

        func account() throws -> Account {
            try #require(try pool.read { db in try Account.fetchOne(db, key: accountId) })
        }

        func folder(_ path: String) throws -> Folder {
            try #require(try pool.read { db in try Folder.fetchOne(db, key: "\(accountId):\(path)") })
        }

        func seeded() throws -> MessageHeader {
            try #require(try heldTarget().first)
        }

        func heldTarget() throws -> [MessageHeader] {
            try pool.read { db in
                try MessageHeader
                    .filter(Column("accountId") == accountId && Column("rfc822MessageId").like("%\(IMAPMoveIntoTrackedFolderTests.target)%"))
                    .fetchAll(db)
            }
        }

        @MainActor
        func drain() async throws {
            for _ in 0..<300 {
                let empty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
                let quiet = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
                if empty && quiet { return }
                if quiet && !empty { await AccountManager.shared.drainPendingQueue() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// The normal path: a foreground sync (its full sync only when due),
        /// then the catch-up run. It runs after the completed move's protection
        /// (`SyncConfig.recentlyCompletedTTLSeconds`) has lapsed, as a later
        /// sync does: within it the listing keeps the row on purpose.
        func normalSync() async throws {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let accountId = accountId
            try await pool.write { db in
                try db.execute(sql: "UPDATE account SET lastSyncedAt = NULL WHERE id = ?", arguments: [accountId])
            }
            _ = try? await engine.sync(account: try account())
            _ = await engine.runCatchUpRun(account: try account(), run: .snapshot(deadline: Date().addingTimeInterval(30)))
        }

        func fullSyncDue() throws -> Bool { try account().lastFullSyncAt == nil }

        /// The change pass alone (the tracked path; no listing). It runs after the
        /// completed move's protection has lapsed, as `normalSync` does.
        func changePass() async throws {
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = try await engine.performChangePass(account: try account(), provider: provider)
        }

        /// After a retirement without proof, before any listing: no folder in
        /// `paths` is still trusted through a bookmark (its copy may be wrong, so
        /// only a listing can say what it holds), and that listing is due.
        func expectListedAgainNotTracked(_ paths: [String], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            for path in paths {
                let folder = try folder(path)
                // A new baseline may be read; it is trusted only after the listing.
                #expect(!FolderChangeState(raw: folder.changeState).tracking,
                        "\(label): \(path) is no longer trusted through a bookmark", sourceLocation: sourceLocation)
            }
            #expect(try fullSyncDue(), "\(label): the listing is due", sourceLocation: sourceLocation)
        }

        /// The property: once locally, in the folder the server holds it in,
        /// under that UID.
        func expectHeldOnceWhereTheServerHoldsIt(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let onServer = ["INBOX", "Archive", "C"].flatMap { path in
                server.uids(in: path, rfc822MessageId: IMAPMoveIntoTrackedFolderTests.target).map { (path, $0) }
            }
            #expect(onServer.count == 1, "\(label): setup: the server holds the message once: \(onServer)", sourceLocation: sourceLocation)
            guard let (path, uid) = onServer.first else { return }
            let held = try heldTarget()
            #expect(held.count == 1, "\(label): held once, not \(held.map { "\($0.folderPath)/\($0.messageId)" })", sourceLocation: sourceLocation)
            #expect(held.first?.folderPath == path, "\(label): in \(path)", sourceLocation: sourceLocation)
            #expect(held.first?.messageId == String(uid), "\(label): under the server's UID \(uid)", sourceLocation: sourceLocation)
            #expect(server.wrongMessageViolations().isEmpty, sourceLocation: sourceLocation)
        }
        /// The COPY route without proof keeps the source on the server (it never
        /// expunges what it cannot prove was copied), so the server holds the
        /// message twice. The property there: no row the server does not hold
        /// (no placeholder left), and the message is shown.
        func expectNoPlaceholderLeft(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let onServer = Set(["INBOX", "Archive", "C"].flatMap { path in
                server.uids(in: path, rfc822MessageId: IMAPMoveIntoTrackedFolderTests.target).map { "\(path)/\($0)" }
            })
            let held = try heldTarget().map { "\($0.folderPath)/\($0.messageId)" }
            #expect(!held.isEmpty, "\(label): the message is shown", sourceLocation: sourceLocation)
            #expect(Set(held).isSubset(of: onServer), "\(label): held \(held), server \(onServer.sorted())", sourceLocation: sourceLocation)
            #expect(server.wrongMessageViolations().isEmpty, sourceLocation: sourceLocation)
        }
    }

    /// `tracked`: the folders holding a bookmark at the server's numbers, as a
    /// committed baseline leaves it. `local`: the rows the device holds per folder
    /// (the target is seeded in INBOX at UID 88).
    @MainActor
    static func withWorld(
        _ name: String, capabilities: [String], archive: [Int], local: [String: [Int]],
        tracked: Set<String>, folders: [String] = ["INBOX", "Archive"],
        _ configure: (FakeIMAPServer) -> Void = { _ in },
        _ body: (World) async throws -> Void
    ) async throws {
        var mailboxes: [String: [FakeIMAPServer.Message]] = ["INBOX": [message(uid: 88, id: target)], "Archive": archive.map(filler)]
        if folders.contains("C") { mailboxes["C"] = [] }
        let server = FakeIMAPServer(capabilities: capabilities, mailboxes: mailboxes)
        for mailbox in mailboxes.keys { server.setUidValidity(epoch, for: mailbox) }
        configure(server)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let accountId = "tracked-move-\(name)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        for path in folders {
            let role: FolderRole = path == "INBOX" ? .inbox : (path == "Archive" ? .archive : .custom)
            let uids = mailboxes[path]?.map(\.uid) ?? []
            try FolderEpochTestFixture.insertFolder(accountId: accountId, path: path, role: role, pool: pool,
                                                    totalCount: uids.count, lastKnownUidNext: (uids.max() ?? 0) + 1,
                                                    lastKnownUidValidity: epoch)
            if path == "C" {
                try await pool.write { db in try db.execute(sql: "UPDATE folder SET isFavorite = 1 WHERE id = ?", arguments: ["\(accountId):C"]) }
            }
            if let rows = local[path], !rows.isEmpty {
                try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: path, uids: rows, pool: pool)
            }
        }
        var header = MessageHeader(
            messageId: "88", subject: "tracked move 88", from: "Sender", fromAddress: "sender@example.com",
            to: "receiver@example.com", date: Date(), snippet: "body",
            folderId: "\(accountId):INBOX", accountId: accountId, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(target)>"
        header.observedUidValidity = epoch
        let seeded = header
        try await pool.write { db in try seeded.insert(db) }
        for path in tracked {
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            let encodedState = state.encoded
            let uidNext = (mailboxes[path]?.map(\.uid).max() ?? 0) + 1
            let cursor = IMAPChangeCursor(uidValidity: UInt32(epoch), highestModSeq: 1, uidNext: UInt32(uidNext)).encoded
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, changeState = ? WHERE id = ?",
                               arguments: [cursor, encodedState, "\(accountId):\(path)"])
            }
        }
        // The full sync is not due: only the exit rule can make it due.
        try await pool.write { db in
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), accountId])
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        let engine = SyncEngine()
        await engine.register(accountId: accountId, provider: provider,
                              workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        try await body(World(server: server, provider: provider, engine: engine, pool: pool, accountId: accountId))
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        try? await provider.disconnect()
    }

    // MARK: - Into a tracked folder

    enum Shape: String, CaseIterable {
        case moveCopyUidLeftOut, moveCardinalityMismatch, copyCopyUidLeftOut, copyCardinalityMismatch
    }

    @Test("A move into a tracked folder with no proven destination UID: one copy, under the server's UID, after the normal sync",
          arguments: Shape.allCases)
    @MainActor
    func oneCopyAfterTheNormalSync(_ shape: Shape) async throws {
        var caps = FakeIMAPServer.defaultCapabilities + Self.qresync
        if shape == .copyCopyUidLeftOut || shape == .copyCardinalityMismatch { caps.removeAll { $0 == "MOVE" } }
        try await Self.withWorld(shape.rawValue, capabilities: caps, archive: [50, 120],
                                 local: ["Archive": [50, 120]], tracked: ["INBOX", "Archive"]) { server in
            switch shape {
            case .moveCopyUidLeftOut: server.withholdMoveCOPYUID(forSourceUIDs: [88])
            case .moveCardinalityMismatch: server.reportMoveCOPYUIDWithCardinalityMismatch()
            case .copyCopyUidLeftOut: server.withholdCopyUID(forSourceUIDs: [88])
            case .copyCardinalityMismatch: server.reportCopyUIDWithCardinalityMismatch()
            }
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(try w.fullSyncDue(), "\(shape): the unproven move makes the full sync due")
            try await w.normalSync()
            switch shape {
            case .moveCopyUidLeftOut, .moveCardinalityMismatch: try w.expectHeldOnceWhereTheServerHoldsIt(shape.rawValue)
            case .copyCopyUidLeftOut, .copyCardinalityMismatch: try w.expectNoPlaceholderLeft(shape.rawValue)
            }
        }
    }

    @Test("Below the listing window: the placeholder is healed by the older-mail check the unproven move arms")
    @MainActor
    func placeholderBelowTheWindowIsHealedByTheCatchUp() async throws {
        // Archive holds more than one window; the device holds the newest window
        // only, so neither the window listing nor the count walk reaches UID 88.
        let archive = Array(1000..<(1000 + SyncConfig.syncMessageLimit + 10))
        let localArchive = Array(archive.suffix(SyncConfig.syncMessageLimit))
        try await Self.withWorld("below-window", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: archive, local: ["Archive": localArchive], tracked: ["INBOX", "Archive"]) { server in
            server.withholdMoveCOPYUID(forSourceUIDs: [88])
        } _: { w in
            // Archive has completed its first catch-up, as a tracked folder has.
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: .snapshot(deadline: Date().addingTimeInterval(30)))
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(try w.fullSyncDue())
            // The older-mail check alone heals it: no window listing reaches it.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: .snapshot(deadline: Date().addingTimeInterval(30)))
            #expect(try w.heldTarget().allSatisfy { $0.folderPath != "Archive" || w.server.uids(in: "Archive", rfc822MessageId: Self.target).contains(Int($0.messageId) ?? -1) },
                    "below-window: the older-mail check leaves no Archive row the server does not hold")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("below-window")
        }
    }

    // MARK: - Chained and refused moves

    @Test("A chained move INBOX -> Archive -> C without COPYUID: one copy, where the server holds it, after the normal sync")
    @MainActor
    func chainedMoveWithoutProof() async throws {
        try await Self.withWorld("chained", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive", "C"],
                                 folders: ["INBOX", "Archive", "C"]) { server in
            server.withholdMoveCOPYUID(forSourceUIDs: [88])
            // The first move is still in flight when the second gesture is made.
            server.stallNextCommand(containing: "UID MOVE", seconds: 1)
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            await AccountManager.shared.move([try w.seeded()], to: "C")
            try await w.drain()
            try await w.changePass()
            try w.expectListedAgainNotTracked(["INBOX", "Archive"], "chained")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("chained")
        }
    }

    @Test("A move refused by the server out of a tracked folder: the message is held once, back where the server keeps it")
    @MainActor
    func refusedMoveFromTrackedSource() async throws {
        try await Self.withWorld("refused", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { server in
            server.failNextCommand(containing: "UID MOVE", message: "[NOPERM] Permission denied")
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("refused")
        }
    }

    // MARK: - The gate

    @Test("QRESYNC + ENABLE without UIDPLUS: no folder is ever tracked (no QRESYNC on the wire), and a move leaves one copy")
    @MainActor
    func noUidPlusIsNeverTracked() async throws {
        var caps = FakeIMAPServer.defaultCapabilities + Self.qresync
        caps.removeAll { $0 == "UIDPLUS" }
        try await Self.withWorld("no-uidplus", capabilities: caps, archive: [50, 120],
                                 local: ["Archive": [50, 120]], tracked: []) { _ in } _: { w in
            try await w.normalSync()
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            try await w.normalSync()
            let qresyncCommands = w.server.recordedCommands().filter { $0.uppercased().contains("QRESYNC") }
            #expect(qresyncCommands.isEmpty, "a server without UIDPLUS is never read with QRESYNC: \(qresyncCommands)")
            for path in ["INBOX", "Archive"] {
                #expect(try w.folder(path).changeCursor == nil, "\(path) holds no bookmark")
            }
            try w.expectHeldOnceWhereTheServerHoldsIt("no-uidplus")
        }
    }

    // MARK: - r5: retirements outside a provider result

    @Test("A move that keeps failing until the retry limit retires it: one copy, where the server holds it, after the normal sync")
    @MainActor
    func retryLimitRetirement() async throws {
        // The COPY route: a refused UID COPY changed nothing on the server, so
        // each attempt is charged (a refused UID MOVE "may have partially
        // completed" and is not).
        var caps = FakeIMAPServer.defaultCapabilities + Self.qresync
        caps.removeAll { $0 == "MOVE" }
        try await Self.withWorld("retry-limit", capabilities: caps,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { server in
            for _ in 0..<SyncConfig.pendingOperationServerRefusalRetryLimit {
                server.failNextCommand(containing: "UID COPY", message: "Server busy")
            }
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(w.server.uids(in: "INBOX", rfc822MessageId: Self.target) == [88], "setup: the move never ran")
            try await w.changePass()
            try w.expectListedAgainNotTracked(["INBOX", "Archive"], "retry-limit")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("retry-limit")
        }
    }

    @Test("A move retired because the source's UIDVALIDITY changed: one copy, where the server holds it, after the normal sync")
    @MainActor
    func uidValidityChangedRetirement() async throws {
        try await Self.withWorld("uidvalidity", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { _ in } _: { w in
            w.server.setUidValidity(Self.epoch + 1, for: "INBOX")
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            try await w.changePass()
            try w.expectListedAgainNotTracked(["INBOX", "Archive"], "uidvalidity")
            try await w.normalSync()
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("uidvalidity")
        }
    }

    // MARK: - r5: positive control and the remaining arms

    @Test("A move WITH proof into a tracked folder keeps its bookmark and tracking, and makes no listing due")
    @MainActor
    func provenMoveKeepsTracking() async throws {
        try await Self.withWorld("proven", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { _ in } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            let archive = try w.folder("Archive")
            #expect(archive.changeCursor != nil, "a proven move keeps the destination's bookmark")
            #expect(FolderChangeState(raw: archive.changeState).tracking, "and its tracking")
            #expect(try w.folder("INBOX").changeCursor != nil, "and the source's")
            #expect(try !w.fullSyncDue(), "no listing is due")
            try w.expectHeldOnceWhereTheServerHoldsIt("proven")
        }
    }

    @Test("A proven destination under a UIDVALIDITY the folder does not share: the listing is due at once, and one copy after the normal sync")
    @MainActor
    func destinationEpochDisagreement() async throws {
        try await Self.withWorld("epoch-disagree", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { server in
            server.setUidValidity(Self.epoch + 7, for: "Archive")
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(try w.folder("Archive").changeCursor == nil, "the unproven row's folder is no longer tracked")
            #expect(try w.fullSyncDue())
            try await w.normalSync()
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("epoch-disagree")
        }
    }

    @Test("A chained move whose first hop the server refused: the message is held once, back in the source, after the normal sync")
    @MainActor
    func chainedMoveFirstHopRefused() async throws {
        try await Self.withWorld("chained-refused", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive", "C"],
                                 folders: ["INBOX", "Archive", "C"]) { server in
            server.stallNextCommand(containing: "UID MOVE", seconds: 1)
            server.failNextCommand(containing: "UID MOVE", message: "[NOPERM] Permission denied")
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            await AccountManager.shared.move([try w.seeded()], to: "C")
            try await w.drain()
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("chained-refused")
        }
    }

    // MARK: - r6: the remaining retirement paths

    @Test("A move whose source UID the server no longer holds (already moved): one copy, where the server holds it, after the normal sync")
    @MainActor
    func notFoundRetirement() async throws {
        try await Self.withWorld("not-found", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { server in
            // An earlier attempt's move landed but its answer was lost.
            server.setMessages([], in: "INBOX")
            server.setMessages([Self.filler(50), Self.message(uid: 51, id: Self.target)], in: "Archive")
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            try await w.changePass()
            try w.expectListedAgainNotTracked(["INBOX", "Archive"], "not-found")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("not-found")
        }
    }

    /// Admits the move with no provider registered (nothing drains), then makes
    /// `between` happen, then lets the queue drain.
    @MainActor
    static func moveQueuedThen(_ w: World, between: () async throws -> Void) async throws {
        await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
        await AccountManager.shared.move([try w.seeded()], to: "Archive")
        try await between()
        await AccountManager.shared.registerProviderForTesting(accountId: w.accountId, provider: w.provider)
        try await w.drain()
    }

    @Test("A queued move the claim retires (its source epoch moved on): one copy, where the server holds it, after the normal sync")
    @MainActor
    func claimTimeRetirement() async throws {
        try await Self.withWorld("claim-retire", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { _ in } _: { w in
            try await Self.moveQueuedThen(w) {
                // A turnover the sync already stamped: server and folder agree on a
                // new epoch the op was not recorded under.
                w.server.setUidValidity(Self.epoch + 3, for: "INBOX")
                let inboxId = "\(w.accountId):INBOX"
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?", arguments: [Self.epoch + 3, inboxId])
                }
            }
            try await w.changePass()
            try w.expectListedAgainNotTracked(["INBOX", "Archive"], "claim-retire")
            try await w.normalSync()
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("claim-retire")
        }
    }

    @Test("A queued move dropped by the UIDVALIDITY turnover reaction: one copy, where the server holds it, after the normal sync")
    @MainActor
    func turnoverReactionRetirement() async throws {
        try await Self.withWorld("turnover", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { _ in } _: { w in
            await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            w.server.setUidValidity(Self.epoch + 4, for: "INBOX")
            await AccountManager.shared.registerProviderForTesting(accountId: w.accountId, provider: w.provider)
            // The change pass sees the turnover first; its reaction drops the queued move.
            try await w.changePass()
            try await w.drain()
            try w.expectListedAgainNotTracked(["Archive"], "turnover")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("turnover")
        }
    }

    @Test("A move WITH proof on the COPY route keeps both bookmarks and tracking, and makes no listing due")
    @MainActor
    func provenCopyMoveKeepsTracking() async throws {
        var caps = FakeIMAPServer.defaultCapabilities + Self.qresync
        caps.removeAll { $0 == "MOVE" }
        try await Self.withWorld("proven-copy", capabilities: caps,
                                 archive: [50], local: ["Archive": [50]], tracked: ["INBOX", "Archive"]) { _ in } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(try w.folder("Archive").changeCursor != nil)
            #expect(FolderChangeState(raw: try w.folder("Archive").changeState).tracking)
            #expect(try w.folder("INBOX").changeCursor != nil)
            #expect(try !w.fullSyncDue())
            try w.expectHeldOnceWhereTheServerHoldsIt("proven-copy")
        }
    }

    // MARK: - r7

    @Test("An unproven move between UNTRACKED folders makes no listing due, and the message is held once after the normal sync")
    @MainActor
    func unprovenMoveIntoUntrackedFolder() async throws {
        try await Self.withWorld("untracked", capabilities: FakeIMAPServer.defaultCapabilities + Self.qresync,
                                 archive: [50], local: ["Archive": [50]], tracked: []) { server in
            server.withholdMoveCOPYUID(forSourceUIDs: [88])
        } _: { w in
            await AccountManager.shared.move([try w.seeded()], to: "Archive")
            try await w.drain()
            #expect(try !w.fullSyncDue(), "no folder was tracked, so nothing needs a listing")
            try await w.normalSync()
            try w.expectHeldOnceWhereTheServerHoldsIt("untracked")
        }
    }

    /// A database-only world: one account of `provider` with INBOX and Archive,
    /// both holding a tracked bookmark, and the full sync not due.
    static func withBookmarkedFolders(_ provider: AccountProvider, _ body: (DatabasePool, String) throws -> Void) throws {
        let accountId = "tracked-retire-\(provider.rawValue)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: provider, pool: pool)
        var state = FolderChangeState(raw: nil)
        state.tracking = true
        let encoded = state.encoded
        for path in ["INBOX", "Archive"] {
            try FolderEpochTestFixture.insertFolder(accountId: accountId, path: path, role: path == "INBOX" ? .inbox : .archive,
                                                    pool: pool, lastKnownUidValidity: epoch)
            try pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, changeState = ? WHERE id = ?",
                               arguments: ["bookmark-\(path)", encoded, "\(accountId):\(path)"])
            }
        }
        try pool.write { db in
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), accountId])
        }
        try body(pool, accountId)
    }

    @Test("Gmail and Outlook: a move retired with no proof leaves every folder bookmark and its tracking alone",
          arguments: [AccountProvider.gmail, .outlook])
    func accountScopedRetirementKeepsBookmarks(_ provider: AccountProvider) throws {
        try Self.withBookmarkedFolders(provider) { pool, accountId in
            // The optimistic move left the row in Archive under the provider id.
            try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: "Archive", uids: [1], pool: pool)
            let op = PendingOperation(type: .move, messageIds: ["1"], accountId: accountId,
                                      folderPath: "INBOX", destinationPath: "Archive")
            try pool.write { db in
                var row = op
                try row.insert(db)
                try AccountOperationExecutor.deleteRetiringOperation(row, db: db)
            }
            for path in ["INBOX", "Archive"] {
                let folder = try #require(try pool.read { db in try Folder.fetchOne(db, key: "\(accountId):\(path)") })
                #expect(folder.changeCursor == "bookmark-\(path)", "\(provider) \(path): bookmark kept")
                #expect(FolderChangeState(raw: folder.changeState).tracking, "\(provider) \(path): still tracked")
            }
            #expect(try pool.read { db in try Account.fetchOne(db, key: accountId)?.lastFullSyncAt } != nil, "no listing made due")
        }
    }

    @Test("IMAP: a move retired with no proof whose row is no longer at its key still ends the source's tracking")
    func goneRowRetirementDropsTheSource() throws {
        try Self.withBookmarkedFolders(.imap) { pool, accountId in
            // No header row at the move's key: it vanished before the retirement.
            let op = PendingOperation(type: .move, messageIds: ["88"], accountId: accountId,
                                      folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: Self.epoch)
            try pool.write { db in
                var row = op
                try row.insert(db)
                try AccountOperationExecutor.deleteRetiringOperation(row, db: db)
            }
            let inbox = try #require(try pool.read { db in try Folder.fetchOne(db, key: "\(accountId):INBOX") })
            #expect(inbox.changeCursor == nil, "the source the optimistic move emptied is listed again")
            #expect(!FolderChangeState(raw: inbox.changeState).tracking)
            #expect(try pool.read { db in try Account.fetchOne(db, key: accountId)?.lastFullSyncAt } == nil, "its listing is due")
        }
    }
}
