/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Stateful Exchange action transport")
struct StatefulExchangeActionServerTests {
    @Test("real Exchange adapter preserves final fields while Graph IDs churn across inverse moves")
    func actionFinalState() async throws {
        let rfc822MessageId = "exchange-stateful@example.com"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: "graph/original+=",
            folderId: "source-folder"
        )])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(ids: [rfc822MessageId], folder: "source-folder")
        try await provider.markFlagged(
            ids: [rfc822MessageId], flagged: true, folder: "source-folder"
        )
        try await provider.move(
            ids: [rfc822MessageId], from: "source-folder", to: "destination-folder"
        )

        let moved = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(moved.count == 1)
        guard moved.count == 1 else { return }
        #expect(moved[0].providerMessageId != "graph/original+=")
        #expect(moved[0].folderId == "destination-folder")
        #expect(moved[0].isRead)
        #expect(moved[0].isFlagged)

        let movedHeaders = try await provider.fetchMessages(
            folder: "destination-folder",
            limit: 10,
            offset: 0
        )
        #expect(movedHeaders.count == 1)
        guard movedHeaders.count == 1 else { return }
        #expect(movedHeaders[0].messageId == moved[0].providerMessageId)
        #expect(movedHeaders[0].rfc822MessageId == rfc822MessageId)
        #expect(movedHeaders[0].isRead)
        #expect(movedHeaders[0].isFlagged)

        let firstMovedId = moved[0].providerMessageId
        try await provider.move(
            ids: [rfc822MessageId], from: "destination-folder", to: "source-folder"
        )
        let restored = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(restored.count == 1)
        guard restored.count == 1 else { return }
        #expect(restored[0].providerMessageId != firstMovedId)
        #expect(restored[0].folderId == "source-folder")
        #expect(restored[0].isRead)
        #expect(restored[0].isFlagged)

        let restoredHeaders = try await provider.fetchMessages(
            folder: "source-folder",
            limit: 10,
            offset: 0
        )
        #expect(restoredHeaders.count == 1)
        guard restoredHeaders.count == 1 else { return }
        #expect(restoredHeaders[0].messageId == restored[0].providerMessageId)
    }

    @Test("missing and duplicate RFC identities no-op while transient lookup and mutation retry")
    func staleAmbiguousAndTransient() async throws {
        let duplicateRFC = "exchange-duplicate@example.com"
        let exactRFC = "exchange-transient@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(
                rfc822MessageId: duplicateRFC,
                providerMessageId: "graph-duplicate-1",
                folderId: "source-folder"
            ),
            .init(
                rfc822MessageId: duplicateRFC,
                providerMessageId: "graph-duplicate-2",
                folderId: "source-folder"
            ),
            .init(
                rfc822MessageId: exactRFC,
                providerMessageId: "graph-transient",
                folderId: "source-folder"
            ),
        ])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(
            ids: ["exchange-missing@example.com"], folder: "source-folder"
        )
        try await provider.markRead(ids: [duplicateRFC], folder: "source-folder")
        let duplicates = server.snapshots(rfc822MessageId: duplicateRFC)
        #expect(duplicates.count == 2)
        guard duplicates.count == 2 else { return }
        #expect(duplicates.allSatisfy { !$0.isRead })

        server.failNextLookup()
        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [exactRFC], folder: "source-folder")
        }
        let afterLookupFailure = server.snapshots(rfc822MessageId: exactRFC)
        #expect(afterLookupFailure.count == 1)
        guard afterLookupFailure.count == 1 else { return }
        #expect(!afterLookupFailure[0].isRead)

        server.failNextMutation()
        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [exactRFC], folder: "source-folder")
        }
        let afterMutationFailure = server.snapshots(rfc822MessageId: exactRFC)
        #expect(afterMutationFailure.count == 1)
        guard afterMutationFailure.count == 1 else { return }
        #expect(!afterMutationFailure[0].isRead)

        try await provider.markRead(ids: [exactRFC], folder: "source-folder")
        let afterRetry = server.snapshots(rfc822MessageId: exactRFC)
        #expect(afterRetry.count == 1)
        guard afterRetry.count == 1 else { return }
        #expect(afterRetry[0].isRead)
    }

    @Test("ordinary folder listings decode current identity, fields, order, and paging")
    func ordinaryFolderListings() async throws {
        let newest = Date()
        let older = newest.addingTimeInterval(-60)
        let server = StatefulExchangeActionServer(messages: [
            .init(
                rfc822MessageId: "exchange-list-older@example.com",
                providerMessageId: "graph/list-older+=",
                folderId: "source-folder",
                receivedAt: older
            ),
            .init(
                rfc822MessageId: "exchange-list-newer@example.com",
                providerMessageId: "graph/list-newer+=",
                folderId: "source-folder",
                isRead: true,
                isFlagged: true,
                receivedAt: newest
            ),
            .init(
                rfc822MessageId: "exchange-list-other@example.com",
                providerMessageId: "graph/list-other+=",
                folderId: "other-folder",
                receivedAt: newest
            ),
        ])
        defer { server.close() }
        let provider = server.provider()

        server.failNextLookup()
        let first = try await provider.fetchMessages(folder: "source-folder", limit: 1, offset: 0)
        #expect(server.consumedLookupFailureCount() == 0)
        #expect(first.count == 1)
        guard first.count == 1 else { return }
        #expect(first[0].messageId == "graph/list-newer+=")
        #expect(first[0].rfc822MessageId == "exchange-list-newer@example.com")
        #expect(first[0].isRead)
        #expect(first[0].isFlagged)

        let second = try await provider.fetchMessages(folder: "source-folder", limit: 1, offset: 1)
        #expect(second.count == 1)
        guard second.count == 1 else { return }
        #expect(second[0].messageId == "graph/list-older+=")
        #expect(!second[0].isRead)
        #expect(!second[0].isFlagged)

        await #expect(throws: ProviderError.self) {
            try await provider.markRead(
                ids: ["exchange-list-newer@example.com"],
                folder: "source-folder"
            )
        }
        #expect(server.consumedLookupFailureCount() == 1)
    }
}
