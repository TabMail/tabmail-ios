/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@preconcurrency import Combine
import SwiftUI
import Synchronization

@Observable
@MainActor
final class InboxViewModel {
    /// Short unique tag for this VM instance — used in logs to correlate
    /// init/deinit/onAppear/reloadMessages events across overlapping VMs
    /// (which we know happen during rapid nav — SwiftUI caches two view
    /// identities and alternates; teardown of the old VM overlaps with
    /// setup of the new one).
    let instanceTag: String = String(UUID().uuidString.prefix(6))

    private(set) var folders: [Folder]
    var showCompose = false
    var showAgentChat = false
    var isRefreshing = false
    var isLoadingOlder = false
    var hasMoreMessages = true
    var error: String?
    var filterUnread = false
    var filterLabelIds: Set<String> = []
    var mode: InboxMode = .normal
    private(set) var hasLoadedInitialPage = false

    /// Paginated message list as VALUE-TYPE snapshots.
    /// Snapshots capture properties at fetch time so SwiftUI rendering is stable.
    private(set) var loadedMessages: [MessageSnapshot] = []

    /// Target size of the pagination window — what reloads aim to fill.
    /// Grows by `pageSize` on each successful `loadMoreMessages()`; reset to
    /// `pageSize` by `resetMessages()`. Decoupled from `loadedMessages.count`
    /// so archives don't ratchet the visible window down past the page size.
    private var targetWindowSize: Int = SyncConfig.inboxPageSize

    /// Thread-grouped view of loadedMessages for the normal list view.
    /// Rebuilt whenever loadedMessages changes.
    private(set) var displayGroups: [ThreadGroup] = []

    /// Whether any filter (unread or labels) is currently active.
    var isFilterActive: Bool { filterUnread || !filterLabelIds.isEmpty }

    /// Clear all filters (unread + labels).
    func clearFilters() {
        filterUnread = false
        filterLabelIds.removeAll()
        expandedThreads.removeAll()
        resetMessages()
    }

    /// Which thread groups are currently expanded in the list.
    var expandedThreads: Set<String> = []

    private let manager = AccountManager.shared
    // nonisolated(unsafe) to allow deinit cancellation from nonisolated context.
    // Task<_, Never> is inherently thread-safe for `cancel()` calls.
    @ObservationIgnored nonisolated(unsafe) private var syncTask: Task<Void, Never>?
    /// Inflight guard for `startSync`. Set to `true` at the top of `startSync`
    /// before spawning the sync Task; cleared via `defer` inside the Task so
    /// every exit path (early return, cancellation, thrown error) releases
    /// the guard. While `true`, further `startSync` calls are no-ops —
    /// idempotent. Distinct from `isRefreshing` which only flips inside
    /// `performSync` after the 250ms debounce window; without this flag,
    /// rapid `startSync` calls during that window would spawn multiple
    /// overlapping Tasks.
    @ObservationIgnored private var isSyncPending = false
    private var loadedIds: Set<String> = []
    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    // On-demand snippet loading state
    private var snippetQueue: Set<String> = []
    private var snippetInFlight: Set<String> = []
    private var snippetFailed: Set<String> = []
    private var snippetTask: Task<Void, Never>?
    private var backgroundChangeTask: Task<Void, Never>?
    /// Dirty bit — set by any `.inboxDataDidChange` arrival, cleared immediately before a reload.
    /// If a signal arrives while the throttle is sleeping OR while `reloadMessages` is running,
    /// this bit causes the throttle task to loop and reload again after the current pass finishes.
    /// Prevents lost-wakeup where a signal arriving during the 500ms window was silently dropped.
    private var backgroundChangeDirty: Bool = false
    /// Single-flight guard so the IMMEDIATE (privileged NSE-merge) reload path and
    /// the THROTTLED (background-producer) reload path never run `reloadMessages`
    /// concurrently. A reload requested while one is in flight re-runs once more
    /// after it (see `runReloadCoalesced`).
    private var isReloadingMessages: Bool = false
    private var reloadRequestedAgain: Bool = false
    /// DIAGNOSTIC (debug-gated, emitted via `BootProfiler`): CFAbsoluteTime of the
    /// FIRST `.inboxDataDidChange` that armed the current throttled reload cycle.
    /// Lets `reloadMessages` emit the end-to-end "change signal → inbox repainted"
    /// latency (500ms debounce + merge-gated async read + paint) — the
    /// user-perceived unread-bubble / new-arrival lag. Reset to nil once the
    /// cycle's first reload logs it.
    private var firstDirtySignalAt: Double?
    @ObservationIgnored nonisolated(unsafe) private var backgroundChangeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var aiUpdateObserver: NSObjectProtocol?
    @ObservationIgnored private var folderObservationCancellable: AnyCancellable?

    // MARK: - Background Update Gate (legacy — interaction freeze removed)
    // The optimistic overlay guarantees reloadMessages() always shows correct state,
    // so we no longer need to defer updates. These are no-ops kept for call-site compat.
    func beginInteraction() {}
    func endInteraction() {}
    func listDidDisappear() {}

    /// Called when the list reappears (e.g., user pops back from detail).
    /// With the overlay, reloadMessages is always safe — just trigger a refresh.
    /// Folder self-heal now happens inside `reloadMessages` via the async
    /// `selfHealFoldersAsync()` (Half A / PLAN_HANG_FIX). The previous
    /// SYNCHRONOUS `selfHealFolders()` call here did a GRDB read on the main
    /// thread during foreground return — the warm-foreground hang — so it was
    /// removed; `reloadMessages` below heals off-main (and was already healing).
    func listDidAppear() {
        BackgroundSyncLogger.logInbox("[\(instanceTag)] listDidAppear hasLoaded=\(hasLoadedInitialPage) loadedCount=\(loadedMessages.count) folders=\(folders.count)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            await self.reloadMessages(animated: true)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.logInbox("[\(self.instanceTag)] listDidAppear reloadMessages done in \(ms)ms loadedCount=\(self.loadedMessages.count)")
        }
    }

    /// Selection used to self-resolve folders from GRDB when the initial folder list is empty
    /// (first-account scenario where folders arrive after init).
    private let selection: MailboxSelection

    init(folders: [Folder], selection: MailboxSelection = .unified(.inbox)) {
        self.folders = folders
        self.selection = selection
        BackgroundSyncLogger.logInbox("[\(instanceTag)] init folders=\(folders.map { "\($0.id):\($0.role.rawValue)" }) selection=\(String(describing: selection))")
        // Cheap synchronous fetch of the first page. Done here (not in start())
        // so the very first body evaluation has data — no one-frame blank.
        //
        // Phantom-VM context: SwiftUI re-runs this View struct's init on every
        // parent re-render (NavigationStore emissions, selection flips). Each
        // re-init eagerly evaluates `State(initialValue: InboxViewModel(...))`,
        // producing a fresh VM that SwiftUI immediately discards in favor of
        // the already-registered one. We accept ~5–15ms of wasted GRDB work
        // per phantom to avoid the blank-frame regression. Expensive side
        // effects (NotificationCenter observers, GRDB ValueObservation, sync
        // kick-off) live in start() instead — only the VM SwiftUI actually
        // appearance-hooks runs those.
        loadInitialPage()
    }

    deinit {
        // Capture instanceTag before accessing in nonisolated context. String is Sendable.
        let tag = instanceTag
        let started = hasStarted
        BackgroundSyncLogger.logInbox("[\(tag)] deinit started=\(started)")
        if let obs = backgroundChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = aiUpdateObserver { NotificationCenter.default.removeObserver(obs) }
        folderObservationCancellable?.cancel()
        // Cancel the pending sync Task so a VM discarded mid-startSync-delay
        // doesn't fire a sync after deinit. Without this, rapid nav produces
        // a pile of stale sync tasks all hitting GRDB on MainActor.
        syncTask?.cancel()
    }

