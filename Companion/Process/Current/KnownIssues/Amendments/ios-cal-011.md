# IOS-CAL-011

- Register classification: `accepted`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-08-12)** — iOS's `text/calendar`-download import path is **add-only**.
It performs no iTIP reconciliation, so it neither applies an iTIP `REPLY` nor updates an event
already on the calendar, and it gives a third-party app no observable signal that it declined.
Attribution is platform, not TabMail.

## Subsystem and search terms

ICS invite import; iTIP; RFC 5546 §3.2.3; `METHOD:REPLY`; `METHOD:REQUEST`; `SEQUENCE`;
`RECURRENCE-ID`; `PARTSTAT`; add-to-calendar; `ICSCalendarImporter`; `presentCalendarImport`;
`SFSafariViewController`; invisible sub-pixel sheet; `.custom { _ in 0.01 }`; `NWListener`;
`text/calendar`; `Shared/ICS/ICSSanitizer.swift`; `ICSBuilder.parseIncoming`;
`buildIncomingInviteBody`; ADR-IOS-052; `IOS-CAL-010` sibling; add-only import path; RSVP

## Full detail

**The symptom.** Tapping a `text/calendar` attachment that carries an iTIP `METHOD:REPLY` adds
nothing, changes nothing, and shows nothing. No error, no alert, no log line indicating failure.

**Why it is correct behaviour for that payload.** Under RFC 5546 §3.2.3 a `REPLY` is an
*attendee → organizer* response whose only defined effect is to set that attendee's `PARTSTAT` on
the organizer's **already-existing** copy of the event. It is not an event-bearing object to add.
The system import path implements adding, not iTIP processing, so there is nothing for it to do.
Where the recipient is also the organizer the event is on the calendar already, so no addition
could apply even in principle. There is no third-party entry point for applying an iTIP `REPLY`.

**Evidence that it is platform behaviour and not ours (anonymized observation, 2026-08-12).**
The same payload produced the same no-op through Apple's first-party Mail client on iOS. That client
reaches the same system import path.
⚠️ **Scope of that claim, stated so it is not widened:** one operating system, one first-party
client, one payload. It establishes **nothing** about macOS, about Apple clients in general, or
about any other platform, and it is an observation rather than an independent reproduction by the
session that wrote this record.

**Independent corroboration for the update case, from published sources rather than our devices.**
Apple Developer Forums thread 772082 (January 2025, still unanswered) reports a spec-correct
update — unchanged `UID`, `SEQUENCE` incremented, refreshed `DTSTAMP` and `LAST-MODIFIED` —
previewing correctly in iOS Safari and then doing nothing when "Add All" is tapped. iOS Calendar's
ICS import is also widely reported to ignore `UID` for deduplication, treating an import as
all-new material.

**Anonymized device traces showed every TabMail-controlled delivery step succeeded.** A synthetic
summary of the comparison is sufficient for the public record: a `METHOD=REQUEST` invite imported,
while a `METHOD=REPLY` response did not; both traversed the same loopback listener, navigation
request, successful HTTP response, and teardown path. Account classes, attendee counts, recurrence
metadata, request counts, and private calendar state are intentionally omitted.

**Four hypotheses refuted from that log, recorded so they are not re-run.**
1. *The sanitizer strips update markers.* `ICSSanitizer.sanitize` was a **byte-for-byte no-op** on
   both payloads (identical input and output sizes) and every fingerprinted iTIP field —
   `METHOD`, `SEQUENCE`, `RECURRENCE-ID`, `STATUS`, `DTSTAMP`, `UID`, `VEVENT`, `ATTENDEE`,
   `ORGANIZER` — matched raw against sanitized.
2. *The one-shot server dies before iOS re-fetches.* One request per attempt, no `HEAD`, no range
   request, and the after-teardown flag false throughout.
3. *The listener's port-conflict / `.failed` path.* Every one of `Listener failed:`,
   `Port … in use, trying random port`, `Failed to create listener:`, the `.failed` diagnostic and
   `No view controller to present from` occurs **zero** times in the log. That path is a separate
   open fix item and is **not implicated by this evidence**; it is described in `IOS-CAL-010`
   § *Related but separate* so it is not lost.
4. *The missing `method=` Content-Type parameter (RFC 6047 §2.1).* We omit it — but we omit it in
   the **working** case too, so it cannot discriminate. It remains a real spec gap and is
   deliberately not fixed: adding it changes wire behaviour on the currently-working `REQUEST`
   path for zero evidence, and on a `REPLY` would only push the platform harder down a path it
   does not implement.

⚠️ **Do NOT re-diagnose this as the invisible sheet.** The deliberately-invisible 0.01-point sheet
having no failure surface is a true observation about the *design* — and it is why the user sees
silence rather than a message — but it is **not the cause**: the working first-time invite in the
same log used the identical sheet. The discriminator is the payload's iTIP role.

## Explicitly UNANSWERED — do not read this record as having tested it

**Whether a genuine `METHOD=REQUEST` update works on our path is still unanswered.** An anonymized
device trace included a non-zero-sequence `METHOD=REQUEST`, so the request-shape half of the re-test
criterion is covered. The public record intentionally omits its byte size, recurrence metadata,
participant counts, and neighboring private invite activity.

**What is genuinely untested is the OTHER half of the criterion: whether that `UID` named an event
already on the device's calendar.** A device log cannot show calendar state, so nothing captured
here settles it in either direction — and that payload imported normally. Thread 772082 remains a
published third-party report, not a measurement on our code. The re-test
therefore stays outstanding, and what it now turns on is a `UID` comparison across two taps, not
another `METHOD`/`SEQUENCE` read-out, which we have.

The `METHOD`/`SEQUENCE` read-out needed **no new build** — the debug-gated fingerprint was already
in the shipped device build, and `METHOD` is a short value never subject to RFC 5545 line folding,
so the folding defect noted in `IOS-CAL-010` never affected it. ⚠️ **The `UID` comparison the
outstanding re-test now turns on is exactly what that defect DID affect**, and it is fixed as of
2026-08-13 — `ICSCalendarImporter.itipFingerprint` unfolds before splitting — so the re-test does
need a build carrying that fix.

## Related but separate

- `IOS-CAL-010` — the affordance is offered for payloads that cannot succeed (ours, open, deferred),
  and it carries the `NWListener` `.failed` fix item and the instrument-unfold fix item.
- **A latent scope error in the sanitizer, not this bug and not fixed.**
  `ICSSanitizer.sanitizeProperty(_:organizerAddress:)` drops the `ATTENDEE` whose address equals
  the `ORGANIZER` — a rule designed for `REQUEST`-shaped invites — and the test is structurally
  incapable of conditioning on `METHOD`, because the function's signature receives no method. In a
  `REPLY` (or `COUNTER` / `DECLINECOUNTER`) whose sole `ATTENDEE` **is** the organizer, i.e. a
  self-RSVP, it would remove the only `ATTENDEE` and yield an object violating RFC 5546 §3.2.3,
  which requires at least one. Currently harmless **only because** the platform discards such
  objects anyway; it becomes real the moment one is routed anywhere else. `MIS-020` shape — a
  heuristic applied past its origin's purpose. Registering rather than fixing: ADR-IOS-052 pins the
  sanitizer's rules with 16 tests.
- ADR-IOS-052 — the presentation-time sanitizer, and the already-rejected provider-side
  alternative.
