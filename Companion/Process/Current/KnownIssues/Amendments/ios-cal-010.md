# IOS-CAL-010

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-12) — live in the shipped release, and DEFERRED by owner decision the same
day.** The attachment row offers the native add-to-calendar affordance for **every**
`text/calendar` part, deciding on the MIME type alone and never consulting the iTIP `METHOD`. For
`REPLY`, `COUNTER`, `DECLINECOUNTER` and `REFRESH` that starts a flow which cannot succeed and
which, by the mechanism's design, reports nothing. The owner has characterised the result as a UX
problem rather than a defect and has explicitly declined the work for now.

## Subsystem and search terms

`AttachmentListView`; `downloadAndImportICS`; `visibleAttachments`; `text/calendar`;
`contentType.lowercased().contains`; iTIP `METHOD`; `REPLY`; `COUNTER`; `DECLINECOUNTER`;
`REFRESH`; `ICSBuilder.parseIncoming`; `ICSBuilder.buildIncomingInviteBody`;
`ICSBuilder.ParsedInvite`; `ICSBuilder.parseParticipant`; `PARTSTAT`; `RECURRENCE-ID`;
`BodyRenderer.render`; `icsRenderer`; `tm-ics-collapsible`; `tm-ics-invite`;
`IMAPFetchMapping.renderBody`; `BodyFetchProcessor.renderBody`; `hasUnresolvedICS`;
`ICSCalendarImporter.itipFingerprint`; unfold; RFC 5545 §3.1; `NWListener`; `requiredLocalEndpoint`;
`stateUpdateHandler`; `IOS-CAL-011` sibling

## Full detail

**The defect.** The `text/calendar` branch of the attachment button in `AttachmentListView.body`
tests only `attachment.contentType.lowercased().contains("text/calendar")` before dispatching to
`AttachmentListView.downloadAndImportICS`. Nothing on that path reads the iTIP `METHOD`. Since the
system import path is add-only (`IOS-CAL-011`), the affordance is offered for four iTIP methods it
can never satisfy, and the user's tap produces no event, no message and no log line.

## Known-good fix direction — recorded so a future session does not re-derive it

**The discriminator already exists in the tree.** `ICSBuilder.parseIncoming` extracts the
calendar-level `METHOD` into `ICSBuilder.ParsedInvite.method`, and
`ICSBuilder.buildIncomingInviteBody` already branches on it — rendering `REPLY` as
"has responded to" and `CANCEL` as "has cancelled". Both arms are covered by passing tests. The
tap path simply never asks.

