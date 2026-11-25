/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Speech
import SwiftUI
import TipKit

/// Expandable chat pill. Collapsed: small floating capsule.
/// Expanded: morphs into a chat window growing upward from the pill.
/// Tap outside to dismiss (handled by parent via binding).
///
/// When `composeContext` is provided, operates in **inline edit mode**:
/// user instructions edit the compose draft instead of triggering agent chat.
/// Edit chat history is maintained for continuous editing across turns.
struct DynamicIslandChat: View {
    let message: MessageHeader?
    let draftSubject: String?
    let draftBody: String?
    /// The AI Suggestion shown as the draft, as one value; nil when the draft is not it. Its text
    /// version and change command are recorded with each edit, so a resend or rewind puts them back.
    let draftSuggestion: ReplyResult?
    let composeContext: ComposeEditContext?
    /// A compose edit request's own context, read after admission through the identity-checked
    /// body read (`ComposeEditContext.relatedBodyText`); nil refuses the request. Absent: the
    /// request uses `composeContext`.
    let composeEditContext: (@MainActor () async -> ComposeEditContext?)?
    let draftId: String?
    let draftReplyToId: String?  // MessageHeader.id of the email being replied to (for draft eviction)
    /// The compose's reply-all kind (#915), stored on the row the agent's first
    /// autosave creates, like `draftReplyToId`, so a draft reopened after the app
    /// ends still sends as reply-all.
    let draftIsReplyAll: Bool
    /// T5.8 — the reply target's PROVIDER id (`MessageHeader.messageId`) and observed
    /// UIDVALIDITY, captured from the SAME header `draftReplyToId` came from. Stamped
    /// onto the `Draft` row this view creates so the durable address survives the
    /// re-keying that makes `draftReplyToId` untrustworthy.
    let draftReplyToProviderMessageId: String?
    let draftReplyToUidValidity: Int?
    let composeGenerationCursor: ComposeGenerationCursor?
    let composeAgentSendFence: ComposeAgentSendFence?
    /// Live attachment state and the original-forward carry boundary owned by
    /// ComposeView. Autosave waits, then copy-on-write persists this exact set.
    let composeAttachments: Binding<[DraftAttachment]>?
    /// The To, Cc and Bcc the compose shows now, as a saved draft stores them
    /// (`ComposeDraftGuards.committedRecipients`). Autosave reads it when it
    /// writes, so the row names every recipient, the agent's edits included.
    let composeRecipients: (() -> (to: [String], cc: [String], bcc: [String]))?
    let composeAttachmentCarryGate: ComposeAttachmentCarryGate?
    let composeMutationAllowed: Bool
    /// Skip writing LLM results to the `Draft` table — caller persists elsewhere.
    let skipDraftAutoSave: Bool
    @Binding var isExpanded: Bool
    @Binding var isInputFocused: Bool
    @Binding var isWorking: Bool
    /// Applies an edit's result, or a resend's or rewind's restore, to the draft; awaited under the
    /// compose agent fence, so the draft and the suggestion's write are settled before the next step.
    var onDraftUpdate: ((String?, String?, RecipientDelta?, RecipientDelta?, RecipientDelta?, String?, String?) async -> Void)?
    var onAgentReply: ((String) -> Void)?
    /// The chat view's reply field (`ChatReplyField`): collapsed, this pill is [mic] [field] [Send]
    /// on the thread's newest email instead of the Chat capsule.
    let replyField: ChatReplyField?
    /// The user's own words went from the field to the agent.
    var onFieldSend: ((String) -> Void)?
    /// The host presents the agent's compose cards that this pill's chat asked for (ADR-IOS-053
    /// Phase 2): the pill takes them from the router while it is on screen and hands each one
    /// here. Nil: the host presents none, and this pill's turns can open no compose card.
    var onAgentCompose: ((AgentToolRouter.ComposeRequest) -> Void)?
    /// The account a new email this pill's turns ask for is sent from: the host's opened email's
    /// account, bound to each turn as it starts (`ComposeOrigin.fromAccountId`). Nil in the inbox.
    let composeFromAccountId: String?
    /// The host's own sheet or cover is up over the pill: it takes no compose card until that
    /// closes, so a card never opens under it.
    let composeHostCovered: Bool
    /// Whether the host is on screen, as the host's own navigation state says. The inbox supplies
    /// it: in the collapsed split view its page gets a disappear right after it appears while it
    /// stays visible, and no disappear when an email is pushed over it (ADR-IOS-054), so its
    /// appearance callbacks cannot say whether it shows. Nil: the pill's own appearance says
    /// (`composeHostAppeared`), as for a pushed screen (the chat view, the email screen).
    let composeHostShown: Bool?
    /// The pill has appeared and not disappeared since.
    @State private var composeHostAppeared = false
    @Environment(\.hasTabMailSession) var hasTabMailSession
    /// Reply field: the words sent to the agent, shown pulsing while it works.
    @State var fieldSentText: String?
    /// The input's words and the reply field's state. `ChatFieldFill.apply` is the only way the words
    /// change; no AI text is ever written into them (`ChatFieldFill`). A pill about an email changes
    /// its chat's one fill, which every pill on the chat shares (`ChatFieldWords`, ADR-IOS-117); the
    /// inbox's chat and a compose's pill have their own.
    private var fieldFill: ChatFieldWords.Field { ChatFieldWords.Field(key: wordsKey, own: $ownFill) }
    @State private var ownFill = ChatFieldFill()
    /// The user's own words in the input (`ChatFieldFill.words`), read-only here.
    var inputText: String { fieldFill.words }
    /// Where the field's unsent words are kept (`ChatFieldWords`, ADR-IOS-117): the thread chat key
    /// of the pill's email. Nil for the inbox's chat and a compose's pill, which keep none.
    private var wordsKey: String? {
        guard composeContext == nil, let message else { return nil }
        return ChatFieldWords.key(for: message)
    }
    @State var fieldPulse = false
    /// A new email's chat has put its draft's words in the field (`ChatNewEmailField.startWords`).
    @State private var newEmailStarted = false
    @State private var inputSelection: TextSelection?
    @State private var dictation = DictationController()
    /// Dictation for a user opted out of AI: Apple's recognition on this iPhone only (`PillDictationMode`).
    @State private var speech = OnDeviceSpeechRecognizer()
    /// The speech and microphone permissions, read again when the app becomes active (the user may
    /// have changed them in Settings, or answered the system prompt) and when a start begins or ends.
    @State private var speechPermission = SFSpeechRecognizer.authorizationStatus()
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @Environment(\.scenePhase) private var scenePhase
    private let networkMonitor = NetworkMonitor.shared
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false
    @State private var autoStartTask: Task<Void, Never>?
    /// Send was tapped while dictating: the dictation's text is sent as soon as it lands.
    @State private var sendWhenDictated = false
    @State var workingStatus = ""
    @State private var statusQueue: [String] = []
    @State private var statusTickTask: Task<Void, Never>?
    @State private var lastStatusChangeTime: Date = .distantPast
    @State private var isThrottled = false
    @State private var contextEmailNumericId: Int?
    @State private var expandedReminderHash: String?
    @State private var hiddenReminderHashes: Set<String> = []
    /// Active chat task lives on ChatPillState.Session (survives view recreation).
    /// Forwarding computed property keeps existing code unchanged.
    private var activeChatTask: Task<Void, Never>? {
        get { session.activeChatTask }
        nonmutating set { session.activeChatTask = newValue }
    }
    @State private var agentToast: String?
    @State private var agentToastDismiss: Task<Void, Never>?
    /// Which text field has the keyboard: the chat's reply field, or the open panel's input. Each is
    /// its own text field, and one value each lets the keyboard move from the field to the panel's
    /// input as the panel opens (`InputFocus`).
    @FocusState private var focusedInput: InputFocus?
    /// Whether a text field has the keyboard; set false, neither has it. Set true, the panel's input
    /// takes it: only the open panel sets it so (a forked chat's words, put in its input).
    private var isTextFieldFocused: Bool {
        get { focusedInput != nil }
        nonmutating set { focusedInput = newValue ? .panel : nil }
    }
    @AppStorage(ChatPillState.autoDictationKey) private var autoDictation = false
    @AppStorage(ChatPillState.dictationPromptShownKey) private var dictationPromptShown = false
    @State private var showDictationPrompt = false

    private var isComposeMode: Bool { composeContext != nil }
    /// The inbox's own chat: not about a message, not editing a draft, not a new email's chat.
    private var isInboxChat: Bool { composeContext == nil && message == nil && replyField?.newEmail == nil }
    private var isBackfillInProgress: Bool {
        AccountManagerState.shared.backfillProgressByAccount.values.contains { !$0.isFullyComplete }
    }

    // Session state lives in ChatPillState (survives SwiftUI view recreation).
    // Forwarding computed properties keep existing code unchanged.
    /// About an email: its thread's chat (ADR-IOS-114), at the current thread key of the email the
    /// pill is given (the chat view's newest email, the email screen's open one), where a send writes.
    private var sessionKey: String {
        if composeContext != nil, let cursor = composeGenerationCursor {
            return ActiveAgentTracker.composeSessionKey(
                draftId: draftId ?? "default", epoch: cursor.newEpoch)
        }
        if let message { return ChatThreadKey.key(for: message) }
        if let newEmail = replyField?.newEmail { return newEmail.sessionKey }
        return "inbox"
    }
    /// The keys of the thread's chat (`ThreadChatReader.keys`), own key first.
    @State private var threadKeys: [String] = []
    /// The keys this pill's chat reads: about an email, the thread's; else its own session.
    private var chatKeys: [String] {
        guard message != nil else { return [sessionKey] }
        return threadKeys.first == sessionKey ? threadKeys : [sessionKey] + threadKeys.filter { $0 != sessionKey }
    }
    /// The kind of screen this pill's host is, for the compose cards its chat asks for
    /// (ADR-IOS-053 Phase 2). Nil when the host presents none (the compose editor's chat, a host
    /// without `onAgentCompose`).
    private var composeScreen: ComposeOrigin.Screen? {
        guard onAgentCompose != nil, composeContext == nil else { return nil }
        if replyField != nil { return .chat }
        return message != nil ? .email : .inbox
    }
    /// Where a compose card a turn asks for opens, and the account a new email it asks for is
    /// sent from, read as the turn starts. A turn carrying the reply field's send belongs to the
    /// chat view, where the field and the choice it carries live, even when it is retried from
    /// another screen of the thread. A resume reuses the origin its turn started with
    /// (`PendingResume.origin`).
    private func composeOrigin(sessionKey: String, fieldReply: ChatFieldReply?) -> ComposeOrigin? {
        guard let screen = composeScreen else { return nil }
        return ComposeOrigin(sessionKey: sessionKey, screen: fieldReply != nil ? .chat : screen,
                             fromAccountId: composeFromAccountId)
    }
    /// What the pill takes its compose requests on: the router's offer, and the screen it stands
    /// for while it is on screen and uncovered (nil off screen, under its host's own sheet or
    /// cover, or when its host presents none).
    private struct ComposeTakeWatch: Equatable {
        let offer: Int
        let host: AgentToolRouter.ComposeHost?
    }
    private var composeTakeWatch: ComposeTakeWatch {
        let host = (composeHostShown ?? composeHostAppeared) && !composeHostCovered
            ? composeScreen.map { AgentToolRouter.ComposeHost(screen: $0, sessionKeys: chatKeys) } : nil
        return ComposeTakeWatch(offer: AgentToolRouter.shared.composeOffer, host: host)
    }
    /// Takes the oldest compose request this screen's chat asked for and hands it to the host.
    private func takeAgentCompose(for host: AgentToolRouter.ComposeHost?) {
        guard let host, let onAgentCompose,
              let request = AgentToolRouter.shared.takeCompose(for: host) else { return }
        onAgentCompose(request)
    }
    /// What the chat shows: about an email, the whole thread's chat (`ThreadChatReader`).
    private var shownMessages: [ChatMessage] {
        message != nil ? ThreadChatReader.messages(keys: chatKeys) : chatMessages
    }
    private var session: ChatPillState.Session { ChatPillState.shared.session(for: sessionKey) }
    private var chatMessages: [ChatMessage] {
        get { session.chatMessages }
        nonmutating set { session.chatMessages = newValue }
    }
    private var lastChatActivity: Date? {
        get { session.lastChatActivity }
        nonmutating set { session.lastChatActivity = newValue }
    }
    private var lastFailedSend: ChatPillState.Session.FailedSend? {
        get { session.lastFailedSend }
        nonmutating set { session.lastFailedSend = newValue }
    }
    /// Saved checkpoint for a turn cut off in transit. Drives the "Connection
    /// lost. Tap to retry." affordance and the field's Retry (`chatRetry`): on an
    /// empty field, or in Send's place while the field still holds the unedited
    /// sent words of this same request (its `fieldWordsKey` is the field's
    /// `wordsKey`). Separate from `lastFailedSend`.
    private var pendingResume: ChatPillState.Session.PendingResume? {
        get { session.pendingResume }
        nonmutating set { session.pendingResume = newValue }
    }
    private var activeReminders: [Reminder] {
        get { session.activeReminders }
        nonmutating set { session.activeReminders = newValue }
    }
    private var nextReminders: [Reminder]? {
        get { session.nextReminders }
        nonmutating set { session.nextReminders = newValue }
    }
    /// Whether activeReminders (Buffer 1) is currently being displayed to the user.
    /// When false, Buffer 2 updates propagate immediately to Buffer 1.
    private var isActiveRemindersShown: Bool {
        guard isExpanded else { return false }
        // Non-tabview mode: Buffer 1 is shown when no session snapshot exists
        if loadedSessions.isEmpty {
            return currentSessionId == nil || sessionReminderSnapshots[currentSessionId ?? ""] == nil
        }
        guard activeSessionIndex < loadedSessions.count else { return false }
        let pageId = loadedSessions[activeSessionIndex].id
        // __new__ page always shows Buffer 1
        if pageId == "__new__" { return true }
        // Live session page: Buffer 1 shown only if no snapshot yet (before first message)
        if pageId == currentSessionId {
            return sessionReminderSnapshots[pageId]?.isEmpty ?? true
        }
        return false
    }
    private var sessionReminderSnapshots: [String: [Reminder]] {
        get { session.sessionReminderSnapshots }
        nonmutating set { session.sessionReminderSnapshots = newValue }
    }
    private var sessionEmailContexts: [String: EmailContextSnapshot] {
        get { session.sessionEmailContexts }
        nonmutating set { session.sessionEmailContexts = newValue }
    }
    private var editHistory: [InlineEditTurn] {
        get { session.editHistory }
        nonmutating set { session.editHistory = newValue }
    }
    private var sessionTurns: [ChatTurn] {
        get { session.sessionTurns }
        nonmutating set { session.sessionTurns = newValue }
    }
    private var loadedSessions: [ChatStore.ChatSession] {
        get { session.loadedSessions }
        nonmutating set { session.loadedSessions = newValue }
    }
    private var activeSessionIndex: Int {
        get { session.activeSessionIndex }
        nonmutating set { session.activeSessionIndex = newValue }
    }
    private var currentSessionId: String? {
        get { session.currentSessionId }
        nonmutating set { session.currentSessionId = newValue }
    }
    private var hasLoadedHistory: Bool {
        get { session.hasLoadedHistory }
        nonmutating set { session.hasLoadedHistory = newValue }
    }
    private var cachedSessionMessages: [String: [ChatMessage]] {
        get { session.cachedSessionMessages }
        nonmutating set { session.cachedSessionMessages = newValue }
    }

    /// Whether swipeable session history is available (inbox context, >1 session loaded).
    private var hasSessionHistory: Bool {
        isInboxChat && loadedSessions.count > 1
    }

    /// Whether the active page is the live (current/newest) session or the "new session" page.
    /// True for __new__ placeholder (will create new session on send).
    /// False only when user is on a past session page (triggers adoption on send).
    private var isOnLiveSession: Bool {
        if loadedSessions.isEmpty { return true }
        guard activeSessionIndex < loadedSessions.count else { return true }
        let currentPageId = loadedSessions[activeSessionIndex].id
        if currentPageId == "__new__" { return true }
        if let sid = currentSessionId, currentPageId == sid { return true }
        return false
    }

