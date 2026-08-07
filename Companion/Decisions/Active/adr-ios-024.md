<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **⚠️ CURRENT ROUTING NOTE (2026-08-07) — the `Currently applies to:` line below is STALE. It names
> FOUR tools; the real set is TWELVE.** The body is preserved unedited because its bytes are pinned by
> `Companion/Decisions/manifest.tsv` and reconstruct `v1.6.38:DECISIONS.md`; read this note in its
> place. The correction was first written *inside* the body on 2026-08-06 (`7c143daa5`) and is moved
> here unchanged — that inline edit is what broke `ruby Scripts/compact_companion_docs.rb verify` for
> a day (`MIS-IOS-009`, recurrence 3).
>
> **Applies to every tool that calls the gate — re-derived by that property 2026-08-06 (round-15
> FIX-9), not by editing names into a list.** The predicate is `rg -l 'awaitConfirmation'` over
> `TabMail/Services/AI/Tools/`, mapped to each type's `let name = "…"`. **Twelve tools:**
>
> - mail — `email_archive`, `email_delete`
> - contacts — `contacts_edit`, `contacts_delete`
> - calendar — `calendar_event_create`, `calendar_event_edit`, `calendar_event_delete`
> - templates — `template_create`, `template_edit`, `template_delete`, `template_share`,
>   `template_download`
>
> ⚠️ **This list said four — `email_archive`, `email_delete`, `contacts_edit`, `contacts_delete` —
> until 2026-08-06, and the calendar and template families had been confirming for a long time.** The
> staleness predates the v3 range. Re-derive the property; do not append to the names, because a list
> maintained by appending is stale from the first tool added without touching this file (`MIS-031`).
>
> ⚠️ **THE NEGATIVE CASE, so this is not misread as "every mutating tool confirms" — it is not.**
> `contacts_add`, `task_add`/`task_edit`/`task_del`, `reminder_add`/`reminder_del`, `kb_add`/`kb_del`,
> `template_toggle`, `change_setting` and the compose family (`email_compose`, `email_reply`,
> `email_forward`) all mutate and **do not** call this gate. That is a product decision about which
> actions are destructive or irreversible enough to interrupt the user for, and this ADR does not
> adjudicate it — it defines the pattern a tool MUST follow **once** it needs confirmation. If you are
> here to decide whether a NEW tool should confirm, this list is evidence of practice, not a rule.
<!-- COMPANION-CURRENT-NOTE-END -->

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
