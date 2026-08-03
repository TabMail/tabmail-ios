
### Device Prompt Sync & AI Cache Probe
- `DeviceSyncService` — always-on WebSocket to Cloudflare DO relay (`sync-dev.tabmail.ai`)
- Auto-connect in `RootView.task`, reconnect in `.active`, disconnect in `.background`
- **Text fields (composition, action, kb)**: State-based delta merge with **peer-received base** as common ancestor. Steps: (1) epoch-zero → skip, (2) stale → skip, (3) first sync (no peer base) → LWW, (4) fast-forward (no local changes) → accept incoming, (5) both changed → 3-way bullet merge using `peer_base` as ancestor. **Critical**: `peer_base = incoming` (what peer sent), NOT merged result. Peer base stored in UserDefaults (`device_peer_base:*` / `device_peer_base_ts:*` keys). One-time migration from old `syncBase*` keys.
- **Templates**: per-template CRDT merge by id (newer `updatedAt` wins per template)
- **DisabledReminders**: per-hash CRDT merge (newer `ts` wins per hash)
- **Epoch-zero protection**: defaults and resets get epoch-zero timestamps — never overwrite customized content
- **Virgin device detection**: all timestamps epoch-zero → skip broadcast, probe peers instead
- `isSyncApplying` flag prevents echo loops when applying incoming sync
- 500ms debounce on outgoing broadcasts to prevent flooding during typing
- **AI cache probe**: before LLM, ask connected peers for cached results via `probeAICache(keys:)` (2s timeout, always probes)
- Probe key = RFC 2822 Message-ID header without angle brackets (device-independent, matches TB's `headerMessageId`)
- `rfc822MessageId` field on `MessageHeader` — populated from IMAP ENVELOPE or Gmail `Message-Id` header
- TB IDB keys: `summary:<accountId>:<folderPath>:<cleanHeaderMessageId>` — iOS probe handler searches by `rfc822MessageId.contains(key)`
- Date encoding: `.iso8601` for cross-platform template sync (TB sends ISO strings, not timestamps)
- Backend SSE: `BackendClient.extractSSEFinalData()` parses `event: final` from `text/event-stream` responses
