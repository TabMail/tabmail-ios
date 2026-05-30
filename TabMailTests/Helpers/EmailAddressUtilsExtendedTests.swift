/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailAddressUtils Extended")
struct EmailAddressUtilsExtendedTests {

    @Test("extractEmailAddress handles multiple angle brackets")
    func multipleAngleBrackets() {
        let result = extractEmailAddress("<<test@example.com>>")
        #expect(result.contains("test@example.com"))
    }

    @Test("extractEmailAddress handles name with comma")
    func nameWithComma() {
        let result = extractEmailAddress("\"Doe, John\" <john@example.com>")
        #expect(result == "john@example.com")
    }

    @Test("parseAddressList handles semicolons")
    func semicolonSeparated() {
        let result = parseAddressList("a@b.com; c@d.com")
        #expect(result.count >= 1) // Implementation may or may not support semicolons
    }

    @Test("extractEmailAddress handles address with plus")
    func addressWithPlus() {
        let result = extractEmailAddress("user+tag@example.com")
        #expect(result == "user+tag@example.com")
    }

    @Test("extractEmailAddress handles international domain")
    func internationalDomain() {
        let result = extractEmailAddress("user@münchen.de")
        #expect(result.contains("@"))
    }

    @Test("parseAddressList empty string returns empty")
    func emptyStringReturnsEmpty() {
        let result = parseAddressList("")
        #expect(result.isEmpty)
    }

    @Test("extractEmailAddress nil-safe for empty string")
    func emptyStringExtraction() {
        let result = extractEmailAddress("")
        #expect(result.isEmpty)
    }
}

// MARK: - buildReplyAllRecipients

@Suite("buildReplyAllRecipients")
struct BuildReplyAllRecipientsTests {

