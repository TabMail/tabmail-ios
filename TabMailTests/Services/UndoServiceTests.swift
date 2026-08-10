/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Helpers

/// Creates a test MessageHeader without requiring a database.
private func makeHeader(
    messageId: String = "100",
    subject: String = "Test Subject",
    from: String = "sender@example.com",
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    isRead: Bool = false
) -> MessageHeader {
    var header = MessageHeader(
        messageId: messageId,
        subject: subject,
        from: from,
        fromAddress: from,
        to: "recipient@example.com",
        date: Date(),
        snippet: "Test snippet",
        folderId: "\(accountId):\(folderPath)",
        accountId: accountId,
        folderPath: folderPath,
        isInInbox: folderPath == "INBOX"
    )
    header.isRead = isRead
    return header
}

private func makeMoveAction(
    messages: [MessageHeader]? = nil,
    fromPath: String = "INBOX",
    toPath: String = "Trash",
    accountId: String = "acc1",
    originalFolderId: String = "acc1:INBOX",
    originalFolderPath: String = "INBOX",
    timestamp: Date = Date()
) -> UndoableAction {
    let msgs = messages ?? [makeHeader()]
    return UndoableAction(
        type: .move(fromPath: fromPath, toPath: toPath),
        messages: msgs,
        originalFolderId: originalFolderId,
        originalFolderPath: originalFolderPath,
        accountId: accountId,
        timestamp: timestamp
    )
}

@Suite("Undo member provider re-key")
struct UndoMemberProviderRekeyTests {
    @Test("A proven return to the original source promotes its previously unknown epoch")
    func returnToSourcePromotesEpoch() {
        var optimistic = makeHeader(
            messageId: "901", accountId: "acc1", folderPath: "INBOX")
        optimistic.id = MessageIdentity.headerId(
            accountId: "acc1", folderPath: "Trash", messageId: "901")
        optimistic.observedUidValidity = nil
        var member = UndoMember(header: optimistic)

        member.rekey(
            accountId: "acc1",
            newHeaderId: MessageIdentity.headerId(
                accountId: "acc1", folderPath: "INBOX", messageId: "102"),
            newProviderMessageId: "102",
            newObservedUidValidity: 41)

        #expect(member.originalHeaderId == "acc1:INBOX:102")
        #expect(member.providerMessageId == "102")
        #expect(member.sourceObservedUidValidity == 41)
    }

    @Test("A forward re-key into another folder never rewrites the source epoch")
    func forwardRekeyDoesNotPromoteSourceEpoch() {
        var member = UndoMember(header: makeHeader(
            messageId: "101", accountId: "acc1", folderPath: "INBOX"))

        member.rekey(
            accountId: "acc1",
            newHeaderId: MessageIdentity.headerId(
                accountId: "acc1", folderPath: "Trash", messageId: "901"),
            newProviderMessageId: "901",
            newObservedUidValidity: 74)

        #expect(member.sourceObservedUidValidity == nil)
    }
}

// MARK: - Undo Stack Logic Tests (Test Double)

/// Tests the push/pop/eviction stack logic by replicating UndoService's algorithm
/// without depending on AppDatabase.dbPool or AccountManager.shared.
@Suite("Undo Stack Logic")
struct UndoStackLogicTests {

    /// Replicates UndoService.push() stack logic without DB side effects.
    private func pushToStack(_ stack: inout [UndoableAction], _ action: UndoableAction) {
        stack.append(action)
        if stack.count > SyncConfig.undoStackMaxSize {
            let evictCount = stack.count - SyncConfig.undoStackMaxSize
            stack.removeFirst(evictCount)
        }
    }

    @Test("Push adds action to stack")
    func pushAddsToStack() {
        var stack: [UndoableAction] = []
        let action = makeMoveAction()
        pushToStack(&stack, action)
        #expect(stack.count == 1)
    }

