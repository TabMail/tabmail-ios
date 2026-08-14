# IOS-COMPOSE-002 — attachment `filename` and `mimeType` are interpolated into MIME parameters without quoting

**Class:** `open` · **Opened:** 2026-08-12 · **Attribution:** pre-existing
**Deferred deliberately** — see *Why this is deferred* below. The higher-severity member of the same
class was fixed the same day (sender-authored CRLF in an outbound `Subject:`); this is the remainder.

## What is wrong

`GmailProvider.buildMIMEMessage` builds three header lines by interpolation:

```swift
partHeader += "Content-Type: \(alt.mimeType)\r\n"
partHeader += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
partHeader += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
```

- **`filename` lands in a quoted-string unescaped.** `"` is a legal filename scalar and
  `AttachmentFilename.isSafeFileComponent` deliberately accepts it, so `a"; boundary="X.pdf` closes
  the quoted-string early and appends an attacker-chosen parameter. RFC 2045 quoting (escape `\` and
  `"`) or RFC 2231 encoding is the fix; **stripping is not** — the filename is user-visible data.
- **`mimeType` has no validation at all.** On a forward it is the incoming part's Content-Type
  (`ComposeView.carryForwardAttachments` → `att.contentType`).
- **Non-ASCII filenames go out as raw UTF-8 inside a quoted-string**, which is non-conformant; RFC
  2231 (`filename*=UTF-8''…`) is the conformant carrier. Cosmetic beside the above, same fix.

The same shape exists **library-side** on the IMAP/SMTP path, so it is not confined to our code:
`EMLSerializer.swift:137,148` and `Email+Content.swift:195,199,298` in SwiftMail interpolate
`filename` into the same two parameters with no escaping (see `IOS-IMAP-016`).

## Blast radius, and what it can NOT do

Confined to **one MIME part's parameter list**. A control character is required to end a header field
and start a new one, and controls in a filename are refused by `AttachmentFilename.isSafeFileComponent`
(`c35cfdca2`, `ADR-IOS-077`) — which the finding session flagged as an **incidental** closure, not a
designed guard: it holds only while that predicate keeps refusing controls. So this issue cannot forge a
header, cannot add a recipient, and cannot escape the part. It can confuse a receiving client's
parameter parsing for one attachment.

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
- No header can be forged through it (above).

## Reachability

Requires the user to **forward** a message carrying a crafted attachment filename, on a **Gmail**
account for the app-side sites, or any IMAP/SMTP account for the library-side ones. No hostile server
needed for the quote — `"` survives every predicate on the path by design.

## When revisited

1. One parameter encoder, used at every site: RFC 2231 when the value is non-ASCII or contains
   specials/controls, otherwise a quoted-string with `\`-escaped `\` and `"`.
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
