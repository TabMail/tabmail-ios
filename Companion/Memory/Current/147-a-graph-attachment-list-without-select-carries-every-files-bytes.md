# A Graph attachment list without `$select` carries every file's bytes

**Added 2026-11-09 (#434). Corrected 2026-11-11 after the first review and a live measurement.**

Microsoft Graph returns each `fileAttachment`'s bytes (`contentBytes`, base64) with the attachment
list unless the request has a `$select` that leaves them out, and `GET /messages/{id}?$expand=attachments`
embeds them the same way. Opening an Outlook message therefore downloaded every attachment it carried,
in the main app (`ExchangeProvider.readMessage` listed `/attachments` with no `$select`) and in the
notification service extension (`GraphAPI.messageFull` read the message with `$expand=attachments`,
which also put every file in the extension's small memory budget).

The same holds one level down: an attached email (`#microsoft.graph.itemAttachment`, what Outlook's
"Forward as attachment" produces) expanded with `$expand=microsoft.graph.itemattachment/item` comes
back with its own attachments, every file with its bytes, nested attached emails included
(learn.microsoft.com/graph/api/attachment-get, Example 4). An older code comment read Microsoft Q&A
1013332 as saying the expansion leaves them out; it says the opposite.

## Measured (2026-11-11, Graph Explorer, a consumer Outlook test mailbox, GETs only)

| Request | Result |
|---|---|
| `/attachments`, no `$select` | 200, 6.2 MB for 2 files, `contentBytes` present |
| `/attachments?$select=id,name,contentType,size,isInline` | 200, 1.1 KB, no `contentBytes`; `@odata.type` still returned |
| `/messages/{id}?$expand=attachments` | 200, 6.2 MB, `contentBytes` present |
| `/attachments?$select=id,name,contentId` | 400, "Could not find a property named 'contentId' on type 'microsoft.graph.attachment'" |
| `/attachments?$select=id,size,isInline,microsoft.graph.fileAttachment/contentId` | 200, `contentId` returned, no `contentBytes` |

Attached email, measured the same day on test drafts (nothing sent):

| Request | Result |
|---|---|
| POST an itemAttachment whose inner message carries a file | 201, but the inner file is dropped (`hasAttachments=false`); a draft cannot hold the nested-file case |
| `/attachments/{att}?$expand=microsoft.graph.itemattachment/item` | 200, the item (subject, body, hasAttachments); no `attachments` key when it has no files |
| the same with `item($select=id,subject)` | 400, "Could not find a property named 'subject' on type 'microsoft.graph.outlookItem'" |
| `/attachments/{att}/microsoft.graph.itemAttachment/item/attachments`, with or without `$select` | 400, "Resource not found for the segment 'attachments'" |

**Not measured:** whether an expanded attached email's files carry `contentBytes` (Example 4 says
they do), a type-cast `$select` inside the `$expand`, and a nested `$expand` of the item's
attachments with its own `$select`. See "Open" below.

## The rule

- List attachments with `GraphAPI.attachmentMetadataQuery` (`$select=id,name,contentType,size,isInline`),
  as Microsoft's large-attachments guide does (learn.microsoft.com/graph/outlook-large-attachments,
  Step 4). `ExchangeProvider.isFileAttachment` keeps working off `@odata.type`.
- `contentId` unqualified in that `$select` is a 400. The type-qualified
  `microsoft.graph.fileAttachment/contentId` works (measured above) but is not used: an inline image's
  content id comes with its bytes from the attachment's own GET (`/messages/{id}/attachments/{attId}`),
  one request per image.
- A `$select` nested inside `$expand` is not documented for Outlook attachments (Graph's
  query-parameter page: not every relationship supports it), so the extension reads the message and
  its attachment list in two requests. `GraphAPI.messageFull` makes 2 + k requests for k inline images
  fetched, one more per extra list page (it made 1).
