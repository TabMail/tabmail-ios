
### Cross-Instance Action Tag Sync (ADR-IOS-036, supersedes ADR-IOS-004 "First Compute Wins")
- Action tags are **local-only** on iOS. No `tm_*` IMAP keyword, Gmail label, or Exchange category is written or read. `MessageHeader.actionTag` is driven by `MessageAICache.restoreIfCached` + AIService classification only.
- Cross-device parity on overlapping inboxes uses **Device Sync** (`DeviceSyncService.probeAICache`): iOS probes peers on cache miss before running the LLM. Peers that have the classification respond with `AICacheResult(summary, action, reply)`.
- Async cross-device pickup (device A offline when device B processes) is intentionally **not** covered — device B runs the LLM independently. Cost = one duplicate LLM call per miss. Accepted tradeoff.
- User manual overrides (long-press menu → pick action) go through `AccountManagerAI.setManualTag`: optimistic local `MessageHeader.actionTag` + `MessageAICache` write, plus a PendingOperation(.setTag) that drains to a no-op (legacy queue rows flush cleanly).
- Legacy `tm_*` keywords/labels/categories still present on user servers from prior versions are **not scrubbed** (too risky); they decay naturally as messages turn over. `UserLabelStore.shouldExcludeLabel` (matches `tm_` prefix) keeps them out of user-visible label chips.
