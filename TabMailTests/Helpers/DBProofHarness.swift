/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
@testable import TabMail

/// Old-versus-new proof harness for a change to a database read or write.
///
/// A change that replaces a statement on a mail-sized table has to show, on a large
/// database, that the new statement is no slower and reads no more than the one it
/// replaces. This harness gives every such change the same three pieces:
///
/// 1. **One large database, built the production way.** `build(at:shape:seed:anchor:)`
///    runs `AppDatabase.runMigrations` and the production deferred-index build
///    (`SyncEngine.createDeferredIndexes`), then seeds several accounts from a seeded
///    generator: inbox, archive, sent and trash folders with a realistic inbox share,
///    read and unread mail, action tags in every triage bucket, user labels from
///    dense to very sparse, and most headers complete (`headerComplete`, most of those
///    with their body in, `bodyComplete`) with a share still incomplete, as on a synced
///    phone. `Shape.large` is just over 100,000 headers. Dates are offsets from `anchor`
///    (pass `Date()`), so nothing goes stale.
/// 2. **A measurer.** `compare(unit:modes:in:statistics:repeats:)` runs each mode's
///    old and new variant on its own copy of the database, once per statistics state
///    (no `sqlite_stat1`, and after the app's `ANALYZE`), each run on a FRESH
///    connection opened with the production configuration
///    (`AppDatabase.makeConfiguration`), old and new interleaved after one warm-up
///    each. Per run it records wall time, pages read (`SQLITE_DBSTATUS_CACHE_MISS`;
///    a fresh connection has an empty page cache, so every page the statement needs is
///    a miss), pages written (`SQLITE_DBSTATUS_CACHE_WRITE`, write modes), and rows
///    visited (`SQLITE_STMTSTATUS_VM_STEP` and `SQLITE_STMTSTATUS_FULLSCAN_STEP`, plus
///    sorts and automatic-index inserts, summed over every statement the variant runs).
///    A write mode runs on a fresh clone of the file per run and includes its commit.
///    It also counts the rows each side's result holds (or each side wrote), and
///    refuses a comparison in which either side's result is empty, unless the mode is
///    declared empty (`Mode.emptyResult`): two empty results are trivially equal and
///    prove nothing about the statements.
/// 3. **One plain-text report per unit** (`report.txt`), plus a `manifest.json` that
///    `Scripts/db-proof-mac.py` reads to measure the same files and statements with the
///    Mac's own `sqlite3` (`.stats on`).
///
/// The noise of a time comparison is the spread of the repeated OLD runs (p90 minus
/// p10): a new median above the old median by more than that spread is "slower".
/// Pages and rows visited do not vary between runs, so they compare exactly.
///
/// **How a unit uses it.** Add a suite that is enabled only when
/// `DBProof.outputDirectory` is set, declare the modes, call `compare`, and attach the
/// report. Run it with `TEST_RUNNER_TABMAIL_DB_PROOF_DIR=<dir>` (the `TEST_RUNNER_`
/// prefix is what carries an environment variable into the simulator-hosted test
/// process) and optionally `TEST_RUNNER_TABMAIL_DB_PROOF_REPEATS=<n>`. Then, on the Mac:
/// `python3 -I Scripts/db-proof-mac.py <dir>/<unit>`. Test tooling only: nothing here
/// ships in the app.
enum DBProof {

    // MARK: - Environment

    /// Where a gated proof suite writes its database files and report, or nil when the
    /// test runner was not asked for a proof (the suite then stays disabled).
    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment[Config.outputDirectoryKey],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Timed runs per variant, from the environment or `Config.defaultRepeats`.
    static var repeats: Int {
        guard let raw = ProcessInfo.processInfo.environment[Config.repeatsKey],
              let value = Int(raw), value > 0 else { return Config.defaultRepeats }
        return value
    }

