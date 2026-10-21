# IOS-DRAFT-021

- Register classification: `accepted`
- New post-freeze record (2026-10-17) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-17, owner).** Filed with the #217 reload-and-ask work
(`IOS-DRAFT-020`, ADR-IOS-091).

Owner, 2026-10-17: *"The brief gap time between our check and the save is an acceptable loophole
where the server can actually have an edit and then ours can overwrite. It would be an acceptable
race condition that I'm going to document as accepted."*

## The behaviour

1. **Check-then-write race.** Save and the upload first read the server copy
   (`EmailProvider.fetchDraftCopy`, compared as text since the owner's 2026-10-17 third ruling;
   this item first said "server revision", `draftRevision`) and only then write (`saveDraft`). No provider offers a
   conditional draft write TabMail uses, so another app that saves inside that gap is overwritten
   by ours. The gap is one round trip at the upload, and at Save it also spans the time the user
   takes to answer the prompt when they choose Overwrite. Reachability: two apps saving the same
   draft within about a second of each other.
2. **Pre-v92 rows.** A draft row written before migration `v92_addDraftServerText` has no
   recorded copy of the server text (this item first named the superseded
   `v92_addDraftServerRevision`). A nil base is "no evidence", so such a row keeps the old last-save-wins
   behaviour for its first upload after updating, and a row with no unsent edits opens as is.
   Every push, adoption or reload records the text, so this ends after one save per draft.

## Recoverability

Not a dropped intention and not a wrong-message mutation: the overwritten version was a draft of
the same message. The other app's text is lost only inside the gap above, which the owner accepted.

## Subsystem and search terms

Drafts; race; check then write; time of check to time of use; last save wins; overwrite;
`draftRevision`; `serverDraftRevision`; `fetchDraftCopy`; `serverDraftText`; `DraftServerText`;
`DraftServerCheck`; v92; owner-accepted
