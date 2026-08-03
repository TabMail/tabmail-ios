
### Bounded Memory (CRITICAL)
- **Every loop/batch operation MUST process a bounded number of items** — never accumulate unbounded arrays or materialize all objects
- All chunk/batch sizes are centralized in `SyncConfig` enum (`Services/Sync/SyncConfig.swift`) and `BackfillProfile` enum — never hardcode numeric limits elsewhere
- Current defaults (normal profile): sync=50, snippets=25, backfill=500, prune=50, FTS index=200, embeddings=50, body FTS=20
- Aggressive profile: backfill=1000, IMAP fetch batch=200 (per-lock), Gmail fetch batch=100, body FTS=50
- GRDB queries: use `Column("folderId") == fid` where `folder.id` is `"accountId:path"`, unique across accounts
