/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The databases' one-time upgrade, and giving their empty pages back (ADR-IOS-121, #1450)
//
// A delete moves the pages it frees to the database's freelist and never shrinks
// the file. On `auto_vacuum = INCREMENTAL` (`DatabaseVacuum`) those pages can be
// given back to the device in short steps. A new install starts on it. An install
// from before this change is on NONE, and SQLite changes that only with a `VACUUM`
// of the whole database: the one-time upgrade, which the user starts
// (`DatabaseUpgrade`) and the app never runs by itself.
//
// - The upgrade (`runDatabaseUpgrade`): each database still on NONE, the email
//   database first, then the search database, gets one `VACUUM`
//   (`DatabaseVacuum.switchToIncremental`), when the device has
//   `SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple` times the database's pages
//   less its empty pages free (what the `VACUUM` copies, twice: its temporary copy
//   and the WAL), and then a TRUNCATE checkpoint. It runs in `DatabaseUpgrade`'s upgrade
//   mode: the spinner over the app, polling and the body, AI and embedding queues
//   paused; any other write waits behind it. Measured on a Mac at 1.1 GB: the
//   `VACUUM` 10-15 s, the TRUNCATE checkpoint after it 4-10 s, more on a phone. If
//   the databases are suspended while the `VACUUM` builds its copy (the app's
//   background time ran out), the suspension interrupts it and it rolls back; the
//   upgrade starts it again when the app returns. Once it writes the copy back into
//   the database file (about the last 60% of its time at 1 GB), no interrupt stops
//   it; if iOS ends the app then, SQLite rolls the unfinished rewrite back at the
//   next open. A copy-back that commits after the databases were suspended has its
//   TRUNCATE refused (the suspended database aborts it, and the error is dropped).
//   That TRUNCATE, and one that cannot empty the WAL because a reader still holds
//   part of it, is not tried again: the WAL keeps the rewritten pages until the
//   database's later checkpoints (`checkpointWALThrottled` for the email database).
// - The background processing job (`runOvernightSpaceReturn`): a database on
//   INCREMENTAL gives its empty pages back in steps of
//   `SyncConfig.incrementalVacuumStepPages` (`DatabaseVacuum.giveBackEmptyPages`),
//   each one short write followed by the app's throttled PASSIVE checkpoint
//   (`checkpointWALThrottled`, at most once per
//   `SyncConfig.walCheckpointMinIntervalSeconds`: about one step in 40 at 35 ms a
//   step), until no page is empty, the app comes to the foreground or the job ends,
//   and then a TRUNCATE checkpoint. The foreground check comes before each step, so
//   a step that started in the background, and its checkpoint, can still hold the
//   writer for their few milliseconds after the app comes forward. Measured on a Mac
//   at 1 GB with 190 MB empty: 24 steps of 2,048 pages, 35 ms each (median).
// - The Optimize Storage tap (`StorageOptimizer`, #1448): the same steps, run at once
//   from Settings, the one run in the foreground. Its check (`optimizeStorageMayRun`)
//   needs the app in the foreground and the databases not suspended. Sync is not
//   paused: the run's writes are at the background tier, and a sync write that
//   arrives waits for at most one of the run's writer holds: a step, one throttled
//   PASSIVE checkpoint (about 0.6 to 2 s), or the final TRUNCATE (about 0.4 to 1.1 s
//   at 1 GB with 190 MB empty).
//
// No TRUNCATE follows a switch that failed or a database with nothing to give back:
// whatever the WAL holds then is left to the database's later checkpoints
// (`checkpointWALThrottled` for the email database). The one exception is a switch
// that ran out of disk space: its rolled-back copy-back can leave the WAL file large
// on a phone short of space. The TRUNCATE copies any committed frames, then empties
// the log, giving that space back at once; if a reader or the disk stops it, SQLite's
// journal size limit cuts the log back at its next reset.
//
// A database that is not upgraded gets no step: it stays as it was before this
// change, its empty pages in the file, reused by later writes.

extension SyncEngine {

