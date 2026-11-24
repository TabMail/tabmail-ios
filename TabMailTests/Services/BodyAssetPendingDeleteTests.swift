/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// #1376: the body-asset pending-delete list and its worker, the one-time sweep,
/// the publish owner check, file-first deletes and the Settings wipe.
///
/// Every test pins a SYSTEM PROPERTY of the store ("a deleted message's cached
/// files are gone", "a write in progress is never deleted under it", "no file is
/// left that no row names"), never which helper ran.
///
/// Uses the production `AppDatabase.dbPool` (the worker reads the list there) with
/// a per-test account prefix, and a per-test asset container plus in-memory
/// manifest. The list is process-global, so each test that counts batches starts
/// from an empty list; the suite is serialized with the other process-global suites.
@Suite("Body-asset pending deletes (#1376)", .serialized, .processGlobalState)
struct BodyAssetPendingDeleteTests {

    // MARK: - Fixture

    private static func makeAssetEnvironment() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pendingDeleteTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: try BodyAssetStore._makeTestQueue())
        return dir
    }

    private static func teardownAssets(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    private func seedScope(accountId: String, folderPath: String) async throws {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(
                    emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .imap)
                account.id = accountId
                try account.insert(db)
            }
            if try Folder.fetchOne(db, key: folderId) == nil {
                let folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
                try folder.insert(db)
            }
        }
    }

    @discardableResult
    private func seedHeader(accountId: String, folderPath: String, messageId: String) async throws -> MessageHeader {
        let header = MessageHeader(
            messageId: messageId,
            subject: "pending delete fixture", from: "a", fromAddress: "a@example.com", to: "b@example.com",
            date: Date(), snippet: "",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath,
            isInInbox: false
        )
        try await AppDatabase.dbPool.write { db in try header.insert(db) }
        return header
    }

    private func cleanup(accountId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
            try db.execute(
                sql: #"DELETE FROM bodyAssetPendingDelete WHERE contentKey LIKE ? ESCAPE '\'"#,
                arguments: [MessageIdentity.escapeForLike(accountId) + ":%"])
        }
    }

    private func clearPendingList() async throws {
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM bodyAssetPendingDelete")
        }
    }

    private func queue(_ keys: [ContentKey]) async throws {
        try await AppDatabase.dbPool.write { db in
            for key in keys {
                try db.execute(
                    sql: "INSERT INTO bodyAssetPendingDelete (contentKey) VALUES (?)",
                    arguments: [key.rawValue])
            }
        }
    }

    private func pendingEntries(for key: ContentKey) async throws -> Int {
        try await AppDatabase.dbPool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM bodyAssetPendingDelete WHERE contentKey = ?",
                arguments: [key.rawValue]) ?? -1
        }
    }

    private func attach(_ key: ContentKey, section: String = "2", bytes: Int = 32) -> String? {
        BodyAssetStore.writeAttachment(
            contentKey: key, section: section, contentType: "application/pdf",
            data: Data(repeating: 7, count: bytes), identityStamp: "rfc:\(key.rawValue)@example.com")
    }

    private func fileExists(_ assetId: String) -> Bool {
        guard let dir = BodyAssetStore.storeDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(assetId).path)
    }

    private func rows(for key: ContentKey) throws -> Int {
        guard let queue = BodyAssetStore.manifestQueue() else { return -1 }
        return try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM bodyAsset WHERE headerId = ?",
                arguments: [key.rawValue]) ?? -1
        }
    }

    private func leaseCount() throws -> Int {
        guard let queue = BodyAssetStore.manifestQueue() else { return -1 }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bodyAssetPreparation") ?? -1
        }
    }

    /// One worker pass with a budget that cannot run out and an explicit
    /// foreground answer, so the outcome never depends on the host's state.
    @discardableResult
    private func runWorker(
        batchSize: Int = SyncConfig.bodyAssetPendingDeleteBatchSize,
        checkpoint: @escaping @Sendable () async -> Void = {},
        foreground: @escaping @Sendable () -> Bool = { true }
    ) async -> BodyAssetMaintenance.PendingDeletePass {
        await BodyAssetMaintenance.processPendingDeletes(
            batchSize: batchSize, passBudgetSeconds: 120,
            checkpoint: checkpoint, foreground: foreground)
    }

    /// A foreground answer that is true for its first `n` calls and false after, to
    /// leave the foreground at an exact point of a pass.
    private static func foreground(forCalls n: Int) -> @Sendable () -> Bool {
        let calls = Locked(0)
        return {
            calls.mutate { $0 += 1 }
            return calls.get() <= n
        }
    }

    /// Every statement the test manifest's one connection runs during `body`.
    /// `expandedDescription` carries bound values: acceptable only because this is
    /// a throwaway in-memory fixture.
    private func manifestStatements(during body: () async -> Void) async -> [String] {
        guard let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return []
        }
        let tape = Locked<[String]>([])
        queue.inDatabase { db in
            db.trace(options: .statement) { event in
                let sql = event.expandedDescription
                tape.mutate { $0.append(sql) }
            }
        }
        await body()
        queue.inDatabase { db in db.trace(options: .statement, nil) }
        return tape.get()
    }

    // MARK: - The worker

    /// The production path end to end: a header delete queues its id in the same
    /// transaction (v114 trigger), and one worker pass deletes the message's cached
    /// rows AND files and takes the entry off the list.
    @Test("A deleted message's cached assets are deleted by the worker, rows and files")
    func headerDeleteQueuesAndTheWorkerDeletes() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-header-delete"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let header = try await seedHeader(accountId: accountId, folderPath: "INBOX", messageId: "7001")
        let key = ContentKey(rawValue: header.id)
        guard let attachment = attach(key), let inline = BodyAssetStore.writeInlineImage(
            contentKey: key, contentId: "cid-1", contentType: "image/png",
            data: Data(repeating: 1, count: 16)) else {
            Issue.record("asset writes failed")
            return
        }

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [header.id])
        }
        #expect(try await pendingEntries(for: key) == 1, "the header delete queues its id")

        await runWorker()

        #expect(try rows(for: key) == 0, "the deleted message's rows must go")
        #expect(!fileExists(attachment) && !fileExists(inline), "and its files")
        #expect(try await pendingEntries(for: key) == 0, "a settled key leaves the list")
        await cleanup(accountId: accountId)
    }

    /// A write in progress for a queued key is never deleted under it: the entry
    /// stays. Once the write publishes, the next pass deletes its row, so no row
    /// survives for a key no message names.
    @Test("A live write keeps the entry; the next pass deletes what it published")
    func liveWriteKeepsTheEntryAndALaterPassDeletes() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-live-write"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let key = ContentKey(rawValue: "\(accountId):INBOX:7101")
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "2", contentType: "application/pdf",
            data: Data(repeating: 3, count: 24), identityStamp: "rfc:live-write@example.com") else {
            Issue.record("prepare failed")
            return
        }
        try await queue([key])

        await runWorker()

        #expect(try await pendingEntries(for: key) == 1, "a key with a write in progress stays queued")
        #expect(try leaseCount() == 1, "the live lease is not reaped")
        #expect(BodyAssetStore.publish(prepared) == prepared.blobId)
        #expect(try rows(for: key) == 1)

        await runWorker()

        #expect(try rows(for: key) == 0, "the published row of a dead key is deleted on the next pass")
        #expect(!fileExists(prepared.blobId))
        #expect(try await pendingEntries(for: key) == 0)
        await cleanup(accountId: accountId)
    }

    /// Most keys of a large delete have nothing cached (only opened messages cache
    /// assets): their entries go with one manifest READ for the batch and no
    /// manifest write at all.
    @Test("Keys with nothing cached are dropped with no manifest write")
    func keysWithoutAssetsCostNoManifestWrite() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-no-assets"
        try await clearPendingList()
        let keys = (0..<5).map { ContentKey(rawValue: "\(accountId):INBOX:72\($0)") }
        try await queue(keys)

        let statements = await manifestStatements { await runWorker() }

        for key in keys {
            let entries = try await pendingEntries(for: key)
            #expect(entries == 0)
        }
        let writes = statements.filter {
            let sql = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return sql.hasPrefix("INSERT") || sql.hasPrefix("UPDATE") || sql.hasPrefix("DELETE")
        }
        #expect(writes.isEmpty, "no manifest write for keys with nothing cached: \(writes)")
        await cleanup(accountId: accountId)
    }

    /// The list drains in bounded batches, and the WAL checkpoint runs once after
    /// each batch (SQLite autocheckpoint is off, so every constant writer bounds the
    /// WAL itself).
    @Test("The list drains in bounded batches with one checkpoint after each")
    func drainsInBoundedBatchesWithACheckpointAfterEach() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-batches"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        try await clearPendingList()
        let keys = (0..<5).map { ContentKey(rawValue: "\(accountId):INBOX:73\($0)") }
        for key in keys { #expect(attach(key) != nil) }
        try await queue(keys)

        let checkpoints = Locked(0)
        let pass = await runWorker(batchSize: 2, checkpoint: { checkpoints.mutate { $0 += 1 } })

        // At least 3: an entry another suite queued meanwhile would add a batch, not break the bound.
        #expect(pass.batches >= 3, "5 entries in batches of 2")
        #expect(checkpoints.get() == pass.batches, "one checkpoint after each batch")
        #expect(pass.deletedKeys == 5)
        #expect(pass.dropped == 5)
        for key in keys {
            let remainingRows = try rows(for: key)
            let entries = try await pendingEntries(for: key)
            #expect(remainingRows == 0)
            #expect(entries == 0)
        }
        await cleanup(accountId: accountId)
    }

    /// Entries are dropped BY ROWID, only the ones the pass decided: an entry for
    /// the same key outside the batch (queued again meanwhile) stays for its own turn.
    @Test("A pass drops only the entries of the batches it decided")
    func dropsOnlyTheDecidedEntries() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-by-rowid"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        try await clearPendingList()
        let keyA = ContentKey(rawValue: "\(accountId):INBOX:7401")
        let keyB = ContentKey(rawValue: "\(accountId):INBOX:7402")
        #expect(attach(keyA) != nil)
        #expect(attach(keyB) != nil)
        try await queue([keyA, keyB, keyA])

        // Stop after the first batch: the checkpoint after it turns the foreground off.
        let stop = Locked(false)
        await runWorker(
            batchSize: 2,
            checkpoint: { stop.set(true) },
            foreground: { !stop.get() })

        let rowsA = try rows(for: keyA)
        let rowsB = try rows(for: keyB)
        let entriesA = try await pendingEntries(for: keyA)
        let entriesB = try await pendingEntries(for: keyB)
        #expect(rowsA == 0)
        #expect(rowsB == 0)
        #expect(entriesB == 0)
        #expect(entriesA == 1,
                "the later entry for the same key was outside the decided batch and stays")

        await runWorker()
        let entriesAfter = try await pendingEntries(for: keyA)
        #expect(entriesAfter == 0, "and its own turn settles it")
        await cleanup(accountId: accountId)
    }

    /// The manifest is a non-WAL store: the worker starts no manifest access outside
    /// the foreground (ADR-IOS-046), and decides nothing.
    @Test("Outside the foreground the worker reads nothing and deletes nothing")
    func foregroundGateStopsTheWorker() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-background"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let key = ContentKey(rawValue: "\(accountId):INBOX:7501")
        #expect(attach(key) != nil)
        try await queue([key])

        let statements = await manifestStatements {
            let pass = await runWorker(foreground: { false })
            #expect(pass.batches == 0)
        }

        #expect(statements.isEmpty, "no manifest statement outside the foreground")
        #expect(try rows(for: key) == 1)
        #expect(try await pendingEntries(for: key) == 1)
        await cleanup(accountId: accountId)
    }

    /// Leaving the foreground during a pass stops it before its next manifest
    /// access (ADR-IOS-046): the worker checks before the batch's manifest read and
    /// before each key. Calls: 1 = the loop head, 2 = before the manifest read,
    /// 3 = before the first key, 4 = before the second.
    @Test("Leaving the foreground between keys stops the worker before the next key")
    func foregroundLostBetweenKeysStopsBeforeTheNextKey() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-background-mid-batch"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        try await clearPendingList()
        let first = ContentKey(rawValue: "\(accountId):INBOX:7511")
        let second = ContentKey(rawValue: "\(accountId):INBOX:7512")
        #expect(attach(first) != nil)
        #expect(attach(second) != nil)
        try await queue([first, second])

        await runWorker(batchSize: 2, foreground: Self.foreground(forCalls: 3))

        let firstRows = try rows(for: first)
        let secondRows = try rows(for: second)
        let firstEntries = try await pendingEntries(for: first)
        let secondEntries = try await pendingEntries(for: second)
        #expect(firstRows == 0, "the key decided in the foreground is deleted")
        #expect(firstEntries == 0)
        #expect(secondRows == 1, "the key after the foreground was lost is not touched")
        #expect(secondEntries == 1, "and stays queued")
        await cleanup(accountId: accountId)
    }

    @Test("Leaving the foreground after the batch read stops the worker before any manifest access")
    func foregroundLostAfterTheBatchReadStopsBeforeTheManifest() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "pending-background-after-read"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        try await clearPendingList()
        let key = ContentKey(rawValue: "\(accountId):INBOX:7521")
        #expect(attach(key) != nil)
        try await queue([key])

        let statements = await manifestStatements {
            let pass = await runWorker(foreground: Self.foreground(forCalls: 1))
            #expect(pass.batches == 1, "precondition: the loop head let the batch read run")
        }

        #expect(statements.isEmpty, "no manifest statement once the foreground is lost: \(statements)")
        #expect(try rows(for: key) == 1)
        #expect(try await pendingEntries(for: key) == 1)
        await cleanup(accountId: accountId)
    }

    // MARK: - File first, then its row

    /// Every delete path unlinks a file BEFORE deleting the row that names it, in
    /// the same manifest transaction: a crash in between leaves a row whose file is
    /// gone (a read notices and refetches; the next delete finishes), never a file no
    /// row names, which nothing would ever find. Observed at the moment SQLite
    /// starts each row DELETE.
    @Test("Every delete path unlinks the files before it deletes their rows")
    func deletesUnlinkFilesBeforeRows() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        guard let storeDir = BodyAssetStore.storeDirectory(),
              let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("store unavailable")
            return
        }

        func filesPresentAtRowDelete(
            _ assetIds: [String], marker: String, _ body: () -> Void
        ) -> [Bool] {
            let seen = Locked<[Bool]>([])
            let paths = assetIds.map { storeDir.appendingPathComponent($0).path }
            queue.inDatabase { db in
                db.trace(options: .statement) { event in
                    guard event.expandedDescription.contains(marker) else { return }
                    let present = paths.map { FileManager.default.fileExists(atPath: $0) }
                    seen.mutate { $0.append(contentsOf: present) }
                }
            }
            body()
            queue.inDatabase { db in db.trace(options: .statement, nil) }
            return seen.get()
        }

        // deletePendingContentKey (the worker) and deleteAllAssets(forContentKey:).
        let pendingKey = ContentKey(rawValue: "acc-file-first:INBOX:1")
        let purgeKey = ContentKey(rawValue: "acc-file-first:INBOX:2")
        guard let p1 = attach(pendingKey, section: "1"), let p2 = attach(pendingKey, section: "2"),
              let q1 = attach(purgeKey, section: "1") else {
            Issue.record("writes failed")
            return
        }
        let atPendingDelete = filesPresentAtRowDelete([p1, p2], marker: "DELETE FROM bodyAsset WHERE headerId") {
            #expect(BodyAssetStore.deletePendingContentKey(pendingKey) == .deleted(bytes: 64))
        }
        #expect(!atPendingDelete.isEmpty && !atPendingDelete.contains(true),
                "the worker's delete must unlink the files before the row DELETE starts")

        let atPurge = filesPresentAtRowDelete([q1], marker: "DELETE FROM bodyAsset WHERE headerId") {
            #expect(BodyAssetStore.deleteAllAssets(forContentKey: purgeKey) == 32)
        }
        #expect(!atPurge.isEmpty && !atPurge.contains(true))

        // deleteAllAssets(kind:), batched by primary key.
        let wipeKey = ContentKey(rawValue: "acc-file-first:INBOX:3")
        guard let w1 = attach(wipeKey, section: "1") else {
            Issue.record("write failed")
            return
        }
        let atWipe = filesPresentAtRowDelete([w1], marker: "DELETE FROM bodyAsset WHERE id IN") {
            #expect(BodyAssetStore.deleteAllAssets(kind: .attachment) == [wipeKey])
        }
        #expect(!atWipe.isEmpty && !atWipe.contains(true))
    }

    // MARK: - The publish owner check

    /// The main app refuses to publish for a key that names no message: the refused
    /// write leaves no row, no file in the store, no staged file and no lease. The
    /// check runs under the write's lease, which is what makes the worker exact.
    @Test("Publish refuses a key the owner check rejects and leaves nothing behind")
    func publishOwnerCheckRefusesAndLeavesNothing() throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let owned = ContentKey(rawValue: "acc-owner:INBOX:1")
        let orphan = ContentKey(rawValue: "acc-owner:INBOX:2")
        // The leases that exist when the check is asked: the check must run while
        // this write holds its lease (the check is called before `publish` opens its
        // manifest transaction, so reading the manifest here is safe).
        let leasesAtCheck = Locked<[Int]>([])
        BodyAssetStore.setPublishOwnerCheck { key in
            let leases = (try? BodyAssetStore.manifestQueue()?.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bodyAssetPreparation") ?? -1
            }) ?? -1
            leasesAtCheck.mutate { $0.append(leases) }
            return key == owned
        }

        #expect(attach(orphan) == nil, "a key no message names must not be published")
        #expect(try rows(for: orphan) == 0)
        #expect(try leaseCount() == 0, "the refused write releases its lease")
        let staged = (try? FileManager.default.contentsOfDirectory(
            atPath: BodyAssetStore.stagingDirectory()?.path ?? "")) ?? []
        #expect(staged.isEmpty, "and removes its staged bytes")
        let hashDir = BodyAssetStore.folder(for: orphan)?.path ?? ""
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: hashDir)) ?? []).isEmpty,
                "and puts no file into the store")

        // NON-VACUITY: the check lets through what it accepts.
        guard let ownedId = attach(owned) else {
            Issue.record("an accepted key must publish")
            return
        }
        let ownedRows = try rows(for: owned)
        #expect(fileExists(ownedId))
        #expect(ownedRows == 1)
        #expect(leasesAtCheck.get() == [1, 1],
                "the check runs while the write holds its lease, for the refused key and the accepted one")
    }

    /// The production check answers from the main database's header table.
    @Test("headerExists answers whether a header row names the key")
    func headerExistsReadsTheHeaderTable() async throws {
        let accountId = "pending-header-exists"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let header = try await seedHeader(accountId: accountId, folderPath: "INBOX", messageId: "7601")
        #expect(BodyAssetMaintenance.headerExists(ContentKey(rawValue: header.id)))
        #expect(!BodyAssetMaintenance.headerExists(ContentKey(rawValue: "\(accountId):INBOX:7602")))
        await cleanup(accountId: accountId)
    }

    // MARK: - The one-time sweep

    /// The whole-store sweep runs once after the update: it queues every manifest
    /// key no header names (the worker then judges them like any queued key), never
    /// a live one, deletes the files no row names, and sets its flag. A second run
    /// does nothing.
    @Test("The one-time sweep queues only dead keys, prunes unnamed files, and runs once")
    func oneTimeSweepQueuesDeadKeysAndRunsOnce() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let suite = "pending-sweep-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("defaults unavailable")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountId = "pending-sweep"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let live = ContentKey(rawValue: try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "7701").id)
        let dead = ContentKey(rawValue: "\(accountId):INBOX:7702")
        #expect(attach(live) != nil)
        #expect(attach(dead) != nil)
        // A file no row names, aged past the sweep threshold.
        guard let storeDir = BodyAssetStore.storeDirectory() else { return }
        let strayDir = storeDir.appendingPathComponent(String(repeating: "a", count: 16), isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        let stray = strayDir.appendingPathComponent(String(repeating: "b", count: 16))
        try Data("stray".utf8).write(to: stray)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(BodyAssetStore.sweepMinAgeSeconds + 30))],
            ofItemAtPath: stray.path)

        let checkpoints = Locked(0)
        let completed = await BodyAssetMaintenance.runOrphanSweepOnce(
            defaults: defaults, pageSize: 1,
            checkpoint: { checkpoints.mutate { $0 += 1 } }, foreground: { true })

        let deadEntries = try await pendingEntries(for: dead)
        let liveEntries = try await pendingEntries(for: live)
        let deadRows = try rows(for: dead)
        #expect(completed)
        #expect(deadEntries == 1, "a key no header names is queued")
        #expect(liveEntries == 0, "a live key is never queued")
        #expect(deadRows == 1, "the sweep only queues; the worker deletes")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "a file no row names is deleted")
        #expect(defaults.bool(forKey: BodyAssetMaintenance.orphanSweepDoneKey))
        #expect(checkpoints.get() == 2, "one checkpoint after each page that queued")

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM bodyAssetPendingDelete WHERE contentKey = ?", arguments: [dead.rawValue])
        }
        let again = await BodyAssetMaintenance.runOrphanSweepOnce(
            defaults: defaults, pageSize: 1, checkpoint: {}, foreground: { true })
        #expect(!again, "a completed sweep does not run again")
        #expect(try await pendingEntries(for: dead) == 0)
        await cleanup(accountId: accountId)
    }

    /// A sweep abandoned outside the foreground leaves the flag unset, so the next
    /// pass starts it over.
    @Test("A sweep stopped outside the foreground leaves its flag unset")
    func abandonedSweepLeavesTheFlagUnset() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let suite = "pending-sweep-bg-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("defaults unavailable")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let dead = ContentKey(rawValue: "pending-sweep-bg:INBOX:7801")
        #expect(attach(dead) != nil)

        let completed = await BodyAssetMaintenance.runOrphanSweepOnce(
            defaults: defaults, checkpoint: {}, foreground: { false })

        #expect(!completed)
        #expect(!defaults.bool(forKey: BodyAssetMaintenance.orphanSweepDoneKey))
        #expect(try await pendingEntries(for: dead) == 0)
        await cleanup(accountId: "pending-sweep-bg")
    }

    /// Leaving the foreground after the pages, before the file prune, stops the
    /// sweep there: no prune (a manifest access, ADR-IOS-046), flag unset. Calls:
    /// 1 = the only page, 2 = before the prune.
    @Test("A sweep that leaves the foreground before the prune does not prune and leaves its flag unset")
    func sweepStopsBeforeThePruneOutsideTheForeground() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let suite = "pending-sweep-prune-bg-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("defaults unavailable")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountId = "pending-sweep-prune-bg"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let dead = ContentKey(rawValue: "\(accountId):INBOX:7811")
        #expect(attach(dead) != nil)
        guard let storeDir = BodyAssetStore.storeDirectory() else { return }
        let strayDir = storeDir.appendingPathComponent(String(repeating: "c", count: 16), isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        let stray = strayDir.appendingPathComponent(String(repeating: "d", count: 16))
        try Data("stray".utf8).write(to: stray)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(BodyAssetStore.sweepMinAgeSeconds + 30))],
            ofItemAtPath: stray.path)

        let completed = await BodyAssetMaintenance.runOrphanSweepOnce(
            defaults: defaults, checkpoint: {}, foreground: Self.foreground(forCalls: 1))

        let deadEntries = try await pendingEntries(for: dead)
        #expect(deadEntries == 1, "precondition: the page ran in the foreground")
        #expect(!completed)
        #expect(!defaults.bool(forKey: BodyAssetMaintenance.orphanSweepDoneKey))
        #expect(FileManager.default.fileExists(atPath: stray.path), "no prune outside the foreground")
        await cleanup(accountId: accountId)
    }

    // MARK: - Plans

    private static func plan(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
    }

    /// The worker and the one-time sweep touch only what they name: every statement
    /// they run on a mail-sized table plans as an index seek, with no statistics and
    /// after ANALYZE. A SCAN here would put a whole-store walk back. The statements
    /// are the production ones, captured by tracing the connection that runs them:
    /// the manifest's one connection, the main database's writer, and a read the
    /// test runs `pendingDeleteDecision` in. The worker's batch read runs on a pool
    /// reader a test cannot trace, so its planned text is tied to the source.
    @Test("The worker's and the sweep's own statements are index seeks, with and without statistics")
    func pendingDeleteReadsAreSeeks() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        guard let manifest = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return
        }
        let accountId = "pending-plans"
        try await seedScope(accountId: accountId, folderPath: "INBOX")
        let keys = (1...3).map { ContentKey(rawValue: "\(accountId):INBOX:79\($0)") }
        for key in keys { #expect(attach(key) != nil) }

        // Manifest: `contentKeysWithAssets` (the worker) and `manifestContentKeys` (the sweep's pages).
        for analyzed in [false, true] {
            if analyzed {
                try manifest.write { db in
                    for index in 0..<200 {
                        try db.execute(
                            sql: """
                                INSERT INTO bodyAsset (id, headerId, kind, contentType, sizeBytes, createdAt)
                                VALUES (?, ?, 1, 'application/pdf', 16, 0)
                                """,
                            arguments: ["\(index)/blob", "acc:INBOX:\(index / 4)"])
                    }
                    try db.execute(sql: "ANALYZE")
                }
            }
            let statements = await manifestStatements {
                _ = BodyAssetStore.contentKeysWithAssets(among: keys)
                _ = BodyAssetStore.manifestContentKeys(after: nil, limit: SyncConfig.bodyAssetOrphanSweepPageSize)
                _ = BodyAssetStore.manifestContentKeys(after: keys[0], limit: SyncConfig.bodyAssetOrphanSweepPageSize)
            }
            let assetReads = statements.filter { $0.contains("FROM bodyAsset ") }
            #expect(assetReads.count >= 3, "precondition: the three calls' reads were captured: \(statements)")
            for sql in assetReads {
                let plan = try manifest.read { db in try Self.plan(db, sql, []) }
                #expect(plan.contains("SEARCH bodyAsset USING COVERING INDEX") && !plan.contains("TEMP B-TREE"),
                        "analyzed=\(analyzed): \(sql): \(plan)")
            }
        }

        // Main database, the live probe: the statements `pendingDeleteDecision` runs.
        let decisionTape = Locked<[String]>([])
        _ = try await AppDatabase.rawPool.read { db in
            db.trace(options: .statement) { event in
                let sql = event.expandedDescription
                decisionTape.mutate { $0.append(sql) }
            }
            defer { db.trace(options: .statement, nil) }
            return try BodyAssetMaintenance.pendingDeleteDecision(for: keys, db: db)
        }
        let liveProbes = decisionTape.get().filter { $0.hasPrefix("SELECT id FROM messageHeader WHERE id IN") }
        #expect(liveProbes.count == 1, "precondition: the live probe was captured: \(decisionTape.get())")

        // Main database, the sweep's queue write: traced on the one writer connection.
        let suite = "pending-plans-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("defaults unavailable")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let writerTape = Locked<[String]>([])
        try await AppDatabase.rawPool.writeWithoutTransaction { db in
            db.trace(options: .statement) { event in
                let sql = event.expandedDescription
                writerTape.mutate { $0.append(sql) }
            }
        }
        await BodyAssetMaintenance.runOrphanSweepOnce(defaults: defaults, checkpoint: {}, foreground: { true })
        try await AppDatabase.rawPool.writeWithoutTransaction { db in db.trace(options: .statement, nil) }
        let sweepWrites = writerTape.get().filter { $0.contains("INSERT INTO bodyAssetPendingDelete") }
        #expect(!sweepWrites.isEmpty, "precondition: the sweep's queue write was captured")

        // The worker's batch read, tied to its source text.
        let batchRead = "SELECT id, contentKey FROM bodyAssetPendingDelete WHERE id > ? ORDER BY id LIMIT ?"
        let workerSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("TabMail/Services/BodyAssetMaintenance.swift"),
            encoding: .utf8)
        #expect(workerSource.contains("sql: \"\(batchRead)\""), "the planned batch read is the worker's statement")

        let mainPlans = try await AppDatabase.dbPool.write { db -> [(String, String)] in
            try (liveProbes + sweepWrites).map { ($0, try Self.plan(db, $0, [])) }
                + [(batchRead, try Self.plan(db, batchRead, [0, 200]))]
        }
        for (sql, plan) in mainPlans {
            #expect(!plan.contains("SCAN messageHeader") && !plan.contains("SCAN bodyAssetPendingDelete"),
                    "\(sql): \(plan)")
        }
        for (sql, plan) in mainPlans where sql.contains("messageHeader") {
            #expect(plan.contains("SEARCH messageHeader") && plan.contains("(id=?)"), "\(sql): \(plan)")
        }
        if let batchPlan = mainPlans.last?.1 {
            #expect(batchPlan.contains("SEARCH bodyAssetPendingDelete USING INTEGER PRIMARY KEY (rowid>?)"),
                    "list batch: \(batchPlan)")
        }
        await cleanup(accountId: accountId)
        // The sweep also queued the analyzed fixture's keys.
        try await clearPendingList()
    }

    // MARK: - Settings wipe

    /// "Nuke database" deleted every header, so every cached asset of both kinds
    /// goes, rows and files.
    @Test("The local index wipe deletes every cached asset of both kinds")
    func localIndexWipeDeletesEverything() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let key = ContentKey(rawValue: "acc-wipe:INBOX:1")
        guard let attachment = attach(key), let inline = BodyAssetStore.writeInlineImage(
            contentKey: key, contentId: "cid-1", contentType: "image/png",
            data: Data(repeating: 2, count: 16)) else {
            Issue.record("asset writes failed")
            return
        }

        await BodyAssetMaintenance.wipeAllAfterLocalIndexWipe()

        #expect(try rows(for: key) == 0)
        #expect(!fileExists(attachment) && !fileExists(inline))
    }
}

private final class Locked<Value: Sendable>: Sendable {
    private let box: Mutex<Value>
    init(_ value: Value) { box = Mutex(value) }
    func set(_ value: Value) { box.withLock { $0 = value } }
    func get() -> Value { box.withLock { $0 } }
    func mutate(_ body: (inout Value) -> Void) { box.withLock { body(&$0) } }
}
