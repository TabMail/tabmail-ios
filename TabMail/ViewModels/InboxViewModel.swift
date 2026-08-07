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
    #if DEBUG
    /// Test-only interleaving seam: fires after `markAllAsRead` captures a
    /// durable page and advances its cursor, but BEFORE that page enters
    /// `AccountManager.markRead`.
    ///
    /// REFERENCE (`v2final`): PORTED verbatim in name, type and placement from
    /// `InboxViewModel.markAllAsReadWillAdmitBatchForTesting` at the tag.
    ///
    /// It is load-bearing for T4.V20-A, not a convenience. `markAllAsRead`'s
    /// page loop is otherwise **unassertable from a unit test**: the only
    /// externally visible artefacts of a pass are the `messageHeader.isRead`
    /// rows and the `PendingOperation` rows it produces, and the failure mode
    /// this seam exists to pin — a page that is read, handed to `markRead`, and
    /// comes back with `isRead` still `0` — produces *no* new artefact at all.
    /// A test can therefore not distinguish "the loop terminated after N pages"
    /// from "the loop is still spinning on page 1" by looking at the database;
    /// it can only distinguish them by counting admissions, which is what this
    /// hook makes possible (and lets the test fail fast on a bound instead of
    /// hanging the suite waiting for a loop that never ends).
    ///
    /// Placed AFTER the cursor advance on purpose: a hook that observed the
    /// page before `lastVisitedID` moved could not tell a re-read of the same
    /// page from progress.
    nonisolated static let markAllAsReadWillAdmitBatchForTesting = Mutex<
        (@Sendable ([MessageHeader]) async -> Void)?
    >(nil)
    #endif

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
        // BootProfile anchor (2026-08-06). The `[InboxLog]` lines around inbox
        // appearance carry NO timestamp, so on a cold boot this milestone — the
        // tail of `InboxView.onAppear`, which lands inside the ~1320ms
        // main-thread block that follows first paint — had nothing in the
        // BootProfile timeline to place it against, leaving ~606ms of that
        // block unattributable. Marked HERE rather than in the view's
        // `.onAppear` closure because that closure is already at the Swift
        // type-checker's expression budget: one more statement in it fails the
        // build with "unable to type-check this expression in reasonable time".
        BootProfiler.mark("InboxViewModel.listDidAppear — @MainActor, tail of InboxView.onAppear (loaded=\(loadedMessages.count) folders=\(folders.count))")
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

    /// Undo snapshots must capture the VISUALIZED state (act-on-visualized-state
    /// rule): a queued intent cycle's isRead/isFlagged/actionTag exist only in the
    /// overlay until the FIFO drains, and a DB-fresh row predates them — an undo
    /// restoring that row would silently revert the user's most recent gesture.
    /// Folder fields are deliberately NOT taken from the overlay (a pending move's
    /// dest must not leak into a snapshot that records the pre-move location).
    ///
    /// MUST be called BEFORE the call site's own `retainOverlayEntry`/
    /// `registerMutation` — those calls write THIS action's own overlay mutation
    /// (e.g. the F6 tag-clear on inbox exit), and `registerMutation` merges into
    /// the SAME coalesced entry this reads. Calling it after would capture this
    /// action's own not-yet-committed mutation as if it were pre-existing state.
    private func overlayAdjustedForUndo(_ header: MessageHeader) -> MessageHeader {
        manager.overlayAdjustedSnapshot(header)
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
                if let v = mutation.actionTag { snapshot.actionTag = v }
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
            if let overlayFolderId = overlay[id]?.folderId {
                header.folderId = overlayFolderId
            }
            if let overlayFolderPath = overlay[id]?.folderPath {
                header.folderPath = overlayFolderPath
            }
            if let overlayIsInInbox = overlay[id]?.isInInbox {
                header.isInInbox = overlayIsInInbox
            }
            if let overlayIsRead = overlay[id]?.isRead {
                header.isRead = overlayIsRead
            }
            // Only insert if the message belongs to a currently displayed folder
            guard folderIds.contains(header.folderId) else { continue }
            // Respect unread filter
            if filterUnread && header.isRead { continue }
            let labels = labelsByMessage[id] ?? []
            // Respect label filter — mirrors InboxListComposer step 6 (compose
            // applies the label filter uniformly to D/P/S); this path just
            // loaded real labels above so it can match the reader exactly.
            if !filterLabelIds.isEmpty && !filterLabelIds.isSubset(of: Set(labels.map(\.id))) { continue }
            let snapshot = MessageSnapshot(from: header, userLabels: labels)
            // Insert at the slot the READER would have put this row in — the one
            // shared ordering key (`InboxOrdering`, R13), not a local restatement
            // of it. Before this, the triage arm compared `(tagSortOrder, date)`
            // and the normal arm compared `date` alone, with no `id` tie-break at
            // either, so an undone row tied on the boundary landed at the END of
            // its tie block while every other spelling of the order placed it by
            // `id`. See `InboxOrdering` for why that reaches pagination.
            let insertionIndex = loadedMessages.firstIndex {
                InboxOrdering.areInIncreasingOrder(snapshot, $0, mode: mode)
            } ?? loadedMessages.endIndex
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
                if let v = m.actionTag { header.actionTag = v }
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
            // The one shared ordering key (`InboxOrdering`, R13). The slot picked
            // here must be the slot the DURABLE read picks once the merge lands,
            // or the row visibly jumps on the next reload — and until then the
            // array is out of the reader's order with `loadMoreMessages`' cursor
            // read off its tail.
            let insertionIndex = loadedMessages.firstIndex {
                InboxOrdering.areInIncreasingOrder(snapshot, $0, mode: mode)
            } ?? loadedMessages.endIndex
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

            // Pass 2: Insert new messages at the slot the reader put them in.
            // `freshMessages` arrives from `InboxListReader` already in the total
            // order; this diff must reproduce that order in-place, so it uses the
            // SAME comparator the reader's step-7 sort does (`InboxOrdering`,
            // R13) rather than a fourth restatement of the key.
            for fresh in freshMessages where !survivingIds.contains(fresh.id) {
                let insertAt = loadedMessages.firstIndex {
                    InboxOrdering.areInIncreasingOrder(fresh, $0, mode: mode)
                } ?? loadedMessages.endIndex
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
            mode: mode,
            targetCount: targetWindowSize,
            before: nil,
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
        // 🚨 THE CURSOR IS THE FULL ORDERING KEY OF THE LAST ROW, NOT ITS DATE
        // (R12-T3). `loadedMessages.last?.date` alone skipped every row tied on
        // the boundary second in `.normal` mode, and every row in a later tag
        // bucket in `.triage` mode (whose order is not date-monotonic). Both
        // were permanent: a later page never asks for them and a refresh
        // rebuilds the same initial window. See `InboxPageCursor`.
        // `loadedMessages.last` stays the deepest row across eviction —
        // `scheduleEvictionIfNeeded` trims with `removeFirst`, never the tail.
        //
        // 🚨 THE CURSOR IS THE ARRAY'S MAXIMUM UNDER THE ORDER, NOT ITS LAST
        // ELEMENT (R13-U14). Those coincide only while `loadedMessages` is
        // sorted, and it is sorted when BUILT but does not stay that way:
        // `tagSortOrder` is not immutable for a loaded row (the AI queue, delta
        // and full sync, and manual tagging all change it) and `reloadMessages`
        // Pass 1 writes a fresh row into the STALE row's index without
        // repositioning it. `rg 'loadedMessages\.sort'` → no matches; nothing
        // re-sorts it. In `.triage` a loaded row re-tagged into a later bucket
        // then sorts AFTER `.last`, is re-admitted by the SQL keyset predicate,
        // burns a `LIMIT` slot, and is dropped by `excludeIds` only after the
        // limit — enough of them and the page comes back short and
        // `hasMoreMessages` flips false.
        //
        // Shipped read only `date`, which a row's lifetime never changes, so
        // its Pass-1-in-place was harmless to the cursor; `3b31fdb4d` put a
        // MUTABLE field into the key without giving Pass 1 a reposition.
        //
        // ⚠️ THE FIX IS HERE AND NOT IN PASS 1 ON PURPOSE. Repositioning rows
        // during a reload is exactly what `reloadMessages`' Pass 1 guard above
        // defends against — it writes in place and skips the assignment
        // entirely when nothing changed, precisely to avoid the `@Observable`
        // churn that shifts layout and jumps the scroll position. Taking the
        // maximum costs one O(n) pass over an
        // already-bounded window and changes no render behaviour.
        //
        // `.normal` is unaffected either way — neither its comparator nor its
        // SQL predicate reads `tagSortOrder` — but the cursor is taken this way
        // in both modes so there is one rule, not a mode-conditional one.
        let deepest = loadedMessages.max { a, b in
            InboxOrdering.areInIncreasingOrder(a, b, mode: mode)
        }
        let cursor = deepest.map(InboxPageCursor.init(row:))

        // Phase 1: try local data first
        let nextPage = fetchPage(before: cursor)

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
                let pull = try await manager.fetchOlderMessages(folders: folders)
                if pull.inserted > 0 {
                    // Network fetch added messages to GRDB; now load them locally
                    let freshPage = fetchPage(before: cursor)
                    for msg in freshPage { loadedIds.insert(msg.id) }
                    loadedMessages.append(contentsOf: freshPage)
                    targetWindowSize += SyncConfig.inboxPageSize
                    rebuildDisplayGroups()
                    scheduleEvictionIfNeeded()
                }
                // 🚨 EXHAUSTION IS A STATEMENT ABOUT SERVER COVERAGE, NEVER ABOUT
                // HOW MANY ROWS WE MATERIALISED. Both signals this used to read —
                // `newCount == 0` and `freshPage.count >= inboxPageSize` — count
                // ROWS WE INSERTED, and a record the server reports `\Deleted`
                // occupies a slot in the page and is deliberately never inserted
                // (IOS-IMAP-001 / D3). One such record in a full page made the page
                // look short, flipped this false, and left every older message in
                // the folder unreachable by scrolling. The pull itself now reports
                // what the SERVER covered; see `SyncEngine.fetchOlderMessages` for
                // the coverage-AND-progress rule that also guarantees termination.
                hasMoreMessages = pull.mayHaveMore
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
    private func fetchPage(before: InboxPageCursor?) -> [MessageSnapshot] {
        let pageSize = SyncConfig.inboxPageSize
        let tStart = CFAbsoluteTimeGetCurrent()

        let query = InboxListQuery(
            displayedFolderIds: Set(folders.map(\.id)),
            filterUnread: filterUnread,
            filterLabelIds: filterLabelIds,
            mode: mode,
            targetCount: pageSize,
            before: before,
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
            if let body = try? await SearchIndex.shared.bodyText(
                contentKey: ContentKey(rawValue: headerId)) {
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
        return message.folderPath == trashPath
    }

    /// FU-1 (no-op-elimination half): the members an ARCHIVE thread-gesture
    /// should act on and HIDE — the members that are NOT a per-member archive
    /// no-op. A thread can span folders of different roles; deciding the whole
    /// thread from the REPRESENTATIVE drops the intention of every member that
    /// lives in a different role folder. An archive-resident member is a SETTLED
    /// no-op — nothing happens to it, so it stays VISIBLE and is excluded here;
    /// only the genuinely-actionable members are hidden and passed to
    /// `archiveThread`. Order-preserving. Extracted so the View is both correct
    /// AND unit-testable.
    func actionableArchiveIds(_ messageIds: [String]) -> [String] {
        messageIds.filter { !archiveIsNoOp($0) }
    }

    /// FU-1 (no-op-elimination half): the members a DELETE thread-gesture should
    /// act on and HIDE. See `actionableArchiveIds` for the full rationale — a
    /// trash-resident member stays VISIBLE and is excluded here.
    /// Order-preserving.
    func actionableDeleteIds(_ messageIds: [String]) -> [String] {
        messageIds.filter { !deleteIsNoOp($0) }
    }

    /// Returns false when nothing was recorded (lookup miss, no archive folder
    /// for the account, or already-at-destination no-op) — callers (InboxView's
    /// single-message dismiss/swipe sites) MUST NOT leave the row hidden when
    /// this returns false, or it vanishes forever with no undo entry (same
    /// defect class `archiveThread`'s skipped-ids contract guards against).
    @discardableResult
    func archive(_ messageId: String) -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp.
        guard lookupFolderRole(message.folderId) != .archive else { return false }
        guard let archivePath = lookupFolderPath(accountId: message.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(message.accountId)")
            return false
        }
        guard message.folderPath != archivePath else { return false }
        let destFolderId = "\(message.accountId):\(archivePath)"
        // Capture the undo snapshot BEFORE this action's own retain/
        // registerMutation below — see overlayAdjustedForUndo's doc comment.
        let undoSnapshot = overlayAdjustedForUndo(message)
        manager.retainOverlayEntry(id: messageId)
        // Archive's destination is never the inbox (guarded above), so
        // `message.isInInbox` alone determines "leaving the inbox" — clear
        // the tag in the overlay (F6) so the mid-drain window doesn't flash
        // the stale tag in the destination folder's row.
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId, actionTag: message.isInInbox ? .some(nil) : nil))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: archivePath), messages: [undoSnapshot],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: archivePath)
            manager.releaseOverlayEntry(id: messageId)
        }}
        return true
    }

    /// Returns the ids of `messageIds` that were NOT acted upon (nothing
    /// resolved for them, or the whole call aborted) — the caller (InboxView)
    /// optimistically hides the actionable members (`actionableArchiveIds`)
    /// BEFORE calling this, so it MUST un-hide exactly the ids returned here or
    /// those rows vanish forever with no undo entry.
    @discardableResult
    func archiveThread(_ messageIds: [String]) -> [String] {
        let messages = messageIds.compactMap { lookupMessage($0) }
        // Nothing resolved — every id reported skipped so the caller un-hides.
        guard let first = messages.first else { return messageIds }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp. Reached only if the
        // caller's own `actionableArchiveIds` filter raced a concurrent move;
        // nothing is recorded, so every id is reported skipped (un-hide).
        guard lookupFolderRole(first.folderId) != .archive else { return messageIds }
        guard let archivePath = lookupFolderPath(accountId: first.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(first.accountId)")
            return messageIds
        }
        guard first.folderPath != archivePath else { return messageIds }
        let destFolderId = "\(first.accountId):\(archivePath)"
        let compositeIds = messages.map(\.id)
        // Capture undo snapshots BEFORE the retain/registerMutation loop
        // below — see overlayAdjustedForUndo's doc comment.
        let undoMessages = messages.map { overlayAdjustedForUndo($0) }
        // Archive's destination is never the inbox (guarded above), so each
        // member's own `isInInbox` determines "leaving the inbox" (F6) — a
        // thread can mix members already outside the inbox with ones still
        // in it.
        for msg in messages {
            manager.retainOverlayEntry(id: msg.id)
            manager.registerMutation(id: msg.id, mutation: .init(folderId: destFolderId, actionTag: msg.isInInbox ? .some(nil) : nil))
        }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: archivePath), messages: undoMessages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: archivePath)
            for id in compositeIds { manager.releaseOverlayEntry(id: id) }
        }}
        // Members that never resolved were never acted upon — report them
        // skipped so the caller un-hides exactly those rows.
        let recorded = Set(compositeIds)
        return messageIds.filter { !recorded.contains($0) }
    }

    /// Returns false when nothing was recorded (lookup miss, no trash folder for
    /// the account, or already-at-destination no-op) — callers MUST NOT leave
    /// the row hidden when this returns false. See `archive(_:)`'s doc comment
    /// for the full contract; a Drafts-folder member propagates the
    /// draft-specific path's own success.
    @discardableResult
    func delete(_ messageId: String) async -> Bool {
        guard let message = lookupMessage(messageId) else { return false }
        // Drafts folder: use draft-specific deletion (DELETE /drafts or STORE+EXPUNGE)
        // instead of move-to-trash, which doesn't work for Gmail drafts.
        let folderRole = lookupFolderRole(message.folderId)
        if folderRole == .drafts {
            // The draft-specific path fails CLOSED (unresolvable identity,
            // failed durable write). Propagate its outcome so the caller
            // un-hides the row instead of leaving the draft vanished while the
            // server copy survives.
            return await deleteDraftMessage(message)
        }
        AccountManager.logDeleteTrace(accountId: message.accountId, messages: [message], callSite: "InboxViewModel.delete")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp.
        if folderRole == .trash { return false }
        guard let trashPath = lookupFolderPath(accountId: message.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(message.accountId)")
            return false
        }
        guard message.folderPath != trashPath else { return false }
        let destFolderId = "\(message.accountId):\(trashPath)"
        // Capture the undo snapshot BEFORE this action's own retain/
        // registerMutation below — see overlayAdjustedForUndo's doc comment.
        let undoSnapshot = overlayAdjustedForUndo(message)
        manager.retainOverlayEntry(id: messageId)
        // Delete's destination is never the inbox (guarded above), so
        // `message.isInInbox` alone determines "leaving the inbox" (F6).
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId, actionTag: message.isInInbox ? .some(nil) : nil))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: trashPath), messages: [undoSnapshot],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: trashPath)
            manager.releaseOverlayEntry(id: messageId)
        }}
        return true
    }

    /// Returns the ids of `messageIds` that were NOT acted upon — see
    /// `archiveThread`'s doc comment for the un-hide contract this satisfies.
    @discardableResult
    func deleteThread(_ messageIds: [String]) async -> [String] {
        let messages = messageIds.compactMap { lookupMessage($0) }
        // Nothing resolved — every id reported skipped so the caller un-hides.
        guard let first = messages.first else { return messageIds }
        // Drafts folder: delete each draft individually
        let folderRole = lookupFolderRole(first.folderId)
        if folderRole == .drafts {
            // A draft whose provider-addressed cleanup fails closed is reported
            // SKIPPED (row un-hides), never vanished with the server copy intact.
            var settled = Set<String>()
            for message in messages {
                if await deleteDraftMessage(message) { settled.insert(message.id) }
            }
            return messageIds.filter { !settled.contains($0) }
        }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "InboxViewModel.deleteThread")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp. Reached only if the
        // caller's own `actionableDeleteIds` filter raced a concurrent move;
        // nothing is recorded, so every id is reported skipped (un-hide).
        if folderRole == .trash { return messageIds }
        guard let trashPath = lookupFolderPath(accountId: first.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(first.accountId)")
            return messageIds
        }
        guard first.folderPath != trashPath else { return messageIds }
        let destFolderId = "\(first.accountId):\(trashPath)"
        let compositeIds = messages.map(\.id)
        // Capture undo snapshots BEFORE the retain/registerMutation loop
        // below — see overlayAdjustedForUndo's doc comment.
        let undoMessages = messages.map { overlayAdjustedForUndo($0) }
        // Delete's destination is never the inbox (guarded above), so each
        // member's own `isInInbox` determines "leaving the inbox" (F6).
        for msg in messages {
            manager.retainOverlayEntry(id: msg.id)
            manager.registerMutation(id: msg.id, mutation: .init(folderId: destFolderId, actionTag: msg.isInInbox ? .some(nil) : nil))
        }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: trashPath), messages: undoMessages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: trashPath)
            for id in compositeIds { manager.releaseOverlayEntry(id: id) }
        }}
        // Members that never resolved were never acted upon — report them
        // skipped so the caller un-hides exactly those rows.
        let recorded = Set(compositeIds)
        return messageIds.filter { !recorded.contains($0) }
    }

    /// Delete a draft message from the Drafts folder using the draft-specific deletion path.
    /// Provider-native identities only. An actual IMAP header has no source-bound
    /// UIDVALIDITY and therefore fails closed; the next sync preserves truth.
    ///
    /// Returns whether the draft was actually acted upon. `false` (fail-closed /
    /// failed durable write) means the caller MUST NOT leave the row hidden — it
    /// stays visible while the server copy is untouched.
    @discardableResult
    private func deleteDraftMessage(_ message: MessageHeader) async -> Bool {
        let drafts: [Draft]
        do {
            drafts = try await dbPool.read { db in
                try Draft
                    .filter(Column("accountId") == message.accountId)
                    .fetchAll(db)
            }
        } catch {
            return false
        }

        let placeholderMatches = drafts.filter {
            PendingOperation.draftPlaceholderMessageId(
                draftId: $0.id, instanceEpoch: $0.instanceEpoch) == message.messageId
        }
        if placeholderMatches.count == 1, let owned = placeholderMatches.first {
            guard let epoch = owned.instanceEpoch, !epoch.isEmpty else { return false }
            if owned.serverDraftId == nil {
                do {
                    // `deleted` is carried separately from `dir` because
                    // `attachmentsDirName` is itself optional — a nil dir on a
                    // SUCCESSFUL delete must not read as "nothing happened".
                    let outcome = try await dbPool.write { db -> (deleted: Bool, dir: String?) in
                        guard let fresh = try Draft.fetchOne(db, key: owned.id),
                              fresh.instanceEpoch == epoch else { return (false, nil) }
                        _ = try MessageHeader.deleteOne(db, key: message.id)
                        _ = try MessageBody.deleteOne(
                            db, key: ContentKey(rawValue: message.id))
                        try DraftStore.applyDelete(
                            id: owned.id,
                            expectedInstanceEpoch: epoch,
                            db: db)
                        return (true, fresh.attachmentsDirName)
                    }
                    guard outcome.deleted else { return false }
                    if let dir = outcome.dir { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
                    NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
                    return true
                } catch { return false }
            }
            guard let serverId = owned.serverDraftId,
                  let runtimeKind = await manager.draftRuntimeIdentityKind(
                    accountId: owned.accountId) else { return false }
            let identity: DraftDeleteIdentity
            switch runtimeKind {
            case .gmail:
                identity = .gmail(resourceId: serverId)
            case .outlook:
                identity = .outlook(graphId: serverId)
            case .demo:
                identity = .demo(localId: serverId)
            case .imap:
                guard let folder = owned.serverDraftFolderPath,
                      let uidValidity = owned.serverDraftUidValidity,
                      let uid = Int(serverId), uid > 0 else { return false }
                identity = .imap(
                    folder: folder, uidValidity: uidValidity, uid: uid)
            case .unknown:
                return false
            }
            return await manager.queueDraftDelete(
                identity: identity,
                accountId: owned.accountId,
                folderPath: owned.serverDraftFolderPath,
                draftId: owned.id,
                instanceEpoch: epoch,
                deleteOwnedLocalDraft: true)
        }

        guard let runtimeKind = await manager.draftRuntimeIdentityKind(
            accountId: message.accountId) else { return false }
        let identity: DraftDeleteIdentity
        switch runtimeKind {
        case .gmail:
            // PORT — `v2final:TabMail/Views/Compose/ComposeView.swift`
            // `ServerDraftOpen.inboxDraftDeletePlan(...)`, its FIRST branch
            // (`isSyntheticPlaceholderId(headerProviderMessageId) ⇒ failClosed`).
            //
            // A `draft-…` id is LOCAL bookkeeping written into
            // `messageHeader.messageId` by `AccountManager.queueDraftSave` so the row
            // shows up in Drafts before the server has assigned anything. It is not a
            // Gmail address in any namespace. It reaches this arm because
            // `placeholderMatches` above resolves a placeholder only against the
            // draft's CURRENT `instanceEpoch`, while `queueDraftSave` keys the header
            // on the epoch live at save time and never removes the previous epoch's
            // row — so a reopened draft leaves a stale-epoch placeholder that matches
            // nothing. (`DraftStore.applyPushCompletion` likewise leaves the
            // placeholder unmigrated when Gmail returns no contained MESSAGE id.)
            //
            // Handing it to Gmail addresses NOTHING and is not merely wasted work:
            // `GmailProvider.trashContainedDraftMessage` reads the resulting 404 as
            // idempotent success, so the op RETIRES, the local header is already gone,
            // and the real server draft — addressed by `Draft.serverDraftId`, which
            // this arm never consulted — survives and re-syncs. The user is told a
            // destructive action landed on a draft that was never touched.
            //
            // FAIL CLOSED. `false` reports this id SKIPPED to `delete`/`deleteThread`,
            // which un-hide the row: nothing is deleted anywhere and the gesture stays
            // RETRYABLE. An unknown provider address is an ABSENCE of evidence, never
            // a licence to substitute a local id.
            guard !isSyntheticPlaceholderId(message.messageId) else { return false }
            identity = .gmailContainedMessage(messageId: message.messageId)
        case .outlook:
            // Same refusal, same reference: `inboxDraftDeletePlan`'s Outlook branch
            // admits only `exactProviderIdentifier(headerProviderMessageId)`, which
            // rejects synthetic placeholder ids. `ExchangeProvider.deleteDraft` also
            // treats 404 as success, so an unaddressable id retires identically.
            guard !isSyntheticPlaceholderId(message.messageId) else { return false }
            identity = .outlook(graphId: message.messageId)
        case .demo:
            identity = .demo(localId: message.messageId)
        case .imap, .unknown:
            return false
        }

        let nativeMatches = drafts.filter { draft in
            switch runtimeKind {
            case .gmail:
                // SUBTRACT — no persisted contained-MESSAGE carrier on Draft.
                // The exact contained address still authorizes the provider
                // delete, but local ownership remains unproven and is preserved.
                return false
            case .outlook, .demo:
                return draft.serverDraftId == message.messageId
            case .imap, .unknown:
                return false
            }
        }
        let owned = nativeMatches.count == 1 ? nativeMatches.first : nil
        return await manager.queueDraftDelete(
            identity: identity,
            accountId: message.accountId,
            folderPath: message.folderPath,
            draftId: owned?.id,
            instanceEpoch: owned?.instanceEpoch,
            deleteOwnedLocalDraft: owned != nil)
    }

    /// Current state comes from the ON-SCREEN snapshot — the visualized state
    /// the user is acting on — never a DB read. `lookupMessage` is a
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

    /// Batched set-read. Filters to currently-unread members, then applies the
    /// optimistic-UI + overlay + write pipeline once for the whole group.
    /// Use for thread-level actions (tag-tap archive/delete/reply).
    ///
    /// Current-read-state is derived from the ON-SCREEN snapshot where
    /// available (act-on-visualized-state, mirrors `toggleRead`) — never a
    /// gesture-path DB read. Thread-member ids passed in here can be stale
    /// relative to the CURRENT `loadedMessages`: callers capture a `ThreadGroup`
    /// value at render time (`InboxView.executeTaggedAction` /
    /// `dismissAndArchiveThread` / `dismissAndDeleteThread`), and a background
    /// reload can evict/replace rows before the user's tap actually fires. For
    /// ids without a current on-screen snapshot, current-state + full header
    /// resolution both happen OFF-MAIN inside the queued closure — preserving
    /// the original filter-to-currently-unread semantics without a
    /// synchronous DB read on the gesture path.
    func markRead(_ messageIds: [String]) {
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
            // Overlay protects against reloadMessages clobbering the optimistic
            // state. Retain BEFORE registering, at gesture time, one per id —
            // matches this op's later per-id release in the queued closure.
            for id in unreadOnScreenIds {
                manager.retainOverlayEntry(id: id)
                manager.registerMutation(id: id, mutation: .init(isRead: true))
            }
            rebuildDisplayGroups()
        }

        // FIFO write queue — ensures ordering with other actions
        Task { await manager.enqueueWrite { [manager] in
            // On-screen ids: intent already established by the visualized
            // state — resolve headers and write unconditionally (writing
            // isRead=true to a row that's already true, or still lags to
            // false, is idempotent either way).
            let onScreenHeaders = await manager.resolveHeadersForAction(ids: unreadOnScreenIds)
            // Off-screen ids: current state unknown from the gesture path —
            // resolve + filter to currently-unread OFF-MAIN here, preserving
            // the original filter-to-unread semantics for the batch case.
            // Their overlay registration happens HERE (not at gesture time),
            // so retain immediately before each registerMutation call, in the
            // SAME closure that releases it below — the entry lives exactly
            // as long as this op.
            let offScreenHeaders = await manager.resolveHeadersForAction(ids: offScreenIds).filter { !$0.isRead }
            for header in offScreenHeaders {
                manager.retainOverlayEntry(id: header.id)
                manager.registerMutation(id: header.id, mutation: .init(isRead: true))
            }

            let vanishedOnScreenCount = unreadOnScreenIds.count - onScreenHeaders.count
            if vanishedOnScreenCount > 0 {
                BackgroundSyncLogger.logInbox("[InboxViewModel] markRead — header resolution failed for \(vanishedOnScreenCount) on-screen id(s), releasing overlay retain")
            }

            let messages = onScreenHeaders + offScreenHeaders
            if !messages.isEmpty {
                await manager.markRead(messages)
            }
            // Release exactly one retain per id this op holds: on-screen ids
            // were retained at gesture time (above, before this closure ran);
            // off-screen ids were retained just above, inside this same
            // closure — including vanished on-screen ids, whose retain still
            // needs releasing even though `onScreenHeaders` dropped them.
            for id in unreadOnScreenIds { manager.releaseOverlayEntry(id: id) }
            for header in offScreenHeaders { manager.releaseOverlayEntry(id: header.id) }
        }}
    }

    /// Sweep every currently-unread message in every loaded folder to read.
    ///
    /// The whole sweep runs inside ONE `enqueueWrite` closure, so it holds the
    /// FIFO write queue for its entire duration — every other durable write in
    /// the app is behind it. That makes TERMINATION a hard requirement, not a
    /// nicety: a sweep that cannot finish is not a slow mark-all, it is a
    /// permanently wedged application.
    ///
    /// Termination comes from the keyset cursor, exactly as in `v2final`. Each
    /// page is bounded on BOTH sides:
    ///
    /// * `upperBound` — the greatest currently-unread `id` in this folder,
    ///   read ONCE before the first page. It freezes the sweep's domain to the
    ///   rows that were unread when the user asked. Mail that arrives (or is
    ///   marked unread by a gesture that POSTDATES this one) while the sweep is
    ///   running is deliberately outside the domain and stays unread — the
    ///   user's later intent must win over an in-flight bulk action.
    /// * `lastVisitedID` — the keyset cursor, advanced to the last `id` of the
    ///   page just handed to `markRead`. Because `id` is the table's PRIMARY
    ///   KEY, `id > cursor` is a STRICT total order, so the candidate set
    ///   `{ id : cursor < id <= upperBound, isRead = 0 }` strictly shrinks on
    ///   every iteration and is finite. That is the loop's variant, and it
    ///   decreases whether or not the page's write landed.
    ///
    /// The pre-cursor loop re-ran the SAME unbounded query every pass, so a
    /// page whose write did not clear `isRead` came back byte-identical
    /// forever. That is reachable in production, not theoretical:
    /// `AccountManager.markRead` -> `admittedOrdinaryActionTargets` refuses a
    /// whole group (writing nothing, queueing nothing) whenever the folder's
    /// epoch is not yet known — `lastKnownUidValidity == nil` before the first
    /// sync completes, or `uidValidityResetPendingAt != nil` during a reset
    /// reaction. Both are *retryable* refusals that persist for as long as the
    /// condition holds, which is precisely long enough to spin forever.
    ///
    /// A refused page is NOT treated as read. The cursor moving past it writes
    /// nothing: those rows stay `isRead = 0` in the database and stay unread on
    /// screen, and the trailing recount + `reloadMessages` below republish that
    /// truth, so the intention remains visible and the gesture re-issuable.
    /// The refusal is never converted into "these are read now" — see the
    /// retryable/terminal split documented on
    /// `AccountManager.roleMoveRejectDispositions`.
    func markAllAsRead() {
        let batchSize = SyncConfig.inboxPageSize
        let foldersCopy = folders

        Task { @MainActor in
            await manager.enqueueWrite { [manager] in
                let dbPool = AppDatabase.dbPool
                for folder in foldersCopy {
                    let fid = folder.id

                    // Freeze this folder's domain before the first page. No
                    // unread row at all => nothing to sweep here.
                    let upperBound: String
                    do {
                        guard let bound = try await dbPool.read({ db in
                            try String.fetchOne(db, sql: """
                            SELECT id FROM messageHeader
                            WHERE folderId = ? AND isRead = 0
                            ORDER BY id COLLATE BINARY DESC
                            LIMIT 1
                            """, arguments: [fid])
                        }) else { continue }
                        upperBound = bound
                    } catch {
                        continue
                    }

                    var lastVisitedID: String?

                    while true {
                        let batch: [MessageHeader]
                        let cursor = lastVisitedID
                        do {
                            batch = try await dbPool.read { db in
                                if let cursor {
                                    return try MessageHeader.fetchAll(db, sql: """
                                    SELECT * FROM messageHeader
                                    WHERE folderId = ? AND isRead = 0
                                      AND id COLLATE BINARY > ? COLLATE BINARY
                                      AND id COLLATE BINARY <= ? COLLATE BINARY
                                    ORDER BY id COLLATE BINARY ASC
                                    LIMIT ?
                                    """, arguments: [fid, cursor, upperBound, batchSize])
                                }
                                return try MessageHeader.fetchAll(db, sql: """
                                SELECT * FROM messageHeader
                                WHERE folderId = ? AND isRead = 0
                                  AND id COLLATE BINARY <= ? COLLATE BINARY
                                ORDER BY id COLLATE BINARY ASC
                                LIMIT ?
                                """, arguments: [fid, upperBound, batchSize])
                            }
                        } catch { break }
                        guard !batch.isEmpty else { break }
                        // Advance BEFORE the write. The page is now spent for
                        // this sweep whatever `markRead` decides, which is what
                        // makes the variant decrease unconditionally.
                        lastVisitedID = batch.last?.id

                        #if DEBUG
                        if let hook = Self.markAllAsReadWillAdmitBatchForTesting.withLock({ $0 }) {
                            await hook(batch)
                        }
                        #endif

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
    /// mirrors `toggleRead`'s guard on the on-screen snapshot rather than a
    /// gesture-path DB read (zero-DB rule).
    func applyManualTag(_ messageId: String, tag: ActionTag?) {
        guard let snapshot = loadedMessages.first(where: { $0.id == messageId }) else { return }
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].actionTag = tag
        }
        // Gesture intents on the same id coalesce to the NET target
        // (ADR-IOS-057) — see `toggleRead`'s doc comment.
        manager.registerGestureIntent(id: messageId, .actionTag(target: tag, baseline: snapshot.actionTag))
        rebuildDisplayGroups()
    }

    func removeUserLabel(_ label: UserLabel, from snapshot: MessageSnapshot) async {
        // Look up full MessageHeader from DB for correct folderPath
        guard let message = lookupMessage(snapshot.id) else { return }
        // Optimistic UI: remove label from the on-screen row. A refused or failed
        // write RECONCILES from the database (see `reconcileUserLabels`) — the
        // whole-array snapshot this used to capture is not restorable correctly
        // under concurrent gestures.
        if let idx = loadedMessages.firstIndex(where: { $0.id == snapshot.id }) {
            loadedMessages[idx].userLabels.removeAll { $0.id == label.id }
        }
        // Persist + queue
        do {
            let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                // T1.3 — on IMAP a user label is a keyword STORE resolved by UID, so
                // an unknown folder epoch fails closed. Refuse before the local
                // delete so neither half lands.
                guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                    accountId: message.accountId, folderPath: message.folderPath, db: db) else { return false }
                // 🚨 ADMIT THROUGH THE PROVIDER-ADDRESS PREDICATE (audit A-6).
                // `stableId` is an rfc822 Message-ID on IMAP and carried no epoch,
                // so the drain's checkpoint A could only refuse this op: the label
                // vanished from the row, the op was written, and no drain ever
                // executed it. ⚠ CORRECTED (audit round 2): this said "the very
                // next drain deleted it unexecuted", which was checkpoint A's
                // behaviour when the defect shipped. It now SKIPS rather than
                // deletes, so today the same shape leaves a permanently
                // unclaimable row instead of vanishing. Admitting the same way every other
                // ordinary action does records the provider's native address and
                // the epoch that proved it.
                guard let admission = try AccountManager.admittedOrdinaryActionTargets(
                    [message], accountId: message.accountId,
                    folderPath: message.folderPath, db: db) else { return false }
                try MessageUserLabel
                    .filter(Column("messageId") == snapshot.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                // 🚨 `providerLabelId`, NEVER `id` — THIS VALUE GOES ON THE WIRE.
                // The drain hands `PendingOperation.userLabelId` straight to the
                // provider as a raw argument (Gmail `removeLabelIds:`, IMAP
                // `STORE -FLAGS (<keyword>)`), and `UserLabel.id` is the
                // account-prefixed surrogate (D10 / `IOS-LABEL-001`). See
                // `UserLabelMenuModel.applyLabel` for why a prefixed value is not
                // merely a failure on Gmail but a SILENT drop: `"Invalid label"`
                // is matched by `GmailProvider.isAuthoritativeActionRejection` as a
                // provider-authoritative no-op, so the op leaves the queue as if
                // it had been performed.
                let op = PendingOperation(
                    type: .removeUserLabel,
                    messageIds: admission.providerIds,
                    accountId: message.accountId,
                    folderPath: message.folderPath,
                    userLabelId: label.providerLabelId,
                    observedUidValidity: admission.observedUidValidity
                )
                try op.insert(db)
                return true
            }
            // A refusal queued nothing and changed no row. Leaving the optimistic
            // removal in place would show the label as gone forever while it is still
            // applied in the database — a phantom success.
            guard admitted else {
                reconcileUserLabels(forMessageId: snapshot.id)
                return
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
            // Also on the admitted path, for the convergence reason stated on
            // `UserLabelMenuModel`: reconciling only on refusal leaves a stale row
            // standing whenever the LAST overlapping gesture to finish was admitted.
            reconcileUserLabels(forMessageId: snapshot.id)
        } catch {
            reconcileUserLabels(forMessageId: snapshot.id)
            print("[InboxViewModel] removeUserLabel failed: \(error)")
        }
    }

    /// Re-derive a message's on-screen label set from the DATABASE after a write
    /// that was refused or failed. No-op when the row has since left the list.
    ///
    /// 🚨 It RECONCILES; it does not restore a snapshot. The predecessor captured
    /// the whole `userLabels` array before the await and assigned it back, which
    /// composes wrongly the moment two label gestures overlap on the same row:
    /// the second gesture's "previous" array is the FIRST gesture's unpersisted
    /// optimistic state, so restoring it re-publishes a state that was never
    /// durable and can leave the row disagreeing with `messageUserLabel` in either
    /// direction. Undoing each gesture's own delta has the same flaw for the same
    /// reason. Reading the join rows is the only formulation whose result does not
    /// depend on what any gesture happened to observe — see
    /// `UserLabelMenuModel`'s doc comment, which states the same invariant for the
    /// menu's checkmarks.
    ///
    /// Re-finds by id rather than reusing a captured index: the array can be
    /// rebuilt across an await.
    ///
    /// **The `dbPool.read` here is SYNCHRONOUS on the MainActor, deliberately**
    /// (audit round 8 raised it against Resilience Rule 1). Making it `async`
    /// would put a suspension point between the read and the assignment, and the
    /// whole value of this function is that those two are ATOMIC: nothing can
    /// interleave, so whichever overlapping gesture completes LAST leaves
    /// `loadedMessages` equal to the durable truth. With an await in the middle,
    /// two reconciles can read in one order and write in the other, and the older
    /// read can land last — which is exactly the compose-wrongly failure the
    /// snapshot restore this replaced had, in a new costume. The read itself is
    /// one lookup on `messageUserLabel`'s composite primary key
    /// `(messageId, userLabelId)` — leading-column indexed, a handful of rows —
    /// on a path that has just awaited `drainPendingQueue`. Same reasoning and
    /// same shape as `UserLabelMenuModel.reconcileAppliedIdsFromDatabase` and
    /// `loadLabels`. (This list used to name `resolvedFolderPath` too; T4.V13
    /// deleted that helper — `applyLabel`/`removeLabel` now resolve the header
    /// inside their own admission write transaction instead.) If this ever has
    /// to go async, the
    /// atomicity has to be restored some other way (a generation token on the
    /// row, or reconciling under a serialising actor) — not dropped.
    private func reconcileUserLabels(forMessageId id: String) {
        guard let idx = loadedMessages.firstIndex(where: { $0.id == id }) else { return }
        do {
            let labels = try AppDatabase.dbPool.read { db in
                try UserLabelStore.labelsForMessage(id, in: db)
            }
            loadedMessages[idx].userLabels = labels
        } catch {
            print("[InboxViewModel] reconcileUserLabels failed for \(id): \(error)")
        }
    }

    /// Returns false when nothing was recorded (lookup miss) — callers
    /// (InboxView's move-sheet site) MUST NOT leave the row hidden when this
    /// returns false, or it vanishes forever with no undo entry. Same contract
    /// and same defect class as `archive(_:)`; see its doc comment.
    @discardableResult
    func move(_ messageId: String, toFolderPath: String) -> Bool {
        guard let message = lookupMessage(messageId) else {
            print("[MoveTrace] ViewModel.move — lookupMessage FAILED for id=\(messageId)")
            return false
        }
        print("[MoveTrace] ViewModel.move — msgId=\(message.messageId) from=\(message.folderPath) to=\(toFolderPath) folderId=\(message.folderId) headerDbId=\(message.id)")
        let destFolderId = "\(message.accountId):\(toFolderPath)"
        // Capture the undo snapshot BEFORE this action's own retain/
        // registerMutation below — see overlayAdjustedForUndo's doc comment.
        let undoSnapshot = overlayAdjustedForUndo(message)
        manager.retainOverlayEntry(id: messageId)
        // Generic move: unlike archive/delete, the destination CAN be the
        // inbox (e.g. moving out of Spam) — check the dest folder's role,
        // not just the source's isInInbox (F6).
        let destRole = lookupFolderRole(destFolderId)
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId, actionTag: (message.isInInbox && destRole != .inbox) ? .some(nil) : nil))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: toFolderPath), messages: [undoSnapshot],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: toFolderPath)
            manager.releaseOverlayEntry(id: messageId)
        }}
        return true
    }

    /// Move every member of a thread to `toFolderPath` as one grouped action.
    /// Pushes a single UndoableAction carrying all members so the whole thread
    /// restores in one undo — mirrors archiveThread/deleteThread.
    ///
    /// Returns the ids of `messageIds` that were NOT acted upon (nothing
    /// resolved for them, or the whole call aborted) — the caller (InboxView)
    /// optimistically hides every member BEFORE calling this, so it MUST
    /// un-hide exactly the ids returned here or those rows vanish forever with
    /// no undo entry. See `archiveThread`'s doc comment for the full contract.
    @discardableResult
    func moveThread(_ messageIds: [String], toFolderPath: String) -> [String] {
        let messages = messageIds.compactMap { lookupMessage($0) }
        // Nothing resolved — every id reported skipped so the caller un-hides.
        guard let first = messages.first else {
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] ViewModel.moveThread — no messages resolved for ids=\(messageIds)")
            }
            return messageIds
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] ViewModel.moveThread — count=\(messages.count) from=\(first.folderPath) to=\(toFolderPath)")
        }
        let destFolderId = "\(first.accountId):\(toFolderPath)"
        let compositeIds = messages.map(\.id)
        // Capture undo snapshots BEFORE the retain/registerMutation loop
        // below — see overlayAdjustedForUndo's doc comment.
        let undoMessages = messages.map { overlayAdjustedForUndo($0) }
        // Generic move: destination CAN be the inbox — check the dest
        // folder's role once (same dest for every member), then combine with
        // each member's own isInInbox (F6).
        let destRole = lookupFolderRole(destFolderId)
        for msg in messages {
            manager.retainOverlayEntry(id: msg.id)
            manager.registerMutation(id: msg.id, mutation: .init(folderId: destFolderId, actionTag: (msg.isInInbox && destRole != .inbox) ? .some(nil) : nil))
        }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: toFolderPath), messages: undoMessages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: toFolderPath)
            for id in compositeIds { manager.releaseOverlayEntry(id: id) }
        }}
        // Members that never resolved were never acted upon — report them
        // skipped so the caller un-hides exactly those rows.
        let recorded = Set(compositeIds)
        return messageIds.filter { !recorded.contains($0) }
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
