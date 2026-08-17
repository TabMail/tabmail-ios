# IOS-PERF-012

- Register classification: `open`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.
- 🔢 **Id note:** drafted as `IOS-PERF-009`; renumbered to **012** on placement because `009`–`011` were
  already claimed by an earlier, independent set of drafts. The **namespace** choice (`IOS-PERF`, not
  `IOS-QUEUE`) is the drafting agent's and is preserved — see § *On the namespace* below.

## Status

🔓 **OPEN — TWO HOT MEMBERS MITIGATED (2026-08-15); THE CLASS REMAINS OPEN.** With stale
`sqlite_stat1`, `DurableIdentityLookup.find`'s rfc822 fallback (step 3) and
`AccountManager.resolveInboxEntryAITargets` degraded from an RFC seek to an **account-wide scan**.
The 2026-08-15 campaign reproduced that on the exact current migrated schema at 200,000 rows / two
accounts: the shared fallback took **15.307 ms median / 17.879 ms p95** for a tail hit and
**14.998 / 20.088 ms** for a miss; the moved-inbox target took **17.027 / 21.334 ms** and
**16.964 / 26.218 ms**. The existing v1 RFC index served the same cases in **0.004–0.006 ms**, and
both hinted and unhinted forms were **0.003–0.006 ms** after full `ANALYZE`.

This change pins those two hot statements to `messageHeader_rfc822MessageId`; it adds no index,
migration, statistics refresh, query, write, or cache. The shared resolver also makes its previously
planner-dependent duplicate-RFC pick deliberate: prefer the sibling in the staged row's observed
folder, then an inbox sibling, then lowest `id`. The moved-inbox target is already destination-folder
scoped and chooses lowest `id`. **That ordering is a correctness guard for the hint, not the performance
mechanism.** Ten residual statement sites across nine logical query groups remain below and keep this
class open.

## Subsystem and search terms

`sqlite_stat1`; `ANALYZE`; `PRAGMA optimize`; query planner; `EXPLAIN QUERY PLAN`; stale statistics;
`SyncEngineMaintenance.runRefreshPlannerStatisticsIfStale`; `plannerStatisticsSchemaVersionKey`;
`didAnalyzeAtSchemaVersion_v1`; `schema_version` latch; ADR-IOS-029 2026-08-05 amendment;
`DurableIdentityLookup.find`; step 3 rfc822 fallback; `messageHeader_rfc822MessageId`;
`messageHeader_rfc822MessageId_date`; `messageHeader_accountId_messageId`; full table scan;
`SEARCH … USING INDEX … (accountId=?)`; `NSEDataBridge.verifyDurable`; `detectStaleByMoveRows`;
`performMerge` phase 1; `performMerge` phase 2; `InboxListReader.gather`;
`AccountManager.resolveInboxEntryAITargets`; slow push merge; slow inbox compose; fresh install
empty-table statistics; "do not confirm on a freshly-ANALYZEd database"; false negative on a red-first
control

## Full detail

**The mechanism.** `DurableIdentityLookup.find` step 3 is `WHERE accountId = ? AND rfc822MessageId = ?`.
With **fresh** statistics SQLite picks `messageHeader_rfc822MessageId_date (rfc822MessageId=?)` — an index
seek. With **stale** statistics it picks the `accountId=?` **prefix** of
`messageHeader_accountId_messageId` and scans every row of the account, filtering `rfc822MessageId` per
row. **No index is missing** — `messageHeader_rfc822MessageId_date` exists and is simply not chosen.

Measured on a real DB at schema `v84`, 20,000 rows across 2 accounts (~10k per account), 200–300 lookups
per cell:

| | STALE stats | FRESH stats |
|---|---|---|
| step 3 **hit** | 2.61 ms | 0.099 ms |
| step 3 **miss** | 2.47 ms | 0.003 ms |

