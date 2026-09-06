# IOS-ACTION-003

> **Post-freeze record.** Added 2026-09-06 through the amendment surface in
> `Scripts/compact_known_issues.rb`. It has no row in the hash-pinned archive and is not regenerated
> from it.
>
> **This record AMENDS [`IOS-ACTION-001`](../ios-action-001.md).** That row is a hash-pinned closed
> decision about ONE frozen migration and cannot be edited (Data Integrity rule 5 freezes `v74`'s
> name and body, and the register row carries the pre-split source hash). Its **scope** sentence —
> "an owner-approved **one-time** upgrade boundary" — is what changes here: the predicate-free purge
> is now a **recurring launch rule**, not a single historical migration. Everything IOS-ACTION-001
> says about `v74` itself, and its whole cost/recoverability argument, stands unmodified and is the
> basis this record reuses.

- Register classification: `accepted`.
- Relates to: [`ios-action-001.md`](../ios-action-001.md) (the one-time `v74` precedent this
  generalises), [`ios-action-002.md`](../ios-action-002.md) (the epoch-reset drop, a *runtime* exit
  and therefore a different class), `Companion/Rules/Active/never-drop-user-intention.md`
  (2026-09-06 amendment), `Companion/Decisions/V3/Active/adr-ios-071.md`.

## Status

✅ **ACCEPTED (2026-09-06, owner-approved)** — every app-release change retires the action queue.

## Subsystem and search terms

Action queue; `pendingOperation`; app upgrade; app version; release boundary; `appReleaseStamp`;
`retirePreviousReleaseActionQueue`; `currentAppRelease`; migration `v89`; blanket purge; lifecycle
carve-out; full sync due; `lastFullSyncAt`

## Full detail

`AppDatabase.retirePreviousReleaseActionQueue` runs inside `AppDatabase.init`, on the raw
`DatabasePool`, before `AppDatabase.shared` is published and therefore before anything in the process
can admit or claim work. If the release recorded in `appReleaseStamp` (migration `v89`) differs from
the running bundle's `CFBundleShortVersionString (CFBundleVersion)`, then in **one transaction**:
every `pendingOperation` row is deleted **without being decoded**, every account is marked
full-sync-due (`Account.lastFullSyncAt = NULL`), and the new release is recorded. Either all three
commit or none does; a failure propagates out of `init`, leaves initialization incomplete, and the
next launch retries the whole thing. A **missing** stamp counts as a boundary — first adoption cannot
know which release queued the rows it finds. An **unchanged** release does not purge: this is not a
per-launch, per-foreground, per-login or per-retry clear, and ordinary crash recovery
(`recoverPreviousSessionResidue`) is unchanged.

**Why this is not a fifth exit.** The four exits in `never-drop-user-intention.md` answer *"may the
drain retire THIS operation, on THIS attempt, given what the provider said?"*. This boundary answers
nothing about any operation: it consults no evidence, no epoch, no identity and no provider result,
it destroys the queue as a whole, it runs outside the drain, and it is explicitly owner-approved —
all three carve-out properties. A runtime retirement dressed in this language would still owe one of
the four exits.

**Accepted cost.** A user who updates the app while work is queued may have to repeat a gesture. The
queue normally drains in seconds, so the reachable set is small; the full sync that the same
transaction schedules restores the server's own state for any optimistic local change the retired
operation would have carried. **Recoverability:** every retired op's target is still visible after
that sync, so the gesture is re-issuable — the same argument IOS-ACTION-001 established for `v74`,
re-checked against the recurring case.

**Scope limit, unchanged from the carve-out.** Authored `Draft` and `outboxMessage` rows, mail,
bodies, attachments and FTS content are untouched; `pendingOperation` owns no authored bytes and
nothing cascades from it. A retired `.saveDraft` loses only the automatic server-push intention — the
local `Draft` keeps its content and reopening/editing/saving admits fresh work. **No draft sweeper
and no automatic re-admission are added**, and sync alone does not upload content that never reached
the server; a never-uploaded draft stays a draft until the user saves it again.

**Why a blanket purge rather than a version-aware migration.** The same reason IOS-ACTION-001 gives
for `v74`: deciding per row would mean decoding each one and validating its address space against
whatever keying the previous release used — the "reconstruct an address the system was already told
and discarded" pattern `MIS-IOS-003` and `CLAUDE.md`'s *THE ADDRESS PROBLEM* forbid. The boundary
deliberately holds no per-operation version field, no ordering backfill and no replay history.
