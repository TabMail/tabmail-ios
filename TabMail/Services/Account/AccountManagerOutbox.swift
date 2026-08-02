/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail

/// One completed send's server-side draft cleanup, collected INSIDE the crash
/// recovery transaction and acted on outside it (network work must never run in
/// a write block). Carries the draft's durable rfc822 identity alongside its
/// server address so the `.deleteDraft` it queues can actually resolve — on IMAP
/// the address alone is a bare UID the provider refuses to act on. Mirrors
/// `v2final`'s `CompletedSendCleanupDisposition.ServerDraftCleanup`.
struct ServerDraftCleanup: Sendable, Equatable {
    let accountId: String
    let serverDraftId: String
    let gmailContainedMessageId: String?
    let folderPath: String?
    let uidValidity: Int?
}

enum OutboxFinalizeError: Error {
    case outboxRowVanished(String)
    case outboxDeleteDidNotLand(String)
}

/// PORT — v2final `OutboxAdmissionError`, with the reference's absent-Draft
/// allowance intentionally SUBTRACTED. This forward-port requires a live exact
/// owner/generation in the same transaction that performs dedup/insert.
enum OutboxAdmissionError: LocalizedError, Equatable {
    case invalidInstanceEpoch
    case draftMissing(String)
    case draftOwnerMismatch(draftId: String)
    case draftGenerationMismatch(draftId: String)
    case inFlightGenerationMismatch(draftId: String)
    case ambiguousInFlightCandidates(draftId: String)

    var errorDescription: String? {
        switch self {
        case .invalidInstanceEpoch:
            "This compose session has an invalid generation. Close and reopen it before sending."
        case .draftMissing:
            "This draft changed while Send was being prepared. Close and reopen it before sending."
        case .draftOwnerMismatch:
            "This draft belongs to a different account. Close and reopen it before sending."
        case .draftGenerationMismatch:
            "This draft was changed by another compose session. Review the newer draft before sending."
        case .inFlightGenerationMismatch:
            "A different version of this draft is already being sent. Close and reopen it before sending."
        case .ambiguousInFlightCandidates:
            "More than one send is pending for this draft. Resolve the Outbox entries before sending again."
        }
    }
}

struct InFlightOutboxCandidate: FetchableRecord, Decodable, Equatable, Sendable {
    let id: String
    let instanceEpoch: String?
}

struct DraftSendAuthority: FetchableRecord, Decodable, Equatable, Sendable {
    let accountId: String
    let instanceEpoch: String?
}

struct CompletedSendCleanupDisposition: Sendable {
    let accountId: String
    let outboxDir: String?
    let draftDir: String?
    let replyDetectHeaderId: String?
    let serverDraftCleanup: ServerDraftCleanup?
    let preservedMismatchedDraftId: String?
}

extension AccountManager {

    // MARK: - Outbox (Offline Send Queue)

    /// Queue a send operation to the outbox. Persists the draft + attachments to disk,
    /// then fires off a drain attempt. Throws if persistence fails — caller MUST
    /// surface the error to the user so the message is not silently lost.
    /// Returns the created outboxId so the caller can pass it to PendingSendService.
    ///
    /// `async`: the persistence runs through the ASYNC `dbPool.write` overload (in
    /// `persistQueuedSend`), so the `@MainActor` caller (`ComposeView.send`) is
    /// SUSPENDED — not blocked — while the single serialized writer is busy with a
    /// background write. A *synchronous* write here was the compose-dismiss freeze:
    /// the writer-serialization wait was transmitted 1:1 to the main thread (2–3 s
    /// on a contended writer). See PROJECT_MEMORY "Foreground-return UI freeze".
    ///
    /// Double-send firewall: if an in-flight (`.queued`/`.sending`) outbox row for
    /// this `draftId` already exists — a rapid double-tap, or async reentrancy
    /// during the now-suspended dismiss window — NO second row is created; the
    /// existing id is returned. (This is the persistence-layer guarantee; the UI
    /// `isSending` guard in ComposeView is the first line of defense.)
    @discardableResult
    nonisolated func queueSend(
        draft: DraftMessage,
        from account: Account,
        replyToHeaderId: String? = nil,
        isForward: Bool = false,
        serverDraftId: String? = nil,
        draftUidValidity: Int? = nil,
        draftServerFolderPath: String? = nil,
        serverDraftGmailMessageId: String? = nil,
        draftId: String,
        instanceEpoch: String
    ) async throws -> String {
        let result = try await Self.persistQueuedSend(
            draft: draft,
            accountId: account.id,
            replyToHeaderId: replyToHeaderId,
            isForward: isForward,
            serverDraftId: serverDraftId,
            draftUidValidity: draftUidValidity,
            draftServerFolderPath: draftServerFolderPath,
            serverDraftGmailMessageId: serverDraftGmailMessageId,
            draftId: draftId,
            instanceEpoch: instanceEpoch
        )
        if DebugModeManager.isLoggingEnabled() {
            if result.deduped {
                print("[Outbox] Deduped duplicate send for draftId=\(draftId) → existing outbox id=\(result.outboxId)")
            } else {
                print("[Outbox] Queued send to \(draft.to.joined(separator: ", ")) (id: \(result.outboxId))")
            }
        }

        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        if let resolvedOriginalId = result.resolvedOriginalId {
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            // Notify MessageDetailViewModel so reply/forward indicator updates immediately
            NotificationCenter.default.post(name: .messageDataDidChange, object: resolvedOriginalId)
        }
        // synchronous=NORMAL durability: the OutboxMessage row is committed, but NORMAL
        // does not fsync per commit. Harden the send NOW (async, off the compose-dismiss
        // path) so it survives an unclean power-off before the drain runs — a dropped send
        // is the outbox's cardinal sin. Skip on dedup (no new row was written).
        if !result.deduped {
            Task { await AppDatabase.checkpointForDurability() }
        }
        Task { await self.drainOutbox() }
        return result.outboxId
    }

