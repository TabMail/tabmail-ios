/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum StorageEstimator {
    /// Minimum messages per folder that are never pruned
    static let floorPerFolder = 50

    /// Global storage budget key in UserDefaults
    static let storageBudgetKey = "globalStorageBudgetMB"

    /// Default global storage budget: unlimited
    static let defaultBudgetMB = Int.max

    /// Get the user-configured global storage budget in MB.
    static var budgetMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: storageBudgetKey)
            return val > 0 ? val : defaultBudgetMB
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageBudgetKey)
        }
    }

    /// Measure disk usage of our stored data (GRDB + FTS) in Application Support.
    /// Excludes system-managed caches (Apple Intelligence e5rt, WebKit, etc.) that iOS
    /// can purge independently and that don't count toward our storage budget.
    static func totalSizeMB() -> Double {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        return allocatedSizeMB(of: appSupport)
    }

    /// Recursively measure allocated disk size of a directory in MB. Not private
    /// since #1437: tests measure their own folder with it.
    static func allocatedSizeMB(of directory: URL) -> Double {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }

        var totalBytes: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let allocated = values.totalFileAllocatedSize else { continue }
            totalBytes += UInt64(allocated)
        }
        return Double(totalBytes) / (1024.0 * 1024.0)
    }

    /// The allocated size of the WAL file of the database at `path`, in bytes,
    /// measured as `allocatedSizeMB` measures it; 0 when there is none.
    static func walFileBytes(ofDatabaseAt path: String) -> Int64 {
        let url = URL(fileURLWithPath: path + "-wal")
        guard let allocated = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else {
            return 0
        }
        return Int64(allocated)
    }

    /// `percent` of the Email Index Limit `budgetMB`, in bytes. nil when no limit is
    /// set (the budget is `Int.max`). A `Double`, so a large limit cannot overflow.
    static func limitBytes(percent: Int, ofBudgetMB budgetMB: Int) -> Double? {
        guard budgetMB != Int.max else { return nil }
        return Double(budgetMB) * 1024 * 1024 * Double(percent) / 100
    }

    /// One database's pages, in bytes: all of them, and the empty ones on its
    /// freelist. A delete moves the pages it frees to the freelist and never shrinks
    /// the file (auto_vacuum is off, and the app runs VACUUM only after "Delete All
    /// Email Index Data"), so the file's size cannot show what a delete freed, and
    /// the empty pages show it as soon as the delete commits. Read from the database
    /// header, no table. nil if SQLite returns no row.
    struct PageTotals: Equatable, Sendable {
        let allBytes: Int64
        let emptyBytes: Int64

        static func + (lhs: PageTotals, rhs: PageTotals) -> PageTotals {
            PageTotals(allBytes: lhs.allBytes + rhs.allBytes, emptyBytes: lhs.emptyBytes + rhs.emptyBytes)
        }

        static func read(_ db: Database) throws -> PageTotals? {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT pageCount.page_count * pageSize.page_size AS allBytes,
                    freePages.freelist_count * pageSize.page_size AS emptyBytes
                FROM pragma_page_count() AS pageCount, pragma_freelist_count() AS freePages,
                    pragma_page_size() AS pageSize
                """) else { return nil }
            return PageTotals(allBytes: row["allBytes"], emptyBytes: row["emptyBytes"])
        }
    }

    /// Where a measure of the space the Email Index Limit counts comes from: the
    /// space Settings reports (`totalSizeMB`, a walk of the storage folder), the WAL
    /// files of the email and search databases, and the page totals of the two
    /// databases together. Tests pass their own.
    struct SpaceSource: Sendable {
        let reportedBytes: @Sendable () -> Int64
        let walBytes: @Sendable () async -> Int64
        let pageTotals: @Sendable () async -> PageTotals?

        /// The app's: the walk Settings reports, and the email database `pool` with
        /// the search database. nil page totals when either cannot be read, e.g.
        /// before the search database is open.
        static func app(pool: PrioritizedDatabase) -> SpaceSource {
            SpaceSource(
                reportedBytes: { Int64(totalSizeMB() * 1024 * 1024) },
                walBytes: { walFileBytes(ofDatabaseAt: pool.pool.path) + (await SearchIndex.shared.walFileBytes()) },
                pageTotals: {
                    let email: PageTotals?
                    do {
                        email = try await pool.read { db in try PageTotals.read(db) }
                    } catch {
                        email = nil
                    }
                    guard let email, let search = await SearchIndex.shared.pageTotals() else { return nil }
                    return email + search
                })
        }
    }

    /// The space the Email Index Limit counts (#1437): the space Settings reports,
    /// less the WAL files of the email and search databases, less their empty pages,
    /// which later writes fill before either file grows. A delete writes to the WAL
    /// and frees pages, and neither shrinks a file: the WAL keeps its size until a
    /// truncating checkpoint (throttled), the database until a VACUUM. A run (a
    /// storage prune, or a run of the older-mail walk) walks the storage folder and
    /// reads the WAL files' size once, at its start (`start`), never inside a write.
    /// `usedBytes()` then re-reads only the page totals: the space reported at the
    /// start, less the WAL files then, less the empty pages now, plus any pages the
    /// databases gained since. With none gained, a delete lowers it as soon as it
    /// commits. Pages the WAL adds past the end of a database file are left out until
    /// a checkpoint copies them into it: the measure can then be low by their size,
    /// so a prune deletes less, never more.
    struct SpaceMeter: Sendable {
        let source: SpaceSource
        let reportedBytes: Int64
        let walBytes: Int64
        let startPages: PageTotals

        /// nil when the page totals cannot be read.
        static func start(_ source: SpaceSource) async -> SpaceMeter? {
            guard let pages = await source.pageTotals() else { return nil }
            let reported = source.reportedBytes()
            return SpaceMeter(source: source, reportedBytes: reported, walBytes: await source.walBytes(), startPages: pages)
        }

        /// The space used when the run started.
        var startBytes: Int64 { reportedBytes - walBytes - startPages.emptyBytes }

        /// The space used now. nil when the page totals cannot be read.
        func usedBytes() async -> Int64? {
            guard let now = await source.pageTotals() else { return nil }
            return reportedBytes - walBytes - now.emptyBytes + (now.allBytes - startPages.allBytes)
        }
    }

    /// The older-mail walk's storage check, for one walk run (#1437). The walk loads
    /// no more mail once the space used reaches the storage prune's target,
    /// `SyncConfig.storagePruneTargetPercent` of the limit, so it stops where the
    /// prune stops and never loads mail the next prune deletes. `start` walks the
    /// storage folder once for the run; `reached()` re-reads only the page totals. A
    /// measure that cannot be read counts as reached: the walk loads nothing it
    /// cannot check, and its next run checks again.
    ///
    /// *Superseded (#1437):* `isOverBudget()`, a walk of the storage folder against
    /// 100% of the limit before every folder pick, gated both the walk and the prune.
    struct WalkCheck: Sendable {
        let meter: SpaceMeter?
        let targetBytes: Double

        /// nil when no limit is set, without walking the folder.
        static func start(_ source: SpaceSource) async -> WalkCheck? {
            guard let targetBytes = limitBytes(
                percent: SyncConfig.storagePruneTargetPercent, ofBudgetMB: budgetMB) else { return nil }
            return WalkCheck(meter: await SpaceMeter.start(source), targetBytes: targetBytes)
        }

        func reached() async -> Bool {
            guard let used = await meter?.usedBytes() else { return true }
            return Double(used) >= targetBytes
        }
    }

    /// Which run of the storage prune this is, and so where it starts: the
    /// background processing job (`overnight`) starts lower than the foreground
    /// maintenance task (`foreground`), so most of the deleting happens while the
    /// phone is idle. Both stop at `SyncConfig.storagePruneTargetPercent`.
    enum PruneGate: Sendable {
        case overnight
        case foreground

        var startPercent: Int {
            switch self {
            case .overnight: SyncConfig.storagePruneOvernightStartPercent
            case .foreground: SyncConfig.storagePruneForegroundStartPercent
            }
        }
    }
}
