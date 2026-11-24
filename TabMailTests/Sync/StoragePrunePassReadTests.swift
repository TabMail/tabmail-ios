/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1402 on the production pass itself: `SyncEngine.runPruneIfOverBudget`, with the
/// store over its limit for the whole pass, so the body pass and the header pass both
/// run to the floor in a large and a small folder of one account. Every statement the
/// passes run on the readers costs, in the large folder, what it costs in the small one.
/// Before #1402 the body pass counted the whole folder and paged it with `OFFSET`, and
/// the header pass counted the whole folder before every chunk: each of those costs
/// more the larger the folder.
///
/// `StoragePrunePagingTests` pins the helpers' pages, stops and costs; this pins that
/// the pass reads through them and through nothing that grows with the folder.
///
/// `.serialized` and `.processGlobalState`: the test sets the storage limit in the
/// standard defaults and writes a padding file into Application Support, as the prune
/// tests of `IMAPMissingByUIDTests` do.
@Suite("Storage prune pass: no read grows with the folder", .serialized, .processGlobalState, .timeLimit(.minutes(3)))
struct StoragePrunePassReadTests {
    private typealias Paging = StoragePrunePagingTests

    /// Rows in the small folder, whose reads are each statement's baseline.
    static let smallFolder = 200

    /// A 1 MB limit and a 2 MB padding file: the store is over its limit whatever
    /// else it holds, so both passes run to the floor.
    static let budgetMB = 1
    static let paddingBytes = 2 * 1024 * 1024

    /// The statements the passes read headers with: the body pass's page and check,
    /// each first and after a cursor, and the header pass's batch (its check is the
    /// body pass's first check).
    static let passStatements = 5

    @Test("Every header read of the body and the header pass costs the same in a large folder as in a small one",
          arguments: [StaleWindowMode.uid, .date])
    func noPassReadGrowsWithTheFolder(_ mode: StaleWindowMode) throws {
        let fixture = try Paging.makeFixture()
        // A deferred close: the header pass hands each chunk's content release to a
        // detached task, which can still be running when the test returns.
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let large = fixture.folderId("Archive")
        let small = fixture.folderId("INBOX")
        try Paging.seedHeaders(
            fixture, path: "Archive",
            rows: Paging.Shape(mode: mode, count: Paging.largeFolder, ties: [], pages: 0).rows())
        try Paging.seedHeaders(
            fixture, path: "INBOX",
            rows: Paging.Shape(mode: mode, count: Self.smallFolder, ties: [], pages: 0).rows())
        try Paging.resetBodies(fixture)

        let savedBudget = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
        defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }
        StorageEstimator.budgetMB = Self.budgetMB
        let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let padding = appSupport.appendingPathComponent("prune-test-padding-\(UUID().uuidString)")
        try Data(count: Self.paddingBytes).write(to: padding)
        defer { try? FileManager.default.removeItem(at: padding) }
        let overBudget = StorageEstimator.isOverBudget()
        try #require(overBudget, "setup: the store is over the limit, so both passes run to the floor")

        // Opens the reader the pass reads on, so its schema load is not counted.
        _ = try fixture.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        let run = fixture.meter.headerReads {
            SyncEngine.runPruneIfOverBudget(dbPool: fixture.database, pruneOrder: [fixture.accountId: mode])
        }

        // Each statement's costliest run in each folder, told apart by the folder id it binds.
        var largeCost: [String: Int] = [:]
        var smallCost: [String: Int] = [:]
        for read in run.reads {
            if read.expandedSQL.contains("'\(large)'") {
                largeCost[read.sql] = max(largeCost[read.sql] ?? 0, read.pages)
            } else if read.expandedSQL.contains("'\(small)'") {
                smallCost[read.sql] = max(smallCost[read.sql] ?? 0, read.pages)
            }
        }
        let left = try fixture.pool.read { db in
            (large: try MessageHeader.filter(Column("folderId") == large).fetchCount(db),
             small: try MessageHeader.filter(Column("folderId") == small).fetchCount(db))
        }

        #expect(left.large <= Paging.floor && left.small <= Paging.floor,
                "setup: the header pass did not run to the floor: \(left.large) rows left in the large folder, \(left.small) in the small one")
        #expect(largeCost.count >= Self.passStatements,
                "setup: the pass read the large folder with \(largeCost.count) statements: \(largeCost.keys.sorted())")
        let withoutBaseline = largeCost.keys.filter { smallCost[$0] == nil }.sorted()
        #expect(withoutBaseline.isEmpty, "statements that read only the large folder: \(withoutBaseline)")
        for (sql, cost) in largeCost.sorted(by: { $0.key < $1.key }) {
            let baseline = smallCost[sql] ?? 0
            #expect(cost <= baseline + Paging.pageSlack,
                    "\(sql) fetched up to \(cost) pages in \(Paging.largeFolder) rows, \(baseline) in \(Self.smallFolder)")
        }
    }
}
