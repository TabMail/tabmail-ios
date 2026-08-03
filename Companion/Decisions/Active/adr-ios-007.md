
## ADR-IOS-007: Hybrid FTS5 + Vector Search (Local)

**Context:** Search was remote-first (IMAP SEARCH / Gmail API) with basic in-memory string matching for local results. This was slow, didn't search message bodies, had no stemming or synonyms, and required network connectivity. The Thunderbird extension had a mature Rust FTS library with FTS5, synonym expansion, and all-MiniLM-L6-v2 embeddings.

**Decision:**
1. **Separate SQLite FTS5 database** — `fts.db` in Application Support using GRDB, separate from the main app database (`tabmail.sqlite`).
2. **Query parser with synonym expansion** — Ported from Rust `query.rs`. Handles field aliases (`from:`→`from_:`), auto-wildcards for tokens ≥4 chars, OR groups for synonym expansion (~65 email synonym groups).
3. **CoreML embeddings** — all-MiniLM-L6-v2 converted to CoreML float16 (~45MB). Runs on Neural Engine when available. Bundled in app for offline support.
4. **Hybrid merge** — 70% semantic / 30% keyword scoring with candidate multiplier (4×). Minimum score threshold (0.1) filters noise.
5. **In-memory embedding matrix** — Loaded lazily on first semantic search. Uses Accelerate/vDSP for batch cosine similarity. Evicted on memory warnings.
6. **Incremental indexing** — Headers indexed via SyncEngine hooks on insert. Body text + embedding generated in AccountManager.fetchBody(). Background rebuild catches up existing messages.
7. **Graceful degradation** — If CoreML model/tokenizer not in bundle, falls back to FTS-only keyword search. If FTS index is empty, falls back to legacy string matching.

**Rationale:**
- Offline-capable search is essential for a mobile mail client
- FTS5 with Porter stemmer handles English morphology (searching "meeting" finds "meetings")
- Synonym expansion finds related concepts (searching "meeting" also finds "standup", "huddle", "sync")
- Semantic search finds conceptually similar messages even without keyword overlap
- CoreML + Neural Engine makes embedding inference practical on modern iPhones (~10ms per embedding)
- Porting from proven Rust implementation reduces risk vs. designing from scratch

**Consequences:**
- ~45MB added to app bundle (CoreML model) — acceptable, comparable to other ML features
- ~75MB additional on-device storage for embeddings (at 50K messages) — excluded from StorageEstimator
- Embedding generation is CPU/NPU-intensive — throttled to low priority, cooperative cancellation
- First-launch bulk indexing may take minutes for large mailboxes — runs in background
- GRDB adds a new dependency — well-maintained, widely used in iOS ecosystem

---
