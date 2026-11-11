/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Describes the current phase of a foreground sync for UI feedback.
enum SyncPhase: Equatable {
    case checking
    case downloading(Int)

    var displayText: String {
        switch self {
        case .checking: return "Checking for mail..."
        case .downloading(let count): return "Downloading \(count) email\(count == 1 ? "" : "s")..."
        }
    }

    /// Phase ordering for aggregation: highest phase wins across concurrent accounts.
    var priority: Int {
        switch self {
        case .checking: return 1
        case .downloading: return 2
        }
    }
}

/// Thin @Observable shell for SwiftUI views.
/// Holds only the properties that SwiftUI needs to observe.
/// AccountManager publishes to this when state changes.
@Observable
@MainActor
final class AccountManagerState {
    static let shared = AccountManagerState()

    /// Account IDs that failed authentication (shown in Settings auth error badges).
    var authFailedAccounts: Set<String> = []

    /// Per-account backfill progress for progress bars. Throttled to 1Hz.
    var backfillProgressByAccount: [String: BackfillProgress] = [:]

    /// User-requested fast sync mode (not persisted — resets on app restart).
    var fastSyncModeActive = false

    /// True when ActiveBodyQueue has pending items. Drives sidebar indexing indicator.
    var isBodyFetchActive = false

    /// Aggregated sync phase across all accounts for UI display. Nil when not syncing.
    /// Derived from per-account phases: highest phase wins, download counts sum.
    var syncPhase: SyncPhase?

    /// Per-account sync phases (internal, drives the aggregated syncPhase).
    private var accountSyncPhases: [String: SyncPhase] = [:]

    /// Update sync phase for a specific account and recompute aggregate.
    func setSyncPhase(_ phase: SyncPhase?, forAccount accountId: String) {
        // Only the enum is captured before the mutation; the `split` and
        // `String(describing:)` render inside `logDebug`'s autoclosure, so a
        // locked gate pays nothing on this main-actor, per-transition path (#72).
        let oldPhase = syncPhase
        if let phase {
            accountSyncPhases[accountId] = phase
        } else {
            accountSyncPhases.removeValue(forKey: accountId)
        }
        recomputeSyncPhase()
        BackgroundSyncLogger.logDebug("[SyncPhaseMut] setSyncPhase(\(Self.describe(phase))) acct=\(accountId.split(separator: "@").first.map(String.init) ?? accountId) → agg \(Self.describe(oldPhase))→\(Self.describe(syncPhase)) (perAccount=\(accountSyncPhases.count))")
    }

    /// Clear all per-account phases (called when sync cycle ends).
    func clearSyncPhases() {
        let oldPhase = syncPhase
        let perAccount = accountSyncPhases.count
        accountSyncPhases.removeAll()
        syncPhase = nil
        BackgroundSyncLogger.logDebug("[SyncPhaseMut] clearSyncPhases() → agg \(Self.describe(oldPhase))→nil (cleared \(perAccount) per-account)")
    }

    private static func describe(_ phase: SyncPhase?) -> String {
        phase.map { String(describing: $0) } ?? "nil"
    }

    private func recomputeSyncPhase() {
        guard !accountSyncPhases.isEmpty else {
            syncPhase = nil
            return
        }
        // Sum download counts across all accounts in downloading phase
        let totalDownloads = accountSyncPhases.values.reduce(0) { sum, phase in
            if case .downloading(let count) = phase { return sum + count }
            return sum
        }
        // Highest priority phase wins
        let maxPriority = accountSyncPhases.values.map(\.priority).max() ?? 0
        if maxPriority == 2 {
            syncPhase = .downloading(totalDownloads)
        } else {
            syncPhase = .checking
        }
    }

    /// Timestamp of the last successful header sync. Nil if no sync has completed yet.
    /// This is the source of the inbox "Updated … ago" subtitle — marking it in the
    /// boot timeline shows EXACTLY when the freshness indicator resets vs. stays stale.
    var lastSyncCompletedAt: Date? {
        didSet {
            BackgroundSyncLogger.logDebug("[SyncPhaseMut] lastSyncCompletedAt = \(lastSyncCompletedAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "nil")")
            BootProfiler.mark("✓ 'Updated … ago' RESET (lastSyncCompletedAt = now)")
        }
    }

