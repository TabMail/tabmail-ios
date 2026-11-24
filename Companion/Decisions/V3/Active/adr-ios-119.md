## ADR-IOS-119: The Header Records When Its HTML Was Cached, Kept Exact by SQLite Triggers

**Status:** Active (2026-11-24, #1433). Amends ADR-IOS-050 (the display cache's state) and
ADR-IOS-029 (`messageHeader_htmlCachedAt` replaces `messageBody_staleEvict` in the deferred set).

**Context:** The body-cache evict (`SyncEngine.runEvictStaleBodies`) deletes the cached HTML of
messages outside every inbox that was cached more than `SyncConfig.bodyCacheTTLHours` ago, except
the undo set and each folder's `SyncConfig.bodyCacheRecentPerFolder` newest. It found its candidates
by walking `messageBody` in `fetchedAt` order (`messageBody_staleEvict`, #1354) and reading each
body's header to learn whether the message was in an inbox. Inbox bodies are always kept, so once
they pass the TTL every pass walked all of them again, a page of `SyncConfig.pruneChunkSize` per
write. Measured (#1427, simulator): at 105k headers a pass visited 18,764 kept bodies, read 65.8k
pages, took 7.5 s and took the writer 377 times; at 525k, about 93,000 bodies, 33 to 37 s and 1,861
writes, with single writes up to 715 ms. The pass runs on every foreground poll. No narrower exact
read existed: the body row records nothing about the inbox, and walking the headers outside the
inbox instead reads about 85k rows at 105k.

**Decision:**
1. **The pair.** `messageHeader.htmlCachedAt` (`v116_addMessageHeaderHTMLCachedAt`) is the
   `fetchedAt` of the message's `messageBody` row, NULL when it has none. It is not part of the
   `MessageHeader` record, so a record `insert`, `update` or `save` never writes it.
2. **SQLite keeps it exact,** whatever code writes either table, with five triggers:
   `messageBody` AFTER INSERT (set it), AFTER UPDATE OF `id`, `fetchedAt` when either changed
   (clear the old id's header, set the new one's), AFTER DELETE (clear it); `messageHeader` AFTER
   INSERT when it differs from the body's (a body written before its header, a header deleted and
   inserted again), AFTER UPDATE OF `id` when the id changed (set it from the body at the new id).
   Each trigger writes the state at the end of its own statement, so any order of header and body
   writes ends exact. A `REPLACE` fires the insert triggers and so ends exact too.
3. **Index.** `messageHeader_htmlCachedAt (isInInbox, htmlCachedAt)`, NULLs included (not
   partial), a deferred index (`SyncEngine.deferredIndexes`; decision 7). The evict seeks `isInInbox = 0 AND htmlCachedAt < cutoff` in keyset pages on
   `(htmlCachedAt, rowid)` (`HTMLCachePair.evictCandidatesPageSQL`); "no cached HTML" is
   `htmlCachedAt IS NULL` under one `isInInbox` value. Leading with `isInInbox` keeps the evict from
   reading old inbox entries only to skip them; `StaleBodyEvictPairProofTests` measures it against
   the column alone.
4. **One reader.** `HTMLCachePair` answers every "is this message's HTML cached?" question
   (`isCached`, `evictCandidatesPage`): the `fetchBody` already-loaded check, the thread-message
   check in `MessageDetailViewModel`, `NSEDataBridge.verifyDurable`, the no-search-text diagnostic
   in `ActiveAIQueue`, and the evict. Reads of the HTML itself, the reads that carry a body to a new
   id, the canonicalize re-attach guard, and the one-time `bodyComplete` restore in `SyncEngineFTS`
   (it runs at startup and can come before the fill, decision 7) stay on `messageBody`. `HTMLCachePairFenceTests` lists every
   production site that names `messageBody` and why, and fails on a new one; only `AppDatabase` and
   `HTMLCachePair` name the column.
5. **The evict reads only candidates.** It applies the unchanged keep rules (undo set, a folder's
   newest) to the headers the index returns. It no longer reads bodies without a header (the former
   "orphan leg"): such a body is left only when the release after its header's removal is skipped
   (#1445) and stays as a harmless leftover (#1446). Schedule, TTL and rules are unchanged. The
   evict waits for `messageHeader_htmlCachedAt` (`runEvictStaleBodiesIfIndexed`), as it waited
   for `messageBody_staleEvict`, which leaves `SyncEngine.deferredIndexes`. As of 2026-11-24 no
   released or TestFlight build ran the deferred step with `messageBody_staleEvict` in it (it was
   added after build 392), so no user's database holds it; a development database that built it
   keeps it (nothing reads it, and it changes no result).
6. **A UIDVALIDITY reset deletes every cached body in the folder's id range**
   (`uidValidityResetPurgeTxn`), with or without a header, after the header delete (so the delete
   trigger finds none of the folder's own headers to rewrite): `id >= <account>:<folder>: AND id <`
   its successor (`MessageIdentity.headerIdRange`, `prefixUpperBound`, shared with
   `BodyAssetStore`), plus the no-deeper-colon guard so a child folder keeps its HTML. Before, a
   body left without a header survived the reset and the new message given that UID adopted it.
   An optimistic move still in flight keeps its source id until the drain re-keys it
   (ADR-IOS-061): a message moving out of the folder keeps its header and loses its cached HTML
   (its address is in the renumbered space; the trigger clears its pair), and a message moving in
   loses its header and leaves its HTML under the source folder's id, a harmless leftover like
   #1446's.
7. **The fill runs in the deferred step, not the migration.** v116 adds only the column and the
   five triggers. The bodies cached before v116 are recorded by `HTMLCachePair.fillSQL`, which
   `SyncEngine.createDeferredIndexes` runs only while the index is missing, in the one write that
   then builds the index and analyzes it (`runRefreshPlannerStatisticsIfStale`). The index's
   existence is the proof the fill ran: both commit together, and no app-kept marker records it.
   Two reasons: the fill reads every cached body once (`fetchedAt` is stored after the HTML), which
   is upgrade work for the deferred step, not the blocking migration chain; and an index built in
   a migration would have no planner statistics until the next `ANALYZE` (#1401). It costs what
   `messageBody_staleEvict`'s build cost, which read every cached body the same way.
   **Before the step,** a message whose HTML was cached before v116 and not written since reads
   as not cached: `fetchBody` and the thread view fetch its body again; the notification merge
   re-merges a staged row whose body predates v116 (its body insert is ignored, so the pair stays
   empty); the AI queue's diagnostic says it has no body. Nothing is deleted (the evict waits for
   the index) and no message is given another's content. A pair that is set is exact from v116 on,
   because the triggers run from then.

**Proof of need (why a column, triggers and an index):** no existing field says whether a header's
HTML is cached or when. `bodyComplete` is the search-text pair (ADR-IOS-050) and is set for messages
whose HTML was evicted long ago; `messageBody` is keyed by content and holds nothing about the inbox
or the folder. A partial index on `messageBody` cannot name `isInInbox`, which lives on the header. The
column is kept by SQLite, not by app code, so no writer can forget it, which is what ADR-IOS-050 feared
from a second flag: it is a pair column on the house pattern for state held elsewhere, not a marker.

**Content keys.** The triggers match a body to its header by id, exact while `ContentKey.forHeader`
returns the header id. The change that makes content keys differ must re-point the triggers at the
content key the header holds; `HTMLCachePairTests.contentKeysAreHeaderIds` fails that day.

**Write cost:** a body save, re-save or delete also rewrites its header row and moves one entry of the
new index; a header insert, and a header id change, probe `messageBody` by primary key and, when a
body is there, read its `fetchedAt` through the body's pages (it is stored after the HTML); a
whole-table body delete fires the delete trigger per row (SQLite's truncate shortcut is off while a
trigger exists). Account removal and the full wipe delete the headers first, so their body deletes
rewrite no header (`HTMLCachePairTests.removalAndWipeRewriteNoHeader`). A write of `htmlCachedAt`
alone does not wake the inbox notification observer (`InboxNotificationObserver.ignoredUpdateColumns`)
or the chat pill's reminder count, which reads no such column. Measured against the old schema in
`StaleBodyEvictPairProofTests` (body save, re-save, delete, header merge, inbox moves, IMAP move
with its body, message delete, both whole-table wipes, account removal and a reset in both orders),
with v116's time, the deferred step's time (whole, and the fill, the index and `ANALYZE` apart, per
MB of body pages) and the column's and index's size at 105k and 525k headers. The proof seeds the
body cache as #1427 did: a body for every complete message the rules keep and for other complete
mail within the TTL, each 4,200 to 8,292 bytes of HTML (one whole cycle of a 4,096-byte page's
overflow layout). A phone whose bodies are larger pays the fill's cost in proportion to its body
pages, which is why the step's time is reported per MB.

**Consequences:** the evict pass reads the old non-inbox candidates only, so its cost no longer grows
with the inbox. A later migration that rebuilds `messageHeader` or `messageBody` drops these triggers
with the old table and must create them again (`HTMLCachePairTests` checks the pair after the whole
chain). Tests: `HTMLCachePairTests` (every write shape, the deferred step's fill and the state
before it, renames, the rekey, the delete orders), `StaleBodyEvictRunTests` (the first maintenance
pass fills and indexes, the next one evicts),
`StaleBodyEvictDifferentialTests` (the old step against the new on the same rows: `new ⊆ old`, and
`old − new` is exactly the headerless bodies), `UidValidityResetBodyPurgeTests` (a reused UID adopts
no HTML), `HTMLCachePairFenceTests`.
