/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1376: every way a header leaves `messageHeader`, or changes its id in place,
/// writes its content key into `bodyAssetPendingDelete` in the same transaction,
/// because SQLite writes it (v114's triggers), not the app.
@Suite("Body-asset pending deletes: the v114 triggers")
struct BodyAssetPendingDeleteTriggerTests {

    static let triggerNames: Set<String> = [
        "messageHeader_queueAssetDelete",
        "messageHeader_queueAssetRekey",
    ]

    /// The other triggers on `messageHeader` at the end of the chain: v116's HTML-cache
    /// pair (#1433), which writes only `messageHeader.htmlCachedAt` and never this list.
    static let otherTriggerNames: Set<String> = [
        "messageHeader_htmlCachedAtInsert",
        "messageHeader_htmlCachedAtRekey",
    ]

    static func pending(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT contentKey FROM bodyAssetPendingDelete ORDER BY id") }
    }

    /// Two accounts, an inbox each, two headers in the first and one in the second.
    static func seeded() throws -> (db: DatabaseQueue, first: [MessageHeader], other: MessageHeader) {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com")
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")
        let a = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let b = try TestDatabase.insertMessageHeader(db, messageId: "101")
        let c = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: "acc2:INBOX", accountId: "acc2")
        return (db, [a, b], c)
    }

    @Test("the whole migration chain ends with both triggers, and inserting headers queues nothing")
    func chainEndsWithBothTriggers() throws {
        let (db, _, _) = try Self.seeded()
        let triggers = try db.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'messageHeader'")
        }
        #expect(Set(triggers) == Self.triggerNames.union(Self.otherTriggerNames))
        #expect(try Self.pending(db).isEmpty)
    }

    @Test("deleting a header queues its id")
    func deleteQueuesTheId() throws {
        let (db, first, _) = try Self.seeded()
        _ = try db.write { try MessageHeader.deleteOne($0, key: first[0].id) }
        #expect(try Self.pending(db) == [first[0].id])
    }

    @Test("a delete that rolls back queues nothing")
    func rolledBackDeleteQueuesNothing() throws {
        struct Abort: Error {}
        let (db, first, _) = try Self.seeded()
        #expect(throws: Abort.self) {
            try db.write { db in
                _ = try MessageHeader.deleteOne(db, key: first[0].id)
                throw Abort()
            }
        }
        #expect(try Self.pending(db).isEmpty)
    }

    @Test("removing an account queues every one of its headers through the foreign-key cascade, and no other account's")
    func accountRemovalQueuesEveryHeader() throws {
        let (db, first, other) = try Self.seeded()
        try db.write { try AccountManager.removeAccountRowsTxn($0, accountId: "acc1", wasPrimary: false) }
        let headersLeft = try db.read { try String.fetchAll($0, sql: "SELECT id FROM messageHeader") }
        #expect(headersLeft == [other.id], "precondition: the cascade removed the account's headers")
        let queued = try Self.pending(db)
        #expect(queued.count == first.count)
        #expect(Set(queued) == Set(first.map(\.id)))
    }

    @Test("a move's re-key queues the old id, and the new id stays off the list")
    func moveRekeyQueuesTheOldId() throws {
        let (db, first, _) = try Self.seeded()
        var migrated = first[0]
        migrated.messageId = "900"
        migrated.id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "900")
        #expect(migrated.id != first[0].id, "precondition: the re-key changes the id")
        let inserted = try db.write { try MessageHeaderRekey.apply(from: first[0], to: migrated, db: $0) }
        #expect(inserted)
        #expect(try Self.pending(db) == [first[0].id])
    }

    @Test("an in-place id change queues the old id; an update of any other column queues nothing")
    func idUpdateQueuesTheOldId() throws {
        let (db, first, _) = try Self.seeded()
        try db.write { try $0.execute(sql: "UPDATE messageHeader SET isRead = 1, snippet = 'changed'") }
        #expect(try Self.pending(db).isEmpty)
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET id = id WHERE id = ?", arguments: [first[0].id])
        }
        #expect(try Self.pending(db).isEmpty, "an id written with its own value is not a change")
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET id = ? WHERE id = ?", arguments: ["acc1:INBOX:renamed", first[1].id])
        }
        #expect(try Self.pending(db) == [first[1].id])
    }

    @Test("a statement that deletes many headers queues each one once")
    func bulkDeleteQueuesEach() throws {
        let (db, first, other) = try Self.seeded()
        try db.write { try $0.execute(sql: "DELETE FROM messageHeader") }
        let queued = try Self.pending(db)
        #expect(queued.count == 3)
        #expect(Set(queued) == Set(first.map(\.id) + [other.id]))
    }
}

