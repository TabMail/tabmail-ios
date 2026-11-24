/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1402 on the production pass itself: `SyncEngine.runPruneIfOverBudget`, with
/// the space used above its target for the whole pass (a measure the test passes in), so the
/// body pass and the header pass both run to the floor in a large and a small folder
/// of one account. Every statement the
/// passes run on the readers costs, in the large folder, what it costs in the small one.
/// Before #1402 the body pass counted the whole folder and paged it with `OFFSET`, and
/// the header pass counted the whole folder before every chunk: each of those costs
/// more the larger the folder.
///
/// `StoragePrunePagingTests` pins the helpers' pages, stops and costs; this pins that
/// the pass reads through them and through nothing that grows with the folder.
///
/// `.serialized` and `.processGlobalState`: the test sets the storage limit in the
/// standard defaults, as the prune tests of `IMAPMissingByUIDTests` do. Until #1437 it
/// also wrote a padding file into Application Support, to put the walk of its files
/// over the limit.
@Suite("Storage prune pass: no read grows with the folder", .serialized, .processGlobalState, .timeLimit(.minutes(3)))
struct StoragePrunePassReadTests {
    private typealias Paging = StoragePrunePagingTests

    /// Rows in the small folder, whose reads are each statement's baseline.
    static let smallFolder = 200

    /// Any limit: the prune runs only under one. The measure the test passes in is
    /// above every level of it, so both passes run to the floor.
    static let budgetMB = 1

    /// The statements the passes read headers with: the body pass's page and check,
    /// each first and after a cursor, and the header pass's batch (its check is the
    /// body pass's first check).
    static let passStatements = 5

    @Test("Every header read of the body and the header pass costs the same in a large folder as in a small one",
          arguments: [StaleWindowMode.uid, .date])
    func noPassReadGrowsWithTheFolder(_ mode: StaleWindowMode) async throws {
        let fixture = try Paging.makeFixture()
        // A deferred close, kept from before #1437, when the header pass handed each
        // chunk's content release to a detached task it did not wait for.
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        // The small folder is the one the pass reaches first (it reads an account's
        // folders through `folder(accountId, role)`, so the archive before the inbox).
        // Its reads are then the baseline at the size the table has while the large
        // folder is read. The header batch fetches each of its rows from the table,
        // one descent of the table's b-tree per row, and that depth follows the whole
        // table, not the folder: read after the large folder was pruned, the same batch
        // costs a level less per row.
        let large = fixture.folderId("INBOX")
        let small = fixture.folderId("Archive")
        try Paging.seedHeaders(
            fixture, path: "INBOX",
            rows: Paging.Shape(mode: mode, count: Paging.largeFolder, ties: [], pages: 0).rows())
        try Paging.seedHeaders(
            fixture, path: "Archive",
            rows: Paging.Shape(mode: mode, count: Self.smallFolder, ties: [], pages: 0).rows())
        try Paging.resetBodies(fixture)

        let savedBudget = UserDefaults.standard.object(forKey: StorageEstimator.storageBudgetKey)
        defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }
        StorageEstimator.budgetMB = Self.budgetMB

        // Opens the reader the pass reads on, so its schema load is not counted.
        _ = try Paging.readNow(fixture) { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        let run = await fixture.meter.asyncHeaderReads {
            await SyncEngine.runPruneIfOverBudget(
                dbPool: fixture.database, pruneOrder: [fixture.accountId: mode],
                gate: .foreground, space: .constant(Int64.max))
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
        let left = try Paging.readNow(fixture) { db in
            (large: try MessageHeader.filter(Column("folderId") == large).fetchCount(db),
             small: try MessageHeader.filter(Column("folderId") == small).fetchCount(db))
        }

        let firstLarge = run.reads.firstIndex { $0.expandedSQL.contains("'\(large)'") } ?? run.reads.count
        let firstSmall = run.reads.firstIndex { $0.expandedSQL.contains("'\(small)'") } ?? run.reads.count
        #expect(firstSmall < firstLarge,
                "setup: the pass read the large folder (read \(firstLarge)) before the small one (read \(firstSmall)), so the small folder's costs are not a baseline at the same table size")
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
