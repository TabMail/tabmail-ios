# IOS-CATCHUP-005

- Register classification: `accepted`
- New post-freeze record (2026-11-20) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-20, #1062).** Registered with the stored listing top of the IMAP
older-mail check (ADR-IOS-107, amendment of 2026-11-20). Sits next to IOS-CATCHUP-004 (unknown
epoch): this one is an unknown top.

## The behaviour

A listing of a folder with no change bookmark and no stored top (`IMAPCatchUpState.Listing.top`)
reads the folder's UIDNEXT before its first range. When that SELECT reports no UIDNEXT, the top is
unknown (a "could not determine" answer is not an answer): no top is stored, and every call of
that listing lists only up to the last local UID, with no further UIDNEXT read. Flags and removals of held mail are reconciled as before, and an
empty folder completes. Mail above the last local UID is not looked for. The listing can complete
only as not clean (`Listing.topUnknown`), so a folder owed a check stays owed and is listed again
at least daily, plus when its change counter moves; nothing settles on an unknown top. A later range SELECT that does
report UIDNEXT stores it as the top and the listing goes on to it, still not clean; one without
UIDNEXT keeps the top already learned.

## When it happens

Only on a nonconforming server whose SELECT omits `* OK [UIDNEXT n]`: RFC 3501 §6.3.1 and RFC 9051
§6.3.2 require it in every SELECT response.

## Recoverability

The folder's window listing still runs on every full sync. Once a SELECT reports UIDNEXT, the next
catch-up stores the top and the listing finds and loads what is missing. Nothing is mutated or
removed on a guess.

## Subsystem and search terms

Older-mail check; catch-up; missing message; UIDNEXT missing; unknown top; nonconforming server;
fail closed; owed folder; `IMAPProvider.catchUp`; `Listing.top`; `getUidNextWithEpoch`;
`suppressSelectUidNext`; `topUnknown`; `unknownTopKeepsTheFolderOwed`;
`unknownTopStillReconcilesFlagsAndRemovals`; `unknownTopOneRequestPerCallCompletes`;
`laterUidNextStoresTheTopButStaysUnclean`; ADR-IOS-107; #1062