    init(
        message: MessageHeader? = nil,
        draftSubject: String? = nil,
        draftBody: String? = nil,
        draftSuggestion: ReplyResult? = nil,
        composeContext: ComposeEditContext? = nil,
        composeEditContext: (@MainActor () async -> ComposeEditContext?)? = nil,
        draftId: String? = nil,
        draftReplyToId: String? = nil,
        draftIsReplyAll: Bool = false,
        draftReplyToProviderMessageId: String? = nil,
        draftReplyToUidValidity: Int? = nil,
        composeGenerationCursor: ComposeGenerationCursor? = nil,
        composeAgentSendFence: ComposeAgentSendFence? = nil,
        composeAttachments: Binding<[DraftAttachment]>? = nil,
        composeRecipients: (() -> (to: [String], cc: [String], bcc: [String]))? = nil,
        composeAttachmentCarryGate: ComposeAttachmentCarryGate? = nil,
        composeMutationAllowed: Bool = true,
        skipDraftAutoSave: Bool = false,
        isExpanded: Binding<Bool>,
        isInputFocused: Binding<Bool> = .constant(false),
        isWorking: Binding<Bool> = .constant(false),
        onDraftUpdate: ((String?, String?, RecipientDelta?, RecipientDelta?, RecipientDelta?, String?, String?) async -> Void)? = nil,
        onAgentReply: ((String) -> Void)? = nil,
        replyField: ChatReplyField? = nil,
        onFieldSend: ((String) -> Void)? = nil,
        onAgentCompose: ((AgentToolRouter.ComposeRequest) -> Void)? = nil,
        composeFromAccountId: String? = nil,
        composeHostCovered: Bool = false,
        composeHostShown: Bool? = nil
    ) {
        self.message = message
        self.draftSubject = draftSubject
        self.draftBody = draftBody
        self.draftSuggestion = draftSuggestion
        self.composeContext = composeContext
        self.composeEditContext = composeEditContext
        self.draftId = draftId
        self.draftReplyToId = draftReplyToId
        self.draftIsReplyAll = draftIsReplyAll
        self.draftReplyToProviderMessageId = draftReplyToProviderMessageId
        self.draftReplyToUidValidity = draftReplyToUidValidity
        self.composeGenerationCursor = composeGenerationCursor
        self.composeAgentSendFence = composeAgentSendFence
        self.composeAttachments = composeAttachments
        self.composeRecipients = composeRecipients
        self.composeAttachmentCarryGate = composeAttachmentCarryGate
        self.composeMutationAllowed = composeMutationAllowed
        self.skipDraftAutoSave = skipDraftAutoSave
        self._isExpanded = isExpanded
        self._isInputFocused = isInputFocused
        self._isWorking = isWorking
        self.onDraftUpdate = onDraftUpdate
        self.onAgentReply = onAgentReply
        self.replyField = replyField
        self.onFieldSend = onFieldSend
        self.onAgentCompose = onAgentCompose
        self.composeFromAccountId = composeFromAccountId
        self.composeHostCovered = composeHostCovered
        self.composeHostShown = composeHostShown
    }

    /// Max expanded height as fraction of screen height.
    /// Compose: 60%, message detail: 80% (no tab bar → match inbox visual height), inbox: 92%.
    private var expandedHeightFraction: CGFloat {
        if isComposeMode { return 0.60 }
        if message != nil { return 0.80 }
        return 0.92
    }

