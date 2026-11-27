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

    /// The allocated size of the database file at `path` and of its WAL file, in
    /// bytes, measured as `allocatedSizeMB` measures them; a file that is not there
    /// counts 0.
    static func databaseFileBytes(ofDatabaseAt path: String) -> Int64 {
        [path, path + "-wal"].reduce(0) { total, file in
            let allocated = try? URL(fileURLWithPath: file)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            return total + Int64(allocated ?? 0)
        }
    }

    /// `percent` of the Email Index Limit `budgetMB`, in bytes. nil when no limit is
    /// set (the budget is `Int.max`). A `Double`, so a large limit cannot overflow.
    static func limitBytes(percent: Int, ofBudgetMB budgetMB: Int) -> Double? {
        guard budgetMB != Int.max else { return nil }
        return Double(budgetMB) * 1024 * 1024 * Double(percent) / 100
    }

    /// One database's pages, in bytes: all of them, and the empty ones on its
    /// freelist. A delete moves the pages it frees to the freelist and does not
    /// shrink the file (empty pages go back to the file system only in the overnight
    /// job's steps and the Optimize Storage tap's, on a database the user has upgraded, ADR-IOS-121), so the file's size cannot show what a delete freed,
    /// and the empty pages show it as soon as the delete commits. Read from the
    /// database header, no table. nil if SQLite returns no row.
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
    /// space Settings reports (`totalSizeMB`, a walk of the storage folder), the size
    /// on disk of the email and search database files and their WAL files, and the
    /// page totals of the two databases together. Tests pass their own.
    struct SpaceSource: Sendable {
        let reportedBytes: @Sendable () -> Int64
        let databaseFileBytes: @Sendable () async -> Int64
        let pageTotals: @Sendable () async -> PageTotals?

        /// The app's: the walk Settings reports, and the email database `pool` with
        /// the search database. nil page totals when either cannot be read, e.g.
        /// before the search database is open.
        static func app(pool: PrioritizedDatabase) -> SpaceSource {
            SpaceSource(
                reportedBytes: { Int64(totalSizeMB() * 1024 * 1024) },
                databaseFileBytes: {
                    StorageEstimator.databaseFileBytes(ofDatabaseAt: pool.pool.path)
                        + (await SearchIndex.shared.databaseFileBytes())
                },
                pageTotals: {
                    guard let email = emailPageTotals(pool),
                          let search = await SearchIndex.shared.pageTotals() else { return nil }
                    return email + search
                })
        }

        /// The email database's page totals, read with `PrioritizedDatabase.read`'s
        /// synchronous overload. Not `async` on purpose: from an async context Swift
        /// binds the awaited overload, which runs the notification extension's staging
        /// merge before it reads, and this reads the database header alone.
        private static func emailPageTotals(_ pool: PrioritizedDatabase) -> PageTotals? {
            try? pool.read { db in try PageTotals.read(db) }
        }
    }

    /// The space the Email Index Limit counts (#1437): the space Settings reports,
    /// less the space in the email and search databases that holds no data, i.e. their
    /// empty pages and their WAL files. A run (a storage prune, or a run of the
    /// older-mail walk) walks the storage folder and reads the size on disk of the two
    /// database files and their WAL files once, at its start (`start`), never inside a
    /// write: the space reported less those files is everything else the folder holds.
    /// `usedBytes()` then re-reads only the page totals and adds the data the two
    /// databases hold now, their logical size (`page_count` x `page_size`, which
    /// counts the pages still in a WAL) less their empty pages. A delete lowers it as
    /// soon as it commits, though it shrinks neither file (the WAL keeps its size until
    /// a truncating checkpoint, the database until a VACUUM), and a checkpoint or a
    /// VACUUM, which move bytes between the files and change no data, leave it as it
    /// was. It is exact but for the other files in the folder changing during the run,
    /// and a checkpoint landing between the start's reads.
    struct SpaceMeter: Sendable {
        let source: SpaceSource
        /// The space Settings reported at the run's start.
        let reportedBytes: Int64
        /// The two database files and their WAL files on disk at the run's start.
        let databaseFileBytes: Int64
        let startPages: PageTotals

        /// nil when the page totals cannot be read.
        static func start(_ source: SpaceSource) async -> SpaceMeter? {
            guard let pages = await source.pageTotals() else { return nil }
            let reported = source.reportedBytes()
            return SpaceMeter(
                source: source, reportedBytes: reported,
                databaseFileBytes: await source.databaseFileBytes(), startPages: pages)
        }

        /// The space used when the run started.
        var startBytes: Int64 { usedBytes(at: startPages) }

        /// The space used now. nil when the page totals cannot be read.
        func usedBytes() async -> Int64? {
            guard let now = await source.pageTotals() else { return nil }
            return usedBytes(at: now)
        }

        /// Everything in the folder but the two databases, as at the run's start, plus
        /// the data the databases hold at `pages`.
        private func usedBytes(at pages: PageTotals) -> Int64 {
            reportedBytes - databaseFileBytes + pages.allBytes - pages.emptyBytes
        }
    }

    /// The older-mail walk's storage check, for one walk run (#1437). The walk picks
    /// no more folders once the space used reaches the storage prune's target,
    /// `SyncConfig.storagePruneTargetPercent` of the limit, so it stops where the
    /// prune stops. It checks at each folder pick, as the check it replaced did: a
    /// folder once picked is walked until it is complete or the run's time is up, so
    /// a run can carry the space used past the target by up to that folder's mail,
    /// which the next prune then deletes. `start` walks the storage folder once for
    /// the run; `reached()` re-reads only the page totals. A measure that cannot be
    /// read counts as reached: the walk loads nothing it cannot check, and its next
    /// run checks again.
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
