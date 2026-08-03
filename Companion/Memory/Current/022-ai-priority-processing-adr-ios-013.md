
### AI Priority Processing (ADR-IOS-013)
- **Dual-path architecture** (matching TB's `onMessagesDisplayed`):
  - Direct path: `processOpenedMessage()` — when user opens a message in MessageDetailView, AI runs immediately bypassing queue
  - Queue path: `processMessagesForAccount()` — background batch processing with semaphore (32 workers)
- Per-message dedup in AIService prevents duplicate LLM calls between paths
- `fetchBody` also triggers `processMessage` for inbox messages after body is fetched
