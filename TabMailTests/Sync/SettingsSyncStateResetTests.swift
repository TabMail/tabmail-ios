/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The two Settings resets, "Reset message data" on one account
/// (`SyncEngine.resetMessageDataTxn`) and "Delete All Email Index Data"
/// (`SyncEngine.localIndexWipeTxn`), delete the local mail and must leave every
/// folder they cover with no sync progress at all, so the next sync starts the
/// folder like a new account's. A kept cursor describes rows that no longer exist
/// (#501: the global wipe kept `lastKnownUidNext`; #848: neither reset cleared
/// the older-mail check's `catchUpState`).
///
/// The property test does not compare against a list of columns. It reads the
/// `folder` schema and treats every column as sync state except the identity,
/// display and epoch columns named in `notSyncState`, each with its reason, so a
/// column added later is checked by these tests until someone decides otherwise.
@Suite("Settings resets clear every folder sync-state column")
struct SettingsSyncStateResetTests {

    /// The two user gestures that reset sync state.
    enum Wipe: String, CaseIterable, Sendable {
        /// Reset Message Data on one account (`SyncEngine.resetMessageDataTxn`).
        case accountReset
        /// Delete All Email Index Data in Settings (`SyncEngine.localIndexWipeTxn`).
        case settingsWipe
    }

    static let resetAccountId = "acc-reset"
    static let otherAccountId = "acc-other"

    /// `folder` columns that are NOT sync progress, with the reason. Every other
    /// column of the live schema is sync state, which a reset must clear.
    static let notSyncState: [String: String] = [
        "id": "identity",
        "accountId": "identity",
        "path": "identity (the server's name for the folder)",
        "name": "display",
        "role": "the user's folder-role choice",
        "unreadCount": "display count, refreshed by sync",
        "totalCount": "display count, refreshed by sync",
        "isFavorite": "the user's choice",
        "backfillVersion": "row version the trigger owns; never set by hand",
        "lastKnownUidValidity": "the epoch the local UIDs belong to (ADR-IOS-061); a reset does not change the server's numbering",
        "uidValidityResetPendingAt": "the UIDVALIDITY reaction's quarantine flag; only the reaction clears it",
    ]

    /// Excluded columns a reset must leave exactly as they were. The identity and
    /// display columns are not seeded; `backfillVersion` moves with every reset.
    static let keptOnPurpose = ["lastKnownUidValidity", "uidValidityResetPendingAt"]

    /// Columns the two resets are known to own. Only a non-vacuity check on the
    /// derived set: the property below never compares against this list.
    static let knownSyncState = [
        "backfillComplete", "oldestSyncedDate", "lastKnownUidNext", "backfillUidCursor",
        "backfillPageToken", "backfillPageHeldSince", "changeState", "changeCursor", "catchUpState",
    ]

    struct SchemaColumn: Sendable {
        let name: String
        let type: String
        let defaultSQL: String?
    }

    // MARK: - Fixture

