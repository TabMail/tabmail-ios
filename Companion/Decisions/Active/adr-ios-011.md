
## ADR-IOS-011: ActionTag Raw Values Are Plain Names

**Context:** See global ADR-022. ActionTag raw values were `"tm_delete"` (IMAP keyword format), causing Device Sync mismatches with TB which uses `"delete"` internally.

**Decision:** Changed `ActionTag` raw values to plain names (`"delete"`, `"archive"`, `"reply"`, `"none"`). Added `imapKeyword` computed property and `fromIMAPKeyword()` for IMAP/Gmail boundary conversion.

**Rationale:** Unifies internal storage format with TB. Eliminates transport-layer naming from application logic.

**Consequences:**
- `ActionTag.rawValue` is now the canonical format for Device Sync, database, and all internal use
- Use `tag.imapKeyword` when writing IMAP flags or Gmail labels
- Use `ActionTag.fromIMAPKeyword()` when reading IMAP flags or Gmail labels

---
