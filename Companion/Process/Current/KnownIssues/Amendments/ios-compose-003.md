# IOS-COMPOSE-003 — outgoing subject encoded-word conformance: literal syntax and physical line limits

**Class:** `fixed` · **Opened:** 2026-08-12 · **Fixed:** PR #37 · **Attribution:** pre-existing

## What was wrong

The two Gmail raw-message builders and the IMAP/SMTP path could emit sender-authored printable ASCII
that was itself shaped like an RFC 2047 encoded-word. A receiving reader could then decode part of the
literal subject and display text the sender never wrote. Separately, the encoder split only between
Swift `Character` values, so one extended grapheme wider than 45 UTF-8 bytes could produce an
encoded-word over RFC 2047 §2's 75-octet ceiling. Even compliant 72-octet words could make the first
physical line too long once the `Subject: ` prefix was included.

These were display and interoperability defects, not header injection. The control-bearing subject
class was already fixed by `1d28552c1`; Base64 encoded-word output contains no CR or LF capable of
ending the field.

## Fixed behavior

`RFC2047.encodeHeaderValue` now owns the complete raw Subject boundary for both Gmail emitters and for
the sole `IMAPProvider.buildEmail` construction path before SwiftMail serializes the message. It:

1. Parses SP/HTAB-delimited scalar tokens at the field-body start or after whitespace. A complete,
   valid encoded-word at that boundary is the standard RFC 2047 §6.1 reader-recognition case.
2. Also protects every complete substring matched by TabMail's shipped readers, including valid
   non-boundary and suffixed substrings. Both `RFC5322Parse.decodeRFC2047` and SwiftMail's
   `decodeMIMEHeader()` use an unanchored encoded-word pattern and would otherwise consume that
   substring on send -> readback. This is a deliberate compatibility guarantee beyond §6.1, not a
   claim that a conforming reader must recognize those placements.
3. Leaves bare and unterminated `=?` shapes literal because neither shipped decoder consumes them.
4. Protects complete malformed or oversized boundary shapes too, including the minimal `=?=`. They
   are intentionally a separate composer-conformance case: a reader recognises only valid §2 syntax
   within 75 octets, while §7
   requires a composer not to emit a boundary word that begins with `=?` and ends with `?=` unless it
   is valid. Encoding the whole value makes the outer word valid and preserves the literal text.
5. Splits encoded data between Unicode scalars, so every word is independently valid UTF-8 and no
   word exceeds the RFC 2047 ceiling.
6. Uses a 39-byte first-word budget and 45-byte continuation budget. When encoding is required, the
   final emitted physical Subject lines are at most 76 octets including `Subject: ` on the first line
   and continuation WSP thereafter. Literal ASCII pass-through is outside this encoded-line claim.

The helper returns ASCII, so SwiftMail's current non-ASCII-only encoder is a no-op rather than a
double encoder. Exchange/Graph remains deliberately outside this transformation: it receives the
subject as semantic JSON and constructs MIME server-side.

## Verification

- Field start, SP, and HTAB valid-token recognition boundaries.
- Non-boundary and suffixed compatibility cases proved through the actual unanchored Gmail and
  SwiftMail decoders; bare and unterminated literal negative controls.
- Complete malformed encoding and Base64 payload shapes, plus valid ≤75 and oversized >75 shapes,
  including `=?=`, with the §7 reason asserted separately from reader recognition.
- Both Gmail raw emitters → `RFC5322Parse.decodeRFC2047` and final SwiftMail `constructContent()` →
  `decodeMIMEHeader()`: exact Subject round-trip, scalar integrity, every encoded-word within 75
  octets, and every physical Subject line within 76.
- The final test fixtures were run unchanged against the pre-compatibility predicate: 51 of 54
  focused cases passed, with only the three new decoder-compatibility cases failing, before GREEN.
- Ordinary ASCII and non-ASCII behavior controls, CR/LF injection invariants, and Exchange semantic
  JSON preservation.

## Remaining separate work

- `IOS-COMPOSE-002` / issue #7 remains open for Gmail attachment MIME parameter serialization.
- `IOS-IMAP-016` / issue #10 remains open until the equivalent SwiftMail library fixes are accepted
  upstream and TabMail's deviation-free fork is synchronized. App-side closure here does not fix
  SwiftMail for other callers.

Issue #8 can close when PR #37 merges. PR #38 was documentation-only and did not implement this fix.
