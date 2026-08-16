# IOS-COMPOSE-002 — attachment `filename` and `mimeType` are interpolated into MIME headers without encoding or validation

**Class:** `open` · **Opened:** 2026-08-12 · **Attribution:** pre-existing
**Deferred deliberately** — see *Why this is deferred* below. The higher-severity member of the same
class was fixed the same day (sender-authored CRLF in an outbound `Subject:`); this is the remainder.

## What is wrong

`GmailProvider.buildMIMEMessage` contains three header-line interpolations:

```swift
partHeader += "Content-Type: \(alt.mimeType)\r\n"
partHeader += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
partHeader += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
```

- **`filename` lands in a quoted-string unescaped.** `"` and `\` are legal filename scalars and
  `AttachmentFilename.isSafeFileComponent` deliberately accepts both. `a"; boundary="X.pdf` closes
  the quoted-string early and appends another parameter; a benign `report\final.pdf` is interpreted as
  a quoted-pair by conforming parsers and can display as `reportfinal.pdf`. RFC 2231 encoding is the
  full fix; **stripping is not** — the filename is user-visible data.
- **The regular attachment's `mimeType` has no outbound validation.** On a forward,
  `ComposeView.carryForwardAttachments` copies `AttachmentInfo.contentType` unchanged into the
  `DraftAttachment`; the From picker can then send it through Gmail even when another provider parsed
  it. This proves structural propagation, **not** that arbitrary original Content-Type header bytes
  survive every provider parser: SwiftMail/NIO reconstructs IMAP type/subtype plus at most `charset`,
  Gmail exposes a separate parsed `MessagePart.mimeType`, Graph supplies a `contentType`, and local
  sources use UTType or fixed defaults.
- **The `alt.mimeType` interpolation is model/persisted-state capability, not a current UI/forward
  route.** No production constructor in current, v1.7.9, or v1.7.8 sets
  `DraftAttachment.isAlternative = true`; ordinary attachments therefore take the regular branch.
- **Non-ASCII filenames go out as raw UTF-8 inside a quoted-string**, which is non-conformant; RFC
  2231 (`filename*=UTF-8''…`) is the conformant carrier. Cosmetic beside the above, same fix.

The same shape exists **library-side** on the IMAP/SMTP path, so it is not confined to our code:
SwiftMail has six raw filename interpolations across `EMLSerializer.serializePartHeaders`,
`Email.writeMultipartMixed`, and `Email.writeHTMLWithInlineAttachments`. Only the two
`Email.writeMultipartMixed` filename sites are reachable from TabMail today. SwiftMail has four raw
content-type interpolations in total; its regular-attachment and calendar-alternative sites are the two
TabMail-reachable members. The related upstream evidence remains tracked separately in the
still-open `IOS-IMAP-016` record.

## Blast radius, and what it can NOT do

The proven filename consequence is confined to **one MIME part's parameter list**. A control character
is required to end a header field and start a new one, and controls in a filename are refused by
`AttachmentFilename.isSafeFileComponent` (`c35cfdca2`, `ADR-IOS-077`) — which the finding session
flagged as an **incidental** closure, not a designed guard: it holds only while that predicate keeps
refusing controls. So the proven filename route cannot forge a header, add a recipient, or escape the
part; it can confuse a receiving client's parameter parsing for one attachment. The regular `mimeType`
path is structurally reachable and lacks an outbound validator, but no audit has shown an arbitrary
control-bearing original header surviving the provider parsers above; do not upgrade that leg to
header injection without tracing such a value.

**Persisted-draft `mimeType` lead, not a finding.** `DraftAttachmentStorage.loadAttachments` uses
Swift `String.split(separator: "\n")`; because CRLF is one extended grapheme cluster, a CRLF can remain
inside the first `mimeType` element. The outbox loader instead uses
`components(separatedBy: "\n")` and truncates at LF. No production attachment/provider source was
shown to write a control-bearing MIME type into that sidecar, so this is a provenance lead for the
future boundary audit, not a demonstrated header-injection route.

⚠️ **CORRECTED 2026-08-12 — this paragraph said "refused at attach time", which was wrong twice and
wrong in the direction that makes a defence sound broader than it is.** Raised by
`ios-render-security-fix` after its `efe175e66` retraction; mechanism verified independently here.

- **Not at attach — at SAVE/STAGE.** Every production caller of `isSafeFileComponent` is a save, stage
  or preview site: `OutboxMessage.saveAttachments` (the call is inside `saveAttachments`, confirmed by
  locating the enclosing `func`), `Draft.swift`'s save path, two `AttachmentListView` guards, and
  `EmlAttachmentPreview`. **None is on a load or send path.**
- **The outbox drain never re-validates.** `OutboxMessage.loadAttachments` performs no filename
  validation at all — its only fail-closed guard tests `.meta` sidecar ambiguity, a data-loss check, a
  different question. It recovers the sender's name via `DraftAttachmentStorage.afterIndexPrefix` and
  hands it straight to `DraftAttachment(filename:)`, under a comment reading *"This name goes on the
  wire."* The path is structurally continuous: `AccountManagerOutbox` (two call sites) →
  `OutboxMessage.toDraftMessage` → `loadAttachments` → `DraftMessage.attachments[].filename` → the
  interpolation above.

**So the accurate claim is: the filename half is closed AT SAVE, and only for rows THIS BUILD wrote.**
Any row whose name did not pass this build's `saveAttachments` reaches the interpolation unchecked.

**Registered as a LEAD, deliberately not upgraded to a finding.** The peer's acquisition chain is that
`v1.7.8` wrote `"\(index)_\(att.filename)"` verbatim, all 79 refused scalars are filesystem-writable,
and a row queued pre-upgrade drains without re-saving (`ADR-IOS-077` consequence 5, codex's R14
narrowing) — so a forwarded attacker-named attachment queued while offline survives an upgrade and
sends. **Neither session traced that to a sent wire byte**, and it needs an undrained pre-upgrade row to
exist at all. The correction above stands on the caller enumeration alone and needs no exploit.

**Why the wording mattered enough to fix on its own:** the predictable cost is a future reader closing
this issue believing the filename half is handled, and scoping their fix to the subject half only. A
residual note that describes a defence more broadly than the code implements it is where `MIS-019`
hid a live bypass twenty-five times.

Contrast with the fixed sibling, which is why that one shipped first and this one waited: a
CRLF-bearing `Subject:` created a whole new header field on the user's own outgoing mail.

## Why this is deferred

Owner directive, 2026-08-12: *"make sure these fixes do not cause product degradation they should
really be security fixes minimal and if it's not minimal, it's OK to have it into known issues so
that we can revisit this in a different session … unless the security risk is too high to ignore."*

This one is **not minimal** and its risk **is** ignorable for now:

- RFC 2231 changes what recipients see for every attachment with a non-ASCII or special-character
  filename. Older clients handle `filename*=` variably, so it is a compatibility change to the
  product's outbound mail, not a contained predicate edit.
- It touches the Gmail builder **and** the IMAP `Attachment` boundary, and the library half needs an
  upstream PR — three surfaces, one of them not ours.
- The proven filename route cannot forge a header (above); no control-bearing `mimeType` value has
  been traced through a provider parser.

## Reachability

No hostile sender is required. The Files importer constructs a `DraftAttachment` with
`url.lastPathComponent`; APFS permits `"` and `\`, and the predicate accepts both. Forwarding a
sender-named attachment is a second route. Gmail reaches `buildMIMEMessage` through both outbox send
and saved-draft upload (`DraftStore` → `DraftAttachmentStorage.loadAttachments` → provider
`saveDraft` → `buildUrlSafeBase64`/`buildMIMEMessage`); IMAP/SMTP reaches the library sites through
the shared `IMAPProvider.buildEmail` boundary. Regular attachment `mimeType` propagation is also
current-reachable; Gmail's alternative branch is only legacy/model-state capable.

