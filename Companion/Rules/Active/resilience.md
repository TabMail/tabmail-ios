## Resilience Rules

These are **mandatory** for all code in this project:

1. **NEVER block the main thread** — **CRITICAL.** GRDB's `DatabasePool` is thread-safe (concurrent readers, serialized writers), so no background `DispatchQueue` dance is needed. Heavy writes (backfill inserts, bulk updates) should use `dbPool.write { }` — the WAL journal mode keeps reads non-blocking. Avoid doing expensive computation inside write transactions on the main actor; offload to background Tasks where needed.
2. **Assume connections drop at any time** — State updates (e.g. history ID, sync cursors) must only be persisted upon verified completion. Never update state optimistically for backend/IMAP operations — a dropped connection with pre-written state causes stale entries that are hard to recover from.
3. **Assume every action can fail mid-operation** — The user can close the app, lose signal, or the process can be killed at any point. All operations must be idempotent. Implement state completion checks and self-healing: on next launch or sync, detect incomplete operations and either retry or clean up.
4. **Optimistic UI, hardened sync** — GUI actions must feel instant. Archiving, deleting, or moving messages should immediately animate away (swipe-to-zap, iOS-native animations) and update local GRDB state. The actual IMAP/provider sync happens asynchronously in the background, with the hardened retry/idempotency guarantees from rules 2 and 3.
5. **Use `Mutex` (from `import Synchronization`) instead of `nonisolated(unsafe)`** — When mutable state must be shared across isolation domains, protect it with `Mutex<T>` (SE-0433). NEVER use `nonisolated(unsafe)` to bypass the compiler — it hides data races. `NSLock` is also superseded by `Mutex` for new code. `@unchecked Sendable` is acceptable ONLY on the inner value type when the Mutex provides the synchronization, or on types wrapping inherently thread-safe APIs (e.g. CoreML's `MLModel`).

---
