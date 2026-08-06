/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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

    @Test("outboxStatus FAILS CLOSED to .failed for an unknown status string")
    func outboxStatusFallback() {
        // F2b §1.3: an unknown status is NON-DRAINABLE — .failed, never .queued.
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = "unknown_status"
        #expect(msg.outboxStatus == .failed)
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

// MARK: - Round-9: "Delete All Email Index Data" and the Outbox

/// The local-index wipe is a **lifecycle** boundary — owner-approved, explicit,
/// outside the drain — and `Companion/Rules/Active/never-drop-user-intention.md`
/// states the limit of that carve-out outright: it *"does not extend past queue
/// state: Outbox sends, user-authored drafts, bodies, attachments and FTS content
/// are never dropped under it."*
///
/// These tests execute the PRODUCTION statement list against the PRODUCTION
/// schema, so they cannot drift from what the gesture actually runs.
@Suite("Local index wipe — Outbox survival")
struct LocalIndexWipeOutboxTests {

    private func runWipe(_ db: DatabaseQueue) throws {
        try db.write { connection in
            for sql in SettingsView.localIndexWipeStatements {
                try connection.execute(sql: sql)
            }
        }
    }

    @Test("""
    A queued Outbox send survives the local index wipe with its payload intact — \
    it has never reached a server, so it cannot "re-sync automatically from your \
    servers" and deleting it destroys the message outright
    """)
    func queuedOutboxSendSurvivesTheWipe() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db)

        let authoredBody = "Text the user composed that has never left this device."
        var queued = OutboxMessage(
            accountId: "acc1",
            draft: DraftMessage(
                to: ["recipient@example.com"], subject: "Unsent", body: authoredBody))
        queued.id = "outbox-1"
        queued.status = OutboxStatus.queued.rawValue
        let insertable = queued
        try db.write { try insertable.insert($0) }

        try runWipe(db)

        let survivor = try db.read { try OutboxMessage.fetchOne($0, key: "outbox-1") }
        guard let survivor else {
            Issue.record("the queued send was destroyed by the local index wipe")
            return
        }
        #expect(survivor.body == authoredBody, "and it survives with its payload, not as a husk")
        #expect(survivor.subject == "Unsent")
        #expect(survivor.status == OutboxStatus.queued.rawValue,
                "still drainable — surviving in a state the drain skips is not survival")

        // NON-VACUITY: the wipe really ran. Without this the test above passes on
        // a statement list that does nothing at all.
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 0)
    }

    @Test("""
    HELD DIRECTION — queued message ACTIONS are still purged: they address \
    messageHeader rows the same transaction destroys, so leaving them would queue \
    mutations against addresses that no longer exist locally
    """)
    func queuedMessageActionsAreStillPurged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { try op.insert($0) }
        #expect(try db.read { try PendingOperation.fetchCount($0) } == 1)

        try runWipe(db)

        #expect(try db.read { try PendingOperation.fetchCount($0) } == 0,
                "the pendingOperation purge is deliberate and must not be removed with the outbox one")
    }
}