    /// One database the upgrade and the background processing job work on.
    struct SpaceReturnTarget: Sendable {
        /// For the debug lines and the results: "email" or "search".
        let name: String
        /// The database file's path. The device's free space is read for its volume.
        let path: String
        /// The database's mode and pages; nil when they cannot be read.
        let state: @Sendable () async -> DatabaseVacuum.SpaceState?
        /// The one-time switch to INCREMENTAL, on the database's writer connection.
        /// It asks `shouldRun` again on the writer, just before its `VACUUM`, and
        /// throws `SpaceReturnDeferred.mayNotRun` when it says no.
        let switchToIncremental: @Sendable (_ shouldRun: @escaping @Sendable () -> Bool) async throws -> Void
        /// One step of `DatabaseVacuum.giveBackEmptyPages` with the given number of
        /// pages, on the writer connection. Returns the empty pages left.
        let giveBack: @Sendable (_ pages: Int) async throws -> Int
        /// A TRUNCATE checkpoint of the database, on its writer connection. A
        /// failure is left to the database's next checkpoint.
        let truncateWAL: @Sendable () async -> Void

        /// The email database through `pool`, at its write tier. Its switch carries
        /// the planner statistics marker `markerKey` and empties `inboxObserver`'s
        /// rowid map (`switchEmailDatabaseToIncremental`). Each step is followed by
        /// `checkpoint` (the app's throttled PASSIVE checkpoint; a test counts it).
        static func email(
            _ pool: PrioritizedDatabase,
            markerKey: String = SyncEngine.plannerStatisticsSchemaVersionKey,
            inboxObserver: InboxNotificationObserver?,
            checkpoint: @escaping @Sendable (PrioritizedDatabase) async -> Void = { await SyncEngine.checkpointWALThrottled(pool: $0) }
        ) -> SpaceReturnTarget {
            SpaceReturnTarget(
                name: "email", path: pool.pool.path,
                state: { SyncEngine.emailSpaceState(pool) },
                switchToIncremental: { shouldRun in
                    try await SyncEngine.switchEmailDatabaseToIncremental(
                        pool, markerKey: markerKey, inboxObserver: inboxObserver, shouldRun: shouldRun)
                },
                giveBack: { pages in
                    let left = try await pool.writeWithoutTransaction { db in
                        try DatabaseVacuum.giveBackEmptyPages(db, upTo: pages)
                    }
                    // Autocheckpoint is off on this database: like every batch writer,
                    // the steps bound the WAL with the throttled PASSIVE checkpoint.
                    await checkpoint(pool)
                    return left
                },
                truncateWAL: {
                    _ = try? await pool.writeWithoutTransaction { db in
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                })
        }

        /// The search database of `index`; nil when it cannot be opened.
        static func search(_ index: SearchIndex) async -> SpaceReturnTarget? {
            guard let path = await index.databasePath() else { return nil }
            return SpaceReturnTarget(
                name: "search", path: path,
                state: { await index.spaceState() },
                switchToIncremental: { shouldRun in try await index.switchToIncrementalVacuum(shouldRun: shouldRun) },
                giveBack: { pages in try await index.giveBackEmptyPages(upTo: pages) },
                truncateWAL: { await index.truncateWAL() })
        }
    }

    /// What `runOvernightSpaceReturn` did with one database.
    enum SpaceReturnStep: Equatable, Sendable {
        /// INCREMENTAL with empty pages: its steps ran until no empty page was left,
        /// or until a step freed nothing, then its WAL was truncated.
        case gaveBack(String)
        /// INCREMENTAL, with no empty page.
        case alreadyCompact(String)
        /// On NONE: not upgraded, so nothing was written.
        case notUpgraded(String)
        /// Not started, or stopped between two steps or before the steps' TRUNCATE:
        /// the app came to the foreground or the databases were suspended
        /// (`shouldRun`). The run ends.
        case stopped(String)
        /// Its state could not be read, or a step threw.
        case failed(String)
    }

    /// What `runDatabaseUpgrade` did with one database.
    enum UpgradeStep: Equatable, Sendable {
        /// Switched from NONE to INCREMENTAL: its `VACUUM` committed, then its WAL
        /// was truncated.
        case upgraded(String)
        /// Already INCREMENTAL (or FULL): nothing to do.
        case alreadyUpgraded(String)
        /// On NONE, with too little free space on the device: `bytesToFree` more
        /// bytes are needed (`bytesToFreeForUpgrade`). Nothing was written; the
        /// upgrade ends.
        case needsSpace(String, bytesToFree: Int64)
        /// Its `VACUUM` ran out of disk space (SQLITE_FULL) although the check found
        /// room: something else used the space meanwhile, or the copy needed more.
        /// It rolled back and nothing was lost; its WAL was truncated (any committed
        /// frames copied first), which gives back at once the space the rolled-back
        /// copy took there. The upgrade ends and the notice asks for space.
        case ranOutOfSpace(String)
        /// Not started, its `VACUUM` not started, or its `VACUUM` interrupted (rolled
        /// back): the databases were suspended (`shouldRun`). The upgrade ends; it
        /// starts again when the app returns.
        case stopped(String)
        /// Its state or the free space could not be read, or its `VACUUM` threw (other
        /// than running out of space) while the databases were not suspended (it then
        /// rolled back). The upgrade ends.
        case failed(String)
    }