    static func folderColumns(_ db: Database) throws -> [SchemaColumn] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(folder)").map { row in
            SchemaColumn(name: row["name"], type: (row["type"] as String? ?? "").uppercased(), defaultSQL: row["dflt_value"])
        }
    }

    static func syncStateColumns(_ db: Database) throws -> [SchemaColumn] {
        try folderColumns(db).filter { notSyncState[$0.name] == nil }
    }

    /// The value a column holds when nothing has been synced: its schema default.
    static func resetValue(_ column: SchemaColumn, _ db: Database) throws -> DatabaseValue {
        guard let defaultSQL = column.defaultSQL else { return .null }
        return try DatabaseValue.fetchOne(db, sql: "SELECT \(defaultSQL)") ?? .null
    }

    /// A non-default value of the column's type.
    static func seedValue(_ column: SchemaColumn) -> DatabaseValue {
        if column.type.contains("BOOL") { return true.databaseValue }
        if column.type.contains("INT") { return 4242.databaseValue }
        if column.type.contains("DATE") { return Date().databaseValue }
        return "seeded-\(column.name)".databaseValue
    }

    static func value(_ db: Database, folderId: String, column: String) throws -> DatabaseValue {
        try DatabaseValue.fetchOne(db, sql: "SELECT \"\(column)\" FROM folder WHERE id = ?", arguments: [folderId]) ?? .null
    }

    static func accountValue(_ db: Database, accountId: String, column: String) throws -> DatabaseValue {
        try DatabaseValue.fetchOne(db, sql: "SELECT \"\(column)\" FROM account WHERE id = ?", arguments: [accountId]) ?? .null
    }

    /// Two accounts: the reset one has an Inbox, an Archive and an empty-path
    /// folder row; the other has an Inbox. One header in each Inbox.
    static func makeWorld() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        for accountId in [resetAccountId, otherAccountId] {
            try TestDatabase.insertAccount(db, id: accountId, email: "\(accountId)@example.com")
            try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            try TestDatabase.insertMessageHeader(
                db, messageId: "1", folderId: "\(accountId):INBOX", accountId: accountId, folderPath: "INBOX")
        }
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: resetAccountId)
        try TestDatabase.insertFolder(db, name: "", path: "", role: .custom, accountId: resetAccountId)
        return db
    }

    /// Every sync-state column and every kept-on-purpose column of every folder
    /// gets a non-default value; both accounts get a bookmark and a full-sync time.
    static func seedEverything(_ db: DatabaseQueue) throws -> (columns: [SchemaColumn], seeds: [String: DatabaseValue]) {
        try db.write { conn in
            let all = try folderColumns(conn)
            let seeded = all.filter { notSyncState[$0.name] == nil || keptOnPurpose.contains($0.name) }
            var seeds: [String: DatabaseValue] = [:]
            for column in seeded {
                let seed = seedValue(column)
                seeds[column.name] = seed
                try conn.execute(sql: "UPDATE folder SET \"\(column.name)\" = ?", arguments: [seed])
            }
            try conn.execute(sql: "UPDATE account SET lastHistoryId = ?, lastFullSyncAt = ?",
                             arguments: ["seeded-bookmark", Date()])
            return (try syncStateColumns(conn), seeds)
        }
    }

    static func run(_ wipe: Wipe, _ db: DatabaseQueue) throws {
        try db.write { conn in
            switch wipe {
            case .accountReset: try SyncEngine.resetMessageDataTxn(conn, accountId: resetAccountId)
            case .settingsWipe: try SyncEngine.localIndexWipeTxn(conn)
            }
        }
    }

    static func folderIds(_ db: DatabaseQueue, accountId: String) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT id FROM folder WHERE accountId = ? ORDER BY id", arguments: [accountId]) }
    }

    // MARK: - The schema split

    @Test("The derived sync-state set is not empty and every excluded column exists")
    func derivedSetIsNotVacuous() throws {
        let db = try TestDatabase.make()
        try db.read { conn in
            let names = Set(try Self.folderColumns(conn).map(\.name))
            let derived = Set(try Self.syncStateColumns(conn).map(\.name))
            for name in Self.notSyncState.keys {
                #expect(names.contains(name), "excluded column \(name) is not in the folder schema any more")
            }
            for name in Self.knownSyncState {
                #expect(derived.contains(name), "\(name) is not treated as sync state")
            }
            for column in try Self.syncStateColumns(conn) {
                let reset = try Self.resetValue(column, conn)
                #expect(Self.seedValue(column) != reset,
                        "the seed for \(column.name) equals its reset value, so the check could not fail")
            }
        }
    }

    // MARK: - The property

    @Test("A reset leaves no folder it covers with any sync-state value", arguments: Wipe.allCases)
    func resetClearsEverySyncStateColumn(_ wipe: Wipe) throws {
        let db = try Self.makeWorld()
        let (columns, seeds) = try Self.seedEverything(db)
        try Self.run(wipe, db)

        let covered = try Self.folderIds(db, accountId: Self.resetAccountId)
            + (wipe == .settingsWipe ? try Self.folderIds(db, accountId: Self.otherAccountId) : [])
        #expect(covered.count == (wipe == .settingsWipe ? 4 : 3), "precondition: the fixture's folders")
        try db.read { conn in
            for folderId in covered {
                for column in columns {
                    let value = try Self.value(conn, folderId: folderId, column: column.name)
                    let expected = try Self.resetValue(column, conn)
                    #expect(value == expected,
                            "\(wipe.rawValue): folder \(folderId) kept \(column.name) = \(value), want \(expected)")
                }
                for name in Self.keptOnPurpose {
                    let kept = try Self.value(conn, folderId: folderId, column: name)
                    #expect(kept == seeds[name],
                            "\(wipe.rawValue): folder \(folderId) lost \(name), which a reset must keep")
                }
            }
        }
    }

    @Test("A reset clears the bookmark and makes the full sync due on every account it covers", arguments: Wipe.allCases)
    func resetClearsAccountSyncState(_ wipe: Wipe) throws {
        let db = try Self.makeWorld()
        _ = try Self.seedEverything(db)
        try Self.run(wipe, db)

        let covered = wipe == .settingsWipe ? [Self.resetAccountId, Self.otherAccountId] : [Self.resetAccountId]
        try db.read { conn in
            for accountId in covered {
                for column in ["lastHistoryId", "lastFullSyncAt"] {
                    let value = try Self.accountValue(conn, accountId: accountId, column: column)
                    #expect(value.isNull, "\(wipe.rawValue): account \(accountId) kept \(column) = \(value)")
                }
            }
        }
    }

    @Test("Reset Message Data leaves another account's folders and account row untouched")
    func accountResetLeavesOtherAccountAlone() throws {
        let db = try Self.makeWorld()
        let (columns, seeds) = try Self.seedEverything(db)
        try Self.run(.accountReset, db)

        let others = try Self.folderIds(db, accountId: Self.otherAccountId)
        #expect(others == ["\(Self.otherAccountId):INBOX"], "precondition: the other account's folder")
        try db.read { conn in
            for folderId in others {
                for column in columns {
                    let value = try Self.value(conn, folderId: folderId, column: column.name)
                    #expect(value == seeds[column.name],
                            "folder \(folderId) of another account lost \(column.name)")
                }
            }
            let bookmark = try Self.accountValue(conn, accountId: Self.otherAccountId, column: "lastHistoryId")
            let fullSyncAt = try Self.accountValue(conn, accountId: Self.otherAccountId, column: "lastFullSyncAt")
            let otherMail = try MessageHeader.filter(Column("accountId") == Self.otherAccountId).fetchCount(conn)
            let resetMail = try MessageHeader.filter(Column("accountId") == Self.resetAccountId).fetchCount(conn)
            #expect(bookmark == "seeded-bookmark".databaseValue, "another account lost its bookmark")
            #expect(!fullSyncAt.isNull, "another account's full sync was made due")
            #expect(otherMail == 1, "the other account's mail was deleted")
            #expect(resetMail == 0, "the reset account's mail was kept")
        }
    }

    // MARK: - The behaviour before #501, pinned column by column

    /// What each path cleared before the two were joined. Still true after it:
    /// the joined list is a superset of both.
    @Test("Each reset still clears every column it cleared before #501", arguments: Wipe.allCases)
    func resetKeepsClearingItsOriginalColumns(_ wipe: Wipe) throws {
        let db = try Self.makeWorld()
        _ = try Self.seedEverything(db)
        try Self.run(wipe, db)

        let folderColumns: [String: DatabaseValue] = {
            var cleared: [String: DatabaseValue] = [
                "backfillComplete": false.databaseValue,
                "oldestSyncedDate": .null,
                "backfillUidCursor": .null,
                "backfillPageToken": .null,
                "backfillPageHeldSince": .null,
                "changeState": .null,
                "changeCursor": .null,
            ]
            if wipe == .accountReset { cleared["lastKnownUidNext"] = .null }
            return cleared
        }()
        let folders = [
            "\(Self.resetAccountId):INBOX", "\(Self.resetAccountId):Archive",
        ] + (wipe == .settingsWipe ? ["\(Self.otherAccountId):INBOX"] : [])
        let accounts = wipe == .settingsWipe ? [Self.resetAccountId, Self.otherAccountId] : [Self.resetAccountId]
        try db.read { conn in
            for folderId in folders {
                for (column, expected) in folderColumns.sorted(by: { $0.key < $1.key }) {
                    let value = try Self.value(conn, folderId: folderId, column: column)
                    #expect(value == expected, "\(wipe.rawValue): folder \(folderId) kept \(column) = \(value)")
                }
            }
            for accountId in accounts {
                let bookmark = try Self.accountValue(conn, accountId: accountId, column: "lastHistoryId")
                #expect(bookmark.isNull,
                        "\(wipe.rawValue): account \(accountId) kept its bookmark")
            }
            if wipe == .accountReset {
                let fullSyncAt = try Self.accountValue(conn, accountId: Self.resetAccountId, column: "lastFullSyncAt")
                #expect(fullSyncAt.isNull,
                        "Reset Message Data no longer makes the full sync due")
            }
            let mail = try MessageHeader.fetchCount(conn)
            #expect(mail == (wipe == .settingsWipe ? 0 : 1),
                    "\(wipe.rawValue): the reset no longer deletes the mail it covers")
        }
    }
}
