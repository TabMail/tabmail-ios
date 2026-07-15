/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Stateful Gmail action transport")
struct StatefulGmailActionServerTests {
    @Test("Gmail user-label membership becomes authoritative after catalog discovery")
    func userLabelCatalogAuthority() async throws {
        let labelId = "Label_42"
        let server = StatefulGmailActionServer(
            messages: [.init(
                rfc822MessageId: "gmail-label-catalog@example.com",
                providerMessageId: "gmail-label-catalog-1",
                labels: ["INBOX", labelId]
            )],
            userLabels: [
                labelId: "Project",
                "Label_99": "tm_legacy",
            ]
        )
        defer { server.close() }
        let provider = server.provider()

        let beforeCatalog = try await provider.fetchMessages(
            folder: "INBOX",
            limit: 10,
            offset: 0
        )
        #expect(beforeCatalog.count == 1)
        guard beforeCatalog.count == 1 else { return }
        #expect(beforeCatalog[0].userLabelIds.isEmpty)
        #expect(!beforeCatalog[0].userLabelIdsAreAuthoritative)

        #expect(try await provider.findLabelIdByName("Project") == labelId)
        #expect(try await provider.findLabelIdByName("tm_legacy") == nil)

        let folders = try await provider.fetchFolders()
        #expect(folders.contains { $0.path == labelId && $0.name == "Project" })

        let afterCatalog = try await provider.fetchMessages(
            folder: "INBOX",
            limit: 10,
            offset: 0
        )
        #expect(afterCatalog.count == 1)
        guard afterCatalog.count == 1 else { return }
        #expect(afterCatalog[0].userLabelIds == [labelId])
        #expect(afterCatalog[0].userLabelIdsAreAuthoritative)
    }

    @Test("a newly created opaque Gmail label is immediately recognized by message parsing")
    func createdUserLabelIsImmediatelyKnown() async throws {
        let existingLabelId = "Label_42"
        let createdLabelId = "Label_43"
        let server = StatefulGmailActionServer(
            messages: [.init(
                rfc822MessageId: "gmail-label-created@example.com",
                providerMessageId: "gmail-label-created-1",
                labels: ["INBOX", createdLabelId]
            )],
            userLabels: [existingLabelId: "Existing"],
            createdLabelId: createdLabelId
        )
        defer { server.close() }
        let provider = server.provider()

        _ = try await provider.fetchFolders()
        #expect(try await provider.createLabel(name: "Created") == createdLabelId)

        let headers = try await provider.fetchMessages(
            folder: "INBOX",
            limit: 10,
            offset: 0
        )
        #expect(headers.count == 1)
        guard headers.count == 1 else { return }
        #expect(headers[0].userLabelIds == [createdLabelId])
        #expect(headers[0].userLabelIdsAreAuthoritative)
    }

    @Test("an older overlapping label catalog cannot overwrite newer label knowledge")
    func overlappingUserLabelCatalogsKeepNewestKnowledge() {
        var catalog = GmailUserLabelCatalogState()
        let olderRequest = catalog.beginRequest()
        let newerRequest = catalog.beginRequest()

        catalog.apply(
            userLabelIds: ["Label_42"],
            legacyTmLabelIds: [],
            request: newerRequest
        )
        catalog.apply(
            userLabelIds: ["Label_41"],
            legacyTmLabelIds: [],
            request: olderRequest
        )

        #expect(catalog.knownUserLabelIds == ["Label_42"])
        #expect(catalog.isAuthoritative)

        let requestBeforeCreate = catalog.beginRequest()
        catalog.recordKnownUserLabel("Label_43")
        catalog.apply(
            userLabelIds: ["Label_42"],
            legacyTmLabelIds: [],
            request: requestBeforeCreate
        )
        #expect(catalog.knownUserLabelIds == ["Label_42", "Label_43"])
    }

