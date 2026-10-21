# IOS-DRAFT-019

- Register classification: `resolved`
- New post-freeze record (2026-10-17) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-10-17, GitHub [#217](https://github.com/TabMail/tabmail-ios/issues/217)).**
Drafts written by another mail app (Gmail web, Apple Mail, Outlook, …) open and edit again. From
v1.7.0 (`e0d3d30e`, "unverified server-origin reopen" SUBTRACTED) until this fix, tapping one showed
"Draft unavailable — No editable copy of this draft was found on this device."

## What changed

`ServerDraftComposeLoader` resolves a local owner first, exactly as before. When there is none it
ADOPTS the server copy (`ExternalDraftAdoption`): it fetches the body and top-level attachments,
then ONE write transaction re-verifies the header and its exact provider-native address, refuses if
any `Draft` row already owns that address, and inserts an ordinary `Draft` row keyed `adopted:<uuid>`
with status `"pushed"` and the address the save/send/delete paths already use — IMAP
`(Drafts folder, UIDVALIDITY, UID)`, Gmail draft resource id, Graph message id. The normal resolver
then opens it through `DraftComposePresenter`. From there it is indistinguishable from a draft
authored on this device: the first save REPLACES exactly that server copy, Send deletes it.

**Owner ruling (2026-10-17):** take over the draft whichever client wrote it, with no lease or
lock; v2final's Outlook open lease is therefore not ported. The first version of the ruling said
concurrent edits are last-save-wins with no warning; the owner's second ruling the same day
replaced that with reload-on-open and an Overwrite / Reload / Save as new question — see
`IOS-DRAFT-020` (resolved) and `IOS-DRAFT-021` (the accepted check-then-write race). An adopted row
records the server revision its content came from (`Draft.serverDraftRevision`).

**What still fails closed (irreversible-wire hazards, not concurrency):** an IMAP header whose
observed UIDVALIDITY does not equal the Drafts folder's live, unquarantined epoch; a placeholder id;
a header that changed during the fetches (nothing is inserted); a body that is not on the device or
reads empty without server confirmation, or a failed attachment fetch (retryable "Try Again").

**Reply threading:** the other app's `In-Reply-To` is resolved like `Draft.resolveReplyToHeader`
Strategy 2 (exactly one header in the account) and claimed only when the v80 stamps will be
accepted again at reopen; otherwise the draft is adopted unthreaded rather than with a Send that is
blocked from the start. Adopted drafts never get TabMail's own quote — their body already carries
the other app's.

**Compared with the pre-v1.7 behaviour** (`e0d3d30e^`): that open matched rows by Message-ID and
subject, deleted the server copy at Send by Message-ID search, opened an EMPTY editor when the body
fetch failed, and left the other app's copy behind as a duplicate on save. All four are gone.

## Subsystem and search terms

Drafts; server-origin draft; external draft; other mail app; adoption; `ExternalDraftAdoption`;
`ServerDraftComposeLoader`; `noLocalCopy`; `LocallyAuthoredDraftOpenAuthority`;
`DraftStore.applyAdoption`; `adopted:` draft key; #217
