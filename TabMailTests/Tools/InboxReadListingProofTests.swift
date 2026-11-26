/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The simulator proof for the assistant's inbox listing (`InboxReadTool.readListing`, #1391): the replaced count
/// and LIMIT/OFFSET read (`InboxReadListingDifferentialTests.oracle`) against the listing, through the `DBProof`
/// harness, on the large proof database (about 100,000 headers, about 24,600 in the inbox), the same with demo rows
/// left in it, a medium inbox (`Shape.small`, about 490 inbox rows) and an inbox of one page. Each side returns its
/// page's rows. Writes `report.txt` per database and `ratios.txt` (old over new for time, pages read and rows
/// visited) under `<TABMAIL_DB_PROOF_DIR>/ios-scan-inbox-tool-offset/`. Runs only when the test runner sets
/// `TABMAIL_DB_PROOF_DIR`.
@Suite("Inbox read tool listing: old against new on the proof databases", .enabled(if: DBProof.outputDirectory != nil))
struct InboxReadListingProofTests {

    static let unit = "ios-scan-inbox-tool-offset"
    /// Demo rows left in the database, dated among the newest inbox mail.
    static let leftoverDemoInboxRows = 63
    static let leftoverDemoArchiveRows = 9
    /// One account whose inbox is a single page.
    static let onePageShape = DBProof.Shape(
        accounts: [DBProof.AccountShape(provider: .gmail, headers: 120, inboxShare: 0.3)],
        labels: DBProof.Shape.defaultLabels,
        otherFolders: DBProof.Shape.defaultOtherFolders)

    private static func variant(page: Int, demoActive: Bool, old: Bool) -> DBProof.Variant {
        DBProof.Variant(run: { db in
            old
                ? try InboxReadListingDifferentialTests.oracle(db, pageIndex: page, demoActive: demoActive).ids.count
                : try InboxReadListingDifferentialTests.listing(db, pageIndex: page, demoActive: demoActive).ids.count
        })
    }

    private static func mode(_ name: String, page: Int, demoActive: Bool) -> DBProof.Mode {
        DBProof.Mode(name: name, kind: .read,
                     old: variant(page: page, demoActive: demoActive, old: true),
                     new: variant(page: page, demoActive: demoActive, old: false))
    }

    private static func pages(_ url: URL, demoActive: Bool) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        let total = try queue.read { try InboxReadListingDifferentialTests.oracle($0, pageIndex: 1, demoActive: demoActive).totalCount }
        return InboxReadTool.totalPages(for: total)
    }

    /// The normal-mode pages a user can ask for: the first, the second, the middle and the last.
    private static func normalModes(_ url: URL, label: String) throws -> [DBProof.Mode] {
        let last = try pages(url, demoActive: false)
        return Set([1, 2, max(1, last / 2), last]).sorted().map {
            mode("\(label), normal mode, page \($0) of \(last)", page: $0, demoActive: false)
        }
    }

    private static func base(_ shape: DBProof.Shape, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DBProof.prepareBase(in: directory, shape: shape)
    }

    private static func addLeftoverDemoRows(to url: URL, anchor: Date) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.write { db in
            try InboxReadListingDifferentialTests.insertAccount(db, id: DemoSeed.demoAccountId)
            try InboxReadListingDifferentialTests.insertRows(
                db, accountId: DemoSeed.demoAccountId, inbox: leftoverDemoInboxRows, archive: leftoverDemoArchiveRows
            ) { anchor.addingTimeInterval(-Double($0) * 3_600) }
        }
        try queue.close()
    }

    @Test("Old against new: median time, pages read and rows visited, with ratios")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        let root = output.appendingPathComponent(Self.unit, isDirectory: true)
        let anchor = Date()

        let large = try Self.base(.large, in: root.appendingPathComponent("db-large", isDirectory: true))
        let withDemo = root.appendingPathComponent("db-large-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: withDemo, withIntermediateDirectories: true)
        let largeDemo = withDemo.appendingPathComponent("proof-base.sqlite")
        try? FileManager.default.removeItem(at: largeDemo)
        try FileManager.default.copyItem(at: large, to: largeDemo)
        try Self.addLeftoverDemoRows(to: largeDemo, anchor: anchor)
        let medium = try Self.base(.small, in: root.appendingPathComponent("db-medium", isDirectory: true))
        let onePage = try Self.base(Self.onePageShape, in: root.appendingPathComponent("db-one-page", isDirectory: true))

        let demoPages = try Self.pages(largeDemo, demoActive: true)
        let demoNormalPages = try Self.pages(largeDemo, demoActive: false)
        let runs: [(name: String, base: URL, modes: [DBProof.Mode], largeInbox: Bool)] = [
            ("large", large, try Self.normalModes(large, label: "large inbox"), true),
            ("large-demo", largeDemo,
             [Self.mode("large inbox with leftover demo rows, normal mode, page 1", page: 1, demoActive: false),
              Self.mode("large inbox with leftover demo rows, normal mode, page \(demoNormalPages) of \(demoNormalPages)",
                        page: demoNormalPages, demoActive: false)], true),
            ("demo-mode", largeDemo,
             Set([1, demoPages]).sorted().map {
                 Self.mode("demo mode, page \($0) of \(demoPages)", page: $0, demoActive: true)
             }, false),
            ("medium", medium, try Self.normalModes(medium, label: "medium inbox"), false),
            ("one-page", onePage, [Self.mode("one-page inbox, normal mode, page 1", page: 1, demoActive: false)], false),
        ]

        var ratioLines = ["Old over new (above 1: the new reads less or runs faster). Rows visited = VM steps.", ""]
        for run in runs {
            let results = try DBProof.compare(unit: "\(Self.unit)/\(run.name)", modes: run.modes, base: run.base, in: output)
            for result in results {
                let oldMs = result.old.wallMs.median
                let newMs = result.new.wallMs.median
                let oldPages = result.old.count(\.pagesRead).median
                let newPages = result.new.count(\.pagesRead).median
                let oldSteps = result.old.count(\.vmSteps).median
                let newSteps = result.new.count(\.vmSteps).median
                ratioLines.append("== \(result.mode.name), \(result.statistics.label)")
                ratioLines.append(Self.ratioLine("median ms", oldMs, newMs))
                ratioLines.append(Self.ratioLine("pages read", Double(oldPages), Double(newPages)))
                ratioLines.append(Self.ratioLine("rows visited", Double(oldSteps), Double(newSteps)))
                ratioLines.append("  time verdict: \(result.timeVerdict.rawValue)")
                ratioLines.append("")
                let context = "\(result.mode.name), \(result.statistics.label): pages old \(oldPages), new \(newPages)"
                if run.largeInbox {
                    #expect(newPages < oldPages, "fewer pages on a large inbox: \(context)")
                } else {
                    #expect(newPages <= oldPages, "never more pages: \(context)")
                }
            }
        }
        try ratioLines.joined(separator: "\n").write(
            to: root.appendingPathComponent("ratios.txt"), atomically: true, encoding: .utf8)
    }

    private static func ratioLine(_ label: String, _ old: Double, _ new: Double) -> String {
        let ratio = new > 0 ? String(format: "%.2f", old / new) : "n/a"
        let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }
        return "  \(label): old \(format(old)), new \(format(new)), old/new \(ratio)"
    }
}
