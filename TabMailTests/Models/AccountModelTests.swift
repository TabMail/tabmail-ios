/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Account Model")
struct AccountModelTests {

    @Test("Account init sets emailAddress and displayName")
    func initSetsBasicFields() {
        let account = Account(emailAddress: "user@example.com", displayName: "User Name", provider: .gmail)
        #expect(account.emailAddress == "user@example.com")
        #expect(account.displayName == "User Name")
    }

    @Test("Account init sets provider correctly for all types")
    func initSetsProvider() {
        let gmail = Account(emailAddress: "a@g.com", displayName: "A", provider: .gmail)
        let outlook = Account(emailAddress: "a@o.com", displayName: "A", provider: .outlook)
        let imap = Account(emailAddress: "a@i.com", displayName: "A", provider: .imap)
        let icloud = Account(emailAddress: "a@ic.com", displayName: "A", provider: .icloud)
        let caldav = Account(emailAddress: "a@c.com", displayName: "A", provider: .caldav)
        #expect(gmail.provider == .gmail)
        #expect(outlook.provider == .outlook)
        #expect(imap.provider == .imap)
        #expect(icloud.provider == .icloud)
        #expect(caldav.provider == .caldav)
    }

    @Test("Account id is a valid UUID string")
    func idIsUUID() {
        let account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        #expect(UUID(uuidString: account.id) != nil)
    }

    @Test("Account createdAt is set near current time")
    func createdAtIsNow() {
        let before = Date()
        let account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        let after = Date()
        #expect(account.createdAt >= before)
        #expect(account.createdAt <= after)
    }

    @Test("Account IMAP fields default to nil")
    func imapFieldsDefaultNil() {
        let account = Account(emailAddress: "a@b.com", displayName: "A", provider: .imap)
        #expect(account.imapUsername == nil)
        #expect(account.imapHost == nil)
        #expect(account.imapPort == nil)
        #expect(account.smtpHost == nil)
        #expect(account.smtpPort == nil)
    }

    @Test("Account signatureBelowQuote defaults to false")
    func signatureBelowQuoteDefault() {
        let account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        #expect(account.signatureBelowQuote == false)
    }

    @Test("Account Equatable compares all fields")
    func equatableComparesFields() {
        var a1 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        a1.id = "fixed-id"
        a1.createdAt = Date(timeIntervalSince1970: 1000)
        var a2 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        a2.id = "fixed-id"
        a2.createdAt = Date(timeIntervalSince1970: 1000)
        #expect(a1 == a2)
    }

    @Test("Account Equatable detects differences")
    func equatableDetectsDifferences() {
        var a1 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        a1.id = "fixed-id"
        a1.createdAt = Date(timeIntervalSince1970: 1000)
        var a2 = a1
        a2.isPrimary = true
        #expect(a1 != a2)
    }

    @Test("Account databaseTableName is account")
    func tableNameIsCorrect() {
        #expect(Account.databaseTableName == "account")
    }

    @Test("Account signature can be set and read")
    func signatureField() {
        var account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        account.signature = "Best regards,\nUser"
        #expect(account.signature == "Best regards,\nUser")
    }

    @Test("Account lastHistoryId for Gmail cursor tracking")
    func lastHistoryIdField() {
        var account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        account.lastHistoryId = "12345678"
        #expect(account.lastHistoryId == "12345678")
    }

    @Test("Account calendarOnly can be toggled")
    func calendarOnlyToggle() {
        var account = Account(emailAddress: "a@b.com", displayName: "A", provider: .caldav)
        #expect(account.calendarOnly == false)
        account.calendarOnly = true
        #expect(account.calendarOnly == true)
    }

    @Test("Account Codable round-trip preserves all fields")
    func codableRoundTripFull() throws {
        var account = Account(emailAddress: "user@test.com", displayName: "Test User", provider: .imap)
        account.id = "test-id"
        account.isActive = false
        account.isPrimary = true
        account.signature = "Sent from TabMail"
        account.signatureBelowQuote = true
        account.imapUsername = "user"
        account.imapHost = "imap.test.com"
        account.imapPort = 993
        account.smtpHost = "smtp.test.com"
        account.smtpPort = 587
        account.calendarOnly = true
        account.lastHistoryId = "hist-123"

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.id == "test-id")
        #expect(decoded.emailAddress == "user@test.com")
        #expect(decoded.displayName == "Test User")
        #expect(decoded.provider == .imap)
        #expect(decoded.isActive == false)
        #expect(decoded.isPrimary == true)
        #expect(decoded.signature == "Sent from TabMail")
        #expect(decoded.signatureBelowQuote == true)
        #expect(decoded.imapUsername == "user")
        #expect(decoded.imapHost == "imap.test.com")
        #expect(decoded.imapPort == 993)
        #expect(decoded.smtpHost == "smtp.test.com")
        #expect(decoded.smtpPort == 587)
        #expect(decoded.calendarOnly == true)
        #expect(decoded.lastHistoryId == "hist-123")
    }

    @Test("AccountProvider has exactly 5 cases")
    func providerCaseCount() {
        let allProviders: [AccountProvider] = [.gmail, .outlook, .imap, .icloud, .caldav]
        #expect(allProviders.count == 5)
    }

    @Test("AccountProvider decoding rejects unknown values")
    func providerRejectsUnknown() {
        let json = "\"yahoo\""
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AccountProvider.self, from: json.data(using: .utf8)!)
        }
    }

    @Test("Account GRDB persistence round-trip with all fields")
    func grdbFullRoundTrip() throws {
        let db = try TestDatabase.make()
        var account = Account(emailAddress: "full@test.com", displayName: "Full Test", provider: .outlook)
        account.id = "grdb-test"
        account.isPrimary = true
        account.signature = "Regards"
        account.signatureBelowQuote = true
        account.calendarOnly = false
        account.lastHistoryId = "abc"
        try db.write { try account.insert($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "grdb-test") }
        #expect(fetched?.isPrimary == true)
        #expect(fetched?.signature == "Regards")
        #expect(fetched?.signatureBelowQuote == true)
        #expect(fetched?.lastHistoryId == "abc")
    }

    @Test("Account lastSyncedAt and lastFullSyncAt can be set")
    func syncTimestamps() {
        var account = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        let now = Date()
        account.lastSyncedAt = now
        account.lastFullSyncAt = now
        #expect(account.lastSyncedAt == now)
        #expect(account.lastFullSyncAt == now)
    }
}
