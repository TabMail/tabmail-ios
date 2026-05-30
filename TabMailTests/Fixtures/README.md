# Provider Test Fixtures

> **Discipline:** every fixture file in this directory must cite the
> authoritative reference URL it was derived from (in a leading comment, or in
> this README for JSON files that don't allow comments). Fixtures encode our
> understanding of Gmail API / Microsoft Graph / RFC 3501 response shapes —
> if the shape is wrong, a mock-passing test can hide a prod-breaking bug.
>
> **Do NOT write a fixture from memory.** Before editing or adding a fixture,
> open the cited doc/RFC and verify.

---

## Gmail fixtures (`Gmail/`)

All Gmail fixtures model responses from the Gmail REST API v1.
Base URL: `https://gmail.googleapis.com/gmail/v1/`.

### Endpoint shapes

| Endpoint | Fixture | Reference |
|---|---|---|
| `GET /users/{userId}/messages/{id}?format=full` | `message-nested-eml.json`, `message-plain-text-eml.json`, `message-large-body.json` | [Method: users.messages.get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get) |
| `GET /users/{userId}/messages/{id}/attachments/{attId}` | `attachment-body.json` | [Method: users.messages.attachments.get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get) |

### Message schema invariants (verified 2026-04)

Source: [REST Resource: users.messages](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages) + [MessagePart Java SDK ref](https://developers.google.com/resources/api-libraries/documentation/gmail/v1/java/latest/com/google/api/services/gmail/model/MessagePart.html) + [MessagePartBody Java SDK ref](https://developers.google.com/resources/api-libraries/documentation/gmail/v1/java/latest/com/google/api/services/gmail/model/MessagePartBody.html).

- `payload: MessagePart` — the top-level MIME part.
- `MessagePart`: `{ partId, mimeType, filename, headers: [{name, value}], body: MessagePartBody, parts: [MessagePart] }`.
- `parts` only appears for container MIME types (`multipart/*`, `message/rfc822`); empty for leaf types like `text/plain`.
- `MessagePartBody`: `{ size, data?, attachmentId? }`. Exactly one of `data` / `attachmentId` is present for non-empty leaf bodies.
  - When `data` is set → body bytes are base64url-encoded (URL-safe alphabet, no padding in general).
  - When `attachmentId` is set → call `users.messages.attachments.get` separately; the `data` field on that response is ALSO base64url-encoded.
- `headers` on a `message/rfc822` part are the NESTED email's headers (From/To/Subject/Date/Cc). Case is server-dependent; our `GmailProvider.envelopeFromHeaders` is case-insensitive by contract.

### Attachment response schema (verified 2026-04)

Source: [Method: users.messages.attachments.get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get).

```json
{ "size": 12345, "data": "<base64url-encoded bytes>" }
```

---

## Exchange / Microsoft Graph fixtures (`Exchange/`)

All Exchange fixtures model responses from Microsoft Graph v1.0.
Base URL: `https://graph.microsoft.com/v1.0/`.

### Endpoint shapes

| Endpoint | Fixture | Reference |
|---|---|---|
| `GET /me/messages/{id}/attachments/{attId}?$expand=microsoft.graph.itemattachment/item` | `itemattachment-expanded.json` | [Get attachment](https://learn.microsoft.com/en-us/graph/api/attachment-get?view=graph-rest-1.0) |
| `GET /me/messages/{id}/attachments/{attId}/microsoft.graph.itemattachment/item/attachments` | `itemattachment-children.json` | [List attachments](https://learn.microsoft.com/en-us/graph/api/message-list-attachments?view=graph-rest-1.0) + [double-expand limitation Q&A](https://learn.microsoft.com/en-us/answers/questions/1013332/how-to-fetch-the-second-level-of-embedded-messages) |
| `GET /me/messages/{id}/attachments/{outerId}/microsoft.graph.itemattachment/item/attachments/{innerId}` | `itemattachment-child-download.json` | [Get attachment](https://learn.microsoft.com/en-us/graph/api/attachment-get?view=graph-rest-1.0) |

### Schema invariants (verified 2026-04)

Source: [itemAttachment resource](https://learn.microsoft.com/en-us/graph/api/resources/itemattachment?view=graph-rest-1.0), [fileAttachment resource](https://learn.microsoft.com/en-us/graph/api/resources/fileattachment?view=graph-rest-1.0), [attachment resource](https://learn.microsoft.com/en-us/graph/api/resources/attachment?view=graph-rest-1.0).

- Polymorphic discriminator: `@odata.type` is one of `#microsoft.graph.fileAttachment`, `#microsoft.graph.itemAttachment`, `#microsoft.graph.referenceAttachment`. **The `#` prefix is part of the literal value in responses.** Casing of the type name (e.g. `itemAttachment` vs `itemattachment`) is server-returned with the "Pascal" form (`#microsoft.graph.itemAttachment`), while URL path segments prefer lowercase (`microsoft.graph.itemattachment/item`). Our code lowercases the discriminator before comparison.
- `itemAttachment.item`: contains a nested message's envelope (subject, from, toRecipients, ccRecipients, receivedDateTime), `body: { contentType: "html" | "text", content: String }`, and `hasAttachments: Bool`.
- The nested item's `attachments` property is NOT reliably populated by the outer `$expand`. To list them, make a second call to `.../microsoft.graph.itemattachment/item/attachments` (see double-expand limitation Q&A).
- `fileAttachment.contentBytes`: standard base64 (with `=` padding, NOT base64url).
- Recipients (`from`, `toRecipients[]`, `ccRecipients[]`): `{ emailAddress: { name?: String, address?: String } }`.

### Known server quirks

- **[Exchange BODYSTRUCTURE violation](https://support.microsoft.com/en-us/topic/the-response-of-fetch-bodystructure-command-of-imap-violates-rfc-3501-in-exchange-server-2019-and-2016-ce22e3bc-996a-2f2b-96ba-4683ddd8f99d)** — applies to Exchange's IMAP endpoint (not Graph). Listed here because if a user ever configures IMAP-over-Exchange instead of Graph, the IMAP mock needs to model this quirk.

---

## IMAP fixtures (`IMAP/`)

All IMAP fixtures are wire-level response scripts (text). The fake server
reads an expected-command-prefix + canned-response pair file per test.

### Reference specs (verified 2026-04)

| Spec | Section | Use |
|---|---|---|
| [RFC 3501](https://www.rfc-editor.org/rfc/rfc3501) | §6.3.1 SELECT | fixture sets untagged OK responses (EXISTS, RECENT, UIDVALIDITY, UIDNEXT, FLAGS, PERMANENTFLAGS) |
| RFC 3501 | §6.4.5 FETCH | FETCH BODYSTRUCTURE, BODY.PEEK[], BODY.PEEK[HEADER], BODY.PEEK[N] |
| RFC 3501 | §7.4.2 FETCH response | BODYSTRUCTURE ABNF, BODY[section] response |
| RFC 3501 | §6.4.8 UID | UID FETCH, UID COPY, UID STORE — sequence-set argument holds UIDs instead of sequence numbers |
| RFC 3501 | §6.3.11 APPEND | fixture for OutboxMessage append → Sent folder |
| [RFC 6851](https://www.rfc-editor.org/rfc/rfc6851.html) | MOVE extension | UID MOVE preserves UIDs where possible; server returns untagged EXPUNGE for source msgs after copy |
| [RFC 9051](https://www.rfc-editor.org/rfc/rfc9051.xml) | IMAP4rev2 | where we rely on v2-specific capability (UTF8=ACCEPT, SEARCH RETURN, etc.), fixtures match v2 shape |

### BODYSTRUCTURE — `message/rfc822` part shape (critical for .eml tests)

Per RFC 3501 §7.4.2 (body-type-msg): `"MESSAGE" "RFC822" <body-fields> <envelope> <body> <body-fld-lines>`.

A `message/rfc822` BODYSTRUCTURE entry contains:

1. **media-message** — `"MESSAGE" "RFC822"` (literal).
2. **body-fields** — `body-fld-param body-fld-id body-fld-desc body-fld-enc body-fld-octets` (parameters list, Content-ID, Content-Description, transfer encoding, octet count).
3. **envelope** — the parsed RFC 2822 header structure of the encapsulated (nested) message: `(date subject from sender reply-to to cc bcc in-reply-to message-id)`.
4. **body** — the nested body structure of the encapsulated message (recursive).
5. **body-fld-lines** — number of text lines in the nested message body.

This nested envelope + body recursion is what our marker emission depends on: when a top-level BODYSTRUCTURE contains a `message/rfc822` part, SwiftMail parses through to the nested body so we can extract envelope + inner attachments without issuing a second FETCH.

### BODY.PEEK[<section>] vs BODY[<section>]

- `BODY.PEEK[...]` does NOT set the `\Seen` flag. All our fetches use PEEK.
- Section specifiers:
  - `BODY.PEEK[]` — full message.
  - `BODY.PEEK[HEADER]` — RFC 2822 headers only.
  - `BODY.PEEK[N]` — the Nth MIME part (1-based, dotted for nesting: `2`, `2.1`, `2.2`).
  - `BODY.PEEK[N.MIME]` — MIME headers of the Nth part.
  - `BODY.PEEK[N.TEXT]` — body text of the Nth part (no headers).

Our `IMAPProvider` uses section strings like `"2"`, `"2.1"` which map to
`AttachmentInfo.section`. The fake server script matches these verbatim.

### UID FETCH semantics

Per RFC 3501 §6.4.8: "a non-existent unique identifier is ignored without
any error message generated. Thus, it is possible for a UID FETCH command
to return an OK without any data." Our tests include a case for this
(UID remapped during backfill → FETCH returns just `OK`, no untagged FETCH).

---

## Update protocol

When Gmail/Graph change schemas, or a new RFC is relevant:

1. Update the "verified YYYY-MM" date next to the affected section.
2. Update any impacted fixture and cite the new URL / revised wording.
3. Add a regression test if the schema change is a breaking one.
