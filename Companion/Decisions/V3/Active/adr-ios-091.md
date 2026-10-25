## ADR-IOS-091: Drafts Written by Other Mail Apps Are Adopted on Open

**Status:** Active (2026-10-17, GitHub #217)

**Context:** `e0d3d30e` (v1.7.0) bound every draft mutation to an exact provider-native address
and SUBTRACTED "unverified server-origin reopen": the pre-v1.7 open matched local rows by Message-ID
and subject, deleted the server copy at Send by Message-ID search, opened an empty editor when the
body fetch failed, and left the other app's copy behind as a duplicate on save. Removing it made
every draft started in Gmail web, Apple Mail or Outlook unopenable ("Draft unavailable"). Owner,
2026-10-17: take over the draft whichever client wrote it; if two apps edit it at the same time,
the last save wins — no lock, no warning, "simple is king".

**Decision:** When `ServerDraftComposeLoader` finds no local owner for a Drafts header, it adopts
the server copy (`ExternalDraftAdoption`): body and top-level attachments are fetched, then one
write transaction re-verifies the header and its exact address, refuses if any `Draft` row already
owns that address, and inserts an ordinary `Draft` row (`adopted:<uuid>`, status `"pushed"`)
carrying the address the existing save/send/delete paths use (IMAP folder + UIDVALIDITY + UID,
Gmail draft resource id, Graph id). The normal resolver then opens it. The reply parent comes from
`In-Reply-To` (exactly one header in the account, stamp-provable at reopen) or the draft is
unthreaded; adopted drafts get no TabMail quote.

**Rationale:** Adoption reuses the v1.7 machinery instead of re-opening its hazards: the row is
the same shape a locally authored draft has after its first push, so save replaces and Send deletes
exactly the adopted copy, and nothing ever selects a mutation target by Message-ID (ADR-IOS-068 D4).
The v2final Outlook open lease is not ported (owner ruling). An unproven IMAP epoch, a placeholder
id, a changed header, an unconfirmed-empty body or a failed attachment fetch still fail closed.

**Consequences:**
- Drafts from any client open and edit; the first save replaces the other app's copy.
- ~~Concurrent edits in two apps: last save wins. A later in-place edit elsewhere (Gmail/Graph keep
  their ids) is not shown on reopen — `IOS-DRAFT-020`, open for the owner.~~ Superseded by the
  amendment below (preserved as written).
- An evicted but pushed local draft is re-adopted from its server copy when reopened.
- Inline images in another app's HTML draft become plain-text body only (the compose is plain
  text); top-level attachments are carried.

**Amendment (2026-10-17, owner's second ruling, same PR):** *(Its revision witness and its open
rules are superseded by the two amendments below; preserved as written.)* *"It should definitely reload from the
server. It should not hold its local copy. … if it changed on the server, we should ask whether to
overwrite or reload or save as new … and then before saving, always check if the server copy has
updated. The brief gap time between our check and the save is an acceptable loophole …"*

- **Revision witness.** `Draft.serverDraftRevision` (migration `v92_addDraftServerRevision`) records
  the server revision the row's content is based on: IMAP UID (an edit elsewhere is a new APPEND),
  Gmail draft's contained message id (changes on every update), Graph `changeKey`. Written at push
  completion (`applyPushCompletion`), adoption and reload. `EmailProvider.draftRevision(identity:)`
  answers `.present` / `.gone`; a throw means "could not tell" and is never treated as either.
  A nil base (pre-v92 row) is no evidence and keeps last-save-wins.
- **Open:** a row with no unsent edits follows the server (changed ⇒ reload before the editor
  opens; gone ⇒ "Draft unavailable"). A row with unsent edits opens as is unless the server moved on
  from its base, then asks Overwrite / Reload / Save as new. Check failure ⇒ open as is.
- **Save:** checks first (`DraftServerCheckConfig.saveCheckTimeoutSeconds`); changed ⇒ the same
  question; gone ⇒ Save as new or Cancel; failure/offline ⇒ save locally.
- **Upload:** `pushDraftToServer` checks before the provider write. Changed ⇒ `.serverChanged`
  (never overwrites; edits stay `"dirty"`, asked on next open); gone ⇒ saved as a new draft; throw
  ⇒ retry. Send does not check (owner: "Send just sends").
- **Accepted:** the check-then-write gap and the first upload of a pre-v92 dirty row
  (`IOS-DRAFT-021`). Graph documents `changeKey` as changing on any item change, so a server-side
  property change (for example a category) can prompt or reload without a body edit; that errs
  toward asking, never toward overwriting.
- `IOS-DRAFT-020` resolved.

