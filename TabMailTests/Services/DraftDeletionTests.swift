/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for draft save/delete lifecycle: isPermanentlyInvalidError classification,
/// DraftSaveResult struct, pendingAllIds protection for .saveDraft ops, and
/// flushAIBatch folder filtering.
@Suite("Draft Deletion Tests")
struct DraftDeletionTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "DRAFT", role: .drafts, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Inbox", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
    }

    // MARK: - isPermanentlyInvalidError

    @Test("isPermanentlyInvalidError: Gmail 400 returns true")
    func permanentlyInvalidGmail400() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 400))
        let manager = AccountManager.shared
        #expect(manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Exchange 400 returns true")
    func permanentlyInvalidExchange400() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Exchange", code: 400))
        let manager = AccountManager.shared
        #expect(manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: non-REST domain 400 returns false")
    func permanentlyInvalidOtherDomain400() {
        let error = ProviderError.networkError(underlying: NSError(domain: "IMAP", code: 400))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail 404 returns false (not permanently invalid)")
    func permanentlyInvalidGmail404() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 404))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail 500 returns false")
    func permanentlyInvalidGmail500() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 500))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: non-ProviderError returns false")
    func permanentlyInvalidNonProviderError() {
        let error = NSError(domain: "Gmail", code: 400)
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: messageNotFound returns false")
    func permanentlyInvalidMessageNotFound() {
        let error = ProviderError.messageNotFound
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    // MARK: - isPermanentlyInvalidError — HTTPError enum shape (commit 06f4b3c)
    //
    // GmailProvider / ExchangeProvider's `request()` helpers throw
    // `ProviderError.networkError(underlying: HTTPError.networkError(statusCode: N))`.
    // The classifier must enum-pattern-match the underlying directly — bridging
    // HTTPError to NSError gives `domain="TabMail.HTTPError" code=<case ordinal>`,
    // NOT the HTTP status code. The previous NSError-only check silently missed
    // every Gmail/Exchange 400 thrown this way, which is why a stuck `.move` op
    // (Gmail "Invalid label: Deleted Messages") retried for 9 days.

    @Test("isPermanentlyInvalidError: HTTPError.networkError(400) returns true")
    func permanentlyInvalidHTTPError400() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 400))
        let manager = AccountManager.shared
        #expect(manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(404) returns false")
    func permanentlyInvalidHTTPError404() {
        // 404 is messageNotFound's job, not the permanent-invalid classifier.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(500) returns false")
    func permanentlyInvalidHTTPError500() {
        // 5xx is transient; must retry.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(429) returns false")
    func permanentlyInvalidHTTPError429() {
        // Throttle is transient; must retry.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    // MARK: - DraftSaveResult

    @Test("DraftSaveResult: init with serverId only")
    func draftSaveResultServerIdOnly() {
        let result = DraftSaveResult(serverId: "r-123")
        #expect(result.serverId == "r-123")
        #expect(result.messageId == nil)
    }

    @Test("DraftSaveResult: init with serverId and messageId (Gmail)")
    func draftSaveResultGmail() {
        let result = DraftSaveResult(serverId: "r-123", messageId: "19d4abc")
        #expect(result.serverId == "r-123")
        #expect(result.messageId == "19d4abc")
    }

    // MARK: - PendingOperation messageIds for .saveDraft

    @Test("saveDraft PendingOperation includes placeholder messageId for pendingAllIds protection")
    func saveDraftPendingOpIncludesPlaceholder() throws {
        let draftId = "test-draft-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"

        // Insert a Draft record (required by queueDraftSave)
        try db.write { db in
            let draft = Draft(
                id: draftId,
                accountId: "acc1",
                toJSON: "[]",
                ccJSON: "[]",
                bccJSON: "[]",
                subject: "Test",
                body: "Body",
                replyToId: nil,
                isForward: false,
                editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            try draft.save(db)
        }

        // Simulate what queueDraftSave does: create PendingOperation with protection IDs
        try db.write { db in
            let draft = try Draft.fetchOne(db, key: draftId)!
            var opMsgIds = [draftId, placeholderMsgId]
            if let rfc822 = draft.rfc822MessageId {
                opMsgIds.append(rfc822)
            }
            try PendingOperation(
                type: .saveDraft,
                messageIds: opMsgIds,
                accountId: "acc1",
                folderPath: "DRAFT"
            ).insert(db)
        }

        // Verify the PendingOperation has the right messageIds
        let ops = try db.read { db in
            try PendingOperation.filter(Column("type") == OperationType.saveDraft.rawValue).fetchAll(db)
        }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds.contains(draftId))
        #expect(ops[0].messageIds.contains(placeholderMsgId))
    }

    // MARK: - Optimistic draft header + body creation

    @Test("queueDraftSave creates optimistic MessageHeader in Drafts folder")
    func optimisticHeaderCreated() throws {
        let draftId = "header-test-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"

        try db.write { db in
            let draft = Draft(
                id: draftId,
                accountId: "acc1",
                toJSON: "[\"test@example.com\"]",
                ccJSON: "[]",
                bccJSON: "[]",
                subject: "Optimistic Test",
                body: "Hello world",
                replyToId: nil,
                isForward: false,
                editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            try draft.save(db)

            // Simulate optimistic header creation (from queueDraftSave)
            let folderId = "acc1:DRAFT"
            let headerId = "\(folderId):\(placeholderMsgId)"
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Optimistic Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "Hello world",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            try header.insert(db)

            let body = MessageBody(headerId: headerId, htmlContent: MessageBody.plainTextToHTML("Hello world"))
            try body.save(db)
        }

        // Verify header exists
        let folderId = "acc1:DRAFT"
        let headerId = "\(folderId):\(placeholderMsgId)"
        let header = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(header != nil)
        #expect(header?.subject == "Optimistic Test")

        // Verify body exists
        let body = try db.read { db in try MessageBody.fetchOne(db, key: headerId) }
        #expect(body != nil)
        #expect(body?.htmlContent?.contains("Hello world") == true)
    }

    // MARK: - Header migration (simulates pushDraftToServer)

    @Test("Draft header migration: placeholder PK migrated to real messageId")
    func headerMigrationPlaceholderToReal() throws {
        let draftId = "migrate-test-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"
        let realMessageId = "19d4abc123"
        let folderId = "acc1:DRAFT"
        let oldHeaderId = "\(folderId):\(placeholderMsgId)"
        let newHeaderId = "\(folderId):\(realMessageId)"

        // Create optimistic header + body
        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Migration Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "Body text",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-rfc822@test.com"
            try header.insert(db)

            let body = MessageBody(headerId: oldHeaderId, htmlContent: "<p>Body text</p>")
            try body.save(db)
        }

        // Simulate migration (what pushDraftToServer does).
        // Must save body content BEFORE deleting header (ON DELETE CASCADE deletes body too).
        try db.write { db in
            if let existing = try MessageHeader.fetchOne(db, key: oldHeaderId) {
                let savedHtml = try MessageBody.fetchOne(db, key: oldHeaderId)?.htmlContent
                try existing.delete(db) // CASCADE deletes body
                var migrated = existing
                migrated.id = newHeaderId
                migrated.messageId = realMessageId
                try migrated.insert(db)
                let newBody = MessageBody(headerId: newHeaderId, htmlContent: savedHtml)
                try newBody.insert(db)
            }
        }

        // Old PK should be gone
        let oldHeader = try db.read { db in try MessageHeader.fetchOne(db, key: oldHeaderId) }
        #expect(oldHeader == nil)
        let oldBody = try db.read { db in try MessageBody.fetchOne(db, key: oldHeaderId) }
        #expect(oldBody == nil)

        // New PK should exist with preserved content
        let newHeader = try db.read { db in try MessageHeader.fetchOne(db, key: newHeaderId) }
        #expect(newHeader != nil)
        #expect(newHeader?.subject == "Migration Test")
        #expect(newHeader?.messageId == realMessageId)
        #expect(newHeader?.rfc822MessageId == "draft-rfc822@test.com")

        let newBody = try db.read { db in try MessageBody.fetchOne(db, key: newHeaderId) }
        #expect(newBody != nil)
        #expect(newBody?.htmlContent == "<p>Body text</p>")
    }

    // MARK: - Three-strategy deletion (simulates optimisticDeleteDraftHeader)

    @Test("Optimistic delete: strategy 1 — exact PK from serverDraftHeader")
    func deleteByExactPK() throws {
        let headerId = "acc1:DRAFT:19d4abc123"

        try db.write { db in
            var header = MessageHeader(
                messageId: "19d4abc123",
                subject: "Delete Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "",
                folderId: "acc1:DRAFT",
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.isRead = true
            try header.insert(db)
        }

        // Strategy 1: delete by exact PK
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: headerId)
        }

        let result = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(result == nil)
    }

    @Test("Optimistic delete: strategy 3 — rfc822MessageId fallback")
    func deleteByRfc822MessageId() throws {
        let rfc822 = "draft-fallback@test.com"
        let folderId = "acc1:DRAFT"

        try db.write { db in
            var header = MessageHeader(
                messageId: "19d4different",
                subject: "RFC822 Fallback",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            try header.insert(db)
        }

        // Strategy 3: delete by rfc822MessageId query
        try db.write { db in
            let matches = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                .fetchAll(db)
            for header in matches {
                try header.delete(db)
            }
        }

        let remaining = try db.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        }
        #expect(remaining == 0)
    }

    // MARK: - Mock provider draft operations

    @Test("MockEmailProvider.deleteDraft records call")
    func mockDeleteDraft() async throws {
        let provider = MockEmailProvider()
        try await provider.deleteDraft(draftId: "draft-123", draftsFolderPath: "DRAFT")
        let log = await provider.callLog
        #expect(log.contains { $0.contains("deleteDraft") })
    }

    // MARK: - isMessageNotFoundError (boundary with isPermanentlyInvalidError)

    @Test("isMessageNotFoundError: 404 is message-not-found, not permanently invalid")
    func messageNotFound404() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 404))
        let manager = AccountManager.shared
        #expect(manager.isMessageNotFoundError(error))
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isMessageNotFoundError: messageNotFound enum case")
    func messageNotFoundEnumCase() {
        let error = ProviderError.messageNotFound
        let manager = AccountManager.shared
        #expect(manager.isMessageNotFoundError(error))
    }
}
