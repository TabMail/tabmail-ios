# TabMail iOS — Test Reference

This file documents cross-cutting test architecture that spans multiple files/layers. It is not a full test inventory — see individual test files for detailed coverage of a given component.

---

## Interrupted action recovery

`GlobalFifoExecutorTests.interruptedMovesConvergeAfterRestart` captures a real
SQLite snapshot at the provider boundary after the FIFO claim and reopens it
through `AppDatabase.init`. It checks ordered effects across the restart with
zero or two earlier moves completed, plus preserved operation identity, position,
retry count and attempt history. It models process death through a snapshot;
it does not terminate the hosted test process.

`interruptedGraphMoveConverges`, `interruptedGmailMoveConverges`, and
`interruptedIMAPMoveRetainsAuthority` exercise
real providers against stateful servers before and after remote completion,
including changed/unknown IMAP epochs and untouched bystanders.
`interruptedGroupedGmailMoveConverges` snapshots a real claim for one or three
messages and reopens it through both testing and production startup modes, with
existing-release flags, both normally and after a refused recovery UPDATE clears.
It checks preserved intent/history, every target, the bystander and durable queue
settlement through the database returned as usable.
`AccountManagerQueueDrainTests` retains startup-only coverage of cancelled-row
cleanup and unrelated queued work.

## Outlook calendar edits — server-side oracle

`ExchangeCalendarEditPreservationTests` drives `ExchangeCalendarProvider.updateEvent` and
`updateOccurrence` over `FakeHTTP` against `FakeGraphCalendar`, which applies Graph's documented
event-update semantics (unsent properties keep their values; writing `location` replaces
`locations`; `$select` returns only what it names). For seven edit kinds (rename, move an hour, move
only the end, change the room, add an attendee, remove an attendee, mark busy) on a single event, a whole series and one
occurrence, and a description edit of a plain event and a rule edit of a series, it asserts on the
stored event, not on our payload: every property the edit did not set (body, `showAs`, `locations`, attendee types, recurrence, start and end) comes back
unchanged, and the edited property holds what was asked (a removed attendee is gone, the rest keep
their types). The fake also models the recurrence
behaviour measured live for #423 (a range written without a zone is stored as UTC; a written rule
that differs from the stored one resets the series' exceptions; a `recurrence` PATCHed without
`start` moves the series to UTC midnight; a range without `startDate` is refused with a 400): a
whole-series edit that gives no rule writes no `recurrence` and resets nothing; a series moved to
another date, timed and all day (its end moving with it), keeps its stored recurrence but for the
range's start date; an
occurrence edit never writes a rule or the master. Also covered: an event made recurring, a series
given a new rule and a new date (the new rule is written), a series moved by a start written
without an offset, a series moved by a start spelled with an offset (`Z`, `.000Z`, `+00:00`) or
without seconds (`…T10:00`, bare or with `Z`) but labelled with another zone, as the tools pass one
through (dated where Graph stores it: within the device's day no recurrence, to another day the
range at that day; a start without seconds is written with `:00`), an all-day end-only edit (the
start stays), a move across UTC midnight within the device's day (no recurrence) and across
the device's midnight within one UTC date (range start = the device's date; both skipped within
about an hour of UTC), an occurrence named by its own id, an empty edit writing nothing, a PATCH
retried after a 401 with a refreshed sign-in, and an attendee stored in mixed case keeping its
type. The fixtures hold at any host offset from -12 to +14 hours.