    @Test("real Gmail adapter mutates final move, read, flag, and label state by RFC identity")
    func actionFinalState() async throws {
        let rfc822MessageId = "gmail-stateful@example.com"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: "gmail-resource-1",
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(ids: [rfc822MessageId], folder: "INBOX")
        try await provider.markFlagged(ids: [rfc822MessageId], flagged: true, folder: "INBOX")
        try await provider.setUserLabel(
            ids: [rfc822MessageId], labelId: "Label_1", present: true, folder: "INBOX"
        )
        try await provider.move(
            ids: [rfc822MessageId], from: "INBOX", to: GmailProvider.archivePath
        )

        let archived = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(archived.count == 1)
        guard archived.count == 1 else { return }
        #expect(archived[0].providerMessageId == "gmail-resource-1")
        #expect(archived[0].isRead)
        #expect(archived[0].isFlagged)
        #expect(archived[0].labels.contains("Label_1"))
        #expect(!archived[0].labels.contains("INBOX"))

        let archivedHeaders = try await provider.fetchMessages(
            folder: GmailProvider.archivePath,
            limit: 10,
            offset: 0
        )
        #expect(archivedHeaders.count == 1)
        guard archivedHeaders.count == 1 else { return }
        #expect(archivedHeaders[0].messageId == "gmail-resource-1")
        #expect(archivedHeaders[0].rfc822MessageId == rfc822MessageId)
        #expect(archivedHeaders[0].isRead)
        #expect(archivedHeaders[0].isFlagged)

        try await provider.move(
            ids: [rfc822MessageId], from: GmailProvider.archivePath, to: "INBOX"
        )
        let restored = server.snapshots(rfc822MessageId: rfc822MessageId)
        #expect(restored.count == 1)
        guard restored.count == 1 else { return }
        #expect(restored[0].labels.contains("INBOX"))

        let inboxHeaders = try await provider.fetchMessages(folder: "INBOX", limit: 10, offset: 0)
        #expect(inboxHeaders.count == 1)
        guard inboxHeaders.count == 1 else { return }
        #expect(inboxHeaders[0].rfc822MessageId == rfc822MessageId)
    }

    @Test("missing and duplicate RFC identities no-op while one-shot lookup failure retries")
    func staleAmbiguousAndTransient() async throws {
        let duplicateRFC = "gmail-duplicate@example.com"
        let exactRFC = "gmail-transient@example.com"
        let server = StatefulGmailActionServer(messages: [
            .init(
                rfc822MessageId: duplicateRFC,
                providerMessageId: "gmail-duplicate-1",
                labels: ["INBOX", "UNREAD"]
            ),
            .init(
                rfc822MessageId: duplicateRFC,
                providerMessageId: "gmail-duplicate-2",
                labels: ["INBOX", "UNREAD"]
            ),
            .init(
                rfc822MessageId: exactRFC,
                providerMessageId: "gmail-transient-1",
                labels: ["INBOX", "UNREAD"]
            ),
        ])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(ids: ["gmail-missing@example.com"], folder: "INBOX")
        try await provider.markRead(ids: [duplicateRFC], folder: "INBOX")
        let duplicates = server.snapshots(rfc822MessageId: duplicateRFC)
        #expect(duplicates.count == 2)
        guard duplicates.count == 2 else { return }
        #expect(duplicates.allSatisfy { !$0.isRead })

        server.failNextLookup()
        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [exactRFC], folder: "INBOX")
        }
        let beforeRetry = server.snapshots(rfc822MessageId: exactRFC)
        #expect(beforeRetry.count == 1)
        guard beforeRetry.count == 1 else { return }
        #expect(!beforeRetry[0].isRead)

        try await provider.markRead(ids: [exactRFC], folder: "INBOX")
        let afterRetry = server.snapshots(rfc822MessageId: exactRFC)
        #expect(afterRetry.count == 1)
        guard afterRetry.count == 1 else { return }
        #expect(afterRetry[0].isRead)
    }

    @Test("ordinary folder listings decode current membership, fields, and limits")
    func ordinaryFolderListings() async throws {
        let inboxRFC = "gmail-list-inbox@example.com"
        let archiveRFC = "gmail-list-archive@example.com"
        let server = StatefulGmailActionServer(messages: [
            .init(
                rfc822MessageId: inboxRFC,
                providerMessageId: "gmail-list-1",
                labels: ["INBOX", "UNREAD"]
            ),
            .init(
                rfc822MessageId: "gmail-list-second@example.com",
                providerMessageId: "gmail-list-2",
                labels: ["INBOX"]
            ),
            .init(
                rfc822MessageId: archiveRFC,
                providerMessageId: "gmail-list-3",
                labels: ["STARRED"]
            ),
            .init(
                rfc822MessageId: "gmail-list-sent@example.com",
                providerMessageId: "gmail-list-4",
                labels: ["SENT"]
            ),
        ])
        defer { server.close() }
        let provider = server.provider()

        server.failNextLookup()
        let inbox = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        #expect(server.consumedLookupFailureCount() == 0)
        #expect(inbox.count == 1)
        guard inbox.count == 1 else { return }
        #expect(inbox[0].messageId == "gmail-list-1")
        #expect(inbox[0].rfc822MessageId == inboxRFC)
        #expect(!inbox[0].isRead)
        #expect(!inbox[0].isFlagged)

        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [inboxRFC], folder: "INBOX")
        }
        #expect(server.consumedLookupFailureCount() == 1)

        let archive = try await provider.fetchMessages(
            folder: GmailProvider.archivePath,
            limit: 10,
            offset: 0
        )
        #expect(archive.count == 1)
        guard archive.count == 1 else { return }
        #expect(archive[0].messageId == "gmail-list-3")
        #expect(archive[0].rfc822MessageId == archiveRFC)
        #expect(archive[0].isRead)
        #expect(archive[0].isFlagged)
    }
}
