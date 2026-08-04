## `MessageHeaderInfo.isDeletedOnServer` has FOUR materialisation paths, not two — and `insertBackfillBatchGuardable` is the funnel for most of them (2026-08-04)

**The census that matters is of the paths that BUILD A `MessageHeader` FROM a `MessageHeaderInfo`,
not of the sites that read the flag.** `a659c4bc5` closed `IOS-IMAP-001`/D3 by teaching the *merge*
to stop presenting a message the server reports as `\Deleted`, and enumerated **two** consumers.
There were **four** places that materialise a row from the same `MessageHeaderInfo` values, and the
other two never consulted the flag — so a message the merge had correctly removed could be put back
as an ordinary visible row by a later crawl. Closed by `45ad66d38`.

### The one producer and the four materialisation paths, by symbol

- **Producer (exactly one):** `IMAPProvider.mapMessageInfo` (`TabMail/Providers/IMAPProvider.swift`)
  sets it from `info.flags.contains(.deleted)`. The property is declared on `MessageHeaderInfo` in
  `TabMail/Providers/EmailProvider.swift` with a `false` default, which is the fail-closed direction:
  a provider that cannot observe the flag is never read as one that observed its absence.
- **`SyncEngineFullSync.selectStaleHeaders`** — subtracts `\Deleted` records from the PRESENT set
  (`remoteIds`) **and from nothing else**.
- **`SyncEngineFullSync.runSyncMessages`** — adds the same ids to the upsert loop's skip set, so a
  row the stale channel just removed cannot be re-created in the same transaction.
- **`SyncEngine.insertBackfillBatchGuardable`** (`TabMail/Services/Sync/SyncEngineBackfillDeep.swift`
  — the enclosing type is `SyncEngine`, the file name is not a type qualifier). **This one is a
  FUNNEL**: `backfillWindow`'s three provider arms, `deepBackfillFolder`, two
  `SyncEngineBackfillWalk` call sites and `SyncEngineSelfHeal` all reach it through
  `insertBackfillBatch`. One filter here closed more than the finding enumerated.
- **`SyncEngine.fetchOlderMessages`** (`TabMail/Services/Sync/SyncEngine.swift`) — the *"load older"*
  pull.

### The scenario, so the shape is recognisable elsewhere

On an IMAP server without UIDPLUS a completed move leaves the source copy **soft-deleted**, because
the purge stays gated on `COPYUID` and **that gate is never widened**. `runSyncMessages` hides it and
the stale channel removes the local row, so `existingIds` no longer contains that UID — which is
exactly what makes the row **eligible for re-insertion** by any path that pages the same UID range
later. A deep-backfill window, a self-heal pass or a "load older" pull then re-materialises it as an
ordinary Inbox row. **Hiding a row at the merge does not immunise it against a crawl that inserts by
UID.**

### The two boundaries that keep this safe

1. **Insert-prevention ONLY.** Both new sites *skip the insert*; an EXISTING row is left to the
   merge's stale channel rather than deleted. A crawl therefore still never deletes as a side effect
   of paging, and no new deletion path is added. All four paths agree on the same end state — no
   local row — by two different routes.