- **Which inline images are fetched.** Both readers fetch the listed inline images (`isInline`,
  `image/*`) only when the HTML body has a `cid:` reference (case-insensitive), sequentially, until
  `BodyRenderer.maxInlineImages` are resolved. The gate is "the body has some `cid:`", not "this image
  is referenced": the list does not carry the content id, so an image is matched to a `cid:` only after
  its GET. So an unreferenced inline image is fetched too, and an image that does not resolve (no
  content id, failed GET) does not count toward the cap.
- **No image is lost in the main app.** An inline image is resolved inline only when its GET returns
  bytes and a content id. One whose GET fails or returns no bytes or no content id, and one not
  fetched (no `cid:` in the body, or past the cap), is listed as a file. Exception, #550: an inline
  image whose content id the body does not reference is fetched and then neither shown nor listed (the
  code before #434 did the same). In the extension every listed attachment, inline images included, is
  an attachment ref, and a failed inline GET leaves its `cid:` unresolved, so the main app reads the
  body again.
- **An attached email is still OPEN (#434).** `ExchangeProvider.fetchExpandedItemAttachment` expands
  it with the plain `$expand=microsoft.graph.itemattachment/item`, which by Example 4 brings every one
  of its files' bytes; they are decoded into `GraphExpandedMessageItem.attachments` and never read.
  Its own list, `.../microsoft.graph.itemattachment/item/attachments`, is a 400 on v1.0 (measured), so
  the caller's catch lists none of its files (#549). A fix must get the file metadata without
  expanding content that can carry bytes, and must be correct whether or not Graph sends nested
  bytes; every candidate request shape is unrun (see "Open").
- The message's own list (both readers) follows `@odata.nextLink` up to
  `GraphAPI.maxAttachmentListPages`, and only to a Graph page link (`GraphAPI.isGraphPageLink`: https,
  graph.microsoft.com, default port, no user info; shared by `ExchangeProvider.requestAbsolute` and the
  extension). A list that cannot be read fails the whole read, so the extension never stages a body
  without its attachment list.
- **Bytes still fetched on a read:** the inline images above, and, by design, a file-uploaded `.eml`
  read whole for its preview and the first `text/calendar` attachment, for the invite. Also, still
  open, an attached email's files (above). Nothing else is fetched until the user opens it.

## Open

Request shapes a fix for the attached email could use, none run yet (`{id}` the message, `{att}` the
attached email; `M` = `microsoft.graph.message`):

1. `GET /me/messages/{id}/attachments/{att}?$expand=microsoft.graph.itemattachment/item($select=M/subject,M/from,M/toRecipients,M/ccRecipients,M/receivedDateTime,M/body,M/hasAttachments)`
   — a type-cast `$select`; needs 200 with those properties and no `attachments`.
2. `GET /me/messages/{id}/attachments/{att}?$expand=microsoft.graph.itemattachment/item($select=<as 1>;$expand=M/attachments($select=id,name,contentType,size,isInline))`
   — needs 200 with `item.attachments` as metadata only (no `contentBytes`, `@odata.type` kept).
3. As 2 with `$expand=attachments(...)` (no cast) inside.

Whether nested files carry `contentBytes` needs a RECEIVED message with an attached email that
carries a file (a draft drops the file). Opening such a file uses
`.../attachments/{att}/microsoft.graph.itemattachment/item/attachments/{inner}`, which is likely the
same 400 as the list and is also unrun.

## Tests

`GraphAttachmentBytesTests` runs both readers against `GraphAttachmentServer`, a fake that serves
bytes the way Graph does (with the list unless `$select`, embedded on `$expand=attachments`, with an
attached email's expansion per Example 4, 400 for an unqualified `contentId`, for a `$select` of
message properties inside the expansion and for the attached email's own list; 501 for a shape it
does not model) and counts them at the HTTP boundary. It also covers an upper-case `CID:`, the cap in
both readers, an inline GET that fails or has no bytes, a tap download with no bytes, and
`GraphPageLinkTests` pins `isGraphPageLink` both ways. The attached email's two open defects are
`withKnownIssue` markers in `attachedEmailIsListedWithoutBytes`, which fail once fixed.
