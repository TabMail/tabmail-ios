# IOS-DRAFT-023

- Register classification: `accepted`
- New post-freeze record (2026-10-21) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-21, owner).** Found by the #217 tier-1 review round 3 (C3).

Owner, 2026-10-21, asked whether to fix or accept that typed line breaks at the very end of a draft
are dropped on every save and reopen: *"Accept as known edge"*.

## The behaviour

`ExternalDraftAdoption.editableBody` reads a text-only server copy (every draft TabMail uploads,
and every Outlook copy) with ALL trailing line breaks removed, because MIME and the providers may
append one and a save and reopen must never grow the body by a line. Line breaks the user typed at
the very end of the draft go with them. Reachability: a Gmail or Outlook draft whose text ends in
one or more line breaks (for example "Hi Bob,\n\nAlice\n\n"), saved, then reopened, which reloads
the server copy. No visible character is lost; spacing and line breaks inside the text are kept.

## Recoverability

Nothing to recover: the text is unchanged apart from blank lines at its end, which the user can type
again. Not a dropped intention, not a wrong-message mutation.

## Subsystem and search terms

Drafts; trailing newline; trailing line break; save and reopen; reload; `editableBody`;
`refreshBeforeOpen`; Gmail; Outlook; #217; t1r3 C3; owner-accepted
