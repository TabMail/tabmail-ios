/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI

// MARK: - Undo payload (ADR-IOS-060)
//
// Undo stores only enough command data to issue an ORDINARY inverse move and
// display the undo affordance — no full-row snapshot, no durable token, no
// receipt/ledger, no execution status of the forward job (plan §8.1). The
// inverse move is dispatched through the SAME journal/fold/gated-admission
// path every other move uses (`origin: .undo`); see
// `AccountManager.undoMove(accountId:forwardDestinationPath:members:)`.

/// One message the forward gesture moved, from this account's perspective.
struct UndoMember: Sendable, Equatable {
    /// Hybrid durable member identity (PLAN_IDENTITY_HYBRID): a normalized
    /// RFC Message-ID when the message has one, otherwise the raw provider
    /// ID as an opaque token. Classified by shape via
    /// `MessageIdentity.durableMemberKind` at every consumer.
    let memberIdentity: String
    /// Where this member came FROM — the inverse move's destination.
    let sourceFolderPath: String
    /// UI-LOCAL ONLY: the composite `MessageHeader.id` this row had at
    /// gesture time, before the forward move. Used solely to post
    /// `.messagesUndone` so `InboxView` can un-dismiss the exact row it hid
    /// (`dismissedMessages` is keyed by this same pre-move id) — never used
    /// to resolve/mutate the row. Resolution always happens by
    /// `memberIdentity`, because an independent sync re-key between the
    /// forward gesture and this Undo can make this id stale
    /// (`AccountManager.undoMove` falls back to identity-scoped resolution
    /// when it is).
    let originalHeaderId: String
}

/// One account's slice of an Undo. Cross-account batches route through
/// independent commands because folders/providers are account-scoped.
struct UndoAccountCommand: Sendable, Equatable {
    let accountId: String
    /// Where the forward move put these members — the inverse move's SOURCE.
    let forwardDestinationPath: String
    let members: [UndoMember]
}

/// A UI-local undo-stack entry. `id` is used only to dismiss/evict the stack
/// entry and never enters durable storage.
struct UndoableAction: Sendable, Equatable {
    let id: UUID
    let commands: [UndoAccountCommand]

    init(id: UUID = UUID(), commands: [UndoAccountCommand]) {
        self.id = id
        self.commands = commands
    }

    var totalMemberCount: Int {
        commands.reduce(0) { $0 + $1.members.count }
    }

    var label: String {
        let count = totalMemberCount
        let noun = count == 1 ? "message" : "messages"
        return "Moved \(count) \(noun)"
    }

    /// Builds one command per account from a set of pre-move headers headed
    /// to their account's own destination (a cross-account batch sends each
    /// account's members to ITS OWN folder — e.g. `archiveThread`). A member
    /// whose RFC identity does not normalize falls back to its provider ID
    /// (`header.messageId`) as a token member — the same hybrid rule as
    /// durable admission (PLAN_IDENTITY_HYBRID §2). Only a member with no
    /// identity at all, or whose account has no recorded destination, is
    /// omitted: there is nothing to undo for a member the durable queue
    /// itself could never have admitted.
    static func commands(
        for messages: [MessageHeader],
        forwardDestinationByAccount: [String: String]
    ) -> [UndoAccountCommand] {
        let byAccount = Dictionary(grouping: messages, by: \.accountId)
        var result: [UndoAccountCommand] = []
        for accountId in byAccount.keys.sorted() {
            guard let forwardDestinationPath = forwardDestinationByAccount[accountId] else { continue }
            let members: [UndoMember] = (byAccount[accountId] ?? []).compactMap { header in
                guard let memberIdentity = MessageIdentity.durableActionMemberIdentity(
                    rfc822MessageId: header.rfc822MessageId,
                    providerMessageId: header.messageId
                ) else {
                    return nil
                }
                return UndoMember(
                    memberIdentity: memberIdentity,
                    sourceFolderPath: header.folderPath,
                    originalHeaderId: header.id
                )
            }
            guard !members.isEmpty else { continue }
            result.append(UndoAccountCommand(
                accountId: accountId,
                forwardDestinationPath: forwardDestinationPath,
                members: members
            ))
        }
        return result
    }
}

