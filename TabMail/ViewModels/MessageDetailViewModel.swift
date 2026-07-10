/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI

@Observable
@MainActor
final class MessageDetailViewModel {
    /// Sentinel prefix for a notification-tap open whose PROVIDER messageId has
    /// not yet been resolved to a composite header id. The deep-link handler
    /// pushes the detail view IMMEDIATELY (skeleton on screen) with
    /// `"\(notificationTapIdPrefix)<providerMessageId>"` instead of blocking
    /// navigation on the resolve ladder; the VM resolves it asynchronously
    /// (`resolveTapIfNeeded`) and rewrites `messageId` to the composite.
    /// Cannot collide with real composite ids — those start with an accountId.
    static let notificationTapIdPrefix = "notifTap::"

    private(set) var messageId: String
    private(set) var message: MessageHeader?
    private(set) var messageBody: MessageBody?
    var isLoading = true
    var error: String?
    var messageNotFound = false
    var threadMessages: [MessageHeader] = []

    /// Guards against concurrent/duplicate `loadBody()` calls.
    /// `.task` and `.onAppear` both call `loadBody()` — the first caller wins.
    @ObservationIgnored private var loadBodyCalled = false

    /// Guards against concurrent/duplicate `markReadOnOpenIfNeeded()` calls.
    /// Independent of `loadBodyCalled` — mark-read must succeed even when
    /// body load is cancelled mid-DB-read.
    @ObservationIgnored private var markReadOnOpenCalled = false

    /// Guards against overlapping `retryLoad()` invocations. retryLoad
    /// unconditionally clears the single-shot latches above, so without this
    /// a double-tap on the Retry button (or a `.task` re-fire mid-retry)
    /// starts a second independent resolve ladder whose exhaustion can post
    /// `.notificationTapUnresolved` and pop the view even though the first
    /// invocation resolved. MainActor serializes accesses; retryLoad's
    /// `defer` releases it on every exit path.
    @ObservationIgnored private var retryInFlight = false

    /// Whether the owning MessageDetailView is currently on screen — set by
    /// its `.onAppear`/`.onDisappear`. Defaults to TRUE: the VM is presumed
    /// presented from init (it's constructed at push time, before the first
    /// `.onAppear` fires), and the existing exhaustion tests drive `loadBody`
    /// without any view mounted.
    ///
    /// Purpose: suppress the `.notificationTapUnresolved` pop post from a
    /// DISAPPEARED VM. Scenario: tap → VM₁ (sentinel S) ladder in flight →
    /// user navigates away (the `.task` is cancelled but the ladder await is
    /// not cancellation-aware; loadBody continues) → user re-taps the SAME
    /// notification → VM₂ for the IDENTICAL sentinel S resolves → VM₁'s
    /// abandoned ladder exhausts late and posts S →
    /// `shouldPopForUnresolvedTap(S, S)` passes on string equality — it
    /// cannot distinguish VM INSTANCES — and VM₂ is popped to the inbox while
    /// the user reads the message. Instance staleness is gated here instead.
    ///
    /// NOTE: this flag only covers NAVIGATION-away. Sheets/fullScreenCovers do
    /// NOT fire the presenting view's `onDisappear` — see
    /// `hasActivePresentation` below for that case.
    @ObservationIgnored var isViewVisible = true

    /// Whether ANY sheet/fullScreenCover of the owning MessageDetailView is
    /// currently presented — maintained by the view's single
    /// `.onChange(of: isAnyCoverPresented)`. Covers do NOT fire the presenting
    /// view's `onAppear`/`onDisappear`, so this flag is the only way the VM
    /// knows a cover is up. A `.notificationTapUnresolved` pop must NEVER tear
    /// down a view that has a live presentation on top: SwiftUI force-dismisses
    /// the presentation along with it — worst case yanking an OPEN COMPOSE
    /// DRAFT out from under the user (never-drop-user-intention). Imperative
    /// QuickLook (presented outside this view's tree by AttachmentListView) is
    /// covered separately by the global `PreviewFreezeGate.shared.isFrozen`
    /// check at the same gate.
    @ObservationIgnored var hasActivePresentation = false

    private let manager = AccountManager.shared
    private var dbPool: PrioritizedDatabase { _dbPoolOverride ?? AppDatabase.dbPool }

    // Test seams — internal so @testable import can inject them
    @ObservationIgnored var _dbPoolOverride: PrioritizedDatabase?
    @ObservationIgnored var _fetchBodyOverride: ((MessageHeader) async throws -> Void)?
    /// Overrides for `resolveProviderTap`'s bounded poll (production defaults
    /// to `SyncConfig.notifTapStagedResolveWaitSeconds`/`notifTapStagedResolvePollMs`,
    /// i.e. 1.5s) so tests exercising a genuinely-exhausted ladder don't pay
    /// the full wait.
    @ObservationIgnored var _tapResolveWaitSecondsOverride: TimeInterval?
    @ObservationIgnored var _tapResolvePollMsOverride: Int?

    /// The resolved composite ID — may differ from `messageId` if the message was found
    /// via cross-folder fallback (e.g., after IMAP MOVE changed the UID).
    private var resolvedId: String { message?.id ?? messageId }

    @ObservationIgnored nonisolated(unsafe) private var aiUpdateObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var previewFreezeReleasedObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var nseMergeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var messagesStagedObserver: NSObjectProtocol?
    /// Poll task that checks for MessageBody in DB when body is missing.
    /// Catches cases where fetchBody succeeds but the ViewModel missed the read
    /// (e.g., lock contention caused a timeout, but a later retry wrote the body).
    	@ObservationIgnored nonisolated(unsafe) private var bodyPollTask: Task<Void, Never>?

    /// True while `refetchBody` (pull-to-refresh) is in flight: it deliberately
    /// deletes the durable body + sets `messageBody = nil` to show "Loading…"
    /// until its own fresh server fetch lands. Any OTHER `messageBody == nil`
    /// consumer (`adoptReadyBody`, driven by `.nseMergeDidCommit` or the poll
    /// entry) MUST NOT re-adopt a durable/staged body during that window — doing
    /// so flashes the stale body back and clears the spinner mid-refresh,
    /// defeating the user's explicit refresh. Internal for the guard's unit test.
    @ObservationIgnored var isRefetchingBody = false

    /// Message IDs whose `.messageDataDidChange` notifications arrived while the
    /// global `PreviewFreezeGate` was active. `Set` coalesces duplicate ids so a
    /// burst of notifications during a preview replays as one refresh per id.
    /// Flushed by `flushPendingRefreshes()` when `.previewFreezeReleased` fires.
    @ObservationIgnored private var pendingRefreshIds: Set<String> = []

    /// Set when a wholesale thread-detection re-run must replay on
    /// `.previewFreezeReleased` (same contract as `pendingRefreshIds`): either
    /// `.nseMergeDidCommit` arrived while the `PreviewFreezeGate` was active,
    /// or an in-flight `loadThreadMessagesAsync` hit the frozen gate at its
    /// mutation site (its computed results are discarded, not applied — the
    /// replay recomputes from current DB state). A `Bool` (not a set): the
    /// reload is wholesale.
    @ObservationIgnored private var pendingThreadRefreshOnRelease = false

    /// Monotonic token for `loadThreadMessagesAsync` runs. Each call bumps it;
    /// a completion may apply only if it is newer than the last APPLIED run
    /// (`lastAppliedThreadGeneration`). Needed because detached-query
    /// completions are unordered and an empty result now CLEARS
    /// `threadMessages` — a stale pre-merge empty completing after the
    /// merge-triggered reload would wipe the bubbles it just populated.
    /// Compared against last-APPLIED (not last-started) so that when the
    /// newest run THROWS (transient read error), an older successful result
    /// still applies instead of being discarded with nothing to replace it.
    @ObservationIgnored private var threadLoadGeneration = 0
    /// Generation of the last `loadThreadMessagesAsync` result actually
    /// assigned to `threadMessages`. See `threadLoadGeneration`.
    @ObservationIgnored private var lastAppliedThreadGeneration = 0

    /// Bubble ids the user moved IN PLACE via `updateThreadMessageFolder`
    /// (archive/delete/move keeps the card visible showing its new location
    /// at ACTION time). The pin window is EXACTLY the move OPERATION's
    /// lifetime: set when the in-place mutation happens, removed by
    /// `completeLocalMove` when that op's `enqueueWrite` continuation runs
    /// (the optimistic local DB write has landed). While pinned, reloads
    /// carry the local folder fields (and re-append the card if the fresh
    /// query already excludes it); once un-pinned, the DB is authoritative —
    /// a trashed card drops as on a fresh open, an undone card heals, a
    /// UID-re-keyed row appears only under its new id. Two earlier keyings
    /// were tried and abandoned (ADR-IOS-049 rounds 4–8): view-lifetime
    /// (permanent duplicates under UID re-key, unhealable undo) and
    /// overlay-entry lifetime (the overlay coalesces ONE entry per id, so a
    /// sibling op's drain ended the window early and an undo's own entry
    /// extended it). A REFCOUNT, not a Set: two OVERLAPPING move ops on the
    /// SAME bubble (archive, then delete of the still-visible card) each
    /// pin/un-pin independently — a Set collapsed them, so the first op's
    /// completion ended the window while the second move was still queued.
    @ObservationIgnored private var localMovePins: [String: Int] = [:]

    /// Provider messageId of a notification tap that hasn't resolved to a
    /// composite header id yet (set iff `init` received the sentinel-prefixed
    /// id and the staged snapshot didn't match). Cleared by
    /// `resolveTapIfNeeded` when the ladder resolves and `messageId` is
    /// rewritten to the composite.
    @ObservationIgnored private var pendingProviderTapId: String?
    /// The account the pending notification tap belongs to, decoded from the
    /// sentinel (`notifTap::<accountId>::<providerId>`). Disambiguates the
    /// resolve when the same provider id (an IMAP UID) exists in more than one
    /// account. `nil` for legacy sentinels (`notifTap::<providerId>`) → the
    /// resolve falls back to messageId-only (today's behavior).
    @ObservationIgnored private var pendingTapAccountId: String?
    /// Single-flight resolve for `pendingProviderTapId` — UNSTRUCTURED so a
    /// cancelled `loadBody` (deep-link nav churn cancels `.task`) doesn't kill
    /// the resolve; `markReadOnOpenIfNeeded` awaits the same task.
    @ObservationIgnored private var tapResolveTask: Task<String?, Never>?

    /// Decode a notification-tap sentinel payload (everything after
    /// `notificationTapIdPrefix`) into `(accountId?, providerId)`. New shape is
    /// `<accountId>::<providerId>`; `accountId` is `:`-free (MessageIdentity
    /// contract) so the FIRST `::` is the unambiguous boundary. A payload with
    /// no interior `::` is a legacy account-less sentinel → `(nil, payload)`.
    static func decodeTapSentinel(_ payload: String) -> (accountId: String?, providerId: String) {
        if let sep = payload.range(of: "::") {
            return (String(payload[payload.startIndex..<sep.lowerBound]),
                    String(payload[sep.upperBound...]))
        }
        return (nil, payload)
    }

    /// Pure pop-decision for MailNavigationView's `.notificationTapUnresolved`
    /// handler: pop back to the inbox ONLY when the unresolved id (posted by
    /// the VM whose resolve ladder exhausted) still matches the
    /// currently-pushed message. A stale VM firing late (the user already
    /// navigated elsewhere), a missing selection, or a malformed post must
    /// never pop an unrelated open. Extracted from the `.onReceive` guard so
    /// the decision is unit-testable (audit finding B3 — zero coverage).
    nonisolated static func shouldPopForUnresolvedTap(postedId: String?, selectedId: String?) -> Bool {
        guard let postedId, let selectedId else { return false }
        return postedId == selectedId
    }

