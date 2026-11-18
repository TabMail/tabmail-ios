/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Shared cursor for parallel UID walk-back within a single folder.
/// N workers consume the highest UIDs first, walking backward to UID 1.
/// Thread-safe via actor isolation — workers grab ranges atomically.
///
/// ROBUSTNESS: Uses claim/confirm model. Workers claim ranges (cursor advances
/// speculatively), but the *confirmed* cursor only advances when ranges are
/// explicitly confirmed. Failed ranges are returned for retry. The persistable
/// cursor (`confirmedCursor`) only reflects successfully processed ranges.
actor UIDWalkCursor {
    private var cursor: Int
    private var chunkSize: Int
    private let defaultChunkSize: Int
    private var consecutiveSuccesses: Int = 0
    /// How many consecutive successful fetches before doubling chunk back toward default.
    private static let recoverAfterSuccesses = 5

    /// Ranges claimed by workers but not yet confirmed.
    /// Sorted by `from` descending (highest first — matches walk direction).
    private var inFlight: [(from: Int, to: Int)] = []

    /// Ranges that failed and need retry. Workers drain these before grabbing new ranges.
    private var retryQueue: [(from: Int, to: Int)] = []

    /// The top of the highest range that failed in a way this walk does not
    /// retry. `nextRange` never serves such a range again, but it stays
    /// PENDING: the confirmed cursor stops at this top and the walk cannot
    /// complete, so the next walk (a new cursor, started from the persisted
    /// position) asks it again. Only the highest top matters, because the
    /// cursor walks downward. In memory only.
    private var highestFailedThisWalk: Int?

    /// The lowest confirmed cursor — only advances when contiguous ranges from the
    /// top are confirmed. This is the value safe to persist to DB.
    private var confirmedCursor: Int

    var isComplete: Bool { cursor < 1 && inFlight.isEmpty && retryQueue.isEmpty && highestFailedThisWalk == nil }

    init(startCursor: Int, chunkSize: Int) {
        self.cursor = startCursor
        self.confirmedCursor = startCursor
        self.chunkSize = chunkSize
        self.defaultChunkSize = chunkSize
    }

    /// Grab the next UID range to process. Retries are served first, then new ranges.
    /// Returns nil only when ALL ranges are processed (no pending, no retry, cursor exhausted).
    func nextRange() -> (from: Int, to: Int)? {
        // Serve retries first
        if !retryQueue.isEmpty {
            let range = retryQueue.removeFirst()
            inFlight.append(range)
            return range
        }
        guard cursor >= 1 else {
            // No new ranges — but might still have in-flight ranges being processed
            return nil
        }
        let to = cursor
        let from = max(1, cursor - chunkSize + 1)
        cursor = from - 1
        let range = (from: from, to: to)
        inFlight.append(range)
        return range
    }

    /// Confirm a range was successfully processed. Advances confirmedCursor if this
    /// range (and any contiguous ranges above it) form a complete chain from the top.
    func confirmRange(from: Int, to: Int) {
        inFlight.removeAll { $0.from == from && $0.to == to }
        updateConfirmedCursor()
        // Chunk recovery
        guard chunkSize < defaultChunkSize else { return }
        consecutiveSuccesses += 1
        if consecutiveSuccesses >= Self.recoverAfterSuccesses {
            chunkSize = min(defaultChunkSize, chunkSize * 2)
            consecutiveSuccesses = 0
            BackgroundSyncLogger.logDebug("[UIDCursor] Chunk recovered to \(chunkSize)")
        }
    }

    /// Return a range that failed — it goes back into the retry queue for another worker.
    func failRange(from: Int, to: Int) {
        inFlight.removeAll { $0.from == from && $0.to == to }
        retryQueue.append((from: from, to: to))
        consecutiveSuccesses = 0
    }

    /// Set aside a range this walk will not ask again: it stays pending (the
    /// cursor stays above it, the walk does not complete) and is retried by the
    /// next walk.
    func failRangeForThisWalk(from: Int, to: Int) {
        inFlight.removeAll { $0.from == from && $0.to == to }
        highestFailedThisWalk = max(highestFailedThisWalk ?? to, to)
        consecutiveSuccesses = 0
    }

    /// Return a failed range for retry SMALLER: its two halves, which together
    /// cover exactly the original range, go back into the retry queue. A range
    /// of one UID cannot be split, so it is set aside for this walk instead.
    /// Never serves a failed range again at its own size.
    func failRangeSmaller(from: Int, to: Int) {
        guard to > from else {
            failRangeForThisWalk(from: from, to: to)
            return
        }
        inFlight.removeAll { $0.from == from && $0.to == to }
        let mid = from + (to - from) / 2
        // Upper half first: the walk runs downward.
        retryQueue.append((from: mid + 1, to: to))
        retryQueue.append((from: from, to: mid))
        consecutiveSuccesses = 0
    }

    /// Whether any range was set aside for this walk.
    var hasFailedThisWalk: Bool { highestFailedThisWalk != nil }

    /// Reduce chunk size on PayloadTooLargeError. Affects subsequent new ranges only.
    func reduceChunk() -> Int {
        chunkSize = max(1, chunkSize / 2)
        consecutiveSuccesses = 0
        return chunkSize
    }

    /// The confirmed cursor — safe to persist. Only advances past ranges that
    /// are fully confirmed, not just claimed.
    var currentCursor: Int { confirmedCursor }

    /// The confirmed cursor, read inside the actor. A local function reading
    /// `currentCursor` across the actor boundary draws a spurious
    /// "no 'async' operations" warning; a method call does not.
    func confirmedCursorSnapshot() -> Int { confirmedCursor }

    /// Current chunk size (for logging).
    var currentChunkSize: Int { chunkSize }

    /// Whether there are still ranges being processed or waiting for retry.
    var hasPendingWork: Bool { !inFlight.isEmpty || !retryQueue.isEmpty || highestFailedThisWalk != nil }

    // MARK: - Private

    /// Advance confirmedCursor downward.
    /// The confirmed cursor = the highest point where ALL ranges above it are confirmed
    /// (not in-flight, not in retry). If any range is still pending, the cursor stops
    /// above it.
    private func updateConfirmedCursor() {
        if inFlight.isEmpty && retryQueue.isEmpty && highestFailedThisWalk == nil {
            // All ranges confirmed — cursor can advance to the speculative position
            confirmedCursor = cursor
        } else {
            // Find the highest unconfirmed range — cursor stops just above it
            var highestPending = Int.min
            for range in inFlight { highestPending = max(highestPending, range.to) }
            for range in retryQueue { highestPending = max(highestPending, range.to) }
            if let top = highestFailedThisWalk { highestPending = max(highestPending, top) }
            // confirmedCursor = the highest pending range's top (nothing above it is unconfirmed
            // because we walk downward). Actually: everything ABOVE highestPending.to is confirmed.
            // So confirmedCursor should be highestPending.to (we've confirmed everything above it).
            // Wait — we need the cursor to represent "everything above this is done".
            // If highest pending is range X..Y, then everything from Y+1 upward is confirmed.
            // So confirmedCursor = highestPending (Y). On next cycle, walk resumes from Y downward.
            let newConfirmed = highestPending
            if newConfirmed < confirmedCursor {
                confirmedCursor = newConfirmed
            }
        }
    }

    /// Legacy compatibility — same as confirmRange.
    func recordSuccess() {
        // No-op in new model — use confirmRange instead
    }
}

