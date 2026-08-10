# IOS-DRAFT-017

> Routed from `KNOWN_ISSUES.md` line 1094 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `20b9cf2b3ba193652054e2a4f50f6f0b85a9cfa700d36dca9c0df441ba085ce4`

## Status

✅ **CLOSED AS A DECISION (2026-08-05, round-10 F12)** — migration `v79_addDraftLastTouchedSeq`'s safety justification named the `draft` eviction cap as the bound on its table's size. **It is not a bound.** `DraftStore.evictImpl` `continue`s over inbox-tied exempt drafts WITHOUT counting them toward `kept`, so exempt rows are not merely retained past the cap, they do not consume it — the retained set is `cap + |exempt|`, and `|exempt|` is bounded by the user's inbox, not by the cap. **Comment corrected in place; the `v79` BODY IS UNCHANGED (a migration is immutable once applied) and the eviction exemption is UNCHANGED — the exemption is deliberate and load-bearing.** The migration's actual cost, measured in round 8 (A4) on a Mac and stated device-adjusted ×2–4 per this repo's standing rule: **100 rows 2 ms · 300 rows 9 ms · 1,000 rows 93 ms · 3,000 rows 841 ms**. **RECOVERABILITY, with the non-recovering case named:** the cost is a one-time migration pause proportional to the retained draft count; it recovers by completing. What does NOT self-heal is a user whose exempt population is large enough for the 3,000-row tier — the migration is still bounded and still completes, but the launch pause is user-visible and there is no incremental path

## Subsystem and search terms

drafts; migration `v79`; `lastTouchedSeq`; `DraftStore.evictImpl`; eviction cap; inbox-tied exempt drafts; `kept`; migration timing

## Full detail

Comment-only correction. Do NOT edit the `v79` body and do NOT change the eviction exemption to "fix" the cap.
