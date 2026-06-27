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

    /// The lowest confirmed cursor — only advances when contiguous ranges from the
    /// top are confirmed. This is the value safe to persist to DB.
    private var confirmedCursor: Int

    var isComplete: Bool { cursor < 1 && inFlight.isEmpty && retryQueue.isEmpty }

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
            print("[UIDCursor] Chunk recovered to \(chunkSize)")
        }
    }

    /// Return a range that failed — it goes back into the retry queue for another worker.
    func failRange(from: Int, to: Int) {
        inFlight.removeAll { $0.from == from && $0.to == to }
        retryQueue.append((from: from, to: to))
        consecutiveSuccesses = 0
    }

    /// Reduce chunk size on PayloadTooLargeError. Affects subsequent new ranges only.
    func reduceChunk() -> Int {
        chunkSize = max(1, chunkSize / 2)
        consecutiveSuccesses = 0
        return chunkSize
    }

    /// The confirmed cursor — safe to persist. Only advances past ranges that
    /// are fully confirmed, not just claimed.
    var currentCursor: Int { confirmedCursor }

    /// Current chunk size (for logging).
    var currentChunkSize: Int { chunkSize }

    /// Whether there are still ranges being processed or waiting for retry.
    var hasPendingWork: Bool { !inFlight.isEmpty || !retryQueue.isEmpty }

    // MARK: - Private

    /// Advance confirmedCursor downward.
    /// The confirmed cursor = the highest point where ALL ranges above it are confirmed
    /// (not in-flight, not in retry). If any range is still pending, the cursor stops
    /// above it.
    private func updateConfirmedCursor() {
        if inFlight.isEmpty && retryQueue.isEmpty {
            // All ranges confirmed — cursor can advance to the speculative position
            confirmedCursor = cursor
        } else {
            // Find the highest unconfirmed range — cursor stops just above it
            var highestPending = Int.min
            for range in inFlight { highestPending = max(highestPending, range.to) }
            for range in retryQueue { highestPending = max(highestPending, range.to) }
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

    /// Reset backfill state for fast sync mode. Called once when fast sync is activated.
    /// Clears in-memory tracking so the worker restarts.
    /// Does NOT reset backfillComplete on already-crawled folders — fast sync focuses
    /// on body indexing, not re-crawling headers. Only incomplete folders get cursor reset.
    func resetForFastSync() {
        // Don't reset backfillComplete — folders already crawled stay crawled.
        // Only reset cursors for incomplete folders so they retry from scratch.
        Task { [weak self] in
            try? await self?.dbPool.write { db in
                _ = try Folder.filter(
                    Column("backfillComplete") == false &&
                    Column("path") != ""
                ).updateAll(db,
                    Column("backfillUidCursor").set(to: nil as Int?),
                    Column("backfillPageToken").set(to: nil as String?)
                )
            }
        }
    }

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
        try? await dbPool.write { db in
            _ = try Folder.filter(Column("path") != "")
                .updateAll(db,
                    Column("backfillComplete").set(to: false),
                    Column("oldestSyncedDate").set(to: now),
                    Column("backfillUidCursor").set(to: nil as Int?),
                    Column("backfillPageToken").set(to: nil as String?)
                )
        }
        // Reset bodyEmptyConfirmed — gives previously-empty messages a fresh chance
        try? await dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyEmptyConfirmed = 0, emptyFetchCount = 0, bodyComplete = 0 WHERE bodyEmptyConfirmed = 1")
        }
        // Reset cc/bcc backfill flag so existing messages get cc/bcc populated
        UserDefaults.standard.set(false, forKey: "ccBccBackfillDone")
        print("[SmartReindex] Crawl state reset — backfill will re-walk from top")
    }

    /// Start persistent background backfill for an account.
    /// Launches a single worker that crawls folders in reverse chrono, inserting headers.
    /// Body fetching is delegated to BackfillBodyQueue (runs independently).
    /// Respects battery/idle/cellular gates. Progress is reported per cycle.
    static let backfillDisabled = false

    func startBackfill(account: Account) {
        if Self.backfillDisabled { print("[Backfill] SKIPPED \(account.emailAddress) — backfillDisabled"); return }
        let accountId = account.id
        guard providers[accountId] != nil else { print("[Backfill] SKIPPED \(account.emailAddress) — no provider"); return }

        if headerBackfillTasks[accountId] == nil {
            print("[Backfill] Starting for \(account.emailAddress)")
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
                        try? await Task.sleep(for: .seconds(60))
                        continue
                    }

                    // PAUSE THE WHOLE CRAWL while a privileged merge holds the gate.
                    // The per-write facade yield only steps the GRDB writes aside;
                    // this parks the entire batch (network fetch + body render CPU +
                    // FTS index) so a foreground NSE→inbox merge runs unburdened.
                    // No-op when nothing privileged is active.
                    await PriorityGate.shared.yield("backfill-walk")

                    // Pause backfill when user has WiFi-only setting enabled and we're on cellular.
                    // Uses checkExpensive() (Mutex-backed) as WiFi proxy — on iOS, expensive == cellular/hotspot.
                    // Pauses (not stops) so backfill resumes instantly when WiFi returns or setting is toggled.
                    let wifiOnly = UserDefaults.standard.object(forKey: "backgroundSyncWiFiOnly") as? Bool ?? true
                    if wifiOnly && NetworkMonitor.checkExpensive() {
                        print("[Backfill] \(account.emailAddress) paused — WiFi-only enabled, on cellular")
                        try? await Task.sleep(for: .seconds(30))
                        continue
                    }

                    guard !Task.isCancelled else { print("[Backfill] \(account.emailAddress) cancelled"); break }

                    let profile = await self?.getBackfillProfile() ?? .low
                    print("[Backfill] \(account.emailAddress) cycle start (profile=\(profile))")
                    let didWork = await self?.runBackfill(account: account) ?? false
                    await self?.updateBackfillProgressForAccount(account)

                    if !didWork {
                        let walkDone = await self?.isFolderWalkComplete(account: account) ?? false
                        print("[Backfill] \(account.emailAddress) no work, walkDone=\(walkDone)")
                        guard walkDone else {
                            let sleepDelay = profile.interCycleActiveDelay
                            try? await Task.sleep(for: .seconds(sleepDelay))
                            continue
                        }

                        // Mark cc/bcc backfill done after first full crawl cycle completes
                        if !UserDefaults.standard.bool(forKey: "ccBccBackfillDone") {
                            UserDefaults.standard.set(true, forKey: "ccBccBackfillDone")
                            print("[Backfill] cc/bcc backfill marked complete for account \(accountId)")
                        }

                        // All folders walked — body fetch handled by BackfillBodyQueue
                        break
                    }

                    let sleepSeconds = profile.interCycleActiveDelay
                    try? await Task.sleep(for: .seconds(sleepSeconds))
                }

                // Only clear dictionary if this task is still the current generation.
                print("[Backfill] \(account.emailAddress) walk loop ended")
                await self?.clearBackfillTaskIfCurrent(accountId: accountId, generation: gen)
            }
        } else {
            print("[Backfill] \(account.emailAddress) already has active backfill task")
        }
    }

    // MARK: - Progress Helpers

    /// Clear backfill task from dictionary only if the generation matches.
    /// Prevents a finishing old task from overwriting a new task started by resetCrawlState.
    func clearBackfillTaskIfCurrent(accountId: String, generation: Int) {
        guard backfillGeneration[accountId] == generation else {
            print("[Backfill] Skipping clearBackfillTask — generation mismatch (task=\(generation), current=\(backfillGeneration[accountId] ?? -1))")
            return
        }
        headerBackfillTasks[accountId] = nil
    }

    /// Query current backfill state and push to AccountManager for UI.
    /// Derives headersDone from DB (all folders backfillComplete) — no in-memory cache.
    func updateBackfillProgressForAccount(_ account: Account) async {
        let accountId = account.id

        // Quick DB check: are all folders done? + UID walk progress
        let (incompleteFolders, uidTotal, uidWalked) = (try? await dbPool.read { db -> (Int, Int, Int) in
            let folders = try Folder.filter(
                Column("accountId") == accountId &&
                Column("path") != ""
            ).fetchAll(db)
            let incomplete = folders.filter { !$0.backfillComplete }.count
            // UID progress: sum of (UIDNEXT-1) for total scope, walked = total - remaining cursors
            var total = 0
            var walked = 0
            for folder in folders {
                let uidNext = folder.lastKnownUidNext ?? 0
                guard uidNext > 0 else { continue }
                let folderTotal = uidNext - 1
                total += folderTotal
                if folder.backfillComplete {
                    walked += folderTotal  // Fully walked
                } else if let cursor = folder.backfillUidCursor {
                    walked += max(0, folderTotal - cursor)  // Partially walked
                }
                // cursor == nil && !complete → not started, walked = 0
            }
            return (incomplete, total, walked)
        }) ?? (1, 0, 0)
        let headersDone = incompleteFolders == 0

        // GRDB is sole authority for body status flags
        let (grdbTotal, grdbIndexed, pendingBody) = (try? await dbPool.read { db -> (Int, Int, Int) in
            let total = try MessageHeader.filter(Column("accountId") == accountId).fetchCount(db)
            let indexed = try MessageHeader.filter(
                Column("accountId") == accountId &&
                (Column("bodyComplete") == true || Column("bodyEmptyConfirmed") == true)
            ).fetchCount(db)
            // Body-eligible headers still awaiting fetch — same criteria the body
            // queues use (BackfillBodyQueue/ActiveBodyQueue: headerComplete=1,
            // no body yet, not confirmed-empty). Completion gates on this reaching
            // 0, not on an exact count match against a server-reported total.
            let pending = try MessageHeader.filter(
                Column("accountId") == accountId &&
                Column("headerComplete") == true &&
                Column("bodyComplete") == false &&
                Column("bodyEmptyConfirmed") == false
            ).fetchCount(db)
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
        if uidTotal == 0 && !headersDone {
            // Fetch & cache server total on first call
            if serverMessageTotal[accountId] == nil {
                if let gp = providers[accountId] as? GmailProvider {
                    if let t = try? await gp.getMessagesTotal(), t > 0 { serverMessageTotal[accountId] = t }
                } else if providers[accountId] is ExchangeProvider {
                    // Exchange folders don't overlap — sum totalCount from DB
                    let sum = (try? await dbPool.read { db in
                        try Int.fetchOne(db, sql: """
                            SELECT COALESCE(SUM(totalCount), 0) FROM folder
                            WHERE accountId = ? AND path != ''
                            """, arguments: [accountId])
                    }) ?? nil
                    if let s = sum, s > 0 { serverMessageTotal[accountId] = s }
                }
            }
            if let serverTotal = serverMessageTotal[accountId], serverTotal > grdbTotal {
                totalEmails = serverTotal
                // ftsIndexed stays as-is (bodies indexed), total becomes server count
            }
        }

        await AccountManager.shared.updateBackfillProgress(
                accountId: accountId, email: account.emailAddress,
                headersDone: headersDone, isPaused: false,
                totalEmails: totalEmails, ftsIndexed: ftsIndexed,
                uidTotal: uidTotal, uidWalked: uidWalked,
                pendingBodyCount: pendingBody
            )
    }

    /// Check if all folders have been walked for an account (header crawl complete).
    /// Does NOT check FTS body completion — body fetch is handled by BackfillBodyQueue.
    func isFolderWalkComplete(account: Account) async -> Bool {
        let accountId = account.id
        let incompleteFolders = (try? await dbPool.read { db in
            try Folder.filter(
                Column("accountId") == accountId &&
                Column("backfillComplete") == false &&
                Column("path") != ""
            ).fetchCount(db)
        }) ?? 0
        return incompleteFolders == 0
    }

}
