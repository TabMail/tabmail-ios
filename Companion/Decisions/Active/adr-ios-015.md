
## ADR-IOS-015: Three-Tier Background Execution for AI Processing

**Context:** AI processing calls (summary, action, future tool-enabled chat) can take 60+ seconds, especially with multi-turn tool execution loops. iOS suspends apps within ~5 seconds of backgrounding. Without protection, all in-flight AI work is lost (though idempotent design means messages re-queue on next sync, wasting LLM tokens). The existing `BGAppRefreshTask` (Tier 2) only provides ~15-60s — insufficient for long AI calls.

**Decision:**
1. **Tier 2 (existing):** `BGAppRefreshTask` (`ai.tabmail.sync`) — lightweight sync polling + embeddings (15-60s budget).
2. **Tier 3 (new):** `BGProcessingTask` (`ai.tabmail.ai-processing`) — long-running AI processing (up to ~10 min). Requires network connectivity, no external power required. Scheduled on app background with 5 min earliest begin date. Runs: sync → AI processing for all accounts → embeddings → badge update.
3. **`beginBackgroundTask`:** Wraps both `processMessagesForAccount` (queue path) and `processMessage` (priority path) to protect in-flight AI calls with ~30s grace period on backgrounding.
4. **SSE streaming with tool execution loop:** `BackendClient.sendCompletionsWithTools()` implements multi-turn tool execution matching TB's architecture. Parses full SSE event stream, executes client-side tools via `ToolRegistry`, manages `conversation_state` across rounds.
5. **Tool scaffold:** `AgentTool` protocol + `ToolRegistry` actor. No implementations yet — tools added incrementally.

**Rationale:**
- `BGProcessingTask` grants up to ~10 minutes — sufficient for batch AI processing with tool loops
- `beginBackgroundTask` is a quick-win safety net (~30s) for single in-flight calls
- Tool execution loop matches TB's proven architecture (ADR-IOS-008 compliance)
- Existing summary/action pipeline untouched (still uses simpler `sendCompletions`)

**Consequences:**
- `processing` added to `UIBackgroundModes` in Info.plist
- iOS decides when to run `BGProcessingTask` (not immediate — best-effort scheduling)
- Tool-enabled features (chat, reply precompute) use `sendCompletionsWithTools`; summary/action use `sendCompletions`
- When adding tools, register them in `ToolRegistry` at app startup

---
