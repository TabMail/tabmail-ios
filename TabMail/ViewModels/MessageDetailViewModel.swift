/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI

@Observable
@MainActor
final class MessageDetailViewModel {
    let messageId: String
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

    private let manager = AccountManager.shared
    private var dbPool: PrioritizedDatabase { _dbPoolOverride ?? AppDatabase.dbPool }

    // Test seams — internal so @testable import can inject them
    @ObservationIgnored var _dbPoolOverride: PrioritizedDatabase?
    @ObservationIgnored var _fetchBodyOverride: ((MessageHeader) async throws -> Void)?

    /// The resolved composite ID — may differ from `messageId` if the message was found
    /// via cross-folder fallback (e.g., after IMAP MOVE changed the UID).
    private var resolvedId: String { message?.id ?? messageId }

    @ObservationIgnored nonisolated(unsafe) private var aiUpdateObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var previewFreezeReleasedObserver: NSObjectProtocol?
    /// Poll task that checks for MessageBody in DB when body is missing.
    /// Catches cases where fetchBody succeeds but the ViewModel missed the read
    /// (e.g., lock contention caused a timeout, but a later retry wrote the body).
    	@ObservationIgnored nonisolated(unsafe) private var bodyPollTask: Task<Void, Never>?

    /// Message IDs whose `.messageDataDidChange` notifications arrived while the
    /// global `PreviewFreezeGate` was active. `Set` coalesces duplicate ids so a
    /// burst of notifications during a preview replays as one refresh per id.
    /// Flushed by `flushPendingRefreshes()` when `.previewFreezeReleased` fires.
    @ObservationIgnored private var pendingRefreshIds: Set<String> = []

    init(messageId: String) {
        self.messageId = messageId
        // Fetch initial message state from DB (with cross-folder fallback),
        // then layer the optimistic overlay so a just-toggled isRead survives
        // view recreation before the queued write commits.
        if var m = resolveMessage(compositeId: messageId) {
            applyOverlay(to: &m)
            self.message = m
        }
        startAIUpdateListener()
        startPreviewFreezeReleasedListener()
    }

    /// Test-only init that accepts a DatabasePool override and fetch closure.
    /// Must be set before `loadBody()` accesses `dbPool`.
    init(messageId: String, dbPool: DatabasePool, fetchBodyOverride: @escaping (MessageHeader) async throws -> Void) {
        self._dbPoolOverride = PrioritizedDatabase(pool: dbPool)
        self._fetchBodyOverride = fetchBodyOverride
        self.messageId = messageId
        if var m = resolveMessage(compositeId: messageId) {
            applyOverlay(to: &m)
            self.message = m
        }
    }

