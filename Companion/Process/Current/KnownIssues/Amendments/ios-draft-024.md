# IOS-DRAFT-024

- Register classification: `accepted`
- New post-freeze record (2026-10-21) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-21, owner).** Found by the #217 tier-1 review round 3 (A1/C1).

A data-only migration (`v93_openPreUpgradeServerDraftsLocally`) was written to keep these drafts
opening from the device until their next save. Asked about it, the owner ruled: *"i think we should
drop it"*, and kept drafts that are not yet on the server as they are. The migration was removed
before release; its name is burned (`AppDatabase` notes it beside v92).

## The behaviour

Releases up to v1.9.2 uploaded a Gmail or Outlook draft's body as HTML built from the text, and on
Outlook the draft update never changed attachments after the first save. After the upgrade, every
open of a Gmail or Outlook draft with no unsent edits (`serverPushStatus == "pushed"`) reloads the
server copy (`ExternalDraftAdoption.refreshBeforeOpen`), so the first open of such a draft replaces
the device's copy with what the old release uploaded:

- **Gmail:** the HTML is read back as text through `EmailFilter.htmlToPlainText`; spacing and line
  breaks can differ from what was typed.
- **Outlook:** the body is Graph's text conversion of that HTML, and the attachments are the ones
  the draft had at its FIRST save: a file added afterwards is gone from the draft, and a file
  removed afterwards comes back.

Reachability: only drafts an earlier release uploaded and that had no unsent edits at the upgrade,
on their first open after it. Drafts with unsent edits (`"dirty"`) and drafts never uploaded open
from the device and upload as text on their next save, unchanged by this record. IMAP drafts do
not reload on open. A draft saved once by this release uploads as text with its real attachments,
and from then on reopens as saved.

## Recoverability

The text stays readable and editable; the user can fix spacing and save. An Outlook file added
after the draft's first save must be attached again from wherever the user still has it. Not a
dropped intention of a queued action, not a wrong-message mutation.

## Subsystem and search terms

Drafts; pre-upgrade; upgrade; v1.9.2; v93 dropped; `v93_openPreUpgradeServerDraftsLocally`; reload
on open; `refreshBeforeOpen`; `reloadsBeforeOpen`; HTML upload; Gmail; Outlook; Graph attachments;
#217; t1r3 A1 C1; owner-accepted
