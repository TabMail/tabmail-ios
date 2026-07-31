/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
private actor ProgressThrottle {
    private var lastUpdate: Date = .distantPast
    private static let intervalSeconds: TimeInterval = 1

    func shouldUpdate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= Self.intervalSeconds else { return false }
        lastUpdate = now
        return true
    }
}

/// Thread-safe cursor for distributing UID batches to parallel workers.
/// Unlike UIDWalkCursor which generates contiguous ranges, this consumes
/// a pre-computed list of existing UIDs (from UID SEARCH).
private actor UIDListCursor {
    private let uids: [UInt32]
    private var index: Int = 0
    private let batchSize: Int

    init(uids: [UInt32], batchSize: Int) {
        self.uids = uids
        self.batchSize = batchSize
    }

    func nextBatch() -> [UInt32]? {
        guard index < uids.count else { return nil }
        let end = min(index + batchSize, uids.count)
        let batch = Array(uids[index..<end])
        index = end
        return batch
    }
}

/// What one parallel backfill worker reports back to the walk.
///
/// Round 8: this used to be a bare `Bool` (did-work). The walk now also has to
/// know whether ANY worker saw the folder's UIDVALIDITY move under it, because
/// that decides whether this pass's confirmed-range accounting describes the UID
/// space the walk started in — see `SyncEngine.runBackfill`'s epoch handling.
/// Returned by value rather than accumulated in shared state on purpose: a
/// `TaskGroup` result is already the file's established channel for
/// `workerDidWork`, and adding a second one costs no synchronisation.
private struct BackfillWorkerOutcome: Sendable {
    var didWork = false
    var epochDisagreed = false
}

extension SyncEngine {

    // MARK: - T1.3 anti-brick: the crawl's epoch bootstrap, BOUND to its UIDs

    /// Bootstrap `Folder.lastKnownUidValidity` from an epoch the CRAWL observed —
    /// and only when that epoch provably describes every local UID in the folder.
    ///
    /// 🚨 **THE COLUMN'S MEANING IS "the epoch the LOCAL UIDs belong to", NOT
    /// "the epoch the server most recently reported".** `AccountManager
    /// .newGestureRefusedForUnknownEpoch` tests only `lastKnownUidValidity == nil`
    /// — it never compares stored against live — so stamping ANY value, right or
    /// wrong, unlocks every gesture on every header in that folder. A header with
    /// no `rfc822MessageId` has `MessageHeader.stableId` fall back to its bare
    /// numeric UID, and `IMAPProvider.resolveUID` treats a numeric id as a LITERAL
    /// UID. Stamp an epoch the local rows do not belong to and the next gesture
    /// mutates whatever message now occupies that number — constraint C3, the one
    /// hard invariant.
    ///
    /// Hence the `localHeaders == 0` precondition, evaluated INSIDE the caller's
    /// write transaction (the TOCTOU rule: a count read before a network round trip
    /// cannot decide a write that happens after it). With no local rows the claim
    /// "every local UID belongs to `observed`" is vacuously true, and it STAYS true
    /// for the rows the crawl then inserts — because the walk refuses to insert any
    /// chunk whose own SELECT reported a different epoch (see `runBackfill`). Every
    /// caller must therefore stamp BEFORE the walk inserts anything; a post-walk
    /// stamp would find the count non-zero from its own inserts and, worse, would
    /// be sampling an epoch nothing bound to those inserts.
    ///
    /// ⚑ R0 — this precondition has **NO REFERENCE in `v2final`** and is a v3
    /// addition. It is not needed there: `v2final` carries the whole ADR-IOS-061
    /// reset reaction (`uidValidityResetPendingAt` quarantine → purge of the rows
    /// belonging to the old epoch → stamp → resync), so a turnover cannot leave
    /// old-epoch rows sitting under a new-epoch stamp. v3 has ported none of that
    /// machinery. Until it does, a folder that ALREADY holds rows of unproven epoch
    /// cannot be stamped by the crawl, and this fails CLOSED — the folder keeps
    /// refusing gestures. That is the sanctioned trade (C6/C3): a wrong stamp is
    /// silent data corruption, a refusal is a silent no-op. It is not a permanent
    /// brick for anything the new code produces, because the fresh-cursor branch
    /// stamps at the moment the crawl plants its first cursor, when the count is
    /// still zero: from this build on, `backfillUidCursor != nil` implies the epoch
    /// was already bootstrapped (or the server reports none at all, which nothing
    /// can fix). Folders left half-crawled by an OLDER build keep a nil epoch; no
    /// backward compatibility is required (owner constraint C6) and Smart Reindex
    /// (`SyncEngine.resetCrawlState`) does not recover them either, since it clears
    /// cursors without clearing headers.
    ///
    /// ⚠ **RETRACTION (round 8) — the crawl is NOT the only pass that reaches a
    /// custom non-favourite folder.** Round 7 asserted that, in five places, and it
    /// is false. `syncableFolders` excludes such a folder from full sync, delta
    /// sync and self-heal, but ON-DEMAND NAVIGATION reaches ANY folder:
    /// `InboxView.onAppear` → `InboxViewModel.startSync()` → `performSync()` →
    /// `AccountManager.syncFolders(_:)` (in `AccountManagerFetch.swift`, which
    /// filters on `!folder.path.isEmpty` alone — no role predicate, no favourite
    /// predicate) → `SyncEngine.syncFolderMessages` → `syncMessages` →
    /// `runSyncMessages`, carrying T1.2b's SELECT-sourced bootstrap.
    /// `SyncEngineFullSync.swift` says so itself, three lines under the
    /// `syncableFolders` construction: *"Custom non-favorited folders sync
    /// on-demand when the user navigates to them."*
    ///
    /// So the pre-fix refusal was never permanent — it was bounded by "the user
    /// opens that folder once". It was still a real and INDEFINITE bug, because
    /// backfill makes that folder's mail reachable by account-wide search while the
    /// user may never open the folder itself, which is why this bootstrap exists.
    /// Say "indefinite until the user opens the folder", never "permanent".
    ///
    /// Returns whether the gated UPDATE was issued — for logging only. The UPDATE
    /// itself is still `bootstrapFolderUidValidity`'s, so it also carries
    /// `lastKnownUidValidity IS NULL` in the statement and can never overwrite.
    /// May a crawl walking under `walk` touch a folder whose local rows are
    /// stamped `stored`?
    ///
    /// A DISAGREEMENT means the mailbox was re-created since the folder's rows
    /// were written: every local UID belongs to a numbering that no longer
    /// exists, and every UID the walk is about to fetch belongs to one those rows
    /// know nothing about. Inserting into that folder mixes two numberings under
    /// one stamp, and half the resulting rows resolve a bare-UID gesture against
    /// the wrong message. There is no correct crawl to run here — only a
    /// purge-and-resync, which v3 has not ported (ADR-IOS-061's reaction). So the
    /// crawl declines the folder, which is fail-closed and costs one SELECT per
    /// cycle until that reaction exists.
    ///
    /// Either side UNKNOWN admits: a nil `stored` is the ordinary first-crawl
    /// case this whole item exists to serve, and a nil `walk` is a server that
    /// does not report UIDVALIDITY on SELECT at all — refusing every crawl for
    /// such an account would be a far larger change than any epoch guard needs.
    ///
    /// REFERENCE (`v2final`): the same observed-vs-stored comparison, expressed
    /// as `uidValidityWalkWriteAllowed` / `uidValidityWriteAllowed`, re-read
    /// inside each bookkeeping write's own transaction and combined there with a
    /// `uidValidityResetPendingAt` quarantine flag v3 does not have. The
    /// comparison ports; the quarantine does not.
    nonisolated static func crawlEpochAgrees(stored: UInt32?, walk: UInt32?) -> Bool {
        guard let stored, let walk else { return true }
        return stored == walk
    }

