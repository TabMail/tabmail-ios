/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// #1400: a body queue's refill admits a WINDOW of the rows waiting for a body, the
/// newest `SyncConfig.bodyFetchRepopulateLimit`, and once their bodies are stored the
/// next refill admits the next newest window, so successive refills still reach every
/// row. Driven through each queue's real `repopulateFromDatabase()` against a database
/// swapped in as `AppDatabase.shared`, which is the database the refill reads.
///
/// `.serialized, .processGlobalState`: the refill reads the process-wide
/// `AppDatabase.shared`.
@Suite("A body queue refill admits the newest window, then the next", .serialized, .processGlobalState)
struct BodyQueueAdmissionWindowTests {

    private static let window = SyncConfig.bodyFetchRepopulateLimit
    /// Rows past two full windows, so the third refill admits a partial window.
    private static let remainder = 7

    /// A temporary `DatabasePool` with every migration, swapped in as
    /// `AppDatabase.shared`, holding `2 * window + remainder` headers that wait for a
    /// body in one folder (the inbox for the active queue, an archive folder for the
    /// backfill queue), one minute apart counting back from now. Returns their ids
    /// newest first, and the restore closure the caller runs in `defer`.
    private func seed(isInInbox: Bool) throws -> (newestFirst: [String], restore: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let restore: () -> Void = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let folderPath = isInInbox ? "INBOX" : "Archive"
        var account = Account(emailAddress: "window@example.com", displayName: "Window", provider: .imap)
        account.id = "acc1"
        // A refill schedules a dispatch; with no host the account's provider cannot be
        // built, so nothing here can reach the network.
        #expect(account.imapHost == nil, "fixture precondition: the account has no imapHost")
        var folder = Folder(name: folderPath, path: folderPath, role: isInInbox ? .inbox : .archive, accountId: "acc1")
        folder.lastKnownUidValidity = 1000
        let now = Date()
        let count = 2 * Self.window + Self.remainder
        do {
            let newestFirst = try pool.write { db -> [String] in
                try account.insert(db)
                try folder.insert(db)
                var ids: [String] = []
                for n in 0..<count {
                    var header = MessageHeader(
                        messageId: String(n + 1),
                        subject: "Message \(n)",
                        from: "sender@example.com",
                        fromAddress: "sender@example.com",
                        to: "recipient@example.com",
                        date: now.addingTimeInterval(-60 * Double(n)),
                        snippet: "",
                        folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: folderPath),
                        accountId: "acc1",
                        folderPath: folderPath,
                        isInInbox: isInInbox
                    )
                    header.headerComplete = true
                    try header.insert(db)
                    ids.append(header.id)
                }
                return ids
            }
            return (newestFirst, restore)
        } catch {
            restore()
            throw error
        }
    }

    /// Stores the rows' bodies as a completed fetch does, so they leave the admission
    /// predicate.
    private func storeBodies(_ ids: [String]) async throws {
        try await AppDatabase.dbPool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Three refills, each after the window before it has its bodies: the newest
    /// window, the next, then the partial rest; a fourth finds nothing left.
    /// `orderedAdmission` is the queue's admission read, checked for newest-first order;
    /// `refill` runs the queue's real refill and returns the ids it admitted.
    private func expectSuccessiveWindows(
        _ newestFirst: [String],
        orderedAdmission: @escaping @Sendable (Database) throws -> [String],
        refill: () async throws -> [String]
    ) async throws {
        var remaining = newestFirst
        for pass in 1...3 {
            let expected = Array(remaining.prefix(Self.window))
            let ordered = try await AppDatabase.dbPool.read { db in try orderedAdmission(db) }
            let newestFirstWindow = ordered == expected
            #expect(newestFirstWindow, "refill \(pass): the admission read returns the newest \(expected.count) waiting rows, newest first (it returned \(ordered.count))")
            let admitted = try await refill()
            #expect(admitted.count == expected.count, "refill \(pass): admitted \(admitted.count) rows, the window holds \(expected.count)")
            let admittedSet = Set(admitted)
            let expectedSet = Set(expected)
            #expect(admittedSet == expectedSet, "refill \(pass): the queue holds exactly that window")
            try await storeBodies(expected)
            remaining.removeFirst(expected.count)
        }
        let afterEveryWindow = try await refill()
        #expect(afterEveryWindow.isEmpty, "every waiting row was admitted by some refill: \(afterEveryWindow.count) left")
    }

    @Test("ActiveBodyQueue: a refill admits the newest window of waiting inbox bodies, the next refill the next window, until every row was admitted")
    func activeRefillsAdmitSuccessiveWindows() async throws {
        let (newestFirst, restore) = try seed(isInInbox: true)
        defer { restore() }
        let queue = ActiveBodyQueue()
        try await expectSuccessiveWindows(
            newestFirst,
            orderedAdmission: { try ActiveBodyQueue.admissionItems($0).map(\.headerId) }
        ) {
            await queue.repopulateFromDatabase()
            let admitted = await queue.queuedItemsForTesting.map(\.headerId)
            // Empty the queue, so the next refill admits from the database alone.
            await queue.emptyForTesting()
            return admitted
        }
    }

    @Test("BackfillBodyQueue: a refill admits the newest window of waiting bodies, the next refill the next window, until every row was admitted")
    func backfillRefillsAdmitSuccessiveWindows() async throws {
        let (newestFirst, restore) = try seed(isInInbox: false)
        defer { restore() }
        let queue = BackfillBodyQueue()
        await queue.setDispatchSuppressedForTesting(true)
        try await expectSuccessiveWindows(
            newestFirst,
            orderedAdmission: { try BackfillBodyQueue.admissionItems($0).map(\.headerId) }
        ) {
            await queue.repopulateFromDatabase()
            let admitted = await queue.queuedItemsForTesting.map(\.headerId)
            // Empty the queue, so the next refill admits from the database alone.
            await queue.emptyForTesting()
            return admitted
        }
    }
}
