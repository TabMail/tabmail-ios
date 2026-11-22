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
        #expect(files.count == 3, "precondition: the three change files were read")
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

    /// Scans (the catch-up of every provider, the change readers, their seams and
    /// the engine's catch-up and change files) never read a download gate: no
    /// network type, no battery, no Low Power Mode (#1063). Only the walk does.
    @Test("scans never read the network type, the battery or Low Power Mode (#1063)")
    func scansNeverReadAGate() throws {
        let files = try Self.sources().filter { file in
            let name = (file.relativePath as NSString).lastPathComponent
            return (file.relativePath.hasPrefix("TabMail/Providers/")
                    && (name.hasSuffix("ProviderCatchUp.swift") || name.contains("ProviderChanges")))
                || (file.relativePath.hasPrefix("TabMail/Services/Sync/")
                    && (name == "SyncEngineCatchUp.swift" || name.hasPrefix("SyncEngineChanges")))
        }
        #expect(files.count >= 11, "precondition: the catch-up and change files were read (\(files.count))")
        let forbidden = [
            "checkExpensive", "isExpensiveNetwork", "catchUpExpensiveNetworkMaxWaitSeconds",
            "batteryLevel", "batteryState", "isLowPowerModeEnabled",
        ]
        for file in files {
            for term in forbidden {
                #expect(!file.source.contains(term), "\(file.relativePath) reads \(term)")
            }
        }
    }

    @Test("the engine's older-mail check and the repair of missing messages name no concrete provider and test no account provider (#1061)")
    func missingMessageRepairIsProviderBlind() throws {
        let files = try Self.sources().filter {
            $0.relativePath.hasPrefix("TabMail/Services/Sync/SyncEngineSelfHeal")
                || $0.relativePath == "TabMail/Services/Sync/SyncEngineCatchUp.swift"
        }
        #expect(!files.isEmpty, "precondition: the engine's catch-up file was read")
        for file in files {
            for term in [
                "GmailProvider", "ExchangeProvider", "IMAPProvider", "DemoProvider",
                ".provider ==", ".provider !=", "as? IMAP", "as! IMAP", "provider as?", "provider as!",
                "case .gmail", "case .outlook", "case .imap",
            ] {
                #expect(!file.source.contains(term), "\(file.relativePath) names \(term)")
            }
        }
    }

    @Test("only the IMAP provider, its fork adapter and the notification merge read the IMAP bookmark; the from-server insert guard is provider-blind (#755)")
    func imapBookmarkStaysBelowTheBoundary() throws {
        let files = try Self.sources()
        let allowed = ["TabMail/Providers/IMAPProvider", "TabMail/Providers/IMAPChangeCommands.swift", "TabMail/Services/NSEDataBridge.swift"]
        let readers = files.filter { file in
            file.source.contains("IMAPChangeCursor") && !allowed.contains { file.relativePath.hasPrefix($0) }
        }
        #expect(readers.isEmpty, "IMAPChangeCursor named above the boundary: \(readers.map(\.relativePath))")
        let guardFile = try Self.file(files, "TabMail/Services/Sync/SyncEngineFromServerInsertGuard.swift")
        for term in ["GmailProvider", "ExchangeProvider", "IMAPProvider", "IMAPChange", "provider as?", "case .imap"] {
            #expect(!guardFile.contains(term), "the insert guard names \(term)")
        }
        // The only provider-neutral result fields the CONDSTORE reader added.
        let seam = try Self.file(files, "TabMail/Providers/EmailProviderChanges.swift")
        #expect(seam.contains("var mustList = false"))
        #expect(seam.contains("var heldRowsProof: HeldRowsProof?"))
    }

    @Test("the release boundary's re-read of retired actions names no concrete provider and tests no account provider (#876)")
    func retiredActionRecheckIsProviderBlind() throws {
        let source = try Self.file(try Self.sources(), "TabMail/Services/Sync/SyncEngineRetiredActionRecheck.swift")
        for term in [
            "GmailProvider", "ExchangeProvider", "IMAPProvider", "DemoProvider",
            ".provider ==", ".provider !=", "provider as?", "provider as!", "case .gmail", "case .outlook", "case .imap",
            "SELECT provider", "provider FROM",
        ] {
            #expect(!source.contains(term), "the boundary's re-read names \(term)")
        }
    }

    @Test("the change readers only read: no database in a reader file")
    func readersOnlyRead() throws {
        let files = try Self.sources().filter {
            $0.relativePath.hasSuffix("ProviderChanges.swift") || $0.relativePath.hasSuffix("ProviderChangesCondstore.swift")
        }
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
        #expect(pass.contains("dbPool.write { db in try Self.applyFolderChanges(applying, db: db) }"))
        // And the shields come before any row is written in it.
        let shieldIndex = try #require(apply.range(of: "AccountManager.shared.liveRecentlyCompleted()"))
        let firstWrite = try #require(apply.range(of: "deleteConfirmedGhostHeadersReportingProtected("))
        #expect(shieldIndex.lowerBound < firstWrite.lowerBound)
    }

    @Test("the full sync's window listing skips every tracked folder")
    func noWindowListingForTrackedFolders() throws {
        let fullSync = try Self.file(try Self.sources(), "TabMail/Services/Sync/SyncEngineFullSync.swift")
        #expect(fullSync.contains("FolderChangeState(raw: $0.changeState).tracking && (holdsChangeBookmark || $0.changeCursor != nil)"),
                "a tracked folder is skipped while the account, or the folder itself, holds a bookmark")
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
        // The raw column, not a `Folder`: the record reads columns later
        // migrations add (`isFollowed`, v112), which this schema does not have yet.
        let row = try #require(try db.read { try Row.fetchOne($0, sql: "SELECT changeState FROM folder") })
        let changeState: String? = row["changeState"]
        #expect(changeState == nil)
        #expect(FolderChangeState(raw: changeState).tracking == false)
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
        // The raw column, not a `Folder`: the record reads columns later
        // migrations add (`isFollowed`, v112), which this schema does not have yet.
        let row = try #require(try db.read { try Row.fetchOne($0, sql: "SELECT changeCursor FROM folder") })
        let changeCursor: String? = row["changeCursor"]
        #expect(changeCursor == nil)
        #expect(OutlookFolderCursor(raw: changeCursor) == nil)
    }
}
