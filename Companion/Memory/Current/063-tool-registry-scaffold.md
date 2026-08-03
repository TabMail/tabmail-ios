
### Tool Registry (Scaffold)
- `ToolRegistry.swift` — `AgentTool` protocol + `ToolRegistry` actor (central registry matching TB's `core.js`)
- Tools registered at startup, looked up by name during tool execution loop
- Types defined: `CompletionsSSEEvent`, `ToolStatusEvent`, `CompletionsFinalEvent`, `CompletionsToolCall`, `ConversationState`, `HarmonyMessage`, `ToolTrace`, `ToolResult`
- No tool implementations yet — scaffold only. Tools added incrementally (memory_search → email tools → calendar/contacts)