**Amendment (2026-10-17, owner's third ruling, same PR): compare text, not server revisions.**
*"Do not use server info, simply just compare the text. That's the simplest form of comparison if
draft has changed. We can save a local copy, and if the updated copy just doesn't match, that's the
sign of an update. Simple, and no exceptions required at all, or no server deviations required at
all for providers either."*

- `Draft.serverDraftText` (migration `v92_addDraftServerText`) replaces `serverDraftRevision`: the
  row's copy of the server text (`DraftServerText`), written at push completion, adoption and
  reload. `EmailProvider.fetchDraftCopy(identity:)` reads the server copy (`nil` = gone, throw =
  unknown); `DraftServerCheck.compare` decides unchanged / changed / gone. No provider revision
  field is read. Graph property-only changes (for example a category) no longer prompt.

**Amendment (2026-10-20, review round 1 of the PR):**

- **What is compared.** Subject (whitespace collapsed, "(no subject)" = empty), To, Cc and Bcc
  (addresses, lowercased, sorted), attachment file names (sorted; inline images under the name
  adoption gives them, `ExternalDraftAdoption.inlineImageFilename`) and the body through the same
  HTML-to-text conversion with each whitespace run collapsed to one space. Bcc and attachments were
  missing, and whitespace used to be deleted outright, so a remote Bcc, attachment or "now here" to
  "nowhere" edit read as unchanged and the upload replaced it. The upload records the text of the
  exact payload it sends (`DraftServerText.of(DraftMessage)`).
- **Open, on every route.** The check runs in the one step every saved-draft open shares,
  `ComposeView.loadDraftOrPrepopulate` → `ExternalDraftAdoption.refreshBeforeOpen` (Drafts list,
  compose toolbar, agent draft, reply/forward resume, undo reopen). Every row with a server address
  is checked. A row with no unsent edits whose copy changed is reloaded from that same fetched copy.
  A row with unsent edits whose copy changed asks Overwrite / Reload / Save as new before the editor
  shows (`ComposeView`'s `ServerChangedOnOpenAlert`; Cancel opens the edits with nothing written).
  This is the owner's 2026-10-17 answer: an upload that refuses a changed copy leaves the question
  for the next open, and Send does not check, so without it an opened-then-sent draft would delete
  the other app's newer copy unasked. (A first fix of this round asked only at Save; corrected the
  same day.) The separate open-time prompt in `ServerDraftComposeLoader` is deleted. A gone copy, a
  failed or slow read (`DraftServerCheckConfig.checkTimeoutSeconds`) or an unreadable body opens the
  row as is and never asks; Save and the upload check again.
- **One server read per adoption or reload.** Subject, recipients (Bcc included), body, attachments
  and inline images all come from one `fetchDraftCopy` result; the synced header is no longer the
  content source. Inline images are carried as ordinary attachments (the editor is plain text).
- **Older actions never undo newer ones.** Overwrite, Save as new and Reload-at-save (and the same
  answers at open) advance
  `pushAttemptVersion`, so an upload already past its server check retires at Stage A. A reload
  writes only over the exact row it compared (same generation, version, status and address).
- Images the provider's inline-image read drops (a failed image fetch, more than
  `BodyRenderer.maxInlineImages`) are a pre-existing reader behaviour, tracked separately rather
  than guarded here (#227).

**Amendment (2026-10-21, review round 2 of the PR):**

- **IMAP reads the copy under the selection it checked.** `IMAPProvider.fetchDraftCopy` proves the
  recorded UIDVALIDITY, then reads summary and content on that same selection
  (`fetchMessage(from:)`), never through `fetchMessageOnConnection`, which selected again without
  the proof and could return another draft at the same UID after the mailbox was recreated.
- **Demo drafts are never compared.** `DraftDeleteIdentity.isSharedWithOtherApps` is false for the
  demo address; the open, Save and upload checks skip such a draft (no other app edits it, and the
  demo copy holds only part of the draft, so a comparison would erase its Cc and Bcc).
  `DemoProvider.fetchDraftCopy` is deleted.
- **An empty body is a body.** A copy whose body part came back empty reloads as empty; only a copy
  with no body part and no attachments still fails closed.
- **Accepted limitations (owner 2026-10-21):** attachments compare by name only (#229), and
  recipient text that is no address is not compared, because IMAP servers rewrite it in the
  summary we read (#230). Both are recorded in `IOS-DRAFT-021`.

**Amendment (2026-10-21, owner's fourth ruling, after tier-1 review round 1): LAST SAVE WINS; the
change check is removed.** The second and third rulings' check (compare the server copy before
Save and before every upload; ask Overwrite / Reload / Save as new) is superseded; the text above
is preserved as written. Owner: *"the first version we have a last save wins strategy and [file an
issue] tracker that we might overwrite other drafts. Sort of a known defect which we put as low
priority because it's really just hypothetical."* (dictated; "file an issue" transcribed as
"file init") Filed as #233 (P4); `IOS-DRAFT-021` records it.

Why: the review round found four of its five code defects in the check itself. A text comparison
assumes the server stores exactly what was sent, and it does not: IMAP rewrites recipient text that
is no address, Graph's message PATCH does not update attachments, inline-image reads skipped
failures and capped the count, and this device's own in-flight upload read as another app's edit.
Every mismatch became a false "edited elsewhere", for a race the owner judges hypothetical.

- **Save and upload:** no read, no prompt. The upload replaces whatever the server holds.
  `pushDraftToServer` no longer returns `.serverChanged`; `Draft.serverDraftText`, migration
  `v92_addDraftServerText` (never released; a dev database that applied it keeps an unused column
  and an applied identifier GRDB ignores), `DraftServerText`, `DraftServerCheck`,
  `DraftDeleteIdentity.isSharedWithOtherApps`, the Overwrite / Reload / Save as new alerts and the
  rebase, detach and discard-for-reload writers are deleted. Send still does not check.
- **Open:** `ExternalDraftAdoption.refreshBeforeOpen` reloads a Gmail or Outlook row with no unsent
  edits (`"pushed"`) from its server copy on every open, with no comparison
  (`ExternalDraftAdoption.reloadsBeforeOpen`). The whole read, attachments included, is bounded by
  `ExternalDraftOpenConfig.reloadTimeoutSeconds`; attachment files are written only after the read
  returns, so a timed-out read leaves nothing behind. Offline, a timeout, a gone copy, a part that
  could not be read or a row that changed meanwhile (the `applyReload` CAS) opens the local row as
  it is. A row with unsent edits (`"dirty"`, `"pushing"`, never uploaded) opens as it is and its
  next upload wins. IMAP is not read at open: an IMAP message never changes in place, so another
  app's edit is a new UID, opened by adoption. Demo drafts are never read back.
- **A reload must never lose what the server holds**, because the next save uploads the reloaded
  row: a draft-copy read is COMPLETE or it throws. Gmail and Graph read every inline image (no
  `BodyRenderer.maxInlineImages` cap) and a failed image fetch throws (the draft-copy half of #227;
  rendering keeps its best effort). IMAP returns every inline image and the decoded bytes of every
  top-level attachment from the one read made under the proven UIDVALIDITY
  (`IMAPProvider.completeDraftCopy`, `FullMessageInfo.attachmentData`), so adoption never fetches
  an attachment again by UID without that proof; a part that came back without bytes throws.
- **A save makes the server copy equal the local draft.** Graph's message PATCH cannot change
  attachments, so `ExchangeProvider.saveDraft`'s update PATCHes without them and then replaces the
  set through `/messages/{id}/attachments` (list, DELETE each, POST each local file); a failure
  throws and the retried upload runs the replacement again from the start. Gmail and IMAP already
  replace the whole message.
- Moot with the check: #229 and #230 (closed as not planned, pointing to #233).

**Amendment (2026-10-21, owner's fifth ruling, after tier-1 review round 2): a draft is TEXT; read the
draft, not its render; sync Outlook attachments by name.** The round found that a save and reopen did
not give back what was typed: the upload sent HTML built from the text and the reload converted the
server's HTML back, and the two conversions did not agree on spacing and blank lines. It also found
attached-message text joining the body, unreferenced inline images dropped, and Graph attachments
deleted before the new set was added. Owner: *"we should make sure our converter doesn't cause
double spaces etc"*; *"minor cosmetics going away okay, as long as the spacing and the linebreaks
are preserved properly"*; *"upload as plain text, but also should be able to decode properly. Exact
round trip isn't required, but we SHOULD decode properly so that we don't add lines"*; *"we should
not re-invent yet another converter"*; and for attachments *"Match by name, accept the edge"*.

- **Upload as text.** `DraftStore.pushDraftToServer` uploads the row's body exactly as typed,
  `isHTML: false` (Gmail a text/plain message, Graph `contentType: "text"`, IMAP the text body). Sent
  mail is unchanged: the Outbox builds its own HTML.
- **Decode with the one converter.** `ExternalDraftAdoption.editableBody` takes the HTML part through
  `EmailFilter.htmlToPlainText` when there is one (another app's text part may be `format=flowed`
  soft-wrapped), else the text part with CRLF/CR made LF and MIME's trailing newlines removed (so a
  save and reopen never grows the body). `htmlToPlainText`'s line rules were fixed rather than a
  second converter written: `<br>` always ends a line; a block open or close ends one only when the
  line has text; a space before a break is dropped. So `<div><br></div>` is one blank line, nested
  closes do not stack, and a block after inline text starts a new line. FTS and the text part of
  HTML sends use the same function and gain the same fix. The provider placeholder subject
  `"(no subject)"` reads as empty.
- **Read the draft, not its render** (`EmailProvider.fetchDraftCopy`). The body is only the draft's
  own text/plain and text/html parts, joined in order when split around an inline part. An attached
  message (Graph item attachment, `.eml` file, `message/rfc822`) is an attachment and is never opened,
  so its text never joins the body. Every image with a Content-ID is an inline image whether or not
  the body references it; an image with no Content-ID and every other non-body part is a file.
  *(Amended in round 5, below: a part whose disposition makes it a file is a file first, Content-ID
  or not.)*
  Graph is asked for the body as text (`Prefer: outlook.body-content-type="text"`). A part whose
  bytes cannot be read throws. Gmail walks the payload iteratively (`readDraftMessage`); IMAP
  rebuilds the copy from the one proven read (`completeDraftCopy`); Graph uses
  `readMessage(id:forDraft:)`.
- **Outlook attachments sync by name, add before delete** (`replaceDraftAttachments`,
  `draftAttachmentPlan`). Local files pair with server attachments by name, one to one. Each unpaired
  local file is added first: one POST under `ExchangeDraftConfig.singlePostAttachmentLimitBytes`,
  else an upload session whose ranges are PUT in order to its Outlook-host URL with no
  `Authorization` header. Only then is each unpaired server attachment deleted. A failure throws
  before any delete, so the server never loses a file the draft still has, and an unchanged file is
  never sent again. Accepted edge: a different file under the same name keeps the old one
  (`IOS-DRAFT-022`, #236, P4). The attachment DELETE joins the irreversible-operation census as (7).
- Filed, not fixed here: the first save of a NEW Outlook draft with a 3 MB+ attachment still goes in
  one POST (pre-existing, #237).
- **A `format=flowed` text part is decoded when read** (#238, owner 2026-10-21: fix it here, at our
  SwiftMail fork, and upstream it). Thunderbird and Apple Mail write a plain-text draft as RFC 3676
  `format=flowed`, soft-breaking long lines with a trailing space. Gmail's `readDraftMessage` and
  IMAP's `completeDraftCopy` pass each text/plain part through `EmailFilter.decodeFormatFlowed` with
  that part's own Content-Type; it decodes only when the part declares `format=flowed` (joins soft
  breaks within a quote depth, removes space-stuffing, honours `delsp=yes`, keeps `"-- "` a line of
  its own), so a TabMail draft, which never declares it, keeps every trailing space. The soft-break
  rule is the one `plainTextToHTML` already rendered with, now shared as
  `EmailFilter.isFlowedSoftBreak`. IMAP needed SwiftMail to stop dropping the parameters: a
  BODYSTRUCTURE part's content type carried only `charset`, and now carries `format` and `delsp`
  too (fork branch `agent/format-flowed-content-type`, `a767603`, pinned by the app until upstream
  merges it; `.eml` parsing already kept them). Graph returns an Outlook draft as text Exchange
  converts, so it has no flowed part to decode.

### Review round 3 corrections (2026-10-21)

The tier-1 round 3 review found three ways content could be lost, and its fixes' own tests found a
fourth; each is fixed at its cause, except the first, which the owner accepted (below).

- **WITHDRAWN 2026-10-21 (owner: *"i think we should drop it"*; accepted as `IOS-DRAFT-024`; the
  migration was removed before release and its name is burned). After the upgrade, a pre-upgrade
  Gmail or Outlook draft with no unsent edits reloads the copy the earlier release uploaded on its
  first open. Drafts with unsent edits or never uploaded are left as they are.** *Preserved, as
  written before the ruling:* **Drafts uploaded by an earlier release open from this device until
  their next save.** Releases
  up to v1.9.2 uploaded the body as HTML (which reads back with quote markers, double spaces and
  soft line ends changed) and, on Outlook, never updated attachments after the first save, so for
  their `"pushed"` rows the server copy is not the draft and the open-time reload would replace the
  only exact copy. Migration `v93_openPreUpgradeServerDraftsLocally` (data only; v92 is burned) marks
  every Gmail and Outlook `"pushed"` row `"dirty"`: it opens as it is, nothing pushes it on its own
  (the only `.saveDraft` producers are the user's and the agent's saves), and its next save uploads
  it as text, after which every open reloads it. Cost: until that save, an edit made elsewhere to a
  pre-upgrade draft is not shown, which is the released behaviour.
- **A draft holding an attachment TabMail cannot carry is refused** (owner 2026-10-21: refuse and
  say why; #241 tracks carrying them). An Outlook item attachment (attached email, contact, event)
  or reference attachment (cloud link) has no bytes to read, and a file whose name
  `AttachmentFilename.isSafeFileComponent` refuses cannot be stored. The draft read throws
  `DraftCopyUnsupportedAttachment`; adoption shows a final "Draft unavailable" card with no Try
  Again, and the open-time reload returns `.unsupportedAttachment`, which opens the compose in its
  blocked error state, since a save of the local row would overwrite the server's version. Outlook's
  attachment sync pairs and deletes only file attachments with names the read accepts, so a save
  never deletes such an attachment (irreversible operation (7), memory 102).
- **Gmail draft text is decoded in its declared charset** by SwiftMail's `MessagePart.textContent`,
  the decoder the IMAP draft read already uses, instead of UTF-8 or nothing; text it cannot decode
  throws `GmailDraftCopyIncomplete`, never reads as an empty draft.
- **An IMAP draft part the server's FETCH response left out fails the read.** SwiftMail's full
  `fetchPart` returns EMPTY bytes, not an error, when the response carries no `BODY[n]`, so
  `IMAPProvider.completeDraftCopy`'s nil checks never fired: the text read as an empty draft and a
  file as an empty file, which the next save (irreversible operation (3)) would upload in place of
  the original. `IMAPProvider.draftPartArrived` treats a part BODYSTRUCTURE declares non-empty that
  came back empty as missing (`IMAPDraftCopyIncomplete`, retryable); a part declared empty, or of
  unknown size, still reads as empty.
- **Accepted (owner 2026-10-21): typed line breaks at the very end of a draft go on save and
  reopen** (`IOS-DRAFT-023`); the reload removes every trailing line break so the body never grows.

### Review round 4 corrections (2026-10-22)

The tier-1 round 4 review found one way content could be lost and one secret written to a log; each
is fixed at its cause.

- **A quoted charset is the declared charset.** Gmail serves a part's Content-Type as the writing
  app wrote it, and `charset="iso-2022-jp"` (Outlook quotes the value) is common. SwiftMail's
  `MessagePart.declaredCharset` matched only an unquoted, lower-case `charset=`, so such text fell
  back to UTF-8, then Windows-1252 and Latin-1: ISO-2022-JP kept its escape sequences as
  characters, Cyrillic and Shift_JIS came out as Latin mojibake, and the next save uploaded that
  over the other app's draft. Fixed in the SwiftMail fork (`946ae36` on
  `agent/format-flowed-content-type`, after `a767603`; the app pins `946ae36`): `declaredCharset`
  reads the parameter with SwiftMail's own MIME parameter reader (`EMLParser.extractHeaderParam`).
  It goes upstream with the #238 commit. **Correction to round 3:** "text it cannot decode throws
  `GmailDraftCopyIncomplete`" never happens for text, because Latin-1 decodes any bytes; the
  declared charset is therefore the only thing that makes the decode right, and a test whose
  fallback decode reads the same text as its declared charset (Latin text in ISO-8859-1) cannot
  tell the two apart.
- **A failed upload-session PUT no longer carries the session URL.** Graph's upload URL for a
  3 MiB+ attachment holds a pre-authenticated `authtoken`, and a `URLError` carries its failing URL
  in its userInfo, which the queue's failure log (`AccountOperationExecutor`, exportable) prints.
  `ExchangeProvider.addDraftAttachment` rethrows the PUT's `URLError` with only its code, which is
  all the retry classification reads.

### Review round 5 corrections (2026-10-22)

The tier-1 round 5 review found three ways another app's draft could lose content on its first
save; each is fixed at its cause.

- **The converter keeps blank lines, `<pre>` text and spacing as the page shows them.** TinyMCE,
  CKEditor and Word HTML (Outlook desktop and Outlook for Mac) write a blank line as a paragraph
  holding only a no-break space. A no-break space at the start of a line was never written, so the
  round 2 block rule ("end a line only when it has text") saw the paragraph as empty and every blank
  line went. `htmlToPlainText` now tracks whether the line holds anything visible, a no-break space
  included, and ends only such a line; this applies to every caller. A draft's text
  (`ExternalDraftAdoption.editableBody`) also passes `keepingSpacing: true`, which writes every
  no-break space as a space (Gmail web types a double space as `&nbsp; `, and indentation as no-break
  spaces), keeps whitespace inside `<pre>` as written (Thunderbird quotes a plain-text message in
  `<pre>` and writes a plain-text signature as one) after dropping the line break right after
  `<pre>`, and adds no space at an inline formatting tag (`un<b>believ</b>able`) or around a link.
  Other callers (FTS, AI, snippets, the text part of HTML sends) keep the collapsed form, so a
  newsletter's `&nbsp;` padding does not reach snippets. The named entity `&nbsp;` now decodes to
  U+00A0, not a plain space, so it takes the same no-break-space rule as a raw U+00A0 (the collapsed
  form is unchanged). Still one converter, as the owner ruled.
- **Gmail classifies a draft part by its disposition first, as IMAP does.** Gmail web gives every
  attachment it composes a Content-ID (`<f_…>`) and an `X-Attachment-Id`, and the reader took any
  image with a Content-ID as inline, so an attached photo was renamed `image1.jpeg` on the first
  save and in the sent mail. `GmailProvider.readDraftMessage` now takes a part with
  `Content-Disposition: attachment`, or a file name and no `inline` disposition, as a file under its
  own name (a text part attached as a file no longer joins the body); only then is an image with a
  Content-ID inline. This amends "every image with a Content-ID is an inline image" above.
- **Gmail carries a file whose bytes came in the part.** When a part has no `attachmentId`, Gmail
  returns its whole content in `body.data`. The reader dropped such a leaf with no file name (an
  unnamed `text/calendar` invite, a PGP/MIME control part) and threw for a named one. It now carries
  the bytes in `FullMessageInfo.attachmentData` under a key of its own, and
  `ExternalDraftAdoption.read` takes carried bytes for each file and fetches only the rest; an IMAP
  file whose bytes are missing still throws, since it is never fetched again by UID alone. A leaf
  Gmail reports as empty holds nothing and is skipped.

### Review round 6 corrections (2026-10-22)

The tier-1 round 6 review found two defects; each is fixed at its cause.

- **A Gmail file that is a container with no bytes of its own is refused.** Gmail may list an
  attached message (or a multipart marked `attachment`) by its child parts, with `body.size` 0, no
  `data` and no `attachmentId`. The round 5 rule "declared size 0 is empty" read such a part as a
  0-byte file; a reload then replaced the real local file and the next save uploaded the empty one.
  `GmailProvider.draftPartBytes` now throws `DraftCopyUnsupportedAttachment` for a part with children
  and neither bytes nor an attachment id, the refusal Outlook item attachments already take (#241):
  the open is refused, nothing is written. Only an empty LEAF reads as empty.
- **An adopted reply finds its original again after the original moves.** The adopted key was
  `adopted:<uuid>`, so `Draft.resolveReplyToHeader`'s Strategy 2 never ran for it, and once an IMAP
  move re-keyed the original (new UID, new primary key) its Send was blocked for good, while a reply
  written in TabMail re-resolves through the `{accountId}:{stableId}` tail of its `reply:` key
  (memory 023). An adopted reply whose parent was claimed now has the key
  `adopted:<uuid>:{accountId}:{stableId}` (`ExternalDraftAdoption.adoptedKey`), and
  `Draft.replyKeyTail` gives Strategy 2 and `expectedReplyToRfc` the same tail from either key form.
  An unthreaded adopted row keeps `adopted:<uuid>`; Strategy 2 keeps its exactly-one rule, so two
  copies still refuse (`IOS-DRAFT-009`). No column, no migration; adoption is unreleased, so no
  shipped row has the old form.

### Review round 7 correction (2026-10-22)

- **Adoption never outranks a draft saved here in the eviction cap.** `DraftStore.applyAdoption`
  gave each adopted row `lastTouchedSeq = MAX + 1`, so opening drafts written elsewhere pushed drafts
  typed on this device past `SyncConfig.maxComposeDraftSessions` (10), and the next maintenance pass
  deleted the oldest even when its text had never reached the server (a dropped user intention).
  Adopted rows are now inserted at rank 0, below every saved row; ties break on `updatedAt`; the
  first save ranks the row like any other. An evicted adopted row is a server copy the next open
  adopts again. IOS-DRAFT-012's "no server→local ingest path" premise is amended accordingly.

### Codex review round 1 corrections (2026-10-22)

The owner flipped the review tiers for token supply (Codex first, then one Opus round). Codex
round 1 on `4e37ee02` found:

- **An Outlook attachment list read as one page.** Graph pages a collection with
  `@odata.nextLink`; `ExchangeProvider.readMessage` and `replaceDraftAttachments` read only the
  first page, so a reload kept only that page's files and the next save deleted the rest from the
  server (irreversible operation 7). `ExchangeProvider.listAttachments` now follows the next link
  through the existing origin-checked `requestAbsolute`, bounded by
  `ExchangeDraftConfig.maxAttachmentListPages`; past the bound it throws
  `GraphAttachmentListIncomplete`, so neither a read nor a save ever acts on part of the list.
- **A whitespace-only body opened empty.** `ExternalDraftAdoption.editableBody` returned `""` for
  a body the server returned that held only spaces, tabs or line breaks; it now returns that text
  as written. An unconfirmed empty body is still refused.
- **The flowed-parameter reader split on `;` and `=`.** `EmailFilter.decodeFormatFlowed` read
  `format=flowed` inside another parameter's quoted value, and kept a trailing comment in the
  value. It now reads `format` and `delsp` with SwiftMail's MIME parameter reader through the new
  public `MessagePart.contentTypeParameter(named:)`.
- **SwiftMail wrote BODYSTRUCTURE parameter values bare.** A quoted value holding `;` split into a
  second parameter when read back (a `format` value could declare a charset the part never had).
  Fork commit `c86900c` (after `946ae36`) writes a value that is not an RFC 2045 token as a
  quoted-string; the app pins `c86900c`. It goes upstream with the #238 commits.
- **HTML spacing that CSS keeps visible** (`white-space: pre-wrap` text, which TabMail's own
  earlier HTML draft uploads used, and no-break spaces in a link label) is collapsed by
  `htmlToPlainText(keepingSpacing:)`. Moved to #251, the immediate follow-up in this release
  train, whose WebKit rendering replaces that conversion for drafts and honours both.

### Codex review round 2 corrections (2026-10-22)

Codex round 2 on `f609479` found:

- **Gmail sends empty `data` for bytes it stores apart.** `GmailProvider.draftPartBytes` returned
  the empty inline `data` before looking at the part's `attachmentId`, so a body or inline image
  stored apart read as empty or zero bytes, and a reload committed it. A failed image fetch was
  never even attempted, so the reload replaced the local copy and deleted its old attachment
  directory. Only non-empty `data` is now the part's bytes; otherwise the `attachmentId` is
  fetched, a container with children is refused (`DraftCopyUnsupportedAttachment`), and only an
  empty leaf reads as empty.
- **A typed subject of "(no subject)" was erased on reopen.** The header parsers put
  "(no subject)" in place of an empty subject for lists, and `ExternalDraftAdoption.read` mapped
  that value back to empty, so the user's identical literal was lost. The comparison
  (`providerNoSubjectPlaceholder`) is deleted; the draft-copy reads pass `keepEmptySubject`
  (`parseGmailMessage`, `parseGraphMessage`, `mapMessageInfo`), so a draft's empty subject stays
  empty and a literal one stays literal.
- **A charset the platform cannot resolve became a guessed draft.** `MessagePart.textContent` is
  the viewing decoder: past the declared charset it falls back to Windows-1252 and Latin-1, which
  accept any bytes. GBK text labelled `chinese` or `x-gbk` (labels iOS does not resolve, #257)
  read as Latin mojibake and became the editable copy. Draft reads now use
  `MessagePart.draftTextContent`: the declared charset decodes the bytes, or they are UTF-8, or the
  read fails and the local copy stays. A part declaring no charset reads as before.
- **Graph upload progress was taken as completion.** `addDraftAttachment` accepted 200 or 201 on
  the last range; Graph answers 201 when the attachment exists and 200 with `nextExpectedRanges`
  while the upload is incomplete. A 200 there let `replaceDraftAttachments` delete the old file
  with no replacement (irreversible operation 7). The last range now requires 201.
- **Coverage:** recipient entries that are not addresses, in To, Cc and Bcc, on adoption and on
  reload; a failed Outlook add keeps the old server file (add before delete); SwiftMail fork
  commit `9ceb96b` tests that quoted parameter values read back as written (app pin `9ceb96b`).
- **HTML conversion** (comments splitting a word, the `<pre>` boundary, U+200C/U+200D removed):
  moved to #251. **#251 changed since round 1** (owner 2026-10-22): no WebKit; a SwiftSoup DOM
  walk replaces `EmailFilter.htmlToPlainText` for every caller, with a small built-in CSS reader
  (inline styles plus simple `<style>` rules for display, white-space and vertical margins).
  **Superseded 2026-10-24 (option B):** the DOM walk was rejected on NSE memory; #251 fixes the
  streaming byte scanner instead (`HTMLText`), with the same CSS reader. Design:
  `Companion/Memory/Current/125-html-links-in-converted-text.md`.

### Codex review round 3 corrections (2026-10-23)

Codex round 3 on `8110694` found:

- **An IMAP draft file took the summary's name.** SwiftMail's full fetch restores a filename from
  the part's own MIME header when the BODYSTRUCTURE summary lost characters (`docs\notes.txt`
  read as `docsnotes.txt`), but `IMAPProvider.completeDraftCopy` kept the summary's name, and
  adoption stored the altered name. A strict-copy file now takes the fetched part's filename.
- **A Gmail draft replaced between listing and read mixed two versions.** The read returned the
  new contained message's text and recipients, while adoption claimed the reply parent from the
  listed (old) header, and a reload kept the row's old parent. Adoption now refuses when the copy
  is not the listed contained message (the next open re-lists). A reload whose copy names a known
  `In-Reply-To` different from the row's parent deletes the clean row and its files
  (`ExternalDraftAdoption.repliesElsewhere`, `ReloadWrite.removed`), and compose reports
  `OpenCheck.replacedElsewhere` ("This draft changed while it was opening"), so the next open
  adopts the copy with its own parent. A forward, or a parent either side cannot name, is not
  compared.
- **A failed declared charset still guessed UTF-8.** The same bytes mean different text
  (`C2 A9` is GBK 漏 and UTF-8 ©), so `MessagePart.draftTextContent` now decodes in the declared
  charset or returns nil; UTF-8 is never tried. A charset iOS does not resolve refuses the read
  and keeps the local copy (aliases remain #257).
- **The format=flowed quote prefix was read as graphemes.** A quoted line whose content starts
  with a combining mark made `>` and the mark one Character, so the depth and the stuffing space
  were wrong. `EmailFilter.decodeFormatFlowed` reads quote indicators and stuffing as Unicode
  scalars (RFC 3676 ASCII syntax).
- **An Outlook inline image under an unstorable name multiplied on every save.** The draft read
  converted Graph inline images to `InlineImage` (stored as generated `imageN` files), bypassing
  the #241 name refusal, so a by-name save never paired the original and added another copy.
  Resolved by deletion: a Graph draft read carries EVERY attachment, inline images included, as
  a file under its own name through the ordinary file path, so the name is checked and the next
  save pairs it. Viewing is unchanged.
- **Coverage:** ordered complete body pieces and every inline image's bytes past the viewer cap
  (Gmail, IMAP, Outlook); a database failure after staging leaves the old row and files and no
  staged directory, on adoption and on reload; flowed markers as ASCII; the fork commit
  `3a0cdf7` checks that each emitted BODYSTRUCTURE parameter value is a MIME token or
  quoted-string (app pin `3a0cdf7`).

### Codex review round 4 corrections (2026-10-23)

Codex round 4 on `c074753` found:

- **A reply whose parent moved escaped the replacement check.** `repliesElsewhere` looked the
  row's parent up by its raw primary key, which an archive (a new folder, a new key) removes,
  and read the miss as "no contradiction". The reload then kept the old parent's claim (Send
  still found the parent through the reply key) under another reply's text. The row's parent is
  now resolved as Send resolves it (`Draft.resolveReplyToHeader`), and a parent the row claims but
  that no local row corroborates is NOT taken as agreement: the clean row is removed and the next
  open adopts the copy with its own parent. Re-adoption of a copy whose parent the device lacks
  claims no parent, so the check does not repeat.
- **Coverage:** the single-POST limit for an Outlook attachment is exclusive (a file of exactly
  `singlePostAttachmentLimitBytes` goes through an upload session; one byte less in one POST),
  pinned at the boundary with the exact bytes the server receives.
- **Filed, owner 2026-10-23:** a `multipart/alternative` body of two `text/plain` alternatives
  reads with its text doubled (#272, P4, a unit of this train; IMAP needs SwiftMail to expose the
  multipart grouping); the partial-staging-write cleanup in `ExternalDraftAdoption.stage` has no
  test, because no test can force a mid-write failure without a production hook (#273, P5).
  The owner stopped further review rounds at round 9 since the fifth ruling to rethink the design.

### Codex review round 5 corrections (2026-10-23)

Codex round 5 on `358fc05` found:

- **Eviction could delete an unsent adopted reply.** `DraftStore.evictImpl` kept a reply whose
  parent is in Inbox, but parsed only `reply:`/`forward:` keys, so after the parent moved out of
  Inbox and back (a new key) an edited adopted reply lost its exemption. Eviction now reads the
  parent from the key as Send does (`Draft.replyKeyParent`).
- **A parent whose Message-ID starts with a combining mark could not be followed.** The key tail
  `{accountId}:{stableId}` was split at the first `:` as Characters, and a combining mark after
  the `:` joins it into one Character. `Draft.replyKeyParent` splits it as Unicode scalars; the
  resolver, `expectedReplyToRfc` and eviction use it.
- **Flowed soft breaks after a Prepend scalar.** `isFlowedSoftBreak` and the `delsp=yes` removal
  read the final space as a scalar.
- **A part that arrives shorter than declared is incomplete.** IMAP compares the fetched bytes with
  the BODYSTRUCTURE size (encoded octets) and Gmail compares the decoded bytes with `body.size`;
  fewer bytes refuse the copy. A part of unknown size is taken as read. Gmail test fixtures now
  declare their real sizes.
- **Filed, big (a SwiftMail change or a migration), in the train after #217:** a plain-text body
  with a Content-ID reads as a file (#276) and RFC 2231 extended charset/format parameters are
  ignored (#277), both with #272 as one SwiftMail reader unit; a Gmail reply replaced by a
  standalone message keeps its old parent (#278, needs a record of whether the server copy names
  a parent).

### Codex review round 6 corrections (2026-10-23)

Codex round 6 on `290031d` found:

- **A flowed line could become a false signature separator.** With `delsp=yes`, the line
  `"--  "` (a text space and the soft-break marker) became `"-- "` once the marker was dropped,
  and was then taken for the signature separator, splitting the paragraph. The separator is now
  recognised on the line as written, before the marker is dropped.
- **A Gmail part fetched apart was not checked for completeness.** `draftPartBytes` checked inline
  bytes against `body.size` but not bytes fetched through the attachments API, and a Gmail file
  with an attachment id was fetched later by the generic attachment path, unchecked. A Gmail draft
  read now reads every file whole with the draft, through `draftPartBytes`, and checks every
  part's decoded bytes against `body.size` by either route; a short part keeps the local copy.

### Codex review round 7 corrections (2026-10-23)

Codex round 7 on `497150d` found:

- **Independent plain and HTML body pieces lose one.** A `multipart/mixed` draft with a
  `text/plain` part and a separate `text/html` part reads both, and `editableBody` then keeps
  only the HTML. It is the mirror of #272 (two plain alternatives doubled) and has the same
  cause: the draft read does not know which multipart group a part belongs to. The fix selects
  within an alternative and keeps every mixed piece in order; IMAP needs SwiftMail to expose
  the grouping, so it is a dependency change and moves to #272 (SwiftMail reader unit, next in
  the train), with its tests.
- **The attachment-refusal card's Close was untested.** `ServerDraftCloseUITests` now opens a
  draft refused for its attachment (#241) from the Drafts list, a push and a detail, and checks
  the refusal text, no Retry, Close back to the mailbox twice, and unchanged rows.

### Multipart grouping, Gmail half (#272, 2026-10-23)

A draft read now returns one body as the MIME tree groups it. Within a `multipart/alternative`
it reads one representation, the last child that holds body text (RFC 2046 section 5.1.4:
alternatives are versions of one body, the last the richest); the text of the other children
is not read, though their images and files still are. The text/plain and text/html pieces of
every other multipart (mixed, related, ...) are one body, in order. `DraftBodyPiece.body` builds
the copy's body fields from the ordered pieces: a body all of one kind keeps it (its HTML is
converted once, by `editableBody`, as before); a body of both kinds is converted piece by piece
with the same `EmailFilter.htmlToPlainText(keepingSpacing: true)` and returned as text, so
neither kind is dropped for the other. Pieces are joined in order, with a line break added only
where neither side of a join has one. `GmailProvider.readDraftMessage` uses it now; the IMAP
reader follows in its own PR, once SwiftMail exposes the multipart grouping.

### Multipart grouping, IMAP half (#272, 2026-10-23)

`IMAPProvider.completeDraftCopy` applies the same rule. SwiftMail (TabMail/SwiftMail
`agent/multipart-containers`, pinned at `0ca687a` when #272 merged) now records on each
`MessagePart` the multipart bodies that enclose it (`enclosingMultiparts`, from BODYSTRUCTURE and
`.eml` alike) and `branch(of:)`, the child of a multipart that holds the part: a general MIME fact,
not a draft rule. For each enclosing `multipart/alternative` the read takes the highest branch
holding body text; a body part in any other branch is not read. The pieces go through the shared
`DraftBodyPiece.body`.

### A Gmail reply replaced by a standalone message (#278, 2026-10-24)

`repliesElsewhere` compared parents only when the server copy names one, and TabMail's own uploads
wrote no `In-Reply-To`, so a reload could not tell TabMail's copy from another app's standalone
message put in the draft's place (through the Gmail API, keeping the draft resource): the row took
the new text and kept the old parent, and Send threaded it under that message.
- A Gmail reply draft's upload now writes `In-Reply-To` and `References` as Send will
  (`DraftStore.uploadThreadHeaders`: `ThreadUtils.outgoingThreadHeaders` on the parent
  `Draft.resolveReplyToHeader` finds). Forwards, and every other provider, write none, as before:
  the Outlook draft read does not return the header, and an IMAP draft is never replaced in place
  (a new copy is a new UID).
- `Draft.serverCopyNamesParent` (v94, nullable, no backfill) records whether the copy the row last
  uploaded (`applyPushCompletion`), adopted (`makeDraft`) or reloaded (`applyReload`) names a parent.
- A reload whose copy names no parent, when that record says the last one did, takes the existing
  removal (`ReloadWrite.removed`, `OpenCheck.replacedElsewhere`) and the next open adopts the copy
  unthreaded. A row with no record (every row from before v94) keeps its parent, as before.

### Images named only by their Content-ID (#283, 2026-10-24)

SwiftMail names a media part that has no filename after its Content-ID (upstream behaviour,
`MessagePart` from BODYSTRUCTURE), so the image of a `multipart/related` HTML body written without
a `Content-Disposition` read as a file named like `logo@example.com`: in the message's attachment
list, its paperclip, and an adopted draft, which carried it as a file instead of an inline image.
`IMAPFetchMapping.isRelatedPartNamedByContentID` now marks a part as inline content when it is an
image with no disposition, a `multipart/related` body holds it directly (the multipart's `path` is
the part's section without its last number), and its filename is its Content-ID. Every IMAP
classifier uses it: `IMAPFetchMapping.hasAttachments` (which `IMAPProvider.mapMessageInfo` now
calls instead of its copy) and `extractAttachments`, and `IMAPProvider.buildFullMessageInfo`.
These keep their file: a Content-ID image outside a related body, so an image no HTML shows is
still listed; one with a name of its own; a related part that is not an image (a related body may
hold a PDF, and the HTML gives no way to open it); and a part of an attached message's own mixed
body when the outer message's body is related (an outer related body does not reach into an
attached message, RFC 2046 §5.2.1).

### Drafts open prepared, with no blank frame (#309, 2026-10-24)

> **Superseded in part by #326 (2026-10-25), below:** the previous screen no longer waits with a
> busy mark, and `DraftOpenTracker` is deleted. The preparation, the seeded compose and the
> hydration gate described here still hold.

Opening a saved draft showed a blank: the cover presented a spinner, then a compose with empty
fields that filled in once the draft (and, for a pushed Gmail or Outlook row, its server copy) had
been read. Owner, 2026-10-24 (option B): stay on the previous screen with a busy mark on the draft
row until the server read finishes, then open the compose already filled; the read stays capped at
`ExternalDraftOpenConfig.reloadTimeoutSeconds`.

`DraftOpenPreparation.prepare` now does the whole open before anything is presented: resolve a
Drafts header to its local row (`ServerDraftComposeLoader`, now only the resolver, adopting as
above), `ExternalDraftAdoption.refreshBeforeOpen`, then the row with its exact owning account and
reply parent (the checks `DraftComposePresenter` ran before). `DraftComposePresenter(source:
prepared:)` renders the outcome; `ComposeView(preparedDraft:)` starts its fields from the prepared
row, so its first frame is the draft, and does not read the server again (its guarded local read
and every bind check still run). Every presenter caller prepares before presenting, and
`DraftComposePresenter` has no unprepared initializer: the Drafts list (`InboxView.openDraft`, busy
mark on the row in both the normal and triage layouts), the agent-draft toast, the compose toolbar's working draft (the button shows the
busy mark), the detail column (`DetailDraftOpen`, a busy mark in the column) and a chat-pill push
(`MailNavigationView`, its own cover). Reply/forward resume and Undo reopen do not go through the
presenter and keep the open-time reload inside `ComposeView` (`ServerCopyCheckCover`).

The opens that present a cover (Drafts list, toast, toolbar, chat pill) are prepared one at a time,
app-wide (`DraftOpenTracker`, through `DraftOpenPreparation.open`; the detail column's open lives and
ends with its view):
a newer open, from another place or the same one (a second toolbar tap may name another working
draft, so a re-tap is never dropped, only prepared again), a navigation the user makes
meanwhile (another message, a folder, a pushed message, a deep link, a toast, the account screen,
or Back out of a pushed message, a selected message or the account screen — `DraftOpenCancelledByBack`,
review r5), or any compose that
appears (a new message, a reply; `ComposeView.performLifecycleAppear`) supersedes it, and the
superseded open presents nothing when it ends, so an older, slower open never covers what the user
went to. The busy mark is the tracker's, so it ends with every open, failed or not.

Until the compose has bound the prepared row (its attachments, change baselines and generation, in
`loadDraftOrPrepopulate`), its fields, its attachment button and its chat take no edits, Send does
nothing (before the empty-body question too) and Close dismisses without writing: the row on disk is exactly the draft the user opened, while a save in that window would
have carried the not-yet-loaded attachments as none and deleted the saved files. The first frame does
no synchronous Contacts lookup: the `resolveContactNames` prepaint, inert while recipients arrived
only after it, waited on the Contacts permission dialog on the main thread once they were seeded
before it, and is deleted (review r3, 2026-10-25).

A failed open is a card in the presented cover, as before: no local copy and an uncarriable
attachment are final; a failed read, an unverifiable account and a copy that replaced the row while
opening (formerly an error inside the compose) offer Try Again, which re-runs the preparation.
While an open is prepared nothing is presented, so the agent compose queue's hold (ADR-IOS-030)
starts when the presenter appears, as before; an agent compose presented during the preparation
makes the draft's cover not present, and tapping the draft again opens it. The owner accepted this on 2026-10-24
(`IOS-DRAFT-025`, GitHub #311, P5).

### Drafts open at once, a spinner inside (#326, 2026-10-25)

After the 1.10.0 TestFlight smoke the owner kept "no flash" but asked that the open look immediate:
"It opens and then spins and then it loads." Tapping a draft now presents its compose cover at
once with the normal open animation. `DraftComposePresenter(source:)` runs
`DraftOpenPreparation.prepare` inside the cover and shows `DraftOpeningView` meanwhile: the
compose's Close bar (`ComposeView.headerHeight`) and background with a spinner, and no field to
type into. When the open is ready the compose appears holding the draft (`ComposeView(preparedDraft:)`,
unchanged from #309); a failure shows its card in the same cover, and Try Again shows the spinner
again. Close on the spinner dismisses and writes nothing. The server-read rule is unchanged: a clean
Gmail or Outlook row is reloaded from its server copy, capped at
`ExternalDraftOpenConfig.reloadTimeoutSeconds`.

Every caller presents at once with a `DraftOpenRequest`: the Drafts list (both layouts), the agent
toast, the compose button, the chat pill (`MailNavigationView`, its own cover) and the detail column
(the presenter in place of `DetailDraftOpen`). With nothing pending outside a cover, an older open
can no longer appear over a newer screen, so `DraftOpenTracker`, its cancellations at every
navigation, `DraftOpenCancelledByBack`, `DraftOpenPreparation.open`, `PreparedDraftOpen` and
`DraftOpeningMark` are deleted. Because the presenter is on screen for the whole read, the
ADR-IOS-030 compose hold begins before the read, which resolves `IOS-DRAFT-025` (#311).