⚠️ **Hit and miss cost the same when scanning** — a fruitless lookup is not cheaper, because concluding
"no match" requires visiting every row of the account. **The miss is the common case on the hot paths
below**, so the bad plan is paid at full price precisely where it is most frequent.

**Why stale is the shipped regime.** `SyncEngineMaintenance.runRefreshPlannerStatisticsIfStale` latches on
SQLite's `schema_version`, and its own doc comment states the exclusion explicitly: *"WHAT DOES NOT re-arm
it … ordinary `INSERT`/`UPDATE`/`DELETE` traffic, however far the row counts move. That is deliberate."*
On a fresh install the migration bodies record statistics for an **empty** `messageHeader`, so a device
that then syncs its mail carries empty-table statistics until the next schema-changing migration.
Confirmed on a real simulator DB at `v84`: `sqlite_stat1` holds **4 rows, all partial indexes, all
`0 0`**. `AppDatabase.swift`'s `v83` block already records the same regime for the unread sweep — *"in
every shipped build `ANALYZE` ran only inside migration bodies, never periodically"*.

**Reachability — established per caller by reading each call site, not inferred from the shared
resolver.** All five callers pass a **staged** row's identity, which is the address the NSE just observed
on the server and therefore *current*, not stale. So steps 1/2 **hit** when the durable row already exists
and **miss** when it does not:

- `NSEDataBridge.verifyDurable`, `detectStaleByMoveRows`, `performMerge` phase 1, `performMerge` phase 2 —
  once per staged message on the **push merge**. The miss case is the **ordinary new pushed message**,
  which `detectStaleByMoveRows` states in its own nil-branch comment: *"no durable header yet — an
  ordinary new message, not stale"*; both `performMerge` probes exist to "seed onto an EXISTING durable row
  ONLY". **So the scan is paid on exactly the case the NSE exists to handle.**
- `InboxListReader.gather` — once per staged row on **every inbox compose**; a staged row whose durable row
  has not yet landed takes the scan.
- `AccountManager.resolveInboxEntryAITargets` (ADR-IOS-008 decision 3) — once per member moved into an
  inbox. **Does NOT use `DurableIdentityLookup.find`** (see the 🚨 block at that function for why: step 1's
  currency precondition cannot be met by a caller whose input address is deliberately stale). Issues a
  single `(accountId, folderPath, rfc822MessageId)` lookup, which takes the **same** index and therefore
  carries the **same** stale-statistics exposure: measured **3.04 ms hit / 3.15 ms miss** stale, versus
  **0.060 ms / 0.003 ms** fresh.

  ⚠️ **This bullet said the opposite until 2026-08-13** — *"Here step 3 answers on a **hit**, because the
  captured address is deliberately the pre-remap one"* — and the correction is worth more than the
  replacement text. That sentence was **true of the code as written and false about the code as
  intended**: the caller really did reach `find`, and step 1 really did answer on a hit — **by returning
  an unrelated message that merely shared the stale UID.** The row described the wrong-message defect
  accurately and read it as a cost note. Commit `1eb41702e` removed the caller from `find` entirely.
  **A per-caller cost table records which index a call takes; it cannot tell you whether the call is
  resolving the right row.** Do not treat this table as evidence of correctness for any caller in it.

**Blast radius.** Bounded by staged-set size, which is small — one push typically stages one message, and
the reader's staged set is bounded by recent pushes. So ≈2.5 ms × a small integer per push at 10k
rows/account, ≈13–17 ms each at 100k. The placement is **not uniformly an off-main WAL read**:
`performMerge` phases 1/2 pay the fallback inside per-message savepoints of the merge write, extending
single-writer occupancy, while `InboxListReader.gather` can pay it in a synchronously initiated
`@MainActor` read. `resolveInboxEntryAITargets` remains an off-main post-drain read.

⚠️ **"Already paid on hotter paths" is a statement about the FREQUENCY OF THE CODE PATH, not about total
cost** — the queue path is lower-frequency than the push path, but the push path's per-event volume is
also small. **Do not restate this as "the hot paths are slow".**

