/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The simulator proof for the badge dedup read (`UnreadCountManager.recentUnreadCountedIds`, #1403): the replaced
/// statement (`BadgeDedupRecentUnreadReadTests.oracle`) against the hinted read, through the `DBProof` harness, on:
/// - the large proof database (about 100,000 headers, four inboxes, about 7,400 unread inbox rows);
/// - the same with every inbox row unread (about 24,600);
/// - a medium database (`Shape.small`, about 150 unread inbox rows, below the limit);
/// - one inbox of about 3,000 headers, where the planner already walks the date index.
/// Each side returns its ids. Writes `report.txt` per database and `ratios.txt` (old over new for median time,
/// pages read and rows visited) under `<TABMAIL_DB_PROOF_DIR>/ios-scan-badge-dedup-sort/`. Runs only when the test
/// runner sets `TABMAIL_DB_PROOF_DIR`.
///
/// What each database must show:
/// - The two large ones: fewer pages read.
/// - One inbox: never more pages (both sides walk the same index).
/// - Below the limit (medium): the same rows visited (VM steps). Both statements then read every unread inbox row,
///   and the date index's wider entries can take one more page than `messageHeader_folderId_isRead` (59 against 58
///   on this database), so pages are reported here but not compared.
@Suite("Badge dedup read: old against new on the proof databases", .enabled(if: DBProof.outputDirectory != nil))
struct BadgeDedupRecentUnreadProofTests {

    static let unit = "ios-scan-badge-dedup-sort"
    static let oneInboxShape = DBProof.Shape(
        accounts: [DBProof.AccountShape(provider: .imap, headers: 3_000, inboxShare: 0.6)],
        labels: DBProof.Shape.defaultLabels,
        otherFolders: DBProof.Shape.defaultOtherFolders)

    private static let mode = DBProof.Mode(
        name: "badge dedup read, newest \(SyncConfig.nseBadgeDedupRecentLimit) unread inbox rows",
        kind: .read,
        old: DBProof.Variant(run: { try BadgeDedupRecentUnreadReadTests.oracle($0).count }),
        new: DBProof.Variant(run: { try UnreadCountManager.recentUnreadCountedIds($0).ids.count }))

    private static func base(_ shape: DBProof.Shape, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DBProof.prepareBase(in: directory, shape: shape)
    }

    @Test("Old against new: median time, pages read and rows visited, with ratios")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        let root = output.appendingPathComponent(Self.unit, isDirectory: true)

        let large = try Self.base(.large, in: root.appendingPathComponent("db-large", isDirectory: true))
        let allUnreadDirectory = root.appendingPathComponent("db-large-all-unread", isDirectory: true)
        try FileManager.default.createDirectory(at: allUnreadDirectory, withIntermediateDirectories: true)
        let allUnread = allUnreadDirectory.appendingPathComponent("proof-base.sqlite")
        try? FileManager.default.removeItem(at: allUnread)
        try FileManager.default.copyItem(at: large, to: allUnread)
        let queue = try DatabaseQueue(path: allUnread.path)
        try queue.write { try $0.execute(sql: "UPDATE messageHeader SET isRead = 0 WHERE isInInbox = 1") }
        try queue.close()
        let medium = try Self.base(.small, in: root.appendingPathComponent("db-medium", isDirectory: true))
        let oneInbox = try Self.base(Self.oneInboxShape, in: root.appendingPathComponent("db-one-inbox", isDirectory: true))

        let runs: [(name: String, base: URL, expectation: Expectation)] = [
            ("large", large, .fewerPages),
            ("large-all-unread", allUnread, .fewerPages),
            ("medium", medium, .sameRowsVisitedBelowTheLimit),
            ("one-inbox", oneInbox, .neverMorePages),
        ]
        var ratioLines = ["Old over new (above 1: the new reads less or runs faster). Rows visited = VM steps.", ""]
        for run in runs {
            let unread = try Self.unreadInboxRows(run.base)
            if run.expectation == .sameRowsVisitedBelowTheLimit {
                #expect(unread.rows < SyncConfig.nseBadgeDedupRecentLimit, "\(run.name) is not below the limit: \(unread.rows)")
            }
            let results = try DBProof.compare(unit: "\(Self.unit)/\(run.name)", modes: [Self.mode], base: run.base, in: output)
            for result in results {
                let oldPages = result.old.count(\.pagesRead).median
                let newPages = result.new.count(\.pagesRead).median
                let oldSteps = result.old.count(\.vmSteps).median
                let newSteps = result.new.count(\.vmSteps).median
                ratioLines.append("== \(run.name) (\(unread.folders) inboxes, \(unread.rows) unread inbox rows), \(result.statistics.label)")
                ratioLines.append(Self.ratioLine("median ms", result.old.wallMs.median, result.new.wallMs.median))
                ratioLines.append(Self.ratioLine("pages read", Double(oldPages), Double(newPages)))
                ratioLines.append(Self.ratioLine("rows visited", Double(oldSteps), Double(newSteps)))
                ratioLines.append("  time verdict: \(result.timeVerdict.rawValue)")
                ratioLines.append("")
                let context = "\(run.name), \(result.statistics.label): pages old \(oldPages), new \(newPages); "
                    + "rows visited old \(oldSteps), new \(newSteps)"
                switch run.expectation {
                case .fewerPages:
                    #expect(newPages < oldPages, "fewer pages with several inboxes and a large unread backlog: \(context)")
                case .neverMorePages:
                    #expect(newPages <= oldPages, "never more pages: \(context)")
                case .sameRowsVisitedBelowTheLimit:
                    #expect(newSteps == oldSteps, "the same rows visited below the limit: \(context)")
                }
            }
        }
        try ratioLines.joined(separator: "\n").write(
            to: root.appendingPathComponent("ratios.txt"), atomically: true, encoding: .utf8)
    }

    enum Expectation {
        case fewerPages
        case neverMorePages
        case sameRowsVisitedBelowTheLimit
    }

    private static func unreadInboxRows(_ url: URL) throws -> (folders: Int, rows: Int) {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            let folders = try BadgeDedupRecentUnreadReadTests.inboxFolderIds(db).count
            let rows = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader WHERE isRead = 0
                  AND folderId IN (SELECT id FROM folder WHERE role = ?)
                """, arguments: [FolderRole.inbox.rawValue]) ?? 0
            return (folders, rows)
        }
    }

    private static func ratioLine(_ label: String, _ old: Double, _ new: Double) -> String {
        let ratio = new > 0 ? String(format: "%.2f", old / new) : "n/a"
        let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }
        return "  \(label): old \(format(old)), new \(format(new)), old/new \(ratio)"
    }
}
