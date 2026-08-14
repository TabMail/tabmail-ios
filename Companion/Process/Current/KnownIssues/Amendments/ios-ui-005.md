# IOS-UI-005

- Register classification: `open`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-13) — mechanism CONFIRMED on all three providers; impact deliberately assessed as
NEAR-NIL and registered rather than fixed.** The `tm-*` class namespace is **not reserved** against
sender-authored markup, so a sender's `class="tm-eml-section"` is indistinguishable from an app marker
to app CSS, to `hiddenByViewMode`, and to `EmailFilter.parseEmlSectionMetadata`.

⚠️ **This record exists as much to stop the finding being RE-ESCALATED as to track it.** It was first
framed as "attacker-chosen From/Subject/Date in native SwiftUI chrome", which sounds severe and is
misleading. See *Why the severity is near-nil* — that reasoning is the durable part.

## Subsystem and search terms

`tm-eml-section`; `tm-eml-headers`; `tm-*` namespace; class-attribute forgery; sender-authored markup;
`EmailFilter.parseEmlSectionMetadata`; first-match-wins; `EmailFilter.matchEmlSectionOpen`;
`findClassAttr`; `containsToken`; `EmlMarker.build`; `IMAPFetchMapping.renderBodyWithEmbeddedHeaders`;
`GmailProvider.extractBodyAndEmlMarkers`; `ExchangeProvider.fetchMessage`; `BodyRenderer.render`;
`EmailHTMLWrapper.unwrapFullHTMLDocument`; `EmlAttachmentPreview.metadata`;
`EmailFilter.stripEmbeddedEmlSections`; `body.tm-preview-mode`; `data-filename`

## The mechanism, verified per provider

`EmailHTMLWrapper.wrapHTML` strips `loading="lazy"`, external stylesheet `<link>`s and `<meta>`, and
rewrites `<img src/srcset>` — but **never strips, rewrites, or namespaces author `class` attributes**.
The only place author `class` is touched at all is `EmailHTMLWrapper.unwrapFullHTMLDocument`, which
**prepends** `tm-email-body ` to an existing `<body class="…">` — an addition, never a strip.

**Markers are strictly APPENDED after the sender-authored body on all three providers:**