Online meetings (#511): the online fixture's body follows the layout a Teams meeting on a work
account stored when checked live (notes, then a join section between two lines of underscores with a
short "Join:" link and the long `meetup-join` one; every link, id, number and passcode a
placeholder), and the fake models what that check measured: a body written without the join link
turns the online meeting off (`isOnlineMeeting` false, `onlineMeetingProvider` `unknown`,
`onlineMeeting` null). A description edit is one of the edit kinds on the online single event,
series and occurrence: the notes are replaced, the join section and everything after it are kept byte
for byte, and the meeting stays on. Also: a read gives the stored notes as the description at full
length (past the 255-character preview), an online meeting's without its join section and with its
join link as `conferenceUrl`, by `getEvent` and by a `calendarView` listing (the fake lists single
events and occurrences, never a series master); a description read, added to and written back keeps
the notes and the meeting; after the join link is written into the notes, the next description edit
still keeps the meeting; clearing the notes keeps the join section; and a layout without a separator
line gets the description as text, as before.
`GraphOnlineMeetingBodyTests` pins the recogniser over the live layout (found by either join link) and
the older layout of Graph's online-meeting samples: bare-text and element notes, escaping and line
breaks, a `<body>` tag with attributes or none, a join link
written raw, a separator nested in several elements, the cases it does not recognise (no link, the
separator only after it, a line shorter than `separatorMinUnderscores`, an unclosed `<body` tag, an
empty link) and where the notes end; a copy of the join link in the notes (as written and with
`&amp;`) and a line of underscores in the notes are part of the notes; with both, the join section is
still kept whole; trailing line breaks in new notes are dropped, so repeated edits do not grow the
body; and thousands of copies of the join link in the notes, with or without a join section after
them, are recognised as the clean body is, within a time limit a scan that restarts for each copy
exceeds. `ExchangeCalendarTests` maps an HTML, text or missing body to the
description; `CalendarToolHelpersTests` pins the `conference_url:` line after the description and an
event pill's notes (join link first); `ToolCachingTests` checks that the search and direct-read pill
caches carry the join link (including a read that finds the event by scanning every calendar), and
that in a new session a pill tap that fetches the event live shows it.
Notes written back as HTML (#577): `GraphOnlineMeetingBodyTests` writes a web, mail or phone link in
new notes as a link (with the read's escapes reversed), keeps a link to any other kind of destination
as its text (escaped, so markup in its label or destination stays text), writes a link whose
destination holds more colons (a port, a path, a query) as a link, escapes a label or destination so it can't add markup or leave the link (also a quote or
`<` joined to a combining, joining, spacing or Prepend mark), and keeps runs of spaces and spaces that
start or end a line; `ExchangeCalendarEditPreservationTests` reads back notes with links (web, mail,
phone, and one carrying every escape a read writes in a label or destination) and runs of spaces
exactly as written, for an online meeting and a plain event, and checks
that a description read and written back keeps its link as a link; `EmailFilterTests` pins
`markdownPieces` (unescaped label and destination, and the pieces joining back to the text).

## Inbox list — layered test architecture

the unified inbox read (ADR-IOS-055) replaced four disagreeing inbox-list read paths with one unified reader (`InboxListReader` → `InboxListComposer.compose`). Getting this right — and *keeping* it right as the code evolves — needs coverage at four distinct layers, each catching a different class of bug. A 5-round adversarial audit of the refactor found two HIGH-severity findings (F1, F2) that lived entirely *between* layers, invisible to any single layer's test suite — that's why the fourth layer (E2E) exists.

### Layer 1 — Pure composer harness (logic, thousands of cases)

**File:** `TabMailTests/ViewModels/InboxComposeScenarioTests.swift`

Drives `InboxListComposer.compose` — a pure function, no I/O, no GRDB, no clocks — over a value-type `SimWorld` state machine standing in for the whole pipeline (NSE staging → merge phases → sync → user actions → overlay drain). Each `SimWorld.Step` mirrors exactly one real-world event at FINE granularity (`stagePush`, `phase1Commit`, `ftsFlushCommit`, `phase2Commit`, `drainStaging`, `userMove`, `undo`, `uidRemap`, `reStage`, …).

Invariants I1–I7 (no-resurrection, no-vanish, AI-monotonic, undo-visible, no-duplicates, move-hides, window-sanity) are asserted after **every single step** of every named scenario, plus commutable-pair permutations and a seeded `SplitMix64` fuzz over hundreds of random legal step sequences per run. Because there's no I/O, this is cheap enough to run thousands of compositions per second — this layer is where lifecycle-interleaving bugs (the ones that would otherwise need a flaky on-device repro) get caught for pennies.

### Layer 2 — Reader integration (GRDB seams)

**File:** `TabMailTests/ViewModels/InboxListReaderIntegrationTests.swift`

Thin by design — only what the pure layer can't see: `DurableIdentityLookup` behavior against a real temp GRDB pool (exact-folder match, rfc822 fallback, UID-remap re-key), the P-step's by-id overlay fetch, and a contract-parity test asserting the shell's identity lookup matches the merge's own lookup helper over a shared fixture set (§4.4 risk 1 — divergence here reintroduces I1/I5-class bugs). One end-to-end smoke per fetch site (`fetchFullRange`/`fetchPage`/`resetMessages`) proves they all actually route through the reader.

### Layer 3 — Pinning suite (VM contracts)

**File:** `TabMailTests/ViewModels/InboxListBehaviorPinningTests.swift`

Exercises `InboxViewModel`'s public surface only (`insertStagedRows`/`reloadMessages`/`resetMessages`/`insertUndoneMessages`/`loadMoreMessages`/`lookupMessage` + `loadedMessages`/`displayGroups`) against a real temp `AppDatabase` swapped in for `AppDatabase.shared`. Originally written test-first (to pin current behavior) as the safety net for the composer refactor; now pins the reader's structural guarantees (staged-row survival, AI carry-over, undo-survives-reload, filter/pagination/triage-order parity) directly through the VM, independent of the pure layer's value-world model.

### Layer 4 — E2E invariant layer (orchestration + cross-layer ordering)

**File:** `TabMailTests/E2E/InboxEndToEndInvariantTests.swift`

The SAME scenario histories as Layer 1, driven through the REAL pipeline instead of a value world: a real temp `AppDatabase` + a real NSE staging SQLite file merged via `NSEDataBridge.mergeNSEStagingData(stagingPathOverride:)` + real `AccountManager` overlay mutations + real `NotificationCenter` posts + a real `InboxViewModel`. Assertions run against `vm.loadedMessages`/`displayGroups` (what the user's screen actually shows), not `compose`'s return value.

**Why this layer exists — F1 and F2.** Both were HIGH findings from the 5-round audit, and both slipped past Layers 1–3 with everything green:

- **F1 (signal-orchestration gap):** a "scrub-only" merge wake (re-staging an already-archived message finds nothing durable to write, only a staging scrub) has no `endOfMergeChanged` signal — before the fix, this left a phantom row the pre-detection `.messagesStaged` post had already inserted with no eviction trigger. Layer-local tests can't catch this because it's not about what `compose` returns or what the VM's *methods* do in isolation — it's about whether a *signal actually fires* to wake a real consumer after a mutation. **Invariant I8 (signal-liveness)** generalizes this: any step that changes what SHOULD be visible must be followed by an actual `.inboxDataDidChange`/`.messagesStaged` post — captured via a real `NotificationCenter` observer. The `scrubOnlyWakeStillConverges` scenario runs in WIRED mode (`vm.start()`, no manual reload) specifically so a regression shows up as "the screen never converges," not just "a flag was false."
- **F2 (cross-layer ordering gap):** `compose`'s `targetCount` trim and the VM's `loadedIds` pagination dedup were each tested individually, but their *composition* — trim running before dedup vs. after — was not. In triage mode (non-date-monotonic sort), an already-loaded row re-entering a later page's D query could eat a trim slot meant for a not-yet-loaded row, silently shrinking a page and flipping `hasMoreMessages` false with reachable mail still unread. **Invariant I9 (pagination-completeness)** generalizes this: driving `loadMoreMessages` to true exhaustion must surface every reachable id exactly once, with `hasMoreMessages` going false only at genuine exhaustion — dedicated scenarios (`paginationCompletenessNormal`, `paginationCompletenessTriage`) seed 2+ pages across multiple folders and drive to exhaustion rather than checking a single page transition.

**Invariant I10 (screen-truth convergence)**, checked at every settle point, is the general backstop for both classes: `Set(vm.loadedMessages.map(\.id))` must equal a fresh direct `InboxListReader.fetchSync` call built with the VM's own query shape. Running the SAME named scenarios at the pure (Layer 1) and E2E (Layer 4) layers turns any `SimWorld`-vs-reality fidelity drift into a loud, immediate disagreement instead of a silent blind spot.

**Granularity note:** the E2E step vocabulary is coarser than the pure layer's — staging a terminal (header+body+AI) row and running one `mergeNSEStagingData` call performs phase-1, the FTS flush, phase-2, and the staging drain all within one real "wake" (the merge awaits its own FTS flush). This is deliberate: Layer 1 proves invariants hold at every micro-step; Layer 4 proves they hold across real wake boundaries, which is the actual unit of observability a production reload/render cycle has. Scenarios that need to observe an in-between state (e.g. `aiNeverFlashesAcrossWakes`) drive two explicit gradual-staging wakes instead of relying on sub-wake granularity that doesn't exist at this layer.

**Retro-fit discipline:** a harness that can't re-catch a known bug isn't done. Both F1 and F2 were deliberately re-introduced (scrub-branch post disabled; `excludeIds` moved to post-trim) against this layer and confirmed to fail `scrubOnlyWakeStillConverges`/I8 and `paginationCompletenessTriage`/I9 respectively before the fixes were restored.

## Gmail moves and the labels Gmail maintains

Gmail keeps the `SENT` and `DRAFT` labels itself and refuses any
`messages.modify` that adds or removes them with 400 "Invalid label".
`TabMailTests/Infrastructure/StatefulGmailActionServer.swift` refuses them the
same way, refuses a new label on a draft's message, and serves
`/messages/{id}/trash` and `/untrash`.
`TabMailTests/Services/GmailMaintainedLabelMoveTests.swift` asserts, over every
source and destination pair, that the move reaches Gmail's end state (the kept
label stays, Trash is entered and left with trash/untrash, a draft's message
takes no new label) and that no request ever names a maintained label. It also
asserts that delete from Sent or Drafts and its Undo land on the server through
trash/untrash; that every real member of a delete from Sent and of its Undo
lands when the first member is an invalid or missing id;
the agent's draft delete lands; a move the server refuses stays queued rather
than counted as done; a delete from Sent, and its Undo, that Gmail refuses with a
503 or an unclassified 400 on trash/untrash stays queued with the server
unchanged and lands once the failure clears; a user move into Sent or Drafts is refused on Gmail and
queued on IMAP. `MoveFolderPickerTests.gmailOmitsTheLabelsGmailKeeps` covers the
picker, and `DraftDeletionTests` pins that an "Invalid label" body is not an
authoritative rejection.

## Local placeholder rows never reach the provider

A `sent-…` row (the optimistic Sent copy of a sent message, written before sync
lists the server's copy) or a `draft-…` row (a draft the server has not saved
yet) has no address on a server.
`TabMailTests/Services/PlaceholderActionAdmissionTests.swift` runs these producers
of a message action (the agent's delete, a user move, mark unread, flag, applying
and removing a label from the label menu, removing a label from the row, and the
reply and forward flags set when a reply or forward finishes sending) on Gmail,
Outlook and IMAP. Mark read and undo move go through the same admission check but have no case here.
On a placeholder alone, each action queues nothing and changes nothing locally,
and the agent's delete reports the row pending; the same action on a real row
queues an op for it. For the actions that take several rows, a placeholder and a
real message together reach the provider with only the real id, and the
placeholder row stays as it was.

An open message shows what was stored. When a read toggle from the message view
(the focused message, or a message in its thread) is refused for a placeholder,
the view returns to the stored row; on a real row it keeps the toggled state.

The same file covers what happens once a draft save lands. On Gmail, Outlook and
IMAP the row takes the server's id, its search entry moves to that id, and an
agent delete reaches that id. A Gmail
save that returns no contained message id leaves the placeholder, which an agent
delete reports pending. An Outlook re-save onto a server row the Drafts sync had
already listed drops the placeholder row, its cached body and its search entry,
and an agent delete reaches the server id. When the re-keyed row cannot be
written, the draft records no server copy (the save and the re-key are one
write), and the retry lands both.

On the demo account the mailbox is the local database and nothing ever replaces
a placeholder, so `DemoProvider` is the one provider that can act on one
(`EmailProvider.placeholderIdsAreAddressable`). With the real `DemoProvider`, the
Sent copy of a demo send can be marked unread, flagged and deleted, and a saved
demo draft's row can be deleted.

## Server-draft dismissal UI

`TabMailScreenshots/ServerDraftCloseUITests.swift` runs in the existing
`TabMailScreenshots` UI-test scheme. Its six cases cover unavailable and failed
resolution in full-screen, pushed, and collapsed detail-column presentations.
The Debug fixture seeds disposable account, folder, and header rows and mounts the
production `MailNavigationView`. Cover cases tap the real Drafts row; push and detail
cases emit the existing email-pill and notification input events. No substitute
navigation stack or cover owns the loader. Each opens and closes twice, checks the
real mailbox is usable, and checks that the fixture rows remain intact. Failure
cases also verify that Try Again invokes the injected dependency again. The
resolver seam is a Debug-only environment value, defaulting to nil. These are
mailbox-presentation integration tests, not provider-resolution integration tests.

## Dictation upload — one bitstream pinned in two repositories

`FLACEncoderTests.writesTheStreamTheReferenceDecoderWasCheckedAgainst` pins the SHA-256 of the FLAC
stream for a deterministic speech-like signal; TabMail Voice's `apps/desktop/test/flac.test.ts`
pins the same hash for the same signal, which the reference `flac` decoder accepted. The signal is
computed in doubles with JavaScript's rounding so both produce identical samples. A change to either
encoder's choices fails its own suite, and the two apps keep uploading the same bytes. Losslessness
is checked by two independent decoders: `FLACTestDecoder` (every CRC checked) and Core Audio.
`decodesToTheSameSamplesWhateverLengthTheLastFrameIs` sweeps every last-frame length 1–40 and 127,
255, 1001, alone and after a full block, over noise, a tone (a high predictor order) and quiet audio
with a full-scale burst and a step (the largest Rice parameter): each of the encoder's predictor-order,
partition-order and Rice-parameter guards, removed, fails it (a trap or a stream that does not
decode to the samples). The size tests hold digital silence to a few bytes a frame (the constant
subframe) and full-scale audio to its PCM plus a frame's overhead (the verbatim fallback the upload's
size bound rests on).

## Device Sync — labelled bullets, shared with Thunderbird and Voice

`DeviceSyncVectorsTests` runs the conformance vectors Thunderbird and TabMail Voice run too
(`TabMailTests/Fixtures/DeviceSync/device-sync-vectors.json` and the bundled default catalog, both
SHA-256 pinned, so a change to the shared files fails all three suites until each re-pins). Each
scenario runs on simulated devices (`BulletDevices.swift`): every device runs the real `PromptBulletSync`,
`BulletSync`, `Bullets` and `UserDefaultsBulletStore` on its own `UserDefaults` suite, connected through a
relay the scenario delivers, reorders or drops. `DeviceSyncFuzzTests` runs seeded random devices, edits,
resets, failed saves, restores and deliveries, and asserts at every delivery that no bullet a user did not
delete is lost, at the end that the devices converge and stop sending, and that no message exceeds the
relay's budget (8 seeds by default; `DEVICE_SYNC_FUZZ_SEEDS` sets more, 30 pass).

`PromptSemaphoreTests` covers the prompt store's one semaphore: a hold is released when its body
returns, throws or is cancelled; a hold past its lease loses it, hands the semaphore on and does not move
the counter; a call made inside a hold, and from a child task of the holder, is refused as busy at once; a
task created under the cleared mark waits instead; waiters take the semaphore in the order they asked, a
request made as the holder releases queues behind the line, a cancelled waiter and one past its wait leave
the line and are never granted. `PromptStoreBoundaryTests` pins the AI write (read, call holding nothing,
write carrying the counter) being dropped after a local edit, a reset, a restore or a lapsed lease, with
the stored state, the rendered text and the history unchanged; the counter moving only on a saved change;
a hung model call blocking nothing; and the two gesture-order inversions (delete then add, add then
delete) ending as the user's last gesture. `DeviceSyncReceiveTests` covers arrival order with the busy
re-apply, the connection end dropping everything waiting, the bound (messages plus held parts) renewing
the connection, and an older `prompt_state` never landing on a newer edit. `DeviceSyncSocketBoundaryTests`
runs a loopback WebSocket server to show a message read after its connection was replaced is dropped.

## Gmail thread binding — Send and draft uploads

Gmail files a message or draft in a conversation only when the request's `message` resource names the
`threadId`, the raw message's In-Reply-To/References name the parent, and the Subject matches.
`GmailSendBodyTests` covers the Send body. `GmailReplyDraftThreadTests` drives production
`DraftStore.pushDraftToServer` against a real `GmailProvider` on `FakeHTTP` and reads both
`drafts.create` and `drafts.update` off the wire: each carries the `threadId` that
`ThreadUtils.outgoingThreadHeaders` gives Send for the same reply (the parent's id for a matching
subject, none for a changed one) beside the headers that name the parent. A reply draft saved in a
different Gmail account than its parent sends no `threadId` on either request, as Send from that
account would not, and still names the parent in its headers. Both cases run with and without a
stored attachment, so the multipart upload is held to the same binding and keeps the body and the
attachment bytes.

## Gmail history pages and the delta work bound

`GmailHistoryPaginationTests` drives production `SyncEngine.performDeltaSync` end to end against a
real `GmailProvider` on `FakeHTTP`. The property: the Gmail delta applies every history record after
the stored cursor before the cursor moves, and never moves it past a page it did not read. Covered:
every page applied with the first page's `historyId` as the cursor and the page token percent-encoded
on the wire; each of three page requests carrying the original query, a `maxResults` Gmail accepts and
only the current page token; a deletion on a later page applied (the deleted row removed, a bystander
kept, a message added then deleted never fetched or kept); a later page that fails (error status,
transport failure, cancellation, or a 200 whose body is not a history page) applies nothing and keeps
the cursor; a later-page 404 and a history past the page limit clear the cursor for the full sync. The
work bound, which stops a delta from committing to more message GETs than the sync deadline can
carry: the record budget on its own (records that name nothing to fetch), and the distinct-message
budget for every record kind that makes the delta fetch a message, on one page and across pages,
each at exactly the budget (applied) and one past it (no GET, cursor cleared); a message named by two records on different pages counts once. A page without
`history`, Gmail's answer to a quiet poll, is an empty delta that moves the cursor.

## Gmail search text on the wire

`GmailProviderMockTests.searchTextReachesGmailIntact` decodes the recorded
search request the way Gmail reads a query string (`&` separates parameters,
`=` splits name from value, `+` is a space) and asserts that the user's text,
including `&`, `+`, `=`, `%`, `#`, non-ASCII characters, literal percent escapes
such as `%26` (which must not be decoded first) and a `from:` address with a `+`
tag, comes back as exactly one `q`, with no stray parameter. Search text holding
the synthetic All Mail marker is sent as typed: `GmailProviderMockTests.syntheticFolderGuard`
asserts the guard refuses the marker in the path and in folder parameters such as
`labelIds`, and never in `q`.

## Delta detail fetches — a failed fetch is never taken for a deleted message

`DeltaDetailFetchFailureTests` drives production `SyncEngine.performDeltaSync` end to end on
`FakeHTTP` for Gmail and Outlook, whose deltas fetch each changed message by id. A message whose
fetch fails (a 5xx, a non-gone 4xx, a transport failure, a body that does not decode, a 200 whose
record has no usable date) fails the delta and keeps the cursor (the Gmail history id, the Outlook delta link); on the next pass the
fetch succeeds and the change lands. A message that answers 404 is gone and is skipped: the rest of
the delta is applied and the cursor moves. A Graph refusal on the detail fetch is still logged with
its error code and message. Called directly with the gone message first (404 or 410), the detail fetch still
returns the readable one. Through the foreground poll `SyncEngine.sync(account:)` on a registered
work queue, with a full sync due, a Gmail message whose fetch never succeeds does not stop sync: the
full sync completes past it (its row kept), the capture moves the cursor, and on the next ordinary
poll (no full sync due) the delta lands later changes. A dropped connection, a 401 the token refresh does not cure, or a cancellation
during the rate-limit backoff still fails that folder's fetch. On Outlook, a message whose fetch
never succeeds is bounded by the poll's cursor capture after its full sync, which walks the inbox's
delta pages to the final link; the next ordinary poll's delta from that link lands what changed after
it.

## Google Calendar search text and OAuth token bodies on the wire

`GoogleCalendarSearchEncodingTests.searchTextReachesGoogleCalendarIntact`
decodes the recorded `listEvents` request the same way and asserts that the
event search text (with `&`, `+`, `=`, `%`, `#`, non-ASCII characters and
literal percent escapes) comes back as exactly one `q`, with no stray parameter.
`OAuthTokenRequestTests` builds the Google and Microsoft code-exchange and
refresh requests and reads each body as a form, asserting that a code,
verifier or refresh token holding `+`, `&`, `=`, `/` or a literal `%2B` arrives
exactly as given, every field appears once, and the endpoint, method and
content type are the token endpoint's. The same suite drives the four real
sign-in and refresh calls (`OAuthService` with a fake token transport) and
asserts each sends its own grant, once, to its own provider's endpoint.
`GmailProviderExactDraftResourceTests` serves a later drafts page only for the
exact page token it issued (one holding `+`, `/`, `=`, `&` and a space) and
reads the second request's query as a form. `CredentialRefreshContractTests` reads
the notification extension's refresh body the same way, with a grant holding
`+`, `&`, `=` and `/`. All four use `FormDecoding` (test helper). Every one of
these values, and Graph ids and search text, Gmail search and the Gmail
drafts.list and history.list page tokens, is encoded by the single
`StrictPercentEncoding` in `Shared/HTTP`. A synthetic folder marker that reaches
the bad-request-preserving entry (`modifyMessage`) is refused before any network
call, as at the ordinary request entry.

## Gmail older-mail paging — one failed message does not stop the page

`GmailOlderPageFailureTests` drives `GmailProvider.fetchOlderMessagesWithCoverage` on `FakeHTTP`. A
page where messages answer 404, 410, 400, 503 and an unreadable body still loads every other
message, reports those five as named but not loaded, and counts the whole page as covered. A 401
the token refresh does not cure, or a dropped connection, still fails the page, and so does a page
cancelled while a message waits out the rate-limit backoff: it never reports coverage and asks for
nothing more. Through the real caller, `GmailReceivedDateBoundaryTests` pulls older mail with
`SyncEngine.fetchOlderMessages` the way the scroller does: a full page with one message Gmail cannot
serve still says there may be more, so the next pull loads the message beyond it, the unreadable
message gets no row, and the stored rows stay.

## On-demand folder sync — a folder the provider reports gone

`FolderSyncGoneStatusTests` drives `AccountManager.syncFolders(_:)` over two folders of one account
whose provider throws the Gmail and Outlook HTTP error shape (`ProviderError.networkError` around
`HTTPError.networkError(statusCode:)`). A 404 or 410 skips the folder: no error reaches the caller
and the next folder is still synced. Any other status (500) still reaches the caller.

## Gmail label create — a name Gmail already has

`UserLabelCreateExistingNameTests` creates a label through `UserLabelMenuModel.createAndApply(name:)`
against `StatefulGmailActionServer`, which answers 409 "Label name exists or conflicts" when a user
label with that name (compared without case) exists. A name Gmail already has applies Gmail's
existing label: the gesture succeeds, Gmail is asked to add that label's id, the stored row and the
menu entry carry Gmail's spelling of the name, and a label already in the menu, under an older name, is
listed once under Gmail's name. A 409 for a name the label listing no longer has (deleted elsewhere in
between) fails the gesture and writes nothing: no label row, no menu entry, no queued label change. A
create that fails with any other status (a 500) is refused the same way and writes nothing, even
though Gmail lists a label by that name, so only the 409 leads to the lookup. A
free name still creates and applies a new label. The 409 is read through `httpStatus(of:)`; a check of the
bridged `NSError` code on the thrown error never sees the HTTP status.

