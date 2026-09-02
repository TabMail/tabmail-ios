# IOS-NSE-008

> **Post-freeze record.** Added 2026-09-02, after the 2026-08-09 hierarchy freeze, through the
> amendment surface in `Scripts/compact_known_issues.rb`. It has no row in
> `known-issues-pre-hierarchy-2026-08-09.txt` and is deliberately not regenerated from that archive.

- Register classification: `open`
- Disposition: 🔓 **OPEN (2026-09-02)** — filed alongside the change that made the notification
  service extension's identity mirrors refresh on account add. Residuals A and B below are
  *narrowed* by that change and neither is created by it in the general case; Residual C predates it
  and is neither narrowed nor widened by it. The one genuinely new window (a re-derivation
  straddling a removal) has **not** been accepted by the owner and is carried here rather than
  absorbed silently.

## Status

🔓 **OPEN — three residuals in the App Group identity mirrors: two convergence windows and one
key-slot collision.**
The extension resolves a push through two mirrors it cannot re-derive itself: `nse.accountMap`
(address → account id) and `nse.imapAccounts` (account id → connection info). They are pure derived
state re-computed by `NSEDataBridge.mirrorAccountIdentity()`. Two *timing* windows remain where a
mirror can disagree with the database: a re-derivation whose read straddles a concurrent account
removal can briefly restore the removed account's entries (A), and an edit to a *mirrored column* of
an existing account converges only at the next re-derivation rather than at the write (B). The third
residual is not a window at all and no convergence pass heals it: two MAIL rows at one address
contend for the single address-keyed map slot **deterministically and permanently** (C). Read C as a
keying defect, not as a latency one.

## Subsystem and search terms

NSE; notification service extension; App Group; `NSEDataBridge`; `mirrorAccountIdentity`;
`mirrorAccountMap`; `mirrorIMAPAccounts`; `NSEState.findAccountId`; `NSEState.getIMAPAccount`;
`nse.accountMap`; `nse.imapAccounts`; `handleIMAPReconnect`; `attemptSilentResubscribe`;
`removeAccountFromMirrors`; `AccountManagerSetup.removeAccount`; `AppDataWiper`;
`SyncScheduler.startForegroundPolling`; `AccountEditableField`; derived state; convergence;
read straddles a delete; stale mirror

## Full detail

### Residual A — concurrent re-derivations have no read-to-write ordering

**The general property first, because an earlier draft of this record stated only its sharpest
instance and read as if that instance were the whole of it.** `mirrorAccountIdentity` is a
read-then-write with no lock, epoch or CAS, and it now has **eight** production launch points, on
different executors and at different isolations. Enumerated rather than counted, because an earlier
revision of this paragraph said "several" and named five: `activateMailAccount`, `addIMAPAccount`
and `addICloudAccount`; `removeAccount`'s post-commit convergence **and** its rollback `catch`;
`addCalDAVAccount`'s rollback `catch`; `AppDataWiper`'s rollback; and the detached foreground
convergence pass in `SyncScheduler.startForegroundPolling` — plus `mirrorAllState()` at launch,
which re-derives the same pair under a different name.

⚠️ **The concurrency source is not only cross-executor.** `AccountManager` is a *reentrant* actor, so
two `removeAccount` calls (the Settings confirm button has no in-flight guard) interleave at every
`await`: one can be parked at its `dbPool.write` with its pre-commit clearing already done while the
other runs a re-derivation that republishes it. The re-derivation itself is fully synchronous, so it
cannot be interleaved *by another actor task* — but the GRDB commit it races lands on the writer
thread, so the straddle is real. It is narrower than it looks, but the guarantee is NOT uniform and
the distinction matters. For an ACTOR-LOCAL straddler the repair is guaranteed, and full synchrony
is exactly what buys it: the re-derivation's read-and-write is atomic with respect to the removal's
own post-commit convergence, so it is either wholly before it (and repaired by it) or wholly after
it, in which case its read post-dates the commit and republishes nothing. A straddler that is NOT
an actor task gets no such guarantee, and that is every DETACHED launch point in the list above —
today the foreground convergence pass, `AppDataWiper`'s rollback, and the launch pass, which reaches
the same pair through `mirrorAllState()`; enumerate it from that list rather than from this
sentence, which has already been wrong once by naming a subset.
Nothing serialises those against that convergence, so their write can land after it and the entries
survive to the next foreground return, or the next cold launch when the account removed was the
last one. Either way `disconnectAccount` deletes that account's credentials synchronously, after
which the extension cannot authenticate; that credential delete, not the mirror content, is the
safety bound. Any two
overlapping re-derivations resolve
last-writer-wins per key, so the pass holding the OLDER snapshot can land last and briefly re-open
whichever window the other had just closed — in either direction, not only against removal. A
concurrent add is the benign direction: a stale pass can drop a just-added account from the map for
one interval, which fails closed and is repaired by the next pass. Separately, the two halves take
their own `dbPool.read`, so one call can publish an address map and a connection map derived from
different database states.

