
## Test flakiness: `UserDefaults(suiteName:)` isolation FALLS THROUGH to `.standard` — isolating a suite's WRITES is necessary but not sufficient (2026-06-22)

**Symptom:** a test (`FirstLaunchOverdueTests`) **passes in isolation but is flaky in the full suite**. That signature = a parallel suite is contaminating *process-global* state.

**Root cause — the read-through trap:** a `UserDefaults(suiteName: uuid)` instance is NOT a sealed sandbox. Its read search list **falls through to the application (`.standard`) domain** for any key its own suite domain doesn't contain. So even though `FirstLaunchOverdueTests` wrote ONLY to its isolated suite (via `DisabledRemindersStore.withTestDefaults` / `@TaskLocal`), its *reads* of a key it didn't write (`disabled_reminders_v2`) fell through to `.standard`. `DisabledRemindersCRDTTests` ran in parallel and wrote `disabled_reminders_v2` straight to `.standard` (its `.serialized` only orders tests *within* that suite — it does NOT stop it running parallel to OTHER suites), so the victim read the polluter's value → `#expect(map.isEmpty)` etc. flaked. Writes on a suite instance go to the suite domain (isolated ✓); the leak is purely on the read side.

**Fix:** make EVERY test that touches the store write to an isolated suite — converted `DisabledRemindersCRDTTests` to the same per-test `UserDefaults(suiteName: uuid)` + `DisabledRemindersStore.withTestDefaults` pattern `FirstLaunchOverdueTests` already uses (and dropped its now-pointless `.serialized`). With no test writing `disabled_reminders_v2` to `.standard`, the victim's read-through returns nil and the flake is gone (verified: 3× full-suite runs, 7106 tests, both suites green every time).

**Rules of thumb:** (1) A test must NEVER write `UserDefaults.standard` — always an isolated `suiteName`. (2) `.serialized` only serializes *within* a suite; it gives ZERO protection against cross-suite parallel contamination of global state. (3) You cannot mask an ABSENT key via the suite domain (no way to make a suite read return nil when `.standard` has the key) — so "isolated reads" only hold if `.standard` is genuinely clean, i.e. if every writer is isolated. The `@TaskLocal` defaults override (`DisabledRemindersStore.withTestDefaults`) directs reads/writes to the suite instance, but it does NOT change that instance's fall-through to `.standard`.

---
