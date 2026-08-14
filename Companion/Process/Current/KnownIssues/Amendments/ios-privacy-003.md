# IOS-PRIVACY-003 — T8 is closed for hidden `.eml` sections ONLY; the general "don't fetch invisible images" predicate is RULED OUT by an in-document reveal

**Status:** 📋 ACCEPTED LIMITATION (2026-08-12) — **deliberately scoped, not an oversight.**
Registered because the obvious "completion" of this fix is a behaviour regression, and a future
agent reading only the T8 row would ship it.

## What was closed

`deferredImageLoadJS`'s `swap()` now withholds the real URL from images our own **view-mode** CSS
has hidden, via `hiddenByViewMode`. Both manifestations of T8 are closed:

- **Main view** — `.tm-eml-section { display:none !important }` hides every embedded `.eml`, but
  WebKit fetches an `<img>` regardless of `display:none`. Opening an ordinary message therefore
  fired the tracking pixels of every `.eml` attached to it, which the user never opened. This is
  the common case and needs no preview sheet at all; the plan's T8 row described only the second.
- **Preview sheet** — `body.tm-preview-mode > *:not(.tm-eml-section)`,
  `body.tm-preview-mode .tm-eml-section` and `body.tm-preview-mode .tm-eml-headers` hide everything
  but the selected section, so opening one `.eml` preview fetched the parent message's images *and*
  every other embedded `.eml`'s.

The predicate is inside `swap()`, not at its two call sites, so both the double-`rAF` `post-paint`
arm and the `setTimeout(…, 1500)` `failsafe-1500ms` arm inherit it. Filtering at the call sites is
the one edit that would have made this a silent no-op — the failsafe would re-fetch 1500 ms later
everything the post-paint arm withheld.

## What is NOT closed, and why widening it is a REGRESSION rather than an improvement

`hiddenByViewMode` is **not** a general "is this image visible" test. Stated negatively, it does not
treat as hidden:

- `visibility:hidden`, `opacity:0`, zero-size, `content-visibility`, clipped, or merely
  scrolled-off-screen images;
- an image the **sender's** own CSS hides — a hidden preheader, an `@media` desktop-only block;
- an image inside a **collapsed quote or collapsed invite**;
- a hidden `<img>` that is itself a direct child of `<body>` in main view (the direct-body-child arm
  is preview-mode only, because in main view no rule of ours governs those children).

⛔ **Do NOT "finish the job" with `im.offsetParent === null` or
`im.getClientRects().length === 0`.** Both are correct tests of the `display:none` ancestor chain and
both are wrong here, for a reason that is structural rather than a matter of taste:

> `collapseQuotesJS` and `collapseICSJS` build `.tm-quote-wrapper.tm-collapsed`, whose
> `.tm-quote-content` is `display:none` (EmailHTMLWrapper) until the user taps **"Show quoted text"**
> / **"Show invite details"**. That is an **in-document reveal** — a click handler toggling a class,
> with no document reload — and nothing re-runs the swap afterwards. A general predicate would
> withhold those URLs permanently, so every quoted reply and every collapsed invite containing
> images would expand to blank frames.

That case is common (reply chains, forwarded newsletters, calendar invites), so it is a
behaviour change under the standing owner directive *"no behaviour changes, just security"* — the
same directive that produced `IOS-UI-002`, `IOS-UI-003` and `IOS-PRIVACY-001`/`-002`. Over-skipping
is worse than the leak.

A second, independent reason not to widen: `fitViewportJS` **widens the layout viewport** on
overflow (288 → 400 → …), which crosses the email's own `@media` breakpoints. An image hidden at
device width can therefore become visible after a widen, again with no reload.

The narrow predicate is safe precisely because **every ancestor it tests is governed by one of four
of our own `!important` rules whose value is fixed for the lifetime of the loaded document**, so its
answer cannot change in-document and no observer, re-run hook or reveal listener is needed.
Selecting a different `.eml` is a *different wrapped document and a fresh load* (`previewFilename` is
a `wrapHTML` parameter; the coordinator reloads on `loadedPreviewFilename` change), and a withheld
image keeps its `data-tmsrc`/`data-tmsrcset` and is never marked, so the new document's own `swap()`
fetches it normally.

## Failure direction

`hiddenByViewMode` is wrapped in `try/catch` like the debug-only diagnostic hook call beside it,
because it runs inside the swap loop and an uncaught throw would abort the loop and strand every
remaining deferred image on the message. It **fails OPEN** — a throw is treated as "visible" and the
image is swapped — which preserves pre-change behaviour. The cost, stated rather than hidden: a DOM
able to make `classList`/`getComputedStyle` throw would defeat the skip. T8 is a privacy leak, not a
wrong-message or data-loss class defect, so trading a bounded privacy win for an unbounded rendering
regression would be the wrong way round. Sender script cannot install such an accessor while
`allowsContentJavaScript = false` + `script-src 'none'` hold (ADR-IOS-076 decision 1); if that ever
changes, revisit the default.

## Relationship to the rest of the remote-image posture

This does **not** make the render path "tracking-free" and must not be described that way.
`img-src https:` is open by owner decision, and `IOS-PRIVACY-002` records the same capture showing
20+ tracking-pixel requests leaving the device for the message the user *did* open. What changed is
narrower and exactly stateable: **the user no longer fetches remote content on behalf of a message
they never opened.** CSS `background-image` URLs are untouched — the deferral rewrite only ever
rewrote `<img src/srcset>` — and remain the open remainder of T9.

## Pins

`EmailRenderPipelineTests`, all behavioural (JSContext + a mock DOM whose `getComputedStyle`
reproduces the wrapper's actual view-mode cascade, not a hand-set flag):
`deferredSwapWithholdsHiddenEmlSectionImages` (both arms),
`deferredSwapFailsafeArmAloneWithholdsHiddenImages` (the failsafe alone — the no-op guard),
`deferredSwapPreviewModeFetchesOnlySelectedSection`,
`deferredSwapNegativeControlLoadsEverything` (over-skip guard),
`deferredSwapStillFetchesInsideCollapsedQuote` (the reveal guard — asserts the container really is
`display:none` at swap time *and* the image is fetched anyway),
`deferredSwapWithheldImageStaysSwappable` (idempotence / re-runnability),
`deferredSwapCensusIsDebugGated`.