    init(messageId: String) {
        self.messageId = messageId
        // ZERO-I/O init (2026-07-03): seed only from the in-memory staged
        // snapshot. This init runs ON THE MAIN ACTOR at tap → view
        // construction, and the previous sync `dbPool.read` here is unbounded
        // under I/O pressure (page faults queue behind whatever the disk is
        // doing — measured ~4.3s MAIN THREAD STALL under an in-flight merge
        // fsync, boot_logs 6). Durable resolution is loadBody's async chain
        // (PK → cross-folder/rfc822 → server-sync fallback), which populates
        // `message` moments later; the view shows the loading skeleton until
        // then. `markReadOnOpenIfNeeded` has its own async resolve fallback,
        // and the optimistic overlay (`applyOverlay` on every resolve) keeps
        // a just-toggled isRead correct across the async gap.
        seedAtInit()
        startAIUpdateListener()
        startPreviewFreezeReleasedListener()
        startNSEMergeCommitListener()
        startMessagesStagedListener()
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] VM.init vm=\(ObjectIdentifier(self)) msgId=\(messageId.prefix(40))")
        }
    }

    /// Test-only init that accepts a DatabasePool override and fetch closure.
    /// Must be set before `loadBody()` accesses `dbPool`.
    ///
    /// `observeNotifications` is opt-in (default OFF) so pre-existing
    /// test-init consumers keep their notification-free behavior: with it on,
    /// any cross-suite `.nseMergeDidCommit` (NSE merge tests post `object:
    /// nil` from real merges) would trigger wholesale thread reloads against
    /// the test's seeded state. Tests exercising the merge-commit / refresh
    /// paths pass true — the flag registers ALL of the production init's
    /// listeners (AI-update, freeze-release, merge-commit) because they form
    /// one contract: a merge-commit buffered while the global gate is frozen
    /// needs the release listener to replay, and the AI-update listener's
    /// `applyRefresh` shares the preserve/freeze machinery under test.
    init(
        messageId: String,
        dbPool: DatabasePool,
        fetchBodyOverride: @escaping (MessageHeader) async throws -> Void,
        observeNotifications: Bool = false
    ) {
        self._dbPoolOverride = PrioritizedDatabase(pool: dbPool)
        self._fetchBodyOverride = fetchBodyOverride
        self.messageId = messageId
        seedAtInit()
        if observeNotifications {
            startAIUpdateListener()
            startPreviewFreezeReleasedListener()
            startNSEMergeCommitListener()
            startMessagesStagedListener()
        }
    }

    /// Zero-I/O init seed, shared by both inits. Handles the two id shapes:
    /// - Sentinel-prefixed notification tap (`notifTap::<providerId>`): match
    ///   the staged snapshot by PROVIDER id — a fresh push usually hits here
    ///   (the NSE staged it before notifying) and resolves instantly; a miss
    ///   leaves `pendingProviderTapId` for the async ladder.
    /// - Composite header id: match the staged snapshot as before.
    private func seedAtInit() {
        if messageId.hasPrefix(Self.notificationTapIdPrefix) {
            let payload = String(messageId.dropFirst(Self.notificationTapIdPrefix.count))
            let (tapAccountId, providerId) = Self.decodeTapSentinel(payload)
            let stagedRow = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.first {
                    $0.messageId == providerId && (tapAccountId == nil || $0.accountId == tapAccountId)
                }
            }
            if var m = stagedRow?.toMessageHeader() {
                applyOverlay(to: &m)
                self.message = m
                self.messageId = m.id
            } else {
                self.pendingProviderTapId = providerId
                self.pendingTapAccountId = tapAccountId
            }
        } else if var m = stagedRowFallback(compositeId: messageId) {
            applyOverlay(to: &m)
            self.message = m
        }
    }

    /// Resolve a pending notification-tap provider id to a composite header id
    /// and rewrite `messageId`. Returns false only when the full ladder
    /// (indexed durable read → bounded staged/durable poll → merge fallback)
    /// exhausts — the message is genuinely gone. Single-flight: concurrent
    /// callers (`loadBody`, `markReadOnOpenIfNeeded`) share one ladder run.
    /// No-op (true) when nothing is pending.
    private func resolveTapIfNeeded() async -> Bool {
        guard let providerId = pendingProviderTapId else { return true }
        let accountId = pendingTapAccountId
        let task: Task<String?, Never>
        if let existing = tapResolveTask {
            task = existing
        } else {
            let waitSeconds = _tapResolveWaitSecondsOverride ?? SyncConfig.notifTapStagedResolveWaitSeconds
            let pollMs = _tapResolvePollMsOverride ?? SyncConfig.notifTapStagedResolvePollMs
            let t = Task {
                await Self.resolveProviderTap(providerId, accountId: accountId, waitSeconds: waitSeconds, pollMs: pollMs)
            }
            tapResolveTask = t
            task = t
        }
        let composite = await task.value
        // Seeded elsewhere while the ladder ran (`seedFromStagedPublish` cleared
        // the pending state and rewrote `messageId`)? Then the open is already
        // resolved — a nil ladder result must NOT flip it to Not-Found.
        guard pendingProviderTapId != nil else { return true }
        guard let composite else { return false }
        self.messageId = composite
        self.pendingProviderTapId = nil
        return true
    }

    /// The notification-tap resolve ladder (moved from
    /// `MailNavigationView.handleNotificationDeepLink`, which now pushes the
    /// detail view IMMEDIATELY instead of blocking navigation on this — the
    /// skeleton is on screen while it runs). The push payload's `messageId` is
    /// the PROVIDER id (Gmail id / Graph id / IMAP UID), not the composite
    /// `MessageHeader.id`. Scoped to `isInInbox=true` — the tap always means
    /// "open the inbox row".
    ///
    /// Tiers (marks preserved from the old handler for log continuity):
    /// 1. staged snapshot (in-memory, instant),
    /// 2. durable indexed lookup (rawPool — PrioritizedDatabase.read would run
    ///    the read-through staging merge first, re-introducing the wait),
    /// 2.5 bounded re-poll of both (a foreground-return tap races the
    ///    tap-kicked merge's snapshot publish by ~100ms — and the
    ///    `.messagesStaged` seed observer covers the open independently the
    ///    instant the publish lands, so this poll is defense, not the gate),
    /// 3. merge fallback (rare — no merge in flight ever read staging).
    ///
    /// NO staging-FILE tier here (removed 2026-07-07): a direct file read
    /// resolves the id BEFORE the merge publishes the in-memory snapshot, so
    /// every downstream snapshot consumer (header seed, mark-read, staged body)
    /// then misses — racing the publish starves the reveal. Consumers read the
    /// snapshot; the merge is its only publisher (ADR-IOS-049).
    nonisolated static func resolveProviderTap(
        _ providerId: String,
        accountId: String? = nil,
        waitSeconds: TimeInterval = SyncConfig.notifTapStagedResolveWaitSeconds,
        pollMs: Int = SyncConfig.notifTapStagedResolvePollMs
    ) async -> String? {
        let t0 = CFAbsoluteTimeGetCurrent()
        func mark(_ tier: String, hit: Bool) {
            BootProfiler.mark("notifTap: resolved via \(tier) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (hit=\(hit))")
        }
        // accountId disambiguates the same provider id (an IMAP UID is a
        // per-mailbox small integer → COLLIDES across accounts) so account A's
        // push never opens account B's message. `nil` (legacy sentinel) →
        // messageId-only match, today's behavior.
        func stagedMatch() -> String? {
            NSEDataBridge.latestStagedRows.withLock { rows in
                rows.first {
                    $0.messageId == providerId && (accountId == nil || $0.accountId == accountId)
                }?.headerId
            }
        }
        @Sendable func durableMatch(_ db: Database) throws -> String? {
            var request = MessageHeader
                .filter(Column("messageId") == providerId && Column("isInInbox") == true)
            if let accountId { request = request.filter(Column("accountId") == accountId) }
            return try request.fetchOne(db)?.id
        }
        if let id = stagedMatch() { mark("staged", hit: true); return id }
        if let id = (try? await AppDatabase.rawPool.read(durableMatch)) ?? nil {
            mark("durable", hit: true)
            return id
        }
        let deadline = CFAbsoluteTimeGetCurrent() + waitSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(for: .milliseconds(pollMs))
            if let id = stagedMatch() { mark("stagedWait", hit: true); return id }
            if let id = (try? await AppDatabase.rawPool.read(durableMatch)) ?? nil {
                mark("stagedWait", hit: true)
                return id
            }
        }
        await NSEDataBridge.mergeNSEStagingData()
        let id = (try? await AppDatabase.dbPool.read(durableMatch)) ?? nil
        mark("mergeFallback", hit: id != nil)
        return id
    }

    deinit {
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] VM.deinit vm=\(ObjectIdentifier(self))")
        }
        if let obs = aiUpdateObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = previewFreezeReleasedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = nseMergeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = messagesStagedObserver { NotificationCenter.default.removeObserver(obs) }
        bodyPollTask?.cancel()
    }

    #if DEBUG
    /// Test seam: seed `message` directly. `init` is zero-I/O (staged snapshot
    /// only), so move/read tests that need a focused message set it here
    /// instead of driving the full async `loadBody` resolve.
    func _testSeedMessage(_ msg: MessageHeader) {
        self.message = msg
    }
    #endif

    /// Listen for AI processing completion and refresh the message in-place.
    /// Ensures SummaryBubbleView updates from "Analyzing..." to actual content
    /// when the background AI task (probe or LLM) finishes writing to DB.
    private func startAIUpdateListener() {
        let obs = NotificationCenter.default.addObserver(
            forName: .messageDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let updatedId = notification.object as? String else { return }
            Task { @MainActor in
                // Preview freeze: while the QL PDF preview is on screen, don't mutate
                // observable state (would cascade through MessageCardView → QL).
                // Buffer the id; release will replay via `flushPendingRefreshesIfNeeded`.
                if PreviewFreezeGate.shared.isFrozen {
                    self.pendingRefreshIds.insert(updatedId)
                    return
                }
                await self.applyRefresh(for: updatedId)
            }
        }
        aiUpdateObserver = obs
    }

    /// Listen for the NSE merge committing staged rows to GRDB. A quick-rendered
    /// open (ADR-IOS-049: header/body synthesized from the in-memory staged
    /// snapshot) ran thread detection BEFORE the merge wrote the header +
    /// reference-junction rows, so related messages came up empty — they simply
    /// weren't queryable yet. When the merge lands (phase-1 surface and
    /// end-of-merge), re-run thread detection so the related-message bubbles
    /// appear (the focused header is deliberately NOT re-read here — see
    /// `refreshAfterMergeCommit`). Bounded: at most two posts per merge wake,
    /// and merges only run on push/foreground/boot.
    private func startNSEMergeCommitListener() {
        let obs = NotificationCenter.default.addObserver(
            forName: .nseMergeDidCommit,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Preview freeze: same buffering contract as the
                // `.messageDataDidChange` observer — replay on release.
                if PreviewFreezeGate.shared.isFrozen {
                    self.pendingThreadRefreshOnRelease = true
                    return
                }
                self.refreshAfterMergeCommit()
            }
        }
        nseMergeObserver = obs
    }

    /// The merge-commit refresh: re-run thread detection against the rows the
    /// merge just made queryable. Deliberately does NOT re-read the focused
    /// header: phase-1 writes header-ONLY rows (AI fields nil, ADR-IOS-047),
    /// so an `applyRefresh` here would REGRESS a staged-synthesized `message`
    /// that already carries the NSE's summary/action tag — the summary bubble
    /// would flash back to "Analyzing…" until phase 2 lands. AI-field updates
    /// reach the open view via the existing `.messageDataDidChange` observer.
    @MainActor
    private func refreshAfterMergeCommit() {
        // Body catch-up (boot_logs 8, 2026-07-05): a notification-tap open whose
        // loadBody got cancelled defers body-load to `startBodyPoll`, whose entry
        // fast-paths (durable read + staged snapshot) can BOTH miss when a FAST
        // merge writes the body and drains staging in the narrow window between
        // the poll's entry check and the body commit — stranding the body on the
        // fixed 2s poll cadence (measured ~2.6s open-lag: body durable at +…960ms
        // but not shown until the +…989ms poll tick). This end-of-merge signal
        // fires the instant the merge makes the body durable, so adopt it NOW,
        // event-driven. Body-only (never the header — see this method's doc
        // above): a nil → content transition is additive and cannot regress the
        // staged-synthesized AI fields. `adoptReadyBody` owns the adoption
        // invariants at its post-await mutation site (body still missing, not mid
        // pull-to-refresh) and re-runs no thread detection — the tail
        // `loadThreadMessagesAsync()` below is the SINGLE scan for this post.
        // DURABLE-ONLY (allowStagedFallback: false, round-4 audit): this fires at
        // BOTH the phase-1 and end-of-merge posts, and phase-1 precedes the phase-2
        // body write — adopting display-only STAGED bytes there would end the
        // still-running persisting poll on a body that isn't durable yet (no
        // hasBody/FTS/AI if phase-2 then fails). Adopt only once the body is
        // durable; the end-of-merge post (or the poll) covers it.
        if messageBody == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.adoptReadyBody(source: "merge-commit catch-up", allowStagedFallback: false)
            }
        }
        loadThreadMessagesAsync()
    }

    /// Listen for the merge PUBLISHING the in-memory staged snapshot
    /// (`.messagesStaged` fires right after `latestStagedRows`/`latestStagedBodies`
    /// are replaced, BEFORE the slow durable write — the same signal the inbox's
    /// `insertStagedRows` consumes). A notification tap races this publish: the
    /// tap's `seedAtInit` + resolve ladder read the snapshot BEFORE the tap-kicked
    /// merge publishes it (~100ms later), so every in-memory tier misses, the
    /// header stays nil, and the skeleton pulses until some unrelated later event
    /// sets it (boot_logs 7: the durable merge / AI write, seconds later). React
    /// to the publish instead of racing it: the instant the snapshot is fresh,
    /// seed the header (+ body + read-flip) from it. Zero I/O — reads only the
    /// just-published in-memory snapshot.
    private func startMessagesStagedListener() {
        let obs = NotificationCenter.default.addObserver(
            forName: .messagesStaged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.seedFromStagedPublish()
            }
        }
        messagesStagedObserver = obs
    }

    /// Seed the focused header from the just-published staged snapshot when the
    /// open is still header-less. Two id shapes (mirrors `seedAtInit`):
    /// - Pending sentinel tap: match by PROVIDER id, account-scoped.
    /// - Resolved composite (resolve landed but `loadBody`'s durable header read
    ///   was cancelled / missed — the row isn't durable until the merge's write):
    ///   match via `stagedRowFallback`.
    /// No-op whenever `message` is already set — a durable-loaded header is never
    /// clobbered by staged bytes (durable-first invariant). No freeze-gate check:
    /// `message == nil` means the skeleton is on screen, so no attachment preview
    /// can be frozen (same rationale as `adopt`).
    @MainActor
    private func seedFromStagedPublish() async {
        guard message == nil else { return }
        var seeded: MessageHeader?
        if let providerId = pendingProviderTapId {
            let row = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.first {
                    $0.messageId == providerId
                        && (pendingTapAccountId == nil || $0.accountId == pendingTapAccountId)
                }
            }
            seeded = row?.toMessageHeader()
        } else {
            // EXACT headerId match ONLY — deliberately NOT `stagedRowFallback`,
            // whose fuzzy accountId+messageId arm ignores folderPath: a normal
            // open of an IMAP Archive message (`acc:Archive:N`) in its skeleton
            // window would match a just-pushed INBOX message with the same UID
            // (`acc:INBOX:N`), and this seed REWRITES `messageId` + marks read —
            // sticky wrong identity + wrong message read-flipped (review round,
            // 2026-07-07). The composite branch only serves the resolved-tap
            // case, where `messageId` IS the staged row's headerId — exact match
            // is sufficient. (`seedAtInit`'s fuzzy match stays display-only and
            // self-heals via loadBody's durable resolve; this one must be exact.)
            seeded = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.first { $0.headerId == messageId }
            }?.toMessageHeader()
        }
        guard var m = seeded else { return }
        applyOverlay(to: &m)
        // Skeleton → content: dissolve (same rule as loadBody's assignment).
        withAnimation(Theme.detailContentDissolve) { message = m }
        messageId = m.id
        pendingProviderTapId = nil
        pendingTapAccountId = nil
        messageNotFound = false
        BootProfiler.mark("detail header seeded on .messagesStaged publish \(m.id.prefix(24))")
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] seedFromStagedPublish vm=\(ObjectIdentifier(self)) id=\(m.id.prefix(40))")
        }
        // Read-flip: `markReadOnOpenIfNeeded` ran on open but bailed — its resolve
        // found neither a durable row (not merged) nor a staged one (snapshot was
        // empty pre-publish). Re-arm it now that `message` is set; its fast path
        // flips isRead + registers the overlay + enqueues the durable write.
        markReadOnOpenCalled = false
        await markReadOnOpenIfNeeded()
        // Body: `latestStagedBodies` is fresh at the same publish — adopt the
        // staged body for display (durable-first inside `adoptReadyBody`; the
        // merge's phase-2 persists the same bytes). On a miss (body not staged,
        // e.g. CID-excluded) the poll's server fetch owns it — and it NEEDS the
        // header we just seeded (its fetch step guards on `self.message`).
        if await adoptReadyBody(source: "staged-publish seed") {
            loadThreadMessagesAsync()
        } else if messageBody == nil {
            startBodyPoll()
        }
    }

    /// Layer the AccountManager optimistic overlay on top of a DB-derived header.
    /// Mirrors `InboxViewModel.applyOverlay` so the detail view doesn't revert
    /// pending user mutations (e.g. mark-read on open) when a DB re-read races
    /// the queued local write. Without this, every site that re-reads
    /// `MessageHeader` from GRDB can clobber `self.message?.isRead = true` back
    /// to the stale `isRead = false` until the `enqueueWrite { markRead }`
    /// drain commits — visible as the unread dot persisting in the detail view
    /// while the inbox row (which does layer overlay) already shows read.
    ///
    /// Display-only fields only — `folderId`/`folderPath` are intentionally
    /// excluded because the detail view's body fetch + AI processing use those
    /// to address the IMAP folder, and an optimistic move's overlay points at
    /// the destination before the message has physically been moved there.
    private func applyOverlay(to header: inout MessageHeader) {
        let overlay = manager.snapshotOverlay()
        guard let mutation = overlay[header.id] else { return }
        if let v = mutation.isRead { header.isRead = v }
        if let v = mutation.isFlagged { header.isFlagged = v }
        if let v = mutation.actionTag { header.actionTag = v }
        if let v = mutation.isInInbox { header.isInInbox = v }
    }

    private func applyOverlay(to headers: inout [MessageHeader]) {
        let overlay = manager.snapshotOverlay()
        guard !overlay.isEmpty else { return }
        for i in headers.indices {
            guard let mutation = overlay[headers[i].id] else { continue }
            if let v = mutation.isRead { headers[i].isRead = v }
            if let v = mutation.isFlagged { headers[i].isFlagged = v }
            if let v = mutation.actionTag { headers[i].actionTag = v }
            if let v = mutation.isInInbox { headers[i].isInInbox = v }
        }
    }

    /// Re-reads the message (and thread entry if matched) from GRDB after a
    /// `.messageDataDidChange` notification. Extracted from the observer so the
    /// same logic can be replayed when preview-freeze is released.
    @MainActor
    private func applyRefresh(for updatedId: String) async {
        let originalId = self.messageId
        // Update main message if it matches
        if updatedId == originalId || updatedId == self.message?.id {
            let rid = self.resolvedId
            if var updated = try? await self.dbPool.read({ db in try MessageHeader.fetchOne(db, key: rid) }) {
                // Freeze re-check at the mutation site: a preview can begin
                // during the awaited read above. Re-buffer instead of mutating
                // @Observable state under the frozen gate.
                if PreviewFreezeGate.shared.isFrozen {
                    self.pendingRefreshIds.insert(updatedId)
                    return
                }
                applyOverlay(to: &updated)
                self.message = updated
            }
        }

        // Update thread message if it matches (fixes "Analyzing..." stuck forever
        // when AI completes after thread detection snapshot was taken)
        if self.threadMessages.contains(where: { $0.id == updatedId }) {
            if var updated = try? await self.dbPool.read({ db in try MessageHeader.fetchOne(db, key: updatedId) }) {
                if PreviewFreezeGate.shared.isFrozen {
                    self.pendingRefreshIds.insert(updatedId)
                    return
                }
                applyOverlay(to: &updated)
                // Re-find the index AFTER the awaited read: a merge-commit
                // wholesale reload (including clear-on-empty) can replace or
                // shrink `threadMessages` during the suspension — a stale
                // index would subscript out of bounds or overwrite the wrong
                // row.
                if let idx = self.threadMessages.firstIndex(where: { $0.id == updatedId }) {
                    // Field-level move preserve: AI/display fields always flow
                    // from the fresh row; local folder fields survive only
                    // while the move op is in flight (see preservingLocalMove).
                    self.threadMessages[idx] = self.preservingLocalMove(
                        fresh: updated, current: self.threadMessages[idx]
                    )
                }
            }
        }
    }

    /// Field-level preserve for a locally-moved thread bubble
    /// (`localMovePins`). While the move op is in flight (pin present
    /// — see `completeLocalMove` for the window's exact bounds) the DB row
    /// still shows the pre-move folder, so the local folder fields
    /// (`folderPath`/`folderId`/`isInInbox`) are carried onto the fresh row —
    /// but AI/display fields flow from the DB (a whole-row pin starved pinned
    /// bubbles of AI updates: "Analyzing…" stuck forever). Un-pinned rows
    /// pass through untouched: the DB is authoritative once the op executed.
    private func preservingLocalMove(
        fresh: MessageHeader,
        current: MessageHeader
    ) -> MessageHeader {
        guard localMovePins[fresh.id] != nil else { return fresh }
        var merged = fresh
        merged.folderPath = current.folderPath
        merged.folderId = current.folderId
        merged.isInInbox = current.isInInbox
        return merged
    }

    /// Listen for the `PreviewFreezeGate` release signal so any
    /// `.messageDataDidChange` notifications that arrived during the freeze get
    /// replayed against current DB state — no update is dropped, only coalesced
    /// (Set semantics) and deferred.
    private func startPreviewFreezeReleasedListener() {
        let obs = NotificationCenter.default.addObserver(
            forName: .previewFreezeReleased,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Re-check the SHARED gate before consuming the buffers: a
                // release post can arrive while the gate is (still or again)
                // frozen — e.g. a non-shared `PreviewFreezeGate` instance's
                // `end()` posts the same global notification, or a new preview
                // begins between the post and this hop. Consuming here would
                // silently drop the buffered refreshes; leave them for the
                // next genuine release instead.
                guard !PreviewFreezeGate.shared.isFrozen else { return }
                let ids = self.pendingRefreshIds
                let threadRefresh = self.pendingThreadRefreshOnRelease
                guard !ids.isEmpty || threadRefresh else { return }
                self.pendingRefreshIds.removeAll()
                self.pendingThreadRefreshOnRelease = false
                if DebugModeManager.isLoggingEnabled() {
                    print("[PreviewFreeze] flushing \(ids.count) buffered .messageDataDidChange ids (threadRefresh=\(threadRefresh))")
                }
                var remaining = Array(ids)
                while let id = remaining.popLast() {
                    // A NEW preview can begin during an awaited applyRefresh —
                    // re-buffer the unapplied remainder (this id included)
                    // instead of mutating @Observable state under the
                    // re-frozen gate; the next release replays it.
                    if PreviewFreezeGate.shared.isFrozen {
                        self.pendingRefreshIds.formUnion(remaining + [id])
                        if threadRefresh { self.pendingThreadRefreshOnRelease = true }
                        return
                    }
                    await self.applyRefresh(for: id)
                }
                if threadRefresh {
                    // A preview may have begun during the LAST applyRefresh's
                    // await — re-buffer instead of launching a thread query
                    // whose result would only be discarded and re-buffered at
                    // the mutation site anyway.
                    if PreviewFreezeGate.shared.isFrozen {
                        self.pendingThreadRefreshOnRelease = true
                    } else {
                        self.refreshAfterMergeCommit()
                    }
                }
            }
        }
        previewFreezeReleasedObserver = obs
    }

    /// One-shot, display-only body adoption from already-available bytes: the
    /// durable `MessageBody` in GRDB, or (on a durable miss) the NSE staged
    /// snapshot. Pure reads — NO server fetch, so it never competes for the IMAP
    /// connection (the risky retry stays on `startBodyPoll`'s 2s cadence).
    /// Body-only: it NEVER touches `self.message`, so it cannot regress a
    /// staged-synthesized header's AI fields (the invariant `refreshAfterMergeCommit`
    /// relies on). Adoption is decided at the MUTATION SITE (`adopt`), AFTER the
    /// awaited read — the caller's pre-await guard is stale by then (a pull-to-
    /// refresh can start, or another path can set the body, during the
    /// suspension). Does NOT re-run thread detection — the caller
    /// owns that, so a merge-commit that also refreshes the thread doesn't scan
    /// twice. Returns true iff a body was adopted. Shared by `startBodyPoll`'s
    /// entry check and the `.nseMergeDidCommit` catch-up; `source` labels the
    /// boot-timeline mark so the two entry points stay distinguishable.
    /// `allowStagedFallback` (default true) controls the durable-miss branch:
    /// the entry / merge-commit callers want the in-memory staged bytes for an
    /// instant DISPLAY (the merge that staged them persists the durable row in
    /// phase 2). The 2s POLL loop passes `false` — a staged adoption is
    /// display-only and would END the poll before its server-fetch branch (the
    /// only path that PERSISTS a durable MessageBody), so a durable miss must
    /// fall through to that fetch, leaving hasBody/FTS/AI intact (round-3 audit).
    @MainActor
    @discardableResult
    func adoptReadyBody(source: String, allowStagedFallback: Bool = true) async -> Bool {
        let rid = resolvedId
        // `dbPool.pool` (raw pool), NOT `dbPool.read`: same reason as loadBody's cache-check —
        // the read-through merge would block this durable read behind an in-flight merge and
        // defeat the staged fallback below. Raw read = durable body instantly, else nil-fast
        // → staged fallback. `.pool` (not `AppDatabase.rawPool`) keeps `_dbPoolOverride` honored.
        if let body = try? await dbPool.pool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
            return adopt(body, source: source, rid: rid, mark: "detail body via \(source)")
        }
        if allowStagedFallback, let stagedBody = NSEDataBridge.stagedBodyFallback(headerId: rid) {
            return adopt(stagedBody, source: source, rid: rid, mark: "detail body from STAGED snapshot (\(source))")
        }
        return false
    }

    /// Mutation-site adoption: re-verify the invariants that `adoptReadyBody`'s
    /// awaited read may have invalidated, then adopt for display. Bails (false,
    /// no mutation) if the body already landed via another path, or a pull-to-
    /// refresh is in flight (it owns the body until its fresh fetch lands). No
    /// `PreviewFreezeGate` check: adoption's `messageBody == nil` precondition
    /// means no body is rendered in this view, so no attachment preview can be
    /// on screen to have frozen the gate (round-2 audit — the freeze re-check
    /// added in round 1 guarded an unreachable state; the merge-commit path is
    /// additionally freeze-gated at the `.nseMergeDidCommit` observer).
    @MainActor
    private func adopt(_ body: MessageBody, source: String, rid: String, mark: String) -> Bool {
        guard messageBody == nil, !isRefetchingBody else { return false }
        messageBody = body
        isLoading = false
        error = nil
        BootProfiler.mark("\(mark) \(rid.prefix(24))")
        if DebugModeManager.isLoggingEnabled() {
            print("[MessageDetail] Body adopted (\(source)) for \(rid.prefix(40)) vm=\(ObjectIdentifier(self))")
            print("[DetailRender] adopt id=\(rid.prefix(40)) html=\(body.htmlContent?.count ?? -1) att=\(body.attachments.count) ics=\(body.icsText?.count ?? -1)")
        }
        return true
    }

    /// Header recovery for the poll (the designated un-cancelled recovery
    /// task): a cancelled `loadBody` (`CANCELLED (initial read) → poll`)
    /// latches `loadBodyCalled` and never runs the header-resolve ladder, and
    /// for a NON-staged open (e.g. chat email pill → composite id of an older
    /// message) `seedAtInit`/`seedFromStagedPublish` can't seed either — so
    /// nothing sets `message`, and the detail view's skeleton (gated on the
    /// HEADER) pulses forever (boot_logs 8, +4026513/+4058827). Resolve the
    /// same way the cancelled `loadBody` would have (PK → cross-folder →
    /// rfc822 → staged fallback via `resolveMessageAsync`), then seed for
    /// display. Body-only recovery stays `adoptReadyBody`'s job — its
    /// header-untouched contract is load-bearing for `refreshAfterMergeCommit`.
    @MainActor
    private func recoverHeaderIfMissing() async {
        guard message == nil, pendingProviderTapId == nil else { return }
        guard var m = await resolveMessageAsync(compositeId: messageId) else { return }
        // Re-check across the await: a concurrent path (staged-publish seed,
        // merge-commit refresh) may have set the header while we read.
        guard message == nil else { return }
        applyOverlay(to: &m)
        // Skeleton → content dissolve, same as loadBody/seedFromStagedPublish.
        withAnimation(Theme.detailContentDissolve) { message = m }
        messageNotFound = false
        BootProfiler.mark("detail header recovered via poll \(m.id.prefix(24))")
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] header recovered vm=\(ObjectIdentifier(self)) id=\(m.id.prefix(40)) messageSet=\(message != nil)")
        }
        // Body-adoption's thread load no-ops while `message` is nil — re-run
        // now that the header exists.
        if messageBody != nil {
            loadThreadMessagesAsync()
        }
    }

    /// Poll for MessageBody while body is missing. First checks DB (catches cases
    /// where a background path wrote the body), then re-attempts a server fetch.
    /// Primary scenario: app resumed from background with stale IMAP connection —
    /// loadBody() fails before a fresh pool connection is established. The poll
    /// retries after the connection pool self-heals.
    /// Unbounded: runs until body arrives, user navigates away (Task cancelled),
    /// or ViewModel is deallocated (weak self).
    /// Internal (not `private`) so tests can drive the immediate-cache path
    /// directly — `@testable import` cannot reach `private` members.
    func startBodyPoll() {
        bodyPollTask?.cancel()
        bodyPollTask = Task { [weak self] in
            // IMMEDIATE cache check, BEFORE the first 2s sleep. On the
            // notification-tap deep-link path the body is usually ALREADY in the DB
            // (the deep-link's own NSE merge wrote it) — loadBody just got cancelled
            // by the inbox-reload/navigation re-render churn during its initial read
            // (GRDB throws CancellationError on async reads in a cancelled task), so
            // it deferred here. This independent, un-cancelled task can read it NOW
            // and render at once instead of waiting 2s on a body that's already
            // present. Pure DB read — NO server fetch, so it doesn't compete for the
            // IMAP connection (the risky retry path stays on the 2s cadence below).
            if let self, self.messageBody == nil {
                // Cancelled-open header recovery FIRST (see recoverHeaderIfMissing) —
                // ordered before body adoption so the adopt-and-return below cannot
                // end the poll with a nil header (skeleton is gated on the header).
                await self.recoverHeaderIfMissing()
                // Entry fast-path (shared with the `.nseMergeDidCommit` catch-up):
                // the deep-link's own NSE merge usually wrote the body (durable or
                // still-staged, ADR-IOS-049) before loadBody's task got cancelled
                // by the inbox-reload/nav churn and deferred here — adopt it NOW
                // instead of waiting on the first 2s tick.
                if await self.adoptReadyBody(source: "poll IMMEDIATE check") {
                    self.loadThreadMessagesAsync()
                    if self.message != nil { return }
                    // Body adopted but the header is still missing (cancelled
                    // non-staged open): fall into the loop, which keeps
                    // recovering the header until it lands.
                }
            }
            var fetchAttempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if self.message == nil { await self.recoverHeaderIfMissing() }
                guard self.messageBody == nil else {
                    // Body already landed (entry fast-path above, merge-commit
                    // catch-up, …): the poll's only remaining job is the header
                    // (cancelled-open recovery) — done once it's set.
                    if self.message != nil { return }
                    continue
                }
                // Pull-to-refresh (refetchBody) owns the body for its window — it
                // deletes the durable row, nils messageBody, and runs its OWN fetch.
                // Skip this whole tick so the poll neither adopts/flashes a body nor
                // competes with refetch's IMAP fetch, and STAY ALIVE to resume next
                // tick. The poll is NOT cancelled, so it needs no restart (rounds
                // 2-5: cancelling+restarting resurrected stale staged bytes and
                // dropped the retry on the not-found early return; skipping ticks is
                // the simple provably-correct version).
                guard !self.isRefetchingBody else { continue }
                let rid = self.resolvedId
                // 1. Body appeared in DB (written by another path) — adopt via the
                // shared mutation-site helper. DURABLE-ONLY (allowStagedFallback:
                // false): a staged adoption is display-only and would end the poll
                // before the persisting server fetch below (round-3 audit) — a
                // durable miss must fall through so hasBody/FTS/AI get a real body.
                if await self.adoptReadyBody(source: "poll (DB, 2s cadence)", allowStagedFallback: false) {
                    self.loadThreadMessagesAsync()
                    return
                }
                // `adoptReadyBody` returns false EITHER on a durable miss OR because
                // `adopt` bailed on a concurrent set (e.g. the merge-commit catch-up
                // won the durable read during step-1's await). Only the former should
                // fall through to the server fetch — re-check so a body that already
                // landed doesn't trigger a redundant IMAP round-trip on the serial
                // folder lock (round-6 audit).
                guard self.messageBody == nil else { return }
                // The loop-top `!isRefetchingBody` (above) goes STALE across step-1's
                // await: a pull-to-refresh that began during that read now owns the
                // body and is running its OWN fetch. Re-check before starting ours so
                // we don't compete on the serial folder connection lock ("cannot
                // connect", cf. loadBody). `continue` (not `return`) keeps the poll
                // alive to resume after the refresh (round-7 audit). Residual: a
                // refresh that begins DURING the fetch below still competes for one
                // round-trip (`manager.fetchBody` is not cancellable); the post-fetch
                // mutation-site guard skips our write and the loop-top guard blocks
                // every subsequent tick.
                guard !self.isRefetchingBody else { continue }
                // 2. Re-attempt server fetch (connection may have recovered)
                guard let msg = self.message else { continue }
                fetchAttempt += 1
                print("[MessageDetail] Poll fetch attempt \(fetchAttempt) for \(rid.prefix(40))")
                do {
                    try await self.manager.fetchBody(for: msg)
                    // Read BOTH the fetched body AND the refreshed header, THEN gate
                    // on a single mutation-site `!isRefetchingBody` and write
                    // SYNCHRONOUSLY — there is no `await` between the guard and the
                    // `return`, so a concurrent pull-to-refresh cannot interleave to
                    // clobber the body or blank the header (round-4/5 audit: guarding
                    // BEFORE the reads left a window; a refresh that begins during the
                    // fetch/reads bails us to `continue`, poll stays alive).
                    // `dbPool.pool` (raw), NOT `dbPool.read`: read back what the
                    // server fetch just wrote durably; no reason to block behind
                    // an in-flight merge. Matches loadBody's post-fetch reads.
                    let freshBody = try? await self.dbPool.pool.read({ db in try MessageBody.fetchOne(db, key: rid) })
                    let freshHeader = try? await self.dbPool.pool.read({ db in try MessageHeader.fetchOne(db, key: rid) })
                    guard !self.isRefetchingBody else { continue }
                    if let freshBody {
                        self.messageBody = freshBody
                        self.isLoading = false
                        self.error = nil
                        // Header refresh (AI processing may have updated it)
                        if var refreshed = freshHeader {
                            self.applyOverlay(to: &refreshed)
                            self.message = refreshed
                        } else {
                            self.message = nil
                        }
                        self.loadThreadMessagesAsync()
                        print("[MessageDetail] Body fetched via poll for \(rid.prefix(40))")
                        BootProfiler.mark("detail body via poll SERVER fetch \(rid.prefix(24))")
                        return
                    }
                } catch {
                    print("[MessageDetail] Poll fetch failed (attempt \(fetchAttempt)): \(error)")
                }
            }
        }
    }

    /// Explicit user Retry from the Not-Found screen. `loadBody()` alone is a
    /// permanent no-op after a failed first run — the latches below memoize
    /// the failure and each must be reset for the retry to actually re-run:
    /// - `loadBodyCalled = false`: `loadBody` is single-shot (`.task` +
    ///   `.onAppear` dedup); without this reset the retry's `loadBody()`
    ///   returns on its first line and the user stays on an inert skeleton.
    /// - `tapResolveTask = nil`: the single-flight tap-resolve ladder memoizes
    ///   its result INCLUDING a failed (nil) run — a still-pending
    ///   `pendingProviderTapId` would `await` the same exhausted task and
    ///   instantly re-fail. Clearing it makes the retry run a FRESH ladder
    ///   (the message may have been staged/synced since the first attempt).
    /// - `messageNotFound = false`: swaps the Not-Found screen back to the
    ///   loading skeleton while the retry runs (loadBody re-sets it on a
    ///   genuine repeat failure).
    /// - `markReadOnOpenCalled = false` + the trailing `markReadOnOpenIfNeeded()`:
    ///   on the ORIGINAL tap-exhausted open, the view's `.task`/`.onAppear`
    ///   already invoked `markReadOnOpenIfNeeded()` — it latched true, then
    ///   bailed at its `resolveTapIfNeeded` guard. Those callers sit on the
    ///   stable outer body and never refire, so without this reset a
    ///   successful retry renders the message but the user's implicit
    ///   read-intention is silently dropped (never-drop-user-intention).
    ///   Re-running it after `loadBody()` flips isRead via the fast path; on
    ///   a still-exhausted retry it re-latches and bails at the same guard
    ///   harmlessly. (Same re-arm pattern as `seedFromStagedPublish`.)
    ///
    /// Re-entrancy: guarded by `retryInFlight`. The resets above are
    /// unconditional, so two overlapping invocations (double-tap before the
    /// button leaves screen, or a `.task` re-fire mid-retry) would each start
    /// an independent resolve ladder — and a LOSING duplicate that exhausts
    /// posts `.notificationTapUnresolved` and pops the view even though the
    /// winner resolved. MainActor serializes the flag accesses; the `defer`
    /// releases it whether the retry resolves or exhausts.
    func retryLoad() async {
        guard !retryInFlight else { return }
        retryInFlight = true
        defer { retryInFlight = false }
        loadBodyCalled = false
        messageNotFound = false
        tapResolveTask = nil
        markReadOnOpenCalled = false
        await loadBody()
        await markReadOnOpenIfNeeded()
    }

    func loadBody() async {
        guard !loadBodyCalled else { return }
        loadBodyCalled = true
        // Tap-timeline mark (debug-gated): pairs with "notifTap:" marks so an
        // open-lag decomposes into resolve vs body-load vs render in one file.
        let loadT0 = CFAbsoluteTimeGetCurrent()
        BootProfiler.mark("detail loadBody START \(messageId.prefix(24))")
        if DebugModeManager.isLoggingEnabled() {
            print("[DetailRender] loadBody vm=\(ObjectIdentifier(self)) msgId=\(messageId.prefix(40))")
        }
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
            if ms >= 50 {
                BootProfiler.mark("detail loadBody DONE in \(ms)ms (body=\(messageBody != nil))")
            }
        }

        // Pending notification tap: resolve the PROVIDER id to a composite
        // header id first (single-flight ladder; the skeleton is on screen).
        // On failure the NSE never staged the message AND sync hasn't landed
        // it yet — this branch is only reachable for tap-sentinel opens
        // (resolveTapIfNeeded returns false only when a pendingProviderTapId
        // ladder exhausted). Contract: pop the detail view and land on the
        // inbox instead of stranding the user on Message-Not-Found — the
        // message will appear at the top of the inbox once sync lands
        // seconds later. `MailNavigationView` does the actual pop/nav on
        // `.notificationTapUnresolved`; `messageNotFound`/`isLoading` stay
        // set here as a backstop for the case where that observer isn't
        // mounted (cold-start edge, multi-column layouts) — Not-Found still
        // shows rather than a blank view.
        guard await resolveTapIfNeeded() else {
            print("[MoveTrace] loadBody — notification-tap resolve exhausted for \(messageId)")
            // Pop post only when NOTHING is over or replacing this view.
            // Three independent gates, each covering a case the others can't:
            //  - `isViewVisible` (onAppear/onDisappear) — NAVIGATION-away: a
            //    disappeared VM's late exhaustion (user left mid-ladder, then
            //    re-tapped the SAME notification → a NEWER VM for the
            //    IDENTICAL sentinel resolved) must not pop the newer view —
            //    `shouldPopForUnresolvedTap`'s string equality can't
            //    distinguish VM instances, so instance staleness gates here.
            //  - `hasActivePresentation` — SAME-VIEW covers: sheets and
            //    fullScreenCovers do NOT fire the presenting view's
            //    onDisappear, and popping the detail view force-dismisses
            //    whatever is on top — worst case an OPEN COMPOSE DRAFT
            //    (never-drop-user-intention).
            //  - `PreviewFreezeGate.shared.isFrozen` — IMPERATIVE QuickLook:
            //    presented outside this view's tree (AttachmentListView, top
            //    view controller), invisible to both flags above; the global
            //    freeze gate is its signal.
            // When suppressed, the UNCONDITIONAL `messageNotFound`/`isLoading`
            // below genuinely leave Not-Found + a working Retry underneath /
            // on re-present.
            if isViewVisible && !hasActivePresentation && !PreviewFreezeGate.shared.isFrozen {
                NotificationCenter.default.post(name: .notificationTapUnresolved, object: nil, userInfo: ["messageId": messageId])
            }
            isLoading = false
            messageNotFound = true
            return
        }

        // Resolve message from DB with proper error handling.
        // GRDB 7.x throws CancellationError on async reads when the Task is
        // cancelled (e.g., SwiftUI .task during bg→fg transitions). Using try?
        // would mask this as "not found", so we use do/catch to distinguish.
        var msg: MessageHeader?
        do {
            let mid = messageId
            // `dbPool.pool` (raw), NOT `dbPool.read`: the async `dbPool.read` awaits
            // `mergeIfStagingPending()` first (PriorityGate :203), so it BLOCKS this header
            // resolve behind an in-flight merge — and it runs SEQUENTIALLY before the body
            // read below, so it gates the entire open (the ~5s that preceded the body on a
            // notif-tap, boot_logs 3). The header is already on screen from seedAtInit's
            // staged snapshot; this is the durable refresh, so a nil-fast raw read →
            // resolveMessageAsync (raw + staged fallback) keeps the open off the merge path.
            // `.pool` honors a `_dbPoolOverride` test pool.
            msg = try await dbPool.pool.read { db in try MessageHeader.fetchOne(db, key: mid) }
        } catch is CancellationError {
            print("[MoveTrace] loadBody — task cancelled during initial DB read, deferring to body poll")
            BootProfiler.mark("detail loadBody CANCELLED (initial read) → poll")
            startBodyPoll()
            return
        } catch {
            print("[MoveTrace] loadBody — DB read error: \(error)")
        }
        if msg == nil {
            msg = await resolveMessageAsync(compositeId: messageId)
        }

        // Server fallback: if still not found locally, sync the original folder and retry.
        // Skip if task was cancelled — all async DB reads fail with CancellationError
        // in a cancelled task, so nil doesn't mean "not found".
        if msg == nil && !Task.isCancelled {
            print("[MoveTrace] loadBody — local resolve failed for \(messageId), attempting server sync fallback")
            await syncOriginalFolder()
            msg = await resolveMessageAsync(compositeId: messageId)
        }

        guard let msg else {
            if Task.isCancelled {
                // Task cancelled (e.g., SwiftUI .task during bg→fg transition).
                // Don't mark as "not found" — defer to bodyPoll which runs in an
                // independent Task immune to parent cancellation.
                print("[MoveTrace] loadBody — task cancelled, deferring to body poll")
                BootProfiler.mark("detail loadBody CANCELLED (resolve) → poll")
                startBodyPoll()
                return
            }
            print("[MoveTrace] loadBody — message not found after server fallback: \(messageId)")
            isLoading = false
            messageNotFound = true
            return
        }
        // Apply overlay to a separate copy for UI state — `msg` stays
        // DB-faithful so downstream fetchBody/processOpenedMessage use the
        // real (unmoved) folderPath, not an optimistic overlay value.
        var displayMsg = msg
        applyOverlay(to: &displayMsg)
        if message == nil {
            // Skeleton → content: dissolve (withAnimation at the mutation site,
            // NEVER .animation(_:value:) on the List's ancestors — feedback-loop
            // hang, see UX rules). Later refreshes assign without animation.
            withAnimation(Theme.detailContentDissolve) { message = displayMsg }
        } else {
            message = displayMsg
        }

        // User tap on a message body counts as "accessed" — bump LRU on every
        // asset (kind=0 inline images + kind=1 attachments) belonging to this
        // message so eviction doesn't drop a message the user is actively
        // reading. Single UPDATE in BodyAssetStore's manifest DB; fire-and-forget.
        // This is the SOLE bump site for opened-message access (the WKURLSchemeHandler
        // does NOT bump per-image).
        BodyAssetStore.bumpMessageAccess(headerId: msg.id)

        // Mark-as-read on open lives in `markReadOnOpenIfNeeded()` — called
        // from the view's `.task`/`.onAppear` on its own unstructured Task so
        // that cancellation of this body-load path (GRDB 7.x throws
        // CancellationError on async reads in cancelled Tasks, which the
        // early-return to `startBodyPoll()` above honors) does not skip the
        // read-flip. Body load and read-flip are independent intents.

        // Check if body already loaded (use resolvedId which may differ from messageId)
        let rid = resolvedId
        do {
            // `dbPool.pool` (raw DatabasePool), NOT `dbPool.read`: the read-through
            // `PrioritizedDatabase.read` runs the staging merge FIRST, blocking this body
            // cache-check behind an in-flight merge — measured 7.8s on a notif-tap during
            // the cold-start foreground herd (merge.phase1 stalled 5s, then the read queued
            // behind the fullSync writes). Reading the raw pool: a durable body returns
            // instantly; a not-yet-merged body returns nil FAST so we fall through to the
            // STAGED fallback below (value-identical bytes the merge will commit). Uses
            // `dbPool.pool` (NOT `AppDatabase.rawPool`) so a `_dbPoolOverride` test pool is
            // still honored. Mirrors `resolveProviderTap`, whose tiers rawPool for this reason.
            if let existingBody = try await dbPool.pool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
                // Body already loaded — trigger priority AI processing if needed.
                // Matches TB's onMessagesDisplayed direct path: when user opens a message
                // with a body but missing AI state, process immediately (bypasses queue).
                BootProfiler.mark("detail body CACHE HIT \(rid.prefix(24))")
                messageBody = existingBody
                isLoading = false
                Task { await manager.enqueueWrite { [manager] in
                    await manager.processOpenedMessage(msg)
                }}
                loadThreadMessagesAsync()
                return
            }
        } catch is CancellationError {
            print("[MoveTrace] loadBody — task cancelled during body check, deferring to body poll")
            BootProfiler.mark("detail loadBody CANCELLED (body check) → poll")
            startBodyPoll()
            return
        } catch {
            print("[MoveTrace] loadBody — body read error: \(error)")
        }
        // ADR-IOS-049 (notification tap): GRDB missed, but the NSE already
        // fetched + rendered this body into staging — synthesize it for DISPLAY
        // now instead of waiting on phase-2's durable write (1.5–5.6s measured
        // under backfill I/O), the 2s body-poll cadence, or a needless network
        // re-fetch. Durability stays phase-2's job; the staged bytes are the
        // SAME ones it will commit, so the later durable row is value-identical
        // (no poll needed — AI-field refreshes reach the open detail view via
        // the existing `.messageDataDidChange` observers).
        if let stagedBody = NSEDataBridge.stagedBodyFallback(headerId: rid) {
            BootProfiler.mark("detail body from STAGED snapshot (phase-2 not durable yet) \(rid.prefix(24))")
            messageBody = stagedBody
            isLoading = false
            Task { await manager.enqueueWrite { [manager] in
                await manager.processOpenedMessage(msg)
            }}
            loadThreadMessagesAsync()
            return
        }
        // If the body queue is already fetching this message, don't compete for the
        // IMAP connection — just poll until the background fetch completes. Competing
        // causes "cannot connect" errors because the folder connection is locked.
        let queuedInBackground = await ActiveBodyQueue.shared.isQueuedOrInFlight(headerId: rid)
        if queuedInBackground {
            print("[MessageDetail] Body in-flight via background queue — polling for \(rid.prefix(40))")
            isLoading = true
            startBodyPoll()
            return
        }

        isLoading = true
        BootProfiler.mark("detail body MISS everywhere → SERVER fetch \(rid.prefix(24))")
        do {
            if let override = _fetchBodyOverride {
                try await override(msg)
            } else {
                try await fetchBodyWithRetry(for: msg)
            }
        } catch is CancellationError {
            print("[MoveTrace] loadBody — task cancelled during fetch, deferring to body poll")
            BootProfiler.mark("detail loadBody CANCELLED (fetch) → poll")
            startBodyPoll()
            return
        } catch {
            if !SyncEngine.isConnectionError(error) {
                self.error = error.localizedDescription
            }
        }
        isLoading = false

        // Refetch message in case AI processing updated it during body fetch.
        // `dbPool.pool` (raw), NOT `dbPool.read`: these read back what the server
        // fetch above just wrote durably — no reason to block behind an in-flight
        // merge (`PrioritizedDatabase.read` awaits `mergeIfStagingPending` first).
        // Matches the header/body-cache reads at the top of `loadBody`.
        let postFetchId = resolvedId
        if var refreshed = try? await dbPool.pool.read({ db in try MessageHeader.fetchOne(db, key: postFetchId) }) {
            applyOverlay(to: &refreshed)
            message = refreshed
        } else {
            message = nil
        }
        messageBody = try? await dbPool.pool.read { db in try MessageBody.fetchOne(db, key: postFetchId) }
        loadThreadMessagesAsync()

        // If body is still nil after all attempts, start polling as a safety net.
        // Covers: connection errors (where self.error stays nil), lock timeouts,
        // or any transient failure. A reconnect or background path may still
        // write the body to DB later.
        if messageBody == nil {
            startBodyPoll()
        }
    }

    func refetchBody() async {
        // Guard the whole refresh window: from the durable-row delete + in-memory
        // `messageBody = nil` below until the fresh fetch lands, a concurrent
        // `.nseMergeDidCommit` catch-up must NOT re-adopt a body (`adopt`), and a
        // running `startBodyPoll` skips its ticks (loop-top `!isRefetchingBody`
        // guard) — so the poll stays alive and resumes after, no cancel/restart
        // needed (rounds 2-5). `defer` covers every exit, incl. the not-found path.
        isRefetchingBody = true
        defer { isRefetchingBody = false }
        let rid = resolvedId
        print("[Refetch] Starting refetchBody for rid=\(rid.prefix(40))")
        // Delete existing body and reset body-fetch state. Pull-to-refresh is the
        // user's explicit "retry from scratch" signal — give the empty-fetch chain
        // a fresh start (otherwise a previously-confirmedEmpty message is locked
        // into the "This message has no content." stub forever, even after the
        // underlying server/parser issue is resolved). When the message was
        // previously auto-classified as empty, also clear the auto-generated
        // summary/tag so the user doesn't see stale stub text after a successful
        // re-fetch. The AI queue will repopulate summaryBlurb/actionTag from the
        // refreshed body content.
        try? await dbPool.write { db in
            _ = try MessageBody.deleteOne(db, key: rid)
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET summaryBlurb = CASE
                            WHEN bodyEmptyConfirmed = 1 AND summaryBlurb = 'This message has no content.'
                                THEN NULL
                            ELSE summaryBlurb
                        END,
                        actionTag = CASE
                            WHEN bodyEmptyConfirmed = 1 AND actionTag = ?
                                THEN NULL
                            ELSE actionTag
                        END,
                        tagSortOrder = CASE
                            WHEN bodyEmptyConfirmed = 1 AND actionTag = ?
                                THEN 99
                            ELSE tagSortOrder
                        END,
                        bodyComplete = 0,
                        bodyEmptyConfirmed = 0,
                        emptyFetchCount = 0,
                        embeddingComplete = 0
                    WHERE id = ?
                """,
                arguments: [ActionTag.delete.rawValue, ActionTag.delete.rawValue, rid]
            )
        }
        print("[Refetch] Deleted body from DB and reset empty-fetch state")
        // Clear in-memory body immediately — forces SwiftUI to drop the stale
        // WKWebView and show "Loading..." until the fresh body arrives.
        messageBody = nil

        // Refetch message (with fallback)
        var msg = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: rid) })
        if msg == nil {
            msg = await resolveMessageAsync(compositeId: messageId)
        }
        guard var msg else {
            print("[Refetch] Message not found after resolve")
            messageNotFound = true
            return
        }
        print("[Refetch] Resolved message: id=\(msg.id.prefix(40)) folderPath=\(msg.folderPath) messageId=\(msg.messageId.prefix(30))")
        applyOverlay(to: &msg)
        message = msg

        isLoading = true
        error = nil
        messageNotFound = false

        // Run fetch in an unstructured Task so .refreshable's cooperative
        // cancellation doesn't kill the URLSession request (NSURLErrorCancelled -999).
        // URLSession.data() checks Task.isCancelled and aborts the HTTP request;
        // .refreshable may cancel its task when the view tree changes mid-refresh.
        let fetchMsg = msg
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                defer { continuation.resume() }
                do {
                    if let override = self._fetchBodyOverride {
                        try await override(fetchMsg)
                    } else {
                        try await self.fetchBodyWithRetry(for: fetchMsg)
                    }
                    print("[Refetch] fetchBodyWithRetry succeeded")
                } catch {
                    print("[Refetch] fetchBodyWithRetry failed: \(error)")
                    if !SyncEngine.isConnectionError(error) {
                        self.error = error.localizedDescription
                    }
                }
                let postRefetchId = self.resolvedId
                self.messageBody = try? await self.dbPool.read { db in try MessageBody.fetchOne(db, key: postRefetchId) }
                let htmlLen = self.messageBody?.htmlContent?.count ?? 0
                let htmlPreview = String(self.messageBody?.htmlContent?.prefix(200) ?? "nil")
                print("[Refetch] Body loaded: htmlLen=\(htmlLen) preview=\(htmlPreview)")
                self.isLoading = false
                self.loadThreadMessagesAsync()
            }
        }
    }

    /// Returns false when the archive was a no-op (no archive folder, or the
    /// message is already in it) — callers must not dismiss/flash in that case.
    @discardableResult
    func archive() -> Bool {
        guard let message else { return false }
        return archiveMessage(message)
    }

    /// Returns false when the delete was a no-op (no trash folder, or the
    /// message is already in it) — callers must not dismiss/flash in that case.
    @discardableResult
    func delete() -> Bool {
        guard let message else { return false }
        return deleteMessage(message)
    }

    func toggleRead() {
        guard let message else { return }
        let wasRead = message.isRead
        let newIsRead = !wasRead
        self.message?.isRead = newIsRead
        manager.registerMutation(id: message.id, mutation: .init(isRead: newIsRead))
        Task { await manager.enqueueWrite { [manager] in
            if wasRead {
                await manager.markUnread([message])
            } else {
                await manager.markRead([message])
            }
            manager.removeOverlayEntries(ids: [message.id])
        }}
    }

    /// Returns false when the archive was a no-op (no archive folder, or the
    /// message is already in it) — callers must not dismiss/flash in that case.
    @discardableResult
    func archiveMessage(_ msg: MessageHeader) -> Bool {
        // Archive-from-Archive is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — accounts can carry more than one folder of
        // the same role (e.g. iCloud "Trash" + "Deleted Messages") and the
        // canonical lookup below is fetchOne-arbitrary among them.
        guard lookupFolderRole(msg.folderId) != .archive else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] detail archiveMessage suppressed — already archived: \(msg.id)")
            return false
        }
        guard let archiveFolder = lookupFolder(accountId: msg.accountId, role: .archive) else {
            print("[Queue] ERROR: no archive folder for account \(msg.accountId)")
            return false
        }
        guard msg.folderPath != archiveFolder.path else { return false }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: msg.folderPath, toPath: archiveFolder.path), messages: [msg],
            originalFolderId: msg.folderId,
            originalFolderPath: msg.folderPath,
            accountId: msg.accountId, timestamp: Date()
        ))
        manager.registerMutation(id: msg.id, mutation: .init(folderId: archiveFolder.id))
        enqueueMove(msg, to: archiveFolder.path)
        updateThreadMessageFolder(msg, newFolderPath: archiveFolder.path, newFolderId: archiveFolder.id)
        return true
    }

    /// Returns false when the delete was a no-op (no trash folder, or the
    /// message is already in it) — callers must not dismiss/flash in that case.
    @discardableResult
    func deleteMessage(_ msg: MessageHeader) -> Bool {
        AccountManager.logDeleteTrace(accountId: msg.accountId, messages: [msg], callSite: "MessageDetailViewModel.deleteMessage")
        // Delete-from-Trash is a no-op: no undo entry, no overlay, no queued
        // move. Role check first — see archiveMessage for why.
        guard lookupFolderRole(msg.folderId) != .trash else {
            BackgroundSyncLogger.logInbox("[NoOpGuard] detail deleteMessage suppressed — already in trash: \(msg.id)")
            return false
        }
        guard let trashFolder = lookupFolder(accountId: msg.accountId, role: .trash) else {
            print("[Queue] ERROR: no trash folder for account \(msg.accountId)")
            return false
        }
        guard msg.folderPath != trashFolder.path else { return false }
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: msg.folderPath, toPath: trashFolder.path), messages: [msg],
            originalFolderId: msg.folderId,
            originalFolderPath: msg.folderPath,
            accountId: msg.accountId, timestamp: Date()
        ))
        manager.registerMutation(id: msg.id, mutation: .init(folderId: trashFolder.id))
        enqueueMove(msg, to: trashFolder.path)
        updateThreadMessageFolder(msg, newFolderPath: trashFolder.path, newFolderId: trashFolder.id)
        return true
    }

    /// Update a thread message's folder info in-place after a move operation.
    /// The card stays visible but shows the new location. `isInInbox` reflects the
    /// destination: archive/delete move OUT of inbox (false); a generic move may target
    /// the Inbox (true), which must re-enable inbox-only UI (tags, summary, triage).
    /// Internal (not `private`) so tests can drive the locally-moved-bubble
    /// preserve contract without a full archive/delete flow (folders + IMAP drain).
    func updateThreadMessageFolder(_ msg: MessageHeader, newFolderPath: String, newFolderId: String, isInInbox newIsInInbox: Bool = false) {
        guard let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) else { return }
        threadMessages[idx].folderPath = newFolderPath
        threadMessages[idx].folderId = newFolderId
        threadMessages[idx].isInInbox = newIsInInbox
        threadMessages[idx].actionTag = nil
        localMovePins[msg.id, default: 0] += 1
    }

    /// The single queued-move protocol shared by archive/delete/move: execute
    /// the move, drop the (coalesced) overlay entry, then end THIS op's pin
    /// window — all INSIDE the queued closure. `enqueueWrite` returns at
    /// ENQUEUE time ("Never blocks caller"), so a continuation after it would
    /// un-pin before the move has executed (zero-width pin window — the
    /// round-9 defect, which shipped in three hand-kept copies; one helper
    /// keeps the protocol in lockstep).
    private func enqueueMove(_ msg: MessageHeader, to folderPath: String) {
        let manager = manager
        Task { await manager.enqueueWrite { [weak self, manager] in
            await manager.move([msg], to: folderPath)
            manager.removeOverlayEntries(ids: [msg.id])
            await self?.completeLocalMove(msg.id)
        }}
    }

    /// Ends a bubble move's pin window — called INSIDE the archive/delete/move
    /// `enqueueWrite` closures once THIS move op has fully executed (the
    /// optimistic local DB write landed inside `manager.move`). It must NOT be
    /// called after `enqueueWrite` RETURNS — that is enqueue time ("Never
    /// blocks caller", AccountManager.enqueueWrite), which makes the pin
    /// window zero-width. The pin is
    /// deliberately keyed to the OPERATION's lifetime, NOT to the shared
    /// overlay entry: `optimisticOverlay` coalesces one `PendingMutation` per
    /// id and every op's drain calls `removeOverlayEntries(ids:)` on the whole
    /// entry — so a sibling op draining first (e.g. a mark-read queued before
    /// the archive) would end an overlay-keyed pin while the move hasn't run
    /// (card snaps back), and an undo registering its own entry under the same
    /// id would extend it (stale folder fields clobber the undo).
    /// Internal (not `private`) so tests can simulate drain completion.
    func completeLocalMove(_ id: String) {
        guard let count = localMovePins[id] else { return }
        if count <= 1 {
            localMovePins.removeValue(forKey: id)
        } else {
            localMovePins[id] = count - 1
        }
    }

    /// True when the given folder path is the account's Inbox (role-based, not name-based).
    private func isInboxFolder(accountId: String, path: String) -> Bool {
        let role = try? dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("path") == path).fetchOne(db)?.role
        }
        return role == .inbox
    }

    func move(toFolderPath: String) {
        guard let message else { return }
        moveMessage(message, toFolderPath: toFolderPath)
    }

    func moveMessage(_ msg: MessageHeader, toFolderPath: String) {
        let destFolderId = "\(msg.accountId):\(toFolderPath)"
        manager.registerMutation(id: msg.id, mutation: .init(folderId: destFolderId))
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: msg.folderPath, toPath: toFolderPath), messages: [msg],
            originalFolderId: msg.folderId,
            originalFolderPath: msg.folderPath,
            accountId: msg.accountId, timestamp: Date()
        ))
        enqueueMove(msg, to: toFolderPath)
        updateThreadMessageFolder(
            msg, newFolderPath: toFolderPath, newFolderId: destFolderId,
            isInInbox: isInboxFolder(accountId: msg.accountId, path: toFolderPath)
        )
    }

    func applyManualTag(_ msg: MessageHeader, tag: ActionTag?) {
        // Optimistic UI update
        if msg.id == message?.id {
            message?.actionTag = tag
        }
        if let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) {
            threadMessages[idx].actionTag = tag
        }
        manager.registerMutation(id: msg.id, mutation: .init(actionTag: tag))
        Task { await manager.enqueueWrite { [manager] in
            await manager.applyManualTag(msg, tag: tag)
            manager.removeOverlayEntries(ids: [msg.id])
        }}
    }

    // MARK: - Lookup Helpers

    private func lookupFolder(accountId: String, role: FolderRole) -> Folder? {
        try? dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == role.rawValue).fetchOne(db)
        }
    }

    private func lookupFolderRole(_ folderId: String) -> FolderRole? {
        try? dbPool.read { db in try Folder.fetchOne(db, key: folderId)?.role }
    }

    // MARK: - Thread Messages

    /// Thread messages that are chronologically before the focused message (oldest first).
    private(set) var earlierMessages: [MessageHeader] = []
    /// Thread messages that are chronologically after the focused message (oldest first).
    private(set) var laterMessages: [MessageHeader] = []

    /// Recompute earlier/later splits from threadMessages + focused message date.
    private func recomputeThreadSplit() {
        guard let focusDate = message?.date else {
            earlierMessages = []
            laterMessages = []
            return
        }
        let focusId = message?.id ?? ""
        earlierMessages = threadMessages
            .filter { $0.date < focusDate || ($0.date == focusDate && $0.id < focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        laterMessages = threadMessages
            .filter { $0.date > focusDate || ($0.date == focusDate && $0.id > focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    /// Mark the focused message as read on first view appearance. Owns its
    /// own idempotency latch independent of `loadBody()`. Exists because
    /// `loadBody()` can be cancelled at its first cancellable `await`
    /// (GRDB 7.x throws `CancellationError` on async reads in cancelled
    /// Tasks — observed on notification deep-link navigation where split
    /// view re-layout cancels `.task`). When that cancellation hits, the
    /// early-return to `startBodyPoll()` leaves the message displayed via
    /// the poll path but never marks it read. This method is invoked from
    /// the view on an unstructured `Task { }` that does not inherit
    /// cancellation, so the read-flip survives.
    func markReadOnOpenIfNeeded() async {
        guard !markReadOnOpenCalled else { return }
        markReadOnOpenCalled = true

        // Fast path: `self.message` is already populated — seeded at init from
        // the staged snapshot, or an earlier resolve (loadBody) landed first.
        // Use it to flip the detail-view state and register the overlay BEFORE
        // any await — eliminates the perceived "popped back to inbox, row
        // still unread" beat.
        if let msg = self.message {
            guard !msg.isRead else { return }
            self.message?.isRead = true
            manager.registerMutation(id: msg.id, mutation: .init(isRead: true))
            Task { await manager.enqueueWrite { [manager] in
                await manager.markRead([msg])
                manager.removeOverlayEntries(ids: [msg.id])
            }}
            return
        }

        // Fallback: message not resolved yet — init is zero-I/O (staged
        // snapshot only) and loadBody's async resolve may not have landed.
        // Resolve here independently so the read-flip never depends on the
        // body-load path's timing. A pending notification tap resolves its
        // provider id first (shares loadBody's single-flight ladder).
        guard await resolveTapIfNeeded() else { return }
        guard let msg = await resolveMessageAsync(compositeId: messageId) else { return }
        guard !msg.isRead else { return }
        // Layer any concurrent pending mutations (e.g. user just flagged this
        // message in another view before init's resolve raced through nil) on
        // top of the fresh DB header, then force isRead=true. Without this,
        // self.message = msg silently drops the overlay's isFlagged/actionTag.
        var displayMsg = msg
        applyOverlay(to: &displayMsg)
        displayMsg.isRead = true
        if self.message == nil {
            // Skeleton → content dissolve (same rule as loadBody's assignment).
            withAnimation(Theme.detailContentDissolve) { self.message = displayMsg }
        } else {
            self.message = displayMsg
        }
        manager.registerMutation(id: msg.id, mutation: .init(isRead: true))
        Task { await manager.enqueueWrite { [manager] in
            await manager.markRead([msg])
            manager.removeOverlayEntries(ids: [msg.id])
        }}
    }

    /// Mark a thread message as read when expanded (fire-and-forget).
    func markReadIfNeeded(_ msg: MessageHeader) {
        guard !msg.isRead else { return }
        toggleReadForThread(msg)
    }

    /// Toggle read/unread for a thread message (not the focused message).
    func toggleReadForThread(_ msg: MessageHeader) {
        let wasRead = msg.isRead
        let newIsRead = !wasRead
        if let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) {
            threadMessages[idx].isRead = newIsRead
        }
        manager.registerMutation(id: msg.id, mutation: .init(isRead: newIsRead))
        Task { await manager.enqueueWrite { [manager] in
            if wasRead {
                await manager.markUnread([msg])
            } else {
                await manager.markRead([msg])
            }
            manager.removeOverlayEntries(ids: [msg.id])
        }}
    }

    /// Fetch body for any message by ID (used by thread card expansion)
    func bodyFor(_ messageId: String) -> MessageBody? {
        try? dbPool.read { db in try MessageBody.fetchOne(db, key: messageId) }
    }

    /// Load body for a thread message on demand (when user expands a bubble)
    func loadThreadMessageBody(_ threadMsg: MessageHeader) async {
        let hasBody = (try? await dbPool.read { db in try MessageBody.fetchOne(db, key: threadMsg.id) }) != nil
        guard !hasBody else { return }
        do {
            try await fetchBodyWithRetry(for: threadMsg)
        } catch {
            print("[MessageDetail] Failed to load thread message body: \(error)")
        }
    }

    /// Retry fetchBody up to 3 times on transient errors (messageNotFound, connection errors).
    /// messageNotFound: IMAP actor may be mid-sync with a different mailbox selected.
    /// Connection errors: fetchBody reconnects on failure internally, retry uses the fresh connection.
    /// Delays: 200ms, 500ms — fast first retry since priority lock resolves most contention quickly.
    /// After exhausting retries, re-resolves the message (it may have been re-synced with a new
    /// composite ID during the delay window) and retries body fetch once with the new header.
    private func fetchBodyWithRetry(for msg: MessageHeader) async throws {
        let maxAttempts = 3
        let retryDelays = [200, 500] // ms — indexed by (attempt - 1)
        for attempt in 1...maxAttempts {
            do {
                try await manager.fetchBody(for: msg)
                return
            } catch ProviderError.messageNotFound where attempt < maxAttempts {
                print("[MessageDetail] messageNotFound (attempt \(attempt)/\(maxAttempts)), retrying...")
                try await Task.sleep(for: .milliseconds(retryDelays[attempt - 1]))
            } catch let error where attempt < maxAttempts && SyncEngine.isConnectionError(error) {
                print("[MessageDetail] connection error (attempt \(attempt)/\(maxAttempts)): \(error), retrying...")
                try await Task.sleep(for: .milliseconds(retryDelays[attempt - 1]))
            }
        }
        // All retries exhausted — re-resolve (message may have been re-synced with new ID)
        print("[MoveTrace] fetchBodyWithRetry — retries exhausted, re-resolving \(msg.id)")
        if var resolved = await resolveMessageAsync(compositeId: messageId), resolved.id != msg.id {
            print("[MoveTrace] fetchBodyWithRetry — re-resolved to \(resolved.id), retrying body fetch")
            applyOverlay(to: &resolved)
            message = resolved
            try await manager.fetchBody(for: resolved)
            return
        }
        // Re-resolve didn't help — throw to trigger error state
        throw ProviderError.messageNotFound
    }

    // MARK: - Message Resolution

    /// Multi-strategy local message lookup. Tries:
    /// 1. Direct composite ID lookup (fastest)
    /// 2. Cross-folder search by messageId + accountId (finds moved messages)
    /// 3. Search by rfc822MessageId (handles UID changes after IMAP MOVE)
    /// ADR-IOS-049: a message that is staged (NSE) but not yet durable in GRDB —
    /// e.g. a notification tapped seconds after the push, or an instant-inserted
    /// inbox row opened before its merge write lands — has no GRDB header yet.
    /// Synthesize one from the merge's latest staged snapshot so the detail view
    /// renders immediately (subject/sender/snippet); the body arrives via the
    /// existing body-poll once phase 2 commits, and later GRDB re-reads replace
    /// the synthesized header with the durable one. On the ASYNC resolve GRDB
    /// always wins (this runs only on a GRDB miss); `init` seeds from this
    /// directly (its only zero-I/O source — init never touches the DB).
    private func stagedRowFallback(compositeId: String) -> MessageHeader? {
        let parts = compositeId.split(separator: ":", maxSplits: 2)
        let accountId = parts.count == 3 ? String(parts[0]) : nil
        let msgId = parts.count == 3 ? String(parts[2]) : nil
        return NSEDataBridge.latestStagedRows.withLock { rows in
            rows.first {
                $0.headerId == compositeId ||
                (accountId != nil && $0.accountId == accountId && $0.messageId == msgId)
            }
        }?.toMessageHeader()
    }

    /// Async multi-strategy resolve — the ONLY DB-touching resolve. `init` is
    /// deliberately zero-I/O (staged snapshot only); every durable lookup runs
    /// here, off the main-actor construction path.
    /// Returns nil immediately if the Task is cancelled — GRDB 7.x would throw
    /// CancellationError on the async read, which try? converts to nil anyway,
    /// but skipping the read avoids misleading "not found" log entries.
    private func resolveMessageAsync(compositeId: String) async -> MessageHeader? {
        guard !Task.isCancelled else { return nil }
        // `dbPool.pool` (raw), NOT `dbPool.read`: same reason as loadBody's header read —
        // `dbPool.read` would block on `mergeIfStagingPending()`. Raw-read the durable copy
        // (PK → cross-folder → rfc822), then fall through to `stagedRowFallback` below for a
        // not-yet-merged (staged) message. Keeps notif-tap resolution off the merge path;
        // a UID-remap that lands only in the pending merge self-heals via the merge-commit
        // catch-up. `.pool` honors a `_dbPoolOverride` test pool.
        let dbHit: MessageHeader? = try? await dbPool.pool.read { db in
            if let msg = try MessageHeader.fetchOne(db, key: compositeId) { return msg }

            let parts = compositeId.split(separator: ":", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let accountId = String(parts[0])
            let msgId = String(parts[2])

            if let msg = try MessageHeader
                .filter(Column("messageId") == msgId && Column("accountId") == accountId && Column("folderId") != "")
                .fetchOne(db) {
                print("[MoveTrace] resolveMessageAsync — found via cross-folder: \(msg.id)")
                return msg
            }

            let normalizedMsgId = EmailFilter.normalizeMessageId(msgId)
            if let msg = try MessageHeader
                .filter(Column("rfc822MessageId") == normalizedMsgId && Column("accountId") == accountId && Column("folderId") != "")
                .fetchOne(db) {
                print("[MoveTrace] resolveMessageAsync — found via rfc822MessageId: \(msg.id)")
                return msg
            }

            return nil
        }
        if let dbHit { return dbHit }
        // Cancellation makes the read return nil without meaning "not found" —
        // don't synthesize from a cancelled read; the caller defers to the poll.
        guard !Task.isCancelled else { return nil }
        return stagedRowFallback(compositeId: compositeId)
    }

    /// Sync the original folder from the composite ID to pick up the message with its new UID.
    /// No-ops if the Task is cancelled — async DB reads and IMAP calls would all fail.
    private func syncOriginalFolder() async {
        guard !Task.isCancelled else { return }
        let parts = messageId.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return }
        let accountId = String(parts[0])
        let folderPath = String(parts[1])

        guard let provider = await manager.providers[accountId] else {
            print("[MoveTrace] syncOriginalFolder — no provider for \(accountId)")
            return
        }
        guard let folder = try? await dbPool.read({ db in
            try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
        }) else {
            print("[MoveTrace] syncOriginalFolder — folder not found: \(folderPath)")
            return
        }
        do {
            try await manager.syncEngine.syncFolderMessages(folder: folder, provider: provider)
            print("[MoveTrace] syncOriginalFolder — completed for \(folder.name)")
        } catch {
            print("[MoveTrace] syncOriginalFolder — failed: \(error)")
        }
    }

    /// Fire-and-forget async thread detection — does not block message rendering.
    private func loadThreadMessagesAsync() {
        guard let msg = message else { return }
        threadLoadGeneration += 1
        let generation = threadLoadGeneration
        if DebugModeManager.isLoggingEnabled() {
            let refsStr = msg.references.isEmpty ? "[]" : "[\(msg.references.joined(separator: ", "))]"
            print("[ThreadDebug] Finding related for: id=\(msg.id.prefix(40)) rfc822=\(msg.rfc822MessageId ?? "nil") inReplyTo=\(msg.inReplyTo ?? "nil") threadId=\(msg.threadId ?? "nil") computedThreadId=\(msg.computedThreadId) references=\(refsStr) folder=\(msg.folderPath)")
        }
        let pool = dbPool
        Task {
            // Probe the DB for *any* messages that could plausibly be thread-related,
            // to distinguish "no candidates exist" from "candidates exist but chain
            // lookup missed them". Debug-gated: the probe exists ONLY to feed the
            // [ThreadDebug] prints and runs two unbounded fetchAll scans — with
            // `.nseMergeDidCommit` now re-running this per merge post, production
            // must not pay that cost for discarded output.
            if DebugModeManager.isLoggingEnabled() {
                do {
                    try await Task.detached {
                        try pool.read { db in
                            // 1. Same subject-based threadId (other messages that would group by subject)
                            if let tid = msg.threadId, !tid.isEmpty {
                                let sameTid = try MessageHeader
                                    .filter(Column("threadId") == tid && Column("id") != msg.id)
                                    .fetchAll(db)
                                print("[ThreadDebug]   probe sameThreadId(\(tid.prefix(60))...) count=\(sameTid.count)")
                                for r in sameTid.prefix(5) {
                                    let rRefs = r.references.isEmpty ? "[]" : "[\(r.references.joined(separator: ", "))]"
                                    print("[ThreadDebug]     sameTid: id=\(r.id.prefix(40)) rfc822=\(r.rfc822MessageId ?? "nil") inReplyTo=\(r.inReplyTo ?? "nil") ctid=\(r.computedThreadId) references=\(rRefs)")
                                }
                            }
                            // 2. Same computedThreadId (the actual grouping key used by the inbox)
                            if !msg.computedThreadId.isEmpty {
                                let sameCtid = try MessageHeader
                                    .filter(Column("computedThreadId") == msg.computedThreadId && Column("id") != msg.id)
                                    .fetchAll(db)
                                print("[ThreadDebug]   probe sameComputedThreadId(\(msg.computedThreadId.prefix(60))) count=\(sameCtid.count)")
                                for r in sameCtid.prefix(5) {
                                    print("[ThreadDebug]     sameCtid: id=\(r.id.prefix(40)) rfc822=\(r.rfc822MessageId ?? "nil") inReplyTo=\(r.inReplyTo ?? "nil")")
                                }
                            }
                        }
                    }.value
                } catch {
                    print("[ThreadDebug] probe failed: \(error)")
                }
            }
            do {
                let results = try await Task.detached {
                    try ThreadDetection.findRelatedMessages(for: msg, in: pool.pool)
                }.value
                if DebugModeManager.isLoggingEnabled() {
                    print("[ThreadDebug] Found \(results.count) related messages for \(msg.id.prefix(40))")
                    for r in results {
                        print("[ThreadDebug]   related: id=\(r.id.prefix(40)) rfc822=\(r.rfc822MessageId ?? "nil") inReplyTo=\(r.inReplyTo ?? "nil") folder=\(r.folderPath)")
                    }
                }
                // Ordering guard: apply only if newer than the last APPLIED
                // run. Detached completions are unordered, and clear-on-empty
                // (below) made ordering destructive — a stale pre-merge empty
                // result completing after the merge-triggered reload would
                // wipe the bubbles it just populated, with no further signal
                // to heal. Compared against last-APPLIED (not last-started):
                // if the newest run throws, an older successful result still
                // applies rather than being discarded for nothing.
                guard generation > self.lastAppliedThreadGeneration else { return }
                // Empty→empty is a no-op for DISPLAY — but still record the
                // generation: this run successfully observed "no related
                // messages", and a STALE older in-flight run with a
                // pre-removal non-empty snapshot must not pass the guard
                // afterwards and resurrect bubbles for deleted messages.
                if results.isEmpty && self.threadMessages.isEmpty {
                    self.lastAppliedThreadGeneration = generation
                    return
                }
                // Freeze re-check at the MUTATION site: the detached thread
                // query can outlast a QuickLook preview appearing, and the
                // caller's entry check cannot see a freeze that began during
                // the await. Discard these results and buffer a wholesale
                // reload for the release flush.
                if PreviewFreezeGate.shared.isFrozen {
                    self.pendingThreadRefreshOnRelease = true
                    return
                }
                // Remote state wins for CONTENT: an EMPTY result CLEARS stale
                // bubbles (e.g. an end-of-merge `.nseMergeDidCommit` after
                // inbox removals deleted every related member). In-flight
                // optimistic mutations survive via applyOverlay (display
                // fields) plus the FIELD-LEVEL move preserve for locally-moved
                // bubbles — folder fields are deliberately NOT in applyOverlay;
                // see preservingLocalMove for the full contract (the pin ends
                // when the move op's queued closure runs completeLocalMove).
                var overlayed = results
                self.applyOverlay(to: &overlayed)
                // The pin window is the move OP's lifetime (completeLocalMove
                // removes it when the op's continuation runs) — no overlay-
                // based pruning here: the overlay coalesces one entry per id,
                // so a sibling op's drain would end the window early and an
                // undo's own entry would extend it (ADR-IOS-049 round-8).
                if !self.localMovePins.isEmpty {
                    for i in overlayed.indices where self.localMovePins[overlayed[i].id] != nil {
                        if let current = self.threadMessages.first(where: { $0.id == overlayed[i].id }) {
                            overlayed[i] = self.preservingLocalMove(
                                fresh: overlayed[i], current: current
                            )
                        }
                    }
                    // An IN-FLIGHT moved bubble may already be EXCLUDED from
                    // fresh results (the optimistic local write can land the
                    // row in Trash before the op's continuation un-pins) —
                    // re-append its current in-memory row so the card doesn't
                    // flicker out mid-drain. Post-completion reloads (pin
                    // removed) follow fresh results: a trashed card drops,
                    // same as a fresh open of this view would show.
                    for id in self.localMovePins.keys where !overlayed.contains(where: { $0.id == id }) {
                        if let current = self.threadMessages.first(where: { $0.id == id }) {
                            overlayed.append(current)
                        }
                    }
                }
                // No-op guard: an UNRELATED merge re-runs this reload but
                // ThreadDetection returns the same set, so reassigning the
                // @Observable array + recomputing the splits would invalidate
                // the thread view for nothing (merges fire 2 posts on every
                // push/foreground/boot). Full-value equality — never a field
                // subset, which could silently drop a real thread update.
                // Still record the generation so a later stale run can't apply
                // over this confirmed-current set.
                guard overlayed != self.threadMessages else {
                    self.lastAppliedThreadGeneration = generation
                    return
                }
                self.threadMessages = overlayed
                self.recomputeThreadSplit()
                self.lastAppliedThreadGeneration = generation
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[ThreadDebug] Failed to load thread messages: \(error)")
                }
            }
        }
    }
}
