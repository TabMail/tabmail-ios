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
