# IOS-IMAP-016 — SwiftMail's header encoder has the same inverted guard, and its part-header builder interpolates filenames raw

**Class:** `open` · **Opened:** 2026-08-12 · **Remedy is UPSTREAM** (Cocoanetics/SwiftMail, not the
TabMail fork — per the repo convention that SwiftMail PRs go upstream).
**Mitigated app-side the same day**, so this is not a live exposure for the subject; see *Status*.
**Amended 2026-08-12** with a third, pre-existing defect in the same function — the 75-octet
encoded-word ceiling (item 3). It is a conformance cost, not an exposure, and its app-side twin is the
same algorithm, which is why it lands here rather than as an app-side fix.

## What is wrong

Three defects in the pinned fork at `7aee922`:

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

**This is byte-for-byte the same predicate the app-side `RFC2047.encodeHeaderValue` had**, and not by
coincidence: `TabMail/Helpers/RFC2047.swift`'s own doc comment states it is *"kept byte-for-byte in
step with SwiftMail's `String.rfc2047EncodedHeader()`"*. **The defect was copied along with the
helper**, and the comment recording the duplication is the same comment that would have predicted it.
Recorded as `MIS-019` instance 29 — a note saying "this is a deliberate duplicate of X" is a
blast-radius statement.

**2. Raw filename interpolation into MIME parameters** — `EMLSerializer.swift:137,148` and
`Email+Content.swift:195,199,298`:

```swift
contentType += "; name=\"\(filename)\""
dispValue   += "; filename=\"\(filename)\""
```

No escaping, so an embedded `"` closes the quoted-string. Five sites. App-side twin:
`IOS-COMPOSE-002`.

**3. `rfc2047EncodedHeader()` can emit an encoded-word over RFC 2047 §2's 75-octet ceiling.**
Added 2026-08-12; **pre-existing**, not introduced by any TabMail change, and present in the app-side
twin (`RFC2047.encodeAsWords`) for the same reason — the two are the same algorithm.

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

The remedy is to split a single character's bytes across words when it exceeds the budget and accept
that such a word does not decode standalone, or to fold the field differently — a design call for the
library, which is why it is filed here rather than fixed in the app: **the app-side twin has the same
defect, and fixing only our copy re-creates the divergence `MIS-019` instance 29 is about.**

## Status — why this is not a live exposure for the subject

`IMAPProvider.buildEmail` now pre-encodes the subject at **our** boundary with
`RFC2047.encodeIfNotEmittableLiterally`, which encodes only when a value carries a character that
cannot appear literally in a header body. The composition is deliberate and verified by test: our
helper emits pure ASCII, so SwiftMail's guard then sees ASCII and passes it through untouched — no
double encoding — and non-ASCII subjects are left alone because encoding them is already SwiftMail's
job, keeping ordinary mail byte-identical on the wire.

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
2. Same PR or a sibling: quote or RFC 2231-encode the filename parameter at the five sites.
3. Same PR or a sibling: bound the 75-octet word. Whatever is chosen must be applied to the app-side
   `RFC2047.encodeAsWords` in the same change — they are one algorithm in two repos, and fixing one is
   how they diverged in the first place. **Red-first test asserting every emitted word is ≤ 75
   octets**, with `"a"` + 23 combining marks as the boundary fixture (76 octets today), plus a
   non-vacuity twin proving ordinary text still emits ≤ 45-byte chunks unchanged.
4. Do not fix any of these in the fork without an upstream PR; the fork-sync skill exists to keep the
   two from diverging, and these defects are the cost of a silent divergence.

## Related

- `IOS-COMPOSE-002` — the app-side filename/mimeType half.
- `IOS-COMPOSE-003` — the other pre-existing encoder-conformance cost on the same functions: a subject
  that is literally shaped like an encoded-word is passed through by all three encoders and decoded by
  the recipient. Same trigger predicate; if both are taken, take them together.
- `MIS-019` instance 29 — "the library builds it" is a relocation, not a safety property; and
  "kept in step with X" is a duplication register to audit in the same round.
- `IOS-IMAP-015` — the other open SwiftMail issue whose remedy is also upstream.