Every outcome fails closed and the next pass converges, so this is a bound problem rather than a
safety one. The removal direction below is the instance with a consequence worth stating in detail.

#### The sharp instance — a re-derivation straddling a removal

Account removal does not rely on re-derivation *alone*, and since the change this record
accompanies it uses both mechanisms: `removeAccountFromMirrors` edits both mirrors *before* the
authoritative delete, precisely so there is no commit-to-mirror window, and a re-derivation follows
once that delete commits, to restore the survivor whose shared address key the clearing takes with
it. (An earlier revision of this section said removal does not re-derive at all, which was true only
before that second half existed.) The pre-commit ordering is
only safe against a *serial* reader. Adding a re-derivation that can run concurrently — the
foreground convergence pass, and the rollback path in `AppDataWiper` — introduces a window that did
not previously exist: a pass whose database read happens before the delete commits, but whose write
to the App Group lands after `removeAccountFromMirrors` has already edited it, republishes the
removed account's entries.

**Bound on the consequence.** The restored entries are stale identity for an account being torn
down.

- `removeAccount` deletes credentials in `disconnectAccount`, entered immediately after the delete
  commits. For the remainder of that hop the credentials still exist, so a push for that address
  could still be serviced — with the removed account's own mail. There is no cross-account access:
  both mirrors are keyed by the same identity, so a restored entry can only ever name the account it
  was derived from.
- After teardown, the extension's keychain lookup fails and it takes no action on the account:
  `attemptSilentResubscribe` returns false and `fetchIMAPMessage` returns nil. Note that the
  re-subscribe hop is not read-only — it re-posts the account's stored connection credentials to the
  push service — so the bound that matters is the credential delete, not the mirror content.
- The one user-visible difference is that a new-mail push for the removed address then delivers the
  payload's own alert instead of the "connection lost" override that an unresolvable address
  produces. A stale notification: dismissable, and gone at the next re-derivation.

**⚠️ The "gone at the next re-derivation" bound is not uniform, and the sharp case is the one that
matters.** The convergence pass runs from `SyncScheduler.startForegroundPolling()`, and its
`scenePhase` call site in `RootView` is gated on `!navigationStore.accounts.isEmpty`. So when the
account being removed is the **last** mail account, there is no next foreground return — the stale
entries survive until the next cold launch, exactly as they did before this change. In every other
case the window closes at the next foreground return rather than the next cold launch, which is a
strict improvement.

`AppDataWiper.wipeAll` has the same shape with a wider window: it clears the mirrors with a
per-account `removeAccountFromMirrors` **loop** and only then runs its multi-table delete, so the
interval a concurrent re-derivation can straddle spans the whole loop plus that transaction rather
than a single delete. That file records that `wipeAll` has no callers, so the widest window is not
currently reachable — worth knowing before anyone prices this residual off it. Its *rollback* re-derivation is not part of the window — it runs when the
delete threw, so the rows are still authoritative and re-deriving is the correct response.

**Why it is carried rather than guarded.** Closing it needs a compare-and-swap epoch over state that
is purely derived — a generation token stamped at read time and re-checked at write time, or a
single-writer serialisation of every mirror write. That is more mechanism than a dismissable stale
notification justifies, and the mechanism would itself become a correctness surface. Recorded at the
mechanism in `NSEDataBridge.mirrorAccountIdentity`, per the rule that an accepted limitation lives
in the source beside the thing that has it.

