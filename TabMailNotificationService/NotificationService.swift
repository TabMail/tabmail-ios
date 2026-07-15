/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UserNotifications
import GRDB
import Synchronization

/// Thread-safe one-shot flag for content handler race prevention.
final class OneShotFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return false }
        fired = true; return true
    }
    /// Non-consuming check: has this flag already fired? Used by the zombie
    /// guard in `process(...)` to detect that the watchdog/timeout already
    /// delivered (and released the AI lease) before a late-resuming task
    /// reaches a persist point — without itself claiming the fire.
    func hasFired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

/// Reference-typed holder for a cancellable Task (the AI lease heartbeat, and
/// the graceful-exit watchdog). Mutex is noncopyable, so a class wrapper is the
/// simplest way to share the slot between `process` (sets it) and the instance's
/// exit handlers (cancel it). `cancelAndClear` is idempotent — both paths can
/// call it.
final class CancellableTaskHolder: @unchecked Sendable {
    private let slot = Mutex<Task<Void, Never>?>(nil)
    func set(_ task: Task<Void, Never>) { slot.withLock { $0 = task } }
    func cancelAndClear() {
        let t = slot.withLock { let was = $0; $0 = nil; return was }
        t?.cancel()
    }
}

/// Reference-typed holder carrying the claimed AI-lease identity from the static
/// `process(...)` back to the instance, so EVERY exit path (natural completion,
/// the graceful-exit watchdog, and `serviceExtensionTimeWillExpire`) can release
/// the lease — "lease all the time". `releaseIfHeld` is idempotent: it reads and
/// clears the slot under the lock, so whichever path runs first does the single
/// conditional release write and the rest are no-ops (no duplicate / edge write).
///
/// Why this matters: without it, an NSE that times out mid-AI leaves a held
/// lease that the main app must wait out (`staleMs` = 4 s) before taking over.
/// Releasing it on the way out hands off instantly. The watchdog (fires
/// `NSEConfig.watchdogSeconds` before the ~30 s hard-kill) is what makes the
/// release SAFE — it happens with margin, not racing suspension (0xdead10cc).
final class LeaseHolder: @unchecked Sendable {
    private let slot = Mutex<(db: DatabaseQueue, accountId: String, messageId: String)?>(nil)
    func claim(db: DatabaseQueue, accountId: String, messageId: String) {
        slot.withLock { $0 = (db, accountId, messageId) }
    }
    /// Release the lease iff still held, then clear the slot. Returns true if a
    /// release was actually performed (for logging). Idempotent across paths.
    @discardableResult
    func releaseIfHeld() -> Bool {
        guard let held = slot.withLock({ let was = $0; $0 = nil; return was }) else { return false }
        AIOwnershipLease.release(db: held.db, accountId: held.accountId, messageId: held.messageId, owner: .nse)
        return true
    }
}