## Plan picker — no in-app purchase while a web subscription is live

`WebSubscriptionGateTests` decodes `/whoami` bodies through the real `AccountInfo` parser. A web
subscription that is active, trialing, past due, cancelled but not yet ended, unpaid, incomplete,
paused, or has no status counts as live, and `PlanPickerView.webManagedNote(for:)` then returns the
one plain sentence that replaces the purchase options. An ended or never-completed web subscription,
an Apple subscription, a signup trial (running or ended), no subscription, and an account not yet
loaded all leave the plans on sale. A status the app does not know counts as live.
`viewHidesEveryPurchaseOptionBehindTheGate` reads the view's source (a hosted `PlanPickerView`
fetches its own account) and pins the two gates: the billing toggle, plan cards, footnotes and Apple
disclosure sit in the `else` of the sentence, Restore Purchases sits inside its own gate, and Cancel /
Manage Subscription sits outside both.

## Draft placeholders and the Drafts sync window

`DraftPlaceholderStaleWindowTests` saves a draft through `AccountManager.queueDraftSave`, lets that
save land with no server address, re-saves it ten days later, and then runs the production sync
merge over a full Drafts page whose oldest draft is newer than the first save but older than the
latest one. The placeholder is not on the page and its latest save is inside it, so sync removes it
and the draft is not shown twice. The second case leaves the latest save queued: the same sync keeps
the placeholder, because the queued save names it, and the sync after that save lands removes it.

