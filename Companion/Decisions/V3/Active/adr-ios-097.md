## ADR-IOS-097: A Date-Sorted Search Walks Date Windows

**Status:** Active (2026-10-28). Port of tabmail-native-fts ADR-NF-023 (native-fts #47, PR #58, squash
`60536b5`), tabmail-ios#294; amends ADR-IOS-094 (the date sort's single pool). ADR-IOS-008 parity at the
tool boundary.

**Context:** ADR-IOS-094 made a date sort read `SearchConfig.dateSortPool` (4,096) candidates per leg and
sort that pool. With more matches than that in a leg, it sorted the pool's matches, not all of them: a
common word without dates could miss the newest (oldest) match. native-fts measured the first result right
for 33% of common words without dates and the full list for 0-7% (ADR-NF-023). The `email_search`
description told the agent to narrow by `from_date` / `to_date`.

**Decision:** `SearchIndex.hybridSearch` with a date sort calls `dateWindowCandidates`, which mirrors
native-fts `date_window_candidates` rule for rule. Relevance is unchanged (one pool, `relevanceCandidates`).
1. Walk the search's dates in windows from the end the sort starts at (newest for `date_desc`, oldest for
   `date_asc`). Every match in a window comes before every match in the next, so the walk stops once
   `limit` matches are found.
2. Keyword: the next `dateSortPool` keyword matches in sort order (date, then rank; `keywordOrder`). The
   window ends where they end; the matches at their last date go to the next window, so a window never
   splits a date. More than a pool at one millisecond cannot be split: that pool is sorted and a
   debug-gated line says so.
3. Vector: sqlite-vec's `dateSortPool` nearest within the window (`knnCandidates`, `alwaysScoped`) hold every
   match by meaning alone when fewer answered, or the farthest's vector-only score
   (`vectorWeight * HybridMerge.adjustedVectorScore`) is under `minScore`.
4. Otherwise every one of them is a match: every vector's distance within the window is read in one pass
   (`vecDistancesWithin`, `vec_distance_cosine` by rowid). More than the limit match, so the walk ends there.
5. A full pool whose farthest scores above `vectorScoreThreshold` leaves out vectors a keyword match still
   counts: the own distances of the window's keyword matches missing from it are read (one `rowid IN`
   search over at most a pool of rows). So no score depends on the window.
6. No vector in the windows walked: one k = 1 search over the whole dates (and field). None found, or any
   vector read failing, means the keyword-only answer (`searchFTSOnly`).
7. Date bounds are one-sided at the ends of time (`Int64.min` / `Int64.max` bound only their own side).

iOS differences from native-fts, each forced by the app's own index:
- The demo scope (ADR-IOS-038) is inside the vector search's `rowid IN` (`alwaysScoped`), not a join after
  it: a window is complete when fewer than a pool answered, which holds only if every answer is in scope.
- A year shard is not a window. The keyword pool and the vector pool choose windows, as in native-fts.
- Vector reads go through the writer connection (sqlite-vec's vtab lifecycle), as `searchVecCandidates`
  always has; the walk's reads are not one snapshot with the keyword reads, as the hybrid search's never were.

**The inbox search screen's typing path is untouched.** `SearchView` -> `keywordSearch` -> `searchFTSOnly`
never reaches `hybridSearch` and never read the pool: it is one SQL query over every match, newest first.
The walk therefore cannot slow it, and no iPhone measurement is needed to keep that requirement (issue
#294). Only `search` / `hybridSearch` callers with a date sort walk; today that is the agent's
`email_search`. Memory search has no sort and is unaffected.

**Consequences:**
- A date-sorted `email_search` answers the true newest (oldest) matches, in order, however many match. The
  tool description's advice to narrow a common-word date sort by dates is no longer needed for
  correctness (the backend description changes separately).
- A window whose pool is full reads the vectors once more (own distances, or the whole window in one pass,
  which ends the walk): no window reads them more than twice. Typically one window.
- Costs on a phone are not measured here; native-fts measured medians within about 6% of the single pool
  on a 300,783-message archive.

**Rejected:** year shards as windows (a year holds from a few to tens of thousands of matches); a separate
interactive single-query path (the typing path already is one, and no other interactive caller sorts);
completeness at `vectorScoreThreshold` and narrowing a window full of matches (ADR-NF-023 "Rejected":
quadratic or many searches on a dense archive).

**Tests:** `SearchDateWindowTests` (exact past the keyword pool, across two windows with an edge date shared
by 20 matches, exact past the vector pool, a keyword match scored by its own meaning whatever window found
it, a pool of matches at one date terminates, the ends of time); the 4,096-pool tests and field-only,
keyword-fallback and demo tests in `SearchSortTests` pass through the walk unchanged.
