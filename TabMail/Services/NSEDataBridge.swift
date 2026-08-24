/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import UserNotifications

/// DEBUG-ONLY probe to pin a "merged outcome shows late" lag. Stamps when the NSE
/// merge fires its immediate inbox-reload signal, then measures how long until the
/// inbox actually reloads (`InboxViewModel.reloadMessages`) and the badge is set
/// (`UnreadCountManager.updateBadge`). On a quick-open capture:
///   • `inbox reloaded +Nms` large  → the signal→reload path is the lag (debounce /
///     single-flight / interaction-freeze) — look there.
///   • `inbox reloaded +Nms` small but the row still looks late → SwiftUI RENDER
///     delay after the @Observable mutation.
///   • both small → the merge fired late (trigger timing), not the surfacing.
/// No-op unless `DebugModeManager.isLoggingEnabled()` (CLAUDE.md rule 12).
enum MergeSurfaceProbe {
    nonisolated static let signalAt = Mutex<CFAbsoluteTime>(0)

    static func markMergeSignal() {
        guard DebugModeManager.isLoggingEnabled() else { return }
        signalAt.withLock { $0 = CFAbsoluteTimeGetCurrent() }
    }

    static func logSince(_ label: @autoclosure () -> String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let t0 = signalAt.withLock { $0 }
        guard t0 > 0 else { return }
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard ms <= 30_000 else { return } // ignore events unrelated to a recent merge
        print("[MergeSurface] \(label()) +\(ms)ms after merge signal")
    }
}

/// Bridges data between the main app and the Notification Service Extension.
/// Main app writes to shared UserDefaults (prompts, account map, etc.).
/// NSE writes to the staging DB. Main app merges staging data on every wake.
enum NSEDataBridge {
    private static let appGroupId = "group.ai.tabmail"
    private static var suite: UserDefaults? { UserDefaults(suiteName: appGroupId) }
    private static let rejectedAccountPushMarkerKey = "tabmail.rejectedAccountPush"