    enum Config {
        static let outputDirectoryKey = "TABMAIL_DB_PROOF_DIR"
        static let repeatsKey = "TABMAIL_DB_PROOF_REPEATS"
        static let defaultRepeats = 9
        static let seed: UInt64 = 0x7AB_3A11
        static let secondsPerDay: Double = 86_400
        /// Days back the newest-weighted inbox, the archive and the trash reach.
        static let inboxMaxDays: Double = 730
        static let archiveMaxDays: Double = 2_920
        static let trashMaxDays: Double = 60
        /// Share of the inbox that is read, and of every other folder.
        static let inboxReadShare = 0.70
        static let otherReadShare = 0.98
        /// Action tags on inbox rows (the rest are untagged), and the share of
        /// non-inbox rows that still carry a tag.
        static let inboxTagShares: [(ActionTag, Double)] = [
            (.reply, 0.10), (.none, 0.40), (.archive, 0.30), (.delete, 0.15),
        ]
        static let leftoverTagShare = 0.02
        /// Share of headers whose header write has finished (`headerComplete`); the rest are
        /// still incomplete, as mail being synced is. Of the complete ones, the share whose
        /// body is in too (`bodyComplete`; the body queue fetches only complete headers, so an
        /// incomplete header never has its body).
        static let headerCompleteShare = 0.95
        static let bodyCompleteShare = 0.85
        /// Distinct senders the seed cycles through.
        static let senderCount: UInt64 = 400
    }

    // MARK: - Shape

    struct AccountShape: Sendable, Equatable {
        let provider: AccountProvider
        let headers: Int
        /// Share of this account's headers that are in its inbox.
        let inboxShare: Double
    }

    struct LabelShape: Sendable, Equatable {
        let providerLabelId: String
        /// Share of the account's inbox and archive rows that carry the label.
        let share: Double
        let isSystem: Bool
    }

    /// A non-inbox folder and its share of the headers outside the inbox (the last
    /// folder takes the remainder).
    struct FolderShape: Sendable, Equatable {
        let path: String
        let role: FolderRole
        let share: Double
    }

    struct Shape: Sendable, Equatable {
        let accounts: [AccountShape]
        let labels: [LabelShape]
        let otherFolders: [FolderShape]

        var totalHeaders: Int { accounts.reduce(0) { $0 + $1.headers } }

        static let defaultLabels: [LabelShape] = [
            LabelShape(providerLabelId: "proof_dense", share: 0.35, isSystem: false),
            LabelShape(providerLabelId: "proof_medium", share: 0.05, isSystem: false),
            LabelShape(providerLabelId: "proof_sparse", share: 0.005, isSystem: false),
            LabelShape(providerLabelId: "proof_rare", share: 0.0005, isSystem: false),
            LabelShape(providerLabelId: "IMPORTANT", share: 0.20, isSystem: true),
        ]

        static let defaultOtherFolders: [FolderShape] = [
            FolderShape(path: "Archive", role: .archive, share: 0.80),
            FolderShape(path: "Sent", role: .sent, share: 0.15),
            FolderShape(path: "Trash", role: .trash, share: 0.05),
        ]

        /// Just over 100,000 headers in four accounts: a large Gmail account with a
        /// big inbox, an IMAP account with a small inbox share, and two smaller ones
        /// that keep most of their mail in the inbox.
        static let large = Shape(
            accounts: [
                AccountShape(provider: .gmail, headers: 60_000, inboxShare: 0.25),
                AccountShape(provider: .imap, headers: 30_000, inboxShare: 0.10),
                AccountShape(provider: .outlook, headers: 12_000, inboxShare: 0.40),
                AccountShape(provider: .icloud, headers: 3_000, inboxShare: 0.60),
            ],
            labels: defaultLabels,
            otherFolders: defaultOtherFolders)

        /// The same proportions at one fiftieth of the size, for the harness's own tests.
        static let small = Shape(
            accounts: large.accounts.map {
                AccountShape(provider: $0.provider, headers: $0.headers / 50, inboxShare: $0.inboxShare)
            },
            labels: defaultLabels,
            otherFolders: defaultOtherFolders)
    }

