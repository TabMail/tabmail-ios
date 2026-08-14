## ADR-IOS-076: The Message Document Is Untrusted Content, Enforced at the WebKit Boundary

**Date:** 2026-08-11

**Status:** Active. Specification frozen 2026-08-11 (owner). The frozen text is
`PLAN_EMAIL_RENDER_SECURITY.md` §8.4 + §9.1 (B1–B3) + §10.1 (C1–C5) + §2.9 (T11), implemented in the
commit order of that plan's §11. Any later change to this specification is an audit finding against a
commit candidate, not a plan revision.

**Context.** The message document is **fully attacker-controlled input**. Anyone who can send mail to
the user authors it; there is no origin authentication, no reputation gate, and **no user gesture
between arrival and render** — the detail view renders on open and `MessageCardView` renders expanded
cards inside a list. Against that, the shipped renderer treated the document as ordinary web content:

- `HTMLWebView.makeUIView` sets `config.defaultWebpagePreferences.allowsContentJavaScript = true`, so
  sender-authored script executes on open.
- No sanitizer exists in the render path. `EmailHTMLWrapper.wrapHTML` strips exactly three things —
  `loading="lazy"`, external stylesheet `<link>`, and remote `img src` → `data-tmsrc`. `<script>`,
  inline event-handler attributes, `javascript:` URLs, `<iframe>`, `<form>`, `<object>`/`<embed>` and
  `<meta http-equiv="refresh">` pass through untouched. SwiftSoup is a declared SPM dependency, but
  its only occurrence in the app source is the credits list in `AcknowledgmentsView`; it cleans
  nothing. `EmailFilter`'s `<script>`/`<style>` skipping is the **plain-text extraction** path
  (snippets, AI input) and must never be cited as a render-path sanitizer.
- The Content-Security-Policy emitted by `wrapHTML` consists solely of `upgrade-insecure-requests`.
  A CSP delivery vehicle therefore already exists — this decision **extends one meta tag**, it does
  not introduce a mechanism.

All four render call sites share the one `WKWebViewConfiguration` built in `HTMLWebView.makeUIView`:
two in `MessageCardView`, one in `EmlAttachmentPreview` (an attacker-supplied `.eml`, opaque origin),
one in `ComposeView` (the quoted original rendered inside compose). All four inherited content JS.

This is **shipped behaviour, not a regression** — the security-relevant sequence is byte-identical at
the immutable tag `v1.7.8` and at the plan's HEAD `ef5457ba7` (A1 verified; the plan's positional
citations are pinned to that tag, which is the only form of `file:line` citation this repo accepts —
everything named in this ADR is a symbol). There was no shipped mitigation to inherit, so shipped is
the thing being fixed.

**Decision.** The message document is untrusted content, and that is enforced **at the WebKit
boundary** — configuration, navigation policy, and asset authorization — rather than by trying to
make attacker HTML safe.

1. **Author JavaScript is disabled; app-injected scripts are unaffected — by CSP's scope, not by
   luck.** `allowsContentJavaScript = false`, together with the full policy
   `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: data:
   tabmail-asset:; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none';
   connect-src 'none'; form-action 'none'; base-uri 'none'; upgrade-insecure-requests`.

   **↳ AMENDED 2026-08-12 (owner): `font-src 'none'` → `font-src https:`.** The policy quoted just
   above is preserved as P1b shipped it; the live value is `EmailHTMLWrapper.contentSecurityPolicy`,
   and the two now differ in exactly that one directive. A device smoke test measured enforced
   `font-src` blocks on a real marketing email's web font, and the owner relaxed the directive under
   *"no behaviour changes, just security"* — the anti-tracking rationale being inconsistent with the
   open `img-src https:` in the same policy. The **font leg of T9 is therefore OPEN and
   owner-accepted** (`IOS-PRIVACY-002`); `media-src 'none'` was explicitly retained. Do not read the
   quoted string as shipped state.

   The `WKUserScript`s registered in `HTMLWebView.makeUIView` (≈17 at plan time) and the `fit()` /
   `resetAndFit()` `evaluateJavaScript` calls **keep working**: WebKit evaluates injected user-script
   source directly, and `script-src` governs *document-requested* script mechanisms — `<script>`
   elements, `javascript:` URLs, `eval`/`Function` — not host-application injection.
   **Negative case, because this is an absolute that will be tested by future code:** the property
   holds for the current scripts *because none of them contains a `script-src`-sensitive construct* —
   `rg "eval\(|new Function|createElement\('script'"` over `AutoSizingHTMLView.swift` returns zero
   matches. A future injected script that calls `eval`, constructs a `Function`, or appends a
   `<script>` element **is** document-requested script and `script-src 'none'` will block it. Pin
   that with a source-level test rather than rediscovering it on device.
   This was **contested and resolved**: round 1's premise that page-world user scripts are subject
   to the document CSP — which would have made `WKContentWorld` isolation a prerequisite for the CSP —
   was refuted (plan §8.1). `WKContentWorld` demotes to defense-in-depth; the CSP ships with the
   config hardening.
   Also in this layer: per-message `WKWebsiteDataStore.nonPersistent()` (a *shared* ephemeral store
   still permits within-session correlation — only per-view stores draw the boundary),
   `allowsLinkPreview = false` (unset today; long-press preview is another non-delegate route), and an
   explicit `dataDetectorTypes` decision rather than an inherited one.
   **↳ NOT ADOPTED, 2026-08-12 (owner). Both of the first two were shipped by P1b and then REVERSED
   by explicit owner directive** — *"no behaviour changes, just security"* — back to `v1.7.8`'s
   state, which for both is **unset**. So the store stays `WKWebsiteDataStore.default()` (one
   process-wide **persistent** jar shared across every message and every sender: **T5 is OPEN and
   owner-accepted**, `IOS-PRIVACY-001`) and long-press preview stays ON (a second non-delegate fetch
   route, `IOS-UI-003`, see decision 6). The data-store reversal was made **against the implementing
   side's recommendation**, which was to keep the ephemeral store; it is recorded that way rather
   than rewritten. Only the third — the explicit `dataDetectorTypes` decision — survives from this
   sentence, and its value is `[.link, .phoneNumber]`. **Do not read this paragraph as shipped
   state.**

