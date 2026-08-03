
### IMAP Folder Role Detection & Dedup (iCloud "Trash" + "Deleted Messages")
- `IMAPProvider.mapRole(attributes:name:)` returns a single role per folder via SPECIAL-USE first, then a name-based fallback. Both "Trash" and "Deleted Messages" match the trash heuristic — without dedup, iCloud accounts ended up with two `.trash` folders (and a confusing/empty unified Trash view).
- `IMAPProvider.dedupRoles(_:)` runs at the end of `fetchFolders()` and demotes losers to `.custom`. Tiebreak: SPECIAL-USE flag first, then `canonicalNameRank` (the position in the canonical-name list — lower wins), then shorter name.
- `fullSync` deliberately does NOT update `role` on existing folders (it only refreshes `name`/`totalCount`/`uidNext`). This protects user manual reassignments — but it also means existing duplicate state needs a one-shot migration.
- Migration `v48_dedupFolderRoles` in `AppDatabase.swift` mirrors the same canonical-name preference (no SPECIAL-USE info on disk) and runs once to heal pre-fix accounts.
- UI: `AccountDetailView`'s "Folder Roles" section shows ALL folders for a role (joined) plus a `exclamationmark.triangle` warning icon when >1 — surfaces edge cases the migration didn't catch.
