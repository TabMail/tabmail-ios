
## Test Isolation for `UserDefaults`-Backed State

`UserDefaults.standard` is a process-wide singleton. Using it directly in tests creates cross-suite races — Swift Testing runs different `@Suite`s in parallel, and even `.serialized` only orders tests *within* one suite. The pattern adopted for `DisabledRemindersStore` + `ReminderBuilder.autoDisableOverdueOnFirstLaunch`:

- Production code reads from an overridable static: `DisabledRemindersStore.defaults` (falls back to `.standard`). A `Mutex<DefaultsRef?>` (with a `@unchecked Sendable` class wrapper around the thread-safe `UserDefaults`) holds the override so it's Swift 6-safe.
- `DisabledRemindersStore._setTestDefaults(_:)` swaps in a per-test `UserDefaults(suiteName: UUID().uuidString)`.
- Entry points that read *ambient* keys on their own (`firstLaunchDate`, `didAutoDisableOverdueReminders`) take `defaults: UserDefaults = .standard` as a default parameter so tests can pass the isolated instance through.
- Tests wrap the body in a `withIsolatedDefaults { defaults in ... }` helper that sets up, runs, and tears down (including `removePersistentDomain`) the per-test `UserDefaults`. This lets the suite drop `.serialized` entirely — tests run in parallel.

Apply this same pattern to any future `UserDefaults`-backed service before introducing tests for it.

---
