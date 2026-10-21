# IOS-DRAFT-020

- Register classification: `resolved`
- New post-freeze record (2026-10-17) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-10-17, GitHub [#217](https://github.com/TabMail/tabmail-ios/issues/217),
ADR-IOS-091).** Filed `open` earlier the same day alongside `IOS-DRAFT-019`; the owner then chose
option 2 below and went further:

> "It should definitely reload from the server. It should not hold its local copy. Also, as a
> safety check … if it changed on the server, we should ask whether to overwrite or reload or save
> as new … and then before saving, always check if the server copy has updated."

## What changed

Every draft row records the server revision its content is based on (`Draft.serverDraftRevision`,
migration `v92_addDraftServerRevision`): the IMAP UID, the Gmail draft's contained message id, or
the Graph `changeKey`. It is written at push completion, adoption and reload. Each provider answers
`draftRevision(identity:)` — `.present(revision)`, `.gone`, or a THROW for "could not tell".
`DraftServerCheck` holds the decisions as pure functions.

- **Open** (`ServerDraftComposeLoader.checkServerCopy`): a row with no unsent edits (`"pushed"`)
  follows the server — a changed copy is RELOADED before the editor opens, a vanished one shows
  "Draft unavailable". A row with unsent edits opens as it is when the server is unchanged
  (owner answer: "Phone's edits"), and otherwise asks **Overwrite / Reload / Save as new**. If the
  check cannot run, the row opens as it is; Save and the upload check again. IMAP needs no round
  trip here: the opened header IS the row's UID and an IMAP message never changes in place.
- **Save** (`ComposeView.saveDraftAndDismiss`): checks first, with a bounded wait
  (`DraftServerCheckConfig.saveCheckTimeoutSeconds`). Changed ⇒ the same three choices; gone ⇒
  Save as New or Cancel. Offline or failed ⇒ saves locally (owner answer: "Save locally, check at
  upload").
- **Upload** (`DraftStore.pushDraftToServer`): checks before the provider write. Changed ⇒ does NOT
  overwrite, returns `.serverChanged`; the edits stay `"dirty"` in the row and the question is asked
  on the next open. Gone ⇒ saves as a new draft. A thrown check propagates and the upload retries.
- **Send** does not check (owner answer: "No, Send just sends").

The three choices: Overwrite re-bases the row on the server's revision and queues the upload;
Reload replaces the row with the server copy (at Save: drops the edits and closes, and the next
open reloads); Save as New detaches the row from the other app's copy and queues it as a new draft.

## What remains

`IOS-DRAFT-021` (accepted, owner-blessed): the check and the write are two calls, so an edit inside
that gap is overwritten; and a pre-v92 row with unsent edits keeps last-save-wins for its first
upload.

## Original record (preserved)

Once this device owns a draft (authored here, or adopted from another app), reopening it from the
Drafts folder shows the LOCAL copy. If another app later edits that draft IN PLACE — Gmail keeps the
draft resource id across edits, Graph keeps the message id — the local row still owns the address,
so TabMail opens its older text, and the user's next save replaces the other app's newer edit
(last save wins, per the owner's 2026-10-17 ruling on concurrent edits).

IMAP is not affected the same way: another app's edit is a new APPEND with a new UID, so the new
header has no owner and is adopted fresh.

Why it was not fixed in the first #217 commit: detecting "the server copy changed since we last
wrote it" needs a version witness this tree did not record for Gmail/Graph drafts, and refreshing a
`"pushed"` row from the server is a product-behaviour choice. Options were (1) accept last save wins
across reopen, or (2) refresh on open when the row is `"pushed"` and a recorded version witness
shows the server copy changed. The owner chose (2) plus the question for unsent edits.

## Amendment, 2026-10-20 (Codex review round 1 of #217)

The mechanism above is superseded in two places; the behaviour the owner chose is unchanged.
The comparison is the draft's text, not a server revision (ADR-IOS-091 third ruling,
`serverDraftText`, `fetchDraftCopy`, `DraftServerText`). The open check moved from
`ServerDraftComposeLoader.checkServerCopy` (deleted) into the step every saved-draft open shares,
`ComposeView.loadDraftOrPrepopulate` → `ExternalDraftAdoption.refreshBeforeOpen`, so every route
checks. A clean row whose copy changed reloads; a row with unsent edits whose copy changed asks
Overwrite / Reload / Save as new before the editor shows; a gone copy or a failed check opens the
row as it is. The IMAP "no round trip" note no longer holds: an IMAP draft is read like the others.

## Subsystem and search terms

Drafts; stale draft on reopen; edited in another app; server revision; `serverDraftRevision`;
`draftRevision`; `DraftServerCheck`; `DraftServerRevision`; `changeKey`; Gmail contained message id;
reload; overwrite; save as new; `.serverChanged`; `ExternalDraftAdoption.reload`;
`LocallyAuthoredDraftOpenAuthority`; v92; `refreshBeforeOpen`; `ServerChangedOnOpenAlert`;
`serverDraftText`; `fetchDraftCopy`

## Amendment, 2026-10-21 (owner's fourth ruling: last save wins)

Still `resolved`, by a simpler mechanism. The text comparison, the Save and upload checks and the
Overwrite / Reload / Save as new question above are deleted (ADR-IOS-091 fourth ruling, #233).
Every open of a Gmail or Outlook draft with no unsent edits (`"pushed"`) now reloads its server
copy with no comparison (`ExternalDraftAdoption.refreshBeforeOpen`, `reloadsBeforeOpen`), so a
stale local copy is never shown. A row with unsent edits opens as it is and its next upload
replaces the server copy (last save wins, `IOS-DRAFT-021`). IMAP is not read at open again: an
IMAP message never changes in place. Offline, a timeout, a gone copy or an unreadable part opens
the local row unchanged. A reload never loses content the server holds: draft-copy reads are
complete (every inline image; IMAP attachment bytes from the proven read) or they throw, and a
Graph draft update now replaces the server's attachments so the reload brings back what was saved.
Search terms: last save wins; always reload; `reloadsBeforeOpen`; `ExternalDraftOpenConfig`;
`completeDraftCopy`; `attachmentData`; `replaceDraftAttachments`; #233.
