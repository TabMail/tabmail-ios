## AI Processing Rules

**MANDATORY: All AI processing (summary, action, reply) must exactly replicate the Thunderbird addon's architecture (ADR-IOS-008).**

- The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the **authoritative reference implementations**.
- Before implementing or modifying any AI flow, **read the TB reference code first** to ensure 1:1 parity.
- Key patterns that MUST be replicated: persistent processing queue, event-driven enqueue, drain loop with watchdog timer, per-message semaphores, global LLM concurrency limit, caching with TTL, first-compute-wins, three-call action voting.
- Do NOT invent new AI processing patterns. Adapt TB's patterns to Swift/iOS idioms, but preserve the same architecture.

---
