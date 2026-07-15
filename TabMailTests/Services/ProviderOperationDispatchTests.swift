/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

private func makeHeader(
    messageId: String = "100",
    subject: String = "Test Subject",
    from: String = "sender@example.com",
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    isRead: Bool = false,
    isFlagged: Bool = false,
    rfc822MessageId: String? = nil
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
    header.isFlagged = isFlagged
    header.rfc822MessageId = rfc822MessageId
    return header
}

private func makeDraft(
    to: [String] = ["to@example.com"],
    subject: String = "Test Draft",
    body: String = "Hello world"
) -> DraftMessage {
    DraftMessage(to: to, subject: subject, body: body)
}

// MARK: - Suite 1: Operation Type Dispatch

@Suite("Operation Type Dispatch")
struct OperationTypeDispatchTests {

    @Test("markRead dispatches to provider.markRead with correct ids and folder")
    @MainActor
    func markReadDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("markRead(") })
        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1", "msg-2"])
        #expect(reads[0].folder == "INBOX")
    }

    @Test("markUnread dispatches to provider.markUnread with correct ids and folder")
    @MainActor
    func markUnreadDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-1"])
        #expect(unreads[0].folder == "INBOX")
    }

    @Test("markFlagged dispatches to provider.markFlagged with flagged=true")
    @MainActor
    func markFlaggedDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("markUnflagged dispatches to provider.markFlagged with flagged=false")
    @MainActor
    func markUnflaggedDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == false)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("move dispatches to provider.move with correct ids, from, and to")
    @MainActor
    func moveDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Archive")
    }

    @Test("archive type is a legacy no-op")
    @MainActor
    func archiveLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .archive,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy archive should not call any provider method")
    }

    @Test("delete type is a legacy no-op")
    @MainActor
    func deleteLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .delete,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy delete should not call any provider method")
    }
}

// MARK: - Suite 3: Error Propagation

@Suite("Error Propagation")
struct ErrorPropagationTests {

    @Test("markRead throws propagates error from provider")
    @MainActor
    func markReadThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setMarkReadThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("move throws propagates error from provider")
    @MainActor
    func moveThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

}

// MARK: - Suite 5: Send Operation Flow

@Suite("Send Operation Flow")
struct SendOperationFlowTests {

    @Test("send dispatches to provider.send with DraftMessage")
    @MainActor
    func sendDispatch() async throws {
        let mock = MockEmailProvider()
        let draft = makeDraft(to: ["alice@example.com"], subject: "Hello", body: "World")

        try await mock.send(draft: draft)

        let sent = await mock.sentDrafts
        #expect(sent.count == 1)
        #expect(sent[0].to == ["alice@example.com"])
        #expect(sent[0].subject == "Hello")
        #expect(sent[0].body == "World")
    }

    @Test("appendToSentFolder dispatches with draft, sentFolderPath, and messageId")
    @MainActor
    func appendToSentDispatch() async throws {
        let mock = MockEmailProvider()
        let draft = makeDraft()
        let sentMsgId = "<generated-id@example.com>"

        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: sentMsgId)

        #expect(result == true)
        let appended = await mock.appendedToSent
        #expect(appended.count == 1)
        #expect(appended[0].sentFolderPath == "Sent")
        #expect(appended[0].messageId == sentMsgId)
    }

    @Test("send throws propagates error")
    @MainActor
    func sendThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setSendThrows(ProviderError.notConnected)
        let draft = makeDraft()

        await #expect(throws: ProviderError.self) {
            try await mock.send(draft: draft)
        }
    }

    @Test("appendToSentFolder returns false when provider auto-saves (still succeeds)")
    @MainActor
    func appendReturnsFalse() async throws {
        let mock = MockEmailProvider()
        await mock.setAppendToSentResult(false)
        let draft = makeDraft()

        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: "<id@example.com>")

        // false means the provider didn't append (e.g., Gmail auto-saves) — this is NOT an error
        #expect(result == false)

        // The call was still made
        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("appendToSentFolder(") })
    }
}

// MARK: - Suite 6: Move Edge Cases

@Suite("Move Operation Edge Cases")
struct MoveEdgeCaseTests {

    @Test("move with missing destinationPath throws messageNotFound")
    @MainActor
    func moveMissingDestination() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: nil
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("move with source == destination is a no-op")
    @MainActor
    func moveSameSourceAndDest() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "Archive",
            destinationPath: "Archive"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.isEmpty, "Self-move should be a no-op")
    }
}

// MARK: - Suite 7: stableId Computed Property

@Suite("MessageHeader stableId")
struct StableIdTests {

    @Test("stableId returns rfc822MessageId for numeric messageId")
    func stableIdNumericUID() {
        let header = makeHeader(messageId: "42", rfc822MessageId: "<abc@example.com>")
        #expect(header.stableId == "<abc@example.com>")
    }

    @Test("stableId returns messageId for non-numeric messageId")
    func stableIdNonNumeric() {
        let header = makeHeader(messageId: "gmail-id-xyz", rfc822MessageId: "<abc@example.com>")
        #expect(header.stableId == "gmail-id-xyz")
    }

    @Test("stableId returns messageId when rfc822MessageId is nil")
    func stableIdNilRfc822() {
        let header = makeHeader(messageId: "42", rfc822MessageId: nil)
        #expect(header.stableId == "42")
    }

    @Test("stableId returns messageId when rfc822MessageId is empty")
    func stableIdEmptyRfc822() {
        let header = makeHeader(messageId: "42", rfc822MessageId: "")
        #expect(header.stableId == "42")
    }
}
