/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB
import TipKit

/// Parent-owned refusal state for every mutating Outbox-row gesture.
/// `OutboxView` owns this rather than `OutboxRow`, so the state outlives any one
/// `ForEach` row. Dismissal of the enclosing Outbox view when the outbox empties
/// remains a separate, pre-existing presentation-lifetime boundary.
@Observable
@MainActor
final class OutboxActionController {
    enum Failure: Equatable, Sendable {
        case destructiveNotConfirmed
        case retryNotConfirmed

        var title: String {
            switch self {
            case .destructiveNotConfirmed: "Couldn't update Outbox"
            case .retryNotConfirmed: "Couldn't retry"
            }
        }

        var message: String {
            switch self {
            case .destructiveNotConfirmed:
                "The change wasn't confirmed. The message may already be sending or may no longer be in the Outbox."
            case .retryNotConfirmed:
                "Retry wasn't confirmed. The message may no longer be failed or may no longer be in the Outbox."
            }
        }
    }

    private(set) var failure: Failure?

    /// Re-resolve at the gesture instant, then require a confirmed synchronous
    /// delete. A presented Cancel Send may legitimately downgrade to Discard at
    /// the buffered deadline: both actions execute the same safe confirmed
    /// delete, and the durable hold still prevents a drain claim until holdUntil.
    /// Refuse only when no destructive action is currently safe, or when the
    /// executor rejects after winning the DB race.
    func attemptDestructive(
        presentedAction: OutboxCancellationAction,
        status: OutboxStatus,
        sentAt: Date?,
        holdUntil: Date?,
        at instant: Date,
        discardConfirmed: () -> Bool
    ) {
        let currentAction = OutboxCancellationPolicy.action(
            status: status,
            sentAt: sentAt,
            holdUntil: holdUntil,
            at: instant
        )
        switch (presentedAction, currentAction) {
        case (.cancelSend, .cancelSend?),
             (.cancelSend, .discard?),
             (.discard, .cancelSend?),
             (.discard, .discard?):
            break
        case (_, nil):
            failure = .destructiveNotConfirmed
            return
        }

        guard discardConfirmed() else {
            failure = .destructiveNotConfirmed
            return
        }
        failure = nil
    }

    func attemptRetry(retryConfirmed: () -> Bool) {
        guard retryConfirmed() else {
            failure = .retryNotConfirmed
            return
        }
        failure = nil
    }

    func dismissFailure() {
        failure = nil
    }
}

/// Production view-driver state for the Outbox row's destructive affordance.
/// `invalidationAt` is the exact wall-clock transition from Cancel Send to
/// Discard; the row schedules a one-shot invalidation there instead of relying
/// on the unrelated one-second countdown cadence.
struct OutboxHeldState: Equatable, Sendable {
    let action: OutboxCancellationAction?
    let retryAvailable: Bool
    let invalidationAt: Date?

    static func resolve(
        status: OutboxStatus,
        sentAt: Date?,
        holdUntil: Date?,
        at instant: Date
    ) -> OutboxHeldState {
        let action = OutboxCancellationPolicy.action(
            status: status,
            sentAt: sentAt,
            holdUntil: holdUntil,
            at: instant)
        let deadline = OutboxCancellationPolicy.undoDeadline(for: holdUntil)
        return OutboxHeldState(
            action: action,
            retryAvailable: status == .failed && sentAt == nil,
            invalidationAt: action == .cancelSend && instant < deadline ? deadline : nil)
    }
}

/// Production integration driver for the Outbox row's exact cancellation
/// boundary. It owns the complete lifecycle connection: resolve the rendered
/// state, key one stable task to that state's deadline, wait once, invalidate
/// local state, then resolve and render again from a fresh instant.
///
/// The clock, sleeper, and render observer are injectable so a hosted
/// `OutboxRow` test can prove this exact production connection without waiting
/// on wall-clock time. Production callers use the defaults.
@MainActor
private struct OutboxRowDeadlineRefreshDriver<Content: View>: View {
    let status: OutboxStatus
    let sentAt: Date?
    let holdUntil: Date?
    let clock: @MainActor () -> Date
    let sleep: @MainActor (UInt64) async throws -> Void
    let didRender: @MainActor (OutboxHeldState) -> Void
    @ViewBuilder let content: (OutboxHeldState) -> Content

