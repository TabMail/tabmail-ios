# IOS-SETTINGS-002

> Routed from `KNOWN_ISSUES.md` line 1446 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `a1d530f33eb17f957f121bbbe9a935d0a933c9f2af38b59fc06fce316b75ab9c`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — account-field and folder-role edits can appear accepted in Settings even when their synchronous GRDB write failed

## Subsystem and search terms

Settings; `AccountDetailView.saveAccountField`; signature; display name; email; IMAP username; folder role; `try?`; silent revert

## Full detail

`saveAccountField` ignores the throwing `dbPool.write` and then overwrites the matching `NavigationStore` account with the edited in-memory value. Display name, email address, signature placement, IMAP username, and signature all use this helper. Folder-role helpers also swallow the write, though their immediate `reloadFolders()` normally makes the failure visibly revert. A failed account-field write therefore looks saved for the rest of that in-memory session and reverts on a later reload/relaunch. There is no server mutation or durable corruption; the user re-enters the value. This is retained as a simple recoverable limitation rather than adding a settings outbox.
