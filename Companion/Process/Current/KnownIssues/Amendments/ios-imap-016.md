# IOS-IMAP-016 — SwiftMail's header encoder has the same inverted guard, and its part-header builder interpolates filenames raw

**Class:** `closed-decision` · **Opened:** 2026-08-12 · **Closed:** 2026-08-15 · **Remedy is
UPSTREAM** (Cocoanetics/SwiftMail, not the TabMail fork — per the repo convention that SwiftMail PRs
go upstream).
**The control-bearing-subject defect was mitigated app-side the same day**, so that defect is not a
live exposure for the subject; see *Status*.
**Amended 2026-08-12** with a third, pre-existing defect in the same function — the 75-octet
encoded-word ceiling (item 3). It is a conformance cost, not an exposure. Its app-side twin is tracked
separately under `IOS-COMPOSE-003`; this record preserves the SwiftMail/library defect.

**Closed as a repository decision, not as a fix.** Re-audited on 2026-08-15 against
`tabmail-ios@98dde448` and SwiftMail `a2d4a94` (release 1.11.0): the fork and Cocoanetics upstream
are byte-identical and all three defects remain. Owner context on 2026-08-15 was *“yeah, we don't
have deviations anymore”*. **The authorization conclusion that follows is agent-authored scope
reasoning, not an owner ruling:** this task authorizes iOS issue PRs, not a new fork deviation or an
external Cocoanetics PR. The app-owned filename/mimeType residue remains open under
`IOS-COMPOSE-002`, and the app-owned encoded-word trigger and 75-octet ceiling residues remain open under
`IOS-COMPOSE-003`. This upstream-only tracker therefore has no authorized action inside the TabMail
iOS repository. Re-open only if upstream work is separately authorized.

## What is wrong

Three defects in the pinned, deviation-free SwiftMail 1.11.0 at `a2d4a94`. The prior record named
fork commit `7aee922`; the 1.11.0 sync reset the fork to upstream, so that commit is no longer an
ancestor of `main`, while the defects themselves survived unchanged:

**1. `String.rfc2047EncodedHeader()` — the inverted guard.**

```swift
public func rfc2047EncodedHeader() -> String {
    guard self.contains(where: { !$0.isASCII }) else { return self }
```

**CR and LF are ASCII.** So a value containing a raw CRLF is returned unchanged, while a value
containing non-ASCII text is safely wrapped in an encoded-word — the encoder passes exactly the input
that can break a header and encodes the one that cannot. `Email.writeHeaders` then emits
`"Subject: \(self.subject.rfc2047EncodedHeader())\r\n"`, so the value ends the header field and
everything after the CRLF is read as a new header.

**This is byte-for-byte the same predicate the app-side `RFC2047.encodeHeaderValue` had**, and not by
coincidence: `TabMail/Helpers/RFC2047.swift`'s own doc comment states it is *"kept byte-for-byte in
step with SwiftMail's `String.rfc2047EncodedHeader()`"*. **The defect was copied along with the
helper**, and the comment recording the duplication is the same comment that would have predicted it.
Recorded as `MIS-019` instance 29 — a note saying "this is a deliberate duplicate of X" is a
blast-radius statement.

**2. Raw filename interpolation into MIME parameters** — six sites across
`EMLSerializer.serializePartHeaders`, `Email.writeMultipartMixed`, and
`Email.writeHTMLWithInlineAttachments`:

```swift
contentType += "; name=\"\(filename)\""
dispValue   += "; filename=\"\(filename)\""
```

No escaping, so an embedded `"` closes the quoted-string. SwiftMail also has **four** raw content-type
interpolations: the `Email.writeMultipartMixed` and `Email.writeCalendarAlternative` sites are
TabMail-reachable, while the `Email.writeHTMLWithInlineAttachments` and
`EMLSerializer.serializePartHeaders` sites are not. `IOS-COMPOSE-002` owns the app-side
filename/mimeType twin.

Only two of the six filename sites are reachable from TabMail: the regular/invite attachment arms of
`Email.writeMultipartMixed`. The app has no `EMLSerializer` caller, and its sole SwiftMail
`Attachment` construction site never sets `isInline`, so `Email.writeHTMLWithInlineAttachments` has
no app-reachable member. This narrows the product surface; it does not make the two reachable sites
safe.

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
| `"a"` + 22 combining marks | 45 | 72 | no — last safe input |
| `"a"` + 23 combining marks | 47 | 76 | **yes** — first breach |
| `"a"` + 30 combining marks | 61 | 96 | **yes** |
| `"a"` + 60 combining marks | 121 | 176 | **yes** |

Ordinary text cannot reach it: no single grapheme in normal orthography is 46 UTF-8 bytes. It takes a
long combining sequence or a very long ZWJ/tag sequence — i.e. sender- or user-authored pathological
input, which a subject line accepts. **Consequence is conformance, not injection**: a strict receiving
parser may reject or mangle the word; the value cannot escape the field, because the encoded-word
alphabet contains no CR or LF.

The bounded remedy can iterate Unicode scalars rather than extended grapheme clusters, so every split
remains on a valid UTF-8 scalar boundary, or fold the field by another independently round-tripped
method. That is a design call for the library. The app-side twin remains separately open under
`IOS-COMPOSE-003`; fixing the app boundary does not authorize or require a fork deviation.

