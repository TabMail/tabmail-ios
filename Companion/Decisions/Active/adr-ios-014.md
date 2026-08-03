
## ADR-IOS-014: IMAP Connection Pool (supersedes serial lock)

**Context:** IMAP operations were serialized by a single lock on one TCP connection. This prevented concurrent operations (e.g., a user archiving a message while backfill fetches headers) even though IMAP servers support multiple concurrent connections (e.g., 15 for Gmail). Move/tag/mark operations blocked behind background work despite using priority lock.

**Decision:** Replaced the serial lock AND temporary connection infrastructure with `IMAPConnectionPool` — an actor managing a pool of logged-in IMAP connections. Operations checkout a connection via `withPoolConnection(priority:) { server in ... }`, SELECT their mailbox independently, and return the connection on completion. The pool handles:
- **Priority checkout**: user ops jump the waiter queue (preserves ADR-IOS-002 intent)
- **Adaptive concurrency**: detects server limits from `mail_max_userip_connections=N` rejections, cooldown on full failure, gradual recovery
- **Connection reuse**: idle connections persist across operations (no create/destroy per batch)
- **Liveness checks**: NOOP before reuse if idle > 2 minutes
- **Batch checkout**: `checkoutBatch(count:)` for parallel body fetch (replaces `createTempConnections`)

**Rationale:**
- IMAP servers allow multiple concurrent connections — serialization was unnecessary overhead
- Connection pool amortizes TCP+TLS+LOGIN cost across operations
- Pool unifies the two separate concurrency mechanisms (serial lock + temp connections) into one
- Actor isolation on the pool eliminates the race conditions that a class-based pool would have

**Consequences:**
- Multiple IMAP operations for an account can execute concurrently on separate connections
- Background tasks no longer block user actions (each gets its own connection)
- Body fetch connections return to pool for reuse instead of being destroyed after each batch
- Pool actor + IMAPProvider actor = two actor hops per operation (negligible overhead — pool methods are microsecond-fast)

---