## Recurring series split — the new series' end

`RecurrenceTailCountTests` checks `RecurrenceTail.occurrences` against the worked examples of
RFC 5545 §3.8.5.3, whose occurrence lists are the oracle (the expected counts were also checked
against python-dateutil), plus the edges the RFC states in prose and every rule shape the counter
refuses, including INTERVAL above `RecurrenceTail.maxInterval` and BY values of `Int.min`, which would
otherwise overflow or trap. `RecurrenceTailNewSeriesRuleTests` covers the rule a split's new series
gets: COUNT reduced in place, a used-up or uncountable COUNT refused (the message names unreadable
dates or the uncountable rule, whichever it was), an UNTIL at or after the split kept, one before it
refused, a DATE UNTIL covering its whole day, and an UNTIL equal to the split's own cap read as a
retry. `GoogleSplitSeriesTailTests` and `CalDAVSplitSeriesTailTests` drive the real providers on
`FakeHTTP` with a series zoned to Pacific/Auckland at 07:00 and the split declared in UTC, so a rule
read in the wrong frame counts other weekdays. A refused split sends no write: Google sends only the
master GET, and CalDAV sends no PUT.

## Outlook sends carry the Outbox's Message-ID

`ExchangeSentMessageIdTests` reads the requests `ExchangeProvider.send` makes on `FakeHTTP`. The
Outbox keys its optimistic Sent row by the Message-ID it generated, and sync replaces that row only
with a Sent Items copy whose `internetMessageId` matches; Graph answers a send with no id of its own.
A send without files asks `sendMail` for that id as the message's `internetMessageId`, in angle
brackets whether or not the stored id has them, and it normalizes to the key the row holds. A send
with files creates its draft carrying the id, then sends that draft. A reply, on either route, carries
the id together with In-Reply-To (`String 0x1042`) and References (`String 0x1039`) and no other
extended property. A draft save (create and update) does not set the id: `DraftStore` gives every
save a fresh one, and a Message-ID once set should stay constant. `ExchangeOutboxSentMessageIdTests`
drives the real Outbox send (`sendClaimedOutboxMessageForTesting`) for an Outlook account over
`FakeHTTP`, on both routes, and checks that the id Graph is asked for, the optimistic Sent row's key
and the claim's `sentMessageId` are one id. Its refusal case runs the real claim and send three times
while Graph refuses the send at `sendMail`, at the files route's draft create, or at its `/send`: every
claim reuses the first claim's id, every attempt asks Graph for it, each refusal is counted, the row
is shown as failed after the third, it is never marked sent, and no Sent row is written.

