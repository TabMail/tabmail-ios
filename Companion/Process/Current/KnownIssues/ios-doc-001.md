# IOS-DOC-001

> Routed from `KNOWN_ISSUES.md` line 444 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `193330da19ecd82c7fd95bb7286f4eae50d880ad5cbdaac1361b0d588be6be10`

## Status

✅ **CLOSED AS A DECISION (2026-08-04)** — ⚠️ **the item's own premise was FALSE and is refuted here by measuring the right artifact**

## Subsystem and search terms

Documentation; `tabmail-ios/CLAUDE.md`; companion budget; `compact_companion_docs.rb verify`; working tree vs committed; un-routed duplicate bodies; `Companion/Rules/Active/resilience.md`; `Companion/Rules/Active/user-interaction-freeze.md`

## Full detail

**This was carried as *"`CLAUDE.md` is 40,401 B against a 30,000 B budget (+34 %), the sole remaining verify violation"*. ⚠️ THAT IS FALSE OF THE REPOSITORY, and it dissolves the moment the committed file and the working tree are measured separately.** `git show HEAD:CLAUDE.md` is **15,176 B — 49 % HEADROOM, comfortably passing**; the working tree is 40,401 B; the difference, **25,225 B, is UNCOMMITTED OWNER CONTENT** (THE MANTRA, THE ADDRESS PROBLEM, and the A1–A13 audit-supervision block). **The repository does not violate the budget.** `Scripts/compact_companion_docs.rb verify` measures the **working tree**, so it reports a violation the committed repo does not have. **Record that, because the next agent to run `verify` will otherwise re-open this row and re-derive the same wrong conclusion.** **What IS real, and is still not worth landing:** two byte-identical twins remain in the *committed* file — `## Resilience Rules` ≡ `Companion/Rules/Active/resilience.md` (**1,977 B**, measured) and `## User Interaction Freeze Rule` ≡ `Companion/Rules/Active/user-interaction-freeze.md` (**1,184 B**, measured). Both bodies were diffed: **IDENTICAL**. They are genuine un-routed duplicates of the `23ea83b62` class. **DISPOSITION: CLOSED AS A DECISION — do not route. Three grounds, in order of weight.** **(1)** It buys **3,161 B** against a budget already met with **49.4 % headroom** (all four figures re-measured for this row, not transcribed). There is no problem to solve. **(2) It cannot land cleanly.** `git add CLAUDE.md` stages the whole file, sweeping the owner's 25,225 B of uncommitted work into someone else's commit — which the standing constraint forbids outright. Partial-hunk staging on a file the owner is actively editing is the wrong trade for 3 KB of hygiene. **(3)** The only edit that would move the working-tree number is routing A1–A13 out, and that is **plausibly harmful** rather than neutral: A9's own text reads *"This gets forgotten after every compaction; re-read it on resume."* Those rules are written to be always-loaded, and routing makes them search-conditional. **Stated as a consideration, not an absolute** — a future owner may reasonably decide the index budget outranks it, and this row is the place to argue against, per the register's own instruction for decision rows. **Accepted cost:** `verify` continues to report a `CLAUDE.md` budget violation against the working tree for as long as the owner's uncommitted block sits there. **Recoverability is not the relevant test** — nothing is refused or deferred by this decision and there is no failure state to recover from; the cost is a noisy verify line, never a lost or misdirected message.
