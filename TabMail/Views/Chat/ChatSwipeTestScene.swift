/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import GRDB
import SwiftUI

/// Disposable fixture data for the chat swipe UI tests (`--chat-swipe-ui-test`): one synthetic
/// account with a four-email chat, opened from a plain list screen so a back swipe has somewhere to
/// go. `ChatThreadView` owns every swipe; the scene only seeds data and, when armed, takes one email
/// out of the chat as a sync would. With `--chat-swipe-in-sheet` the list sits in a presented sheet
/// with its own navigation stack, as search opens chats.
struct ChatSwipeTestScene: View {
    @State private var ready = false
    @State private var status = "Preparing fixture"
    @State private var armed = false
    @State private var showsSheet = false
    private let inSheet = ProcessInfo.processInfo.arguments.contains("--chat-swipe-in-sheet")
    nonisolated private static let accountID = "chat-swipe-fixture"
    nonisolated private static let count = 4
    /// The email "Remove a bubble" takes out of the chat.
    static let removedIndex = 1
    /// How long after "Remove a bubble" the email leaves: long enough for a test to open the chat
    /// and that bubble's actions first.
    private static let removalDelay: Duration = .seconds(8)

    var body: some View {
        Group {
            if ready {
                if inSheet {
                    NavigationStack {
                        Button("Show sheet") { showsSheet = true }
                            .navigationTitle("Fixture root")
                    }
                    .sheet(isPresented: $showsSheet) { NavigationStack { list } }
                } else {
                    NavigationStack { list }
                }
            } else {
                Text(status)
            }
        }
        .task { await seed() }
    }

    private var list: some View {
        VStack(spacing: 24) {
            Text("Chat swipe fixture")
            NavigationLink("Open chat") { ChatThreadView(messageId: Self.headerId(Self.count - 1)) }
            Button(armed ? "Removal armed" : "Remove a bubble") { arm() }
        }
        .navigationTitle("Fixture list")
    }

    private static func headerId(_ index: Int) -> String {
        MessageIdentity.headerId(accountId: accountID, folderPath: "INBOX", messageId: "swipe-\(index)")
    }

    private func arm() {
        armed = true
        Task {
            try? await Task.sleep(for: Self.removalDelay)
            let id = Self.headerId(Self.removedIndex)
            _ = try? await AppDatabase.dbPool.write { db in try MessageHeader.deleteOne(db, key: id) }
            // As a sync's merge announces it: the open chat re-reads its emails.
            NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        }
    }

    private func seed() async {
        do {
            UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
            let accountID = Self.accountID
            let now = Date()
            try await AppDatabase.dbPool.write { db in
                // Each launch owns only this synthetic account's fixture rows.
                try MessageHeader.filter(Column("accountId") == accountID).deleteAll(db)
                var account = Account(emailAddress: "me@example.com", displayName: "Chat swipe fixture", provider: .imap)
                account.id = accountID
                try account.save(db)
                let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountID)
                try folder.save(db)
                for index in 0..<Self.count {
                    var header = MessageHeader(
                        messageId: "swipe-\(index)", subject: "Swipe fixture lunch", from: "Sender \(index)",
                        fromAddress: "sender\(index)@example.com", to: "me@example.com",
                        date: now.addingTimeInterval(TimeInterval(index - Self.count) * 600),
                        snippet: "Note \(index)",
                        folderId: MessageIdentity.folderId(accountId: accountID, folderPath: "INBOX"),
                        accountId: accountID, folderPath: "INBOX", isInInbox: true)
                    header.rfc822MessageId = "<swipe-\(index)@example.com>"
                    header.inReplyTo = index == 0 ? nil : "<swipe-\(index - 1)@example.com>"
                    header.headerComplete = true
                    header.bodyComplete = true
                    header.isRead = true
                    header.summaryBlurb = "Note \(index)"
                    header.summaryTextMessage = "Note \(index): a short line."
                    try header.save(db)
                }
            }
            status = "Fixture ready"
            ready = true
        } catch {
            status = "Fixture setup failed"
        }
    }
}
#endif
