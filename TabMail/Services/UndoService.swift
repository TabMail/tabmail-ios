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

enum UndoInvocationSource: String, Sendable {
    case compactToast
    case shakeAlert
    case programmatic
}

/// PORT — the reference's command/member Undo shape, adapted from hybrid
/// identity to the one native provider address plus its source epoch.
struct UndoMember: Sendable, Equatable {
    /// The message's address in the folder it is CURRENTLY in. On IMAP a move
    /// changes that address, so this is re-pointed by `rekey` when the drain
    /// finishes the move — it is not a stable identifier and never was.
    private(set) var providerMessageId: String
    let sourceFolderId: String
    let sourceFolderPath: String
    private(set) var sourceObservedUidValidity: Int?
    let sourceIsInInbox: Bool
    let sourceActionTag: ActionTag?
    let sourceTagSortOrder: Int
    /// UI-local only. It authenticates the exact still-present optimistic row;
    /// it is never used as provider identity and is never resurrected. It is
    /// the row's PRIMARY KEY, which the drain's re-key changes — hence `rekey`.
    private(set) var originalHeaderId: String
    /// 🚨 THE CONTENT WITNESS — the only field here that names the MESSAGE
    /// rather than an address, and the only thing that can tell an undo target
    /// apart from an impostor that inherited its address.
    ///
    /// Every other predicate `AccountManager.undoMove` authenticates a member
    /// with — the primary key, `accountId`, `messageId`, `folderPath`,
    /// `folderId` — describes the ADDRESS, and on IMAP the address is a
    /// per-folder UID a UIDVALIDITY turnover reassigns. The reset reaction
    /// purges the folder and step 6 resyncs it, so a DIFFERENT physical message
    /// can legitimately occupy the exact composite id this member names while
    /// the undo stack (in-memory, unaffected by the reaction) still holds it.
    /// All five address predicates then PASS, and the epoch guard passes too
    /// because the impostor's epoch is the FRESH one. Undo would move a message
    /// the user never touched (C3).
    ///
    /// ⚑ REFUSE-ONLY, never a lookup key — this is not the banned mechanism.
    /// ADR-IOS-068/D4 forbids resolving an undo target BY Message-ID (`v2final`'s
    /// `UndoMember.memberIdentity` did exactly that, and `IOS-IMAP-002` records
    /// what a Message-ID `SEARCH` does: it returns every copy and mutates all of
    /// them). The target here is still selected by the recorded address; the
    /// witness can only refuse it.
    ///
    /// `nil` for mail with no usable `Message-ID` — see
    /// `ExpectedMessageIdentity`'s doc for why that population fails OPEN.
    let sourceRfc822MessageId: String?

    init(header: MessageHeader) {
        providerMessageId = header.messageId
        sourceFolderId = header.folderId
        sourceFolderPath = header.folderPath
        sourceObservedUidValidity = header.observedUidValidity
        sourceIsInInbox = header.isInInbox
        sourceActionTag = header.actionTag
        sourceTagSortOrder = header.tagSortOrder
        originalHeaderId = header.id
        sourceRfc822MessageId = header.rfc822MessageId
    }

    /// Follow the row this member names to the destination address the drain
    /// proved for it. **Only the two ADDRESS fields move.** Everything else on
    /// this member describes where the message came FROM — the folder, epoch,
    /// inbox flag and tag to restore — and undoing the move must still restore
    /// exactly those, so re-keying must not touch them.
    ///
    /// `sourceRfc822MessageId` is deliberately NOT re-keyed either, and for a
    /// stronger reason than the rest: a move changes a message's address, never
    /// its identity. The whole point of the witness is that it is invariant
    /// across exactly the re-addressing this method performs — re-keying it would
    /// make it agree with whatever now sits at the new address, i.e. destroy it.
    mutating func rekey(
        accountId: String,
        newHeaderId: String,
        newProviderMessageId: String,
        newObservedUidValidity: Int?
    ) {
        originalHeaderId = newHeaderId
        providerMessageId = newProviderMessageId
        // An optimistic inverse deliberately clears the row epoch while it
        // waits for the provider to assign its source-folder UID. When that
        // exact inverse later re-keys back into the command's original source,
        // adopt the corroborated epoch so a subsequent Undo can authenticate
        // the newly-addressed row. A forward re-key into any other folder must
        // never rewrite the source witness.
        let sourceHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: sourceFolderPath,
            messageId: newProviderMessageId)
        if sourceObservedUidValidity == nil,
           newHeaderId == sourceHeaderId,
           let newObservedUidValidity,
           newObservedUidValidity > 0 {
            sourceObservedUidValidity = newObservedUidValidity
        }
    }
}