## ⚠️ DO NOT CONFIRM THIS ON A FRESHLY-`ANALYZE`d DATABASE

**This is the part of the row with the most reuse value.** The plan is a function of `sqlite_stat1`, so a
development database that has been `ANALYZE`d — or a small test fixture — shows the *fast* plan and
nothing to see. **A reader who "cannot reproduce it" has almost certainly measured the wrong regime.**
Capture `EXPLAIN QUERY PLAN` under **both** regimes, and state which one each figure came from.
`AppDatabase.swift`'s `v83` block carries the identical warning for the unread-sweep index, for the
identical reason.

⚠️ **The trap is SYMMETRIC, and two agents hit it from opposite directions on 2026-08-12/13** — which is
why it is recorded as one row rather than as either instance alone:

- **Stale stats made a real cost invisible** (this row): the fast plan appeared on an analyzed fixture, so
  a genuine account-wide scan in shipped builds looked like an index seek.
- **Fresh stats on a small fixture hid a real bug** (the Archive folder-scoped search case, committed as
  `53d17514e`): the planner's chosen plan on a tiny analyzed dataset masked a defect that only appears at
  scale, and **would have produced a false negative on a red-first control** — the inversion would have
  "passed", certifying a broken system.

**The second direction is the more dangerous of the two**, because it corrupts the red-first gate itself
rather than merely under-reporting a cost. **Any red-first proof whose predicate touches a query plan must
state the stat regime it was observed under.**

### Walk position is a THIRD axis, independent of the statistics regime (2026-08-13)

ADR-IOS-029 already warns to probe with a value that **exists**, because a miss walks the account and a
hit stops early. This is the next question after that one: among values that *all* exist, **where the
value sits in the walk** sets the cost.

The same 200-member resolution measured **21 ms total (0.105 ms each)** with members drawn from the
**HEAD** of `(accountId, messageId)` index order, and **12,229 ms** with members drawn from the **TAIL** —
a **~580× spread with no change to schema, statement, or stat regime**. The head-drawn figure makes the
defect look absent, and it cost a measurement round on `f60f41391`.

**The tail is the operationally relevant end.** A bulk archive acts on recent mail, whose UIDs are
highest, so a drain's members sit at the end of the walk. **Any probe of this class must state which end
of the index its sample came from, and should draw from the tail.**

## Why schema/statistics machinery remains rejected

The 2026-08-15 campaign selected a cheaper already-shipped mechanism for the two hot statements:
`INDEXED BY messageHeader_rfc822MessageId`. `v1.7.9` already owns this exact architecture in
`MessageContentStore.ownersSQL`, `ChatStore.findByStableIdSQL`, and
`AccountManager.queuedMemberIdentitySQL`; both affected statements themselves are unchanged between
`v1.7.9` and the campaign base, so the release contains the defect and the remedy precedent. The larger
alternatives remain wrong-layer or disproportionate:

1. **A `(accountId, rfc822MessageId)` composite index** — this is a **migration**, and it is redundant with
   an index that already serves the query whenever statistics are fresh. **Adding schema to compensate for
   a statistics problem is the wrong layer.**
2. **Re-arming the latch on row-count growth** — explicitly rejected by ADR-IOS-029's 2026-08-05
   amendment, whose own note measures a whole-database `ANALYZE` at up to **8.5 s at 500k headers** and
   states a per-poll `ANALYZE` *"would be a far worse defect than the one this fixes"*.
3. Re-arming once at a row-count threshold was previously the first option to cost. The completed
   whole-SQL audit found fresh statistics are not uniformly better (`UserLabelStore`: 10 ms stale vs
   23 ms fresh), so even a one-shot refresh is a database-wide trade, not a targeted remedy.

## 2026-08-15 class census and bounded disposition

