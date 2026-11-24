/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The cost of building a deferred index and analyzing in ONE write, against the two
/// writes it replaced (the build, then the whole-database `ANALYZE`), on the shared
/// large proof database and on one five times its size. Opt-in: runs only when the test
/// runner sets `TABMAIL_DB_PROOF_DIR` (see `DBProof`).
///
/// Each mode compares the combined write (new) with ONE of the two old writes (old), so
/// the report shows the new write against each old write it replaced: its hold on the
/// writer against the longer of the two, and its total against their sum. Two index
/// sets: every deferred index the app builds today (what the first pass after an
/// upgrade builds), and a single four-column index over the completeness flags (one
/// added index on a device that has the rest).
@Suite("Deferred index statistics: the one write's cost on a large database",
       .serialized, .enabled(if: DBProof.outputDirectory != nil))
struct DeferredIndexStatisticsProofTests {

    /// The large shape at `factor` times its size, same proportions.
    private static func scaled(_ factor: Int) -> DBProof.Shape {
        DBProof.Shape(
            accounts: DBProof.Shape.large.accounts.map {
                DBProof.AccountShape(provider: $0.provider, headers: $0.headers * factor, inboxShare: $0.inboxShare)
            },
            labels: DBProof.Shape.defaultLabels,
            otherFolders: DBProof.Shape.defaultOtherFolders)
    }

    private static let completenessIndexSQL = """
        CREATE INDEX IF NOT EXISTS messageHeader_proofCompletenessWindow \
        ON messageHeader(headerComplete, bodyComplete, date, id)
        """

    /// A timed write of `statements`. `CREATE INDEX` and `ANALYZE` change no rows that
    /// `changesCount` reports, so the result is the number of indexes in the schema
    /// afterwards: never 0, and the same on both sides of a mode. Its one `sqlite_master`
    /// read is paid by both sides alike.
    private static func write(setup: [String], _ statements: [String]) -> DBProof.Variant {
        DBProof.Variant(setupSQL: setup, sql: statements, run: { db in
            for statement in statements { try db.execute(sql: statement) }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'") ?? 0
        })
    }

    /// The two modes for one index set: the one write against the old build write, and
    /// against the old `ANALYZE` write. `drop` removes the set from the new side's copy
    /// (untimed); `oldAnalyzeSetup` gives the old `ANALYZE` side the set already built.
    private static func modes(_ name: String, drop: [String], create: [String],
                              oldAnalyzeSetup: [String]) -> [DBProof.Mode] {
        let oneWrite = write(setup: drop, create + ["ANALYZE"])
        return [
            DBProof.Mode(
                name: "\(name): one write vs the old build write",
                kind: .write,
                old: write(setup: drop, create),
                new: oneWrite),
            DBProof.Mode(
                name: "\(name): one write vs the old ANALYZE write",
                kind: .write,
                old: write(setup: oldAnalyzeSetup, ["ANALYZE"]),
                new: oneWrite),
        ]
    }

    private static var allModes: [DBProof.Mode] {
        let deferred = SyncEngine.deferredIndexes
        // The base already has every deferred index (`DBProof` builds them), so the old
        // ANALYZE side needs no setup; the completeness index is not in the base, so its
        // old ANALYZE side builds it first, untimed.
        return modes("every deferred index",
                     drop: deferred.map { "DROP INDEX IF EXISTS \($0.name)" },
                     create: deferred.map(\.sql),
                     oldAnalyzeSetup: [])
            + modes("completeness index",
                    drop: [],
                    create: [completenessIndexSQL],
                    oldAnalyzeSetup: [completenessIndexSQL])
    }

    private func prove(factor: Int) throws {
        guard let root = DBProof.outputDirectory else { return }
        let directory = root.appendingPathComponent("deferred-index-stats-x\(factor)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try DBProof.prepareBase(in: directory, shape: Self.scaled(factor))
        let results = try DBProof.compare(
            unit: "ios-deferred-index-stats-x\(factor)",
            modes: Self.allModes,
            base: base,
            in: directory,
            statistics: [.analyzed])
        #expect(results.count == Self.allModes.count)
    }

    @Test("At the large proof shape (just over 100,000 headers)")
    func atTheLargeShape() throws {
        try prove(factor: 1)
    }

    @Test("At five times the large proof shape (just over 500,000 headers)")
    func atFiveTimesTheLargeShape() throws {
        try prove(factor: 5)
    }
}
