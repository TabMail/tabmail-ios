/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - AccountManager.generateMessageId

@Suite("AccountManager.generateMessageId")
struct GenerateMessageIdTests {

    @Test("Extracts domain from standard email address")
    func extractsDomain() {
        let id = AccountManager.generateMessageId(senderEmail: "alice@example.com")
        #expect(id.hasSuffix("@example.com>"))
        #expect(id.hasPrefix("<"))
    }

    @Test("Uses the string itself as domain when no @ present")
    func noDomainSeparator() {
        let id = AccountManager.generateMessageId(senderEmail: "nodomain")
        // split(separator: "@").last returns "nodomain" when there's no @
        #expect(id.hasSuffix("@nodomain>"))
    }

    @Test("Uses tabmail.local for empty string")
    func emptyEmail() {
        let id = AccountManager.generateMessageId(senderEmail: "")
        #expect(id.hasSuffix("@tabmail.local>"))
    }

    @Test("Produces RFC822 format with angle brackets")
    func rfc822Format() {
        let id = AccountManager.generateMessageId(senderEmail: "user@test.org")
        #expect(id.hasPrefix("<"))
        #expect(id.hasSuffix(">"))
        #expect(id.contains("@"))
    }

    @Test("Generates unique IDs for same email")
    func uniqueIds() {
        let id1 = AccountManager.generateMessageId(senderEmail: "user@test.com")
        let id2 = AccountManager.generateMessageId(senderEmail: "user@test.com")
        #expect(id1 != id2)
    }

    @Test("Handles email with subdomain")
    func subdomain() {
        let id = AccountManager.generateMessageId(senderEmail: "user@mail.company.co.uk")
        #expect(id.hasSuffix("@mail.company.co.uk>"))
    }

    @Test("Handles email with multiple @ signs (takes last)")
    func multipleAtSigns() {
        let id = AccountManager.generateMessageId(senderEmail: "user@first@second.com")
        #expect(id.hasSuffix("@second.com>"))
    }

    @Test("UUID portion is 36 characters (standard UUID format)")
    func uuidFormat() {
        let id = AccountManager.generateMessageId(senderEmail: "user@test.com")
        // Format: <UUID@domain>
        let inner = String(id.dropFirst().dropLast()) // Remove < and >
        let parts = inner.split(separator: "@", maxSplits: 1)
        let uuidPart = String(parts[0])
        #expect(uuidPart.count == 36) // Standard UUID: 8-4-4-4-12
    }
}

// MARK: - OutboxStatus state machine logic

@Suite("OutboxStatus State Machine")
struct OutboxStatusStateMachineTests {

    @Test("All three statuses have distinct raw values")
    func distinctRawValues() {
        let rawValues: Set<String> = [
            OutboxStatus.queued.rawValue,
            OutboxStatus.sending.rawValue,
            OutboxStatus.failed.rawValue
        ]
        #expect(rawValues.count == 3)
    }

    @Test("OutboxStatus init from raw value round-trips")
    func rawValueRoundTrip() {
        for status in [OutboxStatus.queued, .sending, .failed] {
            let reconstructed = OutboxStatus(rawValue: status.rawValue)
            #expect(reconstructed == status)
        }
    }

    @Test("Unknown raw value returns nil")
    func unknownRawValue() {
        #expect(OutboxStatus(rawValue: "cancelled") == nil)
        #expect(OutboxStatus(rawValue: "") == nil)
        #expect(OutboxStatus(rawValue: "QUEUED") == nil)
    }

    @Test("outboxStatus falls back to .queued for unknown status string")
    func outboxStatusFallback() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = "unknown_status"
        #expect(msg.outboxStatus == .queued)
    }
}

// MARK: - OutboxMessage computed accessors

@Suite("OutboxMessage Computed Accessors")
struct OutboxMessageComputedAccessorTests {

    @Test("to getter decodes JSON")
    func toGetter() {
        let draft = DraftMessage(to: ["alice@test.com", "bob@test.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.to == ["alice@test.com", "bob@test.com"])
    }

    @Test("to setter encodes JSON")
    func toSetter() {
        let draft = DraftMessage(to: ["initial@test.com"], subject: "Hi", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.to = ["new@test.com", "other@test.com"]
        #expect(msg.to == ["new@test.com", "other@test.com"])
        // Verify the underlying JSON was updated
        let decoded = decodeStringArray(msg.toJSON)
        #expect(decoded == ["new@test.com", "other@test.com"])
    }

    @Test("cc getter returns empty array when empty JSON")
    func ccEmptyArray() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.cc.isEmpty)
    }

    @Test("bcc getter returns empty array when empty JSON")
    func bccEmptyArray() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.bcc.isEmpty)
    }

    @Test("references getter decodes from referencesJSON")
    func referencesGetter() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Re: Hi", body: "Body", references: ["ref1@test.com", "ref2@test.com"])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.references == ["ref1@test.com", "ref2@test.com"])
    }

    @Test("references returns empty when referencesJSON is nil-like")
    func referencesEmpty() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.references.isEmpty)
    }
}

