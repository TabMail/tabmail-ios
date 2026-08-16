# IOS-UI-004 — RESOLVED: the generic image-failure census no longer drives a banner

**Status:** ✅ **RESOLVED AS A UI LIMITATION (2026-08-13).** The underlying non-settling-image
condition remains in a diagnostic census, but it can no longer suppress or delay user-visible UI.

## Current resolution

The owner confirmed that Apple Mail also fails the same quoted Outlook images and chose to keep
routine broken remote images silent. `imageLoadFailure` is now diagnostic-only; its
`{ failed, deferred }` count has no user-visible sink. Therefore the dead zone documented below can
at worst omit one debug census. It no longer withholds an explanation, raises a stale notice, or
affects message chrome.

There is no replacement security-specific notice. The measured freeT failure is ATS rejecting a
TLS 1.2 static-RSA cipher for lack of forward secrecy, while `WKWebView` exposes neither the exact
failure of an `<img>` request nor a supported per-resource timeout. A timing heuristic would also
label slow DNS and other transport failures. Revisit only if WebKit exposes an exact subresource
failure reason; do not add a retry or duplicate probe to manufacture one.

Everything below is preserved as the historical P4 landing shape and the still-current diagnostic
census mechanics. Do not use its references to a "banner" as current product behavior.

> **Current implementation note (`1051ecbf6`):** the opening description below records P4's landing
> shape. The live census derives terminal outcomes from `armedImgs`, waits on `armedPending()`, and
> computes the report from records; it does not count arbitrary `error` fires or settle on
> `pendingImgs()`. The accepted dead zone remains when a withheld armed image receives no terminal
> mark. **That is not every withheld image and not every `.eml` attachment:** a mixed live
> `src="cid:…"` plus deferred `srcset="https://…"` can settle from the live candidate. That
> disagreement is already recorded below; it is known accepted behavior, not a new review finding.
>
> **Copy note (2026-08-13 device smoke):** the banner no longer suggests a sender-server or secure-
> connection cause. A connected device loaded public images in the same message while authenticated
> or expired Outlook `/mail/id/…` quote URLs errored, and WebKit exposed no reason code. Current copy:
> **“Some images couldn't be loaded. They may be unavailable or require sign-in.”** This changes
> only the explanation; the census and this accepted non-settling-image dead zone are unchanged.

## Historical P4 landing shape (no longer user-visible)

`postImageWidthRecheckJS` counts the `error` fires among the images **we** deferred (remote
`http(s)`, i.e. the ones `EmailHTMLWrapper.wrapHTML` rewrote to `data-tmsrc` / `data-tmsrcset`) and
posts `{ failed, deferred }` **once**, on the `imageLoadFailure` bridge channel, at the moment
`pendingImgs()` reaches 0. A nonzero `failed` raises `ImageLoadFailureBanner` — a dismiss-only notice
rendered in SwiftUI above the web view.

It is observational: nothing on this path retries, probes, HEAD-checks or re-requests a URL, and
nothing changes which images load or when. It is **not** the block-with-banner design that was
implemented, smoke-tested and reverted on 2026-06-17.

## The current dead zone

The report is gated on `armedPending()`: every image armed at document end needs one first-terminal
`load` or `error` mark. P2 (`IOS-PRIVACY-003`) made `deferredImageLoadJS`'s `swap()` withhold remote
URLs from images our view-mode CSS hides. An ordinary remote-only withheld image therefore remains
armed but never loads or errors, so its terminal mark stays nil and the report remains suppressed.

The condition is **a non-settling withheld armed image**, not the mere presence of an attachment.
An `.eml` with no such image does not create the gap. Nor does every withheld image: a mixed live
`cid:` src plus deferred remote `srcset` can receive a terminal event from the live src, under the
accepted first-terminal rule below.

Concretely, the banner remains suppressed when at least one non-settling armed image exists:

- in an ordinary message when a hidden `.tm-eml-section` contains such an image;
- in an `.eml` preview when the hidden parent body or a non-selected section contains such an image.

A message with no armed image that remains terminal-less is unaffected.

## Why this is accepted rather than fixed

**Direction.** It fails in the safe direction. The banner is a claim that this message lost remote
image content, so a withheld banner costs an explanation while a spurious one falsely describes
the message. This edge only ever withholds.

**Recoverability (THE MANTRA).** There is nothing to recover: no user intention is dropped, no state
is wrong, no action is misdirected. The user sees the same blank image frames they saw before P4,
just without the sentence explaining them.

