/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1433: a proven UIDVALIDITY reset deletes EVERY cached body in the folder's id
/// range, with or without a header, in the purge transaction.
///
/// THE INVARIANT: after a folder's reset, a message the new epoch numbers with a
/// reused UID never shows HTML cached for the message that had that UID before.
/// Before #1433 the purge deleted only the bodies whose header it was deleting; a
/// body with no header (left by an earlier crash or a skipped release, #1446) stayed
/// at `<account>:<folder>:<uid>`, and the new message's header, inserted at that
/// same id, read it as its own. The stale-body evict used to reclaim such bodies;
/// since #1433 it reads only headers, so the reset is what keeps the address clean.
///
/// Controls that must keep their bodies: a ':'-delimited child folder
/// (`INBOX:sub`, inside the id range, excluded by the no-deeper-colon guard), a
/// sibling whose path extends the name (`INBOX2`), and another account whose id
/// extends this one's (same folder path, same UID).
@Suite("A UIDVALIDITY reset removes every cached body in the folder", .serialized, .processGlobalState)
struct UidValidityResetBodyPurgeTests {

    private static let folderPath = "INBOX"

    /// Installs a temp `AppDatabase` as `AppDatabase.shared` (what
    /// `AccountManager.shared` reads) holding two IMAP accounts and the folders.
    @MainActor
    private func makeTestDB(accountIds: [String]) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            for accountId in accountIds {
                var account = Account(emailAddress: "user@example.com", displayName: "Test", provider: .imap)
                account.id = accountId
                try account.insert(db)
                for (name, path, role) in [
                    ("Inbox", Self.folderPath, FolderRole.inbox),
                    ("Sub", "\(Self.folderPath):sub", FolderRole.custom),
                    ("Inbox2", "\(Self.folderPath)2", FolderRole.custom),
                ] {
                    var folder = Folder(name: name, path: path, role: role, accountId: accountId)
                    folder.lastKnownUidValidity = 12345
                    try folder.insert(db)
                }
            }
        }
        return (pool, dir, previous)
    }

    private func header(accountId: String, folderPath: String, uid: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "reset fixture", from: "Sender", fromAddress: "sender@example.com",
            to: "recipient@example.com", date: Date(), snippet: "",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: folderPath == Self.folderPath)
        header.headerComplete = true
        return header
    }

    private func bodyIds(_ pool: DatabasePool) async throws -> Set<String> {
        try await pool.read { db in try Set(String.fetchAll(db, sql: "SELECT id FROM messageBody")) }
    }

    @Test("After a reset, a reused UID never shows the HTML cached for the message it named before")
    @MainActor
    func aReusedUIDAdoptsNoCachedHTML() async throws {
        let accountId = "reset-\(UUID().uuidString)"
        // Extends `accountId`: its ids share the reset folder's prefix up to the ':'.
        let otherAccountId = "\(accountId)2"
        let (pool, dir, previous) = try makeTestDB(accountIds: [accountId, otherAccountId])
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }

        let held = header(accountId: accountId, folderPath: Self.folderPath, uid: "5")
        // A body with no header, at the address the new epoch hands to another message.
        let headerless = MessageIdentity.headerId(accountId: accountId, folderPath: Self.folderPath, messageId: "7")
        let controls = [
            MessageIdentity.headerId(accountId: accountId, folderPath: "\(Self.folderPath):sub", messageId: "7"),
            MessageIdentity.headerId(accountId: accountId, folderPath: "\(Self.folderPath)2", messageId: "7"),
            MessageIdentity.headerId(accountId: otherAccountId, folderPath: Self.folderPath, messageId: "7"),
        ]
        try await pool.write { db in
            try held.insert(db)
            for id in [held.id, headerless] + controls {
                try MessageBody.create(contentKey: ContentKey(rawValue: id), htmlBody: "<p>\(id)</p>").insert(db)
            }
        }
        let seeded = try await bodyIds(pool)
        #expect(seeded == Set([held.id, headerless] + controls), "setup: every body is cached")

        let purge = await AccountManager.shared.uidValidityResetPurgeTxn(
            accountId: accountId, folderPath: Self.folderPath,
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: Self.folderPath))
        let committed = purge != nil
        #expect(committed, "setup: the purge transaction committed")

        // The new epoch numbers a different message 7.
        let reused = header(accountId: accountId, folderPath: Self.folderPath, uid: "7")
        #expect(reused.id == headerless)
        try await pool.write { db in try reused.insert(db) }

        let after = try await bodyIds(pool)
        let (reusedHasBody, reusedCached) = try await pool.read { db in
            (try MessageBody.fetchOne(db, key: ContentKey(rawValue: reused.id)) != nil,
             try HTMLCachePair.isCached(db, headerId: reused.id))
        }
        #expect(!reusedHasBody, "the reused UID must not find the old message's HTML")
        #expect(!reusedCached, "the reused UID's header must not read as cached")
        #expect(!after.contains(held.id), "the body of a purged header goes")
        #expect(after == Set(controls),
                "a child folder, a sibling folder and another account keep their bodies: \(after.sorted())")
    }
}