    nonisolated static func bootstrapCrawledFolderUidValidity(
        _ db: Database, folderId: String, observed: UInt32?
    ) throws -> Bool {
        guard let observed, let epoch = knownUidValidity(Int(observed)) else { return false }
        let localHeaders = try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        guard localHeaders == 0 else { return false }
        try Self.bootstrapFolderUidValidity(db, folderId: folderId, observed: epoch)
        return true
    }

    // MARK: - Unified Backfill Walk

    /// Crawl folders for this account, inserting headers AND indexing bodies in the same walk.
    /// Gmail/Exchange: single API call per message (format=full) — headers + body together.
    /// IMAP: header fetch then body fetch in the same iteration (protocol limitation).
    /// After walking all folders, runs a cleanup pass for any remaining empty bodies.
    /// Returns true if any work was done.
    func runBackfill(account: Account, deadline: Date? = nil) async -> Bool {
        var didWork = false
        let fastSync = await getIsFastSync()
        let isPastDeadline: () -> Bool = {
            guard let deadline else { return false }
            return Date() >= deadline
        }


        let incompleteFolders: [Folder]
        do {
            incompleteFolders = try await dbPool.read { db in
                try Folder.filter(
                    Column("accountId") == account.id &&
                    Column("backfillComplete") == false &&
                    Column("path") != ""
                ).fetchAll(db)
            }.sorted { a, b in
                func priority(_ f: Folder) -> Int {
                    switch f.role {
                    case .inbox: return 0
                    case .sent: return 1
                    case .archive: return 2
                    case .drafts: return 3
                    case .trash: return 4
                    case .spam: return 5
                    case .custom: return f.isFavorite ? 6 : 7
                    }
                }
                return priority(a) < priority(b)
            }
        } catch {
            print("[Backfill] Failed to fetch folders: \(error)")
            BackgroundSyncLogger.logError("Failed to fetch folders: \(error)", source: "backfill:\(account.emailAddress)")
            return false
        }

        guard !incompleteFolders.isEmpty else { return false }
        guard let provider = providers[account.id] else { return false }
        guard let workQueue = workQueues[account.id] else { return false }

        print("[Backfill] Starting for \(account.emailAddress): \(incompleteFolders.count) folders to backfill")
        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) walk: \(incompleteFolders.count) incomplete folders")

        var consecutiveConnectionFailures = 0
        var connectionBackoffSeconds: TimeInterval = 5  // Exponential backoff: 5, 10, 20, 40, 60 (max)
        var previousFolderId: String?  // Skip interFolderDelay when continuing same folder
        // Chunk sizes are managed per-folder by UIDWalkCursor (with recovery).
        // No cross-folder contamination — each folder gets a fresh cursor.

