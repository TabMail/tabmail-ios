/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountManager {

    // MARK: - Per-Account Sync Units
    //
    // Self-contained per-account operations: ensure connection → sync.
    // Designed to be launched in parallel via withTaskGroup. No sequential
    // per-account loops should exist anywhere in the sync path.

    /// Ensure the provider is connected (create + connect if needed).
    /// Connection staleness is handled by the provider's dirty flag (set on session start
    /// via markAllProvidersDirty). IMAP pools drain and reseed on first checkout after dirty.
    /// HTTP providers use ephemeral sessions (no stale connections possible).
    func ensureConnected(_ account: Account) async throws {
        if let queue = workQueues[account.id] {
            let t0 = CFAbsoluteTimeGetCurrent()
            try await queue.execute(priority: .userAction) {
                try await withTimeout(seconds: SyncConfig.connectTimeoutSeconds) {
                    try await queue.provider.connect()
                }
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("ensureConnected: \(account.emailAddress) done in \(ms)ms")
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            try await connectAccount(account)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("ensureConnected: \(account.emailAddress) created+connected in \(ms)ms")
        }
    }

    /// Background delta sync for one account: ensure connection → delta sync only.
    /// Returns true if changes were found.
    /// Self-contained — safe to launch in parallel for multiple accounts.
    /// - Parameter inboxOnly: When true, IMAP accounts only check inbox (BGAppRefresh path).
    func backgroundSyncOne(_ account: Account, inboxOnly: Bool = false) async -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        // Log to main sync log only — bgAppRefresh log reserved for BGAppRefresh lifecycle events.
        BackgroundSyncLogger.log("bgSync: START \(account.emailAddress)\(inboxOnly ? " (inbox-only)" : "")")
        // Emit .checking phase IMMEDIATELY — before ensureConnected. Otherwise the
        // subtitle can't flip to "Checking..." until IMAP TLS/login (~500-1000ms)
        // completes, which feels sluggish on cold foreground return. Idempotent
        // with the inner emission in backgroundDeltaSync.
        let accountId = account.id
        await MainActor.run { AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }
        do {
            let (changed, reason) = try await withTimeout(seconds: SyncConfig.backgroundPerAccountTimeoutSeconds) {
                try await self.ensureConnected(account)
                return try await self.syncEngine.backgroundDeltaSync(account: account, inboxOnly: inboxOnly)
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("bgSync: END \(account.emailAddress): \(elapsed)ms, changes=\(changed), reason=\(reason)")
            return changed
        } catch is TimeoutError {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[SyncScheduler:bg] Delta sync timed out for \(account.emailAddress)")
            BackgroundSyncLogger.logError("timeout", source: "bgSync:\(account.emailAddress)")
            BackgroundSyncLogger.log("bgSync: TIMEOUT \(account.emailAddress) after \(elapsed)ms")
            return false
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[SyncScheduler:bg] Sync failed for \(account.emailAddress): \(error)")
            if !SyncEngine.isConnectionError(error) && !(error is CancellationError) {
                BackgroundSyncLogger.logError("\(error)", source: "bgSync:\(account.emailAddress)")
            }
            BackgroundSyncLogger.log("bgSync: FAILED \(account.emailAddress) after \(elapsed)ms: \(error.localizedDescription)")
            return false
        }
    }

    /// Result of a sync attempt for one account.
    struct SyncResult {
        let hadChanges: Bool
        let failed: Bool
    }

    /// Foreground sync for one account: ensure connection → full sync (delta + periodic full).
    /// Self-contained — safe to launch in parallel for multiple accounts.
    /// Sync phases are published automatically by ensureConnected() and SyncEngine.
    func foregroundSyncOne(_ account: Account) async -> SyncResult {
        // Emit .checking BEFORE ensureConnected so the subtitle flips immediately
        // rather than waiting on IMAP TLS/login. Idempotent with the inner
        // emission in SyncEngine.sync().
        let accountId = account.id
        await MainActor.run { AccountManagerState.shared.setSyncPhase(.checking, forAccount: accountId) }
        defer {
            Task { @MainActor in AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
        }
        do {
            try await ensureConnected(account)
            // Foreground inbox catch-up runs at `.normal` — it beats deep backfill
            // in the write scheduler but yields to the merge / a live user action.
            let changed = try await withTimeout(seconds: SyncConfig.perAccountSyncTimeoutSeconds) {
                try await PriorityGate.normal {
                    try await self.syncEngine.sync(account: account)
                }
            }
            return SyncResult(hadChanges: changed, failed: false)
        } catch is TimeoutError {
            print("[SyncScheduler] Sync timed out for \(account.emailAddress) after \(SyncConfig.perAccountSyncTimeoutSeconds)s")
            return SyncResult(hadChanges: false, failed: true)
        } catch let error where SyncEngine.isTransientError(error) {
            // Transient provider blip (HTTP 5xx/429 from a reachable server) — not a
            // real sync failure. Report `failed: false` so the foreground poll doesn't
            // flip the sync-status subtitle to "failed"; the next cycle retries.
            print("[SyncScheduler] Transient error for \(account.emailAddress) (not surfaced): \(error)")
            return SyncResult(hadChanges: false, failed: false)
        } catch let error where error.isDatabaseSuspensionAbort {
            // GRDB write aborted by database suspension (ADR-IOS-041) — benign,
            // retried on the next wake. Not a sync failure; don't flip the subtitle.
            print("[SyncScheduler] DB suspended for \(account.emailAddress) (not surfaced): \(error)")
            return SyncResult(hadChanges: false, failed: false)
        } catch {
            print("[SyncScheduler] Sync failed for \(account.emailAddress): \(error)")
            if !SyncEngine.isConnectionError(error) && !(error is CancellationError) {
                BackgroundSyncLogger.logError("\(error)", source: "fgSync:\(account.emailAddress)")
            }
            return SyncResult(hadChanges: false, failed: true)
        }
    }

    // MARK: - Parallel Launchers

    /// Background delta sync ALL active accounts in parallel.
    /// Returns true if any account had changes.
    /// All account types (Gmail, Exchange, IMAP, iCloud) sync on every opportunity.
    func backgroundSyncAll(inboxOnly: Bool = false) async -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        let accounts: [Account]
        do {
            accounts = try await AppDatabase.dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[SyncScheduler:bg] Failed to load accounts: \(error)")
            return false
        }
        guard !accounts.isEmpty else { return false }
        let label = "bgSyncAll"
        BackgroundSyncLogger.log("\(label) START (\(accounts.count) accounts)")

        return await withTaskGroup(of: (String, Bool).self) { group in
            for account in accounts {
                group.addTask {
                    let changed = await self.backgroundSyncOne(account, inboxOnly: inboxOnly)
                    return (account.emailAddress, changed)
                }
            }
            var hadChanges = false
            var results: [(String, Bool)] = []
            for await (email, changed) in group {
                results.append((email, changed))
                if changed { hadChanges = true }
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let summary = results.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            BackgroundSyncLogger.log("\(label) END in \(elapsed)ms: [\(summary)]")
            return hadChanges
        }
    }

    /// Background delta sync for a single account identified by email address.
    /// Used by silent push handler to sync only the pushed account.
    /// Returns true if changes were found.
    func backgroundSyncForAccount(email: String) async -> Bool {
        guard let account = try? await AppDatabase.dbPool.read({ db in
            try Account
                .filter(Column("emailAddress") == email)
                .filter(Column("isActive") == true)
                .fetchOne(db)
        }) else {
            print("[SyncScheduler:bg] No active account for email \(email)")
            return false
        }
        return await backgroundSyncOne(account)
    }

    /// Foreground sync ALL active accounts in parallel.
    /// Badge + UI notification fired per-account inside each provider's delta/full sync.
    func foregroundSyncAll() async -> SyncResult {
        let accounts: [Account]
        do {
            accounts = try await AppDatabase.dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[SyncScheduler:fg] Failed to load accounts: \(error)")
            return SyncResult(hadChanges: false, failed: true)
        }
        guard !accounts.isEmpty else { return SyncResult(hadChanges: false, failed: false) }

        return await withTaskGroup(of: SyncResult.self) { group in
            for account in accounts {
                group.addTask {
                    return await self.foregroundSyncOne(account)
                }
            }
            var hadChanges = false
            var allFailed = true
            for await result in group {
                if result.hadChanges { hadChanges = true }
                if !result.failed { allFailed = false }
            }
            return SyncResult(hadChanges: hadChanges, failed: allFailed)
        }
    }

    // MARK: - Legacy

    /// Lightweight delta-only sync for background execution.
    /// Prefer `backgroundSyncOne` or `backgroundSyncAll` for new code.
    @discardableResult
    func backgroundDeltaSyncAccount(_ account: Account) async throws -> Bool {
        return try await syncEngine.backgroundDeltaSync(account: account).changed
    }

    @discardableResult
    func syncAccount(_ account: Account) async throws -> Bool {
        return try await syncEngine.sync(account: account)
    }

    /// Run one cycle of backfill for the given account, optionally constrained by a deadline.
    /// Used by SyncScheduler for time-budgeted background backfill.
    func runBackfill(account: Account, deadline: Date? = nil) async -> Bool {
        return await syncEngine.performBackfill(account: account, deadline: deadline)
    }

    /// Re-queue all inbox messages for AI processing.
    /// Called when AI is re-enabled (privacy toggle off) so messages received while AI was off get processed.
    /// Idempotent: messages that already have summary+action are filtered out by ActiveAIQueue.
    func reprocessInboxMessages(accounts: [Account]) {
        Task {
            await ActiveAIQueue.shared.repopulateFromDatabase()
        }
    }
}
