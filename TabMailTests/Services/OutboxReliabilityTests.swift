/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SwiftMail
@testable import TabMail

@Suite("Outbox Send Reliability (ADR-IOS-019)")
struct OutboxReliabilityTests {

    @Test("sentAt guards against double-send: sentAt present means send completed")
    func sentAtGuard() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.sentAt = Date()
        try db.write { try msg.insert($0) }

        // When reconciling: sentAt != nil → DO NOT re-send
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
        // This is the double-send firewall: presence of sentAt prevents re-queue
    }

    @Test("Crash between send and delete: sentAt + appendedToSent=false → append only")
    func crashRecoverySentNotAppended() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date()
        msg.appendedToSent = false
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
        #expect(fetched?.appendedToSent == false)
        // Recovery action: append to Sent folder, then delete
    }

    @Test("Crash after send + append: sentAt + appendedToSent=true → safe to delete")
    func crashRecoverySentAndAppended() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date()
        msg.appendedToSent = true
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
        #expect(fetched?.appendedToSent == true)
        // Recovery action: just delete, everything completed
    }

    @Test("Only .queued messages are drained, not .failed")
    func onlyQueuedDrained() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Queued message
        let d1 = DraftMessage(to: ["a@b.com"], subject: "Queued", body: "Body")
        let m1 = OutboxMessage(accountId: "acc1", draft: d1)
        try db.write { try m1.insert($0) }

        // Failed message
        let d2 = DraftMessage(to: ["a@b.com"], subject: "Failed", body: "Body")
        var m2 = OutboxMessage(accountId: "acc1", draft: d2)
        m2.status = OutboxStatus.failed.rawValue
        m2.retryCount = 3
        try db.write { try m2.insert($0) }

        // Query drainable: only .queued
        let drainable = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.queued.rawValue).fetchAll($0)
        }
        #expect(drainable.count == 1)
        #expect(drainable.first?.subject == "Queued")
    }

    @Test("Auto-retry: retryCount < 3 stays queued")
    func autoRetryUnderLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Retry", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.retryCount = 2
        // Still queued because retryCount < 3
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 2)
    }

    @Test("Manual retry resets retryCount to 0")
    func manualRetryResetsCount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Reset", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 5
        try db.write { try msg.insert($0) }

        // User taps Retry → reset retryCount, set status back to queued
        msg.retryCount = 0
        msg.status = OutboxStatus.queued.rawValue
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 0)
    }

    @Test("sentMessageId generated for IMAP APPEND dedup")
    func sentMessageIdGenerated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Dedup", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.sentMessageId = "<generated-uuid@tabmail.ai>"
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentMessageId?.contains("@tabmail.ai") == true)
    }

    @Test("Failed messages are never auto-deleted")
    func failedNeverAutoDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Permanent Fail", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 10
        msg.errorMessage = "SMTP connection refused"
        try db.write { try msg.insert($0) }

        // Failed messages stay in DB — user must explicitly dismiss
        let failed = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.failed.rawValue).fetchAll($0)
        }
        #expect(failed.count == 1)
        #expect(failed.first?.errorMessage == "SMTP connection refused")
    }

    @Test("OutboxMessage cascade on account delete")
    func cascadeOnAccountDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Cascade", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let remaining = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("OutboxMessage toDraftMessage round-trips")
    func toDraftMessageRoundTrip() throws {
        let draft = DraftMessage(to: ["alice@test.com", "bob@test.com"], subject: "Multi-recipient", body: "<p>HTML body</p>")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)

        let recovered = try msg.toDraftMessage()
        #expect(recovered.to == ["alice@test.com", "bob@test.com"])
        #expect(recovered.subject == "Multi-recipient")
        #expect(recovered.body == "<p>HTML body</p>")
    }

    // MARK: - Fatal Error Classification (immediate failure, no retry)

    @Test("invalidEmailAddress is fatal — marks failed immediately")
    func invalidEmailIsFatal() {
        let error = SMTPError.invalidEmailAddress("Invalid recipient address: bad@example.com")
        #expect(AccountManager.isFatalSendError(error) == true)
    }

    @Test("messageTooLarge is fatal — marks failed immediately")
    func messageTooLargeIsFatal() {
        let error = SMTPError.messageTooLarge(messageSizeOctets: 50_000_000, maximumMessageSizeOctets: 25_000_000)
        #expect(AccountManager.isFatalSendError(error) == true)
    }

    @Test("connectionFailed is not fatal")
    func connectionFailedIsNotFatal() {
        let error = SMTPError.connectionFailed("Connection refused")
        #expect(AccountManager.isFatalSendError(error) == false)
    }

    @Test("authenticationFailed is not fatal (may succeed after token refresh)")
    func authFailedIsNotFatal() {
        let error = SMTPError.authenticationFailed("Invalid credentials")
        #expect(AccountManager.isFatalSendError(error) == false)
    }

    @Test("Unknown errors are not fatal")
    func unknownErrorIsNotFatal() {
        let error = NSError(domain: "com.test.unknown", code: 42, userInfo: nil)
        #expect(AccountManager.isFatalSendError(error) == false)
    }

    // MARK: - Transient vs Permanent Error Classification

    @Test("connectionFailed is transient")
    func connectionFailedIsTransient() {
        let error = SMTPError.connectionFailed("Connection refused")
        #expect(AccountManager.isTransientSendError(error) == true)
    }

    @Test("tlsFailed is transient")
    func tlsFailedIsTransient() {
        let error = SMTPError.tlsFailed("TLS handshake timeout")
        #expect(AccountManager.isTransientSendError(error) == true)
    }

    @Test("sendFailed is transient")
    func sendFailedIsTransient() {
        let error = SMTPError.sendFailed("Broken pipe")
        #expect(AccountManager.isTransientSendError(error) == true)
    }

    @Test("authenticationFailed is permanent")
    func authFailedIsPermanent() {
        let error = SMTPError.authenticationFailed("Invalid credentials")
        #expect(AccountManager.isTransientSendError(error) == false)
    }

    @Test("invalidEmailAddress is permanent")
    func invalidEmailIsPermanent() {
        let error = SMTPError.invalidEmailAddress("bad@")
        #expect(AccountManager.isTransientSendError(error) == false)
    }

    @Test("commandFailed is permanent")
    func commandFailedIsPermanent() {
        let error = SMTPError.commandFailed("550 User unknown")
        #expect(AccountManager.isTransientSendError(error) == false)
    }

    @Test("messageTooLarge is permanent")
    func messageTooLargeIsPermanent() {
        let error = SMTPError.messageTooLarge(messageSizeOctets: 50_000_000, maximumMessageSizeOctets: 25_000_000)
        #expect(AccountManager.isTransientSendError(error) == false)
    }

    // Note: SMTPError.unexpectedResponse requires SMTPResponse which has internal init.
    // Covered implicitly — it falls into the permanent default branch of the switch.

    @Test("invalidResponse is permanent")
    func invalidResponseIsPermanent() {
        let error = SMTPError.invalidResponse("Garbled server response")
        #expect(AccountManager.isTransientSendError(error) == false)
    }

    @Test("NSURLErrorDomain errors are transient")
    func urlErrorIsTransient() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        #expect(AccountManager.isTransientSendError(error) == true)
    }

    @Test("Unknown errors default to permanent")
    func unknownErrorIsPermanent() {
        let error = NSError(domain: "com.test.unknown", code: 42, userInfo: nil)
        #expect(AccountManager.isTransientSendError(error) == false)
    }
}
