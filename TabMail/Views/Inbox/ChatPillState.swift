/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Holds in-memory chat state for DynamicIslandChat, keyed by context.
/// Survives SwiftUI view recreation (which resets @State).
/// Sessions are cleared after 30s idle (checked on expand).
@MainActor @Observable
final class ChatPillState {
    static let shared = ChatPillState()

    /// UserDefaults key for max inbox sessions to show in pill swipe UI.
    /// nonisolated so background maintenance threads can read them.
    nonisolated static let maxSessionsKey = "maxChatSessions"
    nonisolated static let defaultMaxSessions = 10

    /// UserDefaults key for max total chat history turns stored in memory (GRDB chatHistory).
    nonisolated static let maxMemoryTurnsKey = "maxMemoryTurns"
    nonisolated static let defaultMaxMemoryTurns = 5000

    /// UserDefaults key for auto-enable dictation on chat pill open.
    static let autoDictationKey = "autoDictation"
    /// UserDefaults key tracking whether the one-time dictation prompt has been shown.
    static let dictationPromptShownKey = "dictationPromptShown"

    /// Dictionary is @ObservationIgnored — observation happens at Session level.
    /// This prevents "modifying state during view update" when creating sessions.
    @ObservationIgnored
    private var sessions: [String: Session] = [:]

    /// The service the pills' agent requests go to. Tests install one built on a `FakeHTTP`
    /// session (precedent: `AIService(backendClient:)`) to read what a request sends and answer
    /// it; production uses `AIService.shared`.
    @ObservationIgnored
    var aiService: AIService = .shared

    func session(for key: String) -> Session {
        if let existing = sessions[key] { return existing }
        let new = Session()
        sessions[key] = new
        return new
    }

    /// Remove a session by key.
    func removeSession(for key: String) {
        sessions.removeValue(forKey: key)
    }

    /// End a session for good, as the screen holding it closes: a turn still running is cancelled and no
    /// longer counted as working, then the session goes (as compose's Discard ends its own). A new
    /// email's chat (`ChatNewThreadView`) ends its session this way; nothing else would, since
    /// `evictIdleSessions` runs only when a chat expands.
    func endSession(for key: String) {
        if let session = sessions[key] {
            session.activeChatTask?.cancel()
            session.activeChatTask = nil
            session.pendingResume = nil
        }
        ActiveAgentTracker.shared.clearWorking(key)
        removeSession(for: key)
    }

    /// Drop ALL in-memory sessions. Called on demo entry/exit
    /// (`DemoModeService`) so the demo and real chat pills never share
    /// in-memory state (loaded session pages, live turns, reminder buffers).
    /// Views re-create Session objects lazily via `session(for:)` — RootView
    /// swaps the routing branch on demo entry/exit, so the chat pill views
    /// (and their reminder observation `.task`) are recreated as well.
    ///
    /// Any in-flight chat task is CANCELLED first: a streaming agent loop
    /// re-samples the demo flag on every tool call, so a task surviving the
    /// mode flip would execute its remaining tools on the WRONG side of the
    /// demo/real boundary (e.g. a demo-authored compose resolving the real
    /// account after exit). Resume checkpoints are dropped with the session.
    func removeAllSessions() {
        let count = sessions.count
        for (_, session) in sessions {
            session.activeChatTask?.cancel()
            session.activeChatTask = nil
            session.pendingResume = nil
        }
        sessions.removeAll()
        if count > 0 {
            BackgroundSyncLogger.logDebug("[ChatPillState] Cancelled tasks + removed all \(count) in-memory sessions (demo entry/exit)")
        }
    }

    /// Evict in-memory sessions that are idle (no active task, no recent activity).
    /// Called periodically to prevent unbounded growth of the sessions dictionary.
    /// The "inbox" session is never evicted here (it has its own 30s idle TTL on expand).
    func evictIdleSessions(maxIdleSeconds: TimeInterval = 300) {
        let now = Date()
        let keysToEvict = sessions.compactMap { key, session -> String? in
            guard key != "inbox" else { return nil }
            // Don't evict if agent is actively working
            if let task = session.activeChatTask, !task.isCancelled { return nil }
            // Don't evict if recently active
            if let lastActivity = session.lastChatActivity,
               now.timeIntervalSince(lastActivity) < maxIdleSeconds { return nil }
            // No activity at all and no task — evict
            return key
        }
        for key in keysToEvict {
            sessions.removeValue(forKey: key)
        }
        if !keysToEvict.isEmpty {
            BackgroundSyncLogger.logDebug("[ChatPillState] Evicted \(keysToEvict.count) idle in-memory sessions")
        }
    }

