/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import TipKit

struct OutboxView: View {
    /// nil = show all accounts (unified outbox), non-nil = filter to one account
    let accountId: String?
    @Environment(NavigationStore.self) private var navigationStore
    private let swipeTip = OutboxSwipeActionsTip()

    private var messages: [OutboxMessage] {
        if let accountId {
            return navigationStore.outboxMessages.filter { $0.accountId == accountId }
        }
        return navigationStore.outboxMessages
    }

    var body: some View {
        Group {
            if messages.isEmpty {
                ContentUnavailableView("No Queued Messages", systemImage: "paperplane.circle",
                                       description: Text("Messages waiting to be sent will appear here."))
            } else {
                List {
                    ForEach(messages) { msg in
                        OutboxRow(message: msg)
                            .listRowBackground(Color.clear)
                            .popoverTip(msg.id == messages.first?.id ? swipeTip : nil, arrowEdge: .top)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.previewPaneBg)
        .navigationTitle("Outbox")
    }
}

// MARK: - Outbox Row

private struct OutboxRow: View {
    let message: OutboxMessage
    /// Dummy state toggled by the 1 Hz Timer publisher while a hold is active
    /// — forces SwiftUI to redraw the countdown Text each second. The value
    /// itself doesn't matter; only that it changes.
    @State private var tickTrigger = false

    private var statusIcon: String {
        switch message.outboxStatus {
        case .queued: return "clock"
        case .sending: return "arrow.up.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch message.outboxStatus {
        case .queued: return .secondary
        case .sending: return Theme.accent
        case .failed: return .red
        }
    }

    /// True while this row is still in its undo-send hold window.
    private var isHeld: Bool {
        (message.holdUntil ?? .distantPast) > Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Recipients
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(message.to.joined(separator: ", "))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(message.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Subject
            if !message.subject.isEmpty {
                Text(message.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Status / Error
            if message.outboxStatus == .queued, let hold = message.holdUntil, hold > Date() {
                // Held during the undo-send window — countdown.
                // `_ = tickTrigger` forces SwiftUI to treat this view as
                // dependent on tickTrigger so the Text redraws each tick.
                let _ = tickTrigger
                HStack(spacing: 4) {
                    Image(systemName: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Sending in \(Int(hold.timeIntervalSinceNow.rounded(.up)))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if message.outboxStatus == .sending {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Sending...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if message.outboxStatus == .failed, let error = message.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Only redraw while counting down. Once hold passes, tick stops
            // making visible changes (condition for the countdown Text
            // becomes false).
            if let hold = message.holdUntil, hold > Date() {
                tickTrigger.toggle()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if message.outboxStatus != .sending {
                Button(role: .destructive) {
                    AccountManager.shared.discardOutboxMessage(message.id)
                } label: {
                    Label(isHeld ? "Cancel Send" : "Discard",
                          systemImage: isHeld ? "xmark.circle" : "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if message.outboxStatus == .failed {
                Button {
                    AccountManager.shared.retryOutboxMessage(message.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(Theme.accent)
            }
        }
    }
}
