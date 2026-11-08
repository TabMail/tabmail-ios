# IOS-DRAFT-026

- Register classification: `accepted`
- New post-freeze record (2026-11-07) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-08, owner, #422).** The owner accepted it as a limitation and kept
the draft route for every send with files.

*Preserved, superseded:* 🔓 **OPEN (2026-11-07, #422), proposed for acceptance.** Registered with the change that sends an
Outlook message with files through a draft (ADR-IOS-091, #422 section). Recoverable by one ordinary
gesture, so THE MANTRA's answer is to register it rather than build a mechanism; it becomes
`accepted` only once accepted as a limitation.

## The behaviour

An Outlook send with files creates a draft (`ExchangeProvider.createDraftWithAttachments`), adds each
file, then sends it with `POST /messages/{id}/send`. Any failure tries once to delete that draft and
rethrows the original error, so the Outbox row stays queued (transient) or is counted (permanent)
exactly as before. The draft stays in the user's Drafts folder when:

- the cleanup DELETE itself fails. It runs once, right after the failure it cleans up, and that
  failure is most often a lost connection, so on a flaky network the two tend to come together;
- the create's answer is lost, so there is no id to delete (the leftover has no files);
- the app is terminated between the create and the send or cleanup.

One leftover per affected attempt; transient failures retry without a cap. Unlike the draft-save
residual (`IOS-DRAFT-015`), a later successful attempt does not replace the leftover, because the
Outbox keeps no server id, and the leftover is a copy of a message that is (or will be) sent: sending
it from another client sends a duplicate, possibly missing files. Even a successful cleanup leaves a
soft-deleted copy in Deleted Items / Recoverable Items. Before #422 a message with only small files
went in one atomic `sendMail` and could leave nothing behind.

## Recoverability

One ordinary delete of the leftover in Drafts. No sent message is lost and no other message is
touched: the cleanup only ever addresses the id this attempt created. Not mechanised on purpose:
finding the leftover in Drafts by Message-ID could delete the user's own draft of the same message.

## Subsystem and search terms

Outbox; Outlook; Graph; send with attachments; draft route; `/messages/{id}/send`; stray draft;
leftover draft; cleanup failure; `createDraftWithAttachments`; `ExchangeProvider.send`; upload
session; ADR-IOS-091; #422; IOS-DRAFT-015; owner-accepted
