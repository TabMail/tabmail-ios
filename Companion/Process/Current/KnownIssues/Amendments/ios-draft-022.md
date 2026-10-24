# IOS-DRAFT-022

- Register classification: `accepted`
- New post-freeze record (2026-10-21) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-21, owner).** Filed with the #217 last-save-wins work
(ADR-IOS-091, fifth ruling). GitHub [#236](https://github.com/TabMail/tabmail-ios/issues/236) (P4).

Owner, 2026-10-21, choosing between matching Outlook draft attachments by name and comparing their
content: *"Match by name, accept the edge (Recommended)"*.

## The behaviour

Graph's message PATCH cannot change attachments, so an Outlook draft update syncs them through
`/messages/{id}/attachments` (`ExchangeProvider.replaceDraftAttachments`,
`ExchangeProvider.draftAttachmentPlan`). Local files and server attachments are paired BY FILE NAME,
one to one. Each local file with no same-named server attachment is added (a file of
`ExchangeDraftConfig.singlePostAttachmentLimitBytes` or more through an upload session); only after
every add succeeded is each unpaired server attachment deleted. A same-named file is left alone, so
an unchanged file, a large one included, is never uploaded again on each save.

The edge: removing an attachment and adding a DIFFERENT file with the SAME name in one edit leaves
the old file on the server. This device shows the new file until the draft is next opened, when the
reload brings back the server copy with the old file. Reachability: one edit that replaces a file
by another of the same name (for example an updated `report.pdf`) on an Outlook draft.

## Recoverability

Recoverable by one ordinary gesture: rename the new file, or remove the attachment, save, and add
the new one. Not a dropped intention of a different message and not a wrong-message mutation; the
server copy never loses a file the draft still names, because adds precede deletes and a failure
throws before any delete.

## Subsystem and search terms

Drafts; Outlook; Graph; attachments; same name; replace attachment; by name; add before delete;
upload session; `replaceDraftAttachments`; `draftAttachmentPlan`; `ExchangeDraftConfig`; #236;
#217; owner-accepted
