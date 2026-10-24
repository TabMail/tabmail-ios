## ADR-IOS-095: Every Search Fetches 100, in Pages of 20 Where It Pages

**Status:** Active (2026-10-23). tabmail-ios#264; ADR-IOS-008 parity with the Thunderbird add-on's
`CHAT_SETTINGS` (`searchPageSizeDefault` 20, `emailSearchMaxResults` 100, `memorySearchMaxResults`
100). Builds on ADR-IOS-094 (the search sorts before it takes its limit).

**Context:** the iOS searches each kept a different number of matches. `email_search` fetched 50
and served pages of 20. `memory_search` fetched `min(pageSize * prefetchPages, prefetchMax)` =
5 x 4 = 20, in pages of 5. The Chat History screen listed and searched 200 turns, and the inbox
search screen (`SearchConfig.searchDefaultLimit`) kept 50. The owner decided (2026-10-22) on 100
everywhere.

**Decision:**
1. `email_search` fetches its 100 best matches (`EmailSearchTool.Config.maxResults`), in the
   search's sort, and serves them in pages of 20.
2. `memory_search` fetches 100 (`SearchConfig.memorySearchMaxResults`) in one request, a query and a
   listing alike, and serves them in pages of 20 (`SearchConfig.memorySearchPageSize`). The
   prefetch-pages arithmetic and its settings (`memoryPageSizeDefault`, `memoryPageSizeMax`,
   `memoryPrefetchPagesDefault`, `memoryPrefetchMaxResults`) are deleted.
3. The Chat History screen lists the 100 most recent turns (`ChatHistoryView.listHistory`) and
   searches for the 100 best (`ChatHistoryView.searchHistory`). It does not page; older turns are
   found through its search.
4. `SearchConfig.searchDefaultLimit`, the limit of a search whose caller names none and of the inbox
   search screen, is 100.
5. Past the last page both tools answer with the last page (the existing clamp); the agent narrows
   its query or its dates instead. The backend tool descriptions name no counts, so no prompt changes.

**Consequences:** a keystroke search ranks, snippets and renders up to 100 rows instead of 50
(snippets are read for the survivors only, `snippetsForSurvivors`). The Chat History screen shows
100 turns instead of 200 before a search is needed.

**Tests:** `EmailSearchToolSortTests.fetchesOneHundredInPagesOfTwenty` (105 matches: five pages of
20, the newest 100, page 6 is page 5), `MemorySearchToolTests.fetchesOneHundredInPagesOfTwenty`
(listing and query), `MemorySearchToolTests.historyListsAndSearchesOneHundred`,
`SearchSortTests.searchWithNoLimitKeepsOneHundred`; the date-sort tool test now writes 120 days, more
than one fetch.