    /// Why a database's switch did not start.
    enum SpaceReturnDeferred: Error, Equatable {
        /// The planner statistics refresh holds its latch
        /// (`switchEmailDatabaseToIncremental`).
        case statisticsRefreshRunning
        /// The search database is not open.
        case notOpen
        /// `shouldRun`, asked again once the switch's write had the writer, said no:
        /// while the write waited behind others, the databases were suspended.
        case mayNotRun
    }

    /// The background processing job's check: its steps start nothing while the
    /// databases are suspended (the job has ended) or while the app is in the
    /// foreground. The foreground gate keeps the sync timing promises (ADR-IOS-121),
    /// not ADR-IOS-046's non-WAL lock reason: both databases are WAL.
    nonisolated static func spaceReturnMayRun(
        isSuspended: Bool = DatabaseSuspension.isSuspended,
        isAppActive: Bool = DatabaseSuspension.isAppActive
    ) -> Bool {
        !isSuspended && !isAppActive
    }

    /// The upgrade's check: it starts no `VACUUM` while the databases are
    /// suspended (the app's background time ran out, `DatabaseSuspension`).
    nonisolated static func upgradeMayRun(isSuspended: Bool = DatabaseSuspension.isSuspended) -> Bool {
        !isSuspended
    }

    /// The Optimize Storage tap's check (`StorageOptimizer`, #1448): the one run of the
    /// steps in the foreground. Its steps start only while the app is in the foreground
    /// and the databases are not suspended; the app leaving stops them between two, and
    /// the rest waits for the background job. Sync is not paused: a sync write waits for
    /// at most one step, one throttled checkpoint or the final TRUNCATE, as behind any
    /// batch writer (ADR-IOS-121 decision 5).
    nonisolated static func optimizeStorageMayRun(
        isSuspended: Bool = DatabaseSuspension.isSuspended,
        isAppActive: Bool = DatabaseSuspension.isAppActive
    ) -> Bool {
        !isSuspended && isAppActive
    }

    /// The email and search databases, in the order the upgrade and the background
    /// processing job work on them. The search database only once it can be opened.
    /// `emailPool` is the app database's pool, whose inbox banner observer the
    /// email database's switch empties.
    nonisolated static func appSpaceReturnTargets(emailPool: PrioritizedDatabase) async -> [SpaceReturnTarget] {
        let inboxObserver = AppDatabase.shared.withLock { $0?.inboxNotificationObserver }
        var targets = [SpaceReturnTarget.email(emailPool, inboxObserver: inboxObserver)]
        if let search = await SpaceReturnTarget.search(SearchIndex.shared) {
            targets.append(search)
        }
        return targets
    }

    /// The free space a switch of a database holding `liveBytes` needs (its pages less
    /// its empty pages, `DatabaseVacuum.SpaceState.liveBytes`): the `VACUUM` copies
    /// only those, into its temporary copy and then through the WAL, so
    /// `SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple` times them. The empty
    /// pages are not copied: on a database with many, the file's size would ask for
    /// far more than the rewrite uses (#1449).
    nonisolated static func bytesNeededForUpgrade(liveBytes: Int64) -> Int64 {
        Int64((Double(liveBytes) * SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple).rounded(.up))
    }

    /// How many more bytes the device needs free to switch a database holding
    /// `liveBytes` (0: it has room), against `bytesNeededForUpgrade`.
    nonisolated static func bytesToFreeForUpgrade(liveBytes: Int64, availableBytes: Int64) -> Int64 {
        max(0, bytesNeededForUpgrade(liveBytes: liveBytes) - availableBytes)
    }

