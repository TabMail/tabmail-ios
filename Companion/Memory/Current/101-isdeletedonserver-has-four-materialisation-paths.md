## `MessageHeaderInfo.isDeletedOnServer` has FOUR **materialisation** paths and a FIFTH **presentation** path the census could not see (2026-08-04, corrected same day)

**The census that matters is of the paths that BUILD A `MessageHeader` FROM a `MessageHeaderInfo`,
not of the sites that read the flag.** `a659c4bc5` closed `IOS-IMAP-001`/D3 by teaching the *merge*
to stop presenting a message the server reports as `\Deleted`, and enumerated **two** consumers.
There were **four** places that materialise a row from the same `MessageHeaderInfo` values, and the
other two never consulted the flag — so a message the merge had correctly removed could be put back
as an ordinary visible row by a later crawl. Closed by `45ad66d38`.

> ⚠️ **AND THE NOUN THE CENSUS ENUMERATED IS THE LIMIT OF WHAT IT COULD FIND.** The noun was
> `MessageHeader` **construction**. A path that shows a message to the user WITHOUT constructing a
> `MessageHeader` is structurally invisible to that search, and there is exactly one:
> `SearchView.searchAccount`. "Four materialisation paths" is TRUE of its own noun and does not
> license the broader claim that all presentation is covered — see
> "**The FIFTH path**" below. When a census closes a register row, write the noun into the row.

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
  ⚠️ **Two of those feeders are DEAD CODE and the list must not be read as a reachability claim:**
  `rg -n 'deepBackfillFolder' TabMail/` returns ONE `func` declaration and comment mentions only —
  **zero callers** — and its sole callee `backfillWindow` is called from exactly one production
  site, *inside `deepBackfillFolder` itself*. The live feeders are the `SyncEngineBackfillWalk`
  call sites and `SyncEngineSelfHeal`. Filtering at the funnel is still correct (it covers the live
  feeders and any future revival of the dead ones); what is NOT correct is citing
  `deepBackfillFolder` as a mechanism that runs.
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
2. **The crawl advances on COVERAGE, NEVER on `inserted`.** That is precisely why permanently
   skipping a UID **cannot stall the crawl**. Any future filter on this path must preserve it: a
   filter that shrank the coverage quantity would turn a skipped message into a stalled walk.

   ⚠️ **The mechanism originally cited here — `deepBackfillFolder`'s `found == 0` termination — is
   DEAD CODE (see the funnel bullet above), so it proves nothing about the shipping crawl.** The
   invariant holds anyway, by a different and live mechanism:
   **`SyncEngine.runBackfill`** (`TabMail/Services/Sync/SyncEngineBackfillWalk.swift`) walks the
   folder's UID space downward in ranges and persists **`UIDWalkCursor`'s `confirmedCursor`**
   (`TabMail/Services/Sync/SyncEngineBackfill.swift`), which advances only through
   `UIDWalkCursor.confirmRange`. A range is confirmed when it has been **accounted for** — either
   `IMAPProvider.searchExistingUIDs` reported it empty, or its FETCH+insert leg completed — and a
   failed or epoch-refused range goes back via `failRange` instead. **A range that inserts zero rows
   is still confirmed**, so `\Deleted`-skipped and dedupe-skipped UIDs advance the cursor exactly
   like inserted ones. `UIDWalkCursor`'s own header states the model: *"N workers consume the
   highest UIDs first, walking backward to UID 1"*, `isComplete` is `cursor < 1`, and the persisted
   value is *"only advances past ranges that are fully confirmed, not just claimed"*.

   **What invokes it — because "covered by X" is a claim about the path that REACHES X, and an
   unreachable X covers nothing.** Two live entry points, both verified by grep:
   `SyncEngine.startBackfill` (`SyncEngineBackfill.swift`) runs the per-account crawl loop and calls
   `runBackfill(account:)` each cycle; it is started from `SyncEngine.sync` after every sync, and
   from `FastSyncView` / `SettingsView` / `DebugLogView`. Separately `SyncScheduler`'s BGProcessing
   pass calls `AccountManager.runBackfill` (`AccountManagerSync.swift`) →
   `SyncEngine.performBackfill` (`SyncEngineBackfillCleanup.swift`) → the same `runBackfill`.

   **Negative case, stated because the absolute is otherwise false.** `runBackfill` selects only
   folders with `backfillComplete == false`, so a folder already marked complete is never re-walked
   — but by then its whole UID space has been covered down to UID 1, so there is no older mail left
   for the walk to reach. The residual gap is a folder wrongly marked complete: `runBackfill`'s
   `.fresh` branch derives its initial cursor from `UIDNEXT`, and a server that does not report
   `UIDNEXT` yields `0`, an `initialCursor` of `-1`, and `backfillComplete = true` permanently. The
   epoch beside it *is* normalised and the UIDNEXT is not — that asymmetry is the tell. That case is
   NOT recoverable by ordinary sync and is byte-identical in shipped `v1.6.38`.

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
be materialised therefore stops paging (fail closed, and recoverable — by the mechanism named in
boundary 2 above, **not** by the one the commit body named; see the erratum below).