    deinit {
        if let obs = aiUpdateObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = previewFreezeReleasedObserver { NotificationCenter.default.removeObserver(obs) }
        bodyPollTask?.cancel()
    }

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
                applyOverlay(to: &updated)
                self.message = updated
            }
        }

        // Update thread message if it matches (fixes "Analyzing..." stuck forever
        // when AI completes after thread detection snapshot was taken)
        if let idx = self.threadMessages.firstIndex(where: { $0.id == updatedId }) {
            if var updated = try? await self.dbPool.read({ db in try MessageHeader.fetchOne(db, key: updatedId) }) {
                applyOverlay(to: &updated)
                self.threadMessages[idx] = updated
            }
        }
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
                let ids = self.pendingRefreshIds
                guard !ids.isEmpty else { return }
                self.pendingRefreshIds.removeAll()
                print("[PreviewFreeze] flushing \(ids.count) buffered .messageDataDidChange ids")
                for id in ids {
                    await self.applyRefresh(for: id)
                }
            }
        }
        previewFreezeReleasedObserver = obs
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
                let rid = self.resolvedId
                if let body = try? await self.dbPool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
                    self.messageBody = body
                    self.isLoading = false
                    self.error = nil
                    self.loadThreadMessagesAsync()
                    print("[MessageDetail] Body found immediately on poll start for \(rid.prefix(40))")
                    BootProfiler.mark("detail body via poll IMMEDIATE check \(rid.prefix(24))")
                    return
                }
                // Staged-body fast-path (ADR-IOS-049): loadBody got cancelled by
                // the deep-link reload/navigation churn and deferred here — the
                // body may be sitting in NSE staging, not yet durable. Same
                // display-only synthesis as loadBody's fast-path.
                if let stagedBody = NSEDataBridge.stagedBodyFallback(headerId: rid) {
                    BootProfiler.mark("detail body from STAGED snapshot (poll entry) \(rid.prefix(24))")
                    self.messageBody = stagedBody
                    self.isLoading = false
                    self.error = nil
                    self.loadThreadMessagesAsync()
                    return
                }
            }
            var fetchAttempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.messageBody == nil else { return }
                let rid = self.resolvedId
                // 1. Check if body appeared in DB (written by another path)
                if let body = try? await self.dbPool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
                    self.messageBody = body
                    self.isLoading = false
                    self.error = nil
                    self.loadThreadMessagesAsync()
                    print("[MessageDetail] Body found via poll for \(rid.prefix(40))")
                    BootProfiler.mark("detail body via poll (DB, 2s cadence) \(rid.prefix(24))")
                    return
                }
                // 2. Re-attempt server fetch (connection may have recovered)
                guard let msg = self.message else { continue }
                fetchAttempt += 1
                print("[MessageDetail] Poll fetch attempt \(fetchAttempt) for \(rid.prefix(40))")
                do {
                    try await self.manager.fetchBody(for: msg)
                    // Fetch succeeded — read from DB
                    if let body = try? await self.dbPool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
                        self.messageBody = body
                        self.isLoading = false
                        self.error = nil
                        // Refetch header (AI processing may have updated it)
                        if var refreshed = try? await self.dbPool.read({ db in try MessageHeader.fetchOne(db, key: rid) }) {
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

    func loadBody() async {
        guard !loadBodyCalled else { return }
        loadBodyCalled = true
        // Tap-timeline mark (debug-gated): pairs with "notifTap:" marks so an
        // open-lag decomposes into resolve vs body-load vs render in one file.
        let loadT0 = CFAbsoluteTimeGetCurrent()
        BootProfiler.mark("detail loadBody START \(messageId.prefix(24))")
        defer {
            let ms = Int((CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
            if ms >= 50 {
                BootProfiler.mark("detail loadBody DONE in \(ms)ms (body=\(messageBody != nil))")
            }
        }

        // Resolve message from DB with proper error handling.
        // GRDB 7.x throws CancellationError on async reads when the Task is
        // cancelled (e.g., SwiftUI .task during bg→fg transitions). Using try?
        // would mask this as "not found", so we use do/catch to distinguish.
        var msg: MessageHeader?
        do {
            msg = try await dbPool.read { db in try MessageHeader.fetchOne(db, key: messageId) }
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
        message = displayMsg

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
            if let existingBody = try await dbPool.read({ db in try MessageBody.fetchOne(db, key: rid) }) {
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

        // Refetch message in case AI processing updated it during body fetch
        let postFetchId = resolvedId
        if var refreshed = try? await dbPool.read({ db in try MessageHeader.fetchOne(db, key: postFetchId) }) {
            applyOverlay(to: &refreshed)
            message = refreshed
        } else {
            message = nil
        }
        messageBody = try? await dbPool.read { db in try MessageBody.fetchOne(db, key: postFetchId) }
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
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([msg], to: archiveFolder.path)
            manager.removeOverlayEntries(ids: [msg.id])
        }}
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
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([msg], to: trashFolder.path)
            manager.removeOverlayEntries(ids: [msg.id])
        }}
        updateThreadMessageFolder(msg, newFolderPath: trashFolder.path, newFolderId: trashFolder.id)
        return true
    }

    /// Update a thread message's folder info in-place after a move operation.
    /// The card stays visible but shows the new location. `isInInbox` reflects the
    /// destination: archive/delete move OUT of inbox (false); a generic move may target
    /// the Inbox (true), which must re-enable inbox-only UI (tags, summary, triage).
    private func updateThreadMessageFolder(_ msg: MessageHeader, newFolderPath: String, newFolderId: String, isInInbox newIsInInbox: Bool = false) {
        guard let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) else { return }
        threadMessages[idx].folderPath = newFolderPath
        threadMessages[idx].folderId = newFolderId
        threadMessages[idx].isInInbox = newIsInInbox
        threadMessages[idx].actionTag = nil
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
        Task { await manager.enqueueWrite { [manager] in
            await manager.move([msg], to: toFolderPath)
            manager.removeOverlayEntries(ids: [msg.id])
        }}
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

        // Fast path: `self.message` is populated synchronously in `init` via
        // `resolveMessage(compositeId:)`. Use it to flip the detail-view state
        // and register the overlay BEFORE any await — eliminates the
        // perceived "popped back to inbox, row still unread" beat.
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

        // Fallback: init's sync resolve returned nil (rare — composite id
        // didn't match any local row at init time). Retry asynchronously.
        guard let msg = await resolveMessageAsync(compositeId: messageId) else { return }
        guard !msg.isRead else { return }
        // Layer any concurrent pending mutations (e.g. user just flagged this
        // message in another view before init's resolve raced through nil) on
        // top of the fresh DB header, then force isRead=true. Without this,
        // self.message = msg silently drops the overlay's isFlagged/actionTag.
        var displayMsg = msg
        applyOverlay(to: &displayMsg)
        displayMsg.isRead = true
        self.message = displayMsg
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
    /// the synthesized header with the durable one. GRDB always wins — this runs
    /// ONLY on a GRDB miss.
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

    private func resolveMessage(compositeId: String) -> MessageHeader? {
        let dbHit: MessageHeader? = try? dbPool.read { db in
            // 1. Direct primary key lookup
            if let msg = try MessageHeader.fetchOne(db, key: compositeId) { return msg }

            // Parse composite ID: "accountId:folderPath:messageId"
            let parts = compositeId.split(separator: ":", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let accountId = String(parts[0])
            let msgId = String(parts[2])

            // 2. Cross-folder search by messageId
            if let msg = try MessageHeader
                .filter(Column("messageId") == msgId && Column("accountId") == accountId && Column("folderId") != "")
                .fetchOne(db) {
                print("[MoveTrace] resolveMessage — found via cross-folder: \(msg.id) (original: \(compositeId))")
                return msg
            }

            // 3. Search by rfc822MessageId (handles UID changes after IMAP MOVE).
            // The rfc822MessageId may be stored normalized — try searching by the msgId
            // as a potential rfc822 value (for IMAP where stableId == rfc822MessageId).
            let normalizedMsgId = EmailFilter.normalizeMessageId(msgId)
            if let msg = try MessageHeader
                .filter(Column("rfc822MessageId") == normalizedMsgId && Column("accountId") == accountId && Column("folderId") != "")
                .fetchOne(db) {
                print("[MoveTrace] resolveMessage — found via rfc822MessageId: \(msg.id) (original: \(compositeId))")
                return msg
            }

            print("[MoveTrace] resolveMessage — not found locally: \(compositeId)")
            return nil
        }
        if let dbHit { return dbHit }
        return stagedRowFallback(compositeId: compositeId)
    }

    /// Async version of resolveMessage for use in async contexts.
    /// Returns nil immediately if the Task is cancelled — GRDB 7.x would throw
    /// CancellationError on the async read, which try? converts to nil anyway,
    /// but skipping the read avoids misleading "not found" log entries.
    private func resolveMessageAsync(compositeId: String) async -> MessageHeader? {
        guard !Task.isCancelled else { return nil }
        let dbHit: MessageHeader? = try? await dbPool.read { db in
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
        let refsStr = msg.references.isEmpty ? "[]" : "[\(msg.references.joined(separator: ", "))]"
        print("[ThreadDebug] Finding related for: id=\(msg.id.prefix(40)) rfc822=\(msg.rfc822MessageId ?? "nil") inReplyTo=\(msg.inReplyTo ?? "nil") threadId=\(msg.threadId ?? "nil") computedThreadId=\(msg.computedThreadId) references=\(refsStr) folder=\(msg.folderPath)")
        let pool = dbPool
        Task {
            // Probe the DB for *any* messages that could plausibly be thread-related,
            // to distinguish "no candidates exist" from "candidates exist but chain lookup missed them".
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
            do {
                let results = try await Task.detached {
                    try ThreadDetection.findRelatedMessages(for: msg, in: pool.pool)
                }.value
                print("[ThreadDebug] Found \(results.count) related messages for \(msg.id.prefix(40))")
                for r in results {
                    print("[ThreadDebug]   related: id=\(r.id.prefix(40)) rfc822=\(r.rfc822MessageId ?? "nil") inReplyTo=\(r.inReplyTo ?? "nil") folder=\(r.folderPath)")
                }
                if !results.isEmpty {
                    var overlayed = results
                    self.applyOverlay(to: &overlayed)
                    self.threadMessages = overlayed
                    self.recomputeThreadSplit()
                }
            } catch {
                print("[ThreadDebug] Failed to load thread messages: \(error)")
            }
        }
    }
}