    private let expandSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ZStack {
                    // Center: title + session hint
                    Text(isComposeMode ? "Edit Draft" : "Agent Chat")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    HStack {
                        // Left: Magic wand icon (glows when AI is working)
                        ChatPillWandIcon(isWorking: isWorking || ActiveAgentTracker.shared.anyWorking, size: 22)

                        Spacer()

                        // Right: Close button
                        Button {
                            withAnimation(expandSpring) { isExpanded = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.gray)
                                .frame(width: 32, height: 32)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .overlay {
                            // Guided tutorial: the open chat covers the card, whose
                            // button is the next tap.
                            // In the chat view, the chat's own sheet (part 2's template).
                            if (isInboxChat || replyField != nil) && TutorialCoordinator.shared.highlightsChatClose {
                                TutorialPulseRing(shape: Circle(), lineWidth: 2, outset: 3)
                            }
                        }
                        .accessibilityIdentifier("chatClose")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(expandSpring) { isExpanded = false }
                }
                .modifier(ChatPillCollapseTipModifier(isComposeMode: isComposeMode, hasMessage: message != nil))

                if let message {
                    HStack {
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.subject)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(message.from)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Palette.boxBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // One element for VoiceOver: the email the chat is about.
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chatEmailCard")
                    .padding(.horizontal, 14)
                } else if let draftSubject, !draftSubject.isEmpty {
                    HStack {
                        Image(systemName: "pencil.and.outline")
                            .foregroundStyle(.secondary)
                        Text(draftSubject)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(10)
                    .background(Palette.boxBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 14)
                }

                chatMessagesView
                    .transition(.opacity)
                    .layoutPriority(0)
                Text("AI responses may contain errors")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                Divider()
                if !hasTabMailSession {
                    signInBar
                        .layoutPriority(1)
                } else if TutorialCoordinator.shared.isRunning {
                    // Scripted: the input is filled in and read-only.
                    TutorialChatInputBar(
                        prompt: tutorialPromptText,
                        isWorking: isWorking,
                        send: sendTutorialInput)
                    .layoutPriority(1)
                } else if !AISubscriptionGate.shared.isActive {
                    subscribeBar
                        .layoutPriority(1)
                } else {
                    expandedInputBar
                        .layoutPriority(1)
                }
            } else if let replyField {
                replyFieldBar(replyField)
            } else {
                collapsedPill
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(
            cornerRadius: isExpanded ? 24 : (replyField != nil ? ChatViewLayout.fieldCornerRadius : 100)))
        .overlay {
            // Guided tutorial: the step's next move is opening this chat.
            if !isExpanded
                && (tutorialPromptText != nil || (isInboxChat && TutorialCoordinator.shared.highlightsEmailReference)) {
                TutorialPulseRing(shape: Capsule())
                    .accessibilityIdentifier("tutorial-pill-highlight")
            }
        }
        .frame(
            maxWidth: isExpanded ? .infinity : nil,
            maxHeight: isExpanded ? ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * expandedHeightFraction : nil
        )
        .overlay(alignment: .top) {
            // Toast shown when agent finishes while pill is collapsed
            if !isExpanded, let toast = agentToast {
                Button {
                    dismissAgentToast()
                    withAnimation(expandSpring) { isExpanded = true }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(toast)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color(hex: 0x323232))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .offset(y: -86)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, isExpanded ? 8 : 0)
        .background {
            if isExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .frame(width: 3000, height: 3000)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(expandSpring) { isExpanded = false }
                    }
            }
        }
        // Keep the screen from auto-locking while the user is engaged with the
        // agent: pill expanded, agent working (incl. background sessions — same
        // scope as the wand glow), or dictation listening.
        .keepScreenAwake(while: isExpanded || isWorking || ActiveAgentTracker.shared.anyWorking || dictation.isActive || speech.isRecording)
        .onChange(of: isExpanded) { _, expanded in
            autoStartTask?.cancel()
            autoStartTask = nil
            if expanded {
                // The chat's field becomes the panel's input with its words (mock v15 M2); typed
                // in, it keeps the keyboard, which moves to the panel's input, its own text field,
                // so the panel opens above the keyboard (mock v15 H2). This reads the focus the
                // field holds as the panel opens and gives it to the panel's input. SwiftUI does not
                // document the order of this action and the field's removal, so the swipe UI tests'
                // drags from the typed-in field check on screen that the panel's input has it.
                if focusedInput == .replyField { focusedInput = .panel }
                dismissAgentToast()
                // Opportunistic cleanup of idle in-memory sessions (5 min TTL).
                ChatPillState.shared.evictIdleSessions()
                // 30s idle clear: ONLY for inbox sessions. Message-detail and compose
                // sessions persist across pill opens (tied to their email/draft).
                if isInboxChat,
                   let lastActivity = lastChatActivity,
                   Date().timeIntervalSince(lastActivity) > 30,
                   !chatMessages.isEmpty,
                   !isWorking {
                    // Enqueue KB refinement with a dereferenced snapshot of the expiring
                    // session. Previously fire-and-forget to `KBRefinementService.refineKB`;
                    // now persisted to GRDB first via BackfillAIQueue so it survives app
                    // kill / suspend / network drop. Drains on BGProcessing and foreground.
                    //
                    // Per-turn text is ROLE-aware (required — see
                    // `KBRefinementService.buildChatHistory` which reads `userMessage`
                    // for user turns and `content` for assistant turns). For user turns,
                    // raw `content` is the template name "chat_converse" (not human text).
                    let expiringTurns = sessionTurns
                    let expiringSid = currentSessionId
                    // Demo sessions never refine the user's KB — a demo chat
                    // feeding kb refinement would pollute the real KB (and the
                    // reminders parsed from it) with demo content.
                    if !expiringTurns.isEmpty, let sid = expiringSid, !sid.hasPrefix("demo:") {
                        let snapshot = KBRefineSnapshot(
                            sessionId: sid,
                            enqueuedAt: Int64(Date().timeIntervalSince1970 * 1000),
                            turns: expiringTurns.map(KBRefineSnapshot.Turn.from)
                        )
                        Task {
                            await BackfillAIQueue.shared.enqueueKBRefine(snapshot)
                        }
                        // Memory indexing runs per-turn at `ChatStore.appendTurn` time
                        // (ADR-IOS-034). Session-end no longer needs to
                        // re-index; it only triggers KB refine + dereference below.
                    }
                    // Dereference numeric IDs in the expiring session's persisted turns.
                    // Replaces raw [Email](N) in content with resolved renderedContent
                    // so past sessions don't depend on ChatIdTranslator mappings.
                    if let sid = expiringSid {
                        Task {
                            do { try await ChatStore.shared.dereferenceSessionTurns(sessionId: sid) }
                            catch { BackgroundSyncLogger.logDebug("[DynamicIslandChat] Failed to dereference expiring session: \(error)") }
                        }
                    }
                    // Snapshot reminders for the expiring session before clearing
                    if let sid = currentSessionId {
                        sessionReminderSnapshots[sid] = activeReminders
                    }
                    chatMessages = []
                    lastFailedSend = nil
                    sessionTurns = []
                    currentSessionId = nil
                    // Clear stale email context from resumed message-detail sessions —
                    // without this, the next fresh inbox message would incorrectly get
                    // "Regarding [Email](N):" prefix from the expired session's context.
                    contextEmailNumericId = nil
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] Session expired (>30s idle), cleared chat")
                }

                // Load session history on expand (inbox context only, once per open cycle).
                if isInboxChat {
                    loadSessionHistory()
                }

                // About an email: read the thread's stored chat (every key of the thread, once
                // per session) and register the email for [Email](N) references. An email's
                // number follows it across moves (`ChatIdTranslator.remapRealId` at the move),
                // so a stored turn's pills resolve as they are.
                if let msg = message {
                    Task {
                        await loadThreadChat(about: msg)
                        contextEmailNumericId = await ChatIdTranslator.shared.toNumericId(msg.id)
                        BackgroundSyncLogger.logDebug("[DynamicIslandChat] Registered context email id=\(msg.id) → numeric=\(contextEmailNumericId!)")
                    }
                }

                // Compose: load existing session from GRDB if in-memory is empty.
                // This restores previous edit chat when reopening the same reply/forward.
                if isComposeMode, chatMessages.isEmpty, let did = draftId {
                    let composeSessionId = DemoModeStore.scopedSessionId("compose:\(did)")
                    Task {
                        if let session = try? await ChatStore.shared.loadContextSession(sessionId: composeSessionId) {
                            if chatMessages.isEmpty {
                                currentSessionId = composeSessionId
                                sessionTurns = session.turns
                                chatMessages = messagesForSession(session)
                                BackgroundSyncLogger.logDebug("[DynamicIslandChat] Loaded compose session from GRDB (\(session.turns.count) turns)")
                            }
                        }
                        // Also load edit history from draft
                        if let draft = try? DraftStore.shared.load(id: did) {
                            if editHistory.isEmpty {
                                editHistory = draft.editHistory
                                BackgroundSyncLogger.logDebug("[DynamicIslandChat] Loaded edit history from draft (\(editHistory.count) turns)")
                            }
                        }
                    }
                }

                // Double buffer: swap Buffer 2 → Buffer 1 on expand (instant, no flicker).
                // Then pre-fetch a new Buffer 2 in the background for the next swap.
                // Once shown, Buffer 1 is stable until the next expand.
                if isInboxChat {
                    expandedReminderHash = nil
                    if let buffered = nextReminders {
                        activeReminders = buffered
                        nextReminders = nil
                    }
                    // Pre-fetch Buffer 2 for next swap
                    Task {
                        nextReminders = await ReminderBuilder.getRandomReminders(count: 3, force: true)
                    }
                }

                if Self.autoListens(autoDictation: autoDictation, inChat: replyField != nil) {
                    // Start dictation after the animation fully settles.
                    // (Never in the chat view: there the mic listens only when tapped.)
                    // Task is stored so collapse cancels it (prevents a double start).
                    autoStartTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled, isExpanded, !isTextFieldFocused else { return }
                        startDictation(auto: true)
                    }
                } else if !dictationPromptShown && !TutorialCoordinator.shared.isRunning && replyField == nil {
                    dictationPromptShown = true
                    showDictationPrompt = true
                }
            } else {
                // Collapsing ends the recording; its text is still appended to the input.
                dictation.finish()
                speech.stop()
                isTextFieldFocused = false
                // Start the 30s idle timer from when chat closes —
                // but only if agent is NOT working (WIP responses don't count as idle).
                if !isWorking {
                    lastChatActivity = Date()
                }
                // Reset so next open refreshes session history from GRDB
                hasLoadedHistory = false
            }
        }
        .onChange(of: dictation.isActive) { _, active in
            // A dictation that ended without text sends nothing. On success the text has already
            // been delivered (and sent) by the time this runs.
            if !active { sendWhenDictated = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshDictationPermissions() }
            // The microphone never outlives the app on screen.
            if phase == .background { speech.stop() }
        }
        .onChange(of: speech.isStarting) { _, _ in refreshDictationPermissions() }
        .onChange(of: isTextFieldFocused) { _, focused in
            isInputFocused = focused
            if focused {
                dictation.finish()
                speech.stop()
            }
        }
        // Reply field (chat view): a confirmation card while collapsed opens the sheet, which takes
        // the request. The field's words are not changed here: the request's own transitions
        // (card, answer, sent compose) land on the chat key it was sent under, in `ChatFieldWords`
        // (`SessionUISink`, `sendAgentChat`, `AgentToolRouter.enqueueComposeAndAwaitOutcome`).
        // A new email's chat: a reopened draft's words are put in the field once, the field takes
        // focus as the chat opens, and every change of the words goes to the draft.
        .task(id: replyField?.newEmail?.sessionKey) { startNewEmail() }
        .onChange(of: inputText) { _, words in replyField?.newEmail?.wordsChanged(words) }
        // The thread's chat, read as the pill appears and whenever it is about a newer email, so a
        // card raised in any key of the thread opens the sheet while collapsed (ADR-IOS-114).
        .task(id: message?.id) {
            guard let message else { return }
            await loadThreadChat(about: message)
        }
        // The compose cards this screen's chat asked for (ADR-IOS-053 Phase 2), taken while the
        // pill is on screen, whenever one may have become takeable or the chat's keys change.
        // Another screen's request is never taken here, whichever screens are mounted.
        // `initial`: a screen mounted with a request already waiting (the inbox entered again
        // from the sidebar, whose on-screen value starts true) takes it without a later change.
        .onChange(of: composeTakeWatch, initial: true) { _, watch in takeAgentCompose(for: watch.host) }
        // The field's unsent words (ADR-IOS-117): the chat's kept words come back as the pill
        // shows it; `ChatFieldWords.apply` keeps every change until it is sent.
        .task(id: wordsKey) {
            guard let key = wordsKey else { return }
            await ChatFieldWords.shared.load(key)
        }
        .onChange(of: shownMessages.last?.actionConfirmation != nil) { _, hasCard in
            guard hasCard, replyField != nil, !isExpanded else { return }
            fieldSentText = nil
            withAnimation(expandSpring) { isExpanded = true }
        }
        .onChange(of: isWorking && fieldSentText != nil) { _, pulsing in
            if pulsing {
                withAnimation(.easeInOut(duration: ChatViewLayout.fieldPulseDuration).repeatForever(autoreverses: true)) {
                    fieldPulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { fieldPulse = false }
            }
        }
        .onChange(of: isWorking) { wasWorking, nowWorking in
            if wasWorking && !nowWorking {
                fieldSentText = nil
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart onChange(isWorking) fired: wasWorking=\(wasWorking) nowWorking=\(nowWorking)")
            }
            // Auto-restart dictation when the agent finishes its turn — same UX
            // as auto-start on pill open. Respects the autoDictation preference,
            // and skips if the user has the keyboard up or already dictating.
            guard wasWorking, !nowWorking else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: skip — not a working->idle transition")
                }
                return
            }
            guard Self.autoListens(autoDictation: autoDictation, inChat: replyField != nil), isExpanded, !isTextFieldFocused else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: skip — replyField=\(replyField != nil) autoDictation=\(autoDictation) isExpanded=\(isExpanded) isTextFieldFocused=\(isTextFieldFocused)")
                }
                return
            }
            guard !dictation.isActive else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: skip — already recording")
                }
                return
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: scheduling delayed start (800ms)")
            }
            autoStartTask?.cancel()
            autoStartTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, isExpanded, !isTextFieldFocused else {
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: delayed task aborted — cancelled=\(Task.isCancelled) isExpanded=\(isExpanded) isTextFieldFocused=\(isTextFieldFocused)")
                    }
                    return
                }
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] dictation-auto-restart: calling startDictation")
                }
                startDictation(auto: true)
            }
        }
        .task {
            guard isInboxChat else { return }
            await session.observeMessageReminders()
        }
        .onChange(of: PromptStore.shared.rawKB) { _, _ in
            // KB changed (user edit, Device Sync, agent tool) — triggers reminder regeneration
            guard isInboxChat else { return }
            regenerateReminders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remindersDidChange).receive(on: DispatchQueue.main)) { _ in
            // Reminder data changed (message count, dismiss/enable) — regenerate Buffer 2
            guard isInboxChat else { return }
            regenerateReminders()
        }
        .onChange(of: ActiveAgentTracker.shared.workingSessions) { _, sessions in
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] workingSessions onChange: sessionKey=\(sessionKey) matches=\(sessions.contains(sessionKey)) isWorking=\(isWorking) activeChatTaskNil=\(activeChatTask == nil) sessionsCount=\(sessions.count)")
            }
            // Restore working state when view is recreated and agent is still running,
            // or clear it when the agent finishes while this view is active.
            if sessions.contains(sessionKey) && !isWorking {
                isWorking = true
            } else if !sessions.contains(sessionKey) && isWorking && activeChatTask == nil {
                isWorking = false
                resetStatusQueue()
            }
        }
        .onAppear {
            composeHostAppeared = true
            // Sync isWorking with ActiveAgentTracker on view (re)appearance.
            // .onChange only fires on CHANGES — if the agent started/finished while
            // this view was off-screen, isWorking would be stale.
            let trackerHasSession = ActiveAgentTracker.shared.workingSessions.contains(sessionKey)
            if trackerHasSession && !isWorking {
                isWorking = true
            } else if !trackerHasSession && isWorking {
                isWorking = false
                resetStatusQueue()
            }
        }
        .onDisappear {
            composeHostAppeared = false
            // Recording must never outlive its UI: if this pill vanishes while
            // dictating (host view dismissed/torn down), stop the mic and cancel
            // any pending auto-restart so it can't re-arm after removal
            // (2026-07-08: mic kept recording under a dismissed compose cover).
            autoStartTask?.cancel()
            autoStartTask = nil
            sendWhenDictated = false
            // Unconditional: cancel() is a no-op when idle, and discards a
            // recording or transcription in progress (nowhere left to append it).
            dictation.cancel()
            dictation.stopLearning()
            speech.stop()
            // No eager cancellation for any session type:
            // - Inbox: pill stays mounted, N/A
            // - Message-detail: user can navigate back to see the result
            // - Compose: agent writes draft to GRDB via autoSaveDraft — user can
            //   reopen from Drafts folder. Cancelling would drop the edit.
            // Sessions are evicted by TTL/maintenance, not by view lifecycle.
        }
        .alert("Auto-Enable Dictation", isPresented: $showDictationPrompt) {
            Button("Enable") {
                autoDictation = true
                autoStartTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled, isExpanded, !isTextFieldFocused else { return }
                    startDictation(auto: true)
                }
            }
            Button("No Thanks", role: .cancel) { }
        } message: {
            Text("Automatically start dictation when you open the chat pill? You can change this anytime in TabMail Settings > UI.")
        }

    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        Button {
            withAnimation(expandSpring) { isExpanded = true }
        } label: {
            HStack(spacing: 8) {
                ChatPillWandIcon(isWorking: isWorking || ActiveAgentTracker.shared.anyWorking, size: 24)
                Text(isComposeMode ? "Edit" : "Chat")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .contentShape(Capsule())
        }
        .buttonStyle(ExpandablePillPressStyle())
        .modifier(ChatPillTipModifier(isComposeMode: isComposeMode, hasMessage: message != nil))
        .modifier(AgentBackgroundTipModifier(active: !isWorking && ActiveAgentTracker.shared.anyBackgroundWorking))
        .accessibilityIdentifier("chatPill")
    }

    // MARK: - Expanded input bar

    private var expandedInputBar: some View {
        ChatFieldBarRow {
            micButton
        } text: {
            inputField(placeholder: PillDictationMode.placeholder(isCompose: isComposeMode, offNote: dictationOffNote))
        } send: {
            trailingButton
        }
        .animation(nil, value: isTextFieldFocused)
        .animation(nil, value: isWorking)
    }

    /// The mic: dictation into the input (backend, or on this iPhone when opted out of AI).
    var micButton: some View {
        Button {
            // The newest gesture wins: a delayed auto-start still waiting must not start after this tap.
            autoStartTask?.cancel()
            autoStartTask = nil
            if speech.isRecording || speech.isStarting {
                speech.stop()
                return
            }
            switch dictation.phase {
            case .listening: dictation.finish()
            case .idle: startDictation()
            case .transcribing: break
            }
        } label: {
            ChatMicCircle(symbol: micSymbol, listening: micListening, transcribing: spinnerPlace == .mic)
                .frame(width: ChatViewLayout.fieldTapSize, height: ChatViewLayout.fieldTapSize)
                .contentShape(Rectangle())
        }
        // Dictation is transcribed on the AI backend (off without a connection), or on this iPhone
        // when opted out of AI (off if the language has no on-device model).
        .disabled(isWorking || dictation.phase == .transcribing
            || (!dictation.isActive && !speech.isRecording && !speech.isStarting && !canDictate))
        .accessibilityLabel(spinnerPlace == .mic ? "Transcribing" : micListening ? "Stop dictation" : "Dictate")
        .popoverTip(DictationLanguageTip(), arrowEdge: .bottom)
    }

    /// The input as the user sees and edits it: what the user types becomes their words. The
    /// app's own changes to the words do not pass through here.
    private var typedText: Binding<String> {
        Binding(get: { inputText }, set: { fieldFill.apply(.put($0)) })
    }

    /// The "e.g." line's change, put in the field for the user to send or edit; never sent here.
    func putExample(_ example: String) {
        fieldFill.apply(.put(example))
        inputSelection = .init(insertionPoint: inputText.endIndex)
    }

    /// The two text fields that take the keyboard: the chat view's reply field, and the open
    /// panel's input (also the only one of the inbox and compose pills, which have no reply field).
    enum InputFocus: Hashable {
        case replyField
        case panel
    }

    /// The input field, with the dictation waveform over it while listening. `showChat`: the chat's
    /// reply field's "Show TabMail chat" (`showChatAction`), on the field and, while dictation hides
    /// the field from VoiceOver, on the waveform VoiceOver focuses instead. `focus`: which field
    /// this is, for the keyboard (`InputFocus`).
    func inputField(placeholder: String, showChat: (() -> Void)? = nil, focus: InputFocus = .panel) -> some View {
        // Dictating: the field's text dims behind the waveform. Tap it to stop listening; the
        // text is appended when it comes back.
        TextField(placeholder, text: typedText, selection: $inputSelection, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($focusedInput, equals: focus)
            .modifier(ReplyFieldFocusMarker(focused: isTextFieldFocused))
            // Debug UI tests only: counts this field being built while a drag's finger is down
            // and after its let-go.
            .modifier(ChatFieldDragMarker.InputFieldBuilt())
            .frame(minHeight: dictation.isActive ? DictationConfig.meterMaxBarHeight : nil)
            .opacity(dictation.isActive ? DictationConfig.dimmedInputOpacity : 1)
            .allowsHitTesting(!dictation.isActive)
            // VoiceOver reads the waveform instead of the dimmed field.
            .accessibilityHidden(dictation.isActive)
            .showChatAction(showChat, isExpanded: isExpanded)
            .overlay {
                if dictation.isActive {
                    DictationPillView(controller: dictation)
                        .contentShape(Rectangle())
                        .onTapGesture { dictation.finish() }
                        .showChatAction(showChat, isExpanded: isExpanded)
                }
            }
    }

    /// Send, or Stop while the agent works, Retry after a failure, the spinner while transcribing the
    /// words Send stopped (the mic spins for the words it stopped, and Send keeps its look).
    @ViewBuilder
    var trailingButton: some View {
        if isWorking {
            // Stop button — handle stop entirely here (not in Task catch)
            // because URLSession throws URLError.cancelled, not CancellationError
            Button {
                activeChatTask?.cancel()
                activeChatTask = nil
                isWorking = false
                ActiveAgentTracker.shared.clearWorking(sessionKey)
                resetStatusQueue()
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: "Stopped.",
                    timestamp: Date()
                ))
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: ChatViewLayout.fieldTapSize, height: ChatViewLayout.fieldTapSize)
                    .contentShape(Rectangle())
            }
        } else if spinnerPlace == .send {
            DictationSpinner(isRetrying: dictation.isRetrying)
                .frame(width: ChatViewLayout.fieldTapSize, height: ChatViewLayout.fieldTapSize)
                .accessibilityLabel("Transcribing")
        } else if !isWorking && !dictation.isActive && (pendingResume != nil || lastFailedSend != nil) && isOnLiveSession
                    && (inputText.trimmingCharacters(in: .whitespaces).isEmpty || (pendingResume?.fieldWordsKey == wordsKey && fieldFill.holdsSentWords)) {
            // Retry button. Shown on an empty field, or on a field still holding the unchanged sent
            // words of the field's own cut-off request (resuming it adds no user turn). Reverts to the send
            // button as soon as the user types or edits. Routes to the right path:
            // a connection-lost RESUMES from saved state; a plain failure re-sends.
            Button {
                if pendingResume != nil {
                    // Connection-lost: resume the interrupted turn (no re-execution
                    // of completed tools). Same action as the inline affordance.
                    resumeAgentChat()
                } else if let failed = session.takeFailedSendForRetry() {
                    // The failed send leaves the chat, then is sent again (matches TB retry),
                    // as it was sent: from the field with its email and choice, or from the panel.
                    sendAgentChat(failed.text, field: failed.field, ownsFieldWords: failed.ownsFieldWords)
                }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: ChatViewLayout.fieldTapSize, height: ChatViewLayout.fieldTapSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Retry")
            .accessibilityIdentifier("chatRetry")
        } else {
            // Normal send button
            Button {
                if dictation.phase == .listening {
                    // Send finishes the dictation first; its text, if any, is sent when it lands.
                    sendWhenDictated = true
                    dictation.finish()
                } else {
                    sendMessage()
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .frame(width: ChatViewLayout.fieldSendSize, height: ChatViewLayout.fieldSendSize)
                    .foregroundStyle(canTapSend ? Theme.accent : .secondary.opacity(0.3))
                    .frame(width: ChatViewLayout.fieldTapSize, height: ChatViewLayout.fieldTapSize)
                    .contentShape(Rectangle())
            }
            .disabled(!canTapSend)
            .accessibilityIdentifier("chatSend")
        }
    }

    private var signInBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Sign in to TabMail for AI features and push notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var subscribeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Subscribe to unlock AI features")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Chat messages

    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    private var chatMessagesView: some View {
        let page = remindersForPage(isLive: true, sessionId: "")
        return VStack(spacing: 0) {
            if hasSessionHistory {
                sessionTabView
            } else {
                singleSessionScrollView(
                    messages: shownMessages,
                    isLive: true,
                    showIndexingWarning: true,
                    reminders: page.reminders,
                    canDismissReminders: page.canDismiss
                )
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !shownMessages.isEmpty {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if focused {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: shownMessages.count) {
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: isWorking) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// Regenerate reminders after a change (dismiss, tool add/del, KB edit).
    /// Always rebuilds Buffer 2 (nextReminders). If Buffer 1 is not currently being
    /// displayed, also propagates immediately so the next expand is instant.
    private func regenerateReminders() {
        Task {
            let fresh = await ReminderBuilder.getRandomReminders(count: 3, force: true)
            nextReminders = fresh
            if !isActiveRemindersShown {
                activeReminders = fresh
            }
        }
    }

    /// Reminders + dismissability for a given session page.
    /// - `__new__` page and live session without snapshot: show `activeReminders` (Buffer 1), dismissable
    /// - Live session with snapshot / past sessions: show frozen snapshot, read-only
    private func remindersForPage(isLive: Bool, sessionId: String) -> (reminders: [Reminder], canDismiss: Bool) {
        if isLive {
            // Live session that already has a snapshot → show frozen (user sent a message)
            if let snapshot = sessionReminderSnapshots[sessionId], !snapshot.isEmpty {
                return (snapshot, false)
            }
            // __new__ page or live session before first message → show Buffer 1
            return (activeReminders, true)
        }
        return (sessionReminderSnapshots[sessionId] ?? [], false)
    }

    /// TabView with page-style swiping between sessions.
    private var sessionTabView: some View {
        VStack(spacing: 0) {
            TabView(selection: Binding(get: { activeSessionIndex }, set: { activeSessionIndex = $0 })) {
                ForEach(Array(loadedSessions.enumerated()), id: \.element.id) { index, loadedSession in
                    let isLivePage = loadedSession.id == currentSessionId
                    let isNewPage = loadedSession.id == "__new__"
                    let page = remindersForPage(isLive: isLivePage || isNewPage, sessionId: loadedSession.id)
                    // Show email context for past message-detail sessions
                    let emailCtx = (!isLivePage && !isNewPage) ? sessionEmailContexts[loadedSession.id] : nil
                    singleSessionScrollView(
                        messages: isNewPage ? [] : (isLivePage ? chatMessages : (cachedSessionMessages[loadedSession.id] ?? [])),
                        isLive: isLivePage,
                        showIndexingWarning: isLivePage || isNewPage,
                        reminders: page.reminders,
                        canDismissReminders: page.canDismiss,
                        emailContext: emailCtx,
                        sessionTurnsForFork: (!isLivePage && !isNewPage) ? loadedSession.turns : nil
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Subtle custom dot indicator
            HStack(spacing: 4) {
                ForEach(0..<loadedSessions.count, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(index == activeSessionIndex ? 0.6 : 0.15))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Scroll view for a single session's messages.
    private func singleSessionScrollView(messages: [ChatMessage], isLive: Bool, showIndexingWarning: Bool = false, reminders: [Reminder] = [], canDismissReminders: Bool = false, emailContext: EmailContextSnapshot? = nil, sessionTurnsForFork: [ChatTurn]? = nil) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Email context card (for message-detail sessions shown in inbox history)
                if let ctx = emailContext {
                    HStack {
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ctx.subject)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(ctx.from)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Palette.boxBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                // Indexing warning (agent search results may be incomplete)
                if showIndexingWarning && isBackfillInProgress && isInboxChat {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Indexing in progress — search results may be incomplete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                // Reminder cards (inbox context, live or past sessions with snapshots)
                if !reminders.isEmpty && isInboxChat {
                    VStack(alignment: .leading, spacing: 6) {
                        // Warning if proactive notifications won't actually fire — either
                        // disabled in-app or blocked at the iOS permission level.
                        RemindersNotificationWarning()
                        ForEach(reminders, id: \.hash) { reminder in
                            ReminderTopCard(reminder: reminder, canDismiss: canDismissReminders, expandedReminderHash: $expandedReminderHash, hiddenReminderHashes: $hiddenReminderHashes)
                        }
                    }
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                    ChatBubble(message: msg)
                        .id(msg.id)
                        .popoverTip(msg.role == .user && !messages[(index + 1)...].contains(where: { $0.role == .user }) ? ChatForkTip() : nil, arrowEdge: .trailing)
                        .contextMenu {
                            if !isWorking && msg.role == .user {
                                // The live list can be a thread's merged chat (ADR-IOS-114); a turn is
                                // rewound or re-sent in its own session, so the menu works on that
                                // session's index and offers nothing for another session's turn.
                                if isLive, let index = chatMessages.firstIndex(where: { $0.id == msg.id }) {
                                    let hasLaterUserMsg = chatMessages[(index + 1)...].contains { $0.role == .user }
                                    if isComposeMode {
                                        // Compose: single-session; rewind in-place (mutates draft back to snapshot).
                                        if !hasLaterUserMsg {
                                            Button("Re-send message", systemImage: "arrow.clockwise") {
                                                resendLastUserComposeEdit(text: msg.content, afterIndex: index)
                                            }
                                        } else {
                                            Button("Rewind and re-send", systemImage: "arrow.uturn.backward") {
                                                rewindComposeEditToMessage(text: msg.content, atIndex: index)
                                            }
                                        }
                                    } else if !hasLaterUserMsg {
                                        Button("Re-send message", systemImage: "arrow.clockwise") {
                                            resendLastUserMessage(text: msg.content, field: msg.fieldSend, afterIndex: index)
                                        }
                                    } else if message != nil {
                                        // Message-detail: rewind in-place (no session history)
                                        Button("Rewind and re-send", systemImage: "arrow.uturn.backward") {
                                            rewindToMessage(text: msg.content, atIndex: index)
                                        }
                                    } else {
                                        Button("Fork and re-send", systemImage: "arrow.uturn.right") {
                                            forkFromMessage(text: msg.content, atIndex: index)
                                        }
                                    }
                                } else if !isLive {
                                    Button("Fork and re-send", systemImage: "arrow.uturn.right") {
                                        forkFromMessage(text: msg.content, atIndex: index, sourceMessages: messages, sourceTurns: sessionTurnsForFork, sourceReminders: reminders)
                                    }
                                }
                            }
                        }
                }
                if isLive && isWorking {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(workingStatus.isEmpty ? "Thinking..." : workingStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if isThrottled {
                            Text("Taking a little longer — upgrade to Pro for faster responses")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                // Connection-lost resume affordance. Tapping continues the interrupted
                // turn from saved conversation_state (completed tools/thinking preserved)
                // — distinct from the fork/resend context-menu actions on user messages.
                if isLive && !isWorking && pendingResume != nil {
                    Button {
                        resumeAgentChat()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Connection lost. Tap to retry.")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Convert a loaded ChatSession's turns into ChatMessage array for display.
    private func messagesForSession(_ session: ChatStore.ChatSession) -> [ChatMessage] {
        ThreadChatReader.chatMessages(for: session.turns)
    }

    /// Finds the keys of `email`'s thread chat and reads their stored turns (ADR-IOS-114).
    private func loadThreadChat(about email: MessageHeader) async {
        let keys = await ThreadChatReader.keys(about: email)
        // The pill may be about another email by now; the next load is for that one.
        if message?.id == email.id { threadKeys = keys }
        await ThreadChatReader.load(keys: keys)
    }

    /// Load past sessions from GRDB for swipe navigation (inbox context only).
    /// Always appends a "__new__" placeholder as the rightmost page for starting fresh sessions.
    private func loadSessionHistory() {
        guard !hasLoadedHistory else { return }
        hasLoadedHistory = true
        let maxSessions = UserDefaults.standard.integer(forKey: ChatPillState.maxSessionsKey)
        let limit = maxSessions > 0 ? maxSessions : ChatPillState.defaultMaxSessions
        // Demo isolation: demo mode lists ONLY demo sessions; normal mode
        // never lists them.
        let demoActive = DemoModeStore.shared.isActive

        Task {
            do {
                var sessions = try await ChatStore.shared.loadSessions(limit: limit, demoActive: demoActive)

                // If there's a live session with messages not yet in GRDB (or the current
                // session is already the last loaded one), ensure it's represented.
                if let sid = currentSessionId {
                    if !sessions.contains(where: { $0.id == sid }) && !chatMessages.isEmpty {
                        sessions.append(ChatStore.ChatSession(
                            id: sid,
                            turns: sessionTurns,
                            lastActivity: Date(),
                            remindersSnapshot: sessionReminderSnapshots[sid],
                            emailContext: sessionEmailContexts[sid]
                        ))
                    }
                }

                // Always append a "new session" placeholder (rightmost page).
                // Allows starting a fresh session at any time by swiping right.
                sessions.append(ChatStore.ChatSession(
                    id: "__new__",
                    turns: [],
                    lastActivity: .distantFuture,
                    remindersSnapshot: nil,
                    emailContext: nil
                ))

                // Pre-compute ChatMessage arrays for past sessions (stable UUIDs prevent flicker).
                // Restore persisted reminder snapshots for past sessions.
                var cache: [String: [ChatMessage]] = [:]
                for s in sessions where s.id != "__new__" && s.id != currentSessionId {
                    cache[s.id] = messagesForSession(s)
                    if let reminders = s.remindersSnapshot, sessionReminderSnapshots[s.id] == nil {
                        sessionReminderSnapshots[s.id] = reminders
                    }
                    if let emailCtx = s.emailContext, sessionEmailContexts[s.id] == nil {
                        sessionEmailContexts[s.id] = emailCtx
                    }
                }
                cachedSessionMessages = cache
                loadedSessions = sessions

                // Navigate to pending session (deep link) or live session or __new__
                if let pending = session.pendingNavigateToSession,
                   let idx = sessions.firstIndex(where: { $0.id == pending }) {
                    activeSessionIndex = idx
                    session.pendingNavigateToSession = nil
                } else if let sid = currentSessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    activeSessionIndex = idx
                } else {
                    activeSessionIndex = sessions.count - 1
                }
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] Loaded \(sessions.count - 1) session(s) + new session page")
            } catch {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] Failed to load session history: \(error)")
            }
        }
    }

    // MARK: - Logic

    private var composeAttachmentSnapshotReady: Bool {
        guard let gate = composeAttachmentCarryGate else { return true }
        return ComposeDraftGuards.attachmentSnapshotGate(
            producer: .autoSave,
            outstandingCarryCount: gate.outstanding,
            hasUnacknowledgedFailure: gate.hasUnacknowledgedFailure) == .ready
    }

    /// The mic listens: a dictation on the backend, or on this iPhone when opted out of AI.
    private var micListening: Bool {
        dictation.phase == .listening || speech.isRecording
    }

    /// The button that spins while the words are transcribed: the one that stopped the dictation.
    private var spinnerPlace: DictationSpinnerPlace? {
        DictationSpinnerPlace.resolve(phase: dictation.phase, sendWhenDictated: sendWhenDictated)
    }

    /// The mic's glyph: the stop square while listening, else the outlined mic, struck through when
    /// dictation is off.
    private var micSymbol: String {
        if micListening { return "stop.fill" }
        return canDictate ? "mic" : "mic.slash"
    }

    /// Whether the mic can start a dictation: on the backend (online), or on this iPhone when opted out.
    private var canDictate: Bool { dictationMode != .off }

    private func refreshDictationPermissions() {
        speechPermission = SFSpeechRecognizer.authorizationStatus()
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    private var speechLocale: Locale {
        PillDictationMode.speechLocale(dictationLanguage: DictationLanguage.current())
    }

    private var dictationMode: PillDictationMode {
        PillDictationMode.resolve(
            optedOutOfAI: optOutAllAI,
            isOnline: networkMonitor.isConnected,
            onDevice: onDeviceReadiness,
            tutorialRunning: TutorialCoordinator.shared.isRunning)
    }

    /// Opted out: whether this iPhone can dictate (an on-device model for the language, and the
    /// speech and microphone permissions not denied). Not opted out, `.ready`: the backend decides.
    private var onDeviceReadiness: OnDeviceReadiness {
        guard optOutAllAI else { return .ready }
        return OnDeviceReadiness.resolve(
            modelAvailable: OnDeviceSpeechRecognizer.isAvailable(locale: speechLocale),
            speech: speechPermission,
            microphone: microphonePermission)
    }

    /// Opted out and the mic is off: the placeholder says why.
    private var dictationOffNote: String? {
        guard optOutAllAI, !TutorialCoordinator.shared.isRunning, dictationMode == .off else { return nil }
        return onDeviceReadiness.note
    }

    /// What the dictation's cleanup reads as the screen, captured when it starts: what the pill
    /// is about, the chat so far, and the input field it appends to.
    private var dictationContext: DictationContext {
        if isComposeMode {
            let header = [draftSubject.map { "Subject: \($0)" }, draftBody].compactMap { $0 }.filter { !$0.isEmpty }
            return .chatPill(title: "Edit draft", header: header, messages: chatMessages, input: inputText)
        }
        if let message {
            let header = ["From: \(message.from)", "Subject: \(message.subject)", message.snippet].filter { !$0.isEmpty }
            return .chatPill(title: message.subject, header: header, messages: chatMessages, input: inputText, emailId: message.id)
        }
        return .chatPill(title: "Chat", header: [], messages: chatMessages, input: inputText)
    }

    /// `auto`: started by the pill itself (it opened, the agent finished, Auto-Enable Dictation), not
    /// by a tap on the mic. The on-device recognizer asks for permission on a tap only: an auto-start
    /// runs when speech recognition and the microphone are both already granted, else it does nothing.
    /// Whether dictation starts by itself, on open and after the agent's turn: only with the
    /// auto-dictation preference on, and never in the chat view's reply field, where the mic
    /// listens only when tapped. The ONE decision both automatic starts ask.
    static func autoListens(autoDictation: Bool, inChat: Bool) -> Bool {
        autoDictation && !inChat
    }

    private func startDictation(auto: Bool = false) {
        // Auto-start follows the mic button: while it is off, nothing starts.
        guard canDictate else { return }
        // The same gate that shows the input bar (and so the mic and the waveform) in the body.
        let canUseAI = hasTabMailSession && AISubscriptionGate.shared.isActive
        isTextFieldFocused = false
        if dictationMode == .onDevice {
            // Behind the sign-in or subscribe bar there is no mic or waveform: an auto-start records nothing there.
            guard canUseAI, !speech.isRecording, !speech.isStarting else { return }
            fieldFill.apply(.startHearing)
            speech.start(locale: speechLocale, auto: auto) { transcript in
                fieldFill.apply(.heard(transcript))
                inputSelection = .init(insertionPoint: inputText.endIndex)
            }
            return
        }
        dictation.start(context: dictationContext, canUseAI: canUseAI, input: { inputText }) { text in
            fieldFill.apply(.said(text))
            inputSelection = .init(insertionPoint: inputText.endIndex)
            Task { await DictationLanguageTip.dictationCompleted.donate() }
            if sendWhenDictated {
                sendWhenDictated = false
                if canSend { sendMessage() }
            }
            // The appended text grows the input bar, shrinking the scroll view.
            // Defer the scroll so layout settles before repositioning.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private var canSend: Bool {
        hasTabMailSession
            && !inputText.trimmingCharacters(in: .whitespaces).isEmpty
            && !isWorking
            && !dictation.isActive
            && !speech.isRecording
            && composeReadyToSend
    }

    /// In compose mode, the draft has loaded and its attachments are known.
    private var composeReadyToSend: Bool {
        !isComposeMode || (composeMutationAllowed && composeAttachmentSnapshotReady)
    }

    /// While listening, send stays available: it finishes the dictation, then sends its text.
    private var canTapSend: Bool {
        canSend || (dictation.phase == .listening && hasTabMailSession && !isWorking && composeReadyToSend)
    }

    /// The practice reply's draft chat (part 2), where the tutorial fills in an edit.
    private var isTutorialPracticeDraft: Bool {
        isComposeMode && draftReplyToProviderMessageId == DemoSeed.TutorialFixture.priyaOffsite
    }

    /// The tutorial's filled-in input in this chat now, if any.
    private var tutorialPromptText: String? {
        if isInboxChat { return TutorialCoordinator.shared.chatPrompt?.rawValue }
        if isTutorialPracticeDraft { return TutorialCoordinator.shared.composeEditPrompt }
        return nil
    }

    private func sendTutorialInput() {
        if isInboxChat, let prompt = TutorialCoordinator.shared.chatPrompt {
            sendTutorialPrompt(prompt)
        } else if isTutorialPracticeDraft, TutorialCoordinator.shared.composeEditPrompt != nil {
            sendTutorialEdit()
        }
    }

    /// The practice reply's scripted edit, through the real edit path: the
    /// chat closes, the draft pulses as during an AI edit, then fades to the
    /// declined reply.
    private func sendTutorialEdit() {
        isTextFieldFocused = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            isExpanded = false
        }
        isWorking = true
        Task { @MainActor in
            await TutorialCoordinator.shared.runPracticeReplyEdit { reply in
                await onDraftUpdate?(nil, reply.body, nil, nil, nil, reply.textMessage, nil)
            }
            isWorking = false
        }
    }

    /// The tutorial's filled-in input: sent like typed text, answered by
    /// `TutorialChatScript`. No tip events are donated (TipKit state outlives
    /// the demo).
    private func sendTutorialPrompt(_ prompt: TutorialCoordinator.ChatPrompt) {
        isTextFieldFocused = false
        TutorialCoordinator.shared.chatPromptSent(prompt)
        sendAgentChat(prompt.rawValue, script: prompt)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let replyField, !isExpanded {
            sendFromReplyField(text, replyField)
            return
        }
        let composeAdmissionAcquired: Bool
        if isComposeMode {
            guard acquireComposeEditAdmission() else { return }
            composeAdmissionAcquired = true
        } else {
            composeAdmissionAcquired = false
        }
        // Dismiss keyboard focus first — stops any in-flight iOS keyboard
        // dictation that could push a final text update after we clear.
        // Then clear text field immediately. Defer remaining state changes to
        // the next tick so the TextField renders as empty before chatMessages /
        // isWorking changes trigger a parent re-render whose .animation()
        // modifier can leak into child views, briefly persisting the old text.
        isTextFieldFocused = false
        // The input as sent is the last word on a correction of a dictation in it (ADR-IOS-086).
        dictation.inputSent(inputText)
        // From the open sheet the input empties as it goes; a newer draft is what is typed next.
        fieldFill.apply(.sentFromSheet)
        inputSelection = .init(insertionPoint: "".startIndex)

        Task { @MainActor in
            await ChatForkTip.chatMessageSent.donate()
            if isComposeMode {
                ComposeChatCollapseTip.hasStartedComposeChat = true
            } else if message != nil {
                MessageChatCollapseTip.hasStartedMessageChat = true
            } else {
                InboxChatCollapseTip.hasStartedInboxChat = true
                TutorialCoordinator.shared.discovered(.inboxChat)
            }
            if isComposeMode {
                sendComposeEdit(text, agentAdmissionAcquired: composeAdmissionAcquired)
            } else {
                sendAgentChat(text)
            }
        }
    }

    /// Send in the chat's reply field: the words go to the agent on the newest email and stay in
    /// the field, pulsing, while it works. The field empties when the reply goes out or the agent
    /// answers in the sheet; a closed compose card leaves the words.
    private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {
        // A new email's chat decides what its Send does; the words stay until it acts on them.
        if let newEmail = field.newEmail {
            newEmail.send(text)
            return
        }
        isTextFieldFocused = false
        fieldFill.apply(.sentFromField)
        dictation.inputSent(inputText)
        fieldSentText = text
        onFieldSend?(text)
        // Who the reply goes to, as chosen now, travels with the send (its words and the agent's
        // compose card), whatever the chat shows when the card arrives or the send is retried.
        let send = message.map { ChatFieldSend(message: $0, onlyTo: field.onlyTo, isNoReply: field.isNoReply, suggestion: field.suggestion) }
        Task { @MainActor in
            MessageChatCollapseTip.hasStartedMessageChat = true
            sendAgentChat(text, field: send)
        }
    }

    /// A new email's chat opening: its draft's words, once, then its reply field takes the
    /// keyboard (`InputFocus.replyField`: the panel, which `isTextFieldFocused` focuses, never
    /// opens in a new email's chat).
    private func startNewEmail() {
        guard let newEmail = replyField?.newEmail, !newEmailStarted else { return }
        newEmailStarted = true
        if !newEmail.startWords.isEmpty { fieldFill.apply(.put(newEmail.startWords)) }
        focusedInput = .replyField
    }

    /// A dictation is recording, transcribing, or starting: its words are coming to the field.
    var isDictating: Bool {
        dictation.isActive || speech.isRecording || speech.isStarting
    }

    // MARK: - Compose inline edit

    private func acquireComposeEditAdmission() -> Bool {
        guard composeMutationAllowed else {
            chatMessages.append(ChatMessage(
                role: .warning,
                content: "This draft did not finish loading. Close and reopen it before editing.",
                timestamp: Date()))
            return false
        }
        guard composeAttachmentSnapshotReady else {
            chatMessages.append(ChatMessage(
                role: .warning,
                content: "Wait for the forward's attachments to finish preparing before editing.",
                timestamp: Date()))
            return false
        }
        guard let ctx = composeContext else {
            BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit: NO composeContext — aborting")
            return false
        }
        _ = ctx
        guard composeAgentSendFence?.beginAgent() ?? true else {
            chatMessages.append(ChatMessage(
                role: .warning,
                content: "Saving, sending, or another draft action is already in progress.",
                timestamp: Date()))
            return false
        }
        return true
    }

    /// `anchor`: a resend or rewind's restored turn. The request edits that turn's draft, as it
    /// was when first asked, never the view's current one, and puts that draft back (awaited)
    /// before its own result is applied.
    /// The draft a compose edit reads: the restored turn's (`anchor`, a resend or rewind), else the
    /// card's current one, with the suggestion's text version and change command when the draft is
    /// the suggestion. A restore hands its turn here, so the edit never reads the card's draft from
    /// before the restore reached it.
    nonisolated static func editBase(
        anchor: InlineEditTurn?, draftSubject: String?, draftBody: String?, draftSuggestion: ReplyResult?
    ) -> (subject: String, body: String, atRequest: (textMessage: String?, changeCommand: String?)) {
        if let anchor {
            return (anchor.subjectAtRequest, anchor.bodyAtRequest,
                    (anchor.textMessageAtRequest, anchor.changeCommandAtRequest))
        }
        return (draftSubject ?? "", draftBody ?? "",
                (draftSuggestion?.textMessage, draftSuggestion?.changeCommand))
    }

    /// The history turn an accepted compose edit records: the request and the draft it edited
    /// (`editBase`), with the suggestion's text version and change command when that draft was the
    /// suggestion, so a resend or rewind puts the whole value back. Internal for testability.
    nonisolated static func editTurn(
        instruction: String, subject: String, body: String,
        atRequest: (textMessage: String?, changeCommand: String?), assistantResponse: String
    ) -> InlineEditTurn {
        InlineEditTurn(
            userRequest: instruction,
            bodyAtRequest: body,
            subjectAtRequest: subject,
            assistantResponse: assistantResponse,
            textMessageAtRequest: atRequest.textMessage,
            changeCommandAtRequest: atRequest.changeCommand
        )
    }

    /// Resend: the last turn is restored and leaves the history. Internal for testability.
    nonisolated static func resendAnchor(_ history: [InlineEditTurn]) -> (anchor: InlineEditTurn?, history: [InlineEditTurn]) {
        guard let last = history.last else { return (nil, history) }
        return (last, Array(history.dropLast()))
    }

    /// Rewind to the user message after `userMessagesBefore` user messages: the turn at that index
    /// (the draft as it was when that request was made) is restored, and it and every later turn
    /// leave the history. Internal for testability.
    nonisolated static func rewindAnchor(
        _ history: [InlineEditTurn], userMessagesBefore: Int
    ) -> (anchor: InlineEditTurn?, history: [InlineEditTurn]) {
        let cutoff = min(userMessagesBefore, history.count)
        guard cutoff < history.count else { return (nil, history) }
        return (history[cutoff], Array(history.prefix(cutoff)))
    }

    /// Puts a resend's or rewind's turn's draft back, awaited, through the card's draft update.
    /// Recipients are not tracked in editHistory: nil keeps the current values. Internal for testability.
    static func restoreDraft(
        _ anchor: InlineEditTurn,
        through apply: (String?, String?, RecipientDelta?, RecipientDelta?, RecipientDelta?, String?, String?) async -> Void
    ) async {
        await apply(anchor.subjectAtRequest, anchor.bodyAtRequest, nil, nil, nil,
                    anchor.textMessageAtRequest, anchor.changeCommandAtRequest)
    }

    private func sendComposeEdit(_ instruction: String, agentAdmissionAcquired: Bool = false, from anchor: InlineEditTurn? = nil) {
        guard composeMutationAllowed else {
            if agentAdmissionAcquired { composeAgentSendFence?.finishAgent() }
            chatMessages.append(ChatMessage(
                role: .warning,
                content: "This draft did not finish loading. Close and reopen it before editing.",
                timestamp: Date()))
            return
        }
        guard composeAttachmentSnapshotReady else {
            if agentAdmissionAcquired { composeAgentSendFence?.finishAgent() }
            chatMessages.append(ChatMessage(
                role: .warning,
                content: "Wait for the forward's attachments to finish preparing before editing.",
                timestamp: Date()))
            return
        }
        guard let ctx = composeContext else {
            if agentAdmissionAcquired { composeAgentSendFence?.finishAgent() }
            BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit: NO composeContext — aborting")
            return
        }
        if !agentAdmissionAcquired {
            guard acquireComposeEditAdmission() else { return }
        }

        // The draft this request edits: the restored turn's, or the parent's current one (values
        // are up-to-date via SwiftUI re-render), with the suggestion's text version and command.
        let base = Self.editBase(anchor: anchor, draftSubject: draftSubject, draftBody: draftBody,
                                 draftSuggestion: draftSuggestion)
        let currentSubject = base.subject
        let currentBody = base.body
        let atRequest = base.atRequest
        // Snapshot — state may flip during the network round-trip.
        let skipSave = skipDraftAutoSave

        BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit START: instruction=\(instruction.prefix(60))")

        // Generate deterministic sessionId for compose (tied to draft).
        // Demo-prefixed while demo mode is active (wiped on demo exit).
        if currentSessionId == nil, let did = draftId {
            currentSessionId = DemoModeStore.scopedSessionId("compose:\(did)")
        }
        let sid = currentSessionId
        // Captured with the session id: a demo turn is written only while its demo runs.
        let admission = DemoModeStore.shared.chatAdmission

        chatMessages.append(ChatMessage(role: .user, content: instruction, timestamp: Date()))
        isWorking = true
        ActiveAgentTracker.shared.setWorking(sessionKey)

        // Persist user turn to GRDB (compose edits now persisted for session resume)
        let userTurn = ChatTurn(
            id: ChatTurn.generateId(),
            timestamp: Date().timeIntervalSince1970 * 1000,
            role: "user",
            content: "compose_edit",
            userMessage: instruction,
            type: "normal",
            chars: instruction.count,
            renderedContent: nil,
            sessionId: sid,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let userTurnPersistence = Task {
            await session.appendTurn(userTurn, admission: admission)
        }
        sessionTurns.append(userTurn)

        // Unstructured timeout: cancel editTask if it takes >120s.
        let contextSource = composeEditContext
        let editTask = Task {
            // The request's context, read now that it is admitted, through the identity-checked
            // body read: another email seated at the replied email's address refuses it.
            var requestContext = ctx
            if let contextSource {
                guard let read = await contextSource() else {
                    throw InlineEditFailure(message: "The email this draft answers changed. Close and reopen the draft before editing.")
                }
                requestContext = read
            }
            // The chat's one AI service, as the pills' agent requests use it (tests install theirs).
            return try await ChatPillState.shared.aiService.performInlineEdit(
                currentSubject: currentSubject,
                currentBody: currentBody,
                context: requestContext,
                instruction: instruction,
                chatHistory: editHistory,
                onSSEEvent: makeCompletionsSSEHandler(idleLabel: "Thinking..."),
                // Owned UI delivery (ADR-IOS-053): compose inline edit enables
                // calendar/contact tools, so route their confirmation cards to
                // THIS compose session's pill rather than fast-failing.
                invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey)
            )
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(120))
            editTask.cancel()
        }

        activeChatTask = Task {
            defer { composeAgentSendFence?.finishAgent() }
            // A resend or rewind first puts its turn's draft back, awaited under this request's
            // admission, so this request's result lands over the restored draft, never before it.
            if let anchor, let onDraftUpdate {
                await Self.restoreDraft(anchor, through: onDraftUpdate)
            }
            _ = await userTurnPersistence.value
            do {
                let result = try await editTask.value
                timeoutTask.cancel()

                // Guard: if user pressed stop, don't append result
                guard !Task.isCancelled else { return }

                // Update the draft, awaited: its suggestion write lands while this request is admitted.
                await onDraftUpdate?(result.subject, result.body, result.toDelta, result.ccDelta, result.bccDelta, result.textMessage, result.changeCommand)

                // Show conversational response as chat bubble
                let responseText = result.response ?? "Done."
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: responseText,
                    timestamp: Date(),
                    animate: true
                ))
                if !isExpanded {
                    // 🚨 R16-3 — `setPendingResponse("Draft updated — tap to review")`
                    // USED TO BE HERE, 41 lines ABOVE the `await autoSaveDraft(…)`
                    // it announces. It is now published after that save, below.
                    //
                    // The conversational reply below stays here: it reports what the
                    // AGENT did, which is true the moment the edit is applied to the
                    // in-memory draft. The moved line is different in kind — it is a
                    // GLOBAL, cross-view claim that a reviewable DURABLE draft exists,
                    // and `finishAutoSave`'s warning is a chat `.warning` appended to
                    // `chatMessages` only, invisible once the sheet is dismissed. So
                    // when the first save failed the Inbox still offered "Draft
                    // updated — tap to review", and tapping it reached
                    // `DraftComposePresenter`'s `case .notFound: Color.clear.onAppear
                    // { dismiss() }` — a success signal that opens nothing, for
                    // generated content that was never committed and that no sync can
                    // recreate.
                    onAgentReply?(responseText)
                    if onAgentReply == nil {
                        showAgentToast(responseText)
                    }
                }

                // Record in edit history for continuous editing (with draft state)
                editHistory.append(Self.editTurn(
                    instruction: instruction, subject: currentSubject, body: currentBody,
                    atRequest: atRequest, assistantResponse: result.raw))

                // Persist assistant turn to GRDB
                let assistantTurn = ChatTurn(
                    id: ChatTurn.generateId(),
                    timestamp: Date().timeIntervalSince1970 * 1000,
                    role: "assistant",
                    content: responseText,
                    userMessage: nil,
                    type: "normal",
                    chars: responseText.count,
                    renderedContent: nil,
                    sessionId: sid,
                    remindersSnapshot: nil,
                    emailContextJSON: nil,
                    thinkingContent: nil
                )
                await session.appendTurn(assistantTurn, admission: admission)
                sessionTurns.append(assistantTurn)

                // Auto-save draft to GRDB (state after edit applied).
                var autoSaveExit: ComposeDraftGuards.AutoSaveExit?
                var autoSaveAttempted = false
                if let did = draftId, !skipSave {
                    let updatedSubject = result.subject ?? currentSubject
                    let updatedBody = result.body ?? currentBody
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit: autoSaveDraft task fired draftKey=\(did) sessionKey=\(sessionKey)")
                    }
                    autoSaveAttempted = true
                    autoSaveExit = await autoSaveDraft(
                        draftKey: did, subject: updatedSubject, body: updatedBody)
                }

                // R16-3 — THE GLOBAL SIGNAL, PUBLISHED AFTER THE WRITE IT CLAIMS.
                // The anonymous `.onReceive(… .agentSessionDidFinish)` closure in
                // `InboxView` consumes this on the post that
                // `clearWorking(sessionKey)` makes at the end of this task, so
                // publishing here still reaches it. (⚠ This named
                // `InboxView.observeAgentFinish` until R17-5 — a symbol that has
                // never existed. `rg 'observeAgentFinish'` returned two hits, both
                // comments citing each other. This repo cites symbols because line
                // numbers rot, `MIS-009`; a symbol citation naming nothing is the
                // same failure with better manners, `MIS-010`.)
                //
                // ⚠️ DELIBERATELY NOT GATED ON THE PROVIDER-SIDE UPLOAD, which is
                // the mirror image (`MIS-005`): `autoSaveDraft` returns once the
                // LOCAL durable row and the durable `.saveDraft` admission have
                // landed, and the server push is a queued `PendingOperation` that
                // drains later. Waiting for it would hide successful offline saves,
                // which is the opposite error. The bar is "a durable draft exists
                // that tapping this toast can open", and that is exactly what a nil
                // exit means.
                //
                // 🚨 **R17-5 — `autoSaveAttempted == false` PUBLISHES NOTHING, AND
                // THE COMMENT THAT LICENSED THE BYPASS WAS THE LOAD-BEARING ERROR.**
                // It read *"this turn never claimed to save, and the caller that set
                // `skipDraftAutoSave` owns the save"*, and `!autoSaveAttempted` was
                // OR-ed into `landed` — which makes "no save was attempted"
                // indistinguishable from "the save landed" and republishes the exact
                // R16-3 symptom through a different door.
                //
                // There is exactly ONE caller that sets `skipDraftAutoSave`
                // (`ComposeView`, `skipDraftAutoSave: showingSuggestion`) and it does
                // NOT own the save. `applyInlineEdit`'s suggestion branch writes
                // only `if replyTo != nil && !isForward`, so
                // new-message and forward have no durable writer at all — and even in
                // reply mode that write stores the header's AI Suggestion,
                // which is not the `Draft` row this toast's tap resolves. The other
                // half of `!autoSaveAttempted` is `draftId == nil`, where no durable
                // draft exists by construction. In every one of those states the
                // toast tapped through to `DraftComposePresenter`'s
                // `case .notFound:` arm and dismissed instantly.
                //
                // ⚠️ AND THE MIRROR IMAGE IS NOT TO AUTO-SAVE THE SUGGESTION. The
                // suggestion bubble is ephemeral BY DESIGN; adopting it requires an
                // explicit user gesture, so persisting it here to make the toast true
                // would be the inverse error (`MIS-005`). Publishing nothing is the
                // honest option: the agent's own reply is already in `chatMessages`
                // above, and a toast whose tap opens nothing is strictly worse than
                // no toast. Nothing else reads this key — `InboxView`'s reappear
                // path consumes the literal `"inbox"` key, not a compose one.
                if !isExpanded {
                    switch ComposeDraftGuards.composeEditGlobalSignal(
                        autoSaveAttempted: autoSaveAttempted, autoSaveExit: autoSaveExit
                    ) {
                    case .durableDraftAvailable:
                        ActiveAgentTracker.shared.setPendingResponse(
                            sessionKey, text: "Draft updated — tap to review")
                    case .autoSaveDidNotLand:
                        ActiveAgentTracker.shared.setPendingResponse(
                            sessionKey, text: Self.autoSaveDidNotLandWarning)
                    case .none:
                        break
                    }
                }

                BackgroundSyncLogger.logDebug("[DynamicIslandChat] Inline edit applied, editHistory=\(editHistory.count) turns")
                confirmSubscriptionActive()
            } catch is CancellationError {
                timeoutTask.cancel()
                guard !Task.isCancelled else { return }
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: "Edit timed out. Please try again.",
                    timestamp: Date()
                ))
            } catch {
                timeoutTask.cancel()
                guard !Task.isCancelled else { return }
                if Self.isSubscriptionError(error) {
                    chatMessages.append(ChatMessage(
                        role: .warning,
                        content: "Active subscription required. Go to TabMail Account to subscribe.",
                        timestamp: Date()
                    ))
                } else {
                    chatMessages.append(ChatMessage(
                        role: .agent,
                        content: "Edit failed: \(error.localizedDescription)",
                        timestamp: Date()
                    ))
                }
            }
            // Guard: stop button already cleaned up
            guard !Task.isCancelled else { return }
            activeChatTask = nil
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit completion: writing isWorking=false sessionKey=\(sessionKey)")
            }
            isWorking = false
            ActiveAgentTracker.shared.clearWorking(sessionKey)
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DynamicIslandChat] sendComposeEdit completion: clearWorking called sessionKey=\(sessionKey)")
            }
        }
    }

    /// The ONE user-facing string for "this compose-edit turn's auto-save did not
    /// land". Held in a single place so the six exits that surface it cannot drift
    /// apart, and so a sixth cannot be added with a sixth wording.
    private static let autoSaveDidNotLandWarning =
        "This draft couldn't be saved to your Drafts folder. Your text is still here — tap Save to try again."

    /// R15-FIX-1 — THE ONE PLACE `autoSaveDraft` DECIDES WHETHER THE USER HEARS
    /// ABOUT AN EXIT. Every early return in `autoSaveDraft` goes through here, so
    /// the roster in `ComposeDraftGuards.AutoSaveExit` is the LIVE decision rather
    /// than a parallel description of it — a new exit cannot be added without
    /// choosing a case, and choosing a case is choosing warn-or-silent.
    ///
    /// Surfaced as a chat `.warning`, which is this surface's own failure channel —
    /// the same one `sendComposeEdit`'s two catch arms use — and which persists in
    /// the transcript. `agentToast` is deliberately NOT used: it renders only while
    /// the pill is collapsed (`!isExpanded`), and the compose sheet this message is
    /// about is on screen precisely when it is expanded.
    ///
    /// ⚠️ NOT A ROLLBACK, and that is the mirror image (see
    /// `ComposeDraftGuards.runCheckedDurableAutoSave`): whatever the local `Draft`
    /// row already holds stays exactly as saved. Deleting it on a failed exit would
    /// destroy the very text this signal exists to protect.
    private func finishAutoSave(_ exit: ComposeDraftGuards.AutoSaveExit) {
        guard ComposeDraftGuards.autoSaveExitWarnsUser(exit) else { return }
        chatMessages.append(ChatMessage(
            role: .warning,
            content: Self.autoSaveDidNotLandWarning,
            timestamp: Date()))
    }

    /// Auto-save the current draft state to GRDB for resume on reopen.
    ///
    /// R16-3 — RETURNS ITS EXIT (nil = the durable local save and the durable
    /// `.saveDraft` admission both landed). `finishAutoSave` still owns the in-chat
    /// warning; the return value exists because the caller publishes a GLOBAL
    /// "Draft updated — tap to review" signal that must not outrun this write, and
    /// a chat `.warning` cannot reach a user whose compose sheet is already gone.
    /// Internal, not private, so a test can drive the row write directly.
    @discardableResult
    func autoSaveDraft(draftKey: String, subject: String, body: String) async -> ComposeDraftGuards.AutoSaveExit? {
        let entryTime = Date()
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: enter draftKey=\(draftKey)")
        }
        guard let ctx = composeContext,
              let cursor = composeGenerationCursor,
              let composeRecipients,
              composeMutationAllowed else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: exit (no composeContext) draftKey=\(draftKey)")
            }
            finishAutoSave(.composeUnavailable)
            return .composeUnavailable
        }

        // IOS-COMPOSE-001: the inline editor is normally disabled while the
        // original forward carry is unsettled, but an already-admitted agent turn
        // can cross that boundary. Wait here as the authoritative producer gate,
        // then read the live Binding so autosave persists the complete attachment
        // set rather than the prefix captured when the turn began.
        if let gate = composeAttachmentCarryGate {
            if ComposeDraftGuards.attachmentSnapshotGate(
                producer: .autoSave,
                outstandingCarryCount: gate.outstanding,
                hasUnacknowledgedFailure: gate.hasUnacknowledgedFailure) == .wait {
                await gate.waitUntilSettled()
            }
            guard ComposeDraftGuards.attachmentSnapshotGate(
                producer: .autoSave,
                outstandingCarryCount: gate.outstanding,
                hasUnacknowledgedFailure: gate.hasUnacknowledgedFailure) == .ready else {
                finishAutoSave(.attachmentCarryIncomplete)
                return .attachmentCarryIncomplete
            }
        }
        let attachmentSnapshot = composeAttachments?.wrappedValue
        let recipients = composeRecipients()
        let editHistJSON = Draft.encodeEditHistory(editHistory)
        let now = Date().timeIntervalSince1970

        // Track accountId for PendingOperation queue after save
        var savedAccountId: String?

        // Try to load existing draft — mutate in place to preserve all fields
        // (especially v24 server sync: serverDraftId, serverPushStatus, rfc822MessageId, attachmentsDirName)
        let loadStart = Date()
        let existingLoaded: Draft?
        do {
            existingLoaded = try DraftStore.shared.load(id: draftKey)
        } catch {
            BackgroundSyncLogger.logDebug("[DraftStore] Auto-save predecessor read failed: \(error)")
            finishAutoSave(.predecessorReadFailed)
            return .predecessorReadFailed
        }
        if DebugModeManager.isLoggingEnabled() {
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: load took \(loadMs)ms found=\(existingLoaded != nil) draftKey=\(draftKey)")
        }

        // Copy-on-write the exact post-boundary attachment snapshot before the DB
        // save. A nil Binding means a non-Compose caller and preserves the row's
        // directory; an empty Compose snapshot intentionally adopts nil. Cleanup
        // always follows `attachmentDisposition`, so a losing generation can
        // destroy only its own staging directory and never the winner's live one.
        let previousDirName = existingLoaded?.attachmentsDirName
        let stagingDirName: String?
        if let attachmentSnapshot {
            if attachmentSnapshot.isEmpty {
                stagingDirName = nil
            } else {
                let staging = DraftAttachmentStorage.newStagingDirName()
                do {
                    try DraftAttachmentStorage.saveAttachments(
                        attachmentSnapshot, dirName: staging)
                } catch {
                    DraftAttachmentStorage.deleteAttachments(dirName: staging)
                    let exit: ComposeDraftGuards.AutoSaveExit = existingLoaded == nil
                        ? .firstSaveFailed : .updateSaveFailed
                    BackgroundSyncLogger.logDebug("[DraftStore] Auto-save attachment staging failed: \(error)")
                    finishAutoSave(exit)
                    return exit
                }
                stagingDirName = staging
            }
        } else {
            stagingDirName = nil
        }

        func finishAttachmentSnapshot(saveApplied: Bool) {
            guard attachmentSnapshot != nil else { return }
            switch ComposeDraftGuards.attachmentDisposition(
                saveApplied: saveApplied,
                stagingDir: stagingDirName,
                previousDir: previousDirName
            ) {
            case .deleteSuperseded(let dir), .deleteStaging(let dir):
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            case .noCleanup:
                break
            }
        }

        if var existing = existingLoaded {
            existing.toJSON = Draft.encodeStringArray(recipients.to)
            existing.ccJSON = Draft.encodeStringArray(recipients.cc)
            existing.bccJSON = Draft.encodeStringArray(recipients.bcc)
            existing.subject = subject
            existing.body = body
            // #915: the compose's current entry decides reply vs reply-all on every
            // save, as on Save and Send; a row loaded from the other entry under the
            // shared `reply:` key must not keep its old kind.
            existing.isReplyAll = draftIsReplyAll && !existing.isForward
            existing.editHistoryJSON = editHistJSON
            existing.updatedAt = now
            savedAccountId = existing.accountId
            let existingToSave = attachmentSnapshot == nil
                ? existing
                : ComposeDraftGuards.applyingAttachmentSnapshotDirectory(
                    stagingDirName, to: existing)
            let saveStart = Date()
            do {
                let result = try await cursor.admit { newEpoch, predecessor in
                    try await DraftStore.shared.saveAsync(
                        existingToSave,
                        epoch: newEpoch,
                        expectedPredecessor: predecessor)
                }
                guard result == .applied else {
                    finishAttachmentSnapshot(saveApplied: false)
                    finishAutoSave(.updateLostGeneration)
                    return .updateLostGeneration
                }
                finishAttachmentSnapshot(saveApplied: true)
                if DebugModeManager.isLoggingEnabled() {
                    let saveMs = Int(Date().timeIntervalSince(saveStart) * 1000)
                    BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: save (existing) took \(saveMs)ms draftKey=\(draftKey)")
                }
            }
            catch {
                finishAttachmentSnapshot(saveApplied: false)
                BackgroundSyncLogger.logDebug("[DraftStore] Auto-save failed: \(error)")
                finishAutoSave(.updateSaveFailed)
                return .updateSaveFailed
            }
        } else {
            // First save — need accountId. Use sender email from context to find account.
            let accountId: String? = try? await AppDatabase.dbPool.read { db in
                try Account.filter(sql: "emailAddress = ?", arguments: [ctx.senderEmail]).fetchOne(db)?.id
            }
            guard let aid = accountId else {
                finishAttachmentSnapshot(saveApplied: false)
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: exit (no account for first save) draftKey=\(draftKey)")
                }
                finishAutoSave(.noAccountForFirstSave)
                return .noAccountForFirstSave
            }
            savedAccountId = aid
            var draft = Draft(
                id: draftKey,
                accountId: aid,
                toJSON: Draft.encodeStringArray(recipients.to),
                ccJSON: Draft.encodeStringArray(recipients.cc),
                bccJSON: Draft.encodeStringArray(recipients.bcc),
                subject: subject,
                body: body,
                replyToId: draftReplyToId,
                isForward: ctx.mode.contains("forward"),
                editHistoryJSON: editHistJSON,
                createdAt: now,
                updatedAt: now
            )
            // T5.8 — stamp the reply target's durable ADDRESS beside its mutable PK,
            // from the SAME header both values were captured from. This is the FIRST
            // save of the row, so an unstamped row here would stay unstamped for the
            // draft's whole life (the update path preserves, it does not re-derive).
            draft.replyToProviderMessageId = draftReplyToProviderMessageId
            draft.replyToUidValidity = draftReplyToUidValidity
            draft.isReplyAll = draftIsReplyAll && !draft.isForward
            // Immutable copy for the escaping admission closure, mirroring the
            // `existingToSave` binding in the update branch above (a captured `var`
            // is a concurrency hazard, not merely a style point).
            let draftToSave = attachmentSnapshot == nil
                ? draft
                : ComposeDraftGuards.applyingAttachmentSnapshotDirectory(
                    stagingDirName, to: draft)
            let saveStart = Date()
            do {
                let result = try await cursor.admit { newEpoch, predecessor in
                    try await DraftStore.shared.saveAsync(
                        draftToSave,
                        epoch: newEpoch,
                        expectedPredecessor: predecessor)
                }
                guard result == .applied else {
                    finishAttachmentSnapshot(saveApplied: false)
                    finishAutoSave(.firstSaveLostGeneration)
                    return .firstSaveLostGeneration
                }
                finishAttachmentSnapshot(saveApplied: true)
                if DebugModeManager.isLoggingEnabled() {
                    let saveMs = Int(Date().timeIntervalSince(saveStart) * 1000)
                    BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: save (first) took \(saveMs)ms draftKey=\(draftKey)")
                }
            }
            catch {
                finishAttachmentSnapshot(saveApplied: false)
                BackgroundSyncLogger.logDebug("[DraftStore] Auto-save failed (first save): \(error)")
                finishAutoSave(.firstSaveFailed)
                return .firstSaveFailed
            }
        }

        // Queue server push via PendingOperation (crash-safe, retried on failure/launch).
        //
        // 🚨 R14-F3 — CONSUME THE VERDICT. This was a bare
        // `await AccountManager.shared.queueDraftSave(…)`; the producer is
        // `@discardableResult`, so `false` was silently thrown away here while the
        // ONLY other production caller (`ComposeView.saveDraftAndDismiss`) has
        // consumed it since R5. `false` means the Drafts-folder `MessageHeader`,
        // the `MessageBody` and the durable `.saveDraft` `PendingOperation` were
        // NOT minted, so the text this function just committed to `Draft` has no
        // route back to it and `SyncEngineMaintenance` eventually trims it —
        // see `ComposeDraftGuards.runCheckedDurableAutoSave` for the full argument
        // and for why NOT rolling the local row back is load-bearing.
        //
        // Surfaced through `finishAutoSave` above, which is this surface's own
        // failure channel and now the SHARED one: R15-FIX-1 routed the four earlier
        // failure exits of this function through the same signal, because leaving
        // them silent while only this one warned was `MIS-006` — the instance fixed,
        // the class left open.
        var admissionExit: ComposeDraftGuards.AutoSaveExit?
        if let savedAccountId {
            await ComposeDraftGuards.runCheckedDurableAutoSave(
                save: {
                    await AccountManager.shared.queueDraftSave(
                        draftId: draftKey, accountId: savedAccountId)
                },
                onAdmissionFailure: {
                    admissionExit = .durableAdmissionRefused
                    finishAutoSave(.durableAdmissionRefused)
                })
        }
        if DebugModeManager.isLoggingEnabled() {
            let totalMs = Int(Date().timeIntervalSince(entryTime) * 1000)
            BackgroundSyncLogger.logDebug("[DraftStore] autoSaveDraft: exit draftKey=\(draftKey) totalMs=\(totalMs)")
        }
        return admissionExit
    }

    // MARK: - Agent chat (non-compose mode) — uses completions API matching TB's agentConverse

    /// The label a running tool shows: the event's `display_label` (a server tool's comes from the
    /// backend, e.g. "Searching the web: <query>"; a client tool's from `ToolRegistry.activityLabel`),
    /// as Thunderbird's chat shows them (ADR-IOS-008), then the tool's name, then a generic one.
    /// A finished tool shows `idleLabel`; any other event leaves the status as it is (nil).
    static func statusLabel(for event: CompletionsSSEEvent, idleLabel: String) -> String? {
        switch event {
        case .toolStarted(let status):
            status.display_label ?? status.tool_name ?? "Processing"
        case .toolCompleted:
            idleLabel
        default:
            nil
        }
    }

    /// Minimum time (seconds) each status is displayed before the next one takes over.
    private static let statusTickInterval: TimeInterval = 2.0

    /// Build the SSE event handler closure used by all completions calls in this view.
    /// Centralizes label resolution, throttle handling, and the "between tools" idle
    /// status so compose-edit and agent chat can never drift apart on event handling.
    /// Both call sites use the same `idleLabel` ("Thinking...") so the working
    /// indicator — tool-call labels + idle status + throttle banner — renders
    /// identically in compose-edit mode and agent chat.
    private func makeCompletionsSSEHandler(
        idleLabel: String
    ) -> BackendClient.SSEEventHandler {
        let isReplyField = replyField != nil
        return { @Sendable event in
            Task { @MainActor in
                switch event {
                case .throttled:
                    isThrottled = true
                case .throttleEnded:
                    isThrottled = false
                default:
                    if let label = Self.statusLabel(for: event, idleLabel: idleLabel) {
                        enqueueStatus(isReplyField ? ChatReplyField.statusLine(label) : label)
                    }
                }
            }
        }
    }

    /// Enqueue a status change. If the current status was shown recently, buffer it
    /// and display on the next tick. This prevents fast tool transitions from flashing.
    private func enqueueStatus(_ newStatus: String) {
        let elapsed = Date().timeIntervalSince(lastStatusChangeTime)
        if elapsed >= Self.statusTickInterval {
            // Enough time has passed — show immediately
            workingStatus = newStatus
            lastStatusChangeTime = Date()
            // Clear any pending queue items since we're showing a newer status
            statusQueue.removeAll()
        } else {
            // Buffer it — replace any pending item (we only care about the latest)
            statusQueue = [newStatus]
            startStatusTickIfNeeded()
        }
    }

    /// Start a tick timer that drains the status queue after the remaining interval.
    private func startStatusTickIfNeeded() {
        guard statusTickTask == nil else { return }
        let task = Task { @MainActor in
            while !statusQueue.isEmpty {
                let elapsed = Date().timeIntervalSince(lastStatusChangeTime)
                let remaining = max(Self.statusTickInterval - elapsed, 0)
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }
                guard !Task.isCancelled, !statusQueue.isEmpty else { break }
                let next = statusQueue.removeLast()
                statusQueue.removeAll() // Only show the most recent
                workingStatus = next
                lastStatusChangeTime = Date()
            }
            // Only clear if we're still the active tick task (prevents race with resetStatusQueue)
            if statusTickTask != nil, !Task.isCancelled {
                statusTickTask = nil
            }
        }
        statusTickTask = task
    }

    /// Reset the status queue (called when work finishes).
    private func resetStatusQueue() {
        statusQueue.removeAll()
        statusTickTask?.cancel()
        statusTickTask = nil
        workingStatus = ""
        isThrottled = false
        lastStatusChangeTime = .distantPast
    }

    /// The [Email](N) number a send names: the pill's email as the send starts, else the number
    /// already known (a resumed session's email). Never a number found for another email.
    static func contextNumber(sendingAbout message: MessageHeader?, known: Int?) async -> Int? {
        guard let message else { return known }
        return await ChatIdTranslator.shared.toNumericId(message.id)
    }

    /// `script`: a guided-tutorial prompt, answered by `TutorialChatScript`
    /// on the device instead of the AI.
    /// `field`: the reply field's send as it started; nil for a send from the panel.
    /// `ownsFieldWords`: the send is the field's open send, so its card, answer and sent compose
    /// complete the field's words (`fieldWordsKey`). A sheet Re-send of an answered turn carries the
    /// turn's `field` (its email and Reply to choice) but owns no words: its own send completed when
    /// it was answered, and words open by then belong to a newer send.
    func sendAgentChat(
        _ text: String, script: TutorialCoordinator.ChatPrompt? = nil, field: ChatFieldSend? = nil, ownsFieldWords: Bool = true
    ) {
        // If on the "new session" page in multi-session mode, start a fresh session
        if hasSessionHistory, activeSessionIndex < loadedSessions.count,
           loadedSessions[activeSessionIndex].id == "__new__" {
            // Snapshot current live session's turns + reminders before switching
            if let sid = currentSessionId, let liveIdx = loadedSessions.firstIndex(where: { $0.id == sid }) {
                let snapshot = ChatStore.ChatSession(
                    id: sid, turns: sessionTurns, lastActivity: Date(), remindersSnapshot: nil, emailContext: sessionEmailContexts[sid]
                )
                loadedSessions[liveIdx] = snapshot
                cachedSessionMessages[sid] = messagesForSession(snapshot)
                sessionReminderSnapshots[sid] = activeReminders
            }
            chatMessages = []
            sessionTurns = []
            currentSessionId = nil
            lastFailedSend = nil
        }
        // If viewing a past session, adopt its context before sending
        else if !isOnLiveSession, activeSessionIndex < loadedSessions.count {
            // Snapshot current live session before switching (so swiping back shows latest state)
            if let sid = currentSessionId, let liveIdx = loadedSessions.firstIndex(where: { $0.id == sid }) {
                let snapshot = ChatStore.ChatSession(
                    id: sid, turns: sessionTurns, lastActivity: Date(), remindersSnapshot: nil, emailContext: sessionEmailContexts[sid]
                )
                loadedSessions[liveIdx] = snapshot
                cachedSessionMessages[sid] = messagesForSession(snapshot)
                // Snapshot uses existing frozen reminders if available, else Buffer 1
                if sessionReminderSnapshots[sid] == nil {
                    sessionReminderSnapshots[sid] = activeReminders
                }
            }
            let oldSession = loadedSessions[activeSessionIndex]
            currentSessionId = oldSession.id
            sessionTurns = oldSession.turns
            // Use cached messages (stable UUIDs) — fall back to fresh computation
            chatMessages = cachedSessionMessages.removeValue(forKey: oldSession.id) ?? messagesForSession(oldSession)
        }

        // Generate a sessionId for this session if not yet created.
        // Message-detail: the thread's key, "thread:{accountId}:{threadId}" (ADR-IOS-114).
        // Inbox: random UUID (new session each time).
        // In demo mode every sessionId gets the "demo:" prefix (via
        // scopedSessionId) so demo turns are wiped on exit and never mix with
        // the user's session history.
        if currentSessionId == nil {
            if let msg = message {
                currentSessionId = DemoModeStore.scopedSessionId(ChatThreadKey.key(for: msg))
            } else {
                currentSessionId = DemoModeStore.scopedSessionId(UUID().uuidString)
            }
            // In multi-session mode: transform __new__ into live, append new __new__
            if hasSessionHistory, activeSessionIndex < loadedSessions.count,
               loadedSessions[activeSessionIndex].id == "__new__" {
                loadedSessions[activeSessionIndex] = ChatStore.ChatSession(
                    id: currentSessionId!, turns: [], lastActivity: Date(), remindersSnapshot: nil, emailContext: nil
                )
                loadedSessions.append(ChatStore.ChatSession(
                    id: "__new__", turns: [], lastActivity: .distantFuture, remindersSnapshot: nil, emailContext: nil
                ))
            }
        }

        // Snapshot reminders on first message for this session — freezes them for this session page.
        // After this, the session page shows the snapshot; Buffer 1 is free for the __new__ page.
        // Also encode for persistence so past sessions show their reminders after restart.
        var remindersSnapshotJSON: String?
        if isInboxChat, let sid = currentSessionId,
           sessionReminderSnapshots[sid] == nil {
            sessionReminderSnapshots[sid] = activeReminders
            remindersSnapshotJSON = ChatStore.encodeRemindersSnapshot(activeReminders)
            // Buffer 1 is now free (live session reads from snapshot).
            // Swap Buffer 2 → Buffer 1 so the new __new__ page shows fresh reminders,
            // then kick off a new Buffer 2 fetch.
            if let buffered = nextReminders {
                activeReminders = buffered
                nextReminders = nil
            }
            Task {
                nextReminders = await ReminderBuilder.getRandomReminders(count: 3, force: true)
            }
        }

        // Snapshot email context on first message for message-detail sessions.
        // Persists which email was being discussed so past sessions show context.
        var emailContextJSON: String?
        if let msg = message, let sid = currentSessionId,
           sessionEmailContexts[sid] == nil {
            let ctx = EmailContextSnapshot(messageHeaderId: msg.id, subject: msg.subject, from: msg.from)
            sessionEmailContexts[sid] = ctx
            emailContextJSON = ChatStore.encodeEmailContext(ctx)
        }

        // Show only the user's raw text in chat bubble (not the enriched prefix)
        chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date(), fieldSend: field))
        isWorking = true
        ActiveAgentTracker.shared.setWorking(sessionKey)
        resetStatusQueue()
        // A scripted tutorial request names its own work (it runs no tools that would).
        if let status = script?.workingStatus { enqueueStatus(status) }
        lastFailedSend = nil
        pendingResume = nil  // a fresh send abandons any interrupted turn
        lastChatActivity = Date()

        let sid = currentSessionId
        // Captured with the session id: a demo turn is written only while its demo runs.
        let admission = DemoModeStore.shared.chatAdmission
        let capturedSessionKey = sessionKey
        // Sent from the reply field: the request carries the field's send as it started, and the
        // chat key its words were sent under, where its card, answer and sent compose land
        // (ADR-IOS-117), whichever chat this pill shows by then, and whether or not it still exists.
        let fieldReply = field?.fieldReply
        let fieldWordsKey = ownsFieldWords ? field.map { ChatFieldWords.key(for: $0.message) } : nil
        // The screen whose chat asked, where a compose card the turn asks for opens.
        let origin = composeOrigin(sessionKey: capturedSessionKey, fieldReply: fieldReply)

        activeChatTask = Task {
            // Ensure email context is registered before building enrichedText.
            // Covers three cases:
            // 1. Live message-detail session — message is non-nil, register from it
            // 2. Resumed past message-detail session from inbox — message is nil but
            //    sessionEmailContexts has the snapshot, register from it (avoids race
            //    with fire-and-forget Task that was previously used)
            // 3. Inbox session — neither applies, enrichedText = raw text
            // The email this send is about is the pill's email as the send starts: the chat view's
            // newest email changes while its pill stays mounted, so a number found for an earlier
            // email is never reused, and the send reads its own copy, which a late registration
            // from an earlier open cannot overwrite.
            var contextNumericId = await Self.contextNumber(sendingAbout: field?.message ?? message, known: contextEmailNumericId)
            if message != nil {
                contextEmailNumericId = contextNumericId
            } else if contextNumericId == nil, let sid = sid,
                      let emailCtx = sessionEmailContexts[sid] {
                // Resuming past msg-detail session from inbox. The messageHeaderId may be stale
                // (IMAP MOVE changes PKs). Resolve to current PK before registering.
                let resolvedId = try? await ChatStore.shared.resolveMessageHeaderId(
                    originalId: emailCtx.messageHeaderId,
                    sessionId: sid
                )
                if let resolvedId {
                    // Remap old PK → current PK so old pills in loaded turns still work
                    if resolvedId != emailCtx.messageHeaderId {
                        _ = await ChatIdTranslator.shared.remapRealId(
                            from: emailCtx.messageHeaderId, to: resolvedId
                        )
                    }
                    contextNumericId = await ChatIdTranslator.shared.toNumericId(resolvedId)
                    contextEmailNumericId = contextNumericId
                    BackgroundSyncLogger.logDebug("[DynamicIslandChat] Restored email context for resumed session: \(emailCtx.subject)")
                }
            }

            // Build enrichedText INSIDE Task block (after awaiting registration)
            let enrichedText: String
            if let numericId = contextNumericId, let field {
                enrichedText = ChatReplyField.agentMessage(
                    emailNumericId: numericId, text: text, isNoReply: field.isNoReply,
                    onlyTo: field.onlyTo)
            } else if let numericId = contextNumericId {
                enrichedText = "Regarding [Email](\(numericId)): \(text)"
            } else {
                enrichedText = text
            }

            // The history this request sends. About an email: the thread's whole chat, every
            // key's stored turns merged by time within the budget (ADR-IOS-114), read before
            // this turn is added. Inbox: this session's turns.
            let history: [ChatTurn]
            if let msg = message {
                let keys = await ThreadChatReader.keys(about: msg)
                await ThreadChatReader.load(keys: keys)
                history = ThreadChatReader.history(keys: keys)
            } else {
                history = sessionTurns
            }

            // Step 1: Persist user turn (crash resilience: persist BEFORE network call).
            // renderedContent stores the user's raw text (without the enriched prefix)
            // so ChatHistoryView doesn't show "Regarding [Email](N):".
            let userTurn = ChatTurn(
                id: ChatTurn.generateId(),
                timestamp: Date().timeIntervalSince1970 * 1000,
                role: "user",
                content: "chat_converse",
                userMessage: enrichedText,
                type: "normal",
                chars: enrichedText.count,
                renderedContent: enrichedText != text ? text : nil,
                sessionId: sid,
                remindersSnapshot: remindersSnapshotJSON,
                emailContextJSON: emailContextJSON,
                thinkingContent: nil
            )
            if let evicted = await session.appendTurn(userTurn, admission: admission) {
                let userRefs = ChatIdTranslator.collectRefsFromTurn(userTurn)
                await ChatIdTranslator.shared.registerTurnRefs(userRefs)
                if !evicted.isEmpty {
                    await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                }
            }

            // Step 2: Send via completions API with the history read above.
            // No expired/archived history from past inbox sessions.
            sessionTurns.append(userTurn)

            do {
                // Owned UI delivery (ADR-IOS-053): bind the confirmation channel to
                // THIS session so any FSM tool's card is delivered to (and rendered
                // by) the session that launched the turn — never a global slot that
                // other mounted pills race for.
                let invocation = ToolInvocation(
                    uiSink: SessionUISink(session: session, fieldWordsKey: fieldWordsKey), sessionKey: sessionKey,
                    fieldReply: fieldReply, composeOrigin: origin, fieldWordsKey: fieldWordsKey)
                let response: ChatResponse?
                response = try await TutorialChatScript.response(for: script, invocation: invocation) {
                    try await ChatPillState.shared.aiService.sendChatMessage(
                        userText: enrichedText,
                        history: history,
                        onSSEEvent: makeCompletionsSSEHandler(idleLabel: "Thinking..."),
                        invocation: invocation
                    )
                }

                let replyText = response?.text ?? "I couldn't generate a response. Please try again."
                if response == nil {
                    BackgroundSyncLogger.logChatError("Empty/nil response from LLM", userMessage: text)
                } else if script == nil {
                    confirmSubscriptionActive()
                }
                BackgroundSyncLogger.logDebug("[AIChatDebug] Raw LLM response (\(replyText.count) chars): \(replyText.prefix(300))")
                if replyText.contains("[Email]") {
                    BackgroundSyncLogger.logDebug("[AIChatDebug] Response contains [Email] pattern — pills should render")
                }

                // Rendered text with pills resolved — used for both persistence and display.
                // Resolving once here avoids a redundant actor hop in MarkdownChatText.
                var displayText = replyText

                // Only persist real assistant responses (not client-generated fallbacks).
                // Dangling user turns are harmless — LLM sees the unanswered question next time.
                if response != nil {
                    BackgroundSyncLogger.logDebug("[AIChatRender] step 1/5: processResponseForDisplay START")
                    // Generate rendered snapshot with pills resolved (subjects baked in).
                    // This survives across sessions even after ChatIdTranslator is cleared.
                    // Matches TB's _rendered HTML snapshot approach.
                    let rendered = await ChatIdTranslator.shared.processResponseForDisplay(replyText)
                    displayText = rendered
                    BackgroundSyncLogger.logDebug("[AIChatRender] step 2/5: processResponseForDisplay DONE (\(rendered.count) chars)")

                    let assistantTurn = ChatTurn(
                        id: ChatTurn.generateId(),
                        timestamp: Date().timeIntervalSince1970 * 1000,
                        role: "assistant",
                        content: replyText,
                        userMessage: nil,
                        type: "normal",
                        chars: replyText.count,
                        renderedContent: rendered != replyText ? rendered : nil,
                        sessionId: sid,
                        remindersSnapshot: nil,
                        emailContextJSON: nil,
                        thinkingContent: response?.thinking
                    )
                    // Add to current session history for multi-turn
                    sessionTurns.append(assistantTurn)

                    BackgroundSyncLogger.logDebug("[AIChatRender] step 3/5: persisting turn to chatStore...")
                    if let evicted = await session.appendTurn(assistantTurn, admission: admission) {
                        BackgroundSyncLogger.logDebug("[AIChatRender] step 3a: appendTurn done, evicted=\(evicted.count)")
                        let assistantRefs = ChatIdTranslator.collectRefsFromTurn(assistantTurn)
                        await ChatIdTranslator.shared.registerTurnRefs(assistantRefs)
                        if !evicted.isEmpty {
                            await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                        }
                    }
                    BackgroundSyncLogger.logDebug("[AIChatRender] step 4/5: persistence complete")
                }

                // Guard: if user already pressed stop, don't append result
                guard !Task.isCancelled else { return }

                BackgroundSyncLogger.logDebug("[AIChatRender] step 5/5: appending to chatMessages (count=\(chatMessages.count))...")
                // Store pre-rendered text (pills already resolved) — MarkdownChatText
                // parses it synchronously without a redundant actor hop.
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: displayText,
                    timestamp: Date(),
                    animate: true
                ))
                BackgroundSyncLogger.logDebug("[AIChatRender] chatMessages appended (count=\(chatMessages.count)), about to set isWorking=false")
                // The agent answered the field's send: it completes on the send's own chat key.
                if let fieldWordsKey {
                    ChatFieldWords.shared.apply(.answered, to: fieldWordsKey)
                    fieldSentText = nil
                }
                if !isExpanded {
                    if let onAgentReply {
                        // Parent view handles the toast (InboxView, ComposeView)
                        onAgentReply(displayText)
                    } else {
                        // No parent callback (e.g., MessageDetailView) — set pending response
                        // so InboxView can show a deep-linked toast when the user navigates back.
                        ActiveAgentTracker.shared.setPendingResponse(capturedSessionKey, text: displayText)
                        showAgentToast(displayText)
                    }
                }
            } catch {
                // Guard: if user pressed stop, stop button already handled UI
                guard !Task.isCancelled else { return }

                if Self.isSubscriptionError(error) {
                    chatMessages.append(ChatMessage(
                        role: .warning,
                        content: "Active subscription required. Go to TabMail Account to subscribe.",
                        timestamp: Date()
                    ))
                } else if let resumable = error as? ChatConnectionLostError {
                    // Cut off mid-turn. Arm the dedicated "tap to retry" affordance
                    // with the saved checkpoint — completed tool calls + prior thinking
                    // are preserved in its conversation_state. No hard error bubble, and
                    // no `lastFailedSend` (that's the separate fork/resend pathway). The field's
                    // request goes with it, for the resumed turn's tools.
                    BackgroundSyncLogger.logChatError("Connection lost (resumable): \(error.localizedDescription)", userMessage: text)
                    pendingResume = .init(
                        request: resumable.resumeRequest, fieldReply: fieldReply, origin: origin, fieldWordsKey: fieldWordsKey)
                } else {
                    // Connection/server error — enable retry
                    BackgroundSyncLogger.logChatError("Chat error: \(error.localizedDescription)", userMessage: text)
                    lastFailedSend = .init(text: text, field: field, ownsFieldWords: fieldWordsKey != nil)
                    chatMessages.append(ChatMessage(
                        role: .agent,
                        content: "Couldn't connect. (\(error.localizedDescription))",
                        timestamp: Date()
                    ))
                }
            }
            // Guard: stop button already cleaned up
            guard !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[AIChatRender] setting isWorking=false, activeChatTask=nil")
            activeChatTask = nil
            isWorking = false
            ActiveAgentTracker.shared.clearWorking(capturedSessionKey)
            resetStatusQueue()
            lastChatActivity = Date()
            BackgroundSyncLogger.logDebug("[AIChatRender] sendAgentChat complete")
        }
    }

    // MARK: - Subscription Error Detection

    /// Returns true if the error indicates the user needs an active subscription (402 or 403).
    private static func isSubscriptionError(_ error: any Error) -> Bool {
        if case BackendError.requestFailed(statusCode: 402) = error { return true }
        if case BackendError.forbidden = error { return true }
        return false
    }

    /// Reopen AI subscription gate on successful API response.
    private func confirmSubscriptionActive() {
        AISubscriptionGate.shared.openGate()
    }

    // MARK: - Connection-lost Resume

    /// Resume a turn that was cut off in transit (the catch above armed
    /// `pendingResume`). Re-enters the tool loop from the saved
    /// `conversation_state`, so every already-completed tool call and prior round's
    /// thinking is reused — nothing is re-executed and the user's message is NOT
    /// re-sent. This is intentionally separate from the fork/resend pathways
    /// (`resendLastUserMessage` / `rewindToMessage` / `forkFromMessage`), which
    /// restart from a user message via `sendAgentChat`.
    private func resumeAgentChat() {
        guard !isWorking, let resume = pendingResume else { return }
        pendingResume = nil  // hide the affordance; re-armed on failure
        isWorking = true
        ActiveAgentTracker.shared.setWorking(sessionKey)
        resetStatusQueue()
        lastChatActivity = Date()

        let sid = currentSessionId
        // Captured with the session id: a demo turn is written only while its demo runs.
        let admission = DemoModeStore.shared.chatAdmission
        let capturedSessionKey = sessionKey
        // The screen that asked when the turn was sent, and the account bound then: a resume
        // continues that turn, from whichever screen of the thread resumes it.
        let origin = resume.origin

        activeChatTask = Task {
            do {
                let response = try await ChatPillState.shared.aiService.resumeChatMessage(
                    request: resume.request,
                    onSSEEvent: makeCompletionsSSEHandler(idleLabel: "Thinking..."),
                    invocation: ToolInvocation(
                        uiSink: SessionUISink(session: session, fieldWordsKey: resume.fieldWordsKey), sessionKey: sessionKey,
                        fieldReply: resume.fieldReply, composeOrigin: origin, fieldWordsKey: resume.fieldWordsKey)
                )

                let replyText = response?.text ?? "I couldn't generate a response. Please try again."
                if response != nil { confirmSubscriptionActive() }

                // Guard: if user pressed stop, stop button already handled UI.
                guard !Task.isCancelled else { return }

                var displayText = replyText
                if response != nil {
                    let rendered = await ChatIdTranslator.shared.processResponseForDisplay(replyText)
                    displayText = rendered
                    let assistantTurn = ChatTurn(
                        id: ChatTurn.generateId(),
                        timestamp: Date().timeIntervalSince1970 * 1000,
                        role: "assistant",
                        content: replyText,
                        userMessage: nil,
                        type: "normal",
                        chars: replyText.count,
                        renderedContent: rendered != replyText ? rendered : nil,
                        sessionId: sid,
                        remindersSnapshot: nil,
                        emailContextJSON: nil,
                        thinkingContent: response?.thinking
                    )
                    sessionTurns.append(assistantTurn)
                    if let evicted = await session.appendTurn(assistantTurn, admission: admission) {
                        let assistantRefs = ChatIdTranslator.collectRefsFromTurn(assistantTurn)
                        await ChatIdTranslator.shared.registerTurnRefs(assistantRefs)
                        if !evicted.isEmpty {
                            await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: displayText,
                    timestamp: Date(),
                    animate: true
                ))
                if let fieldWordsKey = resume.fieldWordsKey {
                    ChatFieldWords.shared.apply(.answered, to: fieldWordsKey)
                    fieldSentText = nil
                }
                if !isExpanded {
                    if let onAgentReply {
                        onAgentReply(displayText)
                    } else {
                        ActiveAgentTracker.shared.setPendingResponse(capturedSessionKey, text: displayText)
                        showAgentToast(displayText)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isSubscriptionError(error) {
                    chatMessages.append(ChatMessage(
                        role: .warning,
                        content: "Active subscription required. Go to TabMail Account to subscribe.",
                        timestamp: Date()
                    ))
                } else if let resumable = error as? ChatConnectionLostError {
                    // Cut off again — keep the affordance armed with the latest checkpoint.
                    BackgroundSyncLogger.logChatError("Connection lost again (resumable)", userMessage: "(resumed)")
                    pendingResume = .init(
                        request: resumable.resumeRequest, fieldReply: resume.fieldReply, origin: resume.origin,
                        fieldWordsKey: resume.fieldWordsKey)
                } else {
                    // Non-transient failure — surface it; the user's message still has
                    // the fork/resend context menu for a fresh attempt.
                    BackgroundSyncLogger.logChatError("Resume failed: \(error.localizedDescription)", userMessage: "(resumed)")
                    chatMessages.append(ChatMessage(
                        role: .agent,
                        content: "Couldn't connect. (\(error.localizedDescription))",
                        timestamp: Date()
                    ))
                }
            }
            guard !Task.isCancelled else { return }
            activeChatTask = nil
            isWorking = false
            ActiveAgentTracker.shared.clearWorking(capturedSessionKey)
            resetStatusQueue()
            lastChatActivity = Date()
        }
    }

    // MARK: - Re-send / Fork

    /// Shared trim for "re-send last user message": drop everything from `index` down, and pop
    /// the trailing user+assistant pair from `sessionTurns` + GRDB so the next send re-persists.
    private func trimForResendLast(atIndex index: Int) {
        if index + 1 < chatMessages.count {
            chatMessages.removeSubrange((index + 1)...)
        }
        if index < chatMessages.count {
            chatMessages.remove(at: index)
        }
        var turnIdsToDelete: [String] = []
        if let lastAssistant = sessionTurns.last, lastAssistant.role == "assistant" {
            turnIdsToDelete.append(lastAssistant.id)
            sessionTurns.removeLast()
        }
        if let lastUser = sessionTurns.last, lastUser.role == "user" {
            turnIdsToDelete.append(lastUser.id)
            sessionTurns.removeLast()
        }
        if !turnIdsToDelete.isEmpty {
            Task { await session.deleteTurns(ids: turnIdsToDelete) }
        }
    }

    /// Shared trim for "rewind to earlier user message": drop everything from `index` onward,
    /// truncate `sessionTurns` + GRDB. Returns the count of user messages that remain — callers
    /// that track parallel state (e.g. compose `editHistory`) use it to align truncation.
    @discardableResult
    private func trimForRewind(atIndex index: Int) -> Int {
        if index < chatMessages.count {
            chatMessages.removeSubrange(index...)
        }
        // Each exchange = 1 user turn + 1 assistant turn (in order).
        let userMessagesBefore = chatMessages.filter { $0.role == .user }.count
        let turnsCutoff = min(userMessagesBefore * 2, sessionTurns.count)
        let turnsToDelete = Array(sessionTurns.suffix(from: turnsCutoff))
        if !turnsToDelete.isEmpty {
            let idsToDelete = turnsToDelete.map(\.id)
            Task { await session.deleteTurns(ids: idsToDelete) }
        }
        sessionTurns = Array(sessionTurns.prefix(turnsCutoff))
        return userMessagesBefore
    }

    /// Re-send the last user message (same session). Removes the agent response/error below it.
    /// Sent from the reply field, it is sent again with its email and who the user chose in Reply
    /// to (`field`, read from its bubble before the trim), as Retry does, but it owns none of the
    /// field's words (`ownsFieldWords`): the turn was answered, so its send is complete.
    private func resendLastUserMessage(text: String, field: ChatFieldSend?, afterIndex index: Int) {
        trimForResendLast(atIndex: index)
        lastFailedSend = nil
        sendAgentChat(text, field: field, ownsFieldWords: false)
    }

    /// Rewind chat to an earlier user message (message-detail context).
    /// Truncates everything from that message onward and resends it in the same session.
    /// Unlike `forkFromMessage`, this stays in the same session — no new session is created.
    private func rewindToMessage(text: String, atIndex index: Int) {
        trimForRewind(atIndex: index)
        lastFailedSend = nil
        sendAgentChat(text)
    }

    /// Re-send the last compose-edit instruction. In addition to the standard trim, this rolls
    /// the draft back to the pre-edit snapshot (if the prior edit succeeded and mutated the
    /// draft) and pops the trailing `editHistory` entry so the LLM history matches state.
    private func resendLastUserComposeEdit(text: String, afterIndex index: Int) {
        guard acquireComposeEditAdmission() else { return }
        trimForResendLast(atIndex: index)
        let replay = Self.resendAnchor(editHistory)
        let anchor = replay.anchor
        editHistory = replay.history
        // The request restores the anchor's draft first (`sendComposeEdit(from:)`).
        sendComposeEdit(text, agentAdmissionAcquired: true, from: anchor)
    }

    /// Rewind compose-edit chat to an earlier user message. In addition to the standard trim,
    /// this rolls the draft back to the snapshot captured at that turn and truncates
    /// `editHistory`.
    private func rewindComposeEditToMessage(text: String, atIndex index: Int) {
        guard acquireComposeEditAdmission() else { return }
        let userMessagesBefore = trimForRewind(atIndex: index)
        // Snapshot on the earliest popped editHistory entry is the pre-edit draft for that turn.
        let replay = Self.rewindAnchor(editHistory, userMessagesBefore: userMessagesBefore)
        let anchor = replay.anchor
        editHistory = replay.history
        // The request restores the anchor's draft first (`sendComposeEdit(from:)`).
        sendComposeEdit(text, agentAdmissionAcquired: true, from: anchor)
    }

    /// Fork a new session from an earlier user message. Creates a new session on the __new__
    /// page with the conversation history before that message as API context.
    /// Preserves all messages above the fork point (including frozen reminders) in the new session.
    private func forkFromMessage(text: String, atIndex index: Int, sourceMessages: [ChatMessage]? = nil, sourceTurns: [ChatTurn]? = nil, sourceReminders: [Reminder]? = nil) {
        let msgs = sourceMessages ?? chatMessages
        let turns = sourceTurns ?? sessionTurns
        // Count user messages before the selected one to find the sessionTurns cutoff.
        // Each exchange = 1 user turn + 1 assistant turn (in order).
        let userMessagesBeforeIndex = msgs[..<index].filter { $0.role == .user }.count
        let turnsCutoff = min(userMessagesBeforeIndex * 2, turns.count)
        let contextTurns = Array(turns.prefix(turnsCutoff))

        // Capture messages above the fork point to carry over to the new session
        let messagesAbove = Array(msgs[..<index])

        // Capture reminders to carry over: use source reminders (history fork) or active reminders (live fork)
        let remindersToCarry = sourceReminders ?? activeReminders

        // Snapshot current live session into loadedSessions (including reminders)
        if let sid = currentSessionId {
            let snapshot = ChatStore.ChatSession(
                id: sid, turns: sessionTurns, lastActivity: Date(), remindersSnapshot: nil, emailContext: sessionEmailContexts[sid]
            )
            if let liveIdx = loadedSessions.firstIndex(where: { $0.id == sid }) {
                loadedSessions[liveIdx] = snapshot
            } else {
                // Single-session mode or session not yet in list — insert before __new__
                let insertIdx = loadedSessions.firstIndex(where: { $0.id == "__new__" }) ?? loadedSessions.count
                loadedSessions.insert(snapshot, at: insertIdx)
            }
            cachedSessionMessages[sid] = messagesForSession(snapshot)
            if sessionReminderSnapshots[sid] == nil {
                sessionReminderSnapshots[sid] = activeReminders
            }
            // Buffer 1 is now free — swap Buffer 2 in and start fresh fetch
            if let buffered = nextReminders {
                activeReminders = buffered
                nextReminders = nil
            }
            Task {
                nextReminders = await ReminderBuilder.getRandomReminders(count: 3, force: true)
            }
        }

        // Switch to __new__ page if available, otherwise create new session in place
        if let newIdx = loadedSessions.firstIndex(where: { $0.id == "__new__" }) {
            activeSessionIndex = newIdx
        }

        // Start forked session with messages above preserved and old turns as API context
        chatMessages = messagesAbove
        currentSessionId = nil
        lastFailedSend = nil
        sessionTurns = contextTurns

        // Transform __new__ into live session.
        // Demo-prefixed via scopedSessionId — fork must honor the same
        // invariant as sendMessage's mint, or forked demo turns escape the
        // demo: namespace (never wiped, leak into real session history).
        if hasSessionHistory, activeSessionIndex < loadedSessions.count,
           loadedSessions[activeSessionIndex].id == "__new__" {
            let newId = DemoModeStore.scopedSessionId(UUID().uuidString)
            currentSessionId = newId
            loadedSessions[activeSessionIndex] = ChatStore.ChatSession(
                id: newId, turns: [], lastActivity: Date(), remindersSnapshot: nil, emailContext: nil
            )
            loadedSessions.append(ChatStore.ChatSession(
                id: "__new__", turns: [], lastActivity: .distantFuture, remindersSnapshot: nil, emailContext: nil
            ))
            // Freeze carried-over reminders into the new forked session
            if !remindersToCarry.isEmpty {
                sessionReminderSnapshots[newId] = remindersToCarry
            }
        }

        fieldFill.apply(.put(text))
        isTextFieldFocused = true
    }

    // MARK: - Agent Toast

    private func showAgentToast(_ text: String) {
        agentToastDismiss?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            agentToast = text
        }
        agentToastDismiss = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissAgentToast()
        }
    }

    private func dismissAgentToast() {
        agentToastDismiss?.cancel()
        agentToastDismiss = nil
        withAnimation(.easeOut(duration: 0.25)) {
            agentToast = nil
        }
    }

}