struct UndoAccountCommand: Sendable, Equatable {
    let accountId: String
    let forwardDestinationPath: String
    var members: [UndoMember]
}

struct UndoableAction {
    /// Stable identity for the exact undo state presented to the user. A safe
    /// provider re-key keeps this id; pruning an unsafe member replaces it so a
    /// button captured before the prune can never fall through to altered or
    /// older work.
    var id: UUID
    let type: UndoableActionType
    /// The captured snapshot. Not the undo path's identity — `commands` is —
    /// but `SyncEngine.scheduleMaintenanceInBackground` and
    /// `SyncScheduler` derive `undoProtectedBodyIds` from these ids, so they
    /// have to follow the drain's re-key too or the prune protection silently
    /// starts naming a row that no longer exists.
    var messages: [MessageHeader]
    let originalFolderId: String
    let originalFolderPath: String
    let accountId: String
    let timestamp: Date
    var commands: [UndoAccountCommand]

    init(
        id: UUID = UUID(),
        type: UndoableActionType,
        messages: [MessageHeader],
        originalFolderId: String,
        originalFolderPath: String,
        accountId: String,
        timestamp: Date
    ) {
        self.id = id
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
    /// Prevents two controls from consuming the same exact top-of-stack offer
    /// during the short local admission pass. Provider work is never awaited.
    /// The popped action remains reachable until every local inverse admission
    /// finishes. A provider re-key can land in that short window; keeping the
    /// command here lets `applyRekeys` update the exact in-progress address
    /// instead of leaving the queued closure with a deleted primary key.
    private var undoInProgressAction: UndoableAction?
    private var undoInProgressRemainingCommands = 0
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

    /// Follow every stacked member whose row the drain just re-addressed.
    ///
    /// THE ADDRESS PROBLEM, from the undo stack's side: `originalHeaderId` IS
    /// the row's primary key and `providerMessageId` IS its UID, so finishing a
    /// move locally invalidates both for every member of that move. Without
    /// this, `undoMove`'s member authentication looks up a key that no longer
    /// exists and refuses the whole command — the re-key would BREAK undo
    /// instead of enabling it.
    ///
    /// In memory, deliberately: the undo stack is itself in-memory and dies
    /// with the process, so a durable pairing table would outlive the only
    /// thing that consumes it. Nothing here is persisted, and nothing here is
    /// authority for a mutation — `undoMove` re-authenticates the row against
    /// the database before touching anything.
    ///
    /// `preservedIds` is the one ordering exception: an Undo that has already
    /// entered the local FIFO may need its old key long enough to cancel a
    /// deferred successor still stored under that key. Only the in-progress
    /// action is preserved; every stacked action follows the rekey normally.
    func applyRekeys(
        _ records: [HeaderRekeyRecord],
        preservingInProgressMemberIds preservedIds: Set<String> = []
    ) {
        guard !records.isEmpty else { return }
        let byOldId = Dictionary(
            records.map { ($0.oldHeaderId, $0) }, uniquingKeysWith: { first, _ in first })
        for actionIndex in undoStack.indices {
            for messageIndex in undoStack[actionIndex].messages.indices {
                guard let record = byOldId[undoStack[actionIndex].messages[messageIndex].id]
                else { continue }
                undoStack[actionIndex].messages[messageIndex].id = record.newHeaderId
                undoStack[actionIndex].messages[messageIndex].messageId = record.newProviderMessageId
            }
            for commandIndex in undoStack[actionIndex].commands.indices {
                for memberIndex in undoStack[actionIndex].commands[commandIndex].members.indices {
                    let member = undoStack[actionIndex].commands[commandIndex].members[memberIndex]
                    guard let record = byOldId[member.originalHeaderId] else { continue }
                    undoStack[actionIndex].commands[commandIndex].members[memberIndex].rekey(
                        accountId: undoStack[actionIndex].commands[commandIndex].accountId,
                        newHeaderId: record.newHeaderId,
                        newProviderMessageId: record.newProviderMessageId,
                        newObservedUidValidity: record.newObservedUidValidity)
                    // Debug-gated: this witnesses the ordinary drain SUCCESS path
                    // (`AccountManager.publishMoveFinish`), so it fires once per
                    // re-keyed member on every drained move an undo entry names.
                    // `../CLAUDE.md` rule 12 — a new diagnostic must be a no-op in
                    // production. It claims no observability exception: the three
                    // `UNGATED BY DECISION` prints in `AccountManagerQueue` sit on
                    // C3 refusal paths, and that carve-out does not reach a success.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[UndoStack] REKEY member \(record.oldHeaderId) → \(record.newHeaderId)")
                    }
                }
            }
        }
        if var action = undoInProgressAction {
            for messageIndex in action.messages.indices {
                guard !preservedIds.contains(action.messages[messageIndex].id) else { continue }
                guard let record = byOldId[action.messages[messageIndex].id]
                else { continue }
                action.messages[messageIndex].id = record.newHeaderId
                action.messages[messageIndex].messageId = record.newProviderMessageId
            }
            for commandIndex in action.commands.indices {
                for memberIndex in action.commands[commandIndex].members.indices {
                    let member = action.commands[commandIndex].members[memberIndex]
                    guard !preservedIds.contains(member.originalHeaderId) else { continue }
                    guard let record = byOldId[member.originalHeaderId] else { continue }
                    action.commands[commandIndex].members[memberIndex].rekey(
                        accountId: action.commands[commandIndex].accountId,
                        newHeaderId: record.newHeaderId,
                        newProviderMessageId: record.newProviderMessageId,
                        newObservedUidValidity: record.newObservedUidValidity)
                }
            }
            undoInProgressAction = action
        }
    }

