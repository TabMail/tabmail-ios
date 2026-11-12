<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Outlook threading goes as extended properties (#419, 2026-11-07).** Graph's `internetMessageHeaders` takes only custom `x-` headers, set at create; it refuses `In-Reply-To` and `References`. The "Exchange already emits In-Reply-To/References — NO code change" line below was wrong from v1.6.0. `ExchangeProvider.buildGraphSendPayload` now writes them as `singleValueExtendedProperties` `String 0x1042` (PidTagInReplyToId) and `String 0x1039` (PidTagInternetReferences), named by `ExchangeProvider.graphInReplyToProperty` / `graphReferencesProperty`; Exchange writes the headers from them on send (confirmed by a live reply, 2026-11-07). Only `sendMail` carries threading: Outlook drafts upload without it (`DraftStore.uploadThreadHeaders`). *(Since #422, 2026-11-07, a send with files also carries it: the draft create sets the properties, then `/messages/{id}/send`; draft saves still upload without it.)* Never put a standard header back in `internetMessageHeaders`: `ExchangeSendPayloadTests` fails on any name not starting with `x-`. Reading a received Outlook message's In-Reply-To/References still needs a separate `internetMessageHeaders` `$select` (GraphParse leaves them nil). Decision: ADR-IOS-043 amendment (#419).
> **Outlook sends carry the Outbox's Message-ID (#439, 2026-11-09).** The Outbox gives every message a `<UUID@domain>` Message-ID and keys the optimistic Sent row by it; sync replaces that row only with a Sent Items copy whose `internetMessageId` matches (`optimisticDedupSQL`). Graph answers a send with no id and, left alone, makes up its own, so the row stayed beside the real copy and a reply to it named an id no recipient had. `ExchangeProvider.buildGraphSendPayload(draft:sending:)` now sets the message's `internetMessageId` (Graph: "Updatable only if isDraft = true"; both send routes write a draft) to the draft's id in angle brackets, on both send routes: `sendMail`, and the draft create before `/messages/{id}/send` for a send with files. It does not use the MAPI property `String 0x1035` (PidTagInternetMessageId): Graph exposes the id as `internetMessageId`, extended properties are only for properties Graph does not expose, and no Graph page documents a client-set 0x1035. In-Reply-To and References stay `String 0x1042` / `String 0x1039`, because Graph exposes no property for them. Draft saves leave the id out (`sending`, which has no default, so every caller chooses): `DraftStore` gives every save a fresh `draft-<UUID>@domain` id, and MS-OXCMAIL says a Message-ID once set "SHOULD remain constant". **Live check still owed before #439 merges:** send once without and once with a file; compare the Sent Items copy's `internetMessageId` with the optimistic row's key byte for byte; read the Message-ID header the RECIPIENT received (MS-OXCMAIL lets the MIME writer generate a new one); reply from Sent before and after sync and confirm the reply threads at the recipient; if Graph rejects the id, confirm the message stays in the Outbox, reaches `.failed` after 3 attempts and offers Retry. Tests: `ExchangeSentMessageIdTests`, `ExchangeOutboxSentMessageIdTests`.
> **Current routing note (2026-11-07, #431): a second caller of the threading builder; Gmail reply drafts carry `threadId`.** The first bullet's "`ComposeView.send` is the ONE callsite" is stale. `DraftStore.uploadThreadHeaders` also calls `ThreadUtils.outgoingThreadHeaders`, for Gmail reply-draft uploads only (create and update): the References/In-Reply-To pair since #278, and `threadId` since #431, under Send's own conditions (the parent's account, a matching subject). A Gmail reply-draft upload (`drafts.create`/`drafts.update`) posts the same `GmailProvider.buildSendBody` resource Send uses, and `DraftStore`'s push path copies `threadId` from `DraftStore.uploadThreadHeaders`; before #431, drafts sat outside their conversation. Forwards and non-Gmail drafts write no thread headers. A reply draft saved in a different Gmail account than its parent names no thread, exactly as Send from that account would. Pinned by `GmailReplyDraftThreadTests`. See ADR-IOS-043's routing note.
>
> **Header folding on every raw-MIME path (#430, 2026-11-11).** No physical header line may pass 998
> octets (RFC 5322 §2.1.1), with two known exceptions below. Folding lives in one place,
> `IMAPProvider.foldedFieldBody` (CRLF plus
> a space before a token that would pass `IMAPProvider.headerLineSoftLimit`, 78 octets; a
> token is never split, so one token longer than 997 octets, which only a remote sender or the
> user can write, is written whole on a line of its own: the first exception. A recipient's token
> carries the comma that follows it, so for a recipient that is not last the bound is 996 octets). Gmail's `messageIDField` is `"name:"` plus that body of the `<id>`s. The IMAP/SMTP path
> hands SwiftMail `IMAPProvider.messageIDFieldValue`, the same body without its first space, because
> SwiftMail writes an additional header as `name: value` verbatim; when the first id itself folds, the
> value starts with the fold, and SwiftMail's send check unfolds CRLF-space, so it accepts it. One
> builder serves the send, the Sent APPEND (`appendToSentFolder`) and the IMAP draft
> (`buildDraftEmail`). `IMAPProvider.recipientsFieldBody(name, recipients)` folds Gmail's raw
> `To`/`Cc`/`Bcc` through the same `foldedFieldBody`, also after `"name:"`: a fold may come before any
> recipient, the first included, and a recipient is measured with the comma that follows it, so a
> first recipient that fills the line to 998 octets cannot push its comma to octet 999. The IMAP `To`/`Cc`/`Bcc` lines are written by
> SwiftMail (`Email.headerFields`) from `Email.recipients`, which folds them itself since the #447 repin
> (`AddressFormatter.foldedList`, memory 126); the app does not touch them. The second exception is a literal ASCII
> `Subject` of about 990 octets or more, which `RFC2047` and SwiftMail pass through on one line
> (tabmail-ios #465). Tests: `IMAPThreadHeaderFoldingTests` (sent copy as built for SMTP; kept-in-Sent
> and draft copies through the real APPEND to `FakeIMAPServer`, so SwiftMail's header check sees the
> folded values, including the fold-leading `In-Reply-To`; 15 ids of 80 octets, a legal-maximum parent
> id, a UTF-8 ancestor counted by octets, an id that fits 78 octets only on a line of its own,
> short headers unchanged, only folds in the values) and `GmailThreadHeaderFoldingTests` (also long,
> shrinking-length and short recipient lists, a first recipient filling 998 and 78 octets, a UTF-8 recipient counted by octets, and a draft with no
> recipients).
<!-- COMPANION-CURRENT-NOTE-END -->

### Outgoing Threading — reply/forward stay in-thread on every provider (ADR-IOS-043, 2026-06-23)
- **Single source of truth: `ThreadUtils.outgoingThreadHeaders(...)`** builds the outgoing `inReplyTo` + full normalized/deduped `References` chain (`parent.references ++ parent.rfc822MessageId`) + Gmail `threadId`. Pure scalar core + a `MessageHeader` adapter; `ComposeView.send` is the ONE callsite (covers manual AND agent `email_reply`/`email_forward`, which open the same ComposeView).
- **Reply and forward share ONE path** (no `isForward` branch). Per Gmail convention (web-verified) a forward stays under the source conversation on the sender's side, so it gets the same threading headers as a reply. Forward-specific bits (empty To, `Fwd:` subject, quote) stay in ComposeView.
- **The bug this fixed:** `ComposeView.send` set only `inReplyTo` and never built `references` (empty `References` on every send), AND Gmail's REST `send` omitted `threadId`. Gmail's `users.messages.send` does NOT thread by headers alone — it needs `threadId` + RFC `References`/`In-Reply-To` + matching `Subject`. Result: Gmail web filed every iOS reply as a NEW conversation. (TB is unaffected — it sends Gmail via SMTP, header-threaded. Functional parity, not implementation parity.)
- **Gmail `threadId` is guarded twice** (in the builder): parent account == sending account, AND `normalizeSubject(sendSubject) == normalizeSubject(parentSubject)`. A failed guard → `nil` → a fresh thread (correct for cross-account / changed-subject). Preconditions, not a fallback (ADR-003).
- **Plumbing:** `threadId` added to `DraftMessage` + persisted on `OutboxMessage` (**v60** migration, so a post-relaunch drain re-sends with the same binding). `Draft` GRDB record UNCHANGED — derived from the resolved `replyTo` at send, like `inReplyTo` always was.
- **Provider responsibilities:** Gmail send includes `threadId` (`GmailProvider.buildSendBody`, extracted for tests). Exchange (`internetMessageHeaders`) + IMAP/SMTP (`buildEmail`) already emit In-Reply-To/References — NO code change, they just receive a populated chain now. `ExchangeProvider.buildGraphSendPayload` is `nonisolated` (pure, so unit tests can call it synchronously without crossing the actor boundary — `[String:Any]` is non-Sendable).
- Tests: `OutgoingThreadHeadersTests`, `GmailSendBodyTests`, `ExchangeSendPayloadTests`, `DatabaseOutboxTests` (v60 + round-trip), existing `IMAPProviderBuildEmailTests`. Plan: the outgoing-thread fix (ADR-IOS-043).

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
