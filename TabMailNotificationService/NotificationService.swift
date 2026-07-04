/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UserNotifications
import GRDB
import Synchronization
import os

private let log = OSLog(subsystem: "ai.tabmail.nse", category: "debug")

/// Thread-safe one-shot flag for content handler race prevention.
final class OneShotFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return false }
        fired = true; return true
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

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            os_log(.error, log: log, "NSE didReceive: no mutable content, passing through")
            contentHandler(request.content)
            return
        }

        os_log(.error, log: log, "NSE ━━━ STARTED ━━━ id=%{public}@", request.identifier)

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
        nonisolated(unsafe) let deliver = contentHandler
        nonisolated(unsafe) let c = content
        let t0 = CFAbsoluteTimeGetCurrent()

        // The shared delivery closure — exactly one of {process completion,
        // watchdog, iOS expiration} actually fires it (OneShotFlag), the rest
        // are no-ops. Factored out so the watchdog can deliver too.
        let deliverOnce: @Sendable (UNNotificationContent) -> Void = { notification in
            guard deliverGuard.tryFire() else {
                os_log(.error, log: log, "NSE deliver: already fired (race)")
                return
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if let n = notification as? UNMutableNotificationContent {
                os_log(.error, log: log, "NSE ━━━ DELIVERED (%dms) ━━━ title=%{public}@ level=%d sound=%{public}@",
                       ms, n.title, n.interruptionLevel.rawValue,
                       n.sound == nil ? "nil" : "SET")
            } else {
                os_log(.error, log: log, "NSE ━━━ DELIVERED (%dms) ━━━ (immutable)", ms)
            }
            deliver(notification)
        }

        Task { @Sendable in
            await NotificationService.process(
                c: c, info: info, fanOutIds: fanOutIds, db: db,
                heartbeatHolder: heartbeatHolder,
                watchdogHolder: watchdogHolder,
                leaseHolder: leaseHolder,
                deliver: deliverOnce)
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
            try? await Task.sleep(nanoseconds: UInt64(NSEConfig.watchdogSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            os_log(.error, log: log, "NSE ⏱️ WATCHDOG (%ds) — graceful exit: release lease + deliver", watchdogSecs)
            heartbeatHolder.cancelAndClear()
            let released = leaseHolder.releaseIfHeld()
            os_log(.error, log: log, "NSE watchdog: lease %{public}@", released ? "RELEASED" : "(not held)")
            if c.title.isEmpty { c.title = "New Email"; c.body = "You have a new message" }
            c.interruptionLevel = .passive; c.sound = nil
            deliverOnce(c)
        })
    }

    override func serviceExtensionTimeWillExpire() {
        os_log(.error, log: log, "NSE ⏰ TIMEOUT")
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
        if released { os_log(.error, log: log, "NSE timeout: lease RELEASED (watchdog hadn't run)") }
        guard let contentHandler, let content = bestAttemptContent else { return }
        guard delivered.tryFire() else { return }
        if content.title.isEmpty { content.title = "New Email"; content.body = "You have a new message" }
        content.interruptionLevel = .passive; content.sound = nil
        os_log(.error, log: log, "NSE timeout delivering: title=%{public}@ level=%d", content.title, content.interruptionLevel.rawValue)
        contentHandler(content)
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
        deliver: @escaping (UNNotificationContent) -> Void
    ) async {
        let provider = info["provider"] ?? ""
        let accountEmail = info["accountEmail"] ?? ""
        os_log(.error, log: log, "NSE process: provider=%{public}@ email=%{public}@ fanOut=%d", provider, accountEmail, fanOutIds.count)

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
            os_log(.error, log: log, "NSE route: task_alarm")
            await handleTaskAlarm(c: c, info: info, db: db)
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
            os_log(.error, log: log, "NSE route: imap_reconnect final=%{public}@", isFinal ? "true" : "false")
            if isFinal {
                deliverPassive(c: c, deliver: deliver); return
            }
            await handleIMAPReconnect(c: c, accountEmail: accountEmail, deliver: deliver)
            return
        }

        // ── Step 1: Account lookup + (OAuth-only) token ──
        guard let accountId = NSEState.findAccountId(for: accountEmail) else {
            os_log(.error, log: log, "NSE FAIL: no accountId for %{public}@", accountEmail)
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
                os_log(.error, log: log, "NSE FAIL: no token for %{public}@", accountId)
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
        os_log(.error, log: log, "NSE step1 OK: accountId=%{public}@ provider=%{public}@", String(accountId.prefix(20)), provider)

        // ── Step 2: Resolve message IDs ──
        let payloadMessageId = info["messageId"] ?? ""
        var messageIds: [String]
        if !payloadMessageId.isEmpty {
            // Worker already classified + enumerated. Trust the payload.
            messageIds = [payloadMessageId]
            os_log(.error, log: log, "NSE step2: payload messageId=%{public}@ — skipping history.list", payloadMessageId)
        } else if !fanOutIds.isEmpty {
            messageIds = fanOutIds
            os_log(.error, log: log, "NSE step2: fan-out %d IDs", fanOutIds.count)
        } else {
            let historyId = info["historyId"]
            let lastHid = NSEState.getLastHistoryId(for: accountId)
            os_log(.error, log: log, "NSE step2: historyId=%{public}@ lastHid=%{public}@", historyId ?? "NIL", lastHid ?? "NIL")

            switch provider {
            case "gmail":
                let historyResult = await GmailNSEClient.fetchNewMessageIds(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    historyId: historyId?.isEmpty == true ? nil : historyId,
                    accountId: accountId
                )
                messageIds = historyResult.addedMessageIds

                // Advance historyId to prevent re-processing same events
                if let latestHid = historyResult.latestHistoryId {
                    NSEState.setLastHistoryId(latestHid, for: accountId)
                    os_log(.error, log: log, "NSE step2: advanced historyId to %{public}@", latestHid)
                }

                // Persist inbox removals for main app to merge on wake
                if !historyResult.removedMessageIds.isEmpty, let db {
                    NSEStagingDB.persistInboxRemovals(db: db, accountId: accountId, messageIds: historyResult.removedMessageIds)
                    os_log(.error, log: log, "NSE step2: persisted %d inbox removal(s)", historyResult.removedMessageIds.count)
                }

                // Adjust badge for all unread changes discovered in history
                let badgeDecrement = historyResult.unreadRemovedCount + historyResult.markedReadCount
                let badgeIncrement = historyResult.markedUnreadCount
                if badgeDecrement > 0 { _ = NSEState.decrementBadgeCount(by: badgeDecrement) }
                if badgeIncrement > 0 { for _ in 0..<badgeIncrement { _ = NSEState.incrementBadgeCount() } }
                if badgeDecrement > 0 || badgeIncrement > 0 {
                    os_log(.error, log: log, "NSE step2: badge adjust: -%d (removed=%d read=%d) +%d (unread=%d)",
                           badgeDecrement, historyResult.unreadRemovedCount, historyResult.markedReadCount,
                           badgeIncrement, historyResult.markedUnreadCount)
                }
            case "imap_new_mail":
                guard NSEState.isIMAPPushEnabled() else {
                    os_log(.error, log: log, "NSE step2: IMAP disabled")
                    deliverPassive(c: c, deliver: deliver); return
                }
                // IMAP pushes from the droplet always include the RFC 5322
                // Message-ID in the payload. Without it the NSE
                // has no way to locate the new message — fall through to a
                // passive notification.
                let imapMsgId = info["messageId"] ?? ""
                guard !imapMsgId.isEmpty else {
                    os_log(.error, log: log, "NSE step2: imap_new_mail push missing messageId")
                    deliverPassive(c: c, deliver: deliver); return
                }
                messageIds = [imapMsgId]
            default:
                messageIds = []
            }
            os_log(.error, log: log, "NSE step2: got %d message(s)", messageIds.count)
        }

        guard !messageIds.isEmpty else {
            os_log(.error, log: log, "NSE step2: EMPTY — no new messages (removal-only or no change)")
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
            os_log(.error, log: log, "NSE step3: HEAD=%{public}@ TAIL=%d (legacy payload — tail handled by main-app sync)",
                   headId, messageIds.count - 1)
        } else {
            os_log(.error, log: log, "NSE step3: HEAD=%{public}@", headId)
        }

        // ── Step 4: Fetch message ──
        os_log(.error, log: log, "NSE step4: fetching message %{public}@", headId)
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
            os_log(.error, log: log, "NSE step4: FAIL — message fetch failed")
            deliverPassive(c: c, deliver: deliver); return
        }
        os_log(.error, log: log, "NSE step4 OK: from=%{public}@ subj=%{public}@", msg.senderName, String(msg.subject.prefix(40)))

        // ── GRADUAL STAGING stage 1: header ──
        // Write the header + populated=1 NOW so the main app's merge can SHOW the
        // message before body fetch and AI complete. Body / summary / action are
        // staged incrementally below as each finishes (no longer one big write at
        // the end). The merge keeps the row until AI completes.
        if let db {
            NSEStagingDB.stageHeader(
                db: db, accountId: accountId, accountEmail: accountEmail,
                provider: provider, message: msg, historyId: info["historyId"])
            os_log(.error, log: log, "NSE stage1: header staged (populated)")
        }

        // ── Step 5: Body (full render via shared BodyRenderer) ──
        os_log(.error, log: log, "NSE step5: fetching body")
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
        os_log(.error, log: log, "NSE step5: body=%d chars cidsUnresolved=%{public}@",
               body?.count ?? 0, (rendered?.hasUnresolvedCIDs ?? false) ? "YES" : "NO")

        // ── GRADUAL STAGING stage 2: body ──
        // Attach the rendered body to the already-staged header so the merge can
        // write MessageBody + FTS (and the main app's body queue won't re-fetch).
        if let db {
            NSEStagingDB.stageBody(db: db, accountId: accountId, messageId: msg.messageId, renderedBody: rendered)
            os_log(.error, log: log, "NSE stage2: body staged")
        }

        // ── Step 5.5: AI cache probe — check peers + staging DB before running AI ──
        // Cross-device probe (respects Device Sync user setting)
        // Peer probe key must use the provider-canonical folderPath — NOT a
        // hardcoded "INBOX". For Gmail the two agree; for Outlook/Graph the
        // folder is the opaque `parentFolderId` and main-app peers store the
        // AI cache under that.
        if let rfc = msg.rfc822MessageId,
           let peerHit = await NSEAICacheProbe.probe(accountId: accountId, folderId: msg.folderPath, rfc822MessageId: rfc) {
            os_log(.error, log: log, "NSE step5.5: PEER cache HIT — skipping AI calls")
            let active = EmailNotificationBuilder.fill(
                c,
                signal: EmailNotificationBuilder.Signal(
                    senderName: msg.senderName,
                    senderEmail: msg.senderEmail,
                    subject: msg.subject,
                    summaryBlurb: peerHit.summaryBlurb,
                    actionTag: peerHit.actionTag
                ),
                accountId: accountId, messageId: msg.messageId
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
            os_log(.error, log: log, "NSE step5.5: STAGING cache HIT — skipping AI calls")
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
                accountId: accountId, messageId: msg.messageId
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
        var didClaimAI = false
        if !aiDisabled, let db, let body, !body.isEmpty {
            if let existing = AIOwnershipLease.state(db: db, accountId: accountId, messageId: msg.messageId),
               existing.owner == .mainApp,
               AIOwnershipLease.isFresh(heartbeatMs: existing.heartbeatMs) {
                os_log(.error, log: log, "NSE step6: SKIP — main app holds fresh AI claim")
            } else if AIOwnershipLease.tryClaim(db: db, accountId: accountId, messageId: msg.messageId, owner: .nse) {
                didClaimAI = true
                os_log(.error, log: log, "NSE step6: claimed AI ownership")
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
                os_log(.error, log: log, "NSE step6: SKIP — could not claim AI (contested by fresh owner)")
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
            os_log(.error, log: log, "NSE step6a: calling summary (recipient_status=%{public}@)",
                   recipientStatus.isEmpty ? "omitted" : recipientStatus)
            let summaryVars = PromptVariables.summaryVariables(
                metadata: sharedMetadata, body: sharedBody, account: account,
                recipientStatus: recipientStatus
            )
            if let resp = await BackendNSEClient.sendCompletions(
                promptAlias: "system_prompt_summary",
                variables: BackendNSEClient.Vars(summaryVars),
                authToken: authToken, timeout: NSEConfig.summaryTimeoutSeconds
            ) {
                let parsed = NSEResponseParser.parseSummary(resp.assistant)
                summaryBlurb = parsed.blurb; summaryTodos = parsed.todos
                reminderDate = parsed.reminderDate; reminderTime = parsed.reminderTime
                reminderContent = parsed.reminderContent
                os_log(.error, log: log, "NSE step6a OK: blurb=%{public}@", String((summaryBlurb ?? "nil").prefix(60)))
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
            } else {
                os_log(.error, log: log, "NSE step6a FAIL: summary call failed")
            }

            os_log(.error, log: log, "NSE step6b: calling action")
            let summaryCtx = SummaryContext(blurb: summaryBlurb, todos: summaryTodos)
            let actionVars = PromptVariables.actionVariables(
                metadata: sharedMetadata, body: sharedBody,
                summary: summaryCtx, account: account
            )
            actionTag = await BackendNSEClient.sendActionVote(
                promptAlias: "system_prompt_action",
                variables: BackendNSEClient.Vars(actionVars),
                authToken: authToken, timeout: NSEConfig.actionTimeoutSeconds
            )
            os_log(.error, log: log, "NSE step6b: action=%{public}@", actionTag ?? "nil")
        } else if aiDisabled {
            os_log(.error, log: log, "NSE step6: SKIP — AI disabled (privacy opt-out)")
        } else if body == nil || body?.isEmpty == true {
            os_log(.error, log: log, "NSE step6: SKIP (no body)")
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
        if let db {
            NSEStagingDB.persistProcessedMessage(
                db: db, accountId: accountId, accountEmail: accountEmail, provider: provider,
                message: msg, renderedBody: rendered,
                summaryBlurb: summaryBlurb, summaryTodos: summaryTodos,
                actionTag: actionTag, reminderDate: reminderDate, reminderTime: reminderTime,
                reminderContent: reminderContent, historyId: info["historyId"],
                aiCompleted: aiDone, notified: active
            )
            os_log(.error, log: log, "NSE step7: persisted ai=%d notified=%d", aiDone ? 1 : 0, active ? 1 : 0)
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
            accountId: accountId, messageId: msg.messageId
        )
        os_log(.error, log: log, "NSE step8: %{public}@, badge=%d",
               active ? "ACTIVE (reply)" : "PASSIVE", newBadge)
        c.badge = NSNumber(value: newBadge)

        // NSE is terminal. Heavy post-notification work (reply
        // precompute, FTS, embeddings, IMAP tag writes, badge correction,
        // Device Sync broadcast) runs on the next natural main-app wake via
        // mergeNSEStagingData. The previous follow-up silent push to /nse-done
        // was best-effort (~40% delivery) and added a flaky failure mode.
        deliver(c)
    }

    // MARK: - Task Alarm

    private static func handleTaskAlarm(c: UNMutableNotificationContent, info: [String: String], db: DatabaseQueue?) async {
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

        if let resp = await BackendNSEClient.sendCompletions(
            promptAlias: "system_prompt_chat",
            variables: BackendNSEClient.Vars([
                "user_name": NSEState.getUserName() ?? "User",
                "kb": NSEState.getKBText() ?? "",
                "user_message": userMessage,
            ]),
            authToken: await NSETokenManager.validAccessToken(), timeout: NSEConfig.taskTimeoutSeconds
        ) {
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
            os_log(.error, log: log, "NSE imap_reconnect: no accountId for %{public}@", accountEmail)
            deliverPassive(c: c, deliver: deliver)
            return
        }

        let success = await attemptSilentResubscribe(
            accountId: accountId, accountEmail: accountEmail
        )

        if success {
            let email = accountEmail.isEmpty ? "your account" : accountEmail
            os_log(.error, log: log, "NSE imap_reconnect: silent re-subscribe OK")
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
        os_log(.error, log: log, "NSE imap_reconnect: silent re-subscribe FAILED — leaving payload default")
        deliverPassive(c: c, deliver: deliver)
    }

    /// Encrypt the account's IMAP creds with the shared
    /// `IMAP_CRED_ENCRYPTION_KEY` and POST to the push-worker's
    /// `/subscribe-imap`. Returns true on 2xx.
    private static func attemptSilentResubscribe(
        accountId: String, accountEmail: String
    ) async -> Bool {
        guard let imap = NSEState.getIMAPAccount(for: accountId) else {
            os_log(.error, log: log, "NSE resubscribe: no shared IMAP config")
            return false
        }
        guard let password = SharedKeychain.getPassword(for: accountId),
              !password.isEmpty else {
            os_log(.error, log: log, "NSE resubscribe: no password in shared Keychain")
            return false
        }
        guard let userId = NSETokenManager.supabaseUserId() else {
            os_log(.error, log: log, "NSE resubscribe: no supabase userId")
            return false
        }
        guard let token = await NSETokenManager.validAccessToken() else {
            os_log(.error, log: log, "NSE resubscribe: no valid JWT")
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
            os_log(.error, log: log, "NSE resubscribe: encrypt failed: %{public}@", String(describing: error))
            return false
        }

        let urlString = NSEState.getPushWorkerURL() + "/subscribe-imap"
        guard let url = URL(string: urlString) else {
            os_log(.error, log: log, "NSE resubscribe: bad push worker URL")
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
                os_log(.error, log: log, "NSE resubscribe: HTTP %d body=%{public}@", code, bodyPreview)
                return false
            }
            return true
        } catch {
            os_log(.error, log: log, "NSE resubscribe: HTTP failed: %{public}@", String(describing: error))
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
            os_log(.error, log: log, "NSE IMAP: no shared IMAP config for accountId")
            return nil
        }
        guard let password = SharedKeychain.getPassword(for: accountId), !password.isEmpty else {
            os_log(.error, log: log, "NSE IMAP: no password in shared Keychain for accountId")
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
        os_log(.error, log: log, "NSE deliverPassive: title=%{public}@", c.title)
        deliver(c)
    }
}
