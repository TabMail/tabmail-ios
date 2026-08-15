# IOS-COMPOSE-003 — outgoing subject encoded-word conformance: literal syntax and the 75-octet ceiling

**Class:** `open` · **Opened:** 2026-08-12 · **Attribution:** **pre-existing** — not introduced by
`1d28552c1`. The previous non-ASCII-only trigger reached the same code with the same outcome.
**Registered, not fixed** — low-severity display/conformance integrity, not a security issue, and not
minimal to fix. The app behavior is independently actionable; SwiftMail's library twins remain
upstream-only.
Classed `open` rather than `accepted` because these are conformance defects to be closed eventually,
not deliberate limitations. **Scope expanded 2026-08-15** to own the app-side 75-octet ceiling after
the upstream-only `IOS-IMAP-016` tracker was closed as not planned; no defect was fixed by that
reclassification.

## What is wrong — literal encoded-word syntax

RFC 2047 §6.1 recognises a valid encoded-word in an unstructured `*text` body at the field-body start
or immediately after linear whitespace — **not literally anywhere**. The fixture below is nevertheless
in scope because its token is whitespace-delimited: a subject the user typed *as literal text*,
`Re: =?UTF-8?B?SGVsbG8=?= explained`, can be decoded by the recipient and displayed as text the sender
never wrote (here, `Re: Hello explained`).

**All three raw-MIME encoders used by Gmail and IMAP/SMTP let it through unchanged**, because each
triggers only on content the header cannot carry, and such a subject is pure printable ASCII:

Both Gmail MIME builders call the app helper. `IMAPProvider.buildEmail` is the sole SwiftMail `Email`
construction boundary and is shared by SMTP send, Sent append, and IMAP draft save, so no alternate
app construction path or later SMTP sanitizer closes the behavior.

| encoder | trigger | verdict on an encoded-word-shaped ASCII subject |
|---|---|---|
| `RFC2047.encodeHeaderValue` (Gmail builders) | non-ASCII **or** a C0/C1/DEL control | returned unchanged |
| `RFC2047.encodeIfNotEmittableLiterally` (IMAP/SMTP boundary) | a C0/C1/DEL control only | returned unchanged |
| SwiftMail `String.rfc2047EncodedHeader()` | `!$0.isASCII` | returned unchanged |

The conformant app remedy is to protect a valid encoded-word-shaped token when it occurs at an RFC
recognition boundary, so the emitted encoded-word carries the user's literal text and the recipient
reassembles exactly what was typed. A broader `=?` trigger is conservative rather than the RFC's exact
recognition rule and would need its own compatibility justification.

Exchange/Graph receives the subject as structured JSON and constructs MIME server-side. Whether Graph
preserves literal encoded-word spelling is unverified provider behavior; it must not be “fixed” by
pre-encoding the semantic JSON value as though it were a raw header.

## What is wrong — one oversized grapheme can exceed 75 octets

`RFC2047.encodeAsWords` limits a normal encoded-word to 45 UTF-8 bytes, but its loop refuses to split
one Swift `Character`. A single extended grapheme cluster wider than 45 bytes therefore lands alone
in an oversized encoded-word. The first measured breach is `"a"` plus 23 combining marks: 47 UTF-8
bytes become a 76-octet encoded-word; `"a"` plus 22 marks is the last safe boundary at 45 bytes and
72 octets. This app-owned helper is reachable on both Gmail MIME builders. On IMAP/SMTP, the app
passes control-free non-ASCII through to SwiftMail, whose copy of the same algorithm has the same
defect.

The consequence is conformance and display/delivery compatibility, not header injection: Base64's
alphabet cannot end the field. Ordinary orthography does not produce a 46-byte grapheme, so the
trigger needs a pathological combining or ZWJ/tag sequence. The app-side half remains live here even
though the upstream-only twin is retained as a closed decision under `IOS-IMAP-016`.

## Blast radius

**Display fidelity or strict-parser compatibility of one header, in the recipient's client.** Neither
defect can forge a header field, add a recipient, or change the message structure — none of that is
reachable without a control character,
and the control half is already closed on every path (that was `1d28552c1`'s fix). The reverse
direction is symmetric and already handled: our own reader, `RFC5322Parse.decodeRFC2047`, is exactly
the "receiving decoder" that interprets such a subject, so TabMail-to-TabMail shows the effect too.

Worst realistic case: a subject renders as something other than what the sender typed, and a reply
carries the decoded text onward. There is **no app-visible verbatim fallback**: Gmail's read path
decodes RFC 2047 subjects, SwiftMail's IMAP parsing decodes MIME headers, and a successful send deletes
the outbox row after the send/Sent-append workflow completes. This establishes the absence of visible
Sent/readback or retry recovery; it does not claim what raw bytes a server may retain internally.

## Why it is registered rather than fixed

Owner directive, 2026-08-12: *"these fixes … should really be security fixes, minimal — and if it's
not minimal, it's OK to have it into known issues."* This is not a security fix and it is not minimal:
protecting recognition-boundary tokens changes the wire bytes of affected ordinary subjects. The app
can close both behaviors at its Gmail builders and sole SwiftMail `Email` construction boundary;
because that boundary emits ASCII, SwiftMail passes it through without double encoding. The app fix
therefore does **not** wait for or require a SwiftMail change. SwiftMail still needs independent fixes
for other callers on its own merits; those require an upstream PR, not a fork edit, and their evidence
is retained in the closed `IOS-IMAP-016` record.

## When revisited

1. At both Gmail MIME builders and the sole IMAP/SMTP SwiftMail `Email` construction boundary, protect
   valid encoded-word-shaped tokens at RFC recognition boundaries. Do not RFC 2047-encode Exchange's
   semantic Graph JSON subject.
2. Bound every app-emitted encoded-word to 75 octets. Red-first wire-level tests must use
   `"a"` plus 23 combining marks and assert the ceiling on **both** Gmail and IMAP output, with the
   22-mark boundary as the non-vacuity twin; round-trip the field to prove no bytes were dropped.
3. Red-first test: a literal `Re: =?UTF-8?B?SGVsbG8=?= explained` must survive
   `encode → RFC5322Parse.decodeRFC2047` **byte-identically**. Assert the round-trip, not that the
   encoder was called.
4. Non-vacuity twin: an ordinary ASCII subject with no encoded-word-shaped token must still be emitted
   unchanged, so the protection does not start Base64-ing all outbound mail.
5. Take both app conformance defects in the same app round. Separately authorized upstream work must
   close SwiftMail's library defects for its other callers; do not introduce a fork-local deviation.

## Related

- `IOS-IMAP-016` — closed-decision evidence for the upstream SwiftMail twins; re-open only if an
  upstream contribution is separately authorized.
- `IOS-COMPOSE-002` — the other open outbound-conformance cost (MIME parameter quoting).
- `1d28552c1` — the fix that closed the control-character half of this encoder's trigger.