/// Reference-typed holder carrying the BEST-KNOWN partial result from the
/// static `process(...)` back to the instance, so the graceful-exit watchdog
/// and `serviceExtensionTimeWillExpire` can deliver a real summary instead of
/// the bare "New Email" fallback when they fire mid-processing.
///
/// Two writes happen as `process(...)` progresses: `set(...)` right after
/// step 4 (message metadata known — sender/subject only, summary fields nil),
/// then again after step 6a's summary parse (summary/reminder fields filled
/// in; `actionTag` stays nil — the action vote hasn't returned yet). Either
/// snapshot is strictly better than the payload default. `accountId` /
/// provider `messageId` and RFC action identity ride along so the exit paths can call
/// `EmailNotificationBuilder.fill` without threading extra state through the
/// watchdog closure.
final class PartialSignalHolder: @unchecked Sendable {
    private let slot = Mutex<(signal: EmailNotificationBuilder.Signal, accountId: String, messageId: String, rfc822MessageId: String?)?>(nil)
    func set(_ signal: EmailNotificationBuilder.Signal, accountId: String, messageId: String, rfc822MessageId: String?) {
        slot.withLock { $0 = (signal, accountId, messageId, rfc822MessageId) }
    }
    func get() -> (signal: EmailNotificationBuilder.Signal, accountId: String, messageId: String, rfc822MessageId: String?)? {
        slot.withLock { $0 }
    }
}

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private lazy var nseDB: DatabaseQueue? = NSEStagingDB.open()
    private let delivered = OneShotFlag()
    /// Instance-scoped holder for the AI lease heartbeat Task spawned inside
    /// `process(...)`. The exit handlers cancel it so the 1Hz SQLite drumbeat
    /// stops before iOS suspends NSE — without this, a refresh write in flight at
    /// suspension can trip RUNNINGBOARD 0xdead10cc on the extension. Mirrors the
    /// main app's heartbeat lifecycle hygiene.
    private let heartbeatHolder = CancellableTaskHolder()
    /// Graceful-exit watchdog Task (set in `didReceive`). Fires
    /// `NSEConfig.watchdogSeconds` before the ~30 s hard-kill to release the lease
    /// + deliver passive with margin. Natural completion and the iOS expiration
    /// handler cancel it so it never fires after we've already exited.
    private let watchdogHolder = CancellableTaskHolder()
    /// Carries the claimed AI-lease identity so every exit path can release it.
    private let leaseHolder = LeaseHolder()
    /// Carries the best-known partial result (header-only, then +summary) so
    /// the watchdog / `serviceExtensionTimeWillExpire` can deliver a real
    /// summary instead of the bare fallback when they fire mid-processing.
    private let partialHolder = PartialSignalHolder()
    /// Per-run nse.log attribution tag (first 8 chars of the request
    /// identifier), set in `didReceive` and re-bound (`NSELog.$runTag`) around
    /// `serviceExtensionTimeWillExpire`'s body — iOS can run several
    /// NotificationService instances concurrently in one reused NSE process,
    /// and without the tag their interleaved log lines are unattributable.
    /// nil only if `didReceive` bailed on the no-mutable-content early path.
    private var runTag: String?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            NSELog.step("NSE didReceive: no mutable content, passing through")
            contentHandler(request.content)
            return
        }

        // Per-run log attribution (see NSELog.runTag). Derived from the request
        // identifier; the STARTED line below stays untagged — it carries the
        // full id, which is how a [run:<tag>] maps back to its push.
        let runTag = String(request.identifier.prefix(8))
        self.runTag = runTag

        NSELog.step("NSE ━━━ STARTED ━━━ id=\(request.identifier)")

        // Opportunistic delivered-notification cleanup. Detached so it never
        // blocks the 30s NSE budget.
        Task.detached(priority: .utility) {
            await NotificationCleanupService.sweepExpired()
        }

        // Stamp PushHealthStore for non-error pushes — this is what proves
        // the IMAP/Gmail → push-worker → APNs → iOS pipeline works for the
        // account, releasing any stale `imap_reconnect` warning notifications
        // on the next sweep.
        let providerStr = request.content.userInfo["provider"] as? String ?? ""
        let accountEmailStr = request.content.userInfo["accountEmail"] as? String ?? ""
        let nonHealthProviders: Set<String> = ["imap_reconnect", "consent_error"]
        if !nonHealthProviders.contains(providerStr), !accountEmailStr.isEmpty {
            PushHealthStore.recordPush(accountEmail: accountEmailStr)
        }

        // historyId may be a number (JSON integer) — convert to string
        let historyIdRaw = request.content.userInfo["historyId"]
        let historyIdStr: String
        if let s = historyIdRaw as? String { historyIdStr = s }
        else if let n = historyIdRaw as? NSNumber { historyIdStr = n.stringValue }
        else { historyIdStr = "" }

        let info: [String: String] = [
            "provider": request.content.userInfo["provider"] as? String ?? "",
            "accountEmail": request.content.userInfo["accountEmail"] as? String ?? "",
            "historyId": historyIdStr,
            "taskName": request.content.userInfo["taskName"] as? String ?? "",
            "taskInstruction": request.content.userInfo["taskInstruction"] as? String ?? "",
            // Worker classifier now emits one visible push per arrived message
            // with `messageId` in the payload. When present, NSE uses it directly
            // and skips its own Gmail history.list call (saves ~1-3s of the 30s
            // budget + one Gmail API round-trip). Absent → legacy discover-via-
            // history.list path (non-Gmail providers, rollback safety).
            "messageId": request.content.userInfo["messageId"] as? String ?? "",
        ]
        let fanOutIds = request.content.userInfo["messageIds"] as? [String] ?? []
        let db = nseDB
        let deliverGuard = delivered
        let heartbeatHolder = self.heartbeatHolder
        let watchdogHolder = self.watchdogHolder
        let leaseHolder = self.leaseHolder
        let partialHolder = self.partialHolder
        nonisolated(unsafe) let deliver = contentHandler
        nonisolated(unsafe) let c = content
        let t0 = CFAbsoluteTimeGetCurrent()

        // The shared delivery closure — exactly one of {process completion,
        // watchdog, iOS expiration} actually fires it (OneShotFlag), the rest
        // are no-ops. Factored out so the watchdog can deliver too.
        let deliverOnce: @Sendable (UNNotificationContent) -> Void = { notification in
            guard deliverGuard.tryFire() else {
                NSELog.step("NSE deliver: already fired (race)")
                return
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if let n = notification as? UNMutableNotificationContent {
                NSELog.step("NSE ━━━ DELIVERED (\(ms)ms) ━━━ title=\(n.title) level=\(n.interruptionLevel.rawValue) sound=\(n.sound == nil ? "nil" : "SET")")
            } else {
                NSELog.step("NSE ━━━ DELIVERED (\(ms)ms) ━━━ (immutable)")
            }
            deliver(notification)
        }

        Task { @Sendable in
            await NSELog.$runTag.withValue(runTag) {
                await NotificationService.process(
                    c: c, info: info, fanOutIds: fanOutIds, db: db,
                    heartbeatHolder: heartbeatHolder,
                    watchdogHolder: watchdogHolder,
                    leaseHolder: leaseHolder,
                    partialHolder: partialHolder,
                    deliveredFlag: deliverGuard,
                    runStart: t0,
                    deliver: deliverOnce)
            }
        }

        // ── Graceful-exit watchdog ──
        // Fires NSEConfig.watchdogSeconds before iOS's ~30s hard-kill so cleanup
        // happens with margin (NOT racing suspension — see 0xdead10cc rule). On
        // fire: stop the heartbeat, RELEASE the AI lease (so the main app takes
        // over instantly instead of waiting out the 4s stale window), and deliver
        // a passive banner if process() hasn't delivered yet. Natural completion
        // and the iOS expiration handler both cancel this so it never fires late.
        let watchdogSecs = Int(NSEConfig.watchdogSeconds)
        watchdogHolder.set(Task { @Sendable in
            await NSELog.$runTag.withValue(runTag) {
                try? await Task.sleep(nanoseconds: UInt64(NSEConfig.watchdogSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                NSELog.step("NSE ⏱️ WATCHDOG (\(watchdogSecs)s) — graceful exit: release lease + deliver")
                heartbeatHolder.cancelAndClear()
                let released = leaseHolder.releaseIfHeld()
                NSELog.step("NSE watchdog: lease \(released ? "RELEASED" : "(not held)")")
                NotificationService.applyPartialOrBareFallback(c: c, partialHolder: partialHolder, source: "watchdog")
                deliverOnce(c)
            }
        })
    }

    override func serviceExtensionTimeWillExpire() {
        // Synchronous per-run log attribution: bind the stored tag around the
        // whole body so the TIMEOUT/delivery lines attribute to this run.
        // `runTag` is nil only when `didReceive` took the no-mutable-content
        // early path (already delivered, nothing here to attribute) — binding
        // nil is identical to leaving the TaskLocal unbound (untagged lines).
        NSELog.$runTag.withValue(runTag) {
            NSELog.step("NSE ⏰ TIMEOUT")
            // iOS-fired backstop at the suspension edge. In the common case the
            // watchdog (NSEConfig.watchdogSeconds, ~3s earlier) already released the
            // lease + delivered, so the calls below are idempotent no-ops and we do
            // NO write here — keeping us clear of a 0xdead10cc at suspension. Only if
            // iOS gave us a shorter-than-watchdog budget does this do the actual
            // release; a single conditional UPDATE is the lesser evil vs. a held
            // lease (which the main app would otherwise wait out for staleMs=4s).
            watchdogHolder.cancelAndClear()
            heartbeatHolder.cancelAndClear()
            let released = leaseHolder.releaseIfHeld()
            if released { NSELog.step("NSE timeout: lease RELEASED (watchdog hadn't run)") }
            guard let contentHandler, let content = bestAttemptContent else { return }
            guard delivered.tryFire() else { return }
            NotificationService.applyPartialOrBareFallback(c: content, partialHolder: partialHolder, source: "timeout")
            NSELog.step("NSE timeout delivering: title=\(content.title) level=\(content.interruptionLevel.rawValue)")
            contentHandler(content)
        }
    }

    // MARK: - Partial-Result Fallback (watchdog / serviceExtensionTimeWillExpire)

    /// Apply the best-known result to `c` for a graceful-exit delivery: the
    /// `partialHolder`'s snapshot (header, or header+summary) if `process(...)`
    /// got far enough to set one, otherwise today's bare "New Email" fallback.
    /// Either way, forces `.passive`/no sound — the action vote never
    /// returned at this point, so we must never ring or show an active
    /// reply-style banner for a guess. Shared by both exit paths so the
    /// partial-vs-bare branching lives in one place.
    private static func applyPartialOrBareFallback(
        c: UNMutableNotificationContent,
        partialHolder: PartialSignalHolder,
        source: String
    ) {
        if let partial = partialHolder.get() {
            NSELog.step("NSE \(source): delivering PARTIAL (summary=\(partial.signal.summaryBlurb != nil ? "yes" : "no"))")
            EmailNotificationBuilder.fill(
                c, signal: partial.signal,
                accountId: partial.accountId, messageId: partial.messageId,
                rfc822MessageId: partial.rfc822MessageId
            )
            // The action vote is unknown at this point — force passive/no
            // sound regardless of what `fill` decided (it only goes active
            // for actionTag == "reply", which is always nil in a partial
            // signal, but this stays correct even if that rule changes).
            c.interruptionLevel = .passive; c.sound = nil
        } else {
            NSELog.step("NSE \(source): delivering BARE fallback (stuck before step 4)")
            if c.title.isEmpty { c.title = "New Email"; c.body = "You have a new message" }
            applyPassiveSettings(c)
        }
    }

    // MARK: - Main Processing

    private static func process(
        c: UNMutableNotificationContent,
        info: [String: String],
        fanOutIds: [String],
        db: DatabaseQueue?,
        heartbeatHolder: CancellableTaskHolder,
        watchdogHolder: CancellableTaskHolder,
        leaseHolder: LeaseHolder,
        partialHolder: PartialSignalHolder,
        deliveredFlag: OneShotFlag,
        runStart: CFAbsoluteTime,
        deliver: @escaping (UNNotificationContent) -> Void
    ) async {
        let provider = info["provider"] ?? ""
        let accountEmail = info["accountEmail"] ?? ""
        NSELog.step("NSE process: provider=\(provider) email=\(accountEmail) fanOut=\(fanOutIds.count)")

        // Graceful-exit cleanup on EVERY return path. Order matters: cancel the
        // watchdog (we finished before it fired, so it must not deliver a late
        // passive), STOP the heartbeat, THEN release the lease (heartbeat down
        // first so no 1Hz refresh races the release write). All idempotent —
        // no-ops for the task_alarm / imap_reconnect / no-claim paths, and no-ops
        // if the watchdog or the iOS expiration handler already ran. This is the
        // "lease all the time" guarantee: the main app never has to wait out a
        // stale lease after a clean NSE exit. The lease releases AFTER step-7
        // persist (scope exit is past it), so the staged AI results are visible
        // to whoever claims next — a clean handoff, not a half-written row.
        defer {
            watchdogHolder.cancelAndClear()
            heartbeatHolder.cancelAndClear()
            leaseHolder.releaseIfHeld()
        }

        // ── Route by type ──
        if provider == "task_alarm" {
            NSELog.step("NSE route: task_alarm")
            await handleTaskAlarm(c: c, info: info, db: db, deliveredFlag: deliveredFlag)
            // Task result lands in NSE staging DB — main app will merge it on
            // its next natural wake (foreground, BGAppRefresh, BGProcessingTask)
            // via mergeNSEStagingData. The previous follow-up silent push was
            // best-effort (~40% delivery) and is no longer needed.
            deliver(c); return
        }
        if provider == "imap_reconnect" {
            // `final:"true"` is set by the push-worker's retry-ladder cron
            // on the 5th (give-up) tick. The payload already carries the
            // final "Failed to reconnect..." alert — NSE must NOT try to
            // re-subscribe (previous 4 attempts failed; path to recovery
            // is a foreground subscribeAllAccounts() in the main app).
            let isFinal = (info["final"] ?? "") == "true"
            NSELog.step("NSE route: imap_reconnect final=\(isFinal ? "true" : "false")")
            if isFinal {
                deliverPassive(c: c, deliver: deliver); return
            }
            await handleIMAPReconnect(c: c, accountEmail: accountEmail, deliver: deliver)
            return
        }

        // ── Step 1: Account lookup + (OAuth-only) token ──
        guard let accountId = NSEState.findAccountId(for: accountEmail) else {
            NSELog.step("NSE FAIL: no accountId for \(accountEmail)")
            deliverPassive(
                c: c,
                overrideTitle: "Connection to \(accountEmail) lost",
                overrideBody: "Open TabMail to reconnect",
                deliver: deliver
            )
            return
        }
        // IMAP accounts authenticate via app-password in shared Keychain, not
        // OAuth tokens. Skip the access-token gate for imap_new_mail — step 2
        // uses the payload messageId, step 4 opens a one-shot IMAP socket
        // with the Keychain password. The previous all-providers gate fired
        // "no token" and delivered the "Connection lost" passive on every
        // IMAP push, which is what the user was seeing.
        let accessToken: String
        let refreshToken: String?
        if provider == "imap_new_mail" {
            accessToken = ""
            refreshToken = nil
        } else {
            guard let token = SharedKeychain.getAccessToken(for: accountId) else {
                NSELog.step("NSE FAIL: no token for \(accountId)")
                deliverPassive(
                    c: c,
                    overrideTitle: "Connection to \(accountEmail) lost",
                    overrideBody: "Open TabMail to reconnect",
                    deliver: deliver
                )
                return
            }
            accessToken = token
            refreshToken = SharedKeychain.getRefreshToken(for: accountId)
        }
        NSELog.step("NSE step1 OK: accountId=\(String(accountId.prefix(20))) provider=\(provider)")

        // ── Step 2: Resolve message IDs ──
        let payloadMessageId = info["messageId"] ?? ""
        var messageIds: [String]
        if !payloadMessageId.isEmpty {
            // Worker already classified + enumerated. Trust the payload.
            messageIds = [payloadMessageId]
            NSELog.step("NSE step2: payload messageId=\(payloadMessageId) — skipping history.list")
        } else if !fanOutIds.isEmpty {
            messageIds = fanOutIds
            NSELog.step("NSE step2: fan-out \(fanOutIds.count) IDs")
        } else {
            let historyId = info["historyId"]
            let lastHid = NSEState.getLastHistoryId(for: accountId)
            NSELog.step("NSE step2: historyId=\(historyId ?? "NIL") lastHid=\(lastHid ?? "NIL")")

            switch provider {
            case "gmail":
                let historyResult = await GmailNSEClient.fetchNewMessageIds(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    historyId: historyId?.isEmpty == true ? nil : historyId,
                    accountId: accountId
                )
                // Zombie guard — same rationale as the step-4/5/6/7 checks: a
                // history.list fetch can outlive the watchdog (HTTPClient allows
                // up to 300s + retries), and everything below is a write —
                // setLastHistoryId, persistInboxRemovals, and ESPECIALLY the
                // badge adjustment, which is raw UserDefaults arithmetic (unlike
                // the per-message-deduped badgeForDelivery): a zombie re-running
                // it double-counts. NSE-target-only, so (like the other six
                // checkpoints) this is exercised in the field, not unit tests.
                if deliveredFlag.hasFired() {
                    NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
                    return
                }
                messageIds = historyResult.addedMessageIds

                // Advance historyId to prevent re-processing same events
                if let latestHid = historyResult.latestHistoryId {
                    NSEState.setLastHistoryId(latestHid, for: accountId)
                    NSELog.step("NSE step2: advanced historyId to \(latestHid)")
                }

                // Persist inbox removals for main app to merge on wake
                if !historyResult.removedMessageIds.isEmpty, let db {
                    NSEStagingDB.persistInboxRemovals(db: db, accountId: accountId, messageIds: historyResult.removedMessageIds)
                    NSELog.step("NSE step2: persisted \(historyResult.removedMessageIds.count) inbox removal(s)")
                }

                // Adjust badge for all unread changes discovered in history
                let badgeDecrement = historyResult.unreadRemovedCount + historyResult.markedReadCount
                let badgeIncrement = historyResult.markedUnreadCount
                if badgeDecrement > 0 { _ = NSEState.decrementBadgeCount(by: badgeDecrement) }
                if badgeIncrement > 0 { for _ in 0..<badgeIncrement { _ = NSEState.incrementBadgeCount() } }
                if badgeDecrement > 0 || badgeIncrement > 0 {
                    NSELog.step("NSE step2: badge adjust: -\(badgeDecrement) (removed=\(historyResult.unreadRemovedCount) read=\(historyResult.markedReadCount)) +\(badgeIncrement) (unread=\(historyResult.markedUnreadCount))")
                }
            case "imap_new_mail":
                guard NSEState.isIMAPPushEnabled() else {
                    NSELog.step("NSE step2: IMAP disabled")
                    deliverPassive(c: c, deliver: deliver); return
                }
                // IMAP pushes from the droplet always include the RFC 5322
                // Message-ID in the payload. Without it the NSE
                // has no way to locate the new message — fall through to a
                // passive notification.
                let imapMsgId = info["messageId"] ?? ""
                guard !imapMsgId.isEmpty else {
                    NSELog.step("NSE step2: imap_new_mail push missing messageId")
                    deliverPassive(c: c, deliver: deliver); return
                }
                messageIds = [imapMsgId]
            default:
                messageIds = []
            }
            NSELog.step("NSE step2: got \(messageIds.count) message(s)")
        }

        guard !messageIds.isEmpty else {
            NSELog.step("NSE step2: EMPTY — no new messages (removal-only or no change)")
            // Main-app sync picks up the inbox state on its next natural wake.
            deliverPassive(c: c, deliver: deliver); return
        }

        // ── Step 3: Pick the message to process ──
        // Every push from the worker carries its own messageId, so
        // messageIds.count == 1 in practice. The legacy-payload fallback path
        // (history.list discovery) may yield more than one — in that case we
        // process only the head; remaining IDs are picked up by the main app's
        // next sync. (Previously, NSE used to recursively fan-out the tail via
        // /fan-out + a chained NSE; that machinery was removed.)
        let headId = messageIds[0]
        if messageIds.count > 1 {
            NSELog.step("NSE step3: HEAD=\(headId) TAIL=\(messageIds.count - 1) (legacy payload — tail handled by main-app sync)")
        } else {
            NSELog.step("NSE step3: HEAD=\(headId)")
        }

        // ── Step 4: Fetch message ──
        NSELog.step("NSE step4: fetching message \(headId)")
        let msg: NSEMessageMetadata?
        // For IMAP, step 4 + step 5 share a single TCP round-trip: we
        // fetch metadata + full body from one logged-in connection and
        // reuse the `RenderedBody` below. Gmail / Outlook keep the
        // two-call shape since those APIs return metadata and body
        // via separate REST endpoints anyway.
        var imapPreFetchedBody: RenderedBody? = nil
        switch provider {
        case "gmail":
            msg = await GmailNSEClient.fetchSingleMessage(messageId: headId, accessToken: accessToken, refreshToken: refreshToken, accountId: accountId)
        case "outlook":
            msg = await OutlookNSEClient.fetchSingleMessage(messageId: headId, accessToken: accessToken, refreshToken: refreshToken, accountId: accountId)
        case "imap_new_mail":
            msg = await fetchIMAPMessage(
                accountId: accountId, rfc822MessageId: headId,
                imapBody: &imapPreFetchedBody
            )
        default: msg = nil
        }
        guard let msg else {
            NSELog.step("NSE step4: FAIL — message fetch failed")
            deliverPassive(c: c, deliver: deliver); return
        }
        NSELog.step("NSE step4 OK: from=\(String(msg.senderName.prefix(60))) subj=\(String(msg.subject.prefix(40)))")

        // Zombie guard — same rationale as the step6a/6b/pre-step-7 checks: a
        // step-4 fetch that outlived the watchdog resumes here AFTER the exit
        // path delivered and RELEASED the AI lease; the main app may own this
        // message now, and the stageHeader INSERT below (and the partialHolder
        // publish feeding a next-run exit path) would be stale work.
        if deliveredFlag.hasFired() {
            NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
            return
        }

        // Publish the header-only partial NOW — the watchdog / iOS expiration
        // handler can deliver this (sender + subject, no summary yet) instead
        // of the bare "New Email" fallback if they fire before step 6a.
        partialHolder.set(
            EmailNotificationBuilder.Signal(senderName: msg.senderName, senderEmail: msg.senderEmail, subject: msg.subject),
            accountId: accountId, messageId: msg.messageId,
            rfc822MessageId: msg.rfc822MessageId
        )

        // ── GRADUAL STAGING stage 1: header ──
        // Write the header + populated=1 NOW so the main app's merge can SHOW the
        // message before body fetch and AI complete. Body / summary / action are
        // staged incrementally below as each finishes (no longer one big write at
        // the end). The merge keeps the row until AI completes.
        if let db {
            NSEStagingDB.stageHeader(
                db: db, accountId: accountId, accountEmail: accountEmail,
                provider: provider, message: msg, historyId: info["historyId"])
            NSELog.step("NSE stage1: header staged (populated)")
        }

        // ── Step 5: Body (full render via shared BodyRenderer) ──
        NSELog.step("NSE step5: fetching body")
        let rendered: RenderedBody?
        switch provider {
        case "gmail":
            rendered = await GmailNSEClient.fetchRenderedBody(
                messageId: msg.messageId, folderPath: msg.folderPath,
                accessToken: accessToken,
                refreshToken: refreshToken, accountId: accountId
            )
        case "outlook":
            rendered = await OutlookNSEClient.fetchRenderedBody(
                messageId: msg.messageId, folderPath: msg.folderPath,
                accessToken: accessToken,
                refreshToken: refreshToken, accountId: accountId
            )
        case "imap_new_mail":
            // Body was fetched alongside metadata in step 4 — reuse it,
            // no second IMAP connection. If the combined fetch failed
            // the `msg` guard above already returned.
            rendered = imapPreFetchedBody
        default: rendered = nil
        }
        let body = rendered?.textContent
        NSELog.step("NSE step5: body=\(body?.count ?? 0) chars cidsUnresolved=\((rendered?.hasUnresolvedCIDs ?? false) ? "YES" : "NO")")

        // Zombie guard — same rationale as the step-4 check above: a body
        // fetch that outlived the watchdog must not run the stageBody UPDATE
        // (or anything after it) once the exit path delivered + released.
        if deliveredFlag.hasFired() {
            NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
            return
        }

        // ── GRADUAL STAGING stage 2: body ──
        // Attach the rendered body to the already-staged header so the merge can
        // write MessageBody + FTS (and the main app's body queue won't re-fetch).
        if let db {
            NSEStagingDB.stageBody(db: db, accountId: accountId, messageId: msg.messageId, renderedBody: rendered)
            NSELog.step("NSE stage2: body staged")
        }

        // ── Step 5.5: AI cache probe — check peers + staging DB before running AI ──
        // Cross-device probe (respects Device Sync user setting)
        // Peer probe key must use the provider-canonical folderPath — NOT a
        // hardcoded "INBOX". For Gmail the two agree; for Outlook/Graph the
        // folder is the opaque `parentFolderId` and main-app peers store the
        // AI cache under that.
        if let rfc = msg.rfc822MessageId,
           let peerHit = await NSEAICacheProbe.probe(accountId: accountId, folderId: msg.folderPath, rfc822MessageId: rfc) {
            // Zombie guard — the probe is a real network await (raw URLSession,
            // idle-timer timeout, deliberately NOT deadline-wrapped: it's one
            // small plain-JSON round-trip, not SSE, and the watchdog +
            // partialHolder already own delivery). This checkpoint neutralizes
            // the branch's WRITE hazard instead: a zombie-resumed reply-hit
            // would run persistProcessedMessage(..., notified: active) with
            // notified=1, the merge applies it PERMANENTLY (CASE WHEN ? THEN 1
            // ELSE notified END — never resets), and the main app's
            // postReplyNotificationIfNeeded then never fires the reply ping for
            // that message even though the classification was correct.
            if deliveredFlag.hasFired() {
                NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
                return
            }
            NSELog.step("NSE step5.5: PEER cache HIT — skipping AI calls")
            let active = EmailNotificationBuilder.fill(
                c,
                signal: EmailNotificationBuilder.Signal(
                    senderName: msg.senderName,
                    senderEmail: msg.senderEmail,
                    subject: msg.subject,
                    summaryBlurb: peerHit.summaryBlurb,
                    actionTag: peerHit.actionTag
                ),
                accountId: accountId, messageId: msg.messageId,
                rfc822MessageId: msg.rfc822MessageId
            )
            c.badge = NSNumber(value: NSEBadge.badgeForDelivery(
                db: db, suite: SharedNSEData.suite.defaults,
                accountId: accountId, messageId: msg.messageId,
                rfc822MessageId: msg.rfc822MessageId))
            // Persist peer results + rendered body to staging DB for main app merge.
            // Body is persisted even on peer cache hit so merge writes MessageBody + FTS
            // and the main app's body queue doesn't re-fetch.
            if let db {
                NSEStagingDB.persistProcessedMessage(
                    db: db, accountId: accountId, accountEmail: accountEmail, provider: provider,
                    message: msg, renderedBody: rendered,
                    summaryBlurb: peerHit.summaryBlurb, summaryTodos: peerHit.summaryTodos,
                    actionTag: peerHit.actionTag, reminderDate: nil, reminderTime: nil, reminderContent: nil,
                    historyId: info["historyId"], aiCompleted: peerHit.summaryBlurb != nil && peerHit.actionTag != nil,
                    notified: active)
            }
            // NSE is terminal. Main-app post-notification work runs
            // on next natural wake via mergeNSEStagingData. No follow-up push.
            deliver(c); return
        }
        // Local staging DB check (handles NSE-to-NSE dedup)
        if let db, let cached = NSEStagingDB.getCachedResult(db: db, accountId: accountId, messageId: msg.messageId) {
            NSELog.step("NSE step5.5: STAGING cache HIT — skipping AI calls")
            // Unified layout — builder picks active (.reply + sound) when the
            // cached row carries a reply tag; otherwise passive with summary (or
            // empty body when AI was never completed for this cached entry).
            EmailNotificationBuilder.fill(
                c,
                signal: EmailNotificationBuilder.Signal(
                    senderName: msg.senderName,
                    senderEmail: msg.senderEmail,
                    subject: msg.subject,
                    summaryBlurb: cached.summaryBlurb,
                    actionTag: cached.actionTag,
                    reminderContent: cached.reminderContent,
                    dueDate: cached.reminderDate,
                    dueTime: cached.reminderTime
                ),
                accountId: accountId, messageId: msg.messageId,
                rfc822MessageId: msg.rfc822MessageId
            )
            // Idempotent: a staging-cache hit means a previous NSE run already
            // counted this message, so this returns the current value unbumped.
            c.badge = NSNumber(value: NSEBadge.badgeForDelivery(
                db: db, suite: SharedNSEData.suite.defaults,
                accountId: accountId, messageId: msg.messageId,
                rfc822MessageId: msg.rfc822MessageId))
            // NSE is terminal. Main-app post-notification work runs
            // on next natural wake via mergeNSEStagingData. No follow-up push.
            deliver(c); return
        }

        // ── Step 6: AI ──
        let authToken = await NSETokenManager.validAccessToken()
        var summaryBlurb: String?, summaryTodos: String?, actionTag: String?
        var reminderDate: String?, reminderTime: String?, reminderContent: String?

        // Gate 1 — Privacy opt-out. Flag lives in the App Group suite so this
        // process can see it. When set, NSE posts a plain (non-AI) banner and
        // leaves the staging row without summary/action; main app's pipeline
        // (also gated) will not re-run. Matches AIService.disableLLMCalls.
        let aiDisabled = NSEState.isAIDisabled()
        // Gate 2 — AI ownership lease. If the main app already holds a fresh
        // lease on this message, skip the duplicate LLM call (main app is the
        // more reliable actor and will write results to staging we'll merge).
        // If no owner or the holder is stale, we try to claim; on success we
        // refresh the heartbeat every aiHeartbeatIntervalMs while AI runs.
        //
        // Zombie guard — same rationale as the step-4/5 checks above, placed
        // BEFORE the lease-state read: once the exit path delivered + released,
        // this run must not re-CLAIM the lease (tryClaim would steal it back
        // from a main app that may have just taken over) or restart the
        // heartbeat it would then hold until scope exit.
        if deliveredFlag.hasFired() {
            NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
            return
        }
        var didClaimAI = false
        if !aiDisabled, let db, let body, !body.isEmpty {
            if let existing = AIOwnershipLease.state(db: db, accountId: accountId, messageId: msg.messageId),
               existing.owner == .mainApp,
               AIOwnershipLease.isFresh(heartbeatMs: existing.heartbeatMs) {
                NSELog.step("NSE step6: SKIP — main app holds fresh AI claim")
            } else if AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: msg.messageId, owner: .nse) {
                didClaimAI = true
                NSELog.step("NSE step6: claimed AI ownership")
                // Register the claimed identity so EVERY exit path (natural defer,
                // watchdog, iOS expiration) can release this lease — "lease all
                // the time", so the main app never waits out a stale lease.
                leaseHolder.claim(db: db, accountId: accountId, messageId: msg.messageId)
                // Register the heartbeat so the exit handlers can stop the 1Hz
                // SQLite drumbeat before iOS suspends NSE.
                heartbeatHolder.set(Task { @Sendable [db, accountId, mid = msg.messageId] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: AIOwnershipLease.heartbeatIntervalMs * 1_000_000)
                        if Task.isCancelled { break }
                        AIOwnershipLease.refresh(db: db, accountId: accountId, messageId: mid, owner: .nse)
                    }
                })
            } else {
                NSELog.step("NSE step6: SKIP — could not claim AI (contested by fresh owner)")
            }
        }

        if !aiDisabled, didClaimAI, let body, !body.isEmpty {
            // Build shared DTOs so prompt variable assembly uses the same code path
            // as the main app (PromptVariables — single source of truth for AI parity).
            let sharedMetadata = MessageMetadata(
                providerMessageId: msg.messageId,
                threadId: msg.threadId,
                rfc822MessageId: msg.rfc822MessageId,
                inReplyTo: nil, references: [],
                from: EmailAddress(name: msg.senderName, email: msg.senderEmail),
                to: [], cc: [], bcc: [], replyTo: nil,
                subject: msg.subject,
                date: msg.date ?? Date(),
                snippet: msg.snippet,
                isRead: false, isFlagged: false, hasAttachments: false,
                providerLabels: [],
                // Already-captured in `msg` — carry it through so prompt
                // variables stay provider-agnostic.
                folderPath: msg.folderPath
            )
            let sharedBody = RenderedBody(
                htmlContent: body, textContent: body,
                attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
            )
            let account = AccountContext(
                userName: NSEState.getUserName() ?? "User",
                kbText: NSEState.getKBText() ?? "",
                actionPrompt: NSEState.getActionPrompt() ?? ""
            )

            // "cc" needs positive evidence: the RECEIVING account's address (push
            // payload email) in the Cc header (claim set). All mirrored account
            // addresses feed the suppress set only — a cross-account To/From hit
            // prevents a claim, never makes one.
            let recipientStatus = PromptVariables.classifyRecipientStatus(
                toField: msg.to, ccField: msg.cc, fromField: msg.senderEmail,
                claimEmails: [accountEmail], suppressEmails: NSEState.getAllAccountEmails()
            )
            let summaryVars = PromptVariables.summaryVariables(
                metadata: sharedMetadata, body: sharedBody, account: account,
                recipientStatus: recipientStatus
            )

            // Budget each LLM call from the run's REMAINING time (against the
            // watchdog deadline), not the raw nominal timeout — see
            // NSEProviderSupport.llmCallBudget. Makes the watchdog a true
            // backstop: a healthy-but-slow run gives up on its own with
            // llmFinishMarginSeconds left for step 7/8.
            //
            // The summary RETRIES within that budget: each iteration recomputes
            // the remaining budget fresh; a failed attempt (wall-clock deadline
            // or nil response) loops with the smaller recomputed budget. Two
            // terminators: llmCallBudget returning nil (a DEADLINE attempt
            // consumed its budget), and summaryMaxAttempts (a FAST-failing
            // attempt — offline, connection refused — returns in ms and would
            // otherwise spin the loop for the whole ~24.5s window). Field
            // trigger (2026-07-09): a 12s single-shot summary deadlined, and
            // the action then classified "reply" with NO summary context.
            // Futile-loop guard: sendCompletions returns nil INSTANTLY when the
            // auth token is nil (its first guard) — retrying that would
            // tight-spin until the budget runs out. One check, once, up front;
            // the loop condition below skips entirely. (Behavior parity with
            // the pre-loop code: a nil token always produced a nil summary.)
            if authToken == nil {
                NSELog.step("NSE step6a: SKIP — no auth token")
            }
            var summaryAttempt = 0
            while authToken != nil, summaryAttempt < NSEConfig.summaryMaxAttempts {
                guard let summaryBudget = NSEProviderSupport.llmCallBudget(
                    nominal: NSEConfig.summaryTimeoutSeconds,
                    elapsed: CFAbsoluteTimeGetCurrent() - runStart,
                    watchdog: NSEConfig.watchdogSeconds,
                    finishMargin: NSEConfig.llmFinishMarginSeconds,
                    minCall: NSEConfig.llmMinCallSeconds
                ) else {
                    NSELog.step("NSE step6a: SKIP — no time budget left (elapsed=\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - runStart))s)")
                    break
                }
                summaryAttempt += 1
                NSELog.step("NSE step6a: calling summary (attempt \(summaryAttempt), recipient_status=\(recipientStatus.isEmpty ? "omitted" : recipientStatus), budget=\(String(format: "%.1f", summaryBudget))s)")
                let resp = await BackendNSEClient.sendCompletions(
                    promptAlias: "system_prompt_summary",
                    variables: BackendNSEClient.Vars(summaryVars),
                    authToken: authToken, timeout: summaryBudget
                )
                // Zombie guard: the watchdog (or serviceExtensionTimeWillExpire)
                // may have already delivered — and RELEASED the AI lease — while
                // this call was in flight. If so, the main app may own this
                // message now; a late stageSummary UPDATE would clobber its row.
                // Never false-positives on the natural path: deliverOnce only
                // fires after step 8, past every one of these checks. Checked
                // INSIDE the loop, before any staging write.
                if deliveredFlag.hasFired() {
                    NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
                    return
                }
                guard let resp else {
                    NSELog.step("NSE step6a FAIL: summary call failed (attempt \(summaryAttempt)) — retrying with remaining budget")
                    continue
                }
                let parsed = NSEResponseParser.parseSummary(resp.assistant)
                summaryBlurb = parsed.blurb; summaryTodos = parsed.todos
                reminderDate = parsed.reminderDate; reminderTime = parsed.reminderTime
                reminderContent = parsed.reminderContent
                NSELog.step("NSE step6a OK: blurb=\(String((summaryBlurb ?? "nil").prefix(60)))")
                // ── GRADUAL STAGING stage 3a: summary ──
                // Surface the summary before the action vote returns, so a merge
                // landing mid-vote shows it. aiCompleted stays 0 until step 7.
                if let db {
                    NSEStagingDB.stageSummary(
                        db: db, accountId: accountId, messageId: msg.messageId,
                        summaryBlurb: summaryBlurb, summaryTodos: summaryTodos,
                        reminderDate: reminderDate, reminderTime: reminderTime,
                        reminderContent: reminderContent)
                }
                // Upgrade the partial to header+summary — actionTag stays nil,
                // the vote hasn't returned yet. A watchdog/timeout firing from
                // here on delivers the real summary instead of a bare banner.
                partialHolder.set(
                    EmailNotificationBuilder.Signal(
                        senderName: msg.senderName, senderEmail: msg.senderEmail, subject: msg.subject,
                        summaryBlurb: summaryBlurb, reminderContent: reminderContent,
                        dueDate: reminderDate, dueTime: reminderTime
                    ),
                    accountId: accountId, messageId: msg.messageId,
                    rfc822MessageId: msg.rfc822MessageId
                )
                break
            }

            // Parity gate: the action vote REQUIRES summary context, matching
            // the main app's ActiveAIQueue.executeActionJob guard ("Action
            // skipped (no summary yet)"). Field evidence (2026-07-09): a
            // deadline-abandoned summary followed by a summary-less action call
            // produced a spurious "reply" classification.
            if summaryBlurb?.isEmpty == false {
                let actionBudget = NSEProviderSupport.llmCallBudget(
                    nominal: NSEConfig.actionTimeoutSeconds,
                    elapsed: CFAbsoluteTimeGetCurrent() - runStart,
                    watchdog: NSEConfig.watchdogSeconds,
                    finishMargin: NSEConfig.llmFinishMarginSeconds,
                    minCall: NSEConfig.llmMinCallSeconds
                )
                if let actionBudget {
                    NSELog.step("NSE step6b: calling action (budget=\(String(format: "%.1f", actionBudget))s)")
                    let summaryCtx = SummaryContext(blurb: summaryBlurb, todos: summaryTodos)
                    let actionVars = PromptVariables.actionVariables(
                        metadata: sharedMetadata, body: sharedBody,
                        summary: summaryCtx, account: account
                    )
                    actionTag = await BackendNSEClient.sendActionVote(
                        promptAlias: "system_prompt_action",
                        variables: BackendNSEClient.Vars(actionVars),
                        authToken: authToken, timeout: actionBudget
                    )
                    // Zombie guard — same rationale as the step6a check above.
                    if deliveredFlag.hasFired() {
                        NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
                        return
                    }
                    NSELog.step("NSE step6b: action=\(actionTag ?? "nil")")
                } else {
                    NSELog.step("NSE step6b: SKIP — no time budget left (elapsed=\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - runStart))s)")
                }
            } else {
                NSELog.step("NSE step6b: SKIP — no summary (action requires summary context; main-app AI will complete on next wake)")
            }
        } else if aiDisabled {
            NSELog.step("NSE step6: SKIP — AI disabled (privacy opt-out)")
        } else if body == nil || body?.isEmpty == true {
            NSELog.step("NSE step6: SKIP (no body)")
        }

        // AI ownership release + heartbeat stop now happen in the top-of-function
        // `defer` (runs at scope exit, AFTER step-7 persist below) so the staged
        // results are visible before the lease frees. Conditional release
        // (WHERE aiOwner = "nse") means a stale takeover elsewhere isn't clobbered.

        // ── Step 7: Persist ──
        // `notified` records whether the NSE delivered an ACTIVE (reply-tagged)
        // notification. Main app's `postReplyNotificationIfNeeded` skips when
        // this is true, preventing double banners. Passive deliveries leave
        // notified=false so the main app can upgrade if a later AI pass
        // re-classifies the message as a reply.
        let aiDone = summaryBlurb != nil && actionTag != nil
        let signal = EmailNotificationBuilder.Signal(
            senderName: msg.senderName,
            senderEmail: msg.senderEmail,
            subject: msg.subject,
            summaryBlurb: summaryBlurb,
            actionTag: actionTag,
            reminderContent: reminderContent,
            dueDate: reminderDate,
            dueTime: reminderTime
        )
        let active = EmailNotificationBuilder.isImportant(signal)
        // Zombie guard — same rationale as the step6a/step6b checks above:
        // catches the backstop case where AI was skipped entirely (aiDisabled,
        // no claim, no body) but steps 1-5 alone ran long enough for the
        // watchdog to already have delivered + released the lease.
        if deliveredFlag.hasFired() {
            NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
            return
        }
        if let db {
            NSEStagingDB.persistProcessedMessage(
                db: db, accountId: accountId, accountEmail: accountEmail, provider: provider,
                message: msg, renderedBody: rendered,
                summaryBlurb: summaryBlurb, summaryTodos: summaryTodos,
                actionTag: actionTag, reminderDate: reminderDate, reminderTime: reminderTime,
                reminderContent: reminderContent, historyId: info["historyId"],
                aiCompleted: aiDone, notified: active
            )
            NSELog.step("NSE step7: persisted ai=\(aiDone ? 1 : 0) notified=\(active ? 1 : 0)")
        }

        // ── Step 8: Build notification ──
        // Unified layout: title = "New email - <sender>", subtitle = subject,
        // body = reminder-with-due-label | summary | "" (AI-failed). Active +
        // default sound only when reply-tagged; passive otherwise.
        // Per-message idempotent (a duplicate push re-running the full path
        // doesn't re-bump) and skipped when the main app holds a fresh AI
        // lease (it sets the badge authoritatively from its own recount) —
        // see NSEBadge.badgeForDelivery.
        let newBadge = NSEBadge.badgeForDelivery(
            db: db, suite: SharedNSEData.suite.defaults,
            accountId: accountId, messageId: msg.messageId,
            rfc822MessageId: msg.rfc822MessageId)
        EmailNotificationBuilder.fill(
            c, signal: signal,
            accountId: accountId, messageId: msg.messageId,
            rfc822MessageId: msg.rfc822MessageId
        )
        NSELog.step("NSE step8: \(active ? "ACTIVE (reply)" : "PASSIVE"), badge=\(newBadge)")
        c.badge = NSNumber(value: newBadge)

        // NSE is terminal. Heavy post-notification work (reply
        // precompute, FTS, embeddings, IMAP tag writes, badge correction,
        // Device Sync broadcast) runs on the next natural main-app wake via
        // mergeNSEStagingData. The previous follow-up silent push to /nse-done
        // was best-effort (~40% delivery) and added a flaky failure mode.
        deliver(c)
    }

    // MARK: - Task Alarm

    private static func handleTaskAlarm(
        c: UNMutableNotificationContent,
        info: [String: String],
        db: DatabaseQueue?,
        deliveredFlag: OneShotFlag
    ) async {
        let taskName = info["taskName"] ?? "Scheduled Task"
        let rawInstruction = info["taskInstruction"]
        guard let instruction = (rawInstruction?.isEmpty == true ? nil : rawInstruction)
                ?? NSEState.findTaskInstruction(for: taskName), !instruction.isEmpty else {
            c.title = taskName; c.body = "Open app to run this task"
            c.interruptionLevel = .active; c.sound = .default; return
        }
        let now = Date()
        let timeStr = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        let dateStr = DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none)
        let userMessage = "It is now \(timeStr), \(dateStr). I previously scheduled this task: \"\(instruction)\" Execute and respond."

        let resp = await BackendNSEClient.sendCompletions(
            promptAlias: "system_prompt_chat",
            variables: BackendNSEClient.Vars([
                "user_name": NSEState.getUserName() ?? "User",
                "kb": NSEState.getKBText() ?? "",
                "user_message": userMessage,
            ]),
            authToken: await NSETokenManager.validAccessToken(), timeout: NSEConfig.taskTimeoutSeconds
        )
        // Zombie guard — same rationale as process()'s checkpoints: the
        // completions call is deadline-bounded, but the process can still be
        // suspended mid-await and zombie-resumed after the watchdog delivered.
        // Guard BEFORE mutating `c` and before the persistTaskResult write —
        // a stale INSERT would hand the main app a task result from a run the
        // exit path already concluded. Returning without touching `c` is safe:
        // the caller's deliver(c) no-ops on the fired OneShotFlag.
        if deliveredFlag.hasFired() {
            NSELog.step("NSE zombie: exit path already delivered — abandoning without persist")
            return
        }
        if let resp {
            c.title = taskName; c.body = String(resp.assistant.prefix(4096))
            c.interruptionLevel = .active; c.sound = .default
            if let db { NSEStagingDB.persistTaskResult(db: db, taskName: taskName, taskInstruction: instruction, result: resp.assistant) }
        } else {
            c.title = taskName; c.body = "Could not complete. Open app to retry."
            c.interruptionLevel = .active; c.sound = .default
        }
    }

    // MARK: - IMAP Reconnect
    //
    // Triggered by the push-worker's visible-passive `imap_reconnect` push
    // (fired on droplet IDLE drop, retire fanout, or retry-ladder tick).
    // The push-worker owns retry state authoritatively — NSE is dumb:
    //
    //   • Default alert in the APNs payload is ALREADY the neutral
    //     "Reconnecting push connections for <email>" message. If NSE
    //     can't confirm success (timeout, non-2xx, no-accountId, etc.)
    //     it leaves the payload default untouched — we don't claim
    //     success or final-failure on our own.
    //   • On a confirmed 2xx from /subscribe-imap: mutate the alert to
    //     "Restored push notification connection for <email>". The
    //     push-worker also sees the success (via KV) and clears retry
    //     state, so no further ladder tick fires.
    //   • Final give-up copy ("Failed to reconnect..., open TabMail to
    //     retry") is sent by the push-worker AFTER the retry ladder
    //     exhausts — NSE doesn't attempt re-subscribe then; it just
    //     passes the payload default through.

    private static func handleIMAPReconnect(
        c: UNMutableNotificationContent,
        accountEmail: String,
        deliver: @escaping (UNNotificationContent) -> Void
    ) async {
        guard !accountEmail.isEmpty,
              let accountId = NSEState.findAccountId(for: accountEmail) else {
            // No accountId = account deleted or renamed on this device.
            // Leave the payload default ("Reconnecting...") — the push-
            // worker's retry ladder will eventually give up, and the
            // final give-up push carries the "Failed..." copy.
            NSELog.step("NSE imap_reconnect: no accountId for \(accountEmail)")
            deliverPassive(c: c, deliver: deliver)
            return
        }

        let success = await attemptSilentResubscribe(
            accountId: accountId, accountEmail: accountEmail
        )

        if success {
            let email = accountEmail.isEmpty ? "your account" : accountEmail
            NSELog.step("NSE imap_reconnect: silent re-subscribe OK")
            // Stamp PushHealthStore so any sibling imap_reconnect failure
            // notifications for this account get released by the next sweep.
            // Weaker proof than receiving a real push (the IDLE socket may
            // still drop after a 2xx /subscribe-imap), but the push-worker's
            // retry ladder is the safety net — if the socket dies again,
            // another imap_reconnect push will arrive.
            if !accountEmail.isEmpty {
                PushHealthStore.recordPush(accountEmail: accountEmail)
            }
            // Distinguish the success-ack from failure variants so the
            // notification cleanup sweep can age it out at TTL like a
            // normal active.
            var info = c.userInfo
            info["reconnect_state"] = "ok"
            c.userInfo = info
            deliverPassive(
                c: c,
                overrideTitle: "TabMail",
                overrideBody: "Restored push notification connection for \(email)",
                deliver: deliver
            )
            return
        }

        // Failure (timeout / non-2xx / network error). Leave the APNs
        // payload default untouched — push-worker retry ladder takes
        // it from here. Next ladder tick fires another reconnect push
        // after 5/10/30/60 min; we don't spam iOS in the meantime.
        NSELog.step("NSE imap_reconnect: silent re-subscribe FAILED — leaving payload default")
        deliverPassive(c: c, deliver: deliver)
    }

    /// Encrypt the account's IMAP creds with the shared
    /// `IMAP_CRED_ENCRYPTION_KEY` and POST to the push-worker's
    /// `/subscribe-imap`. Returns true on 2xx.
    private static func attemptSilentResubscribe(
        accountId: String, accountEmail: String
    ) async -> Bool {
        guard let imap = NSEState.getIMAPAccount(for: accountId) else {
            NSELog.step("NSE resubscribe: no shared IMAP config")
            return false
        }
        guard let password = SharedKeychain.getPassword(for: accountId),
              !password.isEmpty else {
            NSELog.step("NSE resubscribe: no password in shared Keychain")
            return false
        }
        guard let userId = NSETokenManager.supabaseUserId() else {
            NSELog.step("NSE resubscribe: no supabase userId")
            return false
        }
        guard let token = await NSETokenManager.validAccessToken() else {
            NSELog.step("NSE resubscribe: no valid JWT")
            return false
        }

        let payload = IMAPCredPayload(
            host: imap.host,
            port: imap.port,
            username: imap.username,
            password: password,
            security: (imap.useTLS == false) ? "starttls" : nil
        )
        let ciphertext: String
        do {
            ciphertext = try IMAPCredCrypto.encrypt(payload)
        } catch {
            NSELog.step("NSE resubscribe: encrypt failed: \(String(describing: error))")
            return false
        }

        let urlString = NSEState.getPushWorkerURL() + "/subscribe-imap"
        guard let url = URL(string: urlString) else {
            NSELog.step("NSE resubscribe: bad push worker URL")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "userEmail": accountEmail,
            "credsCiphertext": ciphertext,
        ])
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                // Log the status + a body snippet so we can tell the failure
                // mode apart: push-worker 401/403 (JWT invalid), 502 (droplet
                // unreachable), 503 (no droplet / capacity), etc. Body is
                // truncated to 200 bytes — it's opaque JSON from the worker,
                // never contains credentials.
                let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                NSELog.step("NSE resubscribe: HTTP \(code) body=\(bodyPreview)")
                return false
            }
            return true
        } catch {
            NSELog.step("NSE resubscribe: HTTP failed: \(String(describing: error))")
            return false
        }
    }

    // MARK: - IMAP Message Fetch

    /// Open a one-shot IMAP connection, fetch the pushed message's metadata
    /// and body together, and return them in a single call. Populates
    /// `imapBody` so step 5 can reuse the body without a second connection.
    /// Returns nil on any failure (missing shared IMAP config, bad creds,
    /// SEARCH empty, FETCH empty).
    private static func fetchIMAPMessage(
        accountId: String,
        rfc822MessageId: String,
        imapBody: inout RenderedBody?
    ) async -> NSEMessageMetadata? {
        guard let imap = NSEState.getIMAPAccount(for: accountId) else {
            NSELog.step("NSE IMAP: no shared IMAP config for accountId")
            return nil
        }
        guard let password = SharedKeychain.getPassword(for: accountId), !password.isEmpty else {
            NSELog.step("NSE IMAP: no password in shared Keychain for accountId")
            return nil
        }
        let result = await NSEIMAPConnection.fetch(
            accountId: accountId,
            host: imap.host,
            port: imap.port,
            useTLS: imap.useTLS,
            username: imap.username,
            password: password,
            rfc822MessageId: rfc822MessageId
        )
        guard let result else { return nil }
        imapBody = result.body
        return result.metadata
    }

    // MARK: - Passive Delivery Helper

    /// Deliver a passive (no banner, no sound) notification.
    ///
    /// Default is pass-through: the APNs alert the push-worker pre-populated
    /// (`"New email - <sender>"` / `<subject>`, or `"Reconnecting…"`, etc.) is
    /// left intact. Callers that need situation-specific copy — auth failure,
    /// reconnect-success acknowledgement — supply `overrideTitle` /
    /// `overrideBody`.
    private static func deliverPassive(
        c: UNMutableNotificationContent,
        overrideTitle: String? = nil,
        overrideBody: String? = nil,
        deliver: @escaping (UNNotificationContent) -> Void
    ) {
        applyPassiveSettings(c, overrideTitle: overrideTitle, overrideBody: overrideBody)
        NSELog.step("NSE deliverPassive: title=\(c.title)")
        deliver(c)
    }
}
