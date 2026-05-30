/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - executeOperation Tests

@Suite("AccountManager.executeOperation")
struct ExecuteOperationTests {

    // MARK: - Move Operations

    @Test("move calls provider.move with correct parameters")
    @MainActor
    func moveCallsProvider() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("move(") })
        let moved = await mock.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Archive")
    }

    @Test("move with missing destinationPath throws messageNotFound")
    @MainActor
    func moveMissingDestination() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acct1",
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
            accountId: "acct1",
            folderPath: "Archive",
            destinationPath: "Archive"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.isEmpty, "Self-move should be a no-op — provider.move should not be called")
    }

    @Test("move propagates provider error")
    @MainActor
    func movePropagatesError() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    // MARK: - Mark Read / Unread

    @Test("markRead calls provider.markRead")
    @MainActor
    func markRead() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("markRead(") })
        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1"])
        #expect(reads[0].folder == "INBOX")
    }

    @Test("markUnread calls provider.markUnread")
    @MainActor
    func markUnread() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-1", "msg-2"])
    }

    // MARK: - Flag Operations

    @Test("markFlagged calls provider.markFlagged with flagged=true")
    @MainActor
    func markFlagged() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].flagged == true)
    }

    @Test("markUnflagged calls provider.markFlagged with flagged=false")
    @MainActor
    func markUnflagged() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].flagged == false)
    }

    // MARK: - Legacy Archive/Delete

    @Test("archive type is a no-op (legacy)")
    @MainActor
    func archiveLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .archive,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy archive should not call any provider method")
    }

    @Test("delete type is a no-op (legacy)")
    @MainActor
    func deleteLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .delete,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy delete should not call any provider method")
    }

    // MARK: - Tag Operations (non-IMAP/Gmail/Exchange provider = no-op)

    @Test("setTag with missing tagValue does not throw (returns silently)")
    @MainActor
    func setTagMissingTagValue() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX",
            tagValue: nil
        )

        // Should not throw — early returns with a print
        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "setTag with nil tagValue should early-return without calling provider")
    }

    @Test("setTag with empty messageIds does not throw")
    @MainActor
    func setTagEmptyMessageIds() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .setTag,
            messageIds: [],
            accountId: "acct1",
            folderPath: "INBOX",
            tagValue: "reply"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty)
    }

    @Test("removeTag with empty messageIds does not throw")
    @MainActor
    func removeTagEmptyMessageIds() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .removeTag,
            messageIds: [],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty)
    }

    // MARK: - markReplied / markForwarded (non-IMAP = no-op)

    @Test("markReplied with non-IMAP provider is a no-op")
    @MainActor
    func markRepliedNonImap() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markReplied,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "markReplied with non-IMAP provider should be a no-op")
    }

    @Test("markForwarded with non-IMAP provider is a no-op")
    @MainActor
    func markForwardedNonImap() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markForwarded,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "markForwarded with non-IMAP provider should be a no-op")
    }
}
