/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for AccountManagerQueue drain flow patterns.
/// Tests the DB-level logic used by drainPendingQueue and executeOperation,
/// using TestDatabase + MockEmailProvider for real GRDB + mock provider interaction.
@Suite("AccountManagerQueue Integration")
struct AccountManagerQueueIntegrationTests {

    // MARK: - executeOperation via AccountManager.shared

    @Test("executeOperation move calls provider.move with correct args")
    @MainActor
    func executeOperationMoveCallsProvider() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Trash")
    }

    @Test("executeOperation markRead calls provider.markRead")
    @MainActor
    func executeOperationMarkRead() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1"])
        #expect(reads[0].folder == "INBOX")
    }

    @Test("executeOperation markUnread calls provider.markUnread")
    @MainActor
    func executeOperationMarkUnread() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-3"],
            accountId: "acct1",
            folderPath: "Sent"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-3"])
        #expect(unreads[0].folder == "Sent")
    }

    @Test("executeOperation markFlagged calls provider with flagged=true")
    @MainActor
    func executeOperationMarkFlagged() async throws {
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
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("executeOperation markUnflagged calls provider with flagged=false")
    @MainActor
    func executeOperationMarkUnflagged() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-2"],
            accountId: "acct1",
            folderPath: "INBOX"
        )

        try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].flagged == false)
    }

    @Test("executeOperation propagates provider connection error")
    @MainActor
    func executeOperationPropagatesConnectionError() async throws {
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

    @Test("executeOperation propagates messageNotFound error")
    @MainActor
    func executeOperationPropagatesMessageNotFound() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.messageNotFound)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acct1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

}
