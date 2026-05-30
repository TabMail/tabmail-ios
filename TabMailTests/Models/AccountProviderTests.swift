/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AccountProvider")
struct AccountProviderTests {

    @Test("All provider raw values")
    func providerRawValues() {
        #expect(AccountProvider.gmail.rawValue == "gmail")
        #expect(AccountProvider.outlook.rawValue == "outlook")
        #expect(AccountProvider.imap.rawValue == "imap")
        #expect(AccountProvider.icloud.rawValue == "icloud")
        #expect(AccountProvider.caldav.rawValue == "caldav")
    }

    @Test("AccountProvider Codable round-trip")
    func codableRoundTrip() throws {
        let providers: [AccountProvider] = [.gmail, .outlook, .imap, .icloud, .caldav]
        for provider in providers {
            let data = try JSONEncoder().encode(provider)
            let decoded = try JSONDecoder().decode(AccountProvider.self, from: data)
            #expect(decoded == provider)
        }
    }

    @Test("AccountProvider decodes from string")
    func decodesFromString() throws {
        let json = "\"gmail\""
        let provider = try JSONDecoder().decode(AccountProvider.self, from: json.data(using: .utf8)!)
        #expect(provider == .gmail)
    }
}

@Suite("Account Extended")
struct AccountExtendedTests {

    @Test("Account default values")
    func defaultValues() {
        let account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
        #expect(account.isActive == true)
        #expect(account.isPrimary == false)
        #expect(account.signature == nil)
        #expect(account.signatureBelowQuote == false)
        #expect(account.lastSyncedAt == nil)
        #expect(account.lastFullSyncAt == nil)
        #expect(account.calendarOnly == false)
        #expect(account.lastHistoryId == nil)
    }

    @Test("Account IMAP fields")
    func imapFields() {
        var account = Account(emailAddress: "test@imap.com", displayName: "IMAP User", provider: .imap)
        account.imapUsername = "user"
        account.imapHost = "imap.example.com"
        account.imapPort = 993
        account.smtpHost = "smtp.example.com"
        account.smtpPort = 587
        #expect(account.imapUsername == "user")
        #expect(account.imapHost == "imap.example.com")
        #expect(account.imapPort == 993)
        #expect(account.smtpHost == "smtp.example.com")
        #expect(account.smtpPort == 587)
    }

    @Test("Account unique id generation")
    func uniqueIdGeneration() {
        let a1 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        let a2 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail)
        #expect(a1.id != a2.id) // UUID-based
    }

    @Test("Account GRDB round-trip")
    func grdbRoundTrip() throws {
        let db = try TestDatabase.make()
        var account = Account(emailAddress: "user@example.com", displayName: "User", provider: .outlook)
        account.id = "test-acc"
        account.signature = "Sent from TabMail"
        account.signatureBelowQuote = true
        account.calendarOnly = true
        try db.write { try account.insert($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "test-acc") }
        #expect(fetched?.emailAddress == "user@example.com")
        #expect(fetched?.provider == .outlook)
        #expect(fetched?.signature == "Sent from TabMail")
        #expect(fetched?.signatureBelowQuote == true)
        #expect(fetched?.calendarOnly == true)
    }

    @Test("Account calendarOnly flag persists")
    func calendarOnlyPersists() throws {
        let db = try TestDatabase.make()
        var account = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .caldav)
        account.id = "cal-acc"
        account.calendarOnly = true
        try db.write { try account.insert($0) }

        let fetched = try db.read { try Account.fetchOne($0, key: "cal-acc") }
        #expect(fetched?.calendarOnly == true)
    }
}
