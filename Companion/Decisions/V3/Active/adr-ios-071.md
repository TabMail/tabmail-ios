## ADR-IOS-071: No Backward Compatibility for the Action Queue

**Date:** 2026-08-02

**Status:** Active. Owner constraints C1 and C6, frozen 2026-07-30; the blanket purge is
owner-authorized.

**Context.** Changing the durable action key (ADR-IOS-068) makes every pre-existing
`pendingOperation` row's payload uninterpretable under the new identity rule. The reference line's
answer was to retain and migrate those rows, because that line's policy was survival across identity
churn. v3's policy is not.

Owner: ***"no compat required. even fixes to action queue can simply drop old ops in 1.6.38 since
ops are short lived and not catastrophic when dropped."***

**Decision.**

1. **Nothing migrates old queue rows into a new shape.** There is no payload decoding, no shape
   migration, no legacy slot handling, no provider/runtime-mismatch fence and no pre-F1
   compatibility path.
2. **The one-time migration is a blanket, predicate-free purge** — `DELETE FROM pendingOperation`,
   landed as immutable migration **`v74_purgeLegacyPendingOperations`**. It removes every legacy row
   regardless of type, status, decodability or shape: queued, `inFlight`, cancelled, unknown,
   malformed, `.saveDraft` and `.deleteDraft`.
3. **`PendingOperation` owns no authored bytes.** It has no cascade into `Draft`, `Outbox`,
   `MessageBody` or attachment storage. Draft identity, body, recipients and attachments, and Outbox
   sends, live separately and remain byte-identical across the purge.
4. **The C6 boundary — do not over-apply this.**

   | Drop freely | Never drop — never-drop applies IN FULL |
   |---|---|
   | Every `PendingOperation` row, including `.saveDraft` / `.deleteDraft` | **Outbox / pending sends** — a dropped send means the user's mail silently never goes out |
   | | **Drafts / user-authored content** — identity, body, recipients and attachments |
   | | **Bodies, attachments, FTS content** — these are not queue state |

5. **No transitional RFC-only bypass.** A compatibility bypass for legacy RFC-shaped ops was
   proposed and **rejected**: C1/C6 require no legacy compatibility and C3 permits failing closed.
   During development an intermediate gate may drop every legacy RFC-shaped op; for release the
   admission gates and the native direct producers **co-land as one exact candidate** and neither
   half may ship alone.

**Rationale.** Action ops are short-lived and individually cheap to redo. Retaining them across an
identity change buys nothing and costs a decoder for shapes the new code cannot honour — a decoder
that is, by construction, the least-tested code in the queue. A one-statement purge has no failure
mode that a shape migration does not also have.

**Consequences.**

- **Accepted one-time upgrade loss**, recorded as `IOS-ACTION-001`: any op queued by a pre-v3 build
  and not yet drained at upgrade is gone. Sync reconciles the visible state.
- Dropping a `.saveDraft` loses only the **automatic server-push intention**. Sync does not recreate
  or upload it; the user explicitly saves again, which admits a fresh, safe operation. The local
  `Draft` row keeps the content.
- Dropping a `.deleteDraft` may leave a stale server draft that sync shows again. That is safer than
  retaining an obsolete destructive address; the user redoes the delete.
- Startup still independently runs Outbox reconciliation after the now-empty message queue, so
  queued / sending / sent-append recovery is unchanged.

**2026-09-06 amendment (owner-approved): the purge is no longer ONE-TIME — it is a standing
app-release boundary.** Everything above stands; what changes is decision 2's word *one-time*.
`AppDatabase.retirePreviousReleaseActionQueue` runs inside `AppDatabase.init`, on the raw
`DatabasePool`, before `AppDatabase.shared` is published, and on any change of installed release —
`CFBundleShortVersionString (CFBundleVersion)`, compared against the release recorded in
`appReleaseStamp` (migration **`v89_createAppReleaseStamp`**) — it performs the same predicate-free
`DELETE FROM pendingOperation`, sets `Account.lastFullSyncAt = NULL` on every account, and records
the new release, **all in one transaction**. Either all three commit or none does; a failure
propagates out of `init`, leaves initialization incomplete, and the next launch retries.

The rationale is decision 2's, generalised: the reason not to decode a previous build's rows is not
that v3 changed the key ONCE, it is that any release may change what an operation MEANS, and
deciding per row would require exactly the decoder this ADR refuses to write. A **missing** stamp is
a boundary (first adoption cannot know which release queued the rows it finds); an **unchanged**
release does **not** purge, so this is not a per-launch, per-foreground, per-login or per-retry
clear, and `recoverPreviousSessionResidue` is untouched.

`v74` remains what it always was — a frozen one-shot migration and the precedent for the PRINCIPLE
only. The C6 table above is unchanged and still binding: the boundary destroys queue state and
nothing else, and no draft sweeper or automatic re-admission is added to compensate. The recurring
cost is registered as `IOS-ACTION-003`, which amends `IOS-ACTION-001`'s "one-time" scope; the
lifecycle carve-out this operates under is stated in
`Companion/Rules/Active/never-drop-user-intention.md` (2026-09-06 amendment) — it is **not** a fifth
exit, because it answers no question about any individual operation.

**Relates:** ADR-IOS-068, ADR-IOS-069, ADR-IOS-070 (migration immutability precedent),
`KNOWN_ISSUES.md` (`IOS-ACTION-001`, `IOS-ACTION-003`), migrations
`v74_purgeLegacyPendingOperations` and `v89_createAppReleaseStamp`,
`Companion/Rules/Active/never-drop-user-intention.md`.

---

