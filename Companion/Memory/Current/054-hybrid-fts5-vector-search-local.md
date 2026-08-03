
### Hybrid FTS5 + Vector Search (Local)
- **Separate SQLite database** (`fts.db` in Application Support) using GRDB — separate from main `tabmail.sqlite`
- **FTS5 schema**: 7 columns matching TB — `messages_fts_YYYY` (msgId, subject, from_, to_, cc, bcc, body) year-sharded
- **BM25 weights**: msgId=0, subject=5, from_=3, to_=2, cc=1, bcc=1, body=1
- **UNION ALL search**: single query across all year shards (not per-year loop). Date filtering in SQL.
- **Synonym expansion**: ~65 email synonym groups (ported from Rust `synonyms.rs`)
- **Query parser**: field aliases (`from:` → `from_:`), auto-wildcards for tokens ≥4 chars, OR groups for synonyms
- **Vector search**: sqlite-vec KNN (v0.1.7-alpha.2), embeddings in `messages_vec` virtual table
- **sqlite-vec safety**: ALL `messages_vec` access MUST go through the writer connection (`writeWithoutTransaction` for reads). Reader pool connections create vec0 vtab instances that crash in `vec0_free_resources` on disconnect. No `sqlite3_auto_extension` — registered per-connection in SearchIndex only.
- **Hybrid merge**: 70% vector / 30% keyword scoring, min score 0.1, 4× candidate multiplier
- **FTS-only fallback**: when vec table empty (embedding rebuild), uses `searchFTSOnly()` — sorts by dateMs DESC, rank ASC
- **Date-range scan**: `query="*"` with date params → `scanByDateRange()` (no FTS MATCH, just date filter on message_meta)
- **Column-scope filter-first**: `from:"email"` queries pre-filter vec candidates to matching rowids
- **Indexing pipeline**: headers indexed synchronously (`await indexHeadersForFTS`) — no `Task.detached`, eliminating body race condition. Body + embedding on fetchBody (AccountManager hook).
- **Bulk index**: runs after sync if FTS index is sparse (first-launch catch-up). Phase 1: headers, Phase 2: body backfill from GRDB.
- **Background embedding rebuild**: generates embeddings for messages with bodies but no embeddings, low priority
- **Model conversion**: `Scripts/convert_model.py` → `AllMiniLML6v2.mlmodelc` + `tokenizer.json` in Resources
- **Graceful degradation**: if model/tokenizer not in bundle, falls back to FTS-only (keyword search)
