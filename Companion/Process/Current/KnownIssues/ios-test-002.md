# IOS-TEST-002

> Routed from `KNOWN_ISSUES.md` line 218 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `75cab3f27c9859d9deb7bb7704b1950922c84f775c5cfa3a66d32692d46e7e9b`

## Status

🚨 **PARTLY CANDIDATE-INTRODUCED** (`b78a9303d`); test-register accuracy only; first half CLOSED in round 4 and kept as history; ✅ **second half FIXED by `b87804055`** — the row is now closed in full

## Subsystem and search terms

Tests; `NeverDropExitClosureTests.partialCopyUidRetiresPerMember`; `OutboxStrandedClaimXfailTests`; expected failure

## Full detail

Two test-register inaccuracies, no production impact. ⚠️ **THE FIRST NO LONGER HOLDS — it is retained as history, not as a live finding.** It read: *"`NeverDropExitClosureTests.partialCopyUidRetiresPerMember()`'s doc comment **overstates what it asserts**."* Round 4 re-scoped that test and REWROTE its doc block, which now states the property for all three per-member outcomes the test actually asserts (`COPYUID` names the member ⇒ its source copy may be irreversibly PURGED; unnamed but still present in the source ⇒ the tagged OK plus liveness moves it and authorizes only the REVERSIBLE `\Deleted` mark; both moved ⇒ both retire and nothing is left to re-copy), asserted across two drains against the server's own mailbox contents, and it records both the display-name change and the RED PROOF against the pre-round-4 provider. Doc and assertions agree, so the overstatement is gone. Its current display name is *"A partial COPYUID moves every member and purges only the one it names"*; the prior name — *"A partial COPYUID retires only the proven member and re-queues the rest"* — was itself the overstatement, and is preserved in that test's own doc block rather than here. **THE SECOND IS UNCHANGED AND STILL TRUE:** `OutboxStrandedClaimXfailTests` contains **no expected-failure test** despite its name — three `@Test`s, no `withKnownIssue` anywhere in the file; the suite's single expected failure lives elsewhere, so a reader looking for it here will not find it.

✅ **SECOND HALF FIXED by `b87804055`, "Close the test-accuracy cluster: 5 vacuous tests, 4 wrong names"; the row is now closed in full** (its first half closed in round 4 and is kept above as history, not as a live finding). **The invariant that now holds:** no suite in the test target is named for an expected failure it does not contain. `OutboxStrandedClaimXfailTests` was renamed — **file and type** — to `OutboxStrandedClaimTests`. **No test was added, removed, renamed or re-scoped**, and the `@Suite` display name *"Outbox post-claim provider loss"* is unchanged, so the rename cannot have altered what is asserted; **both** previous names are recorded in the file header, so the old name a commit body or ADR may cite stays searchable.
