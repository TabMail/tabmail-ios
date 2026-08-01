/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-049 (notification tap): when a message is staged (NSE) but not yet
/// durable in GRDB, `MessageDetailViewModel` synthesizes its header from
/// `NSEDataBridge.latestStagedRows` so the detail view renders immediately
/// instead of showing "not found" until the merge write lands.
/// `.serialized`: `mergeCommitBuffersDuringPreviewFreeze` flips the process-
/// GLOBAL `PreviewFreezeGate.shared` — a sibling test's `.nseMergeDidCommit`
/// handler observing the frozen gate would buffer its refresh and flake.
@Suite("MessageDetail staged-row fallback (ADR-IOS-049)", .serialized, .processGlobalState)
struct MessageDetailStagedFallbackTests {

    /// Sentinel `object` for test posts of `.nseMergeDidCommit`. Production
    /// posts carry `object: nil`; the sentinel lets count-contract tests in
    /// OTHER suites (`NSEGradualMergeTests.mergePostsMergeCommitSignal`)
    /// exclude these cross-suite posts. VM observers register `object: nil`
    /// and therefore still receive them.
    static let testPostSentinel = "MessageDetailStagedFallbackTests"

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
        // messageHeader.accountId has an FK → account (v2 migration); durable-row
        // inserts in these tests need the parent row.
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func insertDurableHeader(_ header: MessageHeader, into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    /// Poll (20ms cadence, 3s cap) until `condition` holds — the async
    /// notification → detached-query → main-actor-apply chain has no
    /// completion signal to await. One shared helper so the timeout is tuned
    /// in a single place.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func stagedRow(messageId: String, references: [String] = []) -> StagedInboxRow {
        StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@x>", threadId: nil, inReplyTo: nil, references: references,
            subject: "Staged \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    @MainActor
    @Test("staging-only id resolves via synthesized header (no 'not found')")
    func synthesizesFromStagedSnapshot() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let row = stagedRow(messageId: "m-tap")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        // Not in GRDB — only staged.
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message != nil)
        #expect(vm.message?.subject == "Staged m-tap")
        #expect(vm.message?.id == row.headerId)
    }

    @MainActor
    @Test("init is zero-I/O: staged snapshot seeds it; durable rows resolve via loadBody")
    func initIsZeroIO() async throws {
        // Init never touches the DB (2026-07-03, boot_logs 6): its former SYNC
        // main-actor read is unbounded under I/O pressure (PK miss + fallback
        // queries faulting cold pages behind an in-flight phase-1 fsync;
        // measured ~4.3s MAIN THREAD STALL). Init seeds only from the
        // in-memory staged snapshot; every durable lookup is loadBody's async
        // resolve, with the skeleton on screen until it lands.
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let row = stagedRow(messageId: "m-dual")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        var durable = row.toMessageHeader()
        durable.subject = "Durable m-dual"
        try insertDurableHeader(durable, into: pool)

        // Staged id present → init seeds from the snapshot (zero I/O).
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message?.subject == "Staged m-dual")

        // Snapshot drained → init leaves message nil (no DB read)…
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let vm2 = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm2.message == nil)
        // …and loadBody's async resolve populates the durable row.
        await vm2.loadBody()
        #expect(vm2.message?.subject == "Durable m-dual")
    }

    @MainActor
    @Test("genuinely unknown id still resolves to nil")
    func unknownStillNil() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [stagedRow(messageId: "m-other")] }
        let vm = MessageDetailViewModel(messageId: "acc1:INBOX:m-nope", dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil)
    }

    // MARK: - Staged BODY fast-path (notification-tap open lag)

    @MainActor
    @Test("stagedBodyFallback synthesizes a display MessageBody; unknown id is nil")
    func stagedBodyFallbackSynthesizes() {
        defer { NSEDataBridge.latestStagedBodies.withLock { $0 = [:] } }
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = ["acc1:INBOX:m-tap": NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>staged body</p>", attachmentsJSON: nil, icsText: nil
            )]
        }
        let body = NSEDataBridge.stagedBodyFallback(headerId: "acc1:INBOX:m-tap")
        #expect(body?.htmlContent == "<p>staged body</p>")
        #expect(body?.id.rawValue == "acc1:INBOX:m-tap")
        #expect(NSEDataBridge.stagedBodyFallback(headerId: "acc1:INBOX:m-nope") == nil)
    }

    @MainActor
    @Test("loadBody renders the staged body immediately — no server fetch, no poll wait")
    func loadBodyUsesStagedBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Header durable (the common few-seconds-after-push case: phase 1
        // landed, phase 2's body write hasn't), body ONLY in the staged snapshot.
        let row = stagedRow(messageId: "m-body")
        // Sync helper — an inline call in this async test body would select
        // GRDB's ASYNC writeWithoutTransaction overload (needs await).
        try insertDurableHeader(row.toMessageHeader(), into: pool)
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = [row.headerId: NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>from staging</p>", attachmentsJSON: nil, icsText: nil
            )]
        }

        var serverFetchCalled = false
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in
            serverFetchCalled = true
        })
        await vm.loadBody()

        #expect(vm.messageBody?.htmlContent == "<p>from staging</p>")
        #expect(vm.isLoading == false)
        // The whole point: the on-device staged bytes render without a network
        // round-trip or the 2s body-poll cadence.
        #expect(!serverFetchCalled)
    }

    // MARK: - Merge-commit thread re-run (.nseMergeDidCommit)

    @MainActor
    @Test("merge-commit signal re-runs thread detection — related messages appear post-merge")
    func mergeCommitRefreshesThreadMessages() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Focused message is staging-only, replying into a thread whose parent
        // will only become GRDB-queryable when the merge commits.
        let parent = stagedRow(messageId: "m-parent")
        let focused = stagedRow(messageId: "m-reply", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message != nil)
        // Quick-render state: thread detection has nothing to find yet.
        #expect(vm.threadMessages.isEmpty)

        // The merge lands: the parent header is now durable/queryable, and the
        // merge posts `.nseMergeDidCommit`.
        try insertDurableHeader(parent.toMessageHeader(), into: pool)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)

        // The refresh is async (observer Task → detached thread query) — poll
        // briefly instead of a fixed sleep.
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == parent.headerId)

        // Unrelated/no-op re-merge: an IDENTICAL thread result must not corrupt
        // or drop the displayed set (the no-op guard skips reassignment when
        // `overlayed == threadMessages`; correctness must be unaffected).
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == parent.headerId)
    }

    @MainActor
    @Test("merge-commit adopts a newly-durable body — no 2s poll wait (boot_logs 8)")
    func mergeCommitAdoptsNewlyDurableBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Notification-tap open: header synthesized from the staged snapshot (so
        // the detail view renders a card) but the BODY is neither durable yet NOR
        // in the staged-body snapshot — the exact merge-timing race where
        // `startBodyPoll`'s entry fast-paths BOTH miss and the body would
        // otherwise strand on the 2s poll cadence (~2.6s open-lag, boot_logs 8).
        let row = stagedRow(messageId: "m-mergebody")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        try insertDurableHeader(row.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message != nil)
        #expect(vm.messageBody == nil)

        // The merge writes the body durable, THEN posts the end-of-merge signal
        // (production order: MessageBody insert → main tx commit → .nseMergeDidCommit).
        try await pool.write { db in
            try MessageBody( contentKey: ContentKey(rawValue: row.headerId), htmlContent: "<p>durable merge body</p>").insert(db)
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)

        // Event-driven: the body appears WELL under the 2s poll floor. Without
        // the catch-up it stays nil (nothing drives a body read — startBodyPoll
        // is not running in this open), so this assertion pins the fix.
        try await waitUntil { vm.messageBody != nil }
        #expect(vm.messageBody?.htmlContent == "<p>durable merge body</p>")
        #expect(vm.isLoading == false)
    }

    @MainActor
    @Test("adoptReadyBody bails during pull-to-refresh — no mid-refresh clobber")
    func adoptReadyBodyBailsDuringRefetch() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Durable body present (or a concurrent merge just re-committed it), but
        // refetchBody() deleted the row + set messageBody=nil for its refresh
        // window and is awaiting a fresh server fetch: a .nseMergeDidCommit / poll
        // driven adopt must NOT flash the stale body back mid-refresh.
        let row = stagedRow(messageId: "m-refetch-guard")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        try insertDurableHeader(row.toMessageHeader(), into: pool)
        try await pool.write { db in
            try MessageBody( contentKey: ContentKey(rawValue: row.headerId), htmlContent: "<p>durable body</p>").insert(db)
        }
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.messageBody == nil)

        vm.isRefetchingBody = true
        let adoptedDuringRefresh = await vm.adoptReadyBody(source: "test")
        #expect(adoptedDuringRefresh == false)
        #expect(vm.messageBody == nil)

        // Window closes → the same call now adopts.
        vm.isRefetchingBody = false
        let adoptedAfter = await vm.adoptReadyBody(source: "test")
        #expect(adoptedAfter == true)
        #expect(vm.messageBody?.htmlContent == "<p>durable body</p>")
    }

    @MainActor
    @Test("adoptReadyBody(allowStagedFallback: false) ignores staged bytes — poll falls through to persist")
    func adoptReadyBodyDurableOnlyIgnoresStaged() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Header durable, body ONLY in the staged snapshot (no durable MessageBody).
        let row = stagedRow(messageId: "m-durable-only")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        try insertDurableHeader(row.toMessageHeader(), into: pool)
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = [row.headerId: NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>staged only</p>", attachmentsJSON: nil, icsText: nil
            )]
        }
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.messageBody == nil)

        // Durable-only (the 2s poll loop's mode): staged bytes are IGNORED so the
        // caller falls through to its persisting server fetch (round-3 audit).
        let adoptedDurableOnly = await vm.adoptReadyBody(source: "test", allowStagedFallback: false)
        #expect(adoptedDurableOnly == false)
        #expect(vm.messageBody == nil)

        // Default (entry / merge-commit mode): staged bytes ARE adopted for instant display.
        let adoptedWithStaged = await vm.adoptReadyBody(source: "test")
        #expect(adoptedWithStaged == true)
        #expect(vm.messageBody?.htmlContent == "<p>staged only</p>")
    }

    @MainActor
    @Test("merge-commit catch-up is durable-only — a staged-only body does NOT end the poll early")
    func mergeCommitCatchUpIgnoresStagedOnly() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Header durable, body ONLY staged (phase-1 committed the header but the
        // phase-2 durable body write hasn't landed). The phase-1 .nseMergeDidCommit
        // fires here — the catch-up must NOT adopt the display-only staged bytes
        // (round-4: that would end the persisting poll before a durable body exists).
        let row = stagedRow(messageId: "m-mergecatchup-staged")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        try insertDurableHeader(row.toMessageHeader(), into: pool)
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = [row.headerId: NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>staged only</p>", attachmentsJSON: nil, icsText: nil
            )]
        }
        let vm = MessageDetailViewModel(
            messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.messageBody == nil)

        // Phase-1-style post: body only staged, not durable → the durable-only
        // catch-up must IGNORE it.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        // The body then becomes durable and an end-of-merge-style post fires.
        try await pool.write { db in
            try MessageBody( contentKey: ContentKey(rawValue: row.headerId), htmlContent: "<p>durable now</p>").insert(db)
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)

        // Robust check (no fragile fixed-sleep negative): the catch-up adopts the
        // DURABLE body. Had it wrongly adopted the staged bytes on the FIRST post,
        // messageBody would be "<p>staged only</p>" (and the second post's
        // `if messageBody == nil` would never re-fire) — so asserting the DURABLE
        // content catches that regression even under CI load.
        try await waitUntil { vm.messageBody != nil }
        #expect(vm.messageBody?.htmlContent == "<p>durable now</p>")
    }

    @MainActor
    @Test("merge-commit during preview freeze buffers and replays on release — refresh never dropped")
    func mergeCommitBuffersDuringPreviewFreeze() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            PreviewFreezeGate.shared.end()
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = stagedRow(messageId: "m-parent-frozen")
        let focused = stagedRow(messageId: "m-reply-frozen", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }

        // `observeNotifications: true` registers BOTH the merge-commit listener
        // and the `.previewFreezeReleased` flush listener (they must travel
        // together — a buffered refresh with no flush listener would be
        // dropped).
        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message != nil)

        PreviewFreezeGate.shared.begin()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await Task.sleep(for: .milliseconds(150))
        // Frozen: no observable mutation. (The parent is not durable yet, so
        // even a mis-applied refresh could not populate the thread — this
        // assert cannot race a stray global `.previewFreezeReleased` post.)
        #expect(vm.threadMessages.isEmpty)

        // The merge outcome becomes durable while still frozen; release must
        // replay the buffered refresh — the update is deferred, never dropped.
        try insertDurableHeader(parent.toMessageHeader(), into: pool)
        PreviewFreezeGate.shared.end()

        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == parent.headerId)
    }

    @MainActor
    @Test("merge-commit with all related messages removed CLEARS stale thread bubbles")
    func mergeCommitClearsRemovedThreadMessages() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = stagedRow(messageId: "m-parent-gone")
        let focused = stagedRow(messageId: "m-reply-gone", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)

        // The related message is removed (archived/deleted on another device;
        // the merge's inbox-removal pass deleted the header row) and the
        // end-of-merge signal fires: remote state wins — the stale bubble must
        // CLEAR, not linger pointing at a message that no longer exists.
        try await pool.write { db in
            _ = try MessageHeader.deleteOne(db, key: parent.headerId)
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.isEmpty)
    }

    @MainActor
    @Test("merge-commit re-read never reverts an in-flight optimistic bubble mutation")
    func mergeCommitPreservesPendingBubbleMutation() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-pending")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let focused = stagedRow(messageId: "m-reply-pending", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // User archives the bubble: overlay entry + in-place optimistic move
        // (the exact archiveMessage sequence); the IMAP drain is still
        // pending, so the DB row keeps the OLD folder.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Archive")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Archive", newFolderId: "acc1:Archive"
        )

        // An unrelated merge lands. The wholesale re-read must keep the
        // optimistically-mutated bubble, NOT snap it back to the stale DB row
        // (folder fields are deliberately absent from applyOverlay).
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].folderPath == "Archive")
        #expect(vm.threadMessages[0].isInInbox == false)
    }

    @MainActor
    @Test("AI refresh on an in-flight moved bubble: folder fields preserved, AI fields flow")
    func aiRefreshPreservesLocallyMovedBubble() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-airev")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let focused = stagedRow(messageId: "m-reply-airev", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // User deletes the bubble in place (overlay + in-place move, the
        // deleteMessage sequence); the drain is pending, so the DB row still
        // shows the OLD folder.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Trash")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Trash", newFolderId: "acc1:Trash"
        )

        // Background AI completes and writes to the DB row, then posts. The
        // per-id refresh must carry the AI fields onto the card WITHOUT
        // snapping its folder back to the stale pre-drain value.
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ? WHERE id = ?",
                arguments: ["AI summary done", parent.headerId]
            )
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: parent.headerId)
        try await waitUntil { vm.threadMessages.first?.summaryBlurb == "AI summary done" }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].summaryBlurb == "AI summary done")
        #expect(vm.threadMessages[0].folderPath == "Trash")
        #expect(vm.threadMessages[0].isInInbox == false)
    }

    @MainActor
    @Test("undo heals a locally-moved bubble: overlay drained → fresh DB row wins, pin cleared")
    func undoHealsLocallyMovedBubble() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-undo")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let focused = stagedRow(messageId: "m-reply-undo", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // Archive the bubble in place; the move op completes (continuation
        // un-pins), then the user UNDOES it: the overlay entry is removed and
        // the DB row (never moved in this test) is the INBOX truth again.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Archive")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Archive", newFolderId: "acc1:Archive"
        )
        #expect(vm.threadMessages[0].folderPath == "Archive")
        vm.completeLocalMove(parent.headerId)
        AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])

        // The next merge reload must heal the card back to the DB truth —
        // an insert-only pin would show "Archive" forever after an undo.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.first?.folderPath == "INBOX" }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].folderPath == "INBOX")
        #expect(vm.threadMessages[0].isInInbox == true)
    }

    @MainActor
    @Test("overlapping moves on the same bubble: first completion does not end the pin")
    func overlappingMovesKeepPinUntilLastCompletes() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-overlap")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let focused = stagedRow(messageId: "m-reply-overlap", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // Archive the card, then immediately delete the (still visible,
        // still actionable) same card: two pins on one id.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Archive")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Archive", newFolderId: "acc1:Archive"
        )
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Trash")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Trash", newFolderId: "acc1:Trash"
        )

        // The ARCHIVE op completes first (FIFO drain). The pin must survive —
        // the trash move is still queued and the DB row is stale; a Set pin
        // collapsed both ops and un-pinned here, snapping the card back on
        // the next reload.
        vm.completeLocalMove(parent.headerId)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].folderPath == "Trash")

        // The TRASH op completes: the pin is fully released.
        vm.completeLocalMove(parent.headerId)
    }

    @MainActor
    @Test("real archive wiring: pin survives while the move op is still QUEUED")
    func pinSurvivesWhileMoveQueued() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-queued")
        defer {
            // manager.move fires UNSTRUCTURED tasks (drainPendingQueue, unread
            // recounts — AccountManagerActions) that the drain barrier below
            // cannot join; they may run AFTER these defers. Restore a real
            // predecessor when present, but retain the complete installed
            // fixture until process exit in either case.
            InstalledTestDatabaseLifetime.finish(
                previous: previous,
                pool: pool,
                directory: dir
            )
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
        }
        try await pool.write { db in
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
        }
        let focused = stagedRow(messageId: "m-reply-queued", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // BLOCK the global write queue so the archive's move op stays QUEUED
        // (mirrors production: other user-action writes drain ahead of it).
        // NO early returns from here on: the queued move closure reads the
        // global AppDatabase, so the drain barrier below MUST run before the
        // defers tear the test database down (rawPool force-unwraps shared —
        // a closure outliving teardown fatalErrors the whole test process).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer { gate.finish() }

        // REAL wiring: archiveMessage pins and enqueues its move behind the
        // gate — no manual updateThreadMessageFolder/completeLocalMove.
        #expect(vm.archiveMessage(vm.threadMessages[0]))
        if vm.threadMessages.count == 1 {
            #expect(vm.threadMessages[0].folderPath == "Archive")
        }

        // A merge reload while the op is QUEUED (not executed) must keep the
        // optimistic card. Un-pinning at ENQUEUE time — the round-9 verified
        // defect: enqueueWrite returns immediately, "Never blocks caller" —
        // snapped the card back to INBOX here.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(vm.threadMessages.count == 1)
        if vm.threadMessages.count == 1 {
            #expect(vm.threadMessages[0].folderPath == "Archive")
            #expect(vm.threadMessages[0].isInInbox == false)
        }

        // Release the gate and BARRIER until the queue (gate closure + the
        // archive's move closure) has fully drained — only then may the
        // defers restore AppDatabase.shared and delete the temp store.
        gate.finish()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    @MainActor
    @Test("sibling op draining the coalesced overlay entry does NOT end an in-flight move's pin")
    func siblingDrainDoesNotEndMovePin() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-sibling")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let focused = stagedRow(messageId: "m-reply-sibling", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // Archive in place (overlay + pin), then a SIBLING op that was queued
        // earlier (e.g. a mark-read) drains first: its removeOverlayEntries
        // wipes the whole coalesced entry while the move op has NOT executed —
        // the DB row still shows INBOX.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Archive")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Archive", newFolderId: "acc1:Archive"
        )
        AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])

        // A merge reload in that gap must keep the moved card — an overlay-
        // keyed pin window ended here and snapped the card back to INBOX.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].folderPath == "Archive")
        #expect(vm.threadMessages[0].isInInbox == false)
    }

    @MainActor
    @Test("post-drain trashed bubble follows DB truth: next merge reload drops the card")
    func trashedCardDropsAfterDrain() async throws {
        let (pool, dir, previous) = try makePool()
        let parent = stagedRow(messageId: "m-parent-drain")
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // ThreadDetection excludes by folder ROLE — the Trash folder row must
        // exist for the exclusion to engage.
        try await pool.write { db in
            try Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1").insert(db)
        }
        let focused = stagedRow(messageId: "m-reply-drain", references: [parent.rfc822MessageId!])
        NSEDataBridge.latestStagedRows.withLock { $0 = [focused] }
        try insertDurableHeader(parent.toMessageHeader(), into: pool)

        let vm = MessageDetailViewModel(
            messageId: focused.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }

        // Delete the bubble in place, then the drain lands: the optimistic
        // local write moves the DB row to Trash and the overlay entry drains.
        AccountManager.shared.registerMutation(
            id: parent.headerId, mutation: .init(folderId: "acc1:Trash")
        )
        vm.updateThreadMessageFolder(
            vm.threadMessages[0], newFolderPath: "Trash", newFolderId: "acc1:Trash"
        )
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ? WHERE id = ?",
                arguments: ["acc1:Trash", "Trash", parent.headerId]
            )
        }
        AccountManager.shared.removeOverlayEntries(ids: [parent.headerId])
        vm.completeLocalMove(parent.headerId)

        // Post-completion the pin is gone: ThreadDetection's Trash exclusion
        // is the truth again and the card drops — same as a fresh open. (A
        // view-lifetime pin here produced permanent duplicates under UID
        // re-keying; see ADR-IOS-049 rounds 7–8.)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.isEmpty }
        #expect(vm.threadMessages.isEmpty)
    }
}
