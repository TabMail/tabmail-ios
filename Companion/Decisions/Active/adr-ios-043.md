
## ADR-IOS-043: Outgoing Thread Binding — One Header Builder, Gmail Carries `threadId`

**Context:** Replying from the iOS app on a Gmail account broke the thread on Gmail web — the reply started a new conversation and never appeared in the original thread. Two compounding defects: (1) the reply compose path set only `In-Reply-To` and never built the `References` chain, so every provider sent an empty `References` (`ComposeView.send` passed no `references:`); (2) Gmail's REST `users.messages.send` does not thread by headers alone — it requires the `threadId` field **plus** RFC-2822 `References`/`In-Reply-To` **plus** a matching `Subject` to file a sent message into an existing conversation — and iOS never plumbed the parent's `MessageHeader.threadId` into the send. (Thunderbird is unaffected: it sends Gmail over SMTP, where Gmail's ingestion threads by headers. Functional parity is the goal, not implementation parity — implementations may differ. Per ADR-IOS-008 spirit.)

Forward semantics were verified against Gmail (web research, 2026-06-23): Gmail keeps a forwarded message under the **original conversation in the sender's own mailbox** (the recipient, new to the thread, still sees a fresh conversation). So forward threads the same as reply; it is not a "new thread" case.

**Decision:**
1. **Single source of truth:** `ThreadUtils.outgoingThreadHeaders(...)` derives the outgoing `inReplyTo` + full normalized/deduped `References` chain (`parent.references ++ parent.rfc822MessageId`, RFC 5322 §3.6.4) + Gmail `threadId`. A pure scalar core (no `MessageHeader` needed) plus a `MessageHeader` adapter for the callsite — keeps it unit-testable.
2. **Reply and forward share ONE derivation path** (no `isForward` flag in the builder) — per Gmail convention a forward attaches to the source conversation. Forward-specific differences (empty `To`, `Fwd:` subject, quote block) stay in `ComposeView`.
3. **`threadId` is Gmail-only**, guarded by **two** preconditions: the parent's account == the sending account (the stored id belongs to the sending mailbox), and `normalizeSubject(sendSubject) == normalizeSubject(parent.subject)` (Gmail rejects a `threadId` attach on subject mismatch). A failed guard yields `nil` → a fresh thread, which is the correct outcome for a cross-account send or a deliberately changed subject. These are **preconditions, not a fallback** (consistent with ADR-003).
4. **Plumbing:** `threadId` is added to `DraftMessage` and persisted on `OutboxMessage` (migration **v60**, `threadId TEXT`) so an outbox drain after relaunch re-sends with the same binding. The `Draft` GRDB record is **not** changed — `ComposeView.send` derives the headers from the already-resolved `replyTo`, exactly as `inReplyTo` was derived before.
5. **Provider responsibilities:** Gmail send includes `threadId` in the request body (`GmailProvider.buildSendBody`, extracted for testability) when present. Exchange (`internetMessageHeaders`) and IMAP/SMTP (`buildEmail`) already emit `In-Reply-To`/`References` — they need **no code change**, only the now-populated `References` chain.
6. **One callsite** (`ComposeView.send`) covers manual AND agent reply/forward, because the agent `email_reply`/`email_forward` tools open the same `ComposeView` via `AgentToolRouter.ComposeRequest(mode:.reply/.forward, replyTo:)`.

**Rationale:** Centralizing the header derivation prevents the per-provider drift that caused the empty-`References` bug, and keeps the Gmail-specific `threadId` logic (with its account/subject guards) in one tested place. Persisting only `threadId` on the outbox row (not the `Draft`) is the minimal change that survives process death between queue and drain.

**Consequences:**
- A Gmail reply/forward now lands in the source conversation on Gmail web; IMAP/Exchange recipients thread on the full `References` chain.
- `threadId` is intentionally dropped when the user switches the From account or materially changes the subject → those start a new Gmail thread (correct).
- IMAP parents lacking a Message-ID produce a best-effort (possibly empty) chain — same as before, no regression.
- Local receive-side grouping (`ThreadUtils.assignComputedThreadId`) is untouched; this ADR governs **outgoing** headers only.
- Regression: `OutgoingThreadHeadersTests` (builder), `GmailSendBodyTests` (threadId in/out of send body), `ExchangeSendPayloadTests` (References emission), `DatabaseOutboxTests` (v60 column + round-trip), plus existing `IMAPProviderBuildEmailTests` (References). See `PLAN_THREAD_FIX.md`.

---
