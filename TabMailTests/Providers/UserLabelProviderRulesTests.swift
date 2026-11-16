/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT: each account kind reaches the label rules of the provider that
// serves its mail, with no connected provider, and those rules are the ones the
// stored labels were written under: an IMAP or iCloud label is the lowercased
// keyword, an Outlook label is the category name as typed, Gmail needs its
// connected provider to create a label, and only Gmail keeps a label catalog in
// the folder list. A rule that changed would make a label created after the
// change miss the labels already stored on the user's messages.

@Suite("User-label rules belong to the account's own provider")
struct UserLabelProviderRulesTests {

    /// The provider type for each account kind: the same types
    /// `AccountManager.connectAccount` creates; CalDAV carries no mail.
    @Test("Each account kind maps to its mail provider type; CalDAV maps to none")
    func everyAccountKindMapsToItsProviderType() {
        let expected: [AccountProvider: ObjectIdentifier?] = [
            .gmail: ObjectIdentifier(GmailProvider.self),
            .outlook: ObjectIdentifier(ExchangeProvider.self),
            .imap: ObjectIdentifier(IMAPProvider.self),
            .icloud: ObjectIdentifier(IMAPProvider.self),
            .caldav: nil,
        ]
        for provider in AccountProvider.allCases {
            let mapped = provider.emailProviderType.map { ObjectIdentifier($0) }
            #expect(mapped == expected[provider] ?? nil, "\(provider) maps to \(provider.emailProviderType.map { String(describing: $0) } ?? "none")")
        }
        #expect(Set(expected.keys) == Set(AccountProvider.allCases), "an account kind has no expectation here")
    }

    @Test("A pushed message's provider name maps to its account kind; any other name to none")
    func pushPayloadNamesMapToAccountKinds() {
        let expected: [String: AccountProvider?] = [
            "gmail": .gmail, "outlook": .outlook, "imap_new_mail": .imap,
            "imap": .imap, "icloud": .icloud, "caldav": .caldav,
            "": nil, "Gmail": nil, "exchange": nil,
        ]
        for (name, kind) in expected {
            #expect(NSEDataBridge.stagedAccountProvider(name) == kind, "\(name) mapped to \(String(describing: NSEDataBridge.stagedAccountProvider(name)))")
        }
    }

    @Test("Creating a label with no connected provider: IMAP and iCloud lowercase, Outlook keeps the name, Gmail fails")
    func createdLabelPerProviderWithNoConnection() async throws {
        for provider in [AccountProvider.imap, .icloud] {
            let label = try await #require(provider.emailProviderType).userLabel(named: "Receipts Q3", connected: nil)
            #expect(label == ProviderUserLabel(providerLabelId: "receipts q3", name: "Receipts Q3", isSystem: false), "\(provider): \(label)")
        }
        let outlook = try await #require(AccountProvider.outlook.emailProviderType).userLabel(named: "Receipts Q3", connected: nil)
        #expect(outlook == ProviderUserLabel(providerLabelId: "Receipts Q3", name: "Receipts Q3", isSystem: false))
        await #expect(throws: ProviderError.self) {
            _ = try await #require(AccountProvider.gmail.emailProviderType).userLabel(named: "Receipts Q3", connected: nil)
        }
    }

    @Test("Only Gmail keeps a label catalog in the folder list; IMAP, iCloud and Outlook have none (nil, never an empty list)")
    func onlyGmailHasACatalog() throws {
        let folders = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 0),
            FolderInfo(name: "Work", path: "Label_100", role: .custom, unreadCount: 0, totalCount: 0),
        ]
        for provider in [AccountProvider.imap, .icloud, .outlook] {
            let catalog = try #require(provider.emailProviderType).userLabelCatalog(from: folders)
            #expect(catalog == nil, "\(provider) returned a catalog \(String(describing: catalog)); its stored labels would be swept")
        }
        let gmail = try #require(AccountProvider.gmail.emailProviderType).userLabelCatalog(from: folders)
        #expect(gmail == [ProviderUserLabel(providerLabelId: "Label_100", name: "Work", isSystem: false)])
    }

    @Test("Pushed labels: IMAP drops excluded keywords and lowercases, Outlook drops tm_* and keeps names")
    func pushedLabelsPerProvider() throws {
        let db = try TestDatabase.make()
        let raw = ["tm_reply", "$Forwarded", "Work", "Receipts"]
        try db.read { db in
            let imap = try IMAPProvider.storedUserLabelIds(fromPushed: raw, accountId: "acc1", db: db)
            #expect(imap == ["work", "receipts"])
            let outlook = try ExchangeProvider.storedUserLabelIds(fromPushed: raw, accountId: "acc1", db: db)
            #expect(outlook == ["$Forwarded", "Work", "Receipts"])
        }
    }
}