    /// A colon-free, UUID-shaped account id, stable for a given index.
    static func accountId(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012ld", index)
    }

    // MARK: - Building the database

    /// Builds the proof database at `url`, replacing any file there. Deterministic for
    /// a given shape, seed and anchor. `migratedUpTo` stops the schema at that
    /// migration (a proof that measures a later migration runs it itself); nil runs
    /// the whole chain.
    static func build(
        at url: URL, shape: Shape, seed: UInt64 = Config.seed, anchor: Date, migratedUpTo: String? = nil
    ) throws {
        try removeDatabaseFiles(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        if let migratedUpTo {
            var migrator = DatabaseMigrator()
            AppDatabase.registerAllMigrations(on: &migrator)
            try migrator.migrate(queue, upTo: migratedUpTo)
        } else {
            try AppDatabase.runMigrations(on: queue)
        }
        try queue.write { db in
            try SyncEngine.createDeferredIndexes(db)
            var rng = SeededGenerator(seed: seed)
            for (index, accountShape) in shape.accounts.enumerated() {
                try seedAccount(index: index, shape: accountShape, labels: shape.labels,
                                otherFolders: shape.otherFolders, anchor: anchor, rng: &rng, db: db)
            }
        }
        try queue.close()
    }

    private static func seedAccount(
        index: Int,
        shape: AccountShape,
        labels: [LabelShape],
        otherFolders: [FolderShape],
        anchor: Date,
        rng: inout SeededGenerator,
        db: Database
    ) throws {
        var account = Account(
            emailAddress: "proof\(index)@example.com", displayName: "Proof \(index)",
            provider: shape.provider)
        account.id = accountId(index)
        try account.insert(db)

        // Gmail's system label only on the Gmail account.
        let accountLabels = labels.filter { !$0.isSystem || shape.provider == .gmail }
        let userLabels = accountLabels.map {
            UserLabel(accountId: account.id, providerLabelId: $0.providerLabelId,
                      name: $0.providerLabelId, isSystem: $0.isSystem)
        }
        for label in userLabels { try label.insert(db) }
        var labelMembers = Array(repeating: 0, count: userLabels.count)
        var firstLabelable: String?

        let inboxCount = Int((Double(shape.headers) * shape.inboxShare).rounded())
        var plan: [(FolderShape, Int)] = [(FolderShape(path: "INBOX", role: .inbox, share: 1), inboxCount)]
        var remaining = shape.headers - inboxCount
        let outside = remaining
        for (position, folder) in otherFolders.enumerated() {
            let count = position == otherFolders.count - 1
                ? remaining : Int((Double(outside) * folder.share).rounded(.down))
            plan.append((folder, count))
            remaining -= count
        }

        for (folderShape, count) in plan {
            let folder = Folder(name: folderShape.path, path: folderShape.path,
                                role: folderShape.role, accountId: account.id)
            try folder.insert(db)
            let isInbox = folderShape.role == .inbox
            let maxDays: Double = switch folderShape.role {
            case .inbox: Config.inboxMaxDays
            case .trash: Config.trashMaxDays
            default: Config.archiveMaxDays
            }
            let labelable = folderShape.role == .inbox || folderShape.role == .archive
            guard count > 0 else { continue }
            for uid in 1...count {
                // Newest-weighted for the inbox, flatter elsewhere.
                let u = Double.random(in: 0..<1, using: &rng)
                let daysAgo = maxDays * (isInbox ? u * u : u.squareRoot() * u)
                let date = anchor.addingTimeInterval(-daysAgo * Config.secondsPerDay)
                let sender = rng.next() % Config.senderCount
                var header = MessageHeader(
                    messageId: String(uid),
                    subject: "Subject \(uid)",
                    from: "Sender \(sender) <sender\(sender)@example.com>",
                    fromAddress: "sender\(sender)@example.com",
                    to: "proof\(index)@example.com",
                    date: date,
                    snippet: "Snippet \(uid)",
                    folderId: folder.id,
                    accountId: account.id,
                    folderPath: folderShape.path,
                    isInInbox: isInbox)
                header.rfc822MessageId = "<p\(index)-\(folderShape.path)-\(uid)@example.com>"
                header.isRead = Double.random(in: 0..<1, using: &rng)
                    < (isInbox ? Config.inboxReadShare : Config.otherReadShare)
                header.actionTag = pickTag(isInbox: isInbox, rng: &rng)
                header.tagSortOrder = header.actionTag?.sortOrder ?? header.tagSortOrder
                if header.actionTag != nil { header.actionTagSetAt = date }
                header.headerComplete = Double.random(in: 0..<1, using: &rng) < Config.headerCompleteShare
                let bodyDraw = Double.random(in: 0..<1, using: &rng)
                header.bodyComplete = header.headerComplete && bodyDraw < Config.bodyCompleteShare
                try header.insert(db)

                guard labelable else { continue }
                if firstLabelable == nil { firstLabelable = header.id }
                for (position, label) in accountLabels.enumerated()
                where Double.random(in: 0..<1, using: &rng) < label.share {
                    try MessageUserLabel(messageId: header.id, userLabelId: userLabels[position].id).insert(db)
                    labelMembers[position] += 1
                }
            }
        }
        // Every label has at least one member, so even the rarest label is a real,
        // non-empty filter on a small build.
        if let firstLabelable {
            for (position, members) in labelMembers.enumerated() where members == 0 {
                try MessageUserLabel(messageId: firstLabelable, userLabelId: userLabels[position].id).insert(db)
            }
        }
    }

    private static func pickTag(isInbox: Bool, rng: inout SeededGenerator) -> ActionTag? {
        let u = Double.random(in: 0..<1, using: &rng)
        if !isInbox {
            guard u < Config.leftoverTagShare else { return nil }
            return u < Config.leftoverTagShare / 2 ? .archive : .delete
        }
        var edge = 0.0
        for (tag, share) in Config.inboxTagShares {
            edge += share
            if u < edge { return tag }
        }
        return nil
    }

    /// A content summary of the database: per account, folder, read state, tag and
    /// completion state, the row count and sums over the UIDs, subjects and dates; then per
    /// label its member count. Two builds with the same shape, seed and anchor give the
    /// same summary.
    static func fingerprint(of url: URL) throws -> String {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            let headers = try Row.fetchAll(db, sql: """
                SELECT accountId, folderId, isRead, COALESCE(actionTag, '-') AS tag, tagSortOrder,
                       headerComplete, bodyComplete,
                       count(*) AS n, sum(CAST(messageId AS INTEGER)) AS uids,
                       sum(length(subject)) AS subjects, sum(CAST(strftime('%s', date) AS INTEGER)) AS dates
                FROM messageHeader
                GROUP BY accountId, folderId, isRead, tag, tagSortOrder, headerComplete, bodyComplete
                ORDER BY accountId, folderId, isRead, tag, tagSortOrder, headerComplete, bodyComplete
                """)
            let labels = try Row.fetchAll(db, sql: """
                SELECT userLabelId, count(*) AS n FROM messageUserLabel
                GROUP BY userLabelId ORDER BY userLabelId
                """)
            return (headers + labels).map(\.description).joined(separator: "\n")
        }
    }