## When revisited

1. One parameter encoder, used at every site. RFC 2231 `filename*=` alone is a complete carrier for
   special/non-ASCII values. Do not add a competing ASCII fallback until a recipient matrix proves
   which value clients select; a quote-only Gmail patch would diverge from SwiftMail, and TabMail's
   EML parser does not currently decode quoted-pairs.
2. Red-first test asserting the emitted part header **re-parses to exactly one `filename` parameter
   whose value is the original string** — not "the encoder was called".
3. Non-vacuity twin with a benign filename emitting unchanged output.
4. A `mimeType` decision that does **not** refuse the send.
   **Owner verdict, 2026-08-12, verbatim, offered in reply to their own pros-and-cons request:**
   *"what are the pros and cons of restricting grammar do we need to actually have the harden thing
   because I think compatibility wins here"*. The owner stated the CONCLUSION and asked for the
   reasoning; they did **not** state a rationale.
   **The rationale below is agent-authored** (this session and `ios-render-security-fix`), recorded as
   reasoning-not-ruling so a future reader can overturn it without needing to overturn a directive:
   refusing a send over `text/plain; charset=windows-1252; format=flowed` blocks the user's own
   outbound intention, and `ADR-IOS-077`'s reject-not-reduce answer does not transfer from an
   attachment to a send.

   > ⚠️ **Attribution corrected 2026-08-12.** This item previously presented the whole sentence as the
   > owner's ruling, with the agent-authored rationale riding in as a subordinate clause after
   > *"because"*. The verdict and the quote are genuine — verified in the session transcript at
   > `origin: {kind: human}`, `userType: external`, ts `2026-08-12T23:19:25.834Z` — which is precisely
   > what made the fabricated half credible: **a false claim welded to a verified one inherits its
   > credibility.** Eight occurrences of `restricting grammar` exist in that transcript; exactly ONE is
   > `origin: human` and the other seven are agent restatements. That ratio is the tell — a claim
   > restated more often than it was sourced. Recorded as a `MIS-019` instance. Discovery credit to
   > `ios-render-security-fix`, which challenged the attribution on the wrong hypothesis (that nobody
   > ruled at all) and still found the real defect — an argument for challenging attribution even when
   > the challenge is over-broad.
5. Do **not** rely on `ADR-IOS-077`'s filename predicate to cover `mimeType`. The two values sit on
   the same line and only one is guarded; that proximity reasoning is what kept this open.

## Related

- Fixed sibling, same class, higher severity: the outbound `Subject:` CRLF injection, and `MIS-019`
  instance 29 for why "the library builds it" was not a defence.
- `IOS-IMAP-016` — the SwiftMail half, upstream.
- `ADR-IOS-077` — reject-not-reduce for attachment filenames.
