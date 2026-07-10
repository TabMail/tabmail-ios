/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Immediate-push notification taps (2026-07-04, boot_logs 7): the deep-link
/// handler no longer blocks navigation on the resolve ladder — it pushes the
/// detail view at once, with the sentinel-prefixed PROVIDER id when the staged
/// snapshot misses, and `MessageDetailViewModel` resolves it asynchronously
/// under the loading skeleton (`resolveProviderTap`).
@Suite("Notification-tap provider-id resolve (immediate push)")
struct NotificationTapResolveTests {

    private func makePool() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    private func stagedRow(messageId: String) -> StagedInboxRow {
        StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@x>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Staged \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    @MainActor
    private func insertDurableInboxHeader(from row: StagedInboxRow, subject: String, into pool: DatabasePool) throws -> MessageHeader {
        var durable = row.toMessageHeader()
        durable.subject = subject
        durable.isInInbox = true
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        return durable
    }

    // MARK: - Ladder tiers

    @MainActor
    @Test("staged snapshot tier resolves the provider id instantly")
    func stagedTierResolves() async throws {
        let (_, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-prov-staged")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        let resolved = await MessageDetailViewModel.resolveProviderTap("m-prov-staged")
        #expect(resolved == row.headerId)
    }

    @MainActor
    @Test("durable tier resolves via the indexed inbox lookup")
    func durableTierResolves() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let row = stagedRow(messageId: "m-prov-durable")
        let durable = try insertDurableInboxHeader(from: row, subject: "Durable", into: pool)

        let resolved = await MessageDetailViewModel.resolveProviderTap("m-prov-durable")
        #expect(resolved == durable.id)
    }

    @MainActor
    @Test("exhausted ladder returns nil (message genuinely gone)")
    func exhaustedLadderReturnsNil() async throws {
        let (_, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        // Short wait keeps the bounded poll from slowing the suite.
        let resolved = await MessageDetailViewModel.resolveProviderTap(
            "m-prov-gone", waitSeconds: 0.1, pollMs: 20
        )
        #expect(resolved == nil)
    }

    // MARK: - VM sentinel handling

    @MainActor
    @Test("sentinel init seeds from the staged snapshot by provider id and rewrites messageId")
    func sentinelInitSeedsFromStaged() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-tap-sentinel")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "m-tap-sentinel",
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        #expect(vm.message?.subject == "Staged m-tap-sentinel")
        #expect(vm.messageId == row.headerId, "messageId must be rewritten to the composite")
    }

    @MainActor
    @Test("sentinel init with no staged match: loadBody resolves durable and rewrites messageId")
    func sentinelLoadBodyResolvesDurable() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let row = stagedRow(messageId: "m-tap-durable")
        let durable = try insertDurableInboxHeader(from: row, subject: "Durable tap", into: pool)

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "m-tap-durable",
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        #expect(vm.message == nil, "no staged match → pending resolve, skeleton state")

        await vm.loadBody()
        #expect(vm.message?.subject == "Durable tap")
        #expect(vm.messageId == durable.id, "messageId must be rewritten to the composite")
    }

    // MARK: - Exhausted ladder → inbox fallback (pop-to-inbox contract)

