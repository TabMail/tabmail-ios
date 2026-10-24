## ADR-IOS-094: A Search Sorts Before It Takes Its Limit

**Status:** Active (2026-10-23). Port of tabmail-native-fts ADR-NF-017 (native-fts #46, squash
`599b8eb`), tabmail-ios#265; ADR-IOS-008 parity at the tool boundary (ADR-IOS-032).

**Context:** `EmailSearchTool` asked `SearchIndex.search` for the 50 best matches and then sorted
those by date (`date_desc` by default). So a date-sorted search showed the newest of the best
matches, not the newest match, and for a query of only a sender (`from:"boss@company.com"`) which
of the sender's emails were kept was close to random: the keyword scores of a field match measure
the field's length and the year shard's statistics, not relevance. The same was true of the
Thunderbird add-on over native-fts, which the owner decided (2026-10-22) to fix in the search
itself, on both stacks.

**Decision:**
1. `SearchIndex.search` and `hybridSearch` take a `SearchSort`: `relevance` (the tool's default),
   `date_desc`, `date_asc`. Every match is put in that order before the limit is taken.
2. The order lives in the shared `HybridMerge.mergeResults`, which now takes each candidate's date:
   relevance ties go newer first; a date sort's ties go to the better match first, in both
   directions; then rowid. A candidate without a date (its row is gone) is left out. Vector-only
   candidates' dates are read in one `json_each` query (`SearchIndex.fetchDates`, shared with
   `MemoryIndex`).
3. A date sort reads `SearchConfig.dateSortPool` = 4,096 candidates per leg (sqlite-vec's largest
   `k`, which the vendored copy shares) instead of `limit × candidateMultiplier`. The size is the
   native-fts #46 study's choice (300,357 messages: right in every dated query set, best without
   dates, same median cost as 2,048). A match is what the relevance search keeps (`minScore`, or the
   keyword-only answer).
4. A query of only field terms (`SearchIndex.queryIsFieldOnly`: column-scoped terms with only `AND`
   / `OR` / `NOT` between them) skips the vector leg and answers by keyword over every match in the
   sort's order, newest first under relevance, so "the latest from X" is exact.
5. Every keyword-only answer (`searchFTSOnly`: no model, no vector within the dates or field, a merge
   that keeps nothing) orders by the sort: relevance `rank, newer`; a date sort `date, better rank`.
   The `*`-with-dates scan lists the oldest first for `date_asc`, otherwise the newest first.
6. The memory merge passes `relevance`, so equal memory matches come newer first.
7. `EmailSearchTool` passes the sort, no longer sorts after the fetch, defaults to relevance (as the
   `email_search` tool version that ships with it does), and takes a sort it does
   not know as relevance, as Thunderbird does (tabmail-thunderbird#150; before #265 iOS kept the
   search's relevance order for any sort value, ADR-IOS-008 parity). The agent-facing default
   changes with the `email_search` description served from client 1.9.3 (`email_search-v1.9.3.json`);
   a client reporting an older version gets the old description, which says `date_desc`. So the iOS
   release that carries this must be numbered 1.9.3 or later.
8. The demo scope (ADR-IOS-038) is applied in the vector leg, before the merge:
   `SearchIndex.searchVecCandidates` joins its KNN results to `message_meta` and keeps only the
   mode's account, as `MemoryIndex.searchVecCandidates` does. The filter that dropped out-of-scope
   vector-only hits after the merge is deleted. After the merge, a date sort's 4,096-candidate pool let
   the other mode's newer (older) matches by meaning take every place the limit kept, and the demo got
   nothing.

**Unchanged:** `keywordSearch`, the inbox search screen's typing path (`SearchView`), stays newest
first and is not slowed: it never reads the date-sort pool.

**Consequences:**
- A date-sorted search finds the newest (oldest) match among up to 4,096 candidates per leg. A
  common word in more matches than that, without dates, can still miss the newest; the tool
  description tells the agent to narrow with `from_date` / `to_date` (owner 2026-10-22). Walking
  date windows for an exact answer is native-fts #47 (P3), which must not slow the interactive search.
- A date sort costs more than a relevance search (4,096 KNN neighbours and keyword candidates, one
  date read). Measured 2026-10-23 on the iPhone 17 Pro simulator (30,000 synthetic messages over a
  year, limit 100, median of 5): about 0 to 140 ms more than relevance, at most 459 ms (newest first,
  a word in every message, a year); a field-only query costs the same in every sort (about 100 ms).
  Table in tabmail-ios#265. An iPhone measurement is still owed.
- The memory date read follows `MemoryIndex`'s non-throwing style: a failed read is logged and leaves
  the vector-only candidates out, as a failed `fetchMetaForRowids` already did. The email read throws,
  as the other email search reads do.

**Rejected:** sorting the best `limit` by date (the old behaviour); an unbounded date-sorted
candidate read (unbounded scan); a separate date-ordered query per sort (a second ranking to keep in
step with the merge).

**Tests:** `HybridMergeSortTests`, `SearchSortTests` (field-only, keyword fallbacks with ties written
against rowid order, both 4,096-candidate legs, a match by meaning ordered by its date, the `*`
scan), `EmailSearchToolSortTests`, two `MemoryIndexTests` tie tests, date sorts in
`SearchEmptyMergeKeywordFallbackTests`, and each mode answering with its own matches in every sort
(`SearchSortTests`).
