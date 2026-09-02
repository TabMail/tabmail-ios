## A durable write to a mirrored identity column must refresh the NSE identity mirrors (2026-09-02)

**The invariant.** The notification service extension cannot read the main GRDB database. Two App
Group `UserDefaults` keys are the *only* way it can turn a push payload into an account:

| key | shape | read by |
|---|---|---|
| `nse.accountMap` | `emailAddress` → `account.id` | `NSEState.findAccountId(for:)` |
| `nse.imapAccounts` | `account.id` → `{host, port, username}` | `NSEState.getIMAPAccount(for:)` |

Every extension push handler begins by resolving the payload address through the first map, and the
IMAP handlers then read the account's connection info from the second. **An account absent from
those maps does not exist as far as the extension is concerned** — not "degraded", not "slower":
the handler takes its early return before doing any work.

So: **a durable write to `account.emailAddress`, `account.imapHost`, `account.imapPort`,
`account.imapUsername`, `account.provider`, `account.calendarOnly`, or an `account` row
insert/delete, must be followed by `NSEDataBridge.mirrorAccountIdentity()`.** That helper exists so
the pair has one name and one definition; do not call `mirrorAccountMap()` or `mirrorIMAPAccounts()`
on their own.

⚠️ `calendarOnly` joined that list when `mirrorAccountMap` gained its mail-over-calendar precedence
rule — the column is now an INPUT to which id wins a shared address, not merely a display flag. Its
one production writer on an existing row is `setupOAuthAccount`'s upgrade arm (`row.calendarOnly =
false; try row.update(db)`), which refreshes via its `activateMailAccount(upgraded)` hop.

**INSERTS and UPDATES are not equally urgent, and the contract test scopes to inserts on purpose.**
An insert that does not refresh leaves a brand-new account resolvable *nowhere* — no address key at
all — so a reconnect push arriving before the next convergence dead-ends; that is the shipped defect
this topic exists for. A column UPDATE that does not refresh leaves the account resolvable under its
*previous* value: degraded, not dead, and healed at the next foreground return. That is exactly
`IOS-NSE-008` Residual B, and it is the residual the convergence pass was added to absorb, which is
why the rule is stated for `insert`/`save`/`upsert` and deliberately not `update`. Do not widen
that verb set without first moving Residual B.

**Several inserts are knowingly outside the rule, and the exemption is a PROPERTY, not a list of
names.** ⚠️ An earlier version of this paragraph said "one insert: `addCalDAVAccount`" and was
wrong — three review angles caught it independently, and the test file in the very same commit
enumerated the set correctly. The actual set at the time of writing is `AccountManager.addCalDAVAccount`,
both `CalendarSetupView` arms (`connectGoogleCalendar` / `connectOutlookCalendar`, `calendarOnly`
rows on `.gmail` / `.outlook`), `DemoSeed.seedAccount`, `ScreenshotMode`'s raw-SQL insert, and the
preview fixtures.

They are safe for ONE shared reason: none can produce a row that `mirrorIMAPAccounts` would emit,
because that half admits only `provider IN ('imap','icloud')` **with a non-empty `imapHost`** — the
calendar rows fail the provider clause, the demo/screenshot/preview rows fail the host clause.
**State the property, not the census** ([[feedback_state_the_invariant_not_the_instances]]): the list
goes stale the next time someone adds a fixture, the property does not.

Note that being outside the REFRESH rule does not put a row outside the MAP: `mirrorAccountMap`
holds calendar-only addresses deliberately, which is exactly why it needs the precedence rule below.

The exemption comes from the row's own `calendarOnly` flag, never from the method's name, so a
mail-account inserter cannot inherit it. Nothing asserts that mechanically any more (see the
removal note below); the shared property above is what makes every inserter safe.

**But the exemption is about the REFRESH, not about the MAP — a `calendarOnly` row is still
mirrored, and must never displace a mail account at the same address.** The two halves filter
differently: `mirrorAccountMap` is address-keyed and takes every row (the extension needs
calendar-only addresses in its recipient-status suppress set, via `getAllAccountEmails()`), while
`mirrorIMAPAccounts` filters by provider and takes only mail accounts. So if a user adds a CalDAV
account whose username happens to equal an existing mail address, and the calendar row wins the map
key, the extension gets an account id it *can* resolve but has **no connection info for** — every
push for that address then dead-ends at `deliverPassive` with no re-subscribe, which is the exact
failure this whole topic is about, reintroduced through the other door. `mirrorAccountMap` therefore
carries an explicit precedence rule: a mail row always wins the address, in either insertion order.

⚠️ **The tempting fix — `WHERE calendarOnly = 0` in `mirrorAccountMap` — is wrong**, and wrong in a
way that is invisible at the call site: it would silently shrink `getAllAccountEmails()`'s suppress
set, changing a *different* consumer's behaviour. Match the guard to the consequence (a calendar row
shadowing a mail row) rather than to the mechanism (a calendar row being present at all).

### What was actually broken

`mirrorAllState()` had exactly one production caller — a detached launch-time task in `TabMailApp`,
**not** a foreground-return hook. Below it:

- `activateMailAccount` (the OAuth arm) called only `mirrorAccountMap()` — half the pair.
- `addIMAPAccount` and `addICloudAccount` called **neither** half.

Consequence for an IMAP or iCloud account added in-session: it was in GRDB and fully functional in
the main app, and simultaneously invisible to the extension until the next cold launch. The visible
failure is the IMAP reconnect leg. When the IDLE connection drops, the backend sends a
`imap_reconnect` push with `mutable-content: 1`; the extension is supposed to re-subscribe on the
user's behalf. Instead `handleIMAPReconnect` failed its `findAccountId` guard, returned, never
attempted the re-subscribe, and the backend's retry ladder ran to its give-up notification.

**The asymmetry that made this hard to see from bug reports:** the main app's own foreground
re-subscription path reads GRDB directly and was therefore completely unaffected. Users experienced
"push works, except sometimes it silently stops until I reopen the app" — and reopening the app was
both the workaround and the thing that hid the cause, because a cold launch re-derived the mirrors.

### The shape of the fix, and why it is two mechanisms rather than one

1. **Refresh at each account-add site.** `addIMAPAccount` and `addICloudAccount` call it directly,
   immediately after the row commits. The OAuth arm refreshes one hop away: `setupOAuthAccount`
   inserts the row and hands it to `activateMailAccount`, which refreshes near its end, *after*
   `connectAccount`. So a `connectAccount` failure leaves the row committed and the mirrors
   unrefreshed — benign, because the push subscription is dispatched after the same throw point, so
   there is nothing for a push to arrive against, and (2) re-derives before there is. Placement
   unchanged from before the fix. This mechanism closes the acute window — the interval in which a
   brand-new account is unresolvable.
2. **Re-derive on every foreground return**, ungated and detached, in
   `SyncScheduler.startForegroundPolling()`. This closes the *class*.

(2) is not redundant with (1). The mirrored set includes columns the account-edit surface can
change after the add — the address and the IMAP username are both user-editable — and enumerating
every writer of every mirrored column is exactly the census that goes stale the next time someone
adds one. The mirrors are **pure derived state**, so full re-derivation is idempotent, costs two
unfiltered scans of a table with a handful of rows, and converges regardless of *which* writer left
them stale. Preferring the robust redundant pass over a complete-writer-census is the deliberate
trade.

Concretely, the writer this covers today is `AccountFieldPersistenceStore.persist(accountId:field:
value:database:)`: `AccountEditableField` includes `.emailAddress` and `.imapUsername`, both
mirrored, and it does not refresh. A mirrored column can therefore be one edit stale for as long as
the app stays in the foreground. Both directions of that staleness fail closed — a changed address
misses `findAccountId`, a stale username is rejected by the server — and one foreground return
converges it, so it is a registrable edge rather than a defect.

Two placement constraints, both load-bearing:

- **Off the main actor, and never below `.medium`.** `mirrorAccountMap` / `mirrorIMAPAccounts` do
  *synchronous blocking* `AppDatabase.dbPool.read`. `SyncScheduler` is `@MainActor`, so the call is
  `Task.detached`; a blocking read on the foreground-return path would stall first paint. The tier
  is `.medium` because ADR-IOS-031 makes that the floor for **any** background task that takes a
  reader on a GRDB pool — and `mirrorAccountMap` is not hypothetical here, it appears by name as a
  Thread Performance Checker holder frame in archived suite logs (`IOS-PERF-001`). A `.utility` pass
  on the foreground-return path would sit 8 QoS levels under the MainActor it shares the reader
  pool with. This was caught by the architecture angle of the review gate, having shipped as
  `.utility` in the first draft.
- **Ungated by the herd.** `startForegroundPolling` holds a `isStartupInFlight` gate that a slow
  network can keep closed for 60s+. The convergence pass sits with the NSE-merge block *above* that
  gate, for the same reason the merge does: a foreground arriving mid-sync must not leave the
  extension addressing a stale account set.

Losing the pass to a process kill costs nothing — the next launch's `mirrorAllState()` re-derives
the same values.

### 🚨 A precedence rule changes who OWNS a shared key — and therefore what a keyed delete destroys

The single most valuable finding of the whole review train, raised independently by two angles, and
worth stating as a general shape because it will recur anywhere a derived map gets a tie-break.

`removeAccountFromMirrors` deletes an entry if its **value** is the removed id **OR** its **key**
matches the removed address:

```swift
map = map.filter { key, value in
    value != accountId && key.caseInsensitiveCompare(email) != .orderedSame
}
```

That was tolerable for as long as a shared key *usually* belonged to the row being removed. **The
mail-over-calendar precedence rule inverts exactly that assumption**: after it, the shared key
belongs to the SURVIVOR. So removing a calendar account that shares an address with a mail account
strips the mail account's only resolver — `findAccountId` misses, `handleIMAPReconnect` returns
without re-subscribing, and every new-mail push shows the "connection lost" override. **The fix
reintroduced its own bug through the removal door.**

**The general shape:** adding a precedence/tie-break rule to a derived map is not a local change. It
reassigns ownership of contended keys, so every OTHER operation keyed by that same field — deletes,
filters, invalidations — silently changes meaning. **When you add a tie-break, census the operations
keyed on the same field, not the ones near the code you touched.**

**The fix chosen, and why not the narrower one.** Removal keeps its pre-commit clearing — that is
what closes the commit-to-mirror window and it is not negotiable — and `removeAccount` now
re-derives once, immediately after the delete transaction commits. The precondition is that
commit and nothing else — both halves read only the `account` table, and `removeAccountRowsTxn`
performs an unconditional `Account.deleteOne` (it does not END there: a conditional
`UPDATE account SET isPrimary = 1` promotion follows, inside the same transaction, writing a column
neither mirror reads) — so a full re-derivation can only reproduce the authoritative state:
it cannot restore the removed account and it repairs the survivor. ⚠️ Do **not** restate this as
"safe because the credentials are gone". The credential delete in `disconnectAccount` is irrelevant
to what the pass derives, and an earlier revision's "safe here and nowhere earlier" wording (which
placed the call *below* `disconnectAccount`) cost the survivor a network teardown and a SyncEngine
hop of unresolvability — the very outage this change exists to prevent. Narrowing the filter to `value != accountId` alone was
the other candidate; it was rejected because the address arm is a deliberate stale-data defence, and
weakening a guard to fix a different bug trades one silent failure for another. Preferring the
redundant convergent pass over the narrowed guard is the same trade this whole topic is built on.

### Why account *removal* uses BOTH mechanisms, and needs both

Removal does not rely on re-derivation *alone*. It first calls `removeAccountFromMirrors(accountId:
email:)`, which edits both maps in place *before* the authoritative GRDB delete. That ordering is
deliberate and is not negotiable: a re-derivation can only run *after* the row is gone, which would
leave a commit→mirror process-kill window in which the extension still resolves a deleted account.

It **then** re-derives once, immediately after that delete commits, because the in-place clearing
over-deletes — see the section above. So removal is the one path that runs a fail-closed preparation
*and* a convergence, in that order, and each covers what the other cannot: the clearing covers
process death before the commit, the convergence covers the survivor the clearing strands. Do not
"simplify" the two into one, and do not delete either half believing the other subsumes it.

⚠️ An earlier revision of this section flatly said removal "does **not** use
`mirrorAccountIdentity()`" while the section above it described the call that had just been added.
Fixing one and not the other is how a routed topic starts contradicting itself; the denial sat in
the section a maintainer reads *before touching removal*.

### ⚠️ The wiring scanner's cost, and the shape that would delete most of it

Recorded because the trajectory is the finding, not any one defect. `NSEAccountIdentityMirrorWiring`
WAS a hand-rolled Swift reader — indentation body split, regex write detection, rebinding-chain
resolution, brace-depth catch detection, overload guard, textual write census. Across two review
rounds it produced roughly two dozen defects **in itself** and zero in production. Every one was a
scanner defect: a catch detector that mis-flagged single-line `catch` blocks in both directions, a
direct-refresh branch that skipped the catch filter its own hop branch applied, a scan-order probe
whose query was index-covered where production's table-scans, a reachability check built from a list
of forbidden spellings that was open on everything it did not enumerate.

**⛔ REMOVED (owner decision, 2026-09-02).** It ran to EIGHT review rounds. Every round found
defects in the scanner and none in production, and each round's remedy created the next round's
defects. The decisive one: after a round-8 rewrite replaced the spelling enumerations with a
reachability property, a 73-mutation run showed the half-pair caller census still passed with a live
`NSEDataBridge.mirrorAccountMap()` in `SyncScheduler`. Cause — **Swift's `Regex` `\b` uses Unicode
(UAX #29) word boundaries, where the `.` in `NSEDataBridge.mirrorAccountMap` is not a break**, so the
pattern matched only the bare and wrapped-receiver spellings and missed every qualified call, which
is the only spelling a real half-caller uses. Eight rounds in, the instrument was still confidently
wrong about the one thing it existed to check.

What is lost is real and is recorded as a gap, not papered over: reinstating the shipped defect at
all three call sites now leaves the whole suite green. The twelve behavioural tests pin the helper,
which was never the broken part.

**The shape that would remove rather than add mechanism:** route every durable `account` row write
through one helper, and have that helper refresh. The invariant becomes "there is exactly one
writer", which is a repo-wide grep — no body split, no rebinding resolver, no catch-depth analysis,
no overload guard, no ordering check. It would also close this test's admitted scope hole (it reads
ONE file and cannot see `CalendarSetupView`, `DemoSeed` or `ScreenshotMode`) and would subsume
Residual B, since the account-edit write path would pass through the same point. That is a larger
refactor of account setup than the defect it guards, so it was **not** taken on this change. With
the scanner gone it is now the only way to pin this property mechanically, and it is the first thing
to weigh before anyone writes another source-reading test for it.

### Round 6: the shared root cause of the scanner's fail-opens, named

Round 6 found **no production defect** — the third consecutive round in which every
CODE finding was in the instrument. All of them reduce to ONE property, worth
stating once instead of re-deriving it per pin:

> **A brace depth is recorded at the START of a line, so a depth anchor cannot see
> anything that shares that line.**

Three separate pins fell to it, each added the round before to close the previous
round's fail-open, each defeated by ONE plausible line:

| pin | the line that defeated it |
|---|---|
| `removeAccount`'s convergence at method level | `if wasPrimary { NSEDataBridge.mirrorAccountIdentity() }` |
| the pre-commit clearing at method level | the same shape, on the clearing |
| the foreground launch at method level | `if isPollActive { Task.detached(priority: .medium) {` |

The remedy is one idiom applied three times, not three patches: pair every depth
term with a **line-START** term — `hasPrefix` on the trimmed, comment-stripped
line. That is the same "nothing between the start and the construct" reasoning
that made `closureToCall`'s whitespace-only check beat an enumeration of forbidden
spellings. A fourth instance of the same property: `Task.detached(…) { call() }`
written on ONE line records the depth OUTSIDE the launch, so the outward scope walk
climbed past it and the site vanished from the census with no offender and no
`unclassified` entry — fixed by classifying from the call's own line before walking.

Two further instrument defects from the same round, both structural:

- **`methodBodies` ended a slice at the NEXT declaration.** That gave the file's
  LAST method a body containing the type's own closing brace (balance −1) and
  truncated any method containing a nested `func` (`startForegroundPolling` lost
  everything below its `func fgStep`, balance +3). Neither was noticed until
  `catchFlags` began reporting its own leftover balance, which then fired
  immediately on `AccountManagerSetup.reauthenticateMicrosoft`. A slice now ends on
  its **own closing brace**, which fixes both and retires the nested-`func`
  workaround.
- **The scanners classified from RAW lines, so a COMMENT decided the answer.**
  `Task.detached(priority: .utility) { // was .medium` read as compliant, and
  `// was "SELECT …"` satisfied the scan-order pin while production's query had
  changed. `code(_:)` stripped whole-line comments only; it now delegates to
  `scannable`, which strips trailing ones too, and both are file-scope so the
  behavioural suite's pin uses the same neutralisation as the wiring suite's.

⚠️ **The escalation below is now at SIX rounds, not five**, and the arithmetic has
got worse rather than better: three of the four structural pins added in round 5
were defeated by a one-line spelling. That is the strongest available evidence for
the chokepoint question, and it is the OWNER's decision, not a reviewer's.

⛔ **That trigger has now FIRED.** A third round found three more instrument defects, all fail-OPEN
and none a production defect: the removal test's commit anchor matched the transaction's CALL line
(inside the write closure) so a convergence placed *inside* the transaction satisfied it; the
foreground-pass test proved "ungated" only inside the closure, so wrapping the whole
`Task.detached` in an `if` passed everything; and the tier scan's fixed six-line look-back SKIPPED,
in silence, any site whose launch sat further up. Each was fixed — brace-depth anchoring, a
file-scope launch-depth pin, and an unbounded outward scope walk — and each fix is itself more
scanner. The count is the finding: **four consecutive rounds in which a fix produced the mirror
image of its own bug**, all inside an instrument guarding ~10 lines of production wiring. The
construct question (a single-writer chokepoint in account setup, which would delete most of this
scanner) is therefore escalated to the owner on this change rather than decided inside it —
`feedback_ten_review_rounds_means_wrong_architecture` and
`feedback_fixing_your_own_fix_signals_overcomplication` both point the same way, and neither is the
reviewer's call to make.

**Two hardening items were deliberately declined**, so they are not re-proposed as new:
`unmatchedDeclarations` still reports only `func` declarations — widening it to any four-space
declaration ending in `{` would fire on the ~10 nested `struct`/`enum` bodies in `NSEDataBridge.swift`
and would need an allowlist, i.e. more parser, to fix a mis-attribution that is currently prevented
by file layout. And `textualWriteCount` keeps its `(db` anchor: dropping it, as one review suggested,
matches the **twelve** `KeychainHelper.save(...)` calls in `AccountManagerSetup.swift` (seventeen
lines in all once every `.insert`/`.save`/`.upsert(` spelling is counted) and turns the suite red
against correct code. Both were measured, not reasoned about — though the integer above read "nine"
until a later round re-counted it, which is exactly the drift `feedback_verify_the_instrument_not_just_the_claim`
is about: a stated-as-measured number that nobody re-measures invites the next reviewer to re-propose
the hardening on the strength of a wrong figure.

### Registered limitation `IOS-NSE-008` — a re-derivation can straddle a removal

Mechanism (2) is the first re-derivation that can run *concurrently* with `removeAccount`, so it
introduces one window the base did not have: a read that straddles the authoritative delete can
briefly restore the removed account's mirror entries. Accepted rather than guarded — closing it
needs a compare-and-swap epoch over state that is purely derived, which is more mechanism than the
consequence is worth — but stated precisely, because two earlier drafts overstated the mitigation
in the same direction:

- **"Its credentials are already deleted" is eventually true, not instantly true.** `removeAccount`
  runs `removeAccountFromMirrors` → `discardAccount` → the row-delete commit →
  `disconnectAccount(deletingCredentials:)`, and the Keychain items go in that last step. For the
  remainder of that hop the restored mirrors name an account whose password still exists, so a push
  could still be serviced — with the removed account's own mail, so no cross-account access.
- **"The extension does nothing" is not what the code does.** Once teardown has run,
  `attemptSilentResubscribe` returns false and `fetchIMAPMessage` returns nil, so no action is taken
  on the account — but resolution succeeds *before* those guards, so an `imap_new_mail` push for the
  removed address falls through to `deliverPassive` with the payload's own alert, instead of the
  "connection lost" override an unresolvable address would have produced. A stale notification,
  dismissable, and gone once the next re-derivation drops the entries.

- **The re-subscribe hop is not read-only.** It re-posts the account's stored connection
  credentials, so the bound that matters is the credential delete in `disconnectAccount`, not what
  the mirrors happen to contain.
- ⚠️ **"Dropped at the next foreground return" is FALSE for the last mail account.** `RootView`
  gates `startForegroundPolling()` on `!navigationStore.accounts.isEmpty`, so removing the only
  account leaves no next foreground pass and the entries survive to the next cold launch — exactly
  the bound the code had before mechanism (2) existed. `AppDataWiper.wipeAll` has the same shape
  with a wider window: it clears the mirrors with a per-account `removeAccountFromMirrors` **loop**
  and only then runs its multi-table delete, so the interval a concurrent re-derivation can straddle
  spans the whole loop plus that transaction. Its *rollback* re-derivation is not part of that
  window — it runs when the delete threw, so the rows are still authoritative and re-deriving is
  exactly right. (That rollback is the second `.medium` detached mirror call site, for the same
  ADR-IOS-031 reason as the foreground pass, with the extra force that MainActor is blocked on its
  `.value`.)

Both of the first two corrections came from the review gate (correctness and robustness angles,
independently); the last two came from the following round. The net position is still better than
the base — outside the last-account case the entries are dropped at the next foreground return
rather than the next cold launch — but it is **not** an owner-blessed acceptance. It is filed
`open` as `IOS-NSE-008` (`Companion/Process/Current/KnownIssues/Amendments/ios-nse-008.md`), which
enumerates three remedies; the cheapest, ungating the foreground pass, also closes the sharp case.

⚠️ **A round was spent on a false premise here.** A probe run in the wrong directory produced
`orphan detail`, and I concluded from it that the known-issues register cannot take new rows at all
— then wrote that conclusion into the source comment. It is wrong: `Amendments/` plus the
`KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END` block is the supported post-freeze surface and already held 33
records. `Scripts/compact_known_issues.rb` strips that block before its byte comparison and globs
`ios-*.md` non-recursively, so neither the orphan check nor the hash proof sees an amendment file.
**Before recording that a repo mechanism does not exist, find the mechanism's own users.**

### Testing note

`NSEState.swift` is **not** compiled into `TabMailTests` (see the deliberately short NSE file list
in `project.yml`), so tests cannot call `findAccountId` / `getIMAPAccount` and must decode the
mirror JSON with the same keys the extension reads. That coupling is by convention — changing a
mirror key means changing both sides. `TabMailTests/NSE/NSEAccountIdentityMirrorTests.swift` pins
the invariant two-sidedly: seed a stale mirror, assert the account is **not** resolvable, re-derive,
assert it is. Two of its twelve cases pin the calendar-only precedence rule instead, in **both**
insertion orders — a precedence bug that only appears when the rows arrive the other way round is
the reason the order is a parameter rather than an assumption — and one more of them pins a further
property, that two
addresses differing only in CASE keep two distinct map keys, because the map is keyed on
the raw stored address while `Account.existing(forEmail:provider:in:)` two lines away case-FOLDS:
folding here would collapse the pair into one slot and leave one account resolvable nowhere.

⚠️ **Every one of those twelve cases pins the HELPER, and the helper was never the bug.** Both halves
already worked; nobody CALLED them on add. Drop the three call sites — i.e. reinstate the shipped
defect exactly — and all twelve stay green. An earlier draft of this topic stopped here and concluded the call sites were
untestable, which taught the wrong lesson: it is true of a *behavioural* test and false of coverage
in general. A source-reading suite did assert it at the call sites for eight review rounds and was
then removed — see the removal note above. **The call-site half of this invariant is currently
unpinned, deliberately**, and the honest lesson is narrower than either earlier draft: a behavioural
test cannot reach these call sites without production seams that exist only for tests, and a
textual scanner over Swift source could not be made trustworthy at a cost proportional to the
defect. The remaining options are the single-writer chokepoint above, or the two test-only
parameters — both are changes to production, and both are decisions rather than fixes.

Two traps that cost a round each, recorded because both are generic:

- **Scan the code, not the comments.** The first draft granted `setupOAuthAccount` the calendar-only
  exemption because the words `calendarOnly = true` appear in a comment there, explaining an
  unrelated upgrade path. Every content check now runs on a comment-stripped body.
- **The refresh may legitimately be one hop away.** `setupOAuthAccount` inserts and
  `activateMailAccount` refreshes. A contract test that demands the call in the *same* body reports
  a false positive on the real production shape.
- **The hop needs the ORDERING check too, not just the presence check.** The first version required
  a direct refresh to sit *after* the write but accepted a hop on presence alone — so hoisting
  `activateMailAccount(account)` above the insert kept the suite green while re-deriving the
  pre-insert state, i.e. the shipped defect with the call still present. Proven by mutation, red only
  after the fix. **If a property is worth asserting on one branch of a check, ask what the other
  branch asserts instead of it.**
- **"Before the first `} catch`" is not "outside a `catch`".** The filter that excludes a method
  whose only refresh is in its rollback needs brace depth. The cheap textual proxy dropped
  `activateMailAccount` — which has an unrelated `do/catch` above its refresh — and turned the suite
  red against correct code. Measured, not reasoned about: simulate a scanner rule against the real
  file before trusting it.
- 🚨 **An instrument must share the query plan of the thing it measures.** A new assertion pinning
  the SQLite scan order the precedence test's "both insertion orders" claim depends on used
  `SELECT id FROM account`. That is **covered by the `id` primary-key index**, so SQLite answered it
  from the index in id order, while production's `SELECT id, emailAddress, calendarOnly` does a table
  scan in rowid order. The assertion failed against correct code, and the failure was in the probe.
  Select the same columns.

What remains genuinely uncovered behaviourally: the add paths need a live IMAP connection, and
`NSEDataBridge.suite` has no test override, so an un-overridden production call would write the real
App Group container. That is the same boundary the `removeAccountFromMirrors` call sites sit behind.
Named for the record, because a later audit asked: `addCalDAVAccount`'s setup-failure rollback
refresh is a new production line with **no** coverage at all — deleting it leaves the whole suite
green. Deferring it is deliberate, not an oversight: its consequence is `IOS-NSE-008` residual-B
latency (the doomed row is calendar-only, so it can never reach `nse.imapAccounts`, and the next
foreground return converges), and the wiring scanner deliberately does not count a DELETE as a site
requiring a refresh.

### Related

- [`107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`](107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md)
  — the other half of "the extension addresses accounts by data the main app mirrored".
- `ADR-IOS-041` — why the extension's staging database is a separate non-WAL shared file, i.e. why
  it cannot simply read the main database and make these mirrors unnecessary.
