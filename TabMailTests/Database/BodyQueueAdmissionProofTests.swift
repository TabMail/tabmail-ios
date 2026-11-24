/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The simulator proof for the body queues' admission reads (#1400): each queue's read
/// before the change (`admissionSQL` without its `LIMIT` line, every waiting row) against
/// the windowed read (`admissionSQL`, the newest `SyncConfig.bodyFetchRepopulateLimit`),
/// through the `DBProof` harness, on:
/// - the large proof database (about 100,000 headers; a share of the complete headers
///   waits for a body, thousands in each queue's scope);
/// - the same as on a first backfill: every complete header waits for a body;
/// - the same settled: every complete header has its body, so both reads return nothing;
/// - a medium database (`Shape.small`), fewer waiting rows than one window in each scope.
/// Writes `report.txt` per database and `ratios.txt` (old over new for median time, pages
/// read and rows visited) under `<TABMAIL_DB_PROOF_DIR>/ios-scan-body-queue-admission/`.
/// Runs only when the test runner sets `TABMAIL_DB_PROOF_DIR`.
///
/// What each database must show:
/// - The two large ones with more waiting rows than one window: fewer pages read.
/// - Settled, and below the window (medium): never more pages. Both reads then walk the
///   same index entries; rows visited are reported but not compared, since the `LIMIT`
///   counter adds a step per row returned.
@Suite("Body queue admission reads: old against new on the proof databases", .enabled(if: DBProof.outputDirectory != nil))
struct BodyQueueAdmissionProofTests {

    static let unit = "ios-scan-body-queue-admission"

    /// The read before the change: the production statement without its `LIMIT` line.
    /// Derived from the production string so it cannot drift from it.
    static func withoutLimit(_ sql: String) -> String {
        sql.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("LIMIT") }
            .joined(separator: "\n")
    }

    static let reads: [(name: String, sql: String, scope: String)] = [
        ("active body queue (inbox)", ActiveBodyQueue.admissionSQL, "isInInbox = 1"),
        ("backfill body queue (other folders)", BackfillBodyQueue.admissionSQL, "isInInbox = 0"),
    ]

    private static func modes(emptyResult: Bool) -> [DBProof.Mode] {
        reads.map { read in
            DBProof.Mode(
                name: "\(read.name) admission read",
                kind: .read,
                old: DBProof.Variant(sql: [withoutLimit(read.sql)]),
                new: DBProof.Variant(sql: [read.sql]),
                emptyResult: emptyResult)
        }
    }

    private static func base(_ shape: DBProof.Shape, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DBProof.prepareBase(in: directory, shape: shape)
    }

    /// A copy of `source` under `directory` with `sql` applied.
    private static func variant(of source: URL, in directory: URL, sql: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("proof-base.sqlite")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: sql) }
        try queue.close()
        return url
    }

    @Test("Old against new: median time, pages read and rows visited, with ratios")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        for read in Self.reads {
            #expect(Self.withoutLimit(read.sql) != read.sql, "setup: the old read differs from the new by its LIMIT line")
        }
        let root = output.appendingPathComponent(Self.unit, isDirectory: true)

        let large = try Self.base(.large, in: root.appendingPathComponent("db-large", isDirectory: true))
        let firstBackfill = try Self.variant(
            of: large, in: root.appendingPathComponent("db-large-first-backfill", isDirectory: true),
            sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE headerComplete = 1")
        let settled = try Self.variant(
            of: large, in: root.appendingPathComponent("db-large-settled", isDirectory: true),
            sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE headerComplete = 1")
        let medium = try Self.base(.small, in: root.appendingPathComponent("db-medium", isDirectory: true))

        let runs: [(name: String, base: URL, expectation: Expectation)] = [
            ("large", large, .fewerPages),
            ("large-first-backfill", firstBackfill, .fewerPages),
            ("large-settled", settled, .neverMorePagesNoneWaiting),
            ("medium", medium, .neverMorePagesBelowTheWindow),
        ]
        var ratioLines = ["Old over new (above 1: the new reads less or runs faster). Rows visited = VM steps.", ""]
        for run in runs {
            let waiting = try Self.waitingRows(run.base)
            for (scope, rows) in waiting {
                switch run.expectation {
                case .fewerPages:
                    #expect(rows > SyncConfig.bodyFetchRepopulateLimit, "setup: \(run.name), \(scope) holds more than one window: \(rows)")
                case .neverMorePagesNoneWaiting:
                    #expect(rows == 0, "setup: \(run.name), \(scope) has nothing waiting: \(rows)")
                case .neverMorePagesBelowTheWindow:
                    #expect(rows > 0 && rows < SyncConfig.bodyFetchRepopulateLimit, "setup: \(run.name), \(scope) is below one window: \(rows)")
                }
            }
            let modes = Self.modes(emptyResult: run.expectation == .neverMorePagesNoneWaiting)
            let results = try DBProof.compare(unit: "\(Self.unit)/\(run.name)", modes: modes, base: run.base, in: output)
            for result in results {
                let oldPages = result.old.count(\.pagesRead).median
                let newPages = result.new.count(\.pagesRead).median
                let oldSteps = result.old.count(\.vmSteps).median
                let newSteps = result.new.count(\.vmSteps).median
                let counts = waiting.map { "\($0.scope) \($0.rows)" }.joined(separator: ", ")
                ratioLines.append("== \(run.name) (waiting: \(counts)), \(result.mode.name), \(result.statistics.label)")
                ratioLines.append(Self.ratioLine("median ms", result.old.wallMs.median, result.new.wallMs.median))
                ratioLines.append(Self.ratioLine("pages read", Double(oldPages), Double(newPages)))
                ratioLines.append(Self.ratioLine("rows visited", Double(oldSteps), Double(newSteps)))
                ratioLines.append("  time verdict: \(result.timeVerdict.rawValue)")
                ratioLines.append("")
                let context = "\(run.name), \(result.mode.name), \(result.statistics.label): pages old \(oldPages), new \(newPages)"
                switch run.expectation {
                case .fewerPages:
                    #expect(newPages < oldPages, "fewer pages with more waiting rows than one window: \(context)")
                case .neverMorePagesNoneWaiting, .neverMorePagesBelowTheWindow:
                    #expect(newPages <= oldPages, "never more pages: \(context)")
                }
            }
        }
        try ratioLines.joined(separator: "\n").write(
            to: root.appendingPathComponent("ratios.txt"), atomically: true, encoding: .utf8)
    }

    enum Expectation {
        case fewerPages
        case neverMorePagesNoneWaiting
        case neverMorePagesBelowTheWindow
    }

    /// The rows each queue's read selects without its limit, per scope.
    private static func waitingRows(_ url: URL) throws -> [(scope: String, rows: Int)] {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            try reads.map { read in
                let rows = try Row.fetchAll(db, sql: withoutLimit(read.sql)).count
                return (read.scope, rows)
            }
        }
    }

    private static func ratioLine(_ label: String, _ old: Double, _ new: Double) -> String {
        let ratio = new > 0 ? String(format: "%.2f", old / new) : "n/a"
        let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }
        return "  \(label): old \(format(old)), new \(format(new)), old/new \(ratio)"
    }
}
