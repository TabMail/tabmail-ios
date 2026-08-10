# IOS-ROUND3-D5

> Routed from `KNOWN_ISSUES.md` line 233 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `f2a0b351a741bfa66cd9b278676f70e394b2e1d93a5635d753984099816e00b1`

## Status

Surfaced round 3; test-register accuracy only; ✅ **FIXED by `b87804055`**

## Subsystem and search terms

Tests; `ActiveAIQueueTests.unstampedButUnreplacedRowStillWritesThrough`; universally-quantified name

## Full detail

The test's display name — *"An UNSTAMPED but UNREPLACED row still receives its AI result"* — is universally quantified, but the case it constructs and asserts covers only the **RFC-BEARING** subset. An RFC-less unstamped row is exactly `IOS-AI-002` above and is NOT covered. Same hazard class as `IOS-TEST-002` and the `ProviderNativeActionAdmissionTests` name: a universally-quantified test name that enumerates a subset reads to a later reader as a proof it is not. No production impact.

✅ **FIXED by `b87804055`.** **The invariant that now holds:** the test's display name names the subset it actually constructs. It is now *"An UNSTAMPED but UNREPLACED **RFC-BEARING** row still receives its AI result, and is not recomputed forever"*, and the doc block records that RFC-less unstamped rows are `IOS-AI-002`/`IOS-AI-003` and out of this test's scope — so the gap the name used to hide is now stated by the name and cross-referenced to the rows that own it. The retired name is recorded inline per the established convention, so it stays searchable.
