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

    /// True when all accounts have progress AND all are fully complete.
    private var isAllComplete: Bool {
        let values = Array(state.backfillProgressByAccount.values)
        return !values.isEmpty && values.allSatisfy(\.isFullyComplete)
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
                        let totalUidScope = allProgress.reduce(0) { $0 + $1.uidTotal }
                        let totalUidWalked = allProgress.reduce(0) { $0 + $1.uidWalked }
                        let allHeadersDone = allProgress.allSatisfy(\.headersDone)
                        // Show UID progress only while actively walking (not 100% AND not all done).
                        // Once UIDs hit 100% or headers are done, switch to FTS indexing view.
                        let showUidWalk = !allHeadersDone && totalUidScope > 0 && totalUidWalked < totalUidScope
                        let fraction: Double = showUidWalk
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
                        Label("Sync Complete", systemImage: "checkmark.circle.fill")
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
        .keepScreenAwake(while: !isAllComplete)
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
                    Text("\(progress.totalEmails.formatted()) messages indexed")
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