    /// Remove only undo members whose successful forward move changed their
    /// provider address without leaving a safe destination address to target.
    /// Other members in the same command and other actions remain undoable.
    func discardMembers(namedByOldHeaderIds oldHeaderIds: [String]) {
        let discarded = Set(oldHeaderIds)
        guard !discarded.isEmpty, !undoStack.isEmpty else { return }

        // The toast is an offer to undo one exact action state. If pruning
        // changes that state (or removes it), hide the offer instead of letting
        // SwiftUI transparently retarget the same button to an older action.
        let displayedActionID = showToast ? currentAction?.id : nil

        for actionIndex in undoStack.indices {
            let memberCountBefore = undoStack[actionIndex].commands.reduce(0) {
                $0 + $1.members.count
            }
            undoStack[actionIndex].messages.removeAll { discarded.contains($0.id) }
            for commandIndex in undoStack[actionIndex].commands.indices {
                undoStack[actionIndex].commands[commandIndex].members.removeAll {
                    discarded.contains($0.originalHeaderId)
                }
            }
            undoStack[actionIndex].commands.removeAll { $0.members.isEmpty }
            let memberCountAfter = undoStack[actionIndex].commands.reduce(0) {
                $0 + $1.members.count
            }
            if memberCountAfter != memberCountBefore, memberCountAfter > 0 {
                // This is now a different, smaller undo offer. Keep it in the
                // stack for a later shake, but invalidate any captured button.
                undoStack[actionIndex].id = UUID()
            }
        }
        undoStack.removeAll { $0.commands.isEmpty }
        if let displayedActionID, currentAction?.id != displayedActionID {
            hideToast()
        } else if undoStack.isEmpty {
            hideToast()
        }
    }

