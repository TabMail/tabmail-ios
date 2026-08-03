
## ADR-IOS-008: AI Processing Must Replicate TB Addon Architecture

**Context:** The iOS app needs background AI processing (summary, action classification, cached reply generation). Rather than designing a new architecture, we must exactly replicate the Thunderbird addon's proven architecture, adapted to Swift/iOS idioms.

**Decision:**
1. **Exact replication** — All AI processing flows (summary, action, reply) must match the TB addon's architecture 1:1. The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the authoritative reference implementations.
2. **Persistent processing queue** — Messages awaiting AI processing are stored in a persistent queue (GRDB model) that survives app suspension/termination. Restored on launch.
3. **Event-driven enqueue** — Messages are enqueued for processing on: new mail arrival (post-sync), message moved to inbox, and startup scan of recent untagged inbox messages.
4. **Drain loop with watchdog** — A periodic timer (watchdog) drains the queue in batches. Processing failures trigger a retry timer with backoff. The queue is persisted on app backgrounding.
5. **Per-message semaphores** — Prevent concurrent AI generation for the same message. If a summary is already being generated for message X, other requestors wait for the result.
6. **Global LLM concurrency limit** — A semaphore limits total concurrent backend API calls (prevent overload). Priority/user-initiated requests can bypass the semaphore.
7. **Caching with TTL** — AI results (summary, action) are cached in database fields with generation timestamps. Expired results can be recomputed. Cache is checked before any LLM call.
8. **First-compute-wins** — Before LLM action generation, check IMAP keywords / Gmail labels (per ADR-IOS-004). If found, adopt without LLM.
9. **Three-call action voting** — Action classification makes N parallel calls and takes the mode (most common action), matching TB's voting mechanism.

**Rationale:**
- TB's architecture is battle-tested in production with thousands of users
- Consistent behavior across platforms reduces user confusion
- Persistent queue ensures no messages are missed across app lifecycle events
- Concurrency control prevents backend overload and duplicate work
- Replicating rather than redesigning eliminates architectural risk

**Consequences:**
- iOS AI code must be kept in sync with TB addon changes (same flow, same edge cases)
- When modifying AI flows, always check the TB reference implementation first
- New AI features must be designed for both platforms simultaneously
- Slightly more complex than a naive implementation, but dramatically more reliable

---
