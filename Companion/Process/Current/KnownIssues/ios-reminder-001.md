# IOS-REMINDER-001

> Routed from `KNOWN_ISSUES.md` line 1448 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `e5a1276f7ddd3373bc7f3c077a1111bf9c61b23ca7fce9ce7bc91ee6e2466eca`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — one thrown GRDB reminder observation silently ends reminder refresh for that in-memory chat-pill session

## Subsystem and search terms

reminders; `ChatPillState.Session.observeMessageReminders`; `ValueObservation`; empty catch; stale UI; lifecycle

## Full detail

`observeMessageReminders` runs a `for try await` over the inbox reminder-count observation and ends with an empty `catch {}`. A transient observation failure therefore terminates the only observer attached by that pill view; later reminder changes do not rebuild the staging buffer until the view/session is recreated or the app relaunches. Reminder rows themselves remain durable and ordinary reopen reconstructs them. This is a stale-suggestion UI edge, not a lost reminder or mail mutation, so no restart supervisor is added solely for it.