    @Test("Push multiple actions grows stack")
    func pushMultipleGrows() {
        var stack: [UndoableAction] = []
        for i in 0..<5 {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "\(i)")]))
        }
        #expect(stack.count == 5)
    }

    @Test("currentAction returns last pushed (LIFO)")
    func currentActionIsLast() {
        var stack: [UndoableAction] = []
        let action1 = makeMoveAction(messages: [makeHeader(messageId: "first")])
        let action2 = makeMoveAction(messages: [makeHeader(messageId: "second")])
        let action3 = makeMoveAction(messages: [makeHeader(messageId: "third")])
        pushToStack(&stack, action1)
        pushToStack(&stack, action2)
        pushToStack(&stack, action3)
        // currentAction is stack.last
        let current = stack.last
        #expect(current != nil)
        #expect(current?.messages[0].messageId == "third")
    }

    @Test("currentAction is nil when stack is empty")
    func currentActionNilWhenEmpty() {
        let stack: [UndoableAction] = []
        #expect(stack.last == nil)
    }

    @Test("Push evicts oldest when over limit")
    func pushEvictsOldest() {
        var stack: [UndoableAction] = []
        // Push 21 items (limit is 20)
        for i in 0..<21 {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "\(i)")]))
        }
        #expect(stack.count == SyncConfig.undoStackMaxSize)
        // Oldest (messageId "0") should have been evicted; first item should be messageId "1"
        #expect(stack.first?.messages[0].messageId == "1")
        // Newest (messageId "20") should be last
        #expect(stack.last?.messages[0].messageId == "20")
    }

    @Test("Push evicts multiple when bulk exceeds limit")
    func pushEvictsMultiple() {
        var stack: [UndoableAction] = []
        // Fill to max
        for i in 0..<SyncConfig.undoStackMaxSize {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "old-\(i)")]))
        }
        #expect(stack.count == SyncConfig.undoStackMaxSize)
        // Push one more
        pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "new")]))
        #expect(stack.count == SyncConfig.undoStackMaxSize)
        // The first old item should be gone
        #expect(stack.first?.messages[0].messageId == "old-1")
        #expect(stack.last?.messages[0].messageId == "new")
    }

    @Test("Undo pops from stack (LIFO)")
    func undoPopsFromStack() {
        var stack: [UndoableAction] = []
        let action1 = makeMoveAction(messages: [makeHeader(messageId: "first")])
        let action2 = makeMoveAction(messages: [makeHeader(messageId: "second")])
        pushToStack(&stack, action1)
        pushToStack(&stack, action2)
        #expect(stack.count == 2)

        // Pop (replicating undo's popLast)
        let popped = stack.popLast()
        #expect(popped?.messages[0].messageId == "second")
        #expect(stack.count == 1)
        #expect(stack.last?.messages[0].messageId == "first")
    }

    @Test("Undo on empty stack returns nil")
    func undoEmptyReturnsNil() {
        var stack: [UndoableAction] = []
        let popped = stack.popLast()
        #expect(popped == nil)
        #expect(stack.isEmpty)
    }

    @Test("dismissAll clears entire stack")
    func dismissAllClears() {
        var stack: [UndoableAction] = []
        for i in 0..<10 {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "\(i)")]))
        }
        #expect(stack.count == 10)
        stack.removeAll()
        #expect(stack.isEmpty)
        #expect(stack.last == nil)
    }

    @Test("Multiple pushes maintain LIFO order")
    func multiplePushesLIFO() {
        var stack: [UndoableAction] = []
        let ids = ["alpha", "beta", "gamma", "delta"]
        for id in ids {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: id)]))
        }
        // Pop all and verify reverse order
        var poppedIds: [String] = []
        while let action = stack.popLast() {
            poppedIds.append(action.messages[0].messageId)
        }
        #expect(poppedIds == ["delta", "gamma", "beta", "alpha"])
    }

    @Test("Stack preserves action types in order")
    func stackPreservesTypes() {
        var stack: [UndoableAction] = []
        pushToStack(&stack, makeMoveAction(fromPath: "INBOX", toPath: "Trash"))
        pushToStack(&stack, makeMoveAction(fromPath: "INBOX", toPath: "Spam"))
        pushToStack(&stack, makeMoveAction(fromPath: "INBOX", toPath: "Archive"))

        // Pop and verify types
        let third = stack.popLast()!
        if case .move(_, let to) = third.type {
            #expect(to == "Archive")
        } else {
            Issue.record("Expected .move type")
        }

        let second = stack.popLast()!
        if case .move(_, let to) = second.type {
            #expect(to == "Spam")
        } else {
            Issue.record("Expected .move type")
        }

        let first = stack.popLast()!
        if case .move(_, let to) = first.type {
            #expect(to == "Trash")
        } else {
            Issue.record("Expected .move type")
        }
    }

    @Test("Eviction preserves newest items exactly at max size")
    func evictionPreservesNewest() {
        var stack: [UndoableAction] = []
        let totalPushes = SyncConfig.undoStackMaxSize + 5
        for i in 0..<totalPushes {
            pushToStack(&stack, makeMoveAction(messages: [makeHeader(messageId: "\(i)")]))
        }
        #expect(stack.count == SyncConfig.undoStackMaxSize)
        // The 5 oldest should be evicted (IDs 0-4)
        // Remaining should be IDs 5 through totalPushes-1
        for (index, action) in stack.enumerated() {
            let expectedId = "\(index + 5)"
            #expect(action.messages[0].messageId == expectedId)
        }
    }
}