## Agent tool arguments — whole numbers

`ToolArgumentWholeNumberTests` covers `JSONValue.wholeNumber`, the one way a tool reads an integer
argument. A JSON number `Int` cannot hold decodes as `.double`, so the accessor accepts an `.int`
or a `.double` holding a whole number in `Int`'s range, and nothing else. It then drives every tool
that reads an integer argument with values outside `Int` either way and with a fraction: the
message tools' `unique_id`, `EmailDeleteTool.parseUniqueIds`, the settings value, the template id,
the contact-search `limit` and the calendar-search `page_index`. Each one refuses the value rather
than truncating it. The calendar-search reply for the largest page is checked too. The recurrence
`interval` and `count` must be whole numbers of 1 or more: the event builder throws on anything
else, and calendar create and edit refuse it before the confirmation card. A source check fails if
a new `.double` binding appears under `Services/AI` or `Services/Account`, the one allowed being
the PDF tool's page number, which is bounded before it converts. `CalendarQueueArgumentValidationTests`
stores a create and an edit carrying such a count, as an earlier build could have queued them. The
drain retires each one with its reason and sends nothing to the provider. `MemoryReadToolTests`
refuses a `timestamp` that is not a whole number (including `"1e300"`, `"nan"` and a fraction) and
answers whole numbers at the ends of `Int`, with tolerances whose window edge falls past Int64's
range, by leaving that side of the window unbounded; `MemoryIndexTests` reads a turn with no session
through a window whose upper or lower edge falls past that range. The delete tests check that a fractional id
in `unique_ids` is dropped, not truncated.

