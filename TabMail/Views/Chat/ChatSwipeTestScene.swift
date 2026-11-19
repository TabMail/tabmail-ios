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
/// with its own navigation stack, as search opens chats. With `--chat-swipe-in-split` the list is the
/// content column of a collapsed split view, entered from a sidebar, and opens the chat as the app
/// opens one from a mailbox: the content column's push of `PushedMessageDestination`, through
/// `MessageOpenView`. With `--chat-swipe-tutorial-card` the chat is instead the tutorial's practice
/// chat (Priya's, from the real tutorial seed) in Part 2, so its coach card sits in the header under
/// the subject. "Move the tutorial on" moves the run to Part 3 at once, which takes the card away
/// while the chat stays open: it sits in a strip under the whole navigation stack, outside the
/// chat's region, so it is on screen with the chat and no earlier gesture can reach it.
struct ChatSwipeTestScene: View {
    @State private var ready = false
    @State private var status = "Preparing fixture"
    @State private var armed = false
    @State private var suggestionArmed = false
    @State private var showsSheet = false
    @State private var mailbox: String?
    @State private var pushedId: String?
    /// The tutorial variant's chat: Priya's practice email.
    @State private var practiceId: String?
    private let inSheet = ProcessInfo.processInfo.arguments.contains("--chat-swipe-in-sheet")
    private let inSplit = ProcessInfo.processInfo.arguments.contains("--chat-swipe-in-split")
    /// `--chat-swipe-tall`: the oldest email's text message runs past the screen, so the chat scrolls.
    nonisolated private static let tall = ProcessInfo.processInfo.arguments.contains("--chat-swipe-tall")
    /// `--chat-swipe-unread`: every email is unread, so the chat lands at the Unread line above the
    /// oldest email; with `--chat-swipe-tall` that is far from the bottom.
    nonisolated private static let unread = ProcessInfo.processInfo.arguments.contains("--chat-swipe-unread")
    /// `--chat-swipe-suggestion-on-jump`: the newest email's AI Suggestion lands the moment the
    /// jump button is tapped, while its scroll animates.
    nonisolated private static let suggestionOnJump = ProcessInfo.processInfo.arguments.contains("--chat-swipe-suggestion-on-jump")
    private let tutorialCard = ProcessInfo.processInfo.arguments.contains("--chat-swipe-tutorial-card")
    nonisolated private static let accountID = "chat-swipe-fixture"
    nonisolated private static let count = 4
    /// The email "Remove a bubble" takes out of the chat.
    static let removedIndex = 1
    /// How long after "Remove a bubble" the email leaves: long enough for a test to open the chat
    /// and that bubble's actions first.
    private static let removalDelay: Duration = .seconds(8)
    /// How long after "Arm a late suggestion" the newest email's AI Suggestion lands: long enough
    /// for a test to open the chat and scroll away first.
    private static let suggestionDelay: Duration = .seconds(10)
    /// The late AI Suggestion's text message.
    nonisolated static let lateSuggestion = "Sounds good, see you Tuesday."

    var body: some View {
        Group {
            if ready {
                if inSheet {
                    NavigationStack {
                        Button("Show sheet") { showsSheet = true }
                            .navigationTitle("Fixture root")
                    }
                    .sheet(isPresented: $showsSheet) { NavigationStack { list } }
                } else if inSplit {
                    NavigationSplitView {
                        List(selection: $mailbox) {
                            NavigationLink("Fixture inbox", value: "inbox")
                        }
                        .navigationTitle("Fixture mailboxes")
                    } content: {
                        list
                            .navigationDestination(item: $pushedId) { id in PushedMessageDestination(messageId: id) }
                    } detail: {
                        Text("No message")
                    }
                } else if tutorialCard {
                    // The strip sits below the whole navigation stack, not in its safe area, so
                    // the chat's reply bar (which extends into the bottom safe area) ends above it.
                    VStack(spacing: 0) {
                        NavigationStack { list }
                        Button("Move the tutorial on") {
                            // Part 3 starts in the inbox: Priya's chat holds no card for it,
                            // and the demo stays.
                            TutorialCoordinator.shared.nextLesson()
                        }
                        .padding()
                    }
                } else {
                    NavigationStack { list }
                }
            } else {
                Text(status)
            }
        }
        .task { await seed() }
        .onReceive(NotificationCenter.default.publisher(for: .chatJumpTappedForTesting)) { _ in
            guard Self.suggestionOnJump else { return }
            Task { await Self.writeSuggestion() }
        }
    }

    private var list: some View {
        VStack(spacing: 24) {
            Text("Chat swipe fixture")
            if tutorialCard, let practiceId {
                NavigationLink("Open chat") { ChatThreadView(messageId: practiceId) }
            } else if inSplit {
                Button("Open chat") { pushedId = Self.headerId(Self.count - 1) }
            } else {
                NavigationLink("Open chat") { ChatThreadView(messageId: Self.headerId(Self.count - 1)) }
            }
            if !tutorialCard {
                Button(armed ? "Removal armed" : "Remove a bubble") { arm() }
                Button(suggestionArmed ? "Late suggestion armed" : "Arm a late suggestion") { armSuggestion() }
            }
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

    /// Writes the newest email's AI Suggestion after `suggestionDelay`, as the AI's reply write does,
    /// so the open chat gets a late row height.
    private func armSuggestion() {
        suggestionArmed = true
        Task {
            try? await Task.sleep(for: Self.suggestionDelay)
            await Self.writeSuggestion()
        }
    }

    private static func writeSuggestion() async {
        let id = headerId(count - 1)
        _ = try? await AppDatabase.dbPool.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: id) else { return }
            header.cachedReply = "Hello,\n\n\(lateSuggestion)\n\nThanks."
            header.replyTextMessage = lateSuggestion
            try header.save(db)
        }
        NSLog("[cv9diag] late suggestion written")
        NotificationCenter.default.post(name: .messageDataDidChange, object: id)
    }

    /// The tutorial variant: a real chat-view run of Part 2 on the real demo seed, as
    /// `TutorialChatViewRunTests` starts one.
    private func seedTutorial() async throws {
        UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
        AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
        let coordinator = TutorialCoordinator.shared
        await coordinator.start(.reuseReply, hasTabMailSession: false)
        try await DemoModeService.shared.completeSetup()
        coordinator.seedingFinished()
        guard coordinator.teachesChat, coordinator.step == .replyToPriya else {
            status = "Fixture setup failed"
            return
        }
        practiceId = try await AppDatabase.dbPool.read { db in
            try MessageHeader.filter(Column("accountId") == DemoSeed.demoAccountId
                && Column("messageId") == DemoSeed.TutorialFixture.priyaOffsite).fetchOne(db)?.id
        }
        guard practiceId != nil else {
            status = "Fixture setup failed"
            return
        }
        status = "Fixture ready"
        ready = true
    }

    private func seed() async {
        do {
            if tutorialCard {
                try await seedTutorial()
                return
            }
            UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
            // An open goes to the chat only for a subscriber (`MessageOpenView`); the gate persists
            // across launches, so every mode opens it and runs alike.
            AISubscriptionGate.shared.openGate()
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
                    header.isRead = !Self.unread
                    header.summaryBlurb = "Note \(index)"
                    header.summaryTextMessage = index == 0 && Self.tall
                        ? "Note 0: " + String(repeating: "A long line that fills the screen. ", count: 80)
                        : "Note \(index): a short line."
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
