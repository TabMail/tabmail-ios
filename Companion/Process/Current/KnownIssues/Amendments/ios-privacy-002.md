# IOS-PRIVACY-002 — the font leg of T9 is OPEN: `font-src` was relaxed from `'none'` to `https:`, restoring the `@font-face` conditional-request channel

**Status:** 📋 ACCEPTED LIMITATION (2026-08-12) — **OPEN by explicit owner decision.** Registered here
because an open risk nobody wrote down is the failure mode this file exists to prevent.

## What is exposed

`EmailHTMLWrapper.contentSecurityPolicy` declares `font-src https:`. A sender's CSS may therefore
fetch a remote font over TLS, and `@font-face` + `unicode-range` is a **conditional-request channel**:
the browser downloads a given font subset only when the document actually contains a character in
that range, so the *set of requests* leaks information about the rendered content back to a
sender-controlled host — without any script, and unaffected by `allowsContentJavaScript = false`.

That is the font half of threat **T9** in `ADR-IOS-076` / `PLAN_EMAIL_RENDER_SECURITY.md`. P1b
narrowed it with `font-src 'none'`; it is now **not mitigated at all**. The rest of T9 — CSS
`background-image` URLs, which the deferral rewrite never touched because it only rewrites
`<img src/srcset>` — was already open and remains so.

## Why it is open

P1b shipped `font-src 'none'`. The owner's on-device smoke test the same day measured the cost:
enforced `font-src` violations on a real marketing email (`…/fonts/sofia/sofia_reg.woff`,
`disposition=enforce`), which then rendered in a fallback font. That is a visible change from
`v1.7.8` under the standing directive applied to every P1b setting that removed shipped behaviour:

> *"no behaviour changes, just security"*

**The anti-tracking rationale did not survive contact with the rest of this policy.** `img-src` is
`https:`, and the same capture shows 20+ tracking-pixel requests leaving the device regardless — so
the correlation channel `font-src 'none'` closed is wide open through images. Visible typography
cost, ~zero marginal privacy gain.

**The counter-argument was weighed and DECLINED. It is recorded here so it is not rediscovered and
re-argued:** downloadable-font parsing is a genuine remote-code-execution surface — CoreText and
FreeType have a recurring CVE history — and `font-src 'none'` removed that surface as well as the
tracking channel. The owner priced that against the shipped rendering behaviour and chose the
behaviour. That is the decision.

**Do not restore `'none'`, and do not hedge it into a domain allowlist** (`fonts.googleapis.com`,
`fonts.gstatic.com`, …). Both reverse an owner directive; the second also fails on its own terms,
since the observed blocks were on senders' own CDNs, not on a well-known font host.

`https:` was chosen over `*` and over `https: data:` so the directive **mirrors `img-src`'s
TLS-only posture** — the two remote-content directives stay consistent and neither admits a scheme
the other refuses.

## Scope — stated negatively, because it is easy to get wrong in BOTH directions

This restores **every remote font that ever worked**, i.e. every font fetched over an absolute
`https:` URL. Two classes stay blocked, and **only the first is a behaviour delta**:

1. **`data:`-URI fonts — a real, if small, regression against `v1.7.8`.** That release's entire
   policy was `content="upgrade-insecure-requests"`, with no `font-src` and no `default-src`, so a
   `data:` font loaded there and is refused here. Accepted deliberately. So this change is **not** a
   full restoration, and `data:` is the *only* reason it is not.

2. **Protocol-relative `//host/path` font URLs in author CSS — NOT a loss, and this is the trap.**
   They resolve against the document base, which is `BodyAssetConfig.baseURL`
   (`tabmail-asset://asset/`), so `//fonts.gstatic.com/x.woff` becomes
   `tabmail-asset://fonts.gstatic.com/x.woff` — host `fonts.gstatic.com`, **not** `asset`. `v1.7.8`
   passed that same base URL for persisted bodies
   (`let base: URL? = (headerId != nil) ? BodyAssetConfig.baseURL : nil`), and its
   `BodyAssetStore.assetId(fromURL:)` guarded the host to a fixed-length hex hash, so the request
   was already failed with `URLError(.resourceUnavailable)` **at the scheme handler**. These fonts
   have never been fetchable in any release. The CSP only moved the rejection point — same rendered
   result, different rejection site — so they are neither a regression this introduced nor a
   mitigation that survives.

   ⚠️ **Do NOT add `tabmail-asset:` to `font-src` to "fix" them.** The request would simply reach
   `BodyAssetSchemeHandler` again, whose `canonicalAssetId` rejects a non-hex host. Widening the
   directive costs policy surface and loads **exactly zero** additional fonts.

**Measurement note (`MIS-007`).** The device evidence must be counted **per log capture**, not summed
across captures: three captures of the same session contain the same blocks, and summing them
triple-counts. In `logmain.log`: 59 absolute-`https:` font blocks (50 + 9 across two sender hosts)
and 45 `tabmail-asset:`-scheme ones. An earlier draft of this record said "135 of 194", which was
that aggregation error and is withdrawn.

## Interaction with the other open render records

- **`IOS-PRIVACY-001`** (shared persistent website data store) compounds this one: a font fetch now
  permitted here runs against that shared persistent jar, so the host can set a cookie on the font
  response and read it back from a later message.
- **`IOS-UI-002`** (data detectors) and **`IOS-UI-003`** (long-press link preview) are independent.
- `media-src 'none'` was **deliberately retained** in the same owner directive — the smoke test
  recorded zero `media-src` violations, so it has no observed cost. Do not relax it alongside
  `font-src` on the assumption that the two were judged together; they were judged separately and
  came out differently.

## Recovery, under THE MANTRA

There is no in-app recovery for a conditional request that has already been made — the leak, if any,
already happened. The exposure is a **privacy** cost, not a data-loss, wrong-message-mutation,
dropped-intention or brick class, which is why it is registered and accepted rather than mechanised.
Closing it properly means deferring CSS URLs the way `<img src/srcset>` is deferred, which
`ADR-IOS-076` records as materially harder, needing a design, and the owner's call.

## Reachability and attribution

Reachable on every rendered message body whose CSS references a remote `https:` font, for every user,
immediately. Not an edge. Attribution class: **deliberate accepted privacy exposure, chosen by the
owner over a behaviour change.** Not a defect and not a regression for a later agent to "fix" from the
diff — this is the **fourth** owner-directed reversal of a P1b hardening (after `dataDetectorTypes`,
`allowsLinkPreview` and `websiteDataStore`), and anyone re-tightening `font-src` here is reversing an
owner directive and must ask first.

## Pinned by

`EmailRenderSecurityCanaryTests.cspDirectiveCensus`, positively and in **both** directions, because
either drift is a defect:

- `directives.contains("font-src https:")` — the exact directed value.
- `!raw.contains("font-src 'none'")` — a restore to `'none'` is a **behaviour regression**, not a
  hardening, and must fail loudly rather than read as someone tightening security.
- `directives.contains("media-src 'none'")` — pins the *retained* half of the same directive, so a
  future edit cannot relax `media-src` while claiming the font precedent.

The full-list equality assertion (`directives == expected`) also carries the value, but the three
above state the intent in the failure message, which the list comparison cannot.
