# IOS-CATCHUP-001

- Register classification: `accepted`
- New post-freeze record (2026-11-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-13, #750).** Registered with the Outlook older-mail check
(ADR-IOS-107, ADR-IOS-111). The same holds for Gmail's check, so this is Gmail parity, not an
Outlook-only gap.

## The behaviour

Once an Outlook folder's older-mail listing completes, the check does not list that folder again
until one of two things happens (`ExchangeProvider.catchUpPlan`):

- the folder's change cursor lapses (`ExchangeCatchUpState.lapsedSinceLastListing`), or
- the folder's page walk completes after a listing that ran while the walk was still incomplete
  (`walkIncompleteSeen`).

There is no periodic listing, as on Gmail. IMAP has a daily one
(`SyncConfig.catchUpFullCheckIntervalSeconds`). Anything the change feed cannot report therefore
waits for that next listing:

- **A message the phone lacks, whose direct load kept failing.** After the page walk's hold bound
  (`SyncConfig.backfillPageHoldMinutes`, 60 minutes) the listing passes over it, and the folder
  stays without it.
- **A removal candidate whose proof kept failing.** When the `$batch` proof stays unreadable or
  unanswered for the same bound, the candidate is dropped and its row is kept, so a message
  already gone from the server can stay visible.
- **A message the listing missed.** The listing follows Graph's page link only inside one second
  of `receivedDateTime`. If the folder changes between those pages, a message the phone lacks can
  be skipped for that listing.

## Recoverability

Nothing the user wrote is lost, and no message is removed on a guess: a removal still needs a
`$batch` proof (ADR-IOS-069).

- Opening a message that is gone from the server removes it: the body fetch answers 404, and the
  row is deleted as confirmed gone.
- A message that changes later is reported by the change feed.
- The next lapse lists the folder again and repairs whatever is left.

## Subsystem and search terms

Older-mail check; catch-up; Outlook; Graph; `ExchangeProviderCatchUp`; `catchUpPlan`; listing;
lapse; walk completion; `walkIncompleteSeen`; hold bound; `backfillPageHoldMinutes`; direct load;
`CatchUpDirectLoad`; removal proof; `$batch`; `fetchMessageDetails`; candidate dropped; ghost;
missing message; nextLink drift; same-second group; Gmail parity; ADR-IOS-107; ADR-IOS-111;
ADR-IOS-069; #750; #722; #733
