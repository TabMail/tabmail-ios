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
                        // Raw SQL (not `MessageHeader.setActionTag`) because this
                        // path deliberately updates by id without materialising the
                        // row — so it stamps `actionTagSetAt` explicitly to keep
                        // `actionTag != nil ⇒ actionTagSetAt != nil`. `ActionTag.none`
                        // here is the real tag VALUE "none", not Optional.none.
                        try db.execute(
                            sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, actionTagSetAt = ? WHERE id = ?",
                            arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, Date(), original.id]
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
            let wakeNow = Date()
            earliest = try await dbPool.read { db in
                try Self.earliestFutureHoldWakeTarget(now: wakeNow, db: db)
            }
        } catch {
            earliest = nil
        }
        if let interval = Self.wakeUpDelay(for: earliest, at: Date()) {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.drainOutbox()
            }
        }
    }

    /// The queued row a wake-up timer must be armed for: the EARLIEST row whose
    /// `holdUntil` deadline has NOT yet elapsed.
    ///
    /// 🚨 THE FUTURE-HOLD PREDICATE IS THE WHOLE POINT (`IOS-OUTBOX-002`).
    /// Ordering by `holdUntil ASC` alone returns a legacy-NULL or already-elapsed
    /// hold FIRST — SQLite sorts NULL first under ASC, and a past instant sorts
    /// before a future one — so the caller's `hold > Date()` re-check failed on
    /// that shadowing row and NO timer was armed, even though a genuinely
    /// future-held row existed behind it. Such a row was then reached only by a
    /// later ordinary drain trigger (foreground, sync, another `queueSend`).
    ///
    /// This NARROWS the timer query; it widens nothing the drain acts on. Rows
    /// with a NULL or elapsed hold are already handled by the drain loop that
    /// runs above the timer, so excluding them from the *timer* removes no
    /// intention. Only `.queued` is considered, exactly as before — `.failed`
    /// still requires an explicit user Retry (Outbox Reliability Rule 8).
    ///
    /// `now` is a parameter, not `Date()` inside the query, so the caller's
    /// single instant decides both this selection and its own re-check.
    nonisolated static func earliestFutureHoldWakeTarget(
        now: Date,
        db: Database
    ) throws -> OutboxMessage? {
        try OutboxMessage
            .filter(Column("status") == OutboxStatus.queued.rawValue)
            .filter(Column("holdUntil") > now)
            .order(Column("holdUntil").asc)
            .fetchOne(db)
    }

    /// How long the wake-up timer must sleep before the next autonomous drain,
    /// given the row `earliestFutureHoldWakeTarget` selected and the instant of
    /// the caller's re-check. `nil` ONLY when there is no such row at all.
    ///
    /// 🚨 AN ALREADY-ELAPSED DEADLINE MEANS "DRAIN NOW", NEVER "DO NOTHING".
    /// The selection and this re-check read the clock at two different instants
    /// with an `await dbPool.read` between them, and the query's predicate is
    /// `holdUntil > now`. A row that was future when the query ran can therefore
    /// be past by the time the caller re-checks — and the drain loop above has
    /// already finished. A `hold > Date()` guard that simply fell through in
    /// that case armed NO timer at all and left the row `.queued` until some
    /// unrelated external trigger (foreground, sync, another `queueSend`)
    /// happened along. Clamping at zero schedules an immediate re-drain instead.
    ///
    /// **The re-drive terminates, and it claims the row.** The drain loop's own
    /// admission filter is `(holdUntil ?? .distantPast) <= Date()`, so a row
    /// whose deadline has passed is admitted by the very next pass rather than
    /// falling through again; and `earliestFutureHoldWakeTarget` filters
    /// `holdUntil > now`, so that same row is no longer a wake target and no
    /// second timer can be armed for it. There is no loop to spin.
    ///
    /// The clamp is also what keeps the caller's
    /// `UInt64(interval * 1_000_000_000)` from TRAPPING: converting a negative
    /// `Double` to `UInt64` is a runtime crash, not a saturating conversion.
    ///
    /// A still-future deadline is unaffected — `max(0, positive) == positive` —
    /// so the ordinary path is byte-identical to before.
    ///
    /// `instant` is a parameter for exactly the reason
    /// `earliestFutureHoldWakeTarget` takes `now`: the decision must be
    /// evaluable at a chosen instant, not only at whatever the wall clock
    /// happens to read while a test is running.
    nonisolated static func wakeUpDelay(for target: OutboxMessage?, at instant: Date) -> TimeInterval? {
        guard let hold = target?.holdUntil else { return nil }
        return max(0, hold.timeIntervalSince(instant))
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
                // D12: `sentAt` is THE double-send firewall (Outbox Reliability
                // Rule 3). It is stamped only after `provider.send()` returned
                // SUCCESS (`sendSingleOutboxMessage`), so a row carrying it has
                // already left the server — claiming it would transmit the
                // user's email a second time. Refuse it under EVERY status, and
                // check that BEFORE the status guard so no future status
                // transition can reopen the hole.
                //
                // This strands nothing: rows with `sentAt` belong exclusively to
                // Sent-append / finalization recovery, which selects on
                // `sentAt != nil AND appendedToSent == false` with NO status
                // predicate (`drainPendingSentAppends`) and runs as phase 1 of
                // every drain — before this send phase.
                guard fetched.sentAt == nil else {
                    print("[Outbox] Refusing to claim \(fetched.id) — sentAt is already stamped (double-send firewall); Sent-append/finalization recovery owns this row")
                    return nil
                }
                guard fetched.outboxStatus == .queued else {
                    return nil // already claimed
                }
                // F0a: re-check the undo-hold window IN-TXN. drainOutbox's
                // non-atomic Swift pre-filter (`($0.holdUntil ?? .distantPast)
                // <= Date()`) already skips future-hold rows, but a bypassed or
                // racing caller must never claim a row before its hold elapses —
                // the claim (status→.sending) is the irreversible start of send.
                guard (fetched.holdUntil ?? .distantPast) <= Date() else {
                    return nil // hold window not yet elapsed
                }
                let messageId = fetched.sentMessageId ?? AccountManager.generateMessageId(senderEmail: senderEmail ?? "user@tabmail.local")
                // D12: the claim write is itself a compare-and-swap carrying the
                // same two admission conditions (`status = 'queued'` AND
                // `sentAt IS NULL`), and must transition EXACTLY one row. The
                // firewall therefore travels with the UPDATE and cannot be
                // bypassed by a later refactor that moves the re-read out of
                // this transaction. A 0-row CAS fails CLOSED — no claim, the row
                // stays `.queued` for the next drain — never a send.
                try db.execute(
                    sql: """
                        UPDATE outboxMessage SET status = ?, sentMessageId = ?
                        WHERE id = ? AND status = ? AND sentAt IS NULL
                        """,
                    arguments: [OutboxStatus.sending.rawValue, messageId, fetched.id, OutboxStatus.queued.rawValue]
                )
                guard db.changesCount == 1 else {
                    print("[Outbox] CRITICAL: claim CAS did not transition exactly one row for \(fetched.id) — NOT sending; row left for the next drain")
                    return nil
                }
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
        guard let queue = workQueues[current.accountId] else {
            let requeued = await requeueClaimedOutboxMessage(current.id)
            if !requeued {
                print("[Outbox] CRITICAL: missing-provider rollback did not transition exactly one row for \(current.id) — a newer durable state won or the write failed")
            }
            return
        }
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
                // 🚨 NEVER `try?` ON AN OUTBOX STATE TRANSITION (Outbox rule 2).
                //
                // This write is the ONLY thing moving the row off `.sending`, and
                // the drain selects `.queued` only. Swallowing its failure stranded
                // the row at `.sending` / `sentAt == nil` — no drain would ever look
                // at it again and the Outbox UI offers no retry for a row that is
                // not `.failed`, so the user's message became invisible and
                // unsendable with no error shown. That is the dropped send this
                // rule exists to prevent.
                //
                // On failure we hand the row back to the drain with the SAME helper
                // the missing-provider claim uses, so the next pass re-attempts both
                // the reconstruction and this transition. Nothing was sent here, so
                // requeueing cannot double-send.
                do {
                    try await retryWrite(dbPool, label: "Outbox") { db in
                        try db.execute(
                            sql: "UPDATE outboxMessage SET status = ?, errorMessage = ? WHERE id = ?",
                            arguments: [OutboxStatus.failed.rawValue, "Attachment files could not be loaded. The message was NOT sent.", current.id]
                        )
                    }
                } catch {
                    print("[Outbox] CRITICAL: could not mark \(current.id) failed after attachment-load error: \(error) — requeueing so the row stays drainable")
                    let requeued = await requeueClaimedOutboxMessage(current.id)
                    if !requeued {
                        print("[Outbox] CRITICAL: attachment-failure rollback did not transition exactly one row for \(current.id) — a newer durable state won or the write failed")
                    }
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

    /// Return one exact, definitely-unsent claim to the ordinary drain after
    /// its runtime provider disappears between `atomicClaim` and send.
    ///
    /// The SQL fence is the ownership proof: a stale caller cannot overwrite a
    /// failed/requeued row, and `sentAt IS NULL` prevents a completed provider
    /// send from ever being made drainable again. No other field is changed.
    private func requeueClaimedOutboxMessage(_ outboxId: String) async -> Bool {
        do {
            return try await retryWrite(dbPool, label: "Outbox") { db in
                try db.execute(
                    sql: """
                        UPDATE outboxMessage SET status = ?
                        WHERE id = ? AND status = ? AND sentAt IS NULL
                        """,
                    arguments: [
                        OutboxStatus.queued.rawValue,
                        outboxId,
                        OutboxStatus.sending.rawValue,
                    ]
                )
                return db.changesCount == 1
            }
        } catch {
            print("[Outbox] WARNING: Could not requeue missing-provider claim \(outboxId): \(error)")
            return false
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
        // IOS-TLS-002: a refused TLS floor is DETERMINISTIC and permanent — the
        // server cannot negotiate TLS 1.2 and no number of retries changes that.
        // Classified explicitly, and FIRST, because the substring heuristic at the
        // bottom of this function decides on the error's RENDERED text — and that
        // text is now a user-facing sentence, so a later copy edit introducing the
        // word "connection" would silently flip this to transient and requeue the
        // row forever, which is exactly the send-path half of `IOS-TLS-002`.
        //
        // Deliberately NOT `isFatalSendError`: the ordinary permanent path gives
        // three bounded auto-retries before `.failed`, which is a cheap hedge if
        // this ever misclassifies, and it still ends with the actionable message
        // visible on the Outbox row rather than an infinite silent queue.
        if error is IMAPTransportSecurityError { return false }
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
            // 🚨 ADMIT THROUGH THE PROVIDER-ADDRESS PREDICATE (audit A-6).
            //
            // Both flag ops below used to name `original.stableId` — an rfc822
            // Message-ID on IMAP — with no `observedUidValidity`. That is exactly
            // the shape the drain's checkpoint A exists to refuse, so on IMAP the
            // `\Answered` / `$Forwarded` keyword was queued and never executed,
            // every time: a silently accepted, deterministically lost action.
            // ⚠ CORRECTED (audit round 2): this said "deleted unexecuted on the
            // next drain", which was checkpoint A's behaviour when the defect
            // shipped. It now SKIPS rather than deletes — an absence of evidence is
            // not an exit — so the same shape today leaves a permanently
            // unclaimable row. Same loss to the user, different wreckage.
            //
            // `nil` here means the account row, the folder row or its epoch is
            // missing — an ABSENCE of evidence. We refuse to queue rather than
            // queue an op that can only be refused. That refusal is the documented
            // `IOS-EPOCH-001` fail-closed window and it STAYS.
            //
            // 🚨 THE LOCAL FLAG AND THE DURABLE OP SHARE ONE FATE (audit round 2).
            // `original.isReplied` / `.isForwarded` used to be set OUTSIDE these
            // guards, so when the admission was nil the local flag was written and
            // no durable op was queued — no retry, no record, no disposition to the
            // caller. `isReplied` is not a private note that the user composed
            // something; it is the local mirror of the server's `\Answered`, and
            // every reader treats it as such. Writing it while withholding the
            // gesture makes the UI assert a server-side flag that was never queued
            // and never will be — a claim about the SERVER, made on the strength of
            // evidence we just admitted we do not have. The two siblings that
            // decide the same question — `UserLabelMenuModel.applyLabel` /
            // `removeLabel` and `InboxViewModel.removeUserLabel` — both refuse
            // BEFORE the local mutation ("Refuse before the local insert so neither
            // half lands"), and this site now has the same shape rather than a
            // third one.
            //
            // ⚠ The FIX IS NOT to admit the gesture anyway. Withholding an
            // unaddressable durable op is the specified disposition; the defect was
            // only the local lie about what that withholding meant. When the
            // admission returns, the ordinary reply-detect sweep re-establishes the
            // flag from the server's own state.
            let flagAdmission = try AccountManager.admittedOrdinaryActionTargets(
                [original], accountId: original.accountId,
                folderPath: original.folderPath, db: db)
            if outbox.isForward {
                if let flagAdmission {
                    original.isForwarded = true
                    try PendingOperation(
                        type: .markForwarded,
                        messageIds: flagAdmission.providerIds,
                        accountId: original.accountId,
                        folderPath: original.folderPath,
                        observedUidValidity: flagAdmission.observedUidValidity).insert(db)
                }
            } else {
                if let flagAdmission {
                    original.isReplied = true
                    try PendingOperation(
                        type: .markReplied,
                        messageIds: flagAdmission.providerIds,
                        accountId: original.accountId,
                        folderPath: original.folderPath,
                        observedUidValidity: flagAdmission.observedUidValidity).insert(db)
                }
                // ⚑ DELIBERATELY OUTSIDE the admission guard. An action tag is
                // LOCAL-ONLY (ADR-IOS-036) — clearing `reply` claims nothing about
                // the server, so an unaddressable parent is no reason to leave a
                // stale "needs reply" badge on a message the user just replied to.
                // Its `.setTag` op is excluded from checkpoint A for the same
                // reason, which is why it carries `stableId` and no epoch.
                if original.actionTag == .reply {
                    // `ActionTag.none` is the real tag VALUE "none", not
                    // Optional.none — so this STAMPS `actionTagSetAt`, it does
                    // not clear it.
                    original.setActionTag(ActionTag.none)
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
    ///
    /// 🚨 THE DRAIN LATCH IS ACQUIRED HERE, IN THE SAME SYNCHRONOUS RUN AS THE
    /// CHECK, AND HELD ACROSS THE RESET WRITE. Do not move the check to a caller
    /// and do not "re-check it after the await" — that is the same race one
    /// frame later.
    ///
    /// The reset below is the ONE transition in the outbox that makes a
    /// `.sending` row claimable again, and durable state alone cannot tell the
    /// two producers of `.sending`/`sentAt == nil` apart: crash residue from a
    /// dead session (which MUST be reset) and a row a live in-process drain has
    /// just claimed and put on the SMTP wire (which must NOT be). `sentAt` does
    /// not separate them — it is stamped only AFTER `provider.send()` returns,
    /// so an in-flight send carries `sentAt == nil` exactly like residue.
    /// `isDrainingOutbox` is the only thing that separates them: `drainOutbox`
    /// sets it synchronously, holds it for the whole drain and `await`s
    /// `sendSingleOutboxMessage` inside that hold (its loop is that function's
    /// only production caller — the sole other reference is a `#if DEBUG`
    /// seam), and the NSE never sends.
    ///
    /// So the latch is what AUTHORISES the reset, and an authorising latch has
    /// to be observed no later than the write it authorises. Observing it and
    /// then suspending is not enough: `reconcileOutbox`'s first statement is an
    /// `await dbPool.read`, `AccountManager` is an actor, and
    /// `PrioritizedDatabase.read`'s async overload runs a full NSE staging merge
    /// before it reads (measured at 7.6 s on a cold-I/O boot) — and staging is
    /// pending precisely on foreground return. A drain starting in that window
    /// claimed a row, put its SMTP transaction on the wire, and this function
    /// then reset that row to `.queued` from a snapshot taken after the claim.
    /// `discardOutboxMessageConfirmed` refuses `.sending` and `sentAt != nil`,
    /// so a row reset that way became discardable WHILE ITS SEND WAS ON THE
    /// WIRE: the row and its attachments were deleted, `stampSentAt` matched no
    /// row, and the send returned at its guard — no optimistic Sent header, no
    /// Sent APPEND, no finalize. The recipient received a message the user had
    /// been told was discarded, and it never appeared in Sent. Outbox
    /// Reliability Rules 3 and 10 both forbid that.
    ///
    /// Holding the latch here closes BOTH production reconciliation entries at
    /// once — the launch one (`reconcilePendingOperations`, which had no check
    /// at all) and the foreground one (`reconcileOutboxOnForeground`) — because
    /// both funnel through this function.
    ///
    /// WHAT THE HOLD COSTS, stated as a fail-closed edge rather than hidden: a
    /// drain trigger that fires while reconciliation is running is skipped, and
    /// a reconciliation that finds a drain in flight returns without
    /// reconciling. Neither drops an intention. The skipped drain is subsumed by
    /// this function's own trailing `drainOutbox()`, which runs after the latch
    /// is released and re-reads the table. The skipped reconciliation is
    /// re-driven by the next reconciliation trigger — the next foreground return
    /// or launch — which is exactly the recoverability `IOS-OUTBOX-001`
    /// established; the orphan-attachment sweep it also skips is pure byte
    /// reclamation and is idempotent on the next pass.
    func reconcileOutbox() async {
        guard !isDrainingOutbox else {
            if DebugModeManager.isLoggingEnabled() {
                print("[Outbox] Skipped reconcile — a drain owns the outbox; a send may be on the wire")
            }
            return
        }
        do {
            isDrainingOutbox = true
            defer { isDrainingOutbox = false }
            await performOutboxReconciliation()
        }
        // Outside the hold, so the recovered rows this pass produced are
        // actually drained. Anything a skipped trigger would have drained is
        // re-selected here.
        await drainOutbox()
    }

    /// The reconciliation itself. Split out ONLY so `reconcileOutbox` can hold
    /// `isDrainingOutbox` across all of it and release it before the trailing
    /// drain; the classification and its writes are otherwise unchanged.
    private func performOutboxReconciliation() async {
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
                // 🚨 NEVER `try?` ON AN OUTBOX STATE TRANSITION (Outbox rule 2).
                //
                // This is the crash-recovery transition that makes a row the drain
                // can see again — `drainOutbox` selects `.queued` only. Swallowing
                // the failure left the row at `.sending` and the `drainOutbox()`
                // call at the bottom of this function then skipped it, so a message
                // the user believes is sending sat untouched for the rest of the
                // session with nothing logged.
                //
                // The next `reconcileOutbox` re-selects `.sending` and re-attempts,
                // so the row is not permanently stranded — but the failure must be
                // VISIBLE rather than silent, which is what this rule is for.
                do {
                    try await retryWrite(dbPool, label: "Outbox") { db in
                        try db.execute(
                            sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                            arguments: [OutboxStatus.queued.rawValue, message.id])
                    }
                } catch {
                    print("[Outbox] CRITICAL: crash-recovery requeue failed for \(message.id): \(error) — row remains .sending and will NOT drain until the next reconcile")
                }
            }
        }
        await cleanOrphanedAttachmentDirs()
    }

    /// Second trigger for `reconcileOutbox()`: foreground return.
    ///
    /// `IOS-OUTBOX-001` — reconciliation had exactly ONE trigger, `RootView`'s
    /// launch `.task` (via `reconcilePendingOperations`). A row left `.sending`
    /// with `sentAt == nil` — the crash-mid-send state, and the state reached
    /// when the retrying status write in `sendSingleOutboxMessage` exhausts —
    /// is invisible to `drainOutbox`, which selects `.queued` only, and
    /// `OutboxView` offers the user NO gesture for it: Retry is gated on
    /// `.failed` and Outbox Reliability Rule 10 forbids discarding a `sending`
    /// row. So the user could foreground and background the app all day and the
    /// message would never send and never fail — a dropped user intention by the
    /// wedge corollary, recoverable only by a full process relaunch.
    ///
    /// ⚠️ THIS FUNCTION USED TO CARRY ITS OWN `isDrainingOutbox` GUARD, UNDER A
    /// DO-NOT-RELAX BANNER ASSERTING THAT THE GUARD PROVED NO SEND WAS IN
    /// FLIGHT. THAT ASSERTION WAS FALSE and the banner is deleted rather than
    /// softened — a wrong invariant carrying a warning is worse than none. The
    /// guard read the latch and then `await`ed `reconcileOutbox()`, whose first
    /// statement suspends this actor for as long as an NSE staging merge takes;
    /// a drain starting in that window claimed a row and put its SMTP
    /// transaction on the wire, and the reset then landed on that row anyway.
    /// Checking a latch before a suspension proves nothing about the state at
    /// the write on the far side of it.
    ///
    /// The check now lives in `reconcileOutbox`, which ACQUIRES the latch in the
    /// same synchronous run and HOLDS it across the reset — see the reasoning
    /// there. This entry deliberately keeps no logic of its own, so the launch
    /// entry (`reconcilePendingOperations`, which never had a check at all) and
    /// this one are governed by exactly one piece of code.
    ///
    /// The reconciliation itself is unchanged, so the `sentAt`-before-delete
    /// asymmetry (Outbox Reliability Rule 3) travels with this trigger exactly
    /// as it does with the launch one: a row carrying `sentAt` is finalized or
    /// left to Sent-append recovery, and is NEVER re-queued. Only
    /// `sentAt == nil` rows are reset.
    func reconcileOutboxOnForeground() async {
        await reconcileOutbox()
    }

    /// D2 — the ONE deletion decision the outbox orphan cleaner makes: an
    /// attachment directory is reclaimable only when it is BOTH unreferenced by
    /// a committed row AND older than
    /// `SyncConfig.attachmentOrphanReclaimGraceSeconds`.
    ///
    /// WHY A GRACE WINDOW (and not a marker file or a temp name adopted on
    /// commit). `queueSend` stages the attachment directory to disk via
    /// `OutboxMessage.saveAttachments` BEFORE the gated write that commits the
    /// referencing row — deliberately, so that file I/O never runs inside a DB
    /// transaction (Outbox Reliability Rule 6) and a half-written dir can never
    /// be adopted by a committed row. For the whole staging→commit window the
    /// directory is live user data that NO committed row references, so an
    /// "unreferenced ⇒ orphan" sweep DELETES it; `loadAttachments` then fails
    /// closed (Outbox Rule 5) and the send is permanently failed.
    /// - A staging marker file needs its own crash-safe lifecycle (nothing
    ///   removes a marker left by a killed process), i.e. it replaces the orphan
    ///   problem with a second orphan problem one level up.
    /// - A temp name adopted on commit cannot work on the outbox side at all:
    ///   the directory name IS the row id (`attachmentsDirName = self.id`), so
    ///   adoption would be a post-commit RENAME — reopening the identical window
    ///   on the far side of the commit.
    /// - The grace window costs only DELAYED byte reclamation. This cleaner is
    ///   pure byte reclamation, never repair (the DB always has exactly one
    ///   owner), it runs on every `reconcileOutbox`, and a deferred directory is
    ///   reclaimed by the next pass once it ages out. Sweeping inside the window
    ///   costs the user's attachments. That asymmetry decides it.
    ///
    /// SCOPE — this is a BOUNDED MITIGATION, not a proof of the invariant.
    /// Nothing in the source bounds staging-to-commit latency below the grace
    /// interval, so the loss window is narrowed by orders of magnitude, not
    /// closed.
    ///
    /// Age comes from the CREATION date — a staging directory is created
    /// immediately before its gated write, so its creation instant IS the start
    /// of the staging→commit window. An UNDETERMINABLE age is treated as
    /// in-flight and deferred: the cost of deferring is bytes, the cost of
    /// deleting is data.
    ///
    /// `now` is a test seam (age is simulated by advancing `now`, never by
    /// backdating filesystem attributes).
    nonisolated static func reclaimUnreferencedAttachmentDirs(
        baseDir: URL,
        referenced: Set<String>,
        now: Date = Date(),
        graceSeconds: TimeInterval = SyncConfig.attachmentOrphanReclaimGraceSeconds
    ) -> (reclaimed: [String], deferredInFlight: [String]) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return ([], []) }

        var reclaimed: [String] = []
        var deferredInFlight: [String] = []
        for dir in dirs {
            let dirName = dir.lastPathComponent
            guard !referenced.contains(dirName) else { continue }
            let created = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
            guard let created, now.timeIntervalSince(created) >= graceSeconds else {
                deferredInFlight.append(dirName)
                continue
            }
            try? FileManager.default.removeItem(at: dir)
            reclaimed.append(dirName)
        }
        return (reclaimed, deferredInFlight)
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

        let sweep = Self.reclaimUnreferencedAttachmentDirs(baseDir: baseDir, referenced: existingIds)
        for dirName in sweep.reclaimed {
            print("[Outbox] Cleaning orphaned attachment dir: \(dirName)")
        }
        if DebugModeManager.isLoggingEnabled(), !sweep.deferredInFlight.isEmpty {
            print("[Outbox] Deferred \(sweep.deferredInFlight.count) unreferenced attachment dir(s) inside the staging grace window")
        }
    }

    /// Retry a failed outbox message: reset it to `.queued` and clear
    /// `retryCount` so it gets a fresh set of automatic retries. Returns true
    /// only when the reset ACTUALLY landed on exactly one row.
    ///
    /// D1 — the UPDATE is a compare-and-swap on `status = 'failed' AND sentAt IS
    /// NULL`, not a blind write keyed on id alone. Without the predicate the
    /// only gate was the SwiftUI row snapshot in `OutboxView` (`== .failed`),
    /// which `NavigationStore`'s 100 ms refresh debounce leaves visible after a
    /// first Retry already queued the row and the drain claimed it `.sending` —
    /// so a second activation off that stale snapshot reset a LIVE send back to
    /// `.queued`. `sentAt IS NULL` is equally load-bearing: `sentAt` set means
    /// the provider send already succeeded, so the row belongs exclusively to
    /// Sent-append/finalization recovery and must never re-enter the send phase
    /// (it is the double-send firewall marker — same reason
    /// `discardOutboxMessageConfirmed` refuses on it).
    ///
    /// This does NOT narrow the user's intention: a manual Retry of any unsent
    /// `.failed` row is still admitted, which is the whole protected flow. A row
    /// already `.queued`/`.sending` is *already carrying* the requested retry,
    /// so refusing a second activation drops nothing. Automatic retries never
    /// come through here (the send-failure path writes `.queued`/`.failed`
    /// directly, and reconciliation handles `.sending` rows itself).
    ///
    /// Side effects are gated on the committed change, mirroring
    /// `discardOutboxMessageConfirmed`: a refused retry must not signal success
    /// and must not kick a drain.
    @discardableResult
    nonisolated func retryOutboxMessage(_ messageId: String) -> Bool {
        do {
            // Synchronous ON PURPOSE (IOS-PERF-010 Member 4): held synchronous for symmetry with its
            // pair discardOutboxMessageConfirmed — an `await` widens the NavigationStore refresh-debounce
            // window this D1 CAS closes and makes a repeat Retry feel unresponsive. Trip-wire: if this
            // ever writes holdUntil, it moves under Member 5's deadline proof.
            let admitted: Bool = try AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE outboxMessage SET status = ?, errorMessage = NULL, retryCount = 0
                        WHERE id = ? AND status = ? AND sentAt IS NULL
                        """,
                    arguments: [
                        OutboxStatus.queued.rawValue,
                        messageId,
                        OutboxStatus.failed.rawValue,
                    ]
                )
                return db.changesCount == 1
            }
            guard admitted else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Outbox] Cannot retry \(messageId) — absent, not failed, or already sent")
                }
                return false
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
            // Synchronous ON PURPOSE (IOS-PERF-010 Member 5, memory 104): PendingSendService.undo()
            // decides and applies in ONE @MainActor run inside a holdUntil deadline. An `await` here
            // admits a second Undo tap between decision and apply, and can overrun the
            // outboxClaimBufferSeconds window so the drain claims the row `.sending` first — the mail
            // ships while the user is told it was cancelled (IOS-OUTBOX-006, Outbox Rules 3 and 10).
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

    #if DEBUG
    /// Test seam: returns whether atomicClaim admitted the row (non-nil).
    func atomicClaimForTesting(_ msg: OutboxMessage) async -> Bool {
        await atomicClaim(msg) != nil
    }

    /// Exercises the exact post-claim send owner, including its runtime-provider
    /// guard, without an app-launch or scheduler timing harness.
    func sendClaimedOutboxMessageForTesting(
        _ message: OutboxMessage,
        messageId: String
    ) async {
        await sendSingleOutboxMessage(message, messageId: messageId)
    }

    /// Exercises the rollback ownership fence independently of provider state.
    func requeueClaimedOutboxMessageForTesting(_ outboxId: String) async -> Bool {
        await requeueClaimedOutboxMessage(outboxId)
    }
    #endif
}
