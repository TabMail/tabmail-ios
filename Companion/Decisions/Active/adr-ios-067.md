<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** 2026-07-29 release-range follow-up closes a cross-commit ownership gap in the retained-residual implementation. One quarantine row may own several members, while role moves commit per account and manual tags commit per member. Each successful transaction now atomically removes only its admitted members from that row's existing payload (including display and expected-identity entries), deleting the row only after its final member commits. A failed later transaction therefore remains durably recoverable at every commit boundary; sequence, attempt/state, retry timing, typed receipt, and quarantine-cap semantics are unchanged.
>
> **2026-08-02 — the heading below, and its "exactly three reasons" count, are AMENDED, not
> retracted.** ADR-IOS-069 (`DECISIONS.md`; commit `3843940cb`) adds a **fourth** exit:
> **invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover or
> provider stable-id reset drops every queued op that named an address in the affected space,
> because v3 compares an op against its **durable** `PendingOperation.observedUidValidity` rather
> than a selection minted inside the same call, so once the epoch provably moves every retry of that
> op fails identically and forever (**C3**: no action may ever mutate the wrong message; failing
> closed is always acceptable — `KNOWN_ISSUES.md` `IOS-EPOCH-001` / `IOS-ACTION-002`). Exit 4 turns
> on a **proven** epoch change, a *positive* fact; it never turns on the *unknown* epoch of exit 2,
> which is an **absence of evidence** and stays retryable forever. It is deliberately narrow and
> nothing else may use it; the five decisions below are unaffected. The heading is kept **verbatim**
> as this record's historical title, which ADR-IOS-069's `Relates:` line cites as *"the three exits
> this amends"*. **Normative statement of the invariant:
> `Companion/Rules/Active/never-drop-user-intention.md`, including its current routing note** — this
> ADR is a pointer to it.
<!-- COMPANION-CURRENT-NOTE-END -->

## ADR-IOS-067 — A queued intention leaves the queue for exactly three reasons, and a failure is never one of them

**2026-07-27. Accepted. Landed `b1c89ad`. Found by the per-unit audit train (unit U3a).**

### Context
`executeFold` removed consumed records and resumed their receipts **unconditionally**, while every
action method it called swallowed its transaction failure and returned a success-shaped empty
result. So a failed durable admission left the intention **nowhere** — no operation, no local
mutation, no journal record, no retry, no error.

Worse, `recordAndWait` resolved to a set computed *before* the fold ran, so it was non-empty
regardless of outcome. The archive tool reported `"success": true, "archived_count": N` **for mail
still sitting in the Inbox**, and the notification path logged a success-shaped line. A swallowed
admission failure was indistinguishable from success at every caller.

What made it a defect rather than an accepted trade-off: the *read*-error path already retained and
retried correctly. The *write*-error path had no equivalent.

### Decision
1. **Completion is decoupled from consumption.** The awaiting caller is resumed in every case —
   otherwise it strands forever — but a record is dropped only once its durable work landed.
2. **Outcomes are typed, per id AND per phase** (`retainedForRetry` vs `terminalStale`). A retained
   phase is **never** collapsed into `failed_ids`: telling an agent a still-pending action failed
   invites it to retry and act twice. *Pending is not failure.*
3. **Residual work splits by id and phase**, so a phase that committed is never replayed.
4. **A repeatedly failing admission ends in a bounded, visible, retryable quarantine** — which is
   not a discard, because it is neither consumed nor silently dropped.
5. **Retry is capped and always releases the receipt.** The first version retried forever *before*
   delivering the receipt, turning "never drop the intention" into "never terminate" — and because
   the fold runs on the serial write queue it stranded every write behind it.

The core-philosophy invariant was amended in the same work (`07f9d18`) to admit its missing third
exit — annihilation by a newer inverse action — because the incomplete sentence was the standard
every audit in this train was judged against.

### Consequences
This covers the **five journal-mediated admission sites only**. Eight others bypass the journal
entirely and each needs its own audit; this does **not** close the admission-failure class, and the
commit says so.

**Deliberately unchanged:** gesture and Undo intentions remain memory-only until the fold runs. That
is a recorded trade-off — a durable per-tap INSERT is ruled out twice over (the zero-DB gesture
contract, and writer starvation reintroducing the dead-toggle hang).

**Relates:** ADR-IOS-060 (durable intentions), ADR-IOS-018 (action queue), ADR-IOS-066.