    /// One-time setup of observers + folder ValueObservation + initial sync kick-off.
    /// Called from `InboxView.onAppear`. Idempotent via the `hasStarted` guard,
    /// so repeated onAppear (pop back from detail, app foreground) is a no-op.
    ///
    /// Phantom VMs created by SwiftUI's eager @State(initialValue:) evaluation
    /// never receive onAppear → never run start() → never register observers,
    /// never subscribe to the folder VO. They construct, run loadInitialPage()
    /// (~5ms of wasted GRDB reads), then deinit silently.
    @ObservationIgnored private var hasStarted = false
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        BackgroundSyncLogger.logInbox("[\(instanceTag)] start folders=\(folders.count) loadedCount=\(loadedMessages.count)")
        startBackgroundChangeListener()
        startAIUpdateListener()
        startFolderObservation()
    }

    /// Update folders when NavigationStore emits new data or GRDB folder table changes.
    /// Reloads when the folder set OR any folder's role actually changed — unreadCount/metadata
    /// changes are deduped upstream (folder ValueObservation) so they don't retrigger here.
    ///
    /// Comparison is Set-based (order-independent). NavigationStore's filter preserves
    /// account creation order; the VO's `ORDER BY accountId` produces a different order
    /// for the same 5 folders. Without set-based comparison, every NS emission after
    /// the VO has normalized order triggered a spurious `resetMessages()` + full reload
    /// just to re-order the same folder list.
    func updateFolders(_ newFolders: [Folder]) {
        let oldKeys = Set(folders.map { "\($0.id):\($0.role.rawValue)" })
        let newKeys = Set(newFolders.map { "\($0.id):\($0.role.rawValue)" })
        guard newKeys != oldKeys else { return }
        BackgroundSyncLogger.logInbox("[\(instanceTag)] updateFolders old=\(oldKeys.sorted()) new=\(newKeys.sorted())")
        let hadNoFolders = folders.isEmpty
        folders = newFolders
        expandedThreads.removeAll()
        resetMessages()
        // First account scenario: folders were empty at init (sync bailed early),
        // now folders arrived via NavigationStore — trigger sync so messages get fetched.
        if hadNoFolders && !newFolders.isEmpty {
            startSync()
        }
    }

    /// Resolve folders from GRDB based on the stored selection.
    /// Used for self-healing when folders are empty at init (first-account scenario).
    private func resolveFoldersFromDB() -> [Folder] {
        let tStart = CFAbsoluteTimeGetCurrent()
        let tag = instanceTag
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
            if ms >= 50 {
                BackgroundSyncLogger.logInbox("[\(tag)] resolveFoldersFromDB \(ms)ms")
            }
        }
        // Demo scope: a unified mailbox aggregates folders by role across ALL
        // accounts, so without this it would surface the live user's inbox while
        // demo mode is active. `.folder` selections need no scope — the user can
        // only select a demo folder while demo is active (the sidebar is filtered).
        let demoActive = DemoModeStore.shared.isActive
        switch selection {
        case .unified(let role):
            return (try? dbPool.read { db in
                try Folder.filter(Column("role") == role.rawValue && Folder.demoScope(demoActive: demoActive)).fetchAll(db)
            }) ?? []
        case .folder(let folder):
            return (try? dbPool.read { db in
                if let fresh = try Folder.fetchOne(db, key: folder.id) {
                    return [fresh]
                }
                return [folder]
            }) ?? [folder]
        default:
            return []
        }
    }

    /// Async mirror of `resolveFoldersFromDB`: the GRDB read runs off the main
    /// thread (suspends, never blocks), so a slow/contended/locked read on the
    /// warm-foreground path can't freeze the UI (Half A / PLAN_HANG_FIX). Same
    /// query and fallbacks as the synchronous version.
    private func resolveFoldersFromDBAsync() async -> [Folder] {
        let demoActive = DemoModeStore.shared.isActive
        switch selection {
        case .unified(let role):
            return (try? await dbPool.read { db in
                try Folder.filter(Column("role") == role.rawValue && Folder.demoScope(demoActive: demoActive)).fetchAll(db)
            }) ?? []
        case .folder(let folder):
            return (try? await dbPool.read { db in
                if let fresh = try Folder.fetchOne(db, key: folder.id) {
                    return [fresh]
                }
                return [folder]
            }) ?? [folder]
        default:
            return []
        }
    }

    /// Primary account for compose (explicit isPrimary flag, fallback to oldest active).
    var primaryAccount: Account? {
        let primary = try? dbPool.read { db in
            try Account.filter(Column("isActive") == true && Column("isPrimary") == true).fetchOne(db)
        }
        if let primary { return primary }
        return try? dbPool.read { db in
            try Account.filter(Column("isActive") == true).order(Column("createdAt")).fetchOne(db)
        }
    }

    // MARK: - Live Object Lookup

    /// Look up a MessageHeader by ID from GRDB.
    /// Returns a freshly-fetched value — never stale.
    func lookupMessage(_ id: String) -> MessageHeader? {
        if let header = try? dbPool.read({ db in try MessageHeader.fetchOne(db, key: id) }) {
            return header
        }
        // ADR-IOS-049: staged row not yet durable in GRDB — synthesize from the
        // merge's in-memory snapshot so the action resolves instead of silently
        // no-op'ing (`guard let message = lookupMessage(id) else { return }`).
        // The action's `ensureDurable` gate drains the merge before the
        // optimistic write lands. Mirrors `MessageDetailViewModel`'s exact-id
        // synthesis pattern (`stagedRowFallback`/`seedFromStagedPublish`'s
        // composite branch) — PLAN_INBOX_UNIFIED_READ.md §3.
        return NSEDataBridge.latestStagedRows.withLock { rows in
            rows.first { $0.headerId == id }
        }?.toMessageHeader()
    }

    /// Synchronous folder role lookup — no suspension points.
    private func lookupFolderRole(_ folderId: String) -> FolderRole? {
        try? dbPool.read { db in try Folder.fetchOne(db, key: folderId)?.role }
    }

    /// Synchronous folder path lookup by account + role — no suspension points.
    private func lookupFolderPath(accountId: String, role: FolderRole) -> String? {
        try? dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == role.rawValue).fetchOne(db)?.path
        }
    }

    // MARK: - Paginated Fetch

    /// Load initial page of messages. Called from .onAppear on view appear.
    /// Guarded: only runs once. Subsequent appears (e.g., popping back from detail)
    /// are handled by listDidAppear() which flushes any deferred updates.
    /// Observers are registered in init() — not here — so they survive even if
    /// loadInitialPage is never called (e.g., view cancelled before first appearance).
    func loadInitialPage() {
        guard !hasLoadedInitialPage else {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] loadInitialPage SKIPPED — already loaded, count=\(loadedMessages.count)")
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        resetMessages()
        hasLoadedInitialPage = true
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        BackgroundSyncLogger.logInbox("[\(instanceTag)] loadInitialPage folders=\(folders.count) loadedCount=\(loadedMessages.count) in \(ms)ms")
    }

    /// Observe the `folder` table directly via GRDB ValueObservation.
    /// Authoritative source for `VM.folders` — survives NavigationStore races,
    /// role flips that don't change IDs, and rapid SwiftUI view-lifecycle churn.
    ///
    /// IMPORTANT: This observation is ONLY for the `folder` table. Do NOT use
    /// ValueObservation on `messageHeader` — see PROJECT_MEMORY.md. Message writes
    /// are frequent (sync, AI, backfill) and would cause re-render storms;
    /// messages are driven by the existing `.inboxDataDidChange` notification +
    /// `flushAIBatch` targeted updates instead.
    ///
    /// Emissions are filtered by `.removeDuplicates { (id, role) }`, so folder
    /// metadata writes like `unreadCount` don't retrigger `updateFolders`. The
    /// underlying fetch still runs on every folder-table commit (off-main via
    /// GRDB's reader pool) — cheap on a 5–50 row table.
    private func startFolderObservation() {
        let selection = self.selection
        // Snapshot the demo flag for the observation's lifetime. The VM (and thus
        // this observation) is recreated when routing flips between the demo and
        // real branches, so the snapshot always matches the current mode. Keeps the
        // unified mailbox from aggregating the live user's folders during demo.
        let demoActive = DemoModeStore.shared.isActive
        let observation = ValueObservation.tracking { db -> [Folder] in
            switch selection {
            case .unified(let role):
                return try Folder
                    .filter(Column("role") == role.rawValue && Folder.demoScope(demoActive: demoActive))
                    .order(Column("accountId"))
                    .fetchAll(db)
            case .folder(let stored):
                if let fresh = try Folder.fetchOne(db, key: stored.id) {
                    return [fresh]
                }
                return []
            default:
                return []
            }
        }

        folderObservationCancellable = observation
            .publisher(in: AppDatabase.rawPool)
            .removeDuplicates { old, new in
                // Set-based so order churn from unrelated folder writes doesn't propagate.
                Set(old.map { "\($0.id):\($0.role.rawValue)" }) ==
                Set(new.map { "\($0.id):\($0.role.rawValue)" })
            }
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        let tag = self?.instanceTag ?? "??????"
                        Task { @MainActor in
                            BackgroundSyncLogger.logInbox("[\(tag)] folder VO error: \(error)")
                        }
                    }
                },
                receiveValue: { [weak self] newFolders in
                    // GRDB's default publisher scheduling delivers on main queue.
                    // Hop to MainActor explicitly for Swift 6 isolation compliance.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        BackgroundSyncLogger.logInbox("[\(self.instanceTag)] folder VO emit count=\(newFolders.count) keys=\(newFolders.map { "\($0.id):\($0.role.rawValue)" })")
                        self.updateFolders(newFolders)
                    }
                }
            )
    }

    /// Listen for data changes (backfill inserts, sync) and reload.
    /// Debounced (500ms) and deferred while user is interacting.
    private func startBackgroundChangeListener() {
        if let old = backgroundChangeObserver {
            NotificationCenter.default.removeObserver(old)
        }
        backgroundChangeObserver = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // PRIVILEGED merge signal? The NSE→inbox merge is a single-threaded,
            // boot-priority step (see `NSEMergeCoordinator`); its result must paint
            // AT ONCE, bypassing the 500ms coalescing debounce that the noisy
            // background producers (sync, backfill, AI, user actions) ride.
            let immediate = (note.userInfo?[Notification.Name.inboxReloadImmediateKey] as? Bool) == true
            Task { @MainActor in
                guard let self else { return }
                if immediate {
                    // Reload now — no debounce. Funnels through the same
                    // single-flight as the throttled path so the two never run
                    // `reloadMessages` concurrently.
                    await self.runReloadCoalesced()
                    return
                }
                // Dirty bit + throttled loop.
                // Every signal sets the bit unconditionally. The throttle task loops until
                // the bit is clean at the start of a reload — so any signal arriving during
                // sleep OR during reloadMessages triggers a follow-up reload.
                self.backgroundChangeDirty = true
                if self.backgroundChangeTask == nil {
                    // DIAGNOSTIC: stamp the first signal of this reload cycle so the
                    // reload can emit the end-to-end perceived repaint latency below.
                    if self.firstDirtySignalAt == nil { self.firstDirtySignalAt = CFAbsoluteTimeGetCurrent() }
                    self.backgroundChangeTask = Task { @MainActor [weak self] in
                        while let self, self.backgroundChangeDirty {
                            try? await Task.sleep(for: .milliseconds(500))
                            if Task.isCancelled { break }
                            // Clear BEFORE reload so signals arriving during reload re-arm the loop.
                            self.backgroundChangeDirty = false
                            await self.runReloadCoalesced()
                        }
                        self?.backgroundChangeTask = nil
                    }
                }
            }
        }
    }

    /// Single-flight wrapper around `reloadMessages`. The privileged immediate
    /// (NSE-merge) path and the throttled background path both go through here, so
    /// they never run `reloadMessages` concurrently (which would interleave at the
    /// async DB-read suspension point and double-apply the diff). A reload asked
    /// for while one is in flight sets `reloadRequestedAgain`, which re-runs one
    /// more pass after the current one — so the latest data always wins.
    private func runReloadCoalesced() async {
        if isReloadingMessages {
            reloadRequestedAgain = true
            return
        }
        isReloadingMessages = true
        repeat {
            reloadRequestedAgain = false
            await reloadMessages(animated: true)
        } while reloadRequestedAgain
        isReloadingMessages = false
    }

    /// Listen for AI processing completion and refresh just the affected snapshot in-place.
    /// Avoids full reloadMessages() — only the updated row re-renders.
    /// Deferred while user is interacting. Batched with 300ms debounce to coalesce
    /// rapid AI completions (up to 30/s with 32-worker semaphore).
    private var pendingAIBatch: Set<String> = []
    private var aiBatchTask: Task<Void, Never>?

    private func startAIUpdateListener() {
        if let old = aiUpdateObserver {
            NotificationCenter.default.removeObserver(old)
        }
        aiUpdateObserver = NotificationCenter.default.addObserver(
            forName: .messageDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let msgId = notification.object as? String
            Task { @MainActor in
                guard let self, let messageId = msgId else { return }
                self.pendingAIBatch.insert(messageId)
                // Throttle (not debounce): flush every 300ms regardless of new arrivals.
                // With the overlay, flushAIBatch is always safe — no freeze gate needed.
                self.scheduleAIFlushTick()
            }
        }
    }

    /// One throttle tick: flush 300ms from now unless a tick is already armed.
    private func scheduleAIFlushTick() {
        guard aiBatchTask == nil else { return }
        aiBatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.flushAIBatch()
        }
    }

    /// True while a flush is past its drain point (possibly suspended at the async
    /// read). Prevents a second flush from interleaving — two concurrent flushes
    /// could apply stale headers out of order (the `snapshot != existing` check
    /// doesn't protect ordering). The pre-async version was synchronous and could
    /// never interleave; this restores that invariant.
    private var isFlushingAIBatch = false

    /// Flush batched AI updates — applies all pending snapshot refreshes in one pass.
    private func flushAIBatch() async {
        guard !isFlushingAIBatch else {
            // A flush is mid-await. Leave ids in pendingAIBatch and re-arm a tick so
            // they're picked up next pass (aiBatchTask still points at THIS task —
            // clear it first so the re-arm isn't a no-op).
            aiBatchTask = nil
            scheduleAIFlushTick()
            return
        }
        isFlushingAIBatch = true
        defer {
            isFlushingAIBatch = false
            // Ids that arrived during the await stayed in pendingAIBatch — re-arm.
            if !pendingAIBatch.isEmpty { scheduleAIFlushTick() }
        }
        let ids = pendingAIBatch
        pendingAIBatch.removeAll()
        aiBatchTask = nil
        guard !ids.isEmpty else { return }

        let tStart = CFAbsoluteTimeGetCurrent()
        let tag = instanceTag
        let idCount = ids.count
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
            if ms >= 50 {
                BackgroundSyncLogger.logInbox("[\(tag)] flushAIBatch \(ms)ms ids=\(idCount)")
                // Boot-log mirror: main-actor cost must be correlatable against
                // ⚠ MAIN THREAD STALL marks in the downloadable boot log.
                BootProfiler.mark("flushAIBatch \(ms)ms ids=\(idCount)")
            }
        }
        // Batch-read all needed headers in a single ASYNC DB read (suspends, never
        // blocks). This was a synchronous `dbPool.read` on the @MainActor — it fires
        // ~300ms after AI results land on freshly-merged rows, i.e. inside the same
        // post-merge write burst as the snippet loader, and a contended reader pool
        // blocked the main thread here (part of the "stall when snippet shows up").
        // rawPool deliberately — no read-through staging merge on this path (AI chips
        // don't need post-merge freshness; the reconcile reload covers them).
        let freshHeaders: [String: MessageHeader] = (try? await AppDatabase.rawPool.read { db in
            var result: [String: MessageHeader] = [:]
            for id in ids {
                if let header = try MessageHeader.fetchOne(db, key: id) {
                    result[id] = header
                }
            }
            return result
        }) ?? [:]

        let folderIds = Set(folders.map(\.id))
        let overlay = manager.snapshotOverlay()
        var changed = false
        for messageId in ids {
            guard let idx = loadedMessages.firstIndex(where: { $0.id == messageId }),
                  let header = freshHeaders[messageId] else { continue }
            // Skip if message has been moved/deleted out of the displayed folders
            guard folderIds.contains(header.folderId) else { continue }
            // Full snapshot replacement from DB — overlay preserves pending user state
            // (isRead, isFlagged, actionTag) so wholesale replacement is safe.
            var snapshot = MessageSnapshot(from: header, userLabels: loadedMessages[idx].userLabels)
            // Apply overlay on top for any pending mutations
            if let mutation = overlay[messageId] {
                if let v = mutation.isRead { snapshot.isRead = v }
                if let v = mutation.isFlagged { snapshot.isFlagged = v }
                if let v = mutation.actionTag {
                    snapshot.actionTag = v
                    snapshot.tagSortOrder = v?.sortOrder ?? 99
                }
                if let v = mutation.isInInbox { snapshot.isInInbox = v }
            }
            // Snippet: the fresh DB header's snippet WINS when non-empty — the old
            // "preserve" unconditionally stomped it with the stale in-memory value,
            // which held a new IMAP push's snippet EMPTY through every AI repaint
            // (action tag visible, no snippet) until the terminal-merge reload.
            // (`MessageSnapshot(from:)` does copy `header.snippet`; the old
            // comment's "not in header" premise was wrong.) Keep the in-memory
            // value only as a fallback for the SnippetLoader's in-place fills,
            // which can be ahead of the DB (tier-1/2 update the row before/without
            // a header write landing).
            if snapshot.snippet.isEmpty {
                snapshot.snippet = loadedMessages[idx].snippet
            }
            if snapshot != loadedMessages[idx] {
                loadedMessages[idx] = snapshot
                changed = true
            }
        }
        if changed {
            withAnimation(.easeInOut(duration: 0.2)) {
                rebuildDisplayGroups()
            }
        }
    }

    /// Insert specific messages back into the loaded list (for undo).
    /// Uses targeted insertion instead of full reload so SwiftUI List
    /// sees an incremental change and animates the row insertion smoothly.
    func insertUndoneMessages(_ ids: [String]) {
        let folderIds = Set(folders.map(\.id))
        let filterLabelAccountId = folders.first?.accountId
        // Apply optimistic overlay: undo calls registerMutation(folderId: originalFolderId)
        // synchronously before posting .messagesUndone, but the DB restore write is
        // deferred via enqueueWrite. Without the overlay, the DB read below still sees
        // the destination folder (e.g. Archive) and the membership guard silently drops
        // the message, so the undone row never reappears until the next full reload.
        let overlay = manager.snapshotOverlay()
        // Batch-fetch headers + labels in ONE read txn. Unlike `insertStagedRows`
        // (zero-I/O by contract), this path already reads the DB by design — it
        // needs the durable header to reconstruct a snapshot — so loading real
        // labels alongside the by-id header fetch is one more indexed read, not
        // a new I/O class. Without this, a genuinely-labeled undone row would be
        // dropped here under an active label filter even though
        // `InboxListReader`'s P-step (which DOES load real labels for pinned
        // rows — its "undo shape", see `gather()`'s `labelsByMessage` comment)
        // would keep it on the very next reload — a fidelity gap
        // PLAN_INBOX_UNIFIED_READ.md §2.2/§5 Phase 4 closes.
        let idsToFetch = ids.filter { !loadedIds.contains($0) }
        let headersById: [String: MessageHeader]
        let labelsByMessage: [String: [UserLabel]]
        if let batch = try? dbPool.read({ db -> ([String: MessageHeader], [String: [UserLabel]]) in
            var headers: [String: MessageHeader] = [:]
            for id in idsToFetch {
                if let header = try MessageHeader.fetchOne(db, key: id) {
                    headers[id] = header
                }
            }
            let labels = try UserLabelStore.loadLabels(for: Array(headers.keys), in: db)
            return (headers, labels)
        }) {
            (headersById, labelsByMessage) = batch
        } else {
            headersById = [:]
            labelsByMessage = [:]
        }
        var inserted = false
        for id in ids {
            guard !loadedIds.contains(id) else { continue }
            guard var header = headersById[id] else { continue }
            // Apply EVERY display field the overlay carries — the same set, with the
            // same semantics, as `InboxListComposer.applyOverlay`. This path and the
            // next reload must agree on the row, or the undone message visibly
            // changes under the user when an unrelated reload lands.
            //
            // `actionTag` and `isFlagged` were missing here (round-51 audit) while
            // `UndoService.undo()` deliberately puts the tag in the overlay it
            // registers: leaving the inbox CLEARS `actionTag` in the same write as
            // the move (ADR-IOS-036 amendment), and the undo's restoring write is
            // DEFERRED to the fold — so at this instant the header re-read below is
            // still the cleared one, and the overlay is the only carrier of the tag.
            // Dropping it brought the row back with no badge and, in triage, sank it
            // to the bottom (see `tagSortOrder` below).
            if let mutation = overlay[id] {
                if let v = mutation.folderId { header.folderId = v }
                if let v = mutation.folderPath { header.folderPath = v }
                if let v = mutation.isInInbox { header.isInInbox = v }
                if let v = mutation.isRead { header.isRead = v }
                if let v = mutation.isFlagged { header.isFlagged = v }
                if let v = mutation.actionTag {
                    header.actionTag = v
                    // Derived mirror, never an independent field — same derivation as
                    // the undo's own restore and the inbox-exit clear.
                    header.tagSortOrder = v?.sortOrder ?? 99
                }
            }
            // Only insert if the message belongs to a currently displayed folder
            guard folderIds.contains(header.folderId) else { continue }
            // Respect unread filter
            if filterUnread && header.isRead { continue }
            let labels = labelsByMessage[id] ?? []
            // Respect label filter — mirrors InboxListComposer step 6 (compose
            // applies the label filter uniformly to D/P/S); this path just
            // loaded real labels above so it can match the reader exactly.
            if !filterLabelIds.isEmpty {
                guard header.accountId == filterLabelAccountId else { continue }
                guard filterLabelIds.isSubset(of: Set(labels.map(\.id))) else { continue }
            }
            let snapshot = MessageSnapshot(from: header, userLabels: labels)
            // Insert at correct sorted position (by date, descending)
            let insertionIndex: Int
            if mode == .triage {
                // Triage: tagSortOrder ascending, then date descending
                insertionIndex = loadedMessages.firstIndex {
                    $0.tagSortOrder > snapshot.tagSortOrder ||
                    ($0.tagSortOrder == snapshot.tagSortOrder && $0.date < snapshot.date)
                } ?? loadedMessages.endIndex
            } else {
                insertionIndex = loadedMessages.firstIndex { $0.date < snapshot.date } ?? loadedMessages.endIndex
            }
            loadedMessages.insert(snapshot, at: insertionIndex)
            loadedIds.insert(id)
            inserted = true
        }
        if inserted {
            rebuildDisplayGroups()
        }
    }

    /// ADR-IOS-049: insert NSE-staged rows into the loaded list IN-MEMORY (no GRDB
    /// read/write) so just-pushed mail appears instantly, before the merge's durable
    /// header write. Sourced from the `.messagesStaged` payload, not GRDB. Mirrors
    /// `insertUndoneMessages`. PLAN_INBOX_UNIFIED_READ.md §2.2: a pure latency
    /// optimization, no longer correctness-bearing — any subsequent reload
    /// converges to the same answer because `InboxListReader`/`InboxListComposer`
    /// (the reader) includes staged (S) rows on every fetch, so this insert no
    /// longer needs guard bookkeeping to survive a competing reload.
    func insertStagedRows(_ rows: [StagedInboxRow]) {
        // Query-level label-filter guard, mirroring InboxListComposer step 6
        // (PLAN_INBOX_UNIFIED_READ.md §2.1 step 3 / §2.2 / §5 Phase 4): staged
        // rows synthesize via `toMessageHeader()` with zero `userLabels` (no
        // labels payload in NSE-staged data), so `filterLabelIds.isSubset(of:
        // labels)` can never be satisfied while a filter is active — EVERY row
        // in this batch would be rejected. The check is the same for every
        // row (query-level, not per-row), so bail before the loop rather than
        // per-row. Zero-I/O preserved; a subsequent reload converges via the
        // reader once the row is durable (§2.2's accepted latency window).
        guard filterLabelIds.isEmpty else { return }
        let folderIds = Set(folders.map(\.id))
        let overlay = manager.snapshotOverlay()
        var insertedCount = 0
        for row in rows {
            let id = row.headerId
            // Already shown (durable, or a prior staged insert) — skip.
            guard !loadedIds.contains(id) else { continue }
            // Only for a currently-displayed inbox folder.
            guard folderIds.contains(row.folderId) else { continue }
            // IDENTITY dedup (phantom-row fix): `loadedIds` dedups by exact headerId,
            // but the merge dedups by (accountId, messageId) with rfc822MessageId
            // fallback — any skew (IMAP UID remap, folderPath variant, durable copy
            // already on screen under a different headerId) would insert a DUPLICATE
            // phantom row that no GRDB reload ever evicts. Match the merge's
            // identity in-memory (zero DB I/O on the render path) via
            // `DurableIdentityLookup.isSameLogicalMessage` — the G3-hardened
            // comparator shared with `InboxListComposer.isDuplicateIdentity`: a
            // bare (accountId, messageId) collision no longer counts as a
            // duplicate when both sides' rfc822 identities are known and
            // disagree (IMAP UIDs are per-folder, ADR-IOS-042 — a shared UID
            // across folders can be an unrelated message, not a move). See that
            // helper's doc comment for the full truth table.
            let isDuplicateIdentity = loadedMessages.contains { snap in
                DurableIdentityLookup.isSameLogicalMessage(
                    accountId: row.accountId, messageId: row.messageId, rfc822MessageId: row.rfc822MessageId,
                    candidateAccountId: snap.accountId, candidateMessageId: snap.messageId,
                    candidateRfc822MessageId: snap.rfc822MessageId
                )
            }
            guard !isDuplicateIdentity else { continue }
            var header = row.toMessageHeader()
            // Layer the optimistic mutation overlay (mirrors insertUndoneMessages) —
            // if a mutation moved it out of the displayed folders, don't insert.
            if let m = overlay[id] {
                if let v = m.folderId, !folderIds.contains(v) { continue }
                if let v = m.isRead { header.isRead = v }
                if let v = m.isFlagged { header.isFlagged = v }
                if let v = m.actionTag {
                    header.actionTag = v
                    header.tagSortOrder = v?.sortOrder ?? 99
                }
            }
            if filterUnread && header.isRead { continue }
            // Adopt an on-screen thread's computedThreadId IN-MEMORY (zero DB I/O)
            // so a reply animates straight into its group instead of appearing as a
            // singleton and visibly re-grouping when the durable reload lands with
            // the real thread id. Uses the same linkage signals insert-time thread
            // detection does (provider threadId, rfc822 In-Reply-To/References), so
            // the reconcile normally agrees. A miss or wrong guess self-heals via
            // the reconcile reload — exactly today's regroup, never worse.
            if let adopted = loadedMessages.first(where: { snap in
                guard snap.accountId == row.accountId, !snap.computedThreadId.isEmpty else { return false }
                if let tid = row.threadId, tid == snap.threadId { return true }
                if let rfc = snap.rfc822MessageId, !rfc.isEmpty,
                   row.inReplyTo == rfc || row.references.contains(rfc) { return true }
                return false
            })?.computedThreadId {
                header.computedThreadId = adopted
            }
            let snapshot = MessageSnapshot(from: header)
            let insertionIndex: Int
            if mode == .triage {
                insertionIndex = loadedMessages.firstIndex {
                    $0.tagSortOrder > snapshot.tagSortOrder ||
                    ($0.tagSortOrder == snapshot.tagSortOrder && $0.date < snapshot.date)
                } ?? loadedMessages.endIndex
            } else {
                insertionIndex = loadedMessages.firstIndex { $0.date < snapshot.date } ?? loadedMessages.endIndex
            }
            loadedMessages.insert(snapshot, at: insertionIndex)
            loadedIds.insert(id)
            insertedCount += 1
        }
        if insertedCount > 0 {
            BootProfiler.mark("insertStagedRows: +\(insertedCount) staged row(s) rendered IN-MEMORY (inbox=\(loadedMessages.count)) — no DB I/O, durable write lands later")
            withAnimation(.easeInOut(duration: 0.25)) {
                rebuildDisplayGroups()
            }
        }
    }

    /// Full reset — drops all loaded state and fetches page 1.
    /// Use for semantic changes where the data set itself changes:
    /// folder switch, filter toggle, mode switch, initial load.
    func resetMessages() {
        selfHealFolders()
        resetSnippetState()
        loadedIds = []
        targetWindowSize = SyncConfig.inboxPageSize
        // PLAN_INBOX_UNIFIED_READ.md §3: `fetchPage(before: nil)` already
        // includes eligible staged (S) rows via InboxListReader/InboxListComposer
        // (the reader reads `NSEDataBridge.latestStagedRows` directly), so the
        // explicit `insertStagedRows` re-seed that used to follow this fetch is
        // gone — the reader makes it redundant.
        loadedMessages = fetchPage(before: nil)
        loadedIds = Set(loadedMessages.map(\.id))
        hasMoreMessages = loadedMessages.count >= targetWindowSize
        // Full assign — no diff needed since the data set changed entirely
        displayGroups = ThreadGroupBuilder.buildDisplayGroups(from: loadedMessages, mode: mode)
        requeueVisibleSnippets()
    }

    /// Diff-based reload — re-fetches the currently loaded window and diffs it
    /// in-place. Use for background data changes (sync, backfill, merge) where
    /// the data set may have changed: messages added/removed/updated.
    /// SwiftUI sees incremental changes by stable message ID, preserving scroll
    /// position. Async: DB read runs off MainActor (prevents hang during WAL
    /// checkpoint contention). The diff and @Observable mutations run on
    /// MainActor after the read completes.
    ///
    /// PLAN_INBOX_UNIFIED_READ.md §3: the fetch below routes through
    /// `InboxListReader`/`InboxListComposer` (the unified reader), which
    /// applies the overlay, folds in staged (S) and overlay-pinned (P) rows,
    /// sorts, and trims — so Pass 1's diff is an honest one: a row missing
    /// from the fresh set is simply not on the list anymore, no guard/
    /// tombstone bookkeeping needed. `applyOverlay` (the VM's own overlay
    /// application, once called here) had zero callers left after Phase 3
    /// switched this fetch to the reader — deleted in Phase 5.
    func reloadMessages(animated: Bool = false) async {
        // Heal folders OFF the main thread — the synchronous selfHealFolders()
        // here blocked the UI on a GRDB read during warm-foreground return
        // (the warm-foreground hang; Half A / PLAN_HANG_FIX).
        await selfHealFoldersAsync()
        let folderNames = folders.map { "\($0.name)(\($0.id))" }.joined(separator: ", ")
        print("[MoveTrace] reloadMessages — folders=[\(folderNames)] prevCount=\(loadedMessages.count)")

        resetSnippetState()

        // REPAINT DECOUPLING: kick the read-through NSE merge OFF the repaint critical
        // path (non-awaited). The reload's read below now uses `rawPool` (no inline
        // merge), so the unread-bubble / new-arrival repaint no longer blocks on a
        // multi-second merge. Draining is preserved: `mergeIfStagingPending` self-skips
        // when nothing is staged (~µs, coalesced/signature-gated), and on a real mutation
        // it posts `.inboxDataDidChange` → a reconcile reload picks up the durable rows.
        Task { await NSEDataBridge.mergeIfStagingPending() }

        // Fetch fresh data off MainActor — async GRDB read suspends (not blocks) the main thread.
        // This prevents UI hangs when heavy sync writes trigger WAL auto-checkpoint.
        // DIAGNOSTIC: time the async read. Now reads `rawPool` (merge kicked off-path
        // above), so this should be FAST even while a multi-second merge runs
        // concurrently — the same-timeline before/after proof that the merge was the
        // bubble-lag cause. If this mark still fires ≥250ms post-fix, the READ itself
        // (not the merge) is slow — a distinct signal worth chasing.
        let tFetch = CFAbsoluteTimeGetCurrent()
        let freshMessages = await fetchFullRange()
        let fetchMs = Int((CFAbsoluteTimeGetCurrent() - tFetch) * 1000)
        if fetchMs >= 250 {
            BootProfiler.mark("[\(instanceTag)] reloadMessages async fetch (rawPool, merge OFF critical path) \(fetchMs)ms fresh=\(freshMessages.count)")
        }

        // PLAN_INBOX_UNIFIED_READ.md §2.1 step 4: `fetchFullRange` now routes
        // through InboxListReader/InboxListComposer, which snapshots the
        // overlay itself (at the same "before the DB read" point) and applies
        // it internally — so `reloadMessages` no longer needs its own overlay
        // snapshot at all (Pass 1 below is a plain diff, §3 kill list).

        // Apply diff on MainActor (synchronous — fast in-memory work on @Observable state).
        let applyDiff = { [self] in
            // Diff into loadedMessages in-place
            let freshById: [String: MessageSnapshot] = {
                var dict: [String: MessageSnapshot] = [:]
                dict.reserveCapacity(freshMessages.count)
                for m in freshMessages { dict[m.id] = m }
                return dict
            }()

            // Pass 1: remove messages no longer in the fresh set, update changed
            // ones. PLAN_INBOX_UNIFIED_READ.md §3: an honest diff — the reader
            // (InboxListReader/InboxListComposer) already supplies staged (S)
            // and overlay-pinned (P) rows, and carries AI fields (actionTag/
            // tagSortOrder/summaryBlurb) from a staged row onto its D-visible
            // counterpart when the durable row's own AI fields are still nil
            // (§2.1a) — so nothing legitimate is ever missing from
            // `freshMessages`, and a row absent from it is simply gone. No
            // guard, no tombstone.
            var survivingIds: Set<String> = []
            var indicesToRemove: [Int] = []
            for (i, existing) in loadedMessages.enumerated() {
                if let fresh = freshById[existing.id] {
                    var assigned = fresh
                    // G1 audit fix (PLAN_INBOX_UNIFIED_READ.md): an EMPTY
                    // fresh field must never clobber a NON-EMPTY on-screen
                    // enrichment — same "non-empty beats empty" principle as
                    // flushAIBatch's documented snippet fallback above. A
                    // staged-only row re-synthesizes both fields from the
                    // staging snapshot on every compose
                    // (`StagedInboxRow.toMessageHeader()` / the reader's S-row
                    // thread adoption), so a same-identity fresh row can
                    // legitimately arrive with an EMPTY value even though the
                    // existing row already has a real one — an in-place
                    // SnippetLoader fill that's ahead of the staging
                    // snapshot, or a thread-adoption miss this cycle (its
                    // adopted parent evicted from the D∪P window, or
                    // re-keyed). A durable fresh row's REAL (non-empty) value
                    // always wins regardless — this only guards the
                    // fresh-is-empty case.
                    if assigned.snippet.isEmpty && !existing.snippet.isEmpty {
                        assigned.snippet = existing.snippet
                    }
                    // Durable rows always have a non-empty computedThreadId —
                    // `ThreadUtils.assignComputedThreadId` seeds it from the
                    // message's own (non-empty) id when no thread relation or
                    // native thread id is found, so it never leaves the field
                    // empty. Only a staged-only row's synthesized snapshot
                    // (`StagedInboxRow.toMessageHeader()` doesn't set
                    // `computedThreadId` at all) can land here empty.
                    // Reverting it would silently re-collapse a
                    // user-expanded thread: `ThreadGroupBuilder` keys a
                    // group by `computedThreadId` (falling back to the
                    // message's own id only when it's empty), and
                    // `rebuildDisplayGroups` never migrates
                    // `expandedThreads` entries to a new key.
                    if assigned.computedThreadId.isEmpty && !existing.computedThreadId.isEmpty {
                        assigned.computedThreadId = existing.computedThreadId
                    }
                    // Only assign if the snapshot actually changed — avoids triggering
                    // @Observable for unchanged rows, preventing unnecessary re-renders
                    // and layout shifts that cause scroll position jumps.
                    if existing != assigned {
                        loadedMessages[i] = assigned
                    }
                    survivingIds.insert(existing.id)
                } else {
                    indicesToRemove.append(i)
                }
            }
            for i in indicesToRemove.reversed() {
                loadedMessages.remove(at: i)
            }

            // Pass 2: Insert new messages at correct sorted position
            for fresh in freshMessages where !survivingIds.contains(fresh.id) {
                let insertAt: Int
                if mode == .triage {
                    insertAt = loadedMessages.firstIndex {
                        $0.tagSortOrder > fresh.tagSortOrder ||
                        ($0.tagSortOrder == fresh.tagSortOrder && $0.date < fresh.date)
                    } ?? loadedMessages.endIndex
                } else {
                    insertAt = loadedMessages.firstIndex { $0.date < fresh.date } ?? loadedMessages.endIndex
                }
                loadedMessages.insert(fresh, at: insertAt)
            }

            loadedIds = Set(loadedMessages.map(\.id))
            hasMoreMessages = loadedMessages.count >= targetWindowSize
        }

        let tDiff = CFAbsoluteTimeGetCurrent()
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { applyDiff() }
        } else {
            applyDiff()
        }
        let diffMs = Int((CFAbsoluteTimeGetCurrent() - tDiff) * 1000)

        print("[MoveTrace] reloadMessages — newCount=\(loadedMessages.count) hasMore=\(hasMoreMessages)")
        MergeSurfaceProbe.logSince("inbox reloaded (\(loadedMessages.count) rows)")
        let tRebuild = CFAbsoluteTimeGetCurrent()
        rebuildDisplayGroups()
        let rebuildMs = Int((CFAbsoluteTimeGetCurrent() - tRebuild) * 1000)
        requeueVisibleSnippets()
        // DIAGNOSTIC: end-to-end perceived latency — first `.inboxDataDidChange` of
        // this throttled cycle → inbox now repainted (500ms debounce + the
        // merge-gated async read timed as `fetchMs` above + paint). This is the
        // user-visible unread-bubble / new-arrival lag. Only the throttled path
        // stamps `firstDirtySignalAt`; the immediate NSE-merge and appear paths skip it.
        if let firstSignal = firstDirtySignalAt {
            firstDirtySignalAt = nil
            let e2eMs = Int((CFAbsoluteTimeGetCurrent() - firstSignal) * 1000)
            if e2eMs >= 300 {
                BootProfiler.mark("[\(instanceTag)] inbox repaint latency \(e2eMs)ms since first change signal (debounce+fetch+paint) fetch=\(fetchMs)ms rebuild=\(rebuildMs)ms")
            }
        }
        if diffMs + rebuildMs >= 50 {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] reloadMessages MainActor-sync cost: applyDiff=\(diffMs)ms rebuildGroups=\(rebuildMs)ms (fresh=\(freshMessages.count), loaded=\(loadedMessages.count))")
            // Boot-log mirror for stall-window correlation.
            BootProfiler.mark("reloadMessages MainActor-sync applyDiff=\(diffMs)ms rebuildGroups=\(rebuildMs)ms")
        }
    }

    // MARK: - Shared reload helpers

    /// Synchronous self-heal. Kept for the non-foreground paths that must be
    /// synchronous (`resetMessages`, which `init` calls and so cannot await).
    private func selfHealFolders() {
        applyResolvedFolders(resolveFoldersFromDB())
    }

    /// Async self-heal for the warm-foreground path (`reloadMessages`): resolves
    /// folders OFF the main thread so the GRDB read suspends rather than blocks
    /// the UI (Half A / PLAN_HANG_FIX). Identical healing behavior to
    /// `selfHealFolders` — only the threading differs.
    private func selfHealFoldersAsync() async {
        applyResolvedFolders(await resolveFoldersFromDBAsync())
    }

    /// Heal `folders` to `resolved` when membership+role differs. Shared by the
    /// sync and async self-heal paths; runs on the main actor.
    private func applyResolvedFolders(_ resolved: [Folder]) {
        guard !resolved.isEmpty else { return }
        // Set-based comparison — order differences between NavigationStore and
        // DB query don't count as a mismatch, only membership + role.
        let currentKeys = Set(folders.map { "\($0.id):\($0.role.rawValue)" })
        let resolvedKeys = Set(resolved.map { "\($0.id):\($0.role.rawValue)" })
        if currentKeys != resolvedKeys {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] selfHealFolders current=\(currentKeys.sorted()) → resolved=\(resolvedKeys.sorted())")
            print("[MoveTrace] self-healed folders from GRDB: \(currentKeys.count) → \(resolvedKeys.count)")
            folders = resolved
        }
    }

    private func resetSnippetState() {
        snippetTask?.cancel()
        snippetTask = nil
        snippetQueue.removeAll()
        snippetInFlight.removeAll()
        snippetFailed.removeAll()
    }

    private func requeueVisibleSnippets() {
        let visibleWindow = min(loadedMessages.count, SyncConfig.snippetPrefetchLookahead)
        var requeued = false
        for i in 0..<visibleWindow {
            if loadedMessages[i].snippet.isEmpty {
                if queueSnippetIfNeeded(loadedMessages[i].id) { requeued = true }
            }
        }
        if requeued { scheduleSnippetLoad() }
    }

    /// Re-fetch the currently loaded window of messages for diff-based reload.
    /// If nothing is loaded yet, fetches just the first page (synchronous).
    /// Bounded by count: fetches the top N messages (N = targetWindowSize)
    /// in the active sort order. Works for any sort (date, triage tagSortOrder).
    /// PLAN_INBOX_UNIFIED_READ.md Phase 3: routes through `InboxListReader.fetch`
    /// (async, rawPool-backed — same repaint-decoupling rationale this function
    /// used to inline, now owned by the reader/shell) which also folds in
    /// overlay-pinned (P) and staged (S) rows, so a reload no longer needs a
    /// separate staged-row re-seed. See InboxListReader.swift / InboxListComposer.swift.
    private func fetchFullRange() async -> [MessageSnapshot] {
        // Nothing loaded — first page (sync read, only on initial load)
        guard !loadedMessages.isEmpty else {
            return fetchPage(before: nil)
        }

        // Re-fetch up to the target window size. Sticky — only grows on explicit
        // user scroll (loadMoreMessages); never shrinks just because messages left
        // the inbox. Per-folder limit = target (a single folder might contain all
        // loaded messages in a unified inbox).
        let query = InboxListQuery(
            displayedFolderIds: Set(folders.map(\.id)),
            filterUnread: filterUnread,
            filterLabelIds: filterLabelIds,
            filterLabelAccountId: folders.first?.accountId,
            mode: mode,
            targetCount: targetWindowSize,
            beforeDate: nil,
            // F2 audit: a full-range reload's diff MUST include already-loaded
            // rows (that's the point of the diff) — never exclude here.
            excludeIds: []
        )
        return await InboxListReader.fetch(folders: folders, query: query)
    }

    /// Load next page for infinite scroll.
    /// Phase 1: local GRDB query (instant). Phase 2: network fetch if local exhausted.
    func loadMoreMessages() {
        guard !isLoadingOlder, hasMoreMessages else { return }
        let lastDate = loadedMessages.last?.date

        // Phase 1: try local data first
        let nextPage = fetchPage(before: lastDate)

        if !nextPage.isEmpty {
            for msg in nextPage { loadedIds.insert(msg.id) }
            loadedMessages.append(contentsOf: nextPage)
            targetWindowSize += SyncConfig.inboxPageSize
            hasMoreMessages = nextPage.count >= SyncConfig.inboxPageSize
            rebuildDisplayGroups()
            scheduleEvictionIfNeeded()
            return
        }

        // Phase 2: no more local data — fetch from network
        isLoadingOlder = true
        Task { @MainActor in
            defer { isLoadingOlder = false }
            do {
                let newCount = try await manager.fetchOlderMessages(folders: folders)
                if newCount == 0 {
                    hasMoreMessages = false
                } else {
                    // Network fetch added messages to GRDB; now load them locally
                    let freshPage = fetchPage(before: lastDate)
                    for msg in freshPage { loadedIds.insert(msg.id) }
                    loadedMessages.append(contentsOf: freshPage)
                    targetWindowSize += SyncConfig.inboxPageSize
                    hasMoreMessages = freshPage.count >= SyncConfig.inboxPageSize
                    rebuildDisplayGroups()
                    scheduleEvictionIfNeeded()
                }
            } catch is CancellationError {
                // Task cancelled (e.g., view disappeared) — not user-facing
            } catch {
                print("[InfiniteScroll] Error: \(error)")
                if !SyncEngine.isConnectionError(error) {
                    self.error = "Failed to load older messages: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Fetch one page of messages across all folders.
    /// Converts to value-type MessageSnapshot immediately.
    /// Bounded: fetches at most `folders.count × pageSize`, then trims to `pageSize`.
    /// PLAN_INBOX_UNIFIED_READ.md Phase 3: routes through `InboxListReader.fetchSync`
    /// (the sync `dbPool`-backed gather — status quo I/O, no new main-thread cost;
    /// see InboxListReader.swift §2.1b), which folds in overlay-pinned (P) and
    /// staged (S) rows the same way `fetchFullRange` now does. This is why
    /// `resetMessages`' page-1 fetch (`fetchPage(before: nil)`) already returns
    /// staged rows — its trailing `insertStagedRows` re-seed is now a no-op belt.
    private func fetchPage(before: Date?) -> [MessageSnapshot] {
        let pageSize = SyncConfig.inboxPageSize
        let tStart = CFAbsoluteTimeGetCurrent()

        let query = InboxListQuery(
            displayedFolderIds: Set(folders.map(\.id)),
            filterUnread: filterUnread,
            filterLabelIds: filterLabelIds,
            filterLabelAccountId: folders.first?.accountId,
            mode: mode,
            targetCount: pageSize,
            beforeDate: before,
            // F2 audit: exclude already-loaded ids INSIDE compose, before its
            // targetCount trim — an old already-loaded row (triage mode's
            // sort is not date-monotonic) must not eat a trim slot from a
            // not-yet-loaded one, which would shrink the page below pageSize
            // and flip `hasMoreMessages` false prematurely.
            excludeIds: loadedIds
        )
        let allResults = InboxListReader.fetchSync(folders: folders, query: query)

        // Timing: the reader owns the read+compose split internally now, so we
        // can only time the call as a whole (no more wait/query split) — still
        // worth a diagnostic since fetchPage is a SYNC main-actor call (initial
        // paint + infinite-scroll paging), the top remaining suspect for
        // scroll-time stalls.
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        if totalMs >= 50 {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] fetchPage (via InboxListReader.fetchSync) total=\(totalMs)ms folders=\(folders.count) page=\(pageSize) results=\(allResults.count)")
            BootProfiler.mark("fetchPage SYNC main-actor total=\(totalMs)ms")
        }

        // Belt: `query.excludeIds` above already does this exclusion INSIDE
        // compose (before its trim), so this should be a no-op in the common
        // case. Kept as a second layer in case `loadedIds` grew between the
        // query snapshot above and here (there's no `await` in between today,
        // but this guards against a future one) — pagination-append dedup is
        // the VM's concern either way (loadMoreMessages' cursor overlap), not
        // the reader's; the reader has no notion of what this VM instance
        // already has on screen.
        let unique = allResults.filter { !loadedIds.contains($0.id) }
        return Array(unique.prefix(pageSize))
    }

    // MARK: - Loaded Messages Eviction

    /// Deferred eviction — trims oldest snapshots on the NEXT run loop iteration,
    /// not during the current onAppear/render cycle (avoids SwiftUI layout crashes).
    /// Keeps evicted IDs in loadedIds so fetchPage won't re-fetch them (prevents
    /// infinite append→evict→re-fetch loop). IDs reset on full resetMessages().
    private func scheduleEvictionIfNeeded() {
        guard loadedMessages.count > SyncConfig.maxLoadedMessages else { return }
        Task { @MainActor in
            let maxLoaded = SyncConfig.maxLoadedMessages
            guard self.loadedMessages.count > maxLoaded else { return }
            let trimCount = self.loadedMessages.count - maxLoaded
            self.loadedMessages.removeFirst(trimCount)
            self.rebuildDisplayGroups()
        }
    }

    // MARK: - On-Demand Snippet Loading
    // Tier 1: FTS local lookup (instant). Tier 2: network body fetch → snippet extract.
    // No MessageBody created. Body text released immediately after 150-char extraction.

    /// Called when a message row appears in the viewport.
    /// Prefetches snippets for a window of messages ahead (and slightly behind) so
    /// the user never sees empty snippets while scrolling.
    func requestSnippetIfNeeded(for snapshot: MessageSnapshot) {
        guard let idx = loadedMessages.firstIndex(where: { $0.id == snapshot.id }) else {
            if snapshot.snippet.isEmpty { queueSnippetIfNeeded(snapshot.id) }
            return
        }

        // Prefetch window: small look-behind (upward scroll) + large look-ahead
        let lookahead = SyncConfig.snippetPrefetchLookahead
        let start = max(0, idx - lookahead / 4)
        let end = min(loadedMessages.count, idx + lookahead)

        var queued = false
        for i in start..<end {
            let msg = loadedMessages[i]
            guard msg.snippet.isEmpty else { continue }
            if queueSnippetIfNeeded(msg.id) { queued = true }
        }

        if queued { scheduleSnippetLoad() }
    }

    @discardableResult
    private func queueSnippetIfNeeded(_ id: String) -> Bool {
        let inFlight = snippetInFlight.contains(id)
        let failed = snippetFailed.contains(id)
        let queued = snippetQueue.contains(id)
        guard !inFlight, !failed, !queued else {
            if failed { print("[SnippetLoader] BLOCKED by snippetFailed: \(id.prefix(40))") }
            return false
        }
        snippetQueue.insert(id)
        return true
    }

    private func scheduleSnippetLoad() {
        guard snippetTask == nil else { return }
        snippetTask = Task { @MainActor in
            // Debounce — collect nearby onAppear calls into one batch
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { snippetTask = nil; return }
            await loadSnippetBatch()
            snippetTask = nil
            if !snippetQueue.isEmpty { scheduleSnippetLoad() }
        }
    }

    private func loadSnippetBatch() async {
        let batch = Array(snippetQueue.prefix(SyncConfig.snippetOnDemandChunkSize))
        for id in batch { snippetQueue.remove(id) }
        guard !batch.isEmpty else { return }

        for id in batch { snippetInFlight.insert(id) }
        defer { for id in batch { snippetInFlight.remove(id) } }

        // Collect all snippet updates before touching @Observable state (avoids per-snippet re-renders)
        var snippetUpdates: [(headerId: String, snippet: String)] = []
        var needsFTS: [String] = []

        // Tier 0: DB check — snippet may already be in messageHeader (written by fetchBody
        // or ActiveBodyQueue) but the in-memory snapshot is stale. Idempotent self-heal.
        //
        // ONE async batched read (suspends, never blocks the main thread). This used
        // to be up to 15 SYNCHRONOUS per-id `dbPool.read` calls on the @MainActor —
        // during a post-merge/sync write burst (reader-pool contention + large WAL)
        // each could block, and the loop stalled the main actor exactly when new
        // rows were getting their snippets (the "stall when snippet shows up").
        // Same fix shape as FIX B (checkLargeInbox) / reloadMessages (fetchFullRange).
        //
        // rawPool DELIBERATELY: `PrioritizedDatabase.read` front-runs a read-through
        // staging merge (`mergeIfStagingPending`) — snippets don't need post-merge
        // freshness (the reconcile reload covers them), and going through it would
        // (a) queue this read behind an in-flight multi-second merge and (b) add a
        // new trigger source for TTL re-merges during a gradual staging window.
        // Precedent: the notification-tap resolution in MailNavigationView.
        let tRead = CFAbsoluteTimeGetCurrent()
        let dbHeaders: [String: MessageHeader] = (try? await AppDatabase.rawPool.read { db in
            var result: [String: MessageHeader] = [:]
            for id in batch {
                if let header = try MessageHeader.fetchOne(db, key: id) {
                    result[id] = header
                }
            }
            return result
        }) ?? [:]
        let readMs = Int((CFAbsoluteTimeGetCurrent() - tRead) * 1000)
        if readMs >= 50 {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] snippet batch header read \(readMs)ms (n=\(batch.count))")
            BootProfiler.mark("snippet batch header read \(readMs)ms (n=\(batch.count))")
        }
        guard !Task.isCancelled else { return }
        // ADR-IOS-049: staged rows rendered in-memory may not be durable in GRDB
        // yet — fall back to the merge's in-memory snapshot so a just-surfaced
        // row isn't blacklisted. Mirrors `lookupMessage`'s synthesis pattern.
        let headerFor: (String) -> MessageHeader? = { id in
            dbHeaders[id] ?? NSEDataBridge.latestStagedRows.withLock({ rows in
                rows.first { $0.headerId == id }
            })?.toMessageHeader()
        }
        for headerId in batch {
            if let header = headerFor(headerId), !header.snippet.isEmpty {
                snippetUpdates.append((headerId: headerId, snippet: header.snippet))
            } else {
                needsFTS.append(headerId)
            }
        }
        print("[SnippetLoader] Batch \(batch.count): tier0=\(snippetUpdates.count) needsFTS=\(needsFTS.count) readMs=\(readMs)")

        var networkNeeded: [(headerId: String, header: MessageHeader)] = []

        // Tier 1: FTS lookup (local, no network)
        for headerId in needsFTS {
            guard !Task.isCancelled else { return }
            if let body = try? await SearchIndex.shared.bodyText(headerId: headerId) {
                let snippet = EmailFilter.snippetFromPlainText(body)
                if !snippet.isEmpty {
                    try? await dbPool.write { db in
                        try db.execute(sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?", arguments: [snippet, headerId])
                    }
                    snippetUpdates.append((headerId: headerId, snippet: snippet))
                    continue
                }
            }
            // Need network fetch — reuse the tier-0 batched read (no sync re-read on main)
            if let header = headerFor(headerId) {
                networkNeeded.append((headerId: headerId, header: header))
            } else {
                snippetFailed.insert(headerId)
            }
        }

        print("[SnippetLoader] Tier1 done: ftsHits=\(snippetUpdates.count - batch.count + needsFTS.count) networkNeeded=\(networkNeeded.count)")

        // Tier 2: Network body fetch — extract snippet + update FTS, release body immediately.
        for item in networkNeeded {
            guard !Task.isCancelled else { print("[SnippetLoader] Tier2 cancelled"); return }
            guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: item.header.accountId) }),
                  let provider = await manager.provider(for: account) else {
                print("[SnippetLoader] Tier2 NO PROVIDER for \(item.header.accountId) folder=\(item.header.folderPath)")
                // Provider temporarily unavailable (reconnecting) — don't blacklist, leave retryable
                continue
            }

            do {
                print("[SnippetLoader] Tier2 fetching msgId=\(item.header.messageId) folder=\(item.header.folderPath)")
                let fullMessage = try await provider.fetchMessage(id: item.header.messageId, folder: item.header.folderPath)
                // We just downloaded the WHOLE body for the snippet — CACHE it now
                // instead of discarding it. Previously this path extracted a ~150
                // char snippet and threw the body away, so opening the message
                // re-downloaded the same body (the "first open is slow / re-render"
                // report). Route the already-fetched message through the shared
                // BodyFetchProcessor (single source of truth) so it persists the
                // rendered MessageBody (→ instant open, no re-download), writes
                // FTS, derives the snippet, and enqueues AI/embedding. `enableAI`
                // mirrors the queue split: inbox → AI + active embedding (as
                // ActiveBodyQueue); other folders → backfill embedding only (as
                // BackfillBodyQueue).
                let processorItem = BodyFetchProcessor.Item(
                    headerId: item.headerId, accountId: item.header.accountId,
                    folderPath: item.header.folderPath, messageId: item.header.messageId,
                    isInInbox: item.header.isInInbox
                )
                let enableAI = item.header.isInInbox
                if case .success(let fetchResult) = await BodyFetchProcessor.renderFetched(item: processorItem, fullMessage: fullMessage) {
                    let (_, processed) = await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: enableAI)
                    if let processed {
                        await BodyFetchProcessor.flushBatch([processed], enableAI: enableAI)
                        snippetUpdates.append((headerId: item.headerId, snippet: processed.snippet))
                    } else {
                        // confirmed-empty / first-empty-retry — no usable snippet this pass
                        print("[SnippetLoader] Tier2 no body content for msgId=\(item.header.messageId)")
                    }
                }
            } catch {
                print("[SnippetLoader] Failed for \(item.headerId): \(error)")
                // Only blacklist on non-connection errors (e.g., messageNotFound).
                // Connection errors are transient — leave retryable for next scroll/appearance.
                if !SyncEngine.isConnectionError(error) {
                    snippetFailed.insert(item.headerId)
                }
            }

            // Yield between network fetches to avoid flooding the IMAP actor
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Apply all snippet updates in-place — mutating individual elements preserves
        // array identity so SwiftUI only re-renders the changed rows.
        if !snippetUpdates.isEmpty {
            for (headerId, snippet) in snippetUpdates {
                if let idx = loadedMessages.firstIndex(where: { $0.id == headerId }) {
                    loadedMessages[idx].snippet = snippet
                }
            }
            rebuildDisplayGroups()
        }

        // Bound the failed set to prevent unbounded growth during infinite scroll
        if snippetFailed.count > 1000 {
            snippetFailed.removeAll()
        }
    }

    // MARK: - Sync

    /// Fire-and-forget sync — not tied to SwiftUI task lifecycle.
    /// Safe to call from .onAppear; explicitly cancelled on VM deinit so
    /// rapid-nav-discarded VMs don't keep syncing behind our back.
    ///
    /// Deferred by 250ms so the current view's first render commits before
    /// sync work hits MainActor. Under rapid nav (inbox → archive → inbox),
    /// each new InboxView.onAppear calls startSync(); without the delay,
    /// multiple syncs pile up while SwiftUI is still laying out the most
    /// recent view, visibly stalling the UI and the top nav bar config
    /// (reported as "large title not inline, toolbar items elongated").
    /// If the VM deinits within the 250ms (because user already moved on),
    /// the Task is cancelled in deinit and no sync fires — natural
    /// coalescing of rapid-nav sync requests.
    func startSync() {
        // Inflight guard — idempotent semantics. Any call while a sync is
        // already queued (in its 1000ms delay) OR actively running is a no-op.
        guard !isSyncPending, !isRefreshing else { return }
        isSyncPending = true
        syncTask = Task { @MainActor [weak self] in
            // `defer` fires on EVERY exit path — normal completion, early
            // return after cancellation check, or if `performSync` throws
            // down the road. Guaranteed to clear `isSyncPending` precisely.
            defer { self?.isSyncPending = false }
            // 1000ms debounce — gives view transitions a full second to
            // settle before sync work hits MainActor. Shorter windows let
            // sync start before animations settle, which visibly stutters.
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled, let self else { return }
            await self.performSync()
        }
    }

    /// Awaitable sync for pull-to-refresh (keeps spinner visible until done).
    func refreshSync() async {
        if isRefreshing {
            // Wait for in-progress sync with a timeout to prevent infinite loop
            // if isRefreshing is never cleared (e.g., cancelled task).
            var waited = 0
            while isRefreshing && waited < 150 { // 30s max (150 * 200ms)
                try? await Task.sleep(for: .milliseconds(200))
                waited += 1
            }
            return
        }
        await performSync()
    }

    private func performSync() async {
        // In screenshot mode, skip all network sync — use seeded GRDB data only.
        guard !ScreenshotMode.isActive else { return }

        // Self-heal: if folders are empty, try resolving from GRDB before bailing.
        if folders.isEmpty {
            let resolved = await resolveFoldersFromDBAsync()
            if !resolved.isEmpty {
                folders = resolved
                print("[Sync] performSync self-healed folders from GRDB: \(resolved.count)")
                resetMessages()
            }
        }
        let accountIds = Array(Set(folders.map(\.accountId)))
        guard !accountIds.isEmpty else { return }

        let uniqueAccounts: [Account]
        do {
            uniqueAccounts = try await dbPool.read { db in
                try Account.filter(accountIds.contains(Column("id"))).fetchAll(db)
            }
        } catch {
            print("[Sync] Error fetching accounts: \(error)")
            return
        }
        guard !uniqueAccounts.isEmpty else { return }

        isRefreshing = true
        // `defer` guarantees the in-progress guard clears on EVERY exit — including
        // task cancellation mid-sync (user navigated away) or a throw from
        // reloadMessages below. Without it, a torn-down sync could leave
        // `isRefreshing` stuck true, which makes refreshSync() silently no-op
        // (wait-then-return) for all future pull-to-refreshes — a stuck-stale
        // "Updated N min ago" subtitle with no way to refresh it.
        defer { isRefreshing = false }
        error = nil
        do {
            // Ensure providers are connected
            for account in uniqueAccounts {
                if await manager.provider(for: account) == nil {
                    try await manager.connectAccount(account)
                }
            }

            // Priority: sync ONLY the currently viewed folders first.
            // e.g. unified inbox → sync inbox folders only, not sent/trash/archive.
            try await manager.syncFolders(folders)

            AccountManagerState.shared.lastSyncFailed = false
            AccountManagerState.shared.lastSyncCompletedAt = Date()
        } catch is CancellationError {
            // Task cancelled (e.g., user navigated away) — not user-facing
        } catch let error where SyncEngine.isTransientError(error) {
            // Transient provider blip — HTTP 5xx/429 from a reachable server (e.g. a
            // momentary Microsoft Graph 503 during connect). NOT a real sync failure:
            // the next poll/refresh retries. Leave lastSyncFailed unchanged and show
            // no error banner so a single server hiccup doesn't surface to the user.
            print("[Sync] Transient error (not surfaced): \(error)")
        } catch let error where error.isDatabaseSuspensionAbort {
            // GRDB write aborted because the database is suspended (ADR-IOS-041).
            // Benign and expected at a background-suspension instant — retries on
            // the next wake — so it must NOT surface as a failed sync.
            print("[Sync] Database suspended (not surfaced): \(error)")
        } catch {
            print("[Sync] Error: \(error)")
            AccountManagerState.shared.lastSyncFailed = true
            if !SyncEngine.isConnectionError(error) {
                self.error = error.localizedDescription
            }
        }

        // Refresh loaded messages to pick up changes from sync.
        // Badge + unread counts already updated by UnreadCountManager during syncFolders.
        // With overlay, reloadMessages is always safe to call.
        await reloadMessages()
    }

    // MARK: - Message Actions

    private func isAdmissibleDurableMessageAction(_ message: MessageHeader) -> Bool {
        MessageIdentity.durableActionAddress(
            accountId: message.accountId,
            folderPath: message.folderPath,
            rfc822MessageId: message.rfc822MessageId,
            providerMessageId: message.messageId
        ) != nil
    }

    private func isAdmissibleDurableMessageAction(_ snapshot: MessageSnapshot) -> Bool {
        MessageIdentity.durableActionAddress(
            accountId: snapshot.accountId,
            folderPath: snapshot.folderPath,
            rfc822MessageId: snapshot.rfc822MessageId,
            providerMessageId: snapshot.messageId
        ) != nil
    }

    /// Provider-neutral admission gate for durable message actions. Members
    /// resolve through the same durable/staged lookup as every other gesture
    /// path so account, source folder, and member identity are validated
    /// before any optimistic mutation. Identity is hybrid
    /// (PLAN_IDENTITY_HYBRID): normalized RFC Message-ID when present, else
    /// the provider ID admitted as an opaque token member.
    func durableMessageActionIsAdmissible(_ messageId: String) -> Bool {
        if let snapshot = loadedMessages.first(where: { $0.id == messageId }) {
            return isAdmissibleDurableMessageAction(snapshot)
        }
        guard let message = lookupMessage(messageId) else { return false }
        return isAdmissibleDurableMessageAction(message)
    }

    /// Preserves caller order while removing unresolved or RFC-invalid
    /// members before a thread gesture hides rows, creates Undo state, or
    /// appends an intention-journal record.
    func admissibleDurableMessageActionIds(_ messageIds: [String]) -> [String] {
        messageIds.filter(durableMessageActionIsAdmissible)
    }

    /// Draft deletion is a resource operation, not a durable message action,
    /// so it remains outside the universal RFC admission rule.
    func deleteActionIsAdmissible(_ messageId: String) -> Bool {
        if let snapshot = loadedMessages.first(where: { $0.id == messageId }) {
            let folderId = MessageIdentity.folderId(
                accountId: snapshot.accountId,
                folderPath: snapshot.folderPath
            )
            if lookupFolderRole(folderId) == .drafts { return true }
            guard isAdmissibleDurableMessageAction(snapshot) else { return false }
            if lookupFolderRole(folderId) == .trash { return true }
            guard let trashPath = lookupFolderPath(accountId: snapshot.accountId, role: .trash) else { return false }
            return !trashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let message = lookupMessage(messageId) else { return false }
        if lookupFolderRole(message.folderId) == .drafts { return true }
        guard isAdmissibleDurableMessageAction(message) else { return false }
        if lookupFolderRole(message.folderId) == .trash { return true }
        guard let trashPath = lookupFolderPath(accountId: message.accountId, role: .trash) else { return false }
        return !trashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func admissibleDeleteActionIds(_ messageIds: [String]) -> [String] {
        messageIds.filter(deleteActionIsAdmissible)
    }

    /// True when archiving `messageId` would be a same-folder move — the message
    /// already lives in an archive-role folder. Callers MUST treat the
    /// archive as a no-op and must NOT dismiss/hide the row.
    ///
    /// Role-based check FIRST: an account can carry more than one folder with
    /// the same role (e.g. iCloud "Trash" + "Deleted Messages"), and the
    /// canonical-path lookup below is `fetchOne`-arbitrary among them — a
    /// path-only comparison can miss the folder the user is actually viewing.
    /// Being IN any folder of the destination role makes the action a no-op.
    func archiveIsNoOp(_ messageId: String) -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        if lookupFolderRole(message.folderId) == .archive { return true }
        guard let archivePath = lookupFolderPath(accountId: message.accountId, role: .archive) else { return false }
        guard !archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return message.folderPath == archivePath
    }

    /// True when deleting `messageId` would be a same-folder move — the message
    /// already lives in a trash-role folder. Callers MUST treat the
    /// delete as a no-op and must NOT dismiss/hide the row. Drafts are not
    /// affected: they delete via the draft-specific path, not move-to-trash.
    /// See `archiveIsNoOp` for why the role check comes first.
    func deleteIsNoOp(_ messageId: String) -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        if lookupFolderRole(message.folderId) == .trash { return true }
        guard let trashPath = lookupFolderPath(accountId: message.accountId, role: .trash) else { return false }
        guard !trashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return message.folderPath == trashPath
    }

    /// Returns false when nothing was recorded (lookup miss, no archive
    /// folder for the account, or already-at-destination no-op) — callers
    /// (InboxView's single-message dismiss/swipe/move sites) MUST NOT hide
    /// the row when this returns false, or it vanishes forever with no undo
    /// entry (same defect class `archiveThread`'s skipped-ids contract
    /// already guards against; see this function's InboxView call sites).
    @discardableResult
    func archive(_ messageId: String) -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        guard isAdmissibleDurableMessageAction(message) else { return false }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp.
        guard lookupFolderRole(message.folderId) != .archive else { return false }
        guard let archivePath = lookupFolderPath(accountId: message.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(message.accountId)")
            return false
        }
        guard !archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard message.folderPath != archivePath else { return false }
        let destFolderId = "\(message.accountId):\(archivePath)"
        // Undo command built directly from the pre-move header (ADR-IOS-060):
        // no full-row snapshot, no overlay adjustment needed — `UndoMember`
        // carries only the hybrid member identity and the pre-move source path.
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: [message],
                forwardDestinationByAccount: [message.accountId: archivePath]
            )
        ))
        // Archive's destination is never the inbox (guarded above), so
        // `message.isInInbox` alone determines "leaving the inbox" — clear
        // the tag in the overlay (F6) so the mid-drain window doesn't flash
        // the stale tag in the destination folder's row. record() (ADR-IOS-058)
        // replaces retain+registerMutation+enqueueWrite: the fold executor
        // resolves row truth and calls move() itself.
        manager.record(
            ids: [messageId],
            kind: .move(.folder(folderId: destFolderId, folderPath: archivePath, isInbox: false)),
            displays: [messageId: .init(folderId: destFolderId, actionTag: message.isInInbox ? .some(nil) : nil)],
            origin: .gesture
        )
        return true
    }

    /// Returns the ids of `messageIds` that were NOT acted upon (no archive
    /// folder for their account, or nothing resolved at all) — the caller
    /// (InboxView) optimistically hides the FULL member list before calling
    /// this, so it MUST un-hide exactly the ids returned here or those rows
    /// vanish forever with no undo entry (regression fixed alongside
    /// b20d1f7's per-account archive routing).
    @discardableResult
    func archiveThread(_ messageIds: [String]) -> [String] {
        let messages = messageIds
            .compactMap { lookupMessage($0) }
            .filter(isAdmissibleDurableMessageAction)
        guard let first = messages.first else { return messageIds }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp. The View's own
        // archiveIsNoOp check already suppresses the dismiss for this case,
        // so nothing was hidden that needs un-hiding.
        guard lookupFolderRole(first.folderId) != .archive else { return [] }

        // A thread can span accounts (ThreadGroupBuilder groups by bare
        // computedThreadId with no account partition; ThreadUtils.
        // findAdoptableThreadId probes rfc822/inReplyTo/references with no
        // accountId filter) — resolve EACH member's OWN account's archive
        // path instead of stamping `first`'s account's path on every member.
        // Same defect class `moveToRoleFolderPerAccount` already fixed for
        // tools/notifications (see its doc comment); this uses the `.role`
        // intention kind so the fold executor's existing `.role` branch
        // (`archive()` → `moveToRoleFolderPerAccount`) resolves the
        // destination PER ACCOUNT at execution time. Members whose account
        // has no archive folder are excluded entirely — mirrors
        // `moveToRoleFolderPerAccount`'s own skip — and are reported back to
        // the caller as skipped (see this function's doc comment).
        var actionable: [MessageHeader] = []
        var displays: [String: AccountManager.PendingMutation] = [:]
        var forwardDestinationByAccount: [String: String] = [:]
        for msg in messages {
            guard let archivePath = lookupFolderPath(accountId: msg.accountId, role: .archive) else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Queue] archiveThread — no archive folder for account \(msg.accountId), skipping message \(msg.id)")
                }
                continue
            }
            guard !archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            actionable.append(msg)
            forwardDestinationByAccount[msg.accountId] = archivePath
            let destFolderId = "\(msg.accountId):\(archivePath)"
            displays[msg.id] = .init(folderId: destFolderId, actionTag: msg.isInInbox ? .some(nil) : nil)
        }
        // No account in the thread has an archive folder — every id was
        // hidden by the caller and nothing was recorded, so every id must be
        // reported back as skipped (unlike the no-op guard above, the View
        // has no equivalent pre-dismiss check for this case).
        guard !actionable.isEmpty else { return messageIds }

        // Undo commands built directly from the pre-move headers
        // (ADR-IOS-060): each member restores via its OWN account's recorded
        // destination — `UndoAccountCommand` routes per account, never a
        // single representative value.
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: actionable,
                forwardDestinationByAccount: forwardDestinationByAccount
            )
        ))
        // Archive's destination is never the inbox (guarded above), so each
        // member's own `isInInbox` determines "leaving the inbox" (F6) — a
        // thread can mix members already outside the inbox with ones still
        // in it. ONE record covers every actionable member: per-account
        // destination resolution is the fold executor's `.role` branch job
        // at execution time (`archive()` → `moveToRoleFolderPerAccount`),
        // never the call site's.
        manager.record(
            ids: actionable.map(\.id),
            kind: .move(.role(.archive)),
            displays: displays,
            origin: .gesture
        )
        let actedUpon = Set(actionable.map(\.id))
        return messageIds.filter { !actedUpon.contains($0) }
    }

    /// Returns false when nothing was recorded (lookup miss, no trash folder
    /// for the account, or already-at-destination no-op) — callers MUST NOT
    /// hide the row when this returns false. See `archive(_:)`'s doc comment
    /// for the full contract; drafts always return true (they ARE acted upon
    /// via the draft-specific deletion path).
    @discardableResult
    func delete(_ messageId: String) async -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        // Drafts folder: use draft-specific deletion (DELETE /drafts or STORE+EXPUNGE)
        // instead of move-to-trash, which doesn't work for Gmail drafts.
        let folderRole = lookupFolderRole(message.folderId)
        if folderRole == .drafts {
            await deleteDraftMessage(message)
            return true
        }
        guard isAdmissibleDurableMessageAction(message) else { return false }
        AccountManager.logDeleteTrace(accountId: message.accountId, messages: [message], callSite: "InboxViewModel.delete")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp.
        if folderRole == .trash { return false }
        guard let trashPath = lookupFolderPath(accountId: message.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(message.accountId)")
            return false
        }
        guard !trashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard message.folderPath != trashPath else { return false }
        let destFolderId = "\(message.accountId):\(trashPath)"
        // Undo command built directly from the pre-move header (ADR-IOS-060).
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: [message],
                forwardDestinationByAccount: [message.accountId: trashPath]
            )
        ))
        // Delete's destination is never the inbox (guarded above), so
        // `message.isInInbox` alone determines "leaving the inbox" (F6).
        // record() (ADR-IOS-058) replaces retain+registerMutation+enqueueWrite.
        manager.record(
            ids: [messageId],
            kind: .move(.folder(folderId: destFolderId, folderPath: trashPath, isInbox: false)),
            displays: [messageId: .init(folderId: destFolderId, actionTag: message.isInInbox ? .some(nil) : nil)],
            origin: .gesture
        )
        return true
    }

    /// Returns the ids of `messageIds` that were NOT acted upon — see
    /// `archiveThread`'s doc comment for the un-hide contract this satisfies.
    @discardableResult
    func deleteThread(_ messageIds: [String]) async -> [String] {
        let resolvedMessages = messageIds.compactMap { lookupMessage($0) }
        guard let resolvedFirst = resolvedMessages.first else { return messageIds }
        // Drafts folder: delete each draft individually — every resolved
        // message IS acted upon here, so only ids that never resolved (if
        // any) are reported skipped.
        let folderRole = lookupFolderRole(resolvedFirst.folderId)
        if folderRole == .drafts {
            for message in resolvedMessages {
                await deleteDraftMessage(message)
            }
            let actedUpon = Set(resolvedMessages.map(\.id))
            return messageIds.filter { !actedUpon.contains($0) }
        }
        let messages = resolvedMessages.filter {
            isAdmissibleDurableMessageAction($0)
        }
        guard let first = messages.first else { return messageIds }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "InboxViewModel.deleteThread")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp. The View's own
        // deleteIsNoOp check already suppresses the dismiss for this case,
        // so nothing was hidden that needs un-hiding.
        if folderRole == .trash { return [] }

        // A thread can span accounts — resolve EACH member's OWN account's
        // trash path instead of stamping `first`'s account's path on every
        // member (same defect class `moveToRoleFolderPerAccount` already
        // fixed for tools/notifications; see archiveThread's identical fix
        // for the full rationale). `.role` intention kind routes through the
        // fold executor's `.role` branch (`delete()` →
        // `moveToRoleFolderPerAccount`), which resolves PER ACCOUNT at
        // execution time. Members whose account has no trash folder are
        // excluded entirely and reported back to the caller as skipped.
        var actionable: [MessageHeader] = []
        var displays: [String: AccountManager.PendingMutation] = [:]
        var forwardDestinationByAccount: [String: String] = [:]
        for msg in messages {
            guard let trashPath = lookupFolderPath(accountId: msg.accountId, role: .trash) else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Queue] deleteThread — no trash folder for account \(msg.accountId), skipping message \(msg.id)")
                }
                continue
            }
            guard !trashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            actionable.append(msg)
            forwardDestinationByAccount[msg.accountId] = trashPath
            let destFolderId = "\(msg.accountId):\(trashPath)"
            displays[msg.id] = .init(folderId: destFolderId, actionTag: msg.isInInbox ? .some(nil) : nil)
        }
        // No account in the thread has a trash folder — every id was hidden
        // by the caller and nothing was recorded, so every id must be
        // reported back as skipped (unlike the no-op guard above, the View
        // has no equivalent pre-dismiss check for this case).
        guard !actionable.isEmpty else { return messageIds }

        // Undo commands built directly from the pre-move headers
        // (ADR-IOS-060) — see archiveThread's identical rationale.
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: actionable,
                forwardDestinationByAccount: forwardDestinationByAccount
            )
        ))
        // Delete's destination is never the inbox (guarded above), so each
        // member's own `isInInbox` determines "leaving the inbox" (F6).
        // ONE record covers every actionable member.
        manager.record(
            ids: actionable.map(\.id),
            kind: .move(.role(.trash)),
            displays: displays,
            origin: .gesture
        )
        let actedUpon = Set(actionable.map(\.id))
        return messageIds.filter { !actedUpon.contains($0) }
    }

    /// Delete a draft message from the Drafts folder using the draft-specific deletion path.
    /// Optimistically removes the MessageHeader locally, then queues server deletion.
    private func deleteDraftMessage(_ message: MessageHeader) async {
        // Optimistic local removal
        do {
            try await dbPool.write { db in
                _ = try MessageHeader.deleteOne(db, key: message.id)
                _ = try? MessageBody.deleteOne(db, key: message.id)
            }
        } catch {
            print("[Queue] ERROR: failed to delete draft header locally: \(error)")
        }
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        // Queue server-side draft deletion using stableId (survives UID remaps/restarts).
        // For Gmail/Exchange: stableId == messageId (non-numeric). For IMAP: stableId ==
        // rfc822MessageId, resolved to UID at execution time via IMAPProvider.resolveUID.
        // GmailProvider.deleteDraft handles fallback from draft resource ID to messages.trash.
        await manager.queueDraftDelete(
            serverDraftId: message.stableId,
            accountId: message.accountId,
            rfc822MessageId: message.rfc822MessageId
        )
    }

    /// Current state comes from the ON-SCREEN snapshot — the visualized state
    /// the user is acting on — never from the admission lookup. `lookupMessage` is a
    /// synchronous main-actor `dbPool.read` that lags the FIFO write-queue
    /// depth by seconds under write bursts (logged 3.7s main-thread stalls);
    /// gating the gesture on it meant a second toggle within that window read
    /// the same stale DB row as the first and computed the SAME target — a
    /// dead toggle (see `PROJECT_MEMORY.md` write-queue notes). `snapshot.isRead`
    /// already reflects any prior optimistic flip + overlay, so a rapid
    /// double-toggle before the queue drains computes the correct target from
    /// what's actually on screen (the codebase's act-on-visualized-state
    /// principle — see the User Interaction Freeze Rule in CLAUDE.md).
    func toggleRead(_ messageId: String) {
        guard let snapshot = loadedMessages.first(where: { $0.id == messageId }) else { return }
        guard durableMessageActionIsAdmissible(messageId) else { return }
        let newIsRead = !snapshot.isRead

        // Optimistic in-memory mutation (instant visual feedback)
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].isRead = newIsRead
        }
        // Gesture intents on the same id coalesce to the NET target
        // (ADR-IOS-057): `registerGestureIntent` updates the display overlay
        // synchronously and queues at most ONE write per open cycle, so N
        // rapid alternating toggles execute as ONE write of the FINAL
        // intent instead of N serial writes.
        manager.registerGestureIntent(id: messageId, .isRead(target: newIsRead, baseline: snapshot.isRead))
        rebuildDisplayGroups()
    }

    /// Batched set-read. Optimistically flips on-screen unread members, then
    /// appends ONE batch intention record (ADR-IOS-058) spanning every
    /// target id — on-screen unread + off-screen. Use for thread-level
    /// actions (tag-tap archive/delete/reply).
    ///
    /// Current-read-state is derived from the ON-SCREEN snapshot where
    /// available (act-on-visualized-state, mirrors `toggleRead`). The only
    /// gesture-path lookup is the mandatory account/source/RFC admission
    /// check; it never supplies read state. Thread-member ids can be stale
    /// relative to the CURRENT `loadedMessages`: callers capture a `ThreadGroup`
    /// value at render time (`InboxView.executeTaggedAction` /
    /// `dismissAndArchiveThread` / `dismissAndDeleteThread`), and a background
    /// reload can evict/replace rows before the user's tap actually fires.
    ///
    /// The fold executor (`AccountManager.executeFold`, `IntentionFold.fold`)
    /// now owns everything that used to live in this function's hand-rolled
    /// `enqueueWrite` closure: off-main header resolution for BOTH on- and
    /// off-screen ids, the filter-to-currently-unread semantics (its
    /// row-truth compare in `executeFold` phase 2 skips any id whose resolved
    /// header already reflects `isRead == true`), vanished-id cleanup, and
    /// the batched `manager.markRead` call itself — sibling rfc822 expansion,
    /// unread-count math, and `PendingOperation` insertion are all preserved
    /// because the fold calls that SAME existing action method with the
    /// resolved header set.
    ///
    /// ONE deliberate semantics refinement (ADR-IOS-058): the old on-screen
    /// path wrote UNCONDITIONALLY — a row already `isRead == true` still got
    /// re-written and re-queued a redundant `PendingOperation`. The fold
    /// instead compares the net target against RESOLVED ROW TRUTH and skips a
    /// field that already matches (assert-latest-visualized-intent
    /// semantics) — fewer redundant remote STOREs, and no user intention is
    /// dropped (only the redundant WRITE is, never the intention). Off-screen
    /// ids also get their display overlay entry AT GESTURE TIME now (inside
    /// `record()`) instead of inside the old in-closure resolve — strictly
    /// better: a row that scrolls on-screen mid-window immediately shows the
    /// pending read state instead of only after the write lands.
    func markRead(_ messageIds: [String]) {
        let messageIds = admissibleDurableMessageActionIds(messageIds)
        guard !messageIds.isEmpty else { return }

        let onScreenIds = Set(loadedMessages.map(\.id))
        let unreadOnScreenIds = messageIds.filter { id in
            onScreenIds.contains(id) && (loadedMessages.first { $0.id == id }?.isRead == false)
        }
        let offScreenIds = messageIds.filter { !onScreenIds.contains($0) }
        guard !unreadOnScreenIds.isEmpty || !offScreenIds.isEmpty else { return }

        // Optimistic in-memory mutation for on-screen unread messages (instant visual feedback)
        if !unreadOnScreenIds.isEmpty {
            let flipSet = Set(unreadOnScreenIds)
            for idx in loadedMessages.indices where flipSet.contains(loadedMessages[idx].id) {
                loadedMessages[idx].isRead = true
            }
            rebuildDisplayGroups()
        }

        // ONE batch intention record for every target id — `record()`
        // (ADR-IOS-058) appends to the intention journal (each member id's
        // display becomes visible via the derived overlay) and enqueues at
        // most one fold closure on the FIFO write queue.
        let allTargetIds = unreadOnScreenIds + offScreenIds
        var displays: [String: AccountManager.PendingMutation] = [:]
        for id in allTargetIds {
            displays[id] = AccountManager.PendingMutation(isRead: true)
        }
        manager.record(ids: allTargetIds, kind: .isRead(true), displays: displays, origin: .gesture)
    }

    func markAllAsRead() {
        let batchSize = SyncConfig.inboxPageSize
        let foldersCopy = folders

        Task { @MainActor in
            await manager.enqueueWrite { [manager] in
                let dbPool = AppDatabase.dbPool
                for folder in foldersCopy {
                    let fid = folder.id

                    while true {
                        let batch: [MessageHeader]
                        do {
                            batch = try await dbPool.read { db in
                                try MessageHeader
                                    .filter(Column("folderId") == fid && Column("isRead") == false)
                                    .limit(batchSize)
                                    .fetchAll(db)
                            }
                        } catch { break }
                        guard !batch.isEmpty else { break }
                        await manager.markRead(batch)
                    }
                }
            }

            // Refresh sidebar unread counts + badge after mark-all-as-read
            let folderIds = Set(foldersCopy.map(\.id))
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            Task { await UnreadCountManager.shared.requestRecount(folderIds: folderIds) }
            await reloadMessages()
        }
    }

    /// Same act-on-visualized-state shape as `toggleRead` — see its doc comment.
    func toggleFlag(_ messageId: String) {
        guard let snapshot = loadedMessages.first(where: { $0.id == messageId }) else { return }
        guard durableMessageActionIsAdmissible(messageId) else { return }
        let newFlagged = !snapshot.isFlagged
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].isFlagged = newFlagged
        }
        // Gesture intents on the same id coalesce to the NET target
        // (ADR-IOS-057) — see `toggleRead`'s doc comment.
        manager.registerGestureIntent(id: messageId, .isFlagged(target: newFlagged, baseline: snapshot.isFlagged))
        rebuildDisplayGroups()
    }

    /// Only reachable for on-screen rows (context menu on a visible row) —
    /// mirrors `toggleRead`'s guard on the on-screen snapshot. ActionTag is
    /// local-only (ADR-IOS-036), so provider-action admission does not apply.
    func applyManualTag(_ messageId: String, tag: ActionTag?) {
        guard let snapshot = loadedMessages.first(where: { $0.id == messageId }) else { return }
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].actionTag = tag
            loadedMessages[idx].tagSortOrder = tag?.sortOrder ?? 99
        }
        // Gesture intents on the same id coalesce to the NET target
        // (ADR-IOS-057) — see `toggleRead`'s doc comment.
        manager.registerGestureIntent(id: messageId, .actionTag(target: tag, baseline: snapshot.actionTag))
        rebuildDisplayGroups()
    }

    func removeUserLabel(_ label: UserLabel, from snapshot: MessageSnapshot) async {
        // Look up full MessageHeader from DB for correct folderPath
        guard let message = lookupMessage(snapshot.id) else { return }
        guard isAdmissibleDurableMessageAction(message) else { return }
        // Persist + queue
        do {
            let persisted = try await AccountManager.shared.retryGatedQueueWrite(
                AppDatabase.dbPool, label: "removeUserLabel", maxAttempts: 1
            ) { db -> Bool in
                guard let current = try MessageHeader.fetchOne(db, key: message.id),
                      let account = try Account.fetchOne(db, key: current.accountId),
                      account.provider.supportsRemoteUserLabels,
                      let address = MessageIdentity.durableActionAddress(
                          accountId: current.accountId,
                          folderPath: current.folderPath,
                          rfc822MessageId: current.rfc822MessageId,
                          providerMessageId: current.messageId
                      ),
                      label.accountId == address.accountId,
                      let op = PendingOperation.durableMessageAction(
                          type: .removeUserLabel,
                          messageIds: [address.memberIdentity],
                          accountId: address.accountId,
                          folderPath: address.folderPath,
                          userLabelId: label.id
                      )
                else { return false }
                try MessageUserLabel
                    .filter(Column("messageId") == snapshot.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                try op.insert(db)
                return true
            }
            guard persisted else { return }
            if let idx = loadedMessages.firstIndex(where: { $0.id == snapshot.id }) {
                loadedMessages[idx].userLabels.removeAll { $0.id == label.id }
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
        } catch {
            print("[InboxViewModel] removeUserLabel failed: \(error)")
        }
    }

    /// Returns false when nothing was recorded (lookup miss) — callers MUST
    /// NOT hide the row when this returns false. See `archive(_:)`'s doc
    /// comment for the full contract.
    @discardableResult
    func move(_ messageId: String, toFolderPath: String) -> Bool {
        guard !toFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let message = lookupMessage(messageId) else {
            print("[MoveTrace] ViewModel.move — lookupMessage FAILED for id=\(messageId)")
            return false
        }
        guard isAdmissibleDurableMessageAction(message) else { return false }
        print("[MoveTrace] ViewModel.move — msgId=\(message.messageId) from=\(message.folderPath) to=\(toFolderPath) folderId=\(message.folderId) headerDbId=\(message.id)")
        let destFolderId = "\(message.accountId):\(toFolderPath)"
        // Generic move: unlike archive/delete, the destination CAN be the
        // inbox (e.g. moving out of Spam) — check the dest folder's role,
        // not just the source's isInInbox (F6). record() (ADR-IOS-058)
        // replaces retain+registerMutation+enqueueWrite.
        let destRole = lookupFolderRole(destFolderId)
        let destIsInbox = destRole == .inbox
        // Undo command built directly from the pre-move header (ADR-IOS-060).
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: [message],
                forwardDestinationByAccount: [message.accountId: toFolderPath]
            )
        ))
        manager.record(
            ids: [messageId],
            kind: .move(.folder(folderId: destFolderId, folderPath: toFolderPath, isInbox: destIsInbox)),
            displays: [messageId: .init(folderId: destFolderId, actionTag: (message.isInInbox && !destIsInbox) ? .some(nil) : nil)],
            origin: .gesture
        )
        return true
    }

    /// Move every member of a thread to `toFolderPath` as one grouped action.
    /// Pushes a single UndoableAction carrying all members so the whole thread
    /// restores in one undo — mirrors archiveThread/deleteThread.
    ///
    /// Returns the ids of `messageIds` that were NOT acted upon (unresolved,
    /// or a foreign-account member skipped below) — see `archiveThread`'s doc
    /// comment for the un-hide contract this satisfies.
    @discardableResult
    func moveThread(_ messageIds: [String], toFolderPath: String) -> [String] {
        guard !toFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return messageIds }
        let allMessages = messageIds
            .compactMap { lookupMessage($0) }
            .filter(isAdmissibleDurableMessageAction)
        guard let first = allMessages.first else {
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] ViewModel.moveThread — no messages resolved for ids=\(messageIds)")
            }
            return messageIds
        }
        // moveThread's destination is a single explicit folder path
        // belonging to ONE account (the folder picker is per-account) —
        // unlike archive/delete's role-based destination, there is no
        // "this account's own equivalent folder" to resolve for a member of
        // a DIFFERENT account, and a cross-account IMAP move is impossible
        // (UIDs/folders are account-scoped). Silently stamping another
        // account's folder path onto a foreign-account message (the
        // pre-fix behavior) left that row with an optimistic folderId no
        // real folder backs for its account and a PendingOperation whose
        // destinationPath is meaningless to that provider — strictly worse
        // than skipping. Scope the gesture to `first`'s account; skip the rest.
        let messages = allMessages.filter { $0.accountId == first.accountId }
        let skippedCount = allMessages.count - messages.count
        if skippedCount > 0, DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] ViewModel.moveThread — skipping \(skippedCount) message(s) from other accounts; moveThread's destination is single-account")
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] ViewModel.moveThread — count=\(messages.count) from=\(first.folderPath) to=\(toFolderPath)")
        }
        let destFolderId = "\(first.accountId):\(toFolderPath)"
        // Generic move: destination CAN be the inbox — check the dest
        // folder's role once (same dest for every member), then combine with
        // each member's own isInInbox (F6). ONE record covers every member.
        let destRole = lookupFolderRole(destFolderId)
        let destIsInbox = destRole == .inbox
        // Undo command built directly from the pre-move headers (ADR-IOS-060).
        UndoService.shared.push(UndoableAction(
            commands: UndoableAction.commands(
                for: messages,
                forwardDestinationByAccount: [first.accountId: toFolderPath]
            )
        ))
        var displays: [String: AccountManager.PendingMutation] = [:]
        for msg in messages {
            displays[msg.id] = .init(folderId: destFolderId, actionTag: (msg.isInInbox && !destIsInbox) ? .some(nil) : nil)
        }
        manager.record(
            ids: messages.map(\.id),
            kind: .move(.folder(folderId: destFolderId, folderPath: toFolderPath, isInbox: destIsInbox)),
            displays: displays,
            origin: .gesture
        )
        let actedUpon = Set(messages.map(\.id))
        return messageIds.filter { !actedUpon.contains($0) }
    }

    /// Check if inbox qualifies as "large" (100+ messages with some older than 2 weeks).
    /// Updates TipKit parameter and UserDefaults flag (read by sidebar badge + settings).
    func checkLargeInbox() async {
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: Date()) ?? Date()
        let folderIds = Set(folders.map(\.id))

        // Run both COUNT(*)s OFF the main actor (async dbPool.read overload). They are
        // folderId-index-assisted (the `date <` one rides messageHeader_folderId_date),
        // but on a large All Mail account even an index COUNT is non-trivial — doing it
        // through the SYNC dbPool.read on @MainActor blocked the UI on EVERY inbox
        // onAppear (tab switch / nav-back / foreground). Result only feeds a TipKit flag
        // + UserDefaults, so computing it slightly later off-main is strictly better.
        guard let (totalCount, oldCount) = try? await dbPool.read({ db -> (Int, Int) in
            let total = try MessageHeader
                .filter(folderIds.contains(Column("folderId")))
                .fetchCount(db)
            let old = try MessageHeader
                .filter(folderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }) else { return }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        ArchiveOldEmailsTip.isLargeInbox = isLarge
        UserDefaults.standard.set(isLarge, forKey: "isLargeInbox")
    }

    // MARK: - Thread Grouping

    /// Toggle expansion state for a thread group.
    func toggleThreadExpansion(_ groupId: String) {
        if expandedThreads.contains(groupId) {
            expandedThreads.remove(groupId)
        } else {
            expandedThreads.insert(groupId)
        }
        // No rebuildDisplayGroups() needed — expandedThreads is observed by SwiftUI
        // and the view reads it directly to show/hide children.
    }

    /// Remove a message from the loaded list, collapse its thread, and rebuild groups.
    /// Used when archiving/deleting the thread head while expanded — children need to
    /// appear as their own group(s) in the correct sorted position immediately.
    func evictAndRebuild(_ messageId: String, collapseThread groupId: String) {
        expandedThreads.remove(groupId)
        loadedMessages.removeAll { $0.id == messageId }
        loadedIds.remove(messageId)
        rebuildDisplayGroups()
    }

    /// Rebuild displayGroups from loadedMessages using real thread relationships.
    /// Groups by native threadId (Gmail/Exchange) + RFC header chain (inReplyTo/rfc822MessageId).
    /// No subject-based fallback — messages without real thread links are standalone.
    /// Called whenever loadedMessages changes. Dismiss filtering is done at the view level.
    ///
    /// Uses in-place diffing: updates existing groups, removes stale ones, inserts new ones
    /// at the correct sorted position. SwiftUI sees incremental changes by stable group ID,
    /// preserving scroll position instead of re-laying out the entire List.
    func rebuildDisplayGroups() {
        let tStart = CFAbsoluteTimeGetCurrent()
        let prevMsgCount = loadedMessages.count
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
            if ms >= 50 {
                BackgroundSyncLogger.logInbox("[\(instanceTag)] rebuildDisplayGroups \(ms)ms messages=\(prevMsgCount) groups=\(displayGroups.count)")
            }
        }
        let newGroups = ThreadGroupBuilder.buildDisplayGroups(from: loadedMessages, mode: mode)

        // Prune stale expansion state. Removal pathways that don't go through
        // evictAndRebuild (child-row swipe, detail-view archive/delete, agent
        // tools, sync from another device) can shrink an expanded thread to a
        // single message or remove it entirely. A leftover id keeps painting
        // the expanded-thread row background (looks like a stuck selection
        // highlight) + hidden separators on the remaining row, and the chevron
        // can no longer clear it — MessageRowView only renders the toggle for
        // isThread rows. Prune here so every pathway self-heals on rebuild.
        if !expandedThreads.isEmpty {
            let threadIds = Set(newGroups.lazy.filter(\.isThread).map(\.id))
            let pruned = expandedThreads.intersection(threadIds)
            if pruned.count != expandedThreads.count {
                expandedThreads = pruned
            }
        }

        // Fast path: first build or empty — just assign
        guard !displayGroups.isEmpty else {
            displayGroups = newGroups
            return
        }

        // Build lookup of new groups by ID
        let newById: [String: ThreadGroup] = {
            var dict: [String: ThreadGroup] = [:]
            dict.reserveCapacity(newGroups.count)
            for g in newGroups { dict[g.id] = g }
            return dict
        }()

        // Pass 1: Remove groups that no longer exist, update changed ones
        var survivingIds: Set<String> = []
        var indicesToRemove: [Int] = []
        for (i, existing) in displayGroups.enumerated() {
            if let updated = newById[existing.id] {
                if existing != updated {
                    displayGroups[i] = updated
                }
                survivingIds.insert(existing.id)
            } else {
                indicesToRemove.append(i)
            }
        }
        for i in indicesToRemove.reversed() {
            displayGroups.remove(at: i)
        }

        // Pass 2: Insert new groups at correct sorted position.
        // Comparator is mode-aware (date-desc in normal, tagSortOrder-asc+date-desc in triage)
        // so a reply-tagged thread can land at the top in triage view even with an old date.
        for newGroup in newGroups where !survivingIds.contains(newGroup.id) {
            let insertAt = displayGroups.firstIndex { existing in
                ThreadGroupBuilder.areInIncreasingOrder(newGroup, existing, mode: mode)
            } ?? displayGroups.endIndex
            displayGroups.insert(newGroup, at: insertAt)
        }

        // Pass 3: Fix sort order — an updated group's representative date OR threadTag
        // may have changed (e.g., thread head evicted; user added reply tag; AI assigned tag).
        // Only sort when needed. Same comparator as Pass 2.
        if displayGroups.count > 1 {
            var needsSort = false
            for i in 1..<displayGroups.count {
                if !ThreadGroupBuilder.areInIncreasingOrder(displayGroups[i - 1], displayGroups[i], mode: mode) {
                    needsSort = true
                    break
                }
            }
            if needsSort {
                displayGroups.sort { ThreadGroupBuilder.areInIncreasingOrder($0, $1, mode: mode) }
            }
        }
    }

}

/// Thin `ObservableObject` wrapper around `@Observable InboxViewModel` so
/// that `InboxView` can use `@StateObject` for proper lazy-one-time init.
///
/// Why: plain `@State private var viewModel: InboxViewModel` eagerly evaluates
/// `InboxViewModel(...)` on every parent re-render (State's init signature is
/// NOT `@autoclosure`), spawning "phantom" VMs that SwiftUI then discards.
/// During rapid NavigationSplitView navigation this creates overlapping VM
/// lifetimes and causes the split-view state machine to get stuck.
/// `@StateObject.init(wrappedValue:)` IS `@autoclosure @escaping` — the VM
/// is constructed exactly once per view lifetime. The inner `@Observable`
/// still drives fine-grained UI updates via the new Observation framework;
/// the outer `ObservableObject` is deliberately empty.
///
/// Ref: Swift Forums thread #70811 — "@Observable init() called multiple
/// times by @State, different behavior to @StateObject" — community-
/// endorsed workaround (`@trochoid`).
@MainActor
final class InboxViewModelHolder: ObservableObject {
    let vm: InboxViewModel

    init(folders: [Folder], selection: MailboxSelection) {
        self.vm = InboxViewModel(folders: folders, selection: selection)
    }
}
