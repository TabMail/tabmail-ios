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

struct UndoableAction {
    let type: UndoableActionType
    let messages: [MessageHeader]
    let originalFolderId: String
    let originalFolderPath: String
    let accountId: String
    let timestamp: Date

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
        let msgIds = action.messages.map(\.messageId)
        let compositeIds = action.messages.map(\.id)
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

        // Undo cancels queued ops via .cancelled status flag (safe — atomic with drain's
        // re-read+claim transaction). If the original op was already inFlight/executed,
        // the undo methods queue a reverse move-back operation instead.

        // Register overlay BEFORE the actor call for instant visual feedback.
        // The actor may be busy during heavy sync — overlay ensures the UI updates immediately.
        switch action.type {
        case .move(let fromPath, let toPath):
            // Each captured MessageHeader carries the pre-move isInInbox value,
            // so per-message mirroring is exact even if the action spans folders.
            for msg in action.messages {
                manager.registerMutation(id: msg.id, mutation: .init(
                    folderId: action.originalFolderId,
                    folderPath: action.originalFolderPath,
                    isInInbox: msg.isInInbox
                ))
            }
            await manager.enqueueWrite { [manager] in
                await manager.undoDestructiveAction(
                    action.messages,
                    accountId: action.accountId,
                    originalOpType: .move,
                    fromFolderPath: toPath,
                    toFolderPath: fromPath,
                    toFolderId: action.originalFolderId
                )
                manager.removeOverlayEntries(ids: action.messages.map(\.id))
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

        // Notify InboxView to un-dismiss these messages so they reappear in the list.
        // Use header.id (composite key "accountId:path:messageId") to match dismissedMessages entries.
        print("[UndoStack] posting .messagesUndone for compositeIds=\(compositeIds) remainingStack=\(undoStack.count)")
        NotificationCenter.default.post(name: .messagesUndone, object: compositeIds)

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
