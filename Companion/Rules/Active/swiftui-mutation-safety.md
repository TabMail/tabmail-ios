## SwiftUI Mutation Safety Rules

1. **NEVER remove items from an `@Observable` array synchronously during `onAppear`/`onDisappear`** when that array feeds the same `ForEach`. SwiftUI is mid-layout and will crash. Defer removals to the next run loop: `Task { @MainActor in ... }`.
2. **Appending is safe** from lifecycle callbacks — new items don't invalidate existing layout.
3. **User action handlers** (button, swipe, gesture) are safe for both append and remove.
4. **When evicting from paginated arrays**, keep evicted IDs in the dedup set to prevent re-fetch loops. Reset the set only on full reload.

---