// MARK: - UndoableActionType Tests

@Suite("UndoableActionType Enum")
struct UndoableActionTypeEnumTests {

    @Test("Move type stores from and to paths")
    func moveTypePaths() {
        let actionType = UndoableActionType.move(fromPath: "INBOX", toPath: "Trash")
        if case .move(let from, let to) = actionType {
            #expect(from == "INBOX")
            #expect(to == "Trash")
        } else {
            Issue.record("Expected .move type")
        }
    }

}

// MARK: - UndoableAction Properties Tests

@Suite("UndoableAction Properties")
struct UndoableActionPropertiesTests {

    @Test("Action stores messages correctly")
    func storesMessages() {
        let headers = [
            makeHeader(messageId: "msg1"),
            makeHeader(messageId: "msg2"),
        ]
        let action = makeMoveAction(messages: headers)
        #expect(action.messages.count == 2)
        #expect(action.messages[0].messageId == "msg1")
        #expect(action.messages[1].messageId == "msg2")
    }

    @Test("Action stores original folder info")
    func storesOriginalFolderInfo() {
        let action = makeMoveAction(
            originalFolderId: "acc1:INBOX",
            originalFolderPath: "INBOX"
        )
        #expect(action.originalFolderId == "acc1:INBOX")
        #expect(action.originalFolderPath == "INBOX")
    }

    @Test("Action stores account ID")
    func storesAccountId() {
        let action = makeMoveAction(accountId: "my-account")
        #expect(action.accountId == "my-account")
    }

    @Test("Action stores timestamp")
    func storesTimestamp() {
        let now = Date()
        let action = makeMoveAction(timestamp: now)
        #expect(action.timestamp == now)
    }

    @Test("Action preserves message composite IDs")
    func actionPreservesCompositeIds() {
        let h1 = makeHeader(messageId: "100", accountId: "acc1", folderPath: "INBOX")
        let action = makeMoveAction(messages: [h1], accountId: "acc1")
        #expect(action.messages[0].id == "acc1:INBOX:100")
    }

    @Test("Action with messages from different accounts")
    func actionWithDifferentAccounts() {
        let h1 = makeHeader(messageId: "1", accountId: "acc1")
        let h2 = makeHeader(messageId: "2", accountId: "acc2")
        let action = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [h1, h2],
            originalFolderId: "acc1:INBOX",
            originalFolderPath: "INBOX",
            accountId: "acc1",
            timestamp: Date()
        )
        #expect(action.messages.count == 2)
        #expect(action.messages[0].accountId == "acc1")
        #expect(action.messages[1].accountId == "acc2")
    }

    @Test("Action with messages from different folders")
    func actionWithDifferentFolders() {
        let h1 = makeHeader(messageId: "1", folderPath: "INBOX")
        let h2 = makeHeader(messageId: "2", folderPath: "Sent")
        let action = makeMoveAction(messages: [h1, h2])
        #expect(action.messages[0].folderPath == "INBOX")
        #expect(action.messages[1].folderPath == "Sent")
    }

    @Test("Move action extracts correct paths from type")
    func moveExtractsPaths() {
        let action = makeMoveAction(fromPath: "Drafts", toPath: "Archive")
        guard case .move(let from, let to) = action.type else {
            Issue.record("Expected .move type")
            return
        }
        #expect(from == "Drafts")
        #expect(to == "Archive")
    }

}

// MARK: - UndoableAction Label Edge Cases

@Suite("UndoableAction Label Edge Cases")
struct UndoableActionLabelEdgeCasesTests {

    @Test("Move label with large number of messages")
    func moveManyMessages() {
        let headers = (0..<100).map { makeHeader(messageId: "\($0)") }
        let action = makeMoveAction(messages: headers)
        #expect(action.label == "Moved 100 messages")
    }

