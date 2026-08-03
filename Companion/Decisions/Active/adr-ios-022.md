
## ADR-IOS-022: Agent Chat with Persistent History

**Context:** The Thunderbird addon has a conversational AI assistant (`agentConverse`) that uses the `system_prompt_agent` system prompt, persistent chat history, and the completions API. The iOS app needed the same feature in the Dynamic Island chat pill, replicating TB's architecture per ADR-IOS-008.

**Decision:**
1. **Completions API** — Chat uses `AIService.sendChatMessage()` which sends `system_prompt_agent` (system) + history turns + `chat_converse` (user message) via `sendWithTools()`. Server-side tools (search_web, date_to_day, find_available_slots, time_delta) auto-execute in the backend — the iOS client just receives the final response.
2. **GRDB persistence** — `ChatStore` actor with `chatTurn` table (v6 migration). `ChatTurn` model matches TB's `persistentChatStore.js` turn structure. Budget: 50 exchanges max, 25K chars max, FIFO eviction.
3. **Backend templates** — iOS-specific `system_prompt_agent-v1.0.0.md` (simplified from TB: server-side tool instructions for search_web + date_to_day, no calendar/contacts/FSM, mobile-optimized formatting). Supporting templates: `chat_converse_user_message` (aliased to `chat_converse`), `chat_converse_history`, `chat_converse_reminders`.
4. **History in UI** — `ChatHistoryView` accessible from Settings > AI. Searchable, clearable.
5. **No client-side tools yet** — Server-side tools work out-of-the-box. Client-side tools (email search, memory search, etc.) will be added incrementally via `ToolRegistry`.

**Rationale:**
- ADR-IOS-008 requires exact replication of TB's architecture
- TB's `system_prompt_agent` + `expandSystemPromptAgent()` expansion model is battle-tested
- Persistent history enables cross-session context (prior session history, conversation continuity)
- Server-side tools (search_web, date_to_day) auto-execute in the backend with no iOS code needed — the backend auto-loops and returns the final response

**Consequences:**
- Backend prompt templates must be maintained in sync between iOS and TB (shared intent, platform-specific content)
- iOS agent is more limited than TB (no email operations, calendar, contacts) until client-side tools are implemented
- `chat_converse` alias in `gen-registries.mjs` maps `chat_converse_user_message` filename → `chat_converse` registry key (critical for iOS code that sends `content: "chat_converse"`)
- Budget enforcement is device-local — chat history is NOT synced via Device Sync (per design: stays per-device)

---
