
## ADR-IOS-020: Swift 6 BGTask Handler Isolation Pattern

**Context:** `SyncScheduler` is a `@MainActor` class. `BGAppRefreshTask` and `BGProcessingTask` expiration handlers run on arbitrary Apple-internal threads. In Swift 6 strict concurrency, ALL local variables in a `@MainActor` method are main-actor-isolated — accessing them from `@Sendable` expiration handler closures triggers a dynamic isolation trap (`EXC_BREAKPOINT` at runtime), even for inherently thread-safe types like `Mutex<Bool>`. `nonisolated(unsafe)` on local variables does not prevent this (only works on stored properties per SE-0412). Additionally, `NWPathMonitor.pathUpdateHandler` can fire multiple times racing with `cancel()`, causing `CheckedContinuation` double-resume crashes.

**Decision:**
1. **`nonisolated func` on BGTask handler methods** — Strips actor isolation from ALL method locals, allowing them to be freely captured in `@Sendable` closures. The actual work runs inside `Task { @MainActor in }`.
2. **`BGTaskContext` class (`@unchecked Sendable`)** — Holds shared state (expired flag, processing task reference) between the expiration handler and the processing Task. Uses `NSLock` for internal synchronization. `@unchecked Sendable` lets it be captured across isolation domains without triggering region-based sending errors.
3. **`@preconcurrency import BackgroundTasks`** — Downgrades strict Sendable checking for `BGTask`/`BGProcessingTask` (ObjC types lacking proper annotations), preventing "sending risks causing data races" errors.
4. **Use-then-send ordering** — Set `task.expirationHandler` BEFORE creating the `Task { @MainActor in }` closure that captures `task`. This satisfies Swift 6's region-based "no use after send" rule (SE-0414).
5. **`Mutex<Bool>` guard in `isOnWiFi()`** — Prevents `CheckedContinuation` double-resume when `NWPathMonitor.pathUpdateHandler` fires multiple times racing with `cancel()`.
6. **Only `Task { @MainActor in }` body calls `setTaskCompleted`** — The expiration handler NEVER calls BGTask methods directly. It only sets the expired flag and cancels the processing task. The processing task checks the flag and calls `setTaskCompleted` itself.

**Rationale:**
- Swift 6 runtime isolation checking is stricter than compile-time checks — code that compiles can still crash at runtime
- `Mutex<Bool>` and `Task` are `Sendable`, but Swift 6 isolates them to the actor context of the enclosing method
- `nonisolated(unsafe)` only prevents compile-time errors on stored properties, not runtime isolation traps on locals
- `@unchecked Sendable` on a class with NSLock is the established pattern for cross-isolation shared state
- BGTask's ObjC types don't conform to `Sendable` — `@preconcurrency` is the approved workaround

**Consequences:**
- All BGTask handler methods must be `nonisolated func` — never `@MainActor`
- Shared state between expiration handler and processing task must go through `BGTaskContext` (or similar `@unchecked Sendable` class)
- Any new `CheckedContinuation` with callback-based APIs needs a `Mutex<Bool>` resume guard
- The pattern is more verbose but eliminates an entire class of runtime crashes

---
