# IOS-SEARCH-005

- Register classification: `resolved`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-13, `374a8b3c1`)** — `SearchIndex.searchFTSOnly` generated an FTS5 `snippet()`
for **every row every arm matched**, then discarded all but the rows surviving the final `LIMIT`.
Deferring snippet generation to the survivors took the per-keystroke search from **1,145 ms to
~597 ms (−48%)**.

## Subsystem and search terms

`SearchIndex.searchFTSOnly`; `searchFTSCandidates`; `snippet(`; `bm25(`; FTS5 auxiliary function;
per-keystroke search; typing latency; `UNION ALL` across year shards; `ORDER BY dateMs DESC, rank ASC`;
two-phase query; `fts.rowid`; snippet deferral; `SearchConfig.searchDefaultLimit`;
`SearchIndexError.snippetMissing`; `SearchView` debounced path; `try?` swallowing boundary

## Full detail

**The shape.** `searchFTSOnly` builds a 6-arm `UNION ALL`, one arm per year shard, each selecting
`snippet(…) AS snippet, bm25(…) AS rank`. **No arm carries its own `ORDER BY` or `LIMIT`** — ordering
and limiting happen once, over the union:

```swift
let sql = subqueries.joined(separator: " UNION ALL ") +
    " ORDER BY dateMs DESC, rank ASC LIMIT ?\(limitParam)"
```

So `snippet()` — an FTS5 auxiliary function that reassembles and tokenises the matched column — ran
for the **entire match set**, while only `SearchConfig.searchDefaultLimit` rows were ever displayed.
The fix splits it into two phases: select `fts.rowid` plus `bm25` first, apply the ordering and limit,
then generate snippets only for the surviving rowids.

## ⚠️ This is NOT the index-defeating sorter class, despite arriving from the same audit

The transferable defect in `53d17514e` (`IOS-SEARCH-004`'s family) is *"the `LIMIT` bounds the OUTPUT
and not the WORK"*, and its remedy there was a **per-partition rewrite** — which works because an
ordering index exists. **Here no such index exists and none can:** FTS5 `MATCH` output has no date
order. Measured directly — per-folder 187 ms versus IN-list 191 ms — so the per-partition remedy buys
nothing on this path. The cost was the **auxiliary function**, not the plan.

Filing it beside the sorter findings because an audit found them together would be the
mis-classification the register exists to prevent.

## ⚠️ A defect in the FIRST version of this fix, caught pre-commit — keep the lesson

The initial implementation threw `SearchIndexError.snippetMissing` for the "impossible" case of a
surviving row with no snippet, reasoning that degrading silently would hide a real defect. **The only
per-keystroke consumer swallows it:** `SearchView` calls
`(try? await SearchIndex.shared.keywordSearch(…)) ?? []`. The throw would therefore have discarded the
**entire ranked result set** for that query, silently, with no error and no log — converting a
cosmetic single-row defect into a silent whole-result-set one.

Note the rule-4 pincer that decides this without weighing preferences: the argument for the throw was
that both phases share one `dbPool.read` snapshot, which makes the case **impossible**. So the throw is
either dead code (impossible ⇒ do not add error handling for impossible scenarios) or actively harmful
(possible ⇒ swallowed by `try?`). **Neither branch justifies it.** Resolution: degrade to an empty
snippet plus a debug-gated log, and keep the strictness in the equivalence *test*, where a missing
snippet fails a test instead of a user's search.

**Reusable rule:** before adding a `throw` to a fail-closed guard, **grep the call chain for `try?` and
`?? []`**. Fail-closed is only fail-*safe* if someone is listening; at a swallowing boundary it is
fail-silent, and on a display path silence is worse than degradation.

## Known remaining instance of the same shape — deliberately NOT fixed

`SearchIndex.searchFTSCandidates` has the **identical** one-phase snippet shape and already selects
`fts.rowid`, so this fix's mechanism transfers directly. It is the **hybrid path**
(`search()` ← `EmailSearchTool`, the agent-chat surface), **not** the typing path, so it is not
per-keystroke and was left untouched by scope. Anyone sweeping this class should start there.

## Related

- `IOS-SEARCH-004` — the sorter-shape sibling from the same audit; **different mechanism**, do not merge.
- `IOS-PERF-012` — stat-regime and walk-position measurement traps; read before re-measuring.
- `IOS-PERF-013` — the queue-side finding fixed in the same pass.
- `53d17514e` — the Archive-search fix whose class this one is explicitly **not** a member of.
