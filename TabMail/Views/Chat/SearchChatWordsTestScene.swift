/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import GRDB
import SwiftUI

/// Disposable fixture for the Search chat-words UI test (`--search-chat-words-ui-test`): one
/// synthetic account with one email, and a root screen that presents the real `SearchView` as a
/// sheet, as the inbox does. The test searches, taps the result (the real `openResult` route into
/// `MessageOpenView` and the chat), types in the chat's reply field, leaves with Back and Search's
/// own Done, and opens the same chat again through Search to read the field (ADR-IOS-117). The
/// scene only seeds data and presents the sheet; every screen after that is the app's own.
struct SearchChatWordsTestScene: View {
    @State private var ready = false
    @State private var status = "Preparing fixture"
    @State private var showsSearch = false
    nonisolated private static let accountID = "search-words-fixture"
    /// The fixture email's subject, which the test searches for.
    nonisolated static let subject = "Search words fixture picnic"

    private static var folder: Folder {
        Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountID)
    }

    var body: some View {
        Group {
            if ready {
                NavigationStack {
                    Button("Show search") { showsSearch = true }
                        .navigationTitle("Search words fixture")
                }
                .sheet(isPresented: $showsSearch) {
                    SearchView(folders: [Self.folder], scopeTitle: "Inbox")
                }
            } else {
                Text(status)
            }
        }
        .task { await seed() }
    }

    private func seed() async {
        do {
            UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
            // An open goes to the chat only for a subscriber (`MessageOpenView`).
            AISubscriptionGate.shared.openGate()
            let accountID = Self.accountID
            let folder = Self.folder
            try await AppDatabase.dbPool.write { db in
                // Each launch owns only this synthetic account's fixture rows, its kept words
                // included, so every run starts with an empty field.
                try MessageHeader.filter(Column("accountId") == accountID).deleteAll(db)
                try ChatFieldWords.deleteAccount(accountID, db: db)
                var account = Account(emailAddress: "me@example.com", displayName: "Search words fixture", provider: .imap)
                account.id = accountID
                try account.save(db)
                try folder.save(db)
                var header = MessageHeader(
                    messageId: "search-words-1", subject: Self.subject, from: "Sender",
                    fromAddress: "sender@example.com", to: "me@example.com",
                    date: Date().addingTimeInterval(-600), snippet: "Bring a blanket",
                    folderId: MessageIdentity.folderId(accountId: accountID, folderPath: "INBOX"),
                    accountId: accountID, folderPath: "INBOX", isInInbox: true)
                header.rfc822MessageId = "<search-words-1@example.com>"
                header.headerComplete = true
                header.bodyComplete = true
                header.isRead = true
                header.summaryBlurb = "Bring a blanket"
                header.summaryTextMessage = "Bring a blanket to the picnic."
                try header.save(db)
            }
            status = "Fixture ready"
            ready = true
        } catch {
            status = "Fixture setup failed"
        }
    }
}
#endif
