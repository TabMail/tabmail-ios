## AI Processing Rules

**MANDATORY: All AI processing (summary, action, reply) must exactly replicate the Thunderbird addon's architecture (ADR-IOS-008).**

- The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the **authoritative reference implementations**.
- Before implementing or modifying any AI flow, **read the TB reference code first** to ensure 1:1 parity.
- Key patterns that MUST be replicated: persistent processing queue, event-driven enqueue, drain loop with watchdog timer, per-message semaphores, global LLM concurrency limit, caching, first-compute-wins, three-call action voting.
- **Cache lifetime on iOS (ADR-IOS-114, a recorded exception to TB's TTL):** no TTL. An AI cache entry lives while an email of its own account (the key's account) carries its Message-ID, in any folder; with none, `SyncEngine.runPurgeOrphanedAICache` deletes it after `SyncConfig.aiCacheOrphanGraceDays` (7 days) untouched.
- Do NOT invent new AI processing patterns. Adapt TB's patterns to Swift/iOS idioms, but preserve the same architecture.

---
