# MIS-IOS-034 — kept an Outlook-only fact as per-account state on the sync engine, above the provider boundary

**Class:** design-process
**Severity:** medium (one review round)
**First seen:** 2026-11 · **Recurrences:** 1 · **Status:** Active
**Related:** ADR-IOS-060 (the dumb pipe) · **Rule owner:** owner rule 2026-11-09, no provider knowledge above the EmailProvider boundary

## The tell

> *"The fix needs to remember one thing per account between the delta pass and the full sync, and
> `SyncEngine` already keeps per-account dictionaries, so one more `[accountId: String]` there is the
> smallest change."* The dictionary is named after one provider, and only that provider's arm reads it.

## What actually happened

tabmail-ios #427 (the Outlook delta link kept until Graph refuses it) met #509 on rebase: a round that
fails on one changed message's details must still be bounded by the next full sync replacing the link.
The fix stored `exchangeLinkFailedOnDetails: [String: String]` on the `SyncEngine` actor, set in the
Outlook delta arm and read in the Outlook capture arm, with a clear in `remove(accountId:)`. The arms
live in `SyncEngineDeltaSync`, which the owner exempted as old working code that "new code still never
adds to". The next tier-1 round returned the architecture angle UNCLEAN: the first provider-named
stored property on the engine. The record moved to `ExchangeProvider.deltaLinkFailedOnDetails`, which
the registered provider instance keeps between the delta pass and the full sync.

Later the same day the owner ruled that every full sync takes a new delta link, and #427 was rebuilt
without the record or the mechanism it served. The mistake stands: the placement was wrong while the
record existed.

## Why it is not obvious

The exempt file already switches on the provider, so one more Outlook line there looks like the local
style. The exemption covers the existing code; it is not a place to grow. And the engine's other
per-account dictionaries (work queues, backfill tasks) are provider-blind, which makes a new one look
like the same kind of thing.

## The rule

A fact only one provider produces and only that provider's code reads lives on that provider (a stored
property or a method), never on the engine, the queue, AccountManager or a view.

## Mechanical check

```bash
# provider-named stored state on the sync engine actor (expect no hits)
rg -n '^\s*(private\s+)?var\s+(exchange|outlook|graph|gmail|imap)\w*\s*[:=]' TabMail/Services/Sync/SyncEngine.swift
```
