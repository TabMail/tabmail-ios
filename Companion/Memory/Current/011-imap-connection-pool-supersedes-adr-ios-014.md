
### IMAP Connection Pool (supersedes ADR-IOS-014)
- `IMAPProvider` is a Swift `actor` with an `IMAPConnectionPool` (also an actor) managing multiple concurrent connections
- **Connection pool** (`IMAPConnectionPool.swift`) replaces the old serial lock AND temp connection infrastructure
- Operations checkout a connection via `withPoolConnection(priority:) { server in ... }` — each gets its own connection, SELECTs independently
- **Priority checkout**: user-initiated ops (move, markRead, fetchMessage) use `priority: true` — jump to front of waiter queue ahead of background ops
- **Adaptive concurrency**: detects server connection limits from `mail_max_userip_connections=N` rejections, adjusts automatically (cooldown on full rejection, gradual recovery)
- **Connection reuse**: idle connections persist in the pool across operations (no create/destroy per batch)
- **Liveness checks**: NOOP before reuse if idle > 2 minutes, dead connections discarded
- **Idle pruning**: connections unused > 5 minutes are closed (called during reconnect)
- **Batch checkout**: `pool.checkoutBatch(count:)` for parallel body fetch — replaces `createTempConnections`
- Gmail/Exchange HTTP providers unaffected — URLSession handles connection pooling natively
