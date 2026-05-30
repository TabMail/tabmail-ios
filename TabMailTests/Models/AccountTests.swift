/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Account")
struct AccountTests {

    @Test("AccountProvider raw values")
    func providerRawValues() {
        #expect(AccountProvider.gmail.rawValue == "gmail")
        #expect(AccountProvider.outlook.rawValue == "outlook")
        #expect(AccountProvider.imap.rawValue == "imap")
        #expect(AccountProvider.icloud.rawValue == "icloud")
        #expect(AccountProvider.caldav.rawValue == "caldav")
    }

    @Test("AccountProvider displayName uses brand-correct casing")
    func providerDisplayNames() {
        #expect(AccountProvider.gmail.displayName == "Gmail")
        #expect(AccountProvider.outlook.displayName == "Outlook")
        #expect(AccountProvider.imap.displayName == "IMAP")
        #expect(AccountProvider.icloud.displayName == "iCloud")
        #expect(AccountProvider.caldav.displayName == "CalDAV")
    }

    @Test("Init sets defaults correctly")
    func initDefaults() {
        let account = Account(emailAddress: "test@example.com", displayName: "Test User", provider: .gmail)
        #expect(!account.id.isEmpty)
        #expect(account.emailAddress == "test@example.com")
        #expect(account.displayName == "Test User")
        #expect(account.provider == .gmail)
        #expect(account.isActive == true)
        #expect(account.isPrimary == false)
        #expect(account.signature == nil)
        #expect(account.calendarOnly == false)
        #expect(account.lastHistoryId == nil)
    }

    @Test("IMAP account has host/port fields")
    func imapFields() {
        var account = Account(emailAddress: "test@imap.com", displayName: "IMAP User", provider: .imap)
        account.imapHost = "imap.example.com"
        account.imapPort = 993
        account.smtpHost = "smtp.example.com"
        account.smtpPort = 587
        account.imapUsername = "testuser"
        #expect(account.imapHost == "imap.example.com")
        #expect(account.imapPort == 993)
        #expect(account.smtpHost == "smtp.example.com")
        #expect(account.smtpPort == 587)
        #expect(account.imapUsername == "testuser")
    }

    @Test("Each init generates unique id")
    func uniqueIds() {
        let a1 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        let a2 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        #expect(a1.id != a2.id)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .outlook)
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.emailAddress == account.emailAddress)
        #expect(decoded.provider == account.provider)
        #expect(decoded.id == account.id)
    }
}