**Mechanical class property:** a `messageHeader` query combines selective `rfc822MessageId` equality
(or `IN`) with a low-selectivity scope equality (`accountId` or `folderId`) that leads another index,
allowing stale statistics to prefer a scope-prefix walk. Searches covered raw SQL, GRDB query-interface
filters, `accountId`/`folderId` forms, and sibling selective identity columns. The two hot members above
are mitigated. Three shipped members were already safe: `MessageContentStore.ownersSQL`,
`ChatStore.findByStableIdSQL`, and `AccountManager.queuedMemberIdentitySQL`.

The following **ten statement sites across nine logical query groups** remain unhinted and keep this
record open. `SyncEngineDeltaSync` is one logical group but contains two distinct statements:

1. `SyncEngineFullSync` optimistic Drafts/Sent dedup (`folderId` + RFC + `messageId !=`), per header
   inside the sync write transaction.
2. `SyncEngineDeltaSync`'s **two statements** for optimistic Sent/Drafts dedup, the same write-path
   shape.
3. `ReplyParentResolver.updateParentsForReplies` (`accountId` + RFC `IN` + `isReplied = 0`), byte-shape
   equivalent to the already-hinted queued-member RFC arm.
4. `Draft` reply/forward strategy 2 (`accountId` + RFC, `LIMIT 2`), paid on draft open.
5. `MessageDetailViewModel.resolveMessageAsync`'s RFC fallback (`accountId` + RFC + nonempty folder),
   paid on a message-open fallback.
6. `InboxView.lookupMessageId` (`accountId` + RFC), paid on notification/deep-link resolution.
7. `AccountManagerOutbox.appendToSentFolder` (`folderId` + RFC), one idempotency probe per send.
8. `StuckMessageDiagnostics`' correlated account + RFC sibling check, debug-only.
9. `AccountManager.logStuckOpDiagnostic`'s per-member `(messageId OR rfc822MessageId) AND accountId`
   GRDB query, the same stale-statistics account-walk shape, debug-only.

The GRDB query-interface members cannot express `INDEXED BY`; converting each to raw SQL is a larger
semantic/test surface and is deliberately not smuggled into this bounded change. The first sites to
cost next are the full/delta sync probes (write-transaction placement) and `ReplyParentResolver`
(identical shape to a shipped hinted arm). This change therefore does **not** claim the class is closed
and must not close GitHub issue #15.

### Duplicate-RFC selection correction

The original status said the resolver returned "the same answer either way". That was too strong.
Same-account duplicate RFC identities are normal (for example Inbox plus Archive/All Mail siblings),
and the old unordered `fetchOne` selected whichever row its plan reached first: account/messageId order
with stale statistics, RFC/date order with fresh statistics, and RFC/rowid order under a bare hint.
Consumers inspect the returned folder/inbox state for stale-by-move and AI-cache decisions, so a bare
hint would have changed behavior invisibly. The deterministic same-folder/inbox/id ordering above is a
deliberate narrowing, covered separately from the plan test. The target statement's retained per-member
N+1 is accepted because the set is drain-bounded and each hinted probe is microseconds; a set-based
rewrite would add machinery without operational benefit.

### Failure semantics

The v1 single-column RFC index is created blocking, recreated in v2, named by shipped queries, never
dropped, and is not a deferred index. If a future migration nevertheless drops or renames it,
`INDEXED BY` makes both statements throw instead of silently walking. The moved-inbox caller already
fails closed to no AI target. NSE verification/stale detection remain conservative, and merge savepoints
roll back for retry. `InboxListReader.gather` catches a resolver throw at its outer read and can return an
empty inbox; that user-visible failure class already exists for its triage hint but is widened to staged
resolution by this change, so the blocking-index existence assertion is part of the regression gate.

## On the namespace: `IOS-PERF`, not `IOS-QUEUE`