    func undo(
        expectedActionID: UUID? = nil,
        source: UndoInvocationSource = .programmatic
    ) async {
        guard let top = undoStack.last else {
            print("[UndoStack] UNDO called but stack is empty")
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            let ageMilliseconds = max(
                0,
                Int(Date().timeIntervalSince(top.timestamp) * 1_000)
            )
            let expectedDescription = expectedActionID?.uuidString ?? "nil"
            print(
                "[UndoStack] UNDO invoked source=\(source.rawValue) "
                    + "expected=\(expectedDescription) "
                    + "top=\(top.id.uuidString) ageMs=\(ageMilliseconds)"
            )
        }
        if let expectedActionID, top.id != expectedActionID {
            if DebugModeManager.isLoggingEnabled() {
                print("[UndoStack] Refusing stale Undo control — displayed action changed")
            }
            hideToast()
            return
        }
        guard undoInProgressAction == nil else { return }
        let actionID = top.id

        // Pop the exact action the control displayed BEFORE any suspension.
        // This is the 1.6.38 behaviour: Undo is an immediate latest-stack
        // gesture, never a provider-drain waiter that can fall through to an
        // older action while the newest move is still on the wire.
        guard let action = undoStack.popLast(), action.id == actionID else {
            hideToast()
            return
        }
        undoInProgressAction = action
        undoInProgressRemainingCommands = action.commands.count
        if action.commands.isEmpty {
            undoInProgressAction = nil
            return
        }

        let manager = AccountManager.shared
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
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] undo phase=overlayRecorded "
                        + "action=\(actionID.uuidString) "
                        + "id=\(member.originalHeaderId) "
                        + "source=\(member.sourceFolderPath) "
                        + manager.roleActionOverlayDiagnostic(
                            id: member.originalHeaderId))
            }
        }
        if !originalIds.isEmpty {
            NotificationCenter.default.post(name: .messagesUndone, object: originalIds)
        }

        for (commandIndex, initialCommand) in action.commands.enumerated() {
            // Append behind the gesture's already-admitted local write, but do
            // not wait for that write or any provider operation to finish.
            await manager.enqueueWriteAfterPriorAdmissions { [manager] in
                guard let command = await MainActor.run(body: {
                    UndoService.shared.inProgressCommand(
                        actionID: actionID,
                        commandIndex: commandIndex)
                }) else {
                    await MainActor.run {
                        UndoService.shared.finishInProgressCommand(actionID: actionID)
                    }
                    return
                }
                for member in command.members {
                    BackgroundSyncLogger.logInbox(
                        "[RoleActionTrace] undo phase=queuedClosure.begin "
                            + "action=\(actionID.uuidString) "
                            + "id=\(member.originalHeaderId) "
                            + "forwardDestination=\(command.forwardDestinationPath) "
                            + manager.roleActionOverlayDiagnostic(
                                id: member.originalHeaderId))
                }
                let restoredIds = await manager.undoMove(
                    accountId: command.accountId,
                    forwardDestinationPath: command.forwardDestinationPath,
                    members: command.members)
                for member in command.members {
                    BackgroundSyncLogger.logInbox(
                        "[RoleActionTrace] undo phase=undoMove.returned "
                            + "action=\(actionID.uuidString) "
                            + "id=\(member.originalHeaderId) "
                            + "restored=\(restoredIds.contains(member.originalHeaderId)) "
                            + manager.roleActionOverlayDiagnostic(
                                id: member.originalHeaderId))
                }
                for member in initialCommand.members {
                    // An in-flight IMAP outcome took its own extra retain
                    // before returning. Every other outcome has committed or
                    // refused, so this release exposes durable state.
                    manager.releaseOverlayEntry(id: member.originalHeaderId)
                    BackgroundSyncLogger.logInbox(
                        "[RoleActionTrace] undo phase=initialRetainReleased "
                            + "action=\(actionID.uuidString) "
                            + "id=\(member.originalHeaderId) "
                            + manager.roleActionOverlayDiagnostic(
                                id: member.originalHeaderId))
                }
                if restoredIds.isEmpty {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .inboxDataDidChange,
                            object: command.members.map(\.originalHeaderId))
                    }
                }
                await MainActor.run {
                    UndoService.shared.finishInProgressCommand(actionID: actionID)
                }
                if DebugModeManager.isLoggingEnabled() {
                    print("[UndoStack] UNDO admitted action=\(actionID) restored=\(restoredIds.count)")
                }
            }
        }

        if DebugModeManager.isLoggingEnabled() {
            print("[UndoStack] UNDO displayed action=\(actionID) remainingStack=\(undoStack.count)")
        }

        // If more items on the stack, refresh the toast timer
        if !undoStack.isEmpty {
            showToastWithTimer()
        } else {
            hideToast()
        }
    }

    private func inProgressCommand(
        actionID: UUID,
        commandIndex: Int
    ) -> UndoAccountCommand? {
        guard let action = undoInProgressAction,
              action.id == actionID,
              action.commands.indices.contains(commandIndex)
        else { return nil }
        return action.commands[commandIndex]
    }

    private func finishInProgressCommand(actionID: UUID) {
        guard undoInProgressAction?.id == actionID else { return }
        undoInProgressRemainingCommands -= 1
        if undoInProgressRemainingCommands <= 0 {
            undoInProgressRemainingCommands = 0
            undoInProgressAction = nil
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
