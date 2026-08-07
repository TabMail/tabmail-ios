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
        _ pool: DatabasePool, messageId: String, folderPath: String, isInInbox: Bool,
        actionTag: ActionTag? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Test",
            from: "sender@example.com", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(timeIntervalSince1970: 1_800_000_000),
            snippet: "body",
            folderId: "acc1:\(folderPath)", accountId: "acc1",
            folderPath: folderPath, isInInbox: isInInbox
        )
        header.isRead = true
        header.headerComplete = true
        // `setActionTag` is the pairing's source of truth, so a seeded row is
        // consistent by construction — the fixture can never supply the corrupt
        // pair the test is looking for.
        if let actionTag { header.setActionTag(actionTag) }
        try pool.writeWithoutTransaction { try header.insert($0) }
        return try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)!
        }
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    /// Let the async local-write drain finish against the swapped test pool before
    /// the caller restores AppDatabase.shared.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Tests

    @Test("Moving a thread message back to Inbox updates THAT message in place + re-enables inbox UI")
    @MainActor
    func moveThreadMessageToInbox() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-1", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(pool, messageId: "thread-1", folderPath: Self.archivePath, isInInbox: false)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.moveMessage(thread, toFolderPath: Self.inboxPath)

        // The swiped thread message — not the focused one — reflects the new folder.
        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == thread.id)
        #expect(vm.threadMessages[0].folderPath == Self.inboxPath)
        #expect(vm.threadMessages[0].folderId == "acc1:\(Self.inboxPath)")
        // Destination is the Inbox → inbox-only UI must be re-enabled.
        #expect(vm.threadMessages[0].isInInbox == true)

        // The focused message must be untouched.
        #expect(vm.message?.id == focused.id)
        #expect(vm.message?.folderPath == Self.inboxPath)

        // Optimistic overlay is keyed to the swiped thread message, not the focused one.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[thread.id]?.folderId == "acc1:\(Self.inboxPath)")
        #expect(overlay[focused.id] == nil)

        await settle()
    }

    @Test("Moving a thread message OUT of Inbox to Archive clears inbox membership")
    @MainActor
    func moveThreadMessageToArchive() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        let focused = try insertHeader(pool, messageId: "focused-2", folderPath: Self.inboxPath, isInInbox: true)
        let thread = try insertHeader(pool, messageId: "thread-2", folderPath: Self.inboxPath, isInInbox: true)

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)
        vm.threadMessages = [thread]

        vm.moveMessage(thread, toFolderPath: Self.archivePath)

        #expect(vm.threadMessages.count == 1)
        guard vm.threadMessages.count == 1 else { return }
        #expect(vm.threadMessages[0].id == thread.id)
        #expect(vm.threadMessages[0].folderPath == Self.archivePath)
        #expect(vm.threadMessages[0].folderId == "acc1:\(Self.archivePath)")
        // Destination is not the Inbox → inbox-only UI suppressed.
        #expect(vm.threadMessages[0].isInInbox == false)

        await settle()
    }

    @Test("Moving one thread message leaves the other thread rows untouched")
    @MainActor
    func moveThreadMessageIsolation() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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

        #expect(vm.threadMessages.count == 2)
        guard vm.threadMessages.count == 2 else { return }
        let a = vm.threadMessages.first { $0.id == threadA.id }
        let b = vm.threadMessages.first { $0.id == threadB.id }
        #expect(a?.folderPath == Self.archivePath)
        #expect(a?.isInInbox == false)
        // threadB is untouched.
        #expect(b?.folderPath == Self.inboxPath)
        #expect(b?.isInInbox == true)

        await settle()
    }

    @Test("Focused move() delegates to the focused message (overlay keyed to focused id)")
    @MainActor
    func focusedMoveTargetsFocused() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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

        // Two-sided with `focusedMoveReportsNotRecordedWithNoFocusedMessage`
        // below: a recorded move reports TRUE, so `handleMove` legitimately
        // dismisses the detail view (and the list row stays hidden).
        await settle()
    }

    // The detail view's move sheet used to read `viewModel.move(…);
    // dismissMessage()` — the message was dismissed from the list whether or
    // not anything was recorded. The Bool report is the only signal
    // `MessageDetailView.handleMove` has, matching handleArchive/handleDelete.

    @Test("Focused move() reports NOT-recorded when there is no focused message — the detail view must not dismiss, and nothing is recorded")
    @MainActor
    func focusedMoveReportsNotRecordedWithNoFocusedMessage() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        // No `_testSeedMessage`: `seedAtInit` reads only the in-memory staged
        // snapshot, so `message` stays nil — the sole not-recorded leg.
        let ghostId = "acc1:\(Self.inboxPath):never-existed"
        let vm = MessageDetailViewModel(messageId: ghostId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil)

        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        #expect(vm.move(toFolderPath: Self.archivePath) == false)

        #expect(UndoService.shared.undoStack.isEmpty)
        #expect(AccountManager.shared.snapshotOverlay()[ghostId] == nil)
    }

    // MARK: - (actionTag, tagSortOrder) — the pair a durable write must never split

    /// 🚨 INVARIANT: **no durable write ever lands an `(actionTag, tagSortOrder)`
    /// pair that disagrees.** The two columns are ONE fact stored twice; the
    /// triage list sorts by `ORDER BY tagSortOrder ASC, date DESC` while the
    /// chip renders `actionTag`, so a split pair is a row whose chip says one
    /// thing and whose position says another. It is the exact shape migration
    /// `v58` was written to heal ONCE — and a one-time heal does not re-run, so
    /// anything corrupted after v58 stays corrupted.
    ///
    /// This is the sibling half of R13-U13 (`d3a95d26f`), which closed the
    /// inbox-gesture route by mirroring inside
    /// `AccountManager.overlayAdjustedSnapshot`. That fix does not reach here:
    /// `InboxViewModel`'s display array is `[MessageSnapshot]` and its six undo
    /// pushes pass a DB-fresh `MessageHeader` through `overlayAdjustedForUndo`,
    /// whereas `MessageDetailViewModel` holds `MessageHeader`s in `message` /
    /// `threadMessages` and hands those very values to
    /// `UndoableAction(messages:)`. Any display write that touched one field and
    /// not the other therefore travelled into `UndoMember.init(header:)` — which
    /// records BOTH — and out of `AccountManagerActions.undoMove`, which writes
    /// BOTH durably.
    ///
    /// PINNED AS THE END STATE, NOT THE MECHANISM: the assertion is
    /// `row.tagSortOrder == (row.actionTag?.sortOrder ?? 99)` on the row the
    /// undo actually wrote — never "which expression computes the sort order",
    /// and never the captured `UndoMember`'s fields. It stays honest if the
    /// mapping changes, if the mirror moves to a helper, or if the capture path
    /// is rewritten.
    ///
    /// NON-VACUITY (`MIS-030`, `MIS-027`): the fixture is anchored on both sides
    /// — the seeded row is asserted consistent BEFORE the gesture, the
    /// post-archive row is asserted to have actually left the inbox, and the
    /// restored row is asserted to be back in INBOX. Without the last one a
    /// refused `undoMove` (which returns without writing anything) would leave
    /// the untouched `(nil, 99)` row passing the pairing assertion for free.
    @Test("Retag in the detail view, archive, undo — the restored row's actionTag and tagSortOrder still agree")
    @MainActor
    func detailRetagThenArchiveThenUndoRestoresAConsistentTagPair() async throws {
        let (pool, dir, previous) = try makeEnv()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()
        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        // A tagged inbox row. `.reply` sorts at 0, `.delete` at 3 — so a
        // retag that moves one field and not the other is visible as a gap.
        let focused = try insertHeader(
            pool, messageId: "u13b-focused", folderPath: Self.inboxPath, isInInbox: true,
            actionTag: .reply)
        #expect(focused.actionTag == .reply)
        #expect(focused.tagSortOrder == ActionTag.reply.sortOrder,
                "fixture anchor: the seeded row's pair agrees, so any disagreement below is the code's")

        let vm = MessageDetailViewModel(messageId: focused.id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(focused)

        // THE REPRODUCTION, as the user performs it: retag from the card's
        // badge menu (`MessageCardView.actionTagBadge` → `applyManualTag`), then
        // archive. Both are synchronous MainActor gestures with no suspension
        // between them, exactly as two taps are — nothing can re-read the row
        // and quietly repair the in-memory header in between.
        let target = try #require(vm.message)
        vm.applyManualTag(target, tag: .delete)
        #expect(vm.message?.actionTag == .delete, "the retag took, so this is the header the undo capture sees")
        #expect(vm.archive(), "archive must be recorded — otherwise no undo entry exists to assert on")

        await settle()

        // Anchor the mid-state: the forward move landed, so the undo below is
        // reversing a real move rather than asserting on an untouched row.
        let archived = try #require(
            try await pool.read { db in try MessageHeader.fetchOne(db, key: focused.id) })
        #expect(archived.folderPath == Self.archivePath)
        #expect(archived.isInInbox == false)

        #expect(UndoService.shared.undoStack.count == 1, "the detail archive pushed exactly one undoable action")
        await UndoService.shared.undo()
        await settle()

        let restored = try #require(
            try await pool.read { db in try MessageHeader.fetchOne(db, key: focused.id) })
        #expect(restored.folderPath == Self.inboxPath,
                "non-vacuity: the undo restore actually wrote — a refusal would leave the archived row untouched")
        #expect(restored.tagSortOrder == (restored.actionTag?.sortOrder ?? 99),
                """
                durably restored a split pair: (actionTag: \
                \(restored.actionTag?.rawValue ?? "nil"), tagSortOrder: \(restored.tagSortOrder)) \
                — the chip and the triage bucket disagree, the shape migration v58 heals once and never again
                """)
    }
}