> ⚠️ **CORRECTION, 2026-08-13 — this section argued the opposite of the truth and must not be read as
> originally written.** Two claims below were wrong, and both were load-bearing:
>
> 1. *"exactly `v1.7.8`'s behaviour"* — **false.** It was true of the blank frames and false of
>    everything else. `v1.7.8` also performed the post-image-load **width re-fit** on these messages;
>    HEAD, before the fix, did not. Sharing one settle predicate meant a withheld image kept
>    `pendingImgs()` above zero forever, so `check()` — the only producer of `requestWidthRefit` —
>    returned early forever. Verified against the tag: `postImageWidthRecheckJS`, `pendingImgs`,
>    `requestWidthRefit` and `__tmWidthRefitRequested` all exist at `v1.7.8`, where `swap()` had no
>    visibility predicate; `hiddenByViewMode` has **zero** hits there. So T8 introduced a rendering
>    regression, undisclosed, inside a commit whose body claimed it changed no rendering behaviour.
> 2. *"the fix is out of scope by directive"* — **inverted.** It reasoned that excluding withheld
>    images would *cause* a width-pipeline behaviour change. Including them had **already caused**
>    one; excluding them is what **restores** shipped behaviour. Read as written, this section
>    instructed the next agent to preserve the regression on the grounds that removing it was the
>    regression — which is exactly what it did, unchallenged, until two independent audit legs
>    re-derived the mechanism from the shipped tag.
>
> **Fixed in `758fac32f`.** `pendingImgs(ignoreWithheld)` now answers the pipeline's two DIFFERENT
> questions — the width arm passes `true` (a `display:none` image contributes no box and will never
> load, so waiting on it is waiting forever), the census arm passes `false` (an image that neither
> loaded nor errored has reached no terminal state, so a census taken now would be incomplete). One
> function, one argument, no second spelling — which is what the lockstep concern below was actually
> protecting.
>
> ⚠️ **That sentence describes `758fac32f` only.** Later the same day `1051ecbf6` moved the census
> off `pendingImgs` entirely and onto `armedPending()`, a genuinely second predicate function — see
> the correction under the ⛔ bullet in *What NOT to do* for why that is correct rather than the
> forbidden shape, and for where the surviving lockstep pair actually is.
>
> **This entry remains OPEN, and its scope is now exactly the census half:** no banner when a
> withheld armed image remains terminal-less. That half is still accepted, because closing it changes when a banner P4
> introduced appears — new behaviour, not shipped behaviour — and is the owner's decision. The owner
> chose restore-only on 2026-08-13 and was given both options explicitly.

## What NOT to do about it

- ⛔ **Do not "restore" the shared bare `pendingImgs()` call.** It reads like a simplification and is
  the regression above. The two arms MUST pass different arguments; a test now pins both sides.
- ⛔ **Do not give the census a second predicate FUNCTION.** The lockstep concern is real and
  unchanged — memory topic 037's `measureMaxRight` / `postImageWidthRecheckJS` bullets exist because
  a second *spelling* of the not-yet-displayable key drifts silently. One function taking a parameter
  is not a second spelling; a copy-pasted second function is.

  > ⚠️ **CORRECTION, 2026-08-13 — the shipped code now HAS a second census predicate function, on
  > purpose, and this bullet must not be read as forbidding it.** `1051ecbf6` added `armedPending()`
  > alongside `pendingImgs(ignoreWithheld)`, and the census arm answers from the former. **Do not
  > "restore" a single parameterised function here — that is a regression, not a simplification.**
  > It would put the census back on the live-DOM population and re-open both defects `1051ecbf6`
  > closed (an `error`-fire counter author script can inflate past `deferred`; a detached armed
  > `<img>` vanishing from the walk so the one-shot publishes early).
  >
  > **What distinguishes it from the forbidden shape is its DATA SOURCE, not its call signature.**
  > The forbidden shape is a copy of the not-yet-displayable KEY —
  > `data-tmsrc || data-tmsrcset || !complete`. `armedPending()` does not contain that key at all: it
  > counts records in the `armedImgs` registry whose explicit `terminal` mark is still null, where
  > the mark is written by the `load` / `error` listeners. Editing `pendingImgs`'s key therefore
  > cannot silently desynchronise `armedPending()` from it, because the two were never synchronised —
  > they answer different questions over different populations (live DOM vs the set we armed), and
  > every disagreement between them is deliberate and documented at the call sites: a withheld image
  > (skipped by the width arm, pending forever for the census — that IS this dead zone), a detached
  > armed image (invisible to the walk, still pending for the census), an image injected after
  > documentEnd (pending for the walk, never armed so never counted), and the
  > `<img src="cid:…" srcset="https://…">` shape whose local `load` settles the record while
  > `data-tmsrcset` is still present.
  >
  > **What the bullet still forbids, and where the live lockstep surface actually is.** Restating the
  > displayability key is still banned. That key currently has TWO spellings in
  > `postImageWidthRecheckJS`: `pendingImgs`'s `data-tmsrc || data-tmsrcset || !complete`, and the arm
  > loop's `im.complete && !data-tmsrc && !data-tmsrcset` skip, which is its exact negation. That pair
  > is byte-identical before and after `1051ecbf6` — it is pre-existing, not something the census
  > change introduced — and it is the pair a future edit can drift, because changing which images are
  > *pending* without changing which images are *armed* silently changes the census's population.
  > Check both when you touch either.