**`buildIncomingInviteBody` is on the inbound DISPLAY path — it is NOT dead code for received
mail.** Two wiring sites build the same `ICSBuilder`-backed closure, whose output
`BodyRenderer.render` appends to the body as `<div class="tm-ics-collapsible">`:
`IMAPFetchMapping.renderBody` (shared with the notification extension's IMAP client) and
`BodyFetchProcessor.renderBody` (main app, provider-agnostic; both of its call sites supply an
attachment fetcher). Verified live, not only by reading: the working first-time invite in the
device log rendered a real invite card.

⚠️ **But showing the responder's status is strictly larger than gating the tap, and this is what
sizes the work.** `ICSBuilder.ParsedInvite.attendees` is typed `[(name: String, email: String)]`
and `ICSBuilder.parseParticipant` returns that same pair, extracting only `CN` and the `mailto:`
address — so **`PARTSTAT` is discarded at parse time**; `ParsedInvite` carries no `RECURRENCE-ID`
field either. (The only `PARTSTAT` in `ICSBuilder` is in the **outbound** builder, which emits
`PARTSTAT=NEEDS-ACTION` when generating an invite; nothing reads it on the inbound side.) A `REPLY`
card therefore reads "*someone* has responded to *event*" and lists the attendee, without
accepted/declined/tentative and without which occurrence responded. Rendering the response means
extending `ParsedInvite`, `parseParticipant` and `buildIncomingInviteBody` — no new view, no new
model type, no migration. `ICSParser` already reads `PARTSTAT` via
`ICSParser.extractParam(line, name: "PARTSTAT")`, but it belongs to the CalDAV/calendar-provider
path and must not be reached across that boundary.
**Per ADR-IOS-052, do not answer this by applying the object provider-side** — that alternative is
already weighed and rejected.

## An open LEAD, deliberately not stated as a cause

In the device log the invite card did not render **at all** for the `REPLY` message, so a
`PARTSTAT`-bearing card would not by itself have shown the owner anything. What is established:
`parseIncoming` cannot have returned nil (it returns nil only when no `BEGIN:VEVENT` line exists,
and the payload had one); `FullMessageInfo.icsData` is populated in exactly **two** places, **both
IMAP**, and defaults to nil everywhere else; and the notification extension's non-IMAP clients
call `GmailAPI.messageFull` / `GraphAPI.messageFull` with **neither** an attachment fetcher **nor**
an `icsRenderer`, while those functions construct their ingredients with `icsData: nil` — so
`BodyRenderer`'s `mustResolveOnDemand` is false, no card is produced, `hasUnresolvedICS` stays
false, and the body persists looking complete. `hasUnresolvedICS` has no consumer that would
re-render such a body.

**What was NOT established:** that this particular message's stored body came from the extension
rather than a main-app fetch, and whether `MessageDetailViewModel.refetchBody` would have
re-rendered it. The mechanism is therefore **reachable by construction but unconfirmed as this
message's history** — recorded as a lead with its predicate, not as a cause (`MIS-032`). A related
inference to re-derive rather than trust: the account was read as non-IMAP from folder-name casing
in a single log line, not from a provider field.

## Instrument fix owed before any UID-comparing re-test — ✅ FIXED 2026-08-13

`ICSCalendarImporter.itipFingerprint` splits on newlines without unfolding RFC 5545 line folding
(§3.1), so it reports only a folded value's first physical line. One byte-identical payload in the
device log logged its `UID` length as differing by one between raw and sanitized purely because
the sanitizer re-folds one octet earlier — nothing was removed, and identical total sizes prove it.
The instrument exists to compare a `UID` across two taps, so normalize CRLF and bare CR to LF, then
remove LF+SPACE/LF+HTAB continuations before splitting, matching `ICSSanitizer.unfold`. Debug-gated,
no import behaviour change.

✅ **Done 2026-08-13, then completed for every accepted line ending in the correction round.** The
first fix handled CRLF/LF continuations. Review found that bare-CR folds still disagreed with
`ICSSanitizer.unfold`, so the diagnostic now normalizes CRLF and bare CR to LF before removing
continuations, splitting, or trimming. **The ORDER remains the point:** the fold marker is leading
SPACE/HTAB and must be consumed before per-line trim destroys it.

The reported numbers were both **fold widths**, and that is worth keeping because it made a
byte-for-byte no-op look like corruption: `ICSSanitizerConfig.physicalLineOctetLimit` is 75 and
`foldWidthOctets` is 74, so the log's `(len 71)` is 75 − `"UID:".count` (the SENDER's fold width)
and `(len 70)` is 74 − `"UID:".count` (ours). The `UID`'s true length was never measured on either
line.

Four tests in `ICSCalendarImporterFingerprintTests` pin the invariant *a folded value's parsed
length equals its unfolded TRUE length*: one folds a 120-character `UID` at 75 and at 74 and
requires 120 both times (red pre-fix at 71 and 70 respectively, the exact device-log pair); one
pins the same ordering defect on the COUNT axis, where a folded continuation beginning `ATTENDEE:`
was trimmed into a second attendee (red pre-fix at `ATTENDEE=2`); one negative control asserts
an unfolded payload is unperturbed; and one uses bare CR for both a 90-byte UID fold and a forged
ATTENDEE continuation (red at UID length 45 and `ATTENDEE=2`). `itipFingerprint` dropped `private` for this; its only
production caller is still the debug-gated pair in `presentCalendarImport`.