    /// Account-scoped pushes name the local Account.id and may affect app state
    /// only while the shared account mirror still maps that email to the same
    /// row. Notifications with no account scope (such as task alarms) are
    /// unaffected.
    static func accountIncarnationMatches(
        _ accountIncarnation: String?,
        accountEmail: String,
        defaults customDefaults: UserDefaults? = nil
    ) -> Bool {
        guard !accountEmail.isEmpty else { return true }
        guard let accountIncarnation, !accountIncarnation.isEmpty else { return false }
        let source = customDefaults ?? suite
        guard let json = source?.string(forKey: "nse.accountMap"),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return false
        }
        return map[accountEmail.lowercased()] == accountIncarnation
    }

    /// Reject both a raw stale-incarnation payload and the inert marker emitted
    /// after the NSE has stripped that payload's actionable metadata.
    static func notificationAccountMatches(
        _ userInfo: [AnyHashable: Any],
        defaults customDefaults: UserDefaults? = nil
    ) -> Bool {
        if userInfo[rejectedAccountPushMarkerKey] as? Bool == true { return false }
        return accountIncarnationMatches(
            userInfo["accountIncarnation"] as? String,
            accountEmail: userInfo["accountEmail"] as? String ?? "",
            defaults: customDefaults
        )
    }

    /// Cached read connection to the NSE staging DB for the read-path "is there
    /// anything to merge?" check. We deliberately do NOT use a cross-process dirty
    /// FLAG — a flag can drift (a false-negative silently skips a merge). Instead
    /// we query the REAL staging DB (source of truth, can't drift), cache the
    /// connection, and COALESCE probes (`lastProbeMs` + `stagingProbeCoalesceMs`)
    /// so the cross-process read runs at most once per window — NOT once per app
    /// read, which (the staging DB being a NON-WAL shared file, ADR-IOS-041) would
    /// open a read transaction per read and could block behind an NSE commit.
    /// `nil` until the staging file first exists (no push received yet).
    private static let stagingProbe = Mutex<DatabaseQueue?>(nil)
    /// Monotonic ms (CFAbsoluteTime ×1000) of the last probe attempt — gates the
    /// coalesce window so frequent reads don't each hit the cross-process file.
    private static let lastProbeMs = Mutex<Double>(0)

    private static func stagingProbeConnection() -> DatabaseQueue? {
        stagingProbe.withLock { cached in
            if let cached { return cached }
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
            let path = containerURL.appendingPathComponent("nse_staging.sqlite").path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            var config = Configuration()
            config.observesSuspensionNotifications = true   // ADR-IOS-041
            // Fail FAST, never stall. The staging DB is the NSE's NON-WAL shared
            // file (ADR-IOS-041), so a reader blocks behind an NSE commit. A probe
            // must NEVER make an app read wait: on contention it returns "not
            // pending" and the next-window probe / explicit boot/foreground/push
            // merge catches the row (which stays populated=1 — nothing is lost).
            config.busyMode = .immediateError
            let q = try? DatabaseQueue(path: path, configuration: config)
            cached = q
            return q
        }
    }

    /// Change-detection signature of the populated staging set. Every gradual
    /// stage transition is observable here: a new header row changes `count` +
    /// `maxProcessedAt` (set on first insert); `stageBody` flips html/text
    /// NULL→non-NULL (`bodiedCount`); `stageSummary` flips summaryBlurb
    /// (`summariedCount`); the terminal persist flips `aiCompleted`
    /// (`aiCompletedCount`), and its post-merge delete drops `count`.
    /// `processedAt` is NOT bumped by the later stages (first-insert only, it
    /// anchors the abandon window) — that's exactly why the stage counts are in
    /// the signature. Anything hypothetically invisible to it (an
    /// identical-signature content rewrite, a failed merge awaiting retry) is
    /// bounded by `stagingMergeSignatureTTLSeconds`, after which the read-through
    /// path merges regardless.
    struct StagingSignature: Equatable, Sendable {
        let count: Int
        let maxProcessedAt: Double
        let bodiedCount: Int
        let summariedCount: Int
        let aiCompletedCount: Int
    }

    /// The staged rows the most recent merge read (replace-all per merge; empty
    /// when staging is drained). ADR-IOS-049. Consumers: `InboxListReader` (the
    /// unified inbox-list render path, PLAN_INBOX_UNIFIED_READ.md §2.1 — reads
    /// this directly as the S source on every fetch) and the NON-render
    /// fallbacks that need to resolve a message that is staged but not yet
    /// durable in GRDB: notification deep-link id resolution
    /// (`MailNavigationView`), `MessageDetailViewModel`'s header synthesis, and
    /// `InboxViewModel.lookupMessage`/snippet-loader synthesis. GRDB always
    /// wins for the fallbacks — they consult this only on a GRDB miss.
    static let latestStagedRows = Mutex<[StagedInboxRow]>([])

    /// Display-ready body content of the most recent merge's staged rows, keyed
    /// by headerId. Companion to `latestStagedRows` for the notification-tap
    /// path: the NSE already fetched + rendered the pushed message's body into
    /// staging, but `MessageDetailViewModel.loadBody` only reads GRDB — so a tap
    /// seconds after the push waited on the merge's phase-2 durable write
    /// (measured 1.5–5.6s under backfill I/O), fell to the 2s body-poll cadence,
    /// or re-FETCHED the body from the network. This snapshot lets the detail
    /// view synthesize a transient `MessageBody` for DISPLAY immediately;
    /// durability stays phase-2's job (same bytes, so the later durable read is
    /// value-identical). Replace-all per merge, like `latestStagedRows` (drained
    /// staging clears it); bounded by the staged-set size. Unresolved-CID bodies
    /// are excluded — the main app must re-fetch + re-render those properly.
    struct StagedBodySnapshot: Sendable {
        let htmlContent: String
        let attachmentsJSON: String?
        let icsText: String?
    }
    static let latestStagedBodies = Mutex<[String: StagedBodySnapshot]>([:])

    /// Synthesize a display-only `MessageBody` from the staged snapshot, or nil
    /// when the message isn't staged / has no usable rendered body. GRDB always
    /// wins — call ONLY on a GRDB `messageBody` miss (mirrors
    /// `stagedRowFallback`'s contract for headers).
    static func stagedBodyFallback(headerId: String) -> MessageBody? {
        latestStagedBodies.withLock { $0[headerId] }?
            .toMessageBody(contentKey: ContentKey(rawValue: headerId))
    }

    /// The staged set (headerId-sorted) of the last `.messagesStaged` post — a
    /// re-merge of a KEPT gradual row re-reads an unchanged set; posting it again
    /// is pure churn for the VM. Memo compared/replaced on EVERY merge (including
    /// empty/drained, which resets it so a future re-stage posts again).
    private static let lastPostedStagedRows = Mutex<[StagedInboxRow]>([])

    /// The snippet a staged row should DISPLAY (in-memory render + phase-1 DB
    /// seed). Pure, extracted for unit testing.
    ///
    /// Preference order (the "weird snippet that then snaps" fix):
    /// 1. Body-derived (`snippetFromPlainText(textContent)`) — byte-identical to
    ///    the canonical snippet phase-2 writes, so the row NEVER visibly changes.
    /// 2. `cleanSnippet(providerSnippet)` — body not staged yet. Gmail's API
    ///    `snippet` / Graph's `bodyPreview` arrive HTML-ENTITY-ENCODED with the
    ///    provider's own truncation (`GmailParse.swift` stores `json["snippet"]`
    ///    RAW into staging); the six sync-path header creators launder it through
    ///    `cleanSnippet`, but the staged-row display path didn't — the in-memory
    ///    row briefly showed literal `&#39;`/`&amp;` garbage until the
    ///    body-derived snippet landed ("weird snippet that then snaps in").
    ///    Staging deliberately stays RAW and THIS is the single cleaning
    ///    boundary: entity decoding is not idempotent (`&amp;lt;` → `&lt;` →
    ///    `<`), so cleaning both at NSE-stage time and here would double-decode.
    static func stagedDisplaySnippet(providerSnippet: String, textContent: String?) -> String {
        if let text = textContent, !text.isEmpty {
            let derived = EmailFilter.snippetFromPlainText(text)
            if !derived.isEmpty { return derived }
        }
        guard !providerSnippet.isEmpty else { return "" }
        return EmailFilter.cleanSnippet(providerSnippet)
    }

    /// Pure memo compare + update, extracted for unit testing: true iff `rows`
    /// (order-normalized by headerId) differs from what the memo last recorded;
    /// the memo is updated to `rows` either way it changed. In-memory equality
    /// only — deliberately NOT a DB read (the pre-write `surfacesNew` read was a
    /// regression made once and reverted).
    ///
    /// Fail-open edge: a staged row with a nil `date` gets a fresh `Date()` at
    /// each merge's row build (`msg.date ?? Date()` above), so it never compares
    /// equal → suppression doesn't fire for it and every re-merge re-posts (the
    /// pre-suppression behavior; the VM's dedup absorbs it). Erring toward
    /// posting more, never less.
    static func stagedSetChangedSinceLastPost(
        _ rows: [StagedInboxRow], memo: borrowing Mutex<[StagedInboxRow]>
    ) -> Bool {
        let normalized = rows.sorted { $0.headerId < $1.headerId }
        return memo.withLock { last -> Bool in
            guard last != normalized else { return false }
            last = normalized
            return true
        }
    }

    /// Signature of the staged set the last read-through-triggered merge consumed,
    /// with its completion timestamp. Compared by `mergeIfStagingPending` to skip
    /// re-merging a KEPT gradual row (`aiCompleted=0` survives the merge by design,
    /// so the pending-probe would otherwise answer "yes" — and trigger a full
    /// ~45ms re-merge — on EVERY async read for up to 60s per push).
    private static let lastMergedStagingSignature = Mutex<(sig: StagingSignature, at: Double)?>(nil)

    /// The populated staging set's signature, or nil when nothing is pending.
    /// COALESCED to at most one cross-process probe per `stagingProbeCoalesceMs`:
    /// reads are frequent and the probe is a non-WAL shared-container read, so
    /// without this every read would pay a cross-process read transaction.
    /// Between probes it returns nil — a freshly-staged row is picked up by the
    /// next post-window read (≤ window latency) or the explicit merge triggers
    /// (which call `mergeNSEStagingData` directly, bypassing this probe), and the
    /// row stays populated=1 so nothing is lost. Probe contention (fail-fast
    /// `.immediateError`) likewise returns nil — same fail-open-toward-skip
    /// semantics as before.
    private static func stagingPendingSignature() async -> StagingSignature? {
        let nowMs = CFAbsoluteTimeGetCurrent() * 1000
        let shouldProbe = lastProbeMs.withLock { last -> Bool in
            guard nowMs - last >= SyncConfig.stagingProbeCoalesceMs else { return false }
            last = nowMs
            return true
        }
        guard shouldProbe, let db = stagingProbeConnection() else { return nil }
        return (try? await db.read { db -> StagingSignature? in
            guard try db.tableExists("nse_processed_message") else { return nil }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c,
                       COALESCE(MAX(processedAt), 0) AS maxP,
                       COALESCE(SUM(CASE WHEN htmlContent IS NOT NULL OR textContent IS NOT NULL THEN 1 ELSE 0 END), 0) AS bodied,
                       COALESCE(SUM(CASE WHEN summaryBlurb IS NOT NULL THEN 1 ELSE 0 END), 0) AS summaried,
                       COALESCE(SUM(aiCompleted), 0) AS aiDone
                FROM nse_processed_message WHERE populated = 1
                """), (row["c"] as Int? ?? 0) > 0 else { return nil }
            return StagingSignature(
                count: row["c"],
                maxProcessedAt: row["maxP"],
                bodiedCount: row["bodied"],
                summariedCount: row["summaried"],
                aiCompletedCount: row["aiDone"]
            )
        }) ?? nil
    }

    /// Pure skip decision, extracted for unit testing: skip the read-through merge
    /// iff the current staging signature exactly matches what the last merge
    /// consumed AND that merge is younger than the TTL. Any mismatch, absence of a
    /// recorded signature, or TTL expiry → merge.
    static func shouldSkipReadThroughMerge(
        current: StagingSignature,
        last: (sig: StagingSignature, at: Double)?,
        now: Double,
        ttl: TimeInterval = SyncConfig.stagingMergeSignatureTTLSeconds
    ) -> Bool {
        guard let last else { return false }
        return last.sig == current && (now - last.at) < ttl
    }

    /// READ-PATH entry: drain NSE staging into main GRDB if (and only if) the
    /// staging DB has pending work the app hasn't merged yet. Treats staging as a
    /// read-through delta — any read (UI render, silent push, BGAppRefresh,
    /// BGProcessing) merges it first, with no per-call-site placement. The pending
    /// check reads the real staging DB (no flag drift) and is ~µs when empty.
    ///
    /// SIGNATURE SKIP: a KEPT gradual row (merged, but retained in staging until
    /// the NSE finishes AI — ADR-IOS-047) keeps the probe answering "yes" for up
    /// to 60s, which used to re-run a full merge on every async read (measured 47×
    /// per push during a sync burst). The skip is deferral-only, never a drop:
    /// staging rows are deleted ONLY by phase-2 commit, the signature observes
    /// every stage transition, the TTL re-merges anything it can't see within
    /// `stagingMergeSignatureTTLSeconds`, and ALL explicit merge triggers
    /// (foreground, push, syncStartup step-0, AI queue, action-gate ensureDurable)
    /// call `mergeNSEStagingData`/the coordinator directly — bypassing this skip.
    static func mergeIfStagingPending(
        onSnapshotPublished: (@Sendable () -> Void)? = nil
    ) async {
        // Recursion guard: the merge does its own GRDB reads (e.g. the FTS flush
        // bulk header read), which run inside `PriorityGate.privileged` — don't
        // re-trigger a merge from within one.
        guard !PriorityGate.inPrivilegedContext else { return }
        guard let current = await stagingPendingSignature() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastMergedStagingSignature.withLock { $0 }
        if shouldSkipReadThroughMerge(current: current, last: last, now: now) { return }
        await mergeNSEStagingData(onSnapshotPublished: onSnapshotPublished)
        // Record the PRE-merge signature (what this merge consumed). If the merge
        // itself deleted terminal rows or the NSE staged more mid-merge, the next
        // probe's signature differs → one settling re-merge, which then records
        // the settled signature. Errs toward merging more, never less.
        lastMergedStagingSignature.withLock { $0 = (sig: current, at: CFAbsoluteTimeGetCurrent()) }
    }

    /// BOOT-PATH paint gate: run the read-through merge, but suspend the caller
    /// ONLY until the merge has published its in-memory staged snapshot
    /// (`latestStagedRows`/`latestStagedBodies` replaced, `.messagesStaged`
    /// queued) — or returned without one (nothing pending / staging unreadable),
    /// whichever comes first. The merge itself continues un-awaited and lands
    /// durably post-paint.
    ///
    /// Why: `runIfNeeded` used to await the FULL merge before FIRST PAINT, so a
    /// slow phase-1 header write gated the inbox — measured 7.6s on a cold-I/O
    /// boot (killed-mid-sync WAL debt + cold FS caches, boot_logs 5 2026-07-03)
    /// while the snapshot the first frame actually renders from had been ready
    /// since +700ms. `InboxViewModel.resetMessages` (run at VM init, i.e. at
    /// paint) seeds from `latestStagedRows`, so "pushed message in first frame"
    /// needs only the snapshot; the durable write is invisible to paint — the
    /// same two-phase contract (ADR-IOS-049) as every foreground merge.
    static func mergeIfStagingPendingPaintGate() async {
        let gate = OneShotGate()
        Task {
            await mergeIfStagingPending(onSnapshotPublished: {
                if gate.open() {
                    BootProfiler.mark("bootMerge: paint gate released on SNAPSHOT publish (merge continues post-paint)")
                }
            })
            // Covers every no-snapshot exit: nothing pending, signature skip,
            // privileged recursion, staging file missing/locked. All are fast.
            if gate.open() {
                BootProfiler.mark("bootMerge: paint gate released on merge completion (no snapshot published)")
            }
        }
        await gate.wait()
    }

    // MARK: - Mirror (Main App → Shared UserDefaults for NSE)

    /// Mirror all current state to shared UserDefaults.
    /// Call on app launch and whenever relevant state changes.
    static func mirrorAllState() {
        mirrorAccountMap()
        mirrorIMAPAccounts()
        mirrorPrompts()
        mirrorUserName()
        mirrorBackendConfig()
        mirrorDeviceToken()
        mirrorPushSettings()
        mirrorDebugLogging()
    }

    /// Mirror lowercase account email→accountId mapping to match worker routing.
    /// Call on account add/remove.
    static func mirrorAccountMap(defaults override: UserDefaults? = nil) {
        guard let target = override ?? suite else { return }
        do {
            let accounts = try AppDatabase.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, emailAddress FROM account")
            }
            var map: [String: String] = [:]
            for row in accounts {
                if let email: String = row["emailAddress"], let id: String = row["id"] {
                    map[email.lowercased()] = id
                }
            }
            let data = try JSONEncoder().encode(map)
            target.set(String(data: data, encoding: .utf8), forKey: "nse.accountMap")
        } catch {
            print("[NSEDataBridge] Failed to mirror account map: \(error)")
        }
    }

    /// Remove one deleted account from both NSE identity mirrors without a
    /// second database read. Account removal calls this as reversible,
    /// fail-closed preparation before the authoritative GRDB commit, eliminating
    /// the commit→mirror process-kill window. Malformed mirror data is cleared
    /// rather than retaining an identity we can no longer prove current.
    static func removeAccountFromMirrors(
        accountId: String,
        email: String,
        defaults override: UserDefaults? = nil
    ) {
        guard let target = override ?? suite else { return }

        if let json = target.string(forKey: "nse.accountMap"),
           let data = json.data(using: .utf8),
           var map = try? JSONDecoder().decode([String: String].self, from: data) {
            map = map.filter { key, value in
                value != accountId && key.caseInsensitiveCompare(email) != .orderedSame
            }
            if let encoded = try? JSONEncoder().encode(map) {
                target.set(String(data: encoded, encoding: .utf8), forKey: "nse.accountMap")
            } else {
                target.removeObject(forKey: "nse.accountMap")
            }
        } else {
            target.removeObject(forKey: "nse.accountMap")
        }

        if let json = target.string(forKey: "nse.imapAccounts"),
           let data = json.data(using: .utf8),
           var map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            map.removeValue(forKey: accountId)
            if let encoded = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) {
                target.set(String(data: encoded, encoding: .utf8), forKey: "nse.imapAccounts")
            } else {
                target.removeObject(forKey: "nse.imapAccounts")
            }
        } else {
            target.removeObject(forKey: "nse.imapAccounts")
        }
    }

    /// Mirror IMAP account connection info (host/port/username/useTLS) for
    /// NSE one-shot fetches on `imap_new_mail` / `imap_reconnect` pushes.
    /// The password is already in shared Keychain
    /// (`KeychainHelper.passwordKey(accountId:)` reads/writes via the
    /// app-group access group, so NSE reads it via `SharedKeychain`).
    /// Call on account add / remove / IMAP-config edit.
    static func mirrorIMAPAccounts(defaults override: UserDefaults? = nil) {
        guard let target = override ?? suite else { return }
        do {
            let rows = try AppDatabase.dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, imapHost, imapPort, imapUsername, emailAddress
                    FROM account
                    WHERE provider IN ('imap', 'icloud')
                      AND imapHost IS NOT NULL
                      AND imapHost != ''
                    """
                )
            }
            var map: [String: [String: Any]] = [:]
            for row in rows {
                guard let id: String = row["id"],
                      let host: String = row["imapHost"] else { continue }
                let username = (row["imapUsername"] as String?)
                    ?? (row["emailAddress"] as String?)
                    ?? ""
                let port = (row["imapPort"] as Int?) ?? 993
                let entry: [String: Any] = [
                    "host": host,
                    "port": port,
                    "username": username,
                ]
                // Main app's IMAPProvider defaults useTLS to nil → SwiftMail
                // picks based on port. We mirror that — only stash `useTLS`
                // if the operator ever wires an override; otherwise omit.
                // (Currently always omitted — present as a schema hook.)
                _ = entry
                map[id] = entry
            }
            let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
            target.set(String(data: data, encoding: .utf8), forKey: "nse.imapAccounts")
        } catch {
            print("[NSEDataBridge] Failed to mirror IMAP accounts: \(error)")
        }
    }

    /// Mirror lastHistoryId per account for NSE's history.list calls.
    /// Call after each sync that advances the cursor.
    static func mirrorLastHistoryIds() {
        guard let suite else { return }
        do {
            let accounts = try AppDatabase.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, lastHistoryId FROM account WHERE lastHistoryId IS NOT NULL")
            }
            var map: [String: String] = [:]
            for row in accounts {
                if let id: String = row["id"], let historyId: String = row["lastHistoryId"] {
                    map[id] = historyId
                }
            }
            let data = try JSONEncoder().encode(map)
            suite.set(String(data: data, encoding: .utf8), forKey: "nse.lastHistoryIds")
        } catch {
            print("[NSEDataBridge] Failed to mirror lastHistoryIds: \(error)")
        }
    }

    /// Mirror prompt store values.
    /// Call from PromptStore.didSet and after Device Sync applies incoming state.
    static func mirrorPrompts() {
        guard let suite else { return }
        let defaults = UserDefaults.standard
        suite.set(defaults.string(forKey: "user_prompts:user_composition.md") ?? "", forKey: "nse.compositionPrompt")
        suite.set(defaults.string(forKey: "user_prompts:user_action.md") ?? "", forKey: "nse.actionPrompt")
        suite.set(defaults.string(forKey: "user_prompts:user_kb.md") ?? "", forKey: "nse.kbText")
    }

    /// Mirror user display name.
    static func mirrorUserName() {
        guard let suite else { return }
        let name = UserDefaults.standard.string(forKey: "userName") ?? ""
        suite.set(name, forKey: "nse.userName")
    }

    /// Mirror backend configuration.
    /// Respects the Settings > Debug > "Use Dev Servers" toggle via BackendConfig.
    static func mirrorBackendConfig() {
        guard let suite else { return }
        suite.set(BackendConfig.apiBaseURL.absoluteString, forKey: "nse.backendBaseURL")
        // Mirror whatever the main-app PushClient actually points at. Until
        // 2026-04-18 this was hardcoded to prod, which foot-gunned any dev
        // test that wired a Debug iOS build up to a dev push-worker — the
        // NSE reconnect flow would POST /subscribe-imap to prod instead.
        // PushConfig.baseURL is the single source of truth; change that
        // if you need dev routing and both sides stay in sync.
        suite.set(PushConfig.baseURL, forKey: "nse.pushWorkerURL")
        // Mirror Google client ID for token refresh in NSE
        if let clientId = Bundle.main.infoDictionary?["GOOGLE_CLIENT_ID"] as? String {
            suite.set(clientId, forKey: "nse.googleClientId")
        }
        // Mirror Microsoft client ID (primary mail-account client) for
        // Outlook NSE token refresh — parallel to Gmail. See NSEAuthSource.
        if let msClientId = Bundle.main.infoDictionary?["MICROSOFT_CLIENT_ID"] as? String {
            suite.set(msClientId, forKey: "nse.microsoftClientId")
        }
    }

    /// Mirror push notification and sync settings.
    /// Call on launch and when user toggles settings.
    ///
    /// Note: there used to be an `nse.pushEnabled` mirror of `pushNotificationsEnabledKey`.
    /// Removed — the NSE's deliverPassive now gates suppression solely on Apple's
    /// filtering entitlement. The subscription endpoint choice (silent vs NSE) is
    /// handled entirely by PushClient at registration time; nothing inside the NSE
    /// process needs to read the opt-in state.
    static func mirrorPushSettings() {
        guard let suite else { return }
        suite.set(PushConfig.nseFilteringApproved, forKey: "nse.filteringApproved")
        let syncEnabled = UserDefaults.standard.object(forKey: "device_sync_auto_enabled") as? Bool ?? true
        suite.set(syncEnabled, forKey: "nse.deviceSyncEnabled")
        suite.set(BackendConfig.syncBaseURL, forKey: "nse.syncBaseURL")
    }

    /// Mirror device token so NSE can call /nse-done.
    static func mirrorDeviceToken() {
        guard let suite else { return }
        if let token = UserDefaults.standard.string(forKey: "lastDeviceToken") {
            suite.set(token, forKey: "nse.deviceToken")
        }
    }

    /// Mirror the debug-logging gate flag so the NSE process — which has no
    /// Keychain access for `DebugModeManager.isLoggingEnabled()`'s session
    /// check — can see whether `NSELogStore` should write its persistent
    /// file. Call on launch (`mirrorAllState`) and immediately from
    /// `DebugModeManager` on unlock/lock, so toggling debug mode takes effect
    /// without waiting for the next mirror pass.
    static func mirrorDebugLogging() {
        guard let suite else { return }
        suite.set(DebugModeManager.isLoggingEnabled(), forKey: "nse.debugLoggingEnabled")
    }

    // MARK: - Merge (NSE Staging DB → Main GRDB)

    /// Merge all NSE-processed results into main GRDB.
    /// Called FIRST on every wake path: foreground return, BGAppRefresh, BGProcessingTask, silent push.
    /// MUST succeed independently of sync — if the staging DB is busy, retry with backoff.
    /// Open the NSE staging DB for callers that need to coordinate with the
    /// NSE (e.g. `AIOwnershipLease`) without performing a full merge. Returns
    /// `nil` if the App Group container is unavailable or the staging DB
    /// file hasn't been created yet (first launch before any push).
    static func openStagingDB() -> DatabaseQueue? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return nil }
        let stagingPath = containerURL.appendingPathComponent("nse_staging.sqlite").path
        guard FileManager.default.fileExists(atPath: stagingPath) else { return nil }
        var config = Configuration()
        config.busyMode = .timeout(2.0)
        // 0xdead10cc defense (ADR-IOS-041) — App Group DB, the highest-risk
        // lock for cross-process suspension kills.
        config.observesSuspensionNotifications = true
        return try? DatabaseQueue(path: stagingPath, configuration: config)
    }

    // MARK: - UIDVALIDITY reset purges (T4.S4)

    /// Purge NSE-staged state for ONE folder, as step 4 of the UIDVALIDITY
    /// purge-and-resync reaction (`AccountManager.runUidValidityResetReaction`).
    /// PORTED from `v2final`'s `NSEDataBridge.purgeStagedStateForFolder`
    /// (commit `4d34ee864`). Idempotent: filtering an already-clean snapshot and
    /// deleting already-gone staging rows are both no-ops, so a crash re-drive may
    /// call this again freely.
    ///  - In-memory: filters `latestStagedRows` / `latestStagedBodies`, the same
    ///    `Mutex.withLock` shape the stale-by-move scrub in `performMerge` uses.
    ///  - Staging DB: `nse_processed_message WHERE accountId = ? AND folderPath = ?`.
    ///
    /// 🚨 RETURNS WHETHER THE DURABLE PURGE COMMITTED, AND THE CALLER MUST CONSUME
    /// IT (audit round 1 / C-4). This used to be non-throwing AND non-reporting, so
    /// a failed DELETE was invisible: the reaction went on to stamp the NEW epoch
    /// and clear the quarantine over a staging file still holding OLD-epoch
    /// instructions, and the next merge applied them to whatever the resync had
    /// seated at the reused UID.
    ///
    /// The doc that stood here justified the swallow with "the next ordinary sync
    /// pass stale-sweeps a UID the server no longer returns". **That premise is
    /// false for the case that matters**: after a UIDVALIDITY turnover the new epoch
    /// legitimately REUSES and RETURNS the same UIDs, so the sweep never fires and
    /// the stale instruction lands on a live message. The comment encoded the bug;
    /// it is replaced rather than annotated.
    ///
    /// `true` means the staged rows for this scope are provably gone — including the
    /// case where no staging file exists at all, which is a COMPLETE purge over an
    /// empty set, not a skipped one. `false` means the staging DB exists and could
    /// not be written (or could not be opened), i.e. the contents are UNKNOWN.
    ///
    /// The in-memory scrub happens unconditionally and first: it cannot fail, and it
    /// must not be skipped just because the durable half did.
    ///
    /// Idempotent: filtering an already-clean snapshot and deleting already-gone
    /// staging rows are both no-ops, so a re-drive may call this again freely.
    ///
    /// ⚠ `v2final` justifies its swallow by the D-6 merge epoch guard
    /// (`detectOldEpochStagedRows`), which v3 does NOT have. Stated so a later reader
    /// does not cite a guard this tree lacks — refusing to advance the epoch is v3's
    /// substitute for it.
    ///
    /// `stagingPathOverride` mirrors `mergeNSEStagingData`'s test seam — production
    /// callers never pass it and fall back to the real App-Group file.
    static func purgeStagedStateForFolder(
        accountId: String, folderPath: String, stagingPathOverride: String? = nil
    ) -> Bool {
        latestStagedRows.withLock { rows in
            rows.removeAll { $0.accountId == accountId && $0.folderPath == folderPath }
        }
        // `headerIdBelongsToFolder` — NOT a bare `hasPrefix`: on an IMAP server whose
        // hierarchy delimiter is ':', a nested sibling ("acct:Work:Sub:123") shares
        // this folder's prefix and must NOT be swept up by its purge.
        latestStagedBodies.withLock { bodies in
            let victims = bodies.keys.filter {
                MessageIdentity.headerIdBelongsToFolder($0, accountId: accountId, folderPath: folderPath)
            }
            for key in victims { bodies.removeValue(forKey: key) }
        }
        switch stagingPurgeTarget(stagingPathOverride: stagingPathOverride) {
        case .nothingStaged:
            return true
        case .unreachable:
            if DebugModeManager.isLoggingEnabled() {
                print("[NSEDataBridge] purgeStagedStateForFolder could not open the staging DB for \(accountId.prefix(8)):\(folderPath) — contents unknown, reporting FAILURE")
            }
            return false
        case .queue(let queue):
            do {
                try queue.write { db in
                    guard try db.tableExists("nse_processed_message") else { return }
                    try db.execute(
                        sql: "DELETE FROM nse_processed_message WHERE accountId = ? AND folderPath = ?",
                        arguments: [accountId, folderPath]
                    )
                }
                return true
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[NSEDataBridge] purgeStagedStateForFolder nse_processed_message delete failed for \(accountId.prefix(8)):\(folderPath): \(error)")
                }
                return false
            }
        }
    }

    /// Clear `nse_inbox_removal` rows for ONE account. PORTED from `v2final`'s
    /// `NSEDataBridge.purgeInboxRemovalMarkersForAccount` (commit `4d34ee864`).
    ///
    /// ⚑ CALL ONLY WHEN THE FOLDER BEING RESET IS THE ACCOUNT'S INBOX-ROLE FOLDER.
    /// The table is (account, UID)-keyed with NO folderPath column, so it cannot be
    /// scoped any narrower — and a removal instruction minted in the OLD epoch would
    /// otherwise delete a NEW-epoch row that merely reused the same UID (C3). The
    /// inbox-role gate is what keeps this account-wide delete from firing for a
    /// non-inbox folder's reset, whose staged removals it has no claim over.
    ///
    /// Runs adjacent to (never inside) the main purge transaction — the staging DB
    /// is a separate file — and is idempotent.
    ///
    /// 🚨 RETURNS WHETHER THE DELETE COMMITTED (audit round 1 / C-4), with exactly
    /// the semantics of `purgeStagedStateForFolder`'s result. A surviving marker here
    /// is the sharpest form of the hazard: it is an executable DELETE instruction
    /// naming a bare UID, so once the reaction advances the folder to the new epoch
    /// and the resync seats a different message at that UID, the next merge deletes
    /// it. The caller must not advance the epoch over a `false`.
    static func purgeInboxRemovalMarkersForAccount(accountId: String, stagingPathOverride: String? = nil) -> Bool {
        switch stagingPurgeTarget(stagingPathOverride: stagingPathOverride) {
        case .nothingStaged:
            return true
        case .unreachable:
            if DebugModeManager.isLoggingEnabled() {
                print("[NSEDataBridge] purgeInboxRemovalMarkersForAccount could not open the staging DB for \(accountId.prefix(8)) — contents unknown, reporting FAILURE")
            }
            return false
        case .queue(let queue):
            do {
                try queue.write { db in
                    guard try db.tableExists("nse_inbox_removal") else { return }
                    try db.execute(sql: "DELETE FROM nse_inbox_removal WHERE accountId = ?", arguments: [accountId])
                }
                return true
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[NSEDataBridge] purgeInboxRemovalMarkersForAccount failed for \(accountId.prefix(8)): \(error)")
                }
                return false
            }
        }
    }

    #if DEBUG
    /// ⚑ NO REFERENCE — INVENTED (T4.S4). `v2final` threads `stagingPathOverride`
    /// only through call sites that HAVE one; its reaction calls both purges with no
    /// override, so on that tree the inbox-role gate and the best-effort swallow are
    /// unobservable end-to-end and are pinned at the helper only. This ambient
    /// redirection makes both observable THROUGH the reaction without changing
    /// `runUidValidityResetReaction`'s signature or any production behaviour: it is
    /// `nil` in production, compiled out of release entirely, and consulted only when
    /// the caller passed no explicit override.
    ///
    /// `Mutex` rather than `nonisolated(unsafe)` (iOS resilience rule 5).
    static let purgeStagingPathOverrideForTesting = Mutex<String?>(nil)

    /// Forces App-Group container resolution to report failure, making the "we could
    /// not LOOK" branch of `stagingPurgeTarget` reachable from tests. Without it that
    /// branch has no coverage at all: the unit tests run inside the TabMail host app,
    /// which carries the `group.ai.tabmail` entitlement, so the real
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` always resolves in the
    /// simulator and the nil case can never be observed.
    ///
    /// **Defaulted to the SAFE direction on purpose.** `false` means "use the real
    /// resolution", and only an explicit `true` simulates the failure — so a dropped
    /// or forgotten injection yields exactly production behaviour, never a silently
    /// weakened guard. (A seam whose default is the permissive value is
    /// fail-DANGEROUS; this one fails toward production.)
    ///
    /// `Mutex` rather than `nonisolated(unsafe)` (iOS resilience rule 5).
    static let simulateUnresolvableStagingContainerForTesting = Mutex<Bool>(false)
    #endif

    /// What a purge has to work with. The three cases exist because "there is
    /// nothing to purge" and "there is something and we cannot reach it" are
    /// OPPOSITE answers to the caller's question, and the old `DatabaseQueue?`
    /// collapsed them into one `nil` (audit round 1 / C-4).
    private enum StagingPurgeTarget {
        /// Open. The DELETE decides.
        case queue(DatabaseQueue)
        /// No staging FILE at a container we could actually resolve: nothing was ever
        /// staged, so a purge over it is vacuously COMPLETE. This is a POSITIVE
        /// observation — we looked in the right place and found nothing.
        case nothingStaged
        /// We could not READ the staging state: a staging file exists but will not
        /// open, or the App Group container itself could not be resolved so there was
        /// no place to look. Its contents are unknown, which is a FAILURE — never a
        /// silent success.
        case unreachable
    }

    /// The App-Group container the staging file lives in, or `nil` when it cannot be
    /// resolved. Extracted so the unresolvable case is reachable under test; the
    /// DISPOSITION of a nil result is decided by the caller, not here, so the mapping
    /// that matters stays under test rather than being short-circuited by the seam.
    private static func stagingContainerURL() -> URL? {
        #if DEBUG
        if simulateUnresolvableStagingContainerForTesting.withLock({ $0 }) { return nil }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    /// Shared resolution for the two purge helpers above — an explicit override
    /// path (tests), the DEBUG ambient override, or the real App-Group staging file.
    private static func stagingPurgeTarget(stagingPathOverride: String?) -> StagingPurgeTarget {
        var explicitPath = stagingPathOverride
        #if DEBUG
        if explicitPath == nil {
            explicitPath = purgeStagingPathOverrideForTesting.withLock { $0 }
        }
        #endif
        if let explicitPath {
            guard FileManager.default.fileExists(atPath: explicitPath) else { return .nothingStaged }
            guard let queue = try? DatabaseQueue(path: explicitPath) else { return .unreachable }
            return .queue(queue)
        }
        // 🚨 AUDIT ROUND 2 — was `.nothingStaged`, which is the exact conflation the
        // enclosing commit (`209a55cdf`) exists to forbid: a nil container is "we could
        // not LOOK", not "there was nothing there". The NSE runs as its own process with
        // its own entitlements, so it may well have staged rows into a container this
        // process cannot currently resolve; reporting that as a completed purge lets
        // `runUidValidityResetReaction` advance the durable epoch over staged state it
        // never read. The sibling condition one line down — a file that exists but will
        // not open — already returns `.unreachable`; both are the same question ("can we
        // read the staged state?") with the same answer ("no"), so they get the same
        // disposition. Only the POSITIVE observation "we resolved the container and there
        // is no staging file" may report nothing-staged.
        guard let containerURL = stagingContainerURL() else { return .unreachable }
        let stagingPath = containerURL.appendingPathComponent("nse_staging.sqlite").path
        guard FileManager.default.fileExists(atPath: stagingPath) else { return .nothingStaged }
        guard let queue = openStagingDB() else { return .unreachable }
        return .queue(queue)
    }

    // NOTE (2026-07-07): a `readStagedForDisplay` direct staging-FILE read for the
    // notification-tap path existed here briefly and was REMOVED: consumers reading
    // the file directly RACE the merge's in-memory snapshot publish
    // (`latestStagedRows`/`latestStagedBodies`), resolving ids before the snapshot
    // exists and starving every downstream snapshot consumer (header seed,
    // mark-read, staged body). The contract is: the merge is the snapshot's ONLY
    // publisher; consumers read the snapshot (or react to `.messagesStaged`).

    /// Public entry point. The NSE→inbox merge is a PRIVILEGED, single-threaded
    /// step of the boot / foreground sequence — it must run ALONE (no concurrent
    /// sibling merge fighting the staging-DB busy lock, and ideally ahead of the
    /// sync/backfill/AI herd contending for the GRDB writer) and FULLY complete
    /// before the rest of the herd starts. All six call sites (deep-link tap,
    /// foreground outer, `syncStartup` step-0, foreground-push `willPresent`,
    /// silent push, AI queue) funnel through `NSEMergeCoordinator` so they
    /// serialize into one in-flight run instead of each opening the staging DB
    /// and waiting out the 2s/5s `busyMode` timeout behind the others.
    static func mergeNSEStagingData(
        stagingPathOverride: String? = nil,
        onSnapshotPublished: (@Sendable () -> Void)? = nil
    ) async {
        await NSEMergeCoordinator.shared.merge(
            stagingPathOverride: stagingPathOverride,
            onSnapshotPublished: onSnapshotPublished
        )
    }

    // MARK: - Stage-memo skip (redundant re-merge elimination)
    //
    // Every merge TRIGGER — a push for a different message, syncStartup,
    // foreground, a notif-tap gate — re-reads the FULL staged set, including
    // rows deliberately KEPT (a GRADUAL row, `aiCompleted=0`, still being
    // computed by the NSE). Without a way to tell "unchanged since we last
    // durably wrote it" apart from "just arrived", every one of those triggers
    // redid BOTH write phases for every kept row — even when nothing about it
    // had changed (observed: 982 merge runs in one session; one message's body
    // written 36 times; 80 no-op merges still each held the GRDB writer
    // 20ms–4s, 16.5s total, during the most write-contended windows).
    //
    // The fix: a per-row content signature (`StageKey`) plus an in-process memo
    // of the signature each staging row's content last reached AND had durably
    // written (`stageMemo`). A row whose current signature matches the memo AND
    // whose durable rows verify present is skipped entirely by `performMerge` —
    // no GRDB write, no FTS work, no render signal. A row that advanced (new
    // body / summary / action / notified flip / aiCompleted) or whose durable
    // rows went missing (a sync stale-delete raced it) still gets the full,
    // real write.

    /// Per-row content signature of a staged message. Every phase-2 write this
    /// merge performs when a stage independently ARRIVES must be represented
    /// here — otherwise that arrival would be silently skipped by the memo.
    /// Deliberately PRESENCE-only (not the raw values): the NSE stages each
    /// field exactly once (`NSEStagingDB.stageHeader`/`stageBody`/`stageSummary`/
    /// the terminal `persistProcessedMessage` never re-stage a CHANGED value for
    /// the same row — see `StagedMessage`'s "keep in sync" contract below), so
    /// "did this presence flip since we last wrote?" is equivalent to "did the
    /// content change?".
    struct StageKey: Hashable, Sendable {
        /// `persistRenderedBodyFromStaging` fires whenever either is non-nil.
        let hasBody: Bool
        /// The value-guarded summary/reminder UPDATE fires whenever any of the
        /// five summary/reminder fields is non-nil.
        let hasSummary: Bool
        /// The value-guarded action UPDATE (+ `tagSortOrder`, +
        /// `queueSetTagPendingOp`) fires whenever `actionTag` is non-nil.
        let hasAction: Bool
        /// The `notified`-only UPDATE (the `else if msg.notified` branch) can
        /// flip independently of `hasAction` — must be tracked separately or
        /// that flip is silently skipped once the other fields are memo-stable.
        let notified: Bool
        /// Gates the `messageAICache` UPSERT independently of `hasSummary`/
        /// `hasAction` — the NSE stages the summary BEFORE the terminal action
        /// vote, so `hasSummary` can be true while `aiCompleted` is still false.
        let aiCompleted: Bool
    }

    /// Compute a row's current `StageKey` from its staged content. Internal
    /// (not `private`) so `TabMailTests` can compute the EXPECTED key directly
    /// instead of re-deriving the write conditions by hand.
    static func stageKey(for msg: StagedMessage) -> StageKey {
        StageKey(
            hasBody: msg.htmlContent != nil || msg.textContent != nil,
            hasSummary: msg.summaryBlurb != nil || msg.summaryTodos != nil
                || msg.reminderDate != nil || msg.reminderTime != nil || msg.reminderContent != nil,
            hasAction: msg.actionTag != nil,
            notified: msg.notified,
            aiCompleted: msg.aiCompleted
        )
    }

    /// In-process memo of the `StageKey` each staging row's content last
    /// reached AND had durably written to main GRDB, keyed by the staging
    /// row's stable identity (`StagedMessage.id`, i.e. `"accountId:messageId"`
    /// — the same id `NSEStagingDB` uses for every stage write, so it's stable
    /// for the row's entire staging lifetime). In-process only by design (no
    /// App Group persistence): a relaunch just costs one redundant — but fully
    /// idempotent — re-merge of whatever's still staged, the existing fallback
    /// behavior for every other cache in this file (`lastMergedStagingSignature`,
    /// `lastPostedStagedRows`, the staging-probe connection cache).
    private static let stageMemo = Mutex<[String: StageKey]>([:])

    /// Splits `processed` into rows whose staged content ADVANCED since the
    /// last durable merge (`writeSet` — phase 1 + phase 2 run for these) and
    /// rows that are memo-identical AND durability-VERIFIED (`skipSet` — their
    /// write phases are skipped entirely). A memo HIT that fails verification
    /// (its durable `messageHeader` — or, if it staged a body, `MessageBody` —
    /// row is gone, e.g. a sync stale-delete raced it) is NOT trusted: it's
    /// treated as advanced (re-merged for real) and its stale memo entry
    /// dropped, so a deleted durable row self-heals instead of staying
    /// invisible until staging drains. Load-bearing — see `verifyDurable`.
    private static func partitionByStageMemo(
        _ processed: [StagedMessage]
    ) async -> (writeSet: [StagedMessage], skipSet: [StagedMessage]) {
        guard !processed.isEmpty else { return ([], []) }
        let memoSnapshot = stageMemo.withLock { $0 }
        var writeSet: [StagedMessage] = []
        var candidates: [StagedMessage] = []
        for msg in processed {
            if memoSnapshot[msg.id] == Self.stageKey(for: msg) {
                candidates.append(msg)
            } else {
                writeSet.append(msg)
            }
        }
        guard !candidates.isEmpty else { return (writeSet, []) }
        let durableIds = await verifyDurable(candidates)
        var skipSet: [StagedMessage] = []
        for msg in candidates {
            if durableIds.contains(msg.id) {
                skipSet.append(msg)
            } else {
                _ = stageMemo.withLock { $0.removeValue(forKey: msg.id) }
                writeSet.append(msg)
            }
        }
        return (writeSet, skipSet)
    }

    /// Durability verification for stage-memo candidates: confirms the durable
    /// GRDB rows the memo assumes still exist, so a skip can never mask a row
    /// that vanished out from under it (e.g. a sync stale-delete). ONE
    /// `rawPool.read` for the WHOLE candidate batch (not N round trips) — cheap
    /// even for a large kept set. Same account-scoped lookup phase 1/phase 2
    /// use (messageId, then rfc822 fallback for IMAP UID remaps). Uses
    /// `AppDatabase.rawPool` (not `.dbPool`) deliberately: this runs from
    /// inside the merge itself (`PriorityGate.privileged`), so going through
    /// `PrioritizedDatabase.read` would re-enter the read-through-merge check
    /// for no benefit (its recursion guard would no-op it anyway) — the raw
    /// pool is the direct, minimal path. Returns the subset of `candidates`
    /// (by `.id`) that verified durable.
    private static func verifyDurable(_ candidates: [StagedMessage]) async -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        return (try? await AppDatabase.rawPool.read { db -> Set<String> in
            var durable: Set<String> = []
            for msg in candidates {
                guard let ref = try DurableIdentityLookup.find(
                    db: db, accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId,
                    rfc822MessageId: msg.rfc822MessageId
                ) else { continue }
                if msg.htmlContent != nil || msg.textContent != nil {
                    let hasBody = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM messageBody WHERE id = ?)
                        """, arguments: [ref.id]) ?? false
                    guard hasBody else { continue }
                }
                durable.insert(msg.id)
            }
            return durable
        }) ?? []
    }

    /// One staged row found STALE-BY-MOVE by `detectStaleByMoveRows`. `id` is
    /// the STAGING row's identity (`StagedMessage.id`) — used to filter
    /// `processed` and delete the staging row. `headerId` is the STAGED row's
    /// headerId (`MessageIdentity.headerId` over the staged accountId/
    /// folderPath/messageId — identical to `toInboxRow().headerId`) — used to
    /// filter `latestStagedRows`/`latestStagedBodies`. NOT the durable row's
    /// id: after an IMAP UID-remap move (archive = MOVE = new UID) the durable
    /// header is found via the rfc822 fallback under a DIFFERENT id, while the
    /// published snapshot entries are keyed by the staged id — a durable-id
    /// filter would miss them.
    struct StaleByMoveRow: Equatable, Sendable {
        let id: String
        let headerId: String
    }

    /// Batch staleness check, extracted for unit testing (see
    /// `NSEDataBridge.performMerge`'s STALE-BY-MOVE DETECTION section for the
    /// full rationale). For every staged row, resolves the existing durable
    /// header using the SAME identity lookup phase 1/phase 2 use (provider
    /// `messageId` first, then `rfc822MessageId` fallback for IMAP UID
    /// remaps) and compares its CURRENT `folderId`/`isInInbox` against the
    /// staged row's folder. A row is STALE-BY-MOVE when a durable header
    /// EXISTS and disagrees (`folderId` mismatch OR `isInInbox == false`) —
    /// the durable message was moved/archived/deleted out of the staged
    /// folder after the push was captured. No durable header at all is NOT
    /// stale (an ordinary new message). ONE `rawPool.read` for the whole
    /// batch — same shape as `verifyDurable`, cheap even for a large staged
    /// set. `AppDatabase.rawPool` (not `.dbPool`) for the same reason
    /// `verifyDurable` uses it: this runs from inside the privileged merge, so
    /// `PrioritizedDatabase.read` would just re-enter (and no-op) the
    /// read-through-merge recursion guard for no benefit.
    static func detectStaleByMoveRows(_ processed: [StagedMessage]) async -> [StaleByMoveRow] {
        guard !processed.isEmpty else { return [] }
        return (try? await AppDatabase.rawPool.read { db -> [StaleByMoveRow] in
            var stale: [StaleByMoveRow] = []
            for msg in processed {
                guard let ref = try DurableIdentityLookup.find(
                    db: db, accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId,
                    rfc822MessageId: msg.rfc822MessageId
                ) else { continue } // no durable header yet — an ordinary new message, not stale
                let stagedFolderId = MessageIdentity.folderId(accountId: msg.accountId, folderPath: msg.folderPath)
                if ref.folderId != stagedFolderId || !ref.isInInbox {
                    // STAGED headerId, not the durable row's id — see StaleByMoveRow doc.
                    stale.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                        accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                    )))
                }
            }
            return stale
        }) ?? []
    }

    // MARK: - Stale-by-EPOCH (T5.10 merge half — ADR-IOS-061)
    //
    // The NSE stages a row keyed by a MAILBOX-LOCAL UID (`messageId`). If the
    // folder's UIDVALIDITY turns over between staging and merge, that UID names a
    // DIFFERENT physical message — and `DurableIdentityLookup.find`'s STEP 1
    // (exact-folder `(accountId, folderPath, messageId)`) has no RFC check and no
    // epoch input at all, so it happily returns the new occupant. Merging onto it
    // writes this notification's body/summary/action/notified flag onto a message
    // that is not the one the notification was about: a direct C3 violation.
    //
    // Step 2 (folder-blind) already rejects a POSITIVE RFC disagreement, and step 3
    // is rfc-equality — so the hole this closes is specifically step 1, plus the
    // rfc-nil tail of step 2. Nothing else on v3 compares a staged row's epoch to
    // its folder's.

    /// The staged row's epoch disposition against its folder's CURRENT state,
    /// callable from INSIDE a write transaction. `cache` is a per-TXN memo (a fresh
    /// dictionary per call site) so repeat rows in one folder cost a single
    /// `Folder.fetchOne` for the whole pass.
    ///
    /// PORT of `v2final`'s `NSEDataBridge.uidValidityStagingRowStatus` (commit
    /// `4d34ee864`), MINUS its `processedAt < lastUidValidityResetAt` wall-clock
    /// proxy — SUBTRACT: v3's `Folder` has no `lastUidValidityResetAt` column at
    /// all. It was deliberately not ported (see `Folder.uidValidityResetPendingAt`'s
    /// doc: "its sole purpose there is to be the monotonic authority sidecar
    /// producers compare against, and v3 has no such producer"), so the premise of
    /// that proxy is absent, not merely unused. What remains is the reference's
    /// SECOND, timing-immune signal, which is the stronger one anyway: it compares
    /// EPOCHS directly and never wall-clock order.
    ///
    /// Returns both signals because callers treat them differently:
    ///  - `isOldEpoch` (ARM 1) — the row's observed epoch POSITIVELY disagrees with
    ///    the folder's stored epoch while the folder is settled. Permanently stale:
    ///    `observedUidValidity` is immutable staged data, so no retry can ever make
    ///    it agree. Skipped AND deleted.
    ///  - `isQuarantined` (ARM 2) — the folder is mid-reaction
    ///    (`uidValidityResetPendingAt != nil`). KEPT for retry, NEVER deleted: while
    ///    quarantined the STORED epoch is by construction still the OLD one (the
    ///    reaction does not advance it until step 5, `uidValidityResetStampFreshEpoch`),
    ///    so a mismatch here cannot yet distinguish "permanently stale" from
    ///    "correctly observed the NEW epoch ahead of our own stamp". Deleting on
    ///    that would be a never-drop violation the instant the stamp lands. Hence
    ///    the `!entry.isQuarantined` term inside `isOldEpoch`: during quarantine the
    ///    row is skipped by the caller's own `isQuarantined` guard and re-evaluated
    ///    next wake, when the stamp has settled and the comparison is decisive.
    ///
    /// Fails open (neither signal) when EITHER epoch is `nil` — an unobserved epoch
    /// (Gmail/Graph, pre-upgrade rows) or a folder that never recorded one. That
    /// tail is not left uncovered: on the EXISTING-durable-row arm it is caught by
    /// `nseMergeIdentityConfirmed` instead.
    ///
    /// TRI-STATE FOLDER READ (PORT of the reference's Finding-1). A read FAILURE
    /// (transient `SQLITE_INTERRUPT`, decode error) must NOT collapse to "not
    /// quarantined" — that would let a genuinely quarantined row merge, or be
    /// skip-DELETED, on an absence of evidence. An unknown folder state is treated
    /// as QUARANTINED so the caller KEEPS the row for the next pass, and the failure
    /// is deliberately NOT cached (a later row in the same folder re-reads and may
    /// succeed). A successful read returning `nil` (folder genuinely absent) keeps
    /// the pre-existing not-quarantined behaviour.
    static func uidValidityStagingRowStatus(
        msg: StagedMessage,
        cache: inout [String: (isQuarantined: Bool, lastKnownUidValidity: Int?)],
        db: Database
    ) -> (isQuarantined: Bool, isOldEpoch: Bool) {
        let folderId = MessageIdentity.folderId(accountId: msg.accountId, folderPath: msg.folderPath)
        let entry: (isQuarantined: Bool, lastKnownUidValidity: Int?)
        if let cached = cache[folderId] {
            entry = cached
        } else {
            let folder: Folder?
            do {
                folder = try Folder.fetchOne(db, key: folderId)
            } catch {
                return (isQuarantined: true, isOldEpoch: false)
            }
            entry = (
                isQuarantined: folder?.uidValidityResetPendingAt != nil,
                lastKnownUidValidity: folder?.lastKnownUidValidity
            )
            cache[folderId] = entry
        }
        let isOldEpoch: Bool = {
            guard let observed = msg.observedUidValidity,
                  let stored = entry.lastKnownUidValidity,
                  observed != stored
            else { return false }
            // ARM 2 wins over ARM 1 while the reaction is in flight — see above.
            return !entry.isQuarantined
        }()
        return (entry.isQuarantined, isOldEpoch)
    }

    /// May this staged row's content be written ONTO the durable row currently
    /// occupying its composite key? Returns `true` ONLY on POSITIVE evidence, never
    /// on absence of contradiction.
    ///
    /// PORT of `v2final`'s `NSEDataBridge.nseMergeIdentityConfirmed` (commit
    /// `4d34ee864`) — its (a) RFC / (b) epoch semantics exactly. SUBTRACT: the
    /// reference delegates to `MessageIdentity.fetchedContentIdentityConfirmed`,
    /// which does NOT exist on v3 (no such symbol tree-wide), so the two doors are
    /// expressed directly here. The RFC normalization goes through v3's
    /// `MessageIdentity.comparableRfc822Identity` — deliberately NOT
    /// `usableRfc822Tail`, whose extra `':'` rejection exists for key MINTING and
    /// would answer "never the same message" for a legitimate `no-fold-literal`
    /// domain.
    ///
    /// ⚠ THIS SAID "the tree's SINGLE identity-COMPARISON normalizer" until
    /// R13-U8, and it is not: `SyncEngineEpochVerify` compares identities through
    /// `EmailFilter.normalizeMessageId` directly, at three sites (sample capture,
    /// the server-side map, and the durable re-read). The two are not
    /// interchangeable and neither is wrong — `comparableRfc822Identity` IS
    /// `normalizeMessageId` plus REJECTION (embedded CR/LF, unbalanced angle
    /// brackets, residual whitespace/controls, an empty result), so it answers
    /// `nil` — "no usable identity" — where the raw normalizer answers a string.
    /// Epoch verification wants the raw form because it has already discarded
    /// empties itself and is comparing two values it read from the same wire; the
    /// identity doors here want the rejecting form because a malformed value must
    /// not be allowed to CONFIRM anything. Do not "unify" them without deciding
    /// which side of that asymmetry each caller needs.
    ///
    /// Confirmed when EITHER:
    ///  (a) RFC MATCH — both sides' normalized RFC Message-IDs are present and
    ///      EQUAL. Present-and-DISAGREE ⇒ NOT confirmed, and RFC disagreement WINS
    ///      even when the epochs agree (evaluated first, unconditionally).
    ///  (b) EPOCH CONFIRMED (the rfc-less door) — the durable row lives in the SAME
    ///      folder the staged message was observed in, AND the staged
    ///      `observedUidValidity` and that folder's `lastKnownUidValidity` are both
    ///      present and EQUAL and the folder is NOT quarantined ⇒ the UID is
    ///      provably meaningful under the folder's CURRENT epoch.
    ///
    /// Anything else — rfc unusable on either side AND no epoch agreement — is NOT
    /// confirmed. Provider-blind by design: Gmail/Graph rows leave
    /// `observedUidValidity` nil but always carry an RFC, so they confirm through
    /// (a); the only population this refuses is the rfc-less IMAP/iCloud row with no
    /// epoch baseline.
    ///
    /// ⚠️ WHY DOOR (b) IS FOLDER-SCOPED AND DOOR (a) IS NOT (R11-A audit, 2026-08-06).
    /// `DurableIdentityLookup.find` step 2 is folder-BLIND, so `existingFolderId` may
    /// name a different folder than the staged message's. Door (b)'s only evidence is
    /// a UID that agrees with an epoch — and on IMAP a UID is folder-scoped, so Inbox
    /// UID 7 and Archive UID 7 are routinely different messages. The staged
    /// `observedUidValidity` is the STAGED folder's numbering, and neither folder's
    /// stored epoch says anything about the other's: comparing across folders is not
    /// weak evidence, it is evidence about the wrong thing, and blessing it stamps a
    /// foreign body + `bodyComplete` + AI cache onto the wrong message (C3
    /// misattribution, the non-recoverable set).
    ///
    /// Door (a) deliberately stays cross-folder: an RFC 822 Message-ID is a global
    /// identity, and a Gmail/Graph row that moved folders between the NSE fetch and
    /// the merge MUST still resolve to its durable row — folder-scoping the RFC door
    /// would re-open the duplicate-header class it exists to close. Failing door (b)
    /// closed only costs a skipped NSE merge; ordinary sync performs it later.
    ///
    /// The lookup's own breadth is NOT narrowed here on purpose: its retention on an
    /// absent RFC is documented as "a deliberately conservative default that preserves
    /// today's behavior when there's no evidence to reject it", and every consumer —
    /// including the two `isSameLogicalMessage` inbox call sites — depends on it.
    static func nseMergeIdentityConfirmed(
        msg: StagedMessage, existingRfc: String?, existingFolderId: String,
        folderEpoch: Int?, folderQuarantined: Bool
    ) -> Bool {
        // (a) RFC door — unconditional and first: a positive disagreement is proof
        // of two different messages and no epoch agreement may override it.
        if let stagedRfc = MessageIdentity.comparableRfc822Identity(msg.rfc822MessageId),
           let durableRfc = MessageIdentity.comparableRfc822Identity(existingRfc) {
            return stagedRfc == durableRfc
        }
        // (b) Epoch door — only for rows the RFC door could not adjudicate, and only
        // when the durable row is in the folder the epoch was observed in.
        let stagedFolderId = MessageIdentity.folderId(
            accountId: msg.accountId, folderPath: msg.folderPath)
        guard existingFolderId == stagedFolderId,
              !folderQuarantined,
              let observed = msg.observedUidValidity,
              let stored = folderEpoch
        else { return false }
        return observed == stored
    }

    /// Pre-transaction ARM-1 sweep: the staged rows whose observed epoch positively
    /// disagrees with their folder's settled epoch. PORT of `v2final`'s
    /// `NSEDataBridge.detectOldEpochStagedRows` (commit `4d34ee864`), delegating the
    /// per-row decision to `uidValidityStagingRowStatus` — the SINGLE disposition
    /// this pass and the in-txn re-checks both consult, so they cannot drift.
    ///
    /// ⚑ THIS PASS IS NOT THE GUARD. It runs before `partitionByStageMemo` so an
    /// old-epoch row never enters `writeSet`/`skipSet` (a `skipSet` row reaches
    /// NEITHER write transaction, so only this pass can catch that one) — but it is
    /// TOCTOU-open on its own: a reset completing between this read and the write
    /// transactions would slip past. The actual guard is the per-row
    /// `uidValidityStagingRowStatus` call INSIDE each phase's write closure.
    ///
    /// Reuses `StaleByMoveRow` — same shape (staging-row id + STAGED headerId), same
    /// skip-and-delete contract.
    static func detectOldEpochStagedRows(_ processed: [StagedMessage]) async -> [StaleByMoveRow] {
        guard !processed.isEmpty else { return [] }
        return (try? await AppDatabase.rawPool.read { db -> [StaleByMoveRow] in
            var stale: [StaleByMoveRow] = []
            var cache: [String: (isQuarantined: Bool, lastKnownUidValidity: Int?)] = [:]
            for msg in processed {
                let (_, isOldEpoch) = uidValidityStagingRowStatus(msg: msg, cache: &cache, db: db)
                guard isOldEpoch else { continue }
                stale.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                    accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                )))
            }
            return stale
        }) ?? []
    }

    /// Shared skip-and-delete cleanup for epoch-stale / identity-unconfirmed staged
    /// rows: deletes them from `nse_processed_message` and scrubs them out of the
    /// already-published in-memory snapshots + the stage memo. PORT of `v2final`'s
    /// `NSEDataBridge.applyOldEpochStagingCleanup` (commit `4d34ee864`). Called by
    /// the pre-txn pass AND by phase 1/2's in-txn discoveries, so every disposition
    /// that drops a row drops it the same way.
    ///
    /// The staging delete is idempotent — a failure just leaves the row for the next
    /// wake, which re-evaluates and re-drops it.
    static func applyOldEpochStagingCleanup(_ rows: [StaleByMoveRow], nseDB: DatabaseQueue) async {
        guard !rows.isEmpty else { return }
        let stagingIds = Set(rows.map(\.id))
        let headerIds = Set(rows.map(\.headerId))
        do {
            try await nseDB.write { db in
                for id in stagingIds {
                    try db.execute(sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: [id])
                }
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                print("[NSEDataBridge] Old-epoch staged row delete failed: \(error) — retried next wake (idempotent)")
            }
        }
        latestStagedRows.withLock { rowsBox in
            rowsBox.removeAll { headerIds.contains($0.headerId) }
        }
        latestStagedBodies.withLock { bodies in
            for hid in headerIds { bodies.removeValue(forKey: hid) }
        }
        stageMemo.withLock { memo in
            for id in stagingIds { memo.removeValue(forKey: id) }
        }
    }

    /// Thrown from inside a phase-1/phase-2 per-message savepoint when
    /// `nseMergeIdentityConfirmed` refuses the EXISTING durable row (ARM 3). Rolls
    /// the savepoint back — so NOTHING of this staged row's content lands on a row
    /// it cannot claim — and routes to the same skip-and-delete disposition as an
    /// ARM-1 discovery rather than the ordinary "left in staging for retry" path.
    /// PORT of `v2final`'s `NSEDataBridge.NSERfcMismatchDiscovered`.
    ///
    /// ⚑ DELIBERATE DEVIATION, and it is why this carries NO payload where the
    /// reference's carries the durable `headerId`: `v2final` builds the resulting
    /// `StaleByMoveRow` from the DURABLE row's id, but every consumer of
    /// `StaleByMoveRow.headerId` (`applyOldEpochStagingCleanup`'s `latestStagedRows`
    /// / `latestStagedBodies` scrub) keys off the STAGED headerId —
    /// `StaleByMoveRow`'s own doc comment says so explicitly ("NOT the durable row's
    /// id"). The two coincide for a `DurableIdentityLookup.find` STEP-1 hit and
    /// diverge for a step-2 rfc-nil hit, where the reference's scrub would silently
    /// miss the published phantom. The staged headerId is therefore rebuilt at the
    /// catch site, and the durable id — needed only for the diagnostic — is logged
    /// at the throw site, where it is already in hand.
    private struct NSERfcMismatchDiscovered: Error {}

    /// Test-only seam: reset the process-global stage memo between tests so
    /// state can't leak across cases. Internal (not `#if DEBUG`) — same
    /// visibility as the other hoisted test seams in this file
    /// (`insertNewHeaderFromStaging`, etc.), reachable from `TabMailTests` via
    /// `@testable import`.
    static func resetStageMemoForTesting() {
        stageMemo.withLock { $0 = [:] }
    }

    /// Test-only seam: snapshot the current memo contents, so tests can assert
    /// the skip/record/drop behavior directly instead of only inferring it
    /// from render signals.
    static func stageMemoSnapshotForTesting() -> [String: StageKey] {
        stageMemo.withLock { $0 }
    }

    /// The actual merge work. NEVER call directly — go through
    /// `mergeNSEStagingData` so the coordinator's serialization holds. (Only the
    /// coordinator calls this.)
    static func performMerge(
        stagingPathOverride: String? = nil,
        onSnapshotPublished: (@Sendable () -> Void)? = nil
    ) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        print("[NSEDataBridge] mergeNSEStagingData: START")
        BootProfiler.mark("mergeNSEStagingData START")

        // Production reads the App Group staging DB. Tests inject a path: the
        // unit-test host has no app-group entitlement, so `containerURL` returns
        // nil and the real merge would otherwise bail before exercising anything.
        let stagingPath: String
        if let stagingPathOverride {
            stagingPath = stagingPathOverride
        } else {
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId
            ) else {
                print("[NSEDataBridge] mergeNSEStagingData: no app group container")
                return
            }
            stagingPath = containerURL.appendingPathComponent("nse_staging.sqlite").path
        }
        guard FileManager.default.fileExists(atPath: stagingPath) else {
            print("[NSEDataBridge] mergeNSEStagingData: no staging DB file — nothing to merge")
            return
        }

        // Retry opening the staging DB with increasing timeouts.
        // The NSE may be actively writing — wait rather than silently skip.
        var nseDB: DatabaseQueue?
        for timeout in [2.0, 5.0] {
            var config = Configuration()
            config.busyMode = .timeout(timeout)
            // 0xdead10cc defense (ADR-IOS-041) — see openStagingDB().
            config.observesSuspensionNotifications = true
            if let db = try? DatabaseQueue(path: stagingPath, configuration: config) {
                nseDB = db
                break
            }
            print("[NSEDataBridge] Staging DB busy, retrying with \(timeout)s timeout")
        }
        guard let nseDB else {
            print("[NSEDataBridge] Staging DB locked after retries — merge deferred to next wake")
            return
        }

        // Track whether any merge step mutated main GRDB. Drives whether we
        // bother recomputing the badge at the end.
        var didMutate = false
        // Track whether anything changed AFTER phase 1's header render — i.e. in
        // phase 2 (body/AI), inbox removals, or task results. Gates the SECOND
        // (end-of-merge) `.inboxDataDidChange` so a re-merge that changes nothing
        // past the header doesn't fire a redundant reload. Phase 1's own render is
        // gated separately on headers becoming newly visible.
        var endOfMergeChanged = false
        // F1 (PLAN_INBOX_UNIFIED_READ.md audit): set true when the stale-by-move
        // scrub below removes rows the pre-detection `.messagesStaged` post
        // already published. If the rest of this wake does no durable work
        // (`endOfMergeChanged` stays false), there is otherwise NO eviction
        // trigger for a phantom row the VM may have inserted from that post —
        // drives the scrub-only-wake `else if` branch at the end-of-merge
        // signal site below.
        var scrubbedStaleStagedRows = false

        // Age window after which a still-incomplete (populated=1, aiCompleted=0)
        // GRADUAL staging row is treated as abandoned — its NSE died before
        // finishing AI. By then the header+body have been merged (durable in main
        // GRDB) and the main-app AI queue will finish the AI, so the staging row is
        // deleted. The same window reaps populated=0 lease placeholders at the end.
        // NSE has a ~30s OS budget; 60s is well past it.
        let staleStagingWindowSeconds: TimeInterval = 60
        let abandonedCutoff = Date().timeIntervalSince1970 - staleStagingWindowSeconds

        // 1. Read all NSE-processed messages — only `populated=1` rows. Lease
        // placeholders from AIOwnershipLease.ensureRow keep populated=0 and
        // are invisible to merge until the orphan reap deletes them on age.
        // (StagedMessage hoisted to type-level — see bottom of file — so tests
        // can construct it and drive `insertNewHeaderFromStaging` against an
        // in-memory GRDB without going through the App Group staging file.)

        // Explicit do/catch on the staging read — log on failure, continue
        // with an empty `processed`. The helper sub-paths
        // (`mergeInboxRemovals`, `consumePendingTaskResults`, orphan reap)
        // read different tables and may still succeed; failed rows in
        // `nse_processed_message` simply stay in staging and retry next wake.
        // `var` — the STALE-BY-MOVE check below reassigns it to exclude stale
        // rows from everything that follows (stage-memo partition, phase 1/2).
        var processed: [StagedMessage]
        do {
            processed = try await nseDB.read { db in
                // Row→StagedMessage decode is the SINGLE SOURCE OF TRUTH in
                // `StagedMessage(row:)` — a column change lands in ONE place.
                try Row.fetchAll(db, sql: "SELECT * FROM nse_processed_message WHERE populated = 1")
                    .map { StagedMessage(row: $0) }
            }
        } catch {
            // Log + fall through with empty `processed`. The helpers below
            // read different tables and may still succeed; the unread
            // populated rows stay in staging and retry next wake.
            print("[NSEDataBridge] mergeNSEStagingData: populated read failed: \(error) — skipping main loop, helpers continue")
            processed = []
        }

        let aiCount = processed.filter { $0.aiCompleted }.count
        print("[NSEDataBridge] mergeNSEStagingData: found \(processed.count) staged message(s) (\(aiCount) with AI)")
        BootProfiler.mark("mergeNSEStagingData: found \(processed.count) staged (\(aiCount) AI-complete)")

        // ADR-IOS-049: hand the just-read staged rows to the inbox NOW — before the
        // (resume-time-slow) phase-1 durable write — so the list renders them
        // IN-MEMORY (`InboxViewModel.insertStagedRows`) instead of gating on the
        // write. Separate signal from `.inboxDataDidChange` (doesn't touch its
        // 2-post contract); the VM dedups against `loadedIds`, so re-posting the
        // same rows on a no-op re-merge inserts nothing. Body/badge unaffected.
        // `toInboxRow()` is the SINGLE StagedMessage→row builder.
        let stagedRows = processed.map { $0.toInboxRow() }
        // Replace-all snapshot for the non-render fallbacks (notification deep-link
        // resolution, MessageDetailViewModel synthesis). Updated on EVERY merge —
        // including empty (drained staging clears it). Serialized by the merge
        // coordinator, so this always reflects the last-read staging content.
        latestStagedRows.withLock { $0 = stagedRows }
        // Companion body snapshot (same replace-all lifecycle): lets a
        // notification-tap render the staged body IMMEDIATELY instead of waiting
        // for phase-2's durable write / the 2s body-poll / a network re-fetch.
        // Unresolved-CID bodies excluded (`toBodySnapshot()` returns nil) — the
        // app must re-render those.
        let stagedBodies: [String: StagedBodySnapshot] = processed.reduce(into: [:]) { acc, msg in
            guard let snap = msg.toBodySnapshot() else { return }
            acc[MessageIdentity.headerId(
                accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
            )] = snap
        }
        latestStagedBodies.withLock { $0 = stagedBodies }
        // RE-POST suppression: a KEPT gradual row (ADR-IOS-047, NSE still computing
        // AI) survives the merge, so every re-merge re-read the SAME staged set and
        // re-posted it (observed ~5s cadence for 43+s while NSE AI ran) — each post
        // re-runs the VM's insert/dedup pass for nothing. Post only when the staged
        // set CHANGED since the last post (pure in-memory equality, order-normalized
        // by headerId — deliberately NOT a DB read: the pre-write `surfacesNew` read
        // was tried once and reverted). Replace-all like `latestStagedRows`, so a
        // drained set resets the memo and a future re-stage posts again.
        let setChanged = Self.stagedSetChangedSinceLastPost(stagedRows, memo: lastPostedStagedRows)
        if !stagedRows.isEmpty {
            if setChanged {
                BootProfiler.mark("merge: posted .messagesStaged (\(stagedRows.count) row(s)) — inbox renders IN-MEMORY pre-write")
                Task { @MainActor in
                    NotificationCenter.default.post(name: .messagesStaged, object: stagedRows)
                }
            } else {
                BootProfiler.mark("merge: .messagesStaged suppressed — staged set unchanged (\(stagedRows.count) row(s))")
            }
        }
        // Paint-gate callback (`mergeIfStagingPendingPaintGate`): everything the
        // first frame needs is now in memory — `latestStagedRows` /
        // `latestStagedBodies` replaced and the `.messagesStaged` post queued.
        // Fires BEFORE phase-1's durable write, the proven-slow part on cold I/O
        // (7.6s measured), which must never gate first paint.
        onSnapshotPublished?()

        // ============================================================
        // STALE-BY-MOVE DETECTION.
        //
        // A staged row's `folderPath` is PUSH-TIME truth — whatever folder the
        // message was in when the NSE captured it. If the user (or another
        // client/instance) archived/deleted/moved the DURABLE message before
        // this merge runs, the staging row is stale precache: merging it would
        // resurrect a message the user already acted on. Observed on-device
        // (boot_logs 3, 2026-07-09): a message the user archived in-app
        // reappeared in the inbox LIST later because the NSE re-staged the SAME
        // message on a later, unrelated push with `folderPath=INBOX` — no
        // existing guard catches this. `loadedIds`/`insertStagedRows`' identity
        // dedup only scan the VM's currently-loaded (visible) rows, so an
        // archived row that isn't displayed is invisible to them; the overlay
        // entry that recorded the original archive is long drained by the time
        // a LATER push restages the same message. This is the one place that
        // compares a staged row's folder against the DURABLE header's CURRENT
        // folder.
        //
        // Runs strictly AFTER the snapshot publish/post above — it must never
        // delay first paint — and BEFORE the stage-memo partition, so a stale
        // row never enters `writeSet`/`skipSet`. Read-only against main GRDB;
        // the only write here is the staging-row delete (mirrors the skip-set
        // cleanup's nseDB-only write below).
        //
        // No durable header at all is NOT stale — that's an ordinary new
        // message (or one sync hasn't created yet); only an EXISTING header
        // whose current folder disagrees with the staged folder is stale.
        // ============================================================
        let staleByMove = await Self.detectStaleByMoveRows(processed)
        if !staleByMove.isEmpty {
            scrubbedStaleStagedRows = true
            let staleStagingIds = Set(staleByMove.map(\.id))
            let staleHeaderIds = staleByMove.map(\.headerId)

            // (a) Exclude from all subsequent merge work this wake — must not
            // enter `writeSet` or `skipSet`.
            processed = processed.filter { !staleStagingIds.contains($0.id) }

            // (b) Delete the stale staging rows directly (no main-GRDB write
            // involved). Idempotent: a failure just leaves them staged for
            // re-evaluation (and re-exclusion) next wake.
            do {
                try await nseDB.write { db in
                    for id in staleStagingIds {
                        try db.execute(sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: [id])
                    }
                }
            } catch {
                if !error.isDatabaseSuspensionAbort {
                    print("[NSEDataBridge] Stale-by-move staging delete failed: \(error) — retried next wake (idempotent)")
                }
            }

            // (c) Remove from the ALREADY-PUBLISHED in-memory snapshots — the
            // `.messagesStaged` post above already fired with these rows
            // included (deliberately not delayed for this check), so the VM
            // may have just inserted the phantom via `insertStagedRows`.
            // PLAN_INBOX_UNIFIED_READ.md §3: no eviction notification needed —
            // `scrubbedStaleStagedRows` (set above) drives an explicit
            // immediate-reload post at the end-of-merge signal site below (F1:
            // the scrub-only-wake branch) so a reload is guaranteed even when
            // no durable work follows this wake. Once that reload lands, the
            // reader no longer finds the row in `latestStagedRows`, and its
            // stale-by-move durable header (§2.1a) also suppresses it, so the
            // reader structurally converges and the phantom is evicted.
            let staleHeaderIdSet = Set(staleHeaderIds)
            latestStagedRows.withLock { rows in
                rows.removeAll { staleHeaderIdSet.contains($0.headerId) }
            }
            latestStagedBodies.withLock { bodies in
                for hid in staleHeaderIdSet { bodies.removeValue(forKey: hid) }
            }

            // (d) Drop stage-memo entries — a stale row has no "next merge" to
            // skip against.
            stageMemo.withLock { memo in
                for id in staleStagingIds { memo.removeValue(forKey: id) }
            }

            BootProfiler.mark("merge: invalidated \(staleByMove.count) stale staged row(s) — durable header moved out of staged folder")
        }

        // ============================================================
        // STALE-BY-EPOCH DETECTION (T5.10 merge half, ADR-IOS-061 — ARM 1).
        //
        // Same shape as STALE-BY-MOVE above, but the signal is "this folder's
        // UIDVALIDITY turned over after this row was staged" instead of "this
        // message moved out of the staged folder". The row's UID now names a
        // DIFFERENT physical message, so merging it would land this
        // notification's content on a message it was never about (C3). See
        // `detectOldEpochStagedRows` / `uidValidityStagingRowStatus` for the
        // full rationale, including why a QUARANTINED folder's rows are KEPT
        // here rather than dropped.
        //
        // Runs AFTER stale-by-move (independent checks; a row caught by both is
        // harmlessly excluded once) and BEFORE the stage-memo partition — so an
        // old-epoch row never enters `writeSet`/`skipSet`. That ordering is
        // load-bearing for one case the in-txn guards structurally cannot see: a
        // `skipSet` row reaches NEITHER write transaction.
        //
        // NOTE (TOCTOU): this pre-txn read is a FIRST PASS, not the guard. A
        // reset completing after this read but before phase 1/2's write txns is
        // caught independently by the per-row `uidValidityStagingRowStatus`
        // check inside each phase's own write closure, which reports its finds
        // to `applyOldEpochStagingCleanup` for the identical treatment.
        // ============================================================
        let oldEpochStaged = await Self.detectOldEpochStagedRows(processed)
        if !oldEpochStaged.isEmpty {
            scrubbedStaleStagedRows = true
            let oldEpochStagingIds = Set(oldEpochStaged.map(\.id))
            // Exclude from every subsequent merge step this wake.
            processed = processed.filter { !oldEpochStagingIds.contains($0.id) }
            await Self.applyOldEpochStagingCleanup(oldEpochStaged, nseDB: nseDB)
            BootProfiler.mark("merge: discarded \(oldEpochStaged.count) old-epoch staged row(s) — observed UIDVALIDITY disagrees with the folder's settled epoch")
        }

        if !processed.isEmpty {
            // ============================================================
            // STAGE-MEMO SKIP.
            //
            // A merge TRIGGER unrelated to any particular row (a push for a
            // DIFFERENT message, syncStartup, foreground, a notif-tap gate —
            // every caller funnels through the same coordinator) re-reads the
            // SAME staged content for every KEPT gradual row on every wake.
            // Without this, both write phases below re-ran for a row whose
            // staged content hadn't advanced at all since the last time this
            // exact content was durably written (observed: one message's body
            // written 36×; 80 no-op merges still each held the GRDB writer
            // 20ms–4s — 16.5s total — during the most write-contended
            // windows). `writeSet` gets phase 1 + phase 2 below; `skipSet` is
            // memo-identical AND durability-verified (its durable rows are
            // confirmed still present) — its writes are skipped entirely. It
            // still participates in everything that ISN'T a durable write:
            // the `stagedRows`/`.messagesStaged`/snapshot-publish above ran
            // over the FULL `processed` set before this partition, and the
            // stale-protection refresh below also runs over the full set.
            // See `partitionByStageMemo` / `StageKey` / `stageMemo`.
            // ============================================================
            let (writeSet, skipSet) = await Self.partitionByStageMemo(processed)
            let writeSetById = Dictionary(uniqueKeysWithValues: writeSet.map { ($0.id, $0) })
            if !skipSet.isEmpty {
                BootProfiler.mark("merge: skipped \(skipSet.count) unchanged staged row(s) (stage-memo, durable-verified)")
            }

            // ============================================================
            // TWO-PHASE MERGE.
            //
            // Phase 1 (this block): surface each staged message's HEADER +
            // snippet and flip `headerComplete=1` (what makes it inbox-VISIBLE),
            // then render — OFF the body blob's critical path. A large HTML body
            // write is the proven-slow part (1.3–8s measured for big bodies); the
            // user sees the message arrive on a lightweight header write instead
            // of waiting on it. Phase 1 deletes NOTHING.
            //
            // Phase 2 (the existing write block below, UNCHANGED): writes the
            // body blob + summary/action/AI cache, FTS-indexes the body, and
            // deletes the staging row. Because phase 1 created/visible-flipped the
            // headers, phase 2 normally hits its existing-header branch; if phase
            // 1 ever missed a row (its savepoint failed), phase 2's new-header
            // branch is the fallback.
            //
            // CRITICAL: staging rows are deleted ONLY in phase 2. Staging is the
            // durable source until fully merged, so a crash BETWEEN phases
            // self-heals on the next wake — phase 1's header upsert is idempotent
            // and phase 2 still has the row to write the body from.
            // ============================================================
            var phase1HeaderIds: [String] = []
            // DIAGNOSTIC (debug-gated): split the phase-1 write into THREE parts so a
            // multi-second EXEC can be attributed precisely:
            //   acquireWriter = queue + SQLite writer-lock wait (e.g. blocked behind a
            //                   checkpoint or a long reader) — writeT0 → inside-closure entry
            //   loop(upserts) = the actual per-message reads+writes (cold-disk reads show here)
            //   commit+fsync  = COMMIT (≈0 under synchronous=NORMAL)
            // The earlier single `body` conflated acquireWriter with loop; this disambiguates.
            let phase1WriteT0 = CFAbsoluteTimeGetCurrent()
            let phase1LoopStart = Mutex<Double>(0)
            let phase1BodyEnd = Mutex<Double>(0)
            // STAGE-MEMO SKIP: only rows that advanced (or failed durability
            // re-verification) reach the writer at all — a fully-skipped merge
            // never opens `AppDatabase.dbPool.write` for phase 1, so it can't
            // queue behind / hold the single GRDB writer for nothing.
            if !writeSet.isEmpty {
            do {
                let phase1Result: (
                    headerIds: [String],
                    discoveredOldEpoch: [StaleByMoveRow]
                ) = try await AppDatabase.dbPool.write(label: "merge.phase1") { db in
                    // Writer acquired — everything before here was queue + writer-lock wait.
                    phase1LoopStart.withLock { $0 = CFAbsoluteTimeGetCurrent() }
                    var localIds: [String] = []
                    var localDiscoveredOldEpoch: [StaleByMoveRow] = []
                    // T5.10 IN-TXN epoch guard (ADR-IOS-061 — this, not the
                    // pre-txn pass above, is the guard). Memoized per folderId
                    // for this pass. Re-reading the folder INSIDE the write txn
                    // is what closes the TOCTOU window: a reset that completed
                    // after `detectOldEpochStagedRows`' read still gets caught
                    // right here, before anything durable is written.
                    var folderEpochCache: [String: (isQuarantined: Bool, lastKnownUidValidity: Int?)] = [:]
                    for msg in writeSet {
                        let msgFolderId = MessageIdentity.folderId(accountId: msg.accountId, folderPath: msg.folderPath)
                        let (isQuarantined, isOldEpoch) = Self.uidValidityStagingRowStatus(
                            msg: msg, cache: &folderEpochCache, db: db
                        )
                        // ARM 1 — the observed epoch POSITIVELY disagrees with the
                        // folder's settled epoch. Permanently stale (the stamp is
                        // immutable staged data), so skip AND delete.
                        if isOldEpoch {
                            localDiscoveredOldEpoch.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                                accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                            )))
                            if DebugModeManager.isLoggingEnabled() {
                                print("[NSEDataBridge] Merge phase 1: \(msg.id) OLD-EPOCH in-txn (folder \(msgFolderId) turned over after this row was staged) — skip-and-delete")
                            }
                            continue
                        }
                        // ARM 2 — the folder is mid-reaction. KEEP for retry,
                        // NEVER delete: the stored epoch is still the OLD one by
                        // construction, so no comparison is decisive yet. Same
                        // contract as a savepoint failure — the row stays staged
                        // and is re-evaluated once the reaction's step-5 stamp
                        // lands (or a later wake finds the quarantine cleared).
                        guard !isQuarantined else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[NSEDataBridge] Merge phase 1 skipping \(msg.id) — folder \(msgFolderId) in UIDVALIDITY quarantine (kept for retry)")
                            }
                            continue
                        }
                        // Per-message savepoint: a failure leaves THIS row in
                        // staging for retry (same contract as phase 2's loop) —
                        // siblings still commit.
                        do {
                            try db.inSavepoint {
                                // Find existing header: provider messageId first,
                                // then rfc822 fallback for IMAP UID remaps —
                                // mirrors phase 2's lookup.
                                let existingRef = try DurableIdentityLookup.find(
                                    db: db, accountId: msg.accountId, folderPath: msg.folderPath,
                                    messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId
                                )
                                if let ref = existingRef {
                                    let id = ref.id
                                    // ARM 3 — seed onto an EXISTING durable row ONLY
                                    // on POSITIVE identity evidence: an RFC match, or
                                    // (rfc-less) an epoch-confirmed folder. Both
                                    // rfc-DISAGREE and the rfc-nil + epoch-nil NULL
                                    // tail fail here and route to skip-and-delete.
                                    // This is where misattribution actually happens —
                                    // `DurableIdentityLookup.find` step 1 matches on a
                                    // bare `(accountId, folderPath, UID)` with no RFC
                                    // and no epoch input, so after a turnover it hands
                                    // back the NEW occupant of that UID.
                                    //
                                    // ⚑ THIS DOES NOT WEAKEN "a NULL identity stamp
                                    // means RE-FETCH, NEVER DESTROY". That rule forbids
                                    // destroying DURABLE USER DATA on the strength of a
                                    // NULL. Nothing durable is destroyed here: the arm
                                    // REFUSES TO WRITE without positive proof, and then
                                    // deletes only a STAGING-SCRATCH row that can never
                                    // become provable — `observedUidValidity` is
                                    // immutable staged data, so a retry re-reads the
                                    // same NULL, and `stageHeader`'s on-conflict
                                    // retains the old payload, meaning a KEPT row would
                                    // re-poison whatever later message occupies the
                                    // same address. The user's mail is not lost:
                                    // ordinary sync re-fetches it. The cost is wasted
                                    // NSE AI work plus one main-app recompute — which
                                    // is exactly what that rule prescribes, and the NSE
                                    // is best-effort by policy while C3 is not.
                                    //
                                    // The folder is provably NOT quarantined here (ARM
                                    // 2 `continue`d those rows above), so the epoch
                                    // door is being asked against a settled epoch.
                                    let folderStatus = folderEpochCache[msgFolderId]
                                    guard Self.nseMergeIdentityConfirmed(
                                        msg: msg, existingRfc: ref.rfc822MessageId,
                                        existingFolderId: ref.folderId,
                                        folderEpoch: folderStatus?.lastKnownUidValidity,
                                        folderQuarantined: folderStatus?.isQuarantined ?? false
                                    ) else {
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[NSEDataBridge] Merge phase 1: \(msg.id) identity NOT confirmed vs existing row \(id) (rfc/epoch) — refusing snippet seed, skip-and-delete")
                                        }
                                        throw NSERfcMismatchDiscovered()
                                    }
                                    // Already visible (sync or a prior merge). SEED
                                    // the snippet ONLY if the header has none yet —
                                    // so the fast header render has something to
                                    // show. Do NOT overwrite an existing snippet:
                                    // phase 2 computes the canonical body-derived
                                    // snippet (matching the sync path), and
                                    // re-seeding here on every wake would OSCILLATE
                                    // against phase 2's value (each merge flips it),
                                    // which both churns the column and defeats the
                                    // no-op detection that gates the end-of-merge
                                    // render → redundant reloads. `AND (snippet IS
                                    // NULL OR snippet = '')` makes the re-seed a
                                    // one-time, no-oscillation op.
                                    // Seed the DISPLAY snippet (body-derived when
                                    // staged text exists — identical to phase 2's,
                                    // so it never visibly changes; else the CLEANED
                                    // provider snippet — raw Gmail/Graph snippets
                                    // are entity-encoded, the "weird snippet" bug).
                                    let seed = Self.stagedDisplaySnippet(
                                        providerSnippet: msg.snippet,
                                        textContent: msg.textContent
                                    )
                                    if !seed.isEmpty {
                                        try db.execute(
                                            sql: "UPDATE messageHeader SET snippet = ? WHERE id = ? AND (snippet IS NULL OR snippet = '')",
                                            arguments: [seed, id]
                                        )
                                    }
                                    localIds.append(id)
                                } else {
                                    // No header yet — create the header-only row
                                    // (snippet + thread + junctions; NO body blob,
                                    // NO AI fields). Body + AI land in phase 2.
                                    var dummyFts: [NSEFTSBodyItem] = []
                                    _ = try Self.insertNewHeaderFromStaging(
                                        msg, db: db, ftsBatch: &dummyFts, headerOnly: true
                                    )
                                    localIds.append(MessageIdentity.headerId(
                                        accountId: msg.accountId,
                                        folderPath: msg.folderPath,
                                        messageId: msg.messageId
                                    ))
                                }
                                return .commit
                            }
                        } catch is NSERfcMismatchDiscovered {
                            // ARM 3. The savepoint rolled back, so NOTHING of this
                            // staged row landed on the row it could not claim.
                            // Route to the SAME skip-and-delete disposition as an
                            // ARM-1 discovery — never "left in staging for retry",
                            // which would re-attempt the identical unprovable match
                            // against the identical (correct, unrelated) header on
                            // every future wake.
                            //
                            // The STAGED headerId — see `NSERfcMismatchDiscovered`'s
                            // doc for why the durable id (logged at the throw site)
                            // must not be used for the snapshot scrub.
                            localDiscoveredOldEpoch.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                                accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                            )))
                        } catch {
                            // Savepoint rolled back + re-threw; outer tx still
                            // alive. Row stays in staging (phase 2 re-attempts it
                            // this same wake; otherwise next wake).
                            print("[NSEDataBridge] Merge phase 1 failed for \(msg.id): \(error) — left in staging for retry")
                        }
                    }
                    phase1BodyEnd.withLock { $0 = CFAbsoluteTimeGetCurrent() }
                    return (localIds, localDiscoveredOldEpoch)
                }
                phase1HeaderIds = phase1Result.headerIds
                if !phase1Result.discoveredOldEpoch.isEmpty {
                    scrubbedStaleStagedRows = true
                    await Self.applyOldEpochStagingCleanup(phase1Result.discoveredOldEpoch, nseDB: nseDB)
                }
                if DebugModeManager.isLoggingEnabled() {
                    let loopStart = phase1LoopStart.withLock { $0 }
                    let bodyEnd = phase1BodyEnd.withLock { $0 }
                    if bodyEnd > 0, loopStart > 0 {
                        let acquireMs = Int((loopStart - phase1WriteT0) * 1000)
                        let loopMs = Int((bodyEnd - loopStart) * 1000)
                        let commitMs = Int((CFAbsoluteTimeGetCurrent() - bodyEnd) * 1000)
                        BootProfiler.mark("merge.phase1 SPLIT: acquireWriter=\(acquireMs)ms loop(upserts)=\(loopMs)ms commit+fsync=\(commitMs)ms (\(writeSet.count) msg)")
                    }
                }
            } catch {
                // Outer write threw — nothing durable from phase 1. Phase 2 below
                // still runs and creates the headers via its own new-header
                // branch; staging is untouched so nothing is lost.
                print("[NSEDataBridge] Merge phase 1 failed (outer tx): \(error)")
            }
            } // if !writeSet.isEmpty (phase 1)

            // DIAGNOSTIC (debug-gated): isolate the phase-1 header upsert tx from
            // the FTS-surface step below. The "found N staged" → "newly visible"
            // gap has been observed at 2–20s during concurrent background sync;
            // this localizes whether the cost is the upsert tx (main writer) or
            // flushHeadersToFTS (main read / FTS actor / flip). Remove once pinned.
            BootProfiler.mark("merge phase1: header upsert tx done (\(phase1HeaderIds.count) id(s))")

            // Surface the headers NOW: index + flip headerComplete=1 (inbox-
            // visible), then render. This is the early paint that decouples
            // visibility from the body blob; phase 2's end-of-merge post is the
            // second render once the body + AI are durable.
            if !phase1HeaderIds.isEmpty {
                // flushHeadersToFTS returns how many headers it flipped from
                // headerComplete=0 → 1 (i.e. became NEWLY inbox-visible this wake).
                // It still indexes + flips ALL ids (idempotent recovery); only the
                // RENDER is gated on a real visibility change, so a foreground
                // re-merge of already-visible rows doesn't fire a redundant reload.
                let newlyVisible = await Self.flushHeadersToFTS(headerIds: phase1HeaderIds)
                if newlyVisible > 0 {
                    didMutate = true
                    BootProfiler.mark("merge phase1: \(newlyVisible) header(s) newly visible — rendered")
                    MergeSurfaceProbe.markMergeSignal()
                    Task { @MainActor in
                        NotificationCenter.default.post(
                            name: .inboxDataDidChange,
                            object: nil,
                            userInfo: [Notification.Name.inboxReloadImmediateKey: true]
                        )
                        // Headers + reference junctions are durable/queryable as
                        // of this flip — an open quick-rendered detail view can
                        // now re-run thread detection and find related messages
                        // that were staging-only at first render (ADR-IOS-049).
                        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
                    }
                } else {
                    BootProfiler.mark("merge phase1: \(phase1HeaderIds.count) header(s) already visible — no extra render")
                }
            }

            // ---- Phase 2 (existing, UNCHANGED) ----
            // Only delete from staging the rows that actually committed. A
            // per-message savepoint failure leaves its row in staging for
            // retry on the next wake. This replaces the historical pattern of
            // deleting `processedIds` (the whole read set) regardless of
            // commit outcome — a bug that dropped staging rows for
            // savepoints that never committed.
            // Rows whose staging entry should be DELETED after the tx commits.
            // With gradual staging this is NOT every merged row — only TERMINAL
            // ones (NSE finished AI) or ABANDONED ones (NSE long gone). Non-terminal
            // gradual rows (header/body staged, AI pending) merge successfully but
            // are KEPT so the next wake picks up the AI stage.
            var successfullyMergedIds: [String] = []
            // Count of rows that committed at least a header/body update this wake
            // (terminal OR kept). Drives the UI refresh + badge recount — a kept
            // gradual row still changed main GRDB and must refresh the inbox.
            var committedCount = 0
            // `StagedMessage.id` (staging-row identity) of every `writeSet` row
            // whose savepoint committed this wake — terminal AND kept alike.
            // STAGE-MEMO SKIP uses this to record the current stage key for
            // rows that committed but were KEPT (not deleted below), so the
            // NEXT trigger-only re-merge of this exact content can skip it.
            var committedMsgIds: [String] = []
            // Collect FTS pipeline work across ALL committed messages; flushed
            // once after the main tx commits. Per-message ftsBatch is built
            // INSIDE the savepoint and only merged into this batch after the
            // savepoint commits — so a savepoint rollback doesn't leak stale
            // entries that point at non-existent main-GRDB rows.
            var ftsBatch: [NSEFTSBodyItem] = []
            // The id of EVERY committed merged header (bodied or not). Header
            // visibility (headerComplete) is independent of body presence, so the
            // post-tx flush indexes + flips headerComplete for this full set — an
            // image-only / unresolved-CID push becomes inbox-visible at merge time
            // rather than waiting for a later recoverIncompleteHeaders pass. Body
            // FTS / bodyComplete stay scoped to `ftsBatch` (the bodied subset).
            var allMergedHeaderIds: [String] = []
            // Whether the phase-2 main write changed anything durable (its
            // total_changes delta). Drives the SECOND, end-of-merge render so a
            // no-op re-merge doesn't reload. Assigned from writeResult.realChanged.
            var mainWriteChanged = false

            // Tracks whether the outer dbPool.write actually committed. Per-
            // message savepoints can RELEASE successfully but if the outer
            // commit later fails (SQLITE_FULL/IOERR/INTERRUPT), GRDB rolls
            // back the entire transaction — including those releases — so
            // nothing is durable in main GRDB. We must NOT delete the
            // corresponding staging rows in that case.
            var outerCommitted = false

            // STAGE-MEMO SKIP: same guard as phase 1 — a fully-skipped merge
            // (every staged row memo-identical + durability-verified) never
            // opens `AppDatabase.dbPool.write` for phase 2 either, so it holds
            // the GRDB writer for exactly zero time.
            if !writeSet.isEmpty {
            do {
                // Async overload (foreground-hang fix): SUSPENDS the caller
                // instead of BLOCKING the thread, so a foreground-return merge no
                // longer freezes the @MainActor caller while this write waits
                // behind concurrent sync/backfill writes on GRDB's single writer
                // connection (the writer-serialization wait is uncapped by
                // busyMode). The @Sendable closure can't capture mutable outer
                // state, so the per-message accumulators are built INSIDE and
                // returned, then assigned to successfullyMergedIds/ftsBatch below.
                // Diagnostic: decompose the merge time into "wait for the GRDB
                // writer" (queued behind a concurrent sync/backfill/body write)
                // vs. the actual write. A big gap between these two marks ⇒ the
                // late-surfacing residual is writer contention, not the write itself.
                let writeReqT0 = CFAbsoluteTimeGetCurrent()
                BootProfiler.mark("merge: requesting GRDB writer for \(writeSet.count) staged msg(s)")
                let writeResult: (ids: [String], committed: Int, fts: [NSEFTSBodyItem], headers: [String], realChanged: Bool, committedIds: [String], discoveredOldEpoch: [StaleByMoveRow]) = try await AppDatabase.dbPool.write(label: "merge.body") { db in
                    BootProfiler.mark("merge: GRDB writer ACQUIRED after \(Int((CFAbsoluteTimeGetCurrent() - writeReqT0) * 1000))ms wait")
                    // Connection-level write counter snapshot. The delta over this
                    // whole transaction tells us whether phase 2 changed anything
                    // durable (new header, first body insert, snippet/summary/action
                    // write) vs. a no-op re-merge (body insert ignored, snippet
                    // value-guarded to a no-op). Conservative by design: an ignored
                    // INSERT and a 0-row UPDATE don't count, so it never MISSES a
                    // real change (worst case over-counts → one extra harmless
                    // reload); it only suppresses the provably-nothing-changed case.
                    let tcStart = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
                    var localMergedIds: [String] = []
                    var localCommitted = 0
                    var localCommittedMsgIds: [String] = []
                    var localFtsAccumulator: [NSEFTSBodyItem] = []
                    var localHeaderAccumulator: [String] = []
                    var localDiscoveredOldEpoch: [StaleByMoveRow] = []
                    // T5.10 IN-TXN epoch guard, phase 2's own copy. Phase 1's
                    // per-message skip is NOT sufficient on its own: a row phase 1
                    // SKIPPED (ARM 2, quarantine) is indistinguishable here from a
                    // row whose phase-1 savepoint merely FAILED, and phase 2's
                    // new-header branch is the documented fallback for exactly that
                    // case — so without this guard phase 2 would cheerfully insert
                    // the row phase 1 correctly refused. Same per-txn memo shape.
                    var folderEpochCache: [String: (isQuarantined: Bool, lastKnownUidValidity: Int?)] = [:]
                    for msg in writeSet {
                        let msgFolderId = MessageIdentity.folderId(accountId: msg.accountId, folderPath: msg.folderPath)
                        let (isQuarantined, isOldEpoch) = Self.uidValidityStagingRowStatus(
                            msg: msg, cache: &folderEpochCache, db: db
                        )
                        // ARM 1 — positive epoch disagreement, folder settled.
                        // Permanently stale: skip AND delete.
                        if isOldEpoch {
                            localDiscoveredOldEpoch.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                                accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                            )))
                            if DebugModeManager.isLoggingEnabled() {
                                print("[NSEDataBridge] Merge phase 2: \(msg.id) OLD-EPOCH in-txn (folder \(msgFolderId) turned over after this row was staged) — skip-and-delete")
                            }
                            continue
                        }
                        // ARM 2 — folder mid-reaction: KEEP for retry, never delete.
                        guard !isQuarantined else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[NSEDataBridge] Merge phase 2 skipping \(msg.id) — folder \(msgFolderId) in UIDVALIDITY quarantine (kept for retry)")
                            }
                            continue
                        }
                        // Per-message savepoint: a single bad row (FK
                        // violation, ThreadUtils throw, FTS contention, etc.)
                        // rolls back JUST that row, not the entire batch. The
                        // outer transaction stays alive so siblings still
                        // commit. The failed row stays in staging because we
                        // don't append its id to `successfullyMergedIds`.
                        // GRDB's `inSavepoint` issues a real SQLite SAVEPOINT
                        // when called inside an active transaction
                        // (Database.swift:1625) and re-throws on closure
                        // failure after rolling back the savepoint.
                        //
                        // Per-iteration ftsBatch is local and only merged into
                        // the loop-level state after the savepoint commits, so
                        // a rollback doesn't leak FTS entries pointing at
                        // non-existent rows.
                        var localFtsBatch: [NSEFTSBodyItem] = []
                        // The id of the header this savepoint committed (existing or
                        // newly inserted). Captured regardless of body so the post-tx
                        // flush can index it + flip headerComplete → inbox-visible.
                        var committedHeaderId: String?
                        do {
                            try db.inSavepoint {
                                // Find existing MessageHeader in main DB.
                                //
                                // Primary lookup: by provider messageId. Works for Gmail
                                // (messageId is stable) and Outlook Graph (id is stable),
                                // and for IMAP when UIDs haven't changed.
                                //
                                // Fallback lookup: by rfc822MessageId. Catches IMAP UID
                                // remaps after server-side MOVE — e.g. user archives a
                                // message, hits undo → our MOVE-BACK assigns a fresh UID
                                // in INBOX; the push worker fires a notification with
                                // that new UID as messageId; the primary lookup misses
                                // because our header still has the pre-archive UID.
                                // Without this fallback we'd insert a duplicate header
                                // keyed on the new UID, which the user sees as two
                                // copies of the same email.
                                let existingRef = try DurableIdentityLookup.find(
                                    db: db, accountId: msg.accountId, folderPath: msg.folderPath,
                                    messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId
                                )
                                if let ref = existingRef {
                                    let headerId: String = ref.id
                                    committedHeaderId = headerId
                                    // Use the existing header's folderPath (not the
                                    // staged msg.folderPath) as the AI cache key's
                                    // folder component. If sync raced ahead of our
                                    // merge and moved the message, the main app's
                                    // cache probes go through the CURRENT folderPath
                                    // — we must write under the same key, not the
                                    // one NSE captured at fetch time. For the common
                                    // case (no drift) these are identical.
                                    let existingFolderPath: String = ref.folderPath
                                    let existingRfc822: String? = ref.rfc822MessageId

                                    // ARM 3 — merge body / summary / actionTag /
                                    // notified / reach-out / AI-cache onto an
                                    // EXISTING durable row ONLY on POSITIVE identity
                                    // evidence: an RFC match, or (rfc-less) an
                                    // epoch-confirmed folder. rfc-DISAGREE and the
                                    // rfc-nil + epoch-nil NULL tail BOTH fail here.
                                    // This arm is strictly heavier than phase 1's:
                                    // phase 1 only seeds a snippet, whereas an
                                    // unproven match HERE stamps a whole foreign body
                                    // (and `bodyComplete`) plus AI cache onto a
                                    // reset-reused row, permanently — and that row's
                                    // own later summary job then reads the poisoned
                                    // value as a cache HIT.
                                    //
                                    // ⚑ NOT A WEAKENING OF "a NULL identity stamp
                                    // means RE-FETCH, NEVER DESTROY" — see phase 1's
                                    // ARM-3 comment for the full argument. Nothing
                                    // durable is destroyed: the write is REFUSED for
                                    // want of proof, and only a staging-scratch row
                                    // that can never become provable is deleted, with
                                    // ordinary sync re-fetching the message.
                                    //
                                    // The folder is provably NOT quarantined here
                                    // (ARM 2 `continue`d those rows above).
                                    let folderStatus = folderEpochCache[msgFolderId]
                                    guard Self.nseMergeIdentityConfirmed(
                                        msg: msg, existingRfc: existingRfc822,
                                        existingFolderId: ref.folderId,
                                        folderEpoch: folderStatus?.lastKnownUidValidity,
                                        folderQuarantined: folderStatus?.isQuarantined ?? false
                                    ) else {
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[NSEDataBridge] Merge phase 2: \(msg.id) identity NOT confirmed vs existing row \(headerId) (rfc/epoch) — refusing merge, skip-and-delete")
                                        }
                                        throw NSERfcMismatchDiscovered()
                                    }

                                    // GRADUAL MERGE (header→body→summary→action):
                                    // apply each staged piece as it becomes present
                                    // so a not-yet-AI-complete row updates the
                                    // existing main-GRDB header incrementally across
                                    // wakes, instead of all-or-nothing on aiCompleted.
                                    // Every step is idempotent so re-merging a kept
                                    // (non-terminal) row is safe.

                                    // 1. Body — persist whenever NSE staged one.
                                    // MessageBody insert is onConflict:.ignore and
                                    // the body queue skips bodyComplete=1, so a
                                    // re-merge of an already-bodied row is a cheap
                                    // no-op. Hoisted OUT of the AI gate so the body
                                    // lands at the body stage, before AI.
                                    if msg.htmlContent != nil || msg.textContent != nil {
                                        try persistRenderedBodyFromStaging(
                                            db: db, headerId: headerId,
                                            htmlContent: msg.htmlContent, textContent: msg.textContent,
                                            attachmentsJSON: msg.attachmentsJSON, icsText: msg.icsText,
                                            hasUnresolvedCIDs: msg.hasUnresolvedCIDs,
                                            ftsBatch: &localFtsBatch
                                        )
                                    }

                                    // 2. Summary — apply as soon as it's staged
                                    // (the NSE stages it before the action vote).
                                    if msg.summaryBlurb != nil || msg.summaryTodos != nil
                                        || msg.reminderDate != nil || msg.reminderTime != nil
                                        || msg.reminderContent != nil {
                                        // Value-guarded: the NSE stages the summary BEFORE the
                                        // terminal action vote, so an aiCompleted=0 row with a
                                        // summary is KEPT and re-merges every wake until the
                                        // action lands. Re-writing the SAME five values must be a
                                        // 0-row no-op — otherwise it inflates the merge's
                                        // total_changes() and fires a redundant end-of-merge
                                        // reload. The OR-chain still updates whenever ANY field
                                        // actually differs.
                                        try db.execute(sql: """
                                            UPDATE messageHeader SET
                                                summaryBlurb = ?, summaryTodos = ?,
                                                reminderDate = ?, reminderTime = ?, reminderContent = ?
                                            WHERE id = ? AND (
                                                summaryBlurb IS NOT ? OR summaryTodos IS NOT ?
                                                OR reminderDate IS NOT ? OR reminderTime IS NOT ?
                                                OR reminderContent IS NOT ?
                                            )
                                            """, arguments: [
                                                msg.summaryBlurb, msg.summaryTodos,
                                                msg.reminderDate, msg.reminderTime, msg.reminderContent,
                                                headerId,
                                                msg.summaryBlurb, msg.summaryTodos,
                                                msg.reminderDate, msg.reminderTime, msg.reminderContent
                                            ])
                                    }

                                    // 3. Action — apply when staged (terminal AI
                                    // stage). Keep `tagSortOrder` paired with
                                    // `actionTag` — the triage view sorts by
                                    // `ORDER BY tagSortOrder ASC, date DESC`, so a
                                    // 'reply' tag with the default 99 sort lands at
                                    // the bottom (caught via [TriageSortDiag]). OR-in
                                    // `notified`. Queue the IMAP tag write here too
                                    // (idempotent via deterministic id), since it
                                    // only matters once a tag exists.
                                    if let actionRaw = msg.actionTag {
                                        let aiTagSortOrder = ActionTag(rawValue: actionRaw)?.sortOrder ?? 99
                                        // Value-guarded (same rationale as summary): a re-merge of
                                        // a row whose tag is already applied is a 0-row no-op. The
                                        // third OR-term keeps the notified 0→1 flip working (the
                                        // CASE sets notified=1 only when msg.notified is true).
                                        try db.execute(sql: """
                                            UPDATE messageHeader SET
                                                actionTag = ?, tagSortOrder = ?,
                                                notified = CASE WHEN ? THEN 1 ELSE notified END
                                            WHERE id = ? AND (
                                                actionTag IS NOT ? OR tagSortOrder IS NOT ?
                                                OR (? = 1 AND notified = 0)
                                            )
                                            """, arguments: [
                                                actionRaw, aiTagSortOrder, msg.notified, headerId,
                                                actionRaw, aiTagSortOrder, msg.notified
                                            ])
                                        try queueSetTagPendingOp(db: db, accountId: msg.accountId,
                                                                 messageId: msg.messageId, tag: msg.actionTag)
                                    } else if msg.notified {
                                        // Notification delivered but no action tag (AI failed / passive).
                                        // `AND notified = 0`: a re-merge of an already-notified kept
                                        // row (aiCompleted=0, notified=1, survives up to the 60s
                                        // abandon window) is a 0-row no-op → no redundant reload.
                                        try db.execute(sql: "UPDATE messageHeader SET notified = 1 WHERE id = ? AND notified = 0",
                                                       arguments: [headerId])
                                    }

                                    markReachedOutIfNotified(
                                        notified: msg.notified,
                                        reminderContent: msg.reminderContent,
                                        rfc822MessageId: msg.rfc822MessageId,
                                        headerId: headerId
                                    )

                                    // 4. AI cache — write ONLY once AI is complete
                                    // (both summary + action), matching the new-header
                                    // branch and the pre-gradual behavior. The cache
                                    // is the LLM-SKIP optimization read by peers /
                                    // the main-app AI queue, so it must be
                                    // complete-or-nothing — a transient summary-only
                                    // entry could let a reader skip the action. The
                                    // header's own summary/action columns still update
                                    // gradually above (display); only this cache waits.
                                    // Keyed on the EXISTING header's folderPath
                                    // (current GRDB state) to avoid drift if sync moved
                                    // the message.
                                    if msg.aiCompleted {
                                        let rfc = msg.rfc822MessageId ?? existingRfc822
                                        if let cacheKey = MessageIdentity.aiCacheKey(
                                            accountId: msg.accountId,
                                            folderPath: existingFolderPath,
                                            rfc822MessageId: rfc
                                        ) {
                                            // Value-guarded UPSERT (not INSERT OR REPLACE):
                                            // re-writing the SAME cached summary/action on a
                                            // re-merge of a terminal row whose prior staging
                                            // delete failed must be a 0-row no-op — otherwise it
                                            // bumps total_changes() (redundant reload) AND, since
                                            // REPLACE = delete+insert, NULLs columns it doesn't
                                            // list (e.g. a peer's precomputed `cachedReply`).
                                            // DO UPDATE touches only these four columns, and only
                                            // when the content actually differs.
                                            try db.execute(sql: """
                                                INSERT INTO messageAICache
                                                    (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                                                    VALUES (?, ?, ?, ?, ?)
                                                ON CONFLICT(key) DO UPDATE SET
                                                    summaryBlurb = excluded.summaryBlurb,
                                                    summaryTodos = excluded.summaryTodos,
                                                    actionTag = excluded.actionTag,
                                                    updatedAt = excluded.updatedAt
                                                WHERE summaryBlurb IS NOT excluded.summaryBlurb
                                                   OR summaryTodos IS NOT excluded.summaryTodos
                                                   OR actionTag IS NOT excluded.actionTag
                                                """, arguments: [
                                                    cacheKey, msg.summaryBlurb, msg.summaryTodos,
                                                    msg.actionTag, msg.processedAt
                                                ])
                                        }
                                    }
                                } else {
                                    // Header not in main DB yet — create it from NSE staging data
                                    // so the message appears in inbox immediately (before sync).
                                    // Body of the new-header insert lives in
                                    // `insertNewHeaderFromStaging` so tests can drive it
                                    // against an in-memory GRDB without the App Group
                                    // staging file.
                                    _ = try Self.insertNewHeaderFromStaging(
                                        msg, db: db, ftsBatch: &localFtsBatch
                                    )
                                    // MessageHeader.id == MessageIdentity.headerId(...)
                                    // by construction (MessageHeader.swift:232), so this
                                    // is exactly the row insertNewHeaderFromStaging wrote
                                    // (onConflict:.ignore — same id whether it inserted or
                                    // sync already had it; re-flipping headerComplete is an
                                    // idempotent no-op in the latter case).
                                    committedHeaderId = MessageIdentity.headerId(
                                        accountId: msg.accountId,
                                        folderPath: msg.folderPath,
                                        messageId: msg.messageId
                                    )

                                    // Queue IMAP tag write so the tag propagates to the server.
                                    // Without this, the fresh-header branch would set header.actionTag
                                    // locally but never sync it to the provider.
                                    try queueSetTagPendingOp(db: db, accountId: msg.accountId,
                                                             messageId: msg.messageId, tag: msg.actionTag)

                                    // Also cache AI results for resilience.
                                    // Same shared-helper key as the existing-header branch.
                                    if msg.aiCompleted,
                                       let cacheKey = MessageIdentity.aiCacheKey(
                                        accountId: msg.accountId,
                                        folderPath: msg.folderPath,
                                        rfc822MessageId: msg.rfc822MessageId
                                       ) {
                                        // Value-guarded UPSERT — same rationale as the existing-
                                        // header branch (no REPLACE-clobber of cachedReply, no
                                        // redundant count on a no-op re-write).
                                        try db.execute(sql: """
                                            INSERT INTO messageAICache
                                                (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                                                VALUES (?, ?, ?, ?, ?)
                                            ON CONFLICT(key) DO UPDATE SET
                                                summaryBlurb = excluded.summaryBlurb,
                                                summaryTodos = excluded.summaryTodos,
                                                actionTag = excluded.actionTag,
                                                updatedAt = excluded.updatedAt
                                            WHERE summaryBlurb IS NOT excluded.summaryBlurb
                                               OR summaryTodos IS NOT excluded.summaryTodos
                                               OR actionTag IS NOT excluded.actionTag
                                            """, arguments: [
                                                cacheKey, msg.summaryBlurb, msg.summaryTodos,
                                                msg.actionTag, msg.processedAt
                                            ])
                                    }
                                }
                                return .commit
                            }
                            // Savepoint committed — promote local FTS batch and
                            // count the commit (drives the UI refresh / badge recount).
                            localFtsAccumulator.append(contentsOf: localFtsBatch)
                            if let hid = committedHeaderId {
                                localHeaderAccumulator.append(hid)
                            }
                            localCommitted += 1
                            localCommittedMsgIds.append(msg.id)
                            // Delete the staging row only when the NSE's work is
                            // DONE: AI completed (terminal), or a gradual row whose
                            // NSE is long gone (older than the abandon window — its
                            // header+body are now durable in main GRDB and the
                            // main-app AI queue will finish the AI). Recent
                            // aiCompleted=0 rows are KEPT so the next wake merges the
                            // AI stage as the NSE fills it in.
                            if msg.aiCompleted || msg.processedAt < abandonedCutoff {
                                localMergedIds.append(msg.id)
                            }
                        } catch is NSERfcMismatchDiscovered {
                            // ARM 3. The savepoint rolled back — no body, no
                            // summary, no action, no notified flag, no AI cache
                            // entry landed on the row this staged content could
                            // not claim. Skip-and-delete, NOT retry: the staged
                            // stamp is immutable, so the identical unprovable
                            // match would recur on every future wake.
                            //
                            // The STAGED headerId — the id logged at the throw
                            // site is the DURABLE row's, which the snapshot scrub
                            // must not key off. See `NSERfcMismatchDiscovered`.
                            localDiscoveredOldEpoch.append(StaleByMoveRow(id: msg.id, headerId: MessageIdentity.headerId(
                                accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
                            )))
                        } catch {
                            // inSavepoint already rolled back the savepoint
                            // and re-threw the error; the outer transaction
                            // is still alive. Skip recording this id so the
                            // staging row stays for retry. Local deltas are
                            // discarded with the rollback.
                            print("[NSEDataBridge] Per-message merge failed for \(msg.id): \(error) — left in staging for retry")
                        }
                    }
                    let tcEnd = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
                    return (ids: localMergedIds, committed: localCommitted, fts: localFtsAccumulator, headers: localHeaderAccumulator, realChanged: tcEnd > tcStart, committedIds: localCommittedMsgIds, discoveredOldEpoch: localDiscoveredOldEpoch)
                }
                // Reaching this line means dbPool.write returned normally —
                // GRDB has committed the outer tx and every released savepoint
                // is durable. Assign the returned accumulators, then set the flag
                // so the post-tx staging delete + FTS flush + badge update can
                // proceed.
                successfullyMergedIds = writeResult.ids
                committedCount = writeResult.committed
                committedMsgIds = writeResult.committedIds
                ftsBatch = writeResult.fts
                allMergedHeaderIds = writeResult.headers
                mainWriteChanged = writeResult.realChanged
                outerCommitted = true
                // ARM 1 / ARM 3 discoveries made INSIDE this write txn. Applied
                // only after the outer commit returned normally — the same gate
                // every other post-tx cleanup here observes.
                if !writeResult.discoveredOldEpoch.isEmpty {
                    scrubbedStaleStagedRows = true
                    await Self.applyOldEpochStagingCleanup(writeResult.discoveredOldEpoch, nseDB: nseDB)
                }
                // Main tx done. With the "writer ACQUIRED after Xms" mark above this
                // decomposes the merge: START→found = read; found→ACQUIRED = writer
                // wait (contention); ACQUIRED→here = the actual main write; here→DONE
                // = post-tx FTS flush. Whichever Δ dominates is the real residual.
                BootProfiler.mark("merge: main tx committed (\(committedCount) merged) — FTS flush next")
                print("[NSEDataBridge] mergeNSEStagingData: \(committedCount)/\(writeSet.count) merged (\(successfullyMergedIds.count) terminal → delete)")

                // NOTE: no UI-refresh post here anymore. performMerge posts its
                // end-of-flow `.inboxDataDidChange` (immediate) at the very end,
                // after the synchronous FTS flush below has flipped
                // `headerComplete=1` — so a brand-new staged header is already
                // VISIBLE to the inbox query (which filters `headerComplete ==
                // true`) when that reload fires. (Phase 1 already posted the
                // earlier header-only render; this end-of-merge post is the
                // second.) Posting mid-flight here would trigger a reload that the
                // not-yet-flipped header would miss.
            } catch {
                // Outer dbPool.write threw — usually a hard SQLite error
                // (SQLITE_FULL/IOERR/INTERRUPT) at commit time. EVERY released
                // savepoint is rolled back along with the outer tx, so no
                // matter what successfullyMergedIds contains, nothing is
                // durable in main GRDB. The post-tx staging delete is gated
                // on `outerCommitted` and won't run, leaving all rows in
                // staging for retry.
                print("[NSEDataBridge] Merge failed (outer tx): \(error)")
            }
            } // if !writeSet.isEmpty (phase 2)

            // STALE-DETECTION RACE FIX: a message that just became durable via this
            // push-merge is NOT registered in pending-ops / recentlyCompleted, so a
            // concurrent/next sync whose server fetch TRANSIENTLY misses it (STATUS/
            // fetch propagation lag — the thing flushServerState fights) STALE-DELETES
            // it. Symptom: insta-merge shows the new mail, a sync drops it, a later
            // sync brings it back. Register EVERY staged id (not just `writeSet`'s —
            // 5b: a KEPT gradual row this pass SKIPPED still needs its protection
            // refreshed, the race it guards against doesn't care whether THIS pass
            // wrote anything) as recently-arrived so stale detection (fullSync +
            // reconcile + delta all read AccountManager.shared.recentlyCompleted)
            // SKIPS them for `SyncConfig.pushMergeStaleProtectionTTLSeconds`, by
            // which point the server reliably returns them. Protecting-from-deletion
            // is the safe direction (never deletes; worst case a genuinely-gone
            // message lingers one extra TTL). Keys: provider messageId (exact) +
            // normalized rfc822 (survives UID-remap), matching both stale-check
            // paths. Uses the longer push-merge TTL (not the default
            // action-completion TTL) — see SyncConfig.pushMergeStaleProtectionTTLSeconds.
            do {
                var protectIds: [String] = []
                for m in processed {
                    protectIds.append(m.messageId)
                    if let rfc = m.rfc822MessageId, !rfc.isEmpty {
                        protectIds.append(EmailFilter.normalizeMessageId(rfc))
                    }
                }
                await AccountManager.shared.recordRecentlyCompleted(
                    messageIds: protectIds, ttl: SyncConfig.pushMergeStaleProtectionTTLSeconds
                )
                BootProfiler.mark("merge: stale-protected \(processed.count) recently-arrived msg(s) (\(Int(SyncConfig.pushMergeStaleProtectionTTLSeconds))s) — prevents pre-verify drop")
            }

            // Drive the render/recount off REAL durable changes AND outer-tx
            // success. If the outer commit failed, the per-msg savepoint releases
            // got rolled back, so nothing changed. `mainWriteChanged` (phase 2's
            // total_changes delta) is true only when body/AI/snippet/new-header
            // actually wrote — so a no-op re-merge sets neither flag and fires no
            // end-of-merge reload.
            if outerCommitted, mainWriteChanged {
                didMutate = true
                endOfMergeChanged = true
            }

            // Both the FTS flush and the staging-row delete are gated on the
            // outer commit. If the outer tx rolled back at commit time, the
            // per-msg savepoint releases are undone too — no rows are durable
            // in main GRDB, so we mustn't index FTS for them and mustn't
            // delete their staging rows.
            if outerCommitted {
                // Fire ONE batched FTS pipeline for all committed messages.
                // No-op if nothing was merged this wake.
                //
                // AWAITED (not detached) — this is what flips `headerComplete=1`
                // for EVERY merged header (and `bodyComplete=1` for the bodied
                // subset). Because the merge is privileged and single-threaded
                // (see `NSEMergeCoordinator`), nothing else is contending for the
                // GRDB / FTS writers while it runs, so the flush is fast; awaiting
                // it means the brand-new staged header is FTS-indexed and
                // `headerComplete=1` BEFORE the single end-of-merge
                // `.inboxDataDidChange` fires. The inbox query gates on
                // `headerComplete == true`, so this is the difference between the
                // pushed message appearing in this reload vs. waiting (invisibly)
                // for some unrelated later signal — now true even for image-only /
                // unresolved-CID mail that has no indexable body. For the bodied
                // subset, the pre-rendered body landing here too means the user
                // opens it with no "loading body" flash.
                if !allMergedHeaderIds.isEmpty {
                    // Dropped-render guard: the post-tx flush below ALSO flips
                    // headerComplete=1 (for body-less / unresolved-CID rows, AND as
                    // a backstop if phase 1's flushHeadersToFTS hit a transient error
                    // and returned 0). If neither phase has rendered yet
                    // (endOfMergeChanged still false), a header that's STILL
                    // headerComplete=0 here is about to become visible with no
                    // reload — so detect that and render. In the common case phase 1
                    // already flipped these to 1, so the count is 0 and nothing extra
                    // fires (no over-render). Cheap PK-indexed COUNT, post-tx only.
                    if !endOfMergeChanged {
                        // Immutable copy so the @Sendable read closure doesn't
                        // capture the mutable `allMergedHeaderIds` (Swift 6).
                        let idsForVisibilityCheck = allMergedHeaderIds
                        let placeholders = idsForVisibilityCheck.map { _ in "?" }.joined(separator: ",")
                        let stillHidden = (try? await AppDatabase.dbPool.read { db -> Int in
                            try Int.fetchOne(
                                db,
                                sql: "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND headerComplete = 0",
                                arguments: StatementArguments(idsForVisibilityCheck)
                            ) ?? 0
                        }) ?? 0
                        if stillHidden > 0 {
                            didMutate = true
                            endOfMergeChanged = true
                        }
                    }
                    await Self.flushNSEBatchToFTS(headerIds: allMergedHeaderIds, bodyItems: ftsBatch)
                }

                // Delete only the rows whose per-msg savepoint released AND
                // whose outer tx committed. Failed rows stay in staging with
                // populated=1 (the orphan reap only targets populated=0
                // placeholders, so they stay visible for the next wake's
                // retry; sync's update-existing path will also overwrite the
                // corresponding main-GRDB row regardless).
                do {
                    // Immutable copy so the (now async) @Sendable write closure
                    // doesn't capture the mutable `successfullyMergedIds`.
                    let idsToDelete = successfullyMergedIds
                    try await nseDB.write { db in
                        for id in idsToDelete {
                            try db.execute(sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: [id])
                        }
                    }
                } catch {
                    // Already idempotent across wakes. A suspension abort
                    // (ADR-IOS-041) is benign — don't log it as a failure.
                    if !error.isDatabaseSuspensionAbort {
                        print("[NSEDataBridge] Staging delete failed: \(error) — successfullyMergedIds may be re-merged next wake (idempotent)")
                    }
                }
            }

            // ============================================================
            // SKIP-SET STAGING CLEANUP.
            //
            // `skipSet` rows are durable + unchanged — no GRDB write was
            // needed for them at all — but a TERMINAL (aiCompleted) or
            // ABANDONED one still carries a now-redundant staging row (most
            // commonly: its terminal write landed on an EARLIER merge whose
            // subsequent staging-row DELETE failed, so it re-appears here,
            // still unchanged). Delete it directly against the staging DB —
            // no main-GRDB write involved, so this doesn't reintroduce the
            // writer contention the skip exists to avoid.
            // ============================================================
            let skipSetDeleteIds = skipSet
                .filter { $0.aiCompleted || $0.processedAt < abandonedCutoff }
                .map(\.id)
            if !skipSetDeleteIds.isEmpty {
                do {
                    try await nseDB.write { db in
                        for id in skipSetDeleteIds {
                            try db.execute(sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: [id])
                        }
                    }
                } catch {
                    // Idempotent across wakes, same as the writeSet delete above —
                    // a failure just means this (already-durable, unchanged) row
                    // re-appears next wake and is re-evaluated as a skip candidate.
                    if !error.isDatabaseSuspensionAbort {
                        print("[NSEDataBridge] Skip-set staging delete failed: \(error) — retried next wake (idempotent)")
                    }
                }
            }

            // ============================================================
            // STAGE-MEMO MAINTENANCE.
            //
            // Record the current stage key for every `writeSet` row that
            // committed this wake AND was KEPT (not deleted below) — the next
            // TRIGGER-ONLY re-merge of this exact content can now skip it.
            // Drop the memo entry for every row deleted this wake (writeSet's
            // terminal/abandoned + skip-set's terminal/abandoned) — a deleted
            // staging row has no "next merge" to skip. Finally, bound the memo
            // to rows still staged after this merge — defensive; the
            // record/drop above should already keep it exact, and a self-heal
            // over the (small) staged set costs nothing.
            // ============================================================
            stageMemo.withLock { memo in
                if outerCommitted {
                    let keptWriteSetIds = Set(committedMsgIds).subtracting(successfullyMergedIds)
                    for id in keptWriteSetIds {
                        if let msg = writeSetById[id] {
                            memo[id] = Self.stageKey(for: msg)
                        }
                    }
                }
                for id in successfullyMergedIds { memo.removeValue(forKey: id) }
                for id in skipSetDeleteIds { memo.removeValue(forKey: id) }
                let stillStagedIds = Set(processed.map(\.id))
                    .subtracting(successfullyMergedIds)
                    .subtracting(skipSetDeleteIds)
                memo = memo.filter { stillStagedIds.contains($0.key) }
            }
        }

        // 2. Process inbox removals — messages archived/deleted/moved while app was sleeping
        if mergeInboxRemovals(from: nseDB) { didMutate = true; endOfMergeChanged = true }

        // Consume pending task results
        if consumePendingTaskResults(from: nseDB) { didMutate = true; endOfMergeChanged = true }

        // Whenever the merge changed state, RECOMPUTE inbox unread counts (the merge
        // writes messageHeader but does NOT maintain folder.unreadCount). The merge
        // only ever touches inbox folders, so a blanket inbox recount is correct and
        // self-healing; it also sets the badge and refreshes the sidebar. A plain
        // updateBadge() here would just re-sum a stale counter (the desync bug).
        if didMutate {
            Task { await UnreadCountManager.shared.recountInboxFolders() }
        }

        // Robustness: reap stale `populated=0` placeholders. NSE has a hard
        // ~30 s OS budget; main-app ActiveAIQueue's lease goes stale at 4 s
        // once the process dies. 60 s is well past both — any populated=0
        // row older than that belongs to a process that was killed before
        // persistProcessedMessage could flip populated=1. Safe even while a
        // peer is mid-flight: ensureRow's INSERT OR IGNORE re-creates the row
        // on the next tryClaim, costing at most one duplicate LLM call
        // (lease state was already considered stale by then anyway).
        // Reuse the same stale window as the gradual-row abandon check above.
        do {
            // Return the count from the (now async) @Sendable write closure
            // rather than mutating a captured outer var.
            let reaped = try await nseDB.write { db -> Int in
                try db.execute(sql: """
                    DELETE FROM nse_processed_message
                    WHERE populated = 0 AND processedAt < ?
                    """, arguments: [abandonedCutoff])
                return db.changesCount
            }
            if reaped > 0 {
                print("[NSEDataBridge] Orphan reap: deleted \(reaped) stale placeholder(s) older than \(Int(staleStagingWindowSeconds))s")
            }
        } catch {
            // Best-effort. A failed reap is benign — the placeholders stay
            // populated=0 and remain invisible to merge; next wake retries.
            // (Includes ADR-IOS-041 suspension aborts; don't log those at all.)
            if !error.isDatabaseSuspensionAbort {
                print("[NSEDataBridge] Orphan reap failed: \(error)")
            }
        }

        // End-of-merge UI signal — the SECOND render of the two-phase merge
        // (phase 1 already posted the header-only render). Every stage (header →
        // body → summary → action → synchronous FTS flip → inbox removals → task
        // results) is now durable, so we post here instead of per-stage mid-flight
        // — less reload churn, and the row is fully visible (`headerComplete=1`)
        // and bodied when this reload reads. It carries `inboxReloadImmediate`
        // so the inbox reloads AT ONCE, bypassing its 500ms background-coalescing
        // debounce: this merge is the privileged, single-threaded boot-priority
        // step and must paint immediately (the debounce stays for the noisy
        // background producers — sync/backfill/AI — not for the merge).
        if endOfMergeChanged {
            MergeSurfaceProbe.markMergeSignal()
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .inboxDataDidChange,
                    object: nil,
                    userInfo: [Notification.Name.inboxReloadImmediateKey: true]
                )
                // Everything (headers, bodies, AI, removals) is durable — same
                // re-run signal as phase 1's for the open detail view; also
                // covers merges whose changes landed only in phase 2.
                NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
            }
            // Body-less NSE pushes need a PROACTIVE body fetch. The merge persists
            // a durable MessageBody ONLY for fully-resolved bodies
            // (`persistRenderedBodyFromStaging` drops unresolved-CID/inline-image
            // bodies, and an NSE that didn't render leaves none), so those land
            // `bodyComplete = 0`. Sync-discovered headers get enqueued into
            // `ActiveBodyQueue` by SyncEngine, but NSE-merged rows never were — so a
            // just-arrived inline-image message was body-fetched only on a cold user
            // open (server fetch — the "recently-arrived message is slow to render"
            // report) or whenever the queue next incidentally drained and re-scanned.
            // Kick the queue's self-scan (`bodyComplete=0 AND isInInbox=1`, dedup'd)
            // so a CID push is precached like any other inbox row.
            let mergedBodyLessRow = processed.contains {
                $0.hasUnresolvedCIDs || ($0.htmlContent == nil && $0.textContent == nil)
            }
            if mergedBodyLessRow {
                Task { await ActiveBodyQueue.shared.repopulateFromDatabase() }
            }
        } else if scrubbedStaleStagedRows {
            // F1 (PLAN_INBOX_UNIFIED_READ.md audit): scrub-only wake — the
            // stale-by-move block above scrubbed rows the pre-detection
            // `.messagesStaged` post already published, but nothing durable
            // happened this wake (`endOfMergeChanged` is false), so there is
            // otherwise no eviction trigger for a phantom row the VM may have
            // inserted from that post. Post ONLY the immediate reload — not
            // `.nseMergeDidCommit` (its contract is durable-render points
            // only, and nothing durable landed) and not the ActiveBodyQueue
            // kick (no body work happened). The reader no longer finds the
            // row in `latestStagedRows` (scrubbed above), and its
            // stale-by-move durable header suppresses it regardless (§2.1a),
            // so this reload evicts the phantom promptly. A MIXED wake (some
            // durable work alongside the scrub) takes the `endOfMergeChanged`
            // branch above instead, so this `else if` structurally preserves
            // the ≤2-posts-per-wake contract.
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .inboxDataDidChange,
                    object: nil,
                    userInfo: [Notification.Name.inboxReloadImmediateKey: true]
                )
            }
        }

        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[NSEDataBridge] mergeNSEStagingData: DONE in \(ms)ms (didMutate=\(didMutate))")
        BootProfiler.mark("mergeNSEStagingData DONE in \(ms)ms (didMutate=\(didMutate))")
    }

    // MARK: - Inbox Removals

    /// Merge inbox removal records from NSE staging DB.
    /// Messages that lost their INBOX label (archive/delete/move from another device)
    /// are removed from the inbox folder in main GRDB so the UI stays current on next wake.
    /// Returns true if any header rows were removed from main GRDB.
    /// Per-removal success tracking: failed rows stay in staging and retry
    /// next wake; only committed removals are cleared.
    private static func mergeInboxRemovals(from nseDB: DatabaseQueue) -> Bool {
        struct Removal {
            let id: String
            let accountId: String
            let messageId: String
        }

        let removals: [Removal]
        do {
            removals = try nseDB.read { db in
                guard try db.tableExists("nse_inbox_removal") else { return [] }
                return try Row.fetchAll(db, sql: "SELECT * FROM nse_inbox_removal").map { row in
                    Removal(id: row["id"], accountId: row["accountId"], messageId: row["messageId"])
                }
            }
        } catch {
            print("[NSEDataBridge] Inbox removal read failed: \(error)")
            return false
        }

        guard !removals.isEmpty else { return false }

        // Per-removal success tracking — only delete from staging the rows
        // whose main-GRDB write committed AND whose outer tx subsequently
        // committed. Failed rows stay for the next wake's retry.
        var successfullyConsumedIds: [String] = []
        var deletedTotal = 0
        var outerCommitted = false
        // 🚨 ORDERING CONTRACT (`MessageContentStore`): the content keys are captured
        // INSIDE the delete transaction, from the rows about to go away, and released
        // AFTER it commits. Reversed, the headers still exist when owners are counted,
        // the count is always ≥ 1, and nothing is ever released.
        //
        // This is the highest-FREQUENCY site that used to lean on the FK cascade —
        // every archive/delete/move performed on another device arrives here. Without
        // the release, Stage D would turn it into a recurring push-driven body leak,
        // reclaimed only by `runEvictStaleBodies` up to `bodyCacheTTLHours` later.
        var releasedContentKeys: [ContentKey] = []

        do {
            try AppDatabase.dbPool.write { db in
                // Resolve inbox folder ids once per merge using the authoritative
                // role marker. Replaces the old `folderId LIKE '%:INBOX'` scan,
                // which was both unindexable and semantically wrong for accounts
                // whose inbox path is not literally "INBOX" (localized/custom).
                let inboxFolderIds = try String.fetchAll(db,
                    sql: "SELECT id FROM folder WHERE role = ?",
                    arguments: [FolderRole.inbox.rawValue]
                )
                guard !inboxFolderIds.isEmpty else { return }
                let inboxPlaceholders = inboxFolderIds.map { _ in "?" }.joined(separator: ", ")

                for removal in removals {
                    // Each removal is one DELETE statement — atomic per
                    // statement. Recoverable errors (constraint) leave the
                    // outer tx alive and we move on; unrecoverable errors
                    // (IOERR/FULL/INTERRUPT) abort the outer tx and bubble
                    // out to the catch below.
                    do {
                        let doomedIds = try String.fetchAll(db, sql: """
                            SELECT id FROM messageHeader
                            WHERE accountId = ? AND messageId = ?
                              AND folderId IN (\(inboxPlaceholders))
                            """, arguments: StatementArguments([removal.accountId, removal.messageId] + inboxFolderIds))
                        try db.execute(sql: """
                            DELETE FROM messageHeader
                            WHERE accountId = ? AND messageId = ?
                              AND folderId IN (\(inboxPlaceholders))
                            """, arguments: StatementArguments([removal.accountId, removal.messageId] + inboxFolderIds))
                        deletedTotal += db.changesCount
                        successfullyConsumedIds.append(removal.id)
                        // ⚠ STAGE E1: a header id is handed here as a content key, the
                        // same crossing `SyncEngine.removeHeadersFromFTS` and
                        // `pruneOldMessages` already carry. Convert at the mint when
                        // the two key spaces diverge.
                        releasedContentKeys.append(contentsOf: doomedIds.map(ContentKey.init(rawValue:)))
                    } catch {
                        print("[NSEDataBridge] Per-removal failed for \(removal.id): \(error) — left in staging for retry")
                    }
                }
            }
            // dbPool.write returned normally → outer tx committed; the per-
            // removal DELETEs are durable and we can safely clear staging.
            outerCommitted = true
            print("[NSEDataBridge] Merged \(successfullyConsumedIds.count)/\(removals.count) inbox removal(s), deleted \(deletedTotal) header row(s)")
            // No post here — `performMerge` emits its immediate `.inboxDataDidChange`
            // at the end (this function's `deletedTotal > 0` return feeds `didMutate`).
        } catch {
            // Outer dbPool.write threw — even per-row DELETEs that we logged
            // as committed got rolled back with the outer tx. Don't clear
            // staging; let next wake retry the whole batch.
            print("[NSEDataBridge] Inbox removal merge failed (outer tx): \(error)")
        }

        // Staging cleanup gated on outer-tx success. If the outer commit
        // failed, every per-row DELETE was rolled back along with it, so the
        // staging rows must NOT be cleared — next wake will retry.
        guard outerCommitted else {
            return false
        }

        // The header deletes are durable now, so the owner count below sees the
        // post-delete world. Gated on `outerCommitted` for the same reason the
        // staging cleanup is: on a rolled-back outer tx the headers are still there,
        // every key would read as owned, and the release would be a no-op anyway.
        if !releasedContentKeys.isEmpty {
            let keys = releasedContentKeys
            // 🚨 ADR-IOS-031 — `.medium` is the FLOOR for anything touching GRDB, and
            // `releaseUnowned` touches the MAIN pool: one `pool.read` for the folder
            // roster, then a `pool.read` (ownership) plus a `pool.write` (delete) per
            // key, all on `AppDatabase.dbPool`. At `.utility` (QoS 17) this holds
            // reader/writer slots 8 QoS levels below MainActor's `.userInitiated`
            // (25) — the exact gap that stalls the render thread. Never lower this.
            Task.detached(priority: .medium) {
                await MessageContentStore.releaseUnowned(keys, stores: .body)
            }
        }

        // Clear only the removals that committed.
        try? nseDB.write { db in
            for id in successfullyConsumedIds {
                try db.execute(sql: "DELETE FROM nse_inbox_removal WHERE id = ?", arguments: [id])
            }
        }

        // Also remove any delivered notifications for committed removals.
        // Best-effort UI hygiene — uncommitted removals will retry next wake
        // and clear their notifications then.
        let center = UNUserNotificationCenter.current()
        let consumedSet = Set(successfullyConsumedIds)
        for removal in removals where consumedSet.contains(removal.id) {
            let notificationId = "email-\(removal.accountId)-\(removal.messageId)"
            center.removeDeliveredNotifications(withIdentifiers: [notificationId])
        }

        return deletedTotal > 0
    }

    // MARK: - Task Results

    /// Persist all NSE-staged task results into main-GRDB chatTurn.
    /// Returns true if any task results were persisted.
    /// Per-result success tracking: failed rows stay in staging and retry
    /// next wake; only committed results are cleared.
    private static func consumePendingTaskResults(from nseDB: DatabaseQueue) -> Bool {
        let results: [(id: Int, taskName: String, result: String, timestamp: Double)]
        do {
            results = try nseDB.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM nse_pending_task_result").map { row in
                    (id: row["id"] as Int, taskName: row["taskName"] as String,
                     result: row["result"] as String, timestamp: row["timestamp"] as Double)
                }
            }
        } catch {
            print("[NSEDataBridge] Task result read failed: \(error)")
            return false
        }

        guard !results.isEmpty else { return false }

        var successfullyConsumedIds: [Int] = []

        for result in results {
            // Each result already runs in its own dbPool.write — no savepoint
            // plumbing needed. Just track per-result success for the staging
            // delete below.
            do {
                try AppDatabase.dbPool.write { db in
                    // Deterministic id + INSERT OR IGNORE (data-integrity fix).
                    // A background `task_alarm` merge (`actor PushNotificationService`,
                    // off the main actor) can run CONCURRENTLY with a foreground
                    // merge; both read THIS staging row before either deletes it.
                    // A fresh `UUID()` would write TWO identical task-result turns
                    // into chat history (this is the only non-idempotent write in
                    // the merge). A stable id from the (AUTOINCREMENT, never-reused)
                    // staging-row id + firing timestamp makes the second writer's
                    // insert a no-op, so exactly one turn lands. The staging DB and
                    // chatTurn DB are wiped together on uninstall, so the row id
                    // can't collide with a turn from a prior install.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO chatTurn (id, timestamp, role, content, type, chars)
                        VALUES (?, ?, 'assistant', ?, 'task', ?)
                        """, arguments: [
                            "nse-task-\(result.id)-\(result.timestamp)",
                            result.timestamp,
                            result.result,
                            result.result.count
                        ])
                }
                successfullyConsumedIds.append(result.id)
                print("[NSEDataBridge] Persisted task result: \(result.taskName)")
            } catch {
                print("[NSEDataBridge] Failed to persist task result \(result.taskName): \(error) — left in staging for retry")
            }
        }

        // Delete only the staging rows whose chatTurn committed.
        try? nseDB.write { db in
            for id in successfullyConsumedIds {
                try db.execute(sql: "DELETE FROM nse_pending_task_result WHERE id = ?", arguments: [id])
            }
        }

        return !successfullyConsumedIds.isEmpty
    }

    // MARK: - User-label filtering (merge-path parity)

    /// Apply the provider-specific filter that `GmailProvider.extractUserLabelIds`,
    /// `IMAPProvider.buildMessageHeaderInfo`, and `ExchangeProvider.parseGraphMessage`
    /// each apply locally. Called inside the merge's GRDB write tx so the
    /// Gmail path can query the main `userLabel` table synchronously.
    ///
    /// **Gmail** — since label IDs are opaque (`Label_N`), we can't tell user
    /// vs system vs `tm_*` by the ID alone. Instead we take the path main-
    /// app already walks: look up each ID in the `userLabel` table. Only
    /// real user labels (rows with `isSystem=false`) are kept. tm_* labels
    /// aren't in that table (main-app `extractUserLabelIds` filters them
    /// out before insert). System labels are either absent or have
    /// `isSystem=true`. Zero extra I/O — the transaction already has `db`.
    /// Cold-start caveat: if this device's main-app hasn't yet called
    /// `fetchFolders`, `userLabel` is empty and no user labels materialize
    /// on the NSE row until sync runs. Push subscription normally follows
    /// a sync, so this is mostly hypothetical.
    ///
    /// **IMAP** — plain custom-keyword names. Strip `tm_*` and every
    /// exclusion `UserLabelStore.isExcludedKeyword` knows about.
    ///
    /// **Outlook** — a Graph message `category` IS Outlook's user label. Keep
    /// every category except the reserved `tm_*` namespace, through the SAME
    /// predicate `ExchangeProvider.parseGraphMessage` filters with and
    /// `stripLegacyCategories` DELETES with (ADR-IOS-036: action tags are
    /// local-only). Names are kept VERBATIM, unlike IMAP's lowercasing.
    fileprivate static func filterUserLabels(
        provider: String, rawLabels: [String],
        accountId: String, db: GRDB.Database
    ) throws -> [String] {
        switch provider {
        case "gmail":
            // Query userLabel for known non-system user labels on this
            // account. A single `IN` query covers all staged labelIds.
            //
            // 🚨 MATCHES AND RETURNS `providerLabelId`, NOT `id` (D10 /
            // `IOS-LABEL-001`). `rawLabels` are the provider's own label ids
            // straight off the push payload, and `userLabel.id` is now the
            // account-prefixed surrogate — matching against it would find
            // nothing and silently strip every Gmail user label from every
            // NSE-delivered message. This function's contract, on every
            // provider arm, is "bare provider label ids in, bare provider
            // label ids out"; the caller re-mints the surrogate.
            //
            // A6: `providerLabelId` is unindexed, so this is a scan of
            // `userLabel` rather than the previous primary-key probe. That
            // table holds a user's labels — tens of rows, one small page —
            // and an index to serve one NSE-merge lookup is not justified.
            guard !rawLabels.isEmpty else { return [] }
            let placeholders = rawLabels.map { _ in "?" }.joined(separator: ",")
            let args: [DatabaseValueConvertible] = [accountId] + rawLabels
            let known = try String.fetchAll(db, sql: """
                SELECT providerLabelId FROM userLabel
                WHERE accountId = ? AND isSystem = 0 AND providerLabelId IN (\(placeholders))
                """, arguments: StatementArguments(args))
            let knownSet = Set(known)
            return rawLabels.filter { knownSet.contains($0) }
        case "imap_new_mail", "imap", "icloud":
            // IMAP: strip system flags + tm_* + any other excluded keyword.
            return rawLabels.filter { !UserLabelStore.isExcludedKeyword($0) }
                .map { $0.lowercased() }  // Matches IMAPProvider's lowercase normalization.
        case "outlook":
            // Parity with `ExchangeProvider.parseGraphMessage`, which maps
            // `categories` straight into `userLabelIds` through this same
            // predicate (`e265428ff`). Before that commit both sides returned
            // `[]` and this arm was correct; afterwards it was the only path
            // still dropping them, so an NSE-delivered Outlook message carried
            // no label rows until the next main-app sync.
            //
            // ONE predicate, not a second copy: `isLegacyActionTagCategory` is
            // also what `stripLegacyCategories` uses to DELETE `tm_*`
            // categories from the server, so a category that path erases can
            // never be surfaced here as a label the user owns.
            //
            // 🚨 VERBATIM — do NOT lowercase. The IMAP arm above lowercases
            // because RFC 3501 keywords are case-INsensitive; Graph category
            // names are case-SENSITIVE display strings, and the main-app read
            // and write paths both keep them unchanged. Lowercasing here would
            // mint a second `UserLabel.id` for one category.
            return rawLabels.filter { !ExchangeProvider.isLegacyActionTagCategory($0) }
        default:
            return []
        }
    }

    // MARK: - Clear Notification on Read

    /// Remove the notification for a message from Notification Center.
    /// Call when user reads a message in the app.
    static func clearNotification(accountId: String, messageId: String) {
        let notificationId = "email-\(accountId)-\(messageId)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
    }

    // MARK: - Pending op queue (idempotent)

    /// Queue a `setTag` pending operation with a deterministic id, so re-runs
    /// of the merge (e.g. after a crash between write + staging-row delete)
    /// don't stack duplicate ops for the same message+tag. The deterministic
    /// id + `INSERT OR IGNORE` makes dedup explicit — on collision the existing
    /// queued op is preserved; other SQL errors surface via `throws`.
    ///
    /// Skips entirely when tag is nil, empty, or "none" (no IMAP write needed).
    fileprivate static func queueSetTagPendingOp(
        db: GRDB.Database, accountId: String, messageId: String, tag: String?
    ) throws {
        guard let tag, !tag.isEmpty, tag != "none" else { return }
        let messageIdsJSON = (try? JSONSerialization.data(withJSONObject: [messageId]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // Deterministic id: (accountId, messageId, setTag, tag) tuple.
        let id = "setTag:\(accountId):\(messageId):\(tag)"
        try db.execute(sql: """
            INSERT OR IGNORE INTO pendingOperation (id, type, messageIdsJSON, accountId, folderPath, tagValue, createdAt, status, retryCount)
            VALUES (?, 'setTag', ?, ?, 'INBOX', ?, ?, 'queued', 0)
            """, arguments: [id, messageIdsJSON, accountId, tag, Date()])
    }

    // MARK: - NSE-rendered Body Persistence (merge path)

    /// Persist a RenderedBody produced by the NSE into main GRDB's MessageBody +
    /// messageHeader.bodyComplete + FTS. Called from mergeNSEStagingData inside
    /// the same write transaction. Skips silently when NSE didn't render a body
    /// (e.g. old NSE build, or body fetch failed at NSE time).
    ///
    /// bodyComplete = !hasUnresolvedCIDs. Non-CID mail (the majority) becomes
    /// bodyComplete=true and the main app's body queue never re-fetches. CID-having
    /// mail stays bodyComplete=false; the first user open triggers the existing
    /// main-app fetch+render path which resolves CIDs into data URIs.
    ///
    /// Fully idempotent — re-running is safe:
    ///   - MessageBody `insert(onConflict: .ignore)` preserves any earlier body.
    ///   - UPDATE messageHeader is a deterministic write of the same values.
    ///   - FTS write is fire-and-forget and the index is itself idempotent on id.
    ///
    /// IMPORTANT: we only insert `MessageBody` when `hasUnresolvedCIDs == false`.
    /// Main-app `BodyFetchProcessor.process` uses `insert(onConflict: .ignore)`,
    /// which would skip overwriting an NSE-persisted unresolved-CID body when
    /// the re-fetch arrives. Not persisting placeholder bodies leaves the
    /// re-render free to insert the fully-resolved version cleanly, and the UI
    /// shows its "loading body..." state for the ~1s before re-fetch completes.
    /// Snippet + FTS + bodyComplete flag are still updated because they don't
    /// depend on CID resolution.
    /// In-tx part of the NSE body persistence: inserts `MessageBody` (for fully-
    /// resolved bodies only) and updates `snippet`. If the message has a non-empty
    /// plain-text body and no unresolved CIDs, its `headerId` + text are appended
    /// to `ftsBatch` so the caller can run ONE batched FTS pipeline after the main
    /// transaction commits (see `flushNSEBatchToFTS`). This avoids spawning N
    /// concurrent detached Tasks each doing small FTS writes — critical during
    /// heavy catch-up wakes with many staged messages.
    ///
    /// Invariants `headerComplete=1 ⇒ FTS has header` and `bodyComplete=1 ⇒ FTS
    /// has body` are enforced by the post-tx batch flush, NOT here. Neither flag
    /// is ever touched inside the main tx.
    /// One bodied message queued by a merge savepoint for the post-transaction
    /// FTS pass.
    ///
    /// 🚨 **THIS CARRIES TWO DIFFERENT IDS ON PURPOSE.** `flushNSEBatchToFTS`
    /// uses each entry for two unrelated jobs:
    ///   • `contentKey` addresses the **FTS row** the body text is written into
    ///     (`message_ids.headerId` / `messages_fts_YYYY`).
    ///   • `headerId` addresses the **`messageHeader` row** whose `bodyComplete`
    ///     flag the very same pass flips.
    ///
    /// They are the same string today. They stop being the same string at Stage
    /// E1, when the content key's tail moves off the provider id
    /// (`ContentKeySpace`). If a single field fed both jobs, the
    /// `UPDATE messageHeader SET bodyComplete = 1 WHERE id IN (…)` would match
    /// **nothing** for UID-addressed accounts and the user's pushed mail would
    /// never become visible. Keep the two fields separate; the type is what
    /// stops them being collapsed.
    struct NSEFTSBodyItem: Sendable {
        let contentKey: ContentKey
        let headerId: String
        let textContent: String
    }

    fileprivate static func persistRenderedBodyFromStaging(
        db: GRDB.Database,
        headerId: String,
        htmlContent: String?,
        textContent: String?,
        attachmentsJSON: String?,
        icsText: String?,
        hasUnresolvedCIDs: Bool,
        ftsBatch: inout [NSEFTSBodyItem]
    ) throws {
        // Nothing to persist — NSE didn't render (old build / fetch failure).
        guard htmlContent != nil || textContent != nil else { return }

        // Insert MessageBody ONLY for fully-resolved bodies. Unresolved-CID
        // bodies are dropped on the floor; main app re-fetches + re-renders.
        if !hasUnresolvedCIDs {
            // `htmlContent` is the display-ready html the NSE's BodyRenderer produced
            // (plain bodies already converted there) — store it as-is, no re-conversion.
            var body = MessageBody.create(contentKey: ContentKey(rawValue: headerId), htmlBody: htmlContent)
            // Diagnostic (debug-gated, no-op in prod): flag a double-escaped stored body.
            BackgroundSyncLogger.diagnoseStoredBody(source: "NSEMerge", headerId: headerId, htmlContent: body.htmlContent)
            body.attachmentsJSON = attachmentsJSON
            body.icsText = icsText
            // Diagnostic: time the HTML-blob insert + log its size. The merge-write
            // decomposition showed 0ms writer-wait but a ~1.3s (up to 8s) in-tx write
            // for ONE message — suspect is a large newsletter body (inline base64
            // images = multi-MB blob). If a slow merge shows a big htmlLen here eating
            // the time, that's confirmed; the fix is to keep the large body off the
            // merge critical path (header surfaces instantly, body lands async).
            let bodyInsT0 = CFAbsoluteTimeGetCurrent()
            try body.insert(db, onConflict: .ignore)
            BootProfiler.mark("merge: MessageBody insert htmlLen=\(htmlContent?.count ?? 0) in \(Int((CFAbsoluteTimeGetCurrent() - bodyInsT0) * 1000))ms")
        }

        // Snippet computed from plain text via shared EmailFilter (matches main-app path).
        // Timed (with textLen) because this runs EVEN when the body insert is skipped
        // (unresolved-CID NSE bodies), so if a slow merge has no body-insert mark, this
        // is the next suspect — `snippetFromPlainText` over a very large plain-text body.
        let snipT0 = CFAbsoluteTimeGetCurrent()
        let snippet = textContent.map { EmailFilter.snippetFromPlainText($0) } ?? ""
        if !snippet.isEmpty {
            // `AND snippet IS NOT ?` makes a same-value re-write a true no-op (0
            // rows changed) — so a foreground re-merge of an already-snippeted row
            // doesn't inflate the merge's `total_changes()`, which gates the
            // end-of-merge render. The snippet still updates whenever it differs.
            try db.execute(sql: """
                UPDATE messageHeader SET snippet = ? WHERE id = ? AND snippet IS NOT ?
                """, arguments: [snippet, headerId, snippet])
        }
        let snipMs = Int((CFAbsoluteTimeGetCurrent() - snipT0) * 1000)
        if snipMs > 20 {
            BootProfiler.mark("merge: snippet from plainText textLen=\(textContent?.count ?? 0) in \(snipMs)ms")
        }

        // Queue up the FTS BODY work. `flushNSEBatchToFTS` runs once per merge with
        // the full batch — amortizes FTS transaction overhead. Unresolved-CID and
        // empty-text messages skip the BODY batch (no indexable plain text), so
        // their `bodyComplete` stays 0 and the body queue fetches the body later.
        // Their HEADER is still FTS-indexed + flipped headerComplete=1 via the merge's
        // all-headers path (`allMergedHeaderIds`), so they ARE inbox-visible at merge
        // time — they no longer wait for a recoverIncompleteHeaders pass.
        if let text = textContent, !text.isEmpty, !hasUnresolvedCIDs {
            // ⚠ STAGE E1: `persistRenderedBodyFromStaging` receives only a
            // `headerId` — the staged message's RFC id / provider space are not
            // threaded here yet, so the content key is asserted from the header
            // id rather than minted by `ContentKey.forHeader`.
            ftsBatch.append(NSEFTSBodyItem(
                contentKey: ContentKey(rawValue: headerId),
                headerId: headerId,
                textContent: text
            ))
        }
    }

    /// Phase-1 header-only FTS flush. Mirrors steps 1–3 of `flushNSEBatchToFTS`
    /// (bulk header read → `indexHeaders` → bulk `headerComplete=1`) and STOPS —
    /// it never touches the body half. Used by the two-phase merge to make each
    /// staged message inbox-VISIBLE on a lightweight header write, off the (1.3–8s
    /// for large bodies) body-blob critical path.
    ///
    /// Idempotent: `indexHeaders` skips known IDs and the `headerComplete=1` flip
    /// is a no-op the second time, so phase 2's `flushNSEBatchToFTS` re-running the
    /// same IDs is harmless. Same log-and-return error handling as the steps it
    /// copies.
    ///
    /// - Returns: the number of headers this call flipped from `headerComplete=0`
    ///   → `1` (i.e. became NEWLY inbox-visible). 0 means everything was already
    ///   visible (or an error short-circuited) — the caller uses this to skip a
    ///   redundant render. Indexing + the flip still run for ALL ids regardless.
    fileprivate static func flushHeadersToFTS(headerIds: [String]) async -> Int {
        guard !headerIds.isEmpty else { return 0 }

        // 1. Bulk read ALL merged headers (regardless of body presence).
        let headersById: [String: MessageHeader]
        do {
            headersById = try await AppDatabase.dbPool.read { db in
                let headers = try MessageHeader
                    .filter(headerIds.contains(Column("id")))
                    .fetchAll(db)
                return Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0) })
            }
        } catch {
            print("[NSEDataBridge] FTS header flush: bulk header read failed: \(error) — next wake will recover")
            return 0
        }

        // Filter to headers that actually exist (handle races where a header was
        // deleted/moved between merge and flush). Preserve merge order.
        let validHeaders = headerIds.compactMap { headersById[$0] }
        guard !validHeaders.isEmpty else { return 0 }

        // DIAGNOSTIC (debug-gated): step-1 main-pool read done. Remove once pinned.
        BootProfiler.mark("merge phase1 flush: header read done (\(validHeaders.count))")

        // 2. Batch FTS header indexing for ALL merged headers. Idempotent — known
        //    IDs are skipped; header records carry no body, so this is cheap.
        let records = validHeaders.map { header -> FTSHeaderRecord in
            FTSHeaderRecord(
                contentKey: ContentKey(rawValue: header.id),
                headerId: header.id,
                messageId: header.messageId,
                subject: header.subject,
                from: "\(header.from) <\(header.fromAddress)>",
                to: header.to,
                cc: header.cc,
                bcc: header.bcc,
                dateMs: Int64(header.date.timeIntervalSince1970 * 1000),
                folderId: header.folderId
            )
        }
        do {
            _ = try await SearchIndex.shared.indexHeaders(records)
        } catch {
            print("[NSEDataBridge] FTS header flush: indexHeaders failed: \(error) — recoverIncompleteHeaders will retry next wake")
            return 0
        }

        // DIAGNOSTIC (debug-gated): step-2 SearchIndex-actor indexHeaders done. If
        // the big gap lands between the step-1 mark and THIS one, the stall is the
        // serial SearchIndex actor contending with background updateBodies/
        // indexHeaders. Remove once pinned.
        BootProfiler.mark("merge phase1 flush: FTS indexHeaders done")

        // 3. Batch flip headerComplete=1 for the indexed headers that are NOT yet
        //    visible → inbox-visible NOW. The inbox query gates on headerComplete
        //    == true, so this is what surfaces the pushed message. The `AND
        //    headerComplete = 0` clause keeps the flip idempotent AND makes
        //    `changesCount` the count of headers that became NEWLY visible — the
        //    caller renders only when that's > 0.
        // ⚠ `[String]` is load-bearing (F2): this list is bound into a
        // `WHERE messageHeader.id IN (…)` predicate, so it MUST be the HEADER id.
        // `records.map(\.contentKey)` must not compile here.
        let indexedIds: [String] = validHeaders.map(\.id)
        do {
            return try await AppDatabase.dbPool.write { db -> Int in
                let placeholders = indexedIds.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id IN (\(placeholders)) AND headerComplete = 0",
                    arguments: StatementArguments(indexedIds)
                )
                return db.changesCount
            }
        } catch {
            print("[NSEDataBridge] FTS header flush: headerComplete update failed: \(error)")
            return 0
        }
    }

    /// Batched post-tx FTS pipeline for all NSE-merged messages in a single wake.
    /// Runs after the main merge transaction commits, in a single detached Task.
    /// Amortizes FTS and GRDB write overhead across the whole batch.
    ///
    /// Header visibility (`headerComplete`) is DECOUPLED from body indexing:
    /// `headerIds` is EVERY merged message; `bodyItems` is the subset that had a
    /// rendered, CID-resolved, non-empty plain-text body.
    ///
    /// Pipeline steps:
    ///   1. Bulk read MessageHeaders for ALL `headerIds` → build FTSHeaderRecords.
    ///   2. `SearchIndex.shared.indexHeaders(records)` — idempotent on known IDs.
    ///   3. Bulk `UPDATE messageHeader SET headerComplete=1 WHERE id IN (...)` —
    ///      makes EVERY merged message inbox-visible at merge time (image-only /
    ///      unresolved-CID / body-less mail included; the inbox query gates on
    ///      headerComplete == true).
    ///   4. `SearchIndex.shared.updateBodies(bodyItems)` — body subset only;
    ///      returns set of confirmed IDs.
    ///   5. Bulk `UPDATE messageHeader SET bodyComplete=1 WHERE id IN (confirmed)`.
    ///   6. Enqueue AI (inbox only) + embedding for confirmed items.
    ///
    /// On partial failure at any step, flags already set stay set and the rest
    /// heal via `recoverIncompleteHeaders`, the body queue (`bodyComplete=0`
    /// refetch), and drain-time self-repopulate.
    fileprivate static func flushNSEBatchToFTS(
        headerIds: [String],
        bodyItems: [NSEFTSBodyItem]
    ) async {
        guard !headerIds.isEmpty else { return }

        // 1. Bulk read ALL merged headers (regardless of body presence).
        let headersById: [String: MessageHeader]
        do {
            headersById = try await AppDatabase.dbPool.read { db in
                let headers = try MessageHeader
                    .filter(headerIds.contains(Column("id")))
                    .fetchAll(db)
                return Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0) })
            }
        } catch {
            print("[NSEDataBridge] FTS batch: bulk header read failed: \(error) — next wake will recover")
            return
        }

        // Filter to headers that actually exist (handle races where a header was
        // deleted/moved between merge and flush). Preserve merge order.
        let validHeaders = headerIds.compactMap { headersById[$0] }
        guard !validHeaders.isEmpty else { return }

        // 2. Batch FTS header indexing for ALL merged headers. Idempotent — known
        //    IDs are skipped; header records carry no body, so this is cheap.
        let records = validHeaders.map { header -> FTSHeaderRecord in
            FTSHeaderRecord(
                contentKey: ContentKey(rawValue: header.id),
                headerId: header.id,
                messageId: header.messageId,
                subject: header.subject,
                from: "\(header.from) <\(header.fromAddress)>",
                to: header.to,
                cc: header.cc,
                bcc: header.bcc,
                dateMs: Int64(header.date.timeIntervalSince1970 * 1000),
                folderId: header.folderId
            )
        }
        do {
            _ = try await SearchIndex.shared.indexHeaders(records)
        } catch {
            print("[NSEDataBridge] FTS batch: indexHeaders failed: \(error) — recoverIncompleteHeaders will retry next wake")
            return
        }

        // 3. Batch flip headerComplete=1 for ALL indexed headers → inbox-visible
        //    NOW. This is the fix for body-less / unresolved-CID pushed mail being
        //    invisible until a later recoverIncompleteHeaders pass.
        // ⚠ `[String]` is load-bearing (F2): this list is bound into a
        // `WHERE messageHeader.id IN (…)` predicate, so it MUST be the HEADER id.
        // `records.map(\.contentKey)` must not compile here.
        let indexedIds: [String] = validHeaders.map(\.id)
        do {
            try await AppDatabase.dbPool.write { db in
                let placeholders = indexedIds.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(indexedIds)
                )
            }
        } catch {
            print("[NSEDataBridge] FTS batch: headerComplete update failed: \(error)")
            return
        }

        // 4. Batch FTS BODY write — ONLY the subset that had a rendered, CID-
        //    resolved, non-empty plain-text body (`bodyItems`). Body-less rows are
        //    now headerComplete=1 / bodyComplete=0, so the body queue fetches them
        //    (we never set bodyComplete for a body we didn't index — "never mark
        //    unfetched content as fetched").
        let validBodyItems = bodyItems.compactMap { item -> (item: NSEFTSBodyItem, header: MessageHeader)? in
            guard let header = headersById[item.headerId] else { return nil }
            return (item, header)
        }
        guard !validBodyItems.isEmpty else { return }

        // FTS write keys by CONTENT; the confirmation set that comes back is
        // therefore in content-key space and must be intersected with
        // `item.contentKey` — NEVER with `item.headerId` (F2).
        let ftsBodies = validBodyItems.map { (contentKey: $0.item.contentKey, body: $0.item.textContent) }
        let written: Set<ContentKey>
        do {
            written = try await SearchIndex.shared.updateBodies(ftsBodies)
        } catch {
            print("[NSEDataBridge] FTS batch: updateBodies failed: \(error) — body queue will retry")
            return
        }

        let confirmedItems = validBodyItems.filter { written.contains($0.item.contentKey) }
        guard !confirmedItems.isEmpty else {
            print("[NSEDataBridge] FTS batch: no body writes confirmed (\(ftsBodies.count) attempted) — body queue will retry")
            return
        }

        // 5. Batch flip bodyComplete=1 for confirmed writes.
        // ⚠ `[String]` is load-bearing (F2): bound into `WHERE messageHeader.id
        // IN (…)`, so it takes the HEADER id even though the membership test
        // above ran in content-key space.
        let confirmedIds: [String] = confirmedItems.map(\.item.headerId)
        do {
            try await AppDatabase.dbPool.write { db in
                let placeholders = confirmedIds.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(confirmedIds)
                )
            }
        } catch {
            print("[NSEDataBridge] FTS batch: bodyComplete update failed: \(error)")
            return
        }

        // 6. Enqueue downstream queues (reply precompute + embedding). `enqueue`
        // dedups per-actor.
        //
        // On a FOREGROUND merge (the user opened right after the push), DEFER the
        // heavy herd until the freshly-surfaced message has PAINTED + a short
        // settle — so reply-precompute (SSE/tool LLM) and the CoreML embedding
        // don't contend with first render. The DB side of that contention is
        // already handled by the background pool (those queues now yield to UI
        // writes); this settle covers the non-DB CPU/network cost the gate can't
        // see. On a BACKGROUND merge (silent push / BGAppRefresh) there's no paint
        // to wait for and precomputing the reply before the user ever opens is the
        // whole point, so enqueue at once.
        //
        // Resilience: if this detached task is dropped (app killed), the message
        // is re-discovered by `ActiveAIQueue.repopulateFromDatabase` on the next
        // foreground poll — the enqueue is an optimization, not the only path.
        // ⚠️ ...but only WITHIN THE WINDOW (ADR-IOS-078 pathway regating; comment
        // corrected 2026-08-20, iOS #66). `repopulationCandidates` selects only the
        // newest `SyncConfig.maxRecentEmails` Inbox rows, while the AI enqueue below
        // is deliberately window-EXEMPT (a pushed message is new mail the user was
        // just notified about). A pushed message whose INTERNALDATE puts it outside
        // that window — IMAP COPY preserves INTERNALDATE, so a message another client
        // moved into the Inbox can be new to US and old by date — is therefore NOT
        // re-discovered if this task is dropped. Accepted per ADR-IOS-078's residual
        // invariant: fail-closed, non-durable, one-gesture recoverable (opening it
        // re-enters the exempt direct path). Do NOT widen the sweep to "fix" it.
        let downstream: [(headerId: String, accountId: String, isInInbox: Bool)] =
            confirmedItems.map { ($0.item.headerId, $0.header.accountId, $0.header.isInInbox) }
        Task.detached(priority: .utility) {
            // Gate only when a REAL foreground app is running. `dbReady` is true at
            // any production merge time (the merge needs the DB) and false in unit
            // tests, which never boot AppStartup — so tests skip the gate, enqueue
            // immediately (old behavior), and never trigger ensureDatabaseReady() /
            // a DB build from this detached task. Background launches (isAppActive
            // false) also skip — reply precompute should run ASAP there.
            let booted = await MainActor.run { AppStartup.shared.dbReady }
            if DatabaseSuspension.isAppActive && booted {
                await AppStartup.shared.awaitLaunchReady(background: false)
                try? await Task.sleep(for: .seconds(SyncConfig.nseMergeHerdSettleSeconds))
            }
            // Task.detached starts with inPrivilegedContext = false (task-locals
            // don't cross the detach), so a drain kicked here can't inherit the
            // merge's gate exemption — keep the explicit reset for clarity (FIX 6d).
            await PriorityGate.$inPrivilegedContext.withValue(false) {
                for item in downstream {
                    if item.isInInbox {
                        // ADR-IOS-078 pathway regating (owner directive
                        // 2026-08-19): a pushed message is new mail the user was
                        // just notified about — window-exempt. Inbox scope is
                        // this producer's own `isInInbox` check plus the
                        // executor's unconditional membership re-check.
                        await ActiveAIQueue.shared.enqueue(
                            headerId: item.headerId, accountId: item.accountId, windowExempt: true)
                    }
                    await ActiveEmbeddingQueue.shared.enqueue(headerId: item.headerId)
                }
            }
        }

        if confirmedItems.count > 1 {
            print("[NSEDataBridge] FTS batch: wrote \(confirmedItems.count) headers + bodies in one pass")
        }
    }

    /// When NSE delivered an active (reminder) notification, mark the same
    /// reminder hash in ReachedOutStore so ProactiveNotifyService's dedup path
    /// won't re-deliver a second notification for the same reminder.
    ///
    /// Must compute the hash the same way `ReminderBuilder` does — uses
    /// `rfc822MessageId` when present, else falls back to the GRDB header id
    /// (which `ReminderBuilder` passes as `uniqueId: msg.id`).
    private static func markReachedOutIfNotified(
        notified: Bool,
        reminderContent: String?,
        rfc822MessageId: String?,
        headerId: String
    ) {
        guard notified,
              let content = reminderContent,
              !content.isEmpty else { return }
        let hash = DisabledRemindersStore.hashReminder(
            source: "message",
            content: content,
            uniqueId: headerId,
            rfc822MessageId: rfc822MessageId
        )
        ReachedOutStore.markNotified(hash: hash)
    }

    // MARK: - Hoisted types and helpers (testable from TabMailTests)

    /// One row from the NSE staging DB's `nse_processed_message` table.
    ///
    /// Hoisted to type-level (from its prior nested home inside
    /// `mergeNSEStagingData`) so `TabMailTests` can construct it and drive
    /// `insertNewHeaderFromStaging` end-to-end against an in-memory GRDB
    /// instead of simulating the merge with duplicated inline SQL.
    ///
    /// Any change to this shape MUST also update:
    ///   1. `NSEStagingDB.persistProcessedMessage` (writer, NSE target).
    ///   2. `AppDatabase.createNSEStagingDBIfNeeded` (schema migration).
    ///   3. The `Row.fetchAll` decoder inside `mergeNSEStagingData`.
    struct StagedMessage: Equatable {
        let id: String
        let accountId: String
        let accountEmail: String
        /// Provider from the push payload (`gmail` / `outlook` / `imap_new_mail`).
        /// Drives `filterUserLabels`'s per-provider behavior.
        let provider: String
        let messageId: String
        let rfc822MessageId: String?
        let threadId: String?
        /// Provider-canonical folder path that NSE captured (Gmail: "INBOX";
        /// Outlook/Graph: parentFolderId; IMAP: "INBOX"). Matches what
        /// main-app sync uses so `MessageHeader.id` / `folderId` align.
        let folderPath: String
        let subject: String
        let senderName: String
        let senderEmail: String
        let snippet: String
        let date: Double?
        // v4 (2026-04-19): full header — previously dropped, producing
        // placeholder rows that violated CLAUDE.md Data Integrity Rule #1.
        let to: String
        let cc: String
        let bcc: String
        let replyTo: String?
        let inReplyTo: String?
        let references: [String]
        let isRead: Bool
        let isFlagged: Bool
        let hasAttachments: Bool
        /// IMAP-only: the `\Answered` / `$Forwarded` flags. Gmail/Graph
        /// always stage false. Matches main-app sync's provider behavior.
        let isReplied: Bool
        let isForwarded: Bool
        /// Raw provider-label list (Gmail labelIds / Outlook categories /
        /// IMAP custom keywords). Filtered per-provider by `filterUserLabels`
        /// before insertion as `MessageUserLabel` junction rows.
        let providerLabels: [String]
        let summaryBlurb: String?
        let summaryTodos: String?
        let actionTag: String?
        let reminderDate: String?
        let reminderTime: String?
        let reminderContent: String?
        let processedAt: Double
        let aiCompleted: Bool
        let notified: Bool
        // v2: body persisted by NSE so merge can write MessageBody + FTS without re-fetch.
        let htmlContent: String?
        let textContent: String?
        let attachmentsJSON: String?
        let icsText: String?
        let hasUnresolvedCIDs: Bool
        /// The UIDVALIDITY the NSE's OWN live SELECT observed at fetch time
        /// (IMAP only; `nil` for Gmail/Graph, and for any row staged before the
        /// `nse_processed_message.observedUidValidity` column existed). Written by
        /// `NSEStagingDB.stageHeader` / `persistProcessedMessage` in the extension
        /// process; read HERE, in the main app, usually after that process is gone
        /// — which is why it had to be a durable column and not process-local
        /// state. Consumed by `uidValidityStagingRowStatus` and
        /// `nseMergeIdentityConfirmed`.
        ///
        /// PORT of `v2final`'s `NSEDataBridge.StagedMessage.observedUidValidity`
        /// (commit `4d34ee864`), including its `var`-not-`let` rationale: a `let`
        /// with a default is EXCLUDED from the synthesized memberwise initializer
        /// entirely, whereas a `var` with one participates with that default — so
        /// every pre-existing `StagedMessage(...)` construction site (merge helpers
        /// and their tests) compiles unchanged.
        var observedUidValidity: Int? = nil
    }

    /// Body of the "insert new MessageHeader from NSE staging" branch of
    /// `mergeNSEStagingData`, extracted so tests can exercise it directly.
    /// Runs inside an existing GRDB write transaction (`db`).
    ///
    /// Populates the new header with every field the staging row carries —
    /// recipients, thread chain, flags, provider labels. No placeholder
    /// values. On a collision with an existing row (sync raced ahead), the
    /// INSERT is a no-op and the function returns `false`.
    ///
    /// Side effects on success:
    ///   • MessageHeader INSERT OR IGNORE (all full-header fields).
    ///   • `ThreadUtils.assignComputedThreadId` for subject-based threading
    ///     fallback parity with sync.
    ///   • `MessageBody` + FTS batching via `persistRenderedBodyFromStaging`
    ///     (body is also staged in v2).
    ///   • `MessageReference` junction rows for the references chain.
    ///   • `MessageUserLabel` junction rows for `filterUserLabels`-filtered
    ///     labels.
    ///   • `ReachedOutStore.markNotified` if the NSE delivered an active
    ///     reminder notification.
    ///   • `pendingOperation` row for IMAP tag sync (via `queueSetTagPendingOp`).
    ///   • `messageAICache` entry if AI completed.
    ///
    /// Returns `true` if the INSERT created a new row; `false` if sync raced
    /// ahead and the INSERT OR IGNORE no-oped.
    @discardableResult
    static func insertNewHeaderFromStaging(
        _ msg: StagedMessage,
        db: GRDB.Database,
        ftsBatch: inout [NSEFTSBodyItem],
        headerOnly: Bool = false
    ) throws -> Bool {
        // CRITICAL: use the folderPath NSE captured from the provider
        // (Gmail: "INBOX"; Outlook/Graph: parentFolderId; IMAP: "INBOX")
        // — NOT a hardcoded "INBOX". Sync for Outlook constructs its
        // header with folderPath=parentFolderId, so a hardcoded "INBOX"
        // here produces a different MessageHeader.id and leaves two rows
        // in GRDB. See historical bug 2b.
        let folderId = MessageIdentity.folderId(
            accountId: msg.accountId, folderPath: msg.folderPath
        )
        let msgDate = msg.date.map { Date(timeIntervalSince1970: $0) } ?? Date()
        var header = MessageHeader(
            messageId: msg.messageId,
            subject: msg.subject,
            from: msg.senderName,
            fromAddress: msg.senderEmail,
            to: msg.to,
            date: msgDate,
            // Display snippet, not raw staging value — raw Gmail/Graph provider
            // snippets are entity-encoded ("weird snippet" bug); body-derived
            // preferred so it matches what the phase-2/snippet pipeline settles on.
            snippet: stagedDisplaySnippet(
                providerSnippet: msg.snippet, textContent: msg.textContent
            ),
            folderId: folderId,
            accountId: msg.accountId,
            folderPath: msg.folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = msg.rfc822MessageId
        // The epoch under which the NSE's own live SELECT observed this UID.
        // Both epoch ARMs have already run before a row reaches here — ARM 1
        // (`detectOldEpochStagedRows` → `applyOldEpochStagingCleanup`) DELETES a
        // staged row whose epoch positively disagrees with a settled folder
        // epoch, and ARM 2 keeps a quarantined row for retry instead of merging
        // it — so no positively-stale value can be written by this line. Writing
        // nil where a proven value exists was the only one of the three options
        // that manufactured a false "unknown" (`IOS-NSE-001`). Normalized
        // through `SyncEngine.knownUidValidity` so the `0` sentinel never
        // reaches a column other readers test only for non-nil.
        header.observedUidValidity = SyncEngine.knownUidValidity(msg.observedUidValidity)
        header.inReplyTo = msg.inReplyTo
        header.referencesJSON = MessageHeader.encodeReferences(msg.references)
        header.cc = msg.cc
        header.bcc = msg.bcc
        header.replyTo = msg.replyTo
        header.isRead = msg.isRead
        header.isFlagged = msg.isFlagged
        header.hasAttachments = msg.hasAttachments
        header.isReplied = msg.isReplied
        header.isForwarded = msg.isForwarded
        header.threadId = msg.threadId
        // Subject-based thread-ID fallback parity with sync
        // (SyncEngineFullSync computes this on insert). Without this, a
        // pushed message sits in a singleton thread until sync materializes
        // the row again.
        // Timed: new-header path only. assignComputedThreadId runs up to 3 indexed
        // IN-probes over messageHeader for reply-chain adoption — fast normally, but
        // the other merge-write suspect if the body/snippet marks come back cheap.
        let threadT0 = CFAbsoluteTimeGetCurrent()
        try ThreadUtils.assignComputedThreadId(
            to: &header, nativeThreadId: msg.threadId, db: db
        )
        let threadMs = Int((CFAbsoluteTimeGetCurrent() - threadT0) * 1000)
        if threadMs > 20 {
            BootProfiler.mark("merge: assignComputedThreadId (new header) in \(threadMs)ms")
        }
        header.notified = msg.notified
        // headerComplete reflects "row exists in FTS". Stays false until
        // `flushNSEBatchToFTS` indexes the FTS header row (and sets the flag).
        // The inbox query gates on headerComplete == true, so this row is
        // INVISIBLE until the post-tx flush flips it — which it now does for
        // EVERY merged header (not just bodied ones), so an image-only /
        // unresolved-CID push appears at merge time. The body queue's filter
        // (headerComplete=1 AND bodyComplete=0) then fetches any missing body.
        header.headerComplete = false

        // Action tag (ADR-IOS-036): local-only. NSE writes its AI-computed
        // value into MessageHeader; provider labels are not consulted.
        //
        // `headerOnly` (phase-1 pre-pass) SKIPS the AI header fields — phase 2
        // writes summary/action/AI later, off the body blob's critical path.
        if !headerOnly {
            if msg.aiCompleted {
                header.summaryBlurb = msg.summaryBlurb
                header.summaryTodos = msg.summaryTodos
                header.reminderDate = msg.reminderDate
                header.reminderTime = msg.reminderTime
                header.reminderContent = msg.reminderContent
            }
            if let aiRaw = msg.actionTag, let aiTag = ActionTag(rawValue: aiRaw) {
                header.actionTag = aiTag
                header.tagSortOrder = aiTag.sortOrder
            }
        }
        // INSERT OR IGNORE — if sync already created it, don't overwrite.
        // Detect the no-op case so callers can skip the junction/body writes
        // (which would still succeed but waste work).
        let rowsBefore = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?",
            arguments: [header.id]
        ) ?? 0
        try header.insert(db, onConflict: .ignore)
        let rowsAfter = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?",
            arguments: [header.id]
        ) ?? 0
        let didInsert = rowsAfter > rowsBefore

        print("[NSEDataBridge] Created header for \(msg.messageId) from NSE staging (pre-sync), inserted=\(didInsert)")
        markReachedOutIfNotified(
            notified: msg.notified,
            reminderContent: msg.reminderContent,
            rfc822MessageId: msg.rfc822MessageId,
            headerId: header.id
        )

        // Persist rendered body even on freshly-created headers.
        //
        // 🚨 C3 — bind the content to the header it was INSERTED as, never to a
        // re-lookup. This used to re-acquire the row with
        // `SELECT id FROM messageHeader WHERE accountId = ? AND messageId = ?`,
        // which is not a unique predicate: on IMAP `messageId` is the UID, and a
        // UID is FOLDER-SCOPED, so Archive UID 7 and Inbox UID 7 are two different
        // messages with identical `(accountId, messageId)`. `fetchOne` then returned
        // an arbitrary one of them and the body, the thread references and the
        // user-label junctions below all landed on that row — a wrong-message
        // misattribution, and `MessageBody` inserts use `onConflict: .ignore`, so a
        // wrong cached body is not guaranteed to self-repair.
        //
        // `header.id` is the right answer and is already in hand: `messageHeader`'s
        // only key is `t.primaryKey("id", .text)` and the `(messageId, accountId)`
        // index is NOT unique, so the ignored insert above can only have conflicted
        // on the primary key — meaning the row exists under exactly this id.
        let newHeaderId = header.id
        if !newHeaderId.isEmpty {
            // `headerOnly` (phase-1 pre-pass) SKIPS the (potentially multi-MB)
            // body blob persist — phase 2 writes it later. The thread-continuity
            // + user-label junctions below STILL run so the header threads and
            // labels correctly the moment it surfaces.
            if !headerOnly {
                try persistRenderedBodyFromStaging(
                    db: db, headerId: newHeaderId,
                    htmlContent: msg.htmlContent, textContent: msg.textContent,
                    attachmentsJSON: msg.attachmentsJSON, icsText: msg.icsText,
                    hasUnresolvedCIDs: msg.hasUnresolvedCIDs,
                    ftsBatch: &ftsBatch
                )
            }

            // Thread-continuity junction — mirrors sync's insert path
            // (SyncEngineFullSync.swift:654 etc). Without this, reply-chain
            // walking + references-based thread detection miss the new
            // message until sync re-runs.
            var insertedHeader = header
            insertedHeader.id = newHeaderId
            try ThreadUtils.insertMessageReferences(for: insertedHeader, db: db)

            // User-label junction — per-provider filter so system/tm_*
            // labels don't pollute the Labels UI. See `filterUserLabels`
            // for the per-provider contract. Gmail uses a main-GRDB
            // userLabel lookup (Path A); IMAP uses UserLabelStore
            // exclusions; Outlook keeps every Graph category except the
            // reserved `tm_*` namespace (matches ExchangeProvider).
            //
            // For any id we keep, upsert a placeholder `UserLabel` row so
            // the junction's foreign key holds (mirror of SyncEngineFullSync:
            // 657-660). For Gmail the lookup already confirmed the row
            // exists, so the upsert is a no-op; the upsert is still the
            // safe path for IMAP where user labels can appear on new
            // messages before the sync pass registers them.
            let userLabelIds = try filterUserLabels(
                provider: msg.provider, rawLabels: msg.providerLabels,
                accountId: msg.accountId, db: db
            )
            for labelId in userLabelIds {
                // `labelId` is the BARE provider value (`filterUserLabels`'
                // contract); the deterministic initializer mints the
                // account-prefixed surrogate the join FK needs (D10 /
                // `IOS-LABEL-001`).
                let labelRow = UserLabel(
                    accountId: msg.accountId, providerLabelId: labelId,
                    name: labelId, isSystem: false
                )
                try labelRow.insert(db, onConflict: .ignore)
                try MessageUserLabel(messageId: newHeaderId, userLabelId: labelRow.id)
                    .insert(db, onConflict: .ignore)
            }
        }

        // IMAP tag write + AI cache write are done by the caller (they're
        // shared with the existing-header branch).
        return didInsert
    }
}

// MARK: - Merge serialization

/// Serializes every `NSEDataBridge.mergeNSEStagingData` request so the NSE→inbox
/// merge runs as a PRIVILEGED, single-threaded step — never two at once.
///
/// Why: the merge is part of the boot / foreground sequence and is privileged.
/// It must complete BEFORE the sync/backfill/AI herd starts, and it must not
/// have a sibling merge running alongside it. Before this coordinator, six call
/// sites (deep-link tap, foreground outer, `syncStartup` step-0, foreground-push
/// `willPresent`, silent push, AI queue) could each fire concurrently; each
/// opened its own `DatabaseQueue` to the staging DB and waited out the 2s-then-5s
/// `busyMode` timeout behind the others, while all of them piled onto GRDB's
/// single writer. That contention is exactly the "sometimes 3-5s" deep-link and
/// inbox-merge lag.
///
/// Semantics: a serial task chain. Each caller links its merge after the current
/// tail and awaits ONLY its own link, so:
///   • No two `performMerge` runs ever overlap (no staging-DB / writer fights).
///   • A caller's await returns only after a merge that STARTED no earlier than
///     its call — so data a still-finishing NSE staged mid-read is never missed.
/// Concurrent callers therefore form A→B→C; passes after the first find the
/// staging table already drained and early-return in ~ms (idempotent), so the
/// extra serial passes are effectively free.
actor NSEMergeCoordinator {
    static let shared = NSEMergeCoordinator()

    /// Tail of the serial chain. `nil` when no merge is in flight.
    private var tail: Task<Void, Never>?
    /// Monotonic id so the tail-clearing check doesn't need `Task` identity
    /// (Task isn't Equatable): a caller clears the tail only if no later caller
    /// chained after it.
    private var generation = 0

    func merge(
        stagingPathOverride: String? = nil,
        onSnapshotPublished: (@Sendable () -> Void)? = nil
    ) async {
        let previous = tail
        generation += 1
        let gen = generation
        let mine = Task { [previous] in
            // Wait our turn (serial — the privileged merge runs alone), then do
            // the actual work. `previous` may be a completed task (instant) on a
            // cold chain.
            await previous?.value
            // PRIVILEGED section: the heavy background writers (backfill body/AI,
            // embedding queues, header walk) yield to the merge so it doesn't
            // queue behind their GRDB/FTS-writer transactions or compete for the
            // cooperative pool. This is what makes "single-threaded" actually hold
            // against an in-flight backfill, not just against other merges.
            await PriorityGate.privileged {
                await NSEDataBridge.performMerge(
                    stagingPathOverride: stagingPathOverride,
                    onSnapshotPublished: onSnapshotPublished
                )
            }
        }
        tail = mine
        await mine.value
        // If nobody chained after us, drop the (now-completed) tail so the next
        // merge starts a fresh chain instead of awaiting a dead task.
        if generation == gen { tail = nil }
    }
}

/// Minimal one-shot async gate for the boot paint gate: `wait()` suspends until
/// the first `open()`; `open()` returns true only on the first call (so the
/// call sites can attribute WHICH path released the gate). Single-waiter by
/// contract — the boot path calls `wait()` exactly once. A `wait()` after the
/// gate is already open returns immediately.
final class OneShotGate: Sendable {
    private struct State {
        var opened = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex<State>(State())

    /// Opens the gate, resuming a suspended `wait()`. Returns true iff this
    /// call transitioned the gate (first open); later calls are no-ops.
    @discardableResult
    func open() -> Bool {
        let (transitioned, waiter) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
            guard !s.opened else { return (false, nil) }
            s.opened = true
            let w = s.waiter
            s.waiter = nil
            return (true, w)
        }
        waiter?.resume()
        return transitioned
    }

    /// Suspends until the first `open()` (returns immediately if already open).
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                guard !s.opened else { return true }
                s.waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

// MARK: - StagedMessage: row decode + display projections
//
// SINGLE SOURCE OF TRUTH for turning a `nse_processed_message` staging row into
// the display projections `mergeNSEStagingData` publishes. In an extension (not
// the struct body) so `StagedMessage`'s memberwise `init(id:…)` — used by the
// merge helpers and their tests — stays synthesized.
extension NSEDataBridge.StagedMessage {
    /// Decode a `nse_processed_message` staging row. Any column change lands
    /// HERE once (see `StagedMessage`'s keep-in-sync doc).
    init(row: GRDB.Row) {
        // ⚠ NULL-SAFE BY CONSTRUCTION, and it must stay that way. GRDB's `Row`
        // subscript is overloaded on the RESULT type: `-> Value` TRAPS on a NULL
        // (and on a missing column), `-> Value?` returns `nil` for both. Binding
        // through an explicitly-typed `Int?` local forces the optional overload to
        // be selected regardless of how the call site is later refactored. A trap
        // here would crash the whole merge on the first unstamped row — and an
        // unstamped row is the COMMON case (every Gmail/Graph row, and every row
        // staged by an NSE that predates the column). The MISSING-column case is
        // equally real and equally must decode `nil`: the column is added by
        // `NSEStagingDB.ensureObservedUidValidityColumn` in the EXTENSION process,
        // so a device whose NSE has never run still has a table without it — the
        // same "tolerate a column this DB may not have yet" contract the
        // `folderPath`/`folderId` fallback just below already relies on.
        let observedEpoch: Int? = row["observedUidValidity"]
        self.init(
            id: row["id"],
            accountId: row["accountId"],
            accountEmail: row["accountEmail"] ?? "",
            provider: row["provider"] ?? "",
            messageId: row["messageId"],
            rfc822MessageId: row["rfc822MessageId"],
            threadId: row["threadId"],
            // New `folderPath` column (AppDatabase migration v3); fall back to the
            // legacy `folderId` column for DBs written before the rename landed.
            // Default "INBOX" so pre-migration Gmail rows still merge correctly.
            folderPath: (row["folderPath"] as String?)
                ?? (row["folderId"] as String?)
                ?? "INBOX",
            subject: row["subject"] ?? "",
            senderName: row["senderName"] ?? "",
            senderEmail: row["senderEmail"] ?? "",
            snippet: row["snippet"] ?? "",
            date: row["date"],
            to: row["toRaw"] ?? "",
            cc: row["ccRaw"] ?? "",
            bcc: row["bccRaw"] ?? "",
            replyTo: row["replyToRaw"],
            inReplyTo: row["inReplyTo"],
            references: Self.decodeJSONArray(row["referencesJSON"]),
            isRead: (row["isRead"] as Int? ?? 0) == 1,
            isFlagged: (row["isFlagged"] as Int? ?? 0) == 1,
            hasAttachments: (row["hasAttachments"] as Int? ?? 0) == 1,
            isReplied: (row["isReplied"] as Int? ?? 0) == 1,
            isForwarded: (row["isForwarded"] as Int? ?? 0) == 1,
            providerLabels: Self.decodeJSONArray(row["providerLabelsJSON"]),
            summaryBlurb: row["summaryBlurb"],
            summaryTodos: row["summaryTodos"],
            actionTag: row["actionTag"],
            reminderDate: row["reminderDate"],
            reminderTime: row["reminderTime"],
            reminderContent: row["reminderContent"],
            processedAt: row["processedAt"],
            aiCompleted: row["aiCompleted"] == 1,
            notified: row["notified"] == 1,
            htmlContent: row["htmlContent"],
            textContent: row["textContent"],
            attachmentsJSON: row["attachmentsJSON"],
            icsText: row["icsText"],
            hasUnresolvedCIDs: (row["hasUnresolvedCIDs"] as Int? ?? 0) == 1,
            observedUidValidity: observedEpoch
        )
    }

    /// Decode a JSON-array column, tolerating nil / malformed / non-array content
    /// (e.g. legacy rows written before the column existed).
    static func decodeJSONArray(_ s: String?) -> [String] {
        guard let s, !s.isEmpty,
              let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }

    /// The display+action inbox projection (ADR-IOS-049). Snippet laundered via
    /// `stagedDisplaySnippet`; a nil date maps to a fresh `Date()` (matches the
    /// merge's `?? Date()`, which the re-post memo tolerates — see
    /// `stagedSetChangedSinceLastPost`). SINGLE StagedMessage→row builder.
    func toInboxRow() -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId,
            folderPath: folderPath,
            messageId: messageId,
            rfc822MessageId: rfc822MessageId,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            senderName: senderName,
            senderAddress: senderEmail,
            to: to,
            snippet: NSEDataBridge.stagedDisplaySnippet(
                providerSnippet: snippet, textContent: textContent
            ),
            date: date.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            isRead: isRead,
            isFlagged: isFlagged,
            hasAttachments: hasAttachments,
            isReplied: isReplied,
            isForwarded: isForwarded,
            actionTag: actionTag,
            summaryBlurb: summaryBlurb,
            // Carry the epoch the NSE's own SELECT proved — do NOT re-derive it
            // here. `SyncEngine.knownUidValidity` is the tree's single
            // "is this an epoch at all" normalizer and rejects BOTH nil and the
            // `0` sentinel (RFC 3501 §2.3.1.1 `nz-number`), so an unreported
            // epoch stays unknown rather than becoming a false trust claim.
            observedUidValidity: SyncEngine.knownUidValidity(observedUidValidity)
        )
    }

    /// The display-only body snapshot, or nil when no usable rendered body is
    /// staged (empty html or unresolved inline CIDs — the app must re-render
    /// those). Matches the merge's `stagedBodies` reduce guard.
    func toBodySnapshot() -> NSEDataBridge.StagedBodySnapshot? {
        guard let html = htmlContent, !html.isEmpty, !hasUnresolvedCIDs else { return nil }
        return NSEDataBridge.StagedBodySnapshot(
            htmlContent: html, attachmentsJSON: attachmentsJSON, icsText: icsText
        )
    }
}

extension NSEDataBridge.StagedBodySnapshot {
    /// Synthesize a display-only `MessageBody` from the staged body snapshot.
    /// Shared by `stagedBodyFallback` (in-memory) and the tap-path direct read.
    func toMessageBody(contentKey: ContentKey) -> MessageBody {
        var body = MessageBody.create(contentKey: contentKey, htmlBody: htmlContent)
        body.attachmentsJSON = attachmentsJSON
        body.icsText = icsText
        return body
    }
}
