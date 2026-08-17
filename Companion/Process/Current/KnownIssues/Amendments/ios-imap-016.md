# IOS-IMAP-016 — SwiftMail's header encoder has the same inverted guard, and its part-header builder interpolates filenames raw

**Class:** `open` · **Opened:** 2026-08-12 · **Remedy is UPSTREAM** (Cocoanetics/SwiftMail, not the
TabMail fork — per the repo convention that SwiftMail PRs go upstream).
**Fully mitigated at TabMail's app boundary by PR #37**, so these are no longer live Subject defects
for TabMail's current send paths; see *Status*. They remain library defects for SwiftMail's other
callers and therefore remain open upstream work. The filename/content-type family is independently
live for TabMail and is also tracked app-side by `IOS-COMPOSE-002`.

## What is wrong

Three defect families in the current pinned fork at `a2d4a94`:

**1. `String+RFC2047Encode.swift:31` — the inverted guard.**

```swift
public func rfc2047EncodedHeader() -> String {
    guard self.contains(where: { !$0.isASCII }) else { return self }
```

**CR and LF are ASCII.** So a value containing a raw CRLF is returned unchanged, while a value
containing non-ASCII text is safely wrapped in an encoded-word — the encoder passes exactly the input
that can break a header and encodes the one that cannot. `Email+Content.swift:84` then emits
`"Subject: \(self.subject.rfc2047EncodedHeader())\r\n"`, so the value ends the header field and
everything after the CRLF is read as a new header.

**This was byte-for-byte the same predicate the app-side `RFC2047.encodeHeaderValue` had before
`1d28552c1`**, and the then-current app documentation explicitly required keeping the two encoders in
step. The defect was copied along with that historical duplication. Recorded as `MIS-019` instance
29: a note saying "this is a deliberate duplicate of X" is a blast-radius statement. The app helper
now deliberately owns a stricter Subject boundary and is no longer byte-identical to SwiftMail;
PR #37 does not modify the fork or close this upstream residual.

**2. Raw filename and content-type interpolation into MIME part headers.** SwiftMail has six raw
filename sites: two in `EMLSerializer.serializePartHeaders`, two in
`Email.writeMultipartMixed`, and two in `Email.writeHTMLWithInlineAttachments`:

```swift
contentType += "; name=\"\(filename)\""
dispValue   += "; filename=\"\(filename)\""
```

No escaping, so an embedded `"` closes the quoted-string. The two `writeMultipartMixed` filename
sites are TabMail-reachable today. SwiftMail also has four raw content-type interpolations: the
serializer part header plus the regular-attachment, calendar-alternative, and HTML-inline arms in
`Email+Content.swift`. TabMail reaches the regular-attachment and calendar-alternative members
through `IMAPProvider.buildEmail`; the other two remain library capability. The app-side twin and
provider-boundary qualifications are recorded in `IOS-COMPOSE-002`.

**3. `rfc2047EncodedHeader()` can emit an encoded-word over RFC 2047 §2's 75-octet ceiling.**
Added 2026-08-12; **pre-existing** and not introduced by any TabMail change. PR #37 fixed TabMail's
app-owned encoder independently at the raw Subject boundary; SwiftMail's copy remains unchanged.

The word-splitting loop is `for character in self`, and it flushes only *between* `Character`s:

```swift
for character in self {
    let bytes = Array(String(character).utf8)
    if !chunk.isEmpty, chunk.count + bytes.count > Self.rfc2047MaxBytesPerWord { flush() }
    chunk.append(contentsOf: bytes)
}
```

The `!chunk.isEmpty` guard is correct — it is what stops a character's UTF-8 bytes being split across
two words, which every decoder needs. Its cost is that **a single extended grapheme cluster wider than
`rfc2047MaxBytesPerWord` (45) lands alone in an oversized word**, because there is no boundary inside
it to flush at. A word's octet count is `12 + 4·ceil(N/3)` for N UTF-8 bytes, so the ceiling is
breached from **N ≥ 46**. Measured on this toolchain:

| input | UTF-8 bytes | widest word (octets) | over 75? |
|---|---|---|---|
| 30 Hangul syllables | 90 | 72 (2 words) | no |
| 4-person ZWJ family emoji | 25 | 48 | no |
| `"a"` + 23 combining marks | 47 | 76 | **yes** — first breach |
| `"a"` + 30 combining marks | 61 | 96 | **yes** |
| `"a"` + 60 combining marks | 121 | 176 | **yes** |

