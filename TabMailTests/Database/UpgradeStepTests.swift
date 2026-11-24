/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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
}
