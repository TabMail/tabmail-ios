
## ADR-IOS-013: Direct Priority Path for Opened Emails

**Context:** TB addon processes the currently-displayed email via a direct inline path (`onMessagesDisplayed` → `getSummary()` → `getAction()`), bypassing the background queue entirely. This ensures the user sees AI results immediately when opening an email, without waiting behind other queued messages.

**Decision:** Added `processOpenedMessage()` public method to AccountManager. When the user opens a message in MessageDetailView and the body is already loaded, this direct path triggers AI processing immediately. It bypasses the background queue (matches TB's `processVisibleMessages` architecture). Per-message dedup in AIService prevents duplicate LLM calls if the queue also picks up the same message.

**Rationale:**
- ADR-IOS-008 requires exact replication of TB addon architecture
- TB uses dual-path: direct for displayed email, queue for background batch
- User should see AI results immediately when opening an email

**Consequences:**
- `processOpenedMessage()` runs outside the semaphore-gated queue
- AIService's first-compute-wins dedup prevents duplicate processing
- Body-fetch path (fetchBody → processMessage) still handles the case where body is fetched on open

---
