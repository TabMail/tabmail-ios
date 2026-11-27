/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The simulator proof for the thread adoption probe (`ThreadUtils.findAdoptableThreadId`, run once for every
/// header the app stores): the previous three probes (`oldProbe`, one `IN` query over the whole lookup set with
/// `LIMIT 1`, then the reverse and lateral probes) against the nearest-first probe (one `LIMIT 1` seek per id of the
/// lookup set, in nearest order, then the same reverse and lateral probes), through the `DBProof` harness, on the
/// large proof database with a thread on every stored email (the seed leaves `computedThreadId` empty, which every
/// probe skips). The seed stores no In-Reply-To and no References rows, so the reverse and lateral probes read empty
/// index ranges; they are the same statements on both sides.
///
/// Each run looks up the thread of one sync listing's worth of emails (`SyncConfig.syncMessageLimit`), shaped as:
/// - a new email with no chain (its own Message-ID only), the most common insert;
/// - a reply with a short chain (In-Reply-To and two References, the parent stored);
/// - a long chain (32 References, In-Reply-To the last) whose newest ancestor is stored;
/// - a long chain whose only stored ancestor is the oldest (the nearest-first probe asks every id first);
/// - a long chain with nothing stored (the most seeks for the nearest-first probe).
/// Writes the harness report (`<TABMAIL_DB_PROOF_DIR>/ios-forward-split/probe/report.txt`) and `ratios.txt` (old
/// over new for median time, pages read and rows visited) beside it in `ios-forward-split/`. Runs only when the test
/// runner sets `TABMAIL_DB_PROOF_DIR`.
@Suite("Thread adoption probe: old against new on the proof database", .enabled(if: DBProof.outputDirectory != nil))
struct ThreadAdoptionProbeProofTests {

    static let unit = "ios-forward-split"
    static let batch = SyncConfig.syncMessageLimit
    static let longChain = 32

    /// One email being stored: the arguments of the probe, and the thread the nearest-first probe must find.
    struct Email: Sendable {
        let headerId: String
        let rfc822: String
        let inReplyTo: String?
        let references: [String]
        let nearestThread: String?
    }

    @Test("Old against new: median time, pages read and rows visited, with ratios")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        let root = output.appendingPathComponent(Self.unit, isDirectory: true)
        let largeDirectory = root.appendingPathComponent("db-large", isDirectory: true)
        try FileManager.default.createDirectory(at: largeDirectory, withIntermediateDirectories: true)
        let large = try DBProof.prepareBase(in: largeDirectory, shape: .large)

        let threadedDirectory = root.appendingPathComponent("db-threaded", isDirectory: true)
        try FileManager.default.createDirectory(at: threadedDirectory, withIntermediateDirectories: true)
        let threaded = threadedDirectory.appendingPathComponent("proof-base.sqlite")
        try? FileManager.default.removeItem(at: threaded)
        try FileManager.default.copyItem(at: large, to: threaded)
        let queue = try DatabaseQueue(path: threaded.path)
        try queue.write { try $0.execute(sql: "UPDATE messageHeader SET computedThreadId = 't-' || id") }
        let stored = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rfc822MessageId, computedThreadId FROM messageHeader
                WHERE rfc822MessageId IS NOT NULL ORDER BY id LIMIT ?
                """, arguments: [Self.batch * 2])
                .map { (rfc822: $0["rfc822MessageId"] as String, thread: $0["computedThreadId"] as String) }
        }
        guard stored.count == Self.batch * 2 else {
            Issue.record("Expected \(Self.batch * 2) stored emails, got \(stored.count)"); return
        }

        let shapes = Self.shapes(stored: stored)
        // The nearest-first probe's answers, checked once, untimed.
        try queue.read { db in
            for (name, emails) in shapes {
                for email in emails {
                    let found = try ThreadUtils.findAdoptableThreadId(
                        myHeaderId: email.headerId, rfc822MessageId: email.rfc822, inReplyTo: email.inReplyTo,
                        references: email.references, db: db)
                    #expect(found == email.nearestThread, "\(name): \(email.headerId)")
                }
            }
        }
        try queue.close()

        var modes: [DBProof.Mode] = []
        for (name, emails) in shapes {
            modes.append(DBProof.Mode(
                name: name,
                kind: .read,
                old: DBProof.Variant(run: { db in try Self.lookUp(emails, in: db, probe: Self.oldProbe) }),
                new: DBProof.Variant(run: { db in try Self.lookUp(emails, in: db, probe: ThreadUtils.findAdoptableThreadId) }),
                emptyResult: emails.allSatisfy { $0.nearestThread == nil }))
        }
        let results = try DBProof.compare(unit: "\(Self.unit)/probe", modes: modes, base: threaded, in: output)

        var ratioLines = [
            "Old over new (above 1: the new reads less or runs faster). Rows visited = VM steps.",
            "Each run looks up \(Self.batch) emails (one sync listing).", "",
        ]
        for result in results {
            let oldPages = result.old.count(\.pagesRead).median
            let newPages = result.new.count(\.pagesRead).median
            let oldSteps = result.old.count(\.vmSteps).median
            let newSteps = result.new.count(\.vmSteps).median
            ratioLines.append("== \(result.mode.name), \(result.statistics.label)")
            ratioLines.append(Self.ratioLine("median ms", result.old.wallMs.median, result.new.wallMs.median))
            ratioLines.append(Self.ratioLine("pages read", Double(oldPages), Double(newPages)))
            ratioLines.append(Self.ratioLine("rows visited", Double(oldSteps), Double(newSteps)))
            ratioLines.append("  time verdict: \(result.timeVerdict.rawValue)")
            ratioLines.append("")
        }
        try ratioLines.joined(separator: "\n").write(
            to: root.appendingPathComponent("ratios.txt"), atomically: true, encoding: .utf8)
    }

    /// The five shapes, each `batch` emails over distinct stored ancestors.
    static func shapes(stored: [(rfc822: String, thread: String)]) -> [(String, [Email])] {
        func missing(_ shape: String, _ index: Int, _ position: Int) -> String {
            "<missing-\(shape)-\(index)-\(position)@example.com>"
        }
        func email(_ shape: String, _ index: Int, inReplyTo: String?, references: [String], nearest: String?) -> Email {
            Email(headerId: "proof:INBOX:new-\(shape)-\(index)", rfc822: "<new-\(shape)-\(index)@example.com>",
                  inReplyTo: inReplyTo, references: references, nearestThread: nearest)
        }
        let indices = 0..<batch
        let noChain = indices.map { email("none", $0, inReplyTo: nil, references: [], nearest: nil) }
        let short = indices.map { i -> Email in
            let root = stored[2 * i], parent = stored[2 * i + 1]
            return email("short", i, inReplyTo: parent.rfc822, references: [root.rfc822, parent.rfc822], nearest: parent.thread)
        }
        let newestStored = indices.map { i -> Email in
            let refs = (0..<(longChain - 1)).map { missing("newest", i, $0) } + [stored[i].rfc822]
            return email("newest", i, inReplyTo: refs.last, references: refs, nearest: stored[i].thread)
        }
        let oldestStored = indices.map { i -> Email in
            let refs = [stored[i].rfc822] + (1..<longChain).map { missing("oldest", i, $0) }
            return email("oldest", i, inReplyTo: refs.last, references: refs, nearest: stored[i].thread)
        }
        let nothingStored = indices.map { i -> Email in
            let refs = (0..<longChain).map { missing("nothing", i, $0) }
            return email("nothing", i, inReplyTo: refs.last, references: refs, nearest: nil)
        }
        return [
            ("new email, no chain (own Message-ID only)", noChain),
            ("reply, short chain (In-Reply-To + 2 References), parent stored", short),
            ("long chain (\(longChain) References), newest ancestor stored", newestStored),
            ("long chain (\(longChain) References), only the oldest ancestor stored", oldestStored),
            ("long chain (\(longChain) References), nothing stored", nothingStored),
        ]
    }

    typealias Probe = (String, String?, String?, [String], Bool, Database) throws -> String?

    /// Looks up every email's thread; returns how many found one.
    static func lookUp(_ emails: [Email], in db: Database, probe: Probe) throws -> Int {
        var found = 0
        for email in emails {
            let thread = try probe(email.headerId, email.rfc822, email.inReplyTo, email.references, false, db)
            if thread != nil { found += 1 }
        }
        return found
    }

    /// `ThreadUtils.findAdoptableThreadId` as main has it before the nearest-first probe: one `IN` query over the
    /// whole lookup set with `LIMIT 1` (whichever stored email SQLite returns first), then the reverse and lateral
    /// probes, the In-Reply-To one with main's index name (#1563), so both sides run the same reverse and lateral
    /// statements and only the forward step differs.
    static func oldProbe(
        myHeaderId: String, rfc822MessageId: String?, inReplyTo: String?, references: [String], isForward: Bool,
        db: Database
    ) throws -> String? {
        var lookups: [String] = []
        if let irt = inReplyTo, !irt.isEmpty { lookups.append(irt) }
        lookups.append(contentsOf: references)
        if let rfc = rfc822MessageId, !rfc.isEmpty { lookups.append(rfc) }
        var dedupe = Set<String>()
        let L = lookups.filter { dedupe.insert($0).inserted }
        guard !L.isEmpty else { return nil }
        let placeholders = L.map { _ in "?" }.joined(separator: ",")
        if let found = try String.fetchOne(db, sql: """
            SELECT computedThreadId FROM messageHeader
            WHERE rfc822MessageId IN (\(placeholders))
              AND id != ?
              AND computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }
        if let found = try String.fetchOne(db, sql: """
            SELECT computedThreadId FROM messageHeader INDEXED BY messageHeader_inReplyTo
            WHERE inReplyTo IN (\(placeholders))
              AND id != ?
              AND computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }
        if let found = try String.fetchOne(db, sql: """
            SELECT m.computedThreadId FROM messageReference r
            JOIN messageHeader m ON m.id = r.messageHeaderId
            WHERE r.referencedRfc822Id IN (\(placeholders))
              AND m.id != ?
              AND m.computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }
        return nil
    }

    private static func ratioLine(_ label: String, _ old: Double, _ new: Double) -> String {
        let ratio = new > 0 ? String(format: "%.2f", old / new) : "n/a"
        let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }
        return "  \(label): old \(format(old)), new \(format(new)), old/new \(ratio)"
    }
}
