/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Pins the fix for the "dead toggle under write-queue lag" bug: `toggleRead`,
/// `markRead(_ messageIds:)`, and `toggleFlag` used to gate the USER GESTURE
/// behind `lookupMessage` — a synchronous main-actor `dbPool.read` — and
/// derive the target state (`newIsRead = !message.isRead`) from that DB row.
/// The DB lags the FIFO write queue by seconds under write bursts (logged
/// main-thread stalls up to 3.7s), so a second toggle within that window read
/// the SAME stale value as the first and computed the SAME target — a dead
/// no-op toggle from the user's perspective (log-confirmed: a drain of
/// `markRead×3 + markUnread×2` = the user hammering a dead toggle).
///
/// The fix: derive current state from the ON-SCREEN snapshot (`loadedMessages`)
/// — the visualized state the user is acting on — and resolve the
/// `MessageHeader` needed for the actual write OFF-MAIN, inside the already-
/// queued `enqueueWrite` closure, via the new `AccountManager.resolveHeaderForAction`
/// / `resolveHeadersForAction` helpers (one implementation shared with
/// `InboxViewModel.lookupMessage`'s two-step durable/staged-synthesis lookup).
///
/// `.serialized`: tests touch `AccountManager.shared`'s process-wide optimistic
/// overlay + FIFO write queue and `NSEDataBridge.latestStagedRows` — mirrors
/// `InboxListBehaviorPinningTests` / `MessageDetailStagedFallbackTests`.
@Suite("Inbox gesture actions — zero-DB, act-on-visualized-state (dead-toggle fix)", .serialized, .processGlobalState)
@MainActor
struct InboxGestureActionTests {

    // MARK: - Harness (mirrors InboxListBehaviorPinningTests.swift)

