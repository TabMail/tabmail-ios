/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Observation
import Synchronization
@testable import TabMail

/// The upgrade step (`AppDatabase.runUpgradeStep`, ADR-IOS-029 amendment of
/// 2026-11-24): on an upgrade launch, behind the "Updating…" screen, the missing
/// deferred indexes are built and the statistics refreshed in one write, so the
/// background maintenance pass after it has nothing left to do. On any other launch
/// the step runs nothing.
///
/// `.serialized` and `.processGlobalState` because the step goes through
/// `runRefreshPlannerStatisticsIfStale`, which carries a process-wide single-flight
/// latch and gives up while `DatabaseSuspension.isSuspended`.
@Suite("Upgrade step: deferred indexes and statistics behind the Updating screen", .serialized, .processGlobalState)
struct UpgradeStepTests {

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String
    }

    /// Mail rows in each table a deferred index covers, so `ANALYZE` writes a
    /// statistics row for every deferred index (it writes none for an empty table).
    private static let seededMessages = 20

    /// The migrated schema with no deferred index (as an upgrade from a release
    /// before them leaves it), some mail, and a private defaults suite for the
    /// marker. Foreign keys off: nothing here reads the account and folder rows.
    private static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            for index in 0..<seededMessages {
                let header = MessageHeader(
                    messageId: String(index + 1),
                    subject: "Subject \(index)",
                    from: "Sender <sender@example.com>",
                    fromAddress: "sender@example.com",
                    to: "upgrade@example.com",
                    date: Date().addingTimeInterval(-Double(index) * 60),
                    snippet: "Snippet \(index)",
                    folderId: "upgrade-account:INBOX",
                    accountId: "upgrade-account",
                    folderPath: "INBOX",
                    isInInbox: true)
                try header.insert(db)
                try db.execute(
                    sql: "INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText) VALUES (?, ?, NULL, ?, NULL)",
                    arguments: [header.id, "<p>Body \(index)</p>", Date()])
            }
        }
        let suiteName = "UpgradeStepTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Fixture(pool: pool, directory: directory, defaults: defaults, suiteName: suiteName)
    }

    private static func tearDown(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory)
    }

    private static func existingIndexes(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
    }

    private static func statisticsRows(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in
            guard try db.tableExists("sqlite_stat1") else { return [] }
            return Set(try String.fetchAll(db, sql: "SELECT idx FROM sqlite_stat1 WHERE idx IS NOT NULL"))
        }
    }

    private static func schemaVersion(_ pool: DatabasePool) throws -> Int? {
        try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
    }

    @Test("On an upgrade launch the step builds every deferred index with its statistics, and the next maintenance pass skips ANALYZE")
    func upgradeLaunchBuildsAndAnalyzes() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let before = try Self.existingIndexes(fixture.pool)
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: before),
                "the fixture must start without the deferred indexes, or the step proves nothing")

        let outcome = await AppDatabase.runUpgradeStep(
            pool: fixture.pool, isUpgradeLaunch: true, defaults: fixture.defaults)
        #expect(outcome == .refreshed)

        let after = try Self.existingIndexes(fixture.pool)
        let missing = deferred.subtracting(after)
        #expect(missing.isEmpty, "deferred indexes missing after the upgrade step: \(missing.sorted())")
        let withoutStatistics = deferred.subtracting(try Self.statisticsRows(fixture.pool))
        #expect(withoutStatistics.isEmpty,
                "deferred indexes with no sqlite_stat1 row after the upgrade step: \(withoutStatistics.sorted())")
        let marker = fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) as? Int
        let liveVersion = try Self.schemaVersion(fixture.pool)
        #expect(marker != nil && marker == liveVersion,
                "the marker must hold the schema version after the step: marker \(String(describing: marker)), live \(String(describing: liveVersion))")

        // The background maintenance pass that follows the launch.
        let pass = await SyncEngine.runRefreshPlannerStatisticsIfStale(
            dbPool: PrioritizedDatabase(pool: fixture.pool, priority: .background),
            defaults: fixture.defaults)
        #expect(pass == .alreadyFresh, "the maintenance pass after an upgrade launch ran ANALYZE again")
    }

    @Test("On any other launch the step runs nothing")
    func otherLaunchRunsNothing() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let indexesBefore = try Self.existingIndexes(fixture.pool)
        let statisticsBefore = try Self.statisticsRows(fixture.pool)
        let versionBefore = try Self.schemaVersion(fixture.pool)

        let outcome = await AppDatabase.runUpgradeStep(
            pool: fixture.pool, isUpgradeLaunch: false, defaults: fixture.defaults)
        #expect(outcome == nil)

        #expect(try Self.existingIndexes(fixture.pool) == indexesBefore)
        #expect(try Self.statisticsRows(fixture.pool) == statisticsBefore)
        #expect(try Self.schemaVersion(fixture.pool) == versionBefore)
        #expect(fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) == nil)
    }

    /// The migration-built `messageHeader` indexes that cover every row (no
    /// `WHERE`), each of which gets a statistics row from a whole-database
    /// `ANALYZE` over the seeded mail.
    private static func fullMessageHeaderIndexes(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND tbl_name = 'messageHeader'
                  AND sql IS NOT NULL AND sql NOT LIKE '%WHERE%'
                """))
        }
    }

    @Test("The launch build runs the upgrade step before it returns the database: deferred indexes, whole-database statistics and the marker")
    func launchBuildRunsTheStepBeforeReturning() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let existing = try Self.existingIndexes(fixture.pool)
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: existing),
                "the fixture must start without the deferred indexes, or the build proves nothing")
        let migrationBuilt = try Self.fullMessageHeaderIndexes(fixture.pool)
        #expect(!migrationBuilt.isEmpty, "the schema must have a migration-built messageHeader index")
        #expect(try Self.statisticsRows(fixture.pool).isEmpty)

        let db = try await AppDatabase.openForLaunch(
            pool: fixture.pool, isUpgradeLaunch: true, runStartupResets: false, defaults: fixture.defaults)
        #expect(db.dbPool === fixture.pool)

        // Everything below is already true when the build returns, before any caller
        // could publish the database.
        let missing = deferred.subtracting(try Self.existingIndexes(fixture.pool))
        #expect(missing.isEmpty, "deferred indexes missing after the launch build: \(missing.sorted())")
        let statistics = try Self.statisticsRows(fixture.pool)
        let deferredWithout = deferred.subtracting(statistics)
        #expect(deferredWithout.isEmpty,
                "deferred indexes with no sqlite_stat1 row after the launch build: \(deferredWithout.sorted())")
        // The ANALYZE covers the whole database, not only the indexes it built.
        let migrationBuiltWithout = migrationBuilt.subtracting(statistics)
        #expect(migrationBuiltWithout.isEmpty,
                "migration-built messageHeader indexes with no sqlite_stat1 row: \(migrationBuiltWithout.sorted())")
        let marker = fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) as? Int
        let liveVersion = try Self.schemaVersion(fixture.pool)
        #expect(marker != nil && marker == liveVersion,
                "the marker must hold the schema version after the build: marker \(String(describing: marker)), live \(String(describing: liveVersion))")
    }

    @Test("A background launch after an update builds no deferred index and runs no statistics; the next foreground launch runs both before it returns the database")
    func backgroundLaunchLeavesTheStepToTheNextForegroundLaunch() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let existing = try Self.existingIndexes(fixture.pool)
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: existing),
                "the fixture must start without the deferred indexes, or the launches prove nothing")
        #expect(try Self.statisticsRows(fixture.pool).isEmpty)

        // The first launch after the update is a background one (a silent push):
        // the file existed and the update left upgrade work.
        let backgroundUpgrade = try AppDatabase.isUpgradeLaunch(
            fixture.pool, dbExisted: true, isForegroundLaunch: false, defaults: fixture.defaults)
        #expect(backgroundUpgrade == false)
        _ = try await AppDatabase.openForLaunch(
            pool: fixture.pool, isUpgradeLaunch: backgroundUpgrade, runStartupResets: false,
            defaults: fixture.defaults)
        let builtInBackground = deferred.intersection(try Self.existingIndexes(fixture.pool))
        #expect(builtInBackground.isEmpty, "a background launch built deferred indexes: \(builtInBackground.sorted())")
        #expect(try Self.statisticsRows(fixture.pool).isEmpty, "a background launch ran ANALYZE")
        #expect(fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) == nil)

        // The next launch is the user opening the app: an upgrade launch, so the
        // "Updating…" screen shows and the build runs the step before it returns.
        let foregroundUpgrade = try AppDatabase.isUpgradeLaunch(
            fixture.pool, dbExisted: true, isForegroundLaunch: true, defaults: fixture.defaults)
        #expect(foregroundUpgrade == true)
        _ = try await AppDatabase.openForLaunch(
            pool: fixture.pool, isUpgradeLaunch: foregroundUpgrade, runStartupResets: false,
            defaults: fixture.defaults)
        let missing = deferred.subtracting(try Self.existingIndexes(fixture.pool))
        #expect(missing.isEmpty, "deferred indexes missing after the foreground launch: \(missing.sorted())")
        let withoutStatistics = deferred.subtracting(try Self.statisticsRows(fixture.pool))
        #expect(withoutStatistics.isEmpty,
                "deferred indexes with no sqlite_stat1 row after the foreground launch: \(withoutStatistics.sorted())")
        let marker = fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) as? Int
        let liveVersion = try Self.schemaVersion(fixture.pool)
        #expect(marker != nil && marker == liveVersion,
                "the marker must hold the schema version after the foreground launch: marker \(String(describing: marker)), live \(String(describing: liveVersion))")
    }

    /// What the database held when the inbox would have shown: the deferred indexes
    /// still missing, the statistics marker and the live `schema_version`.
    private struct AtFirstPaint: Sendable {
        let missing: Set<String>
        let marker: Int?
        let liveVersion: Int?
    }

    /// A launch through `AppStartup` on the fixture's database, in the background or
    /// the foreground, whose first paint records `AtFirstPaint`. A launch in the
    /// background is never an upgrade launch, and the foreground one here is not one
    /// either, so the probe answers false; the build is the real launch build.
    /// `dbExisted` is whether the database file existed before the launch.
    @MainActor
    private static func startup(
        _ fixture: Fixture, dbExisted: Bool = true, isForeground: Bool,
        atFirstPaint: @escaping @Sendable (AtFirstPaint) -> Void
    ) -> AppStartup {
        let pool = fixture.pool
        let suiteName = fixture.suiteName
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        return AppStartup(
            probe: { (pool, false) },
            buildAndPublish: { built in
                _ = try await AppDatabase.openForLaunch(pool: built, isUpgradeLaunch: false, runStartupResets: false)
            },
            preparation: {},
            upkeep: {},
            launch: (dbExisted: dbExisted, isForeground: isForeground),
            markerSuiteName: suiteName,
            firstPaint: {
                let existing = (try? Self.existingIndexes(pool)) ?? []
                let marker = UserDefaults(suiteName: suiteName)?
                    .object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) as? Int
                atFirstPaint(AtFirstPaint(
                    missing: deferred.subtracting(existing), marker: marker,
                    liveVersion: (try? Self.schemaVersion(pool)) ?? nil))
            })
    }

    /// The upgrade step on the fixture's database with its defaults suite, for a
    /// main-actor test (the suite is opened here, so no `UserDefaults` crosses actors).
    private static func runStep(_ pool: DatabasePool, suiteName: String) async -> SyncEngine.PlannerStatisticsRefresh? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        return await AppDatabase.runUpgradeStep(pool: pool, isUpgradeLaunch: true, defaults: defaults)
    }

    /// The label of the step's one write (`runRefreshPlannerStatisticsIfStale`).
    private static let statisticsWriteLabel = "AnalyzePlannerStatistics"

    /// What the user sees and what the writer runs at a first foreground, in order.
    private enum StepEvent: Equatable, Sendable {
        case updatingScreen
        case statisticsWrite(WritePriority)
    }

    /// How long a test waits for something that must happen.
    private static let waitTimeout: Duration = .seconds(10)
    /// How long a test gives a second foreground entry to show the inbox, which it
    /// must not do while the first entry's step runs.
    private static let secondEntryWindow: Duration = .milliseconds(500)
    private static let pollInterval: Duration = .milliseconds(5)

    /// Polls `condition` until it holds or `timeout` passes; returns whether it held.
    @MainActor
    private static func waitUntil(timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return await condition()
    }

    /// Holds a write open until the test opens it.
    private actor Gate {
        private var opened = false
        func open() { opened = true }
        func wait() async {
            while !opened { try? await Task.sleep(for: UpgradeStepTests.pollInterval) }
        }
    }

    @Test("A process launched in the background runs the step at its first foreground, behind the Updating screen, before the inbox shows")
    @MainActor
    func backgroundLaunchedProcessRunsTheStepAtItsFirstForeground() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let existing = try Self.existingIndexes(fixture.pool)
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: existing),
                "the fixture must start without the deferred indexes, or the launch proves nothing")
        let seen = Mutex<AtFirstPaint?>(nil)
        let startup = Self.startup(fixture, isForeground: false) { state in seen.withLock { $0 = state } }

        // The launch in the background after the update (a silent push): the app
        // delegate's trigger builds the database, migrations only.
        #expect(await startup.ensureDatabaseReady())
        #expect(!startup.isMigrating && !startup.isReady)
        let builtInBackground = deferred.intersection(try Self.existingIndexes(fixture.pool))
        #expect(builtInBackground.isEmpty, "the background launch built deferred indexes: \(builtInBackground.sorted())")
        #expect(fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) == nil)

        // What the user sees and what the writer runs, in order: the Updating screen
        // switches on, then the step's write starts at the tier ahead of queued
        // background writes. The suite's process-wide lock keeps every other
        // statistics refresh out of this window.
        let events = Mutex<[StepEvent]>([])
        await DatabaseWriteQueue.shared.setTestObserverForTesting { priority, label in
            guard label == Self.statisticsWriteLabel else { return }
            events.withLock { $0.append(.statisticsWrite(priority)) }
        }
        withObservationTracking {
            _ = startup.isMigrating
        } onChange: {
            events.withLock { $0.append(.updatingScreen) }
        }

        // The user opens the app: the scene's task, in the same process.
        await startup.runIfNeeded(navigationStore: NavigationStore())
        await DatabaseWriteQueue.shared.setTestObserverForTesting(nil)
        #expect(startup.isMigrating, "the step ran without the Updating screen")
        #expect(startup.isReady)
        let order = events.withLock { $0 }
        let expectedOrder: [StepEvent] = [.updatingScreen, .statisticsWrite(.priority)]
        #expect(order == expectedOrder,
                "the Updating screen must show before the step's write, which runs at .priority: \(order)")
        let recorded = seen.withLock { $0 }
        let atPaint = try #require(recorded, "the inbox never showed")
        #expect(atPaint.missing.isEmpty, "deferred indexes missing when the inbox showed: \(atPaint.missing.sorted())")
        #expect(atPaint.marker != nil && atPaint.marker == atPaint.liveVersion,
                "the statistics were not current when the inbox showed: marker \(String(describing: atPaint.marker)), live \(String(describing: atPaint.liveVersion))")
    }

    @Test("A second foreground entry while the first one's step runs waits for that step before the inbox shows")
    @MainActor
    func aSecondForegroundEntryWaitsForTheRunningStep() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let existing = try Self.existingIndexes(fixture.pool)
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: existing),
                "the fixture must start without the deferred indexes, or the entries prove nothing")
        let paints = Mutex<[AtFirstPaint]>([])
        let startup = Self.startup(fixture, isForeground: false) { state in paints.withLock { $0.append(state) } }
        #expect(await startup.ensureDatabaseReady())

        // The writer is busy, so the first entry's step waits behind the Updating screen.
        let gate = Gate()
        let heldWrite = Task { try await DatabaseWriteQueue.shared.execute(priority: .priority) { await gate.wait() } }
        let writerHeld = await Self.waitUntil(timeout: Self.waitTimeout) { await DatabaseWriteQueue.shared.isWriting }
        #expect(writerHeld, "the test could not hold the writer")

        let firstEntry = Task { @MainActor in await startup.runIfNeeded(navigationStore: NavigationStore()) }
        let updating = await Self.waitUntil(timeout: Self.waitTimeout) { startup.isMigrating }
        #expect(updating, "the first entry did not show the Updating screen")

        // A second entry (a second scene, a scene reconnecting) while that step waits.
        let secondEntry = Task { @MainActor in await startup.runIfNeeded(navigationStore: NavigationStore()) }
        let paintedDuringStep = await Self.waitUntil(timeout: Self.secondEntryWindow) {
            !paints.withLock { $0.isEmpty }
        }
        #expect(!paintedDuringStep, "the inbox showed while the first entry's step was still waiting for the writer")
        #expect(!startup.isReady)

        await gate.open()
        try await heldWrite.value
        await firstEntry.value
        await secondEntry.value
        #expect(startup.isReady)
        let recorded = paints.withLock { $0 }
        #expect(recorded.count == 2, "each entry shows the inbox once")
        guard recorded.count == 2 else { return }
        for atPaint in recorded {
            #expect(atPaint.missing.isEmpty, "an entry showed the inbox with deferred indexes missing: \(atPaint.missing.sorted())")
            #expect(atPaint.marker != nil && atPaint.marker == atPaint.liveVersion,
                    "an entry showed the inbox before the statistics were current: marker \(String(describing: atPaint.marker)), live \(String(describing: atPaint.liveVersion))")
        }
    }

    @Test("A process launched in the background on a database file it created runs no step at its first foreground")
    @MainActor
    func backgroundLaunchedFreshInstallRunsNoStepAtItsFirstForeground() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let existing = try Self.existingIndexes(fixture.pool)
        // The database has upgrade work, so only the build's own `dbExisted` can
        // keep the first foreground from running the step.
        #expect(!deferred.isEmpty && deferred.isDisjoint(with: existing),
                "the fixture must start without the deferred indexes, or the launch proves nothing")
        let seen = Mutex<AtFirstPaint?>(nil)
        let startup = Self.startup(fixture, dbExisted: false, isForeground: false) { state in
            seen.withLock { $0 = state }
        }

        #expect(await startup.ensureDatabaseReady())
        await startup.runIfNeeded(navigationStore: NavigationStore())
        #expect(!startup.isMigrating, "the Updating screen showed on a launch whose database file did not exist before it")
        #expect(startup.isReady)
        let recorded = seen.withLock { $0 }
        let atPaint = try #require(recorded, "the inbox never showed")
        #expect(atPaint.missing == deferred, "the first foreground ran the step on a fresh install")
        #expect(atPaint.marker == nil)
    }

    @Test("A process launched in the background whose database has no upgrade work shows no Updating screen at its first foreground")
    @MainActor
    func backgroundLaunchedProcessWithNothingToDoShowsNoUpdatingScreen() async throws {
        // The one-time resets count as upgrade work too; they are done here, as in
        // the sibling tests of `StartupMigrationsTests`.
        let savedFlags = StartupMigrationsTests.snapshotFlags()
        defer { StartupMigrationsTests.restoreFlags(savedFlags) }
        for key in StartupMigrations.resetFlagKeys { UserDefaults.standard.set(true, forKey: key) }
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let settled = await Self.runStep(fixture.pool, suiteName: fixture.suiteName)
        #expect(settled == .refreshed, "the fixture must start with nothing left to do")
        let seen = Mutex<AtFirstPaint?>(nil)
        let startup = Self.startup(fixture, isForeground: false) { state in seen.withLock { $0 = state } }

        #expect(await startup.ensureDatabaseReady())
        await startup.runIfNeeded(navigationStore: NavigationStore())
        #expect(!startup.isMigrating, "the Updating screen showed with nothing to update")
        #expect(startup.isReady)
        let recorded = seen.withLock { $0 }
        let atPaint = try #require(recorded, "the inbox never showed")
        #expect(atPaint.missing.isEmpty)
    }

    @Test("A process launched in the foreground runs nothing more at its first foreground than its launch decided")
    @MainActor
    func foregroundLaunchedProcessRunsNoSecondStep() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let deferred = Set(SyncEngine.deferredIndexes.map(\.name))
        let seen = Mutex<AtFirstPaint?>(nil)
        let startup = Self.startup(fixture, isForeground: true) { state in seen.withLock { $0 = state } }

        await startup.runIfNeeded(navigationStore: NavigationStore())
        #expect(!startup.isMigrating)
        #expect(startup.isReady)
        let recorded = seen.withLock { $0 }
        let atPaint = try #require(recorded, "the inbox never showed")
        #expect(atPaint.missing == deferred, "the foreground entry ran a step the launch did not decide on")
        #expect(atPaint.marker == nil)
    }

    @Test("On any other launch the launch build runs no step: indexes, statistics and marker untouched")
    func launchBuildOnOtherLaunchRunsNoStep() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let indexesBefore = try Self.existingIndexes(fixture.pool)
        let statisticsBefore = try Self.statisticsRows(fixture.pool)

        let db = try await AppDatabase.openForLaunch(
            pool: fixture.pool, isUpgradeLaunch: false, runStartupResets: false, defaults: fixture.defaults)
        #expect(db.dbPool === fixture.pool)

        #expect(try Self.existingIndexes(fixture.pool) == indexesBefore)
        #expect(try Self.statisticsRows(fixture.pool) == statisticsBefore)
        #expect(fixture.defaults.object(forKey: SyncEngine.plannerStatisticsSchemaVersionKey) == nil)
    }
}
