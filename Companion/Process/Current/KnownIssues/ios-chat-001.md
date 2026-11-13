# IOS-CHAT-001

> Routed from `KNOWN_ISSUES.md` line 1447 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 dfa31256dfc43d25d741408ed6e33e2e58ae9984d7cc825a2d59c6c1ae1b6535`).

- Register classification: `accepted`
- Original row SHA-256: `8b696f9907b637db9bdcf4a711763e73969ecba52186399c90fc169941aacebd`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — Agent Chat deliberately keeps the live conversation usable when local chat persistence fails, so the visible session and durable history can diverge until reopen

## Subsystem and search terms

Agent Chat; `ChatStore.appendTurn`; `deleteTurns`; resend; rewind; `DynamicIslandChatButton`; `ChatHistoryView`; fire-and-forget; local-only history

## Full detail

**WRITE SIDE.** The main send path catches failed persistence of both user and assistant `ChatTurn`s, logs, appends them to `sessionTurns`, and continues the live API conversation. The user gets the answer, but a restart/reopen can omit one or both turns because the durable session never received them. **DELETE SIDE.** resend/rewind trims `chatMessages` and `sessionTurns` immediately, then performs `Task { try? await ChatStore.shared.deleteTurns(...) }`; if deletion fails, the supposedly removed branch is still loaded from GRDB later alongside newly appended turns. History-screen deletion/clear failures are also log-only, but those paths mutate the UI only after success and therefore remain visible no-ops rather than divergence.

**RECOVERY / DECISION.** Reopening exposes durable truth; repeating rewind/delete or clearing chat repairs it. The mail store and provider are unaffected. Making chat unusable whenever a local history write fails would be worse than allowing the current turn to complete, and a durable second queue would duplicate the database already being written, so this remains an accepted local-history limitation.
<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->

> **The failure is now shown (2026-11-12, issue #532):** the chat pill writes and deletes chat history only through `ChatPillState.Session.appendTurn(_:admission:)` and `ChatPillState.Session.deleteTurns(ids:)`. A failed write or delete still lets the live conversation continue, and now also adds a warning to that chat (`historySaveFailedWarning`, `historyDeleteFailedWarning`) saying the history may differ when the chat is reopened. A demo turn refused after its demo ended (`ChatStore.DemoTurnRefused`) is not a failure and shows nothing. The divergence itself and its recovery are unchanged; the "user is never told" part of this row no longer holds. Tests: `ChatHistoryWriteFailureTests`.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