⚠️ **Build status of the instrumentation, corrected.** A draft of this record stated that the commit
introducing `itipFingerprint` had never been compiled. **That was wrong, and wrong twice over:** the
commit is an ancestor of a later commit whose full-suite build compiled `ICSCalendarImporter.swift`
byte-identically (verified by an empty `git diff` between the two for that path), and the device log
analysed here *contains `itipFingerprint`'s own output*, which is only possible if the code compiled
and ran on the device. The claim survived several restatements because nobody re-checked it against
evidence already in hand — `MIS-032` shape, and the reason it is recorded here rather than silently
dropped.

## Related but separate — a code defect carried here so it is not lost

`930ed7883` ("Bind the ICS invite listener to loopback") moved the listener's port from
`NWListener(using:on:)` into `params.requiredLocalEndpoint` with `NWListener(using:)`. The inner
`catch`'s random-port retry can no longer fire for a port conflict, because the bind now surfaces
asynchronously as `.failed` in `stateUpdateHandler`, which calls `stop()` and **never invokes
`completion(port)`**. If the port is occupied, ICS import does nothing, silently.

⚠️ **The silence is PRE-EXISTING, not introduced by that commit** —
`git show v1.7.8:TabMail/Services/ICSCalendarImporter.swift` has a byte-identical
`stateUpdateHandler` (`completion(port)` on `.ready` only; `.failed` → log → `stop()`). What the
commit could have changed is narrower: whether a conflict was ever reachable as a *synchronous*
throw. That turns on whether `NWListener(using:on:)` reserves the port at init while the
`using:`-only form defers it, which **cannot be settled by reading source** and needs a runtime
check (occupy the port from another process, tap an invite, and see whether the random-port retry
ever logs).

**Not implicated by the 2026-08-12 device evidence** — every listener-failure marker occurs zero
times in that log and the listener bound on its preferred port all three times. This is a fix item,
not an accepted limitation: keep the loopback scoping and handle `.failed` by retrying once on
`.any`, still loopback-scoped, which restores shipped intent rather than adding a fallback routine
(global rule 4). **Surfacing a user-visible error is a behaviour change and is out of scope without
the owner's say-so.**

⚠️ **PARTIALLY FIXED 2026-08-13 — the DROPPED-CALLER half only; the port-conflict retry is still
open.** `ICSCalendarImporter.Server.start` now takes `@Sendable (UInt16?) -> Void` and routes every
resolution through a `Mutex`-guarded single-shot `resolve(_:_:)`, so each of the listener's terminal
states answers the caller exactly once: `.ready` with the port (or `nil` if it reports none),
`.failed` with `nil`, `.cancelled` with `nil`, and both pre-`start` failure paths with `nil`. The
caller's `nil` arm releases the dead server from `activeServer` instead of parking it there until
the next tap. Two directions closed at once — the completion could previously fire ZERO times (the
silence described above) and, because `.ready` can recur via `.waiting`, more than once, which would
have presented Safari twice for one tap.

**Correction-round hardening:** the anomalous `.ready`-without-port arm now calls `stop()` before
resolving `nil`. Without that explicit stop, clearing `activeServer` could leave the listener retained
by its handler cycle until the two-minute timer, while teardown no longer had a reference to it.

**Deliberately NOT done: the retry on `.any` this record prescribes above.** That would make ICS
import start working where it currently does nothing, which is a user-visible behaviour change and
needs the owner's say-so, exactly as the paragraph above says of the error surface. So a port
conflict still ends in silence — it is now an *observable* silence with a debug-gated line at both
the listener and the caller, rather than a dropped closure. The open runtime question is also
unchanged: whether `NWListener(using:on:)` reserved the port at init while the `using:`-only form
defers it cannot be settled by reading source, and needs the occupy-the-port experiment.

No test: `Server` is a private class driving a real `NWListener` and `SFSafariViewController` from
`beginPresentation`, with no seam a unit test can reach, and extracting one is the restructuring
this fix was scoped to avoid.

## Explicitly UNANSWERED

Whether a genuine `METHOD=REQUEST` update works was **never tested** — see `IOS-CAL-011`. Nothing
in this record should be read as having exercised the update case.