Ordinary text cannot reach it: no single grapheme in normal orthography is 46 UTF-8 bytes. It takes a
long combining sequence or a very long ZWJ/tag sequence — i.e. sender- or user-authored pathological
input, which a subject line accepts. **Consequence is conformance, not injection**: a strict receiving
parser may reject or mangle the word; the value cannot escape the field, because the encoded-word
alphabet contains no CR or LF.

The app remedy splits only between Unicode scalars, which keeps every word independently valid UTF-8,
and budgets the first word separately so the complete `Subject: ` physical line also fits. SwiftMail
needs an equivalent upstream implementation for its other callers; the TabMail fork remains
deviation-free.

## Status — why this is not a live exposure for the subject

`IMAPProvider.buildEmail` now pre-encodes every subject that needs raw-header protection at **our**
boundary with `RFC2047.encodeHeaderValue`. That includes controls, Unicode, complete substrings
consumed by the shipped unanchored decoders, complete boundary composer words, the 75-octet
encoded-word ceiling, and the complete physical Subject-line budget. The substring rule is a
send/readback compatibility guarantee distinct from RFC 2047 §6.1 boundary recognition. The
composition is deliberate and verified through final `constructContent()` bytes and SwiftMail's
actual `decodeMIMEHeader()`: the app helper emits pure ASCII, so SwiftMail's encoder passes it through
untouched with no double encoding.

The library still needs its own fix on its own merits: **a library must not emit an unencoded control
character in a header regardless of what its caller did.** Any other caller of SwiftMail, including a
future call site of ours, gets no protection from our boundary encode.

## Public validation scope

The public record intentionally omits measurements taken from a private device and mailbox. They are
not required to establish the defect or the fix: deterministic synthetic fixtures cover literal
controls, legal folding whitespace, non-ASCII text, and ordinary ASCII in both app-side encoders.

No prevalence or per-mailbox degradation claim is made here. The durable statement is narrower: the
old predicate admitted a header-breaking input class, the boundary encoder now closes that class, and
ordinary inputs retain their existing encoding path. Any future base-rate study must use a synthetic
corpus or publish only privacy-reviewed aggregate data.

## Why the "structured field" argument was wrong

The finding was initially reported as *"IMAP/SMTP is not vulnerable — the subject is passed to
SwiftMail as a structured field and SwiftMail builds the MIME."* Every clause of that is **true** and
the conclusion is **false**: handing a value to a library **relocates** the interpolation, it does not
remove it. Two of three providers were vulnerable (Gmail, IMAP/SMTP), not one. Exchange/Graph is
genuinely clean — `buildGraphSendPayload` sets `message["subject"]` as a JSON value and Graph builds
the MIME server-side, so there is no header line of ours to break.

## When revisited

1. Upstream PR to Cocoanetics: widen `rfc2047EncodedHeader()`'s trigger to non-ASCII **or any
   C0/C1/DEL control**, excluding HTAB (which is WSP and legal literal text in an unstructured field
   body — the app-side fix over-reached on exactly this and its own non-vacuity test caught it).
2. Same PR or a sibling: RFC 2231-encode the filename parameter at all six sites, and validate or
   safely serialize the four content-type values. Recipient fallback behavior remains an owner
   compatibility decision; do not ship a Gmail-only quote patch that leaves the library divergent.
3. Same PR or a sibling: bound every encoded-word to 75 octets and the complete physical Subject
   lines to the agreed header limit, without splitting a Unicode scalar. Use `"a"` + 23 combining
   marks as the red boundary fixture and assert final serialized output, not only the helper.
4. Do not fix any of these in the fork without an upstream PR; the fork-sync skill exists to keep the
   two from diverging, and these defects are the cost of a silent divergence.

## Related

- `IOS-COMPOSE-002` — the app-side filename/mimeType half.
- `IOS-COMPOSE-003` — fixed app-side by PR #37. Its decoder-compatibility, composer-word, and
  line-budget tests are the TabMail boundary reference for the upstream SwiftMail work; app closure
  does not close this record.
- `MIS-019` instance 29 — "the library builds it" is a relocation, not a safety property; and
  "kept in step with X" is a duplication register to audit in the same round.
- `IOS-IMAP-015` — the other open SwiftMail issue whose remedy is also upstream.