    /// The free space on the volume that holds the file at `path`, in bytes; nil if
    /// it cannot be read. The space free now, not counting what iOS could purge: the
    /// `VACUUM` writes at once and cannot wait for a purge.
    nonisolated static func deviceAvailableBytes(forVolumeOf path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The background processing job's last step (`SyncScheduler`), and the Optimize
    /// Storage tap's run (`StorageOptimizer`): for each upgraded target in turn, gives
    /// its empty pages back in steps (see the top of this file). A target still on
    /// NONE gets no step.
    ///
    /// Starts no further step and no TRUNCATE after the steps once `shouldRun`, asked
    /// before each, says no. The job's default check says no while the app is in the
    /// foreground or the databases are suspended; the tap passes its own
    /// (`optimizeStorageMayRun`, plus its cancellation). The job runs this in a
    /// detached task, so its end reaches the run through the suspension, not through
    /// cancellation. A target that fails leaves
    /// its database as it was, and the next target still runs; a stop ends the run.
    /// Returns what it did with each database.
    ///
    /// `stepPages` is at least 1: SQLite's `incremental_vacuum` with 0 or less gives
    /// every empty page back in one write (`DatabaseVacuum.giveBackEmptyPages`).
    @discardableResult
    nonisolated static func runOvernightSpaceReturn(
        targets: [SpaceReturnTarget],
        stepPages: Int = SyncConfig.incrementalVacuumStepPages,
        shouldRun: @escaping @Sendable () -> Bool = { SyncEngine.spaceReturnMayRun() }
    ) async -> [SpaceReturnStep] {
        var steps: [SpaceReturnStep] = []
        for target in targets {
            guard shouldRun() else {
                steps.append(.stopped(target.name))
                break
            }
            guard let state = await target.state() else {
                BackgroundSyncLogger.logDebug("[SpaceReturn] \(target.name): mode and pages unreadable; skipped")
                steps.append(.failed(target.name))
                continue
            }
            let step: SpaceReturnStep
            switch state.autoVacuum {
            case DatabaseVacuum.noneMode:
                step = .notUpgraded(target.name)
            case DatabaseVacuum.incrementalMode:
                step = await giveBackInSteps(target, state: state, stepPages: stepPages, shouldRun: shouldRun)
            default:
                // FULL: SQLite gives pages back at every commit; nothing to do.
                step = .alreadyCompact(target.name)
            }
            steps.append(step)
            if step == .stopped(target.name) { break }
        }
        return steps
    }

    /// The one-time upgrade (`DatabaseUpgrade`): each target still on NONE, in
    /// order, is switched to INCREMENTAL and its WAL truncated. Its free space is
    /// checked against its data (its pages less its empty pages) read just before, so
    /// the search database is measured
    /// after the email database's rewrite gave space back. The first target that
    /// needs space, stops or fails ends the upgrade: the later ones are left on NONE
    /// for the next try. A `VACUUM` that runs out of disk space anyway rolls back,
    /// its WAL is truncated, and it ends the upgrade as `ranOutOfSpace`.
    ///
    /// The caller has paused polling and the body, AI and embedding queues
    /// (`DatabaseUpgrade`'s light pause); other writes wait behind each `VACUUM`. If
    /// the planner statistics refresh holds its latch (a maintenance pass's
    /// `ANALYZE`), the email database's switch waits for it,
    /// `SyncConfig.databaseUpgradeStatisticsWaitMilliseconds` at a time.
    /// `shouldRun` is asked before each target and again on the writer, just before
    /// each `VACUUM`. The TRUNCATE after a switch always follows it: the WAL then
    /// holds the whole rewritten database, and only a checkpoint empties it.
    nonisolated static func runDatabaseUpgrade(
        targets: [SpaceReturnTarget],
        availableBytes: @Sendable (String) -> Int64? = { deviceAvailableBytes(forVolumeOf: $0) },
        shouldRun: @escaping @Sendable () -> Bool = { SyncEngine.upgradeMayRun() }
    ) async -> [UpgradeStep] {
        var steps: [UpgradeStep] = []
        for target in targets {
            let step = await upgradeOne(target, availableBytes: availableBytes, shouldRun: shouldRun)
            steps.append(step)
            switch step {
            case .upgraded, .alreadyUpgraded: continue
            case .needsSpace, .ranOutOfSpace, .stopped, .failed: return steps
            }
        }
        return steps
    }

    /// One target of `runDatabaseUpgrade`.
    private static func upgradeOne(
        _ target: SpaceReturnTarget,
        availableBytes: @Sendable (String) -> Int64?,
        shouldRun: @escaping @Sendable () -> Bool
    ) async -> UpgradeStep {
        guard shouldRun() else { return .stopped(target.name) }
        guard let state = await target.state() else {
            BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): mode and pages unreadable")
            return .failed(target.name)
        }
        guard state.autoVacuum == DatabaseVacuum.noneMode else { return .alreadyUpgraded(target.name) }
        guard let available = availableBytes(target.path) else {
            BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): free space unreadable")
            return .failed(target.name)
        }
        let toFree = bytesToFreeForUpgrade(liveBytes: state.liveBytes, availableBytes: available)
        guard toFree == 0 else {
            BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): \(available) bytes free, a \(state.allBytes) byte database holding \(state.liveBytes) bytes of data needs \(SyncConfig.incrementalVacuumSwitchFreeSpaceMultiple)x its data; \(toFree) more bytes needed")
            return .needsSpace(target.name, bytesToFree: toFree)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        while true {
            do {
                try await target.switchToIncremental(shouldRun)
                break
            } catch SpaceReturnDeferred.statisticsRefreshRunning {
                guard shouldRun() else { return .stopped(target.name) }
                try? await Task.sleep(for: .milliseconds(SyncConfig.databaseUpgradeStatisticsWaitMilliseconds))
            } catch SpaceReturnDeferred.mayNotRun {
                BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): not started, the databases were suspended while its write waited")
                return .stopped(target.name)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
                // The disk filled during the rewrite although the check found room:
                // the `VACUUM` rolled back and its temporary copy is gone. Pages its
                // copy-back wrote to the WAL keep the WAL file large. This TRUNCATE
                // copies any committed frames (writes since the last checkpoint), then
                // empties the log, giving that space back at once, on the one path
                // where the phone is short of it. If a reader or the full disk stops
                // it (the error is dropped; no retry), SQLite's journal size limit
                // cuts the log back at its next reset.
                BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): ran out of disk space after \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms, rolled back: \(error)")
                await target.truncateWAL()
                return .ranOutOfSpace(target.name)
            } catch {
                // A suspension interrupts the `VACUUM` while it builds its copy: it
                // rolled back, and the upgrade starts it again on the app's return.
                // Any other error (the search database not open) left the database
                // as it was. If iOS freezes the app between the
                // interrupt and this catch, the catch runs after the resume, finds
                // the databases no longer suspended and reports failed: nothing is
                // lost, the banner stays and Upgrade now runs it again.
                BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): switch not done after \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms: \(error)")
                return shouldRun() ? .failed(target.name) : .stopped(target.name)
            }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        await target.truncateWAL()
        if DebugModeManager.isLoggingEnabled() {
            let after = await target.state()
            BackgroundSyncLogger.logDebug("[DatabaseUpgrade] \(target.name): switched to INCREMENTAL, \(state.allBytes) bytes (\(state.freePages) empty pages) to \(after?.allBytes ?? -1); VACUUM \(Int((t1 - t0) * 1000))ms, WAL truncate \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000))ms")
        }
        return .upgraded(target.name)
    }

    /// Gives `target`'s empty pages back, `stepPages` per step, checking `shouldRun`
    /// before each step and before the TRUNCATE that follows them. Stops early if a
    /// step frees nothing (the database's writes are filling pages as fast as the
    /// steps free them), and does not truncate after a stop: the app's own
    /// checkpoints take what the steps left in the WAL.
    private static func giveBackInSteps(
        _ target: SpaceReturnTarget,
        state: DatabaseVacuum.SpaceState,
        stepPages: Int,
        shouldRun: @Sendable () -> Bool
    ) async -> SpaceReturnStep {
        guard state.freePages > 0 else { return .alreadyCompact(target.name) }
        let t0 = CFAbsoluteTimeGetCurrent()
        var left = Int(state.freePages)
        var stepCount = 0
        while left > 0 {
            guard shouldRun() else {
                BackgroundSyncLogger.logDebug("[SpaceReturn] \(target.name): stopped after \(stepCount) steps, \(left) empty pages left")
                return .stopped(target.name)
            }
            let after: Int
            do {
                after = try await target.giveBack(stepPages)
            } catch {
                BackgroundSyncLogger.logDebug("[SpaceReturn] \(target.name): step failed after \(stepCount) steps: \(error)")
                return .failed(target.name)
            }
            stepCount += 1
            guard after < left else { break }
            left = after
        }
        // The TRUNCATE is a write of its own, as long as what the last checkpoint
        // left: like a step, it does not start once the app has come forward or the
        // job has ended.
        guard shouldRun() else {
            BackgroundSyncLogger.logDebug("[SpaceReturn] \(target.name): stopped before the WAL truncate, after \(stepCount) steps, \(left) empty pages left")
            return .stopped(target.name)
        }
        await target.truncateWAL()
        BackgroundSyncLogger.logDebug("[SpaceReturn] \(target.name): gave back \(state.freePages - Int64(left)) of \(state.freePages) empty pages in \(stepCount) steps, \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        return .gaveBack(target.name)
    }

    /// The email database's mode and pages, read with `PrioritizedDatabase.read`'s
    /// synchronous overload. Not `async` on purpose: from an async context Swift binds
    /// the awaited overload, which runs the notification extension's staging merge
    /// before it reads, and this reads the database header alone.
    private static func emailSpaceState(_ pool: PrioritizedDatabase) -> DatabaseVacuum.SpaceState? {
        (try? pool.read { db in try DatabaseVacuum.SpaceState.read(db) }) ?? nil
    }

    /// Switches the email database to INCREMENTAL (`DatabaseVacuum.switchToIncremental`)
    /// and carries the planner statistics marker across its `VACUUM`.
    ///
    /// Once the `VACUUM` has committed, in the same write on the writer queue, it
    /// empties `inboxObserver`'s map (`InboxNotificationObserver.forgetInboxRows`),
    /// which is keyed by `messageHeader` rowid: the `VACUUM` keeps every header's
    /// rowid (measured, and pinned by `IncrementalVacuumTests`), but SQLite documents
    /// only that it may change the rowids of a table without an INTEGER PRIMARY KEY,
    /// so the map goes back to its state at launch. A `VACUUM` that throws has rolled
    /// back with every rowid as it was, and the map is left.
    ///
    /// A `VACUUM` adds one to SQLite's `schema_version` and copies `sqlite_stat1` as it
    /// is. The marker (`plannerStatisticsSchemaVersionKey`) records the
    /// `schema_version` of the last `ANALYZE`, so without the carry the switch would
    /// make the statistics look stale, and the next maintenance pass would run a whole
    /// `ANALYZE` for statistics that did not change. So: read `schema_version`, switch,
    /// read it again, all on the one writer connection; if the marker equalled the
    /// first value it is set to the second, and a marker that was already stale stays
    /// stale. A switch that throws has rolled back, `schema_version` with it, and the
    /// marker is left. (The steps of `giveBackEmptyPages` change no `schema_version`,
    /// measured, so they need no carry.)
    ///
    /// Under the statistics refresh's single-flight latch, so no `ANALYZE` stores its
    /// marker between the switch and the carry. If an `ANALYZE` holds the latch, the
    /// switch does not start (`SpaceReturnDeferred.statisticsRefreshRunning`; the
    /// upgrade waits and tries again).
    ///
    /// The write is queued at `pool`'s tier and can wait behind others, so `shouldRun`
    /// is asked again first thing in it, on the writer: if the databases were
    /// suspended meanwhile, nothing runs (`SpaceReturnDeferred.mayNotRun`).
    nonisolated static func switchEmailDatabaseToIncremental(
        _ pool: PrioritizedDatabase,
        markerKey: String = plannerStatisticsSchemaVersionKey,
        inboxObserver: InboxNotificationObserver?,
        shouldRun: @escaping @Sendable () -> Bool
    ) async throws {
        let acquired = plannerStatisticsRefreshInFlight.withLock { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard acquired else { throw SpaceReturnDeferred.statisticsRefreshRunning }
        defer { plannerStatisticsRefreshInFlight.withLock { $0 = false } }
        let versions = try await pool.writeWithoutTransaction { db -> SchemaVersions in
            guard shouldRun() else { throw SpaceReturnDeferred.mayNotRun }
            let before = try Int.fetchOne(db, sql: "PRAGMA schema_version") ?? 0
            try DatabaseVacuum.switchToIncremental(db)
            inboxObserver?.forgetInboxRows()
            let after = try Int.fetchOne(db, sql: "PRAGMA schema_version") ?? before
            return SchemaVersions(before: before, after: after)
        }
        let defaults = UserDefaults.standard
        if let marker = defaults.object(forKey: markerKey) as? Int, marker == versions.before {
            defaults.set(versions.after, forKey: markerKey)
        }
    }

    /// `schema_version` before and after the email database's switch.
    private struct SchemaVersions: Sendable {
        let before: Int
        let after: Int
    }
}