**This has not been blessed by the owner.** It is filed `open`, not `accepted`.

### Residual B — an edit to a mirrored column converges late

The mirrors carry columns the account-edit surface can change after the account exists:
`AccountEditableField` covers both the address and the IMAP username, and its write path does not
refresh the mirrors. Between that write and the next re-derivation the extension resolves the *old*
address, or dials with the *old* username.

This is deliberately covered by convergence rather than by a per-writer refresh. Enumerating every
writer of every mirrored column is a census that goes stale the next time a mirrored column is
added, and the failure mode of a missed writer is silent. A full re-derivation is idempotent, costs
two unfiltered scans of a table with a handful of rows, and converges regardless of *which* writer
left the mirrors stale. The residual is therefore the latency, not the correctness: bounded by the
next foreground return.

**Row DELETES outside `removeAccount` fall here too, not under Residual A.** There are exactly five
`account`-row deletes in production. `removeAccountRowsTxn` clears and converges; `addCalDAVAccount`'s
setup-failure rollback now re-derives — the one delete that warranted its own call, because it can
run while a concurrent pass has already mirrored the doomed row. ⛔ `AppDataWiper.wipeAll` does
**both** as well — it clears with a per-account `removeAccountFromMirrors` loop before its
`DELETE FROM account` and re-derives on its rollback — so do **not** read it as unguarded; an earlier
revision of this paragraph listed it as such, contradicting Residual A above and
`mirrorAccountIdentity`'s own doc comment. That leaves two: `DemoSeed.wipe` and `ScreenshotMode`.

For those two a deleted address can keep naming a dead id until the next convergence — Residual B's
latency shape rather than a safety problem, and this change *narrows* it from "until the next cold
launch" to "until the next foreground return". ⚠️ State the reason precisely, because the obvious
one is wrong: it is **not** that the rows cannot reach `nse.imapAccounts`. That holds for
`DemoSeed.wipe`, which is row-scoped to a hostless `demo-account` row, but `ScreenshotMode` issues an
*unqualified* `DELETE FROM account` that reaches real IMAP rows. What actually bounds it is
reachability: `ScreenshotMode` is gated on the `--screenshot-mode` launch argument and cannot run in
a shipped session. `DemoSeed.wipe` runs *inside* a write transaction, so a refresh cannot live in it;
refreshing at its four production callers instead would be exactly the per-writer census this
residual exists to avoid.

Note also that `addIMAPAccount` and `addICloudAccount` refresh *above* their orphaned-demo-data
purge, deliberately: the new account's resolvability is the point of the change, and it outranks a
demo address lingering in the suppress set until the next pass. Unlike Residual A this has **no** last-account edge: the edit surface is
reached through the sidebar, whose request filters inactive and calendar-only rows, so an editable
account is by construction one that keeps the foreground pass ungated.

### Residual C — two MAIL rows at one address have no correct precedence

Found by three review angles independently, after the calendar-only precedence rule closed the
calendar-vs-mail axis. `mirrorAccountMap` gives a mail row precedence over a calendar row, but two
rows that are both mail rows still contend for the address by scan order, and the scan is unordered.

This is reachable without any concurrency: `AccountManager.addIMAPAccount` runs **no** duplicate-address
check at all, and `Account.existing(forEmail:provider:in:)` — the check `setupOAuthAccount` does run
— is **provider-scoped**, so an OAuth row and a generic IMAP row at the same address coexist. If the
OAuth row wins the key, `NSEState.findAccountId` succeeds and `NSEState.getIMAPAccount` returns nil,
so `handleIMAPReconnect` dead-ends with no re-subscribe. If the IMAP row wins, a Gmail/Outlook push
fails its access-token lookup and gets the "connection lost" override. Unlike Residual A this is
**deterministic and permanent** — every re-derivation reproduces it, and no convergence pass heals
it.

