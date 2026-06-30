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

    /// Account IDs where Gmail backfill hit the message ID cap (shown in Settings).
    var backfillCapReachedAccounts: Set<String> = []

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
        let acc = accountId.split(separator: "@").first.map(String.init) ?? accountId
        let phaseStr = phase.map { String(describing: $0) } ?? "nil"
        let oldAgg = syncPhase.map { String(describing: $0) } ?? "nil"
        if let phase {
            accountSyncPhases[accountId] = phase
        } else {
            accountSyncPhases.removeValue(forKey: accountId)
        }
        recomputeSyncPhase()
        let newAgg = syncPhase.map { String(describing: $0) } ?? "nil"
        print("[SyncPhaseMut] setSyncPhase(\(phaseStr)) acct=\(acc) → agg \(oldAgg)→\(newAgg) (perAccount=\(accountSyncPhases.count))")
    }

    /// Clear all per-account phases (called when sync cycle ends).
    func clearSyncPhases() {
        let oldAgg = syncPhase.map { String(describing: $0) } ?? "nil"
        let perAccount = accountSyncPhases.count
        accountSyncPhases.removeAll()
        syncPhase = nil
        print("[SyncPhaseMut] clearSyncPhases() → agg \(oldAgg)→nil (cleared \(perAccount) per-account)")
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
            let v = lastSyncCompletedAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "nil"
            print("[SyncPhaseMut] lastSyncCompletedAt = \(v)")
            BootProfiler.mark("✓ 'Updated … ago' RESET (lastSyncCompletedAt = now)")
        }
    }

    /// True when the most recent sync attempt failed (connectivity, timeout, etc.).
    /// Reset to false on next successful sync.
    var lastSyncFailed = false {
        didSet {
            print("[SyncPhaseMut] lastSyncFailed = \(lastSyncFailed)")
            BootProfiler.mark("'Last updated' subtitle: lastSyncFailed = \(lastSyncFailed)")
        }
    }

    private init() {}
}
