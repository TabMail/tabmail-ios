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
3. **Attachments compared by name only (owner 2026-10-21, #229).** The check compares
   attachment and inline-image file names, not their bytes: there is no time or fingerprint the
   providers all carry, and downloading every attachment on every check is too costly. Another app
   that swaps a file for a different one under the same name, while this device holds unsent
   edits, is overwritten by our next upload. Inline images are the likelier case, since adoption
   names them by position.
4. **Recipient text that is no address is not compared (owner 2026-10-21, #230).** A recipient
   field is compared by the addresses it names. IMAP servers rewrite text that is no address
   (an unfinished name, for example) in the recipient summary TabMail reads, so comparing it would
   report a change after every save. Another app that changes only that text, while this device
   holds unsent edits, is overwritten by our next upload.

Owner, 2026-10-21, on item 3: *"If metadata is not available, just name is fine. Accept it and file
an issue tracker ... saying that we might need to revisit this."* Item 4 was accepted the same day
on the same terms (issue #230 records when to revisit).

## Recoverability

Not a dropped intention and not a wrong-message mutation: the overwritten version was a draft of
the same message. The other app's text is lost only inside the gap above, or by the two narrow
edits of items 3 and 4, all of which the owner accepted.

## Subsystem and search terms

Drafts; race; check then write; time of check to time of use; last save wins; overwrite;
`draftRevision`; `serverDraftRevision`; `fetchDraftCopy`; `serverDraftText`; `DraftServerText`;
`DraftServerCheck`; v92; attachment names only; same-name image swap; rejected recipient entries; leftovers; ENVELOPE rewrite; #229; #230; owner-accepted

## Amendment, 2026-10-21 (owner's fourth ruling): superseded by LAST SAVE WINS (#233)

Items 1 to 4 above described a check that no longer exists; they are preserved as written. The
owner replaced the whole check with last save wins: *"the first version we have a last save wins
strategy and [file an issue] tracker that we might overwrite other drafts. Sort of a known defect
which we put as low priority because it's really just hypothetical."* Tracked as #233 (P4).

**The accepted limitation now:** nothing reads the server copy before Save or the upload, so when
another app edits the same Gmail, Outlook or IMAP draft while this device holds unsent edits for
it, this device's next upload replaces that edit, with no warning. A draft with no unsent edits is
not affected: every open reloads it from the server first (`IOS-DRAFT-020`). Reachability: the
same draft edited in two apps between two of this device's saves; the owner judges it
hypothetical. Recoverability is unchanged: the overwritten version was a draft of the same
message, never a wrong-message mutation or a dropped intention of this device. Items 3 and 4
(#229, #230) are moot, as is item 2 (the v92 column it names was never released and is gone).
