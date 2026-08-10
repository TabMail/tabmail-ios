# IOS-TEST-005

> Routed from `KNOWN_ISSUES.md` line 345 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `fbaf5030189f044062b62b4a2994a592723fa76f4c6c3e700608cb078fd01dfd`

## Status

Surfaced by final train **round 2** (Claude reviewer); **class A**; cosmetic; ✅ **FIXED by `b87804055`**

## Subsystem and search terms

Tests; `IMAPSaveDraftIdentityTests`; display name overstates the assertion; sibling of the correctly re-scoped blessing test

## Full detail

**A sibling test's display name still names cardinality as the operative condition after the outcome became unconditional.** `459786db1` correctly re-scoped the blessing test `nonUidPlusUniqueExactMatch` → `noAppendUidRefusesTheUniqueExactMatch`, recording that the old name asserted the defect. Its neighbour, *"Non-UIDPLUS APPEND with duplicate exact matches returns unaddressable"*, still reads as though duplicate-match cardinality is what produces `.unaddressable`, when absence of `APPENDUID` alone now does. The body carries a comment saying so; the **display name** does not. Same class as `IOS-ROUND3-D5` and `IOS-TEST-004`: a name that claims more than its assertions check.

✅ **FIXED by `b87804055`.** **The invariant that now holds:** the display name states the operative condition, which is the ABSENCE of `APPENDUID` and not duplicate-match cardinality. `IMAPSaveDraftIdentityTests.nonUidPlusDuplicateExactMatch` is now *"Without APPENDUID no address is minted, and duplicate exact matches do not change that"* — which says both halves: what produces `.unaddressable`, and that cardinality is explicitly not part of it. The retired name is recorded inline, matching how its already-re-scoped sibling (`nonUidPlusUniqueExactMatch` → `noAppendUidRefusesTheUniqueExactMatch`, `459786db1`) was handled.