### ⚠️ ERRATUM — `e4dd08e92`'s commit body justified its accepted limitation with DEAD CODE (2026-08-04)

The commit body of `e4dd08e92` is **not** being rewritten; this is the correction of record.

It said, twice, something that is false:

- as positive design justification — *"`deepBackfillFolder` already made this distinction — it
  terminates on `found == 0`, never `inserted == 0` — and this extends the same rule to the paging
  pull"*; and
- as the accepted limitation's recoverability argument — *"No re-issue loop was built for it — the
  deep backfill crawl advances by DATE WINDOW independently of insertion, so that mail still lands
  locally with no user gesture."*

**`deepBackfillFolder` has zero callers, and so does the date-window crawl as a whole.** `rg -n
'deepBackfillFolder' TabMail/` returns one `func` declaration in
`TabMail/Services/Sync/SyncEngineBackfillDeep.swift` plus comment mentions; its only callee
`backfillWindow` is reached from exactly one production site, *inside `deepBackfillFolder`*. Nothing
in the shipping app advances by date window. (Which is unsurprising and not itself a bug: the live
UID walk goes all the way down to UID 1, so the "crawl past the age cutoff" job the date-window
crawl existed for no longer exists. **Do not delete it as a side effect of reading this note** —
dead-code removal is a separate decision with its own risk; this entry only records the fact.)

**The CONCLUSION survives — the mail is recoverable with no user gesture — but by
`SyncEngine.runBackfill`'s UID-range walk, whose cursor advances on COVERAGE, not on inserts**, and
which is reached by the two invocation paths enumerated in boundary 2. The accepted limitation
therefore stands; only its stated mechanism was wrong.

**The tell, generalised:** a design justification that cites a sibling mechanism as precedent
("X already does this") is a claim about code that RUNS. Grep for its callers before writing it
down. The same sentence was written into the commit message, this topic and the `fetchOlderMessages`
doc comment before anyone checked, because each one was copied from the last.

### The FIFTH path — `SearchView.searchAccount` PRESENTS without MATERIALISING (found 2026-08-04)

`SearchView.searchAccount` (`TabMail/Views/Inbox/SearchView.swift`) calls
`AccountManager.search` (`TabMail/Services/Account/AccountManagerActions.swift`) →
`IMAPProvider.search` → `IMAPProvider.searchOnConnection`, which ends in
`infos.compactMap { mapMessageInfo($0) }` — i.e. the values it returns **do** carry
`isDeletedOnServer`, set by the one true producer. `searchAccount` then maps each
`MessageHeaderInfo` straight into a `SearchResult(source: .remote, …, headerId: nil)` and **never
consults the flag**. No `MessageHeader` is constructed anywhere on that path, which is exactly why a
census of `MessageHeader(` construction sites could not find it.

