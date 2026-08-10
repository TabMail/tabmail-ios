# IOS-QUEUE-003

> Routed from `KNOWN_ISSUES.md` line 157 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `decomposed`
- Original row SHA-256: `4288eebefb8aded5bc77484295156fbd58c2ba504858d01157f64ee3b15a9d7c`

## Status

⚠️ **DECOMPOSED 2026-08-04 into NINE per-item dispositions — 3 ALREADY-CLOSED, 3 CLOSED-DECISION, and the 3 formerly-OPEN items are now ✅ FIXED by `2c0d47ed0`. ZERO live remainder.** The id is retained as a stable handle; the per-item table below is authoritative

## Subsystem and search terms

Action queue; F2b L4 demote lane; legacy unstamped rows; `ProviderNativeActionAdmissionTests`; `withRegisteredProvider`; 404-as-success; ungated diagnostic logs; `retainedForRetry`; `sweepStaleActionTags`; gmail-fixture retention

## Full detail

Carried forward unchanged from the previous round's register, none of them candidate-attributable: the F2b L4 demote lane; legacy unstamped rows parking permanently; `ProviderNativeActionAdmissionTests`' overclaiming *"Every ordinary IMAP producer …"* name; the six inline `withRegisteredProvider` sites; 404-as-success; ungated diagnostic logs; D-1 `retainedForRetry` being ownerless; D-2 `sweepStaleActionTags` starvation; and the D-5 gmail-fixture retention test.

⚠️ **THAT SENTENCE IS WHY THIS ROW SURVIVED EVERY AUDIT ROUND UNTOUCHED, AND IT IS THE FINDING.** Nine unrelated findings under one id cannot be adjudicated as a unit: any reviewer who reached it had to hold nine independent questions at once, so the row was carried "unchanged" round after round rather than decided. It is decomposed below and each item is disposed of on its own evidence. **The id is NOT retired and NOT renumbered** — it is referenced from commit bodies and prior rounds — but its live remainder is now exactly the three items marked OPEN, and nothing else.

✅ **THOSE LAST THREE ARE NOW CLOSED by `2c0d47ed0`, "Close the three live IOS-QUEUE-003 items: name, helper, log gating". THIS ID HAS NO LIVE REMAINDER.** ⚠️ **WHICH CENSUS WAS TAKEN, stated because two sources disagreed:** a triage document's summary table said *"4 already-closed / 3 fix-now / 2 closed-decision"* while its own per-item table said 3/3/3. **The per-item table is authoritative and is the one used**, and the implementing agent's independent re-census reproduced it exactly — items 1–3 ALREADY-CLOSED, 4–6 CLOSED-DECISION, 7–9 the live remainder. The summary line was simply wrong arithmetic over its own table; no item moved class. **Where the implementing agent's numbers differed from the REGISTER (item 8), the agent's committed census wins and this row is corrected below rather than left standing with a false count.** No production behaviour changed in that commit; its only production edits are logging gates.
