
### Swift 6 BGTask Isolation Pattern (ADR-IOS-020) — CRITICAL
- **BGTask expiration handlers run on arbitrary Apple threads** — NOT the main thread
- In Swift 6, ALL locals in `@MainActor` methods are main-actor-isolated — accessing them from `@Sendable` expiration closures causes `EXC_BREAKPOINT` at runtime, even for `Sendable` types like `Mutex<Bool>`
- **`nonisolated(unsafe)` on locals does NOT help** — only works on stored properties (SE-0412)
- **Required pattern for BGTask handlers in `@MainActor` classes:**
  1. Handler method must be `nonisolated func` (strips isolation from locals)
  2. Shared state via `BGTaskContext` class (`@unchecked Sendable` + `NSLock`)
  3. `@preconcurrency import BackgroundTasks` (ObjC types lack Sendable annotations)
  4. Set `task.expirationHandler` BEFORE creating `Task { @MainActor in }` (use-then-send ordering for SE-0414)
  5. Only the `Task { @MainActor in }` body calls `task.setTaskCompleted` — expiration handler only sets flag + cancels task
- **`CheckedContinuation` double-resume guard**: `NWPathMonitor.pathUpdateHandler` can fire multiple times racing with `cancel()`. Always guard with `Mutex<Bool>` before `continuation.resume()`
- **`requestBackgroundGracePeriod`**: expiration handler must not access `@MainActor` state — use a safety-timeout `Task { @MainActor in }` to call `endBackgroundTask` instead