## CalDAV series edits — moving a series' time

`CalDAVSeriesStartShiftTests` checks what an edit that moves a repeating
CalDAV series' start does to the values tied to that start. `SeriesOracle`
reads a weekly series independently of the code under test (occurrences on
the wall clock from `DTSTART`, cut by `UNTIL` or `COUNT`, matched against
`EXDATE` and each override's `RECURRENCE-ID` as instants), and each move must
keep every occurrence in the same state: deleted, changed, or shown, the last
one included. Cases cover a same-day time change, a one-week move across a
daylight-saving change, values a server stored in UTC, all-day and floating
series, an RRULE the edit writes itself, `RDATE` and `PERIOD` values, a
folded `EXDATE`, and a zone the device does not know (moved on the wall clock
when no conversion is needed, refused when one is).
`CalDAVSeriesStartShiftWireTests` drives the same through `updateEvent` over
the fake CalDAV store: a movable series lands whole in one `PUT`; an
unmovable one is refused with no `PUT` and the server keeps the original.

## Calendar edits keep the event's kind

`CalendarEditKeepsKindTests.swift` drains real `.edit` rows through `AccountManager.drainCalendarQueue`.
An edit that leaves `all_day` out keeps the event's kind: an all-day event given new dates stays all-day on
those dates (a time of day in them is dropped), a start alone carries the end by whole days, and a timed
event given a date alone stays timed at midnight. A stated `all_day` changes the kind either way. The Google
and Outlook suites run the providers against stateful fakes on `FakeHTTP` (PATCH replaces the properties it
names) and assert on the stored event, for a single event, one occurrence and, on Google, a split's new
series. The CalDAV suite asserts on the stored `.ics`: a move lands as `VALUE=DATE` lines, and a split's new
series starts on the date given; a start given alone moves `DTEND` with it, so an all-day event keeps its
days and a timed one its length across the March daylight-saving change. `CalDAVSeriesStartShiftTests` checks
the same on the merge alone, plus a `DTEND` in another zone from `DTSTART`, a `DURATION` master (no `DTEND`
added), an end the patch gives (written as given, even over a `DTEND` that could not be moved), and a `DTEND`
that cannot be read or converted (refused). An all-day edit whose end date is on or before its start date is
refused before any write on every `edit_scope`, including a split's cap `PUT`, and retired with the reason.
An end given alone is compared with the start the edit keeps: the stored start (a timed one's date included)
on `all`, the occurrence's own date on `this_only` and `this_and_following`; a start the edit gives is what the
end is compared with on every scope. An edit that gives no times
still saves an all-day event stored with its end on its start. The queue suite counts
`getEvent` calls: an edit that moves nothing and sets no UNTIL makes none, and a failed read on a move writes
nothing and stays queued. `calendar_event_edit` refuses a stated `all_day: true` with a same-day end before
its card, and does not refuse times of one day when `all_day` is not stated.