- ⛔ **Do not report early** (e.g. on a timer, or on the first `error`). "Report before the last armed
  image settles" is exactly the property `imageFailureCensusReportsErroredRemoteImages` pins, and
  reporting early can only produce a banner on a page that then goes on to load everything.
- ⛔ **Do not "solve" it by re-requesting the withheld images.** That manufactures the tracking hit
  `IOS-PRIVACY-003` was written to remove.

## Attribution class

⚠️ **PARTIALLY FALSIFIED 2026-08-13 by `IOS-UI-005` — do not quote the paragraph below without this
correction.** The `tm-*` class namespace is **not reserved against sender-authored markup**, and
`EmailHTMLWrapper.wrapHTML` never strips, rewrites or namespaces author `class` attributes. So a
sender can write `<div class="tm-eml-section"><img src="https://…"></div>` in the body; the app's own
main-view `!important` rule hides it, `swap()` therefore **withholds** the image, `data-tmsrc` is
retained and, for a remote-only image that receives no event, `armedPending()` never reaches 0 and
**the census never posts**. That is a sender
*causing* the dead zone directly, with no attached `.eml` and no user inducement — which is precisely
what the paragraph below denies.

The rest of the paragraph survives: the result is still **strictly less UI, never a false statement**,
and severity remains low because a sender can already suppress the census with a hanging image URL that
fires neither `load` nor `error`.

⚠️ **This route runs through the `tm-eml-section` arm, so gating the `tm-eml-headers` arm does NOT
close it.** A forged `.tm-eml-section` is hidden by `.tm-eml-section { display:none !important }`,
and that arm of `hiddenByViewMode` is **unconditional** — it is the one arm claimed in both modes —
so a forged section can keep a remote-only image withheld and armed; if that image receives no
terminal event, `armedPending()` never falls to 0.

> ⚠️ **CORRECTION, 2026-08-13 — the sentence that used to follow was TOO BROAD and must not be
> quoted.** It read *"Anyone fixing the headers arm must not record this dead zone as narrowed"*,
> which is right about the route above and wrong about the dead zone as a whole. `tm-eml-section`
> and `tm-eml-headers` are two INDEPENDENT routes into one settle predicate, and `7f8c40eb2` moved
> exactly one of them. Read as written the sentence forbids recording a narrowing that genuinely
> happened — and `fca415f3a` did record it, in the comment at `hiddenByViewMode`. A reader holding
> both documents sees a flat contradiction where there is none: both are correct, about different
> routes. **Name the route, always.**

| Route into the dead zone | Its `hiddenByViewMode` arm | Status |
|---|---|---|
| App-emitted `.tm-eml-section` containing at least one non-settling armed image | unconditional (main **and** preview) | **OPEN.** Untouched by `7f8c40eb2`. This is the route this entry is scoped to. |
| Sender-authored `.tm-eml-section` (`IOS-UI-005`) | the same unconditional arm | **OPEN.** Same mechanism, sender-triggered rather than attachment-triggered. |
| Sender-authored `.tm-eml-headers` | gated on `preview` since `7f8c40eb2` | **CLOSED IN MAIN VIEW.** No main-view rule of ours hides that class, so the images swap, reach a terminal state, and the census can publish. Still withheld inside the preview sheet, where `body.tm-preview-mode .tm-eml-headers` genuinely applies. |

App-emitted `.tm-eml-headers` is not a fourth row. The ancestor walk is inside-out: in preview mode
it can encounter the headers arm first; in main mode that arm is gated out and the walk continues to
the enclosing `.tm-eml-section`. More fundamentally, `EmlMarker.build`'s generated header markup
contains no image today. Row one therefore covers the actual app-generated image population without
the former false claim about traversal order.

So a fix to the headers arm **may** be recorded as narrowing the dead zone *for the sender-authored
headers route in main view*, and **may not** be recorded as narrowing it for either
`.tm-eml-section` route. This entry stays OPEN because its scope is row one's non-settling-image
condition, which nothing has moved; the presence of an attachment alone is not the predicate.

<details>
<summary>Superseded attribution paragraph, preserved</summary>

Not attributable to a sender, not reachable by a sender's choice in any useful direction — a sender
cannot *cause* the dead zone except by inducing the user to open a message that carries an attached
`.eml`, and the result is strictly less UI, never a false statement.

</details>

## Pinned by

`EmailRenderPipelineTests` — `imageFailureCensusReportsErroredRemoteImages` (never before the last
armed image settles), `imageFailureCensusSettlesOnTheArmedSetNotTheLiveDOM` (the registry remains
authoritative even after DOM detachment), `widthRefitIgnoresWithheldImagesButTheCensusDoesNot`
(width and census answer different questions), and `imageFailureCensusNeverRetries` (no re-request
path exists).

## Relates

`ADR-IOS-076` (P4 landing note and decision 7), `IOS-PRIVACY-003` (the withholding that creates the
dead zone), `ADR-IOS-039` (render idempotency — why the banner lives outside the document), and the
routed memory topic
`Companion/Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md`.