    // MARK: - Statistics states

    enum Statistics: String, CaseIterable, Sendable {
        /// No planner statistics: `sqlite_stat1` (and `sqlite_stat4`) emptied.
        case none
        /// After the app's maintenance `ANALYZE` (`runRefreshPlannerStatisticsIfStale`).
        case analyzed

        var label: String {
            switch self {
            case .none: return "no sqlite_stat1"
            case .analyzed: return "after the app's ANALYZE"
            }
        }
    }

    static func apply(_ statistics: Statistics, to db: Database) throws {
        switch statistics {
        case .none:
            for table in ["sqlite_stat1", "sqlite_stat4"] where try db.tableExists(table) {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        case .analyzed:
            // The same statement `SyncEngine.runRefreshPlannerStatisticsIfStale` runs.
            try db.execute(sql: "ANALYZE")
        }
    }

    // MARK: - Modes

    enum Kind: String, Sendable {
        /// Runs inside a read transaction on the shared variant file.
        case read
        /// Runs in one write transaction, commit included, on a fresh clone per run.
        case write
    }

    /// One side of a comparison.
    struct Variant: Sendable {
        /// Applied once to this variant's copy of the database before statistics are
        /// set, untimed (for example the index the new code relies on, or dropping it).
        var setupSQL: [String] = []
        /// The timed statements. A read statement's rows are all stepped through and
        /// counted; a write statement counts the rows it changed.
        var sql: [String] = []
        /// A timed Swift body instead of `sql`, for code that cannot be written as plain
        /// SQL. It returns the number of rows its result holds (a read) or it wrote (a
        /// write): the rows the code under test gets, not a count statement's one row. The
        /// Mac script cannot run it; prefer `sql`.
        var run: (@Sendable (Database) throws -> Int)? = nil
    }

    struct Mode: Sendable {
        let name: String
        let kind: Kind
        let old: Variant
        let new: Variant
        /// The mode's result is empty on purpose (a lookup of a missing row, say).
        /// `compare` refuses a mode whose old or new result is empty unless this is set,
        /// and one whose old or new result is not empty when it is.
        var emptyResult = false
    }

    // MARK: - Measurement

    /// What one timed run of a variant cost.
    struct RunCost: Sendable, Equatable {
        var wallMs: Double = 0
        var pagesRead = 0
        var pagesWritten = 0
        var vmSteps = 0
        var fullscanSteps = 0
        var sorts = 0
        var autoindexInserts = 0
        /// Rows the variant's result held (a read) or it wrote (a write).
        var resultRows = 0
    }

    struct Sample: Sendable {
        let runs: [RunCost]

        var wallMs: Distribution { Distribution(runs.map(\.wallMs)) }
        /// Counts that should not vary run to run; the median, plus whether they varied.
        func count(_ key: KeyPath<RunCost, Int>) -> (median: Int, varied: Bool) {
            let values = runs.map { $0[keyPath: key] }.sorted()
            guard let first = values.first, let last = values.last else { return (0, false) }
            return (values[values.count / 2], first != last)
        }
    }

    struct Distribution: Sendable {
        let sorted: [Double]
        init(_ values: [Double]) { sorted = values.sorted() }
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        var median: Double { percentile(0.5) }
        var p10: Double { percentile(0.1) }
        var p90: Double { percentile(0.9) }
        var spread: Double { p90 - p10 }
    }

    enum TimeVerdict: String, Sendable {
        case slower = "SLOWER"
        case withinNoise = "within noise"
        case faster = "faster"
    }

    struct Result: Sendable {
        let mode: Mode
        let statistics: Statistics
        let old: Sample
        let new: Sample

        var timeVerdict: TimeVerdict { DBProof.timeVerdict(old: old.wallMs, new: new.wallMs) }
    }

    /// The new median against the old median, with the spread of the repeated old runs
    /// as the noise band.
    static func timeVerdict(old: Distribution, new: Distribution) -> TimeVerdict {
        if new.median > old.median + old.spread { return .slower }
        if new.median < old.median - old.spread { return .faster }
        return .withinNoise
    }

    /// Builds the large database into `directory/proof-base.sqlite` and returns its URL.
    static func prepareBase(in directory: URL, shape: Shape = .large) throws -> URL {
        let url = directory.appendingPathComponent("proof-base.sqlite")
        try build(at: url, shape: shape, anchor: Date())
        return url
    }

    /// Runs every mode's old and new variant under each statistics state, writes
    /// `directory/<unit>/report.txt` and `manifest.json`, and returns the results.
    static func compare(
        unit: String,
        modes: [Mode],
        base: URL,
        in directory: URL,
        statistics: [Statistics] = Statistics.allCases,
        repeats: Int = DBProof.repeats
    ) throws -> [Result] {
        let unitDirectory = directory.appendingPathComponent(unit, isDirectory: true)
        try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
        var results: [Result] = []
        var entries: [ManifestEntry] = []
        for mode in modes {
            for state in statistics {
                let (oldFile, newFile) = variantFiles(unit: unit, mode: mode.name, statistics: state, in: directory)
                try prepareVariantFile(base: base, setupSQL: mode.old.setupSQL, statistics: state, at: oldFile)
                try prepareVariantFile(base: base, setupSQL: mode.new.setupSQL, statistics: state, at: newFile)
                // One warm-up each, then old and new interleaved so drift hits both.
                let oldWarmUp = try measure(mode.old, kind: mode.kind, file: oldFile)
                let newWarmUp = try measure(mode.new, kind: mode.kind, file: newFile)
                try checkResultRows(mode: mode, statistics: state,
                                    old: oldWarmUp.resultRows, new: newWarmUp.resultRows)
                var oldRuns: [RunCost] = []
                var newRuns: [RunCost] = []
                for _ in 0..<repeats {
                    oldRuns.append(try measure(mode.old, kind: mode.kind, file: oldFile))
                    newRuns.append(try measure(mode.new, kind: mode.kind, file: newFile))
                }
                results.append(Result(mode: mode, statistics: state,
                                      old: Sample(runs: oldRuns), new: Sample(runs: newRuns)))
                entries.append(ManifestEntry(
                    mode: mode.name, kind: mode.kind.rawValue, statistics: state.rawValue,
                    old: ManifestVariant(file: oldFile.path, sql: mode.old.sql, swiftOnly: mode.old.run != nil),
                    new: ManifestVariant(file: newFile.path, sql: mode.new.sql, swiftOnly: mode.new.run != nil)))
            }
        }
        let manifest = Manifest(unit: unit, repeats: repeats, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: unitDirectory.appendingPathComponent("manifest.json"))
        let header = try reportHeader(unit: unit, base: base, repeats: repeats)
        try (header + report(results)).write(
            to: unitDirectory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        return results
    }

    /// The old and new variant files `compare` leaves for `mode` under `statistics`, for a
    /// proof that reads them afterwards (a query plan, say).
    static func variantFiles(unit: String, mode: String, statistics: Statistics, in directory: URL)
        -> (old: URL, new: URL) {
        let stem = directory.appendingPathComponent(unit, isDirectory: true)
            .appendingPathComponent("\(fileSafe(mode))-\(statistics.rawValue)")
        return (stem.appendingPathExtension("old.sqlite"), stem.appendingPathExtension("new.sqlite"))
    }

    /// Two empty results compare as equal whatever the statements cost to find nothing, so a
    /// mode is measured only when both sides return rows, or, declared empty, when neither does.
    static func checkResultRows(mode: Mode, statistics: Statistics, old: Int, new: Int) throws {
        let accepted = mode.emptyResult ? (old == 0 && new == 0) : (old > 0 && new > 0)
        guard accepted else {
            throw DBProofError.resultRows(mode: mode.name, statistics: statistics, old: old, new: new,
                                          declaredEmpty: mode.emptyResult)
        }
    }

    /// Copies `base` to `url`, applies the variant's setup and the statistics state, and
    /// leaves the file in WAL mode, as the app's database is.
    static func prepareVariantFile(base: URL, setupSQL: [String], statistics: Statistics, at url: URL) throws {
        try removeDatabaseFiles(at: url)
        try FileManager.default.copyItem(at: base, to: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.inTransaction {
                for sql in setupSQL { try db.execute(sql: sql) }
                try apply(statistics, to: db)
                return .commit
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try queue.close()
    }

    /// One timed run of `variant` on a fresh connection.
    static func measure(_ variant: Variant, kind: Kind, file: URL) throws -> RunCost {
        switch kind {
        case .read:
            let pool = try DatabasePool(path: file.path, configuration: AppDatabase.makeConfiguration())
            defer { try? pool.close() }
            return try pool.read { db in try timed(variant, db: db) }
        case .write:
            // A fresh clone per run (APFS clones the file, so this is cheap and
            // untimed): every run writes the same starting state.
            let scratch = file.deletingLastPathComponent()
                .appendingPathComponent("run-\(UUID().uuidString).sqlite")
            try FileManager.default.copyItem(at: file, to: scratch)
            defer { try? removeDatabaseFiles(at: scratch) }
            let pool = try DatabasePool(path: scratch.path, configuration: AppDatabase.makeConfiguration())
            defer { try? pool.close() }
            return try pool.writeWithoutTransaction { db in
                try timed(variant, db: db, inWriteTransaction: true)
            }
        }
    }

    private static func timed(_ variant: Variant, db: Database, inWriteTransaction: Bool = false) throws -> RunCost {
        guard let handle = db.sqliteConnection else { throw DBProofError.noConnection }
        // Load the schema before the counters start, so they cover only the variant.
        _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
        let counters = StatementCounters()
        var current: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &current, &highwater, 1)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_WRITE, &current, &highwater, 1)
        let context = Unmanaged.passUnretained(counters).toOpaque()
        sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            let counters = Unmanaged<StatementCounters>.fromOpaque(context).takeUnretainedValue()
            counters.add(OpaquePointer(statement))
            return 0
        }, context)
        defer { sqlite3_trace_v2(handle, 0, nil, nil) }

        let start = DispatchTime.now().uptimeNanoseconds
        var resultRows = 0
        if inWriteTransaction {
            try db.inTransaction {
                resultRows = try runBody(variant, db: db)
                return .commit
            }
        } else {
            resultRows = try runBody(variant, db: db)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        var cost = withExtendedLifetime(counters) { counters.cost }
        cost.wallMs = Double(elapsed) / 1_000_000
        cost.resultRows = resultRows
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &current, &highwater, 0)
        cost.pagesRead = Int(current)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_WRITE, &current, &highwater, 0)
        cost.pagesWritten = Int(current)
        return cost
    }

    /// Runs the variant and returns the rows its result held (a read) or it wrote (a write).
    private static func runBody(_ variant: Variant, db: Database) throws -> Int {
        if let run = variant.run {
            return try run(db)
        }
        var resultRows = 0
        for sql in variant.sql {
            let statement = try db.makeStatement(sql: sql)
            if statement.isReadonly {
                let rows = try Row.fetchCursor(statement)
                while try rows.next() != nil { resultRows += 1 }
            } else {
                try statement.execute()
                resultRows += db.changesCount
            }
        }
        return resultRows
    }

    /// Sums the per-statement counters SQLite keeps, read (and reset) as each
    /// statement finishes.
    private final class StatementCounters {
        private(set) var cost = RunCost()

        func add(_ statement: OpaquePointer) {
            cost.vmSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
            cost.fullscanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1))
            cost.sorts += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 1))
            cost.autoindexInserts += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_AUTOINDEX, 1))
        }
    }

    enum DBProofError: Error, CustomStringConvertible {
        case noConnection
        case resultRows(mode: String, statistics: Statistics, old: Int, new: Int, declaredEmpty: Bool)

        var description: String {
            switch self {
            case .noConnection:
                return "no SQLite connection handle"
            case let .resultRows(mode, statistics, old, new, declaredEmpty):
                let rule = declaredEmpty
                    ? "is declared empty, so both sides must return no rows"
                    : "compares nothing unless both sides return rows (declare an intended empty result with emptyResult)"
                return "\(mode), \(statistics.label): old returned \(old) rows, new \(new); the mode \(rule)"
            }
        }
    }

    // MARK: - Report

    private struct ManifestVariant: Encodable {
        let file: String
        let sql: [String]
        let swiftOnly: Bool
    }

    private struct ManifestEntry: Encodable {
        let mode: String
        let kind: String
        let statistics: String
        let old: ManifestVariant
        let new: ManifestVariant
    }

    private struct Manifest: Encodable {
        let unit: String
        let repeats: Int
        let entries: [ManifestEntry]
    }

    private static func reportHeader(unit: String, base: URL, repeats: Int) throws -> String {
        let queue = try DatabaseQueue(path: base.path)
        defer { try? queue.close() }
        let (version, accounts, labels) = try queue.read { db in
            (try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?",
             try Row.fetchAll(db, sql: """
                SELECT accountId, count(*) AS headers, sum(isInInbox) AS inbox, sum(isRead = 0) AS unread,
                       sum(actionTag IS NOT NULL AND isInInbox = 1) AS taggedInbox
                FROM messageHeader GROUP BY accountId ORDER BY accountId
                """),
             try Row.fetchAll(db, sql: """
                SELECT userLabelId, count(*) AS members FROM messageUserLabel
                GROUP BY userLabelId ORDER BY userLabelId
                """))
        }
        let accountLines = accounts.map {
            "  \($0["accountId"] as String? ?? "?"): \($0["headers"] as Int? ?? 0) headers, \($0["inbox"] as Int? ?? 0) in the inbox (\($0["taggedInbox"] as Int? ?? 0) tagged), \($0["unread"] as Int? ?? 0) unread"
        }
        let labelLines = labels.map { "  \($0["userLabelId"] as String? ?? "?"): \($0["members"] as Int? ?? 0) messages" }
        return """
            Database proof: \(unit)
            Side: simulator (the app's SQLite \(version), production connection configuration)
            Database: \(base.path)
            \(accountLines.joined(separator: "\n"))
            Labels:
            \(labelLines.joined(separator: "\n"))
            Runs: \(repeats) timed per variant after one warm-up, old and new interleaved, each on a fresh connection.
            Noise: the spread (p90 - p10) of the repeated old runs. Pages and rows visited compare exactly.

            """
    }

    /// The plain-text table, one block per mode and statistics state.
    static func report(_ results: [Result]) -> String {
        var lines: [String] = []
        for result in results {
            lines.append("== \(result.mode.name) (\(result.mode.kind.rawValue)), \(result.statistics.label)")
            lines.append(row("", "old", "new", "verdict"))
            let old = result.old.wallMs
            let new = result.new.wallMs
            lines.append(row("median ms", format(old.median), format(new.median), result.timeVerdict.rawValue))
            lines.append(row("p90 ms", format(old.p90), format(new.p90), ""))
            lines.append(row("old spread ms", format(old.spread), "", ""))
            lines.append(row("result rows", String(result.old.count(\.resultRows).median),
                             String(result.new.count(\.resultRows).median),
                             result.mode.emptyResult ? "declared empty" : ""))
            let counts: [(String, KeyPath<RunCost, Int>)] = [
                ("pages read", \.pagesRead), ("pages written", \.pagesWritten),
                ("VM steps", \.vmSteps), ("full-scan steps", \.fullscanSteps),
                ("sorts", \.sorts), ("autoindex inserts", \.autoindexInserts),
            ]
            for (label, key) in counts {
                let o = result.old.count(key)
                let n = result.new.count(key)
                let verdict = n.median > o.median ? "MORE" : (n.median < o.median ? "fewer" : "same")
                let varied = (o.varied || n.varied) ? " (varied between runs)" : ""
                lines.append(row(label, String(o.median), String(n.median), verdict + varied))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ label: String, _ old: String, _ new: String, _ verdict: String) -> String {
        label.padding(toLength: 20, withPad: " ", startingAt: 0)
            + old.leftPadded(to: 12) + new.leftPadded(to: 12) + "  " + verdict
    }

    private static func format(_ ms: Double) -> String { String(format: "%.3f", ms) }

    private static func fileSafe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Removes a database file and its WAL and shared-memory files.
    static func removeDatabaseFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Seeded generator

    /// SplitMix64: a small, fast generator that gives the same sequence for a seed.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
