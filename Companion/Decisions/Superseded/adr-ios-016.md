
## ADR-IOS-016: ~~PersistenceGateway — Coalesced SwiftData Saves~~ (SUPERSEDED)

**Status:** Superseded — no longer applicable after migration from SwiftData to GRDB.

**Why superseded:** GRDB's `DatabasePool` writes are immediate and thread-safe. There is no `@Query` re-evaluation, no `autosaveEnabled`, and no `ModelContext` to manage. The "render storm" problem was SwiftData-specific (`@Query` change notifications on every `save()`). With GRDB, UI updates are explicit via `NavigationStore` (GRDB `ValueObservation`), which doesn't suffer from the same issue. The `PersistenceGateway` class, `setNeedsSave()`, `awaitSave()`, and `saveNow()` have all been removed.

---
