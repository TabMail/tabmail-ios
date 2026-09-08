/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

/// UI-test hosts for the loader's presentation contract. The injected dependency
/// feeds the real asynchronous classifier; no draft or provider data is mutated.
struct ServerDraftCloseTestScene: View {
    @State private var coverHeader: MessageHeader?
    @State private var pushed = false
    @State private var detailVisible = false
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var mailboxTaps = 0
    private let header = MessageHeader(
        messageId: "1", subject: "Draft fixture", from: "Sender", fromAddress: "sender@example.com",
        to: "recipient@example.com", date: Date(), snippet: "", folderId: "fixture:Drafts",
        accountId: "draft-close-fixture", folderPath: "Drafts", isInInbox: false)

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List {
                Button("Mailbox ready: \(mailboxTaps)") { mailboxTaps += 1 }
                Button("Open cover") { coverHeader = header }
                Button("Open push") { pushed = true }
                Button("Open detail") {
                    detailVisible = true
                    compactColumn = .detail
                }
            }
            .navigationTitle("Draft close test")
            .navigationDestination(isPresented: $pushed) { loader }
        } detail: {
            if detailVisible {
                loader
            } else {
                Text("Choose a draft")
            }
        }
        .fullScreenCover(item: $coverHeader) { _ in loader }
        .background(Color(.systemBackground))
    }

    private var loader: some View {
        ServerDraftComposeLoader(header: header, resolveOpenAuthorityForTesting: {
            if ProcessInfo.processInfo.arguments.contains("--draft-close-failure") {
                throw FixtureReadFailure()
            }
            return nil
        })
    }

    private struct FixtureReadFailure: Error {}
}
#endif
