
## ADR-IOS-017: ~~Remove Folder→MessageHeader @Relationship~~ (SUPERSEDED)

**Status:** Superseded — no longer applicable after migration from SwiftData to GRDB.

**Why superseded:** GRDB uses explicit SQL foreign keys, not ORM-managed inverse relationships. The `messageHeader` table has a `folderId` foreign key with `ON DELETE CASCADE` — the database engine handles cascade deletes automatically. There is no inverse materialization problem because GRDB never eagerly loads related objects. Queries use `Column("folderId") == fid` directly.

---