    private func makeTestDB(
        provider: AccountProvider = .gmail,
        inboxPath: String = "INBOX",
        archivePath: String = "Archive"
    ) throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
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
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: provider)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: inboxPath, role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: archivePath, role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    enum StatefulRESTKind: String, CaseIterable, Sendable {
        case gmail
        case exchange
    }

    enum StatefulSetter: String, Sendable {
        case read
        case unread
        case flag
        case unflag

        var initialRead: Bool { self == .unread }
        var initialFlagged: Bool { self == .unflag }
        var expectedRead: Bool {
            switch self {
            case .read: true
            case .unread: false
            case .flag, .unflag: initialRead
            }
        }
        var expectedFlagged: Bool {
            switch self {
            case .flag: true
            case .unflag: false
            case .read, .unread: initialFlagged
            }
        }
    }

    struct StatefulSetterArgument: Sendable {
        let kind: StatefulRESTKind
        let setter: StatefulSetter
    }

    private struct StatefulRemoteState: Sendable, Equatable {
        let providerMessageId: String
        let folderPath: String
        let isRead: Bool
        let isFlagged: Bool
        let providerLabelIds: Set<String>
    }

    private struct StatefulRESTFixture: Sendable {
        let accountProvider: AccountProvider
        let inboxPath: String
        let archivePath: String
        let initialProviderMessageId: String
        let provider: any EmailProvider
        let makeProvider: @Sendable () -> any EmailProvider
        let snapshots: @Sendable (String) -> [StatefulRemoteState]
        let failNextLookup: @Sendable () -> Void
        let consumedLookupFailureCount: @Sendable () -> Int
        let close: @Sendable () -> Void
    }

    private func makeStatefulRESTFixture(
        kind: StatefulRESTKind,
        rfc822MessageId: String,
        initialRead: Bool = false,
        initialFlagged: Bool = false,
        remoteCopies: Int = 1,
        gmailUserLabels: [String: String] = [:],
        initialRemoteUserLabelIds: Set<String> = []
    ) -> StatefulRESTFixture {
        precondition(remoteCopies >= 0)
        let suffix = UUID().uuidString.lowercased()
        switch kind {
        case .gmail:
            let providerMessageId = "gmail-resource-\(suffix)"
            var labels: Set<String> = ["INBOX"]
            if !initialRead { labels.insert("UNREAD") }
            if initialFlagged { labels.insert("STARRED") }
            labels.formUnion(initialRemoteUserLabelIds)
            let seeds = (0..<remoteCopies).map { index in
                StatefulGmailActionServer.Seed(
                    rfc822MessageId: rfc822MessageId,
                    providerMessageId: index == 0
                        ? providerMessageId : "gmail-duplicate-\(index)-\(suffix)",
                    labels: labels
                )
            }
            let server = StatefulGmailActionServer(
                messages: seeds,
                userLabels: gmailUserLabels
            )
            return StatefulRESTFixture(
                accountProvider: .gmail,
                inboxPath: "INBOX",
                archivePath: GmailProvider.archivePath,
                initialProviderMessageId: providerMessageId,
                provider: server.provider(),
                makeProvider: { server.provider() },
                snapshots: { rfc822MessageId in
                    server.snapshots(rfc822MessageId: rfc822MessageId).map { snapshot in
                        StatefulRemoteState(
                            providerMessageId: snapshot.providerMessageId,
                            folderPath: snapshot.labels.contains("INBOX")
                                ? "INBOX" : GmailProvider.archivePath,
                            isRead: snapshot.isRead,
                            isFlagged: snapshot.isFlagged,
                            providerLabelIds: snapshot.labels
                        )
                    }
                },
                failNextLookup: { server.failNextLookup() },
                consumedLookupFailureCount: { server.consumedLookupFailureCount() },
                close: { server.close() }
            )
        case .exchange:
            let providerMessageId = "graph/original+\(suffix)="
            let seeds = (0..<remoteCopies).map { index in
                StatefulExchangeActionServer.Seed(
                    rfc822MessageId: rfc822MessageId,
                    providerMessageId: index == 0
                        ? providerMessageId : "graph/duplicate+\(index)-\(suffix)=",
                    folderId: "source-folder",
                    isRead: initialRead,
                    isFlagged: initialFlagged
                )
            }
            let server = StatefulExchangeActionServer(messages: seeds)
            return StatefulRESTFixture(
                accountProvider: .outlook,
                inboxPath: "source-folder",
                archivePath: "destination-folder",
                initialProviderMessageId: providerMessageId,
                provider: server.provider(),
                makeProvider: { server.provider() },
                snapshots: { rfc822MessageId in
                    server.snapshots(rfc822MessageId: rfc822MessageId).map { snapshot in
                        StatefulRemoteState(
                            providerMessageId: snapshot.providerMessageId,
                            folderPath: snapshot.folderId,
                            isRead: snapshot.isRead,
                            isFlagged: snapshot.isFlagged,
                            providerLabelIds: []
                        )
                    }
                },
                failNextLookup: { server.failNextLookup() },
                consumedLookupFailureCount: { server.consumedLookupFailureCount() },
                close: { server.close() }
            )
        }
    }

    private func makeStagedRow(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        date: Date = Date(),
        isRead: Bool = false,
        isFlagged: Bool = false,
        rfc822MessageId: String? = nil,
        includeRFCIdentity: Bool = true
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: includeRFCIdentity
                ? (rfc822MessageId ?? "<\(accountId)-\(messageId)@example.com>")
                : nil,
            threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: date,
            isRead: isRead, isFlagged: isFlagged, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    /// A durable, query-visible header (`headerComplete = true`) for a folder.
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        date: Date = Date(),
        isRead: Bool = false,
        isFlagged: Bool = false,
        isInInbox: Bool? = nil,
        rfc822MessageId: String? = nil,
        includeRFCIdentity: Bool = true
    ) -> MessageHeader {
        // nil derives from the folder's role (matching the sibling harnesses
        // in CoordinatedToolActionTests/NotificationActionRouterTests) so an
        // archive/trash-resident row never silently claims inbox membership —
        // the executor's tag WRITE gate and every tag renderer's display gate
        // key on isInInbox, and the old fixed `= true` default let
        // non-production row shapes into pins (test-review round 15). Pass
        // explicitly only when a test deliberately needs a contradictory shape.
        let resolvedIsInInbox = isInInbox ?? (folder.role == .inbox)
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: date, snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: resolvedIsInInbox
        )
        h.headerComplete = true
        h.isRead = isRead
        h.isFlagged = isFlagged
        h.rfc822MessageId = includeRFCIdentity
            ? (rfc822MessageId ?? "<\(folder.accountId)-\(messageId)@example.com>")
            : nil
        return h
    }

    /// Teardown shared by every test. The production paths these tests drive
    /// fire UNSTRUCTURED background Tasks the drain barrier cannot join
    /// (drainPendingQueue, unread recounts, queueTagWrite's drain hop,
    /// applyManualTag steps 3-4) — they can run AFTER the defers. Restoring a
    /// nil `previous` would make `AppDatabase.rawPool`'s force-unwrap
    /// fatalError the whole test process, so when there is no previous
    /// AppDatabase, leave the test one (and its files) alive. Mirrors
    /// `MessageDetailStagedFallbackTests.pinSurvivesWhileMoveQueued`.
    private func restoreTestDB(previous: AppDatabase?, dir _: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
        }
        // Do not unlink a test database from inside the running test process.
        // Gesture actions intentionally launch background drain/recount work that
        // can still own SQLite descriptors after the explicit FIFO barrier. The
        // next xcodebuild install gets a fresh simulator app container, whose tmp
        // teardown safely owns these directories; eager removal here produces
        // SQLite "vnode unlinked while in use" API violations and false I/O errors.
    }

    private func clearOverlay() {
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    /// Enqueue a barrier onto `AccountManager.shared`'s FIFO write queue and
    /// await it — since the queue is strictly FIFO, every write enqueued
    /// BEFORE this call is guaranteed to have drained by the time this
    /// returns. Mirrors `MessageDetailStagedFallbackTests.pinSurvivesWhileMoveQueued`'s
    /// closing barrier.
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

    /// Journal seam (ADR-IOS-058) replacing `pendingIntentCyclesForTesting()`'s
    /// net-intent checks: folds the journal's currently-pending records (pure,
    /// no I/O — `IntentionFold.fold`) and returns `id`'s net intent, or nil
    /// when the journal holds no pending records for it.
    private func journalNetIntent(for id: String) -> IntentionFieldIntents? {
        IntentionFold.fold(AccountManager.shared.intentionJournal.recordsForTesting()).perId[id]
    }

    nonisolated private func durableId(_ message: MessageHeader) -> String {
        MessageIdentity.durableActionRFC822MessageId(message.rfc822MessageId)!
    }

    @Test("RFC admission refuses missing/malformed single-message gestures before snapshot, journal, or Undo mutation")
    func invalidRFCSingleGesturesAreSideEffectFree() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let missing = makeDurableHeader(
            folder: inbox, messageId: "m-rfc-missing", isRead: false,
            isFlagged: false, includeRFCIdentity: false
        )
        let malformed = makeDurableHeader(
            folder: inbox, messageId: "m-rfc-malformed", isRead: false,
            rfc822MessageId: "<broken@example.com"
        )
        let blankSource: MessageHeader = {
            var header = makeDurableHeader(
                folder: inbox, messageId: "m-source-blank", isRead: false
            )
            header.folderPath = "   "
            return header
        }()
        let valid = makeDurableHeader(
            folder: inbox, messageId: "m-blank-destination", isRead: false
        )
        try await pool.writeWithoutTransaction { db in
            try missing.insert(db)
            try malformed.insert(db)
            try blankSource.insert(db)
            try valid.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(!vm.durableMessageActionIsAdmissible(missing.id))
        #expect(!vm.durableMessageActionIsAdmissible(malformed.id))
        #expect(!vm.durableMessageActionIsAdmissible(blankSource.id))
        #expect(vm.admissibleDurableMessageActionIds([missing.id, malformed.id, blankSource.id]).isEmpty)

        vm.toggleRead(missing.id)
        vm.toggleFlag(missing.id)
        #expect(!vm.archive(missing.id))
        #expect(!vm.move(malformed.id, toFolderPath: "Archive"))
        #expect(!vm.archive(blankSource.id))
        #expect(!vm.move(valid.id, toFolderPath: " \n"))
        #expect(vm.moveThread([valid.id], toFolderPath: "\t") == [valid.id])

        let missingSnapshot = vm.loadedMessages.first { $0.id == missing.id }
        #expect(missingSnapshot?.isRead == false)
        #expect(missingSnapshot?.isFlagged == false)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().isEmpty)
        #expect(AccountManager.shared.snapshotOverlay().isEmpty)
        #expect(UndoService.shared.undoStack.isEmpty)

        let providerOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(providerOps.isEmpty)
    }

    @Test("RFC admission filters a mixed archive thread and acts only on the valid member")
    func mixedRFCArchiveThreadActsOnlyOnValidMember() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let valid = makeDurableHeader(folder: inbox, messageId: "m-rfc-valid")
        let invalid = makeDurableHeader(
            folder: inbox, messageId: "m-rfc-invalid",
            rfc822MessageId: "bad@example.com>"
        )
        try await pool.writeWithoutTransaction { db in
            try valid.insert(db)
            try invalid.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.admissibleDurableMessageActionIds([valid.id, invalid.id]) == [valid.id],
                "the View must hide only the admitted member")

        let skipped = vm.archiveThread([valid.id, invalid.id])
        #expect(skipped == [invalid.id])
        #expect(
            UndoService.shared.currentAction?.commands.flatMap { $0.members.map(\.originalHeaderId) } == [valid.id]
        )
        #expect(AccountManager.shared.snapshotOverlay()[invalid.id] == nil)

        await drainWriteQueue()
        let final = try await pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: valid.id),
                try MessageHeader.fetchOne(db, key: invalid.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(final.0?.folderId == archive.id)
        #expect(final.1?.folderId == inbox.id)
        #expect(final.2.flatMap { $0.messageIds } == ["acc1-m-rfc-valid@example.com"])
    }

    @Test("removeUserLabel refuses invalid RFC before visible/durable mutation and queues normalized RFC for a valid row")
    func removeUserLabelUsesRFCAdmissionAtPublicBoundary() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let label = UserLabel(
            id: "label-rfc-admission", accountId: "acc1",
            name: "Project", isSystem: false
        )
        let invalid = makeDurableHeader(
            folder: inbox, messageId: "m-label-rfc-missing",
            includeRFCIdentity: false
        )
        let valid = makeDurableHeader(
            folder: inbox, messageId: "m-label-rfc-valid",
            rfc822MessageId: "<valid-label@example.com>"
        )
        try await pool.writeWithoutTransaction { db in
            try label.insert(db)
            try invalid.insert(db)
            try valid.insert(db)
            try MessageUserLabel(messageId: invalid.id, accountId: "acc1", userLabelId: label.id).insert(db)
            try MessageUserLabel(messageId: valid.id, accountId: "acc1", userLabelId: label.id).insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        let invalidSnapshot = try #require(vm.loadedMessages.first { $0.id == invalid.id })
        let validSnapshot = try #require(vm.loadedMessages.first { $0.id == valid.id })
        #expect(invalidSnapshot.userLabels.map(\.id) == [label.id])
        #expect(validSnapshot.userLabels.map(\.id) == [label.id])

        let foreignLabel = UserLabel(
            id: label.id,
            accountId: "different-account",
            name: "Different Account Label",
            isSystem: false
        )
        await vm.removeUserLabel(foreignLabel, from: validSnapshot)
        let afterAccountRefusal = try await pool.read { db in
            (
                try MessageUserLabel
                    .filter(Column("messageId") == valid.id && Column("userLabelId") == label.id)
                    .fetchCount(db),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(afterAccountRefusal.0 == 1)
        #expect(afterAccountRefusal.1.isEmpty)
        #expect(vm.loadedMessages.first { $0.id == valid.id }?.userLabels.map(\.id) == [label.id])

        await vm.removeUserLabel(label, from: invalidSnapshot)
        let afterRefusal = try await pool.read { db in
            (
                try MessageUserLabel
                    .filter(Column("messageId") == invalid.id && Column("userLabelId") == label.id)
                    .fetchCount(db),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(afterRefusal.0 == 1)
        #expect(afterRefusal.1.isEmpty)
        #expect(vm.loadedMessages.first { $0.id == invalid.id }?.userLabels.map(\.id) == [label.id])

        await vm.removeUserLabel(label, from: validSnapshot)
        let afterSuccess = try await pool.read { db in
            (
                try MessageUserLabel
                    .filter(Column("messageId") == valid.id && Column("userLabelId") == label.id)
                    .fetchCount(db),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(afterSuccess.0 == 0)
        let removeOps = afterSuccess.1.filter { $0.type == .removeUserLabel }
        #expect(removeOps.count == 1)
        guard removeOps.count == 1 else { return }
        #expect(removeOps[0].messageIds == ["valid-label@example.com"])
        #expect(removeOps[0].accountId == "acc1")
        #expect(removeOps[0].folderPath == inbox.path)
        #expect(removeOps[0].userLabelId == label.id)
        #expect(vm.loadedMessages.first { $0.id == valid.id }?.userLabels.isEmpty == true)
    }

    @Test("Outlook label removal leaves visible, local, and durable final state unchanged")
    func removeUserLabelRefusesUnsupportedProvider() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB(provider: .outlook)
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let label = UserLabel(
            id: "outlook-local-label",
            accountId: "acc1",
            name: "Local only",
            isSystem: false
        )
        let header = makeDurableHeader(
            folder: inbox,
            messageId: "outlook-label-removal",
            rfc822MessageId: "<outlook-label-removal@example.com>"
        )
        try await pool.writeWithoutTransaction { db in
            try label.insert(db)
            try header.insert(db)
            try MessageUserLabel(
                messageId: header.id,
                accountId: header.accountId,
                userLabelId: label.id
            ).insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        let snapshot = try #require(vm.loadedMessages.first { $0.id == header.id })
        #expect(snapshot.userLabels.map(\.id) == [label.id])

        await vm.removeUserLabel(label, from: snapshot)

        let final = try await pool.read { db in
            (
                try MessageUserLabel
                    .filter(Column("messageId") == header.id && Column("userLabelId") == label.id)
                    .fetchCount(db),
                try PendingOperation.fetchCount(db)
            )
        }
        #expect(final.0 == 1)
        #expect(final.1 == 0)
        #expect(vm.loadedMessages.first { $0.id == header.id }?.userLabels.map(\.id) == [label.id])
    }

    // MARK: - (a) Rapid double-toggle correctness

    @Test("toggleRead: a second toggle immediately after the first flips BACK, derived from the visualized snapshot — not a stale DB read")
    func rapidDoubleToggleReadDerivesFromVisualizedState() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.first?.isRead == false)

        // Block the FIFO write queue BEFORE either toggle so neither queued
        // write can drain while we assert the visualized (snapshot) state —
        // mirrors MessageDetailStagedFallbackTests.pinSurvivesWhileMoveQueued.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        // Toggle #1: unread -> read.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true)

        // Toggle #2, IMMEDIATELY (no drain in between): derived from the
        // JUST-FLIPPED visualized snapshot ("read"), so this MUST flip back
        // to unread. Pre-fix, `toggleRead` gated on a synchronous
        // `lookupMessage` DB read — the DB row is still "unread" here too
        // (the write queue is gated, and even ungated the first write hasn't
        // executed yet), so BOTH toggles would compute the same
        // unread -> read target: a dead second toggle.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == false, "second toggle did not flip back — computed from a stale source instead of the visualized snapshot")

        // The DB row itself is untouched while gated — confirms the gesture
        // path performed zero durable writes ahead of the queue.
        let dbIsReadWhileGated = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(dbIsReadWhileGated == false)

        // Round-2 audit: this test was an outlier — every other gated test in
        // this file releases the gate explicitly and drains before returning
        // (the file's own convention). `defer { gate.finish() }` released the
        // gate as the function returned WITHOUT draining, letting the two
        // now-unblocked fold closures escape into whatever test runs next.
        gate.finish()
        await drainWriteQueue()
    }

    // MARK: - (b) Zero-DB gesture on a staged-only row

    @Test("toggleRead on a staged-only row (no durable header) flips the snapshot instantly; the queued write resolves via the ADR-IOS-049 staged synthesis and no-ops gracefully with zero durable rows")
    func toggleReadOnStagedOnlyRowFlipsInstantlyAndResolvesGracefully() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-staged-toggle", isRead: false)
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-staged-toggle")
        #expect(vm.loadedMessages.first?.isRead == false)

        // Gesture: the snapshot flips INSTANTLY — the row is not durable
        // anywhere at gesture time, so a gesture-path DB read would have
        // found nothing durable either; the fix never attempts one.
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true)

        // Mechanism check: the SAME resolution the queued closure uses finds
        // this id via the staged synthesis (mirrors `lookupMessage`'s
        // two-step lookup) — this is what lets the queued write complete
        // even though the row was never durable when the gesture fired.
        let resolved = await AccountManager.shared.resolveHeaderForAction(id: id)
        #expect(resolved != nil)
        #expect(resolved?.id == id)

        // End-to-end: drain the real queued closure. `AccountManager.markRead`
        // -> `ensureDurable` sees the id missing from GRDB and calls
        // `NSEMergeCoordinator.shared.merge()`, which safely no-ops in the
        // test host (no app-group container — see NSEDataBridge.performMerge's
        // early-return branch), then the UPDATE touches zero durable rows.
        // Achievable contract: the gesture never strands, crashes, or hangs
        // on a not-yet-durable id — it just can't durably persist a row that
        // was never written to GRDB (a real device's `ensureDurable` merges
        // the row durable first via the production app-group path).
        await drainWriteQueue()
        let dbCount = try await pool.read { db in try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db) }
        #expect(dbCount == 0, "no durable row ever existed for this id — the write is a graceful no-op, not a crash/hang")
    }

    // MARK: - (c) Batch markRead with mixed on-/off-screen members

    @Test("markRead(_:) computes per-member state correctly when some members are off-screen — mixed read/unread, only some in loadedMessages; ONE batch intention record (ADR-IOS-058) retains once per member id at gesture time (off-screen included, even already-read) and releases fully at fold completion")
    func markReadHandlesMixedOnAndOffScreenMembers() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // On-screen: one unread, one already-read. Loaded into the VM below.
        let onScreenUnread = makeDurableHeader(folder: inbox, messageId: "m-onscreen-unread", isRead: false)
        let onScreenRead = makeDurableHeader(folder: inbox, messageId: "m-onscreen-read", isRead: true)
        try await pool.writeWithoutTransaction { db in
            let a = onScreenUnread; try a.insert(db)
            let b = onScreenRead; try b.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 2)

        // Off-screen: durable in GRDB but inserted AFTER the VM's initial
        // load, so neither is ever in `loadedMessages` — simulates a thread
        // member captured in a stale `ThreadGroup` value that the current
        // `loadedMessages` no longer carries (see markRead's doc comment).
        // One is unread, one is ALREADY READ — the already-read off-screen
        // member exercises the fold executor's row-truth skip (ADR-IOS-058):
        // the gesture path cannot know its current state without a DB read,
        // so it is retained + recorded like every other member, and the fold
        // consumes/releases it transiently with no write.
        let offScreenUnread = makeDurableHeader(folder: inbox, messageId: "m-offscreen-unread", isRead: false)
        let offScreenRead = makeDurableHeader(folder: inbox, messageId: "m-offscreen-read", isRead: true)
        try await pool.writeWithoutTransaction { db in
            try offScreenUnread.insert(db)
            try offScreenRead.insert(db)
        }
        #expect(!vm.loadedMessages.contains { $0.id == offScreenUnread.id })
        #expect(!vm.loadedMessages.contains { $0.id == offScreenRead.id })

        // Gate the FIFO write queue before the gesture so the fold closure
        // record() enqueues stays queued while we inspect mid-flight overlay
        // state (mirrors threadBatchRetainsPerMemberAndReleasesPerMember).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.markRead([onScreenUnread.id, onScreenRead.id, offScreenUnread.id, offScreenRead.id])

        // Optimistic UI: only the on-screen UNREAD member flips immediately;
        // the already-read member is untouched; off-screen members have no
        // snapshot to mutate.
        #expect(vm.loadedMessages.first { $0.id == onScreenUnread.id }?.isRead == true)
        #expect(vm.loadedMessages.first { $0.id == onScreenRead.id }?.isRead == true)
        #expect(vm.loadedMessages.count == 2, "off-screen members must not be inserted into loadedMessages by markRead")

        // `record()` retains + registers the display overlay synchronously
        // (before the fold's executor Task is even spawned) — no sleep
        // needed to observe it, mirrors midDrainReloadShowsFinalIntentAcrossAlternatingToggles.
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(onScreenUnread.id) }.count == 1, "on-screen unread member has a pending record at gesture time")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(offScreenUnread.id) }.count == 1, "off-screen unread member has a pending record at gesture time (was in-closure pre-ADR-IOS-058)")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(offScreenRead.id) }.count == 1, "off-screen ALREADY-READ member has a pending record too — the gesture path cannot know its current state without a DB read")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(onScreenRead.id) }.count == 0, "on-screen already-read member is excluded from the batch entirely — filtered at gesture time from the visualized snapshot")

        // Let the fold's executor Task actually append behind the gate
        // before releasing it (mirrors threadBatchRetainsPerMemberAndReleasesPerMember).
        try await Task.sleep(for: .milliseconds(50))
        gate.finish()
        await drainWriteQueue()

        // Final DB truth: the on-screen unread member and the off-screen
        // unread member both end up read; the already-read members are
        // unaffected — the fold executor's row-truth compare skips a
        // redundant write for both (ADR-IOS-058 semantics refinement: the
        // OLD on-screen path wrote unconditionally even when already true).
        let finalStates = try await pool.read { db -> [String: Bool] in
            var result: [String: Bool] = [:]
            for id in [onScreenUnread.id, onScreenRead.id, offScreenUnread.id, offScreenRead.id] {
                result[id] = try MessageHeader.fetchOne(db, key: id)?.isRead
            }
            return result
        }
        #expect(finalStates[onScreenUnread.id] == true)
        #expect(finalStates[onScreenRead.id] == true)
        #expect(finalStates[offScreenUnread.id] == true, "off-screen unread member was not resolved+written by the fold")
        #expect(finalStates[offScreenRead.id] == true, "off-screen already-read member's row truth is untouched (was already true)")

        // Post-drain: journal fully drained, overlay + refcounts empty for
        // every member id — including the already-read ones the fold
        // consumed/released transiently with no write.
        #expect(AccountManager.shared.snapshotOverlay()[onScreenUnread.id] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[offScreenUnread.id] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[offScreenRead.id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after markRead batch drain")
    }

    // MARK: - (d) toggleFlag equivalent of (a)

    @Test("toggleFlag: a second toggle immediately after the first flips BACK, derived from the visualized snapshot — not a stale DB read")
    func rapidDoubleToggleFlagDerivesFromVisualizedState() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-flag-toggle", isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isFlagged == false)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        vm.toggleFlag(id)
        #expect(vm.loadedMessages.first?.isFlagged == true)

        vm.toggleFlag(id)
        #expect(vm.loadedMessages.first?.isFlagged == false, "second toggle did not flip back — computed from a stale source instead of the visualized snapshot")

        let dbIsFlaggedWhileGated = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isFlagged }
        #expect(dbIsFlaggedWhileGated == false)

        // Round-2 audit: outlier fix, see rapidDoubleToggleReadDerivesFromVisualizedState.
        gate.finish()
        await drainWriteQueue()
    }

    // MARK: - (e) Overlay-drain correctness

    @Test("toggleRead: after the queued write drains, DB truth matches the LAST toggle's target, not the first — and since the two toggles round-trip back to the original state, the coalesced cycle (ADR-IOS-057) executes as a perfect cancel-out: zero PendingOperations")
    func drainedDBStateMatchesLastToggleTarget() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-drain", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so both toggles are guaranteed to land in the SAME
        // cycle (without a gate, the first toggle's spawned executor Task
        // could race ahead and consume the cycle before the second toggle
        // call runs, splitting them into two independent, non-cancelling
        // writes instead of one coalesced cancel-out).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Two toggles register into ONE coalesced cycle: unread -> read -> unread.
        vm.toggleRead(id)
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == false)

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "final DB state must match the LAST toggle's target (unread), not the first (read)")

        // The overlay entry must not strand once the write has drained.
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[id] == nil, "overlay entry stranded after drain — releaseOverlayEntry did not run")

        // ADR-IOS-057 cancel-out contract: the cycle's final target (unread)
        // equals its baseline (unread) — the executor must not have called
        // markRead/markUnread at all, so zero PendingOperations exist.
        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")
    }

    // MARK: - (f) Latest-intent coalescing (ADR-IOS-057) — the alternating-toggle regression
    //
    // Pins the fix for the "dead toggle under write-queue lag" fix's OWN
    // regression (2026-07-10, logmain.log line 1743): `AccountManager.optimisticOverlay`
    // is COALESCED — one `PendingMutation` per id, always holding the LATEST
    // registered intent — but every queued gesture closure called
    // `manager.removeOverlayEntries(ids:)` unconditionally on ITS OWN
    // completion. With N alternating toggles queued FIFO behind a slow write
    // lane, op #1 completing wiped the coalesced entry (which by then already
    // carried op #N's registered intent, since `registerMutation` runs
    // SYNCHRONOUSLY at gesture time) while ops #2..N were still in flight —
    // every `reloadMessages()` call in that window fell through to raw DB
    // truth (an intermediate toggle target) instead of the user's final
    // intent. Same bug class as `MessageDetailViewModel.localMovePins`
    // (ADR-IOS-049 amendment round 8): "overlay-presence is the wrong proxy
    // for in-flight-ness — a sibling op's drain ends the window early."
    //
    // The refcount fix (retain/release) was the FIRST cure. ADR-IOS-057 then
    // coalesced repeated gesture intents for the SAME id into ONE
    // `AccountManager.IntentCycle`, holding exactly ONE retain and queueing
    // exactly ONE executor closure (`executeIntentCycle`) for N alternating
    // toggles. ADR-IOS-058 replaces the register with the intention journal +
    // `record()`: EVERY tap now appends its OWN journal record — the DERIVED
    // overlay is the fold of however many records are pending for an id, so N
    // taps leave N pending records, not one coalesced retain count — but the
    // FOLD-TIME coalescing survives: only the FIRST tap on an id with no open
    // component enqueues a fold closure (`executeFold`); later taps just
    // append to the journal and are swept into that SAME fold. The "op1+op2
    // done, op3 still queued" mid-drain window this test used to probe still
    // cannot happen for repeated toggles of the same field (there is only
    // ever one fold closure per open component) — what remains to pin is that
    // (a) N rapid toggles append N journal records behind ONE fold closure,
    // and (b) a reload while that fold is still queued shows the FINAL
    // registered intent, not raw (pre-gesture) DB truth.

    @Test("toggleRead: three rapid alternating toggles append to the journal behind ONE queued fold closure (ADR-IOS-058) — 3 pending records (one per tap), ONE fold; a reload while the fold is still gated shows the FINAL intent, and after release+drain DB truth matches the final intent with no strand")
    func midDrainReloadShowsFinalIntentAcrossAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-alt-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue BEFORE any toggle.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // Three rapid toggles: unread -> read -> unread -> read (final: read).
        // `registerGestureIntent` runs SYNCHRONOUSLY inside `toggleRead` (it
        // is a thin adapter over `record()`), so the overlay + journal are
        // already updated the instant each call returns; only the fold's ONE
        // executor closure (spawned once, on the FIRST toggle) is deferred
        // behind gate0.
        vm.toggleRead(id)
        vm.toggleRead(id)
        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true, "on-screen snapshot after 3 toggles must reflect the LAST toggle's target")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 3, "record() (ADR-IOS-058) appends once PER TAP — three toggles leave 3 pending records, still consumed by ONE fold")
        #expect(journalNetIntent(for: id)?.isRead == true, "journal's net isRead target must be the LAST toggle's value")

        // Let the fold's executor Task actually append behind gate0.
        try await Task.sleep(for: .milliseconds(50))

        // Regression check: reload while the fold's ONE closure is still
        // queued. Pre-fix (unconditional `removeOverlayEntries`, no
        // coalescing), an EARLIER op completing could wipe the overlay while
        // a later toggle was still in flight; post-fix there is only ever
        // ONE fold closure per open component, and it hasn't run yet — the
        // overlay must still carry the FINAL registered intent (read), not
        // raw (pre-gesture) DB truth (unread).
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true, "reload while the fold is still queued must show the FINAL intent")

        gate0.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true, "DB truth after full drain must match the LAST toggle's target")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after full drain")
    }

    // MARK: - (g) Refcount hygiene

    @Test("refcount hygiene: three toggles on the same id append 3 journal records behind ONE fold (ADR-IOS-058, 3 pending records — one per tap); after it drains, the overlay entry AND the journal are all empty — no strand")
    func refcountDrainsToEmptyAfterAlternatingToggles() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-refcount-hygiene", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so the fold's executor Task cannot race ahead and
        // consume the component between the three toggle calls below
        // (without a gate, the FIRST toggle's spawned Task could run to
        // completion on another thread before the third toggle call
        // executes, splitting one fold into two).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread
        vm.toggleRead(id) // -> read
        // The append is synchronous (runs inside toggleRead's registerGestureIntent
        // -> record() call, not the deferred closure) — the journal already
        // holds 3 pending records the instant these return: record()
        // (ADR-IOS-058) appends once PER TAP, and all three still fold into
        // ONE executor closure.
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 3, "three toggles on the same id append once per tap, leaving 3 pending records, while still folding into ONE closure")

        gate.finish()
        await drainWriteQueue()

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after the fold drained")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after it drained")
    }

    // MARK: - (h) Mixed gestures on the same id

    @Test("mixed gestures on the same id: toggleRead + toggleFlag append 2 journal records behind ONE fold (ADR-IOS-058, refcount 2 — one retain per tap) carrying both fields — a reload while that fold is still gated shows BOTH intents, and after release+drain the final state (snapshot + DB) reflects both")
    func mixedGesturesOnSameIdSurviveUntilBothComplete() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed", isRead: false, isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // gate0: blocks the FIFO write queue before either gesture.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // opens the component: isRead -> true
        vm.toggleFlag(id) // joins the SAME component: isFlagged -> true

        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "toggleRead + toggleFlag on the same id are TWO record() calls, each its own pending record (ADR-IOS-058) — 2 pending records, not one shared entry")

        // Let the fold's executor Task actually append behind gate0.
        try await Task.sleep(for: .milliseconds(50))

        // Mid-gate reload: NEITHER field has executed yet (one closure, still
        // queued) — the overlay must carry BOTH intents.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == true, "both intents must survive while the fold is still queued")

        gate0.finish()
        await drainWriteQueue()

        let final = try await pool.read { db -> (Bool?, Bool?) in
            let h = try MessageHeader.fetchOne(db, key: id)
            return (h?.isRead, h?.isFlagged)
        }
        #expect(final.0 == true)
        #expect(final.1 == true)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // MARK: - (i) Vanished-row path releases

    @Test("toggleRead on a row that vanishes before the queued write drains (never durable, never staged) still releases its overlay retain — no strand")
    func vanishedRowPathReleasesOverlayRetain() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        // Row is on-screen (VM-local, via insertStagedRows) but NEVER durable
        // in GRDB and NEVER registered in NSEDataBridge.latestStagedRows —
        // `resolveHeaderForAction` (durable-then-staged two-step lookup) will
        // find nothing for this id when the queued closure runs.
        let row = makeStagedRow(messageId: "m-vanished", isRead: false)
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-vanished")

        vm.toggleRead(id)
        #expect(vm.loadedMessages.first?.isRead == true, "optimistic flip happens regardless of durability")

        await drainWriteQueue()

        // The fold's executor closure hit the vanished-row branch
        // (`resolveHeadersForActionThrowing` found nothing durable) and
        // still runs its completion phase (`intentionJournal.completeExecution`)
        // — the overlay and journal must both be fully drained, not stranded.
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded on the vanished-row no-op path")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded on the vanished-row no-op path")

        let dbCount = try await pool.read { db in try MessageHeader.filter(Column("accountId") == "acc1").fetchCount(db) }
        #expect(dbCount == 0, "no durable row ever existed for this id — the write is a graceful no-op")
    }

    // MARK: - (j) Perfect cancel-out — zero writes

    @Test("4 alternating toggleRead taps (even count) cancel out to a perfect no-op: DB truth unchanged, zero PendingOperations, folder.unreadCount untouched, and the overlay/refcount/cycle registers all drain to empty")
    func alternatingTogglesCancelOutToZeroWrites() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-cancel-4x", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        let unreadCountBefore = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }

        let vm = InboxViewModel(folders: [inbox])

        // Gate the queue so all four taps land in the SAME fold component
        // deterministically (without a gate, the fold's executor Task could
        // race ahead and consume the component between taps, splitting them
        // into two folds).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread
        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread — back to baseline
        #expect(vm.loadedMessages.first?.isRead == false)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 4, "four taps on the same id append once per tap (ADR-IOS-058) — 4 pending records, still folded into ONE closure")

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "cancel-out must leave DB truth unchanged from baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")

        let unreadCountAfter = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unreadCountAfter == unreadCountBefore, "cancel-out must not touch folder.unreadCount")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("3 alternating toggleRead taps (odd count, net flip) execute as exactly ONE write of the final target — one PendingOperation, folder.unreadCount adjusted by exactly one")
    func oddToggleCountProducesExactlyOneWrite() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-odd-3x", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        // Seed unreadCount=1 (one unread message) so the post-markRead
        // decrement is observable — the harness's Folder init defaults to 0,
        // and markRead's `MAX(0, unreadCount - newlyRead)` would otherwise
        // clamp at 0 either way (see AccountManagerActionsTests for the same
        // seeding pattern).
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [inbox.id])
        }

        let vm = InboxViewModel(folders: [inbox])

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id) // read
        vm.toggleRead(id) // unread
        vm.toggleRead(id) // read — net flip
        #expect(vm.loadedMessages.first?.isRead == true)

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true, "net flip must land as read")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(pendingOps.count == 1, "3 toggles folding to a net flip must produce exactly ONE PendingOperation")
        guard pendingOps.count == 1 else { return }
        #expect(pendingOps[0].type == .markRead)

        let unreadCountAfter = try await pool.read { db in try Folder.fetchOne(db, key: inbox.id)?.unreadCount }
        #expect(unreadCountAfter == 0, "exactly one message transitioned unread -> read")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("a gesture registered after the previous fold for the same id has fully drained starts a NEW, independent fold — two round-trips land as two separate writes, no strand")
    func intentAfterCycleConsumedStartsNewCycle() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-new-cycle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        vm.toggleRead(id) // -> read
        // Let the fold's executor Task actually append to the FIFO queue
        // before the drain barrier's own Task races it (mirrors the settle
        // pattern used across this suite).
        try await Task.sleep(for: .milliseconds(50))
        await drainWriteQueue()

        let afterFirst = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterFirst == true)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "first fold must be fully consumed before the next gesture")

        vm.toggleRead(id) // starts a FRESH fold -> unread
        // Same settle: the second fold's executor append must land before
        // the drain barrier.
        try await Task.sleep(for: .milliseconds(50))
        await drainWriteQueue()

        let afterSecond = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterSecond == false, "the second gesture must start a NEW fold and execute independently, not be swallowed by the already-consumed first fold")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 2, "two independent (non-coalesced) folds must each produce their own PendingOperation")
    }

    // MARK: - (k) applyManualTag coalescing

    @Test("applyManualTag: tagging Reply then Archive on the same id (gated) appends 2 journal records behind ONE fold (ADR-IOS-058, refcount 2) whose executed write lands the LATEST tag, not the first")
    func tagRetagCoalescesToLatestTag() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-retag", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.applyManualTag(id, tag: .reply)
        vm.applyManualTag(id, tag: .archive)
        #expect(vm.loadedMessages.first?.actionTag == .archive)
        #expect(vm.loadedMessages.first?.tagSortOrder == ActionTag.archive.sortOrder,
                "the optimistic row must re-derive its triage sort key from the latest tag")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "two re-tags on the same id are TWO record() calls, each its own pending record (ADR-IOS-058) — 2 pending records, folded into ONE closure")

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalTag = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.actionTag }
        #expect(finalTag == .archive, "drain must land the LATEST tag, not the first")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("applyManualTag: tagging Reply then back to nil (the original baseline) is a perfect cancel-out — DB tag unchanged, zero PendingOperations")
    func tagBackToBaselineIsNoOp() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-cancel", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.applyManualTag(id, tag: .reply)
        vm.applyManualTag(id, tag: nil) // back to the original baseline (no tag)
        #expect(vm.loadedMessages.first?.actionTag == nil)

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalTag = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.actionTag }
        #expect(finalTag == nil, "cancel-out must leave DB tag at baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect tag cancel-out must never call applyManualTag/queueTagWrite — zero PendingOperations")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // MARK: - (l) The §1 mixed-path bypass regression — toggle + move on the same id
    //
    // Before this round, `InboxViewModel.archive`/`move`/etc. called
    // `manager.removeOverlayEntries(ids:)` UNCONDITIONALLY on their own
    // completion — bypassing the gesture-toggle refcount entirely. If a
    // toggle (or, now, an intent cycle) was still in flight for the SAME id
    // when an archive/move's closure completed, the move's unconditional
    // removal stripped the WHOLE coalesced overlay entry, including the
    // sibling op's still-pending intent (PLAN_OVERLAY_CALLSITE_AUDIT.md §1
    // "mixed-path refcount bypass"). Both directions are pinned below: the
    // move finishing first must not strip a still-pending toggle intent, and
    // the toggle finishing first must not strip a still-pending move intent.

    @Test("mixed-path regression: a toggleRead intent queued BEFORE an archive (move) for the SAME id — since ADR-IOS-058, archive() rides the SAME journal/record() path as toggleRead, so both records land in ONE connected component and execute behind ONE fold closure (not two separate closures); the overlay carries BOTH pending intents for the whole gated window and the final state reflects BOTH")
    func mixedToggleAndArchiveOnSameId() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        // File convention: archive() pushes an undo entry this test never
        // pops — clear at start and in defer so it can't leak into later
        // in-suite tests (test-review round 15).
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed-toggle-archive", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue before either op — both records
        // now join the SAME component (they share id), so ONE fold closure
        // (scheduled by the FIRST record) handles both; archive's record()
        // call sees `id` already fold-queued and does NOT schedule a second
        // closure (ADR-IOS-058).
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op1: toggleRead — opens the component's fold (retain=1), queues the
        // fold's executor closure behind gate0.
        vm.toggleRead(id)
        try await Task.sleep(for: .milliseconds(50)) // let the fold's executor Task append

        // op2: archive — takes its OWN retain (refcount 2 total) and joins
        // the SAME still-open component; no second closure is queued.
        vm.archive(id)

        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "the toggle and the archive each have their own pending record")
        #expect(AccountManager.shared.snapshotOverlay()[id]?.isRead == true, "the toggle's intent is visible in the overlay")
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == archive.id, "the archive's intent is visible in the overlay")

        // Mid-drain: reload while BOTH intentions are still gated (the shared
        // fold has not run yet). The row must appear moved out of the inbox —
        // the archive's folderId overlay intent is registered synchronously
        // at record() time, independent of when the (shared) fold executes.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty, "the row must appear moved out of the inbox while the shared fold is still gated")

        gate0.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "final DB state must reflect the archive move")
        #expect(final?.isRead == true, "final DB state must reflect the read intent")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("mixed-path regression, REVERSE order: an archive (move) queued BEFORE a toggleRead for the SAME id — since ADR-IOS-058, archive() opens the component's fold and the LATER toggleRead joins the SAME still-open component (no second closure); the overlay carries BOTH pending intents for the whole gated window and the final state reflects BOTH")
    func mixedArchiveAndToggleOnSameIdReverseOrder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        // File convention: see mixedToggleAndArchiveOnSameId (round 15).
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-mixed-archive-toggle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // gate0: blocks the FIFO write queue before either op — see
        // mixedToggleAndArchiveOnSameId's comment; the ordering of which
        // gesture opens the component doesn't matter, both land in one.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // op1: archive — opens the component's fold (retain=1), queues the
        // fold's executor closure behind gate0.
        vm.archive(id)
        try await Task.sleep(for: .milliseconds(50)) // let the fold's executor Task append

        // op2: toggleRead — takes its OWN retain (refcount 2 total) and joins
        // the SAME still-open component; no second closure is queued.
        vm.toggleRead(id)

        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "the archive and the toggle each have their own pending record")
        #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == archive.id, "the archive's intent is visible in the overlay")
        #expect(AccountManager.shared.snapshotOverlay()[id]?.isRead == true, "the toggle's intent is visible in the overlay")

        // Mid-drain: reload while BOTH intentions are still gated. The row
        // must still appear moved out of the inbox — the folderId overlay
        // intent survives regardless of which gesture opened the shared fold.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty, "the row must still appear moved out of the inbox while the shared fold is still gated")

        gate0.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
        #expect(final?.isRead == true)
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // MARK: - (n) Round-1 audit coverage gaps

    @Test("MessageDetailViewModel.toggleRead(): two gated calls round-trip back to baseline — a perfect cancel-out with zero PendingOperations, DB unchanged, and all registers empty")
    func detailToggleReadCancelOutIsZeroWrites() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-detail-cancel", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Lightest detail-VM harness (MessageDetailViewModelMoveTests): the
        // test-only init is zero-I/O, so seed `message` directly instead of
        // driving the async loadBody resolve.
        let vm = MessageDetailViewModel(messageId: id, dbPool: pool, fetchBodyOverride: { _ in })
        vm._testSeedMessage(header)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead() // unread -> read
        vm.toggleRead() // read -> unread (back to baseline)
        #expect(vm.message?.isRead == false)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 2, "two toggles on the same id are TWO record() calls, each its own pending record (ADR-IOS-058) — 2 pending records, folded into ONE closure")

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "cancel-out must leave DB truth unchanged from baseline")

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 0, "a perfect cancel-out must produce zero PendingOperations")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    @Test("toggleRead (net flip) + toggleFlag×2 (cancel-out) + applyManualTag (net local change) on the same id, via InboxViewModel, all append journal records behind ONE fold (ADR-IOS-058, 4 pending records — one per tap) — drain lands read + local tag; the flag stays untouched")
    func threeFieldsCoalesceInOneCycle() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-three-fields", isRead: false, isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.toggleRead(id)                  // isRead: false -> true (net flip)
        vm.toggleFlag(id)                  // isFlagged: false -> true
        vm.toggleFlag(id)                  // isFlagged: true -> false (cancel-out, back to baseline)
        vm.applyManualTag(id, tag: .reply) // actionTag: nil -> .reply (net change)

        #expect(vm.loadedMessages.first?.isRead == true)
        #expect(vm.loadedMessages.first?.isFlagged == false)
        #expect(vm.loadedMessages.first?.actionTag == .reply)
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 4, "all four gestures on the same id append once per tap (ADR-IOS-058) — 4 pending records, still folded into ONE closure")

        // Let the fold's executor Task actually append behind the gate.
        try await Task.sleep(for: .milliseconds(50))

        gate.finish()
        await drainWriteQueue()

        let finalHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(finalHeader?.isRead == true, "net isRead flip must land")
        #expect(finalHeader?.isFlagged == false, "flag round-tripped back to baseline — must be unchanged")
        #expect(finalHeader?.actionTag == .reply, "net tag change must land")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let opTypes = Set(pendingOps.map(\.type))
        #expect(!opTypes.contains(.markFlagged), "a perfect flag cancel-out must never write markFlagged")
        #expect(!opTypes.contains(.markUnflagged), "a perfect flag cancel-out must never write markUnflagged")
        #expect(opTypes.contains(.markRead), "the net isRead flip must produce a markRead op")
        #expect(!opTypes.contains(.setTag) && !opTypes.contains(.removeTag),
                "manual action tags are local-only and must not create provider work")
        #expect(pendingOps.count == 1, "only the net read flip creates provider work; the tag is local-only and the flag cancels out")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // Deviation from the spec's literal gate-INSIDE-the-write-path ask: there
    // is no production seam that pauses `executeFold` between consuming the
    // fold's records and its markRead/markUnread/markFlagged/applyManualTag
    // calls, and the write itself is a fast in-actor async DB write with no
    // natural pause point — gating it would mean adding a test-only seam to
    // production code purely for this test, out of scope for this fix batch.
    // Driven instead via the spec's own documented fallback: a fully-drained
    // first fold, then a second fold registered strictly afterward. Every
    // `drainWriteQueue()` call is a FIFO barrier, so this is fully
    // deterministic — no sleep-based race.
    @Test("a gesture registered strictly after a prior fold for the same id has fully drained starts a SECOND, independent fold whose own write is semantically necessary — final DB state matches the LAST registered intent and every register drains to empty (ADR-IOS-057 accepted residual, carried under ADR-IOS-058)")
    func sequentialCyclesEachExecuteIndependently() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tap-during-write", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // Fold 1: a single toggle, fully drained before fold 2 starts.
        vm.toggleRead(id) // -> read
        await drainWriteQueue()
        let afterFirst = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterFirst == true)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "fold 1 must be fully consumed before fold 2 starts")

        // Fold 2: registered strictly after fold 1's write has landed and
        // released. Three rapid toggles (odd count) net to a genuine flip —
        // this fold's write is semantically necessary, not a cancel-out.
        vm.toggleRead(id) // -> unread
        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread (net flip from fold 1's landed "read")
        await drainWriteQueue()

        let afterSecond = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(afterSecond == false, "final DB state must match fold 2's LAST registered intent, not fold 1's landed state")
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())

        let pendingOpsCount = try await pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(pendingOpsCount == 2, "two independent folds must each produce their own PendingOperation")
    }

    @Test("archiveThread with 2 members: each member id holds its OWN single retain while the move is gated; after drain both retains release independently and both rows land in the archive folder")
    func threadBatchRetainsPerMemberAndReleasesPerMember() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header1 = makeDurableHeader(folder: inbox, messageId: "m-thread-batch-1", isRead: false)
        let header2 = makeDurableHeader(folder: inbox, messageId: "m-thread-batch-2", isRead: false)
        try await pool.writeWithoutTransaction { db in
            try header1.insert(db)
            try header2.insert(db)
        }
        let id1 = header1.id
        let id2 = header2.id

        let vm = InboxViewModel(folders: [inbox])

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        vm.archiveThread([id1, id2])
        try await Task.sleep(for: .milliseconds(50)) // let the move closure append behind the gate

        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id1) }.count == 1, "each thread member has its own pending record")
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id2) }.count == 1, "each thread member has its own pending record")

        gate.finish()
        await drainWriteQueue()

        let final1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id1) }
        let final2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: id2) }
        #expect(final1?.folderId == archive.id, "member 1 must have moved to the archive folder")
        #expect(final2?.folderId == archive.id, "member 2 must have moved to the archive folder")

        #expect(AccountManager.shared.snapshotOverlay()[id1] == nil)
        #expect(AccountManager.shared.snapshotOverlay()[id2] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after full drain")
    }

    @Test("deleteThread moves every member to trash, RETAINS each member's local action tag (Round D-0 — display alone is hidden while pending), and creates one grouped Undo entry")
    func deleteThreadHappyPathOneBatchRecordSpansAllMembers() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }

        var header1 = makeDurableHeader(folder: inbox, messageId: "m-delthread-1", isRead: false)
        header1.actionTag = .reply
        var header2 = makeDurableHeader(folder: inbox, messageId: "m-delthread-2", isRead: true)
        header2.actionTag = .archive
        let header3 = makeDurableHeader(folder: inbox, messageId: "m-delthread-3", isRead: true) // untagged member
        try await pool.writeWithoutTransaction { [header1, header2] db in
            try header1.insert(db)
            try header2.insert(db)
            try header3.insert(db)
        }
        let ids = [header1.id, header2.id, header3.id]

        let vm = InboxViewModel(folders: [inbox])

        // Gate the FIFO write queue BEFORE the gesture so the batch record
        // stays pending while the mid-flight shape is asserted — mirrors the
        // archiveThread pin above.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        await vm.deleteThread(ids)

        // ONE grouped undo entry covering every member, pushed before
        // deleteThread returns.
        #expect(UndoService.shared.undoStack.count == 1, "one gesture pushes ONE grouped undo entry")
        #expect(UndoService.shared.currentAction?.totalMemberCount == 3, "the entry covers every member")

        // Per-member pending DISPLAY (not data): delete's destination is
        // never the inbox, so each member's display hint hides the tag while
        // pending (including the untagged member — the display asserts the
        // NET state, not a delta). This is a display-only overlay hint — the
        // underlying header retains its tag (Round D-0), asserted below.
        for id in ids {
            #expect(AccountManager.shared.snapshotOverlay()[id]?.folderId == trash.id, "pending display shows the trash destination for every member")
            #expect(AccountManager.shared.snapshotOverlay()[id]?.actionTag == ActionTag??.some(nil), "per-member pending display hides the tag while leaving the inbox")
        }

        gate.finish()
        await drainWriteQueue()

        let expectedTags: [String: ActionTag?] = [
            header1.id: .reply,
            header2.id: .archive,
            header3.id: nil,
        ]
        for id in ids {
            let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
            #expect(final?.folderId == trash.id, "every member must land durably in the trash-role folder")
            #expect(final?.actionTag == expectedTags[id], "Round D-0: each member's tag is RETAINED across the inbox-leaving move — no longer destructively cleared")
            #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry released after drain")
        }

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("Undo after a completed local archive restores the message to its original folder")
    func undoAfterCompletedArchiveRestoresOriginalFolder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-undo-after-exec", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])

        // No gate: let the archive fully drain BEFORE undo fires.
        vm.archive(id)
        await drainWriteQueue()

        let afterArchive = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterArchive?.folderId == archive.id, "archive must have fully executed before undo fires")

        await UndoService.shared.undo()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "undo must restore the message to its original folder")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after full drain")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after full drain")
    }

    @Test(
        "completed archive Undo survives provider recreation and converges by RFC identity",
        arguments: StatefulRESTKind.allCases
    )
    func statefulRESTArchiveUndoFinalOutcome(kind: StatefulRESTKind) async throws {
        let rfc822MessageId = "stateful-rest-undo-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: kind,
            rfc822MessageId: rfc822MessageId
        )
        defer { fixture.close() }
        let (pool, inbox, archive, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: archive, provider: fixture.provider)

            let archivedRemote = fixture.snapshots(rfc822MessageId)
            #expect(archivedRemote.count == 1)
            guard archivedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(archivedRemote[0].folderPath == fixture.archivePath)

            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            await UndoService.shared.undo()
            await drainWriteQueue()
            await AccountManager.shared.drainPendingQueue()
            try await waitForProviderQueueQuiescence()
            await AccountManager.shared.resetPendingQueuePreparationForTesting()

            let restartedProvider = fixture.makeProvider()
            await AccountManager.shared.registerProviderForTesting(
                accountId: "acc1",
                provider: restartedProvider
            )
            try await drainProviderQueue(pool: pool)
            try await syncEngine.syncFolderMessages(folder: inbox, provider: restartedProvider)

            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(remote[0].folderPath == fixture.inboxPath)
            #expect(!remote[0].isRead)
            #expect(!remote[0].isFlagged)
            switch kind {
            case .gmail:
                #expect(remote[0].providerMessageId == fixture.initialProviderMessageId)
            case .exchange:
                #expect(remote[0].providerMessageId != fixture.initialProviderMessageId)
            }

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(local[0].folderId == inbox.id)
            #expect(local[0].folderPath == inbox.path)
            #expect(local[0].isInInbox)
            #expect(local[0].messageId == remote[0].providerMessageId)
            #expect(!local[0].isRead)
            #expect(!local[0].isFlagged)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test(
        "cold notification archive automatically drains to final provider and local state",
        arguments: StatefulRESTKind.allCases
    )
    func statefulRESTColdNotificationArchiveFinalOutcome(kind: StatefulRESTKind) async throws {
        let rfc822MessageId = "stateful-rest-cold-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: kind,
            rfc822MessageId: rfc822MessageId
        )
        defer { fixture.close() }
        let (pool, _, archive, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            await NotificationActionRouter.execute(
                actionId: "ARCHIVE",
                transportMessageId: "irrelevant-transport-\(UUID().uuidString.lowercased())",
                rfc822MessageId: "<\(rfc822MessageId)>",
                accountId: "acc1"
            )

            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(remote[0].folderPath == fixture.archivePath)

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: archive,
                provider: fixture.provider
            )
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(local[0].folderId == archive.id)
            #expect(local[0].folderPath == archive.path)
            #expect(!local[0].isInInbox)
            #expect(local[0].messageId == remote[0].providerMessageId)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test("public Gmail label add and remove converge remotely and through ordinary sync")
    func statefulGmailUserLabelFinalOutcomes() async throws {
        let rfc822MessageId = "stateful-gmail-label-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "Label_\(UUID().uuidString.hashValue.magnitude)"
        let fixture = makeStatefulRESTFixture(
            kind: .gmail,
            rfc822MessageId: rfc822MessageId,
            gmailUserLabels: [labelId: "Project"]
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            _ = try await fixture.provider.fetchFolders()
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.applyLabel(label))
            try await drainProviderQueue(pool: pool)
            let addedRemote = fixture.snapshots(rfc822MessageId)
            #expect(addedRemote.count == 1)
            guard addedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(addedRemote[0].providerLabelIds.contains(labelId))
            let fetchedAfterAdd = try await fixture.provider.fetchMessages(
                folder: fixture.inboxPath,
                limit: 10,
                offset: 0
            )
            #expect(fetchedAfterAdd.count == 1)
            guard fetchedAfterAdd.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(fetchedAfterAdd[0].userLabelIds.contains(labelId))
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).count == 1)

            #expect(await menu.removeLabel(label))
            try await drainProviderQueue(pool: pool)
            let removedRemote = fixture.snapshots(rfc822MessageId)
            #expect(removedRemote.count == 1)
            guard removedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(!removedRemote[0].providerLabelIds.contains(labelId))
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test("ambiguous Gmail label add no-ops remotely and ordinary sync removes optimistic membership")
    func statefulGmailAmbiguousUserLabelFinalOutcome() async throws {
        let rfc822MessageId = "stateful-gmail-label-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "Label_\(UUID().uuidString.hashValue.magnitude)"
        let fixture = makeStatefulRESTFixture(
            kind: .gmail,
            rfc822MessageId: rfc822MessageId,
            remoteCopies: 2,
            gmailUserLabels: [labelId: "Project"]
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            _ = try await fixture.provider.fetchFolders()
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.applyLabel(label))
            try await drainProviderQueue(pool: pool)
            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 2)
            #expect(remote.allSatisfy { !$0.providerLabelIds.contains(labelId) })

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )
            #expect(try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            ).count == 2)
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test("ambiguous Gmail label remove no-ops remotely and ordinary sync restores membership")
    func statefulGmailAmbiguousUserLabelRemoveFinalOutcome() async throws {
        let rfc822MessageId = "stateful-gmail-label-remove-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "Label_\(UUID().uuidString.hashValue.magnitude)"
        let fixture = makeStatefulRESTFixture(
            kind: .gmail,
            rfc822MessageId: rfc822MessageId,
            remoteCopies: 2,
            gmailUserLabels: [labelId: "Project"],
            initialRemoteUserLabelIds: [labelId]
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            _ = try await fixture.provider.fetchFolders()
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
                try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: labelId)
                    .insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.removeLabel(label))
            try await drainProviderQueue(pool: pool)
            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 2)
            #expect(remote.allSatisfy { $0.providerLabelIds.contains(labelId) })

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )
            #expect(try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            ).count == 2)
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).count == 2)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test(
        "public read and flag setters converge final state locally and remotely",
        arguments: [
            StatefulSetterArgument(kind: .gmail, setter: .read),
            StatefulSetterArgument(kind: .gmail, setter: .unread),
            StatefulSetterArgument(kind: .gmail, setter: .flag),
            StatefulSetterArgument(kind: .gmail, setter: .unflag),
            StatefulSetterArgument(kind: .exchange, setter: .read),
            StatefulSetterArgument(kind: .exchange, setter: .unread),
            StatefulSetterArgument(kind: .exchange, setter: .flag),
            StatefulSetterArgument(kind: .exchange, setter: .unflag),
        ]
    )
    func statefulRESTSetterFinalOutcome(argument: StatefulSetterArgument) async throws {
        let rfc822MessageId = "stateful-rest-setter-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: argument.kind,
            rfc822MessageId: rfc822MessageId,
            initialRead: argument.setter.initialRead,
            initialFlagged: argument.setter.initialFlagged
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                isRead: argument.setter.initialRead,
                isFlagged: argument.setter.initialFlagged,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            switch argument.setter {
            case .read, .unread:
                viewModel.toggleRead(header.id)
            case .flag, .unflag:
                viewModel.toggleFlag(header.id)
            }
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: inbox, provider: fixture.provider)

            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(remote[0].folderPath == fixture.inboxPath)
            #expect(remote[0].isRead == argument.setter.expectedRead)
            #expect(remote[0].isFlagged == argument.setter.expectedFlagged)

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(local[0].folderId == inbox.id)
            #expect(local[0].messageId == remote[0].providerMessageId)
            #expect(local[0].isRead == argument.setter.expectedRead)
            #expect(local[0].isFlagged == argument.setter.expectedFlagged)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test(
        "public action against a missing RFC target stale-drops and final sync removes the ghost",
        arguments: StatefulRESTKind.allCases
    )
    func statefulRESTMissingTargetFinalOutcome(kind: StatefulRESTKind) async throws {
        let rfc822MessageId = "stateful-rest-missing-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: kind,
            rfc822MessageId: rfc822MessageId,
            remoteCopies: 0
        )
        defer { fixture.close() }
        let (pool, inbox, archive, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: archive,
                provider: fixture.provider
            )

            #expect(fixture.snapshots(rfc822MessageId).isEmpty)
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test(
        "public action against an ambiguous RFC target no-ops and final sync restores remote truth",
        arguments: StatefulRESTKind.allCases
    )
    func statefulRESTAmbiguousTargetFinalOutcome(kind: StatefulRESTKind) async throws {
        let rfc822MessageId = "stateful-rest-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: kind,
            rfc822MessageId: rfc822MessageId,
            remoteCopies: 2
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            viewModel.toggleRead(header.id)
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: fixture.provider
            )

            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 2)
            guard remote.count == 2 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(remote.allSatisfy { $0.folderPath == fixture.inboxPath })
            #expect(remote.allSatisfy { !$0.isRead })

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 2)
            guard local.count == 2 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(local.allSatisfy { $0.folderId == inbox.id })
            #expect(local.allSatisfy { !$0.isRead })
            #expect(Set(local.map(\.messageId)) == Set(remote.map(\.providerMessageId)))
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test(
        "transient RFC lookup failure survives provider recreation and reaches final state",
        arguments: StatefulRESTKind.allCases
    )
    func statefulRESTTransientRestartFinalOutcome(kind: StatefulRESTKind) async throws {
        let rfc822MessageId = "stateful-rest-restart-\(UUID().uuidString.lowercased())@example.com"
        let fixture = makeStatefulRESTFixture(
            kind: kind,
            rfc822MessageId: rfc822MessageId
        )
        defer { fixture.close() }
        let (pool, inbox, _, dir, previous) = try makeTestDB(
            provider: fixture.accountProvider,
            inboxPath: fixture.inboxPath,
            archivePath: fixture.archivePath
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: fixture.provider
        )

        do {
            let header = makeDurableHeader(
                folder: inbox,
                messageId: fixture.initialProviderMessageId,
                rfc822MessageId: "<\(rfc822MessageId)>"
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            fixture.failNextLookup()
            viewModel.toggleRead(header.id)
            await drainWriteQueue()
            if fixture.consumedLookupFailureCount() == 0 {
                await AccountManager.shared.drainPendingQueue()
            }
            try await waitForConsumedLookupFailure(fixture)
            try await waitForProviderQueueQuiescence()

            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            await AccountManager.shared.resetPendingQueuePreparationForTesting()
            let restartedProvider = fixture.makeProvider()
            await AccountManager.shared.registerProviderForTesting(
                accountId: "acc1",
                provider: restartedProvider
            )
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: inbox, provider: restartedProvider)

            let remote = fixture.snapshots(rfc822MessageId)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(remote[0].isRead)
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                return
            }
            #expect(local[0].isRead)
            #expect(local[0].messageId == remote[0].providerMessageId)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    @Test("Outlook archive then Undo survives a Graph resource-ID re-key and converges locally and remotely")
    func outlookArchiveUndoSurvivesGraphResourceIdRekey() async throws {
        let (pool, inbox, archiveFolder, dir, previous) = try makeTestDB(provider: .outlook)
        let provider = MockEmailProvider(messageFieldScope: .account)
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        do {
            let suffix = UUID().uuidString.lowercased()
            let rfcMessageId = "outlook-rekey-\(suffix)@example.com"
            let originalGraphId = "graph-before-\(suffix)"
            let currentGraphId = "graph-after-\(suffix)"
            let original = makeDurableHeader(
                folder: inbox,
                messageId: originalGraphId,
                rfc822MessageId: "<\(rfcMessageId)>"
            )
            try await pool.writeWithoutTransaction { db in
                try original.insert(db)
            }
            await provider.seedStatefulMessage(
                id: rfcMessageId,
                folder: inbox.path,
                providerMessageId: originalGraphId,
                nextProviderMessageIdAfterMove: currentGraphId
            )

            let viewModel = InboxViewModel(folders: [inbox])
            #expect(viewModel.archive(original.id))
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(
                folder: archiveFolder,
                provider: provider
            )

            let archivedCurrentId = MessageIdentity.headerId(
                accountId: "acc1",
                folderPath: archiveFolder.path,
                messageId: currentGraphId
            )
            let rekeyedArchive = try #require(
                try await waitForHeader(pool: pool, id: archivedCurrentId)
            )
            #expect(rekeyedArchive.folderId == archiveFolder.id)
            #expect(rekeyedArchive.folderPath == archiveFolder.path)
            #expect(rekeyedArchive.messageId == currentGraphId)
            let originalGeneration = try await pool.read { db in
                try MessageHeader.fetchOne(db, key: original.id)
            }
            #expect(originalGeneration == nil)
            #expect(await provider.statefulFolder(messageId: rfcMessageId) == archiveFolder.path)

            let currentId = MessageIdentity.headerId(
                accountId: "acc1",
                folderPath: inbox.path,
                messageId: currentGraphId
            )

            await UndoService.shared.undo()
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            try await syncEngine.syncFolderMessages(folder: inbox, provider: provider)

            let final = try #require(try await waitForHeader(pool: pool, id: currentId))
            #expect(final.folderId == inbox.id)
            #expect(final.folderPath == inbox.path)
            #expect(final.messageId == currentGraphId)
            #expect(await provider.statefulFolder(messageId: rfcMessageId) == inbox.path)
            #expect(AccountManager.shared.snapshotOverlay().isEmpty)
            #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
            let queueIsEmpty = try await pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            #expect(queueIsEmpty)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    // MARK: - ADR-IOS-060 Round D acceptance benchmarks

    /// THE benchmark (plan §"the bug the old design existed to prevent"):
    /// archive A, then delete A, then undo the delete. A naive matcher that
    /// scans PAST the newest related durable row (here: past the delete, to
    /// the archive) would wrongly cancel the archive too, permanently
    /// dropping it. The correct behavior: the newest related row (the
    /// delete) is the ONLY candidate ever considered; it is queued and its
    /// flip exactly equals the undo's inverse, so it is deleted — the
    /// archive (the protected first row) is never touched. Public entry
    /// points only; neither forward op is drained to the provider before
    /// Undo runs. Only final state is asserted.
    @Test("undoing a delete that followed an archive leaves the archive intact")
    func undoingDeleteAfterArchiveLeavesArchiveIntact() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let rfcMessageId = "bench-archive-delete-undo-\(UUID().uuidString.lowercased())@example.com"
        let header = makeDurableHeader(folder: inbox, messageId: "m-bench-ad", rfc822MessageId: "<\(rfcMessageId)>")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        let vm = InboxViewModel(folders: [inbox])

        // No provider registered yet — the automatic post-action drain Tasks
        // (`Task { await drainPendingQueue() }`) find no provider for the
        // account, requeue the claimed frontier, and stop (Round C); neither
        // op reaches the wire until this test explicitly registers one below.
        #expect(vm.archive(header.id), "archive must record")
        await drainWriteQueue()

        let afterArchive = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
        #expect(afterArchive.folderId == archive.id, "archive's local optimistic write must have landed")

        let deleted = await vm.delete(afterArchive.id)
        #expect(deleted, "delete (from Archive) must record")
        await drainWriteQueue()

        let afterDelete = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: afterArchive.id) })
        #expect(afterDelete.folderId == trash.id, "delete's local optimistic write must have landed")

        let opsBeforeUndo = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(opsBeforeUndo.count == 2, "both the archive and the delete are still queued, undrained")

        // Undo the most recent action — the delete.
        await UndoService.shared.undo()
        await drainWriteQueue()

        // Only now does a provider exist to drain against.
        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.seedStatefulMessage(id: rfcMessageId, folder: inbox.path, providerMessageId: header.messageId)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)
        do {
            try await drainProviderQueue(pool: pool)

            let final = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: afterArchive.id) })
            #expect(final.folderId == archive.id, "A must be in Archive")
            #expect(final.folderPath != trash.path, "A must NOT be in Trash")

            let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            #expect(queueIsEmpty, "queue idle")

            // Remote final state: the archive intention must actually have
            // reached the provider. A matcher that scans PAST the newest
            // related row (the delete) to the protected archive row would
            // wrongly delete the archive from the queue too — local state
            // would still show Archive (Undo's own local write is
            // unconditional), masking the loss unless the remote call is
            // checked: the archive would then never reach the wire.
            let movedIds = await provider.movedIds
            #expect(movedIds.count == 1, "exactly one provider move call reached the wire — the archive")
            #expect(movedIds.first?.to == archive.path, "the surviving move is the archive, Inbox → Archive")
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    /// Undo dispatched before the forward gesture's own fold has run joins
    /// the SAME in-memory connected component (ADR-IOS-060 §7.2): ordinary
    /// "latest move wins" nets the target back to the untouched row's actual
    /// location, so the executor's compare-against-fresh-row-truth check
    /// skips the write entirely — zero durable rows, zero provider calls.
    @Test("undo before drain produces zero provider calls for the pair")
    func undoBeforeDrainProducesZeroProviderCalls() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let provider = MockEmailProvider(messageFieldScope: .account)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1") }
        }

        let header = makeDurableHeader(folder: inbox, messageId: "m-bench-zero")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        let vm = InboxViewModel(folders: [inbox])

        // Gate the FIFO write queue BEFORE the gesture so the archive's fold
        // executor cannot run until Undo's own record has joined the SAME
        // connected component — mirrors the gated pattern used throughout
        // this file (e.g. `archiveMessagePushesOverlayAdjustedSnapshotSurvivingUndo`).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        #expect(vm.archive(header.id), "archive must record")
        // Undo dispatch is fire-and-forget (mirrors every other gesture) —
        // it appends its own record and returns without waiting for a fold,
        // so it cannot deadlock behind the gate it shares with the archive.
        await UndoService.shared.undo()

        gate.finish()
        await drainWriteQueue()
        try await drainProviderQueue(pool: pool)

        let final = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
        #expect(final.folderId == inbox.id, "A must be back in INBOX locally")

        let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
        #expect(queueIsEmpty, "queue idle")

        let movedIds = await provider.movedIds
        #expect(movedIds.isEmpty, "provider saw NO move calls — the pair annihilated in memory")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// §14.4 scenario 2: Undo fires while the forward move's PROVIDER CALL is
    /// genuinely in flight — the row is claimed `.inFlight` (protected
    /// frontier) and `provider.move()` has been entered but not yet resolved
    /// — not merely "before the write-queue fold has run" like
    /// `undoBeforeDrainProducesZeroProviderCalls` above. Per the §8.4 table
    /// row "Durable and in flight: do not touch it; append inverse after
    /// it," Undo must never touch the protected in-flight row; it appends an
    /// ordinary inverse that drains once the forward call resolves. Only the
    /// final observable outcome is asserted — final location is A regardless
    /// of the internal reconciliation path.
    @Test("undo fired while the forward move's provider call is in flight appends an ordinary inverse")
    func undoWhileForwardProviderCallInFlightConverges() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let provider = MockEmailProvider(messageFieldScope: .account)
        let rfcMessageId = "bench-inflight-undo-\(UUID().uuidString.lowercased())@example.com"
        let header = makeDurableHeader(folder: inbox, messageId: "m-bench-inflight", rfc822MessageId: "<\(rfcMessageId)>")
        await provider.seedStatefulMessage(id: rfcMessageId, folder: inbox.path, providerMessageId: header.messageId)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1") }
        }

        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        let vm = InboxViewModel(folders: [inbox])

        // Suspend the provider's move() call itself (not the durable write
        // queue) — the row is claimed `.inFlight` and the provider call is
        // entered, but unresolved, while Undo fires. `AsyncStream.finish()`
        // makes every subsequent/pending `next()` (including the inverse's
        // own move() call, once it runs) return immediately — no deadlock.
        let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        await provider.setMoveHook {
            enteredContinuation.yield()
            var it = releaseStream.makeAsyncIterator()
            _ = await it.next()
        }

        #expect(vm.archive(header.id), "archive must record")
        await drainWriteQueue()

        // Own Task: `drainPendingQueue()` will suspend inside the hook,
        // holding the claimed row `.inFlight` for the rest of this test body.
        let drainTask = Task { await AccountManager.shared.drainPendingQueue() }

        // "Provider call entered" — proves the row is genuinely in flight
        // (claimed AND provider.move() invoked), not merely durably queued.
        var it = enteredStream.makeAsyncIterator()
        _ = await it.next()

        // Undo while the forward call is suspended mid-flight. No durable-row
        // assertions here (§14.1: end-to-end Undo tests must not pin the
        // reconciliation formula) — only the final state below matters.
        await UndoService.shared.undo()
        await drainWriteQueue()

        // Release the provider call — the forward move resolves, then the
        // drain loop continues with whatever the reconciliation left behind.
        releaseContinuation.finish()
        await drainTask.value
        try await drainProviderQueue(pool: pool)

        let final = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
        #expect(final.folderId == inbox.id, "final location is A regardless of the internal reconciliation path")

        let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
        #expect(queueIsEmpty, "queue idle")

        let movedIds = await provider.movedIds
        #expect(movedIds.count == 2, "both the forward archive and the inverse reached the wire — the in-flight row was never cancelled")
        #expect(movedIds[0].to == archive.path)
        #expect(movedIds[1].to == inbox.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// §14.4 scenario 5: unrelated protected work (X) sits at the blocked
    /// frontier — a transient provider failure keeps its row `.queued` and
    /// stops the drain (§9.1) — while Undo fires for a LATER, unrelated
    /// message (Y) during that delay. Undo must reconcile only Y's own row
    /// (behind the protected frontier, exact match) without ever touching
    /// X's blocked row; once the transient failure clears, X still reaches
    /// its serially expected final state too.
    @Test("unrelated blocked frontier work and a later Undo both reach their serially expected final states")
    func unrelatedBlockedFrontierAndLaterUndoBothConverge() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let provider = MockEmailProvider(messageFieldScope: .account)
        let xRfcMessageId = "bench-unrelated-blocker-\(UUID().uuidString.lowercased())@example.com"
        let yRfcMessageId = "bench-unrelated-undo-\(UUID().uuidString.lowercased())@example.com"
        let headerX = makeDurableHeader(folder: inbox, messageId: "m-bench-x", rfc822MessageId: "<\(xRfcMessageId)>")
        let headerY = makeDurableHeader(folder: inbox, messageId: "m-bench-y", rfc822MessageId: "<\(yRfcMessageId)>")
        await provider.seedStatefulMessage(id: xRfcMessageId, folder: inbox.path, providerMessageId: headerX.messageId)
        await provider.seedStatefulMessage(id: yRfcMessageId, folder: inbox.path, providerMessageId: headerY.messageId)
        // X's forward move transiently fails until explicitly cleared below —
        // it becomes the blocked, protected frontier (Law 4: throw = retry,
        // stop the drain; §9.1: the first row is never touched or skipped).
        await provider.setMoveThrowsOnId(xRfcMessageId, error: ProviderError.notConnected)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1") }
        }

        try await pool.writeWithoutTransaction { db in
            try headerX.insert(db)
            try headerY.insert(db)
        }

        let vm = InboxViewModel(folders: [inbox])

        #expect(vm.archive(headerX.id), "X's archive must record first")
        await drainWriteQueue()
        #expect(vm.archive(headerY.id), "Y's archive must record behind X")
        await drainWriteQueue()

        let opsBeforeDrain = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(opsBeforeDrain.count == 2, "both X and Y are durably queued, X first")

        // X is claimed as the frontier, fails transiently, and is restored to
        // `.queued` — the drain stops there. Y's row is never claimed.
        await AccountManager.shared.drainPendingQueue()
        let opsAfterBlockedDrain = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(opsAfterBlockedDrain.count == 2, "X's row survives the transient failure unchanged; Y's row is untouched behind it")

        // Undo Y (the later, unrelated message) WHILE X remains blocked at
        // the protected frontier. No durable-row assertions on the
        // reconciliation outcome (§14.1) — only local/provider/queue final
        // state below.
        await UndoService.shared.undo()
        await drainWriteQueue()

        let yAfterUndo = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: headerY.id) })
        #expect(yAfterUndo.folderId == inbox.id, "Y's local state is back at A while X is still blocked")

        // Clear the transient failure — X now proceeds to its serially
        // expected final state.
        await provider.clearMoveThrowsOnId()
        try await drainProviderQueue(pool: pool)

        let finalX = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: headerX.id) })
        #expect(finalX.folderId == archive.id, "X reaches archive once unblocked — unrelated protected work was not lost")

        let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
        #expect(queueIsEmpty, "queue idle")

        let movedIds = await provider.movedIds
        #expect(movedIds.count == 1, "only X's forward archive ever reached the wire — Y's undo never called the provider")
        #expect(movedIds.first?.ids == [xRfcMessageId])
        #expect(movedIds.first?.to == archive.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// §14.4 scenario 12: the LOCAL row is deleted outright (e.g. account
    /// content purge or a sync confirmed-gone removal) between the completed
    /// forward action and the Undo tap. §8.2: a member whose row is absent at
    /// both serial-intent locations is a stale Undo — drop it, fabricate no
    /// row, create no durable work. Sibling of the third-folder relocation
    /// test below (same stale-drop rule; that one is the location-mismatch
    /// variant, this one is the row-vanished variant).
    @Test("undo whose local row vanished before the fold is a stale no-op with no durable work")
    func undoStaleWhenLocalRowVanishedBeforeFold() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let rfcMessageId = "bench-vanished-undo-\(UUID().uuidString.lowercased())@example.com"
        let header = makeDurableHeader(folder: inbox, messageId: "m-bench-vanished", rfc822MessageId: "<\(rfcMessageId)>")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.seedStatefulMessage(id: rfcMessageId, folder: inbox.path, providerMessageId: header.messageId)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)

        do {
            let vm = InboxViewModel(folders: [inbox])

            // Forward archive fully settles and drains.
            #expect(vm.archive(header.id), "archive must record")
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            // The local row vanishes entirely before Undo's fold runs.
            try await pool.writeWithoutTransaction { db in
                _ = try MessageHeader.deleteOne(db, key: header.id)
            }

            await UndoService.shared.undo()
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            // Stale no-op: no fabricated local row, no durable work, provider
            // state unchanged since the forward archive, queue idle.
            let resurrected = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
            #expect(resurrected == nil, "a stale Undo must never fabricate a local row")

            let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            #expect(queueIsEmpty, "queue idle — the stale Undo created no durable row")

            let movedIds = await provider.movedIds
            #expect(movedIds.count == 1, "only the forward archive reached the wire — no inverse call")
            #expect(movedIds.first?.to == archive.path)
            #expect(await provider.statefulFolder(messageId: rfcMessageId) == archive.path, "provider state unchanged by the stale Undo")

            #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    /// Serial-intent location guard (ADR-IOS-060 §8.2, plan §19): an Undo
    /// resolves a member only where serial replay could have left it — the
    /// forward destination or the member's own pre-move source. If an
    /// INDEPENDENT newer action (another client, observed via sync) relocated
    /// the message to a THIRD folder between the forward gesture and the undo
    /// tap, the Undo is stale for that member: it must never drag the message
    /// back from a folder it does not own. Only final observable state is
    /// asserted: the row stays put, no new durable work, queue idle.
    @Test("undo is stale when an independent move relocated the message to a third folder")
    func undoStaleWhenIndependentMoveRelocatedToThirdFolder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        // The third, unrelated folder the "other client" moves the message to.
        let newsletters = Folder(name: "Newsletters", path: "Newsletters", role: .custom, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try newsletters.insert(db) }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal(); UndoService.shared.dismissAll()

        let rfcMessageId = "bench-third-folder-\(UUID().uuidString.lowercased())@example.com"
        let header = makeDurableHeader(folder: inbox, messageId: "m-bench-third", rfc822MessageId: "<\(rfcMessageId)>")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.seedStatefulMessage(id: rfcMessageId, folder: inbox.path, providerMessageId: header.messageId)
        await AccountManager.shared.registerProviderForTesting(accountId: "acc1", provider: provider)

        do {
            let vm = InboxViewModel(folders: [inbox])

            // Forward archive, fully settled AND fully drained (deterministic:
            // the durable forward row is gone, the provider has applied it, the
            // queue is provably idle before the independent relocation happens).
            #expect(vm.archive(header.id), "archive must record")
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            let afterArchive = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
            #expect(afterArchive.folderId == archive.id, "forward archive fully executed")

            // Independent relocation: another client moved the message to
            // Newsletters; ordinary sync updated the local row in place —
            // same primary key, new location. (The queue is empty, so this is
            // exactly what a sync write would leave behind.)
            try await pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 0 WHERE id = ?",
                    arguments: [newsletters.id, newsletters.path, header.id]
                )
            }

            // Undo the archive. The member's row is neither at the forward
            // destination (Archive) nor at its pre-move source (INBOX) — the
            // Undo is stale and must drop, creating no local or durable work.
            await UndoService.shared.undo()
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            let final = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
            #expect(final.folderId == newsletters.id, "the row STAYS in the third folder — never dragged back")
            #expect(final.folderPath == newsletters.path)

            let queueIsEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            #expect(queueIsEmpty, "queue idle — the stale Undo created no durable row")

            // Exactly ONE provider move ever happened: the forward archive.
            // A stale Undo issues no inverse call.
            let movedIds = await provider.movedIds
            #expect(movedIds.count == 1, "only the forward archive reached the wire")
            #expect(movedIds.first?.to == archive.path)

            #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
    }

    private func drainProviderQueue(pool: DatabasePool) async throws {
        var iterations = 0
        repeat {
            await AccountManager.shared.drainPendingQueue()
            let isEmpty = try await pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            iterations += 1
            await Task.yield()
        } while iterations < 200
        let isEmpty = try await pool.read { db in
            try PendingOperation.fetchCount(db) == 0
        }
        let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
        try #require(
            isEmpty && isQuiescent,
            "provider queue did not become empty and quiescent within the bounded test wait"
        )
    }

    private func durableRows(
        pool: DatabasePool,
        rfc822MessageId: String
    ) async throws -> [MessageHeader] {
        try await pool.read { db in
            try MessageHeader.fetchAll(db).filter {
                MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId)
                    == rfc822MessageId
            }
        }
    }

    private func userLabelMemberships(
        pool: DatabasePool,
        rfc822MessageId: String,
        userLabelId: String
    ) async throws -> [MessageUserLabel] {
        try await pool.read { db in
            let messageIds = Set(try MessageHeader.fetchAll(db).filter {
                MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId)
                    == rfc822MessageId
            }.map(\.id))
            return try MessageUserLabel.fetchAll(db).filter {
                messageIds.contains($0.messageId) && $0.userLabelId == userLabelId
            }
        }
    }

    private func expectPipelineIdle(pool: DatabasePool) async throws {
        let queueIsEmpty = try await pool.read { db in
            try PendingOperation.fetchCount(db) == 0
        }
        let queueIsQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
        #expect(queueIsEmpty)
        #expect(queueIsQuiescent)
        #expect(AccountManager.shared.snapshotOverlay().isEmpty)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    private func reconcileWithoutRecentProtection(
        pool: DatabasePool,
        folder: Folder,
        provider: any EmailProvider
    ) async throws {
        _ = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: provider,
            limit: SyncConfig.syncMessageLimit,
            dbPool: PrioritizedDatabase(pool: pool),
            recentlyCompleted: [:]
        )
    }

    private func waitForConsumedLookupFailure(
        _ fixture: StatefulRESTFixture
    ) async throws {
        for _ in 0..<200 {
            if fixture.consumedLookupFailureCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            fixture.consumedLookupFailureCount() > 0,
            "provider did not consume the injected lookup failure"
        )
    }

    private func waitForProviderQueueQuiescence() async throws {
        for _ in 0..<200 {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
            "provider queue did not become quiescent after the injected failure"
        )
    }

    private func waitForHeader(pool: DatabasePool, id: String) async throws -> MessageHeader? {
        for _ in 0..<200 {
            if let header = try await pool.read({ db in
                try MessageHeader.fetchOne(db, key: id)
            }) {
                return header
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test("Undo after a completed cross-folder move restores each member to its own original folder")
    func undoAfterCompletedCrossFolderMoveRestoresEachOriginalFolder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        // Third folder — the move's shared destination, distinct from both
        // members' own source folders.
        let work = Folder(name: "Work", path: "Work", role: .custom, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let f = work
            try f.insert(db)
        }

        let headerA = makeDurableHeader(folder: inbox, messageId: "m-xfold-exec-a", isRead: false)
        let headerB = makeDurableHeader(folder: archive, messageId: "m-xfold-exec-b", isRead: false)
        try await pool.writeWithoutTransaction { db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox, archive])

        // No gate: let the cross-folder move fully execute locally before Undo.
        vm.moveThread([idA, idB], toFolderPath: "Work")
        await drainWriteQueue()

        let afterMoveA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let afterMoveB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(afterMoveA?.folderPath == "Work", "move must have fully executed before undo fires")
        #expect(afterMoveB?.folderPath == "Work")

        await UndoService.shared.undo()
        await drainWriteQueue()

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == inbox.id, "A restores to its own original folder (inbox)")
        #expect(finalA?.folderPath == inbox.path)
        #expect(finalB?.folderId == archive.id, "B restores to its OWN original folder (archive) — not inbox, not a batch-wide value")
        #expect(finalB?.folderPath == archive.path)

        #expect(AccountManager.shared.snapshotOverlay()[idA] == nil, "overlay entry stranded for A after full drain")
        #expect(AccountManager.shared.snapshotOverlay()[idB] == nil, "overlay entry stranded for B after full drain")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after cross-folder undo restore")
    }

    /// Test-review pin: the PRIMARY resolve's read-error path — the last
    /// untested new-code path of ADR-IOS-058. A read failure on the fold's
    /// first resolve must REINSERT the consumed records (journal stays
    /// non-drained, overlay keeps covering the row) and retry on the
    /// `SyncConfig.intentionResolveRetryDelaySeconds` cadence; the intent
    /// executes on the retry — never dropped (throwing-resolve contract).
    @Test("primary resolve read error reinserts records and retries without dropping the intent")
    func primaryResolveReadErrorReinsertsAndRetriesWithoutDropping() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 = nil }
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-primary-fault", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // Arm the one-shot failure BEFORE the gesture: the fold's FIRST
        // resolve throws, records reinsert, the retry fires after the paced
        // delay and executes the write.
        AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 = id }
        vm.toggleRead(id)

        // The failed fold must leave the intent PENDING (not dropped): the
        // journal is non-drained and the overlay still covers the row.
        // Bounded poll to observe the reinserted state before the 1s retry.
        var sawReinserted = false
        for _ in 0..<50 where !sawReinserted {
            if !AccountManager.shared.intentionJournal.isFullyDrainedForTesting()
                && AccountManager.shared.snapshotOverlay()[id]?.isRead == true {
                sawReinserted = true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sawReinserted, "records must be reinserted (journal pending, overlay covering) after the injected read error")

        // The retry (paced by intentionResolveRetryDelaySeconds = 1s) must
        // execute the write. Bounded wait well past the cadence.
        var executed = false
        for _ in 0..<400 where !executed {
            let row = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
            if row?.isRead == true { executed = true } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(executed, "the retry must execute the intent — a read error must never drop it")
        await drainWriteQueue()
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
        #expect(AccountManager.simulatePrimaryResolveFailureForTesting.withLock { $0 } == nil, "the one-shot seam was consumed")
    }

    @Test("Round D-0: archive then return to inbox in one batch RETAINS the tag — no resurrect-guard, no write, no PendingOperation, no AI-cache touch")
    func archiveThenReturnToInboxRetainsTagInOneBatch() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        var mutableHeader = makeDurableHeader(folder: inbox, messageId: "m-retain-tag", isRead: true)
        mutableHeader.actionTag = .reply
        mutableHeader.tagSortOrder = ActionTag.reply.sortOrder
        // rfc822MessageId is what keys the AI cache — without it,
        // `MessageAICache.writeThrough` no-ops (nil cacheKey) and the
        // negative-space cache pin below would be vacuous.
        mutableHeader.rfc822MessageId = "retain-tag-pin@example.com"
        let header = mutableHeader
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Negative-space seed: a pre-existing AI-cache row for this message.
        // Round D-0's move path never touches the actionTag column at all
        // (in either direction), so this row must stay byte-untouched — a
        // regression re-routing any part of the move through
        // `applyManualTag(header, tag:)` would hit its AI-cache
        // write-through, which SAVES the row and bumps `updatedAt` (it
        // preserves the actionTag VALUE — writeThrough skips nil params — so
        // the timestamp is the discriminating field).
        guard let cacheKey = MessageAICache.cacheKey(
            accountId: inbox.accountId, folderPath: inbox.path,
            rfc822MessageId: header.rfc822MessageId
        ) else {
            Issue.record("setup: cacheKey must be derivable from a non-nil rfc822MessageId"); return
        }
        let seededUpdatedAt = Date().addingTimeInterval(-3600)
        var seededCache = MessageAICache(key: cacheKey, rfc822MessageId: header.rfc822MessageId)
        seededCache.actionTag = .reply
        seededCache.updatedAt = seededUpdatedAt
        let cacheToInsert = seededCache
        try await pool.writeWithoutTransaction { db in try cacheToInsert.insert(db) }

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == .reply)

        // Gate, then queue archive + return-to-inbox serially — both records
        // land in ONE connected component and fold together (the "in one
        // in-memory batch" scenario).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        vm.archive(id)
        vm.move(id, toFolderPath: inbox.path)
        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderPath == inbox.path, "net move lands back in the inbox")
        #expect(final?.isInInbox == true)
        #expect(final?.actionTag == .reply, "Round D-0: the tag is retained across the round trip — nothing ever cleared it, so there is no resurrect-guard suppressing it")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())

        // Negative-space pin (a): a move must queue ZERO tag PendingOperations
        // — tags are local-only (ADR-IOS-036), and a move never writes the
        // actionTag column at all now (Round D-0).
        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(
            pendingOps.filter { $0.type == .setTag || $0.type == .removeTag }.isEmpty,
            "a move must not queue any .setTag/.removeTag PendingOperation"
        )

        // Negative-space pin (cache): no AI-cache write-through — the seeded
        // row still carries its tag AND its seeded timestamp (see the seed
        // comment: writeThrough preserves the value but bumps updatedAt, so
        // updatedAt is the discriminating assert).
        let cacheRow = try await pool.read { db in
            try MessageAICache.filter(Column("key") == cacheKey).fetchOne(db)
        }
        #expect(cacheRow?.actionTag == .reply, "a move must not write through to the AI cache")
        if let cacheRow {
            #expect(
                abs(cacheRow.updatedAt.timeIntervalSince(seededUpdatedAt)) < 1,
                "AI-cache updatedAt bumped — something saved the cache row during the move (applyManualTag write-through?)"
            )
        } else {
            Issue.record("seeded AI-cache row vanished during the fold")
        }
    }

    /// Negative-space sibling to the retention pin above: the move path never
    /// calls `applyManualTag` (ADR-IOS-036 — move is not a user tag choice),
    /// so `applyManualTag`'s self-sent early-return
    /// (`fromAddress == account.emailAddress`) is simply not on this path —
    /// a self-sent message retains its tag across a move exactly like any
    /// other message.
    @Test("self-sent message: archive then return to inbox also RETAINS the tag (Round D-0) — applyManualTag's self-sent guard is not on the move path")
    func selfSentArchiveThenReturnRetainsTag() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        var mutableHeader = makeDurableHeader(folder: inbox, messageId: "m-retain-tag-selfsent", isRead: true)
        mutableHeader.actionTag = .reply
        mutableHeader.tagSortOrder = ActionTag.reply.sortOrder
        // Self-sent: fromAddress matches acc1's email exactly — the case
        // applyManualTag's guard blocks.
        mutableHeader.fromAddress = "test@example.com"
        let header = mutableHeader
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == .reply)

        // Gate, then queue archive + return-to-inbox serially
        // (same choreography as the non-self-sent pin above).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        vm.archive(id)
        vm.move(id, toFolderPath: inbox.path)
        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderPath == inbox.path, "net move lands back in the inbox")
        #expect(final?.isInInbox == true)
        #expect(final?.actionTag == .reply, "the tag is retained on a SELF-SENT message too — the move path never touches applyManualTag's self-sent guard")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // MARK: - (o) Out-of-band local writer vs a net-zero cycle (round-3 audit)

    @Test("markAllAsRead queued BEFORE a same-id toggle burst must not swallow the burst's net intent: the cycle executor compares its target against the row's CURRENT truth (which markAllAsRead flipped mid-cycle) and re-asserts the user's latest visualized state")
    func markAllAsReadBeforeToggleBurstDoesNotSwallowLatestIntent() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-markall-vs-cycle", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // gate0: blocks the FIFO write queue before anything.
        let (gate0Stream, gate0) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gate0Stream.makeAsyncIterator()
            _ = await it.next()
        }

        // markAllAsRead first: its batch closure (which writes isRead=true to
        // every unread row, BYPASSING the intent register and the overlay)
        // queues behind gate0.
        vm.markAllAsRead()
        try await Task.sleep(for: .milliseconds(50)) // let its closure append

        // Then a same-id toggle burst: read, then back to unread. The net
        // intent (unread — the user's LATEST visualized state) equals the
        // cycle's gesture-time baseline, so a baseline-compared skip would
        // treat it as a pure cancel-out and write NOTHING — letting
        // markAllAsRead's earlier batch write win over gestures that
        // postdate it (the round-3 regression). The header-truth comparison
        // sees target(false) != row(true, post-batch) and re-asserts unread.
        vm.toggleRead(id) // -> read
        vm.toggleRead(id) // -> unread (net intent; joins the same cycle)
        try await Task.sleep(for: .milliseconds(50)) // let the executor append behind the batch
        #expect(vm.loadedMessages.first?.isRead == false, "visualized state after the burst is unread")

        gate0.finish()
        await drainWriteQueue()

        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == false, "the toggle burst postdates markAllAsRead — its net intent (unread) must win; a baseline-compared cancel-out would leave the row read")

        // Both writes really happened: markAllAsRead's markRead op AND the
        // fold executor's corrective markUnread op.
        let opTypes = try await pool.read { db in try PendingOperation.fetchAll(db).map(\.type) }
        #expect(opTypes.contains(.markRead), "markAllAsRead's batch write must have landed first")
        #expect(opTypes.contains(.markUnread), "the fold executor must re-assert the net intent against the batch write")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    // MARK: - (p) Tag-only cycle on a staged-only row (round-2 audit)

    @Test("applyManualTag on a staged-only row completes gracefully — optimistic tag survives on screen, zero strand (strand-hygiene pin: the test host's merge no-op means this CANNOT distinguish ensureDurable-present from absent; the silent-tag-loss fix is guarded by code review + ADR-IOS-057, not by this test)")
    func tagOnStagedOnlyRowRunsEnsureDurableAndReleasesGracefully() async throws {
        let (_, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let vm = InboxViewModel(folders: [inbox])
        let row = makeStagedRow(messageId: "m-staged-tag")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-staged-tag")
        #expect(vm.loadedMessages.first?.actionTag == nil)

        // Gesture: tag a row that is not durable anywhere yet. Pre-round-2,
        // AccountManagerAI.applyManualTag never called ensureDurable, so its
        // fetchOne-guarded Step-1 write silently no-op'd for staged rows and
        // the tag vanished with no error/retry. Post-fix the executor path
        // forces ensureDurable first. HONESTY NOTE (round-3 audit): in the
        // test host the NSE merge no-ops (no app-group container), so this
        // test passes with OR without the ensureDurable call — it pins only
        // the graceful no-crash/no-strand contract for the tag-on-staged-row
        // path (same achievable contract as
        // toggleReadOnStagedOnlyRowFlipsInstantlyAndResolvesGracefully); the
        // durability fix itself is not observable from a unit test host.
        vm.applyManualTag(id, tag: .reply)
        #expect(vm.loadedMessages.first?.actionTag == .reply, "optimistic tag flip happens regardless of durability")
        try await Task.sleep(for: .milliseconds(50)) // let the fold's executor Task append
        await drainWriteQueue()

        // Achievable contract in the test host (merge cannot durabilize):
        // the fold never strands, crashes, or hangs — the journal and overlay
        // both fully drain.
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after staged-row tag fold")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after staged-row tag fold")
    }

    // MARK: - (q) Tag-vs-move closure-reorder race (FIX B)
    //
    // Audit round 2: a tag gesture opens an intent cycle (now: appends a
    // journal record); an archive gesture's move closure can end up AHEAD of
    // the fold executor in the FIFO (both enqueue via unstructured Tasks —
    // no ordering guarantee between them). The move clears actionTag and
    // moves the row out of the inbox; the tag fold then resolves the header,
    // sees `target != header.actionTag`, and (pre-fix) re-applied the tag to
    // the now-archived row — a stale chip in Archive/Trash lists. Fix (now
    // `executeFold`'s Phase 2 tag gate, ADR-IOS-058 §9g "two-layer rule"):
    // the actionTag branch guards on the RESOLVED header's `isInInbox` and
    // skips the write when the row has already left the inbox by execution
    // time, logging "effective location is outside the inbox".

    @Test("executeFold: a tag intent whose RESOLVED header has already left the inbox (simulating a move closure that ran ahead of the tag fold in the FIFO) does NOT reinstate the tag — no .setTag PendingOperation, actionTag stays nil, and the overlay/refcount/journal all drain to empty")
    func tagIntentSkipsReinstateWhenRowLeftInboxBeforeExecution() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-move-race", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // Gate the FIFO write queue BEFORE registering the tag intent so its
        // executor closure cannot run until we've simulated the reordered
        // move below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Tag gesture: appends a journal record for id (retain #1, via
        // record()) and queues the fold's executor closure onto the FIFO
        // write queue behind the gate.
        AccountManager.shared.registerGestureIntent(id: id, .actionTag(target: .reply, baseline: nil))
        // Settle: let the fold's Task actually append its closure to the
        // queue before the simulated-move write below (mirrors the settle
        // pattern used across this suite).
        try await Task.sleep(for: .milliseconds(50))
        #expect(AccountManager.shared.intentionJournal.recordsForTesting().filter { $0.ids.contains(id) }.count == 1, "the single tag record is pending")

        // Simulate the archive gesture's move closure having ALREADY RUN
        // ahead of the tag fold in the FIFO: directly update the row in
        // DB to a post-move, untagged state (folderId/folderPath -> Archive,
        // isInInbox -> false, actionTag/tagSortOrder at the no-tag sentinel —
        // e.g. as `sweepStaleActionTags` would eventually leave it) —
        // bypassing the overlay/queue machinery entirely, since only the
        // RESOLVED DB row is what `executeFold` consults for the isInInbox
        // guard.
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET folderId = ?, folderPath = ?, isInInbox = ?, actionTag = NULL, tagSortOrder = 99
                WHERE id = ?
                """, arguments: [archive.id, archive.path, false, id])
        }

        // Release the gate: the tag fold now resolves the header (which
        // shows isInInbox == false, actionTag == nil) and must skip the
        // reinstate rather than writing target (.reply) over the cleared tag.
        gate.finish()
        await drainWriteQueue()
        // Settle: the fold's release/log side effects are synchronous within
        // its closure, but give any trailing unstructured Task a beat before
        // asserting (mirrors this suite's drain+settle convention).
        try await Task.sleep(for: .milliseconds(50))

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.actionTag == nil, "the tag must NOT be reinstated on a row that left the inbox")
        #expect(final?.folderId == archive.id, "the simulated move's folder must be untouched by the tag fold")

        let pendingOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(!pendingOps.contains { $0.type == .setTag }, "no .setTag PendingOperation may be queued for a row that already left the inbox")

        #expect(AccountManager.shared.snapshotOverlay()[id] == nil, "overlay entry stranded after the skipped-tag fold")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after the skipped-tag fold")
    }

    // MARK: - (r) Gesture-time tag baseline vs an out-of-band AI auto-tag (ADR-IOS-057 carried)

    /// Pins `executeFold`'s baseline threading into `applyManualTag`
    /// (`AccountManagerIntentions.swift` phase 2: `tagHeader.actionTag =
    /// baseline` before the call): the ActionRefineSnapshot the backfill-AI
    /// queue persists derives `originalAction` from the header's tag AT CALL
    /// TIME (`AccountManagerAI.applyManualTag`: `previousTag?.rawValue ?? ""`),
    /// so an AI auto-tag landing in the gesture→drain gap must NOT masquerade
    /// as the tag the user overrode — the user visually overrode NOTHING
    /// (baseline nil), not the out-of-band "archive". Deleting the
    /// baseline-assignment line flips this test.
    @Test("applyManualTag baseline: an out-of-band AI auto-tag written between gesture and fold must NOT masquerade as the overridden tag — the backfill-AI refine snapshot's originalAction encodes the gesture-time NIL baseline (empty string), not \"archive\"")
    func manualTagRefineSnapshotEncodesGestureTimeBaselineNotOutOfBandTag() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let header = makeDurableHeader(folder: inbox, messageId: "m-tag-baseline", isRead: true)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.actionTag == nil, "setup: the visualized baseline the user gestures over is NO tag")

        // Gate the FIFO write queue BEFORE the gesture so the out-of-band
        // write below deterministically lands in the gesture→fold gap.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Gesture: tag Reply over a visualized nil baseline.
        vm.applyManualTag(id, tag: .reply)
        #expect(vm.loadedMessages.first?.actionTag == .reply)

        // Out-of-band AI auto-tag lands in the gap — DB truth now "archive".
        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ? WHERE id = ?",
                arguments: [ActionTag.archive.rawValue, ActionTag.archive.sortOrder, id]
            )
        }

        // Park the BackfillAI dispatch loop at its `PriorityGate.yield`
        // BEFORE the fold can run applyManualTag's Step-4 enqueue: the drain
        // treats any normal dispatcher return as done and DELETES the
        // pendingAIRefinement row (~50ms debounce later), so without the
        // gate this test would race the deletion. `begin()` only parks
        // loop-boundary `yield()` callers — the fold's own DB writes are
        // unaffected (no deadlock; see PriorityGate's class doc). NOTHING
        // between begin() and end() throws, so the release always runs.
        await PriorityGate.shared.begin()

        gate.finish()
        await drainWriteQueue()

        // Step 4 (the BackfillAIQueue enqueue) runs on an unstructured Task
        // inside applyManualTag — bounded poll for the persisted row (it
        // cannot be deleted while the gate above parks the dispatch).
        var refineRow: PendingAIRefinement?
        for _ in 0..<500 where refineRow == nil {
            refineRow = (try? await pool.read { db in
                try PendingAIRefinement.fetchAll(db)
            })?.first { $0.jobType == "actionRefine" }
            if refineRow == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await PriorityGate.shared.end()

        #expect(refineRow != nil, "applyManualTag's Step 4 must have enqueued an actionRefine snapshot (baseline nil != user tag reply)")
        guard let refineRow else { return }
        let snapshot = try refineRow.decodeActionRefine()
        #expect(snapshot.userManualTag == ActionTag.reply.rawValue)
        #expect(snapshot.originalAction == "", "originalAction must encode the gesture-time NIL baseline (empty string) — the out-of-band \"archive\" must not masquerade as the overridden tag")

        // The fold's own tag write landed the user's tag over the
        // out-of-band value (target .reply != row truth .archive).
        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.actionTag == .reply, "the user's latest visualized tag wins over the out-of-band auto-tag")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - (s) Partial vanish inside ONE batch component (ADR-IOS-058 vanished-row branch)

    /// Pins the PER-ID vanish granularity of `executeFold`: the vanished-row
    /// drop (`headerById[id] == nil` after a CLEAN resolve) is per id, not
    /// per component — a batch archive whose component contains one vanished
    /// and one surviving member must still execute the survivor, drop only
    /// the vanished member's intents, and drain fully.
    @Test("batch archive where one member's durable row vanishes before the fold: the surviving member archives (exactly ONE .move op carrying only its stableId), nothing references the vanished member, and the journal fully drains")
    func batchArchivePartialVanishDropsOnlyVanishedMember() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let headerA = makeDurableHeader(folder: inbox, messageId: "m-vanish-survivor", isRead: true)
        let headerB = makeDurableHeader(folder: inbox, messageId: "m-vanish-victim", isRead: true)
        try await pool.writeWithoutTransaction { db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 2)

        // Gate the FIFO write queue BEFORE the batch gesture so B's durable
        // row can be deleted out-of-band while the ONE batch move record's
        // fold is still queued.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // ONE batch record covering both members (thread archive path).
        vm.archiveThread([idA, idB])
        try await Task.sleep(for: .milliseconds(50)) // let the fold closure append behind the gate

        // Out-of-band: B's durable row vanishes (e.g. deleted by an earlier
        // queued op). Never staged either (resetStagedGlobal above), so the
        // fold's clean resolve genuinely finds nothing for it.
        try await pool.writeWithoutTransaction { db in
            _ = try MessageHeader.deleteOne(db, key: idB)
        }

        gate.finish()
        await drainWriteQueue()

        // Survivor archived; victim stays gone.
        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        #expect(finalA?.folderId == archive.id, "the surviving member must archive despite its component-mate vanishing")
        #expect(finalA?.folderPath == archive.path)
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalB == nil, "the vanished member must not be resurrected")

        // Exactly ONE .move PendingOperation, carrying ONLY the survivor.
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "one .move op for the surviving member only")
        guard moveOps.count == 1 else { return }
        #expect(moveOps[0].messageIds == [durableId(headerA)])
        #expect(!ops.contains { $0.messageIds.contains(durableId(headerB)) }, "nothing may reference the vanished member")

        #expect(AccountManager.shared.snapshotOverlay()[idA] == nil, "overlay entry stranded for the survivor")
        #expect(AccountManager.shared.snapshotOverlay()[idB] == nil, "overlay entry stranded for the vanished member")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded after partial vanish")
    }

    // MARK: - (t) Phase-2-before-phase-3 wire order (flag STORE targets the pre-MOVE folder)

    /// Pins `executeFold`'s phase ordering: field writes (phase 2) execute
    /// BEFORE moves (phase 3), so a flag STORE's `PendingOperation` both
    /// PRECEDES the move op in the same-lane FIFO (rowid order — createdAt
    /// ms-ties, see CoordinatedToolActionTests' staleness pin) and targets
    /// the PRE-MOVE source folder, before an IMAP MOVE rekeys UIDs.
    @Test("flag + archive on the same id in one component: the .markFlagged op precedes the .move op (rowid order) and targets the pre-MOVE inbox folder")
    func flagStoreOrdersBeforeMoveAndTargetsPreMoveFolder() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-flag-then-move", isRead: true, isFlagged: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isFlagged == false)

        // Gate, then net-set flag + archive as ONE pending component.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        vm.toggleFlag(id) // isFlagged: false -> true (net set)
        vm.archive(id)    // same id, joins the SAME component
        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.isFlagged == true)
        #expect(final?.folderId == archive.id)

        // ORDER BY rowid, NOT createdAt — both ops are inserted within the
        // same fold execution and can share a createdAt millisecond.
        let ops = try await pool.read { db in
            try PendingOperation.fetchAll(db, sql: "SELECT * FROM pendingOperation ORDER BY rowid ASC")
        }
        #expect(ops.count == 2, "exactly one flag op + one move op")
        guard ops.count == 2 else { return }
        #expect(ops[0].type == .markFlagged, "the flag STORE must be queued BEFORE the move (phase 2 before phase 3)")
        #expect(ops[0].folderPath == inbox.path, "the flag STORE must target the PRE-MOVE source folder — after an IMAP MOVE the UIDs are rekeyed")
        #expect(ops[1].type == .move)
        #expect(ops[1].destinationPath == archive.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - (u) Redundant-isRead skip still clears the delivered notification

    /// Pins the skipped-write mirror in `executeFold` phase 2 (round-1 audit,
    /// `AccountManagerIntentions.swift`): when an out-of-band writer beats
    /// the fold and the row is ALREADY read, the isRead write is skipped as
    /// redundant — but the gesture's bundled side effect must not be: the
    /// executor still calls `NSEDataBridge.clearNotification` for the
    /// skipped id, observed here via the DEBUG recorder seam (the bridge has
    /// no inspection surface).
    @Test("out-of-band read beats the fold: the redundant isRead write is skipped (zero markRead PendingOperations) but the delivered notification is still cleared for the skipped id")
    func redundantIsReadSkipStillClearsDeliveredNotification() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            AccountManager.notificationClearRecorderForTesting.withLock { $0 = nil }
        }
        clearOverlay(); resetStagedGlobal()

        let cleared = Mutex<[(accountId: String, messageId: String)]>([])
        AccountManager.notificationClearRecorderForTesting.withLock { recorder in
            recorder = { accountId, messageId in
                cleared.withLock { $0.append((accountId: accountId, messageId: messageId)) }
            }
        }

        let header = makeDurableHeader(folder: inbox, messageId: "m-skip-clear", isRead: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.first?.isRead == false)

        // Gate, gesture to read, then let an out-of-band writer flip the row
        // read BEFORE the fold resolves (the markAllAsRead-beats-fold class,
        // reduced to a direct out-of-band write so ZERO markRead ops exist).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        vm.toggleRead(id) // target: read
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [id])
        }
        gate.finish()
        await drainWriteQueue()

        // The write was skipped as redundant — zero markRead PendingOperations…
        let opTypes = try await pool.read { db in try PendingOperation.fetchAll(db).map(\.type) }
        #expect(!opTypes.contains(.markRead), "the redundant isRead write must be skipped — no markRead PendingOperation")
        let finalIsRead = try await pool.read { db in try MessageHeader.fetchOne(db, key: id)?.isRead }
        #expect(finalIsRead == true)

        // …but the notification clear still fired for the skipped id.
        let calls = cleared.withLock { $0 }
        #expect(calls.count == 1, "the skip branch must clear the delivered notification exactly once")
        guard calls.count == 1 else { return }
        #expect(calls[0].accountId == "acc1")
        #expect(calls[0].messageId == "m-skip-clear")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - (v) Tag-gate TRUE override — tag gestured behind a pending move INTO the inbox

    /// The TRUE-override cell of `executeFold`'s two-layer tag gate
    /// (`let gate = intents.actionTagGate ?? header.isInInbox`,
    /// `AccountManagerIntentions.swift` phase 2) — the sibling of (q), which
    /// pins the nil-gate FALSE side. A tag gestured WHILE a move-to-INBOX
    /// record is pending in the same component folds with
    /// `actionTagGate == true` (`IntentionFold`: the gate is the location
    /// context at the tag's seq — the then-pending move's destination). The
    /// executor must let that TRUE gate OVERRIDE resolved row truth: at
    /// phase 2 the row still physically sits in Archive (the move only runs
    /// in phase 3), so `header.isInInbox == false` — a regression to
    /// `let gate = header.isInInbox` (or dropped gate threading from the
    /// fold) silently drops the user's local actionTag while every gate-FALSE
    /// suite stays green.
    @Test("a tag gestured while a move-to-INBOX is pending in the same component writes via the TRUE actionTagGate override — the tag lands even though the resolved row is still physically in Archive at phase-2 time")
    func tagGesturedBehindPendingMoveToInboxWritesViaTrueGateOverride() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        // The row lives OUTSIDE the inbox (Archive) — the physical truth
        // phase 2 resolves while the move-to-INBOX waits for phase 3.
        let header = makeDurableHeader(folder: archive, messageId: "m-tag-gate-true-override", isRead: true, isInInbox: false)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        // VM over the ARCHIVE folder — the surface the user gestures from
        // (e.g. rescuing a message out of Archive, then tagging it). The
        // selection MUST be `.folder(archive)`: the default `.unified(.inbox)`
        // makes `resetMessages`' selfHealFolders re-resolve folders BY ROLE
        // and silently replace [archive] with the inbox folder (zero rows).
        let vm = InboxViewModel(folders: [archive], selection: .folder(archive))
        #expect(vm.loadedMessages.first?.id == id, "setup: the archived row must be on-screen before the gestures")

        // Gate the FIFO BEFORE the gestures so the move and tag records stay
        // in ONE still-pending component when the fold consumes them.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // Gesture 1: move to the inbox — emits
        // `.move(.folder(..., isInbox: true))` (dest role lookup in
        // `InboxViewModel.move`).
        vm.move(id, toFolderPath: inbox.path)
        // Gesture 2: tag while that move is still pending — the fold stamps
        // the tag intent with the pending move's destination as its gate.
        vm.applyManualTag(id, tag: .reply)
        #expect(vm.loadedMessages.first?.actionTag == .reply, "optimistic tag flip on the visualized snapshot")

        // Setup discrimination: the folded net intent must carry the TRUE
        // gate (not nil-falls-back-to-row-truth) — the exact cell this pins.
        #expect(journalNetIntent(for: id)?.actionTagGate == true, "setup: the pending move-to-INBOX must stamp actionTagGate == true on the tag intent")

        // Let the fold's executor Task actually append behind the gate
        // before releasing it (mirrors (s)/(c)).
        try await Task.sleep(for: .milliseconds(50))
        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderPath == inbox.path, "the move landed (phase 3)")
        #expect(final?.isInInbox == true)
        #expect(final?.actionTag == .reply, "TRUE gate must override resolved row truth — the tag write lands even though the row was physically in Archive at phase-2 time; a `header.isInInbox` regression silently drops it")

        // The final actionTag above proves the gated local write ran. Manual
        // action tags do not create provider work (ADR-IOS-036).
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc1").fetchAll(db) }
        #expect(!ops.contains { $0.type == .setTag || $0.type == .removeTag },
                "manual action tags must remain local-only")

        // The move's own op queued too (phase 3), sourced from Archive.
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "exactly one .move op for the pending move")
        guard moveOps.count == 1 else { return }
        #expect(moveOps[0].folderPath == archive.path)
        #expect(moveOps[0].destinationPath == inbox.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - (w) Cross-account thread archive
    @Test("cross-account thread archive: each member must land in its OWN account's archive folder, not account B written through account A's archive path")
    func crossAccountThreadArchiveLandsEachMemberInItsOwnAccountArchive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        // File convention: archiveThread pushes an undo entry this test never
        // pops — clear at start and in defer so it can't leak into later
        // in-suite tests (mirrors mixedToggleAndArchiveOnSameId).
        UndoService.shared.dismissAll()

        // TWO accounts with DIFFERENT archive paths.
        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive1 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let archive2 = Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try archive1.insert(db)
            try inbox2.insert(db); try archive2.insert(db)
        }

        // One header per account's inbox, sharing the SAME non-empty
        // computedThreadId (set directly — no need to exercise the adoption
        // probe). makeDurableHeader derives accountId from the passed folder,
        // so this correctly produces one header per account.
        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-cross-a")
        let threadId = "thread-cross-account-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-cross-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        // Selection MUST stay the default `.unified(.inbox)` (round-9 note,
        // see tagGesturedBehindPendingMoveToInboxWritesViaTrueGateOverride
        // above) — it resolves BY ROLE across ALL accounts, correctly
        // picking up both cross-account inbox folders.
        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        vm.archiveThread([idA, idB])
        await drainWriteQueue()

        // CORRECT behavior: each member lands in ITS OWN account's archive folder.
        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == archive1.id, "acc1's member must land in acc1's own archive folder")
        #expect(finalA?.folderPath == archive1.path)
        #expect(finalB?.folderId == archive2.id, "acc2's member must land in acc2's own archive folder (\(archive2.id)), NOT written through acc1's archive path")
        #expect(finalB?.folderPath == archive2.path, "acc2's member's folderPath must be acc2's own archive path (\(archive2.path))")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    @Test("cross-account archiveThread Undo restores each member to its own account inbox")
    func crossAccountThreadArchiveUndoRestoresEachMemberToOwnAccountInbox() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        // TWO accounts with DIFFERENT archive AND inbox-role folder ids —
        // same shape as the forward-archive repro.
        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive1 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let archive2 = Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try archive1.insert(db)
            try inbox2.insert(db); try archive2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-undo-cross-a")
        let threadId = "thread-undo-cross-account-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-undo-cross-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        vm.archiveThread([idA, idB])
        await drainWriteQueue()

        let afterArchiveA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let afterArchiveB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(afterArchiveA?.folderId == archive1.id, "sanity: acc1's member landed in acc1's own archive folder")
        #expect(afterArchiveB?.folderId == archive2.id, "sanity: acc2's member landed in acc2's own archive folder")

        await UndoService.shared.undo()
        await drainWriteQueue()

        // Each member restores to ITS OWN account's inbox — not a batch-wide
        // value (the pre-fix `action.accountId`/single-`accountId`-param bug
        // would have built acc2's restore folderId as "acc1:INBOX").
        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == inbox1.id, "acc1's member restores to acc1's own inbox (\(inbox1.id))")
        #expect(finalB?.folderId == inbox2.id, "acc2's member restores to acc2's own inbox (\(inbox2.id)), not acc1's")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - (x) Regression coverage: skipped-ids return value + role-folder-missing / foreign-account skips

    /// `deleteThread` sibling of `crossAccountThreadArchiveLandsEachMemberInItsOwnAccountArchive`
    /// — same defect class, trash role instead of archive.
    @Test("cross-account thread delete moves each member to its own account trash folder")
    func crossAccountThreadDeleteLandsEachMemberInItsOwnAccountTrash() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let trash1 = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let trash2 = Folder(name: "Deleted Items", path: "Deleted Items", role: .trash, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try trash1.insert(db)
            try inbox2.insert(db); try trash2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-cross-delete-a")
        let threadId = "thread-cross-delete-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-cross-delete-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        let skipped = await vm.deleteThread([idA, idB])
        await drainWriteQueue()

        #expect(skipped.isEmpty, "both accounts have a trash folder — nothing should be reported skipped")

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == trash1.id, "acc1's member must land in acc1's own trash folder")
        #expect(finalA?.folderPath == trash1.path)
        #expect(finalB?.folderId == trash2.id, "acc2's member must land in acc2's own trash folder (\(trash2.id)), NOT written through acc1's trash path")
        #expect(finalB?.folderPath == trash2.path, "acc2's member's folderPath must be acc2's own trash path (\(trash2.path))")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// Item 1 coverage: `moveThread`'s destination is a single explicit folder
    /// of ONE account (the picker is per-account) — a cross-account IMAP move
    /// is impossible, so a foreign-account member must be skipped AND that
    /// skip must be reported back to the caller (the View un-hides exactly
    /// these ids — see `InboxView.performThreadMove`).
    @Test("moveThread foreign-account skip: acc1's member moves to the acc1 destination folder; acc2's member is UNTOUCHED and reported in the skipped-ids list")
    func moveThreadForeignAccountMemberSkippedAndReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let work1 = Folder(name: "Work", path: "Work", role: .custom, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try work1.insert(db)
            try inbox2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-move-cross-a")
        let threadId = "thread-move-cross-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-move-cross-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        let skipped = vm.moveThread([idA, idB], toFolderPath: "Work")
        await drainWriteQueue()

        #expect(skipped == [idB], "acc2's member (foreign account) must be reported skipped")

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == work1.id, "acc1's member must land in the acc1 destination folder")
        #expect(finalB?.folderId == inbox2.id, "acc2's member must be UNTOUCHED — still in acc2's own inbox")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.allSatisfy { $0.accountId == "acc1" }, "no PendingOperation may reference acc2")
        #expect(
            !ops.contains { op in op.messageIds.contains(headerB.messageId) || op.messageIds.contains(durableId(headerB)) },
            "no PendingOperation references acc2's member"
        )

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// Item 1 coverage: role-folder-missing skip on the THREAD path (as
    /// opposed to the single-message `archive()`/`delete()` path, already
    /// covered elsewhere). acc2 has no archive folder at all — its member
    /// must be left untouched and reported skipped, while acc1's member
    /// still archives normally.
    @Test("archiveThread role-folder-missing skip: acc2 has no archive folder — acc1's member archives, acc2's row is UNTOUCHED and reported skipped")
    func archiveThreadMissingRoleFolderSkipsThatAccountOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive1 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        // acc2 has NO archive-role folder at all.
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try archive1.insert(db)
            try inbox2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-missing-role-a")
        let threadId = "thread-missing-role-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-missing-role-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        let skipped = vm.archiveThread([idA, idB])
        await drainWriteQueue()

        #expect(skipped == [idB], "acc2's member must be reported skipped — its account has no archive folder")

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == archive1.id, "acc1's member archives normally")
        #expect(finalB?.folderId == inbox2.id, "acc2's member is UNTOUCHED — still in acc2's own inbox")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        let moveOps = ops.filter { $0.type == .move }
        #expect(moveOps.count == 1, "only acc1's member is queued")
        #expect(moveOps.first?.accountId == "acc1")
        #expect(moveOps.first?.destinationPath == archive1.path)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// Edge case of the above: NEITHER account has an archive folder — the
    /// "no actionable members at all" guard fires, nothing is recorded, and
    /// EVERY id must come back as skipped (the View hid both rows and has no
    /// other mechanism to un-hide them).
    @Test("archiveThread all-skip edge: no account in the thread has an archive folder — nothing recorded, ALL ids returned skipped")
    func archiveThreadAllAccountsMissingRoleFolderSkipsEverything() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        // NEITHER account has an archive-role folder.
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db)
            try inbox2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-all-skip-a")
        let threadId = "thread-all-skip-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-all-skip-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        let skipped = vm.archiveThread([idA, idB])

        #expect(Set(skipped) == Set([idA, idB]), "every id must be reported skipped — nothing was actionable")
        #expect(UndoService.shared.currentAction == nil, "no undo entry pushed — the guard fires before UndoService.push")

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == inbox1.id, "acc1's row is UNTOUCHED")
        #expect(finalB?.folderId == inbox2.id, "acc2's row is UNTOUCHED")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation queued for either account")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// Mid-flight overlay pin: while the cross-account archive's fold closure
    /// is still gated on the FIFO write queue, each member's TRANSIENT
    /// display overlay must already show its OWN account's archive folder —
    /// never account B's row shown as if filed into account A's archive.
    /// This is the same per-member `displays` dictionary `archiveThread`
    /// builds at gesture time (before the fold executor ever runs), so this
    /// pins a property that already holds today — a regression here would
    /// mean a future edit stopped keying `displays` by each member's own
    /// resolved archive path.
    @Test("archiveThread mid-flight overlay: acc2's member's transient display overlay shows ITS OWN archive folder, never acc1's")
    func archiveThreadMidFlightOverlayShowsEachMembersOwnArchiveFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive1 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let archive2 = Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try archive1.insert(db)
            try inbox2.insert(db); try archive2.insert(db)
        }

        var headerA = makeDurableHeader(folder: inbox1, messageId: "m-overlay-cross-a")
        let threadId = "thread-overlay-cross-\(UUID().uuidString)"
        headerA.computedThreadId = threadId
        var headerB = makeDurableHeader(folder: inbox2, messageId: "m-overlay-cross-b")
        headerB.computedThreadId = threadId
        try await pool.writeWithoutTransaction { [headerA, headerB] db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox1, inbox2])
        #expect(vm.loadedMessages.count == 2, "both cross-account inbox rows must be on-screen before the gesture")

        // Gate the FIFO write queue BEFORE the gesture so the fold-executor
        // closure stays queued (never consumed) while we inspect the
        // transient overlay.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let skipped = vm.archiveThread([idA, idB])
        #expect(skipped.isEmpty, "both accounts have an archive folder — nothing skipped")

        // BEFORE releasing the gate: each member's overlay entry must carry
        // ITS OWN account's archive folder.
        let midFlightOverlay = AccountManager.shared.snapshotOverlay()
        #expect(midFlightOverlay[idA]?.folderId == archive1.id, "acc1's row must show acc1's own archive folder")
        #expect(midFlightOverlay[idB]?.folderId == archive2.id, "acc2's row must show acc2's own archive folder (\(archive2.id)), never acc1's (\(archive1.id))")

        gate.finish()
        await drainWriteQueue()

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == archive1.id)
        #expect(finalB?.folderId == archive2.id)

        #expect(AccountManager.shared.snapshotOverlay()[idA] == nil, "overlay entry stranded for A after full drain")
        #expect(AccountManager.shared.snapshotOverlay()[idB] == nil, "overlay entry stranded for B after full drain")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - Fix: single-message archive()/delete() must report "nothing recorded"

    /// Pins the single-message counterpart of `archiveThread`'s already-
    /// established skipped-ids contract. Before this fix, `archive(_:)`
    /// returned `Void` and silently no-oped when the account had no archive
    /// folder at all — `InboxView.archiveIsNoOp` only special-cases "already
    /// in the archive folder", not "no archive folder exists for this
    /// account", so the view's dismiss/swipe sites hid the row believing the
    /// archive would happen, and it vanished forever with no undo entry
    /// (`.messagesUndone` never fires because nothing was ever pushed to
    /// `UndoService`). `archive(_:)` now returns `false` for this case so
    /// callers can un-hide instead.
    @Test("archive(_:) on an account with no archive folder returns false and records nothing (journal empty, no PendingOperation, no undo entry)")
    func archiveWithNoArchiveFolderReturnsFalseAndRecordsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        // NO archive-role folder for this account — the exact bug condition.
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try inbox.insert(db) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-no-archive-folder")
        try await pool.writeWithoutTransaction { [header] db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1, "row must be on-screen before the gesture")

        let acted = vm.archive(id)
        #expect(acted == false, "no archive folder for the account — archive() must report nothing was recorded")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "row must be UNTOUCHED — still in the inbox")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation queued — nothing was recorded")

        #expect(UndoService.shared.currentAction == nil, "no undo entry pushed — nothing was recorded")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal must be empty — nothing was recorded")
    }

    /// Same defect, delete side: an account with no trash folder at all.
    @Test("delete(_:) on an account with no trash folder returns false and records nothing (journal empty, no PendingOperation, no undo entry)")
    func deleteWithNoTrashFolderReturnsFalseAndRecordsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        // NO trash-role folder for this account — the exact bug condition.
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try inbox.insert(db) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-no-trash-folder")
        try await pool.writeWithoutTransaction { [header] db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        #expect(vm.loadedMessages.count == 1, "row must be on-screen before the gesture")

        let acted = await vm.delete(id)
        #expect(acted == false, "no trash folder for the account — delete() must report nothing was recorded")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "row must be UNTOUCHED — still in the inbox")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation queued — nothing was recorded")

        #expect(UndoService.shared.currentAction == nil, "no undo entry pushed — nothing was recorded")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal must be empty — nothing was recorded")
    }

    /// Happy-path counterpart: an account that DOES have an archive folder
    /// still returns `true` and records exactly as before this fix — the
    /// Bool return is purely additive for callers.
    @Test("archive(_:) happy path (archive folder exists) still returns true and records normally")
    func archiveHappyPathReturnsTrue() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-archive-happy-path")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let acted = vm.archive(id)
        #expect(acted == true, "archive folder exists — archive() must report the action was recorded")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "row must have landed in the archive folder")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one PendingOperation queued")
        #expect(ops.first?.destinationPath == archive.path)

        #expect(UndoService.shared.currentAction != nil, "an undo entry must have been pushed")
    }

    /// Happy-path counterpart for delete.
    @Test("delete(_:) happy path (trash folder exists) still returns true and records normally")
    func deleteHappyPathReturnsTrue() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try trash.insert(db) }

        let header = makeDurableHeader(folder: inbox, messageId: "m-delete-happy-path")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let acted = await vm.delete(id)
        #expect(acted == true, "trash folder exists — delete() must report the action was recorded")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id, "row must have landed in the trash folder")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one PendingOperation queued")
        #expect(ops.first?.destinationPath == trash.path)

        #expect(UndoService.shared.currentAction != nil, "an undo entry must have been pushed")
    }

    // MARK: - (y) Move admission and happy paths

    /// `move(_:toFolderPath:)`'s Bool contract — the lookup-miss half. Mirrors
    /// `archive(_:)`/`delete(_:)`'s already-pinned "nothing recorded" contract
    /// (see the "Fix: single-message archive()/delete() must report..."
    /// section above) for the generic `move` gesture: a vanished id must
    /// report `false` and leave zero trace (no `PendingOperation`, no undo
    /// entry, no journal record) so callers know NOT to hide the row.
    @Test("move(_:toFolderPath:) returns false on a lookupMessage miss and records nothing")
    func moveReturnsFalseOnLookupMiss() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let vm = InboxViewModel(folders: [inbox, archive])
        let missingId = MessageIdentity.headerId(accountId: "acc1", folderPath: inbox.path, messageId: "m-move-never-existed")

        let acted = vm.move(missingId, toFolderPath: archive.path)
        #expect(acted == false, "lookupMessage miss — move() must report nothing was recorded")

        await drainWriteQueue()

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation queued — nothing was recorded")
        #expect(UndoService.shared.currentAction == nil, "no undo entry pushed — nothing was recorded")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal must be empty — nothing was recorded")
    }

    /// `move(_:toFolderPath:)`'s Bool contract — the happy-path half.
    @Test("move(_:toFolderPath:) happy path returns true and moves the message to the destination folder")
    func moveHappyPathReturnsTrue() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let header = makeDurableHeader(folder: inbox, messageId: "m-move-happy-path")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox, archive])
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let acted = vm.move(id, toFolderPath: archive.path)
        #expect(acted == true, "lookupMessage hit — move() must report the action was recorded")

        gate.finish()
        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "row must have landed in the destination folder")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one PendingOperation queued")
        #expect(ops.first?.destinationPath == archive.path)

        #expect(UndoService.shared.currentAction != nil, "an undo entry must have been pushed")
    }

    /// `moveThread`'s happy path (same account, every member resolvable) —
    /// the skipped-ids list must be EMPTY. The foreign-account-skip and
    /// missing-role-folder-skip variants are already pinned elsewhere in this
    /// file; this fills in the plain success case the review flagged as
    /// untested.
    @Test("moveThread happy path (same account): all members move successfully and the skipped-ids list is EMPTY")
    func moveThreadSameAccountHappyPathReturnsEmptySkippedList() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let work = Folder(name: "Work", path: "Work", role: .custom, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try work.insert(db) }

        let headerA = makeDurableHeader(folder: inbox, messageId: "m-movethread-happy-a")
        let headerB = makeDurableHeader(folder: inbox, messageId: "m-movethread-happy-b")
        try await pool.writeWithoutTransaction { db in
            try headerA.insert(db)
            try headerB.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id

        let vm = InboxViewModel(folders: [inbox, work])
        let skipped = vm.moveThread([idA, idB], toFolderPath: "Work")
        #expect(skipped.isEmpty, "same-account thread move — nothing should be reported skipped")

        await drainWriteQueue()

        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        #expect(finalA?.folderId == work.id, "member A landed in the destination folder")
        #expect(finalB?.folderId == work.id, "member B landed in the destination folder")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    /// `delete(_:)` on a drafts-role folder must still return `true` — it
    /// takes the draft-specific deletion path (`deleteDraftMessage`), not the
    /// move-to-trash path, but the Bool contract ("something was acted upon")
    /// is the same. The trash-role and no-trash-folder cases are already
    /// pinned above; the drafts branch (delete's FIRST role check, before the
    /// trash-role no-op check) was untested.
    @Test("delete(_:) on a drafts-role folder returns true")
    func deleteOnDraftsRoleFolderReturnsTrue() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        let drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in try drafts.insert(db) }

        let header = makeDurableHeader(folder: drafts, messageId: "m-draft-delete")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox, drafts])
        let acted = await vm.delete(id)
        #expect(acted == true, "drafts-role folder — delete() takes the draft-specific deletion path and must report acted-upon")

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final == nil, "draft header is deleted locally by the draft-specific path, not moved to trash")
    }

    /// Round D-0 through the `.role` path (as opposed to the `.folder` path
    /// `archive(_:)`/`move(_:toFolderPath:)` use): `archiveThread` always
    /// records `.move(.role(.archive), ...)`, whose fold-time execution
    /// (`archive()` -> `moveToRoleFolderPerAccount` -> `move()` ->
    /// `optimisticMoveToFolder`) no longer touches the tag column at all. A
    /// message carrying a manual `actionTag` must keep it once the archive
    /// actually lands, even for a single-member `archiveThread` call —
    /// display alone hides it while out of the inbox.
    @Test("Round D-0 through the .role path: a message with actionTag=.reply archived via archiveThread RETAINS actionTag==.reply after drain")
    func archiveThreadRetainsActionTagViaRolePath() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        var header = makeDurableHeader(folder: inbox, messageId: "m-retain-role-archive")
        header.actionTag = .reply
        header.tagSortOrder = ActionTag.reply.sortOrder
        try await pool.writeWithoutTransaction { [header] db in try header.insert(db) }
        let id = header.id

        let vm = InboxViewModel(folders: [inbox])
        let skipped = vm.archiveThread([id])
        #expect(skipped.isEmpty)

        await drainWriteQueue()

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "message archived via the .role path")
        #expect(final?.actionTag == .reply, "Round D-0: actionTag is retained through the .role move path — no longer destructively cleared")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder stays paired with the retained tag")
    }

    @Test("combined cross-account and cross-folder Undo restores every member to its own original folder")
    func crossAccountAndCrossFolderCombinedUndoRestoresEachOwnFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay(); resetStagedGlobal()
            UndoService.shared.dismissAll()
        }
        clearOverlay(); resetStagedGlobal()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc1 = Account(emailAddress: "acc1@example.com", displayName: "Acc1", provider: .gmail)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "acc2@example.com", displayName: "Acc2", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox1 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let custom1 = Folder(name: "Projects", path: "Projects", role: .custom, accountId: "acc1")
        let archive1 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let archive2 = Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2")
        try await pool.writeWithoutTransaction { db in
            try inbox1.insert(db); try custom1.insert(db); try archive1.insert(db)
            try inbox2.insert(db); try archive2.insert(db)
        }

        let headerA = makeDurableHeader(folder: inbox1, messageId: "m-combined-a") // acc1/INBOX
        let headerB = makeDurableHeader(folder: custom1, messageId: "m-combined-b", isInInbox: false) // acc1/Projects
        let headerC = makeDurableHeader(folder: inbox2, messageId: "m-combined-c") // acc2/INBOX
        try await pool.writeWithoutTransaction { [headerA, headerB, headerC] db in
            try headerA.insert(db)
            try headerB.insert(db)
            try headerC.insert(db)
        }
        let idA = headerA.id
        let idB = headerB.id
        let idC = headerC.id

        // A unified-inbox VM loads only the two inbox rows. Gesture methods
        // resolve every supplied id from durable state, including the custom
        // folder member that is off-screen.
        let vm = InboxViewModel(folders: [inbox1, custom1, inbox2])

        vm.archiveThread([idA, idB, idC])
        await drainWriteQueue()

        let afterArchiveA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let afterArchiveB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        let afterArchiveC = try await pool.read { db in try MessageHeader.fetchOne(db, key: idC) }
        #expect(afterArchiveA?.folderId == archive1.id, "sanity: acc1 member A archived to acc1's own archive folder")
        #expect(afterArchiveB?.folderId == archive1.id, "sanity: acc1 member B (from a DIFFERENT source folder) archived to the SAME acc1 archive folder")
        #expect(afterArchiveC?.folderId == archive2.id, "sanity: acc2 member archived to acc2's own archive folder")

        await UndoService.shared.undo()
        await drainWriteQueue()

        // Each member restores to ITS OWN original folderId — never another
        // member's (same account, different folder) or another account's.
        let finalA = try await pool.read { db in try MessageHeader.fetchOne(db, key: idA) }
        let finalB = try await pool.read { db in try MessageHeader.fetchOne(db, key: idB) }
        let finalC = try await pool.read { db in try MessageHeader.fetchOne(db, key: idC) }
        #expect(finalA?.folderId == inbox1.id, "acc1 member A restores to acc1's inbox")
        #expect(finalB?.folderId == custom1.id, "acc1 member B restores to its OWN original custom folder (\(custom1.id)), not acc1's inbox")
        #expect(finalC?.folderId == inbox2.id, "acc2 member restores to acc2's own inbox, not acc1's")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }
}
