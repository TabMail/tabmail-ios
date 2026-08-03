<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note — THE BODY BELOW IS THE PRE-HARDENING `v1.6.38` WORDING AND IS SUPERSEDED
> IN PLACE.** It is preserved verbatim as the shipped-release text and stays routed and searchable;
> it is **not** the rule. **The normative statement of the never-drop invariant is
> `Companion/Rules/Active/never-drop-user-intention.md`, including its current routing note.** Where
> the two differ, that file wins — it is strictly stricter, and this body's *"Never silently discard
> user work — failed operations remain visible… Automatic cleanup only applies to provably-completed
> operations"* predates the exit enumeration entirely and must not be read as permitting anything the
> Rules file forbids.
>
> **The enumeration this body lacks (ADR-IOS-067 as amended by ADR-IOS-069, commit `3843940cb`): a
> queued operation may leave the queue for exactly FOUR reasons — and no others:** (1) provider
> success; (2) a provider-authoritative stale/no-op result — *"we could not determine the answer" is
> NOT this*: a thrown read, an unresolvable identity, a failed durable write and an **unknown** epoch
> are all **retryable**, never authoritative; (3) annihilation by a newer exact inverse user action,
> only when the earlier operation was **never attempted** and the members match **exactly**; (4)
> **invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover or
> provider stable-id reset drops every queued op that named an address in that space, because v3
> compares against the op's **durable** `PendingOperation.observedUidValidity` and executing under
> numbering the op never observed would mutate the wrong message (**C3**; `KNOWN_ISSUES.md`
> `IOS-EPOCH-001` / `IOS-ACTION-002`).
>
> **Exit 4 does not widen clause 2.** Exit 4 requires a **proven** epoch change — a *positive* fact.
> Clause 2's *unknown* epoch is an **absence of evidence** and stays retryable forever. The two are
> disjoint. Exit 4 is deliberately narrow and nothing else may use it; a bounded, visible, retryable
> quarantine is not a discard, and a transient failure is not an exit.
<!-- COMPANION-CURRENT-NOTE-END -->
# TabMail iOS - Architectural Decisions

> **Check this file before proposing alternatives.** For cross-cutting decisions, see `../DECISIONS.md`.

---

## Foundational Principle: Never Drop User Intention

The following ADRs (001, 003, 018, 019) form a unified system built on one principle: **user intention must never be lost.** When a user performs an action — archive, delete, send, tag — that intention is persisted to the database before the UI acknowledges success. Remote execution is deferred and retried until complete or provably unnecessary.

**Key invariants across all queue-based systems:**

- **Persist → Acknowledge → Execute** — database write happens before UI dismissal/animation. If persist fails, the user sees an error and retains their data (compose stays open, action is not animated).
- **Remote state wins on conflict** — when sync reveals the server already reflects the desired state (message deleted by another client, tag set by TB addon), the queued operation is silently dropped. The server is the source of truth.
- **Treat all instances equally** — IMAP keyword changes from another TabMail instance (e.g., TB addon setting `tm_archive`) are treated as equivalent to local user actions. When consolidating, the most recent writer wins regardless of which device originated the action. The queue is not privileged over remote state.
- **Never silently discard user work** — failed operations remain visible for user action (retry/dismiss). Automatic cleanup only applies to provably-completed operations.

---