/// #1376: with `recursive_triggers` off (the SQLite default, and no connection
/// changes it), a row that a REPLACE conflict removes fires no DELETE trigger, so
/// its assets would never be queued. Nothing writes `messageHeader` with REPLACE
/// today; these fences keep it that way.
@Suite("Body-asset pending deletes: nothing writes messageHeader with REPLACE")
struct MessageHeaderReplaceFenceTests {

    /// A REPLACE write whose target is `messageHeader`, in SQL text.
    static let replaceWritePattern = try! NSRegularExpression(
        pattern: #"(INSERT\s+OR\s+REPLACE\s+INTO|REPLACE\s+INTO|UPDATE\s+OR\s+REPLACE)\s+["`\[]?messageHeader\b"#,
        options: [.caseInsensitive])

    static func matchesReplaceWrite(_ text: String) -> Bool {
        replaceWritePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every Swift file of the app, the code it shares with the notification
    /// extension, and the extension.
    static func sources() throws -> [DiagnosticPrintGateTests.SourceFile] {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        var files: [DiagnosticPrintGateTests.SourceFile] = []
        for top in ["TabMail", "Shared", "TabMailNotificationService"] {
            let dir = root.appendingPathComponent(top)
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                files.append(.init(relativePath: relative, source: try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    @Test("the pattern finds each REPLACE form, and only for messageHeader")
    func patternIsNotVacuous() {
        #expect(Self.matchesReplaceWrite("INSERT OR REPLACE INTO messageHeader (id) VALUES (?)"))
        #expect(Self.matchesReplaceWrite("replace into \"messageHeader\" (id) values (?)"))
        #expect(Self.matchesReplaceWrite("UPDATE OR REPLACE messageHeader SET id = ?"))
        #expect(!Self.matchesReplaceWrite("INSERT OR REPLACE INTO chatIdMapping (numericId, realId) VALUES (?, ?)"))
        #expect(!Self.matchesReplaceWrite("INSERT OR IGNORE INTO messageHeader (id) VALUES (?)"))
        #expect(!Self.matchesReplaceWrite("INSERT OR REPLACE INTO messageHeaderArchive (id) VALUES (?)"))
    }

    @Test("no source writes messageHeader with a REPLACE statement")
    func noReplaceStatement() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "precondition: the scan read the app (\(files.count) files)")
        #expect(files.contains { $0.relativePath.hasPrefix("TabMailNotificationService/") },
                "precondition: the scan read the notification extension")
        for file in files {
            #expect(!Self.matchesReplaceWrite(file.source), "\(file.relativePath) writes messageHeader with REPLACE")
        }
    }

    /// `onConflict: .replace` names no table, so the fence takes every use and
    /// lists the record each one writes. There is none today; a new one is added
    /// here with its record, which must not be `MessageHeader`.
    @Test("every onConflict: .replace in the sources is listed with its record, and none writes MessageHeader")
    func noReplaceConflictArgument() throws {
        let allowed: [String: String] = [:]   // relative path -> record type
        #expect(!allowed.values.contains("MessageHeader"))
        let uses = try Self.sources().filter { $0.source.contains("onConflict: .replace") }.map(\.relativePath)
        for path in uses {
            #expect(allowed[path] != nil, "\(path) uses onConflict: .replace; list it here with the record it writes")
        }
    }

    @Test("MessageHeader's persistence policy replaces on neither insert nor update")
    func persistencePolicyIsNotReplace() {
        let policy = MessageHeader.persistenceConflictPolicy
        #expect(policy.conflictResolutionForInsert != .replace)
        #expect(policy.conflictResolutionForUpdate != .replace)
    }

    @Test("messageHeader's own schema declares no ON CONFLICT REPLACE")
    func schemaHasNoReplaceClause() throws {
        let db = try TestDatabase.make()
        let sql = try #require(try db.read {
            try String.fetchOne($0, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'messageHeader'")
        })
        #expect(sql.localizedCaseInsensitiveContains("CREATE TABLE"), "precondition: read the table's definition")
        #expect(!sql.localizedCaseInsensitiveContains("REPLACE"))
    }
}
