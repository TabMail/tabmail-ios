
### SSE Streaming & Tool Execution Loop
- `BackendClient.sendCompletionsWithTools()` — full multi-turn tool execution loop matching TB's `sendChatCompletions()` + `onToolExecution` pattern
- Parses SSE events: `keepalive`, `tool_started`, `tool_completed`, `tool_failed`, `final`, `error`
- When `final` contains `tool_calls`: executes tools via `ToolRegistry`, appends results to `conversation_state.harmony_messages`, sends next round
- `CompletionsRequest` now includes optional `conversation_state` for multi-turn continuation
- Max 10 tool rounds before forcing a final response with `disable_tools: true`
- `AIService.sendWithTools()` — entry point for tool-enabled completions (used by future chat/reply features). Removed 2026-11-18 (no callers): chat goes through `AIService.sendWithToolsDirect`, reply and inline edit call `BackendClient.sendCompletionsWithTools[Direct]` directly
- Every round and every 429 retry is a new request, so the AI setting (Opt Out of AI) is read again before each one (`BackendClient.refuseIfAIOff`, `AIOffError`)
- Existing summary/action pipeline unchanged (still uses `sendCompletions` — single-shot, no tools)