    @Test("Move with different folder paths does not affect label text")
    func moveDifferentPathsSameLabel() {
        let action1 = makeMoveAction(fromPath: "INBOX", toPath: "Trash")
        let action2 = makeMoveAction(fromPath: "Archive", toPath: "Spam")
        // Paths don't appear in label — only count matters
        #expect(action1.label == action2.label)
    }

}

// MARK: - Gmail-Specific Undo Paths

@Suite("UndoableAction Gmail Paths")
struct UndoableActionGmailPathsTests {

    @Test("Gmail archive uses empty fromPath for undo")
    func gmailArchiveEmptyFromPath() {
        // Gmail undo archive: move(from: "", to: "INBOX") — removing "" is a no-op
        let action = makeMoveAction(fromPath: "", toPath: "INBOX")
        if case .move(let from, let to) = action.type {
            #expect(from == "")
            #expect(to == "INBOX")
        } else {
            Issue.record("Expected .move type")
        }
        #expect(action.label == "Moved 1 message")
    }

    @Test("Gmail trash uses TRASH path")
    func gmailTrashPath() {
        let action = makeMoveAction(fromPath: "INBOX", toPath: "TRASH")
        if case .move(let from, let to) = action.type {
            #expect(from == "INBOX")
            #expect(to == "TRASH")
        }
    }

    @Test("Gmail spam uses SPAM path")
    func gmailSpamPath() {
        let action = makeMoveAction(fromPath: "INBOX", toPath: "SPAM")
        if case .move(let from, let to) = action.type {
            #expect(from == "INBOX")
            #expect(to == "SPAM")
        }
    }
}

// MARK: - UndoService State Tests

@Suite("UndoService State Management", .processGlobalState)
struct UndoServiceStateTests {

    @MainActor
    private func resetService() {
        UndoService.shared.dismissAll()
    }

    @Test("Initial state - empty stack and no toast")
    @MainActor
    func initialState() {
        resetService()
        let service = UndoService.shared
        #expect(service.undoStack.isEmpty)
        #expect(service.currentAction == nil)
        #expect(service.showToast == false)
    }

    @Test("currentAction is nil when stack is empty")
    @MainActor
    func currentActionNilOnEmpty() {
        resetService()
        #expect(UndoService.shared.currentAction == nil)
    }

    @Test("dismissAll clears stack and hides toast")
    @MainActor
    func dismissAllClearsStack() {
        resetService()
        let service = UndoService.shared
        service.dismissAll()
        #expect(service.undoStack.isEmpty)
        #expect(service.showToast == false)
    }

    @Test("dismissToast hides toast without clearing stack")
    @MainActor
    func dismissToastHidesToast() {
        resetService()
        let service = UndoService.shared
        service.dismissToast()
        #expect(service.showToast == false)
        // Stack should still be empty (was empty to begin with)
        #expect(service.undoStack.isEmpty)
    }

    @Test("dismissAll is idempotent - multiple calls do not crash")
    @MainActor
    func dismissAllIdempotent() {
        resetService()
        let service = UndoService.shared
        service.dismissAll()
        service.dismissAll()
        service.dismissAll()
        #expect(service.undoStack.isEmpty)
        #expect(service.showToast == false)
    }

    @Test("dismissToast is idempotent - multiple calls do not crash")
    @MainActor
    func dismissToastIdempotent() {
        resetService()
        let service = UndoService.shared
        service.dismissToast()
        service.dismissToast()
        service.dismissToast()
        #expect(service.showToast == false)
    }

    @Test("undoStackMaxSize config is within reasonable range")
    func undoStackMaxSizeReasonable() {
        #expect(SyncConfig.undoStackMaxSize >= 5)
        #expect(SyncConfig.undoStackMaxSize <= 50)
    }

    @Test("undoStackMaxSize matches expected value of 20")
    func undoStackMaxSizeValue() {
        #expect(SyncConfig.undoStackMaxSize == 20)
    }
}

// MARK: - UndoService Undo on Empty Stack

@Suite("UndoService Empty Stack Behavior", .processGlobalState)
struct UndoServiceEmptyStackTests {

    @MainActor
    private func resetService() {
        UndoService.shared.dismissAll()
    }

