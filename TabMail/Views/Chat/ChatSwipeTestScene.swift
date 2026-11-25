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
/// chat's region, so it is on screen with the chat and no earlier gesture can reach it. With
/// `--chat-swipe-signed-in` the scene has a TabMail session; with `--chat-swipe-open-panel-under-drag`
/// a strip arms the chat's panel to open under the next drag held on the field.
struct ChatSwipeTestScene: View {
    @State private var ready = false
    @State private var status = "Preparing fixture"
    @State private var armed = false
    @State private var showsSheet = false
    @State private var mailbox: String?
    @State private var pushedId: String?
    /// `--chat-swipe-saved-draft`: what Drafts holds for the fixture, read each time the list shows.
    @State private var draftMarker = ""
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
    /// `--chat-swipe-saved-draft`: the newest email has its AI Suggestion from the start, and a reply
    /// draft is already saved for it under its usual reply key (`Draft.draftKey(replyTo:)`), so the
    /// ghost's card opens next to a saved draft it must leave alone.
    nonisolated private static let savedDraft = ProcessInfo.processInfo.arguments.contains("--chat-swipe-saved-draft")
    /// The saved draft's words.
    nonisolated static let savedDraftBody = "My own words, not sent yet"
    nonisolated private static let accountID = "chat-swipe-fixture"
    nonisolated private static let count = 4
    /// The email "Remove a bubble" takes out of the chat.
    static let removedIndex = 1
    /// How long after "Remove a bubble" the email leaves: long enough for a test to open the chat
    /// and that bubble's actions first, on a simulator loaded by other runs (8 s ran out there).
    private static let removalDelay: Duration = .seconds(15)
    /// `--chat-swipe-late-suggestion`: a strip under the whole navigation stack holds "Release the
    /// AI Suggestion", which writes the newest email's AI Suggestion when the test taps it, so the
    /// test decides that it lands only after its drag or jump has come to rest.
    private let lateSuggestionRelease = ProcessInfo.processInfo.arguments.contains("--chat-swipe-late-suggestion")
    /// `--chat-swipe-writing`: the newest email is classified with no reply yet, so the chat shows
    /// the AI Suggestion's working bubble until "Release the AI Suggestion" stores the reply.
    /// Without it the newest email is filtered, so no working bubble shows.
    nonisolated private static let writing = ProcessInfo.processInfo.arguments.contains("--chat-swipe-writing")
    /// `--chat-swipe-ready`: the newest email's AI Suggestion is already stored as the chat opens.
    nonisolated private static let readyAtOpen = ProcessInfo.processInfo.arguments.contains("--chat-swipe-ready")
    /// The late AI Suggestion's text message.
    nonisolated static let lateSuggestion = "Sounds good, see you Tuesday."
    /// The newest email's full AI Suggestion, as the fixture writes it.
    nonisolated static let fullReply = "Hello,\n\n\(lateSuggestion)\n\nThanks."
    /// What "Rewrite the AI Suggestion" puts in the newest row's reply, unannounced.
    nonisolated static let rewrittenReply = "Hello,\n\nA rewritten reply.\n\nRegards."
    /// `--chat-swipe-signed-in`: the scene runs with a TabMail session, so the open panel shows its
    /// editor (signed out it shows the sign-in bar instead) and the field its signed-in hint.
    private let signedIn = ProcessInfo.processInfo.arguments.contains("--chat-swipe-signed-in")
    /// `--chat-swipe-panel-history`: the newest email's TabMail chat holds a history taller than the
    /// open panel (`panelHistoryCount` messages, each naming its line), so a drag inside it can scroll.
    nonisolated private static let panelHistory = ProcessInfo.processInfo.arguments.contains("--chat-swipe-panel-history")
    nonisolated static let panelHistoryCount = 30
    nonisolated static func panelHistoryLine(_ index: Int) -> String { "History line \(index) of \(panelHistoryCount)" }
    /// `--chat-swipe-open-panel-under-drag`: a strip under the whole navigation stack holds "Open
    /// the panel under the next drag", which arms the panel's expansion to run the moment the next
    /// drag held on the field has swollen it past the open distance (`openPanelUnderTheNextDrag`),
    /// so that drag, still held, is cut off by it.
    private let openPanelUnderDrag = ProcessInfo.processInfo.arguments.contains("--chat-swipe-open-panel-under-drag")

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
                } else if lateSuggestionRelease {
                    // Below the whole stack, like the tutorial strip, so the reply bar ends above it.
                    VStack(spacing: 0) {
                        NavigationStack { list }
                        Button("Release the AI Suggestion") { Task { await Self.writeSuggestion() } }
                            .padding()
                    }
                } else if openPanelUnderDrag {
                    // Below the whole stack, like the other strips, so the reply bar ends above it.
                    VStack(spacing: 0) {
                        NavigationStack { list }
                        Button("Open the panel under the next drag") { Self.openPanelUnderTheNextDrag() }
                            .padding()
                    }
                } else if Self.savedDraft {
                    // Below the whole stack, like the other strips. Rewrites the newest row's reply
                    // with no `.messageDataDidChange`, so the ghost keeps the reply the user taps.
                    VStack(spacing: 0) {
                        NavigationStack { list }
                        Button("Rewrite the AI Suggestion") { Task { await Self.rewriteSuggestionQuietly() } }
                            .padding()
                    }
                } else {
                    NavigationStack { list }
                }
            } else {
                Text(status)
            }
        }
        .environment(\.hasTabMailSession, signedIn)
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
            }
            if Self.savedDraft {
                // Never the draft's words: a test reads that they stay out of the card.
                Text(draftMarker).accessibilityIdentifier("fixture.savedDraft")
            }
        }
        .navigationTitle("Fixture list")
        .onAppear { Task { await readDrafts() } }
    }

    /// "Saved draft kept: yes" while the saved reply draft holds its words and was never saved
    /// over, how many drafts the card saved under keys of their own, and how many of those hold the
    /// full AI Suggestion. Counts only: never any draft's words.
    private func readDrafts() async {
        guard Self.savedDraft else { return }
        let accountID = Self.accountID
        let (kept, separate, holding) = (try? await AppDatabase.dbPool.read { db -> (Bool, Int, Int) in
            let drafts = try Draft.filter(Column("accountId") == accountID).fetchAll(db)
            let kept = drafts.contains {
                !$0.id.hasPrefix(Draft.separateReplyPrefix) && $0.body == Self.savedDraftBody && $0.updatedAt == $0.createdAt
            }
            let own = drafts.filter { $0.id.hasPrefix(Draft.separateReplyPrefix) }
            return (kept, own.count, own.filter { $0.body.contains(Self.fullReply) }.count)
        }) ?? (false, -1, -1)
        draftMarker = "Saved draft kept: \(kept ? "yes" : "no"); separate replies: \(separate); holding the suggestion: \(holding)"
    }

    private static func headerId(_ index: Int) -> String {
        MessageIdentity.headerId(accountId: accountID, folderPath: "INBOX", messageId: "swipe-\(index)")
    }

    /// The newest email's chat gets `panelHistoryCount` messages, the user's and the agent's in
    /// turn, a minute apart, in its in-process session (nothing is stored). The session is marked
    /// active now, as a chat turn marks it, or opening the panel evicts it as idle
    /// (`ChatPillState.evictIdleSessions`).
    private static func seedPanelHistory() async throws {
        let id = headerId(count - 1)
        guard let header = try await AppDatabase.dbPool.read({ try MessageHeader.fetchOne($0, key: id) }) else { return }
        let start = Date().addingTimeInterval(-TimeInterval(panelHistoryCount) * 60)
        let session = ChatPillState.shared.session(for: ChatThreadKey.key(for: header))
        session.chatMessages = (0..<panelHistoryCount).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .agent, content: panelHistoryLine($0),
                        timestamp: start.addingTimeInterval(TimeInterval($0) * 60))
        }
        session.lastChatActivity = Date()
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

    /// Writes the newest email's AI Suggestion as the AI's reply write does, so the open chat gets
    /// a late row height.
    private static func writeSuggestion() async {
        let id = headerId(count - 1)
        _ = try? await AppDatabase.dbPool.write { db -> AIWriteOutcome in
            guard let header = try MessageHeader.fetchOne(db, key: id),
                  let target = try AIWriteTarget.capture(message: header, db: db) else { return .dropped }
            // Through the one central writer (header and cache together), over the value stored.
            let late = ReplyResult(body: fullReply, textMessage: lateSuggestion)
            return try AccountManager.storeSuggestion(late, replacing: header.suggestion, target: target, db: db)
        }
        NSLog("[cv9diag] late suggestion written")
        NotificationCenter.default.post(name: .messageDataDidChange, object: id)
    }

    /// Simulates the panel's expansion that interrupts a held drag: once the next drag held on the
    /// field has swollen it past the open distance (seen by the drag marker's probe, not after a
    /// set time), it posts `.openMessageWithChat`, the notification a tap on the inbox's agent toast
    /// posts, so the chat expands its panel through that path. It is not an agent's answer, which
    /// opens the panel directly (`ChatThreadView.agentAnswered`); either way the panel opening turns
    /// the field's pan off.
    private static func openPanelUnderTheNextDrag() {
        let id = headerId(count - 1)
        ChatFieldDragMarker.Probe.shared.openUnderTheNextDrag {
            NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": id])
        }
    }

    /// Rewrites the newest row's reply with no `.messageDataDidChange`: the open chat is not told,
    /// so its ghost still holds the reply it showed, and a tap must open the card with that one.
    private static func rewriteSuggestionQuietly() async {
        let id = headerId(count - 1)
        _ = try? await AppDatabase.dbPool.write { db -> AIWriteOutcome in
            guard let header = try MessageHeader.fetchOne(db, key: id),
                  let target = try AIWriteTarget.capture(message: header, db: db) else { return .dropped }
            // Through the one central writer, over the value stored: only the reply's body changes.
            let stored = header.suggestion
            let rewritten = ReplyResult(
                body: rewrittenReply, textMessage: stored?.textMessage, changeCommand: stored?.changeCommand)
            return try AccountManager.storeSuggestion(rewritten, replacing: stored, target: target, db: db)
        }
    }

    /// The tutorial variant: a real chat-view run of Part 2 on the real demo seed, as
    /// `TutorialChatViewRunTests` starts one.
    private func seedTutorial() async throws {
        UserDefaults.standard.set(true, forKey: ChatViewConfig.enabledKey)
        // A first-launch tour starts before the AI choice: the fixture clears it (another mode may
        // have recorded one on an earlier launch) and runs that tour, which teaches the chat view.
        AIConsentPolicy.clearChoice(in: AIService.optOutStore)
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
            // An open goes to the chat only for a subscriber with the AI choice made, AI on
            // (`MessageOpenView`); the gate and the choice persist across launches, so every mode
            // sets both and runs alike. Nothing is queued for AI (`resume`).
            AISubscriptionGate.shared.openGate()
            AIService.recordAIChoice(aiEnabled: true, resume: {})
            let accountID = Self.accountID
            let now = Date()
            try await AppDatabase.dbPool.write { db in
                // Each launch owns only this synthetic account's fixture rows, its kept words
                // included, so every run starts with an empty field.
                try MessageHeader.filter(Column("accountId") == accountID).deleteAll(db)
                try ChatFieldWords.deleteAccount(accountID, db: db)
                if Self.savedDraft { try Draft.filter(Column("accountId") == accountID).deleteAll(db) }
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
                    if index == Self.count - 1 {
                        // The AI's state on the newest email, under the shared "AI is working"
                        // rule (`AIWorkingRule`): tagged with no reply yet writes; otherwise it is
                        // filtered (the empty-reply sentinel), so no working bubble shows and a
                        // released suggestion lands with none before it. With a saved draft the
                        // email holds the reply from the start instead, so the ghost shows at once.
                        // Stored through the one rule (`replaceSuggestion`) over the none read.
                        if Self.readyAtOpen {
                            header.actionTag = .reply
                            _ = header.replaceSuggestion(with: ReplyResult(body: Self.fullReply, textMessage: Self.lateSuggestion), ifStill: nil)
                        } else {
                            header.actionTag = Self.writing ? .reply : ActionTag.none
                            if Self.savedDraft {
                                _ = header.replaceSuggestion(with: ReplyResult(body: Self.fullReply, textMessage: Self.lateSuggestion), ifStill: nil)
                            } else if !Self.writing {
                                _ = header.replaceSuggestion(with: .filtered, ifStill: nil)
                            }
                        }
                    }
                    header.summaryBlurb = "Note \(index)"
                    header.summaryTextMessage = index == 0 && Self.tall
                        ? "Note 0: " + String(repeating: "A long line that fills the screen. ", count: 80)
                        : "Note \(index): a short line."
                    try header.save(db)
                    if Self.savedDraft, index == Self.count - 1 {
                        let key = Draft.draftKey(replyTo: "\(accountID):\(header.stableId)", isForward: false, newId: nil)
                        let stamp = now.timeIntervalSince1970
                        try Draft.deleteOne(db, key: key)
                        try Draft(
                            id: key, accountId: accountID,
                            toJSON: "[\"sender\(index)@example.com\"]", ccJSON: "[]", bccJSON: "[]",
                            subject: "Re: Swipe fixture lunch", body: Self.savedDraftBody,
                            replyToId: header.id, isForward: false, editHistoryJSON: nil,
                            createdAt: stamp, updatedAt: stamp,
                            serverDraftId: nil, serverPushStatus: nil,
                            rfc822MessageId: nil, attachmentsDirName: nil).insert(db)
                    }
                }
            }
            if Self.panelHistory { try await Self.seedPanelHistory() }
            await readDrafts()
            status = "Fixture ready"
            ready = true
        } catch {
            status = "Fixture setup failed"
        }
    }
}
#endif