2. **The navigation permit is an unguessable per-load NONCE, not a fixed URL shape.** Immediately
   before each app-owned `loadHTMLString`, exactly one main-frame load permit is armed for that load
   generation. The expected shape is `targetFrame != nil && targetFrame!.isMainFrame`
   **and** `navigationType == .other` **and exact string equality** of
   `request.url.absoluteString` against a per-load synthetic URL carrying **≥128 random bits** and no
   fragment — compared against the URL we supplied, never after `URLComponents` normalization
   (parser disagreement is the bug). For persisted messages the nonce goes in the **path**
   (`tabmail-asset://asset/_tm-document/<nonce>/`), preserving the existing scheme/host origin so
   absolute asset URLs are unaffected. HTTP method, headers, cache policy, `mainDocumentURL`,
   source-frame fields and `URLRequest.attribution` are explicitly **not** security-critical: they add
   mismatch risk without strengthening a nonce-backed correlation. Everything else on the main frame
   is cancelled; subframe actions are always cancelled; `targetFrame == nil` is treated as a
   new-window / `target="_blank"` action, not an ordinary subframe.

   **Why the nonce is load-bearing even with JavaScript off — state this before simplifying it away.**
   `<meta http-equiv="refresh" content="0;url=…">` navigates the main frame with **no script at
   all**, and a *fixed* expected shape (`tabmail-asset://asset/`, `about:blank`) is a URL the message
   document can simply name. A fixed-shape permit is therefore **forgeable by a JS-disabled
   document**, which is exactly why this mechanism is not redundant with decision 1. The second,
   independent failure of a generation-only permit: a `WKNavigationAction` carries no generation, so
   an action from the *previous* document can arrive while the *new* generation's permit is armed and
   consume the wrong permit.

   This complexity was challenged under A2 (three consecutive vet rounds returning blockers: shipped
   `.linkActivated`-only → "cancel non-user main-frame navigation" → "permit keyed to load
   generation" → nonce + `WKNavigation` correlation) and **survived the challenge on the meta-refresh
   vector above**. It stays argued, not assumed.

3. **`.linkActivated` does not prove a user gesture.** `HTMLElement.click()` dispatches a simulated
   click; anchor activation passes that event to the loader; WebKit classifies any event-backed
   non-form navigation as `LinkClicked` and Cocoa maps it to `.linkActivated`. A scripted
   `anchor.click()` is therefore **reported identically to a real tap**, and the true gesture bit lives
   in WebKit's *private* `_isUserInitiated`. The rule "cancel non-user navigation, allow
   `.linkActivated`" is **not expressible through public API** and must not be written down as if it
   were. The permit of decision 2 exists precisely because the public delegate cannot express "a real
   tap". After the permit is consumed, an eligible `.linkActivated` is handled externally/internally
   **and its WebKit navigation is cancelled**; every other main-frame action is cancelled.

4. **The permit is consumed at POLICY time; everything after is correlated by the returned
   `WKNavigation`.** `loadHTMLString` returns a `WKNavigation?` but `decidePolicyFor navigationAction`
   never receives it — hence two states. Consume the pending permit immediately before returning
   `.allow`; from then on the returned `WKNavigation` is the key. The ways to get this wrong, each of
   which is part of the spec:
   - A **rejected** action clears the permit **only if** it presented the expected nonce URL and
     failed another check. An unrelated rejection must never clear a live permit, or an
     old/subframe/user action cancels a legitimate app load.
   - `didReceiveServerRedirectForProvisionalNavigation` is **never normal** for substitute data: if it
     fires on the tracked navigation, invalidate and `stopLoading` — do not treat a following `.other`
     as a continuation.
   - `didStartProvisionalNavigation` / `didCommit` / `didFinish` / both failure callbacks do
     **idempotent, identity-matched** cleanup only. Failure-after-commit cannot leak the permit
     precisely because it was consumed at policy time.
   - `webViewWebContentProcessDidTerminate` must invalidate **both** states before the existing
     recovery load, which then gets a fresh generation, nonce, permit and `WKNavigation`.
   - **Do NOT add `decidePolicyForNavigationResponse`.** WebKit builds the substitute-data response
     with an **empty URL**, so URL-equality correlation there would reject legitimate loads.
   - Overlapping loads (message switching, `reloadToken`, appearance flip, process recovery) are
     **supersession, not an assertion failure**: bump generation → invalidate the older pending permit
     → the new load arms a new nonce → callbacks act only when generation *and* `WKNavigation` match,
     so an old callback never clears newer state.

5. **Asset authorization binds to manifest OWNERSHIP keyed by `MessageBody.id`, and view identity must
   include that key.** `BodyAssetSchemeHandler.webView(_:start:)` currently serves **any** asset id
   the document names, via the unrestricted `BodyAssetStore.read(assetId:)` +
   `BodyAssetStore.contentType(assetId:)` pair, with nothing bound to the rendered message. The
   replacement is one store operation returning authorized metadata **and** bytes, serving only when
   the manifest holds a row whose exact `id` equals the parsed asset id, whose `headerId` equals the
   handler's `ContentKey`, **and whose `kind` is `.inlineImage`** (which also stops message HTML from
   reading the same message's *file attachments*). It additionally requires a canonical URL shape:
   correct scheme, no userinfo/port/query/fragment, exactly one host and one path segment, both
   expected-length lowercase hex, no encoded separators — `BodyAssetStore.assetId(fromURL:)` today
   accepts non-hex and ignores extra path segments. Add `X-Content-Type-Options: nosniff` and a MIME
   allowlist with exact normalization (trim, split at `;`, lowercase), because the handler echoes a
   stored, attacker-influenced content type; `nosniff` is defense-in-depth, **not** content validation.

   Three constraints inside this one, each of which a simplifying reader will get wrong:

   - **The key is `MessageBody.id` (a `ContentKey`), NOT a key rebuilt from `MessageHeader.id`.**
     `MessageBody.id` is declared `var id: ContentKey` and is the body's authoritative key, while
     `MessageHeader.id` is a plain `String`. `MessageBody`'s own doc comment already enumerates the
     trap: of 57 `MessageBody.<method>(db, key:)` lookup sites, **35 pass an unwrapped string** that
     compiles with no cast, no warning and no diagnostic. `AutoSizingHTMLView` carries
     `headerId: String?` today, so this is a plumbing change, not a rename.
     Note also what this replaces: an earlier revision said "bind the handler to the current header
     hash", which is **wrong for moved messages** — `BodyAssetStore.rekeyContentKey(from:to:)`
     deliberately re-points manifest rows after a move while preserving the row `id` and the bytes on
     disk (its own doc comment states that the embedded `tabmail-asset://` URL therefore keeps the
     OLD `headerHash`), so a computed
     `headerHash(currentHeaderId)` would reject the legitimate assets of every moved message. Under
     the ownership predicate the moved case is *correct*: the unchanged URL is authorized by the
     re-keyed row once the view reopens under the destination `ContentKey`.
   - **A `WKURLSchemeHandler` is installed ONCE on the configuration and `updateUIView` cannot replace
     it.** `setURLSchemeHandler` occurs exactly once in `AutoSizingHTMLView.swift`, inside
     `HTMLWebView.makeUIView`. SwiftUI may reuse the platform view across an update in which the body
     `ContentKey` changes (row identity is `stableId`), so a handler bound at construction goes stale
     in **both** directions — legitimate assets denied for the new document, and an old asset servable
     to a new document that names its id. **Asset ids are not secrets**, so this needs a structural
     fix: the representable's identity must include the body `ContentKey`, so the `WKWebView` is
     recreated when it changes.
   - **Each `nil`-`ContentKey` call site chooses explicitly** — carry the source `MessageBody.id`, or
     accept that local assets are unavailable. Compensating with an unrestricted asset lookup is
     forbidden. (`ComposeView`'s quoted body and `EmlAttachmentPreview` resolve differently; see
     *Consequences*.)

6. **Externally dispatched URLs are scheme-allowlisted, with its exception stated.** Compare
   `navigationAction.request.url.scheme` ASCII-case-insensitively to `http`/`https` with a non-empty
   host before `UIApplication.shared.open`; do not re-parse, percent-decode, or rebuild via
   `URLComponents`. Today `MailtoRequest.parse` returns nil for any non-`mailto` scheme and everything
   else is opened unconditionally — `tel:`, `sms:`, `facetime:`, `itms-apps:`, any installed app's
   scheme.
   **The negative case is mandatory here:** *"every externally dispatched target passes through our
   http/https allowlist"* is **FALSE while data detectors are enabled**. With
   `dataDetectorTypes = [.link, .phoneNumber]`, WebKit's anchor-activation path can present Data
   Detectors UI *before* `changeLocation`, so a detected phone number may never reach the navigation
   delegate at all. Either set `dataDetectorTypes = []` or retain it as a **documented system-UI
   exception with its own test** — but do not state the absolute without it. Note also that http/https
   still permits a **universal link into an installed app**; if "must open in a browser" is the actual
   requirement, that is `SFSafariViewController`, not an allowlist.
   **↳ RESOLVED 2026-08-12 by the owner: the SECOND branch is taken — detectors stay ON
   (`dataDetectorTypes = [.link, .phoneNumber]`) and the exception is documented.** P1b took the first
   branch (`[]`) and the owner reversed it the same day: *"still link and phone numbers are important
   for a phone email app. have them back. Again, no behaviour changes, just security"*. The narrower
   `[.phoneNumber]`-only compromise was put to the owner and **explicitly overruled**. So the absolute
   above is permanently FALSE in this app and the sound statement is *"every `.linkActivated` target
   passes the `http`/`https` allowlist"*. The exception is registered as `IOS-UI-002`; the "its own
   test" half is `EmailRenderSecurityCanaryTests.productionConfiguration`, which pins the non-empty
   value positively — with the caveat, stated here because it is the whole point of B2, that **no
   delegate-level test can observe the detector dispatch path itself**. Authored `<a href>` links are
   unaffected by `dataDetectorTypes` and still reach `decidePolicyFor`; detectors govern only
   plain-text numbers and bare URLs.
   **↳ SECOND EXCEPTION, added 2026-08-12: long-press LINK PREVIEW (`IOS-UI-003`).** The owner also
   directed `allowsLinkPreview` back to UNSET (the WebKit default, ON) — `v1.7.8`'s shipped
   behaviour — under the same *"no behaviour changes, just security"*. Preview **fetches and
   presents** the remote URL without producing a `decidePolicyFor` decision, so that fetch does not
   pass this allowlist either, and no delegate-level test can observe it. The absolute now has
   **two** exceptions, not one; qualify every restatement with **both**. The negative case is
   pinned positively by `EmailRenderSecurityCanaryTests.productionConfiguration`
   (`allowsLinkPreview == true`), so a silent change in either direction fails.

7. **The bridge is validated in Swift, because every clamp that lives in our page-side JS is
   advisory.** The three `WKScriptMessageHandler` channels — `heightChanged`, `consoleLog`,
   `gutterAdjust` — are registered in the page world, so any document JS can post to them and simply
   not call our clamps. Validate `heightChanged` heights as finite and non-negative, clamp
   `gutterAdjust` to `[0,16]` **in Swift**, rate-limit fit requests, and move the one-shot guards
   (`__tmFitRequested`, `__tmWidthRefitRequested`) into **Swift** state. An arbitrary height ceiling
   was specified first and then **rejected**: it truncates a legitimately long newsletter and buys
   little once content JS is off. `connect-src 'none'` does not affect `webkit.messageHandlers` —
   it is not a fetch/XHR surface — so the CSP does not close this on its own.
   **↳ BOTH FACTS IN THE OPENING SENTENCE ARE NOW STALE, and they went stale in different phases —
   do not restate either half without the other.** (a) *"registered in the page world"* was falsified
   by **P3** (`c026f96d5`): every channel is now added with `add(_:contentWorld:name:)` in
   `RenderContentWorld.isolated`, so the document has no `webkit.messageHandlers` object to post to
   at all, and each handler additionally refuses a message that did not originate in the main frame.
   (b) *"three"* was falsified by **P4** (this ADR's last phase): there are **four** —
   `heightChanged`, `consoleLog`, `gutterAdjust`, `imageLoadFailure`. The single source of the list is
   `HTMLWebView.bridgeChannels`; count it there rather than restating an integer.
   ⚠️ **Neither change retires the decision.** Isolation is a WebKit configuration, and four of P1b's
   five settings were reversed by owner directive within a day of shipping — so page-world
   reachability is one setting away from returning, and the Swift-side validation stays the layer that
   does not depend on it. `imageFailureReport` is validated on exactly that principle: it is dropped
   whole (never coerced, never clamped, no ceiling-clamping "plausible" branch) on a non-dictionary, a
   missing half, a non-`NSNumber`, a negative/non-finite/fractional value, a count past
   `maxReportedImageCount`, or `failed > deferred`.

8. **`wrapHTML` is the only document builder.** *`EmailHTMLWrapper.wrapHTML` MUST always emit one
   complete app-owned document with the app CSP in `<head>` before any author-controlled element; no
   caller may load raw message HTML.* Meta-CSP delivery is appropriate for `loadHTMLString` with a
   custom-scheme base URL, and the fragment case is safe *because* of this invariant — an author CSP
   meta can only combine restrictively. `frame-ancestors`, `sandbox` and `report-uri` are
   **header-only** and silently ignored in a `<meta>` CSP: do not add them there and assume coverage.

9. **The one BRICK-class item ships first and alone.** `EmlAttachmentPreview.downloadAndPreview`
   writes fetched bytes using the **raw MIME filename**, so a nested part in an attacker-supplied
   `.eml` declaring `filename="../Library/Application Support/TabMail/tabmail.sqlite"` escapes the
   staging directory and overwrites the live GRDB store — a launch crash before any UI appears, plus
   destruction of undrained `PendingOperation`/`OutboxMessage` rows. Two taps, no gesture beyond
   opening the attachment. It routes through `AttachmentPreviewStager.stage` — **not**
   `stageAndPresent`, because this view presents declaratively via `.quickLookPreview` and has no
   presenter `Bool`; a `{ true }` stub would be a lie in the source that also disarms the
   discard-on-refusal contract. This is a half-port: the sibling site already calls the stager and is
   already pinned by `AttachmentPreviewStagingTests.craftedFilenameStaysInsideItsAttempt` — and
   the missing piece here was the CALL SITE, not the stager, which is why that test protected
   nothing here.
   ⚠️ **Retracted 2026-08-12:** this passage originally read "**the stager was already correct**",
   which was an absolute and is false. `05200112d` fixed `AttachmentPreviewStager.displayFilename`
   accepting a separator-bearing name (`"/"` reduced to `"/"`, collapsing back to the attempt
   directory), and `7ce64e44b` fixed the same reduction missing a `U+002F` hidden inside a grapheme
   cluster, plus `discardAttempt` deleting the per-message NAMESPACE rather than the attempt. The
   scoped claim — the traversal at this call site was a half-port, not a stager bug — survives; the
   absolute does not. Recorded as MIS-019 instance 13.
   The fix lands
   with a test that goes red on pre-fix code **at the `downloadAndPreview` call site**, pinning the
   invariant *no attachment write escapes the staging root*, not the mechanism *`stage` was called*.

**Rationale.** A renderer that executes sender script is not one bug; it is the enabling condition for
silent in-app navigation to attacker-controlled pages (chrome-less, address-bar-less, indistinguishable
from app UI — the highest practical severity in the review), for programmable surveillance beyond the
tracking-pixel baseline, and for spoofing the Swift bridge. Closing it at the configuration is a
small, revertible change with no parser-equivalence bet, which is why it outranks sanitizing the HTML.
The mechanisms layered on top exist because two public-API facts do not match intuition: the delegate
cannot tell a tap from a scripted click (decision 3), and a document with no script at all can still
navigate the main frame to a URL it names (decision 2). Asset authorization moved from a *secrecy*
argument to an *isolation* argument for the same reason — the original "ids are hashes, therefore not
enumerable" verdict was 64-bit truncated SHA-256 over inputs the sender knows, i.e. a refusal to fix
carrying a fix's evidentiary burden.

**Alternatives considered and rejected.**

- **An HTML sanitizer as the primary defence — DEFERRED, not chosen (owner question Q3, still open).**
  Once author script is off, `<script>`, inline handlers and `javascript:` URLs are already inert and
  the CSP covers `frame-src`/`object-src`/`form-action`; a DOM sanitizer would be a third overlapping
  layer for one threat. If it is later wanted, SwiftSoup is already a dependency with
  `Cleaner`/`Safelist` — use that, not more regex on the wrapper. **This is a deferral, not a
  finding of no value:** the plan separately records that the wrapper's regexes do not preserve HTML
  parsing semantics, and that SwiftSoup is the right tool for that *structural transform* — a
  distinct question from the sanitizer.
- **Per-domain ATS exceptions — impossible, not merely undesirable.** The reported broken-image
  symptom is ATS working as designed: the failing host negotiates a static-RSA cipher with no forward
  secrecy, so `NSExceptionRequiresForwardSecrecy` would be the fix — but it can only be authored
  **per domain**, and sender domains are arbitrary and unbounded. `NSAllowsArbitraryLoadsInWebContent`
  is rejected as well: it weakens web-content ATS for every email to fix a minority of
  senders. An image proxy is rejected as new infrastructure that would relay the tracking hit through
  us, contradicting the zero-retention posture of the cross-cutting ADR-004.
- **A mutable scheme-handler key instead of recreating the view — rejected as worse.** In-flight
  `WKURLSchemeTask`s would straddle the mutation. The structural fix (view identity includes the body
  `ContentKey`) is the one adopted in decision 5.
- **Serving an empty 200 instead of failing the URL task — rejected.** `BodyAssetSchemeHandler`
  already fails with one uniform `URLError(.resourceUnavailable)`, and that is kept: malformed,
  unowned, wrong-kind and missing-file must stay **indistinguishable** at that boundary. A failed
  request still fires the DOM `error` event, so the view's load/error listeners settle; an empty
  success would look like a completed transaction and hide authorization failures.
- **`WKContentWorld` isolation as a prerequisite — demoted, not dropped.** It was believed to gate the
  CSP; that premise was refuted (decision 1). It remains worth doing as defense-in-depth, since it
  also removes `window.__tmLayoutVp`, `__tmFitDone` and friends from the document's reach.

**Consequences — accepted costs and the limits of the guarantee.**

- **State the guarantee accurately: *no unapproved new main-frame document is admitted*.** It
  deliberately does **not** claim that every fragment navigation or history-state mutation is
  prevented — same-document behaviour is not uniformly surfaced through the public delegate lifecycle.
  Cross-document back/forward *is* delegated as `.backForward` and is cancelled by default-deny. A
  same-document mutation does not replace the trusted document.
- **CSS-only tracking survives entirely (T9, deferred).** `<style>` blocks are deliberately preserved
  by `wrapHTML`, and the deferral rewrite touches only `<img src/srcset>` — CSS `background-image`
  URLs are never deferred, and `@font-face` + `unicode-range` is a conditional-request channel.
  Disabling JavaScript does not close this, and `font-src 'none'` only narrows it. Deferring CSS URLs
  is materially harder than deferring `<img>`; it needs a design and is the owner's call.
  **↳ AMENDED 2026-08-12: the font half of T9 is no longer even narrowed.** `font-src` was relaxed
  to `https:` by owner directive, so `@font-face` + `unicode-range` conditional requests reach the
  network again for absolute-`https:` URLs. T9 is now **fully open and owner-accepted**, registered
  as `IOS-PRIVACY-002`. ⚠️ **Do not read the residual `tabmail-asset:` font blocks as a surviving
  mitigation.** Protocol-relative `//host/path` CSS fonts resolve against `BodyAssetConfig.baseURL`
  and so arrive as `tabmail-asset://<host>/…`; `v1.7.8` used the same base and its
  `BodyAssetStore.assetId(fromURL:)` demanded a fixed-length hex host, so those requests already
  failed at the scheme handler with `URLError(.resourceUnavailable)`. They were never a tracking
  channel because they were never fetched — and widening `font-src` to admit them would load
  nothing, since `canonicalAssetId` refuses a non-hex host.
- **Per-message ephemeral data stores cost image cache reuse.** Remote images re-fetch per render.
  Accepted deliberately in exchange for removing cross-message correlation of the same reader.
- **The cross-database move window can produce temporarily broken images.** The message-header re-key
  notification can precede `publishMoveFinish`, so a destination-key view can load HTML before the
  asset manifest has re-keyed. The result is **temporary broken images, not cross-message
  disclosure**; reordering the notification after the asset re-key narrows it. Recoverable, therefore
  registered rather than gating (THE MANTRA).
- **Compose quoted-reply inline images are already broken on shipped code and must not be attributed
  to this work.** `ComposeView` renders `quotedHTML` sourced from
  `ComposeDraftGuards.outboundQuoteBody` — the persisted `MessageBody.htmlContent`,
  into which `BodyRenderer` bakes `tabmail-asset://` URLs whenever an inline-image writer is supplied
  — while compose passes `headerId: nil`, so no scheme handler is registered at all. Pre-existing,
  filed separately. `EmlAttachmentPreview` is **likely** provenance-free (its HTML is parsed from the
  attachment's own bytes, and the code comment states that intent), but intent is not proof: confirm
  during implementation rather than assuming.
- **The P1 family's acceptance is a device smoke test, not a green unit suite.** The pipeline is
  callback-heavy — `ResizeObserver` height reports, the double-`rAF` reveal and its liveness timer,
  the deferred-image swap and failsafe, the post-load width recheck, the aspect-ratio rescan, and the
  "Show quoted text" / "Show invite details" tap handlers. These are app-world and *should* survive,
  but a silent break in one is the regression to hunt, and `EmailRenderPipelineTests` asserts JS
  *source strings* through JSContext, so it cannot observe WebKit's content-JS gate at all. The gate
  is: quoted-reply toggle, calendar invite pill, image-heavy newsletter, wide desktop-layout email,
  dark-mode flip — on a real device.
- **The banner of the plan's last phase is a post-hoc notice, not the reverted experiment.** A
  *block-with-banner* design was implemented, smoke-tested and **reverted 2026-06-17** because it
  changed loading behaviour and broke messages whose layout depends on images. The phase specified
  here reports failures that already happened and leaves loading behaviour untouched; the revert is
  not precedent against it. It stays observational — no retry, no probe, no HEAD request, since
  re-requesting a failed URL manufactures the tracking hit the deferred-image design exists to bound.
  **↳ LANDED as P4 (2026-08-13), and the observational constraint is now a TEST, not a promise.**
  `EmailRenderPipelineTests.imageFailureCensusNeverRetries` is a static guard over the emitted
  `postImageWidthRecheckJS` source asserting the absence of `fetch(`, `XMLHttpRequest`, `new Image`,
  `HEAD`, `setAttribute('src'`, `setAttribute('srcset'`, `.src =` and
  `removeAttribute('data-tmsrc'` — i.e. it can neither re-request a URL nor change WHICH images load.
  ⚠️ **The banner is also NOT a claim that anything was blocked**, and the copy is pinned
  (`theCopyDoesNotOverclaim`) so it cannot drift into describing the reverted design: `onerror` fires
  for a 404, a DNS failure, malformed image bytes and an offline device just as it does for an ATS/TLS
  refusal, and WebKit gives the page no signal that separates them. The sentence therefore hedges
  ("may not"), names no domain and states no count. That imprecision is ACCEPTED, not unnoticed.

**Tests / evidence.** ⚠️ **Corrected 2026-08-12.** This section originally read "This ADR records a
decision **ahead of implementation**; no code has landed under it." That was already false when the
ADR was committed, and a reader routed here by `rg` sees this file rather than the commit body that
stated it correctly.

**Implementation status.** ⚠️ This paragraph goes stale every time a commit lands. It was already
stale 32 minutes after it was first written (an audit round caught it), so treat a date on it as a
LOWER BOUND, not a guarantee — re-derive from `git log` before relying on it.

As of 2026-08-12, decisions 9 (`.eml` nested-attachment path traversal, T11), **1 (content-JS
disablement + the CSP)** and **the per-message ephemeral store half of decision 5** have **LANDED**.

**P1b (2026-08-12)** landed, in one commit, the configuration half of decision 1 plus the policy:
`allowsContentJavaScript = false`, `websiteDataStore = .nonPersistent()` per web view,
`dataDetectorTypes = []`, `allowsLinkPreview = false`, and the §8.4 CSP extended from
`upgrade-insecure-requests` to the full twelve-directive policy in
`EmailHTMLWrapper.contentSecurityPolicy`. **⚠️ FOUR owner-directed reversals have since landed, all
on 2026-08-12, all under *"no behaviour changes, just security"*. THREE are whole settings reverted
to `v1.7.8`'s shipped state; the FOURTH is a single directive inside the CSP, which is why the count
of reverted SETTINGS (three) and the count of REVERSALS (four) differ — do not restate either number
without the other:**

- `dataDetectorTypes` → `[.link, .phoneNumber]` (see decision 6's resolution note and `IOS-UI-002`).
- `allowsLinkPreview` → **unset**, i.e. WebKit's default ON. Long-press preview fetches and presents
  a remote URL outside `decidePolicyFor`, so this is a **second** exception to the `http`/`https`
  allowlist absolute — `IOS-UI-003`, decision 6's second resolution note.
- `websiteDataStore` → **unset**, i.e. `WKWebsiteDataStore.default()`. **T5 is therefore OPEN and
  owner-accepted** (`IOS-PRIVACY-001`): one process-wide persistent cookie/localStorage jar shared
  across every message and every sender, surviving launches, reachable by remote subresources with
  no sender script. This reversal was made **against the implementing side's recommendation**.
- **`font-src` within the CSP → `https:`** (the fourth reversal, and the only partial one — the CSP
  itself stands). A device smoke test measured enforced `font-src` blocks on a real marketing
  email's web font. The **font leg of T9 is OPEN and owner-accepted**, `IOS-PRIVACY-002`.
  `media-src 'none'` was explicitly retained in the same directive. Note this restores every remote
  font that ever worked; it is NOT a partial restoration except for `data:` fonts, which `v1.7.8`
  permitted and this policy still refuses. ⚠️ A reversal *inside* a surviving item, so "only two of
  the five stand" below is about the five P1b SETTINGS and must not be read as "nothing else was
  relaxed".

**Only two of the five stand: `allowsContentJavaScript = false` and the twelve-directive CSP — and
the CSP stands as a policy while one of its twelve directives (`font-src`) was itself relaxed on
2026-08-12; it is still twelve directives, not eleven.**
Two consequences that are easy to overstate and must not be:

- **P1b does NOT close main-frame navigation.** A `<meta http-equiv="refresh">` in the body still
  navigates the main frame with JavaScript disabled — measured by the P1a canary before P1b and still
  asserted after it (`metaRefreshForgesAnAppLoadShape`, `appScriptsSurviveTheJavaScriptGate`). Only
  decision 2's per-load nonce permit (P1c) closes it. Anyone reading "author JS is off" as "the
  document cannot navigate" is wrong.
  **↳ P1c has since landed and closes it** — but note that those two canary assertions still PASS by
  design and are NOT the regression guard for it. They observe WebKit's raw behaviour through a bare
  probe delegate that has no permit; a forged `<meta refresh>` still *produces* an app-shaped
  navigation ACTION. What changed is the *decision* the production coordinator returns for it, which is
  what `metaRefreshIsRefusedByTheProductionCoordinator` pins.
- **The ephemeral store is per VIEW, not per MESSAGE.** SwiftUI may reuse one platform view across a
  change of rendered message; binding view identity to the body `ContentKey` is decision 5's other
  half and is P1d. `dataDetectorTypes = []` also cost a user-visible affordance, registered as
  `IOS-UI-002` — **and that cost was rejected by the owner and reversed on 2026-08-12**: detectors are
  back at `[.link, .phoneNumber]`, and `IOS-UI-002` now registers the *security* residue instead (the
  allowlist absolute has a permanent documented exception, unobservable to delegate-level tests).
  **↳ SUPERSEDED 2026-08-12 — there is no ephemeral store any more.** The owner reversed
  `websiteDataStore` as well, so the per-VIEW-vs-per-MESSAGE distinction above is moot: the render
  view uses the shared **persistent** default store, T5 is OPEN and accepted (`IOS-PRIVACY-001`), and
  the render path must not be described as "isolated". P1d's `ContentKey` view-identity work remains
  worth doing for the *asset-ownership* half of decision 5, but it no longer narrows any data-store
  boundary, because there is none. `allowsLinkPreview` was reversed in the same directive and adds a
  **second** allowlist exception, `IOS-UI-003`.

Decision 9's landings:

- `1820a4fb3` — routes the write through `AttachmentPreviewStager`.
- `05200112d` — the stager's reduction accepted a separator-bearing name (`"/"` reduced to `"/"`).
- `7ce64e44b` — the same reduction missed a `U+002F` hidden inside a grapheme cluster; also stopped
  the failure path re-deriving its delete target and removing the per-message namespace.
- `a50e378fe` — sealed that failure path's inverted contract behind a private, renamed function.

Adjacent, not a decision in this ADR: `71c19d554` adds the debug-gated image load diagnostics
referenced in the deferred-image discussion above, and `cb46bc46c` hardens them — the hook and its
call sites are omitted from the emitted source unless diagnostics are enabled, the hook is installed
non-replaceably, and diagnostic log lines are sanitized at their choke point.

**P1c (2026-08-12)** landed, in one commit, decisions 2 and 4 plus the Swift half of decision 7:

- **Decision 2 — the per-load navigation permit.** `RenderDocumentURL.nonce()` mints 128 random bits
  per load and `RenderDocumentURL.url(nonce:)` renders them as a PATH segment
  (`tabmail-asset://asset/_tm-document/<32-hex>/`), which every call site now passes to
  `loadHTMLString` **unconditionally** — the `headerId != nil` conditional that used to choose between
  `BodyAssetConfig.baseURL` and `nil` is gone, so there is no longer a load whose base URL a document
  can name. `NavigationPermitState` (new file `TabMail/Views/Shared/RenderNavigationPolicy.swift`)
  holds at most one pending `DocumentLoadPermit` and is consumed at POLICY time by exact string
  equality against `navigationAction.request.url?.absoluteString` — never `URLComponents`, never
  normalization. `decidePolicyFor` is now **default-deny**: permit → allow; `.linkActivated` →
  decision 4; everything else → `.cancel`.
  Three P1a measurements shaped this and are easy to get wrong from the un-amended spec: the nonce
  lives in the PATH because a `.linkActivated` action carries the full URL **including the fragment**,
  so a fragment nonce would be readable by the document; a superseded load receives **no callback at
  all** (not even `didFailProvisionalNavigation`), so a permit can only be retired by issuing the next
  one — `arm()` returns the superseded permit and that is the only retirement path; and
  `Coordinator.wrapAndLoad` **discarded** the `WKNavigation` that C2's correlation needs, so it is now
  captured (`trackedNavigation` / `trackedGeneration`) and matched by identity in the redirect / start
  / commit / finish / fail callbacks. `didFinish`'s fit-and-reveal work is deliberately NOT gated on
  that identity: `loadHTMLString` may legitimately return `nil`, and gating would blank the message.
  **Coverage at candidate `185feafae` was incomplete; the correction round now pins both halves.**
  The WebKit canary still positively observes an ordinary non-nil `WKNavigation`, while
  `NavigationCommitCorrelation.shouldAdoptIssuedGeneration` lets
  `CommittedDocumentGateTests.nilNavigationFallbackPinsBothDirections` control the absent-correlation
  precondition directly: no tracked identity adopts (otherwise the real document is stranded), but
  an unrelated callback is refused while a newer tracked identity exists.
- **Decision 4 — the external-URL allowlist.** `RenderLinkPolicy.dispatch` admits only `http` /
  `https` (ASCII-case-folded over UTF-8 bytes, not `lowercased()`) with a non-empty host before
  `UIApplication.shared.open`. It also fixes a defect the allowlist exposed rather than caused: an
  **in-document fragment** click (`#anchor` on the current document URL) was previously cancelled and
  handed to the system opener. It is now recognised (`.sameDocumentFragment`) and simply cancelled
  with no `open`.
- **Decision 7 (Swift half) — bridge input validation.** `RenderBridgeInput` validates `heightChanged`
  (numeric fields finite and non-negative — **no** height ceiling; the spec's ceiling was REJECTED,
  see decision 7), clamps `gutterAdjust` to `[0,16]`, and bounds + escapes `consoleLog`. The
  `requestFit` / `requestWidthRefit` one-shot guards now live in Swift, keyed by load generation.

Accepted, and stated so nobody reads P1c as broader than it is: a document can still mutate its own
fragment and history (`location.hash`, `history.pushState`) — those are same-document and never reach
`decidePolicyFor`. P1c bounds where the WebView may NAVIGATE, not what the document may do to its own
URL bar state, and nothing downstream trusts that state.

**P4 (2026-08-13)** landed the image-failure banner — the plan's last phase, and the only one that is
a *user-facing notice* rather than a boundary. `postImageWidthRecheckJS` already armed separate `load`
and `error` listeners over exactly the not-yet-displayable image set, so the census rides on that
existing loop: it counts the `error` fires among the images WE deferred and posts
`{ failed, deferred }` ONCE, on a new `imageLoadFailure` channel, after `pendingImgs()` reaches 0.
`ImageFailureBannerState.isVisible` raises a dismiss-only banner above the web view — in SwiftUI,
outside the rendered document, so it adds no DOM node and cannot perturb ADR-IOS-039's
measure → mutate → re-measure pipeline. Four facts worth carrying, because each is a place a
reasonable edit goes wrong:

- **The count comes from the LISTENER, never from the element.** A broken `<img>` reports
  `complete === true` exactly like a loaded one, so no property of the element distinguishes them
  after the fact. `naturalWidth === 0` is separately FORBIDDEN by the `measureMaxRight` scope
  discipline (routed memory topic 037, the `data-tmsrc` keying bullets) because it also classifies a
  loaded intrinsic-size-less SVG as pending.
- **"Did we defer this one" is captured at ARM time, inside a per-iteration IIFE.** `swap()` removes
  `data-tmsrc` *before* assigning `src`, so a read at fire time classifies every remote image as
  local; and ES5 `var` in that loop would hand every listener the LAST image's value. Pinned by
  `imageFailureCensusExcludesLocalImages` — a purely local `cid:` image with no deferred remote
  candidate must drive the settle without accusing the sender's server. The mixed live-`cid:` plus
  deferred-remote-`srcset` exception is recorded below and must not be collapsed into this claim.
- **The census reuses the settle predicate rather than adding a spelling of it**, and takes its OWN
  one-shot (`__tmImageFailureReported`) rather than inheriting `check()`'s guards — a message that
  both loses images and needs a width re-fit must still report. `check()` itself is byte-unchanged and
  `setTimeout(check, 60)` is scheduled FIRST in both handlers, so a throw in the newer code cannot
  reach the width pipeline.
- **The settle point is UNREACHABLE while any image is permanently withheld by P2's
  `hiddenByViewMode`**, because a withheld image KEEPS its `data-tmsrc` and so keeps `pendingImgs()`
  above zero forever. Consequence: no banner ever appears on a message carrying an attached `.eml`,
  nor in the `.eml` preview sheet. Fail-CLOSED — it withholds an explanation, never manufactures a
  false accusation — accepted and registered as `IOS-UI-004`. Widening the settle predicate to
  exclude withheld images would change what `check()` considers settled, i.e. change width-refit
  behaviour, which the standing *"no behaviour changes, just security"* directive forbids.

> ⚠️ **CORRECTION, 2026-08-13 — the mechanism described above is P4's LANDING shape and was replaced
> the same day by `1051ecbf6`. Do not quote it as current.** The census no longer "counts the `error`
> fires" and no longer settles on `pendingImgs()`: it keeps ONE RECORD PER ARMED IMAGE holding the
> FIRST terminal state that image reached, derives `failed` / `deferred` from those records, and
> settles on `armedPending()` — a question about the set we armed rather than about whatever is in
> the live DOM when it is asked. That makes `failed <= deferred` structural, where two free-running
> integers over one population could be made to disagree in both directions by author script. Bullet
> three's *"reuses the settle predicate rather than adding a spelling of it"* is therefore also stale:
> the two arms differ in POPULATION (armed set vs live DOM), not only in predicate, so the census arm
> answers from the marks. `pendingImgs` and `check()` are byte-unchanged, and the withheld-image
> mechanism in bullet four survives for a withheld armed image that receives no terminal event, so
> `armedPending()` never falls to 0. **Not every withheld image has that property:** a mixed live
> `cid:` src plus deferred remote `srcset` can settle from the live candidate; the first-terminal
> trade-off below is current and accepted.
>
> ⚠️ **The behaviour delta of that replacement is NOT confined to "images that were never armed",
> which is how `1051ecbf6` scoped it, and it is not confined to settling either.** That scoping is
> right about SETTLING and too narrow for COUNTING. `EmailHTMLWrapper.wrapHTML` rewrites `src` and
> `srcset` INDEPENDENTLY (`imgSrcDouble`/`imgSrcSingle` match only `src="https?://…"`, while
> `imgSrcsetDouble`/`imgSrcsetSingle` match any `srcset` containing `https?://`), so
> `<img src="cid:…" srcset="https://…">` keeps a live `cid:` src AND gains `data-tmsrcset` — it is
> armed, and `isRemote` is true. Which terminal state it records is a RACE between the local `cid:`
> fetch and the remote srcset candidate `swap()` assigns. If the cid wins, the first-terminal rule
> records `'load'` and the remote `error` is dropped, where the old counter did `remoteFailures++`
> for it regardless of a prior load; and because the record is settled while `data-tmsrcset` may
> still be present, the census can also publish EARLIER for this shape than `pendingImgs(false)`
> allowed. So a banner that used to appear for that shape may not. FAIL-CLOSED both ways, and
> **deliberately left alone**: letting one image be both loaded and failed reopens exactly the
> two-facts-that-disagree problem `1051ecbf6` closed. Recorded rather than fixed, per the standing
> *"no behaviour changes, just security"* directive.
>
> ⚠️ **COPY CORRECTION, 2026-08-13 DEVICE SMOKE.** The earlier copy rationale was right that
> WebKit does not distinguish a 404, DNS failure, invalid bytes, an authenticated/expired URL,
> offline state, or ATS/TLS refusal, but wrong to retain even a hedged server/TLS diagnosis. A
> connected-device trace loaded the message's public Genspark images while its quoted Outlook
> `/mail/id/…` images errored, with no local MIME/CID bytes available. The banner now says exactly
> *“Some images couldn't be loaded. They may be unavailable or require sign-in.”* The census,
> settle rules, one-shot, and no-retry constraint are unchanged. Do not turn an Outlook web-session
> URL into an authenticated fetch with the recipient's account token, and do not substitute a
> visually similar loaded image: neither operation is justified by the received message.
>
> ⚠️ **PRODUCT CORRECTION, 2026-08-13 — supersedes the P4 user-visible trigger and both copy
> corrections above.** After the owner confirmed Apple Mail also fails the same quoted Outlook
> images, routine broken remote images no longer justify prominent message chrome. The
> `imageLoadFailure` bridge census remains observational and one-shot but is **diagnostic-only**;
> it has no user-visible sink. Thus a 404, expired/authenticated URL, DNS failure, invalid image,
> offline error, or ATS rejection is silent.
>
> The requested narrower banner and shorter timeout for the freeT case cannot be implemented from
> `WKWebView`'s public per-resource surface without guessing or re-requesting. The measured host
> already uses TLS 1.2; ATS rejects its static-RSA `AES256-GCM-SHA384` negotiation for lacking
> forward secrecy, so `shouldAllowDeprecatedTLSFor` (deprecated TLS *version*) is not the signal.
> `WKNavigationDelegate` governs main-frame navigation and does not expose `<img>` request failures
> with their `URLError`; JavaScript receives only an undifferentiated `error`. Elapsed time and
> missing Resource Timing cannot distinguish this from slow DNS, connectivity, or other transport
> failures. No timeout, retry, HEAD probe, credential borrowing, proxy, TLS opt-out, or second
> network path was added. Revisit a security-specific notice only if WebKit exposes an exact
> image-subresource failure reason.

Every OTHER decision in this ADR — asset ownership and view identity (decision 5's second half) — is
**specified but NOT implemented**; they land in the order given by the plan's §11. Do not read this
ADR as evidence that any of them is closed.

⚠️ **The paragraph below described the pre-P1b world and is kept because its reasoning is still the
reason those attacks were accepted.** As of P1b it is HISTORICAL: sender-authored JavaScript no longer
executes, so the residual attacks it accepts are closed as a side effect — not because they were
defended, but because their precondition is gone.

Consequence worth stating explicitly, because it bounds everything above: **sender-authored
JavaScript still executes in the message webview.** Residual attacks that require sender script —
replacing `URL` or `setAttribute`, posting directly to the `consoleLog` bridge, tampering with
`String.prototype` — are ACCEPTED for now and are not separately defended, because a sender running
arbitrary script in their own message already has every capability those attacks would grant. They
become unreachable when decision 1 lands, which is the fix. Do not add mechanism against them first.

The specified invariant tests are: content-JS not permitted on the constructed
`WKWebViewConfiguration`; a non-permitted main-frame navigation is cancelled; hostile `heightChanged`
and `gutterAdjust` payloads are clamped in Swift; the emitted CSP contains each required directive;
the asset ownership predicate (id + `headerId` + `kind`) with the moved-message case exercised; and
the traversal test at the `downloadAndPreview` call site (decision 9), red-first per global testing
rule 12. Existing surfaces to extend rather than duplicate: `EmailRenderPipelineTests`,
`EmailHTMLWrapperScopeTests`, `AttachmentPreviewStagingTests`. A real `WKWebView` **integration canary**
lands **before** the mechanisms it tests — author inline script must not execute, app user scripts
must, images behave per CSP, the nonce-in-path load works with **both** `nil` and `tabmail-asset://`
base URLs, plus fragment click, `history.back`, two overlapping app loads, process termination and
appearance reload, on the minimum and current supported iOS.

**Provenance.** Decided 2026-08-11 by the owner after a **three-round cross-model plan vet** (rounds 1,
2 and 3 recorded in `PLAN_EMAIL_RENDER_SECURITY.md` §8, §9 and §10). Round 3 returned **zero new
attack surface** — its blockers were all corrections to mechanisms invented in round 2, plus one
structural finding — which satisfied the owner's stop condition ("keep vetting while genuinely NEW
vulnerability angles appear"). §10.3 recommended a narrowly-scoped round 4; the owner froze instead.
**A8 budget: 3 of 5 rounds spent; the remaining 2 are RESERVED for the post-implementation exact-diff
audit train (A4), not for plan text.** Two process facts worth carrying forward: round 2's first
attempt was refused at the output stage by GPT's cyber-safety classifier after ~270k tokens of
completed research — a refusal is **not** a clean round and was not recorded as one — and the
defensively re-framed prompt ("review these mitigations for correctness and missing validation", never
"how would you bypass this") completed with the same information needs. Three of the vet's findings
overturned the plan's own conclusions, which is why each was independently re-verified before folding.

**Relates:** ADR-IOS-039 (render idempotency + reveal contract — any change to script injection or the
fit path must preserve it), ADR-IOS-066 / ADR-IOS-072 (content is addressed by the message it belongs
to, never by the slot it occupies — decision 5 is that principle applied to asset serving),
ADR-IOS-045 (QuickLook presented imperatively — adjacent to decision 9), ADR-IOS-052
(presentation-time ICS sanitizer — the other place we treat inbound content as hostile), cross-cutting
ADR-004 (zero retention — why an image proxy is rejected), `PLAN_EMAIL_RENDER_SECURITY.md` §8.4, §9.1,
§10.1, §2.9 and §11, and the routed render-pipeline memory topic
`Companion/Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md`
(bullet 30 records the reverted block-with-banner experiment).
