/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import GRDB

// MARK: - Undoable Action Types

enum UndoableActionType {
    case move(fromPath: String, toPath: String)
}

/// PORT — the reference's command/member Undo shape, adapted from hybrid
/// identity to the one native provider address plus its source epoch.
struct UndoMember: Sendable, Equatable {
    let providerMessageId: String
    let sourceFolderId: String
    let sourceFolderPath: String
    let sourceObservedUidValidity: Int?
    let sourceIsInInbox: Bool
    let sourceActionTag: ActionTag?
    let sourceTagSortOrder: Int
    /// UI-local only. It authenticates the exact still-present optimistic row;
    /// it is never used as provider identity and is never resurrected.
    let originalHeaderId: String

    init(header: MessageHeader) {
        providerMessageId = header.messageId
        sourceFolderId = header.folderId
        sourceFolderPath = header.folderPath
        sourceObservedUidValidity = header.observedUidValidity
        sourceIsInInbox = header.isInInbox
        sourceActionTag = header.actionTag
        sourceTagSortOrder = header.tagSortOrder
        originalHeaderId = header.id
    }
}

struct UndoAccountCommand: Sendable, Equatable {
    let accountId: String
    let forwardDestinationPath: String
    let members: [UndoMember]
}

struct UndoableAction {
    let type: UndoableActionType
    let messages: [MessageHeader]
    let originalFolderId: String
    let originalFolderPath: String
    let accountId: String
    let timestamp: Date
    let commands: [UndoAccountCommand]

    init(
        type: UndoableActionType,
        messages: [MessageHeader],
        originalFolderId: String,
        originalFolderPath: String,
        accountId: String,
        timestamp: Date
    ) {
        self.type = type
        self.messages = messages
        self.originalFolderId = originalFolderId
        self.originalFolderPath = originalFolderPath
        self.accountId = accountId
        self.timestamp = timestamp
        switch type {
        case .move(_, let destinationPath):
            self.commands = [UndoAccountCommand(
                accountId: accountId,
                forwardDestinationPath: destinationPath,
                members: messages.map(UndoMember.init(header:))
            )]
        }
    }

