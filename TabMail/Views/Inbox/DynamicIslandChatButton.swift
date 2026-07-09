/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Speech
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
    let composeContext: ComposeEditContext?
    let draftId: String?
    let draftReplyToId: String?  // MessageHeader.id of the email being replied to (for draft eviction)
    /// Skip writing LLM results to the `Draft` table — caller persists elsewhere.
    let skipDraftAutoSave: Bool
    @Binding var isExpanded: Bool
    @Binding var isInputFocused: Bool
    @Binding var isWorking: Bool
    var onDraftUpdate: ((String?, String?, RecipientDelta?, RecipientDelta?, RecipientDelta?) -> Void)?
    var onAgentReply: ((String) -> Void)?
    @Environment(\.hasTabMailSession) private var hasTabMailSession
    @State private var inputText = ""
    @State private var inputSelection: TextSelection?
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var autoStartTask: Task<Void, Never>?
    @State private var workingStatus = ""
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
    @FocusState private var isTextFieldFocused: Bool
    @AppStorage(ChatPillState.autoDictationKey) private var autoDictation = false
    @AppStorage(ChatPillState.dictationPromptShownKey) private var dictationPromptShown = false
    @State private var showDictationPrompt = false

    private var isComposeMode: Bool { composeContext != nil }
    private var isBackfillInProgress: Bool {
        AccountManagerState.shared.backfillProgressByAccount.values.contains { !$0.isFullyComplete }
    }

    // Session state lives in ChatPillState (survives SwiftUI view recreation).
    // Forwarding computed properties keep existing code unchanged.
    /// Stable key for the message, using stableId pattern (rfc822MessageId for IMAP,
    /// messageId for Gmail/Exchange). Falls back to message.id if stableId unavailable.
    /// This survives IMAP MOVE operations where UIDs change.
    private var stableMessageKey: String? {
        guard let msg = message else { return nil }
        return "\(msg.accountId):\(msg.stableId)"
    }

    private var sessionKey: String {
        if composeContext != nil { return "compose:\(draftId ?? "default")" }
        if let key = stableMessageKey { return "msg:\(key)" }
        return "inbox"
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
    private var lastFailedMessage: String? {
        get { session.lastFailedMessage }
        nonmutating set { session.lastFailedMessage = newValue }
    }
    /// Saved checkpoint for a turn cut off in transit — drives the "Connection
    /// lost. Tap to retry." affordance. Separate from `lastFailedMessage`.
    private var pendingResumeRequest: CompletionsRequest? {
        get { session.pendingResumeRequest }
        nonmutating set { session.pendingResumeRequest = newValue }
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
        !isComposeMode && message == nil && loadedSessions.count > 1
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
        composeContext: ComposeEditContext? = nil,
        draftId: String? = nil,
        draftReplyToId: String? = nil,
        skipDraftAutoSave: Bool = false,
        isExpanded: Binding<Bool>,
        isInputFocused: Binding<Bool> = .constant(false),
        isWorking: Binding<Bool> = .constant(false),
        onDraftUpdate: ((String?, String?, RecipientDelta?, RecipientDelta?, RecipientDelta?) -> Void)? = nil,
        onAgentReply: ((String) -> Void)? = nil
    ) {
        self.message = message
        self.draftSubject = draftSubject
        self.draftBody = draftBody
        self.composeContext = composeContext
        self.draftId = draftId
        self.draftReplyToId = draftReplyToId
        self.skipDraftAutoSave = skipDraftAutoSave
        self._isExpanded = isExpanded
        self._isInputFocused = isInputFocused
        self._isWorking = isWorking
        self.onDraftUpdate = onDraftUpdate
        self.onAgentReply = onAgentReply
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
                } else if !AISubscriptionGate.shared.isActive {
                    subscribeBar
                        .layoutPriority(1)
                } else {
                    expandedInputBar
                        .layoutPriority(1)
                }
            } else {
                collapsedPill
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: isExpanded ? 24 : 100))
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
        .keepScreenAwake(while: isExpanded || isWorking || ActiveAgentTracker.shared.anyWorking || speechRecognizer.isRecording)
        .onChange(of: isExpanded) { _, expanded in
            autoStartTask?.cancel()
            autoStartTask = nil
            if expanded {
                dismissAgentToast()
                // Opportunistic cleanup of idle in-memory sessions (5 min TTL).
                ChatPillState.shared.evictIdleSessions()
                // 30s idle clear: ONLY for inbox sessions. Message-detail and compose
                // sessions persist across pill opens (tied to their email/draft).
                if !isComposeMode && message == nil,
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
                            catch { print("[DynamicIslandChat] Failed to dereference expiring session: \(error)") }
                        }
                    }
                    // Snapshot reminders for the expiring session before clearing
                    if let sid = currentSessionId {
                        sessionReminderSnapshots[sid] = activeReminders
                    }
                    chatMessages = []
                    lastFailedMessage = nil
                    sessionTurns = []
                    currentSessionId = nil
                    // Clear stale email context from resumed message-detail sessions —
                    // without this, the next fresh inbox message would incorrectly get
                    // "Regarding [Email](N):" prefix from the expired session's context.
                    contextEmailNumericId = nil
                    print("[DynamicIslandChat] Session expired (>30s idle), cleared chat")
                }

                // Load session history on expand (inbox context only, once per open cycle).
                if !isComposeMode && message == nil {
                    loadSessionHistory()
                }

                // Message-detail: load existing session from GRDB if in-memory is empty.
                // This restores previous chat when reopening the same email.
                // Uses stableMessageKey (rfc822MessageId for IMAP) so chat survives folder moves.
                if let msg = message, chatMessages.isEmpty, let stableKey = stableMessageKey {
                    let msgSessionId = DemoModeStore.scopedSessionId("msg:\(stableKey)")
                    Task {
                        if let session = try? await ChatStore.shared.loadContextSession(sessionId: msgSessionId) {
                            if chatMessages.isEmpty { // Double-check (avoid race)
                                currentSessionId = msgSessionId
                                sessionTurns = session.turns
                                chatMessages = messagesForSession(session)
                                if let emailCtx = session.emailContext {
                                    sessionEmailContexts[msgSessionId] = emailCtx
                                    // If the message moved (IMAP MOVE → new PK), remap the
                                    // ChatIdTranslator entry so old pills point to the current PK.
                                    // Without this, old [Email](N) pills in loaded turns would
                                    // reference a dead PK, and new messages would get a different
                                    // numeric ID — causing inconsistent email references for the LLM.
                                    if emailCtx.messageHeaderId != msg.id {
                                        // Remap ChatIdTranslator so old pills point to current PK
                                        let remapped = await ChatIdTranslator.shared.remapRealId(
                                            from: emailCtx.messageHeaderId, to: msg.id
                                        )
                                        // Update in-memory context with current PK for future eviction
                                        let updatedCtx = EmailContextSnapshot(
                                            messageHeaderId: msg.id,
                                            subject: msg.subject,
                                            from: msg.from
                                        )
                                        sessionEmailContexts[msgSessionId] = updatedCtx
                                        // Update persisted emailContextJSON on first turn (best-effort)
                                        if let json = ChatStore.encodeEmailContext(updatedCtx),
                                           let firstTurnId = session.turns.first?.id {
                                            try? await AppDatabase.dbPool.write { db in
                                                try db.execute(
                                                    sql: "UPDATE chatTurn SET emailContextJSON = ? WHERE id = ?",
                                                    arguments: [json, firstTurnId]
                                                )
                                            }
                                        }
                                        if remapped > 0 {
                                            print("[DynamicIslandChat] Remapped email context: \(emailCtx.messageHeaderId) → \(msg.id)")
                                        }
                                    }
                                }
                                print("[DynamicIslandChat] Loaded msg-detail session from GRDB (\(session.turns.count) turns)")
                            }
                        }
                        // Register viewed email in ID mapping (MessageDetailView context).
                        // This ensures the email has a stable numeric ID for [Email](N) references.
                        // After remap above, toNumericId returns the SAME numeric ID as old turns.
                        contextEmailNumericId = await ChatIdTranslator.shared.toNumericId(msg.id)
                        print("[DynamicIslandChat] Registered context email id=\(msg.id) → numeric=\(contextEmailNumericId!)")
                    }
                } else if let msg = message {
                    // No session to load — just register the email ID for fresh sessions.
                    Task {
                        contextEmailNumericId = await ChatIdTranslator.shared.toNumericId(msg.id)
                        print("[DynamicIslandChat] Registered context email id=\(msg.id) → numeric=\(contextEmailNumericId!)")
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
                                print("[DynamicIslandChat] Loaded compose session from GRDB (\(session.turns.count) turns)")
                            }
                        }
                        // Also load edit history from draft
                        if let draft = try? DraftStore.shared.load(id: did) {
                            if editHistory.isEmpty {
                                editHistory = draft.editHistory
                                print("[DynamicIslandChat] Loaded edit history from draft (\(editHistory.count) turns)")
                            }
                        }
                    }
                }

                // Double buffer: swap Buffer 2 → Buffer 1 on expand (instant, no flicker).
                // Then pre-fetch a new Buffer 2 in the background for the next swap.
                // Once shown, Buffer 1 is stable until the next expand.
                if !isComposeMode && message == nil {
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

                if autoDictation {
                    // Pre-request permissions immediately (dialog shows during animation)
                    speechRecognizer.requestPermissions()
                    // Start dictation after animation fully settles + permissions resolve.
                    // Task is stored so collapse cancels it (prevents double beginRecording).
                    autoStartTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled, isExpanded, !isTextFieldFocused else { return }
                        let prefix = inputText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                        speechRecognizer.start { transcript in
                            inputText = prefix + transcript
                        }
                    }
                } else if !dictationPromptShown {
                    dictationPromptShown = true
                    showDictationPrompt = true
                }
            } else {
                speechRecognizer.stop()
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
        .onChange(of: isTextFieldFocused) { _, focused in
            isInputFocused = focused
            if focused {
                speechRecognizer.stop()
            }
        }
        .onChange(of: isWorking) { wasWorking, nowWorking in
            if DebugModeManager.isLoggingEnabled() {
                print("[DynamicIslandChat] dictation-auto-restart onChange(isWorking) fired: wasWorking=\(wasWorking) nowWorking=\(nowWorking)")
            }
            // Auto-restart dictation when the agent finishes its turn — same UX
            // as auto-start on pill open. Respects the autoDictation preference,
            // and skips if the user has the keyboard up or already dictating.
            guard wasWorking, !nowWorking else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[DynamicIslandChat] dictation-auto-restart: skip — not a working->idle transition")
                }
                return
            }
            guard autoDictation, isExpanded, !isTextFieldFocused else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[DynamicIslandChat] dictation-auto-restart: skip — autoDictation=\(autoDictation) isExpanded=\(isExpanded) isTextFieldFocused=\(isTextFieldFocused)")
                }
                return
            }
            guard !speechRecognizer.isRecording else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[DynamicIslandChat] dictation-auto-restart: skip — already recording")
                }
                return
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[DynamicIslandChat] dictation-auto-restart: scheduling delayed start (800ms)")
            }
            autoStartTask?.cancel()
            autoStartTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, isExpanded, !isTextFieldFocused else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[DynamicIslandChat] dictation-auto-restart: delayed task aborted — cancelled=\(Task.isCancelled) isExpanded=\(isExpanded) isTextFieldFocused=\(isTextFieldFocused)")
                    }
                    return
                }
                let prefix = inputText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                if DebugModeManager.isLoggingEnabled() {
                    print("[DynamicIslandChat] dictation-auto-restart: calling speechRecognizer.start")
                }
                speechRecognizer.start { transcript in
                    inputText = prefix + transcript
                }
            }
        }
        .task {
            guard !isComposeMode && message == nil else { return }
            await session.observeMessageReminders()
        }
        .onChange(of: PromptStore.shared.rawKB) { _, _ in
            // KB changed (user edit, Device Sync, agent tool) — triggers reminder regeneration
            guard !isComposeMode && message == nil else { return }
            regenerateReminders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remindersDidChange).receive(on: DispatchQueue.main)) { _ in
            // Reminder data changed (message count, dismiss/enable) — regenerate Buffer 2
            guard !isComposeMode && message == nil else { return }
            regenerateReminders()
        }
        .onChange(of: ActiveAgentTracker.shared.workingSessions) { _, sessions in
            if DebugModeManager.isLoggingEnabled() {
                print("[DynamicIslandChat] workingSessions onChange: sessionKey=\(sessionKey) matches=\(sessions.contains(sessionKey)) isWorking=\(isWorking) activeChatTaskNil=\(activeChatTask == nil) sessionsCount=\(sessions.count)")
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
            // Recording must never outlive its UI: if this pill vanishes while
            // dictating (host view dismissed/torn down), stop the mic and cancel
            // any pending auto-restart so it can't re-arm after removal
            // (2026-07-08: mic kept recording under a dismissed compose cover).
            autoStartTask?.cancel()
            autoStartTask = nil
            // Unconditional: stop() is idempotent when idle, and its generation
            // bump also invalidates an in-flight beginRecording (a start racing
            // this disappear) before it can commit the mic.
            speechRecognizer.stop()
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
                speechRecognizer.requestPermissions()
                autoStartTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled, isExpanded, !isTextFieldFocused else { return }
                    let prefix = inputText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                    speechRecognizer.start { transcript in
                        inputText = prefix + transcript
                    }
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
        HStack(spacing: 10) {
            Button {
                if speechRecognizer.isRecording {
                    speechRecognizer.stop()
                } else {
                    isTextFieldFocused = false
                    let prefix = inputText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                    speechRecognizer.start { transcript in
                        inputText = prefix + transcript
                    }
                }
            } label: {
                Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.title3)
                    .foregroundStyle(speechRecognizer.isRecording ? .red : Theme.accent)
                    .frame(width: 28, height: 28)
            }
            .disabled(isWorking)

            if speechRecognizer.isRecording {
                // Dictation mode: use ScrollView+Text because an unfocused TextField
                // ignores selection changes and won't scroll to show new text.
                // Tap anywhere to stop dictation and switch to keyboard editing.
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(inputText)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .id("dictationEnd")
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        speechRecognizer.stop()
                        isTextFieldFocused = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            inputSelection = .init(insertionPoint: inputText.endIndex)
                        }
                    }
                    .onChange(of: inputText) {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("dictationEnd", anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.identity)
            } else {
                TextField(isComposeMode ? "Describe your edit..." : "Type or speak...", text: $inputText, selection: $inputSelection, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isTextFieldFocused)
                    .transition(.identity)
            }

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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else if !isWorking && (pendingResumeRequest != nil || lastFailedMessage != nil) && isOnLiveSession && inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Retry button. Reverts to the send button as soon as the user types
                // (the `inputText.isEmpty` gate above). Routes to the right path:
                // a connection-lost RESUMES from saved state; a plain failure re-sends.
                Button {
                    if pendingResumeRequest != nil {
                        // Connection-lost: resume the interrupted turn (no re-execution
                        // of completed tools). Same action as the inline affordance.
                        resumeAgentChat()
                    } else if let msg = lastFailedMessage {
                        lastFailedMessage = nil
                        // Remove error bubble + user bubble, then re-send (matches TB retry)
                        if chatMessages.count >= 2 {
                            chatMessages.removeLast(2)
                        } else {
                            chatMessages.removeLast()
                        }
                        sendAgentChat(msg)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                // Normal send button
                Button {
                    speechRecognizer.stop()
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Theme.accent : .secondary.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(nil, value: isTextFieldFocused)
        .animation(nil, value: isWorking)
    }

    private var signInBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Sign in to TabMail for AI features")
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
                    messages: chatMessages,
                    isLive: true,
                    showIndexingWarning: true,
                    reminders: page.reminders,
                    canDismissReminders: page.canDismiss
                )
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !chatMessages.isEmpty {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if focused {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: chatMessages.count) {
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: isWorking) {
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: inputText) {
            // Dictation grows the input bar, shrinking the scroll view.
            // Defer scroll so layout settles before repositioning.
            if speechRecognizer.isRecording {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
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
                if showIndexingWarning && isBackfillInProgress && !isComposeMode && message == nil {
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
                if !reminders.isEmpty && !isComposeMode && message == nil {
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
                                if isLive {
                                    let hasLaterUserMsg = messages[(index + 1)...].contains { $0.role == .user }
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
                                            resendLastUserMessage(text: msg.content, afterIndex: index)
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
                                } else {
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
                if isLive && !isWorking && pendingResumeRequest != nil {
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
        session.turns.compactMap { turn -> ChatMessage? in
            switch turn.role {
            case "user":
                let displayText = turn.renderedContent ?? turn.userMessage ?? turn.content
                return ChatMessage(role: .user, content: displayText, timestamp: Date(timeIntervalSince1970: turn.timestamp / 1000))
            case "assistant":
                guard turn.type == "normal" || turn.type == "task_result" else { return nil }
                let displayText = turn.renderedContent ?? turn.content
                return ChatMessage(role: .agent, content: displayText, timestamp: Date(timeIntervalSince1970: turn.timestamp / 1000))
            default:
                return nil
            }
        }
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
                print("[DynamicIslandChat] Loaded \(sessions.count - 1) session(s) + new session page")
            } catch {
                print("[DynamicIslandChat] Failed to load session history: \(error)")
            }
        }
    }

    // MARK: - Logic

    private var canSend: Bool {
        hasTabMailSession && !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Dismiss keyboard focus first — stops any in-flight iOS keyboard
        // dictation that could push a final text update after we clear.
        // Then clear text field immediately. Defer remaining state changes to
        // the next tick so the TextField renders as empty before chatMessages /
        // isWorking changes trigger a parent re-render whose .animation()
        // modifier can leak into child views, briefly persisting the old text.
        isTextFieldFocused = false
        inputText = ""
        inputSelection = .init(insertionPoint: "".startIndex)

        Task { @MainActor in
            await ChatForkTip.chatMessageSent.donate()
            if isComposeMode {
                ComposeChatCollapseTip.hasStartedComposeChat = true
            } else if message != nil {
                MessageChatCollapseTip.hasStartedMessageChat = true
            } else {
                InboxChatCollapseTip.hasStartedInboxChat = true
            }
            if isComposeMode {
                sendComposeEdit(text)
            } else {
                sendAgentChat(text)
            }
        }
    }

    // MARK: - Compose inline edit

    private func sendComposeEdit(_ instruction: String) {
        guard let ctx = composeContext else {
            print("[DynamicIslandChat] sendComposeEdit: NO composeContext — aborting")
            return
        }

        // Capture current draft state from parent (values are up-to-date via SwiftUI re-render)
        let currentSubject = draftSubject ?? ""
        let currentBody = draftBody ?? ""
        // Snapshot — state may flip during the network round-trip.
        let skipSave = skipDraftAutoSave

        print("[DynamicIslandChat] sendComposeEdit START: instruction=\(instruction.prefix(60))")

        // Generate deterministic sessionId for compose (tied to draft).
        // Demo-prefixed while demo mode is active (wiped on demo exit).
        if currentSessionId == nil, let did = draftId {
            currentSessionId = DemoModeStore.scopedSessionId("compose:\(did)")
        }
        let sid = currentSessionId

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
        Task {
            do { try await ChatStore.shared.appendTurn(userTurn) }
            catch { print("[DynamicIslandChat] Failed to persist compose edit user turn: \(error)") }
        }
        sessionTurns.append(userTurn)

        // Unstructured timeout: cancel editTask if it takes >120s.
        let editTask = Task {
            try await AIService.shared.performInlineEdit(
                currentSubject: currentSubject,
                currentBody: currentBody,
                context: ctx,
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
            do {
                let result = try await editTask.value
                timeoutTask.cancel()

                // Guard: if user pressed stop, don't append result
                guard !Task.isCancelled else { return }

                // Update draft via callback (with animation)
                onDraftUpdate?(result.subject, result.body, result.toDelta, result.ccDelta, result.bccDelta)

                // Show conversational response as chat bubble
                let responseText = result.response ?? "Done."
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: responseText,
                    timestamp: Date(),
                    animate: true
                ))
                if !isExpanded {
                    // Always set pending response for compose — ComposeView may be
                    // dismissed by the time this fires, so onAgentReply goes nowhere.
                    // InboxView's observeAgentFinish picks it up as a toast.
                    ActiveAgentTracker.shared.setPendingResponse(sessionKey, text: "Draft updated — tap to review")
                    onAgentReply?(responseText)
                    if onAgentReply == nil {
                        showAgentToast(responseText)
                    }
                }

                // Record in edit history for continuous editing (with draft state)
                editHistory.append(InlineEditTurn(
                    userRequest: instruction,
                    bodyAtRequest: currentBody,
                    subjectAtRequest: currentSubject,
                    assistantResponse: result.raw
                ))

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
                Task {
                    do { try await ChatStore.shared.appendTurn(assistantTurn) }
                    catch { print("[DynamicIslandChat] Failed to persist compose edit assistant turn: \(error)") }
                }
                sessionTurns.append(assistantTurn)

                // Auto-save draft to GRDB (state after edit applied).
                if let did = draftId, !skipSave {
                    let updatedSubject = result.subject ?? currentSubject
                    let updatedBody = result.body ?? currentBody
                    if DebugModeManager.isLoggingEnabled() {
                        print("[DynamicIslandChat] sendComposeEdit: autoSaveDraft task fired draftKey=\(did) sessionKey=\(sessionKey)")
                    }
                    Task { await autoSaveDraft(draftKey: did, subject: updatedSubject, body: updatedBody) }
                }

                print("[DynamicIslandChat] Inline edit applied, editHistory=\(editHistory.count) turns")
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
                print("[DynamicIslandChat] sendComposeEdit completion: writing isWorking=false sessionKey=\(sessionKey)")
            }
            isWorking = false
            ActiveAgentTracker.shared.clearWorking(sessionKey)
            if DebugModeManager.isLoggingEnabled() {
                print("[DynamicIslandChat] sendComposeEdit completion: clearWorking called sessionKey=\(sessionKey)")
            }
        }
    }

    /// Auto-save the current draft state to GRDB for resume on reopen.
    private func autoSaveDraft(draftKey: String, subject: String, body: String) async {
        let entryTime = Date()
        if DebugModeManager.isLoggingEnabled() {
            print("[DraftStore] autoSaveDraft: enter draftKey=\(draftKey)")
        }
        guard let ctx = composeContext else {
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftStore] autoSaveDraft: exit (no composeContext) draftKey=\(draftKey)")
            }
            return
        }
        let editHistJSON = Draft.encodeEditHistory(editHistory)
        let now = Date().timeIntervalSince1970

        // Track accountId for PendingOperation queue after save
        var savedAccountId: String?

        // Try to load existing draft — mutate in place to preserve all fields
        // (especially v24 server sync: serverDraftId, serverPushStatus, rfc822MessageId, attachmentsDirName)
        let loadStart = Date()
        let existingLoaded = try? DraftStore.shared.load(id: draftKey)
        if DebugModeManager.isLoggingEnabled() {
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            print("[DraftStore] autoSaveDraft: load took \(loadMs)ms found=\(existingLoaded != nil) draftKey=\(draftKey)")
        }
        if var existing = existingLoaded {
            existing.subject = subject
            existing.body = body
            existing.editHistoryJSON = editHistJSON
            existing.updatedAt = now
            savedAccountId = existing.accountId
            let saveStart = Date()
            do {
                try DraftStore.shared.save(existing)
                if DebugModeManager.isLoggingEnabled() {
                    let saveMs = Int(Date().timeIntervalSince(saveStart) * 1000)
                    print("[DraftStore] autoSaveDraft: save (existing) took \(saveMs)ms draftKey=\(draftKey)")
                }
            }
            catch { print("[DraftStore] Auto-save failed: \(error)"); return }
        } else {
            // First save — need accountId. Use sender email from context to find account.
            let accountId: String? = try? await AppDatabase.dbPool.read { db in
                try Account.filter(sql: "emailAddress = ?", arguments: [ctx.senderEmail]).fetchOne(db)?.id
            }
            guard let aid = accountId else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[DraftStore] autoSaveDraft: exit (no account for first save) draftKey=\(draftKey)")
                }
                return
            }
            savedAccountId = aid
            let draft = Draft(
                id: draftKey,
                accountId: aid,
                toJSON: Draft.encodeStringArray(ctx.recipients),
                ccJSON: "[]",
                bccJSON: "[]",
                subject: subject,
                body: body,
                replyToId: draftReplyToId,
                isForward: ctx.mode.contains("forward"),
                editHistoryJSON: editHistJSON,
                createdAt: now,
                updatedAt: now
            )
            let saveStart = Date()
            do {
                try DraftStore.shared.save(draft)
                if DebugModeManager.isLoggingEnabled() {
                    let saveMs = Int(Date().timeIntervalSince(saveStart) * 1000)
                    print("[DraftStore] autoSaveDraft: save (first) took \(saveMs)ms draftKey=\(draftKey)")
                }
            }
            catch { print("[DraftStore] Auto-save failed (first save): \(error)"); return }
        }

        // Queue server push via PendingOperation (crash-safe, retried on failure/launch).
        if let savedAccountId {
            await AccountManager.shared.queueDraftSave(draftId: draftKey, accountId: savedAccountId)
        }
        if DebugModeManager.isLoggingEnabled() {
            let totalMs = Int(Date().timeIntervalSince(entryTime) * 1000)
            print("[DraftStore] autoSaveDraft: exit draftKey=\(draftKey) totalMs=\(totalMs)")
        }
    }

    // MARK: - Agent chat (non-compose mode) — uses completions API matching TB's agentConverse

    /// Human-readable label for a tool name (e.g., "inbox_read" → "Reading inbox").
    private static let toolDisplayLabels: [String: String] = [
        "inbox_read": "Reading inbox",
        "email_read": "Reading email",
        "email_search": "Searching emails",
        "email_compose": "Composing email",
        "email_reply": "Composing reply",
        "email_forward": "Forwarding email",
        "email_archive": "Archiving emails",
        "email_delete": "Deleting emails",
        "memory_search": "Searching memory",
        "memory_read": "Reading memory",
        "search_web": "Searching web",
        "web_read": "Reading webpage",
        "date_to_day": "Checking date",
        "calendar_read": "Reading calendar",
        "calendar_search": "Searching calendar",
        "calendar_event_read": "Reading event",
        "calendar_event_create": "Creating event",
        "calendar_event_edit": "Editing event",
        "calendar_event_delete": "Deleting event",
        "contacts_search": "Searching contacts",
        "contacts_add": "Adding contact",
        "contacts_edit": "Editing contact",
        "contacts_delete": "Deleting contact",
        "kb_add": "Saving to knowledge base",
        "kb_del": "Removing from knowledge base",
        "reminder_add": "Setting reminder",
        "reminder_del": "Removing reminder",
        "task_add": "Setting scheduled task",
        "task_del": "Removing scheduled task",
        "task_edit": "Updating scheduled task",
        "template_read": "Reading template",
        "template_create": "Creating template",
        "template_edit": "Editing template",
        "template_delete": "Deleting template",
        "template_share": "Sharing template",
        "template_search": "Searching templates",
        "template_download": "Downloading template",
        "template_toggle": "Toggling template",
        "change_setting": "Updating setting",
    ]

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
        return { @Sendable event in
            Task { @MainActor in
                switch event {
                case .toolStarted(let status):
                    let label = status.tool_name.flatMap { Self.toolDisplayLabels[$0] }
                        ?? status.display_label
                        ?? status.tool_name
                        ?? "Processing"
                    enqueueStatus(label)
                case .toolCompleted:
                    enqueueStatus(idleLabel)
                case .throttled:
                    isThrottled = true
                case .throttleEnded:
                    isThrottled = false
                default:
                    break
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

    private func sendAgentChat(_ text: String) {
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
            lastFailedMessage = nil
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
        // Message-detail: deterministic "msg:{accountId}:{stableId}" (tied to email, survives IMAP MOVE).
        // Inbox: random UUID (new session each time).
        // In demo mode every sessionId gets the "demo:" prefix (via
        // scopedSessionId) so demo turns are wiped on exit and never mix with
        // the user's session history.
        if currentSessionId == nil {
            if let key = stableMessageKey {
                currentSessionId = DemoModeStore.scopedSessionId("msg:\(key)")
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
        if !isComposeMode && message == nil, let sid = currentSessionId,
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
        chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date()))
        isWorking = true
        ActiveAgentTracker.shared.setWorking(sessionKey)
        resetStatusQueue()
        lastFailedMessage = nil
        pendingResumeRequest = nil  // a fresh send abandons any interrupted turn
        lastChatActivity = Date()

        let sid = currentSessionId
        let capturedSessionKey = sessionKey

        activeChatTask = Task {
            let chatStore = ChatStore.shared

            // Ensure email context is registered before building enrichedText.
            // Covers three cases:
            // 1. Live message-detail session — message is non-nil, register from it
            // 2. Resumed past message-detail session from inbox — message is nil but
            //    sessionEmailContexts has the snapshot, register from it (avoids race
            //    with fire-and-forget Task that was previously used)
            // 3. Inbox session — neither applies, enrichedText = raw text
            if let msg = message, contextEmailNumericId == nil {
                contextEmailNumericId = await ChatIdTranslator.shared.toNumericId(msg.id)
            } else if contextEmailNumericId == nil, let sid = sid,
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
                    contextEmailNumericId = await ChatIdTranslator.shared.toNumericId(resolvedId)
                    print("[DynamicIslandChat] Restored email context for resumed session: \(emailCtx.subject)")
                }
            }

            // Build enrichedText INSIDE Task block (after awaiting registration)
            let enrichedText: String
            if let numericId = contextEmailNumericId {
                enrichedText = "Regarding [Email](\(numericId)): \(text)"
            } else {
                enrichedText = text
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
            do {
                let evicted = try await chatStore.appendTurn(userTurn)
                let userRefs = ChatIdTranslator.collectRefsFromTurn(userTurn)
                await ChatIdTranslator.shared.registerTurnRefs(userRefs)
                if !evicted.isEmpty {
                    await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                }
            } catch {
                print("[DynamicIslandChat] Failed to persist user turn: \(error)")
            }

            // Step 2: Send via completions API with current session turns as history.
            // Only THIS session's turns — no expired/archived history from past sessions.
            let history = sessionTurns
            sessionTurns.append(userTurn)

            do {
                // Owned UI delivery (ADR-IOS-053): bind the confirmation channel to
                // THIS session so any FSM tool's card is delivered to (and rendered
                // by) the session that launched the turn — never a global slot that
                // other mounted pills race for.
                let response = try await AIService.shared.sendChatMessage(
                    userText: enrichedText,
                    history: history,
                    onSSEEvent: makeCompletionsSSEHandler(idleLabel: "Thinking..."),
                    invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey)
                )

                let replyText = response?.text ?? "I couldn't generate a response. Please try again."
                if response == nil {
                    BackgroundSyncLogger.logChatError("Empty/nil response from LLM", userMessage: text)
                } else {
                    confirmSubscriptionActive()
                }
                print("[AIChatDebug] Raw LLM response (\(replyText.count) chars): \(replyText.prefix(300))")
                if replyText.contains("[Email]") {
                    print("[AIChatDebug] Response contains [Email] pattern — pills should render")
                }

                // Rendered text with pills resolved — used for both persistence and display.
                // Resolving once here avoids a redundant actor hop in MarkdownChatText.
                var displayText = replyText

                // Only persist real assistant responses (not client-generated fallbacks).
                // Dangling user turns are harmless — LLM sees the unanswered question next time.
                if response != nil {
                    print("[AIChatRender] step 1/5: processResponseForDisplay START")
                    // Generate rendered snapshot with pills resolved (subjects baked in).
                    // This survives across sessions even after ChatIdTranslator is cleared.
                    // Matches TB's _rendered HTML snapshot approach.
                    let rendered = await ChatIdTranslator.shared.processResponseForDisplay(replyText)
                    displayText = rendered
                    print("[AIChatRender] step 2/5: processResponseForDisplay DONE (\(rendered.count) chars)")

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

                    print("[AIChatRender] step 3/5: persisting turn to chatStore...")
                    do {
                        let evicted = try await chatStore.appendTurn(assistantTurn)
                        print("[AIChatRender] step 3a: appendTurn done, evicted=\(evicted.count)")
                        let assistantRefs = ChatIdTranslator.collectRefsFromTurn(assistantTurn)
                        await ChatIdTranslator.shared.registerTurnRefs(assistantRefs)
                        if !evicted.isEmpty {
                            await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                        }
                    } catch {
                        print("[DynamicIslandChat] Failed to persist assistant turn: \(error)")
                    }
                    print("[AIChatRender] step 4/5: persistence complete")
                }

                // Guard: if user already pressed stop, don't append result
                guard !Task.isCancelled else { return }

                print("[AIChatRender] step 5/5: appending to chatMessages (count=\(chatMessages.count))...")
                // Store pre-rendered text (pills already resolved) — MarkdownChatText
                // parses it synchronously without a redundant actor hop.
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: displayText,
                    timestamp: Date(),
                    animate: true
                ))
                print("[AIChatRender] chatMessages appended (count=\(chatMessages.count)), about to set isWorking=false")
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
                    // no `lastFailedMessage` (that's the separate fork/resend pathway).
                    BackgroundSyncLogger.logChatError("Connection lost (resumable): \(error.localizedDescription)", userMessage: text)
                    pendingResumeRequest = resumable.resumeRequest
                } else {
                    // Connection/server error — enable retry
                    BackgroundSyncLogger.logChatError("Chat error: \(error.localizedDescription)", userMessage: text)
                    lastFailedMessage = text
                    chatMessages.append(ChatMessage(
                        role: .agent,
                        content: "Couldn't connect. (\(error.localizedDescription))",
                        timestamp: Date()
                    ))
                }
            }
            // Guard: stop button already cleaned up
            guard !Task.isCancelled else { return }
            print("[AIChatRender] setting isWorking=false, activeChatTask=nil")
            activeChatTask = nil
            isWorking = false
            ActiveAgentTracker.shared.clearWorking(capturedSessionKey)
            resetStatusQueue()
            lastChatActivity = Date()
            print("[AIChatRender] sendAgentChat complete")
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
    /// `pendingResumeRequest`). Re-enters the tool loop from the saved
    /// `conversation_state`, so every already-completed tool call and prior round's
    /// thinking is reused — nothing is re-executed and the user's message is NOT
    /// re-sent. This is intentionally separate from the fork/resend pathways
    /// (`resendLastUserMessage` / `rewindToMessage` / `forkFromMessage`), which
    /// restart from a user message via `sendAgentChat`.
    private func resumeAgentChat() {
        guard !isWorking, let request = pendingResumeRequest else { return }
        pendingResumeRequest = nil  // hide the affordance; re-armed on failure
        isWorking = true
        ActiveAgentTracker.shared.setWorking(sessionKey)
        resetStatusQueue()
        lastChatActivity = Date()

        let sid = currentSessionId
        let capturedSessionKey = sessionKey

        activeChatTask = Task {
            let chatStore = ChatStore.shared
            do {
                let response = try await AIService.shared.resumeChatMessage(
                    request: request,
                    onSSEEvent: makeCompletionsSSEHandler(idleLabel: "Thinking..."),
                    invocation: ToolInvocation(uiSink: SessionUISink(session: session), sessionKey: sessionKey)
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
                    do {
                        let evicted = try await chatStore.appendTurn(assistantTurn)
                        let assistantRefs = ChatIdTranslator.collectRefsFromTurn(assistantTurn)
                        await ChatIdTranslator.shared.registerTurnRefs(assistantRefs)
                        if !evicted.isEmpty {
                            await ChatIdTranslator.shared.cleanupEvictedIds(evictedTurns: evicted)
                        }
                    } catch {
                        print("[DynamicIslandChat] Failed to persist resumed assistant turn: \(error)")
                    }
                }

                guard !Task.isCancelled else { return }
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: displayText,
                    timestamp: Date(),
                    animate: true
                ))
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
                    pendingResumeRequest = resumable.resumeRequest
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
            Task { try? await ChatStore.shared.deleteTurns(ids: turnIdsToDelete) }
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
            Task { try? await ChatStore.shared.deleteTurns(ids: idsToDelete) }
        }
        sessionTurns = Array(sessionTurns.prefix(turnsCutoff))
        return userMessagesBefore
    }

    /// Re-send the last user message (same session). Removes the agent response/error below it.
    private func resendLastUserMessage(text: String, afterIndex index: Int) {
        trimForResendLast(atIndex: index)
        lastFailedMessage = nil
        sendAgentChat(text)
    }

    /// Rewind chat to an earlier user message (message-detail context).
    /// Truncates everything from that message onward and resends it in the same session.
    /// Unlike `forkFromMessage`, this stays in the same session — no new session is created.
    private func rewindToMessage(text: String, atIndex index: Int) {
        trimForRewind(atIndex: index)
        lastFailedMessage = nil
        sendAgentChat(text)
    }

    /// Re-send the last compose-edit instruction. In addition to the standard trim, this rolls
    /// the draft back to the pre-edit snapshot (if the prior edit succeeded and mutated the
    /// draft) and pops the trailing `editHistory` entry so the LLM history matches state.
    private func resendLastUserComposeEdit(text: String, afterIndex index: Int) {
        trimForResendLast(atIndex: index)
        if let last = editHistory.last {
            // Recipients are not tracked in editHistory — pass nil to keep current values.
            onDraftUpdate?(last.subjectAtRequest, last.bodyAtRequest, nil, nil, nil)
            editHistory.removeLast()
        }
        sendComposeEdit(text)
    }

    /// Rewind compose-edit chat to an earlier user message. In addition to the standard trim,
    /// this rolls the draft back to the snapshot captured at that turn and truncates
    /// `editHistory`.
    private func rewindComposeEditToMessage(text: String, atIndex index: Int) {
        let userMessagesBefore = trimForRewind(atIndex: index)
        // Snapshot on the earliest popped editHistory entry is the pre-edit draft for that turn.
        let editCutoff = min(userMessagesBefore, editHistory.count)
        if editCutoff < editHistory.count {
            let anchor = editHistory[editCutoff]
            // Recipients are not tracked in editHistory — pass nil to keep current values.
            onDraftUpdate?(anchor.subjectAtRequest, anchor.bodyAtRequest, nil, nil, nil)
            editHistory = Array(editHistory.prefix(editCutoff))
        }
        sendComposeEdit(text)
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
        lastFailedMessage = nil
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

        inputText = text
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

