/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// What the deferred index `messageHeader_backfillProgress` (#1401) costs and what it
/// changes, on the large proof database (`DBProof.Shape.large`: just over 100,000 headers
/// in four accounts, the largest profile the harness has):
///
/// 1. **Size and write cost.** The index's pages beside the table's and beside v40's
///    `messageHeader_accountId_bodyComplete`, whose columns it extends. Then the sync
///    pass's header writes with the index dropped (old) and present (new), through
///    `DBProof.compare`: a batch insert of new headers, the `headerComplete` update after
///    FTS indexing, and the body success update that sets `bodyComplete`.
/// 2. **No hot read switches to it and reads more.** Each hot read's plan with and without
///    the index, in four statistics states, and the pages and rows the read takes both ways
///    on a fresh connection. A read whose plan names the index must read fewer pages.
/// 3. **Which reads still plan on v40's index**, listed per statistics state.
///
/// The harness seeds `headerComplete` and `bodyComplete` at a synced phone's proportions.
/// The two other flags the index holds are set here, from the rowid so that every run
/// sets the same rows, then the file is vacuumed so every index is as compact as a fresh
/// build. The index's statistics and every plan on these columns depend on those
/// proportions.
///
/// Runs only when the test runner sets `TABMAIL_DB_PROOF_DIR`, and writes `size.txt`,
/// `census.txt` and `write-cost/report.txt` under `<dir>/ios-scan-backfill-progress-count`.
@Suite("Backfill progress index proof: size, write cost and the hot reads' plans",
       .serialized, .enabled(if: DBProof.outputDirectory != nil))
struct BackfillProgressIndexProofTests {

    private enum Config {
        static let unit = "ios-scan-backfill-progress-count"
        static let index = "messageHeader_backfillProgress"
        static let v40Index = "messageHeader_accountId_bodyComplete"
        /// The flag shares, in thousandths. A row takes a flag when `(rowid * spread) %
        /// perMille` falls under the share; each flag has its own spread, coprime to
        /// `perMille`, so the flags fall on different rows.
        static let perMille: Int64 = 1_000
        /// Of the bodies in, the ones confirmed empty.
        static let emptyConfirmedPerMille: Int64 = 30
        /// Of the bodies still pending, the ones quarantined as oversized.
        static let oversizedPerMille: Int64 = 30
        static let emptySpread: Int64 = 69_069
        static let oversizedSpread: Int64 = 2_246_822_519
        /// The account the per-account reads name: the large Gmail account.
        static let accountIndex = 0
        static let denseLabel = "proof_dense"
        static let archivePath = "Archive"
        static let inboxPath = "INBOX"
    }

    // MARK: - The proof database