    @MainActor @Observable
    final class Session {
        var chatMessages: [ChatMessage] = []
        var lastChatActivity: Date?
        /// The send that failed outright, for the retry button: its words, and the reply field's
        /// send as it started when the field sent it (nil: the panel sent it).
        var lastFailedSend: FailedSend?
        /// Saved checkpoint for a turn that was cut off in transit (connection lost
        /// mid-stream). Holds the failed round's request with its preserved
        /// `conversation_state`, so "tap to retry" resumes from completed tool work
        /// instead of restarting. Deliberately SEPARATE from `lastFailedSend`
        /// (the fork/resend pathways) — resume continues an in-flight turn, it does
        /// not re-send the user's message. Kept in memory only.
        var pendingResume: PendingResume?

        struct FailedSend {
            let text: String
            let field: ChatFieldSend?
        }

        /// The cut-off turn's request and, when the reply field sent it, the field's request as it
        /// was sent (`ChatFieldReply`): the resumed turn's tools get the same one.
        struct PendingResume {
            let request: CompletionsRequest
            let fieldReply: ChatFieldReply?
        }
        /// Buffer 1 (display): shown on the "new session" page. Swapped from Buffer 2
        /// on pill expand for instant display. Stable while being shown.
        var activeReminders: [Reminder] = []
        /// Buffer 2 (staging): continuously rebuilt in background on any reminder change.
        /// Swapped into Buffer 1 on pill expand, and whenever Buffer 1 is not being shown.
        var nextReminders: [Reminder]?
        /// Frozen reminder snapshots for past/current sessions (keyed by session ID).
        /// Persisted on first user message and when sessions rotate.
        var sessionReminderSnapshots: [String: [Reminder]] = [:]
        /// Email context snapshots for message-detail sessions (keyed by session ID).
        /// Stored on first message, shown in session history to indicate which email was discussed.
        var sessionEmailContexts: [String: EmailContextSnapshot] = [:]
        var editHistory: [InlineEditTurn] = []
        /// Current session's turns for multi-turn API history.
        /// Only includes turns from THIS session (not expired/archived history). A thread's
        /// chat sends every key's turns of the thread (`ThreadChatReader.history`).
        var sessionTurns: [ChatTurn] = []
        /// Active chat task for this session. Stored here (not @State) so it survives
        /// SwiftUI view recreation when the user navigates away and back.
        @ObservationIgnored
        var activeChatTask: Task<Void, Never>?
        /// The one read of this session's stored turns (`loadStoredTurns`).
        @ObservationIgnored
        private var storedTurnsLoad: Task<Void, Never>?

        /// Reads the turns stored under `sessionId` into this session, once: they go in front of
        /// anything already here (a send made before the read), each turn once. Every caller
        /// waits for the same read, so a send's history never misses the stored turns.
        func loadStoredTurns(sessionId: String) async {
            if storedTurnsLoad == nil {
                storedTurnsLoad = Task { @MainActor in
                    let stored: ChatStore.ChatSession?
                    do {
                        stored = try await ChatStore.shared.loadContextSession(sessionId: sessionId)
                    } catch {
                        BackgroundSyncLogger.logDebug("[ChatPillState] Failed to load stored turns of \(sessionId.prefix(40)): \(error)")
                        return
                    }
                    guard let stored else { return }
                    let known = Set(sessionTurns.map(\.id))
                    let earlier = stored.turns.filter { !known.contains($0.id) }
                    sessionTurns = earlier + sessionTurns
                    chatMessages = ThreadChatReader.chatMessages(for: earlier) + chatMessages
                    if currentSessionId == nil { currentSessionId = sessionId }
                    if let context = stored.emailContext, sessionEmailContexts[sessionId] == nil {
                        sessionEmailContexts[sessionId] = context
                    }
                    BackgroundSyncLogger.logDebug("[ChatPillState] Loaded \(earlier.count) stored turns of \(sessionId.prefix(40))")
                }
            }
            await storedTurnsLoad?.value
        }

        // --- Multi-session state (inbox context only) ---

        /// Loaded sessions for swipe navigation. Last element = most recent (rightmost).
        var loadedSessions: [ChatStore.ChatSession] = []
        /// Index of the active session page in the TabView. Defaults to last (newest).
        var activeSessionIndex: Int = 0
        /// The sessionId of the current live session. Generated on first message send.
        var currentSessionId: String?
        /// Whether past sessions have been loaded for this pill open cycle.
        var hasLoadedHistory: Bool = false
        /// If set, loadSessionHistory will navigate to this session after loading.
        /// Used by task result deep links to land on the task page, not __new__.
        var pendingNavigateToSession: String?
        /// Pre-computed ChatMessage arrays for loaded sessions (keyed by session ID).
        /// Prevents UUID regeneration on every render which causes flicker.
        var cachedSessionMessages: [String: [ChatMessage]] = [:]

