
### Outgoing Threading — reply/forward stay in-thread on every provider (ADR-IOS-043, 2026-06-23)
- **Single source of truth: `ThreadUtils.outgoingThreadHeaders(...)`** builds the outgoing `inReplyTo` + full normalized/deduped `References` chain (`parent.references ++ parent.rfc822MessageId`) + Gmail `threadId`. Pure scalar core + a `MessageHeader` adapter; `ComposeView.send` is the ONE callsite (covers manual AND agent `email_reply`/`email_forward`, which open the same ComposeView).
- **Reply and forward share ONE path** (no `isForward` branch). Per Gmail convention (web-verified) a forward stays under the source conversation on the sender's side, so it gets the same threading headers as a reply. Forward-specific bits (empty To, `Fwd:` subject, quote) stay in ComposeView.
- **The bug this fixed:** `ComposeView.send` set only `inReplyTo` and never built `references` (empty `References` on every send), AND Gmail's REST `send` omitted `threadId`. Gmail's `users.messages.send` does NOT thread by headers alone — it needs `threadId` + RFC `References`/`In-Reply-To` + matching `Subject`. Result: Gmail web filed every iOS reply as a NEW conversation. (TB is unaffected — it sends Gmail via SMTP, header-threaded. Functional parity, not implementation parity.)
- **Gmail `threadId` is guarded twice** (in the builder): parent account == sending account, AND `normalizeSubject(sendSubject) == normalizeSubject(parentSubject)`. A failed guard → `nil` → a fresh thread (correct for cross-account / changed-subject). Preconditions, not a fallback (ADR-003).
- **Plumbing:** `threadId` added to `DraftMessage` + persisted on `OutboxMessage` (**v60** migration, so a post-relaunch drain re-sends with the same binding). `Draft` GRDB record UNCHANGED — derived from the resolved `replyTo` at send, like `inReplyTo` always was.
- **Provider responsibilities:** Gmail send includes `threadId` (`GmailProvider.buildSendBody`, extracted for tests). Exchange (`internetMessageHeaders`) + IMAP/SMTP (`buildEmail`) already emit In-Reply-To/References — NO code change, they just receive a populated chain now. `ExchangeProvider.buildGraphSendPayload` is `nonisolated` (pure, so unit tests can call it synchronously without crossing the actor boundary — `[String:Any]` is non-Sendable).
- Tests: `OutgoingThreadHeadersTests`, `GmailSendBodyTests`, `ExchangeSendPayloadTests`, `DatabaseOutboxTests` (v60 + round-trip), existing `IMAPProviderBuildEmailTests`. Plan: `PLAN_THREAD_FIX.md`.

## Outgoing threading IDs containing line breaks (#221)

`IMAPProvider.threadingMessageIDs` omits empty IDs and IDs containing any
`CharacterSet.newlines` scalar, then brackets the remaining IDs without changing
their order. IMAP send and draft construction, both Gmail raw serializers, and
Exchange's Graph payload use this boundary. IDs come from incoming mail: copying
a line break could add another header field, and SwiftMail's outbound checks
would refuse the IMAP send. The reply keeps its authored content and all safe
ancestors; an unsafe parent contributes no `In-Reply-To` field.

Gmail still folds the filtered IDs through `messageIDField`; filtering source IDs
must not remove the serializer's own CRLF-space folds. `ThreadingMessageIDLineBreakTests`
covers CRLF, CR, LF, VT, FF, NEL, line separator and paragraph separator on every
writer, mixed and wholly omitted reference lists, empty IDs and ordinary/bracketed
controls. `GmailThreadHeaderFoldingTests` pins long safe histories and parents.

This restores the app-side boundary parked from the Bcc train, adapting it to the
Gmail folding now on main; it does not change the SwiftMail pin or incoming parsing.
