
### SwiftUI Observable Array Mutation Safety
- **NEVER remove items from an `@Observable` array synchronously during a lifecycle callback (`onAppear`/`onDisappear`) when that array feeds the same `ForEach`** — SwiftUI is mid-layout and will crash
- **Safe pattern for removals**: defer to the next run loop via `Task { @MainActor in ... }` — this lets the current layout pass complete before the mutation fires
- **Appending is generally safe** from lifecycle callbacks — new items don't invalidate existing layout
- **User action handlers** (button press, swipe action, gesture) are safe for both append and remove — SwiftUI processes these between layout passes
- When evicting from a paginated array, keep evicted IDs in the dedup set to prevent infinite re-fetch cycles — reset the set on full reload only
- Example safe eviction:
  ```swift
  // Called from onAppear flow — must defer
  private func scheduleEvictionIfNeeded() {
      guard loadedMessages.count > maxLoaded else { return }
      Task { @MainActor in  // Deferred — safe
          self.loadedMessages.removeFirst(trimCount)
      }
  }
  ```
