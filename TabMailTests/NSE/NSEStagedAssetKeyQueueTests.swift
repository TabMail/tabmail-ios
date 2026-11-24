/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1376: the notification extension writes a staged message's inline images
/// under its STAGED content key. When the merge is done with the staged message
/// (its staging row goes), that key must end either held by a header (whose own
/// delete queues it through the v114 triggers) or on `bodyAssetPendingDelete`;
/// otherwise nothing would ever name those assets again. One test per way the
/// merge lets a staging row go, and one that a failed queue keeps the row.
@Suite("NSE merge: a staged message's asset key ends held by a header or queued", .serialized, .processGlobalState)
@MainActor
struct NSEStagedAssetKeyQueueTests {

    // MARK: - Harness (mirrors NSEStaleStagedRowInvalidationTests)

    private struct World {
        let dir: URL
        let pool: DatabasePool
        let inbox: Folder
        let archive: Folder
        let previous: AppDatabase?
        let stagingPath: String
        let staging: DatabaseQueue
    }

    private func makeWorld() throws -> World {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: stagingPath)
        NSEDataBridge.resetStageMemoForTesting()
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        return World(dir: dir, pool: pool, inbox: inbox, archive: archive, previous: previous,
                     stagingPath: stagingPath, staging: try DatabaseQueue(path: stagingPath))
    }

    private func retire(_ world: World) {
        AppDatabase.shared.withLock { $0 = world.previous }
        TestDatabaseTeardown.retire(pools: [world.pool], queues: [world.staging], directory: world.dir)
    }

    /// A staged header row (mirrors `NSEStagingDB.stageHeader`). `aiCompleted`
    /// true makes it terminal, so the merge lets it go; false keeps it (gradual).
    private func stage(
        _ world: World, messageId: String = "msg-1", folderPath: String = "INBOX", aiCompleted: Bool,
        body: Bool = false
    ) throws {
        try world.staging.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, 'acc1', 'user@example.com', 'gmail', ?, ?, ?,
                        'Subject under test', 'Alice', 'alice@example.com', 'snippet preview', ?,
                        ?, ?, 0, 1)
                """, arguments: [
                    "acc1:\(messageId)", messageId, "rfc-\(messageId)@example.com", folderPath,
                    Date().timeIntervalSince1970 - 3600, Date().timeIntervalSince1970, aiCompleted
                ])
            if body {
                try db.execute(sql: """
                    UPDATE nse_processed_message SET htmlContent = ?, textContent = ?, hasUnresolvedCIDs = 0
                    WHERE id = ?
                    """, arguments: ["<p>Hello body</p>", "Hello body", "acc1:\(messageId)"])
            }
        }
    }

    /// A durable header carrying the staged message's RFC id under ANOTHER
    /// provider id, so the merge's identity lookup (its RFC step) lands the
    /// staged message on it and no header ever has the staged key.
    @discardableResult
    private func insertDurable(
        _ world: World, messageId: String = "555", folder: Folder, isInInbox: Bool,
        rfc822: String = "rfc-msg-1@example.com"
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId, subject: "Durable", from: "Alice", fromAddress: "alice@example.com",
            to: "user@example.com", date: Date().addingTimeInterval(-3600), snippet: "durable",
            folderId: folder.id, accountId: "acc1", folderPath: folder.path, isInInbox: isInInbox)
        header.rfc822MessageId = rfc822
        try world.pool.write { try header.insert($0) }
        return header.id
    }

    nonisolated private func stagedKey(_ messageId: String = "msg-1", folderPath: String = "INBOX") -> String {
        MessageIdentity.headerId(accountId: "acc1", folderPath: folderPath, messageId: messageId)
    }

    private func pending(_ world: World) async throws -> [String] {
        try await world.pool.read { try String.fetchAll($0, sql: "SELECT contentKey FROM bodyAssetPendingDelete ORDER BY id") }
    }

    private func headerExists(_ world: World, _ id: String) async throws -> Bool {
        try await world.pool.read { try MessageHeader.fetchOne($0, key: id) != nil }
    }

    private func stagingRowExists(_ world: World, messageId: String = "msg-1") throws -> Bool {
        try world.staging.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)",
                              arguments: ["acc1:\(messageId)"]) ?? false
        }
    }

    // MARK: - Tests

    @Test("a terminal message merged under its own key lets its staging row go and queues nothing: its header holds the key")
    func terminalMergeUnderItsOwnKeyQueuesNothing() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        try stage(world, aiCompleted: true)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)

        #expect(try stagingRowExists(world) == false, "precondition: the terminal row went")
        #expect(try await headerExists(world, stagedKey()))
        #expect(try await pending(world).isEmpty)
    }

    @Test("a message merged onto a header with another id queues its staged key only when the merge lets the row go")
    func mergeOntoAnotherIdQueuesTheStagedKeyAtTheEnd() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        let durable = try insertDurable(world, folder: world.inbox, isInInbox: true)
        try stage(world, aiCompleted: false)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        #expect(try stagingRowExists(world) == true, "precondition: a gradual row is kept")
        #expect(try await headerExists(world, durable))
        #expect(try await headerExists(world, stagedKey()) == false, "precondition: merged onto the other id")
        #expect(try await pending(world).isEmpty, "a kept row is never queued")

        try await world.staging.write { db in
            try db.execute(sql: "UPDATE nse_processed_message SET aiCompleted = 1 WHERE id = 'acc1:msg-1'")
        }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)

        #expect(try stagingRowExists(world) == false, "precondition: the terminal row went")
        #expect(try await pending(world) == [stagedKey()])
    }

    @Test("a stale-by-move discard queues the staged key")
    func staleByMoveDiscardQueuesTheStagedKey() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        try insertDurable(world, folder: world.archive, isInInbox: false)
        try stage(world, aiCompleted: false)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)

        #expect(try stagingRowExists(world) == false, "precondition: the stale row was discarded")
        #expect(try await headerExists(world, stagedKey()) == false)
        #expect(try await pending(world) == [stagedKey()])
    }

    @Test("an abandoned row drained by the skip-set cleanup queues its staged key")
    func skipSetDrainQueuesTheStagedKey() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        try insertDurable(world, folder: world.inbox, isInInbox: true)
        try stage(world, aiCompleted: false, body: true)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        #expect(try stagingRowExists(world) == true, "precondition: a gradual row is kept")
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()["acc1:msg-1"] != nil, "precondition: memo recorded")
        #expect(try await pending(world).isEmpty)

        // The extension died long ago; the staged content is unchanged, so the
        // row is a memo hit routed to the skip set and drained there.
        try await world.staging.write { db in
            try db.execute(sql: "UPDATE nse_processed_message SET processedAt = ? WHERE id = 'acc1:msg-1'",
                           arguments: [Date().timeIntervalSince1970 - 120])
        }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)

        #expect(try stagingRowExists(world) == false, "precondition: drained by the skip set")
        #expect(try await pending(world) == [stagedKey()])
    }

    @Test("the old-epoch and identity-refused cleanup queues each staged key no header holds, and lets every row go")
    func discardCleanupQueuesUnheldKeys() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        try stage(world, messageId: "msg-1", aiCompleted: true)
        try stage(world, messageId: "msg-2", aiCompleted: true)
        var held = MessageHeader(
            messageId: "msg-2", subject: "Held", from: "Alice", fromAddress: "alice@example.com",
            to: "user@example.com", date: Date(), snippet: "held",
            folderId: world.inbox.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        held.rfc822MessageId = "rfc-msg-2@example.com"
        try world.pool.write { try held.insert($0) }
        #expect(held.id == stagedKey("msg-2"), "precondition: a header holds the second staged key")

        await NSEDataBridge.applyOldEpochStagingCleanup([
            .init(id: "acc1:msg-1", headerId: stagedKey("msg-1")),
            .init(id: "acc1:msg-2", headerId: stagedKey("msg-2")),
        ], nseDB: world.staging)

        #expect(try stagingRowExists(world, messageId: "msg-1") == false)
        #expect(try stagingRowExists(world, messageId: "msg-2") == false)
        #expect(try await pending(world) == [stagedKey("msg-1")])
    }

    @Test("when the queue write fails, the discard keeps its staging rows for the next wake")
    func failedQueueKeepsTheStagingRows() async throws {
        let world = try makeWorld()
        defer { retire(world) }
        try insertDurable(world, folder: world.archive, isInInbox: false)
        try stage(world, messageId: "msg-1", aiCompleted: false)
        try stage(world, messageId: "msg-3", aiCompleted: true)
        try world.pool.write { try $0.execute(sql: "DROP TABLE bodyAssetPendingDelete") }

        await NSEDataBridge.applyOldEpochStagingCleanup(
            [.init(id: "acc1:msg-3", headerId: stagedKey("msg-3"))], nseDB: world.staging)
        #expect(try stagingRowExists(world, messageId: "msg-3"), "the cleanup kept its row")

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        #expect(try stagingRowExists(world, messageId: "msg-1"), "the stale-by-move discard kept its row")
    }
}
