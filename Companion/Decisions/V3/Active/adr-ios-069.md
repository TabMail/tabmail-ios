## ADR-IOS-069: An Id Reset Invalidates the Affected Queued Ops — They Are Dropped, Not Rebound

**Date:** 2026-08-02

**Status:** Active. **Amends ADR-IOS-067's exit enumeration with a fourth exit.** Withdraws the
rebinding/quarantine machinery of the unreleased ADR-IOS-061 (see ADR-IOS-070). Owner constraints
C2, C4 and C5, frozen 2026-07-30.

**Context.** "Never drop user intention" (the foundational principle at the head of this file) has
governed every queue in this app since ADR-IOS-003. The unreleased line took it literally across an
identity boundary and grew an epoch ledger, a quarantine, a refusal contract and a rebinding
protocol so that a queued op could survive a UIDVALIDITY change — roughly 600 lines whose entire
purpose was to re-point an intention at a message whose address had been reissued. That is a
**compensating mechanism**: every edge case of the reset became an edge case of the restoration.

The owner's ruling: ***"much better than a fragile and complicated codebase."***

**Decision.**

1. **A UIDVALIDITY change, or a provider stable-id reset, INVALIDATES every queued op that named an
   address in the affected space.** Those ops are **dropped** — *not* rebound, *not* re-resolved,
   *not* re-searched, *not* quarantined, *not* retried under the new numbering.
2. **This is a fourth exit from the queue**, and it is the only one that is a failure. Restating the
   full enumeration: a queued intention leaves the queue for exactly these reasons —
   1. provider-confirmed success;
   2. a provider-authoritative stale/no-op result (absence, a thrown read, an unresolved identity, a
      failed write and an unknown epoch are **retryable**, never authoritative);
   3. annihilation by a newer exact inverse user action, only when the earlier operation is
      unattempted and the members match exactly;
   4. **invalidation by an id reset in its own address space** — this record.
   Exit 4 is deliberately narrow. **Nothing else may use it.** A bounded, visible, retryable
   quarantine is not a discard, and a transient failure is still not an exit.
3. **"Never drop user intention" holds in full on the ordinary path** — offline, retry, app kill,
   provider error, transient read failure. Only the id-reset boundary is carved out.
4. **The carve-out does not extend past queue state.** Outbox sends, user-authored drafts, bodies,
   attachments and FTS content are never dropped under this ADR. Double-send prevention is
   unchanged, non-negotiable and independent of identity keying.
5. **The signal on refusal is a log, and nothing else.** Drop the refused **whole** operation, never
   a split subset and never unrelated queued work. If the deletion write itself fails, requeue that
   original operation unchanged and stop.
6. **Once dropped, dropped.** v3 compares against the op's **durable** `observedUidValidity`, not
   against a selection minted inside the same call. The reference's refusal silently re-armed on
   retry; v3's does not — **once the folder's epoch moves, every retry of that op fails identically
   and forever.** The intention is dropped rather than executed under numbering it never observed.

**Rationale.** The user's cost is one repeated gesture. The alternative's cost is a rebinding
protocol on the exact path where every wrong-message defect in this app has lived. Sync reconciles
the visible state; the user redoes the action. An intention executed under numbering it never
observed is not the user's intention — it is a mutation of whatever message now holds that address,
which is precisely what C3 forbids.

**Consequences.**

- A UIDVALIDITY turnover during a burst of queued gestures loses those gestures. This is
  user-visible and is recorded as `IOS-ACTION-002` **precisely because it is a deliberate departure
  from never-drop**.
- The rare-but-real window is bounded: `3843940cb`'s accepted residual is a turnover landing between
  the COPY and the pre-STORE assertion, which leaves the copy at the destination and the original at
  the source. Sync reconciles it, and it is strictly safer than completing the delete.
- The UIDPLUS gate in the move sequence is checked **before** the final assertion, deliberately:
  asserting first would let an epoch change refuse an already-complete op, and a refusal after a
  successful COPY retries into a duplicate at the destination.

**Tests / evidence.** `3843940cb` — the epoch-assertion suite, with the durable-epoch comparison
(rather than a call-local `Selection`) as the property under test.

**Relates:** ADR-IOS-068 (what the recorded identity is), ADR-IOS-067 (the three exits this amends),
ADR-IOS-027 / ADR-IOS-018 / ADR-IOS-003 (the FIFO charter), ADR-IOS-070, `KNOWN_ISSUES.md`
(`IOS-ACTION-002`, `IOS-EPOCH-001`).

---

