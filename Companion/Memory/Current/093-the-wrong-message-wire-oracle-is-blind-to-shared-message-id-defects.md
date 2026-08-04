## The wrong-message wire oracle is structurally blind to shared-Message-ID defects (2026-08-04)

**Surfaced by the B1 implementing agent while red-proving the draft-SEARCH fix
(`459786db1`); verified against the code by the coordinator.**

`FakeIMAPServer`'s `WrongMessageViolation` oracle is this repo's generic C3 harness — the
one global Testing rule 12 tells you to extend rather than write a one-off. **It cannot see
a defect whose precondition is that the target and the bystander share one RFC 822
Message-ID.** That is not a gap to patch opportunistically; it follows from how the oracle
discriminates, so a test that "uses the oracle" against such a defect is **vacuous while
looking rigorous**.

### The mechanism, exactly

`recordMutation` (`TabMailTests/Infrastructure/FakeIMAPServer.swift`, the loop ending in
`state.wrongMessageViolations.append(...)`) does:

```swift
guard let msg = byUid[uid] else { continue }
let actualRfc = Self.normalizeOracleRfc(msg.messageID)
guard !state.expectedMutationRfcs.contains(actualRfc) else { continue }   // ← the blindness
state.wrongMessageViolations.append(WrongMessageViolation(...))
```

The oracle's whole notion of "wrong message" is **RFC-identity set membership**:
`expectMutation` registers the intended target's Message-ID, and any mutation whose
occupant carries an RFC id in that set is declared correct. So when the wrong message
carries the *same* Message-ID as the intended one, `actualRfc` **is** in
`expectedMutationRfcs`, the `guard` `continue`s, and **no violation is ever appended** — the
mutation landed on a different physical message, and the oracle reports clean.

### Why this bit exactly here

The B1 defect (`saveDraft`'s no-`APPENDUID` arm minting a draft address from a
`searchByMessageId` hit) **requires** the duplicate to exist: the SEARCH only returns a
sibling *because* that sibling shares the Message-ID. The precondition of the bug is
precisely the precondition of the oracle's blind spot. Asserting
`wrongMessageViolations().isEmpty` there would have passed on the **pre-fix** code.

That is the same shape as the ten blessing tests recorded in
`project_audit_found_blessing_tests_class` — green, plausible, and pinning nothing.

### What to do instead — and when

**When target and bystander are distinguishable by Message-ID, keep using the oracle.** It
is correct and load-bearing for the epoch/renumber family it was built for (INV-2, the
UIDVALIDITY reset closure), where the whole point is that a UID's occupant becomes a
*different* message with a *different* RFC id.

**When they are not, pin on evidence the oracle does not consult:**

1. **Physical wire state** — assert the bystander's message object still *exists* in the
   fake server's mailbox after the operation. A destroyed draft is gone from `byUid`
   regardless of what its Message-ID was.
2. **The command log** — assert no `UID STORE`/`UID EXPUNGE` naming that UID was ever
   issued. B1's red proof did this and observed the pre-fix run mint `uid: 51`, the
   bystander, then physically destroy it after `UID STORE` and `EXPUNGE`.

Identity-by-RFC is the wrong instrument for a mutation-target question, which is the same
asymmetry `ADR-IOS-068`/D4 states for production code: **RFC proves content identity, never
mutation-target authority.** The oracle inherited the production-side asymmetry into the
test harness, where it reads as a general C3 check and is not one.

### Standing caution

Do **not** "fix" the oracle by making it discriminate on UID instead of RFC — the RFC
comparison is what makes it correct across a renumber, which is its primary job. If a
second shared-Message-ID defect appears, build a **separate** physical-identity oracle
alongside it (per global Testing rule 12's build-the-harness-on-the-second-instance bar)
rather than overloading this one.

**Related:** [[project_two_keying_schemes_rationale]] (epoch proves NUMBERING, RFC proves
IDENTITY), `ADR-IOS-068`/D4, `KNOWN_ISSUES.md` `IOS-IMAP-002` and `IOS-BACKFILL-002`.
