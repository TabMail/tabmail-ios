# IOS-DRAFT-020

- Register classification: `open`
- New post-freeze record (2026-10-17) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-10-17) — owner decision.** Filed alongside `IOS-DRAFT-019` (#217).

## The behaviour

Once this device owns a draft (authored here, or adopted from another app), reopening it from the
Drafts folder shows the LOCAL copy. If another app later edits that draft IN PLACE — Gmail keeps the
draft resource id across edits, Graph keeps the message id — the local row still owns the address,
so TabMail opens its older text, and the user's next save replaces the other app's newer edit
(last save wins, per the owner's 2026-10-17 ruling on concurrent edits).

IMAP is not affected the same way: another app's edit is a new APPEND with a new UID, so the new
header has no owner and is adopted fresh.

## Why it is not fixed in #217

It predates #217 for drafts authored on this device. Detecting "the server copy changed since we
last wrote it" needs a version witness this tree does not record for Gmail/Graph drafts (the Gmail
contained message id or a Graph change key), and refreshing a `"pushed"` row from the server would
round-trip TabMail's own drafts through HTML → plain text. That is a product-behaviour choice.

## Options

1. Accept: last save wins also across reopen (simplest).
2. Refresh on open when the row is `"pushed"` (no unsaved local edit) and a recorded version witness
   shows the server copy changed.

## Subsystem and search terms

Drafts; stale draft on reopen; edited in another app; Gmail draft resource id; Graph draft id;
last save wins; `ExternalDraftAdoption`; `LocallyAuthoredDraftOpenAuthority`
