
### Folder.== must include every UI-visible field
- `Folder` overrides `==` (Models/Folder.swift) to compare *visible* fields, because SwiftUI's ForEach diff uses Equatable to decide whether to re-render a row even after the underlying `@State`/`@Observable` array reassignment.
- If a UI-visible field is omitted, the row stays cached with stale data even though the DB write succeeded. This bit us on `role` (Settings → Account Detail folder/role rows didn't refresh after re-assignment or "No Role"). Tests: `FolderEqualityTests.differentRole`.
- Rule: when adding any field that the UI reads off `Folder`, add it to `==`. Sync-only fields (cursors, `lastKnownUidNext`) stay out.
