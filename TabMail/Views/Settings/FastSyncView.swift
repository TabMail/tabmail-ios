/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct FastSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationStore.self) private var navigationStore
    private var manager: AccountManager { AccountManager.shared }
    private var state: AccountManagerState { AccountManagerState.shared }
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    // MARK: - Keep-awake state

    /// Polled snapshots of each body queue's idle state (`ActiveBodyQueue.isIdle` /
    /// `BackfillBodyQueue.isIdle` — queue empty AND no active batch). Start `false`
    /// so the screen holds awake until the first poll confirms idle (fail-safe: an
    /// un-polled screen never sleeps mid-fetch). The keep-awake lock follows the
    /// queues' RUNNABLE state directly. A deterministic partial-fetch protocol
    /// failure is persisted as terminal-unindexed and no longer remains runnable.
    ///
    /// Deliberately NO repopulation on poll and no admission latch: re-running both
    /// full work-remaining scans every poll tick
    /// (`BackfillBodyQueue.repopulateFromDatabase` is a ~200K-row scan) would drain
    /// CPU/DB — the opposite of this screen's battery goal — and the
    /// "repopulation-not-yet-run → lock releases" edge is acceptable (the device
    /// sleeps; bodies fetch on the next foreground, no data loss). `SyncScheduler`
    /// owns (re)populating the queues on wake.
    @State private var activeBodyIdle = false
    @State private var backfillBodyIdle = false

    /// True when all accounts have progress AND all are fully complete.
    ///
    /// `BackfillProgress.isFullyComplete` means the header walk ended and no body
    /// remains runnable. A separate `unindexedBodyCount` keeps terminal failures
    /// visible, so completion never implies that every body reached FTS.
    private var isAllComplete: Bool {
        let values = Array(state.backfillProgressByAccount.values)
        return !values.isEmpty && values.allSatisfy(\.isFullyComplete)
    }

    /// Keep-awake predicate. The device stays awake while there is RUNNABLE body
    /// work, NOT while durable completeness is < 100%.
    ///
    /// This predicate follows the header walk plus the two body queues' idle
    /// state. It releases when all runnable work drains, including when a row has
    /// transitioned to the explicit terminal-unindexed state. Pure and
    /// `nonisolated` so it is
    /// assertable without driving SwiftUI. Holds awake when:
    ///  - any account's header walk is not done (`headersDone != true`, including a
    ///    missing progress entry — mapped to `false` by the caller), OR
    ///  - either body queue is non-idle (queued / in-flight / active batch).
    nonisolated static func keepScreenAwakeWhileWorking(
        accountHeadersDone: [Bool],
        activeBodyIdle: Bool,
        backfillBodyIdle: Bool
    ) -> Bool {
        if accountHeadersDone.contains(false) { return true }
        if !activeBodyIdle { return true }
        if !backfillBodyIdle { return true }
        return false
    }

    /// Live keep-awake value — maps the current SwiftUI state into the pure
    /// predicate. `state.backfillProgressByAccount[$0.id]?.headersDone == true`
    /// preserves the `?.headersDone != true` semantics (a missing progress entry ⇒
    /// not-done ⇒ hold awake).
    private var holdAwake: Bool {
        Self.keepScreenAwakeWhileWorking(
            accountHeadersDone: navigationStore.accounts.map {
                state.backfillProgressByAccount[$0.id]?.headersDone == true
            },
            activeBodyIdle: activeBodyIdle,
            backfillBodyIdle: backfillBodyIdle
        )
    }

    /// Poll both body queues' idle state into `@State` for the keep-awake predicate.
    /// No repopulation here — `SyncScheduler` owns (re)populating the queues on
    /// foreground/wake; this screen only OBSERVES their runnable state.
    private func refreshBodyQueueIdleState() async {
        activeBodyIdle = await ActiveBodyQueue.shared.isIdle
        backfillBodyIdle = await BackfillBodyQueue.shared.isIdle
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return mins > 0 ? "\(hours) hr \(mins) min" : "\(hours) hr"
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            let m = Double(n) / 1_000_000
            return m >= 10 ? "\(Int(m))M" : String(format: "%.1fM", m)
        case 1_000...:
            let k = Double(n) / 1_000
            return k >= 10 ? "\(Int(k))k" : String(format: "%.1fk", k)
        default:
            return "\(n)"
        }
    }

    var body: some View {
        let _ = refreshTick // force re-evaluation on timer
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accent)
                    Text("Fast Sync Mode")
                        .font(.title2.bold())
                    Text("Syncing all email history at maximum speed.\nKeep your device plugged in for best results.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Aggregate progress bar across all accounts
                    let allProgress = Array(state.backfillProgressByAccount.values)
                    if !allProgress.isEmpty {
                        let totalEmails = allProgress.reduce(0) { $0 + $1.totalEmails }
                        let totalIndexed = allProgress.reduce(0) { $0 + $1.ftsIndexed }
                        let totalUnindexed = allProgress.reduce(0) { $0 + $1.unindexedBodyCount }
                        let totalUidScope = allProgress.reduce(0) { $0 + $1.uidTotal }
                        let totalUidWalked = allProgress.reduce(0) { $0 + $1.uidWalked }
                        let allHeadersDone = allProgress.allSatisfy(\.headersDone)
                        // Show UID progress only while actively walking (not 100% AND not all done).
                        // Once UIDs hit 100% or headers are done, switch to FTS indexing view.
                        let showUidWalk = !allHeadersDone && totalUidScope > 0 && totalUidWalked < totalUidScope
                        let fraction: Double = isAllComplete ? 1.0 : showUidWalk
                            ? min(1.0, Double(totalUidWalked) / Double(totalUidScope))
                            : (totalEmails > 0 ? min(1.0, Double(totalIndexed) / Double(totalEmails)) : 0.0)

                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: fraction)
                                .tint(isAllComplete ? .green : Theme.accent)
                            HStack {
                                if showUidWalk {
                                    let pct = Int(Double(totalUidWalked) / Double(totalUidScope) * 100)
                                    Text("\(totalUidWalked.formatted()) / \(totalUidScope.formatted()) UIDs walked (\(pct)%)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let terminalText = BodyIndexingProgressText.terminalCompletion(
                                    isComplete: isAllComplete,
                                    unindexedCount: totalUnindexed
                                ) {
                                    Text(terminalText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if totalEmails > 0 {
                                    let pct = Int(Double(totalIndexed) / Double(totalEmails) * 100)
                                    Text("\(totalIndexed.formatted()) / \(totalEmails.formatted()) indexed (\(pct)%)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Starting sync...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isAllComplete {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                            if !isAllComplete, let eta = allProgress.compactMap(\.estimatedSecondsRemaining).max() {
                                Text("~\(formatETA(eta)) remaining")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Palette.boxBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Per-account status cards — always show all accounts
                    let accounts = navigationStore.accounts
                    if !accounts.isEmpty {
                        VStack(spacing: 12) {
                            ForEach(accounts) { account in
                                let progress = state.backfillProgressByAccount[account.id]
                                FastSyncAccountCard(
                                    email: account.emailAddress,
                                    progress: progress,
                                    formatCount: formatCount,
                                    formatETA: formatETA
                                )
                            }
                        }
                    } else {
                        ProgressView()
                        Text("Starting sync...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Completion state
                    if isAllComplete {
                        let totalUnindexed = state.backfillProgressByAccount.values.reduce(0) {
                            $0 + $1.unindexedBodyCount
                        }
                        Label(
                            BodyIndexingProgressText.completion(unindexedCount: totalUnindexed),
                            systemImage: "checkmark.circle.fill"
                        )
                            .font(.headline)
                            .foregroundStyle(.green)
                    }

                    Button(role: .destructive) {
                        Task { await manager.setFastSyncMode(false) }
                        dismiss()
                    } label: {
                        Text("Stop Fast Sync")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
            }
            .background(Palette.previewPaneBg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Task { await manager.setFastSyncMode(false) }
                        dismiss()
                    }
                }
            }
        }
        .keepScreenAwake(while: holdAwake)
        .onAppear {
            Task { await manager.setFastSyncMode(true) }
            Task {
                // Restart backfill workers — they may have already exited before
                // fast sync was activated. Walks resume from their stored cursors;
                // no cursor reset (the old resetForFastSync() restarted partially
                // walked folders from the top on every screen open).
                for account in navigationStore.accounts {
                    await manager.syncEngine.startBackfill(account: account)
                }
            }
            // Poll queue idle state for the keep-awake predicate.
            Task { await refreshBodyQueueIdleState() }
        }
        .onDisappear { Task { await manager.setFastSyncMode(false) } }
        .onReceive(refreshTimer) { _ in
            refreshTick += 1
            // Poll fresh progress from DB/FTS — don't rely on push callbacks
            Task {
                for account in navigationStore.accounts {
                    await manager.syncEngine.updateBackfillProgressForAccount(account)
                }
            }
            // Re-poll queue idle state so the keep-awake lock releases once the walk
            // is done and the runnable queues drain.
            Task { await refreshBodyQueueIdleState() }
        }
    }
}

// MARK: - Per-Account Progress Card

private struct FastSyncAccountCard: View {
    let email: String
    let progress: BackfillProgress?
    var formatCount: (Int) -> String = { "\($0)" }
    var formatETA: (Double) -> String = { "\(Int($0))s" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(email)
                    .font(.subheadline)
                Spacer()
                if let progress, progress.isFullyComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            if let progress {
                if progress.isFullyComplete {
                    Text(BodyIndexingProgressText.terminalCompletion(
                        isComplete: progress.isFullyComplete,
                        unindexedCount: progress.unindexedBodyCount
                    ) ?? "\(progress.totalEmails.formatted()) messages indexed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress.fractionComplete)
                        .tint(Theme.accent)
                    if !progress.headersDone && progress.uidTotal > 0 {
                        let pct = Int(Double(progress.uidWalked) / Double(progress.uidTotal) * 100)
                        Text("\(progress.uidWalked.formatted()) / \(progress.uidTotal.formatted()) UIDs walked (\(pct)%)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if progress.totalEmails > 0 {
                        let pct = Int(Double(progress.ftsIndexed) / Double(progress.totalEmails) * 100)
                        Text("\(progress.ftsIndexed.formatted()) / \(progress.totalEmails.formatted()) indexed (\(pct)%)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Starting...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let eta = progress.estimatedSecondsRemaining {
                        Text("~\(formatETA(eta))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Waiting...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Palette.boxBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
