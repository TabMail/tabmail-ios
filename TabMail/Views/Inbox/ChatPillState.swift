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
            session.pendingResumeRequest = nil
        }
        sessions.removeAll()
        if count > 0 {
            print("[ChatPillState] Cancelled tasks + removed all \(count) in-memory sessions (demo entry/exit)")
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
            print("[ChatPillState] Evicted \(keysToEvict.count) idle in-memory sessions")
        }
    }

    @MainActor @Observable
    final class Session {
        var chatMessages: [ChatMessage] = []
        var lastChatActivity: Date?
        var lastFailedMessage: String?
        /// Saved checkpoint for a turn that was cut off in transit (connection lost
        /// mid-stream). Holds the failed round's request with its preserved
        /// `conversation_state`, so "tap to retry" resumes from completed tool work
        /// instead of restarting. Deliberately SEPARATE from `lastFailedMessage`
        /// (the fork/resend pathways) — resume continues an in-flight turn, it does
        /// not re-send the user's message.
        var pendingResumeRequest: CompletionsRequest?
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
        /// Only includes turns from THIS session (not expired/archived history).
        var sessionTurns: [ChatTurn] = []
        /// Active chat task for this session. Stored here (not @State) so it survives
        /// SwiftUI view recreation when the user navigates away and back.
        @ObservationIgnored
        var activeChatTask: Task<Void, Never>?

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