// MARK: - Undo Service

@Observable
@MainActor
final class UndoService {
    static let shared = UndoService()

    /// Non-expiring undo stack. Newest at end. Bounded by SyncConfig.undoStackMaxSize.
    private(set) var undoStack: [UndoableAction] = []

    /// The most recent undoable action (top of stack).
    var currentAction: UndoableAction? { undoStack.last }

    /// Whether the undo toast is currently visible. Auto-dismisses after 5s but stack persists.
    /// Shake gesture re-shows the toast and walks back one action.
    private(set) var showToast = false

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func push(_ action: UndoableAction) {
        if DebugModeManager.isLoggingEnabled() {
            print("[UndoStack] PUSH commands=\(action.commands.count) totalMembers=\(action.totalMemberCount) stackSize=\(undoStack.count)→\(undoStack.count + 1)")
        }
        undoStack.append(action)
        // Evict oldest if over limit
        if undoStack.count > SyncConfig.undoStackMaxSize {
            let evictCount = undoStack.count - SyncConfig.undoStackMaxSize
            if DebugModeManager.isLoggingEnabled() {
                print("[UndoStack] EVICT oldest \(evictCount) actions (stack overflow)")
            }
            undoStack.removeFirst(evictCount)
        }
        // Show toast with auto-dismiss timer
        showToastWithTimer()
    }

    /// Pops the top entry and, per account command, issues an ORDINARY
    /// inverse move through the same journal/fold/gated-admission path every
    /// other move uses (`origin: .undo`) — see `AccountManager.undoMove`.
    /// There is no token, no snapshot, no receipt: a member whose row is no
    /// longer identifiable/where the forward move put it is dropped as a
    /// stale Undo, exactly like any other locally vanished intention.
    func undo() async {
        guard let action = undoStack.popLast() else {
            if DebugModeManager.isLoggingEnabled() {
                print("[UndoStack] UNDO called but stack is empty")
            }
            return
        }
        let manager = AccountManager.shared
        if DebugModeManager.isLoggingEnabled() {
            print("[UndoStack] UNDO commands=\(action.commands.count) totalMembers=\(action.totalMemberCount) stackSize=\(undoStack.count + 1)→\(undoStack.count)")
        }

        // Un-dismiss immediately, keyed by the PRE-move composite id the View
        // used to hide these rows (`InboxView.dismissedMessages`) — the
        // durable resolve+move below is asynchronous, so announcing now lets
        // the view optimistically restore the row without waiting on it.
        // `AccountManager.undoMove` re-announces under the CURRENT id if an
        // independent sync re-key means the original id no longer resolves.
        let originalIds = action.commands.flatMap { $0.members.map(\.originalHeaderId) }
        if DebugModeManager.isLoggingEnabled() {
            print("[UndoStack] posting .messagesUndone for originalIds=\(originalIds)")
        }
        NotificationCenter.default.post(name: .messagesUndone, object: originalIds)

        for command in action.commands {
            await manager.undoMove(
                accountId: command.accountId,
                forwardDestinationPath: command.forwardDestinationPath,
                members: command.members
            )
        }

        // If more items on the stack, refresh the toast timer
        if !undoStack.isEmpty {
            showToastWithTimer()
        } else {
            hideToast()
        }
    }

    /// Dismiss the undo toast only (stack persists for shake-to-undo).
    func dismissToast() {
        hideToast()
    }

    /// Dismiss the undo toast AND clear the entire stack.
    func dismissAll() {
        if DebugModeManager.isLoggingEnabled() {
            print("[UndoStack] DISMISS ALL — clearing \(undoStack.count) actions")
        }
        undoStack.removeAll()
        hideToast()
    }

    // MARK: - Private

    private func showToastWithTimer() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showToast = true
        }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            hideToast()
        }
    }

    private func hideToast() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            showToast = false
        }
    }
}
