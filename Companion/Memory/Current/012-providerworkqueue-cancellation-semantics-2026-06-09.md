
### ProviderWorkQueue Cancellation Semantics (2026-06-09)
- The **throwing** `execute<T>` overload is cancellation-aware: a task cancelled while waiting for a slot throws `CancellationError` immediately — the waiter entry is removed, no slot is consumed, and `work` never runs. Before this, cancelled waiters (e.g. abandoned remote searches) queued up in tier 0 ahead of real user actions and still executed doomed network calls — the cause of the 2026-06 search-mode hang.
- The **non-throwing** (fire-and-forget) `execute` overload intentionally keeps the old behavior: always waits, always runs.
- **Overload-resolution gotcha:** a non-throwing `Void` closure resolves to the fire-and-forget overload even when written with `try await`. To get the cancellation-aware path, the closure must throw or return a value (tests force this with `let _: Int = try await queue.execute { ...; return 1 }`).
