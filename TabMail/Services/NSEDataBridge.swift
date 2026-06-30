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

    /// True when the staging DB actually holds a populated (merge-ready) row.
    /// COALESCED to at most one cross-process probe per `stagingProbeCoalesceMs`:
    /// reads are frequent and the probe is a non-WAL shared-container read, so
    /// without this every read would pay a cross-process read transaction.
    /// Between probes it returns false — a freshly-staged row is picked up by the
    /// next post-window read (≤ window latency) or the explicit merge triggers
    /// (which call `mergeNSEStagingData` directly, bypassing this probe), and the
    /// row stays populated=1 so nothing is lost.
    private static func stagingHasPending() async -> Bool {
        let nowMs = CFAbsoluteTimeGetCurrent() * 1000
        let shouldProbe = lastProbeMs.withLock { last -> Bool in
            guard nowMs - last >= SyncConfig.stagingProbeCoalesceMs else { return false }
            last = nowMs
            return true
        }
        guard shouldProbe, let db = stagingProbeConnection() else { return false }
        return (try? await db.read { db -> Bool in
            guard try db.tableExists("nse_processed_message") else { return false }
            return try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE populated = 1)"
            ) ?? false
        }) ?? false
    }

    /// READ-PATH entry: drain NSE staging into main GRDB if (and only if) the
    /// staging DB has a pending row. Treats staging as a read-through delta — any
    /// read (UI render, silent push, BGAppRefresh, BGProcessing) merges it first,
    /// with no per-call-site placement. The pending check reads the real staging
    /// DB (no flag drift) and is ~µs when empty; the full merge runs only when
    /// there's actually something to merge.
    static func mergeIfStagingPending() async {
        // Recursion guard: the merge does its own GRDB reads (e.g. the FTS flush
        // bulk header read), which run inside `PriorityGate.privileged` — don't
        // re-trigger a merge from within one.
        guard !PriorityGate.inPrivilegedContext else { return }
        guard await stagingHasPending() else { return }
        await mergeNSEStagingData()
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
    }

    /// Mirror account email→accountId mapping.
    /// Call on account add/remove.
    static func mirrorAccountMap() {
        guard let suite else { return }
        do {
            let accounts = try AppDatabase.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, emailAddress FROM account")
            }
            var map: [String: String] = [:]
            for row in accounts {
                if let email: String = row["emailAddress"], let id: String = row["id"] {
                    map[email] = id
                }
            }
            let data = try JSONEncoder().encode(map)
            suite.set(String(data: data, encoding: .utf8), forKey: "nse.accountMap")
        } catch {
            print("[NSEDataBridge] Failed to mirror account map: \(error)")
        }
    }

    /// Mirror IMAP account connection info (host/port/username/useTLS) for
    /// NSE one-shot fetches on `imap_new_mail` / `imap_reconnect` pushes.
    /// The password is already in shared Keychain
    /// (`KeychainHelper.passwordKey(accountId:)` reads/writes via the
    /// app-group access group, so NSE reads it via `SharedKeychain`).
    /// Call on account add / remove / IMAP-config edit.
    static func mirrorIMAPAccounts() {
        guard let suite else { return }
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
            suite.set(String(data: data, encoding: .utf8), forKey: "nse.imapAccounts")
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

    /// Public entry point. The NSE→inbox merge is a PRIVILEGED, single-threaded
    /// step of the boot / foreground sequence — it must run ALONE (no concurrent
    /// sibling merge fighting the staging-DB busy lock, and ideally ahead of the
    /// sync/backfill/AI herd contending for the GRDB writer) and FULLY complete
    /// before the rest of the herd starts. All six call sites (deep-link tap,
    /// foreground outer, `syncStartup` step-0, foreground-push `willPresent`,
    /// silent push, AI queue) funnel through `NSEMergeCoordinator` so they
    /// serialize into one in-flight run instead of each opening the staging DB
    /// and waiting out the 2s/5s `busyMode` timeout behind the others.
    static func mergeNSEStagingData(stagingPathOverride: String? = nil) async {
        await NSEMergeCoordinator.shared.merge(stagingPathOverride: stagingPathOverride)
    }

    /// The actual merge work. NEVER call directly — go through
    /// `mergeNSEStagingData` so the coordinator's serialization holds. (Only the
    /// coordinator calls this.)
    static func performMerge(stagingPathOverride: String? = nil) async {
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

        // Decode a JSON-array column, tolerating nil / malformed / non-array
        // content (e.g. legacy rows written before the column existed).
        // @Sendable: captured by the (now async) `nseDB.read` closure.
        @Sendable func decodeJSONArray(_ s: String?) -> [String] {
            guard let s, !s.isEmpty,
                  let data = s.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return []
            }
            return arr
        }

        // Explicit do/catch on the staging read — log on failure, continue
        // with an empty `processed`. The helper sub-paths
        // (`mergeInboxRemovals`, `consumePendingTaskResults`, orphan reap)
        // read different tables and may still succeed; failed rows in
        // `nse_processed_message` simply stay in staging and retry next wake.
        let processed: [StagedMessage]
        do {
            processed = try await nseDB.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM nse_processed_message WHERE populated = 1").map { row in
                    StagedMessage(
                        id: row["id"],
                        accountId: row["accountId"],
                        accountEmail: row["accountEmail"] ?? "",
                        provider: row["provider"] ?? "",
                        messageId: row["messageId"],
                        rfc822MessageId: row["rfc822MessageId"],
                        threadId: row["threadId"],
                        // New `folderPath` column (AppDatabase migration v3); fall
                        // back to the legacy `folderId` column for DBs that were
                        // written before the rename landed. Either way, default
                        // to "INBOX" so pre-migration rows that only had Gmail's
                        // hardcoded value still merge correctly.
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
                        references: decodeJSONArray(row["referencesJSON"]),
                        isRead: (row["isRead"] as Int? ?? 0) == 1,
                        isFlagged: (row["isFlagged"] as Int? ?? 0) == 1,
                        hasAttachments: (row["hasAttachments"] as Int? ?? 0) == 1,
                        isReplied: (row["isReplied"] as Int? ?? 0) == 1,
                        isForwarded: (row["isForwarded"] as Int? ?? 0) == 1,
                        providerLabels: decodeJSONArray(row["providerLabelsJSON"]),
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
                        hasUnresolvedCIDs: (row["hasUnresolvedCIDs"] as Int? ?? 0) == 1
                    )
                }
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

        if !processed.isEmpty {
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
            // Collect FTS pipeline work across ALL committed messages; flushed
            // once after the main tx commits. Per-message ftsBatch is built
            // INSIDE the savepoint and only merged into this batch after the
            // savepoint commits — so a savepoint rollback doesn't leak stale
            // entries that point at non-existent main-GRDB rows.
            var ftsBatch: [(headerId: String, textContent: String)] = []
            // The id of EVERY committed merged header (bodied or not). Header
            // visibility (headerComplete) is independent of body presence, so the
            // post-tx flush indexes + flips headerComplete for this full set — an
            // image-only / unresolved-CID push becomes inbox-visible at merge time
            // rather than waiting for a later recoverIncompleteHeaders pass. Body
            // FTS / bodyComplete stay scoped to `ftsBatch` (the bodied subset).
            var allMergedHeaderIds: [String] = []

            // Tracks whether the outer dbPool.write actually committed. Per-
            // message savepoints can RELEASE successfully but if the outer
            // commit later fails (SQLITE_FULL/IOERR/INTERRUPT), GRDB rolls
            // back the entire transaction — including those releases — so
            // nothing is durable in main GRDB. We must NOT delete the
            // corresponding staging rows in that case.
            var outerCommitted = false

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
                BootProfiler.mark("merge: requesting GRDB writer for \(processed.count) staged msg(s)")
                let writeResult: (ids: [String], committed: Int, fts: [(headerId: String, textContent: String)], headers: [String]) = try await AppDatabase.dbPool.write { db in
                    BootProfiler.mark("merge: GRDB writer ACQUIRED after \(Int((CFAbsoluteTimeGetCurrent() - writeReqT0) * 1000))ms wait")
                    var localMergedIds: [String] = []
                    var localCommitted = 0
                    var localFtsAccumulator: [(headerId: String, textContent: String)] = []
                    var localHeaderAccumulator: [String] = []
                    for msg in processed {
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
                        var localFtsBatch: [(headerId: String, textContent: String)] = []
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
                                var existingRow = try Row.fetchOne(db, sql: """
                                    SELECT id, folderPath, rfc822MessageId FROM messageHeader
                                    WHERE accountId = ? AND messageId = ?
                                    """, arguments: [msg.accountId, msg.messageId])
                                if existingRow == nil,
                                   let rfc822 = msg.rfc822MessageId, !rfc822.isEmpty {
                                    existingRow = try Row.fetchOne(db, sql: """
                                        SELECT id, folderPath, rfc822MessageId FROM messageHeader
                                        WHERE accountId = ? AND rfc822MessageId = ?
                                        """, arguments: [msg.accountId, rfc822])
                                }
                                if let row = existingRow {
                                    let headerId: String = row["id"]
                                    committedHeaderId = headerId
                                    // Use the existing header's folderPath (not the
                                    // staged msg.folderPath) as the AI cache key's
                                    // folder component. If sync raced ahead of our
                                    // merge and moved the message, the main app's
                                    // cache probes go through the CURRENT folderPath
                                    // — we must write under the same key, not the
                                    // one NSE captured at fetch time. For the common
                                    // case (no drift) these are identical.
                                    let existingFolderPath: String = row["folderPath"] ?? msg.folderPath
                                    let existingRfc822: String? = row["rfc822MessageId"]

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
                                        try db.execute(sql: """
                                            UPDATE messageHeader SET
                                                summaryBlurb = ?, summaryTodos = ?,
                                                reminderDate = ?, reminderTime = ?, reminderContent = ?
                                            WHERE id = ?
                                            """, arguments: [
                                                msg.summaryBlurb, msg.summaryTodos,
                                                msg.reminderDate, msg.reminderTime, msg.reminderContent,
                                                headerId
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
                                        try db.execute(sql: """
                                            UPDATE messageHeader SET
                                                actionTag = ?, tagSortOrder = ?,
                                                notified = CASE WHEN ? THEN 1 ELSE notified END
                                            WHERE id = ?
                                            """, arguments: [actionRaw, aiTagSortOrder, msg.notified, headerId])
                                        try queueSetTagPendingOp(db: db, accountId: msg.accountId,
                                                                 messageId: msg.messageId, tag: msg.actionTag)
                                    } else if msg.notified {
                                        // Notification delivered but no action tag (AI failed / passive).
                                        try db.execute(sql: "UPDATE messageHeader SET notified = 1 WHERE id = ?",
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
                                            try db.execute(sql: """
                                                INSERT OR REPLACE INTO messageAICache
                                                (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                                                VALUES (?, ?, ?, ?, ?)
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
                                        try db.execute(sql: """
                                            INSERT OR REPLACE INTO messageAICache
                                            (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                                            VALUES (?, ?, ?, ?, ?)
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
                        } catch {
                            // inSavepoint already rolled back the savepoint
                            // and re-threw the error; the outer transaction
                            // is still alive. Skip recording this id so the
                            // staging row stays for retry. Local deltas are
                            // discarded with the rollback.
                            print("[NSEDataBridge] Per-message merge failed for \(msg.id): \(error) — left in staging for retry")
                        }
                    }
                    return (ids: localMergedIds, committed: localCommitted, fts: localFtsAccumulator, headers: localHeaderAccumulator)
                }
                // Reaching this line means dbPool.write returned normally —
                // GRDB has committed the outer tx and every released savepoint
                // is durable. Assign the returned accumulators, then set the flag
                // so the post-tx staging delete + FTS flush + badge update can
                // proceed.
                successfullyMergedIds = writeResult.ids
                committedCount = writeResult.committed
                ftsBatch = writeResult.fts
                allMergedHeaderIds = writeResult.headers
                outerCommitted = true
                // Main tx done. With the "writer ACQUIRED after Xms" mark above this
                // decomposes the merge: START→found = read; found→ACQUIRED = writer
                // wait (contention); ACQUIRED→here = the actual main write; here→DONE
                // = post-tx FTS flush. Whichever Δ dominates is the real residual.
                BootProfiler.mark("merge: main tx committed (\(committedCount) merged) — FTS flush next")
                print("[NSEDataBridge] mergeNSEStagingData: \(committedCount)/\(processed.count) merged (\(successfullyMergedIds.count) terminal → delete)")

                // NOTE: no UI-refresh post here anymore. The whole merge emits
                // ONE `.inboxDataDidChange` (immediate) at the very end, after the
                // synchronous FTS flush below has flipped `headerComplete=1` — so
                // a brand-new staged header is already VISIBLE to the inbox query
                // (which filters `headerComplete == true`) when the single reload
                // fires. Posting mid-flight here would trigger a reload that the
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

            // Drive `didMutate` off actual commits AND outer-tx success. If
            // the outer commit failed, the per-msg savepoint releases got
            // rolled back; successfullyMergedIds is misleading and we should
            // not trigger a badge update.
            if outerCommitted, committedCount > 0 {
                didMutate = true
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
        }

        // 2. Process inbox removals — messages archived/deleted/moved while app was sleeping
        if mergeInboxRemovals(from: nseDB) { didMutate = true }

        // Consume pending task results
        if consumePendingTaskResults(from: nseDB) { didMutate = true }

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

        // SINGLE end-of-merge UI signal. Every stage (header → body → summary →
        // action → synchronous FTS flip → inbox removals → task results) is now
        // durable, so we post ONE `.inboxDataDidChange` here instead of mid-flight
        // — less reload churn, and the row is fully visible (`headerComplete=1`)
        // and bodied when the single reload reads. It carries `inboxReloadImmediate`
        // so the inbox reloads AT ONCE, bypassing its 500ms background-coalescing
        // debounce: this merge is the privileged, single-threaded boot-priority
        // step and must paint immediately (the debounce stays for the noisy
        // background producers — sync/backfill/AI — not for the merge).
        if didMutate {
            MergeSurfaceProbe.markMergeSignal()
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
                        try db.execute(sql: """
                            DELETE FROM messageHeader
                            WHERE accountId = ? AND messageId = ?
                              AND folderId IN (\(inboxPlaceholders))
                            """, arguments: StatementArguments([removal.accountId, removal.messageId] + inboxFolderIds))
                        deletedTotal += db.changesCount
                        successfullyConsumedIds.append(removal.id)
                    } catch {
                        print("[NSEDataBridge] Per-removal failed for \(removal.id): \(error) — left in staging for retry")
                    }
                }
            }
            // dbPool.write returned normally → outer tx committed; the per-
            // removal DELETEs are durable and we can safely clear staging.
            outerCommitted = true
            print("[NSEDataBridge] Merged \(successfullyConsumedIds.count)/\(removals.count) inbox removal(s), deleted \(deletedTotal) header row(s)")
            // No post here — `performMerge` emits ONE immediate `.inboxDataDidChange`
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
    /// **Outlook** — Graph categories aren't surfaced as user labels yet
    /// (see `ExchangeProvider.parseGraphMessage` → `userLabelIds: []`).
    fileprivate static func filterUserLabels(
        provider: String, rawLabels: [String],
        accountId: String, db: GRDB.Database
    ) throws -> [String] {
        switch provider {
        case "gmail":
            // Query userLabel for known non-system user labels on this
            // account. A single `IN` query covers all staged labelIds.
            guard !rawLabels.isEmpty else { return [] }
            let placeholders = rawLabels.map { _ in "?" }.joined(separator: ",")
            let args: [DatabaseValueConvertible] = [accountId] + rawLabels
            let known = try String.fetchAll(db, sql: """
                SELECT id FROM userLabel
                WHERE accountId = ? AND isSystem = 0 AND id IN (\(placeholders))
                """, arguments: StatementArguments(args))
            let knownSet = Set(known)
            return rawLabels.filter { knownSet.contains($0) }
        case "imap_new_mail", "imap", "icloud":
            // IMAP: strip system flags + tm_* + any other excluded keyword.
            return rawLabels.filter { !UserLabelStore.isExcludedKeyword($0) }
                .map { $0.lowercased() }  // Matches IMAPProvider's lowercase normalization.
        case "outlook":
            // Graph user labels aren't supported yet — ExchangeProvider
            // returns `userLabelIds: []` in parseGraphMessage. Match that.
            return []
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
    fileprivate static func persistRenderedBodyFromStaging(
        db: GRDB.Database,
        headerId: String,
        htmlContent: String?,
        textContent: String?,
        attachmentsJSON: String?,
        icsText: String?,
        hasUnresolvedCIDs: Bool,
        ftsBatch: inout [(headerId: String, textContent: String)]
    ) throws {
        // Nothing to persist — NSE didn't render (old build / fetch failure).
        guard htmlContent != nil || textContent != nil else { return }

        // Insert MessageBody ONLY for fully-resolved bodies. Unresolved-CID
        // bodies are dropped on the floor; main app re-fetches + re-renders.
        if !hasUnresolvedCIDs {
            // `htmlContent` is the display-ready html the NSE's BodyRenderer produced
            // (plain bodies already converted there) — store it as-is, no re-conversion.
            var body = MessageBody.create(headerId: headerId, htmlBody: htmlContent)
            // Diagnostic (debug-gated, no-op in prod): flag a double-escaped stored body.
            BackgroundSyncLogger.diagnoseStoredBody(source: "NSEMerge", headerId: headerId, htmlContent: body.htmlContent)
            body.attachmentsJSON = attachmentsJSON
            body.icsText = icsText
            try body.insert(db, onConflict: .ignore)
        }

        // Snippet computed from plain text via shared EmailFilter (matches main-app path).
        let snippet = textContent.map { EmailFilter.snippetFromPlainText($0) } ?? ""
        if !snippet.isEmpty {
            try db.execute(sql: """
                UPDATE messageHeader SET snippet = ? WHERE id = ?
                """, arguments: [snippet, headerId])
        }

        // Queue up the FTS BODY work. `flushNSEBatchToFTS` runs once per merge with
        // the full batch — amortizes FTS transaction overhead. Unresolved-CID and
        // empty-text messages skip the BODY batch (no indexable plain text), so
        // their `bodyComplete` stays 0 and the body queue fetches the body later.
        // Their HEADER is still FTS-indexed + flipped headerComplete=1 via the merge's
        // all-headers path (`allMergedHeaderIds`), so they ARE inbox-visible at merge
        // time — they no longer wait for a recoverIncompleteHeaders pass.
        if let text = textContent, !text.isEmpty, !hasUnresolvedCIDs {
            ftsBatch.append((headerId: headerId, textContent: text))
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
        bodyItems: [(headerId: String, textContent: String)]
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
        let indexedIds = validHeaders.map(\.id)
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
        let validBodyItems = bodyItems.compactMap { item -> (headerId: String, textContent: String, header: MessageHeader)? in
            guard let header = headersById[item.headerId] else { return nil }
            return (item.headerId, item.textContent, header)
        }
        guard !validBodyItems.isEmpty else { return }

        let ftsBodies = validBodyItems.map { ($0.headerId, $0.textContent) }
        let written: Set<String>
        do {
            written = try await SearchIndex.shared.updateBodies(ftsBodies)
        } catch {
            print("[NSEDataBridge] FTS batch: updateBodies failed: \(error) — body queue will retry")
            return
        }

        let confirmedItems = validBodyItems.filter { written.contains($0.headerId) }
        guard !confirmedItems.isEmpty else {
            print("[NSEDataBridge] FTS batch: no body writes confirmed (\(ftsBodies.count) attempted) — body queue will retry")
            return
        }

        // 5. Batch flip bodyComplete=1 for confirmed writes.
        let confirmedIds = confirmedItems.map(\.headerId)
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
        let downstream: [(headerId: String, accountId: String, isInInbox: Bool)] =
            confirmedItems.map { ($0.headerId, $0.header.accountId, $0.header.isInInbox) }
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
                        await ActiveAIQueue.shared.enqueue(headerId: item.headerId, accountId: item.accountId)
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
        ftsBatch: inout [(headerId: String, textContent: String)]
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
            snippet: msg.snippet,
            folderId: folderId,
            accountId: msg.accountId,
            folderPath: msg.folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = msg.rfc822MessageId
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
        try ThreadUtils.assignComputedThreadId(
            to: &header, nativeThreadId: msg.threadId, db: db
        )
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
        let newHeaderId = try String.fetchOne(db, sql: """
            SELECT id FROM messageHeader WHERE accountId = ? AND messageId = ?
            """, arguments: [msg.accountId, msg.messageId]) ?? ""
        if !newHeaderId.isEmpty {
            try persistRenderedBodyFromStaging(
                db: db, headerId: newHeaderId,
                htmlContent: msg.htmlContent, textContent: msg.textContent,
                attachmentsJSON: msg.attachmentsJSON, icsText: msg.icsText,
                hasUnresolvedCIDs: msg.hasUnresolvedCIDs,
                ftsBatch: &ftsBatch
            )

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
            // exclusions; Outlook stays empty (categories not surfaced
            // as user labels yet — matches ExchangeProvider).
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
                try UserLabel(
                    id: labelId, accountId: msg.accountId,
                    name: labelId, isSystem: false
                ).insert(db, onConflict: .ignore)
                try MessageUserLabel(messageId: newHeaderId, userLabelId: labelId)
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

    func merge(stagingPathOverride: String? = nil) async {
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
                await NSEDataBridge.performMerge(stagingPathOverride: stagingPathOverride)
            }
        }
        tail = mine
        await mine.value
        // If nobody chained after us, drop the (now-completed) tail so the next
        // merge starts a fresh chain instead of awaiting a dead task.
        if generation == gen { tail = nil }
    }
}
