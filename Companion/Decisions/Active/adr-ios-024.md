
## ADR-IOS-024: Destructive Tool Confirmation with ToolDeclinedError

**Context:** Agent tools that perform destructive or irreversible actions (archive, delete, edit contacts) must get explicit user confirmation before executing. The tool suspends via `withCheckedContinuation` while a confirmation card is shown in the chat UI. If the user declines, the tool must signal failure to the LLM with `ok: false` so the LLM knows the action was NOT performed and can adjust its behavior (e.g., re-read the inbox to verify correct targets).

**Decision:**

1. Tool calls `AgentToolRouter.ActionConfirmation.awaitConfirmation()` which suspends via `withCheckedContinuation`
2. `DynamicIslandChatButton` observes `pendingAction` and appends a confirmation card to the chat
3. On accept: continuation resumes with `true`, tool executes the action and returns success JSON
4. On decline: continuation resumes with `false`, tool throws `ToolDeclinedError(output:)` with structured JSON containing `cancelled: true` and a guidance message for the LLM
5. `ToolRegistry.execute()` catches `ToolDeclinedError` specifically and returns `ToolExecutionResult(output:, ok: false)` — distinct from generic errors which also return `ok: false` but with a different error message
6. Cancellation safety: `withTaskCancellationHandler` + `ContinuationGuard` (NSLock-based single-resume guard) prevents double-resume crashes when both task cancellation and user response fire

**All tools requiring user confirmation MUST follow this exact pattern.**

Currently applies to: `email_archive`, `email_delete`, `contacts_edit`, `contacts_delete`.

**Consequences:**
- LLM receives structured feedback on decline — can retry with correct targets
- `ToolDeclinedError` is distinct from generic tool errors — allows different UX handling if needed
- Confirmation cards become non-interactive after response (prevents double-tapping)
- Task cancellation (Stop button) safely resumes pending confirmations as declined

**SUPERSEDED (delivery mechanism) by ADR-IOS-053:** Step 2 above (a global `pendingAction` slot observed by `DynamicIslandChatButton` via `.onChange`) caused a cross-view delivery race that hung calendar/confirmation tools. Delivery now goes through an owned, explicit, invocation-scoped `AgentUISink` into the invoking session's model, rendered level-triggered. The `ToolDeclinedError` contract (steps 3–6) and Stop-cancel safety are unchanged.

---