- **IMAP** — `IMAPFetchMapping.renderBodyWithEmbeddedHeaders`: `var result = topLevelContent` (the
  sender's `part.textContent` verbatim), then `result += EmlMarker.build(…)` per nested/attached `.eml`.
- **Gmail** — `GmailProvider.extractBodyAndEmlMarkers`: markers accumulate in `tail`, returned as
  `(topLevel ?? "") + tail` where `topLevel` is the decoded raw sender body.
- **Exchange** — `ExchangeProvider.fetchMessage`: `htmlBody` starts as the raw Graph body, then
  `htmlBody = (htmlBody ?? "") + markerHtml` at both marker sites.

**No sanitization between generation and storage.** `BodyRenderer.render` only appends the ICS block,
substitutes `cid:` refs and picks `displayHtml`; `MessageBody.create` stores the string unchanged; the
NSE path (`NSEDataBridge.toBodySnapshot` → `toMessageBody`) uses the same `BodyRenderer` output.

**`parseEmlSectionMetadata` is first-match-wins.** It scans forward from index 0 and returns inside the
loop on the first `data-filename` whose decoded value equals the target — no position, provenance or
nesting check. Token matching via `matchEmlSectionOpen`/`findClassAttr`/`containsToken` means
`class="foo tm-eml-section"` in any attribute order matches too.

**`data-filename` is fully sender-controlled.** `AttachmentListView` passes `attachment.filename` raw
through `EmlPreviewState` → `EmlAttachmentPreview.init` → `parseEmlSectionMetadata`, and that filename
is the raw MIME `filename` parameter / Gmail `part.filename` / Graph `att.name` — all authored by the
sender in the same message. The sheet opens whenever `contentType` is `message/rfc822` **or** the
filename ends `.eml`, so the attachment need not even be parsable.

A second route exists on all three providers: a forged marker inside `.eml` **A**'s nested body precedes
the genuine marker for `.eml` **B**.

## 🚨 Why the severity is near-nil — read before re-escalating

**The genuine marker's envelope is ITSELF sender-authored bytes.** IMAP takes it from
`rfc822.embeddedMessageInfo` (the attached message's own headers), Gmail from
`envelopeFromHeaders(part.headers)`, Exchange from Graph's parse of the attached item. **Nothing
authenticates a nested envelope anywhere in the app.**

So a sender who wants the preview sheet to display `From: bank@example.com` simply **attaches an `.eml`
containing that `From:` line**. No class forgery is required, and the forgery therefore buys only the
ability to make the *displayed* envelope disagree with the *attachment's actual bytes* — and both sides
of that disagreement are the attacker's own content. That is a cosmetic inconsistency inside a sheet
whose entire contents are attacker-controlled by construction.

**One claimed leg is REFUTED outright:** `metadata.partSection` is **never read**. The nested-attachment
strip comes from `AttachmentInfo.parentEmlSection == attachment.section`, not from the marker. So **no
fetch, no identity resolution and no security decision hangs off a marker.** `EmlSectionMetadata` has
exactly one consumer in the app — `EmlAttachmentPreview.metadata`, read only by the `header` view for
`from`, `date`, `toList`, `ccList`, `subject`.

For calibration: a sender can **already** suppress the image-failure census with a hanging image URL.
This finding is comparable or lower.

## What a reader would actually see

The preview sheet's native header showing From/Date/To/Cc/Subject taken from the forged `div`, plus the
forged section's body rendered above the genuine one — because the preview rule
`body.tm-preview-mode .tm-eml-section[data-filename="…"] { display: block !important; }` un-hides
**every** matching section, not only the first.

## Related side effect — same class, same low severity, not investigated further

`EmailFilter.stripEmbeddedEmlSections` (reply/forward quoting, four `ComposeView` call sites) will also
silently drop a forged section. A sender who un-hides their forged section with their own CSS can
therefore make what the user **quotes** differ from what the user **saw**.

## What could not be determined statically

- Whether real Gmail/Graph responses ever pre-sanitize or re-serialize a sender's `class` attributes
  **server-side** before the app sees them. Exchange returns a Graph-normalized `body.content`;
  confirmed only that **the app** does not sanitize, not that Graph does not. One captured real message
  with a forged marker per provider would settle it.
- Whether the `<!doctype`-prefixed path through `unwrapFullHTMLDocument` perturbs a forged marker's
  position at render time. Not modelled, because the ordering question is decided at **storage** time,
  before that function runs.
- **No existing test covers a sender-forged marker.** The closest suites
  (`IMAPProviderEmlRenderTests.parseEmlSectionMetadataMultiple`, `EmlMarkerTests`) exercise only
  app-generated markers.

## If it is ever fixed

The fix is **not** to sanitize author `class` attributes — that is a behaviour change to sender content
and the owner's standing ruling is security-only, no behaviour changes. The right shape is to make the
app's markers **distinguishable from sender markup by construction** (a per-load nonce in the marker
attribute, mirroring the render pipeline's existing per-load nonce base URL), so `parseEmlSectionMetadata`
can require provenance rather than position.

## Related

- `IOS-UI-004` — the render dead zone; its "Attribution class" section states the dead zone is *"not
  reachable by a sender's choice in any useful direction"*, which **this record falsifies** for the
  `tm-eml-section` route (a sender-authored section hides an image, so the census never settles). That
  route is **not** closed by gating the `tm-eml-headers` arm.
- `IOS-PRIVACY-002` — the render-family privacy record.
- ADR-IOS-076 — the render pipeline decisions, including the per-load nonce this record's fix sketch borrows.
