<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note — THIS FILE IS THE NORMATIVE STATEMENT OF THE NEVER-DROP INVARIANT.** Every
> other copy in the tree — `CLAUDE.md` § *Core Philosophy: Never Drop User Intention*, `DECISIONS.md`
> § *Foundational Principle: Never Drop User Intention*,
> `Companion/Decisions/foundational-principle.md`, and
> `Companion/Decisions/Active/adr-ios-067.md` — is a **pointer** to this file, not an independent
> statement of the rule. Where any of them differs, this file wins. Do not maintain a second
> enumeration.
>
> **2026-08-02 amendment (ADR-IOS-069, commit `3843940cb`): the enumeration in the frozen body below
> is amended from THREE exits to FOUR.** Read *"exactly THREE reasons — and no others"* as **"exactly
> FOUR reasons — and no others"**. Clauses 1, 2 and 3 are unchanged in substance and stand exactly as
> written below; the amendment **adds** an exit and **subtracts nothing**. The fourth exit is:
>
> 4. **Invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover, or
>    a provider stable-id reset, invalidates every queued op that named an address in the affected
>    space. Those ops are **dropped**: not rebound, not re-resolved, not re-searched, not
>    quarantined, not retried under the new numbering. v3 compares an op against its **durable**
>    `PendingOperation.observedUidValidity`, not against a selection minted inside the same call, so
>    once the folder's epoch provably moves, **every retry of that op fails identically and
>    forever** — the intention is dropped rather than executed under numbering it never observed. The
>    governing principle is **C3: no action may ever mutate the wrong message; failing closed is
>    always acceptable.** This is the only exit that is a failure, it is **deliberately narrow**, and
>    **nothing else may use it.** The user-visible cost is registered in `KNOWN_ISSUES.md` as
>    `IOS-EPOCH-001`, with the queued-gesture loss as `IOS-ACTION-002`.
>
> **Exit 4 does NOT widen clause 2, and may never be read as widening it.** Exit 4 fires only on a
> **proven** epoch change — a *positive* fact: an epoch the server actually reported, disagreeing
> with the epoch the operation durably recorded at admission. Clause 2's *unknown* epoch is its
> opposite — an **absence of evidence** — and remains **retryable forever**. Proven-changed and
> not-known are disjoint; a thrown read, an unresolvable identity, a failed durable write and an
> unobserved epoch stay retryable, never authoritative, and **never reach exit 4**. That distinction
> is the entire safety of this amendment: any change that blurs it converts the most-repeated defect
> class in this codebase into a sanctioned drop.
>
> A bounded, visible, retryable quarantine is still **not** a discard, and a transient failure is
> still **not** an exit. Never-drop holds in full on the ordinary path — offline, retry, app kill,
> provider error, transient read failure — and the carve-out does not extend past queue state:
> Outbox sends, user-authored drafts, bodies, attachments and FTS content are never dropped under it.
>
> **2026-08-03 amendment (audit round 2): the enumeration is about RUNTIME RETIREMENT, and there is
> one owner-approved LIFECYCLE class outside it.** The four exits above answer a single question —
> *may the drain retire THIS operation, on THIS attempt, given what the provider said?* They do not
> govern deliberate, owner-approved destruction of the queue as a whole at a **lifecycle boundary**:
> a schema upgrade, account removal, demo reset, or a full local wipe. Those are not the queue
> deciding an intention's fate on evidence; they are the queue, or the account it belongs to, ceasing
> to exist.
>
> The absolute needed this stated because a shipped migration already contradicts it:
> `v74_purgeLegacyPendingOperations` executes `DELETE FROM pendingOperation` with no predicate at an
> upgrade boundary. **v74 is already applied and therefore immutable** — a registered migration is
> frozen in name and body the moment any database has run it, so it cannot be edited and the clause
> cannot be repaired by changing the code. Its cost is registered as `IOS-ACTION-001`.
>
> **This carve-out is narrow and must never be read as widening the four exits.** It is
> distinguished by three properties, all required: it is **owner-approved and explicit**, never a
> code path deciding for itself; it destroys the queue **as a whole** at a boundary, never an
> individual operation on the strength of something observed about it; and it happens **outside the
> drain**, so no evidence, epoch, identity or provider result is consulted or needed. A runtime
> retirement that dresses itself in lifecycle language — "this op is legacy", "this shape is
> obsolete", "we are cleaning up" — is a drop, and must satisfy one of the four exits. And it does
> not extend past queue state either: the lifecycle boundaries above do not authorize destroying
> Outbox sends, user-authored drafts, bodies, attachments or FTS content.
>
> **2026-09-06 amendment (owner-approved): the APP-VERSION boundary is a standing member of that
> lifecycle class, not a one-off migration.** `AppDatabase.retirePreviousReleaseActionQueue` runs
> inside `AppDatabase.init`, on the raw pool, before `AppDatabase.shared` is published: if the
> recorded release in `appReleaseStamp` differs from the running one, every `pendingOperation` row is
> deleted **without being decoded**, every account is marked full-sync-due
> (`Account.lastFullSyncAt = NULL`), and the new release is recorded — all in **one transaction**, so
> either the whole boundary commits or none of it does and the next launch retries it. A missing
> stamp counts as a boundary (first adoption cannot know which release queued the rows); an
> **unchanged** release does not purge, so this is not a per-launch, per-foreground, per-login or
> per-retry clear.
>
> It satisfies all three carve-out properties: owner-approved and explicit; the queue **as a whole**
> at a boundary; **outside the drain**, consulting no evidence, epoch, identity or provider result.
> It is emphatically **not a fifth exit** — it answers no question about any operation. The accepted
> cost is that a user who updates while work is queued may have to repeat a gesture; the queue
> normally drains in seconds, so the reachable set is small, and the full sync restores the server's
> own state. `v74_purgeLegacyPendingOperations` remains the precedent for the PRINCIPLE only — it is
> a frozen one-shot migration and does not implement this rule. The carve-out's scope limit is
> unchanged: authored `Draft` and `outboxMessage` rows, mail, bodies, attachments and FTS content are
> untouched, and no draft sweeper or automatic re-admission is added to compensate — a retired
> `.saveDraft` loses only the automatic push intention, and reopening/editing/saving admits fresh
> work. `IOS-ACTION-001` is amended through the routed KnownIssues amendment surface to record that
> the blanket predicate-free purge is now a recurring launch rule rather than a single historical
> migration.
<!-- COMPANION-CURRENT-NOTE-END -->
## Core Philosophy: Never Drop User Intention