        // T1.3 (round 8): folders this CALL has declined on UIDVALIDITY grounds —
        // the walk observed an epoch the folder's rows do not belong to, or the
        // mailbox moved under an in-flight walk. Neither case writes
        // `backfillComplete`, so without this set the loop below re-reads the
        // folder as "still incomplete" and immediately walks it again — under the
        // NEW epoch, inserting exactly the mixed-epoch population the refusal was
        // for. (`v2final` needs no such set: its refusals persist through the
        // `uidValidityResetPendingAt` quarantine column, which v3 has not ported.)
        var epochDeclinedFolderIds = Set<String>()

        await updateBackfillProgressForAccount(account)

        // ── Backward crawl — one folder at a time, most recent first ──
        // Each iteration picks the incomplete folder whose oldestSyncedDate is most
        // recent (shallowest crawl depth), fetches older messages via UID/page-token walk.
        // IMAP: walks from UIDNEXT-1 backward to UID 1.
        // Gmail/Exchange: page-token walk from newest to oldest.
        while true {
            guard !Task.isCancelled else { return didWork }
            guard !isPastDeadline() else { break }

            // Fresh DB read each iteration so we see folders completed by Step 1 or previous iterations
            let remaining: [Folder]
            do {
                remaining = try await dbPool.read { db in
                    try Folder.filter(
                        Column("accountId") == account.id &&
                        Column("backfillComplete") == false &&
                        Column("path") != ""
                    ).fetchAll(db)
                }
            } catch { break }
            guard !remaining.isEmpty else { break }

            // Pick folder by role priority (inbox→sent→archive→…→custom),
            // then most recent oldestSyncedDate within the same tier.
            func crawlPriority(_ f: Folder) -> Int {
                switch f.role {
                case .inbox: return 0
                case .sent: return 1
                case .archive: return 2
                case .drafts: return 3
                case .trash: return 4
                case .spam: return 5
                case .custom: return f.isFavorite ? 6 : 7
                }
            }
            let isExpensiveNetwork = NetworkMonitor.checkExpensive()
            let folder = remaining
                .filter { f in
                    if epochDeclinedFolderIds.contains(f.id) { return false }
                    if !fastSync && isExpensiveNetwork && !primaryRoles.contains(f.role) { return false }
                    if StorageEstimator.isOverBudget() { return false }
                    return true
                }
                .sorted { a, b in
                    let pa = crawlPriority(a), pb = crawlPriority(b)
                    if pa != pb { return pa < pb }
                    return (a.oldestSyncedDate ?? .distantFuture) > (b.oldestSyncedDate ?? .distantFuture)
                }
                .first

            guard let folder else {
                // All remaining folders are gated — done for this cycle
                break
            }

            let profile = await getBackfillProfile()
            let limit = profile.backfillChunkSize
            do {
                var headers: [MessageHeaderInfo] = []
                var isLastPage = false  // Gmail/Exchange: true when page-token walk has no more pages
                var insertedCount = 0

                if let imapProvider = provider as? IMAPProvider {
                    // IMAP: parallel UID walk with SEARCH-before-FETCH optimization.
                    // Same chunk structure as before (UIDWalkCursor, parallel workers),
                    // but each chunk does UID SEARCH first → if empty, skip FETCH entirely.
                    // For sparse folders (INBOX: 69k UIDs, 6 msgs) this skips ~99% of FETCHes.
                    // For dense folders, the extra SEARCH per chunk is ~3.5KB — negligible.

                    // Initialize cursor (from DB or UIDNEXT)
                    let cursorValue: Int
                    // T1.3 (round 8) — THE WALK'S OWN EPOCH, captured ONCE here and
                    // never re-read live afterwards. Two things depend on it: the
                    // gated bootstrap below (the anti-brick), and every worker's
                    // per-chunk agreement check (the C3 guard). A live re-read at
                    // the END of the walk is exactly the round-7 blocker: by then
                    // the shared per-folder-path mirror can describe a turnover
                    // that happened mid-crawl, and stamping THAT value asserts it
                    // of UIDs the walk inserted under the old numbering.
                    //
                    // REFERENCE (`v2final`): `walkEpoch` in the same function, same
                    // two branches, same rationale (ADR-IOS-061 item C / R4-2) —
                    // including the forced fresh observation on the RESUMED branch,
                    // where the pinned connection may already exist from an earlier
                    // pass and the mirror is therefore cold or stale.
                    let walkEpoch: UInt32?
                    // Set when the resumed branch's own bootstrap transaction
                    // THREW. See its use at the completion write below: NB2 —
                    // `backfillComplete` must not be stamped by a pass whose epoch
                    // bootstrap failed, or the folder is never revisited and the
                    // failure is permanent.
                    var epochBootstrapWriteFailed = false
                    // The epoch the folder's EXISTING rows belong to. `walkEpoch`
                    // must agree with it or the walk is about to mix two
                    // numberings under one stamp — see `crawlEpochAgrees`.
                    let storedEpoch = Self.knownUidValidity(folder.lastKnownUidValidity)
                        .flatMap { UInt32(exactly: $0) }
                    if let existing = folder.backfillUidCursor {
                        cursorValue = existing
                        // Force one fresh observation. The pinned connection's own
                        // creation SELECT may have happened in an earlier pass (or
                        // an earlier folder's iteration), so reading the mirror
                        // bare here can hand back an epoch that describes neither
                        // this pass nor this moment.
                        _ = try? await workQueue.execute(priority: .headerFetch) {
                            try await imapProvider.getUidNext(folder: folder.path)
                        }
                        walkEpoch = imapProvider.lastObservedUidValidity(folderPath: folder.path)
                        guard Self.crawlEpochAgrees(stored: storedEpoch, walk: walkEpoch) else {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name) declined: rows belong to UIDVALIDITY \(String(describing: storedEpoch)), server is at \(String(describing: walkEpoch))")
                            }
                            continue
                        }
                        if walkEpoch != nil {
                            let folderId = folder.id
                            let observed = walkEpoch
                            do {
                                let stamped = try await AppDatabase.backgroundPool.write { db in
                                    try Self.bootstrapCrawledFolderUidValidity(
                                        db, folderId: folderId, observed: observed)
                                }
                                if stamped, DebugModeManager.isLoggingEnabled() {
                                    print("[Backfill] \(folder.name) epoch bootstrapped from resumed walk")
                                }
                            } catch {
                                epochBootstrapWriteFailed = true
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Backfill] \(folder.name) epoch bootstrap write failed: \(error) — withholding backfillComplete so this pass is retried")
                                }
                            }
                        }
                    } else {
                        let uidNext = try await workQueue.execute(priority: .headerFetch) {
                            try await imapProvider.getUidNext(folder: folder.path)
                        }
                        // Captured immediately after the fetch that produced
                        // `uidNext` — `getUidNext` performs a TRACKED SELECT of
                        // this folder, so this is that SELECT's own epoch and not
                        // some later one (capture-at-fetch).
                        walkEpoch = imapProvider.lastObservedUidValidity(folderPath: folder.path)
                        guard Self.crawlEpochAgrees(stored: storedEpoch, walk: walkEpoch) else {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name) declined: rows belong to UIDVALIDITY \(String(describing: storedEpoch)), server is at \(String(describing: walkEpoch))")
                            }
                            continue
                        }
                        let folderId = folder.id
                        let initialCursor = uidNext - 1
                        if initialCursor < 1 {
                            // NB3 (round 8): this early-out used to skip the epoch
                            // bootstrap entirely. It must not: `getUidNext` above
                            // did a tracked SELECT, so the epoch IS known here, and
                            // this branch fires both for a genuinely empty mailbox
                            // (UIDNEXT == 1) and for a server that reported no
                            // UIDNEXT at all (SwiftMail defaults it to 0, giving
                            // `initialCursor == -1`). Both leave the folder
                            // `backfillComplete` and never revisited — so a folder
                            // that took this branch could never be stamped by any
                            // later pass. Same transaction as the completion write,
                            // so a failure of either leaves the folder incomplete
                            // and it is retried (NB2).
                            try? await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folderId)
                                    .updateAll(db,
                                        Column("backfillComplete").set(to: true),
                                        Column("lastKnownUidNext").set(to: uidNext)
                                    )
                                _ = try Self.bootstrapCrawledFolderUidValidity(
                                    db, folderId: folderId, observed: walkEpoch)
                            }
                            print("[Backfill] \(folder.name) fully crawled (UIDNEXT=1, no messages)")
                            didWork = true
                            await updateBackfillProgressForAccount(account)
                            continue
                        }
                        // THE ANTI-BRICK STAMP. Here, not after the walk: this is
                        // the last moment at which the folder provably holds no
                        // local UID this epoch cannot account for, and the gate
                        // inside `bootstrapCrawledFolderUidValidity` is evaluated
                        // in THIS transaction. Sharing the transaction with the
                        // initial-cursor write is also NB2's fix — the two land
                        // together or not at all, and a throw propagates to the
                        // folder loop's `catch`, which retries next cycle.
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folderId)
                                .updateAll(db,
                                    Column("backfillUidCursor").set(to: initialCursor),
                                    Column("lastKnownUidNext").set(to: uidNext)
                                )
                            _ = try Self.bootstrapCrawledFolderUidValidity(
                                db, folderId: folderId, observed: walkEpoch)
                        }
                        cursorValue = initialCursor
                    }

                    let cursor = UIDWalkCursor(startCursor: cursorValue, chunkSize: limit)
                    let poolMax = await imapProvider.poolMaxConnections()
                    let workerCount = poolMax < Int.max ? poolMax : SyncConfig.imapMaxConnectionCeiling
                    let folderCaptured = folder
                    let batchSize = profile.imapFetchBatchSize
                    let interBatchDelay = profile.imapInterBatchDelay
                    let lastProgressUpdate = ProgressThrottle()
                    let accountCaptured = account

                    // T1.3 (round 8): the epoch every chunk of this walk must agree
                    // with. nil disables the check entirely — a server that never
                    // reports UIDVALIDITY on SELECT has no epoch to compare against,
                    // and refusing its crawl outright would break backfill for that
                    // whole account. `v2final` DOES refuse there (its `guard
                    // observedEpoch != nil` on the final bookkeeping), and this port
                    // deliberately does not: the reference can afford it because the
                    // ADR-IOS-061 reset reaction gives an epochless server another
                    // way through, and v3 has no such machinery. Nothing is stamped
                    // in that case either, so such a folder keeps refusing gestures —
                    // which is what `IOS-EPOCH-001` already documents.
                    let expectedEpoch = walkEpoch
                    var epochMovedMidWalk = false
                    await withTaskGroup(of: BackfillWorkerOutcome.self) { group in
                        for workerIndex in 0..<workerCount {
                            group.addTask { [self] in
                                var outcome = BackfillWorkerOutcome()
                                // Round 8: did the epoch just observed on THIS
                                // worker's own SELECT still describe the UID space
                                // the walk started in? A disagreement means the
                                // mailbox was re-created mid-crawl, so the range is
                                // returned UNCONFIRMED and this worker stops — the
                                // rows it would otherwise insert belong to a
                                // different numbering than the one the folder was
                                // stamped with, and mixing them is precisely the C3
                                // hazard. BREAK rather than continue, for the same
                                // reason `v2final` does: failed ranges are served
                                // first by `nextRange`, so looping would re-fetch
                                // the same range forever — the turnover cannot undo
                                // itself mid-pass.
                                let epochStillAgrees: () -> Bool = {
                                    guard let expectedEpoch else { return true }
                                    return imapProvider.lastObservedUidValidity(
                                        folderPath: folderCaptured.path) == expectedEpoch
                                }
                                while let range = await cursor.nextRange() {
                                    guard !Task.isCancelled else {
                                        // Cancelled — return range for retry next cycle
                                        await cursor.failRange(from: range.from, to: range.to)
                                        break
                                    }

                                    // SEARCH first: discover which UIDs exist in this range
                                    let existingUIDs: [UInt32]
                                    do {
                                        existingUIDs = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.searchExistingUIDs(
                                                folder: folderCaptured.path, from: range.from, to: range.to
                                            )
                                        }
                                    } catch {
                                        // SEARCH failed — return range for retry
                                        await cursor.failRange(from: range.from, to: range.to)
                                        if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH connection error: \(error)")
                                            break
                                        }
                                        print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH error: \(error)")
                                        continue
                                    }

                                    // Capture-at-fetch: `searchExistingUIDs` just did
                                    // a TRACKED SELECT of this folder, so the mirror
                                    // now holds the epoch this range's answer came
                                    // from. Check BEFORE confirming an empty range —
                                    // "no UIDs here" is a statement about a UID
                                    // space, and confirming it against the wrong one
                                    // advances the cursor past mail that still
                                    // exists in the space the walk is accounting for.
                                    guard epochStillAgrees() else {
                                        await cursor.failRange(from: range.from, to: range.to)
                                        outcome.epochDisagreed = true
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) range \(range.from)...\(range.to) refused after SEARCH — UIDVALIDITY moved mid-walk")
                                        }
                                        break
                                    }

                                    if existingUIDs.isEmpty {
                                        // No messages in this range — confirmed empty, safe to advance
                                        await cursor.confirmRange(from: range.from, to: range.to)
                                        if await lastProgressUpdate.shouldUpdate() {
                                            let snapshotCursor = await cursor.currentCursor
                                            try? await AppDatabase.backgroundPool.write { db in
                                                _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                    .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                            }
                                            await self.updateBackfillProgressForAccount(accountCaptured)
                                        }
                                        continue
                                    }

                                    print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH found \(existingUIDs.count) UIDs in \(range.from)...\(range.to)")

                                    // FETCH only the existing UIDs
                                    let fetchedHeaders: [MessageHeaderInfo]
                                    do {
                                        fetchedHeaders = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.fetchMessageHeaders(
                                                folder: folderCaptured.path, uids: existingUIDs,
                                                batchSize: batchSize, interBatchDelay: interBatchDelay
                                            )
                                        }
                                    } catch {
                                        let desc = "\(error)"
                                        let isPayloadError = desc.contains("PayloadTooLargeError") || desc.contains("IMAPDecoderError")
                                        let isTimeout = desc.contains("timed out")
                                        if isPayloadError {
                                            let currentChunk = await cursor.currentChunkSize
                                            if currentChunk <= 1 {
                                                // Single UID too large — confirm anyway (can't split further)
                                                print("[Backfill] \(folderCaptured.name) w\(workerIndex) single UID too large — skipping")
                                                await cursor.confirmRange(from: range.from, to: range.to)
                                                continue
                                            }
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) payload too large, chunk → \(newChunk)")
                                            continue
                                        } else if isTimeout {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) timeout, chunk → \(newChunk)")
                                            continue
                                        } else if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) connection error: \(error)")
                                            break
                                        } else {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) error: \(error)")
                                            BackgroundSyncLogger.logError("\(folderCaptured.name) w\(workerIndex) error: \(error)", source: "backfill")
                                            break
                                        }
                                    }

                                    // Capture-at-fetch again, and BEFORE the insert.
                                    // `fetchMessageHeaders` re-SELECTs (tracked) per
                                    // inner batch, so a turnover that happened
                                    // between this range's SEARCH and its FETCH is
                                    // visible here. These headers must NOT reach the
                                    // database: they carry UIDs from a numbering the
                                    // folder's stamped epoch does not describe, and
                                    // a later bare-UID gesture on one of them would
                                    // resolve against whatever now occupies that
                                    // number. `v2final` expresses the same refusal
                                    // as `insertBackfillBatch`'s `refused` return —
                                    // the shape differs, the rule ("a refused range
                                    // is FAILED, never confirmed") does not.
                                    guard epochStillAgrees() else {
                                        await cursor.failRange(from: range.from, to: range.to)
                                        outcome.epochDisagreed = true
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) range \(range.from)...\(range.to) refused after FETCH — UIDVALIDITY moved mid-walk, \(fetchedHeaders.count) headers discarded")
                                        }
                                        break
                                    }

                                    // Successfully fetched — insert to DB then confirm
                                    if !fetchedHeaders.isEmpty {
                                        let (inserted, ftsRecords, ccBccUpdates) = await self.insertBackfillBatch(
                                            fetchedHeaders, folderId: folderCaptured.id, accountId: folderCaptured.accountId,
                                            folderPath: folderCaptured.path, folderRole: folderCaptured.role, isInInbox: folderCaptured.role == .inbox
                                        )
                                        if !ftsRecords.isEmpty { await self.indexHeadersForFTS(ftsRecords) }
                                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                                        if inserted > 0 {
                                            outcome.didWork = true
                                            await BackfillBodyQueue.shared.enqueueItems(
                                                ftsRecords: ftsRecords, accountId: folderCaptured.accountId,
                                                folderPath: folderCaptured.path, isInInbox: folderCaptured.role == .inbox
                                            )
                                        }
                                    }

                                    // Confirm AFTER successful DB insert
                                    await cursor.confirmRange(from: range.from, to: range.to)

                                    if await lastProgressUpdate.shouldUpdate() {
                                        let snapshotCursor = await cursor.currentCursor
                                        try? await AppDatabase.backgroundPool.write { db in
                                            _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                        }
                                        await self.updateBackfillProgressForAccount(accountCaptured)
                                    }
                                }
                                return outcome
                            }
                        }
                        for await workerResult in group {
                            if workerResult.didWork { didWork = true }
                            if workerResult.epochDisagreed { epochMovedMidWalk = true }
                        }
                    }

                    // ⚠ THE EPOCH IS STAMPED AT WALK START, NOT HERE. Round 7 put a
                    // single POST-walk read of `imapProvider.lastObservedUidValidity`
                    // at this point and handed it to `bootstrapFolderUidValidity`.
                    // The write was correctly bootstrap-only; the VALUE was the
                    // defect. Nothing bound that sample to the UIDs the walk had
                    // just inserted — on a resumed crawl it could be an epoch the
                    // mailbox rolled to AFTER the previous pass's headers were
                    // written, and stamping it made `newGestureRefusedForUnknown
                    // Epoch` (which tests only for nil, never stored-vs-live) admit
                    // bare-UID gestures that then resolved against a different
                    // message. See `bootstrapCrawledFolderUidValidity` for the
                    // binding rule and `walkEpoch` above for the capture. Do not
                    // reintroduce a mirror read here, per chunk or otherwise.

                    // Persist confirmed cursor — only advances past ranges that succeeded
                    let finalCursor = await cursor.currentCursor
                    let isComplete = await cursor.isComplete
                    // A pass that saw the mailbox re-created under it accounted its
                    // confirmed ranges against a UID space that no longer exists, so
                    // neither the cursor nor completeness derived from them may be
                    // persisted. Nothing is lost: no range was confirmed after the
                    // disagreement (workers stop on it), and the ranges confirmed
                    // before it are simply re-walked next cycle — inserts are
                    // idempotent. `v2final` reaches the same outcome through its
                    // §5.5 in-transaction quarantine guard, which v3 has not ported.
                    if epochMovedMidWalk {
                        // …and this CALL must not immediately walk it again. The
                        // loop below re-reads the account's incomplete folders and
                        // would pick this one straight back up — with a fresh
                        // `walkEpoch` read from the mirror, which now describes the
                        // NEW mailbox. That second pass would insert post-turnover
                        // UIDs into a folder still stamped with the old epoch: the
                        // very mixing the per-chunk guard just prevented, one
                        // iteration later. (The stored-vs-walk guard at the top of
                        // the IMAP branch catches the same thing on a LATER call,
                        // once the folder has a stamp; this set covers the case
                        // where it does not yet.)
                        epochDeclinedFolderIds.insert(folder.id)
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Backfill] \(folder.name): UIDVALIDITY moved mid-walk — skipping cursor/completeness bookkeeping, retry next cycle")
                        }
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) UIDVALIDITY moved mid-walk — bookkeeping skipped")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }
                    if isComplete && epochBootstrapWriteFailed {
                        // NB2: a pass whose epoch bootstrap THREW must not be the
                        // pass that stamps `backfillComplete` — both `runBackfill`'s
                        // initial folder query and its per-iteration re-read filter
                        // on `backfillComplete == false`, so the folder would never
                        // be revisited and only a user-initiated Smart Reindex could
                        // ever give it an epoch again. The cursor still persists
                        // below, so the crawl KEEPS its progress and the next cycle
                        // re-tries only the tail plus the bootstrap — it cannot loop
                        // on work it has already done.
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillUidCursor").set(to: finalCursor))
                        }
                        print("[Backfill] \(folder.name) fully crawled but epoch bootstrap failed — withholding backfillComplete for one more cycle")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) epoch bootstrap failed — backfillComplete withheld")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }
                    if isComplete {
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillUidCursor").set(to: nil as Int?)
                                )
                        }
                        print("[Backfill] \(folder.name) fully crawled (all ranges confirmed)")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (all ranges confirmed)")
                    } else {
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillUidCursor").set(to: finalCursor))
                        }
                        let hasPending = await cursor.hasPendingWork
                        if hasPending {
                            print("[Backfill] \(folder.name) has failed ranges — will retry next cycle (cursor at \(finalCursor))")
                            BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) has failed ranges — retry next cycle (cursor at \(finalCursor))")
                        }
                    }
                    didWork = true
                    await updateBackfillProgressForAccount(account)
                    continue

                } else if provider is GmailProvider || provider is ExchangeProvider {
                    // Gmail/Exchange: page-token cursor walk — resumes from stored position.
                    // Each call returns one page of IDs + nextPageToken. No date filter needed;
                    // the token tracks position in the listing (newest→oldest).
                    let pageResult: (ids: [String], nextPageToken: String?)
                    if let gp = provider as? GmailProvider {
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await gp.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    } else {
                        let ep = provider as! ExchangeProvider
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await ep.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    }
                    let (pageIds, nextToken) = pageResult

                    if pageIds.isEmpty && nextToken == nil {
                        // No more pages — folder fully crawled
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillPageToken").set(to: nil as String?)
                                )
                        }
                        print("[Backfill] \(folder.name) fully crawled (no more pages)")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (no more pages)")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    // Page token is stored AFTER processing (not before) so that
                    // cancellation or failure mid-page causes the same page to be
                    // re-fetched next cycle. insertBackfillBatch handles dedup.

                    // Dedup returned IDs against DB
                    let missingIds: [String] = try await dbPool.read { db in
                        let sqlChunkSize = SyncConfig.sqlChunkSize
                        var existingIds = Set<String>()
                        for start in stride(from: 0, to: pageIds.count, by: sqlChunkSize) {
                            let end = min(start + sqlChunkSize, pageIds.count)
                            let chunk = Array(pageIds[start..<end])
                            let found = try String.fetchSet(db,
                                MessageHeader
                                    .select(Column("messageId"))
                                    .filter(Column("folderId") == folder.id && chunk.contains(Column("messageId")))
                            )
                            existingIds.formUnion(found)
                        }
                        return pageIds.filter { !existingIds.contains($0) }
                    }

                    if missingIds.isEmpty {
                        // All IDs on this page already in DB — update anchor for age cutoff tracking
                        let oldestDate: Date? = try? await dbPool.read { db in
                            try Date.fetchOne(db,
                                MessageHeader
                                    .select(min(Column("date")))
                                    .filter(Column("folderId") == folder.id && pageIds.contains(Column("messageId")))
                            )
                        }
                        if let d = oldestDate {
                            try await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db, Column("oldestSyncedDate").set(to: d))
                            }
                        }
                        // Safe to advance — all IDs on this page already exist in GRDB
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            try? await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db,
                                        Column("backfillComplete").set(to: true),
                                        Column("backfillPageToken").set(to: nil as String?)
                                    )
                            }
                            print("[Backfill] \(folder.name) fully crawled (last page, all exist)")
                            didWork = true
                        } else {
                            print("[Backfill] \(folder.name) all \(pageIds.count) IDs on page already exist — advancing to next page")
                        }
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    print("[Backfill] \(folder.name) \(missingIds.count) missing of \(pageIds.count) IDs on page")

                    // Unified fetch: headers + bodies in a single API call per message.
                    // Stream maintains `concurrency` in-flight HTTP requests at all times.
                    // We collect all results, then batch-insert headers and write bodies to FTS.
                    let stream: AsyncStream<BackfillResult>
                    let bodyConcurrency = profile.gmailBodyConcurrency
                    if let gp = provider as? GmailProvider {
                        stream = await gp.fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    } else {
                        stream = await (provider as! ExchangeProvider).fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    }

                    // Consume streaming results — collect headers + bodies together.
                    // Body data is keyed by messageId for matching after GRDB insert.
                    var bodyData: [String: (htmlBody: String?, textBody: String?)] = [:]
                    var streamInterrupted = false

                    for await result in stream {
                        if Task.isCancelled {
                            streamInterrupted = true
                            break
                        }
                        if let header = result.header {
                            headers.append(header)
                            bodyData[result.id] = (htmlBody: result.htmlBody, textBody: result.textBody)
                        }
                        if let error = result.error, case ProviderError.authenticationFailed = error {
                            await AccountManager.shared.markAuthFailed(account.id)
                            throw error
                        }
                    }

                    if !headers.isEmpty {
                        // Step 1: Insert headers to GRDB (batch dedup)
                        let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                            headers, folderId: folder.id, accountId: folder.accountId,
                            folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
                        )
                        if !ftsRecords.isEmpty { await indexHeadersForFTS(ftsRecords) }
                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                        insertedCount = inserted

                        // Step 2: Write bodies to FTS for inserted messages.
                        // Match body data to headerIds using ftsRecords (which have headerId + messageId).
                        var ftsBodyBuffer: [(headerId: String, body: String)] = []
                        var snippetBuffer: [(headerId: String, snippet: String)] = []
                        for ftsRecord in ftsRecords {
                            if let body = bodyData[ftsRecord.messageId] {
                                let plainText = EmailFilter.extractPlainText(htmlBody: body.htmlBody, textBody: body.textBody)
                                if let plainText, !plainText.isEmpty {
                                    ftsBodyBuffer.append((headerId: ftsRecord.headerId, body: plainText))
                                    let snippet = EmailFilter.snippetFromPlainText(plainText)
                                    snippetBuffer.append((headerId: ftsRecord.headerId, snippet: snippet))
                                }
                            }
                        }
                        if !ftsBodyBuffer.isEmpty {
                            do {
                                let writtenIds = try await SearchIndex.shared.updateBodies(ftsBodyBuffer)
                                // Only set bodyComplete for items actually written to FTS.
                                let confirmedSnippets = snippetBuffer.filter { writtenIds.contains($0.headerId) }
                                applySnippetUpdates(confirmedSnippets)
                                let skipped = ftsBodyBuffer.count - writtenIds.count
                                if skipped > 0 {
                                    print("[Backfill] \(folder.name) wrote \(writtenIds.count)/\(ftsBodyBuffer.count) bodies to FTS (\(skipped) deferred)")
                                } else {
                                    print("[Backfill] \(folder.name) wrote \(ftsBodyBuffer.count) bodies to FTS")
                                }
                            } catch {
                                print("[Backfill] FTS body write failed: \(error)")
                                BackgroundSyncLogger.logError("FTS body write failed for \(folder.name): \(error)", source: "backfill")
                            }
                        }

                        // Enqueue to ActiveBodyQueue — items with bodies already in FTS will be
                        // skipped (forwarding inbox items to ActiveAIQueue); items without
                        // bodies will be fetched by the queue.
                        if !ftsRecords.isEmpty {
                            await BackfillBodyQueue.shared.enqueueItems(
                                ftsRecords: ftsRecords, accountId: folder.accountId,
                                folderPath: folder.path, isInInbox: folder.role == .inbox
                            )
                        }
                    }

                    // Only advance page token if the full page was consumed.
                    // If stream was interrupted (cancellation), don't advance — the
                    // same page will be re-fetched next cycle (dedup handles duplicates).
                    if !streamInterrupted {
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            isLastPage = true
                        }
                    } else {
                        print("[Backfill] \(folder.name) stream interrupted — NOT advancing page token")
                    }
                } else {
                    break
                }

                if headers.isEmpty {
                    print("[Backfill] \(folder.name) fetch returned 0 headers — will retry next cycle")
                    continue
                }

                print("[Backfill] \(folder.name) fetched \(headers.count) older messages")

                // Update oldestSyncedDate from oldest fetched message
                if let oldest = headers.min(by: { $0.date < $1.date }) {
                    try await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db, Column("oldestSyncedDate").set(to: oldest.date))
                    }
                }

                // Gmail/Exchange: mark folder complete if this was the last page
                if isLastPage {
                    try? await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db,
                                Column("backfillComplete").set(to: true),
                                Column("backfillPageToken").set(to: nil as String?)
                            )
                    }
                    print("[Backfill] \(folder.name) fully crawled (last page processed)")
                    BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (last page processed)")
                }

                if insertedCount > 0 || isLastPage { didWork = true }
                consecutiveConnectionFailures = 0
                connectionBackoffSeconds = 5  // Reset backoff on success
            } catch is CancellationError {
                return didWork
            } catch {
                print("[Backfill] Failed for \(folder.name): \(error)")
                BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) cycle error: \(error)")
                if !Self.isConnectionError(error) && !Self.isSelectFailedError(error) {
                    BackgroundSyncLogger.logError("Failed for \(folder.name): \(error)", source: "backfill:\(account.emailAddress)")
                }
                if case ProviderError.authenticationFailed = error {
                    await AccountManager.shared.markAuthFailed(account.id)
                    return didWork
                }
                if Self.isSelectFailedError(error) || Self.isConnectionError(error) {
                    // Treat SELECT failures as transient in backfill — the folder exists
                    // but the connection may be stale. Exponential backoff instead of aborting.
                    // Pool self-heals: dead connections are discarded on checkin(healthy: false),
                    // next checkout creates a fresh one.
                    consecutiveConnectionFailures += 1
                    print("[Backfill] Connection failure \(consecutiveConnectionFailures) — backing off \(Int(connectionBackoffSeconds))s")
                    BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) connection failure #\(consecutiveConnectionFailures) — backoff \(Int(connectionBackoffSeconds))s")
                    try? await Task.sleep(for: .seconds(connectionBackoffSeconds))
                    connectionBackoffSeconds = min(60, connectionBackoffSeconds * 2)
                }
            }

            // Only delay between different folders — same folder continues immediately
            if previousFolderId != nil && previousFolderId != folder.id {
                try? await Task.sleep(for: .seconds(profile.interFolderDelay))
            }
            previousFolderId = folder.id
            await updateBackfillProgressForAccount(account)
        }

        await updateBackfillProgressForAccount(account)
        return didWork
    }

}