    /// In-flight outbox row id for `draftId`, or nil. The double-send firewall
    /// predicate: dedup ONLY against non-terminal (`.queued`/`.sending`) rows. A
    /// `.failed` row does NOT block — re-sending an explicitly-failed draft is
    /// legitimate user intention, not a duplicate. MUST be called inside the same
    /// write transaction as the insert so two concurrent sends can't both pass it
    /// (GRDB serializes writers → the 2nd transaction sees the 1st's row).
    nonisolated static func inFlightOutboxCandidates(
        accountId: String,
        draftId: String,
        db: Database
    ) throws -> [InFlightOutboxCandidate] {
        try InFlightOutboxCandidate.fetchAll(
            db,
            sql: """
                SELECT id, instanceEpoch
                FROM outboxMessage
                WHERE accountId = ? AND draftId = ?
                  AND status IN ('queued', 'sending')
                LIMIT 2
                """,
            arguments: [accountId, draftId])
    }

    /// Pure persistence step of a queued send — the SINGLE SOURCE OF TRUTH for
    /// "turn this draft into (at most) one outbox row", with NO drain side effects
    /// (so tests can drive it deterministically). Saves attachments to disk
    /// (outside the txn), then in ONE async write transaction either dedups against
    /// an existing in-flight row (the firewall) or inserts the new row and applies
    /// optimistic isReplied/isForwarded to the original message.
    ///
    /// Returns the id of the outbox row that now represents this send (the freshly
    /// inserted one, or the pre-existing in-flight one when deduped), whether it
    /// deduped, and the resolved original-header id for the reply/forward badge.
    nonisolated static func persistQueuedSend(
        draft: DraftMessage,
        accountId: String,
        replyToHeaderId: String?,
        isForward: Bool,
        serverDraftId: String?,
        draftUidValidity: Int? = nil,
        draftServerFolderPath: String? = nil,
        serverDraftGmailMessageId: String? = nil,
        draftId: String,
        instanceEpoch: String
    ) async throws -> (outboxId: String, deduped: Bool, resolvedOriginalId: String?) {
        guard !instanceEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OutboxAdmissionError.invalidInstanceEpoch
        }
        var outbox = OutboxMessage(
            accountId: accountId,
            draft: draft,
            originalMessageHeaderId: replyToHeaderId,
            isForward: isForward
        )
        outbox.serverDraftId = serverDraftId
        outbox.draftServerUidValidity = draftUidValidity
        outbox.draftServerFolderPath = draftServerFolderPath
        outbox.serverDraftGmailMessageId = serverDraftGmailMessageId
        outbox.draftId = draftId
        outbox.instanceEpoch = instanceEpoch
        // Hold the send until `now + undoHold + claimBuffer`. UI Undo button is
        // shown for `undoHold` (5 s); drain claim fires after +1 s claim buffer.
        // The 1 s gap eliminates TOCTOU races between user-taps-Undo and the
        // atomic claim transaction.
        outbox.holdUntil = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )

        // Save attachments to disk first (outside DB transaction — a file I/O
        // failure must not leave an outbox row pointing at a half-written dir).
        if !draft.attachments.isEmpty {
            try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
        }

        // Capture immutable, Sendable values for the @Sendable async write closure.
        let outboxToInsert = outbox
        let inReplyTo = draft.inReplyTo
        let hadAttachments = !draft.attachments.isEmpty
        do {
            let result = try await AppDatabase.dbPool.write { db -> (outboxId: String, deduped: Bool, resolvedOriginalId: String?) in
                // PORT/SUBTRACT — the v2final authority projection and bounded
                // same-account census, strengthened to require the live Draft.
                // Replacement or disappearance fails closed before dedup/insert.
                guard let liveDraft = try DraftSendAuthority.fetchOne(
                    db,
                    sql: """
                        SELECT accountId, instanceEpoch
                        FROM draft
                        WHERE id = ?
                        LIMIT 1
                        """,
                    arguments: [draftId]) else {
                    throw OutboxAdmissionError.draftMissing(draftId)
                }
                guard liveDraft.accountId == accountId else {
                    throw OutboxAdmissionError.draftOwnerMismatch(draftId: draftId)
                }
                guard liveDraft.instanceEpoch == instanceEpoch else {
                    throw OutboxAdmissionError.draftGenerationMismatch(draftId: draftId)
                }

                let candidates = try inFlightOutboxCandidates(
                    accountId: accountId, draftId: draftId, db: db)
                guard candidates.count <= 1 else {
                    throw OutboxAdmissionError.ambiguousInFlightCandidates(draftId: draftId)
                }
                if let existing = candidates.first {
                    guard existing.instanceEpoch == instanceEpoch else {
                        throw OutboxAdmissionError.inFlightGenerationMismatch(draftId: draftId)
                    }
                    return (existing.id, true, nil)
                }
                try outboxToInsert.insert(db)
                // Optimistic isReplied/isForwarded — matches markRead/archive pattern.
                // Server state overwrites on next sync (~90s). No rollback needed.
                guard let originalId = replyToHeaderId else { return (outboxToInsert.id, false, nil) }
                guard let original = try resolveOriginalMessage(
                    originalId: originalId,
                    inReplyTo: inReplyTo,
                    accountId: accountId,
                    db: db
                ) else { return (outboxToInsert.id, false, nil) }
                if isForward {
                    try db.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [original.id])
                } else {
                    try db.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [original.id])
                    // Clear "Reply" action tag — user already committed to replying.
                    // PendingOperation(.setTag) for server sync stays in finalizeOutboxMessage.
                    if original.actionTag == .reply {
                        try db.execute(
                            sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ? WHERE id = ?",
                            arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, original.id]
                        )
                    }
                }
                return (outboxToInsert.id, false, original.id)
            }
            // Deduped → the attachments dir we just wrote (named by the discarded
            // new outbox.id) is orphaned; clean it up. The kept (existing) row owns
            // its own dir from its original queueSend.
            if result.deduped, hadAttachments {
                outbox.deleteAttachments()
            }
            return result
        } catch {
            // Clean up attachments if DB insert failed.
            outbox.deleteAttachments()
            throw error
        }
    }

    /// Generate an RFC822 Message-ID for a given sender email address.
    /// Format: <UUID@domain>
    nonisolated static func generateMessageId(senderEmail: String) -> String {
        let domain = senderEmail.split(separator: "@").last.map(String.init) ?? "tabmail.local"
        return "<\(UUID().uuidString)@\(domain)>"
    }

    /// Drain all queued outbox messages. Also retries pending Sent folder appends
    /// for messages that were sent but whose IMAP APPEND didn't complete.
    ///
    /// Serial design: picks the oldest ready (past-hold) queued message, sends it,
    /// sleeps `outboxMinSendGapSeconds` (global rate limit), then re-fetches. Per-
    /// iteration re-fetch catches messages whose hold expires during our sleep.
    /// An `attempted` set prevents transient-failure rows from being retried
    /// within this drain pass (they'd spin the loop forever). After the loop,
    /// if any queued rows remain with future `holdUntil`, schedule a fire-and-
    /// forget wake-up Task for the earliest one.
    ///
    /// Only processes `.queued` messages — `.failed` messages require explicit
    /// user retry (swipe-to-retry sets status back to `.queued`).
    ///
    /// All DB writes use `do/catch` (never `try?`) because silent failures on
    /// status transitions can cause double-sends via crash recovery.
    func drainOutbox() async {
        guard !isDrainingOutbox else {
            print("[Outbox] Skipped drain — already draining")
            return
        }
        guard NetworkMonitor.checkConnected() else {
            print("[Outbox] Skipped drain — offline")
            return
        }
        isDrainingOutbox = true
        defer { isDrainingOutbox = false }

        // Log non-queued messages for debugging (stuck/failed). Only fires when
        // there's something unusual to report.
        do {
            let stuckMessages = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") != OutboxStatus.queued.rawValue)
                    .fetchAll(db)
            }
            for m in stuckMessages {
                print("[Outbox] Stuck message: id=\(m.id) status=\(m.status) retryCount=\(m.retryCount) sentAt=\(String(describing: m.sentAt)) appendedToSent=\(m.appendedToSent) error=\(m.errorMessage ?? "nil") to=\(m.to)")
            }
        } catch {
            print("[Outbox] ERROR: Failed to check outbox state: \(error)")
        }

        // Phase 1: Retry pending Sent folder appends (sent but not yet appended)
        await drainPendingSentAppends()

        // Phase 2: Serial drain of ready (past-hold) queued messages.
        var attempted: Set<String> = []
        var drainedCount = 0

        while !Task.isCancelled {
            // Fetch all queued, filter in Swift — `try?` on a closure returning
            // Optional would produce a double-Optional that doesn't auto-flatten.
            let queuedAll: [OutboxMessage] = (try? await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") == OutboxStatus.queued.rawValue)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }) ?? []
            guard let msg = queuedAll.first(where: {
                !attempted.contains($0.id) &&
                ($0.holdUntil ?? .distantPast) <= Date() &&
                workQueues[$0.accountId] != nil
            }) else { break }
            attempted.insert(msg.id)

            guard let (current, messageId) = await atomicClaim(msg) else { continue }

            // NOTE: local Draft deletion happens on send COMPLETION
            // (finalizeOutboxMessage), not at claim time. If SMTP fails
            // transiently, the draft stays in DraftStore so the user can
            // retry or edit.

            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            await sendSingleOutboxMessage(current, messageId: messageId)
            drainedCount += 1

            // Rate limit: sleep between sends. Global serial — all accounts
            // share this spacing. Acceptable trade-off for a rarely-deep outbox.
            try? await Task.sleep(
                nanoseconds: UInt64(SyncConfig.outboxMinSendGapSeconds * 1_000_000_000)
            )
        }

        if drainedCount > 0 {
            print("[Outbox] Drained \(drainedCount) message(s)")
        }

        // Schedule a wake-up Task for the earliest still-pending future-hold
        // message. Handles the just-queued case AND app-relaunch: if queueSend
        // ran this session, its `Task { drainOutbox() }` triggered us and we
        // fell through the loop (hold still future); we schedule the wake-up
        // here. On relaunch, reconcileOutbox calls drainOutbox (line 854);
        // same flow. Multiple concurrent wake-ups are harmless — the
        // isDrainingOutbox guard serializes re-entry.
        // `attempted` isn't in the filter: if a row was attempted and left
        // .queued (transient failure), we don't auto-retry this session — the
        // next natural drain trigger (foreground, sync, queueSend) handles it.
        let earliest: OutboxMessage?
        do {
            earliest = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") == OutboxStatus.queued.rawValue)
                    .order(Column("holdUntil").asc)
                    .fetchOne(db)
            }
        } catch {
            earliest = nil
        }
        if let earliest, let hold = earliest.holdUntil, hold > Date() {
            let interval = hold.timeIntervalSinceNow
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.drainOutbox()
            }
        }
    }

    /// Atomic claim: re-read + status check + mark .sending + persist sentMessageId
    /// in a single write transaction. Returns nil if the row vanished (discarded)
    /// or is no longer .queued. Same pattern as drainPendingQueue's atomic claim.
    private func atomicClaim(_ msg: OutboxMessage) async -> (message: OutboxMessage, messageId: String)? {
        // Look up sender email for Message-ID generation (outside the write txn).
        let senderEmail: String? = try? await dbPool.read { db in
            try Account.fetchOne(db, key: msg.accountId)?.emailAddress
        }
        do {
            return try await dbPool.write { db -> (OutboxMessage, String)? in
                guard let fetched = try OutboxMessage.fetchOne(db, key: msg.id) else {
                    return nil // vanished (discarded)
                }
                guard fetched.outboxStatus == .queued else {
                    return nil // already claimed
                }
                let messageId = fetched.sentMessageId ?? AccountManager.generateMessageId(senderEmail: senderEmail ?? "user@tabmail.local")
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, messageId, fetched.id]
                )
                return (fetched, messageId)
            }
        } catch {
            print("[Outbox] WARNING: Could not claim \(msg.id): \(error)")
            return nil
        }
    }

    /// Send a single outbox message. Called serially from drainOutbox.
    /// Errors are self-contained: transient failures leave the row as .queued
    /// (retry on next drain), permanent failures increment retryCount and
    /// eventually flip to .failed (user-visible, manual retry).
    private func sendSingleOutboxMessage(_ current: OutboxMessage, messageId: String) async {
        guard let queue = workQueues[current.accountId] else { return }
        let provider = queue.provider

        print("[Outbox] Sending message \(current.id) to \(current.to.joined(separator: ", "))")

        do {
            let draft: DraftMessage
            do {
                draft = try current.toDraftMessage()
            } catch {
                // Attachment files corrupted/missing — mark as failed, do NOT send
                // an incomplete email (missing attachments = silent data corruption).
                print("[Outbox] ERROR: Could not reconstruct draft for \(current.id): \(error)")
                try? await retryWrite(dbPool, label: "Outbox") { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ?, errorMessage = ? WHERE id = ?",
                        arguments: [OutboxStatus.failed.rawValue, "Attachment files could not be loaded. The message was NOT sent.", current.id]
                    )
                }
                return
            }

            // Inject the pre-generated Message-ID into the draft so the provider
            // uses it for SMTP send (ensuring IMAP append uses the same ID).
            var draftWithId = draft
            draftWithId.messageId = messageId
            let draftToSend = draftWithId

            print("[Outbox] Sending \(current.id) via \(type(of: provider))")
            try await queue.execute(priority: .userAction) {
                try await provider.send(draft: draftToSend)
            }
            print("[Outbox] Send succeeded for \(current.id)")

            // PORT 4651d894b: a send without a truthful durable stamp may not
            // append or finalize. Reconcile accepts a possible resend, never a drop.
            guard await stampSentAt(
                outboxId: current.id, sentDate: Date()
            ) else { return }

            // Optimistic Sent folder header: insert a placeholder MessageHeader so the
            // message appears in the Sent folder immediately (before IMAP APPEND + sync).
            // Uses rfc822MessageId for dedup — sync will replace this with the real UID.
            await insertOptimisticSentHeader(outboxMessage: current, messageId: messageId, draft: draftWithId)

            // Attempt Sent folder append. If it fails, the message stays in the
            // outbox with sentAt set — drainPendingSentAppends will retry later.
            let appended = await attemptSentAppend(
                provider: provider,
                draft: draftWithId,
                accountId: current.accountId,
                messageId: messageId,
                outboxId: current.id
            )

            if appended {
                // Both send and append succeeded — finalize.
                await finalizeOutboxMessage(current)
            } else {
                print("[Outbox] Sent but append to Sent folder pending — will retry (id: \(current.id))")
            }

            print("[Outbox] Sent successfully (id: \(current.id))")
        } catch {
            // Send failed — three-tier error classification:
            // 1. Fatal (invalid recipient, message too large): immediately mark 'failed',
            //    no retries. These will never succeed without user intervention.
            // 2. Transient (connection, TLS, timeout): keep 'queued' indefinitely
            //    without incrementing retryCount. Resolves on its own.
            // 3. Permanent (auth, command rejected): increment retryCount, mark
            //    'failed' after 3 attempts so user can retry or discard.
            if !(error is CancellationError) && !SyncEngine.isConnectionError(error) {
                BackgroundSyncLogger.logError("Send failed for \(current.id): \(error)", source: "outbox:\(current.accountId)")
            }
            let errorDesc = String(describing: error)
            let isFatal = Self.isFatalSendError(error)
            let isTransient = !isFatal && Self.isTransientSendError(error)
            let newRetryCount = isTransient ? current.retryCount : current.retryCount + 1
            let shouldAutoRetry = !isFatal && (isTransient || newRetryCount < 3)
            let newStatus = shouldAutoRetry ? OutboxStatus.queued.rawValue : OutboxStatus.failed.rawValue

            do {
                try await retryWrite(dbPool, label: "Outbox") { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                        arguments: [newStatus, errorDesc, newRetryCount, current.id]
                    )
                }
                NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            } catch {
                print("[Outbox] CRITICAL: Could not update \(current.id) status — stays as 'sending', will be re-queued on restart")
            }
            if isFatal {
                print("[Outbox] Send failed for \(current.id) (fatal, no retry — requires user action): \(error)")
            } else if isTransient {
                print("[Outbox] Send failed for \(current.id) (transient, will auto-retry on next drain): \(error)")
            } else if shouldAutoRetry {
                print("[Outbox] Send failed for \(current.id) (permanent retry \(newRetryCount)/3, will auto-retry): \(error)")
            } else {
                print("[Outbox] Send failed for \(current.id) after \(newRetryCount) permanent failures — marked as failed: \(error)")
            }
        }
    }

    // MARK: - Error Classification

    /// Classify whether a send error is definitively unrecoverable on first attempt.
    /// Fatal errors (invalid recipient, message too large) will never succeed no matter how
    /// many times we retry — mark as 'failed' immediately so the user can fix and retry.
    nonisolated static func isFatalSendError(_ error: Error) -> Bool {
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .invalidEmailAddress, .messageTooLarge:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Classify whether a send error is transient (will resolve on its own) vs permanent.
    /// Transient errors keep the message as 'queued' indefinitely without incrementing retryCount.
    /// Permanent errors increment retryCount and mark as 'failed' after 3 attempts.
    nonisolated static func isTransientSendError(_ error: Error) -> Bool {
        // SMTPError cases
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .connectionFailed, .tlsFailed, .sendFailed:
                // Connection issues, TLS negotiation, send failures are transient
                return true
            case .authenticationFailed, .invalidEmailAddress, .commandFailed, .messageTooLarge, .invalidResponse, .unexpectedResponse:
                // Auth failures, bad addresses, server rejections are permanent
                return false
            }
        }
        // URL/network errors are transient
        if (error as NSError).domain == NSURLErrorDomain { return true }
        // NIO connection errors are transient
        let desc = String(describing: error)
        if desc.contains("connection") || desc.contains("timeout") || desc.contains("Connection") { return true }
        // Default: treat as permanent to avoid infinite retries on truly broken sends
        return false
    }

    // MARK: - Optimistic Sent Header

    /// Insert a placeholder MessageHeader into the Sent folder so the message appears
    /// immediately in the UI after send succeeds. Uses rfc822MessageId (the pre-generated
    /// Message-ID) for dedup — when sync brings in the real IMAP UID, the placeholder is
    /// replaced in-place (same pattern as optimistic drafts).
    private func insertOptimisticSentHeader(outboxMessage msg: OutboxMessage, messageId: String, draft: DraftMessage) async {
        do {
            // Write transaction returns FTS data for post-transaction indexing.
            // Same pattern as queueDraftSave — headerComplete=1 must be set via the real
            // FTS pipeline, not manually, otherwise the body queue / recovery logic misbehaves.
            let ftsInfo: (record: FTSHeaderRecord, bodyText: String)? = try await dbPool.write { db -> (FTSHeaderRecord, String)? in
                guard let sentFolder = try Folder
                    .filter(Column("accountId") == msg.accountId && Column("role") == FolderRole.sent.rawValue)
                    .fetchOne(db) else {
                    return nil // No Sent folder — nothing to insert into
                }

                let folderId = sentFolder.id
                let rfc822 = EmailFilter.normalizeMessageId(messageId)

                // Don't insert if a header with this rfc822MessageId already exists (idempotent)
                if try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchOne(db) != nil {
                    return nil
                }

                let senderAccount = try Account.fetchOne(db, key: msg.accountId)
                let senderEmail = senderAccount?.emailAddress ?? msg.accountId
                let senderDisplayName = senderAccount?.displayName ?? senderEmail
                let plainText = draft.isHTML ? EmailFilter.htmlToPlainText(draft.body) : draft.body
                let snippet = EmailFilter.snippetFromPlainText(plainText)
                let placeholderMsgId = "sent-\(msg.id)"
                let headerId = "\(msg.accountId):\(sentFolder.path):\(placeholderMsgId)"
                let now = Date()

                var header = MessageHeader(
                    messageId: placeholderMsgId,
                    subject: msg.subject,
                    from: senderDisplayName,
                    fromAddress: senderEmail,
                    to: msg.to.joined(separator: ", "),
                    date: now,
                    snippet: snippet,
                    folderId: folderId,
                    accountId: msg.accountId,
                    folderPath: sentFolder.path,
                    isInInbox: false
                )
                header.rfc822MessageId = rfc822
                header.cc = msg.cc.joined(separator: ", ")
                header.bcc = msg.bcc.joined(separator: ", ")
                header.isRead = true
                header.inReplyTo = msg.inReplyTo.map { EmailFilter.normalizeMessageId($0) }
                header.referencesJSON = MessageHeader.encodeReferences(msg.references)
                // Thread grouping so the sent message appears in the conversation
                try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: nil, db: db)
                try header.insert(db)
                try ThreadUtils.insertMessageReferences(for: header, db: db)

                // Also create MessageBody so the message is viewable immediately
                if draft.isHTML {
                    let body = MessageBody(contentKey: ContentKey(rawValue: headerId), htmlContent: draft.body)
                    try body.save(db)
                } else {
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(contentKey: ContentKey(rawValue: headerId), htmlContent: htmlBody)
                    try body.save(db)
                }

                return (FTSHeaderRecord(
                    contentKey: ContentKey(rawValue: headerId),
                    headerId: headerId,
                    messageId: placeholderMsgId,
                    subject: msg.subject,
                    from: "\(senderDisplayName) <\(senderEmail)>",
                    to: msg.to.joined(separator: ", "),
                    cc: msg.cc.joined(separator: ", "),
                    bcc: msg.bcc.joined(separator: ", "),
                    dateMs: Int64(now.timeIntervalSince1970 * 1000),
                    folderId: folderId
                ), plainText)
            }

            // FTS indexing + headerComplete — runs after GRDB write succeeds.
            // Each step independently caught so failure in one doesn't block the others.
            // Without headerComplete=1, the optimistic header is invisible in the Sent folder
            // view (InboxViewModel filters by headerComplete==true).
            if let ftsInfo {
                do {
                    _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                    if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await SearchIndex.shared.updateBodies([(contentKey: ftsInfo.record.contentKey, body: ftsInfo.bodyText)])
                    }
                } catch {
                    print("[Outbox] WARNING: FTS indexing failed for sent \(ftsInfo.record.headerId): \(error)")
                }
                do {
                    // bodyComplete=1: the body is already persisted locally (MessageBody row
                    // inserted above), so nothing to fetch. Without this, BackfillBodyQueue's
                    // repopulate (headerComplete=1 AND bodyComplete=0 AND isInInbox=0) picks
                    // up the placeholder and feeds its synthetic "sent-<UUID>" messageId to
                    // GmailProvider/GraphAPI → HTTP 400 invalid id, every cold start, until
                    // the delta-sync dedup (SyncEngineDeltaSync) replaces the row.
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1, bodyComplete = 1 WHERE id = ?",
                            arguments: [ftsInfo.record.headerId]
                        )
                    }
                } catch {
                    print("[Outbox] WARNING: headerComplete write failed for sent \(ftsInfo.record.headerId): \(error)")
                }
            }

            // Always post reload notification — UI refreshes regardless of FTS/headerComplete success.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            print("[Outbox] Inserted optimistic Sent header for \(msg.id)")
        } catch {
            // Non-fatal — the message will appear after sync
            print("[Outbox] WARNING: Could not insert optimistic Sent header: \(error)")
        }
    }

    private func stampSentAt(outboxId: String, sentDate: Date) async -> Bool {
        do {
            return try await retryWrite(
                dbPool, retryDelay: .milliseconds(200), label: "Outbox.sentAt"
            ) { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?",
                    arguments: [sentDate, outboxId])
                return db.changesCount == 1
            }
        } catch {
            print("[Outbox] WARNING: Could not stamp sentAt for \(outboxId): \(error)")
            return false
        }
    }

    // MARK: - Sent Folder Append

    /// Attempt to append a sent message to the Sent folder. Returns true if successful.
    private func attemptSentAppend(
        provider: any EmailProvider,
        draft: DraftMessage,
        accountId: String,
        messageId: String,
        outboxId: String
    ) async -> Bool {
        // Look up Sent folder path for this account
        let sentPath: String?
        do {
            sentPath = try await dbPool.read { db in
                try Folder
                    .filter(Column("accountId") == accountId)
                    .filter(Column("role") == FolderRole.sent.rawValue)
                    .fetchOne(db)?
                    .path
            }
        } catch {
            print("[Outbox] WARNING: Could not look up Sent folder for \(accountId): \(error)")
            return false
        }

        guard let sentPath else {
            print("[Outbox] WARNING: No Sent folder found for account \(accountId)")
            // No Sent folder configured — can't append. Mark as appended to avoid
            // blocking the outbox forever. The message was sent via SMTP.
            return await markAppendedToSent(outboxId: outboxId)
        }

        do {
            guard let queue = workQueues[accountId] else { return false }
            let result = try await queue.execute(priority: .userAction) {
                try await provider.appendToSentFolder(draft: draft, sentFolderPath: sentPath, messageId: messageId)
            }
            guard result else { return false }
            return await markAppendedToSent(outboxId: outboxId)
        } catch {
            print("[Outbox] WARNING: Failed to append to Sent folder for \(outboxId): \(error)")
            return false
        }
    }

    /// Mark an outbox message as having been appended to the Sent folder.
    @discardableResult
    private func markAppendedToSent(outboxId: String) async -> Bool {
        do {
            return try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET appendedToSent = 1 WHERE id = ?",
                    arguments: [outboxId]
                )
                return db.changesCount == 1
            }
        } catch {
            print("[Outbox] WARNING: Could not mark \(outboxId) as appended to Sent: \(error)")
            return false
        }
    }

    /// Drain pending Sent folder appends — messages that were sent via SMTP but whose
    /// IMAP APPEND to the Sent folder didn't complete (crash, connection drop, etc.).
    private func drainPendingSentAppends() async {
        let pendingMessages: [OutboxMessage]
        do {
            pendingMessages = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("sentAt") != nil)
                    .filter(Column("appendedToSent") == false)
                    .fetchAll(db)
            }
        } catch {
            print("[Outbox] ERROR: Failed to fetch pending sent appends: \(error)")
            return
        }

        guard !pendingMessages.isEmpty else { return }
        print("[Outbox] Retrying \(pendingMessages.count) pending Sent folder appends")

        for msg in pendingMessages {
            guard let queue = workQueues[msg.accountId] else {
                print("[Outbox] No provider for \(msg.accountId) — skipping sent append")
                continue
            }
            let provider = queue.provider

            guard let messageId = msg.sentMessageId else {
                // No Message-ID stored — can't dedup. Mark as appended to unblock.
                print("[Outbox] WARNING: No sentMessageId for \(msg.id) — marking as appended")
                await markAppendedToSent(outboxId: msg.id)
                await finalizeOutboxMessage(msg)
                continue
            }

            let draft: DraftMessage
            do {
                draft = try msg.toDraftMessage()
            } catch {
                // Attachments already cleaned up from a previous partial finalize.
                // Build a draft without attachments — the email was already sent,
                // we just need the content for the Sent folder copy.
                var draftWithoutAttachments = DraftMessage(
                    to: msg.to,
                    cc: msg.cc,
                    bcc: msg.bcc,
                    subject: msg.subject,
                    body: msg.body,
                    isHTML: msg.isHTML,
                    inReplyTo: msg.inReplyTo,
                    references: msg.references,
                    attachments: []
                )
                draftWithoutAttachments.messageId = messageId
                draft = draftWithoutAttachments
            }

            var draftWithId = draft
            draftWithId.messageId = messageId

            let appended = await attemptSentAppend(
                provider: provider,
                draft: draftWithId,
                accountId: msg.accountId,
                messageId: messageId,
                outboxId: msg.id
            )

            if appended {
                await finalizeOutboxMessage(msg)
            }
        }
    }

    /// Finalize an outbox message: update reply/forward flags, delete from DB, clean up attachments.
    /// Called only after BOTH send and Sent folder append have succeeded.
    /// PORT — atomic reducer from 1b8ab1e32 with owner/generation rules from
    /// 476e257a5 and 97497416b. Completion is verified by the caller, not
    /// duplicated here.
    nonisolated static func deleteCompletedSendAtomic(
        outboxId: String,
        db: Database
    ) throws -> CompletedSendCleanupDisposition {
        guard let outbox = try OutboxMessage.fetchOne(db, key: outboxId) else {
            throw OutboxFinalizeError.outboxRowVanished(outboxId)
        }

        var replyDetectHeaderId: String?
        if let originalId = outbox.originalMessageHeaderId,
           var original = try resolveOriginalMessage(
                originalId: originalId,
                inReplyTo: outbox.inReplyTo,
                accountId: outbox.accountId,
                db: db
           ) {
            if outbox.isForward {
                original.isForwarded = true
                try PendingOperation(
                    type: .markForwarded,
                    messageIds: [original.stableId],
                    accountId: original.accountId,
                    folderPath: original.folderPath).insert(db)
            } else {
                original.isReplied = true
                try PendingOperation(
                    type: .markReplied,
                    messageIds: [original.stableId],
                    accountId: original.accountId,
                    folderPath: original.folderPath).insert(db)
                if original.actionTag == .reply {
                    original.actionTag = ActionTag.none
                    original.tagSortOrder = ActionTag.none.sortOrder
                    try PendingOperation(
                        type: .setTag,
                        messageIds: [original.stableId],
                        accountId: original.accountId,
                        folderPath: original.folderPath,
                        tagValue: ActionTag.none.rawValue).insert(db)
                    replyDetectHeaderId = originalId
                }
            }
            try original.update(db)
        }

        var draftDir: String?
        var cleanup: ServerDraftCleanup?
        var preservedMismatchedDraftId: String?
        if let draftId = outbox.draftId,
           let liveDraft = try Draft.fetchOne(db, key: draftId) {
            if liveDraft.accountId == outbox.accountId,
               let ownerEpoch = outbox.instanceEpoch,
               !ownerEpoch.isEmpty,
               liveDraft.instanceEpoch == ownerEpoch {
                draftDir = liveDraft.attachmentsDirName
                if let serverDraftId = liveDraft.serverDraftId ?? outbox.serverDraftId {
                    cleanup = ServerDraftCleanup(
                        accountId: outbox.accountId,
                        serverDraftId: serverDraftId,
                        gmailContainedMessageId: outbox.serverDraftGmailMessageId,
                        folderPath:
                            liveDraft.serverDraftFolderPath
                            ?? outbox.draftServerFolderPath,
                        uidValidity:
                            liveDraft.serverDraftUidValidity
                            ?? outbox.draftServerUidValidity)
                }
                try DraftStore.applyDelete(
                    id: liveDraft.id,
                    expectedInstanceEpoch: ownerEpoch,
                    db: db)
            } else {
                preservedMismatchedDraftId = liveDraft.id
            }
        } else if let serverDraftId = outbox.serverDraftId {
            // An absent local Draft leaves the immutable Outbox owner authoritative.
            cleanup = ServerDraftCleanup(
                accountId: outbox.accountId,
                serverDraftId: serverDraftId,
                gmailContainedMessageId: outbox.serverDraftGmailMessageId,
                folderPath: outbox.draftServerFolderPath,
                uidValidity: outbox.draftServerUidValidity)
        }

        let outboxDir = outbox.attachmentsDirName
        guard try OutboxMessage.deleteOne(db, key: outbox.id) else {
            throw OutboxFinalizeError.outboxDeleteDidNotLand(outbox.id)
        }
        return CompletedSendCleanupDisposition(
            accountId: outbox.accountId,
            outboxDir: outboxDir,
            draftDir: draftDir,
            replyDetectHeaderId: replyDetectHeaderId,
            serverDraftCleanup: cleanup,
            preservedMismatchedDraftId: preservedMismatchedDraftId)
    }

    private func finalizeOutboxMessage(_ msg: OutboxMessage) async {
        // PORT 4651d894b: fresh completion verification before any mutation.
        do {
            guard let fresh = try await dbPool.read({
                try OutboxMessage.fetchOne($0, key: msg.id)
            }), fresh.sentAt != nil, fresh.appendedToSent else {
                return
            }
        } catch {
            return
        }

        let disposition: CompletedSendCleanupDisposition
        do {
            disposition = try await retryWrite(
                dbPool, label: "Outbox"
            ) { db in
                try Self.deleteCompletedSendAtomic(outboxId: msg.id, db: db)
            }
        } catch {
            print("[Outbox] CRITICAL: atomic finalize failed for \(msg.id); leaving it for reconcile")
            return
        }

        if let outboxDir = disposition.outboxDir {
            let url = OutboxMessage.attachmentsBaseDir
                .appendingPathComponent(outboxDir, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
        if let draftDir = disposition.draftDir {
            DraftAttachmentStorage.deleteAttachments(dirName: draftDir)
        }
        if let replyId = disposition.replyDetectHeaderId {
            NotificationCenter.default.post(
                name: .messageDataDidChange, object: replyId)
        }
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        if let mismatched = disposition.preservedMismatchedDraftId {
            print("[Outbox] Preserved owner/generation-mismatched Draft \(mismatched)")
        }

        if let cleanup = disposition.serverDraftCleanup,
           let provider = providers[cleanup.accountId] {
            let kind = Self.draftRuntimeIdentityKind(for: provider)
            let identity: DraftDeleteIdentity?
            switch kind {
            case .gmail:
                if !cleanup.serverDraftId.isEmpty {
                    identity = .gmail(resourceId: cleanup.serverDraftId)
                } else if let contained = cleanup.gmailContainedMessageId {
                    identity = .gmailContainedMessage(messageId: contained)
                } else {
                    identity = nil
                }
            case .outlook:
                identity = .outlook(graphId: cleanup.serverDraftId)
            case .demo:
                identity = .demo(localId: cleanup.serverDraftId)
            case .imap:
                if let folder = cleanup.folderPath,
                   let epoch = cleanup.uidValidity,
                   let uid = Int(cleanup.serverDraftId), uid > 0 {
                    identity = .imap(
                        folder: folder, uidValidity: epoch, uid: uid)
                } else {
                    identity = nil
                }
            case .unknown:
                identity = nil
            }
            if let identity {
                _ = await queueDraftDelete(
                    identity: identity,
                    accountId: cleanup.accountId,
                    folderPath: cleanup.folderPath)
            }
        }

        if let queue = workQueues[disposition.accountId] {
            let accountId = disposition.accountId
            Task {
                do {
                    if let folder = try await self.dbPool.read({ db in
                        try Folder
                            .filter(Column("accountId") == accountId
                                && Column("role") == FolderRole.sent.rawValue)
                            .fetchOne(db)
                    }) {
                        try await queue.execute(priority: .userAction) {
                            try await self.syncEngine.syncFolderMessages(
                                folder: folder, provider: queue.provider)
                        }
                    }
                } catch {
                    print("[Outbox] Post-send Sent folder sync failed: \(error)")
                }
            }
        }
    }
    /// Resolve the original message for isReplied/isForwarded updates.
    ///
    /// PORT/SUBTRACT — v2final's ADR-IOS-061 F6/F7 guard, reduced to the
    /// provider-ID forward-port boundary. The exact local provider key must still
    /// belong to the sending account, and the outbox's own In-Reply-To must
    /// corroborate the row's RFC identity. Missing or disagreeing evidence fails
    /// closed. The reference's RFC candidate search, sibling expansion, and
    /// reset/redrive machinery are intentionally omitted; sync reconciles a moved
    /// or otherwise unprovable original without risking a wrong-message mutation.
    private nonisolated static func resolveOriginalMessage(
        originalId: String,
        inReplyTo: String?,
        accountId: String,
        db: Database
    ) throws -> MessageHeader? {
        guard let header = try MessageHeader.fetchOne(db, key: originalId),
              header.accountId == accountId,
              let expectedRfc = MessageIdentity.comparableRfc822Identity(inReplyTo),
              let headerRfc = MessageIdentity.comparableRfc822Identity(header.rfc822MessageId),
              expectedRfc == headerRfc else {
            return nil
        }
        return header
    }

    // draftsFolderPath is defined in AccountManagerActions

    /// Get the provider for an account by ID.
    private func providerForAccount(_ accountId: String) async throws -> any EmailProvider {
        guard let account = try await dbPool.read({ db in try Account.fetchOne(db, key: accountId) }),
              let provider = providers[account.id] else {
            throw NSError(domain: "AccountManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No provider for account \(accountId)"])
        }
        return provider
    }

    // MARK: - Crash Recovery

    /// On app launch, recover outbox state from any crash during the previous session.
    ///
    /// - Messages with `sentAt != nil` AND `appendedToSent == true` were fully completed
    ///   but the DB delete didn't finish — delete them now.
    /// - Messages with `sentAt != nil` AND `appendedToSent == false` were sent but the
    ///   Sent folder append didn't complete — keep them for drainPendingSentAppends.
    /// - Messages with `sentAt == nil` and status `sending` were mid-send when the app
    ///   crashed — reset to `queued` for retry (accepts the small double-send risk for
    ///   the case where send succeeded but sentAt write didn't).
    /// - Cleans up orphaned attachment directories that have no matching DB row.
    func reconcileOutbox() async {
        let stale: [OutboxMessage]
        do {
            stale = try await dbPool.read { db in
                try OutboxMessage
                    .filter(Column("status") == OutboxStatus.sending.rawValue)
                    .fetchAll(db)
            }
        } catch {
            return
        }

        for message in stale {
            if message.sentAt != nil, message.appendedToSent {
                await finalizeOutboxMessage(message)
            } else if message.sentAt == nil {
                try? await retryWrite(dbPool, label: "Outbox") { db in
                    try db.execute(
                        sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                        arguments: [OutboxStatus.queued.rawValue, message.id])
                }
            }
        }
        await cleanOrphanedAttachmentDirs()
        await drainOutbox()
    }
    /// Remove attachment directories that have no matching outboxMessage row.
    private func cleanOrphanedAttachmentDirs() async {
        let baseDir = OutboxMessage.attachmentsBaseDir
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        guard !dirs.isEmpty else { return }

        let existingIds: Set<String>
        do {
            existingIds = try await dbPool.read { db in
                let ids = try String.fetchAll(db, sql: "SELECT id FROM outboxMessage WHERE attachmentsDirName IS NOT NULL")
                return Set(ids)
            }
        } catch {
            print("[Outbox] WARNING: Could not fetch outbox IDs for orphan cleanup: \(error)")
            return
        }

        for dir in dirs {
            let dirName = dir.lastPathComponent
            if !existingIds.contains(dirName) {
                print("[Outbox] Cleaning orphaned attachment dir: \(dirName)")
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// Retry a failed outbox message. Resets status to queued and clears retryCount
    /// so the message gets a fresh set of automatic retries. Returns true if reset succeeded.
    @discardableResult
    nonisolated func retryOutboxMessage(_ messageId: String) -> Bool {
        do {
            try AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE outboxMessage SET status = ?, errorMessage = NULL, retryCount = 0 WHERE id = ?",
                    arguments: [OutboxStatus.queued.rawValue, messageId]
                )
            }
            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            Task { await self.drainOutbox() }
            return true
        } catch {
            print("[Outbox] ERROR: Failed to retry \(messageId): \(error)")
            return false
        }
    }

    /// Cancel one still-queued Outbox row and report whether the delete committed.
    /// Undo reopens compose only after this exact confirmation. Sending or sent-at
    /// rows are not cancellation authority; failed-but-unsent rows remain discardable.
    @discardableResult
    nonisolated func discardOutboxMessageConfirmed(_ messageId: String) -> Bool {
        do {
            let outcome: (deleted: Bool, dir: String?) = try AppDatabase.dbPool.write { db in
                guard let msg = try OutboxMessage.fetchOne(db, key: messageId),
                      msg.outboxStatus != .sending,
                      msg.sentAt == nil,
                      try OutboxMessage.deleteOne(db, key: messageId) else {
                    return (false, nil)
                }
                return (true, msg.attachmentsDirName)
            }
            guard outcome.deleted else { return false }
            if let dirName = outcome.dir {
                let dir = OutboxMessage.attachmentsBaseDir
                    .appendingPathComponent(dirName, isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
            }
            NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
            Task { await self.drainOutbox() }
            return true
        } catch {
            print("[Outbox] ERROR: Failed to cancel \(messageId): \(error)")
            return false
        }
    }

    /// Void wrapper for callers that do not need confirmation.
    nonisolated func discardOutboxMessage(_ messageId: String) {
        _ = discardOutboxMessageConfirmed(messageId)
    }
}