    /// The large proof database with the two quarantine flags set, vacuumed.
    private static func prepareBase(in directory: URL) throws -> URL {
        let base = try DBProof.prepareBase(in: directory)
        let queue = try DatabaseQueue(path: base.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: """
                UPDATE messageHeader SET bodyEmptyConfirmed = (rowid * ?) % ? < ? WHERE bodyComplete = 1
                """, arguments: [Config.emptySpread, Config.perMille, Config.emptyConfirmedPerMille])
            try db.execute(sql: """
                UPDATE messageHeader SET bodyMetadataOversized = (rowid * ?) % ? < ?
                WHERE headerComplete = 1 AND bodyComplete = 0
                """, arguments: [Config.oversizedSpread, Config.perMille, Config.oversizedPerMille])
        }
        try queue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        return base
    }

    /// The rows in each combination of the four flags.
    private static func flagCensus(_ base: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: base.path)
        defer { try? queue.close() }
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT headerComplete AS hc, bodyComplete AS bc, bodyEmptyConfirmed AS bec,
                       bodyMetadataOversized AS bmo, count(*) AS n
                FROM messageHeader GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4
                """).map { row in
                let hc: Int = row["hc"], bc: Int = row["bc"], bec: Int = row["bec"], bmo: Int = row["bmo"], n: Int = row["n"]
                return "headerComplete \(hc), bodyComplete \(bc), bodyEmptyConfirmed \(bec), bodyMetadataOversized \(bmo): \(n)"
            }
        }
    }

    // MARK: - Size

    private struct Size {
        let pageSize: Int
        let usedPages: Int
        let headers: Int
        let indexPages: [String: Int]
    }

    private static func usedPages(_ db: Database) throws -> Int {
        let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        return pages - free
    }

    /// Each named index's pages: the used pages it frees when dropped from a copy.
    private static func size(of base: URL, indexes: [String], scratch: URL) throws -> Size {
        let queue = try DatabaseQueue(path: base.path)
        let (pageSize, used, headers) = try queue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0, try usedPages(db),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM messageHeader") ?? 0)
        }
        try queue.close()
        var indexPages: [String: Int] = [:]
        for name in indexes {
            try DBProof.removeDatabaseFiles(at: scratch)
            try FileManager.default.copyItem(at: base, to: scratch)
            let copy = try DatabaseQueue(path: scratch.path)
            indexPages[name] = try copy.writeWithoutTransaction { db in
                let before = try usedPages(db)
                try db.execute(sql: "DROP INDEX \(name)")
                return before - (try usedPages(db))
            }
            try copy.close()
        }
        try DBProof.removeDatabaseFiles(at: scratch)
        return Size(pageSize: pageSize, usedPages: used, headers: headers, indexPages: indexPages)
    }

    // MARK: - Write cost

    /// What the insert mode writes: new headers in one account's inbox, above its UIDs.
    private struct InsertBatch: Sendable {
        let accountId: String
        let folderId: String
        let firstUid: Int
        let count: Int
        let date: Date
    }

    /// The sync pass's header insert: one `MessageHeader` record insert per new header,
    /// in one transaction of `SyncConfig.backfillInsertChunkSize`.
    @discardableResult
    private static func insertHeaders(_ db: Database, _ batch: InsertBatch) throws -> Int {
        for offset in 0..<batch.count {
            let uid = batch.firstUid + offset
            var header = MessageHeader(
                messageId: String(uid),
                subject: "Subject \(uid)",
                from: "Sender <sender@example.com>",
                fromAddress: "sender@example.com",
                to: "proof@example.com",
                date: batch.date,
                snippet: "Snippet \(uid)",
                folderId: batch.folderId,
                accountId: batch.accountId,
                folderPath: Config.inboxPath,
                isInInbox: true)
            header.rfc822MessageId = "<new-\(uid)@example.com>"
            try header.insert(db)
        }
        return batch.count
    }

    /// `SyncEngine.indexHeadersForFTS`' write, once per header whose FTS row is in.
    private static let headerCompleteSQL = "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?"

    /// `BodyFetchProcessor.flushBatch`'s success write, once per body.
    private static let bodyCompleteSQL = """
        UPDATE messageHeader
        SET snippet = ?, bodyComplete = 1, missFetchCount = 0,
            bodyMetadataOversized = 0
        WHERE id = ?
        """

    /// Runs `sql` once per argument list, as the production loops do, and returns the
    /// rows it changed.
    @discardableResult
    private static func executeEach(_ db: Database, _ sql: String, _ arguments: [StatementArguments]) throws -> Int {
        var changed = 0
        for values in arguments {
            try db.execute(sql: sql, arguments: values)
            changed += db.changesCount
        }
        return changed
    }

    private static func writeModes(base: URL) throws -> [DBProof.Mode] {
        let queue = try DatabaseQueue(path: base.path)
        defer { try? queue.close() }
        let account = DBProof.accountId(Config.accountIndex)
        let (inboxFolder, maxUid, incomplete, pending) = try queue.read { db -> (String, Int, [String], [String]) in
            let folder = try String.fetchOne(db, sql: """
                SELECT folderId FROM messageHeader WHERE accountId = ? AND folderPath = ? LIMIT 1
                """, arguments: [account, Config.inboxPath]) ?? ""
            let maxUid = try Int.fetchOne(db, sql: """
                SELECT max(CAST(messageId AS INTEGER)) FROM messageHeader WHERE folderId = ?
                """, arguments: [folder]) ?? 0
            // The newest incomplete headers, as a sync page leaves them for FTS indexing.
            let incomplete = try String.fetchAll(db, sql: """
                SELECT id FROM messageHeader WHERE headerComplete = 0 ORDER BY rowid DESC LIMIT ?
                """, arguments: [SyncConfig.ftsIndexBatchSize])
            // The body queue's next batch, in its own admission order.
            let pending = try ActiveBodyQueue.admissionItems(db)
                .prefix(SyncConfig.backfillBodyDispatchBatch).map(\.headerId)
            return (folder, maxUid, incomplete, pending)
        }
        #expect(!inboxFolder.isEmpty && incomplete.count == SyncConfig.ftsIndexBatchSize
                && pending.count == SyncConfig.backfillBodyDispatchBatch,
                "setup: the inbox, \(incomplete.count) incomplete headers, \(pending.count) pending bodies")
        let batch = InsertBatch(accountId: account, folderId: inboxFolder, firstUid: maxUid + 1,
                                count: SyncConfig.backfillInsertChunkSize, date: Date())
        let headerArguments: [StatementArguments] = incomplete.map { [$0] }
        let bodyArguments: [StatementArguments] = pending.map { ["Snippet", $0] }
        let dropIndex = ["DROP INDEX \(Config.index)"]
        return [
            DBProof.Mode(
                name: "insert \(SyncConfig.backfillInsertChunkSize) new headers", kind: .write,
                old: DBProof.Variant(setupSQL: dropIndex, run: { db in try Self.insertHeaders(db, batch) }),
                new: DBProof.Variant(run: { db in try Self.insertHeaders(db, batch) })),
            DBProof.Mode(
                name: "headerComplete = 1 for \(SyncConfig.ftsIndexBatchSize) headers", kind: .write,
                old: DBProof.Variant(setupSQL: dropIndex,
                                     run: { db in try Self.executeEach(db, Self.headerCompleteSQL, headerArguments) }),
                new: DBProof.Variant(run: { db in try Self.executeEach(db, Self.headerCompleteSQL, headerArguments) })),
            DBProof.Mode(
                name: "bodyComplete = 1 for \(SyncConfig.backfillBodyDispatchBatch) bodies", kind: .write,
                old: DBProof.Variant(setupSQL: dropIndex,
                                     run: { db in try Self.executeEach(db, Self.bodyCompleteSQL, bodyArguments) }),
                new: DBProof.Variant(run: { db in try Self.executeEach(db, Self.bodyCompleteSQL, bodyArguments) })),
        ]
    }

    // MARK: - The plan census

    /// The statistics a device can hold when a hot read runs.
    private enum State: String, CaseIterable {
        /// What the migration chain leaves (it analyzes an empty schema): no row for any
        /// full index. A fresh install, and an upgrade before the pass's `ANALYZE`.
        case migrationLeft
        /// No `sqlite_stat1` rows at all.
        case none
        /// A whole-database `ANALYZE` with the index present: after the maintenance pass.
        case fresh
        /// Analyzed before the index existed, then the index built: a connection that loaded
        /// the schema between the pass's index build and its `ANALYZE`.
        case staleBeforeIndex

        var label: String {
            switch self {
            case .migrationLeft: return "the statistics the migrations leave (no row for a full index)"
            case .none: return "no sqlite_stat1"
            case .fresh: return "a whole-database ANALYZE with the index present"
            case .staleBeforeIndex: return "analyzed before the index existed, then the index built"
            }
        }
    }

    private struct Probe: Sendable {
        let name: String
        let hot: Bool
        let sql: String
        let arguments: StatementArguments
    }

    private static func inboxQuery(_ folderId: String, mode: InboxMode, unread: Bool, labels: Set<String>) -> InboxListQuery {
        InboxListQuery(displayedFolderIds: [folderId], filterUnread: unread, filterLabelIds: labels,
                       mode: mode, targetCount: SyncConfig.inboxPageSize, before: nil)
    }

    /// The hot reads, from their production statements; then the other reads on the
    /// completeness flags (statements transcribed in `DeferredIndexStatisticsTests`'
    /// census, cited at their production sites), and the three backfill progress counts
    /// as `SyncEngine.backfillProgressCounts` runs them.
    private static func probes(_ db: Database) throws -> [Probe] {
        let account = DBProof.accountId(Config.accountIndex)
        let inbox = try String.fetchOne(db, sql: """
            SELECT folderId FROM messageHeader WHERE accountId = ? AND folderPath = ? LIMIT 1
            """, arguments: [account, Config.inboxPath]) ?? ""
        let archive = try String.fetchOne(db, sql: """
            SELECT folderId FROM messageHeader WHERE accountId = ? AND folderPath = ? LIMIT 1
            """, arguments: [account, Config.archivePath]) ?? ""
        let label = try String.fetchOne(db, sql: """
            SELECT id FROM userLabel WHERE accountId = ? AND providerLabelId = ?
            """, arguments: [account, Config.denseLabel]) ?? ""
        func inboxPage(_ name: String, _ query: InboxListQuery) -> Probe {
            let statement = InboxListReader.durableQuerySQL(folderId: inbox, query: query)
            return Probe(name: name, hot: true, sql: statement.sql, arguments: statement.arguments)
        }
        let cutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date()) ?? Date()
        // `SyncEngine.runEvictStaleBodies`' recent-bodies read for a non-inbox folder.
        let recent = try MessageHeader.select(Column("id"))
            .filter(Column("folderId") == archive)
            .order(Column("date").desc)
            .limit(SyncConfig.bodyCacheRecentPerFolder)
            .makePreparedRequest(db).statement
        var probes: [Probe] = [
            inboxPage("inbox first page", inboxQuery(inbox, mode: .normal, unread: false, labels: [])),
            inboxPage("unread page", inboxQuery(inbox, mode: .normal, unread: true, labels: [])),
            inboxPage("triage order", inboxQuery(inbox, mode: .triage, unread: false, labels: [])),
            inboxPage("label-filter page", inboxQuery(inbox, mode: .normal, unread: false, labels: [label])),
            Probe(name: "body download queue, active", hot: true, sql: ActiveBodyQueue.admissionSQL, arguments: []),
            Probe(name: "body download queue, backfill", hot: true, sql: BackfillBodyQueue.admissionSQL, arguments: []),
            Probe(name: "stale-body evict page", hot: true, sql: SyncEngine.staleBodyPageSQL(afterCursor: false),
                  arguments: [cutoff, SyncConfig.pruneChunkSize]),
            Probe(name: "stale-body evict, recent bodies of a folder", hot: true, sql: recent.sql, arguments: recent.arguments),
            Probe(name: "FTS self-heal, recent window", hot: true, sql: SyncEngine.ftsBodyMembershipCandidateSQL, arguments: []),
            Probe(name: "FTS self-heal, backfill scope", hot: true, sql: SyncEngine.backfillFTSSelfHealCandidateSQL, arguments: []),
            Probe(name: "bodyComplete restore", hot: false, sql: """
                SELECT id FROM messageHeader WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                """, arguments: []),
            Probe(name: "FTS heal-all sweep", hot: false, sql: """
                SELECT rowid, id FROM messageHeader WHERE rowid > ? AND bodyComplete = 1 AND headerComplete = 1 \
                ORDER BY rowid LIMIT 500
                """, arguments: [0]),
            Probe(name: "embedding repopulate", hot: false, sql: """
                SELECT id FROM messageHeader WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0 \
                ORDER BY isInInbox DESC, date DESC LIMIT 500
                """, arguments: []),
            Probe(name: "recover incomplete headers", hot: false, sql: """
                SELECT * FROM messageHeader WHERE headerComplete = 0 LIMIT 500
                """, arguments: []),
            Probe(name: "AI recent inbox", hot: false, sql: """
                WITH recentInbox AS (SELECT id, accountId, bodyComplete, summaryBlurb, actionTag, cachedReply, date \
                FROM messageHeader WHERE isInInbox = 1 ORDER BY date DESC, id DESC LIMIT 100) \
                SELECT id, accountId FROM recentInbox WHERE bodyComplete = 1 \
                AND (summaryBlurb IS NULL OR summaryBlurb = '' OR actionTag IS NULL OR cachedReply IS NULL) \
                ORDER BY date DESC, id DESC
                """, arguments: []),
            Probe(name: "inbox member seed", hot: false, sql: """
                SELECT rowid, accountId, messageId FROM messageHeader WHERE isInInbox = 1
                """, arguments: []),
        ]
        let tape = BackfillCountTape()
        db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        _ = try SyncEngine.backfillProgressCounts(db, accountId: account)
        db.trace()
        let counts = tape.all.filter { $0.uppercased().contains("COUNT(") }
        #expect(counts.count == 3, "the progress read runs three counts: \(tape.all)")
        for (name, sql) in zip(["backfill progress total", "backfill progress settled", "backfill progress pending"], counts) {
            probes.append(Probe(name: name, hot: false, sql: sql, arguments: []))
        }
        return probes
    }

    /// A copy of `base` with or without the index, in `state`, in WAL mode.
    private static func prepareCensusFile(base: URL, state: State, withIndex: Bool, at url: URL) throws {
        try DBProof.removeDatabaseFiles(at: url)
        try FileManager.default.copyItem(at: base, to: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            if !withIndex || state == .staleBeforeIndex {
                try db.execute(sql: "DROP INDEX \(Config.index)")
            }
            switch state {
            case .migrationLeft: break
            case .none: try DBProof.apply(.none, to: db)
            case .fresh, .staleBeforeIndex: try DBProof.apply(.analyzed, to: db)
            }
            if withIndex && state == .staleBeforeIndex {
                try SyncEngine.createDeferredIndexes(db)
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try queue.close()
    }

    private static func plans(_ file: URL, _ probes: [Probe]) throws -> [String] {
        let pool = try DatabasePool(path: file.path, configuration: AppDatabase.makeConfiguration())
        defer { try? pool.close() }
        return try pool.read { db in
            try probes.map { probe in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + probe.sql, arguments: probe.arguments)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: " | ")
            }
        }
    }

    /// Steps through every row the read returns and counts them.
    @discardableResult
    private static func stepAll(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> Int {
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        var count = 0
        while try rows.next() != nil { count += 1 }
        return count
    }

    private struct CensusLine {
        let state: State
        let probe: Probe
        let planWith: String
        let planWithout: String
        let with: DBProof.RunCost
        let without: DBProof.RunCost

        var rowsWith: Int { with.resultRows }
        var rowsWithout: Int { without.resultRows }
        var switched: Bool { planWith.contains(Config.index) }
        var usesV40: Bool { planWith.contains(Config.v40Index) }
    }

    private static func census(base: URL, in directory: URL) throws -> [CensusLine] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probeQueue = try DatabaseQueue(path: base.path)
        let probes = try probeQueue.read { db in try Self.probes(db) }
        try probeQueue.close()
        var lines: [CensusLine] = []
        for state in State.allCases {
            let withFile = directory.appendingPathComponent("\(state.rawValue).with.sqlite")
            let withoutFile = directory.appendingPathComponent("\(state.rawValue).without.sqlite")
            try prepareCensusFile(base: base, state: state, withIndex: true, at: withFile)
            try prepareCensusFile(base: base, state: state, withIndex: false, at: withoutFile)
            let plansWith = try plans(withFile, probes)
            let plansWithout = try plans(withoutFile, probes)
            for (offset, probe) in probes.enumerated() {
                let sql = probe.sql
                let arguments = probe.arguments
                let variant = DBProof.Variant(run: { db in try Self.stepAll(db, sql, arguments) })
                lines.append(CensusLine(
                    state: state, probe: probe,
                    planWith: plansWith[offset], planWithout: plansWithout[offset],
                    with: try DBProof.measure(variant, kind: .read, file: withFile),
                    without: try DBProof.measure(variant, kind: .read, file: withoutFile)))
            }
            try DBProof.removeDatabaseFiles(at: withFile)
            try DBProof.removeDatabaseFiles(at: withoutFile)
        }
        return lines
    }

    // MARK: - Report

    private static func censusReport(_ lines: [CensusLine]) -> String {
        var out: [String] = []
        for state in State.allCases {
            out.append("== \(state.rawValue): \(state.label)")
            for line in lines where line.state == state {
                out.append("\(line.probe.name)\(line.probe.hot ? " [hot]" : "")")
                out.append("  with:    \(line.planWith)")
                out.append("  without: \(line.planWithout)")
                out.append("  pages read \(line.with.pagesRead) / \(line.without.pagesRead), "
                           + "VM steps \(line.with.vmSteps) / \(line.without.vmSteps), "
                           + "rows \(line.rowsWith) / \(line.rowsWithout) (with / without)")
            }
            out.append("")
        }
        let switched = lines.filter(\.switched)
        out.append("Reads whose plan names \(Config.index):")
        out.append(contentsOf: switched.isEmpty ? ["  none"] : switched.map {
            "  \($0.state.rawValue): \($0.probe.name)\($0.probe.hot ? " [hot]" : ""), pages read \($0.with.pagesRead) with, \($0.without.pagesRead) without"
        })
        let v40 = lines.filter(\.usesV40)
        out.append("Reads whose plan names \(Config.v40Index) (with \(Config.index) present):")
        out.append(contentsOf: v40.isEmpty ? ["  none"] : v40.map { "  \($0.state.rawValue): \($0.probe.name)" })
        return out.joined(separator: "\n") + "\n"
    }

    private static func sizeReport(_ size: Size, flags: [String]) -> String {
        func line(_ name: String) -> String {
            let pages = size.indexPages[name] ?? 0
            let bytes = pages * size.pageSize
            let perHeader = size.headers > 0 ? Double(bytes) / Double(size.headers) : 0
            let share = size.usedPages > 0 ? 100 * Double(pages) / Double(size.usedPages) : 0
            return "\(name): \(pages) pages, \(bytes) bytes, \(String(format: "%.1f", perHeader)) bytes per header, "
                + "\(String(format: "%.2f", share))% of the database"
        }
        return """
            Size on DBProof.Shape.large (the largest profile the harness has), vacuumed
            Headers: \(size.headers); page size \(size.pageSize); database \(size.usedPages) pages, \(size.usedPages * size.pageSize) bytes
            \(line(Config.index))
            \(line(Config.v40Index))
            Completeness flags:
            \(flags.map { "  " + $0 }.joined(separator: "\n"))

            """
    }

    private static func writeSummary(_ results: [DBProof.Result]) -> String {
        results.map { result in
            let old = result.old.wallMs.median
            let new = result.new.wallMs.median
            let ratio = old > 0 ? new / old : 0
            return "\(result.mode.name), \(result.statistics.label): median \(String(format: "%.3f", old)) ms old, "
                + "\(String(format: "%.3f", new)) ms new, new/old \(String(format: "%.2f", ratio)) (\(result.timeVerdict.rawValue)); "
                + "pages written \(result.old.count(\.pagesWritten).median) old, \(result.new.count(\.pagesWritten).median) new"
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - The proof

    @Test("Size, write cost and the hot reads' plans with messageHeader_backfillProgress")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        let root = output.appendingPathComponent(Config.unit, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = try Self.prepareBase(in: root)

        // 1. Size.
        let flags = try Self.flagCensus(base)
        let size = try Self.size(of: base, indexes: [Config.index, Config.v40Index],
                                 scratch: root.appendingPathComponent("size-scratch.sqlite"))
        try Self.sizeReport(size, flags: flags).write(
            to: root.appendingPathComponent("size.txt"), atomically: true, encoding: .utf8)
        #expect(flags.count >= 4, "the flags take several combinations: \(flags)")
        #expect((size.indexPages[Config.index] ?? 0) > 0, "the index has pages")

        // 1. Write cost: index dropped (old) against present (new).
        let results = try DBProof.compare(unit: "write-cost", modes: try Self.writeModes(base: base), base: base, in: root)
        try Self.writeSummary(results).write(
            to: root.appendingPathComponent("write-cost-summary.txt"), atomically: true, encoding: .utf8)
        for result in results {
            // Non-vacuity: each write maintains the index, so the new side writes more pages.
            #expect(result.new.count(\.pagesWritten).median > result.old.count(\.pagesWritten).median,
                    "\(result.mode.name), \(result.statistics.label): the write does not touch the index")
        }

        // 2 and 3. The plan census.
        let lines = try Self.census(base: base, in: root.appendingPathComponent("census", isDirectory: true))
        try Self.censusReport(lines).write(
            to: root.appendingPathComponent("census.txt"), atomically: true, encoding: .utf8)
        for line in lines {
            #expect(line.rowsWith == line.rowsWithout,
                    "\(line.state.rawValue) \(line.probe.name): the index changed the row count")
            if line.switched && line.probe.hot {
                #expect(line.with.pagesRead < line.without.pagesRead, """
                    \(line.state.rawValue) \(line.probe.name) switched to \(Config.index) and reads \
                    \(line.with.pagesRead) pages, \(line.without.pagesRead) without it
                    """)
            }
        }
        // Non-vacuity: the census sees the index where the progress counts use it.
        let settledFresh = lines.first { $0.state == .fresh && $0.probe.name == "backfill progress settled" }
        #expect(settledFresh?.switched == true, "the census does not see \(Config.index) in the settled count's plan")
    }
}
