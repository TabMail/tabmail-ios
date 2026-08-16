# IOS-CAL-010

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🛠️ **FIX CANDIDATE (2026-08-16) — invariant RED/GREEN and a real iOS 26.5 system-import
matrix are complete; still OPEN in a draft PR pending fresh-context exact-diff review and final
owner approval.** The owner lifted the prior "for now" deferral for this bounded gate. The candidate
fetches the attachment as before, uses
`ICSBuilder.parseIncoming` to refuse exactly `REPLY`, `COUNTER`, `DECLINECOUNTER` and `REFRESH`,
and puts a neutral explanation in `AttachmentListView`'s existing visible error surface instead
of dispatching those payloads into the partial system import flow. It adds no provider parsing,
fallback, listener behavior, sanitizer behavior, or SwiftMail-fork deviation.

**Prior disposition, preserved:** on 2026-08-12 the owner characterised the result as a UX problem
rather than a defect and explicitly declined the work for then. At that point the row offered the
native add-to-calendar affordance for every surfaced `text/calendar` attachment, deciding on MIME
type alone and never consulting `METHOD`; the four response/control methods above therefore
entered a flow that could neither apply them nor explain its no-op.

## Candidate invariant and accepted residuals

- The denylist is exactly `REPLY`, `REFRESH`, `COUNTER`, `DECLINECOUNTER`; method values, the
  RFC-case-insensitive `METHOD` property name, and `BEGIN/END:VEVENT` boundaries are normalized
  by the shared parser.
- `REQUEST`, missing `METHOD`, `PUBLISH`, `ADD`, `CANCEL`, unknown values, non-UTF-8 data, empty
  input and a calendar with no `VEVENT` fail open to the existing importer. Removing a legitimate
  import is the expensive failure direction; an uncertain allow leaves the decision to Calendar.
  `CANCEL` is deliberately allowed: a matching UID produces Update/Remove choices and stores a
  cancelled event, while an unknown UID offers a user-mediated cancelled placeholder.
- `METHOD` after the first `END:VEVENT` remains allowed because `parseIncoming` stops at the first
  event and defaults to `REQUEST`. Changing that shared display parser for an unobserved ordering
  is outside this issue; the policy test pins the residual explicitly.
- A future production caller that invokes `presentCalendarImport` directly could bypass this tap
  gate. The importer header now tells mail-attachment callers to consult the policy first; the
  current census still finds one production attachment caller.
- `IOS-CAL-011` remains accepted but its platform description is corrected by the 2026-08-16
  matrix: the system importer is partial, not uniformly add-only. A genuine same-UID,
  higher-`SEQUENCE` `REQUEST` was recognized and offered Update Event, but accepting it left the
  stored original unchanged. The open listener
  port-conflict retry, sanitizer-scope item, provider-side invite-card lead, and filename-less
  Gmail/Exchange row asymmetry are not closed by this candidate.

## Candidate validation evidence

- **RED:** on the documented two-line re-break (policy always permits; tap presents
  unconditionally), binary diff SHA-256
  `dc03374cd5c574ab1a2229203b73dc7851deeb8cec0ce54e1c99eada083b1d6d`, xcodebuild exited 65
  with 5 selected tests: 3 passed and exactly 2 failed — the denied-method policy at
  `METHOD:REPLY` and the production wiring at zero policy calls. Artifact:
  `/private/tmp/tabmail-campaign-results/issue5-red-authoritative.xcresult`.
- **GREEN:** exact code/test commit `9226608a0f80160d24fc64b31dffcade1d390992` exited 0 with
  `TEST SUCCEEDED`: the same 5 tests all passed, with no failure, skip, or expected failure.
  Artifact: `/private/tmp/tabmail-campaign-results/issue5-green-authoritative.xcresult`.
- **REFRESHED GREEN:** after rebasing onto current `main` and correcting the platform record, the
  exact five-test suite rebuilt successfully and passed 5/5 again, including lower- and mixed-case
  `METHOD` property-name plus mixed-case `VEVENT` boundary witnesses added during exact review.
  Artifact: `/private/tmp/tabmail-campaign-results/issue5-final-green-r3-20260816.xcresult`.
- Coverage reports `ICSCalendarImporter.allowsAddToCalendar(_:)` at 100% (12/12). The
  `AttachmentListView` branch is deliberately pinned by the non-vacuous source-structural test;
  the focused suite does not pretend to drive its UIKit/network attachment tap at runtime.
- **Real system-import matrix (iOS 26.5 simulator, 2026-08-16):** temporary probes drove the exact
  production `ICSCalendarImporter` loopback-listener + hidden-`SFSafariViewController` handoff, and
  Calendar storage was checked after each action. A new `REQUEST` added one event; a same-UID,
  higher-sequence `REQUEST` offered Update Event but left the original unchanged; matching `CANCEL`
  offered Update/Remove and stored cancelled status; unknown `CANCEL` offered Add and created a
  cancelled placeholder when accepted; `REPLY`, `REFRESH`, and isolated `COUNTER` produced no
  Calendar action and no event; `DECLINECOUNTER` incorrectly offered Add and created a normal
  standalone event when accepted. The last result is the strongest sensitivity witness for the
  gate. The test build and every evidence-bearing isolated probe exited 0; result bundles are under
  `/tmp/tabmail-issue5-system-probe-dd/Logs/Test/`. The temporary probes were removed, the branch
  was restored clean, and test events were removed through Calendar (zero active probe
  occurrences). The owner judged this investigation conclusive; first-party Mail parity is not a
  remaining gate.
