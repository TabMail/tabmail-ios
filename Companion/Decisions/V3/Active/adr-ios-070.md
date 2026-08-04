## ADR-IOS-070: Withdrawal Record — the Post-`v1.6.38` Intention/Identity Line Is Withdrawn, Not Superseded

**Date:** 2026-08-02

**Status:** Active withdrawal record. Precedent: ADR-IOS-064 — *"inert code is removed, applied
migrations are not."*

**Context.** Between `v1.6.38` (`07a4bb703`) and `v2final` (`e28dd4edb`) a 58-commit line built an
RFC-822 / hybrid identity model with an epoch ledger, quarantine, rebinding and a global intention
journal. **That line never shipped to a user device** — `project.yml` at its head is byte-identical
to `v1.6.38:project.yml`. v3 branches from `v1.6.38` and carries the bugfixes forward; it does not
branch from that line and revert.

A record that describes a build no user ever ran cannot be *superseded*, because superseded implies
"this was the behavior, and now it is not". It must be **withdrawn**.

**Decision.**

1. **Withdrawn, not superseded:**
   - **ADR-IOS-058** — the intention journal. Salvage only its never-drop / typed-receipt wording,
     which lives on in ADR-IOS-069's exit enumeration.
   - **ADR-IOS-060** — its FIFO half is **re-derived from ADR-IOS-003 / ADR-IOS-018**, which did
     ship and remain the base records for v3's queue; its identity half is withdrawn by
     ADR-IOS-068.
   - **ADR-IOS-061** — the epoch ledger, quarantine, refusal contract and rebinding are withdrawn.
     **Two carve-outs survive:** the purge-and-resync reaction to a UIDVALIDITY change, and the
     invariant-test layer.
   - **ADR-IOS-063** — defers a change to code that will not exist.
   - **The epoch clause of ADR-IOS-065.** The restored Undo-Send close prompt is satisfied by the
     base and survives; the epoch rotation does not.
2. **ADR-IOS-059 is not withdrawn — its principle is ported.** *A folder role is never identity;
   Undo resolves by a recorded tuple and drops on any mismatch* is base-independent and exactly
   D4-shaped. It is folded into ADR-IOS-068 §6.
3. **ADR-IOS-066 is ported as NEW WORK, not carried.** The base does not have the property it
   asserts. See ADR-IOS-072.
4. **ADR-IOS-067 is ported and amended**, with the fourth exit added by ADR-IOS-069.
5. **ADR-IOS-062 was never an ADR.** It appears in no `DECISIONS.md` at either tag and has no
   detail file; it exists only in an untracked draft headed **DRAFT**. The number is unused.
6. **ADR-IOS-057 is RE-ACTIVATED, resolving its orphaned supersession.** 057 **shipped**. It was
   superseded by ADR-IOS-058 — which never shipped — leaving 057 *superseded by nothing*. The
   decisive fact: **ADR-IOS-049 and ADR-IOS-055/056/057/058's read-model family are already in
   `v1.6.38`**; `InboxListComposer.swift` and `ThreadGroupBuilder.swift` are listed at that tag and
   their diffs across the reference range are cosmetic. v3 already has 057's behavior, shipped and
   running. **Do not leave ADR-IOS-057 marked `Superseded`** — as of this record it is **Active**.
7. **Applied migrations are never removed** (ADR-IOS-064's precedent). Migration identifiers are
   immutable once any database has run them. v3's chain resumes at **`v68`, contiguous, no gap**,
   which is safe only because the owner deleted every GRDB database carrying the unreleased
   `v68`–`v91` identifiers on 2026-07-30, so no device holds them in its applied-migration ledger.
   That predicate is recorded in the migration file itself; no runtime detection exists.
8. **Nothing is deleted.** `v2final` (`e28dd4edb`) and `backup/origin-main-pre-v3-20260730` are
   preserved refs, created before any v3 work began. Every withdrawn ADR body remains readable
   there and is the reference implementation this train ports from — its **code** was never the
   problem; its **keying** was.

**Rationale.** Recording the withdrawal explicitly is what prevents a future reader from
"restoring" a record that describes a build that never ran, and what prevents the ADR-IOS-057
inversion — the repo asserting that live shipped behavior is superseded by a withdrawn record —
from recurring. The numbering gap in this file is a pointer to this record, not an accident.

**Consequences.**

- Roughly 4,300 production lines from the reference line are simply never written. That is not work
  removed; it is work never undertaken.
- Anyone grepping for ADR-IOS-058/060/061/063 in code will find nothing, by design. Anyone reading
  those numbers in an old plan file must read this record first.
- ADR-IOS-057's re-activation is close to mechanical: no behavior changes, because the behavior is
  already the base's.

**Relates:** ADR-IOS-057 (re-activated by this record), ADR-IOS-059 / 066 / 067 (ported, not
withdrawn — see 068, 072, 069), ADR-IOS-064 (precedent), ADR-IOS-068, ADR-IOS-071.

---