// MARK: - OutboxMessage init from DraftMessage

@Suite("OutboxMessage Init From DraftMessage")
struct OutboxMessageInitTests {

    @Test("Captures all draft fields")
    func capturesAllFields() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            cc: ["cc@test.com"],
            bcc: ["bcc@test.com"],
            subject: "Test Subject",
            body: "<p>Hello</p>",
            isHTML: true,
            inReplyTo: "orig@test.com",
            references: ["ref1@test.com"]
        )
        let msg = OutboxMessage(accountId: "myAccount", draft: draft, originalMessageHeaderId: "header-123", isForward: true)
        #expect(msg.accountId == "myAccount")
        #expect(msg.to == ["to@test.com"])
        #expect(msg.cc == ["cc@test.com"])
        #expect(msg.bcc == ["bcc@test.com"])
        #expect(msg.subject == "Test Subject")
        #expect(msg.body == "<p>Hello</p>")
        #expect(msg.isHTML == true)
        #expect(msg.inReplyTo == "orig@test.com")
        #expect(msg.references == ["ref1@test.com"])
        #expect(msg.originalMessageHeaderId == "header-123")
        #expect(msg.isForward == true)
    }

    @Test("attachmentsDirName is nil when no attachments")
    func noAttachmentsDirName() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == nil)
        #expect(msg.attachmentsDir == nil)
    }

    @Test("attachmentsDirName is set when attachments present")
    func attachmentsDirNameSet() {
        let attachment = DraftAttachment(filename: "test.txt", mimeType: "text/plain", data: Data("hello".utf8))
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body", attachments: [attachment])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == msg.id)
    }

    @Test("attachmentsDir URL is constructed from attachmentsDirName")
    func attachmentsDirURL() {
        let attachment = DraftAttachment(filename: "test.txt", mimeType: "text/plain", data: Data("hello".utf8))
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body", attachments: [attachment])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        let dir = msg.attachmentsDir
        #expect(dir != nil)
        #expect(dir!.lastPathComponent == msg.id)
    }

    @Test("originalMessageHeaderId defaults to nil")
    func originalMessageHeaderIdDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.originalMessageHeaderId == nil)
    }

    @Test("isForward defaults to false")
    func isForwardDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.isForward == false)
    }
}

// MARK: - OutboxMessage retry logic constants

@Suite("OutboxMessage Retry Logic")
struct OutboxMessageRetryLogicTests {

    @Test("Status transitions: queued -> sending -> queued (auto-retry)")
    func autoRetryTransition() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.outboxStatus == .queued)

        msg.status = OutboxStatus.sending.rawValue
        #expect(msg.outboxStatus == .sending)

        // Auto-retry: retryCount < 3, stays queued
        msg.status = OutboxStatus.queued.rawValue
        msg.retryCount = 1
        #expect(msg.outboxStatus == .queued)
    }

    @Test("Status transitions: queued -> sending -> failed (max retries)")
    func failedTransition() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)

        msg.status = OutboxStatus.sending.rawValue
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        #expect(msg.outboxStatus == .failed)
        #expect(msg.retryCount == 3)
    }

    @Test("Manual retry: failed -> queued with reset retryCount")
    func manualRetryReset() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)

        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        msg.errorMessage = "Network error"

        // Manual retry
        msg.status = OutboxStatus.queued.rawValue
        msg.retryCount = 0
        msg.errorMessage = nil

        #expect(msg.outboxStatus == .queued)
        #expect(msg.retryCount == 0)
        #expect(msg.errorMessage == nil)
    }
}

// MARK: - OutboxMessage databaseTableName

@Suite("OutboxMessage Database Config")
struct OutboxMessageDatabaseConfigTests {

    @Test("databaseTableName is outboxMessage")
    func tableName() {
        #expect(OutboxMessage.databaseTableName == "outboxMessage")
    }

    @Test("attachmentsBaseDir ends with outbox_attachments")
    func baseDir() {
        let baseDir = OutboxMessage.attachmentsBaseDir
        #expect(baseDir.lastPathComponent == "outbox_attachments")
    }
}