    @MainActor
    @Test("exhausted ladder posts .notificationTapUnresolved and sets messageNotFound as a backstop")
    func exhaustedLadderPostsUnresolvedNotification() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        // Empty staging snapshot AND empty DB — the message is genuinely
        // nowhere yet (NSE never staged it, sync hasn't landed it).
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-nowhere"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        #expect(vm.message == nil, "no staged match → pending resolve")
        // Keep the ladder's bounded poll short so the test doesn't pay the
        // production 1.5s wait.
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        let posted = Mutex<[String]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .notificationTapUnresolved, object: nil, queue: .main
        ) { note in
            guard let messageId = note.userInfo?["messageId"] as? String else { return }
            posted.withLock { $0.append(messageId) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await vm.loadBody()
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.messageNotFound == true)
        #expect(vm.isLoading == false)
        let captured = posted.withLock { $0 }
        #expect(captured.count == 1)
        guard captured.count == 1 else { return }
        #expect(captured[0] == sentinelId, "posted messageId must be the VM's sentinel string")
    }

    @MainActor
    @Test("disappeared VM's late exhaustion does NOT post the pop — the Not-Found backstop still arms")
    func hiddenVMExhaustionSuppressesPopPost() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-hidden"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        // The user navigated away mid-ladder (`.onDisappear` fired). A NEWER
        // VM for the SAME sentinel may have since resolved —
        // shouldPopForUnresolvedTap's string equality cannot tell the
        // instances apart, so the hidden VM itself must not post.
        vm.isViewVisible = false

        let posted = Mutex<[String]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .notificationTapUnresolved, object: nil, queue: .main
        ) { note in
            guard let messageId = note.userInfo?["messageId"] as? String else { return }
            posted.withLock { $0.append(messageId) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await vm.loadBody()
        try await Task.sleep(for: .milliseconds(200))

        // The pop post is suppressed…
        #expect(posted.withLock { $0 }.isEmpty,
                "a disappeared VM must not pop a newer same-sentinel view")
        // …but the Not-Found backstop still arms unconditionally, so a
        // RE-PRESENTED view shows Not-Found + a working Retry, not a skeleton.
        #expect(vm.messageNotFound == true)
        #expect(vm.isLoading == false)
    }

    @MainActor
    @Test("exhaustion under an active presentation (visible view) does NOT post the pop — backstop stays underneath")
    func activePresentationExhaustionSuppressesPopPost() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-covered"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        // A sheet/fullScreenCover is up (e.g. an open compose draft). Covers
        // do NOT fire the presenting view's onDisappear, so isViewVisible
        // stays TRUE — hasActivePresentation (wired from the view's
        // isAnyCoverPresented onChange) is the only gate that can stop the
        // pop from tearing down the view and force-dismissing the cover.
        vm.isViewVisible = true
        vm.hasActivePresentation = true

        let posted = Mutex<[String]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .notificationTapUnresolved, object: nil, queue: .main
        ) { note in
            guard let messageId = note.userInfo?["messageId"] as? String else { return }
            posted.withLock { $0.append(messageId) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await vm.loadBody()
        try await Task.sleep(for: .milliseconds(200))

        // The pop post is suppressed — popping would force-dismiss the cover
        // (worst case an open compose draft, never-drop-user-intention)…
        #expect(posted.withLock { $0 }.isEmpty,
                "a live presentation on top must suppress the pop")
        // …while the Not-Found backstop genuinely remains underneath.
        #expect(vm.messageNotFound == true)
        #expect(vm.isLoading == false)
        // NOTE: no PreviewFreezeGate-frozen variant here — the gate is a
        // process GLOBAL and this suite is NOT `.serialized`;
        // MessageDetailStagedFallbackTests is `.serialized` precisely because
        // flipping `PreviewFreezeGate.shared` flakes sibling tests observing
        // it mid-flight. The gate check shares the exact same `if` as the two
        // flags asserted above.
    }

    // MARK: - Not-Found Retry (retryLoad resets the memoized failure)

    @MainActor
    @Test("retryLoad after an exhausted ladder re-runs a FRESH ladder and resolves")
    func retryLoadAfterExhaustionResolves() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        // First attempt: the message is genuinely nowhere yet (empty staging
        // snapshot AND empty DB) — the ladder exhausts → Not-Found.
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-retry"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        // Keep the ladder's bounded poll short so the test doesn't pay the
        // production 1.5s wait (twice — once per ladder run).
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        await vm.loadBody()
        #expect(vm.messageNotFound == true, "first run must exhaust the ladder")
        #expect(vm.messageId == sentinelId, "unresolved open keeps the sentinel id")

        // The message lands AFTER the failed run (sync/merge caught up) —
        // durable tier, same insert the durable-tier test uses.
        let row = stagedRow(messageId: "m-prov-retry")
        let durable = try insertDurableInboxHeader(from: row, subject: "Landed after retry", into: pool)

        // A bare loadBody() here would be a permanent no-op: the
        // `loadBodyCalled` latch short-circuits it, and even without that the
        // single-flight `tapResolveTask` memoized the FAILED ladder run.
        // `retryLoad()` resets both (and `messageNotFound`) so the retry
        // re-runs a fresh ladder against the now-populated durable tier.
        await vm.retryLoad()

        #expect(vm.messageNotFound == false)
        #expect(vm.messageId == durable.id, "messageId must be rewritten to the composite")
        #expect(vm.message?.subject == "Landed after retry")
    }

    @MainActor
    @Test("retryLoad with the message STILL absent lands back on Not-Found and re-posts the pop backstop")
    func retryLoadStillExhaustedRepostsUnresolved() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        // The message is genuinely nowhere — and STAYS nowhere across the retry.
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-still-gone"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        // Short poll so neither ladder run pays the production 1.5s wait.
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        let posted = Mutex<[String]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .notificationTapUnresolved, object: nil, queue: .main
        ) { note in
            guard let messageId = note.userInfo?["messageId"] as? String else { return }
            posted.withLock { $0.append(messageId) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await vm.loadBody()
        #expect(vm.messageNotFound == true, "first run must exhaust the ladder")

        // Retry while the message is still absent: retryLoad resets the
        // latches, runs a FRESH ladder, and that ladder exhausts again. The
        // user must land back on Not-Found with a functional Retry button —
        // never an inert skeleton (messageNotFound stuck false while a bare
        // loadBody() no-ops on its latch).
        await vm.retryLoad()
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.messageNotFound == true, "still-absent retry must re-show Not-Found")
        #expect(vm.isLoading == false)
        let captured = posted.withLock { $0 }
        #expect(captured.count == 2, "the pop backstop must fire once per exhausted run")
        guard captured.count == 2 else { return }
        #expect(captured[0] == sentinelId)
        #expect(captured[1] == sentinelId)
    }

    @MainActor
    @Test("mark-read intent survives retry: a successful retryLoad flips isRead after the original open bailed")
    func retryLoadReplaysMarkReadIntent() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-markread"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        // Simulate the real open: the view's `.task`/`.onAppear` fire BOTH
        // loadBody AND markReadOnOpenIfNeeded. With the message nowhere, both
        // exhaust — and markReadOnOpenIfNeeded LATCHES `markReadOnOpenCalled`
        // before bailing at its resolveTapIfNeeded guard. That latch is the
        // dropped-intent bug: the view-side callers sit on the stable outer
        // body and never refire.
        await vm.loadBody()
        await vm.markReadOnOpenIfNeeded()
        #expect(vm.messageNotFound == true, "setup: the open must exhaust")
        #expect(vm.message == nil)

        // The message lands UNREAD after the failed open (stagedRow's
        // isRead: false carries into the durable header).
        let row = stagedRow(messageId: "m-prov-markread")
        let durable = try insertDurableInboxHeader(from: row, subject: "Unread after retry", into: pool)
        #expect(durable.isRead == false, "setup: the landed message must be unread")

        await vm.retryLoad()

        #expect(vm.messageNotFound == false)
        #expect(vm.messageId == durable.id, "messageId must be rewritten to the composite")
        // retryLoad re-armed markReadOnOpenCalled and re-ran
        // markReadOnOpenIfNeeded after loadBody: its fast path flips the
        // optimistic in-memory isRead (same assertion level as the existing
        // MarkReadOnOpenTests — the durable write is a fire-and-forget
        // enqueue behind it).
        #expect(vm.message?.isRead == true, "the open's read-intent must survive the retry (never-drop-user-intention)")
    }

    @MainActor
    @Test("concurrent retryLoad calls: the in-flight guard runs exactly ONE ladder (one additional unresolved post)")
    func concurrentRetryLoadRunsSingleLadder() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        // Still absent across the whole test — every completed ladder exhausts.
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let sentinelId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-double-retry"
        let vm = MessageDetailViewModel(
            messageId: sentinelId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        vm._tapResolveWaitSecondsOverride = 0.1
        vm._tapResolvePollMsOverride = 20

        let posted = Mutex<[String]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .notificationTapUnresolved, object: nil, queue: .main
        ) { note in
            guard let messageId = note.userInfo?["messageId"] as? String else { return }
            posted.withLock { $0.append(messageId) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await vm.loadBody()
        #expect(vm.messageNotFound == true, "setup: the open must exhaust")

        // Two OVERLAPPING retries (double-tap on the Retry button). The
        // load-bearing property is NOT a specific task ordering: MainActor's
        // non-preemptive scheduling guarantees that exactly ONE of the two
        // synchronous prefixes (guard-check + `retryInFlight = true`) runs
        // atomically first — whichever one that is — so the other observes
        // the flag and no-ops. Both possible winners run the identical
        // still-exhausted ladder and post the identical sentinelId, so the
        // assertions below hold under either ordering. Without the guard,
        // BOTH would clear the latches and run independent ladders → a
        // duplicate pop post.
        async let firstRetry: Void = vm.retryLoad()
        async let secondRetry: Void = vm.retryLoad()
        await firstRetry
        await secondRetry
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.messageNotFound == true, "still-absent retry lands back on Not-Found")
        let captured = posted.withLock { $0 }
        #expect(captured.count == 2, "initial exhaustion + exactly ONE retry ladder — the overlapping duplicate must no-op")
        guard captured.count == 2 else { return }
        #expect(captured[0] == sentinelId)
        #expect(captured[1] == sentinelId)
    }

    // MARK: - Pop guard (shouldPopForUnresolvedTap — MailNavigationView's .onReceive decision)

    @Test("pop guard: posted id matching the pushed message → pop")
    @MainActor
    func popGuardEqualIdsPops() {
        let id = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-1"
        #expect(MessageDetailViewModel.shouldPopForUnresolvedTap(postedId: id, selectedId: id))
    }

    @Test("pop guard: mismatched ids (stale VM fired after the user navigated on) → no pop")
    @MainActor
    func popGuardMismatchDoesNotPop() {
        #expect(!MessageDetailViewModel.shouldPopForUnresolvedTap(
            postedId: MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-1",
            selectedId: MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-2"
        ))
    }

    @Test("pop guard: nil posted or nil selected → no pop")
    @MainActor
    func popGuardNilsDoNotPop() {
        let id = MessageDetailViewModel.notificationTapIdPrefix + "acc1::m-prov-1"
        #expect(!MessageDetailViewModel.shouldPopForUnresolvedTap(postedId: nil, selectedId: id))
        #expect(!MessageDetailViewModel.shouldPopForUnresolvedTap(postedId: id, selectedId: nil))
        #expect(!MessageDetailViewModel.shouldPopForUnresolvedTap(postedId: nil, selectedId: nil))
    }
}
