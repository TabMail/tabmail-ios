
## ADR-IOS-010: Device Always-On Sync with AI Cache Probe

**Context:** Prompt settings (composition, action rules, knowledge base, templates) were manually synced between TB and iOS. AI processing (summary + action) ran independently on each device, duplicating LLM calls for the same emails. Backend KV cache was rejected per ADR-004 (zero server-side data retention).

**Decision:**
1. **Always-on Device Sync** — WebSocket connection to Cloudflare Durable Object relay. Auto-connects on launch, reconnects on foreground, disconnects on background. No manual send/receive buttons.
2. **Per-field timestamp merge** — Each field (composition, action, kb, templates) has its own `updated_at` timestamp. Incoming field applied only if timestamp > local. Prevents newer edits from being overwritten.
3. **AI cache probe before LLM** — Before running LLM for a message, probe connected peers for cached results via WebSocket relay. 2-second timeout. If hit, skip LLM entirely.
4. **RFC 2822 Message-ID as probe key** — Both iOS and TB use the RFC Message-ID header (angle brackets stripped) as the device-independent cache key. iOS stores this in `MessageHeader.rfc822MessageId`.
5. **Consecutive timeout optimization** — After 2 consecutive probe timeouts (no peer connected), skip future probes silently. Reset counter when any peer message is received.
6. **Backup before merge** — Current state saved to UserDefaults ring buffer (max 10) before applying incoming sync.

**Rationale:**
- Pure sync relay — no user data stored on server (ADR-004 compliance)
- DO with WebSocket Hibernation API costs ~$0.001/user/month
- AI cache probe saves $6-75/user/month in LLM costs
- RFC Message-ID is the only device-independent email identifier (UIDs, Gmail IDs are provider-specific)
- Consecutive timeout optimization avoids 2s latency per message when no peer is connected

**Consequences:**
- `rfc822MessageId` may be nil for some messages (IMAP servers with no ENVELOPE Message-ID) — probe gracefully skipped
- `rfc822MessageId` field on MessageHeader — existing messages get nil until re-synced
- WebSocket connection adds minor battery/network overhead — mitigated by hibernation (idle pings auto-responded without waking DO)
- Gmail metadata fetch now requests `Message-Id` header (one extra header per API call — negligible)

---