        // --- Local chat history writes ---

        /// Shown in this chat when a turn could not be written to the local chat
        /// history. The live conversation keeps going; only the saved copy differs.
        nonisolated static let historySaveFailedWarning =
            "This message couldn't be saved to your chat history. You can keep chatting, but it may be missing when you reopen this chat."

        /// Shown in this chat when removed turns could not be deleted from the local
        /// chat history, so they can come back when the chat is reopened.
        nonisolated static let historyDeleteFailedWarning =
            "The removed messages couldn't be deleted from your chat history. They may come back when you reopen this chat."

        /// The pill's one way to write a turn to the local chat history. Returns
        /// the turns evicted by the budget, or nil when the write failed. A failure
        /// does not stop the conversation; it is shown in this chat as a warning,
        /// because the saved history now differs from what is on screen.
        ///
        /// A demo turn refused after its demo ended (`ChatStore.DemoTurnRefused`)
        /// is not a failure: that history is discarded on purpose.
        @discardableResult
        func appendTurn(_ turn: ChatTurn, admission: DemoModeStore.Admission?) async -> [ChatTurn]? {
            do {
                return try await ChatStore.shared.appendTurn(turn, admission: admission)
            } catch is ChatStore.DemoTurnRefused {
                BackgroundSyncLogger.logDebug("[ChatPillState] Demo turn refused after its demo ended: \(turn.role)")
                return nil
            } catch {
                BackgroundSyncLogger.logDebug("[ChatPillState] Failed to persist \(turn.role) turn: \(error)")
                chatMessages.append(ChatMessage(
                    role: .warning, content: Self.historySaveFailedWarning, timestamp: Date()))
                return nil
            }
        }

        /// The pill's one way to delete turns it has already removed from the
        /// screen (resend, rewind). A failure is shown in this chat as a warning.
        func deleteTurns(ids: [String]) async {
            do {
                try await ChatStore.shared.deleteTurns(ids: ids)
            } catch {
                BackgroundSyncLogger.logDebug("[ChatPillState] Failed to delete \(ids.count) turns: \(error)")
                chatMessages.append(ChatMessage(
                    role: .warning, content: Self.historyDeleteFailedWarning, timestamp: Date()))
            }
        }

        /// Takes the failed send for the retry button: returns its text and removes
        /// that send from the chat, from its user message down, so the re-send shows
        /// it once. The send is found by its user message, not by counting from the
        /// end, because a warning can sit between the user message and the error.
        func takeFailedSendForRetry() -> FailedSend? {
            guard let failed = lastFailedSend else { return nil }
            lastFailedSend = nil
            if let userIndex = chatMessages.lastIndex(where: { $0.role == .user }) {
                chatMessages.removeSubrange(userIndex...)
            }
            return failed
        }

        /// Observe inbox message reminder count changes via GRDB ValueObservation.
        /// First emission populates activeReminders (initial load). Subsequent changes
        /// rebuild Buffer 2. The view handles propagation to Buffer 1 based on visibility.
        /// Debounced: during sync, messageHeader changes fire 10-100/sec — we wait for a
        /// 2-second quiet period before regenerating.
        func observeMessageReminders() async {
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE isInInbox = 1 AND reminderContent IS NOT NULL AND isReplied = 0") ?? 0
            }
            .removeDuplicates()
            var isFirstEmission = true
            var debounceTask: Task<Void, Never>?
            do {
                for try await _ in observation.values(in: AppDatabase.rawPool) {
                    if isFirstEmission {
                        activeReminders = await ReminderBuilder.getRandomReminders(count: 3, force: true)
                        isFirstEmission = false
                    } else {
                        // Debounce: cancel previous pending update, wait 2s of quiet
                        debounceTask?.cancel()
                        debounceTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, self != nil else { return }
                            NotificationCenter.default.post(name: .remindersDidChange, object: nil)
                        }
                    }
                }
            } catch {}
        }
    }
}

extension Notification.Name {
    /// Posted when reminder data changes (message reminder count, KB edit, disable/enable).
    /// DynamicIslandChatButton observes this to rebuild Buffer 2 and conditionally propagate.
    static let remindersDidChange = Notification.Name("RemindersDidChange")
}