2. **The crawl advances on `found`, NEVER on `inserted`.** `deepBackfillFolder` returns
   `(inserted:found:)` and its cursor logic keys off `found` — what the server *reported* — with an
   existing comment at that site recording why (`found > 0 && inserted == 0` means "all already
   exist", not "empty window"). That is precisely why permanently skipping a UID **cannot stall the
   crawl**. Any future filter added on this path must preserve that: a filter that reduced `found`
   would turn a skipped message into a stalled walk.

### 🚨 The fourth path had NO such signal, and `45ad66d38` therefore regressed it (found 2026-08-04)

Boundary 2 above was stated for the CRAWL and was true there. **`SyncEngine.fetchOlderMessages` —
the scroller — had no `found`/`inserted` split at all**: it returned a bare `Int` of rows it
INSERTED, and `InboxViewModel.loadMoreMessages` decided "end of folder" from it twice
(`if newCount == 0 { hasMoreMessages = false }`, then
`hasMoreMessages = freshPage.count >= SyncConfig.inboxPageSize` off a DB re-query). Adding the
`\Deleted` skip made *inserted < returned* possible on that path for the first time, so:

- `IMAPProvider.fetchOlderMessagesWithObservedEpoch` takes `Array(sorted.prefix(limit))` **before any
  flag is known**, so a `\Deleted` record CONSUMES a page slot;
- one such record in a full page made the page look short;
- `hasMoreMessages` went false and **every message older than it became unreachable by scrolling.**

It is live, not theoretical: `IMAPProvider.searchDateRange` issues its `SINCE`/`BEFORE` search with
**no `NOT DELETED` term**, and on a server without UIDPLUS soft-deleted move sources accumulate in
exactly the older mail paging walks into.

**The closure (state the invariant, not the instance): exhaustion is a statement about SERVER
COVERAGE, never about how many rows we chose to materialise.** `fetchOlderMessages` now returns
`(inserted: Int, mayHaveMore: Bool)` and owns the decision, because it owns the cursor; the view
model just assigns `hasMoreMessages = pull.mayHaveMore`. `mayHaveMore` needs BOTH halves, per folder:
**coverage** (`found >= SyncConfig.infiniteScrollFetchLimit` — the server handed back a page as large
as the one we asked for) **and progress** (that folder inserted ≥1 row). The progress half is not a
relapse into counting materialised rows: this pull's cursor IS the folder's oldest LOCAL row, so a
round that inserts nothing re-asks the identical window forever — requiring an insert makes every
continuing round strictly grow the local folder, which is finite. A full page in which nothing could
be materialised therefore stops paging (fail closed, and recoverable: the deep crawl advances by date
window independently of insertion, so that mail still lands locally and the next reset re-arms the
scroller).

Pinned by `DeletedFlagMergeVisibilityTests.pagingContinuesPastAFullPageContainingASoftDeletedRecord`,
which asserts at the STORE that the message BEHIND a full `\Deleted`-bearing page is reachable — a
test on any counter would stay green on a re-broken system. It needed `FakeIMAPServer` to honour
`SINCE`/`BEFORE` (`honorSearchDateCriteria()`, opt-in — the fake answers every window with the whole
mailbox by default and dozens of fixtures depend on that), because the scroller's cursor IS the
window and a server that ignores the window can show no continuation at all.

**Two adjacent facts, confirmed and deliberately NOT changed.** (a) In
`insertBackfillBatchGuardable` the `\Deleted` `continue` sits ABOVE the `existingIds.contains`
branch, so an already-present row whose server copy is `\Deleted` no longer gets the one-shot v10
cc/bcc backfill (`ccBccBackfillDone` is a one-way latch) — correct as is; moving it below would spend
a write on a row the merge is about to delete. (b) Phase 1 of `loadMoreMessages` still ends paging on
`nextPage.count >= SyncConfig.inboxPageSize` (LOCAL rows), which is shipped `v1.6.38` behaviour,
untouched by this row, and the reason phase 2 is only reached when a local page comes back exactly
empty.

🚨 **And the flag must stay OUT of the WINDOW.** Taking it into the window instead of into presence
would raise the UID floor or trip the complete-knowledge branch and stale-delete rows the fetch never
returned — the ADR-IOS-042 / `MIS-IOS-002` Archive mass-deletion shape. Sync windowing stays on
`CAST(messageId AS INTEGER)`. The fetch's cardinality and UID floor measure **coverage** and must
keep counting `\Deleted` records; a "simplification" that filtered at the fetch site would have
stayed green across the whole suite while reintroducing that shape, which is why one of
`45ad66d38`'s three tests exists solely to pin it.

**A1 note:** shipped `07a4bb703` has **zero** occurrences of `isDeletedOnServer` and builds its
`remoteIds` sets unfiltered — it avoided this relist with a mailbox-wide `EXPUNGE`, which is banned
here. The shipped architecture for this problem is NONEXISTENT, so this is an incompleteness of new
work rather than a regression, and the shipped sequence must not be restored as a "fix".