- Claude's exact-diff runner remains quota-blocked until 2026-08-18, so the owner-directed interim
  gate is a fresh-context subagent review of the refreshed exact diff. The draft PR and issue stay
  open until that review is reconciled and the owner approves the final diff; do not merge this
  behavioral change automatically.

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
system import path implements only part of iTIP (`IOS-CAL-011`), the affordance is offered for four
methods it cannot safely satisfy: `REPLY`, `REFRESH`, and `COUNTER` silently no-op, while
`DECLINECOUNTER` is misread as a new event and offered for addition. The user receives no TabMail
explanation in either direction.

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
attachment fetcher). Synthetic renderer tests exercise the inbound invite-card path.

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

Construction also exposes a provider-path lead independent of the tap gate. What is established:
`parseIncoming` cannot have returned nil (it returns nil only when no `BEGIN:VEVENT` line exists,
and the payload had one); `FullMessageInfo.icsData` is populated in exactly **two** places, **both
IMAP**, and defaults to nil everywhere else; and the notification extension's non-IMAP clients
call `GmailAPI.messageFull` / `GraphAPI.messageFull` with **neither** an attachment fetcher **nor**
an `icsRenderer`, while those functions construct their ingredients with `icsData: nil` — so
`BodyRenderer`'s `mustResolveOnDemand` is false, no card is produced, `hasUnresolvedICS` stays
false, and the body persists looking complete. `hasUnresolvedICS` has no consumer that would
re-render such a body.

**What is NOT established:** how often a stored body reaches that path, or whether
`MessageDetailViewModel.refetchBody` would re-render it. The mechanism is therefore reachable by
construction but unconfirmed as a field cause — recorded as a lead with its predicate, not as a
measured owner-message history (`MIS-032`).

## Instrument fix owed before any UID-comparing re-test — ✅ FIXED 2026-08-13

`ICSCalendarImporter.itipFingerprint` split on newlines without unfolding RFC 5545 line folding
(§3.1), so it reported only a folded value's first physical line. A synthetic boundary fixture
reproduces a one-unit apparent mismatch when equivalent payloads use different physical fold widths;
nothing is removed. Normalize CRLF and bare CR to LF, then remove LF+SPACE/LF+HTAB continuations
before splitting, matching `ICSSanitizer.unfold`. Debug-gated, no import behaviour change.

✅ **Done 2026-08-13, then completed for every accepted line ending in the correction round.** The
first fix handled CRLF/LF continuations. Review found that bare-CR folds still disagreed with
`ICSSanitizer.unfold`, so the diagnostic now normalizes CRLF and bare CR to LF before removing
continuations, splitting, or trimming. **The ORDER remains the point:** the fold marker is leading
SPACE/HTAB and must be consumed before per-line trim destroys it.

The apparent values were both **fold widths**, not logical value lengths. The synthetic fixtures use
different physical boundaries to make the byte-for-byte no-op look like corruption and assert the
true unfolded logical length instead.

Four tests in `ICSCalendarImporterFingerprintTests` pin the invariant *a folded value's parsed
length equals its unfolded TRUE length*: one folds a 120-character `UID` at 75 and at 74 and
requires 120 both times; one
pins the same ordering defect on the COUNT axis, where a folded continuation beginning `ATTENDEE:`
was trimmed into a second attendee (red pre-fix at `ATTENDEE=2`); one negative control asserts
an unfolded payload is unperturbed; and one uses bare CR for both a 90-byte UID fold and a forged
ATTENDEE continuation (red at UID length 45 and `ATTENDEE=2`). `itipFingerprint` dropped `private` for this; its only
production caller is still the debug-gated pair in `presentCalendarImport`.

⚠️ **Build status of the instrumentation, corrected.** A draft of this record stated that the commit
introducing `itipFingerprint` had never been compiled. That was wrong: the commit is an ancestor of
a later commit whose full-suite build compiled `ICSCalendarImporter.swift` byte-identically
(verified by an empty `git diff` between the two for that path). The claim survived several
restatements because nobody re-checked it against evidence already in hand — `MIS-032` shape, and
the reason it is recorded here rather than silently dropped.

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

## Genuine REQUEST update — answered 2026-08-16

The simulator matrix seeded a new `REQUEST`, then presented the same UID with higher `SEQUENCE` and
changed summary. Calendar recognized the relationship and offered **Update Event**, proving UID
correlation reached the system UI; after accepting, the stored row retained the original summary
and did not take the new sequence. The path therefore recognizes but does not apply this update in
the measured iOS 26.5 environment. `IOS-CAL-011` carries the platform disposition and scope.
