# IOS-UI-002 — Data Detectors dispatch OUTSIDE the navigation delegate, so the `http`/`https` allowlist is not an absolute

**Status:** 📋 ACCEPTED LIMITATION — **RE-SCOPED 2026-08-12. The original registration below is
SUPERSEDED IN PLACE and kept verbatim; nothing here is deleted.**

## What this record is now

`HTMLWebView.makeUIView` sets `config.dataDetectorTypes = [.link, .phoneNumber]`. Data Detectors sit
**outside** the navigation delegate, so the security property P1c's allowlist would otherwise state
outright carries a permanent, documented exception. That exception — not the UX cost — is what this
record registers.

**The security fact, unchanged and still true (§9.1 B2, verified, round-2 cross-model vet):** WebKit's
anchor-activation path can present Data Detector UI *before* `changeLocation`, so a detected target may
never arrive at `decidePolicyFor` at all. Therefore the sentence

> *every externally dispatched target passes through our `http`/`https` allowlist*

is **FALSE while detectors are enabled**, and it is false in a way **no delegate-level test can
observe** — the exact shape `MIS-019` exists for (an absolute stated without its negative case). Never
restate that absolute in code, tests, an ADR, `KNOWN_ISSUES.md`, or a commit body without this
exception. The sound form is *"every `.linkActivated` target passes the allowlist"*.

**⚠️ AMENDED 2026-08-12 — this is no longer the ONLY exception.** The same owner directive that
restored detectors also restored `allowsLinkPreview` to unset (WebKit default, ON). Long-press link
preview **fetches and presents** a remote URL without producing a `decidePolicyFor` decision, so it is
a **second, independent** non-delegate route out of the render view, registered as **`IOS-UI-003`**.
Both exceptions are unobservable to delegate-level tests. Qualify every restatement of the absolute
with **both** — a restatement carrying only this record's exception is now itself an `MIS-019`
instance. See also `IOS-PRIVACY-001`: link preview fetches against the shared persistent data store.

**Scope, so the exception is not overstated:** authored `<a href>` links are **unaffected** by
`dataDetectorTypes`. They are `WKNavigationAction`s and still reach
`Coordinator.webView(_:decidePolicyFor:)`, where `mailto:` interception and P1c's allowlist live.
Detectors govern only **plain-text** phone numbers and **bare** URLs.

## Why the original registration was superseded

The owner rejected it on sight, the same day it was written (2026-08-12):

> *"still link and phone numbers are important for a phone email app. have them back. Again, no
> behaviour changes, just security"*

`dataDetectorTypes` is therefore restored to `[.link, .phoneNumber]` — the value shipped at `v1.7.8`
and at P1b's parent. Two consequences for anyone reading the superseded text below:

- **It was never owner-accepted.** It was registered as an accepted limitation by the implementing
  agent, not by the owner. "Registered" is not "accepted"; this record is the correction.
- **Its recommended fallback is WITHDRAWN.** The narrower `dataDetectorTypes = [.phoneNumber]`
  compromise, and the accompanying instruction *"Restoring `[.link, .phoneNumber]` wholesale is not
  recommended"*, were put to the owner and **explicitly overruled**. Both halves are back. Do not
  re-derive the narrower option as if it were still the recommendation, and do not remove either
  detector without asking the owner first.

The UX limitation the original text described (tap-to-call gone, bare URLs inert) **no longer exists**.

## Pinned by

`EmailRenderSecurityCanaryTests.productionConfiguration` asserts
`cfg.dataDetectorTypes == [.link, .phoneNumber]` on the real `HTMLWebView.makeUIView` configuration.
It is a **positive** pin, not a bug-blessing: a silent change in *either* direction fails the canary.
No test can pin the detector dispatch path itself — that is the unobservable half stated above.

## Reachability and attribution

Reachable on every rendered message body, for every user, immediately — this is not an edge. The
accepted cost is now a **security** one (a documented exception to the allowlist absolute), knowingly
taken by the owner in exchange for a core affordance of a phone mail client, rather than the UX one
originally recorded.

---

# SUPERSEDED — original registration, 2026-08-12, kept verbatim

> Everything below is the record as first written, before the owner's directive. It is retained
> because the repo never deletes superseded reasoning. **Its recommendation is no longer operative**;
> read the sections above for what is currently true.

## What changed

`HTMLWebView.makeUIView` built its `WKWebViewConfiguration` with
`config.dataDetectorTypes = [.link, .phoneNumber]` from the first version of the file. P1b sets it to
`[]`.

Consequence for the user, stated plainly:

- **Anchors are unaffected.** A real link in an email is `<a href="…">`; activating it is a
  `WKNavigationAction` and still reaches `Coordinator.webView(_:decidePolicyFor:)`, which is where
  `mailto:` interception and (from P1c) the `http`/`https` allowlist live. Links in mail keep working.
- **Bare text loses its affordance.** A phone number or a URL typed as plain text — `+1 604 555 0142`,
  `www.example.com` with no anchor — used to be auto-linkified by WebKit and tappable. It is now inert
  text. **Tap-to-call from a message body is gone**, as is tap-to-dial-from-a-signature.
- Selection and the system copy/share menu are unchanged; the user can still select the number and
  copy it.

## Why it was done

§9.1 B2 (verified, round-2 cross-model vet): **Data Detectors sit OUTSIDE the navigation delegate.**
WebKit's anchor-activation path can present Data Detector UI *before* `changeLocation`, so a detected
target may never arrive at `decidePolicyFor` at all. While detectors are enabled, the sentence

> *every externally dispatched target passes through our `http`/`https` allowlist*

is **false**, and it is false in a way no test of the delegate can observe — the exact shape `MIS-019`
exists for (an absolute stated without its negative case).

P1c's guarantee is worth more than the affordance:

- The affordance only ever covered **plain-text** targets. Every *authored* link in mail is an anchor
  and keeps its behaviour.
- Making the guarantee true outright is one line and is trivially reversible; keeping the affordance
  means carrying a permanent documented exception plus a test for a system-UI path we do not control.
- The alternative is not "safe vs unsafe" but "one narrow affordance vs an absolute that stays true
  without a footnote".

## The fallback, recorded so it does not have to be re-derived

If the owner wants tap-to-call back:

```swift
config.dataDetectorTypes = [.phoneNumber]     // instead of []
```

`.phoneNumber` restores tap-to-call while dropping `.link`, which is the **navigating** detector — the
one that manufactures a URL target and can dispatch it outside the delegate. That is a strictly smaller
exception than the shipped `[.link, .phoneNumber]` and is the recommended landing spot if the
affordance is missed. It still has to be written down as an exception to P1c's absolute, and it still
needs its own test, because a detected `tel:` that *does* reach the delegate is dead under an
`http`/`https` allowlist.

Restoring `[.link, .phoneNumber]` wholesale is **not** recommended: `.link` is the half that carries
the navigation.

## Reachability and attribution

Reachable on every rendered message body, for every user, immediately — this is not an edge. It is
registered rather than mechanised because it is fully recoverable by an ordinary user gesture
(select → copy → paste into the dialer), which clears THE MANTRA's bar, and because the recovery is
*one line of code* rather than a mechanism.

Attribution class: deliberate accepted UX cost of a security decision. Not a defect, and not a
regression to be "fixed" by a later agent reading the diff — anyone re-enabling `.link` is reopening
§9.1 B2 and must say so.

## Pinned by

`EmailRenderSecurityCanaryTests.productionConfiguration` asserts
`cfg.dataDetectorTypes == []` on the real `HTMLWebView.makeUIView` configuration, so a silent
re-enable fails the canary.
