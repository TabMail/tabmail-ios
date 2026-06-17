/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@preconcurrency import Combine
import SwiftUI

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
    private var dbPool: DatabasePool { AppDatabase.dbPool }

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
        try? dbPool.read { db in try MessageHeader.fetchOne(db, key: id) }
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
            .publisher(in: AppDatabase.dbPool)
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
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Dirty bit + throttled loop.
                // Every signal sets the bit unconditionally. The throttle task loops until
                // the bit is clean at the start of a reload — so any signal arriving during
                // sleep OR during reloadMessages triggers a follow-up reload.
                self.backgroundChangeDirty = true
                if self.backgroundChangeTask == nil {
                    self.backgroundChangeTask = Task { @MainActor [weak self] in
                        while let self, self.backgroundChangeDirty {
                            try? await Task.sleep(for: .milliseconds(500))
                            if Task.isCancelled { break }
                            // Clear BEFORE reload so signals arriving during reload re-arm the loop.
                            self.backgroundChangeDirty = false
                            await self.reloadMessages(animated: true)
                        }
                        self?.backgroundChangeTask = nil
                    }
                }
            }
        }
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
                if self.aiBatchTask == nil {
                    self.aiBatchTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, let self else { return }
                        self.flushAIBatch()
                    }
                }
            }
        }
    }

    /// Flush batched AI updates — applies all pending snapshot refreshes in one pass.
    private func flushAIBatch() {
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
            }
        }
        // Batch-read all needed headers in a single DB read (not one read per message)
        let freshHeaders: [String: MessageHeader] = (try? dbPool.read { db in
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
            // Preserve snippet (not in header, loaded separately)
            snapshot.snippet = loadedMessages[idx].snippet
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
        var inserted = false
        for id in ids {
            guard !loadedIds.contains(id) else { continue }
            guard var header = try? dbPool.read({ db in try MessageHeader.fetchOne(db, key: id) }) else { continue }
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
            let snapshot = MessageSnapshot(from: header)
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

    /// Full reset — drops all loaded state and fetches page 1.
    /// Use for semantic changes where the data set itself changes:
    /// folder switch, filter toggle, mode switch, initial load.
    func resetMessages() {
        selfHealFolders()
        resetSnippetState()
        loadedIds = []
        targetWindowSize = SyncConfig.inboxPageSize
        loadedMessages = fetchPage(before: nil)
        loadedIds = Set(loadedMessages.map(\.id))
        hasMoreMessages = loadedMessages.count >= targetWindowSize
        // Full assign — no diff needed since the data set changed entirely
        displayGroups = ThreadGroupBuilder.buildDisplayGroups(from: loadedMessages, mode: mode)
        requeueVisibleSnippets()
    }

    /// Diff-based reload — re-fetches the currently loaded date range and diffs in-place.
    /// Use for background data changes (sync, backfill) where the data set is the same
    /// but individual messages may have been added/removed/updated.
    /// SwiftUI sees incremental changes by stable message ID, preserving scroll position.
    /// Async: DB read runs off MainActor (prevents hang during WAL checkpoint contention).
    /// The diff and @Observable mutations run on MainActor after the read completes.
    /// Apply the optimistic overlay on top of DB-fetched snapshots.
    /// Overlay is snapshotted BEFORE the DB read for correct timing.
    /// - Overrides isRead, isFlagged, actionTag, isInInbox for messages with pending mutations
    /// - Filters out messages whose overlay folderId moved them out of current folder set
    private func applyOverlay(_ messages: inout [MessageSnapshot], overlay: [String: AccountManager.PendingMutation], folderIds: Set<String>) {
        guard !overlay.isEmpty else { return }
        // Apply field overrides and filter out moved-away messages
        messages = messages.compactMap { snapshot in
            guard let mutation = overlay[snapshot.id] else { return snapshot }
            // If overlay says this message moved to a different folder, filter it out
            if let newFolderId = mutation.folderId, !folderIds.contains(newFolderId) {
                return nil
            }
            var modified = snapshot
            if let v = mutation.isRead { modified.isRead = v }
            if let v = mutation.isFlagged { modified.isFlagged = v }
            if let v = mutation.actionTag { modified.actionTag = v }
            if let v = mutation.isInInbox { modified.isInInbox = v }
            return modified
        }
    }

    func reloadMessages(animated: Bool = false) async {
        // Heal folders OFF the main thread — the synchronous selfHealFolders()
        // here blocked the UI on a GRDB read during warm-foreground return
        // (the warm-foreground hang; Half A / PLAN_HANG_FIX).
        await selfHealFoldersAsync()
        let folderNames = folders.map { "\($0.name)(\($0.id))" }.joined(separator: ", ")
        print("[MoveTrace] reloadMessages — folders=[\(folderNames)] prevCount=\(loadedMessages.count)")

        resetSnippetState()

        // Snapshot overlay BEFORE DB read — ensures correct timing for all cases.
        let overlay = manager.snapshotOverlay()

        // Fetch fresh data off MainActor — async GRDB read suspends (not blocks) the main thread.
        // This prevents UI hangs when heavy sync writes trigger WAL auto-checkpoint.
        var freshMessages = await fetchFullRange()

        // Apply optimistic overlay on top of DB results
        let folderIds = Set(folders.map(\.id))
        applyOverlay(&freshMessages, overlay: overlay, folderIds: folderIds)

        // Apply diff on MainActor (synchronous — fast in-memory work on @Observable state).
        let applyDiff = { [self] in
            // Diff into loadedMessages in-place
            let freshById: [String: MessageSnapshot] = {
                var dict: [String: MessageSnapshot] = [:]
                dict.reserveCapacity(freshMessages.count)
                for m in freshMessages { dict[m.id] = m }
                return dict
            }()

            // Pass 1: Remove messages no longer in fresh set, update changed ones
            var survivingIds: Set<String> = []
            var indicesToRemove: [Int] = []
            for (i, existing) in loadedMessages.enumerated() {
                if let fresh = freshById[existing.id] {
                    // Only assign if the snapshot actually changed — avoids triggering
                    // @Observable for unchanged rows, preventing unnecessary re-renders
                    // and layout shifts that cause scroll position jumps.
                    if existing != fresh {
                        loadedMessages[i] = fresh
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
        let tRebuild = CFAbsoluteTimeGetCurrent()
        rebuildDisplayGroups()
        let rebuildMs = Int((CFAbsoluteTimeGetCurrent() - tRebuild) * 1000)
        requeueVisibleSnippets()
        if diffMs + rebuildMs >= 50 {
            BackgroundSyncLogger.logInbox("[\(instanceTag)] reloadMessages MainActor-sync cost: applyDiff=\(diffMs)ms rebuildGroups=\(rebuildMs)ms (fresh=\(freshMessages.count), loaded=\(loadedMessages.count))")
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
    /// Bounded by count: fetches the top N messages (N = current loaded count)
    /// in the active sort order. Works for any sort (date, triage tagSortOrder).
    /// Async: DB read runs off MainActor to prevent blocking during WAL checkpoint.
    private func fetchFullRange() async -> [MessageSnapshot] {
        // Nothing loaded — first page (sync read, only on initial load)
        guard !loadedMessages.isEmpty else {
            return fetchPage(before: nil)
        }

        // Capture MainActor-isolated query parameters before async read.
        // These are value types — safe to send across isolation boundaries.
        let foldersCopy = folders
        let filterUnreadCopy = filterUnread
        let modeCopy = mode
        let filterLabelIdsCopy = filterLabelIds
        // Re-fetch up to the target window size. Sticky — only grows on explicit
        // user scroll (loadMoreMessages); never shrinks just because messages left
        // the inbox. Per-folder limit = target (a single folder might contain all
        // loaded messages in a unified inbox).
        let targetCount = targetWindowSize

        var allResults: [MessageSnapshot] = []
        do {
            allResults = try await dbPool.read { db in
                var allHeaders: [MessageHeader] = []
                for folder in foldersCopy {
                    let fid = folder.id
                    var query = MessageHeader.filter(Column("folderId") == fid)
                        .filter(Column("headerComplete") == true)

                    if filterUnreadCopy {
                        query = query.filter(Column("isRead") == false)
                    }

                    if modeCopy == .triage {
                        query = query.order(Column("tagSortOrder").asc, Column("date").desc)
                    } else {
                        query = query.order(Column("date").desc)
                    }

                    let results = try query.limit(targetCount).fetchAll(db)
                    allHeaders.append(contentsOf: results)
                }
                // Batch-load user labels for all fetched messages
                let labelsByMessage = try UserLabelStore.loadLabels(
                    for: allHeaders.map(\.id), in: db
                )
                return allHeaders.map { header in
                    MessageSnapshot(from: header, userLabels: labelsByMessage[header.id] ?? [])
                }
            }
        } catch {
            print("[InboxViewModel] fetchFullRange error: \(error)")
        }

        // Apply label filter (post-filter: keep only messages that have ALL selected labels)
        if !filterLabelIdsCopy.isEmpty {
            allResults = allResults.filter { snapshot in
                let msgLabelIds = Set(snapshot.userLabels.map(\.id))
                return filterLabelIdsCopy.isSubset(of: msgLabelIds)
            }
        }

        // Sort consistently with fetchPage
        if modeCopy == .triage {
            allResults.sort { a, b in
                if a.tagSortOrder != b.tagSortOrder { return a.tagSortOrder < b.tagSortOrder }
                return a.date > b.date
            }
        } else {
            allResults.sort { $0.date > $1.date }
        }

        // Deduplicate by ID (multi-folder can overlap), trim to target window size
        var seen: Set<String> = []
        seen.reserveCapacity(allResults.count)
        allResults.removeAll { !seen.insert($0.id).inserted }
        if allResults.count > targetCount {
            allResults = Array(allResults.prefix(targetCount))
        }

        return allResults
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

    /// Fetch one page of messages across all folders using GRDB.
    /// Converts to value-type MessageSnapshot immediately.
    /// Bounded: fetches at most `folders.count × pageSize`, then trims to `pageSize`.
    private func fetchPage(before: Date?) -> [MessageSnapshot] {
        let pageSize = SyncConfig.inboxPageSize
        var allResults: [MessageSnapshot] = []
        let tStart = CFAbsoluteTimeGetCurrent()
        var tReadStart: CFAbsoluteTime = 0
        var tReadEnd: CFAbsoluteTime = 0

        do {
            tReadStart = CFAbsoluteTimeGetCurrent()
            try dbPool.read { db in
                tReadEnd = CFAbsoluteTimeGetCurrent()  // Reader acquired — wait for semaphore ends here.
                var allHeaders: [MessageHeader] = []
                for folder in folders {
                    let fid = folder.id
                    var query = MessageHeader.filter(Column("folderId") == fid)
                        .filter(Column("headerComplete") == true)

                    if filterUnread {
                        query = query.filter(Column("isRead") == false)
                    }
                    if let cutoff = before {
                        query = query.filter(Column("date") < cutoff)
                    }

                    if mode == .triage {
                        query = query.order(Column("tagSortOrder").asc, Column("date").desc)
                    } else {
                        query = query.order(Column("date").desc)
                    }

                    let results = try query.limit(pageSize).fetchAll(db)
                    allHeaders.append(contentsOf: results)
                }
                // Batch-load user labels for all fetched messages
                let labelsByMessage = try UserLabelStore.loadLabels(
                    for: allHeaders.map(\.id), in: db
                )
                allResults = allHeaders.map { header in
                    MessageSnapshot(from: header, userLabels: labelsByMessage[header.id] ?? [])
                }
            }
            let tEnd = CFAbsoluteTimeGetCurrent()
            let waitMs = Int((tReadEnd - tReadStart) * 1000)
            let queryMs = Int((tEnd - tReadEnd) * 1000)
            let totalMs = Int((tEnd - tStart) * 1000)
            // Log timing split so we can tell pool-contention from query-cost.
            // waitMs = time MainActor spent waiting for a free GRDB reader
            // queryMs = time the actual SELECTs took once we had a reader
            // Huge wait + tiny query = reader pool starvation (fix: async read)
            // Tiny wait + huge query = slow query (fix: query itself)
            if totalMs >= 50 {
                BackgroundSyncLogger.logInbox("[\(instanceTag)] fetchPage timing wait=\(waitMs)ms query=\(queryMs)ms total=\(totalMs)ms folders=\(folders.count) page=\(pageSize) results=\(allResults.count)")
            }
        } catch {
            print("[InboxViewModel] fetchPage error: \(error)")
        }

        // Apply label filter
        if !filterLabelIds.isEmpty {
            allResults = allResults.filter { snapshot in
                let msgLabelIds = Set(snapshot.userLabels.map(\.id))
                return filterLabelIds.isSubset(of: msgLabelIds)
            }
        }

        // Merge sort across folders, deduplicate, trim to pageSize
        if mode == .triage {
            allResults.sort { a, b in
                if a.tagSortOrder != b.tagSortOrder { return a.tagSortOrder < b.tagSortOrder }
                return a.date > b.date
            }
        } else {
            allResults.sort { $0.date > $1.date }
        }

        // Deduplicate against already-loaded messages
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
        for headerId in batch {
            guard !Task.isCancelled else { return }
            if let header = lookupMessage(headerId), !header.snippet.isEmpty {
                snippetUpdates.append((headerId: headerId, snippet: header.snippet))
            } else {
                needsFTS.append(headerId)
            }
        }
        print("[SnippetLoader] Batch \(batch.count): tier0=\(snippetUpdates.count) needsFTS=\(needsFTS.count)")

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
            // Need network fetch
            if let header = lookupMessage(headerId) {
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
                // For snippet-only extraction: use textBody directly when available (no conversion),
                // otherwise truncate HTML to ~2KB before stripping (not the full multi-MB body).
                // FTS indexing is NOT done here — ActiveBodyQueue/BackfillBodyQueue handles it.
                // Prefer htmlBody (authoritative content), fall through to textBody if HTML is empty
                // (IMAP servers sometimes return a 1-char text body alongside full HTML)
                // Uniform snippet derivation: always htmlToPlainText → snippetFromPlainText
                // (same path as ActiveBodyQueue / AccountManagerFetch / BackfillWalk)
                var snippet = ""
                if let html = fullMessage.htmlBody, !html.isEmpty {
                    let plain = EmailFilter.htmlToPlainText(html)
                    snippet = EmailFilter.snippetFromPlainText(plain)
                    if DebugModeManager.isLoggingEnabled() { print("[SnippetLoader] Tier2 htmlBody len=\(html.count) snippet=\(snippet.prefix(50))") }
                }
                if snippet.isEmpty, let text = fullMessage.textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Guard against HTML documents mislabeled as text/plain (same
                    // check as EmailFilter.extractPlainText, which this inlines).
                    let plain = EmailFilter.looksLikeHTMLDocument(text) ? EmailFilter.htmlToPlainText(text) : text
                    snippet = EmailFilter.snippetFromPlainText(plain)
                    if DebugModeManager.isLoggingEnabled() { print("[SnippetLoader] Tier2 textBody len=\(text.count) snippet=\(snippet.prefix(50))") }
                }
                if snippet.isEmpty {
                    print("[SnippetLoader] Tier2 NO USABLE BODY for msgId=\(item.header.messageId)")
                    continue
                }
                let finalSnippet = snippet
                try? await dbPool.write { db in
                    try db.execute(sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?", arguments: [finalSnippet, item.headerId])
                }
                snippetUpdates.append((headerId: item.headerId, snippet: finalSnippet))
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

    func archive(_ messageId: String) {
        guard let message = lookupMessage(messageId) else { return }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp.
        guard lookupFolderRole(message.folderId) != .archive else { return }
        guard let archivePath = lookupFolderPath(accountId: message.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(message.accountId)")
            return
        }
        guard message.folderPath != archivePath else { return }
        let destFolderId = "\(message.accountId):\(archivePath)"
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: archivePath), messages: [message],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: archivePath)
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    func archiveThread(_ messageIds: [String]) {
        let messages = messageIds.compactMap { lookupMessage($0) }
        guard let first = messages.first else { return }
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveIsNoOp.
        guard lookupFolderRole(first.folderId) != .archive else { return }
        guard let archivePath = lookupFolderPath(accountId: first.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(first.accountId)")
            return
        }
        guard first.folderPath != archivePath else { return }
        let destFolderId = "\(first.accountId):\(archivePath)"
        let compositeIds = messages.map(\.id)
        for id in compositeIds { manager.registerMutation(id: id, mutation: .init(folderId: destFolderId)) }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: archivePath), messages: messages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: archivePath)
            manager.removeOverlayEntries(ids: compositeIds)
        }}
    }

    func delete(_ messageId: String) async {
        guard let message = lookupMessage(messageId) else { return }
        // Drafts folder: use draft-specific deletion (DELETE /drafts or STORE+EXPUNGE)
        // instead of move-to-trash, which doesn't work for Gmail drafts.
        let folderRole = lookupFolderRole(message.folderId)
        if folderRole == .drafts {
            await deleteDraftMessage(message)
            return
        }
        AccountManager.logDeleteTrace(accountId: message.accountId, messages: [message], callSite: "InboxViewModel.delete")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp.
        if folderRole == .trash { return }
        guard let trashPath = lookupFolderPath(accountId: message.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(message.accountId)")
            return
        }
        guard message.folderPath != trashPath else { return }
        let destFolderId = "\(message.accountId):\(trashPath)"
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: trashPath), messages: [message],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: trashPath)
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    func deleteThread(_ messageIds: [String]) async {
        let messages = messageIds.compactMap { lookupMessage($0) }
        guard let first = messages.first else { return }
        // Drafts folder: delete each draft individually
        let folderRole = lookupFolderRole(first.folderId)
        if folderRole == .drafts {
            for message in messages {
                await deleteDraftMessage(message)
            }
            return
        }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "InboxViewModel.deleteThread")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see deleteIsNoOp.
        if folderRole == .trash { return }
        guard let trashPath = lookupFolderPath(accountId: first.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(first.accountId)")
            return
        }
        guard first.folderPath != trashPath else { return }
        let destFolderId = "\(first.accountId):\(trashPath)"
        let compositeIds = messages.map(\.id)
        for id in compositeIds { manager.registerMutation(id: id, mutation: .init(folderId: destFolderId)) }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: trashPath), messages: messages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: trashPath)
            manager.removeOverlayEntries(ids: compositeIds)
        }}
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

    func toggleRead(_ messageId: String) {

        guard let message = lookupMessage(messageId) else { return }
        let newIsRead = !message.isRead

        // Optimistic in-memory mutation (instant visual feedback)
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].isRead = newIsRead
        }
        // Overlay protects against reloadMessages clobbering the optimistic state
        manager.registerMutation(id: messageId, mutation: .init(isRead: newIsRead))
        rebuildDisplayGroups()

        // FIFO write queue — ensures ordering with other actions
        Task { await manager.enqueueWrite { [manager] in
            if newIsRead {
                await manager.markRead([message])
            } else {
                await manager.markUnread([message])
            }
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    /// Batched set-read. Filters to currently-unread members, then applies the
    /// optimistic-UI + overlay + write pipeline once for the whole group.
    /// Use for thread-level actions (tag-tap archive/delete/reply).
    func markRead(_ messageIds: [String]) {
        let messages = messageIds.compactMap { lookupMessage($0) }.filter { !$0.isRead }
        guard !messages.isEmpty else { return }
        let flipIds = messages.map(\.id)
        let flipSet = Set(flipIds)

        // Optimistic in-memory mutation (instant visual feedback)
        for idx in loadedMessages.indices where flipSet.contains(loadedMessages[idx].id) {
            loadedMessages[idx].isRead = true
        }
        // Overlay protects against reloadMessages clobbering the optimistic state
        for id in flipIds { manager.registerMutation(id: id, mutation: .init(isRead: true)) }
        rebuildDisplayGroups()

        // FIFO write queue — ensures ordering with other actions
        Task { await manager.enqueueWrite { [manager] in
            await manager.markRead(messages)
            manager.removeOverlayEntries(ids: flipIds)
        }}
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

    func toggleFlag(_ messageId: String) {
        guard let message = lookupMessage(messageId) else { return }
        let newFlagged = !message.isFlagged
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].isFlagged = newFlagged
        }
        manager.registerMutation(id: messageId, mutation: .init(isFlagged: newFlagged))
        rebuildDisplayGroups()
        Task { await manager.enqueueWrite { [manager] in
            await manager.markFlagged([message], flagged: newFlagged)
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    func applyManualTag(_ messageId: String, tag: ActionTag?) {
        guard let message = lookupMessage(messageId) else { return }
        if let idx = loadedMessages.firstIndex(where: { $0.id == messageId }) {
            loadedMessages[idx].actionTag = tag
        }
        manager.registerMutation(id: messageId, mutation: .init(actionTag: tag))
        rebuildDisplayGroups()
        Task { await manager.enqueueWrite { [manager] in
            await manager.applyManualTag(message, tag: tag)
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    func removeUserLabel(_ label: UserLabel, from snapshot: MessageSnapshot) async {
        // Look up full MessageHeader from DB for correct folderPath
        guard let message = lookupMessage(snapshot.id) else { return }
        // Optimistic UI: remove label from snapshot
        if let idx = loadedMessages.firstIndex(where: { $0.id == snapshot.id }) {
            loadedMessages[idx].userLabels.removeAll { $0.id == label.id }
        }
        // Persist + queue
        do {
            try await AppDatabase.dbPool.write { db in
                try MessageUserLabel
                    .filter(Column("messageId") == snapshot.id && Column("userLabelId") == label.id)
                    .deleteAll(db)
                let op = PendingOperation(
                    type: .removeUserLabel,
                    messageIds: [message.stableId],
                    accountId: message.accountId,
                    folderPath: message.folderPath,
                    userLabelId: label.id
                )
                try op.insert(db)
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            await AccountManager.shared.drainPendingQueue()
        } catch {
            print("[InboxViewModel] removeUserLabel failed: \(error)")
        }
    }

    func move(_ messageId: String, toFolderPath: String) {
        guard let message = lookupMessage(messageId) else {
            print("[MoveTrace] ViewModel.move — lookupMessage FAILED for id=\(messageId)")
            return
        }
        print("[MoveTrace] ViewModel.move — msgId=\(message.messageId) from=\(message.folderPath) to=\(toFolderPath) folderId=\(message.folderId) headerDbId=\(message.id)")
        let destFolderId = "\(message.accountId):\(toFolderPath)"
        manager.registerMutation(id: messageId, mutation: .init(folderId: destFolderId))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: message.folderPath, toPath: toFolderPath), messages: [message],
            originalFolderId: message.folderId,
            originalFolderPath: message.folderPath,
            accountId: message.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([message], to: toFolderPath)
            manager.removeOverlayEntries(ids: [messageId])
        }}
    }

    /// Move every member of a thread to `toFolderPath` as one grouped action.
    /// Pushes a single UndoableAction carrying all members so the whole thread
    /// restores in one undo — mirrors archiveThread/deleteThread.
    func moveThread(_ messageIds: [String], toFolderPath: String) {
        let messages = messageIds.compactMap { lookupMessage($0) }
        guard let first = messages.first else {
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] ViewModel.moveThread — no messages resolved for ids=\(messageIds)")
            }
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] ViewModel.moveThread — count=\(messages.count) from=\(first.folderPath) to=\(toFolderPath)")
        }
        let destFolderId = "\(first.accountId):\(toFolderPath)"
        let compositeIds = messages.map(\.id)
        for id in compositeIds { manager.registerMutation(id: id, mutation: .init(folderId: destFolderId)) }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: first.folderPath, toPath: toFolderPath), messages: messages,
            originalFolderId: first.folderId,
            originalFolderPath: first.folderPath,
            accountId: first.accountId, timestamp: Date()
        ))
        Task { await manager.enqueueWrite { [manager] in
            await manager.move(messages, to: toFolderPath)
            manager.removeOverlayEntries(ids: compositeIds)
        }}
    }

    /// Check if inbox qualifies as "large" (100+ messages with some older than 2 weeks).
    /// Updates TipKit parameter and UserDefaults flag (read by sidebar badge + settings).
    func checkLargeInbox() {
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: Date()) ?? Date()
        let folderIds = Set(folders.map(\.id))

        guard let (totalCount, oldCount) = try? dbPool.read({ db -> (Int, Int) in
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
