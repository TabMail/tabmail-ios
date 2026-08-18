# IOS-UI-005

- Register classification: `open`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — NARROWED FIX CANDIDATE (2026-08-15).** The `tm-*` class namespace is **not reserved** against
sender-authored markup, so a sender's `class="tm-eml-section"` remains indistinguishable from an app
marker to app CSS and to `EmailFilter.parseEmlSectionMetadata`. The only app decision found outside
that low-impact cosmetic boundary — `hiddenByViewMode` choosing its app stylesheet branch from
sender-writeable `document.body.classList` — is independently hardened to take the view mode from
Swift's app-owned `previewFilename` instead.

⚠️ **This record exists as much to stop the finding being RE-ESCALATED as to track it.** It was first
framed as "attacker-chosen From/Subject/Date in native SwiftUI chrome", which sounds severe and is
misleading. See *Why the severity is near-nil* — that reasoning is the durable part.

⚠️ **SUPERSEDED DISPOSITION (2026-08-18) — this record is now `accepted`, not `open`; GitHub #20 is
CLOSED as *not planned* (`wontfix`) by owner decision, so THIS FILE IS THE SOLE FENCE.** Everything
above stays true and still governs; only the disposition moved. Read *🧾 OWNER DISPOSITION 2026-08-18*
at the end of this file for the decision, the reopening condition, and the five findings folded in from
the 2026-08-18 verification.

## 2026-08-15 current-main revalidation and narrowed candidate

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
- The remaining marker collision stays open with its precise boundary: sender-controlled native
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
storage/schema change with provider parity and migration work. The currently measured cosmetic residual does not
justify it today; revisit only if a marker begins driving a non-cosmetic decision or trusted provider
metadata becomes materially different from the attached sender-authored bytes.

## Related

- `IOS-UI-004` — the render dead zone; its "Attribution class" section states the dead zone is *"not
  reachable by a sender's choice in any useful direction"*, which **this record falsifies** for the
  `tm-eml-section` route (a sender-authored section hides an image, so the census never settles). The
  trusted Swift view-mode gate closes only the sibling body-class route; this open marker route
  remains.
- `IOS-PRIVACY-002` — the render-family privacy record.
- ADR-IOS-076 — the adjacent render-pipeline and app-owned view-mode decisions; its per-load nonce
  does not establish provenance for markers already persisted in sender-influenced HTML.

## 🧾 OWNER DISPOSITION 2026-08-18 — ACCEPTED LIMITATION; GitHub #20 CLOSED AS NOT PLANNED

