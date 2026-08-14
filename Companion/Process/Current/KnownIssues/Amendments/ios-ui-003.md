# IOS-UI-003 — Long-press link preview is a SECOND non-delegate fetch route, so the `http`/`https` allowlist has two exceptions, not one

**Status:** 📋 ACCEPTED LIMITATION (2026-08-12) — deliberate, owner-directed, registered rather than
mechanised.

## What this record is

`HTMLWebView.makeUIView` leaves `webView.allowsLinkPreview` **unset**, so WebKit's default (ON)
applies. Long-pressing a link in a rendered message body presents a preview of its destination — and
presenting that preview means WebKit **fetches the remote URL**.

That fetch does **not** produce a `WKNavigationAction`, so it never reaches
`Coordinator.webView(_:decidePolicyFor:)` and never passes `RenderLinkPolicy.dispatch`'s `http`/`https`
allowlist. The sentence

> *every externally dispatched target passes through our `http`/`https` allowlist*

is therefore **FALSE for a second, independent reason**, and — exactly as with the first — it is false
in a way **no delegate-level test can observe**. This is the `MIS-019` shape (an absolute stated
without its negative case), and the countermeasure is the same: never restate that absolute without
**both** exceptions.

**The two exceptions, enumerated so neither is forgotten:**

1. **Data Detectors** — `IOS-UI-002`. `config.dataDetectorTypes = [.link, .phoneNumber]`; detectors
   sit outside the navigation delegate and can present UI before `changeLocation`.
2. **Long-press link preview** — this record. `allowsLinkPreview` unset (ON); preview fetches and
   presents remote content with no `decidePolicyFor` decision.

The sound form of the claim remains *"every `.linkActivated` target passes the `http`/`https`
allowlist"*.

## Why it is open

P1b (`5112fcb5d`) set `allowsLinkPreview = false` on exactly this reasoning. The owner reversed it on
2026-08-12 with the standing directive applied to every P1b setting that removed shipped behaviour:

> *"no behaviour changes, just security"*

`v1.7.8` — and every release before it — shipped the symbol **absent** from the file, so the restore is
to **unset**, not to an explicit `= true`. Verified: `git show v1.7.8:TabMail/Views/Shared/AutoSizingHTMLView.swift | grep -c 'allowsLinkPreview'` → `0`.

## Scope, so the exception is not overstated

- Authored `<a href>` activation is **unaffected**. A tap on a link is still a `WKNavigationAction`,
  still reaches `decidePolicyFor`, and still passes the allowlist. Only the **preview** side channel
  is outside it.
- The preview fetch is performed by WebKit, in the content process, using the web view's data store —
  which, per `IOS-PRIVACY-001`, is now the shared persistent default store. The two records compound:
  a preview fetch can write to the same jar every other message reads.
- The reachable harm is a **fetch the user did not navigate to**: a long-press on a sender-authored
  link contacts the sender's host (tracking-pixel-equivalent confirmation of engagement, plus
  whatever the response body causes WebKit to render in the preview). It is user-initiated — a
  long-press — but it is not gated by our policy.

## Reachability and attribution

Reachable on every rendered message body, for every user, on any long-press of a link. Not an edge.
Attribution class: deliberate accepted security exception, taken by the owner in exchange for a
shipped affordance. Not a defect and not a regression for a later agent to "fix" from the diff —
anyone disabling link preview is reversing an owner directive and must ask first.

## Pinned by

`EmailRenderSecurityCanaryTests.productionConfiguration` asserts
`hostedAsset.webView.allowsLinkPreview == true` on the real `HTMLWebView.makeUIView` web view. It is a
**positive** pin, not a bug-blessing: a silent change in *either* direction fails the canary. The same
test's `[P1A]` diagnostic prints `linkPreview=` so the measured value is in the log, and
`AutoSizingHTMLView.logRenderSecurityPosture` prints it per load in debug builds, read back off the
live `WKWebView` rather than restated from the source.

No test can pin the preview fetch path itself — that is the unobservable half stated above, and it is
the whole reason this record exists.
