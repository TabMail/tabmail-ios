/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Guards the invariant the demo-seed / screenshot-seed ordering relies on: the
/// one-time destructive cached-mail resets run once (gated by `UserDefaults`
/// flags) and, once done, re-running them must NOT delete freshly inserted data.
/// In production these run synchronously in `AppDatabase.init` BEFORE any seed,
/// so the seed can never be wiped.
///
/// `.serialized` because the resets read/write process-global
/// `UserDefaults.standard` flags; each test snapshots + restores them. The FTS
/// reset is injected (`resetFTS:`) so tests never touch the real FTS directory.
///
/// `.processGlobalState` as well, for the same reason the three logger suites
/// carry it: `.serialized` orders tests only WITHIN one suite, and these five
/// `UserDefaults` flags — `didDeleteLegacyLogFiles_v1` included — are
/// process-global. Without the shared critical section a parallel suite can run
/// between this suite's snapshot and restore and observe (or be observed by) a
/// half-set flag.
@Suite("StartupMigrations — one-shot gating", .serialized, .processGlobalState)
struct StartupMigrationsTests {

    static let flagKeys = [
        "didMigrateHeaderIds_v2",
        "didClearBodiesForAttachmentEncoding_v1",
        "didResetImapDatesForInternalDate_v1",
        "didCleanResetMessageData_v1",
    ]

    /// Every one-shot flag `run` touches, including the legacy-log cleanup's —
    /// which is deliberately NOT in `StartupMigrations.resetFlagKeys` (it must
    /// not arm the "Updating…" splash) but IS process-global state these tests
    /// must snapshot and restore like the rest.
    static let allFlagKeys = flagKeys + [StartupMigrations.legacyLogCleanupFlagKey]

    static func snapshotFlags() -> [String: Any] {
        var snap: [String: Any] = [:]
        for key in allFlagKeys where UserDefaults.standard.object(forKey: key) != nil {
            snap[key] = UserDefaults.standard.object(forKey: key)
        }
        return snap
    }

    static func restoreFlags(_ snap: [String: Any]) {
        for key in allFlagKeys {
            if let value = snap[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// A throwaway directory standing in for Application Support / TabMail.
    /// Never the real one: `run` unlinks files there, and the test host's
    /// Application Support is not this suite's to modify.
    static func makeTempLogDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("startupmig_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// In-memory DB with just the `messageHeader` table — enough for the
    /// `didMigrateHeaderIds_v2` delete. Other branches are skipped via flags.
    static func makeHeaderDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()  // in-memory
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE messageHeader (id TEXT)")
        }
        return queue
    }

    /// In-memory DB with every table the clean-reset migration touches.
    static func makeCleanResetDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE messageHeader (id TEXT)")
            try db.execute(sql: "CREATE TABLE messageBody (id TEXT)")
            try db.execute(sql: """
                CREATE TABLE folder (
                    id TEXT, backfillComplete INTEGER, oldestSyncedDate DOUBLE,
                    lastKnownUidNext INTEGER, backfillUidCursor INTEGER, backfillPageToken TEXT
                )
                """)
            try db.execute(sql: "CREATE TABLE account (id TEXT, lastFullSyncAt DOUBLE)")
        }
        return queue
    }

    static func count(_ queue: DatabaseQueue, _ table: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    @Test("All flags set: run() preserves existing data (seed safety)")
    func reRunPreservesData() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let logDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let queue = try Self.makeHeaderDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('seed-1')")
        }