**Owner decision (2026-08-18): the residual marker-provenance gap is ACCEPTED as a limitation, and
GitHub issue [#20](https://github.com/TabMail/tabmail-ios/issues/20) is CLOSED as *not planned*
(`wontfix`).** No production code changed with this disposition; the mechanism recorded above is exactly
what ships.

**This record is now the SOLE fence against re-escalation.** There is no tracker row left to carry the
reasoning, so everything that stops this being refiled as *"attacker-chosen From/Subject/Date in native
SwiftUI chrome"* lives here and nowhere else.

**Reopening condition, stated positively.** Re-escalation requires **first showing a `tm-*` marker
driving a NON-COSMETIC decision** — a fetch, a message-identity resolution, a mutation target, an
account-state write, or a privacy/security gate. Until such a consumer exists, the residual is a
disagreement between two sets of sender-authored bytes, and the answer is this record rather than a fix.
The consumer census that establishes the current state is in §3 below; re-run that census before
claiming it has changed.

**Cost if it were ever authorized**, for proportionality: the preview-header leg only, ~200–230
production lines across 9–10 files including `NSEStagingDB` parity, with a blast radius covering the
whole body-fetch → persistence → NSE → attachment-list → preview pipeline on all three providers. That
is the PR #39 silhouette (durable sidecar + multi-provider plumbing + a migration story) against a
near-nil payoff — the same visible-cost-for-security-gain class as the four owner reversals of
2026-08-12 (`IOS-UI-002`, `IOS-UI-003`, `IOS-PRIVACY-001`, `IOS-PRIVACY-002`).

### 1. The loudest leg is NOT caused by the missing namespace reservation

The reply/forward quote-omission leg — what a user would actually notice — does **not** require a forged
marker and would **not** be closed by reserving the `tm-*` namespace.

The app's `.tm-eml-section { display: none !important }` rule lives in the `<head>` stylesheet.
`EmailHTMLWrapper.unwrapFullHTMLDocument` **lifts the author's own `<style>` out of the sender document
and emits it LATER in the cascade**, at **equal specificity and equal `!important` weight** — so the
later rule wins. A sender's own `.tm-eml-section { display: block !important }` therefore overrides the
app's hide rule **against a GENUINE, app-generated marker**. No forgery is involved anywhere in the
sequence.

Consequence for design: provenance machinery aimed at marker *authorship* leaves this leg exactly where
it is. Anyone proposing the out-of-band typed envelope as "the fix for the quote mismatch" has
mis-attributed the mechanism.

### 2. The old-row trilemma — why the mandated out-of-band fix cannot be both provenance-establishing and render-identical

The fix this record mandates — carry the parsed nested envelope and section association out-of-band in an
app-owned typed record (`emlEnvelope: EmlMarker.Envelope?` on `AttachmentInfo`/`AttachmentRef`, which
needs **no migration** because `attachmentsJSON` is JSON-decoded TEXT) — can only ever cover bodies
fetched **after** the change. For every `.eml` already stored there are exactly four doors, and none of
them is open:

1. **Drop the HTML parse.** Every already-stored `.eml` preview permanently loses its native header — a
   visible regression, against the owner's standing render-hardening directive of *security only, no
   behaviour changes*.
2. **Keep `parseEmlSectionMetadata` as a fallback.** The forgery stays live for the entire existing
   corpus, and it is a fallback, which this repo forbids without asking first.
3. **Backfill by re-parsing the stored HTML.** This launders the forged envelope into the app-owned typed
   record — strictly worse than having no typed record at all.
4. **Force a body re-fetch.** Network cost and a behaviour change, and impossible for messages the server
   has since expired.

There is no fifth door. A future proposal must name which of these four it is taking and why its cost has
become acceptable.

### 3. Verified consumer impact at `cdf11a6e5` — the census the reopening condition is measured against

- **Exactly one native string-read of `tm-*` exists**, in `EmailFilter`'s strip/parse paths.
- `EmlSectionMetadata.partSection` has **zero production reads**.
- Nested-attachment routing is **typed** — `AttachmentInfo.parentEmlSection == attachment.section` — and
  never consults marker text.
- The **plain-text / FTS path emits no `tm-*` at all**, so search and every derived index are outside the
  blast radius.
- Outcome of a forged marker, leg by leg (the verifier's enumeration): the native preview-header
  disagreement (**A**) is cosmetic and self-referential, because both envelopes are sender-authored bytes
  either way; the forged section's body rendering above the genuine one (**B**) is cosmetic — sender
  content shown inside a sheet of sender content; the reply/forward quote omission (**C**) is real but,
  per §1, is not a forgery leg at all; the deferred-image withhold decision (**D**) fails
  privacy-**conservative** — it withholds, it does not leak; the remaining diagnostic/observability legs
  (**E**, **F**) are cosmetic.

### 4. LEAD, not a finding — `AttachmentRef` has no `parentEmlSection`

`AttachmentRef` carries no `parentEmlSection` field, so the `attachmentsJSON` an NSE stages **already**
lacks that field until a main-app fetch replaces the record. This was noticed while sizing the typed
envelope and is registered here as a **LEAD, not a finding**: no consequence was traced to it. It is
recorded so a future envelope/provenance design does not rediscover it mid-implementation. Anyone acting
on it must first establish a consumer that actually suffers from the absence.

### 5. Rejected cheap non-fix — last-match-wins

Making `parseEmlSectionMetadata` last-match-wins instead of first-match-wins was considered and
**rejected**: it is unprincipled (nothing makes "last" more authentic than "first"), it changes behaviour
for legitimate mail that genuinely carries two attachments with the same filename, and it does not close
the second route at all — a forged marker inside `.eml` **A**'s nested body still precedes the genuine
marker for `.eml` **B**. Do not re-propose it as a cheap win.

⚠️ It would also invert `IMAPProviderEmlRenderTests.parseEmlSectionMetadataMultiple`, which asserts
first-match-wins today. That test **blesses the current behaviour**, so a real fix must expect to rewrite
it deliberately rather than read its failure as a regression.

### If the reopening condition is ever met — the test shapes already designed

No test covers a sender-forged marker today. If a non-cosmetic consumer ever appears, the red-first
shapes are: `forgedMarkerCannotSupplyThePreviewEnvelope` per provider; a nested-forgery variant (the
`.eml` **A** precedes `.eml` **B** route); two-sided non-vacuity on each; an old-row pinning test that
fails if already-stored previews lose their header; and a SHA-256 render-identity characterization per
provider to prove the corpus renders unchanged.

Required reading before any such work: this record, `IOS-UI-004`, `IOS-PRIVACY-003`, `IOS-PRIVACY-002`,
ADR-IOS-076, ADR-IOS-039,
[`Companion/Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md`](../../../../Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md),
and [`MIS-IOS-011`](../../../../Mistakes/Active/MIS-IOS-011-declared-a-residual-acceptable-on-an-argument-i-never-ran.md)
— the mistake of declaring a residual acceptable on an argument never actually run.
