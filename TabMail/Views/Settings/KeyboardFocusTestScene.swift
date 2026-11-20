/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import GRDB
import SwiftUI

/// Fixture for the keyboard focus UI tests (`--keyboard-focus-ui-test`). The window's
/// keyboard-dismiss tap runs alongside every recognizer (`KeyboardDismissView`), so each control
/// whose action focuses a text field is hosted here, under `dismissKeyboardOnTap`, for a test that
/// taps it for real and checks the field ends with the keyboard. One control per launch argument:
/// - none of the below: a reply template's plus button (`TemplateDetailView`);
/// - `--keyboard-focus-chip`: a rejected recipient chip in a recipient field (`RecipientTokenField`);
/// - `--keyboard-focus-bullet`: a bullet list's Add (`BulletListEditor`);
/// - `--keyboard-focus-search`: a button presenting search in a sheet, as the inbox does (`SearchView`);
/// - `--keyboard-focus-fork`: the inbox chat with one past session, for "Fork and re-send";
/// - `--keyboard-focus-caret`: a single-line and a multi-line field, for a tap inside a field that
///   already has the keyboard (the tap lands on the field's internal subviews).
/// Each screen also has an "Other field" that can hold the keyboard first.
struct KeyboardFocusTestScene: View {
    static let templateId = "keyboard-focus-fixture-template"
    static let rejectedRecipient = "notanaddress"
    static let forkSessionId = "keyboard-focus-fixture-session"
    static let forkUserText = "Keyboard focus fixture question"
    /// The multi-line field's height in lines, so it is backed by a text view with room to tap in.
    static let multiLineLines = 3...6

    private enum Mode {
        case template, chip, bullet, search, fork, caret
    }

    private let mode: Mode = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--keyboard-focus-chip") { return .chip }
        if arguments.contains("--keyboard-focus-bullet") { return .bullet }
        if arguments.contains("--keyboard-focus-search") { return .search }
        if arguments.contains("--keyboard-focus-fork") { return .fork }
        if arguments.contains("--keyboard-focus-caret") { return .caret }
        return .template
    }()

    @State private var ready = false
    @State private var other = ""
    @State private var multiLine = ""
    @State private var recipients = ComposeDraftGuards.Recipients()
        .filling(to: RecipientEntry([KeyboardFocusTestScene.rejectedRecipient]))
    @State private var showCc = false
    @State private var revealedChipKey: String?
    @State private var showSearch = false
    @State private var chatExpanded = false

    var body: some View {
        Group {
            if !ready {
                Text("Preparing fixture")
            } else {
                switch mode {
                case .template:
                    NavigationStack { TemplateDetailView(templateId: Self.templateId) }
                case .chip:
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Other field", text: $other)
                        RecipientTokenField(
                            role: .to, recipients: $recipients, showCc: $showCc, searchResults: [],
                            onFocus: {}, revealedChipKey: $revealedChipKey)
                        Spacer()
                    }
                    .padding()
                    .dismissKeyboardOnTap()
                case .bullet:
                    Form {
                        Section { TextField("Other field", text: $other) }
                        Section { BulletListEditor(store: PromptStore.shared, section: .replyRules) }
                    }
                    .dismissKeyboardOnTap()
                case .search:
                    VStack(spacing: 16) {
                        TextField("Other field", text: $other)
                        Button("Open search") { showSearch = true }
                        Spacer()
                    }
                    .padding()
                    .sheet(isPresented: $showSearch) {
                        SearchView(folders: [], scopeTitle: "Inbox")
                    }
                    .dismissKeyboardOnTap()
                case .fork:
                    VStack {
                        TextField("Other field", text: $other)
                        Spacer()
                        DynamicIslandChat(isExpanded: $chatExpanded)
                    }
                    .padding()
                    .environment(\.hasTabMailSession, true)
                    .dismissKeyboardOnTap()
                case .caret:
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Other field", text: $other)
                        TextField("Multi-line field", text: $multiLine, axis: .vertical)
                            .lineLimit(Self.multiLineLines)
                        Spacer()
                    }
                    .padding()
                    .dismissKeyboardOnTap()
                }
            }
        }
        .task {
            switch mode {
            case .template:
                let store = PromptStore.shared
                if !store.templates.contains(where: { $0.id == Self.templateId && !$0.deleted }) {
                    store.addTemplate(ReplyTemplate(id: Self.templateId, name: "Keyboard focus fixture"))
                }
            case .fork:
                try? await Self.seedPastSession()
                AISubscriptionGate.shared.openGate()
            case .chip, .bullet, .search, .caret:
                break
            }
            ready = true
        }
    }

    /// One past inbox chat session: a question and its answer.
    private static func seedPastSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        try await AppDatabase.dbPool.write { db in
            try ChatTurn.filter(Column("sessionId") == forkSessionId).deleteAll(db)
            try ChatTurn(id: "\(forkSessionId)-user", timestamp: now - 60_000, role: "user", content: "chat_converse",
                         userMessage: forkUserText, type: "normal", chars: forkUserText.count, renderedContent: nil,
                         sessionId: forkSessionId, remindersSnapshot: nil, emailContextJSON: nil,
                         thinkingContent: nil).insert(db)
            let answer = "Keyboard focus fixture answer"
            try ChatTurn(id: "\(forkSessionId)-agent", timestamp: now - 59_000, role: "assistant", content: answer,
                         userMessage: nil, type: "normal", chars: answer.count, renderedContent: nil,
                         sessionId: forkSessionId, remindersSnapshot: nil, emailContextJSON: nil,
                         thinkingContent: nil).insert(db)
        }
    }
}
#endif
