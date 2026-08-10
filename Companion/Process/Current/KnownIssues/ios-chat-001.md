# IOS-CHAT-001

> Routed from `KNOWN_ISSUES.md` line 1447 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `8b696f9907b637db9bdcf4a711763e73969ecba52186399c90fc169941aacebd`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — Agent Chat deliberately keeps the live conversation usable when local chat persistence fails, so the visible session and durable history can diverge until reopen

## Subsystem and search terms

Agent Chat; `ChatStore.appendTurn`; `deleteTurns`; resend; rewind; `DynamicIslandChatButton`; `ChatHistoryView`; fire-and-forget; local-only history

## Full detail

**WRITE SIDE.** The main send path catches failed persistence of both user and assistant `ChatTurn`s, logs, appends them to `sessionTurns`, and continues the live API conversation. The user gets the answer, but a restart/reopen can omit one or both turns because the durable session never received them. **DELETE SIDE.** resend/rewind trims `chatMessages` and `sessionTurns` immediately, then performs `Task { try? await ChatStore.shared.deleteTurns(...) }`; if deletion fails, the supposedly removed branch is still loaded from GRDB later alongside newly appended turns. History-screen deletion/clear failures are also log-only, but those paths mutate the UI only after success and therefore remain visible no-ops rather than divergence.

**RECOVERY / DECISION.** Reopening exposes durable truth; repeating rewind/delete or clearing chat repairs it. The mail store and provider are unaffected. Making chat unusable whenever a local history write fails would be worse than allowing the current turn to complete, and a durable second queue would duplicate the database already being written, so this remains an accepted local-history limitation.
