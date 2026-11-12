# A Graph attachment list without `$select` carries every file's bytes

**Added 2026-11-09 (#434). Corrected 2026-11-11 after the first review and live measurements; the
attached-email rule (files listed on open) added the same day.**

Microsoft Graph returns each `fileAttachment`'s bytes (`contentBytes`, base64) with the attachment
list unless the request has a `$select` that leaves them out, and `GET /messages/{id}?$expand=attachments`
embeds them the same way. Opening an Outlook message therefore downloaded every attachment it carried,
in the main app (`ExchangeProvider.readMessage` listed `/attachments` with no `$select`) and in the
notification service extension (`GraphAPI.messageFull` read the message with `$expand=attachments`,
which also put every file in the extension's small memory budget).

The same holds one level down: an attached email (`#microsoft.graph.itemAttachment`, what Outlook's
"Forward as attachment" produces) expanded with `$expand=microsoft.graph.itemattachment/item` comes
back with its own attachments, every file with its bytes (learn.microsoft.com/graph/api/attachment-get,
Example 4; measured below). An older code comment read Microsoft Q&A 1013332 as saying the expansion
leaves them out; it says the opposite.

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

Attached email carrying a file, measured on a draft created from MIME (`POST /messages` with a base64
MIME body keeps the inner file, where the JSON itemAttachment POST drops it):

| Request (`M` = `microsoft.graph.message`) | Result |
|---|---|
| `/attachments?$select=id,name,contentType,size,isInline` | 200, the itemAttachment (`message/rfc822`) only, no bytes |
| `/attachments/{att}?$expand=microsoft.graph.itemattachment/item` | 200, `item.attachments` lists the inner file WITH its full `contentBytes` |
| `...?$expand=microsoft.graph.itemattachment/item($select=M/subject,M/from,M/toRecipients,M/ccRecipients,M/receivedDateTime,M/body,M/hasAttachments)`, with or without `;$expand=M/attachments($select=id,name,contentType,size,isInline)` inside | 200: subject, from, toRecipients, body, `hasAttachments=true`; NO `item.attachments` and no bytes (the nested `$expand` is accepted and dropped). `receivedDateTime` was not returned for the draft's inner item |
| the same with an uncast nested `$expand=attachments(...)` | 400 |
| `/attachments/{att}/microsoft.graph.itemattachment/item/attachments/{inner}` | 400, "Resource not found for the segment 'attachments'" |
| `/attachments/{att}/microsoft.graph.itemAttachment/item/microsoft.graph.message/attachments/{inner}` | 400, "Resource not found for the segment 'Microsoft.OutlookServices.ItemAttachment'" |

So an attached email's files have exactly one route, the plain expansion, and it carries all their
bytes; there is no list of their metadata and no GET of one file by id. **Not measured:** whether
Graph ever pages an expanded `item.attachments` (`attachments@odata.nextLink`).

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
- **An attached email: envelope at read, files on open.** A read expands it with the cast `$select`
  (`ExchangeProvider.attachedEmailEnvelopeExpand`): envelope and body, no files, no bytes. They become
  the `tm-eml-section` marker in the stored body exactly as on IMAP and Gmail, so the preview sheet,
  search (FTS) and the AI see the attached email's text. A missing `receivedDateTime` leaves the
  marker without a date, as an IMAP or Gmail attached email with no Date header does. The chip carries
  `AttachmentInfo.filesListedOnOpen` when `hasAttachments` is true. Opening the attached email
  (`EmlAttachmentPreview`) calls the generic `EmailProvider.fetchAttachedEmailAttachments`, which on
  Outlook is the plain expansion (all the files' bytes, accepted on that gesture and not kept); a
  failure is shown in the sheet and opening it again retries; an expanded list that says it continues
  fails rather than shows part of it. Opening one of its files (`"<att>|<inner>"`) takes that file's
  bytes from the plain expansion again, downloading its siblings too, since no route by id exists.
  IMAP and Gmail never set the flag: their attached emails' files come with the message's MIME.
- The message's own list (both readers) follows `@odata.nextLink` up to
  `GraphAPI.maxAttachmentListPages`, and only to a Graph page link (`GraphAPI.isGraphPageLink`: https,
  graph.microsoft.com, default port, no user info; shared by `ExchangeProvider.requestAbsolute` and the
  extension). A list that cannot be read fails the whole read, so the extension never stages a body
  without its attachment list.
- **Bytes still fetched on a read:** the inline images above, and, by design, a file-uploaded `.eml`
  read whole for its preview and the first `text/calendar` attachment, for the invite. Nothing else is
  fetched until the user opens it.

## Limits

- Opening a file inside an attached email re-downloads all of that email's files (one plain expansion
  per tap); Graph has no route to one of them.
- A non-file attachment inside an attached email (a further attached email, a reference attachment)
  is listed but has no bytes in the expansion, so opening it fails with a plain error.
- A body the notification service extension staged has no attached-email marker (it never expanded
  item attachments); unchanged by this rule.

## Tests

`GraphAttachmentBytesTests` runs both readers against `GraphAttachmentServer`, a fake that serves
bytes the way Graph does and counts them at the HTTP boundary: with the list unless `$select`,
embedded on `$expand=attachments`, with an attached email's plain expansion; none for the cast
`$select` expansion, which drops a nested cast `$expand`; 400 for an unqualified `contentId`, an
uncast `$select` or nested `$expand` inside the expansion, and anything below an attachment (the
attached email's own list, one of its files by id, plain or cast); 501 for a shape it does not model.
It also covers an upper-case `CID:`, the cap in both readers, an inline GET that fails or has no
bytes, a tap download with no bytes, and, for an attached email: a read downloads none of its files'
bytes, no made-up date, one without files is not marked, opening it lists its files (not its inline
image or an unnamed file), a failed open is shown and a second open lists them, a continued list
fails, and opening one of its files returns its bytes. `AttachedEmailFilesListerTests` pins which chip
gets a lister (`AttachmentListView.filesLister`), and `BodyAddressGateTests` that the list is refused
mid-move. `GraphPageLinkTests`
pins `isGraphPageLink` both ways.