## Status — why the control-bearing-subject defect is not a live TabMail exposure

`IMAPProvider.buildEmail` now pre-encodes the subject at **our** boundary with
`RFC2047.encodeIfNotEmittableLiterally`, which encodes only when a value carries a character that
cannot appear literally in a header body. The composition is deliberate and verified by test: our
helper emits pure ASCII, so SwiftMail's guard then sees ASCII and passes it through untouched — no
double encoding — and non-ASCII subjects are left alone because encoding them is already SwiftMail's
job, keeping ordinary mail byte-identical on the wire.

`IMAPProvider.buildEmail` is the sole SwiftMail `Email` construction boundary in the app and is
shared by SMTP send, Sent append, and IMAP draft save. It constructs address values without display
names, so the separate `EmailAddress.headerString()` encoder is unreachable with app-authored names;
the app also has no `EMLSerializer` caller. Gmail's two MIME builders use the app-side guarded
encoder, while Exchange gives Graph a structured JSON subject. SwiftMail's SMTP command layer only
dot-stuffs the constructed message; it has no later header-sanitizing fallback.

The library still needs its own fix on its own merits: **a library must not emit an unencoded control
character in a header regardless of what its caller did.** Any other caller of SwiftMail, including a
future call site of ours, gets no protection from our boundary encode.

### Unproven additional-header lead preserved by the closure audit

`Email.writeHeaders` emits `additionalHeaders` without encoding or control filtering.
`IMAPProvider.buildEmail` populates that dictionary with `In-Reply-To` and `References` derived from
message ids, and the current normalizers trim only at the edges. An interior control could therefore
survive those helpers in principle. The re-audit did **not** trace such a value from provider parsing
to a sent wire byte, so this is a lead rather than a finding and does not widen this disposition. It
is recorded here so a future header-boundary audit tests the end-to-end provenance instead of assuming
the subject encoder covers every header.

## Public validation scope

The public record intentionally omits measurements taken from a private device and mailbox. They are
not required to establish the defect or the fix: deterministic synthetic fixtures cover literal
controls, legal folding whitespace, non-ASCII text, and ordinary ASCII in both app-side encoders.

No prevalence or per-mailbox degradation claim is made here. The durable statement is narrower: the
old predicate admitted a header-breaking input class, the boundary encoder now closes that class, and
ordinary inputs retain their existing encoding path. Any future base-rate study must use a synthetic
corpus or publish only privacy-reviewed aggregate data.

## Why the "structured field" argument was wrong

The control-bearing finding was initially reported as *"IMAP/SMTP is not vulnerable — the subject is
passed to SwiftMail as a structured field and SwiftMail builds the MIME."* Every clause of that is
**true** and the conclusion is **false**: handing a value to a library **relocates** the interpolation,
it does not remove it. Two of three providers were vulnerable (Gmail, IMAP/SMTP), not one.
Exchange/Graph is genuinely clean for that control-bearing class — `buildGraphSendPayload` sets
`message["subject"]` as a JSON value and Graph builds the MIME server-side, so there is no header line
of ours to break.

## When revisited — requires separate upstream authorization

Do not implement these items as fork-local deviations. If the owner separately authorizes an upstream
contribution, then:

1. Widen `rfc2047EncodedHeader()`'s trigger to non-ASCII **or any
   C0/C1/DEL control**, excluding HTAB (which is WSP and legal literal text in an unstructured field
   body — the app-side fix over-reached on exactly this and its own non-vacuity test caught it).
2. Quote or RFC 2231-encode the filename parameter at all six library sites, and audit **all four** raw
   content-type interpolations in the same library-wide MIME-boundary round (two are TabMail-reachable
   today). Keep the TabMail-facing work tracked under `IOS-COMPOSE-002`.
3. Same PR or a sibling: bound the 75-octet word. Cross-check the separately tracked app-side
   `RFC2047.encodeAsWords` algorithm, but do not overwrite or block an independently validated app
   boundary fix. **Red-first test asserting every emitted word is ≤ 75
   octets**, with `"a"` + 23 combining marks as the boundary fixture (76 octets today), plus a
   non-vacuity twin proving ordinary text still emits ≤ 45-byte chunks unchanged.
4. Add SwiftMail's own recognition-boundary protection for literal encoded-word syntax so the library
   is safe for callers on its own merits. The app behavior remains independently owned by
   `IOS-COMPOSE-003` and does not wait for upstream authorization.

## Related

- `IOS-COMPOSE-002` — the app-side filename/mimeType half.
- `IOS-COMPOSE-003` — app ownership for the literal encoded-word and 75-octet ceiling residues.
  SwiftMail independently passes the literal ASCII fixture and carries the same grapheme-folding
  ceiling. App work does not wait for upstream; if upstream is separately authorized, audit both
  library behaviors together.
- `MIS-019` instance 29 — "the library builds it" is a relocation, not a safety property; and
  "kept in step with X" is a duplication register to audit in the same round.
- `IOS-IMAP-015` — a separate open SwiftMail issue whose remedy is also upstream.