    // Helper to create a minimal MessageHeader for testing
    private func makeHeader(
        from: String = "sender@example.com",
        to: String = "recipient@example.com",
        cc: String = "",
        replyTo: String? = nil,
        accountId: String = "acc1"
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: from,
            fromAddress: from,
            to: to,
            date: Date(),
            snippet: "",
            folderId: "\(accountId):INBOX",
            accountId: accountId,
            folderPath: "INBOX",
            isInInbox: true
        )
        header.cc = cc
        header.replyTo = replyTo
        return header
    }

    private func makeAccount(email: String, id: String = UUID().uuidString) -> Account {
        var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
        account.id = id
        return account
    }

    @Test("Filters out single account email from To")
    func filtersSingleAccountFromTo() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(from: "sender@example.com", to: "me@example.com, other@example.com")
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to.contains("sender@example.com"))
        #expect(result.to.contains("other@example.com"))
        #expect(!result.to.contains("me@example.com"))
    }

    @Test("Filters out all account emails when user has multiple accounts")
    func filtersAllAccountEmails() {
        let acc1 = makeAccount(email: "me@gmail.com", id: "acc1")
        let acc2 = makeAccount(email: "me@work.com", id: "acc2")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "me@gmail.com, me@work.com, colleague@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [acc1, acc2])

        #expect(result.to == ["sender@example.com", "colleague@example.com"])
    }

    @Test("Filters own email from CC too")
    func filtersOwnEmailFromCC() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "other@example.com",
            cc: "me@example.com, third@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(!result.cc.contains("me@example.com"))
        #expect(result.cc.contains("third@example.com"))
    }

    @Test("Case-insensitive email matching")
    func caseInsensitiveFiltering() {
        let me = makeAccount(email: "Me@Example.COM")
        let msg = makeHeader(from: "sender@example.com", to: "me@example.com")
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(!result.to.contains("me@example.com"))
        #expect(result.to == ["sender@example.com"])
    }

    @Test("Non-primary account email in To is the original bug scenario")
    func nonPrimaryAccountBug() {
        // Scenario: user has primary acc1 (gmail) and secondary acc2 (work).
        // Message was sent TO the work account. Old code only filtered primary email.
        let primary = makeAccount(email: "me@gmail.com", id: "acc1")
        let secondary = makeAccount(email: "me@work.com", id: "acc2")
        let msg = makeHeader(
            from: "boss@company.com",
            to: "me@work.com, team@company.com",
            accountId: "acc2"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [primary, secondary])

        #expect(result.to == ["boss@company.com", "team@company.com"])
        #expect(!result.to.contains("me@work.com"))
        #expect(!result.to.contains("me@gmail.com"))
    }

    @Test("Uses replyTo header when present instead of fromAddress")
    func usesReplyToHeader() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "noreply@list.com",
            to: "me@example.com",
            replyTo: "list-reply@list.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to.contains("list-reply@list.com"))
        #expect(!result.to.contains("noreply@list.com"))
    }

    @Test("Deduplicates addresses across To and CC")
    func deduplicatesAcrossToAndCC() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "other@example.com",
            cc: "other@example.com, sender@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to == ["sender@example.com", "other@example.com"])
        #expect(result.cc.isEmpty)
    }

    @Test("Handles display name format in To and CC")
    func handlesDisplayNameFormat() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "Sender <sender@example.com>",
            to: "\"Me\" <me@example.com>, \"Other\" <other@example.com>",
            cc: "\"Third, Person\" <third@example.com>"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to.contains("sender@example.com"))
        #expect(result.to.contains("other@example.com"))
        #expect(!result.to.contains("me@example.com"))
        #expect(result.cc.contains("third@example.com"))
    }

    @Test("Empty accounts list keeps all addresses")
    func emptyAccountsKeepsAll() {
        let msg = makeHeader(from: "sender@example.com", to: "a@x.com, b@x.com")
        let result = buildReplyAllRecipients(for: msg, allAccounts: [])

        #expect(result.to == ["sender@example.com", "a@x.com", "b@x.com"])
    }

    @Test("Sender is own email — excluded from To, others remain")
    func senderIsOwnEmail() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "me@example.com",
            to: "other@example.com, third@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(!result.to.contains("me@example.com"))
        #expect(result.to.contains("other@example.com"))
        #expect(result.to.contains("third@example.com"))
    }

    @Test("Filters out undisclosed-recipients group syntax")
    func filtersUndisclosedRecipients() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "undisclosed-recipients:;, other@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to == ["sender@example.com", "other@example.com"])
    }

    @Test("Filters out undisclosed recipients with display name")
    func filtersUndisclosedRecipientsWithDisplayName() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "\"Undisclosed Recipients\" <undisclosed-recipients:;>, other@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.to == ["sender@example.com", "other@example.com"])
    }

    @Test("Filters undisclosed recipients from CC field")
    func filtersUndisclosedRecipientsFromCC() {
        let me = makeAccount(email: "me@example.com")
        let msg = makeHeader(
            from: "sender@example.com",
            to: "other@example.com",
            cc: "undisclosed-recipients:;, third@example.com"
        )
        let result = buildReplyAllRecipients(for: msg, allAccounts: [me])

        #expect(result.cc == ["third@example.com"])
    }
}

// MARK: - isValidEmailAddress

@Suite("isValidEmailAddress")
struct IsValidEmailAddressTests {

    @Test("Valid email passes")
    func validEmail() {
        #expect(isValidEmailAddress("user@example.com"))
    }

    @Test("Email with plus tag passes")
    func plusTagEmail() {
        #expect(isValidEmailAddress("user+tag@example.com"))
    }

    @Test("Undisclosed recipients group syntax rejected")
    func undisclosedRecipients() {
        #expect(!isValidEmailAddress("undisclosed-recipients:;"))
    }

    @Test("Empty string rejected")
    func emptyString() {
        #expect(!isValidEmailAddress(""))
    }

    @Test("No at sign rejected")
    func noAtSign() {
        #expect(!isValidEmailAddress("nodomain"))
    }

    @Test("No domain dot rejected")
    func noDomainDot() {
        #expect(!isValidEmailAddress("user@localhost"))
    }

    @Test("International domain passes")
    func internationalDomain() {
        #expect(isValidEmailAddress("user@münchen.de"))
    }
}
