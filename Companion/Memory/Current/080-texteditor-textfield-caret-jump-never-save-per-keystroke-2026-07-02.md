
## TextEditor/TextField Caret Jump — Never Save Per Keystroke (2026-07-02)

- **A `TextEditor` (or `TextField`) bound via `Binding(get:set:)` whose setter writes to the DB or mutates `@Observable` store state (e.g. `navigationStore.accounts[idx] = account`) resets the caret to the end** — the mutation invalidates the view mid-edit while the editor is first responder. Same effect from notification-driven reloads (`reloadAccount()`/`reloadFolders()` on `.unreadCountsDidChange`/`.backgroundDataDidChange`) mutating `@State` while the user types. Symptom: first character inserts fine, then the cursor jumps to the end.
- **Pattern:** bind the editor to a plain local `@State` string; commit (diff-guarded DB write + store propagation) on focus loss (`@FocusState` + `onChange`), `.onDisappear`, and `scenePhase != .active` — never per keystroke. Reference: signature editor in `AccountDetailView.swift` (`commitSignature()`). Bonus: removes the synchronous main-thread `dbPool.write` per keystroke (which can stall behind the `DatabaseWriteQueue` sync backlog).
- The displayName/email/imapUsername `TextField`s in the same view still save per keystroke — single-line trailing-aligned fields where the jump hasn't been reported; migrate them to the same pattern if it ever is.

---
