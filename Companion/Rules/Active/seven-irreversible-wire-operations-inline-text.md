### The seven irreversible wire operations: "never permanently deletes" is true of MAIL only, not drafts or calendar events

Routed out of `CLAUDE.md` by the `companion-compact` skill (2026-11-10). A short form stays inline in `CLAUDE.md`; below is the original text, byte-for-byte (sha256 of the block: `2b25dd70f68da83e126bb7cead29572704e47b060deba4ee4f7205d81ab46e34`).

<!-- preserved-block-begin -->
> **Stated negatively, because this absolute was wrong for two years and walked reviewers past two
> live hazards.** "Never permanently deletes" is true of MAIL, **not of DRAFTS OR CALENDAR EVENTS**,
> and the `COPYUID`-gated purge is **not** the only irreversible wire operation. There are **seven**:
> (1) the `COPYUID`-gated source expunge; (2) `IMAPProvider.deleteDraftStrong`; (3) `saveDraft`'s
> old-copy replacement; (4) Gmail's `DELETE /drafts/{id}`, which Google documents as permanent rather
> than a trash; (5) `CalDAVProvider.deleteEvent` — WebDAV `DELETE` on the event's `.ics` resource,
> for which RFC 4918/4791 define **no** trash, undelete or restore (added 2026-08-05; iCloud's
> whole-calendar snapshot rollback is not a per-item recovery and does not exempt it). The draft
> family **destroys a draft outright** rather than moving it to Trash.
> Further scope: (2) and (3) are irreversible only under UIDPLUS — without it `expungeScopedToTargets`
> issues nothing; Gmail's `.gmailContainedMessage` arm trashes rather than destroys; and
> `ExchangeProvider.deleteDraft`, `ExchangeCalendarProvider.deleteEvent` and
> `GoogleCalendarProvider.deleteEvent` are excluded on **positive** documented per-item recovery
> (Graph Recoverable Items; Google Calendar's 30-day event trash), not on the absence of evidence.
> **(6) is not a DELETE at all: `CalDAVProvider.splitSeries`' cap `PUT`** replaces the master `.ics`
> with an `UNTIL=`-capped `RRULE`, destroying every occurrence after the split point; it is
> written only after the new part holds what it removes (ADR-IOS-106), with no rollback.
> **(7) `ExchangeProvider.replaceDraftAttachments`' attachment `DELETE`** (#217) removes a file the
> local Outlook draft no longer names, only after every add succeeded.
> **⚠ Membership is defined by a PROPERTY — content that existed on the server no longer does, with
> no documented per-item recovery the call reaches — NOT by the verb `DELETE`. Do not restate this
> integer without re-running its predicate.** The greps are a **LOWER BOUND**, not the definition:
> five `--multiline` searches over `TabMail/ Shared/ TabMailNotificationService/` —
> `method\s*:\s*"DELETE"`, `httpMethod\s*=\s*"DELETE"`, `expunge\(`, plus the REPLACEMENT axis
> `httpMethod\s*=\s*"PUT"` and `method\s*:\s*"PUT"` — because **both** HTTP spellings occur, and the
> count was "four" for a day precisely because the earlier census saw only the first (`MIS-007`).
> **It is wrong the moment** a further spelling appears (a computed/enum HTTP verb, or deletion
> tunnelled through `POST` like Gmail `batchDelete` or Graph `permanentDelete`), a non-HTTP/non-IMAP
> destructive surface is added, an excluded call loses its documented recovery, or
> `GoogleCalendarProvider` gains a *this-and-following* series delete.
> **Consequence for design:** a fail-closed argument that leans on "nothing is ever destroyed" is
> valid for mail and invalid for drafts and CalDAV events — for those paths, say why the specific
> loss is acceptable.
<!-- preserved-block-end -->

### The count now (outside the preserved block)

The block above is preserved as written (seven). The census has since grown, each step adjudicated in
`Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md`, and the inline
list in `CLAUDE.md` carries all of them. **Eleven** (2026-11-14): (8) the CalDAV one-occurrence
delete's `EXDATE` `PUT` (#661); (9) a this-and-following delete's series end on Google and Outlook
(`endSeries`, #695); (10) the Outlook carry's `DELETE` of an occurrence (a split's new part, #563; a
series after its length change, #718); (11) Outlook's series `PATCH` that moves its time, which resets
every occurrence changed or deleted on its own (#718). The predicate and the greps are unchanged.

**Twelve** (2026-11-14, #718, master-agent): (12) a whole-series edit that moves the end earlier
removes the later occurrences, changed ones included, on all three providers: Google's `patchEvent`
sending a recurrence whose rule changes only where it ends (to an `UNTIL`), Outlook's
`graphPatchJSON` sending a range whose `endDate` alone moves, and CalDAV's `updateEvent` `PUT` built
by `earlierEndResource` (overrides placed after the new last date dropped). Its warning is the card's
"N meetings after <date> are removed." (`CalendarSeriesEndRemoval`). The predicate and the greps are
unchanged; re-run over the same roots: A=10, B=3, C=4, D=3, E=2, and `method\s*:\s*"PATCH"` 11 (main
at `c975c9baf`: 9 / 3 / 4 / 3 / 2, PATCH 10). Adjudication of the differences in the memory file.