    @State private var cancellationBoundaryVersion = 0

    init(
        status: OutboxStatus,
        sentAt: Date?,
        holdUntil: Date?,
        clock: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        didRender: @escaping @MainActor (OutboxHeldState) -> Void = { _ in },
        @ViewBuilder content: @escaping (OutboxHeldState) -> Content
    ) {
        self.status = status
        self.sentAt = sentAt
        self.holdUntil = holdUntil
        self.clock = clock
        self.sleep = sleep
        self.didRender = didRender
        self.content = content
    }

    private var heldState: OutboxHeldState {
        let _ = cancellationBoundaryVersion
        return OutboxHeldState.resolve(
            status: status,
            sentAt: sentAt,
            holdUntil: holdUntil,
            at: clock()
        )
    }

    var body: some View {
        let heldState = heldState
        let _ = didRender(heldState)
        content(heldState)
        .task(id: heldState.invalidationAt) {
            guard let deadline = heldState.invalidationAt else { return }
            do {
                try await sleep(OutboxDeadlineScheduler.nanoseconds(
                    until: deadline,
                    at: clock()))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            cancellationBoundaryVersion &+= 1
        }
    }
}

struct OutboxView: View {
    /// nil = show all accounts (unified outbox), non-nil = filter to one account
    let accountId: String?
    @Environment(NavigationStore.self) private var navigationStore
    @State private var actionController = OutboxActionController()
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
                        OutboxRow(message: msg, actionController: actionController)
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
        .alert(actionController.failure?.title ?? "Couldn't update Outbox", isPresented: Binding(
            get: { actionController.failure != nil },
            set: { if !$0 { actionController.dismissFailure() } }
        )) {
            Button("OK", role: .cancel) { actionController.dismissFailure() }
        } message: {
            Text(actionController.failure?.message ?? "")
        }
    }
}

// MARK: - Outbox Row

/// Kept internal so `@testable` can host this exact production row and pin the
/// deadline-task-to-render connection. No external module API is exposed.
struct OutboxRow: View {
    let message: OutboxMessage
    let actionController: OutboxActionController
    private let deadlineClock: @MainActor () -> Date
    private let deadlineSleep: @MainActor (UInt64) async throws -> Void
    private let didRenderHeldState: @MainActor (OutboxHeldState) -> Void
    /// Dummy state toggled by the 1 Hz Timer publisher while a hold is active
    /// — forces SwiftUI to redraw the countdown Text each second. The value
    /// itself doesn't matter; only that it changes.
    @State private var tickTrigger = false

    init(
        message: OutboxMessage,
        actionController: OutboxActionController,
        deadlineClock: @escaping @MainActor () -> Date = { Date() },
        deadlineSleep: @escaping @MainActor (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        didRenderHeldState: @escaping @MainActor (OutboxHeldState) -> Void = { _ in }
    ) {
        self.message = message
        self.actionController = actionController
        self.deadlineClock = deadlineClock
        self.deadlineSleep = deadlineSleep
        self.didRenderHeldState = didRenderHeldState
    }

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

    var body: some View {
        OutboxRowDeadlineRefreshDriver(
            status: message.outboxStatus,
            sentAt: message.sentAt,
            holdUntil: message.holdUntil,
            clock: deadlineClock,
            sleep: deadlineSleep,
            didRender: didRenderHeldState
        ) { heldState in
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
                    // Durable send hold countdown. Cancel Send is withdrawn one
                    // claim-buffer earlier than this reaches zero.
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
                if let cancellationAction = heldState.action {
                    Button(role: .destructive) {
                        actionController.attemptDestructive(
                            presentedAction: cancellationAction,
                            status: message.outboxStatus,
                            sentAt: message.sentAt,
                            holdUntil: message.holdUntil,
                            at: Date(),
                            discardConfirmed: {
                                AccountManager.shared.discardOutboxMessageConfirmed(message.id)
                            }
                        )
                    } label: {
                        Label(cancellationAction.label, systemImage: cancellationAction.systemImage)
                    }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if heldState.retryAvailable {
                    Button {
                        actionController.attemptRetry {
                            AccountManager.shared.retryOutboxMessage(message.id)
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .tint(Theme.accent)
                }
            }
        }
    }
}