⚠️ **There is no correct precedence to apply here, which is why this is registered rather than
fixed.** An address-keyed map has one slot per address; whichever row wins it, pushes for the other
provider break. Picking a winner in `mirrorAccountMap` would only move the failure, while looking
like a fix. The shapes that actually resolve it change the *model*, not the tie-break: carry the
account id in the push payload, or key the extension's resolution by `(address, provider)` so the
two rows stop sharing a slot. Both are larger than this change.

The narrower and possibly better first move is upstream: give `addIMAPAccount` the duplicate-address
check it lacks, so the second row is never created. That is an account-setup change with its own UX
question (what should adding a duplicate address do?), which is why it is recorded here rather than
bundled.

### Remedy options, if this is taken up

1. **Do nothing.** Accept all three residuals as stated. Requires an owner decision to move the
   classification to `accepted`.
2. **Close Residual A only** — serialise mirror writes behind a single writer that re-reads under
   the same lock as `removeAccountFromMirrors`, or stamp each re-derivation with a generation token
   invalidated by any removal. Removes the straddle; leaves Residual B's latency untouched.
3. **Close the last-account edge of Residual A's sharp case** — hoist the mirror re-derivation out
   of `startForegroundPolling` into `RootView`'s `scenePhase` `.active` arm, outside the
   `!navigationStore.accounts.isEmpty` gate.

   ⚠️ **This is NOT free, and an earlier draft of this record called it "the cheapest" without
   saying why it costs something.** `AppDatabase.rawPool` is `shared.withLock { $0!.dbPool }` — a
   force-unwrap — and the accounts gate is currently what supplies the database-readiness
   precondition for it: a non-empty account list implies the database was built. Move the call
   outside that gate and the precondition has to come from somewhere else, i.e. an
   `await AppStartup.shared.awaitLaunchReady(...)`, which makes the call async and adds the very
   mechanism the remedy is supposed to avoid. Whoever takes this up must supply that precondition
   deliberately rather than assume `.active` implies it.

   Note also that the enumeration of foreground triggers is not just `RootView`:
   `SettingsView.nukeDatabase` calls `startForegroundPolling()` from a `defer`, ungated. That makes
   the "unbounded until cold launch" bound conservative rather than wrong.

   ⛔ **Residual B has no last-account edge**, despite what this remedy's earlier title claimed. An
   `AccountEditableField` edit is reached from `AccountDetailView` via the sidebar, and
   `Account.sidebarRequest` filters out inactive and calendar-only rows — so any editable account is
   by construction one that makes `navigationStore.accounts` non-empty. What this remedy closes is
   Residual A's sharp case only.

### Test coverage

`TabMailTests/NSE/NSEAccountIdentityMirrorTests.swift` pins the HELPER half of the contract:
`NSEAccountIdentityMirror`'s twelve tests assert that a stale mirror is *not* resolvable and becomes
resolvable after re-derivation.

⚠️ **The CALL-SITE half is unpinned.** A companion source-reading suite asserted it for eight review
rounds and was removed (owner, 2026-09-02) after every round found defects in the scanner and none in
production — most decisively a caller census that passed with a live half-call present, because
Swift's `Regex` `\b` uses Unicode word boundaries and does not break on the `.` in a qualified call.
Reinstating the shipped defect at all three call sites now leaves the suite green. Rationale and the
two remaining options (a single-writer chokepoint, or test-only seams on the add paths) are in memory
topic 123. Residuals A and B are not pinned by a test: both are timing windows, and
pinning them requires an injectable seam between the mirror read and the mirror write that the
current code does not have. That seam is the first thing to build if remedy 2 is chosen. Residual C
needs no seam — it is directly expressible today — and a test is deliberately still not written,
because there is no correct outcome to assert. Whichever row an assertion blessed would silently
become the mirror's specification, which is the bug-blessing shape this repo has already been bitten
by; C gets a test the moment a remedy decides which row *should* win.

**Related:** the mirrors' invariant and its `addCalDAVAccount` exemption are routed in
`Companion/Memory/Current/123-a-durable-write-to-a-mirrored-identity-column-must-refresh-the-nse-mirrors.md`.