/// Press-scale spring animation for the pill.
private struct ExpandablePillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The reply field's focus as an accessibility-only marker, for the chat swipe UI tests: XCUITest
/// reads a text field's own focus as lost once a swipe re-renders the chat, while editing goes on.
/// Active only in debug builds launched with the swipe UI test's argument (`--chat-swipe-ui-test`)
/// or the keyboard focus UI test's (`--keyboard-focus-ui-test`); it draws nothing (clear
/// text in the background, so no layout change) and is set as the field appears and when its focus
/// changes, so a field that appears with the keyboard (the panel's input, opened from the typed-in
/// reply field) reads focused at once.
private struct ReplyFieldFocusMarker: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        #if DEBUG
        if Marker.isActive {
            content.modifier(Marker(focused: focused))
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if DEBUG
    private struct Marker: ViewModifier {
        static let isActive = ["--chat-swipe-ui-test", "--keyboard-focus-ui-test"]
            .contains(where: ProcessInfo.processInfo.arguments.contains)
        let focused: Bool
        @State private var shown = false

        func body(content: Content) -> some View {
            content
                .background(
                    Text(shown ? "focused" : "unfocused")
                        .foregroundStyle(.clear)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("chatReplyFieldFocus"))
                .onChange(of: focused, initial: true) { _, now in shown = now }
        }
    }
    #endif
}