    /// True when the most recent sync attempt failed (connectivity, timeout, etc.).
    /// Reset to false on next successful sync.
    var lastSyncFailed = false {
        didSet {
            BackgroundSyncLogger.logDebug("[SyncPhaseMut] lastSyncFailed = \(lastSyncFailed)")
            BootProfiler.mark("'Last updated' subtitle: lastSyncFailed = \(lastSyncFailed)")
        }
    }

    /// The inbox-wide sync failure banner line, or `nil`. Only ever one of
    /// `InboxErrorBanner`'s fixed lines; never text derived from an error.
    var syncErrorBanner: String?

    /// What the generic inbox banner means, stated once for its only two writers
    /// (`finishSyncRun` and `failRefresh`):
    ///
    /// The generic banner is raised only by a user-started refresh that failed
    /// with an error that counts (`InboxErrorBanner.countsAsFailure`). A failed
    /// refresh never clears it. It is cleared only by a run that covered every
    /// active account and had no counted failure; scheduler and background polls
    /// clear it this way too, so recovery heals it without a gesture, and they
    /// never raise it. Accounts marked sign-in-needed never count against a
    /// clear: their own "Sign in again" banner tells the user.
    ///
    /// A run that did not fail as a whole (every poll, and a refresh that
    /// succeeded) ends here. It never raises.
    /// - `coverage`: whether the run covered every active account.
    /// - `countedFailure`: an account in the run failed with an error that
    ///   counts, not being marked sign-in-needed (`InboxErrorBanner.countsAsFailure`).
    /// - `completed`: whether this run advances `lastSyncCompletedAt`.
    func finishSyncRun(coverage: SyncRunCoverage, countedFailure: Bool, completed: Bool) {
        if coverage == .full && !countedFailure {
            syncErrorBanner = nil
        }
        if completed {
            lastSyncCompletedAt = Date()
        }
    }

    /// A user-started refresh failed. It raises the banner when its error counts
    /// and never clears it (see `finishSyncRun` for the banner's meaning).
    func failRefresh(countedFailure: Bool) {
        if countedFailure {
            syncErrorBanner = InboxErrorBanner.genericMessage
        }
    }

    private init() {}
}

/// Whether a sync run covered every active account (`full`) or only some
/// (`partial`: one account, or the folders of some accounts).
enum SyncRunCoverage: Sendable, Equatable {
    case full
    case partial
}

/// The inbox error banner's copy and the decision of which errors raise it.
///
/// The banner shows only fixed plain lines, never text derived from an error.
/// An error's description is developer text (library renderings, errno dumps,
/// server prose); it stays in the debug-gated logs. This replaces the earlier
/// rule that showed the raw text when debug logging was unlocked.
enum InboxErrorBanner {
    /// The one line the banner shows. Every inbox list carries `.refreshable`, so
    /// pull-to-refresh is genuinely the recovery gesture.
    static let genericMessage = "Unable to refresh mail. Pull to retry."

    /// Every line the banner can show. Tests assert membership in this set.
    static let allLines: Set<String> = [genericMessage]

    /// Whether an account's failure counts for the banner
    /// (`AccountManagerState.finishSyncRun`): the account is not marked
    /// sign-in-needed and the failure is not temporary (cancellation, a database
    /// suspension, `SyncEngine.isTransientError`).
    nonisolated static func countsAsFailure(_ error: Error, accountMarkedSignInNeeded: Bool) -> Bool {
        if accountMarkedSignInNeeded { return false }
        if error is CancellationError { return false }
        if error.isDatabaseSuspensionAbort { return false }
        if SyncEngine.isTransientError(error) { return false }
        return true
    }

    /// The banner line a sync or page-load failure raises, or `nil` for none.
    ///
    /// - `nil` for cancellation, a database suspension, a transient refusal
    ///   (HTTP 5xx/429, a temporary IMAP login refusal), and a connection error
    ///   (offline shows no banner).
    /// - `nil` for `AuthError.refreshFailed`: a refused sign-in is told by the
    ///   per-account "sign in again" banner, which reads `authFailedAccounts`.
    /// - `genericMessage` for every other error.
    nonisolated static func text(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if error.isDatabaseSuspensionAbort { return nil }
        if case AuthError.refreshFailed = error { return nil }
        if SyncEngine.isTransientError(error) { return nil }
        if SyncEngine.isConnectionError(error) { return nil }
        return genericMessage
    }
}