**This is the single most important principle in the entire codebase. Every system — actions, sends, tags — is built on it.**

User intention is sacred. When a user archives a message, sends an email, or changes a tag, that intention MUST survive any failure — crashes, disconnections, app kills, device reboots. The system achieves this through two complementary queues:

- **PendingOperation** (ADR-IOS-018) — for actions: archive, delete, move, read, flag, tag
- **OutboxMessage** (ADR-IOS-019) — for sends: compose and send email

Both follow the same contract:

1. **Persist before acknowledge.** The user's action is written to GRDB *before* the UI acknowledges success (dismiss, animate away, show confirmation). If persistence fails, the UI shows an error and does NOT dismiss. The database row IS the user's intention — if it exists, we will execute it.
2. **Optimistic UI, deferred execution.** Local state updates immediately (swipe-to-zap, compose dismiss). Remote execution (IMAP command, SMTP send) happens asynchronously via drain loops. The user never waits for a network round-trip.
3. **Survive everything.** Queue entries persist across: app backgrounding, app termination, crashes, device reboots, prolonged offline periods. On next launch/foreground/reconnect, the queue drains automatically.
4. **Remote state wins on conflict.** When sync discovers that the server state contradicts a queued action (e.g., message already deleted by another client), the queued op is silently dropped — server is the source of truth. But the user's *next* action always takes priority over stale server state.
5. **Treat remote actions as user actions.** IMAP tag updates from other TabMail instances (TB addon) are equivalent to local user actions. When consolidating, the most recent action wins — a remote tag change that arrives after a local queue entry overrides it. The queue is not privileged over remote state; both represent user intention from different devices.
6. **Never silently discard.** Failed sends stay visible in Outbox. Durable message actions retry transient failures without a retry cap. Automatic cleanup only happens for provably completed or provably stale operations.

   **A queued operation may leave the queue for exactly THREE reasons — and no others:**
   1. **Provider success.**
   2. **A provider-authoritative stale/no-op result** — the provider told us the work is already
      done or no longer applicable. *"We could not determine the answer" is NOT this.* A thrown
      read, an unresolvable identity, a failed durable write and an unknown epoch are all
      **retryable**, never authoritative. Conflating the two is the single most repeated defect in
      this codebase's history — it has produced never-drop violations in the notification path, the
      undo path, the intention fold and the queue's identity resolution.
   3. **Annihilation by a newer inverse user action** — a later action that exactly inverts an
      *unattempted* queued operation may delete it instead of queueing the inverse, because the
      pair is a no-op and executing both would cost two provider mutations for zero net effect.
      This is desirable, and it requires all of: the operation was **never attempted**, the members
      match **exactly**, and the new action is a true inverse. Anything weaker is a drop.

   *(Clause 3 was missing until the U2 audit, 2026-07-26. Its absence mattered: this sentence is the
   standard every unit audit in that train was judged against, so an incomplete invariant was
   shaping downstream verdicts — the same defect class the train kept finding in the code.)*

   **A bounded, visible, retryable quarantine is NOT a discard.** An intention that cannot be
   admitted after capped retries may be parked with its payload and failure reason, provided it
   stays visible and the user can retry it. That is the correct terminal state for a poison record —
   unbounded retry that never releases its caller is a liveness bug, not safety.

**When in doubt: persist the intention, retry later, show the user what happened.**

See ADR-IOS-001 (optimistic UI), ADR-IOS-003 (crash recovery), ADR-IOS-018 (action queue), ADR-IOS-019 (outbox).

---
