
## ADR-IOS-023: Mobile-Native Chat UX (Exception to TB Parity)

**Context:** ADR-IOS-008 requires exact replication of TB's architecture, and ADR-IOS-022 established the agent chat system matching TB's `agentConverse`. However, TB's desktop "infinite chat" paradigm — welcome-back messages, greyed-out old sessions, full history replay in the chat window — doesn't suit mobile UX. The iOS Dynamic Island chat pill has limited screen space and users expect a lightweight, focused interaction.

**Decision:** The iOS chat departs from TB's UI presentation while keeping the backend architecture identical:

1. **No welcome-back message** — TB shows a "Welcome back {name}" bubble with staged animation. iOS shows **reminder cards at the top of the chat** (same visual pattern as the email context card) instead. Reminders are loaded fresh on each expand.
2. **Session history with swipe navigation** — TB greys out old-session messages inline. iOS stores a `sessionId` on each `ChatTurn` (GRDB migration v11) and presents past sessions as horizontally swipeable pages in a `TabView(.page)`. Users can swipe left to browse up to K most recent sessions (configurable via `maxChatSessions` in Settings, default 10). The rightmost page is always the current/newest session and is the default on open. **Resuming**: swiping to an old session and sending a message adopts that session's turns as the API conversation history, effectively "resuming" the conversation. The backend receives the same `history` array — no backend changes needed. Sessions reorder by last activity on close/reopen.
3. **Multi-turn within session** — Current session IS multi-turn: prior user/assistant turns from `sessionTurns` (in-memory, in `ChatPillState.Session`) are sent as conversation history. When resuming an old session, that session's persisted turns become the `sessionTurns`. **30s idle timeout** — if the user hasn't interacted for 30s (and the agent is not working), the next expand starts a new session. KB refinement fires on the expiring session.
4. **Nudges become reminder cards** — TB's proactive nudges insert a chat bubble. iOS shows nudge-worthy reminders (urgent/overdue) as **top-of-chat cards with accent highlighting**. Tap to expand, dismiss to snooze.
5. **Compose edit mode is single-turn (atomic)** — Each edit instruction is independent. `editHistory` provides context for continuity, but the LLM does not receive prior conversation turns as messages.

**What stays identical (ADR-IOS-008 compliance):**
- System prompt construction (`system_prompt_agent` with `user_name`, `user_kb_content`, `user_reminders_json`)
- KB refresh per turn, reminders refresh per turn
- ChatIdTranslator (ID recycling, ref counting, pill rendering, eviction cleanup)
- ChatStore persistence (turns still saved for Settings > Chat History, budget enforcement)
- Tool execution (SSE events, server-side tools, client-side tools via ToolRegistry)
- `renderedContent` generation for ChatHistoryView
- Email context enrichment (`Regarding [Email](N):` prefix for LLM, hidden from user)

**Rationale:**
- Mobile users benefit from browsing recent conversations without infinite scrollback
- Swipe-based session navigation is a natural iOS pattern (TabView with page style)
- Resuming old sessions by swapping the conversation history is purely client-side — no backend changes
- Reminder cards at the top are more actionable than a welcome-back bubble
- Multi-turn within the active session is essential for natural conversation flow
- The agent's tools (memory_search, inbox_read) supplement session context

**Consequences:**
- `ChatMessage` model is simplified (no `isHistory`, `isOldSession`, `isGreeting` flags)
- `ChatBubble` is simplified (no greeting tint, no opacity/saturation modifiers)
- Greeting builder functions (`buildGreeting`, `formatRemindersForGreeting`, `formatDueDateForGreeting`) are removed
- `ChatTurn.sessionId` (nullable, GRDB v11) groups turns into sessions; pre-v11 turns have NULL
- `ChatPillState.Session` holds multi-session state: `loadedSessions`, `activeSessionIndex`, `currentSessionId`
- `ChatStore.loadSessions(limit:)` queries distinct sessions ordered by last activity
- `DynamicIslandChatButton` uses `TabView(.page)` for horizontal swiping with custom dot indicators
- Sending in a past session adopts its `sessionId` and turns as the API `history` parameter
- ChatHistoryView and Settings Chat History are unaffected — full history accessible from Settings
- Session state survives SwiftUI view recreation via `ChatPillState` singleton

---
