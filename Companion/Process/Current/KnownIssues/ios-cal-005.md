# IOS-CAL-005

> Routed from `KNOWN_ISSUES.md` line 1128 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed`
- Original row SHA-256: `b79d174c71c22cb90617119611996633ef118254e9606a7596d70281355217b3`

## Status

✅ **FIXED (2026-08-06, round-12 T6)** — `awaitCalendarOpOutcome`'s timeout path discarded the continuation instead of resuming it, so a wait nobody signalled never returned and the calling agent tool hung for the life of the task

## Subsystem and search terms

Calendar; continuation leak; `AccountManager.awaitCalendarOpOutcome`; `dropCalendarOpAwaiter`; `calendarOpAwaiters`; `withCheckedContinuation`; `.timedOut`; `CalendarEventDeleteTool`; `CalendarEventEditTool`; hang; actor isolation; `ContinuationGuard`

## Full detail

**What was wrong.** `dropCalendarOpAwaiter` called `calendarOpAwaiters.removeValue(forKey: opId)` and **discarded the returned continuation**. The timeout was computed and the awaiter unregistered, but nothing resumed the suspended caller, so the tool that queued the operation waited forever whenever no terminal outcome was ever signalled.

**What now holds.** `removeValue(forKey:)?.resume(returning: .timedOut)` — the timeout is *deliverable*, not merely computed.

**Counterfactual discharged, and it is EMPTY.** The usual hazard when adding a resume is a double-resume crash. It is structurally impossible here: `calendarOpAwaiters` lives on the `AccountManager` **actor**, and every path that resumes an awaiter first removes it from that dictionary under actor isolation, so exactly one path can hold any given continuation. This is deliberately NOT adopting `AgentToolRouter.ContinuationGuard` / `ComposeContinuationGuard` — those exist because their owners are unisolated and need an `NSLock`; importing that machinery here would add a lock to protect state the actor already serialises, and the defect was a discarded return value, not a missing lock.

**Verification.** `CalendarQueueOutcomeTests.unsignalledWaitReturnsInsteadOfHanging()`, written as a detached task plus polling **because the pre-fix failure is a HANG** and an inline `await` would wedge the test process rather than fail it (red pre-fix: the settled outcome was still nil after the timeout, then the follow-on assertion failed).
