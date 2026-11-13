/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Source fences for the change seam (ADR-IOS-111). They read the app target's
/// source at run time.
@Suite("Change seam: source fences")
struct ChangeSeamFenceTests {

    static func sources() throws -> [DiagnosticPrintGateTests.SourceFile] {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        #expect(files.count > 100, "precondition: the scan read the app target")
        return files
    }

    static func file(_ files: [DiagnosticPrintGateTests.SourceFile], _ relativePath: String) throws -> String {
        try #require(files.first { $0.relativePath == relativePath }, "missing \(relativePath)").source
    }

    @Test("the engine's change files name no concrete provider and test no account provider")
    func engineIsProviderBlind() throws {
        let files = try Self.sources().filter {
            $0.relativePath.hasPrefix("TabMail/Services/Sync/SyncEngineChanges")
        }
        #expect(files.count == 2, "precondition: both change files were read")
        let forbidden = [
            "GmailProvider", "ExchangeProvider", "IMAPProvider", "DemoProvider",
            ".provider ==", ".provider !=", "provider as?", "provider as!", "case .gmail", "case .outlook", "case .imap",
        ]
        for file in files {
            for term in forbidden {
                #expect(!file.source.contains(term), "\(file.relativePath) names \(term)")
            }
        }
    }

    @Test("the change readers only read: no database in a reader file")
    func readersOnlyRead() throws {
        let files = try Self.sources().filter { $0.relativePath.hasSuffix("ProviderChanges.swift") }
        #expect(files.count >= 3, "precondition: the seam and the Gmail and Outlook readers were read")
        for file in files {
            for term in ["dbPool", "Database", "import GRDB", ".write {", ".read {"] {
                #expect(!file.source.contains(term), "\(file.relativePath) names \(term)")
            }
        }
    }

    @Test("the shields are read only in the per-folder apply, which runs only inside a write transaction")
    func shieldsReadInsideTheTransaction() throws {
        let files = try Self.sources()
        let pass = try Self.file(files, "TabMail/Services/Sync/SyncEngineChanges.swift")
        let apply = try Self.file(files, "TabMail/Services/Sync/SyncEngineChangesApply.swift")
        for term in ["liveRecentlyCompleted", "PendingOperationSnapshot.load"] {
            #expect(!pass.contains(term), "the pass reads \(term) outside a folder transaction")
            #expect(apply.components(separatedBy: term).count - 1 == 1, "\(term) is read once, in applyFolderChanges")
        }
        // The apply function takes the transaction's `db` and is called only from a write closure.
        #expect(apply.contains("static func applyFolderChanges(_ changes: FolderChanges, db: Database)"))
        let calls = pass.components(separatedBy: "applyFolderChanges(").count - 1
        #expect(calls == 1)
        #expect(pass.contains("dbPool.write { db in try Self.applyFolderChanges(changes, db: db) }"))
        // And the shields come before any row is written in it.
        let shieldIndex = try #require(apply.range(of: "AccountManager.shared.liveRecentlyCompleted()"))
        let firstWrite = try #require(apply.range(of: "deleteConfirmedGhostHeadersReportingProtected("))
        #expect(shieldIndex.lowerBound < firstWrite.lowerBound)
    }

    @Test("the full sync's window listing skips every tracked folder")
    func noWindowListingForTrackedFolders() throws {
        let fullSync = try Self.file(try Self.sources(), "TabMail/Services/Sync/SyncEngineFullSync.swift")
        #expect(fullSync.contains("? Set(syncableFolders.filter { FolderChangeState(raw: $0.changeState).tracking }.map(\\.id))"),
                "a tracked folder is skipped while the account holds a bookmark")
        #expect(fullSync.contains("&& !trackedFolderIds.contains(folder.id) {"),
                "the per-folder listing loop's predicate excludes tracked folders")
    }
}

/// `v102_addFolderChangeState` adds the engine's per-folder change state.
@Suite("Migration v102 — folder.changeState")
struct FolderChangeStateMigrationTests {
    @Test("v102 adds a nullable changeState and leaves every existing folder untracked")
    func addsNullableColumn() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v101_backfillVersionCoversUidCursorAndNeverRepeats")
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertFolder(db)
        try migrator.migrate(db, upTo: "v102_addFolderChangeState")
        let columns = try db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(folder)") }
        let column = try #require(columns.first { ($0["name"] as String) == "changeState" })
        #expect((column["notnull"] as Int) == 0)
        let folder = try #require(try db.read { try Folder.fetchOne($0) })
        #expect(folder.changeState == nil)
        #expect(FolderChangeState(raw: folder.changeState).tracking == false)
    }

    @Test("The state round-trips, and the untracked empty state is stored as NULL")
    func stateRoundTrips() {
        let state = FolderChangeState(tracking: true, recheck: ["m1", "m2"])
        #expect(FolderChangeState(raw: state.encoded) == state)
        #expect(FolderChangeState().encoded == nil)
        #expect(FolderChangeState(raw: "not json") == FolderChangeState())
    }
}

/// `v103_addFolderChangeCursor` adds a folder's own change bookmark, for a
/// provider that reads changes folder by folder.
@Suite("Migration v103 — folder.changeCursor")
struct FolderChangeCursorMigrationTests {
    @Test("v103 adds a nullable changeCursor and leaves every existing folder without a bookmark")
    func addsNullableColumn() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v102_addFolderChangeState")
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com")
        try TestDatabase.insertFolder(db)
        try migrator.migrate(db, upTo: "v103_addFolderChangeCursor")
        let columns = try db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(folder)") }
        let column = try #require(columns.first { ($0["name"] as String) == "changeCursor" })
        #expect((column["notnull"] as Int) == 0)
        let folder = try #require(try db.read { try Folder.fetchOne($0) })
        #expect(folder.changeCursor == nil)
        #expect(OutlookFolderCursor(raw: folder.changeCursor) == nil)
    }
}