        var ftsResets = 0
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 }, legacyLogDirectory: logDir)

        // Seed survives + FTS untouched: this is what makes "seed after the
        // DB-open migrations" safe.
        #expect(try await Self.count(queue, "messageHeader") == 1)
        #expect(ftsResets == 0)
    }

    @Test("First run deletes stale headers, sets flag, and is one-shot")
    func firstRunDeletesThenNoOps() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let logDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }

        // Only the messageHeader migration is pending.
        UserDefaults.standard.set(false, forKey: "didMigrateHeaderIds_v2")
        UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
        UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
        UserDefaults.standard.set(true, forKey: "didCleanResetMessageData_v1")

        let queue = try Self.makeHeaderDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('stale-1')")
        }

        StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)
        #expect(try await Self.count(queue, "messageHeader") == 0)
        #expect(UserDefaults.standard.bool(forKey: "didMigrateHeaderIds_v2") == true)

        // Data written after the migration ran survives a second run (no-op).
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('fresh-1')")
        }
        StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)
        #expect(try await Self.count(queue, "messageHeader") == 1)
    }

    @Test("Clean reset deletes headers + bodies, resets FTS once, then no-ops")
    func cleanResetWipesAndResetsFTSOnce() async throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let logDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }

        // Only the clean-reset migration is pending.
        UserDefaults.standard.set(true, forKey: "didMigrateHeaderIds_v2")
        UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
        UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
        UserDefaults.standard.set(false, forKey: "didCleanResetMessageData_v1")

        let queue = try Self.makeCleanResetDB()
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('h1')")
            try db.execute(sql: "INSERT INTO messageBody (id) VALUES ('b1')")
        }

        var ftsResets = 0
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 }, legacyLogDirectory: logDir)

        #expect(try await Self.count(queue, "messageHeader") == 0)
        #expect(try await Self.count(queue, "messageBody") == 0)
        #expect(ftsResets == 1)  // FTS reset fired in lockstep with the deletes
        #expect(UserDefaults.standard.bool(forKey: "didCleanResetMessageData_v1") == true)

        // Re-run after completion: data preserved AND FTS not reset again.
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO messageHeader (id) VALUES ('fresh')")
        }
        StartupMigrations.run(queue, resetFTS: { ftsResets += 1 }, legacyLogDirectory: logDir)
        #expect(try await Self.count(queue, "messageHeader") == 1)
        #expect(ftsResets == 1)
    }

    // MARK: - Migration-detection (drives the "Updating…" splash gate)

    /// `resetFlagKeys` is the single source of truth that `allResetsComplete`
    /// reads; if it drifts from the keys `run(_:)` actually gates on, the splash
    /// gate mis-fires — a newly-shipped destructive reset would run at launch with
    /// no "Updating…" splash in front of it, or a stale key would keep the splash
    /// armed forever.
    ///
    /// ⚠️ Comparing the constant to a hand-maintained list in this file proved
    /// only that TWO LISTS AGREE, which is not what the name claims. Adding a
    /// `UserDefaults.standard.bool(forKey: "didNewReset")` branch to `run` touches
    /// neither list, so the test stayed green while the migration splash omitted
    /// real work. The oracle is now DERIVED FROM THE SOURCE, in the style of
    /// `AppLogStoreTests.gatedWritersGateTheirPrintToo` and of
    /// `everyChannelIsClassifiedExactlyOnce`: every key `run`'s body actually
    /// gates on must be accounted for by exactly one of the two production lists.
    @Test("StartupMigrations.resetFlagKeys matches the keys run() gates on")
    func resetFlagKeysMatchCanonicalList() throws {
        // The independently-maintained list still has to agree, ORDER included:
        // `resetFlagKeys`' own comment calls it "in run order".
        #expect(StartupMigrations.resetFlagKeys == Self.flagKeys)

        let source = try AppLogStoreTests.projectFile("TabMail/Services/StartupMigrations.swift")
        guard let body = Self.runFunctionBody(in: source) else {
            Issue.record("could not find the body of StartupMigrations.run")
            return
        }
        // Non-vacuity: the recovered range really is `run`'s body, and not — say —
        // the `resetFTS:` default-value closure that sits inside its signature.
        #expect(body.contains("didCleanResetMessageData_v1"),
                "the scanned range is not run()'s body")

        let scan = Self.gatedFlagKeys(in: body)
        // Every key `run` gates on is accounted for by exactly one list: the slow
        // cached-mail resets that arm the splash, plus the one-shot legacy-log
        // cleanup that deliberately does NOT. A key in neither is a reset nobody
        // classified; a key in a list but never gated on is a stale entry keeping
        // the splash armed.
        let accounted = Set(StartupMigrations.resetFlagKeys)
            .union([StartupMigrations.legacyLogCleanupFlagKey])
        let found = Set(scan.keys)
        let unclassified = found.subtracting(accounted).sorted()
        let neverGated = accounted.subtracting(found).sorted()
        #expect(found == accounted,
                "gated but unclassified: \(unclassified); never gated on: \(neverGated)")
        // An argument the scan cannot read must never be erased into a clean pass:
        // that is how a new, unclassified reset would slip through as "nothing
        // found". Same shape as `deleteLegacyLogFiles` counting an unresolvable
        // error as a FAILURE rather than a skip.
        #expect(scan.unresolved.isEmpty,
                "a `bool(forKey:)` argument this scan cannot resolve: \(scan.unresolved)")
    }

    /// The body of `StartupMigrations.run` — the text between the brace that
    /// opens it and the matching close — or `nil` if it cannot be recovered.
    ///
    /// `AppLogStoreTests.functionBody(of:in:)` is NOT reusable here, and the
    /// reason is worth stating rather than rediscovering: it takes the first `{`
    /// after the signature, and `run`'s signature contains one —
    /// `resetFTS: () -> Void = { deleteFTSDirectory() }` — so it would hand back
    /// that default-value closure. This walks the PARAMETER LIST to its closing
    /// paren first (parenthesis depth, which the closure's own `()` does not
    /// disturb) and only then takes the next brace. Its scalar-offset primitive is
    /// reused, so both scanners agree on what "where does this token appear" means.
    static func runFunctionBody(in source: String) -> String? {
        let signatureToken = "static func run("
        guard let signature = AppLogStoreTests.firstIndex(ofToken: signatureToken, in: source) else {
            return nil
        }
        let scalars = Array(source.unicodeScalars)
        var index = signature + signatureToken.unicodeScalars.count - 1   // at the `(`
        var parens = 0
        while index < scalars.count {
            if scalars[index] == "(" {
                parens += 1
            } else if scalars[index] == ")" {
                parens -= 1
                if parens == 0 {
                    index += 1
                    break
                }
            }
            index += 1
        }
        while index < scalars.count, scalars[index] != "{" { index += 1 }
        guard index < scalars.count else { return nil }
        var depth = 0
        var body = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "{" {
                depth += 1
                if depth == 1 {
                    index += 1
                    continue
                }
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 { return String(body) }
            }
            body.append(scalar)
            index += 1
        }
        return nil
    }

    /// Every `UserDefaults.standard.bool(forKey: …)` argument in `body`, resolved
    /// to the flag key it names, plus the ones that could not be resolved.
    ///
    /// Two spellings occur in `run` and both must resolve or the scan
    /// under-reports: a string LITERAL (the four cached-mail resets) and the bare
    /// identifier `legacyLogCleanupFlagKey`. Anything else is REPORTED, never
    /// silently skipped.
    static func gatedFlagKeys(in body: String) -> (keys: [String], unresolved: [String]) {
        let token = "UserDefaults.standard.bool(forKey: "
        let tokenLength = token.unicodeScalars.count
        var keys: [String] = []
        var unresolved: [String] = []
        var remaining = body
        while let offset = AppLogStoreTests.firstIndex(ofToken: token, in: remaining) {
            let scalars = Array(remaining.unicodeScalars)
            var cursor = offset + tokenLength
            var argument = String.UnicodeScalarView()
            while cursor < scalars.count, scalars[cursor] != ")" {
                argument.append(scalars[cursor])
                cursor += 1
            }
            let text = String(argument).trimmingCharacters(in: .whitespaces)
            if text.unicodeScalars.count >= 2,
               text.unicodeScalars.first == "\"", text.unicodeScalars.last == "\"" {
                keys.append(String(text.dropFirst().dropLast()))
            } else if text == "legacyLogCleanupFlagKey" {
                keys.append(StartupMigrations.legacyLogCleanupFlagKey)
            } else {
                unresolved.append(text)
            }
            remaining = String(String.UnicodeScalarView(scalars[min(cursor, scalars.count)...]))
        }
        return (keys, unresolved)
    }

    @Test("allResetsComplete is true only when every reset flag is set")
    func allResetsCompleteReflectsFlags() {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        #expect(StartupMigrations.allResetsComplete == true)

        // Any single unset flag flips it back to "pending".
        UserDefaults.standard.set(false, forKey: Self.flagKeys[2])
        #expect(StartupMigrations.allResetsComplete == false)
    }

    @Test("hasPendingMigrationWork: unmigrated schema is pending even with all reset flags set")
    func pendingWhenSchemaIncomplete() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        // Rule out the reset path so a true result can only be the schema check.
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let fresh = try DatabaseQueue()  // in-memory, NO migrations applied
        #expect(try AppDatabase.hasPendingMigrationWork(fresh) == true)
    }

    @Test("hasPendingMigrationWork: fully migrated + all resets done is NOT pending (common launch)")
    func notPendingWhenFullyMigratedAndResetsDone() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }

        let migrated = try TestDatabase.make()  // runs the full migration chain
        #expect(try AppDatabase.hasPendingMigrationWork(migrated) == false)
    }

    @Test("hasPendingMigrationWork: fully migrated but a reset still pending IS pending")
    func pendingWhenResetOutstanding() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        // One destructive reset hasn't run yet (e.g. a newly-shipped reset on an
        // existing install) — that's slow on a populated mailbox, so it counts.
        UserDefaults.standard.set(false, forKey: "didCleanResetMessageData_v1")

        let migrated = try TestDatabase.make()
        #expect(try AppDatabase.hasPendingMigrationWork(migrated) == true)
    }

    // MARK: - Legacy per-subsystem log files (GitHub #83)

    /// The names `AppLogStore`'s header records as the files it replaced,
    /// maintained here independently of the production list so a name dropped
    /// from one side is visible.
    static let legacyLogNames = [
        "background_sync.log", "error.log", "chat_error.log", "bg_app_refresh.log",
        "bg_processing.log", "ai_processing.log", "push.log", "backfill_ai.log",
        "backfill.log", "inbox.log", "boot.log", "body_render.log",
        "stuck_messages.log", "device_sync.log", "auth_diagnostics.log",
    ]

    @Test("The legacy log list is exactly the fifteen files consolidation orphaned")
    func legacyLogNamesMatchTheCanonicalList() {
        #expect(Set(StartupMigrations.legacyLogFileNames) == Set(Self.legacyLogNames))
        #expect(StartupMigrations.legacyLogFileNames.count == 15)
        // The live log and the NSE's own file are NOT legacy and must never be
        // unlinked by this cleanup.
        #expect(!StartupMigrations.legacyLogFileNames.contains("tabmail.log"))
        #expect(!StartupMigrations.legacyLogFileNames.contains("nse.log"))
    }

    @Test("deleteLegacyLogFiles unlinks every orphan and nothing else")
    func deleteLegacyLogFilesRemovesOnlyTheOrphans() throws {
        let dir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in Self.legacyLogNames {
            try Data("stale".utf8).write(to: dir.appendingPathComponent(name))
        }
        // The live app log, and unrelated neighbours, must survive: stranded log
        // bytes are what this deletes, not whatever happens to be adjacent.
        try Data("live".utf8).write(to: dir.appendingPathComponent("tabmail.log"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("tabmail.sqlite"))
        // `unrelated.log` carries the SAME EXTENSION as the fifteen and is not one
        // of them. Without it this test passes an implementation that deletes
        // every `*.log` except `tabmail.log` — which is exactly the widened
        // pattern the production code refuses, so the test has to be able to see
        // the difference between "the fifteen names" and "anything ending .log".
        try Data("keep".utf8).write(to: dir.appendingPathComponent("unrelated.log"))

        let cleanup = StartupMigrations.deleteLegacyLogFiles(in: dir)
        #expect(cleanup.deleted == Self.legacyLogNames.count)
        #expect(cleanup.failed == 0)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["tabmail.log", "tabmail.sqlite", "unrelated.log"],
                "left behind: \(remaining)")
    }

    @Test("deleteLegacyLogFiles treats a missing file as nothing to do")
    func deleteLegacyLogFilesToleratesMissingFiles() throws {
        let dir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A fresh install has none of them.
        #expect(StartupMigrations.deleteLegacyLogFiles(in: dir) == .init(deleted: 0, failed: 0))

        // A partially-completed previous attempt has some.
        try Data("stale".utf8).write(to: dir.appendingPathComponent("push.log"))
        try Data("stale".utf8).write(to: dir.appendingPathComponent("boot.log"))
        #expect(StartupMigrations.deleteLegacyLogFiles(in: dir) == .init(deleted: 2, failed: 0))

        // And a directory that does not exist at all is not an error either.
        let absent = dir.appendingPathComponent("nope", isDirectory: true)
        #expect(StartupMigrations.deleteLegacyLogFiles(in: absent) == .init(deleted: 0, failed: 0))
    }

    @Test("A legacy file that reappears does NOT re-arm the one-shot flag")
    func reappearingLegacyFileDoesNotReArmTheOneShot() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let logDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }

        // Every cached-mail reset already done; only the log cleanup is pending.
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        UserDefaults.standard.set(false, forKey: StartupMigrations.legacyLogCleanupFlagKey)

        for name in Self.legacyLogNames {
            try Data("stale".utf8).write(to: logDir.appendingPathComponent(name))
        }

        let queue = try Self.makeHeaderDB()
        StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)

        #expect(try FileManager.default.contentsOfDirectory(atPath: logDir.path).isEmpty)
        #expect(UserDefaults.standard.bool(forKey: StartupMigrations.legacyLogCleanupFlagKey) == true)

        // The property pinned here is the GATE, not the filesystem: once the
        // flag is set, `run` does not call the cleanup again, so a file that
        // reappears under a legacy name is not looked at. That is what "one
        // shot, ever" means, and it is what keeps the cleanup off every
        // subsequent launch.
        //
        // ⚠️ Its known consequence, recorded rather than blessed: nothing in
        // this build writes those names, but running a PRE-consolidation build
        // (a downgrade, a TestFlight rollback, a sideloaded older archive)
        // after the cleanup has run recreates one — and it will then never be
        // removed again, because the flag stays set and "Clear All Logs" only
        // knows about `tabmail.log`. Those bytes still count toward
        // `StorageEstimator`'s budget. Accepted: recoverable by deleting and
        // reinstalling the app, and a downgrade is not a supported path. Adding
        // a `_v2` flag is the fix if that ever stops being true.
        try Data("later".utf8).write(to: logDir.appendingPathComponent("push.log"))
        StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: logDir.path) == ["push.log"])
    }

    /// Make the file at `url` refuse `removeItem` for the duration of `body`,
    /// then make it deletable again so the temp directory can be cleaned up.
    ///
    /// `UF_IMMUTABLE` (`FileAttributeKey.immutable`) is used because it is
    /// per-FILE. Making the parent directory read-only would fail EVERY name,
    /// which could not distinguish "aborted at the first failure" from
    /// "isolated that one and carried on" — the exact distinction these tests
    /// exist to make.
    static func withUndeletableFile<T>(at url: URL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        return try body()
    }

    @Test("One unremovable legacy file does not strand the other fourteen")
    func deleteLegacyLogFilesIsolatesOneFailure() throws {
        let dir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in Self.legacyLogNames {
            try Data("stale".utf8).write(to: dir.appendingPathComponent(name))
        }
        // Block the FIRST name in production order, so "aborts at the first
        // failure" and "isolates it and continues" give maximally different
        // answers: 0 removed versus 14.
        let blocked = dir.appendingPathComponent(StartupMigrations.legacyLogFileNames[0])

        let cleanup = Self.withUndeletableFile(at: blocked) {
            StartupMigrations.deleteLegacyLogFiles(in: dir)
        }

        // Non-vacuity: if the immutable flag did not take, the "failure" never
        // happened and every assertion below would pass for the wrong reason.
        try #require(FileManager.default.fileExists(atPath: blocked.path),
                     "the immutable flag did not take — this test proves nothing without it")
        #expect(cleanup.failed == 1)
        #expect(cleanup.deleted == Self.legacyLogNames.count - 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
                    == [blocked.lastPathComponent])
    }

    @Test("A DIRECTORY bearing a legacy name is never recursed into, and a symlink loses only the LINK")
    func deleteLegacyLogFilesNeverRecursesIntoADirectory() throws {
        let dir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // `removeItem(at:)` is documented as recursive, so a directory bearing a
        // legacy name would be deleted WITH ITS CONTENTS, at launch, before any UI
        // exists to report it — and an `isRegularFile` check in front of it does
        // NOT close that: the check and the removal are two syscalls with a window
        // between them. `unlink` is one syscall that refuses a directory outright.
        // Nothing in this tree creates such a directory, which is precisely why
        // the code must fail closed rather than depend on that staying true.
        let asDirectory = dir.appendingPathComponent("push.log", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        let inside = asDirectory.appendingPathComponent("keep-me.txt")
        try Data("precious".utf8).write(to: inside)

        // A VALID symlink at a legacy name, pointing at a file that must survive.
        // `unlink` removes the directory ENTRY and never what it points at, so the
        // stranded name goes and the cleanup never reaches THROUGH a name it was
        // handed. This replaces an earlier DANGLING-symlink case that
        // discriminated nothing: `fileExists(atPath:)` follows symlinks and is
        // already false for a dangling one, so it passed under every predicate
        // this function has ever had.
        let target = dir.appendingPathComponent("target-must-survive.txt")
        try Data("keep".utf8).write(to: target)
        let link = dir.appendingPathComponent("inbox.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // A genuine orphan alongside them, so the pass is not trivially empty.
        try Data("stale".utf8).write(to: dir.appendingPathComponent("boot.log"))

        let cleanup = StartupMigrations.deleteLegacyLogFiles(in: dir)

        // Two entries removed: `boot.log` (a regular file) and `inbox.log` (the
        // symlink's own entry — the LINK, not its target).
        #expect(cleanup.deleted == 2)
        // A skip is a permanent, deliberate refusal, not a failure: counting it
        // as one would leave the flag unset and re-scan all fifteen names on
        // every launch forever, with no progress to show for it.
        #expect(cleanup.failed == 0)

        // The property that cannot be undone if it is ever wrong.
        #expect(FileManager.default.fileExists(atPath: asDirectory.path),
                "the directory at a legacy name was removed")
        #expect(FileManager.default.fileExists(atPath: inside.path),
                "the directory's contents were deleted")
        // The link is gone; the file it named is not.
        #expect(FileManager.default.fileExists(atPath: target.path),
                "the unlink reached through the symlink and destroyed its target")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                    == ["push.log", "target-must-survive.txt"])
    }

    /// Make every entry in `directory` refuse `unlink` (Darwin returns `EPERM`)
    /// for the duration of `body`, then make the directory mutable again so the
    /// temp tree can be cleaned up.
    ///
    /// `UF_IMMUTABLE` on the PARENT rather than on the entry, because the entry
    /// under test is a symlink and `FileManager.setAttributes` follows those —
    /// it would flag the link's target instead of the link. A name that is not
    /// present still fails lookup first and returns `ENOENT`, so the fourteen
    /// absent names stay on the "nothing to do" path.
    static func withUndeletableEntries<T>(in directory: URL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path) }
        return try body()
    }

    @Test("A symlink to a DIRECTORY whose unlink fails is a failure, not a clean skip")
    func symlinkToDirectoryThatCannotBeUnlinkedIsAFailure() throws {
        // The skip branch exists for ONE thing: a real directory sitting at a
        // legacy name, which no future launch could make removable, so counting
        // it would re-scan all fifteen names every launch forever with nothing to
        // show for it. Everything else — including an unlink that failed for a
        // reason this pass could not resolve — must count as a FAILURE, because
        // a failure is what keeps the one-shot flag unset and the name retried.
        //
        // The INVARIANT: the classification must describe the ENTRY this pass
        // tried to unlink, never whatever that entry points at. A predicate that
        // resolves the link answers a question about the TARGET, so a symlink is
        // recorded as a clean skip, `failed` stays 0, the one-shot flag arms —
        // and that name's bytes are stranded in Application Support forever,
        // counting against `StorageEstimator`'s budget with no UI able to reach
        // them.
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let dir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The target lives OUTSIDE the scanned directory, so the link is the only
        // entry in it and nothing else can account for the failure count.
        let targetDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: targetDir) }
        let link = dir.appendingPathComponent(StartupMigrations.legacyLogFileNames[0])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetDir)

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        UserDefaults.standard.set(false, forKey: StartupMigrations.legacyLogCleanupFlagKey)
        let queue = try Self.makeHeaderDB()

        let cleanup = Self.withUndeletableEntries(in: dir) {
            StartupMigrations.deleteLegacyLogFiles(in: dir)
        }

        // Non-vacuity: the unlink genuinely failed, so there IS an ambiguity to
        // resolve. `destinationOfSymbolicLink` and not `fileExists`, which
        // follows the link and would be answering about the target again.
        try #require((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
                     "the link was removed — this test proves nothing without a failed unlink")
        #expect(cleanup.deleted == 0)
        #expect(cleanup.failed == 1,
                "a symlink whose unlink failed was recorded as a clean skip")

        // And the consequence that makes it permanent: the one-shot flag must
        // stay unset so the next launch retries this name.
        Self.withUndeletableEntries(in: dir) {
            StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: dir)
        }
        #expect(UserDefaults.standard.bool(forKey: StartupMigrations.legacyLogCleanupFlagKey) == false,
                "the one-shot flag armed — this name is now stranded forever")
    }

    @Test("The one-shot flag arms only after a pass with zero failures")
    func legacyLogCleanupFlagArmsOnlyOnACleanPass() throws {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }
        let logDir = try Self.makeTempLogDirectory()
        defer { try? FileManager.default.removeItem(at: logDir) }

        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        UserDefaults.standard.set(false, forKey: StartupMigrations.legacyLogCleanupFlagKey)

        for name in Self.legacyLogNames {
            try Data("stale".utf8).write(to: logDir.appendingPathComponent(name))
        }
        let blocked = logDir.appendingPathComponent(StartupMigrations.legacyLogFileNames[0])
        let queue = try Self.makeHeaderDB()

        // Launch 1: one name cannot be removed. The other fourteen still are,
        // and the flag stays UNSET so the next launch retries the remainder.
        Self.withUndeletableFile(at: blocked) {
            StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)
        }
        try #require(FileManager.default.fileExists(atPath: blocked.path),
                     "the immutable flag did not take — this test proves nothing without it")
        #expect(try FileManager.default.contentsOfDirectory(atPath: logDir.path)
                    == [blocked.lastPathComponent])
        #expect(UserDefaults.standard.bool(forKey: StartupMigrations.legacyLogCleanupFlagKey) == false)

        // Launch 2: the obstruction is gone, the last name goes, and only NOW
        // does the flag arm. This exercises a TRANSIENT obstruction only —
        // `withUndeletableFile` clears the immutable flag before this launch. A
        // PERMANENTLY undeletable file is a different branch: the flag never arms
        // and the fifteen-name scan repeats every launch, which is the accepted
        // bounded cost documented at the call site, not a progress guarantee.
        StartupMigrations.run(queue, resetFTS: {}, legacyLogDirectory: logDir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: logDir.path).isEmpty)
        #expect(UserDefaults.standard.bool(forKey: StartupMigrations.legacyLogCleanupFlagKey) == true)
    }

    @Test("The legacy log cleanup does NOT arm the migration splash")
    func legacyLogCleanupIsNotASplashGate() {
        let saved = Self.snapshotFlags()
        defer { Self.restoreFlags(saved) }

        // Deleting fifteen small files is not slow work, so a pending cleanup
        // must not make launch show "Updating…". Only the cached-mail resets do.
        for key in Self.flagKeys { UserDefaults.standard.set(true, forKey: key) }
        UserDefaults.standard.set(false, forKey: StartupMigrations.legacyLogCleanupFlagKey)
        #expect(StartupMigrations.allResetsComplete == true)
        #expect(!StartupMigrations.resetFlagKeys.contains(StartupMigrations.legacyLogCleanupFlagKey))
    }
}