extension SyncEngine {

    // MARK: - Unified Background Backfill

    // NOTE: fast sync deliberately does NOT reset backfill cursors. The removed
    // `resetForFastSync()` nulled backfillUidCursor/backfillPageToken on every
    // incomplete folder each time FastSyncView appeared, restarting partially
    // walked folders from the top (IMAP re-fetched every existing header; REST
    // re-paged through all known pages) and racing the running workers' cursor
    // snapshots. Fast sync just flips the profile to .turbo — walks resume from
    // their stored cursors.

    /// Smart Reindex: reset crawl cursors so backfill re-walks from top.
    /// Anchors oldestSyncedDate to now and clears cursors so IMAP walks from UIDNEXT
    /// and Gmail/Exchange from first page. Existing messages are naturally deduped.
    func resetCrawlState() async {
        // Increment generation for all accounts before cancelling — prevents
        // stale task defer from clearing a replacement task's dictionary entry.
        for accountId in headerBackfillTasks.keys {
            backfillGeneration[accountId] = (backfillGeneration[accountId] ?? 0) + 1
        }

        // Cancel existing backfill worker
        for (_, task) in headerBackfillTasks { task.cancel() }
        headerBackfillTasks.removeAll()

        // Reset folder progress — anchor to today so backward crawl starts from top.
        // Cursors = nil → IMAP inits from UIDNEXT-1, Gmail/Exchange from first page.
        let now = Date()
        // Background-tagged: bulk smart-reindex folder/message resets yield to UI work.
        try? await AppDatabase.backgroundPool.write { db in
            _ = try Folder.filter(Column("path") != "")
                .updateAll(db,
                    Column("backfillComplete").set(to: false),
                    Column("oldestSyncedDate").set(to: now),
                    Column("backfillUidCursor").set(to: nil as Int?),
                    Column("backfillPageToken").set(to: nil as String?),
                    Column("backfillPageHeldSince").set(to: nil as Date?)
                )
        }
        // Reset bodyEmptyConfirmed — gives previously-empty messages a fresh chance,
        // and bodyMetadataOversized so a row whose metadata FETCH overflowed the
        // parser buffer is re-attempted too (the overflow is fragmentation-dependent,
        // so a fresh attempt can genuinely succeed).
        //
        // ⚠️ BOTH HALVES OR THIS IS INERT. `bodyMetadataOversized` must be in the
        // WHERE as well as the SET: a flagged row has `bodyEmptyConfirmed = 0`, so
        // the original predicate does not select it and adding it to the SET alone
        // would silently skip exactly the rows Smart Reindex is invoked for.
        try? await AppDatabase.backgroundPool.write { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET bodyEmptyConfirmed = 0, emptyFetchCount = 0, bodyComplete = 0,
                    bodyMetadataOversized = 0
                WHERE bodyEmptyConfirmed = 1 OR bodyMetadataOversized = 1
                """)
        }
        BackgroundSyncLogger.logDebug("[SmartReindex] Crawl state reset — backfill will re-walk from top")
    }

    /// Start persistent background backfill for an account.
    /// Launches a single worker that crawls folders in reverse chrono, inserting headers.
    /// Body fetching is delegated to BackfillBodyQueue (runs independently).
    /// Respects battery/idle/cellular gates. Progress is reported per cycle.
    static let backfillDisabled = false

    /// How long the backfill worker sleeps after a backfill call. A call whose
    /// walk did no work (every remaining folder held, skipped or declined, or
    /// nothing left to do) waits the profile's idle delay, so a page held for
    /// minutes is not re-listed at the pace of a productive walk. Catch-up
    /// progress shortens the wait only once every walk of the account is complete
    /// (`walkComplete`): then no page can be held, and the catch-up's slices keep
    /// the active pace (the slice gap, `SyncConfig.catchUpSliceIntervalSeconds`,
    /// paces their requests). While a walk is unfinished, only the walk's own work
    /// decides (ADR-IOS-107, #766). The worker is per account, so another
    /// account's progress never enters this. *Superseded (#766):* any work of the
    /// call, the catch-up's progress included, chose the active delay.
    nonisolated static func backfillInterCycleDelay(
        cycle: BackfillCycle, walkComplete: Bool, profile: BackfillProfile
    ) -> TimeInterval {
        let active = cycle.walked || (walkComplete && cycle.caughtUp)
        return active ? profile.interCycleActiveDelay : profile.interCycleIdleDelay
    }

    func startBackfill(account: Account) {
        if Self.backfillDisabled { BackgroundSyncLogger.logDebug("[Backfill] SKIPPED \(account.emailAddress) — backfillDisabled"); return }
        let accountId = account.id
        guard providers[accountId] != nil else { BackgroundSyncLogger.logDebug("[Backfill] SKIPPED \(account.emailAddress) — no provider"); return }

        if headerBackfillTasks[accountId] == nil {
            BackgroundSyncLogger.logDebug("[Backfill] Starting for \(account.emailAddress)")
            BackgroundSyncLogger.logBackfill("[Backfill] worker START \(account.emailAddress)")
            let gen = (backfillGeneration[accountId] ?? 0) + 1
            backfillGeneration[accountId] = gen
            // QoS: `.medium` (= .default QoS 21). See ADR-IOS-031. `.low`
            // (= .utility QoS 17) caused priority-inversion warnings when
            // MainActor awaited GRDB readers held by this task. Session 2
            // briefly tried `.low` again (hypothesis: slow background work
            // throttles rapid nav) — confirmed via pre-investigation state
            // compare that `.low` actually produces a MORE frequent stuck-
            // screen bug, so the `.medium` QoS fix is the correct floor.
            headerBackfillTasks[accountId] = Task(priority: .medium) { [weak self] in
                // Brief delay so the app settles after sync
                try? await Task.sleep(for: .milliseconds(200))

                // Emit initial progress immediately so UI doesn't show "Waiting..."
                await self?.updateBackfillProgressForAccount(account)

                while !Task.isCancelled {
                    // Pause backfill entirely when battery is low (<20%) and not charging
                    if await self?.getShouldPauseBackfill() == true {
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) PAUSED — low battery / Low Power Mode (retry in 60s)")
                        try? await Task.sleep(for: .seconds(60))
                        continue
                    }

                    // PAUSE THE WHOLE CRAWL while a privileged merge holds the gate.
                    // The per-write facade yield only steps the GRDB writes aside;
                    // this parks the entire batch (network fetch + body render CPU +
                    // FTS index) so a foreground NSE→inbox merge runs unburdened.
                    // No-op when nothing privileged is active.
                    await PriorityGate.shared.yield("backfill-walk")

                    // Pause the WALK when user has WiFi-only setting enabled and we're on cellular.
                    // Uses checkExpensive() (Mutex-backed) as WiFi proxy — on iOS, expensive == cellular/hotspot.
                    // Pauses (not stops) so the walk resumes instantly when WiFi returns or setting is toggled.
                    // The catch-up ignores the setting (ADR-IOS-107 decision 2, 2026-11-12): it lists ids and
                    // labels under its own network rules, and its repairs must not wait for a Wi-Fi network
                    // that may never come. *Superseded:* the setting paused the whole cycle.
                    let wifiOnly = UserDefaults.standard.object(forKey: "backgroundSyncWiFiOnly") as? Bool ?? true
                    let walkAllowed = !(wifiOnly && NetworkMonitor.checkExpensive())
                    if !walkAllowed {
                        BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) walk paused — WiFi-only enabled, on cellular")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) walk PAUSED — WiFi-only enabled, on cellular (the catch-up still runs)")
                    }

                    guard !Task.isCancelled else { BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) cancelled"); break }

                    let profile = await self?.getBackfillProfile() ?? .low
                    BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) cycle start (profile=\(profile))")
                    BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) cycle start (profile=\(profile))")
                    let cycle = await self?.runBackfillCycle(account: account, walkAllowed: walkAllowed)
                        ?? BackfillCycle(walked: false, caughtUp: false)
                    await self?.updateBackfillProgressForAccount(account)
                    let walkDone = await self?.isFolderWalkComplete(account: account) ?? false

                    if !cycle.didWork {
                        BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) no work, walkDone=\(walkDone)")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) cycle no work, walkDone=\(walkDone)")
                        guard walkDone else {
                            // A walk held back by Wi-Fi-only retries after the setting's pause.
                            let sleepDelay = walkAllowed
                                ? Self.backfillInterCycleDelay(cycle: cycle, walkComplete: walkDone, profile: profile)
                                : 30
                            try? await Task.sleep(for: .seconds(sleepDelay))
                            continue
                        }

                        // All folders walked — body fetch handled by BackfillBodyQueue
                        break
                    }

                    let sleepSeconds = Self.backfillInterCycleDelay(cycle: cycle, walkComplete: walkDone, profile: profile)
                    try? await Task.sleep(for: .seconds(sleepSeconds))
                }

                // Only clear dictionary if this task is still the current generation.
                BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) walk loop ended")
                BackgroundSyncLogger.logBackfill("[Backfill] worker EXIT \(account.emailAddress) (cancelled=\(Task.isCancelled))")
                await self?.clearBackfillTaskIfCurrent(accountId: accountId, generation: gen)
            }
        } else {
            BackgroundSyncLogger.logDebug("[Backfill] \(account.emailAddress) already has active backfill task")
        }
    }

    // MARK: - Progress Helpers

    /// Clear backfill task from dictionary only if the generation matches.
    /// Prevents a finishing old task from overwriting a new task started by resetCrawlState.
    func clearBackfillTaskIfCurrent(accountId: String, generation: Int) {
        guard backfillGeneration[accountId] == generation else {
            BackgroundSyncLogger.logDebug("[Backfill] Skipping clearBackfillTask — generation mismatch (task=\(generation), current=\(backfillGeneration[accountId] ?? -1))")
            return
        }
        headerBackfillTasks[accountId] = nil
    }

    /// Query current backfill state and push to AccountManager for UI.
    /// Derives headersDone from DB (all folders backfillComplete) — no in-memory cache.
    ///
    /// The denominator has its own provider-side source (`progressTotal`), never
    /// the stored folder counters. While the provider's total is not known yet
    /// (before this launch's first folder list) nothing is published: the bar
    /// stays hidden rather than show 0 or the stored row count.
    func updateBackfillProgressForAccount(_ account: Account) async {
        let accountId = account.id
        // Quick DB check: are all folders done?
        let folders = (try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("path") != "").fetchAll(db)
        })
        let headersDone = Self.folderWalkDone(folders)

        // The provider is the source (#755): Gmail keeps its profile total,
        // Exchange answers its latest folder list's sum, IMAP its folder lists'
        // UIDNEXT. A provider not registered yet, or one with no folder list yet
        // (`.notKnownYet`), publishes nothing: the bar waits for its source.
        guard let provider = providers[accountId] else { return }
        let source = await provider.progressTotal(crawling: !headersDone)
        if source == .notKnownYet { return }
        let uidNextByPath: [String: Int]
        if case .uidNext(let map) = source { uidNextByPath = map } else { uidNextByPath = [:] }
        let walk = Self.uidWalkProgress(folders: folders ?? [], uidNextByPath: uidNextByPath)
        let (uidTotal, uidWalked) = (walk.total, walk.walked)

        // GRDB is sole authority for body status flags
        let (grdbTotal, grdbIndexed, pendingBody) = (try? await dbPool.read { db -> (Int, Int, Int) in
            let total = try MessageHeader.filter(Column("accountId") == accountId).fetchCount(db)
            // Both predicates live on `MessageHeader` as named requests rather than
            // inline `filter(…)` chains — see `bodySettledRequest` /
            // `pendingBodyRequest` for what they contain and why they are named. A
            // chain here is invisible to every SQL-text census and unreachable from
            // the test tree, and both properties cost real defects before.
            //
            // `bodyMetadataOversized` counts as SETTLED, not pending: those bodies
            // are unfetchable by this build, and leaving them in work-remaining
            // means `pendingBodyCount` never reaches 0, `isFullyComplete` is false
            // forever, and the sync banner never clears. Owner decision 2026-09-01.
            // If a future fix makes these bodies fetchable again, the two requests
            // and the body-queue admission queries drop the flag together.
            let indexed = try MessageHeader.bodySettledRequest(accountId: accountId).fetchCount(db)
            // Completion gates on this reaching 0, not on an exact count match
            // against a server-reported total.
            let pending = try MessageHeader.pendingBodyRequest(accountId: accountId).fetchCount(db)
            return (total, indexed, pending)
        }) ?? (0, 0, 1)   // pending=1 on read failure → never false-complete

        // Gmail/Exchange: uidTotal is 0 (no IMAP UIDs). Use the server-reported
        // total as the denominator ONLY WHILE STILL CRAWLING, so the bar reflects
        // mailbox size rather than crawl progress. Once the header walk is done
        // (`headersDone`), grdbTotal is authoritative — the server count counts a
        // different population (Exchange: SUM(totalItemCount) incl. Deleted Items,
        // Junk, hidden folders, non-mail items; Gmail: dedup'd messagesTotal vs.
        // our per-label rows) and can permanently exceed what we store, which would
        // keep the bar (and `isFullyComplete`) below 100% forever. See
        // PROJECT_MEMORY "Fast Sync / backfill completion".
        var totalEmails = grdbTotal
        let ftsIndexed = grdbIndexed
        if uidTotal == 0 && !headersDone, case .messages(let serverTotal) = source, serverTotal > grdbTotal {
            totalEmails = serverTotal
            // ftsIndexed stays as-is (bodies indexed), total becomes server count
        }

        await AccountManager.shared.updateBackfillProgress(
                accountId: accountId, email: account.emailAddress,
                headersDone: headersDone, isPaused: false,
                totalEmails: totalEmails, ftsIndexed: ftsIndexed,
                uidTotal: uidTotal, uidWalked: uidWalked,
                pendingBodyCount: pendingBody
            )
    }

    /// UID walk progress: per folder, the scope is UIDNEXT-1 (from the provider's
    /// last folder list) and the walked part is the scope for a completed folder,
    /// the scope less the crawl's cursor for a started one, 0 otherwise. A folder
    /// the list gave no UIDNEXT adds nothing.
    nonisolated static func uidWalkProgress(folders: [Folder], uidNextByPath: [String: Int]) -> (total: Int, walked: Int) {
        var total = 0
        var walked = 0
        for folder in folders {
            let uidNext = uidNextByPath[folder.path] ?? 0
            guard uidNext > 0 else { continue }
            let folderTotal = uidNext - 1
            total += folderTotal
            if folder.backfillComplete {
                walked += folderTotal
            } else if let cursor = folder.backfillUidCursor {
                // Clamped to this folder's own denominator: a crawl that started
                // after UIDNEXT moved past the folder list's value (cursor above
                // it) counts 0, never a negative share or more than the folder
                // (#755). Only a folder whose walk is complete counts in full.
                walked += min(folderTotal, max(0, folderTotal - cursor))
            }
        }
        return (total, walked)
    }

    /// Check if all folders have been walked for an account (header crawl complete).
    /// Does NOT check FTS body completion — body fetch is handled by BackfillBodyQueue.
    /// A failed read answers "not complete": no caller may release work (the
    /// wake lock, the crawl) on a count it could not read.
    func isFolderWalkComplete(account: Account) async -> Bool {
        let accountId = account.id
        let folders = try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("path") != "").fetchAll(db)
        }
        return Self.folderWalkDone(folders)
    }

    /// The account's header walk is done: its folders were read (nil = the read
    /// failed), at least one real folder is known (none = not discovered yet),
    /// and every one of them finished its walk. Fails closed.
    nonisolated static func folderWalkDone(_ folders: [Folder]?) -> Bool {
        guard let folders else { return false }
        let real = folders.filter { !$0.path.isEmpty }
        return !real.isEmpty && real.allSatisfy(\.backfillComplete)
    }

}
