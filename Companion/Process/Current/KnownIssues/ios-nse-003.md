# IOS-NSE-003

> Routed from `KNOWN_ISSUES.md` line 216 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `5d62fbea14bbf2a000d0e47edf34ad72eafe0a549c847fdc7e06f63b6418a6e3`

## Status

**CANDIDATE-INTRODUCED** by `209a55cdf`; ✅ **FIXED in round 2**

## Subsystem and search terms

NSE; `NSEDataBridge.stagingPurgeTarget(...)`; App Group container; nil; `.nothingStaged`

## Full detail

`NSEDataBridge.stagingPurgeTarget(...)` maps a **nil App Group container** to `.nothingStaged` — "we could not look" reported as "there is nothing there". That is the exact conflation the never-drop rule's clause 2 names as this codebase's most repeated defect class, in a path whose answer gates a purge. **FIXED (round 2):** a nil container now returns `.unreachable`, mirroring the sibling condition (a staging file that exists but will not open) that already reported failure — so both ways of failing to READ the staged state get the same disposition, and only the positive observation "container resolved, no staging file" reports nothing-staged. Both purge helpers therefore return `false`, and `runUidValidityResetReaction` holds the folder at its old epoch and quarantined. Pinned by `UidValidityResetPurgeCompanionTests.unresolvableStagingContainerIsNotAnEmptyStagingArea`.