    var label: String {
        let count = messages.count
        let noun = count == 1 ? "message" : "messages"
        switch type {
        case .move:
            return "Moved \(count) \(noun)"
        }
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
    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    private init() {}

    func push(_ action: UndoableAction) {
        let msgIds = action.messages.map(\.messageId)
        let msgFolderIds = action.messages.map(\.folderId)
        let msgCompositeIds = action.messages.map(\.id)
        print("[UndoStack] PUSH type=\(action.type) msgIds=\(msgIds) folderId=\(msgFolderIds) compositeIds=\(msgCompositeIds) originalFolderId=\(action.originalFolderId) originalFolderPath=\(action.originalFolderPath) accountId=\(action.accountId) stackSize=\(undoStack.count)→\(undoStack.count + 1)")
        undoStack.append(action)
        // Evict oldest if over limit
        if undoStack.count > SyncConfig.undoStackMaxSize {
            let evictCount = undoStack.count - SyncConfig.undoStackMaxSize
            print("[UndoStack] EVICT oldest \(evictCount) actions (stack overflow)")
            undoStack.removeFirst(evictCount)
        }
        // Show toast with auto-dismiss timer
        showToastWithTimer()
        // Dump current DB state for the affected messages
        Task { @MainActor in
            for msgId in msgIds {
                let rows = try? dbPool.read { db in
                    try MessageHeader
                        .filter(Column("messageId") == msgId && Column("accountId") == action.accountId)
                        .fetchAll(db)
                }
                let rowSummary = rows?.map { "id=\($0.id) folderId=\($0.folderId) folderPath=\($0.folderPath)" } ?? ["<fetch failed>"]
                print("[UndoStack] DB state after push — msgId=\(msgId) rows=[\(rowSummary.joined(separator: ", "))]")
            }
            let pendingOps = try? dbPool.read { db in
                try PendingOperation
                    .filter(Column("accountId") == action.accountId)
                    .fetchAll(db)
            }
            let opsSummary = pendingOps?.map { "id=\($0.id.prefix(8)) type=\($0.type.rawValue) status=\($0.status) msgIds=\($0.messageIds)" } ?? ["<fetch failed>"]
            print("[UndoStack] PendingOps after push — [\(opsSummary.joined(separator: ", "))]")
        }
    }

    func undo() async {
        guard let action = undoStack.popLast() else {
            print("[UndoStack] UNDO called but stack is empty")
            return
        }

        let manager = AccountManager.shared
        let msgIds = action.commands.flatMap { $0.members.map(\.providerMessageId) }
        let compositeIds = action.commands.flatMap { $0.members.map(\.originalHeaderId) }
        print("[UndoStack] UNDO type=\(action.type) msgIds=\(msgIds) compositeIds=\(compositeIds) originalFolderId=\(action.originalFolderId) originalFolderPath=\(action.originalFolderPath) stackSize=\(undoStack.count + 1)→\(undoStack.count)")
        // Dump DB state BEFORE undo
        for msgId in msgIds {
            let rows = try? await dbPool.read { db in
                try MessageHeader
                    .filter(Column("messageId") == msgId && Column("accountId") == action.accountId)
                    .fetchAll(db)
            }
            let rowSummary = rows?.map { "id=\($0.id) folderId=\($0.folderId) folderPath=\($0.folderPath)" } ?? ["<fetch failed>"]
            print("[UndoStack] DB state BEFORE undo — msgId=\(msgId) rows=[\(rowSummary.joined(separator: ", "))]")
        }
        let pendingBefore = try? await dbPool.read { db in
            try PendingOperation
                .filter(Column("accountId") == action.accountId)
                .fetchAll(db)
        }
        let pendingBeforeSummary = pendingBefore?.map { "id=\($0.id.prefix(8)) type=\($0.type.rawValue) status=\($0.status) msgIds=\($0.messageIds) dest=\($0.destinationPath ?? "nil")" } ?? ["<fetch failed>"]
        print("[UndoStack] PendingOps BEFORE undo — [\(pendingBeforeSummary.joined(separator: ", "))]")

        // PORT — as in v2final's ordinary inverse flow, Undo joins the same
        // FIFO as the forward gesture instead of racing its not-yet-durable
        // optimistic write. Register the inverse display immediately, then
        // authenticate and commit it when its FIFO turn arrives.
        let originalIds = action.commands.flatMap { $0.members.map(\.originalHeaderId) }
        for command in action.commands {
            for member in command.members {
                manager.retainOverlayEntry(id: member.originalHeaderId)
                manager.registerMutation(
                    id: member.originalHeaderId,
                    mutation: .init(
                        folderId: member.sourceFolderId,
                        folderPath: member.sourceFolderPath,
                        isInInbox: member.sourceIsInInbox,
                        actionTag: .some(member.sourceActionTag)
                    )
                )
            }
        }
        if !originalIds.isEmpty {
            NotificationCenter.default.post(name: .messagesUndone, object: originalIds)
        }

        for command in action.commands {
            await manager.enqueueWrite { [manager, command] in
                let restoredOriginalIds = await manager.undoMove(
                    accountId: command.accountId,
                    forwardDestinationPath: command.forwardDestinationPath,
                    members: command.members
                )
                for member in command.members {
                    manager.releaseOverlayEntry(id: member.originalHeaderId)
                }
                if restoredOriginalIds.isEmpty {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .inboxDataDidChange,
                            object: command.members.map(\.originalHeaderId)
                        )
                    }
                }
            }
        }

        // Dump DB state AFTER undo dispatch
        for msgId in msgIds {
            let rows = try? await dbPool.read { db in
                try MessageHeader
                    .filter(Column("messageId") == msgId && Column("accountId") == action.accountId)
                    .fetchAll(db)
            }
            let rowSummary = rows?.map { "id=\($0.id) folderId=\($0.folderId) folderPath=\($0.folderPath)" } ?? ["<fetch failed>"]
            print("[UndoStack] DB state AFTER undo — msgId=\(msgId) rows=[\(rowSummary.joined(separator: ", "))]")
        }
        let pendingAfter = try? await dbPool.read { db in
            try PendingOperation
                .filter(Column("accountId") == action.accountId)
                .fetchAll(db)
        }
        let pendingAfterSummary = pendingAfter?.map { "id=\($0.id.prefix(8)) type=\($0.type.rawValue) status=\($0.status) msgIds=\($0.messageIds) dest=\($0.destinationPath ?? "nil")" } ?? ["<fetch failed>"]
        print("[UndoStack] PendingOps AFTER undo — [\(pendingAfterSummary.joined(separator: ", "))]")

        print("[UndoStack] posted .messagesUndone for originalIds=\(originalIds) remainingStack=\(undoStack.count)")

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
        print("[UndoStack] DISMISS ALL — clearing \(undoStack.count) actions")
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