    @Test("undo on empty stack does not crash")
    @MainActor
    func undoOnEmptyStack() async {
        resetService()
        let service = UndoService.shared
        // undo() when empty should just log and return gracefully
        // It accesses AccountManager.shared so we just verify no crash on empty guard
        #expect(service.undoStack.isEmpty)
        // The guard at the top of undo() returns early if stack is empty,
        // before touching AccountManager or dbPool
        await service.undo()
        #expect(service.undoStack.isEmpty)
    }
}

// MARK: - Undo UI offer identity

@Suite("Undo UI offer identity")
struct UndoUIOfferIdentityTests {
    private func inboxViewSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TabMail/Views/Inbox/InboxView.swift"),
            encoding: .utf8)
    }

    @Test("Each compact Undo offer has the action identity and an explicit invocation source")
    func compactUndoOfferCannotBeRetargetedInPlace() throws {
        let source = try inboxViewSource()
        let start = try #require(source.range(of: "// Compact undo chip"))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "// Agent reply toast"))
        let compactUndo = tail[..<end.lowerBound]

        #expect(compactUndo.contains(".id(action.id)"))
        #expect(compactUndo.contains("source: .compactToast"))
    }

    @Test("Shake Undo names its distinct invocation source")
    func shakeUndoHasExplicitSource() throws {
        let source = try inboxViewSource()
        let start = try #require(source.range(of: ".onShake {"))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "private func collapseChat"))
        let shakeUndo = tail[..<end.lowerBound]

        #expect(shakeUndo.contains("source: .shakeAlert"))
    }
}

// MARK: - UndoableAction Timestamp Ordering

@Suite("UndoableAction Timestamps")
struct UndoableActionTimestampTests {

    @Test("Actions can be compared by timestamp")
    func timestampOrdering() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)

        let action1 = makeMoveAction(timestamp: earlier)
        let action2 = makeMoveAction(timestamp: later)

        #expect(action1.timestamp < action2.timestamp)
    }

    @Test("Actions with same timestamp have equal timestamps")
    func sameTimestamp() {
        let ts = Date(timeIntervalSince1970: 1500)
        let action1 = makeMoveAction(timestamp: ts)
        let action2 = makeMoveAction(fromPath: "INBOX", toPath: "Archive", timestamp: ts)

        #expect(action1.timestamp == action2.timestamp)
    }
}

// MARK: - UndoableAction with Read/Unread Messages

@Suite("UndoableAction Read State Preservation")
struct UndoableActionReadStateTests {

    @Test("Action preserves original isRead state of messages")
    func preservesReadState() {
        let readHeader = makeHeader(messageId: "1", isRead: true)
        let unreadHeader = makeHeader(messageId: "2", isRead: false)
        let action = makeMoveAction(messages: [readHeader, unreadHeader])

        #expect(action.messages[0].isRead == true)
        #expect(action.messages[1].isRead == false)
    }

}

// MARK: - IMAP Undo Path Tests

@Suite("UndoableAction IMAP Paths")
struct UndoableActionIMAPPathsTests {

    @Test("IMAP archive uses real folder path")
    func imapArchivePath() {
        let action = makeMoveAction(fromPath: "INBOX", toPath: "Archive")
        if case .move(let from, let to) = action.type {
            #expect(from == "INBOX")
            #expect(to == "Archive")
        }
    }

    @Test("IMAP trash uses real folder path")
    func imapTrashPath() {
        let action = makeMoveAction(fromPath: "INBOX", toPath: "Trash")
        if case .move(let from, let to) = action.type {
            #expect(from == "INBOX")
            #expect(to == "Trash")
        }
    }

    @Test("IMAP move between custom folders")
    func imapCustomFolders() {
        let action = makeMoveAction(fromPath: "Projects/Alpha", toPath: "Projects/Beta")
        if case .move(let from, let to) = action.type {
            #expect(from == "Projects/Alpha")
            #expect(to == "Projects/Beta")
        }
    }

    @Test("Undo move swaps from and to paths")
    func undoMoveSwapsPaths() {
        // When undoing a move from INBOX to Trash, the undo should move from Trash to INBOX
        // The undo() method passes toPath as fromFolderPath and fromPath as toFolderPath
        let originalAction = makeMoveAction(fromPath: "INBOX", toPath: "Trash")
        if case .move(let from, let to) = originalAction.type {
            // Undo would call: undoDestructiveAction(fromFolderPath: to, toFolderPath: from)
            #expect(to == "Trash")   // becomes fromFolderPath in undo
            #expect(from == "INBOX") // becomes toFolderPath in undo
        }
    }
}
