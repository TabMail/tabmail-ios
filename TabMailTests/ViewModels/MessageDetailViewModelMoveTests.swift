/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression tests for the "wrong message moved" bug in the message detail view.
///
/// Before the fix, swiping a *related/thread* message and choosing Move called the
/// focused-message `move(toFolderPath:)`, which operated on `self.message` (the
/// focused message) — moving the WRONG message and never refreshing the thread row.
///
/// `moveMessage(_:toFolderPath:)` fixes both halves:
/// 1. It targets the passed message (overlay mutation keyed to that message's id).
/// 2. It updates that message's thread row in place, with `isInInbox` reflecting the
///    destination folder's role (so moving back to Inbox re-enables inbox-only UI).
///
/// `move(toFolderPath:)` now simply delegates to `moveMessage(message, …)`, so the
/// focused path still targets the focused message.
@Suite("MessageDetailViewModel move targets the swiped message", .serialized, .processGlobalState)
struct MessageDetailViewModelMoveTests {

    // Folder paths that exist in the test DB (must match for the role lookup).
    private static let inboxPath = "INBOX"
    private static let archivePath = "[Gmail]/All Mail"

    @MainActor
    private func makeEnv() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        // Swap the shared AppDatabase so the AccountManager drain writes to the test
        // pool (manager.move uses AppDatabase.dbPool, not the VM's override).
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            let inbox = Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: "acc1")
            let archive = Folder(name: "Archive", path: Self.archivePath, role: .archive, accountId: "acc1")
            try inbox.insert(db)
            try archive.insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    @discardableResult
    private func insertHeader(
        _ pool: DatabasePool, messageId: String, folderPath: String, isInInbox: Bool, isRead: Bool = true,
        actionTag: ActionTag? = nil, rfc822MessageId: String? = nil, includeRFCIdentity: Bool = true
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Test",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(),
            snippet: "body",
            folderId: "acc1:\(folderPath)", accountId: "acc1",
            folderPath: folderPath, isInInbox: isInInbox
        )
        header.isRead = isRead
        header.actionTag = actionTag
        header.tagSortOrder = actionTag?.sortOrder ?? 99
        header.headerComplete = true
        header.rfc822MessageId = includeRFCIdentity
            ? (rfc822MessageId ?? "<\(messageId)@example.com>")
            : nil
        try pool.writeWithoutTransaction { try header.insert($0) }
        return try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)!
        }
    }

    private func clearOverlay() {
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    private func durableId(_ message: MessageHeader) -> String {
        MessageIdentity.durableActionRFC822MessageId(message.rfc822MessageId)!
    }

    /// Escaped-write hygiene barrier (ADR-IOS-058, PROJECT_MEMORY "drain-before-
    /// return" rule) — replaces a prior fixed 250ms `settle()` sleep (round-1
    /// audit item 1): enqueue a no-op onto `AccountManager.shared`'s FIFO write
    /// queue and await it. Since the queue is strictly FIFO and
    /// `moveMessage`/`move` append their intention record via a SYNCHRONOUS
    /// `manager.record` call (which enqueues the fold executor closure before
    /// returning — see `recordMove`'s doc comment), every write enqueued
    /// BEFORE this call — including this test's own move — is guaranteed to
    /// have executed against the swapped test pool by the time this returns,
    /// before the caller's `defer` restores `AppDatabase.shared`. Mirrors
    /// `InboxGestureActionTests.drainWriteQueue`.
    /// Round-2 audit: a single FIFO enqueue+await only guarantees closures
    /// already enqueued BEFORE this call have run — it does NOT guarantee the
    /// journal is empty. Two independently-created Tasks (a gesture site's
    /// `record()`, which spawns its own fold-executor Task, and this drain
    /// call) can reach the shared FIFO in EITHER order, so a fold closure the
    /// gesture just triggered may land AFTER this barrier's no-op closure and
    /// still be pending when the barrier returns — closing this window is the
    /// likely fix for the plan's known settle-flake. Loop the barrier until
    /// the journal reports fully drained (no pending records, no in-flight
    /// display holds/seqs); bounded so a genuine stuck-drain bug fails the
    /// test instead of hanging it forever.
    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
    }

    // MARK: - Tests

    /// Hybrid identity (PLAN_IDENTITY_HYBRID): missing/malformed RFC identity
    /// no longer refuses detail gestures — those admit the provider ID as a
    /// token member (covered by the tail-admission tests). Only the SCOPE
    /// legs still refuse: blank source folder, blank account, blank
    /// destination.
    @Test("Blank scope refuses detail gestures before detail/thread mutation, journal, Undo, or success")
    @MainActor
    func blankScopeDetailGesturesAreSideEffectFree() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        var blankSource = try insertHeader(
            pool, messageId: "detail-source-blank", folderPath: Self.inboxPath,
            isInInbox: true, isRead: false
        )
        blankSource.folderPath = "   "
        var blankAccount = try insertHeader(
            pool, messageId: "detail-account-blank", folderPath: Self.inboxPath,
            isInInbox: true, isRead: false
        )
        blankAccount.accountId = "   "
        let valid = try insertHeader(
            pool, messageId: "detail-destination-blank", folderPath: Self.inboxPath,
            isInInbox: true, isRead: false
        )

        let vm = MessageDetailViewModel(messageId: blankSource.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(blankSource)
        vm.threadMessages = [blankSource, blankAccount, valid]

        vm.toggleRead()
        #expect(!vm.archive())
        #expect(!vm.delete())
        #expect(!vm.move(toFolderPath: Self.archivePath))

        vm.toggleReadForThread(blankSource)
        #expect(!vm.moveMessage(blankSource, toFolderPath: Self.archivePath))
        vm.toggleReadForThread(blankAccount)
        #expect(!vm.moveMessage(blankAccount, toFolderPath: Self.archivePath))
        #expect(!vm.moveMessage(valid, toFolderPath: " \n"))

        #expect(vm.message?.isRead == false)
        #expect(vm.threadMessages.count == 3)
        guard vm.threadMessages.count == 3 else { return }
        #expect(vm.threadMessages.allSatisfy { !$0.isRead })
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().isEmpty)
        #expect(AccountManager.shared.snapshotOverlay().isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty)

        let providerOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(providerOps.isEmpty)
    }

    @Test("Moving a thread message back to Inbox updates THAT message in place, re-enables inbox UI, and re-displays its retained tag (Round D-0)")
    @MainActor
    func moveThreadMessageToInbox() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-1", folderPath: Self.inboxPath, isInInbox: true)
        // Tagged BEFORE it left the inbox — Round D-0: the tag is retained
        // across the folder move, so it must re-display the moment the
        // message is back in the inbox (isInInbox true).
        let thread = try insertHeader(
            pool, messageId: "thread-1", folderPath: Self.archivePath,
            isInInbox: false, actionTag: .reply
        )

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.moveMessage(thread, toFolderPath: Self.inboxPath)

        // The swiped thread message — not the focused one — reflects the new folder.
        #expect(vm.threadMessages.count == 1)
        // Round-2 audit guard-gap fix: this test's LATER overlay assertions
        // (below) need the write STILL PENDING — draining before them would
        // clear the overlay entry the assertions check for. So the drain
        // stays at the end for the normal path; this branch is the ONLY one
        // gaining a new drain call, closing the early-return escape.
        guard vm.threadMessages.count == 1 else {
            await drainWriteQueue()
            return
        }
        #expect(vm.threadMessages[0].id == thread.id)
        #expect(vm.threadMessages[0].folderPath == Self.inboxPath)
        #expect(vm.threadMessages[0].folderId == "acc1:\(Self.inboxPath)")
        // Destination is the Inbox → inbox-only UI must be re-enabled.
        #expect(vm.threadMessages[0].isInInbox == true)
        // The retained tag re-displays immediately — the exact model state
        // every tag renderer gates on (actionTag != nil && isInInbox).
        #expect(vm.threadMessages[0].actionTag == .reply, "updateThreadMessageFolder must not clear the retained tag on a move back to the inbox")
        #expect(vm.threadMessages[0].tagSortOrder == ActionTag.reply.sortOrder)

        // The focused message must be untouched.
        #expect(vm.message?.id == focused.id)
        #expect(vm.message?.folderPath == Self.inboxPath)

        // Optimistic overlay is keyed to the swiped thread message, not the focused one.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[thread.id]?.folderId == "acc1:\(Self.inboxPath)")
        #expect(overlay[focused.id] == nil)

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: thread.id) }
        #expect(final?.folderId == "acc1:\(Self.inboxPath)")
        #expect(final?.isInInbox == true)
        #expect(final?.actionTag == .reply, "the durable row also retains the tag after the drain")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder)
    }

    @Test("Moving a thread message OUT of Inbox to Archive clears inbox membership but RETAINS the tag (Round D-0) — display alone is suppressed")
    @MainActor
    func moveThreadMessageToArchive() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let focused = try insertHeader(pool, messageId: "focused-2", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(
            pool, messageId: "thread-2", folderPath: Self.inboxPath,
            isInInbox: true, actionTag: .reply
        )

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.moveMessage(thread, toFolderPath: Self.archivePath)

        // Round-2 audit guard-gap fix: drain BEFORE the guard below — this
        // test's guarded assertions only read `vm.threadMessages` (optimistic
        // UI, unaffected by draining), so moving the drain up closes the
        // early-return escape without disturbing anything.
        await drainWriteQueue()

        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == thread.id)
        #expect(vm.threadMessages[0].folderPath == Self.archivePath)
        #expect(vm.threadMessages[0].folderId == "acc1:\(Self.archivePath)")
        // Destination is not the Inbox → inbox-only UI suppressed (display
        // gates on isInInbox — MessageCardView.swift:441/539).
        #expect(vm.threadMessages[0].isInInbox == false)
        // Round D-0: the underlying value is retained — only the DISPLAY is
        // suppressed by the isInInbox gate above, never the data itself.
        #expect(vm.threadMessages[0].actionTag == .reply, "moving out of Inbox must not clear the retained tag")
        #expect(vm.threadMessages[0].tagSortOrder == ActionTag.reply.sortOrder,
                "tagSortOrder stays paired with the retained tag")

        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "exactly one queued .move op")
    }

    @Test("Moving one thread message leaves the other thread rows untouched")
    @MainActor
    func moveThreadMessageIsolation() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-3", folderPath: Self.inboxPath, isInInbox: true)
        let threadA = try insertHeader(pool, messageId: "thread-3a", folderPath: Self.inboxPath, isInInbox: true)
        let threadB = try insertHeader(pool, messageId: "thread-3b", folderPath: Self.inboxPath, isInInbox: true)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [threadA, threadB]

        vm.moveMessage(threadA, toFolderPath: Self.archivePath)

        // Round-2 audit guard-gap fix: drain BEFORE the guard below — this
        // test's guarded assertions only read `vm.threadMessages` (optimistic
        // UI, unaffected by draining), so moving the drain up closes the
        // early-return escape without disturbing anything.
        await drainWriteQueue()

        #expect(vm.threadMessages.count == 2)
        guard vm.threadMessages.count == 2 else { return }
        let a = vm.threadMessages.first { $0.id == threadA.id }
        let b = vm.threadMessages.first { $0.id == threadB.id }
        #expect(a?.folderPath == Self.archivePath)
        #expect(a?.isInInbox == false)
        // threadB is untouched.
        #expect(b?.folderPath == Self.inboxPath)
        #expect(b?.isInInbox == true)
    }

    @Test("Focused move() delegates to the focused message (overlay keyed to focused id)")
    @MainActor
    func focusedMoveTargetsFocused() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-4", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(pool, messageId: "thread-4", folderPath: Self.inboxPath, isInInbox: true)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.move(toFolderPath: Self.archivePath)

        // The focused message is the move target — its overlay reflects the destination,
        // and the unrelated thread row is left alone.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[focused.id]?.folderId == "acc1:\(Self.archivePath)")
        #expect(overlay[thread.id] == nil)
        #expect(vm.threadMessages.first?.folderPath == Self.inboxPath)

        await drainWriteQueue()
    }

    // MARK: - Thread-bubble read/tag real-path pins (ADR-IOS-058 register wiring)
    //
    // Before these, the only "coverage" of the expanded-bubble read flip and
    // the detail-surface manual tag replicated the raw DB UPDATE pattern
    // (MessageDetailViewTests.toggleReadPattern / applyManualTag patterns) —
    // so a dropped `registerGestureIntent` call or an inverted `!msg.isRead`
    // guard shipped silently. These call the REAL VM methods and assert the
    // durable row + PendingOperation the register → fold pipeline produces.
    // Scope is deliberately tight: they pin the register WIRING of the
    // detail-VM surfaces, not executor semantics (pinned in
    // InboxGestureActionTests / IntentionFoldTests).

    @Test("markReadIfNeeded/toggleReadForThread: expanded-bubble read persists durably BOTH ways (.markRead then .markUnread ops); markReadIfNeeded no-ops on an already-read bubble")
    @MainActor
    func threadBubbleReadTogglePersistsDurablyBothWays() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-bubble-read", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(pool, messageId: "thread-bubble-read", folderPath: Self.inboxPath, isInInbox: true, isRead: false)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        // Guard pin: an ALREADY-READ bubble must not record anything — the
        // `!msg.isRead` guard in markReadIfNeeded. `record()` appends
        // synchronously, so the journal is checkable immediately (id-scoped:
        // suites run concurrently with each other).
        var alreadyRead = thread
        alreadyRead.isRead = true
        vm.markReadIfNeeded(alreadyRead)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(thread.id) }.isEmpty, "markReadIfNeeded must no-op on an already-read bubble — no record, no write")
        #expect(vm.threadMessages.first?.isRead == false, "the no-op must not flip the bubble")

        // Expand-gesture on the UNREAD bubble — the real path (register → fold).
        vm.markReadIfNeeded(thread)
        #expect(vm.threadMessages.first?.isRead == true, "optimistic bubble flip")
        await drainWriteQueue()
        let readAfterFirst = try await pool.read { db in try MessageHeader.fetchOne(db, key: thread.id)?.isRead }
        #expect(readAfterFirst == true, "expanded-bubble read must persist durably — a dropped registerGestureIntent leaves only the in-memory flip")
        let opsAfterFirst = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        #expect(opsAfterFirst.contains { $0.type == .markRead && $0.messageIds == [durableId(thread)] }, "a .markRead PendingOperation must exist for the bubble")
        #expect(!opsAfterFirst.contains { $0.messageIds.contains(durableId(focused)) }, "the focused message is untouched")

        // Toggle back from the CURRENT visualized bubble (threadMessages
        // already shows read) — the other direction through the same register.
        guard let bubble = vm.threadMessages.first else { return }
        vm.toggleReadForThread(bubble)
        #expect(vm.threadMessages.first?.isRead == false, "optimistic flip back")
        await drainWriteQueue()
        let readAfterSecond = try await pool.read { db in try MessageHeader.fetchOne(db, key: thread.id)?.isRead }
        #expect(readAfterSecond == false, "the unread flip must persist durably too")
        let opsAfterSecond = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        #expect(opsAfterSecond.contains { $0.type == .markUnread && $0.messageIds == [durableId(thread)] }, "a .markUnread PendingOperation must exist for the flip back")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("applyManualTag on a thread bubble: baseline from the render-time snapshot, bubble-only optimistic update, and local durable actionTag")
    @MainActor
    func threadBubbleManualTagPersistsDurably() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-bubble-tag", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(pool, messageId: "thread-bubble-tag", folderPath: Self.inboxPath, isInInbox: true)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.applyManualTag(thread, tag: .reply)
        // Dual optimistic update, keyed by the PASSED message's id: the
        // bubble's threadMessages row flips; the focused message (different
        // id) is untouched.
        #expect(vm.threadMessages.first?.actionTag == .reply, "optimistic bubble tag flip")
        #expect(vm.threadMessages.first?.tagSortOrder == ActionTag.reply.sortOrder,
                "optimistic bubble tagging must re-derive the paired sort key")
        #expect(vm.message?.actionTag == nil, "the focused message must not be tagged by a thread-bubble gesture")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: thread.id) }
        #expect(final?.actionTag == .reply, "the tag must persist durably — a dropped registerGestureIntent leaves only the in-memory flip")
        let focusedFinal = try await pool.read { db in try MessageHeader.fetchOne(db, key: focused.id) }
        #expect(focusedFinal?.actionTag == nil)

        // Manual action tags are local-only (ADR-IOS-036): the GRDB field is
        // durable, but no provider-facing PendingOperation is created.
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        #expect(ops.isEmpty, "local-only manual tags must not create provider work")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("applyManualTag on the focused message updates the paired optimistic tag sort key")
    @MainActor
    func focusedMessageManualTagUpdatesSortKey() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(
            pool, messageId: "focused-manual-tag", folderPath: Self.inboxPath,
            isInInbox: true
        )
        let vm = MessageDetailViewModel(
            messageId: focused.id, dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        vm._testSeedMessage(focused)

        vm.applyManualTag(focused, tag: .reply)

        #expect(vm.message?.actionTag == .reply)
        #expect(vm.message?.tagSortOrder == ActionTag.reply.sortOrder,
                "the focused row must keep actionTag and tagSortOrder paired")

        await drainWriteQueue()
        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: focused.id) }
        #expect(final?.actionTag == .reply)
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - markReadOnOpenIfNeeded real-path pins (ADR-IOS-058 register wiring)
    //
    // The open-a-message read flip is the highest-traffic register site, and
    // until these pins it had NO real-path durable coverage: the
    // MarkReadOnOpenTests suite (OnDemandBodyFetchIntegrationTests.swift)
    // asserts only the optimistic in-memory flip — its harness deliberately
    // does not swap `AppDatabase.shared`, so the fold executes against
    // whatever process DB is installed (documented in its drainWriteQueue
    // comment) — and NotificationTapResolveTests' retry pin self-documents
    // the same assertion level. These two tests pin BOTH register cells
    // (the fast path with `message` already resolved, and the async-resolve
    // fallback) end-to-end: record() → fold → durable isRead flip + exactly
    // one `.markRead` PendingOperation. Executor semantics themselves are
    // pinned in InboxGestureActionTests / IntentionFoldTests.

    @Test("markReadOnOpenIfNeeded fast path (message already resolved): the .isRead(true) record folds to a durable DB flip + exactly one .markRead PendingOperation")
    @MainActor
    func markReadOnOpenFastPathPersistsDurably() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let header = try insertHeader(pool, messageId: "open-fast-read", folderPath: Self.inboxPath, isInInbox: true, isRead: false)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        // Seed the focused message — the fast path requires `self.message`
        // populated at call time (staged snapshot / earlier resolve).
        vm._testSeedMessage(header)

        await vm.markReadOnOpenIfNeeded()
        #expect(vm.message?.isRead == true, "optimistic in-memory flip lands before any await")

        await drainWriteQueue()

        let durableIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id)?.isRead }
        #expect(durableIsRead == true, "opening a message must persist the read flip durably — a dropped registerGestureIntent leaves only the in-memory flip")
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        let markReadOps = ops.filter { $0.type == .markRead }
        #expect(markReadOps.count == 1, "exactly one .markRead PendingOperation for the open")
        guard markReadOps.count == 1 else { return }
        #expect(markReadOps[0].messageIds == [durableId(header)])
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("markReadOnOpenIfNeeded fallback (message nil at call time): async-resolves the header from the DB and registers the same .isRead(true) record — durable flip + exactly one .markRead PendingOperation")
    @MainActor
    func markReadOnOpenFallbackPersistsDurably() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let header = try insertHeader(pool, messageId: "open-fallback-read", folderPath: Self.inboxPath, isInInbox: true, isRead: false)

        // Zero-I/O init + NO _testSeedMessage: the staged snapshot holds no
        // row for this unique composite id, so `message` is nil at call time —
        // this exercises the async-resolve fallback register cell
        // (resolveTapIfNeeded no-ops on a composite id; resolveMessageAsync
        // resolves the durable header via the override pool), not the fast path.
        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil, "precondition: zero-I/O init leaves the message unresolved — fallback path")

        await vm.markReadOnOpenIfNeeded()

        #expect(vm.message?.id == header.id, "the fallback must resolve the durable header")
        #expect(vm.message?.isRead == true, "the resolved header displays as read")

        await drainWriteQueue()

        let durableIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id)?.isRead }
        #expect(durableIsRead == true, "the fallback's read flip must persist durably too — same contract as the fast path")
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        let markReadOps = ops.filter { $0.type == .markRead }
        #expect(markReadOps.count == 1, "exactly one .markRead PendingOperation for the open")
        guard markReadOps.count == 1 else { return }
        #expect(markReadOps[0].messageIds == [durableId(header)])
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - deleteMessage real-path behavior
    //
    // `deleteMessage` was never called by any test: MessageDetailViewTests
    // replicates only the trash-folder LOOKUP pattern, and
    // MessageDetailStagedFallbackTests hand-simulates the overlay + in-place
    // move via seedDisplayForTesting/updateThreadMessageFolder. These pin the
    // REAL method end-to-end: trash-role no-op guard, user-visible Undo entry,
    // durable move to the trash-role folder, and tag RETENTION (Round D-0).

    @Test("deleteMessage: durable move to the trash-role folder, tag RETAINED (Round D-0), and one user-visible Undo entry")
    @MainActor
    func deleteMessageMovesToTrashDurably() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        // makeEnv seeds inbox + archive only; deleteMessage resolves the
        // trash-role folder, so add one (mirrors InboxGestureActionTests'
        // local trash insertion).
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }

        let header = try insertHeader(pool, messageId: "detail-delete-1", folderPath: Self.inboxPath, isInInbox: true, actionTag: .reply)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        #expect(vm.deleteMessage(header), "deleteMessage from the inbox must record — returns true so callers dismiss/flash")

        #expect(UndoService.shared.undoStack.count == 1, "one gesture pushes ONE undo entry")
        #expect(
            UndoService.shared.currentAction?.commands.flatMap { $0.members.map(\.originalHeaderId) } == [header.id]
        )

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(final?.folderId == trash.id, "the durable row must land in the trash-role folder")
        #expect(final?.folderPath == trash.path)
        #expect(final?.actionTag == .reply, "Round D-0: the tag is retained across the inbox-leaving move — no longer destructively cleared")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag")

        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "exactly one queued .move op")
        guard moveOps.count == 1 else { return }
        #expect(moveOps[0].messageIds == [durableId(header)])
        #expect(moveOps[0].destinationPath == trash.path)
        #expect(moveOps[0].folderPath == Self.inboxPath, "source is the pre-move inbox location")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("deleteMessage on a trash-resident row is a no-op: returns false, records nothing, no undo entry, row untouched")
    @MainActor
    func deleteMessageFromTrashIsNoOp() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }

        let header = try insertHeader(pool, messageId: "detail-delete-noop", folderPath: "Trash", isInInbox: false)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        #expect(vm.deleteMessage(header) == false, "trash-role no-op guard: delete-from-Trash must return the no-op result")

        // record() appends synchronously, so the journal is checkable
        // immediately (id-scoped: suites run concurrently with each other).
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(header.id) }.isEmpty, "the no-op must not record anything")
        #expect(UndoService.shared.undoStack.isEmpty, "no undo entry for a no-op")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(final?.folderId == trash.id, "the row stays untouched in trash")
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation for a no-op")
    }

    // MARK: - Undo preserves preceding user state
    //
    // These tests exercise public detail actions and Undo in serial order. A
    // read change made immediately before a move/archive/delete must remain in
    // the final state after Undo, as must the action tag visible before the
    // destructive action. They deliberately do not assert how Undo represents
    // or reconciles that state internally.

    @Test("archiveMessage then Undo preserves the immediately preceding read and action-tag state")
    @MainActor
    func archiveMessagePushesOverlayAdjustedSnapshotSurvivingUndo() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let header = try insertHeader(pool, messageId: "detail-archive-overlay-snapshot", folderPath: Self.inboxPath, isInInbox: true, isRead: false, actionTag: .reply)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        // Captured BEFORE the toggle below — see this section's doc comment.
        let preToggleSnapshot = header

        // Gate the FIFO write queue BEFORE the toggle so its fold-executor
        // closure cannot drain (and clear the overlay entry) while we archive —
        // mirrors InboxGestureActionTests' gated pattern (e.g.
        // rapidDoubleToggleReadDerivesFromVisualizedState).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead()
        #expect(vm.message?.isRead == true, "optimistic in-memory flip")

        // Let the toggle's fold-executor Task actually enqueue behind the gate
        // before archiving (mirrors the 50ms settle used throughout
        // InboxGestureActionTests).
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.archiveMessage(preToggleSnapshot), "archive must record — returns true")
        #expect(UndoService.shared.undoStack.count == 1, "one gesture pushes ONE undo entry")

        gate.finish()
        await drainWriteQueue()

        await UndoService.shared.undo()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(final?.isRead == true, "the preceding read action must survive Undo")
        #expect(final?.actionTag == .reply, "Undo must return to the tag visible before archive")
    }

    @Test("deleteMessage then Undo preserves the immediately preceding read and action-tag state")
    @MainActor
    func deleteMessagePushesOverlayAdjustedSnapshotSurvivingUndo() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        // makeEnv seeds inbox + archive only; deleteMessage resolves the
        // trash-role folder (mirrors deleteMessageMovesToTrashDurably).
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }

        let header = try insertHeader(pool, messageId: "detail-delete-overlay-snapshot", folderPath: Self.inboxPath, isInInbox: true, isRead: false, actionTag: .reply)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        // Captured BEFORE the toggle below — see the archive test's doc comment.
        let preToggleSnapshot = header

        // Gate the FIFO write queue BEFORE the toggle so its fold-executor
        // closure cannot drain (and clear the overlay entry) while we delete.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead()
        #expect(vm.message?.isRead == true, "optimistic in-memory flip")

        // Let the toggle's fold-executor Task actually enqueue behind the gate
        // before deleting.
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.deleteMessage(preToggleSnapshot), "delete must record — returns true")
        #expect(UndoService.shared.undoStack.count == 1, "one gesture pushes ONE undo entry")

        gate.finish()
        await drainWriteQueue()

        await UndoService.shared.undo()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(final?.isRead == true, "the preceding read action must survive Undo")
        #expect(final?.actionTag == .reply, "Undo must return to the tag visible before delete")
    }

    @Test("moveMessage then Undo preserves the immediately preceding read and action-tag state")
    @MainActor
    func moveMessagePushesOverlayAdjustedSnapshotSurvivingUndo() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        // Same order-discriminating fixture as the archive/delete pins above.
        let header = try insertHeader(pool, messageId: "detail-move-overlay-snapshot", folderPath: Self.inboxPath, isInInbox: true, isRead: false, actionTag: .reply)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        // Captured BEFORE the toggle below — see the archive test's doc comment.
        let preToggleSnapshot = header

        // Gate the FIFO write queue BEFORE the toggle so its fold-executor
        // closure cannot drain (and clear the overlay entry) while we move.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead()
        #expect(vm.message?.isRead == true, "optimistic in-memory flip")

        // Let the toggle's fold-executor Task actually enqueue behind the gate
        // before moving.
        try await Task.sleep(for: .milliseconds(50))

        vm.moveMessage(preToggleSnapshot, toFolderPath: Self.archivePath)
        #expect(UndoService.shared.undoStack.count == 1, "one gesture pushes ONE undo entry")

        gate.finish()
        await drainWriteQueue()

        await UndoService.shared.undo()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(final?.isRead == true, "the preceding read action must survive Undo")
        #expect(final?.actionTag == .reply, "Undo must return to the tag visible before move")
    }
}