`searchOnConnection` builds its criteria from `.text` / `.since` / `.before` / `.from` / `.to` and
adds **no `NOT DELETED` term**, so the server returns soft-deleted copies too. Effect on a
non-UIDPLUS server, where soft-deleted move sources accumulate: the user searches, sees **two hits
for one email**, and tapping the residue does **nothing** — `SearchView.openResult`'s remote branch
(`headerId == nil`) resolves via `resolveRemoteResultHeaderId` and, on a nil resolve, simply returns
without navigating; the `showStaleResultAlert` arm exists only in the local branch. Registered
**OPEN** on `KNOWN_ISSUES.md` `IOS-IMAP-001`. ✅ **CLOSED by `afa7889ee`** — both halves; see *THE FIFTH
PATH IS CLOSED* at the end of this file, which also states the noun the closing census enumerated.

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

### ✅ THE FIFTH PATH IS CLOSED — and the closing census names its noun (`afa7889ee`, 2026-08-04)

**The noun this closure enumerated: CONSUMERS OF `MessageHeaderInfo`** (`rg -n 'MessageHeaderInfo'
TabMail/ Shared/` — 18 files), not producers of `MessageHeader`. Under that noun there are **EIGHT**
consumers, and every one is accounted for (`MIS-006`):

1. `SyncEngineFullSync.selectStaleHeaders` — reads the flag.
2. `SyncEngineFullSync.runSyncMessages` — reads the flag.
3. `SyncEngine.insertBackfillBatchGuardable` — the funnel (fed by `SyncEngineBackfillWalk` ×2 and
   `SyncEngineBackfillDeep` ×2) — reads the flag.
4. `SyncEngine.fetchOlderMessages` — reads the flag.
5. **`SearchView.searchAccount` — the presentation path, closed here.**
6. `SyncEngineDeltaSync`'s Gmail arm (`detail.header`) — materialises, **LEFT ALONE**: only
   `IMAPProvider.mapMessageInfo` ever sets `isDeletedOnServer`, and `IMAPProvider.fetchHistory`
   returns nil, so IMAP never reaches the delta path. Structurally cannot carry the flag.
7. `SyncEngineDeltaSync`'s Exchange arm — same, **LEFT ALONE**.
8. `SyncEngineEpochVerify.classifyEpochVerificationSample` — compares rfc822 ids for epoch
   verification; materialises nothing, presents nothing. **LEFT ALONE.**

**No sixth presentation path exists**: `AccountManager.search` has exactly ONE caller,
`SearchView.searchAccount` — established by grep, not by meaning (`MIS-021`).

**The fix, in two halves.**
(a) `SearchView.presentableRemoteResults` drops every `isDeletedOnServer` record before a
`SearchResult` is built, so the invariant holds for every provider rather than for IMAP only.
(b) `SearchView.tapOutcome` returns a three-case `ResultTapOutcome` with **no silent case** and
`openResult` switches over it, so a remote nil-resolve raises its own alert ("Not downloaded yet",
worded to state only the observed fact — this device holds no copy — rather than claiming the message
is gone) instead of returning.

🚨 **The `NOT DELETED` term was deliberately NOT added to `IMAPProvider.searchOnConnection`; the
SEARCH criteria are byte-identical.** Narrowing what the SERVER reports is the ADR-IOS-042 /
`MIS-IOS-002` shape in another coordinate system, and it would cover IMAP only.

**A1:** neither `07a4bb703` nor `v2final` (`e28dd4edb`) has `isDeletedOnServer`, a `NOT DELETED`
term, or an alert on the remote branch — **both return silently on a nil remote resolve exactly as
v3 did**, so the dead tap is longstanding shipped behaviour, not a v3 regression.

**Accepted residual, with the recovering mechanism's CALLER named (`MIS-024`):** a remote hit for a
message this device has not downloaded still cannot be opened — it is now EXPLAINED rather than
silent. It becomes openable when the header lands locally via `SyncEngine.runBackfill`'s UID-range
walk, invoked by `SyncEngine.startBackfill`'s crawl loop (from `SyncEngine.sync`) and by
`SyncScheduler` → `AccountManager.runBackfill` → `SyncEngine.performBackfill`. **The non-recovering
case, named:** a folder wrongly marked complete by `runBackfill`'s `.fresh` branch when the server
reports no UIDNEXT — already registered. Fetch-on-tap was not built; shipped never did it.
