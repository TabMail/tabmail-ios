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
    /// Returns whether changes were found and whether the account failed.
    /// Self-contained — safe to launch in parallel for multiple accounts.
    /// - Parameter inboxOnly: When true, IMAP accounts only check inbox (BGAppRefresh path).
    func backgroundSyncOne(_ account: Account, inboxOnly: Bool = false) async -> SyncResult {
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
            // The pass is told the timeout's own deadline, so it reads only what it
            // can apply before the timeout gives up on it (ADR-IOS-104).
            let deadline = Date().addingTimeInterval(SyncConfig.backgroundPerAccountTimeoutSeconds)
            let (changed, reason) = try await withTimeout(seconds: SyncConfig.backgroundPerAccountTimeoutSeconds) {
                try await self.ensureConnected(account)
                return try await self.syncEngine.backgroundDeltaSync(account: account, inboxOnly: inboxOnly, deadline: deadline)
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.log("bgSync: END \(account.emailAddress): \(elapsed)ms, changes=\(changed), reason=\(reason)")
            return SyncResult(hadChanges: changed, failed: false)
        } catch let error as TimeoutError {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.logDebug("[SyncScheduler:bg] Delta sync timed out for \(account.emailAddress)")
            BackgroundSyncLogger.logError("timeout", source: "bgSync:\(account.emailAddress)")
            BackgroundSyncLogger.log("bgSync: TIMEOUT \(account.emailAddress) after \(elapsed)ms")
            return .failure(error, accountMarkedSignInNeeded: authFailedAccounts.contains(account.id))
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            BackgroundSyncLogger.logDebug("[SyncScheduler:bg] Sync failed for \(account.emailAddress): \(error)")
            if !SyncEngine.isConnectionError(error) && !(error is CancellationError) {
                BackgroundSyncLogger.logError("\(error)", source: "bgSync:\(account.emailAddress)")
            }
            BackgroundSyncLogger.log("bgSync: FAILED \(account.emailAddress) after \(elapsed)ms: \(error.localizedDescription)")
            return .failure(error, accountMarkedSignInNeeded: authFailedAccounts.contains(account.id))
        }
    }

    /// Result of a sync attempt for one account.
    struct SyncResult {
        let hadChanges: Bool
        /// For one account: it failed. For a run: every account failed.
        let failed: Bool
        /// Whether an account in the run that is not marked sign-in-needed failed
        /// for a non-temporary reason (`InboxErrorBanner.countsAsFailure`). A run
        /// that could not load its accounts counts too: it proved nothing.
        let countedFailure: Bool

        init(hadChanges: Bool, failed: Bool, countedFailure: Bool = false) {
            self.hadChanges = hadChanges
            self.failed = failed
            self.countedFailure = countedFailure
        }

        /// A failed account's result, counted for the banner by the one rule.
        static func failure(_ error: any Error, accountMarkedSignInNeeded: Bool) -> SyncResult {
            SyncResult(hadChanges: false, failed: true,
                       countedFailure: InboxErrorBanner.countsAsFailure(
                           error, accountMarkedSignInNeeded: accountMarkedSignInNeeded))
        }
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
            // Foreground inbox catch-up. Its writes run at `.normal` via
            // `SyncEngine.dbPool` = `AppDatabase.syncPool` — beats deep backfill in the
            // write scheduler but yields to the merge / a live user action.
            // The pass is told the timeout's own deadline (ADR-IOS-104).
            let deadline = Date().addingTimeInterval(SyncConfig.perAccountSyncTimeoutSeconds)
            let changed = try await withTimeout(seconds: SyncConfig.perAccountSyncTimeoutSeconds) {
                try await self.syncEngine.sync(account: account, deadline: deadline)
            }
            return SyncResult(hadChanges: changed, failed: false)
        } catch let error as TimeoutError {
            BackgroundSyncLogger.logDebug("[SyncScheduler] Sync timed out for \(account.emailAddress) after \(SyncConfig.perAccountSyncTimeoutSeconds)s")
            return .failure(error, accountMarkedSignInNeeded: authFailedAccounts.contains(account.id))
        } catch let error where SyncEngine.isTransientError(error) {
            // Transient provider blip (HTTP 5xx/429 from a reachable server) — not a
            // real sync failure. Report `failed: false` so the foreground poll doesn't
            // flip the sync-status subtitle to "failed"; the next cycle retries.
            BackgroundSyncLogger.logDebug("[SyncScheduler] Transient error for \(account.emailAddress) (not surfaced): \(error)")
            return SyncResult(hadChanges: false, failed: false)
        } catch let error where error.isDatabaseSuspensionAbort {
            // GRDB write aborted by database suspension (ADR-IOS-041) — benign,
            // retried on the next wake. Not a sync failure; don't flip the subtitle.
            BackgroundSyncLogger.logDebug("[SyncScheduler] DB suspended for \(account.emailAddress) (not surfaced): \(error)")
            return SyncResult(hadChanges: false, failed: false)
        } catch {
            BackgroundSyncLogger.logDebug("[SyncScheduler] Sync failed for \(account.emailAddress): \(error)")
            if !SyncEngine.isConnectionError(error) && !(error is CancellationError) {
                BackgroundSyncLogger.logError("\(error)", source: "fgSync:\(account.emailAddress)")
            }
            return .failure(error, accountMarkedSignInNeeded: authFailedAccounts.contains(account.id))
        }
    }

    // MARK: - Parallel Launchers

    /// Background delta sync ALL active accounts in parallel.
    /// Returns whether any account had changes and whether any failed.
    /// All account types (Gmail, Exchange, IMAP, iCloud) sync on every opportunity.
    func backgroundSyncAll(inboxOnly: Bool = false) async -> SyncResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let accounts: [Account]
        do {
            accounts = try await AppDatabase.dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            BackgroundSyncLogger.logDebug("[SyncScheduler:bg] Failed to load accounts: \(error)")
            return SyncResult(hadChanges: false, failed: true, countedFailure: true)
        }
        guard !accounts.isEmpty else { return SyncResult(hadChanges: false, failed: false) }
        let label = "bgSyncAll"
        BackgroundSyncLogger.log("\(label) START (\(accounts.count) accounts)")

        return await withTaskGroup(of: (String, SyncResult).self) { group in
            for account in accounts {
                group.addTask {
                    let result = await self.backgroundSyncOne(account, inboxOnly: inboxOnly)
                    return (account.emailAddress, result)
                }
            }
            var hadChanges = false
            var accountResults: [SyncResult] = []
            var results: [(String, Bool)] = []
            for await (email, result) in group {
                results.append((email, result.hadChanges))
                accountResults.append(result)
                if result.hadChanges { hadChanges = true }
            }
            let countedFailure = accountResults.contains { $0.countedFailure }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let summary = results.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            BackgroundSyncLogger.log("\(label) END in \(elapsed)ms: [\(summary)]")
            return SyncResult(hadChanges: hadChanges, failed: false, countedFailure: countedFailure)
        }
    }

    /// Background delta sync for a single account identified by email address.
    /// Used by silent push handler to sync only the pushed account.
    /// Returns whether changes were found and whether the account failed.
    func backgroundSyncForAccount(email: String) async -> SyncResult {
        guard let account = try? await AppDatabase.dbPool.read({ db in
            try Account
                .filter(Column("emailAddress") == email)
                .filter(Column("isActive") == true)
                .fetchOne(db)
        }) else {
            BackgroundSyncLogger.logDebug("[SyncScheduler:bg] No active account for email \(email)")
            return SyncResult(hadChanges: false, failed: false)
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
            BackgroundSyncLogger.logDebug("[SyncScheduler:fg] Failed to load accounts: \(error)")
            return SyncResult(hadChanges: false, failed: true, countedFailure: true)
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
            var accountResults: [SyncResult] = []
            for await result in group {
                accountResults.append(result)
                if result.hadChanges { hadChanges = true }
                if !result.failed { allFailed = false }
            }
            return SyncResult(hadChanges: hadChanges, failed: allFailed,
                              countedFailure: accountResults.contains { $0.countedFailure })
        }
    }

    // MARK: - Scheduler Runs (report to the inbox)
    //
    // Every scheduler run that advances `lastSyncCompletedAt` reports through one
    // of these, so the run's coverage and outcome reach
    // `AccountManagerState.finishSyncRun` in one place. Scheduler and background
    // runs never raise the inbox banner; only a full run with no counted failure
    // clears it (the rule is stated once, on `finishSyncRun`).

    /// The foreground poll's header sync: every active account (a full run).
    func foregroundPollRun() async -> SyncResult {
        let result = await foregroundSyncAll()
        await MainActor.run {
            let state = AccountManagerState.shared
            state.lastSyncFailed = result.failed
            state.finishSyncRun(coverage: .full, countedFailure: result.countedFailure,
                                completed: !result.failed)
        }
        return result
    }

    /// The background poll's delta sync: every active account (a full run), or the
    /// one account a push named (a partial run).
    func backgroundPollRun(accountEmail: String?, inboxOnly: Bool) async -> SyncResult {
        let result: SyncResult
        if let accountEmail {
            result = await backgroundSyncForAccount(email: accountEmail)
        } else {
            result = await backgroundSyncAll(inboxOnly: inboxOnly)
        }
        await MainActor.run {
            let state = AccountManagerState.shared
            state.lastSyncFailed = false
            state.finishSyncRun(coverage: accountEmail == nil ? .full : .partial,
                                countedFailure: result.countedFailure, completed: true)
        }
        return result
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
    /// Used by SyncScheduler for time-budgeted background backfill. `walkAllowed`
    /// false (Wi-Fi-only on, off Wi-Fi) holds back the walk only.
    func runBackfill(account: Account, deadline: Date? = nil, walkAllowed: Bool = true) async -> Bool {
        return await syncEngine.performBackfill(account: account, deadline: deadline, walkAllowed: walkAllowed)
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
