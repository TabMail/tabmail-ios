# IOS-UI-005

- Register classification: `accepted`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-08-15) — mechanism remains reachable; a marker-provenance change is
not justified at NEAR-NIL impact.** The `tm-*` class namespace is **not reserved** against
sender-authored markup, so a sender's `class="tm-eml-section"` remains indistinguishable from an app
marker to app CSS and to `EmailFilter.parseEmlSectionMetadata`. The only app decision found outside
that accepted cosmetic boundary — `hiddenByViewMode` choosing its app stylesheet branch from
sender-writeable `document.body.classList` — is independently hardened to take the view mode from
Swift's app-owned `previewFilename` instead.

⚠️ **This record exists as much to stop the finding being RE-ESCALATED as to track it.** It was first
framed as "attacker-chosen From/Subject/Date in native SwiftUI chrome", which sounds severe and is
misleading. See *Why the severity is near-nil* — that reasoning is the durable part.

## 2026-08-15 current-main revalidation and disposition

- Reproduced structurally at `origin/main` `98dde448b8587c9a47828a8aaaf64ff5e747cdc6` on the IMAP,
  Gmail and Exchange assembly paths described below. The owning marker/parser files are byte-identical
  to shipped iOS `v1.7.9` (`EmlMarker.swift` and `EmailFilter.swift`), and the relevant render/wrapper
  paths have no `v1.7.9..origin/main` change. This is a current shipped-app limitation, not history.
- Re-ran the consumer census: `EmlSectionMetadata.partSection` still has no production read, while
  nested attachment fetch and filtering still use typed `AttachmentInfo.section` and
  `parentEmlSection`. No fetch, message identity, mutation, or wrong-message decision trusts marker
  text.
- Audited the apparent fallback before proposing machinery. The `tm_*` action-tag namespace is a
  separate local-only system under ADR-IOS-036: all provider `setActionTag` implementations are
  no-ops, and legacy server residue is only stripped best-effort during inbox-exit moves. Likewise,
  `UserLabelStore`'s `tm_` exclusion reserves action-tag labels; it neither authenticates nor migrates
  `tm-*` HTML classes. There is no dormant provenance fallback to enable.
- A broader `tm-*` census found one distinct invariant worth fixing: deferred-image policy inferred
  preview mode from `body.tm-preview-mode`, although sender HTML can contribute a second `<body>` and
  therefore donate that class to the parsed body. `deferredImageLoadJS` now receives the app-owned
  `previewFilename != nil` decision from Swift. The two-sided test models a forged body class while
  the app remains in main mode and verifies that the forged class cannot change which image groups
  are fetched or withheld.
- The remaining marker collision is accepted with its precise boundary: sender-controlled native
  preview header/body disagreement, reply/forward quote mismatch, and diagnostic/withhold
  observability. Both competing envelopes are sender-authored, and none escapes into attachment
  routing or account state.

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

**No marker-provenance boundary between generation and storage.** `BodyRenderer.render` only appends the ICS block,
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

## If future evidence raises the impact

The fix is **not** to sanitize author `class` attributes — that is a behaviour change to sender content
and the owner's standing ruling is security-only, no behaviour changes. It is also **not** a static
rename, or a nonce written into and then trusted from the same stored HTML: both are still
sender-declarable, and a render-time nonce arrives too late for markers already emitted and persisted by
provider fetch.

A real provenance boundary would carry the parsed nested envelope and section association out-of-band
in an app-owned typed record (the existing optional `AttachmentInfo` sidecar is the natural migration
surface), then render and preview from that record rather than reparsing an HTML marker. That is a
storage/schema change with provider parity and migration work. The accepted cosmetic residual does not
justify it today; revisit only if a marker begins driving a non-cosmetic decision or trusted provider
metadata becomes materially different from the attached sender-authored bytes.

## Related

- `IOS-UI-004` — the render dead zone; its "Attribution class" section states the dead zone is *"not
  reachable by a sender's choice in any useful direction"*, which **this record falsifies** for the
  `tm-eml-section` route (a sender-authored section hides an image, so the census never settles). The
  trusted Swift view-mode gate closes only the sibling body-class route; this accepted marker route
  remains.
- `IOS-PRIVACY-002` — the render-family privacy record.
- ADR-IOS-076 — the render pipeline decisions, including the per-load nonce this record's fix sketch borrows.
