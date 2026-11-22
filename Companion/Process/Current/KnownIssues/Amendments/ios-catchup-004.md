# IOS-CATCHUP-004

- Register classification: `accepted`
- New post-freeze record (2026-11-20) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-20, #1062).** Registered with the IMAP older-mail check that
finds missing mail by UID (ADR-IOS-107, amendment of 2026-11-20), which replaced the date-based
self-heal.

## The behaviour

`IMAPProvider.catchUp` lists and loads nothing in a folder whose UIDVALIDITY is not known
(`Folder.lastKnownUidValidity` nil or 0) or whose UIDVALIDITY reset is pending
(`uidValidityResetPendingAt`). Nothing is decided about a UID whose numbering is unproven (C3). The
deleted self-heal also repaired such folders by date; that epochless repair is not replaced. A
folder owed a check stays owed.

## When it happens

A folder whose SELECT has never reported a UIDVALIDITY (a nonconforming server; RFC 9051 §6.3.2
requires it), or the short window between a detected reset and its completed reaction.

## Recoverability

The folder's window listing still runs on every full sync. Once a SELECT reports the epoch (or the
reset reaction completes and stamps it), the next listing finds and loads what is missing. No
message is mutated or removed on a guess.

## Subsystem and search terms

Older-mail check; catch-up; missing message; UIDVALIDITY unknown; epochless server; reset pending;
fail closed; `IMAPProvider.catchUp`; `lastKnownUidValidity`; `uidValidityResetPendingAt`;
self-heal removed; `unknownEpochLoadsNothing`; ADR-IOS-107; ADR-IOS-061; C3; #1062