`IOS-QUEUE` would file the row **by its discoverer rather than by its subsystem**, and that is the
mis-filing that makes a register unsearchable — a future reader hunting a slow push merge or a slow inbox
compose has no reason to grep the queue namespace. The latch is a whole-database planner property owned by
ADR-IOS-029, and four of its five consumers are the NSE merge and the inbox reader; **the queue is the
*least* affected caller.** `IOS-DB` was considered and rejected: it has a single mention in the whole
tree, so filing there would bury the row.

## Related

- **ADR-IOS-029** and its 2026-08-05 amendment — owns the statistics latch and the
  migrations-should-only-be-blocking directive this interacts with.
- `IOS-PERF-009`, `IOS-SEARCH-004` — sorter-shape rows that still require both statistics regimes in
  any plan-touching measurement. ⚠️ **CORRECTED 2026-08-15:** both rows measured the same plan under
  stale and fresh statistics, so their observed plans are **not** governed by this latch; they point
  here for the general false-green trap, not because statistics decided their result.
- `IOS-AI-004` — the ADR-IOS-008 decision-3 restoration that is this row's lowest-frequency consumer, and
  the work during which the row was found.
- `IOS-QUEUE-010` — the same-pass report later retracted as a false positive after actor-isolation
  re-audit.
- ✅ **The whole-SQL-surface audit COMPLETED (2026-08-13).** 164 ordering/grouping sites enumerated, 138
  read in full, 25 shapes measured under **both** stat regimes (~47 measurements), 9 findings, **zero
  correctness defects**. Its coverage claim was tested rather than accepted: `IOS-PERF-009` and
  `IOS-SEARCH-004` were **deliberately withheld from its brief as a blind control**, and it surfaced both
  independently with measurements matching the drafts' predictions.

  **Three results change what this row means:**

  1. **All six `ANALYZE` sites are on the MAIN pool** — `AppDatabase` ×5, `SyncEngineMaintenance` ×1 — and
     **none is in the search tree.** So `fts.db` and `memory.db` are **never analyzed at all**. For those
     two databases stale statistics are not "the shipped regime until the next schema-changing migration"
     as this row's *Why stale is the shipped regime* section says of the main pool; **they are the only
     regime that will ever exist**, and no migration will ever refresh them. Any reasoning about a query
     against a shard table or `memory.db` must use the stale plan, full stop.
  2. **Fresh statistics are not uniformly better, which kills the tempting blanket remedy.**
     `UserLabelStore`'s label-frequency query is **worse** analyzed — 10 ms stale versus 23 ms fresh,
     because the join order flips. This row's option 3 ("re-arm once past a row-count threshold") must
     therefore be costed as a **trade**, not an improvement, and cannot be justified by "fresh is
     correct".
  3. **The sorter class did NOT generalise the way its founding instance suggested.** `53d17514e` worked
     by rewriting a `folderId IN (…)` list per-partition, which restored a usable **date-ordering
     index**. Where no such index exists the same rewrite buys nothing — measured directly on
     `SearchIndex.searchFTSOnly`, where per-folder (187 ms) and IN-list (191 ms) are indistinguishable
     because FTS5 `MATCH` output has no date order for a predicate to defeat or restore. **The
     transferable mechanism is "the LIMIT bounds the OUTPUT and not the WORK"; the per-partition REWRITE
     is only its remedy in the sub-case where an ordering index exists.** Conflating the two would send a
     future reader to rewrite a query that cannot benefit.

  **So this row IS the index entry for a class, as anticipated** — but the class is defined by the first
  clause, not the second.

  **Explicit gaps the audit declares:** `memory.db` unmeasured (its own largest gap),
  `bodyAssetIndex.sqlite`, `nse_staging.sqlite`, `StuckMessageDiagnostics`, and ~30 of 41
  loop-pool-acquisition sites. Its two coverage cross-check methods **disagreed**, and the disagreement
  surfaced 3 real sites the second method missed — recorded because a census that agrees with itself has
  not been checked.
