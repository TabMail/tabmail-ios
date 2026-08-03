
## ADR-IOS-002: User Activity Prioritization

**Context:** `IMAPProvider` is a Swift actor with a single IMAP connection per account. All operations (sync, body fetching, message opening) are serialized through the actor's queue. Background body fetching and backfill can block user-initiated `fetchMessage` calls for extended periods — the user taps a message and nothing happens until all background work finishes.

**Decision:**
1. **Cancellable background tasks** — Backfill tasks are stored and cancellable. When the user opens a message, background tasks for that account are cancelled immediately.
2. **Cooperative cancellation** — Background body fetch checks `Task.isCancelled` between each network call. On cancellation, it exits early, freeing the actor for user-initiated work.

**Rationale:**
- IMAP servers typically allow only one active command per connection
- Actor serialization means background work directly delays user actions
- Cancellation is cooperative in Swift — the loop must check and bail
- Users expect message opens to be instant; background work can wait

**Consequences:**
- Any new background work on the IMAP actor must follow the same cancellation pattern
- The cancel → action pattern applies to all user-initiated provider calls

---
