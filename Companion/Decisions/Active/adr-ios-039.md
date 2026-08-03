
## ADR-IOS-039: Idempotent HTML Render Fit + Scroll-Phase Height Freeze

**Date:** 2026-06-09

**Context:** Two user-visible bugs shared one root. (1) In the message
detail view, slow scrolling with expanded related messages caused cards to
overlap / render on top of each other. (2) Backgrounding the app with an
HTML message open and re-foregrounding shrank the message fonts a little
more on every cycle.

`AutoSizingHTMLView`'s pipeline is measure→mutate→re-measure: `fitViewportJS`
measures content overflow, then MUTATES the document (viewport-meta widen,
inline width strips, body padding zeroing) so WebKit scales wide emails
down. The height arm of this pipeline had already been hardened
(`html,body{height:auto}` override; `__tmLayoutVp` instead of
`window.innerWidth`, WebKit bug 170595), but the width arm was
**non-idempotent**: re-running `fit()` against an already-widened document
re-measured widened CSS px against an unreliable `innerWidth` and re-mutated
the document. The `didBecomeActive` foreground observer re-runs `fit()` with
no baseline reset — every background→foreground cycle re-entered the widen
logic (bug 2). The same non-determinism fed bug 1: `handleHeightMessage`
only applies a height when it CHANGED, so scroll-time re-measurement
(WKWebView recycle/process-resume during List scrolling) could only move
rows — and overlap cards via List self-sizing mid-pan — when the
re-derived scale/height drifted from the previous pass.

**Decision:**
1. **Idempotency guard in `fitViewportJS`** — if `window.__tmLayoutVp` is
   already set, the document is already fitted: bail (no measure, no
   mutation). Same document + same device width → same answer.
2. **Swift-stamped baseline width** — `fit()` stamps `window.__tmDeviceWidth`
   from `webView.bounds.width` before the script runs; `fitViewportJS`
   measures against it (`innerWidth` is only a last-resort fallback).
   `monitorHeightJS` vp fallback chain: `__tmLayoutVp || __tmDeviceWidth ||
   innerWidth`.
3. **Explicit reset path for REAL width changes** — `viewportResetJS(deviceWidth:)`
   (updateUIView width-change branch) clears `__tmLayoutVp`, re-stamps
   `__tmDeviceWidth`, and restores `width=device-width` BEFORE `fit()` so
   the guard re-derives from a clean baseline.
4. **ScrollFreezeGate** (Mutex-based, not @MainActor — the WKScriptMessageHandler
   Coordinator is nonisolated) — while `MessageDetailView`'s List scroll
   phase is non-idle, Coordinators buffer changed heights (`pendingHeight`,
   latest-wins) and flush on `.scrollFreezeReleased`. Covers the residual
   legitimate height changes (late image loads) that idempotency can't
   remove. Exception: never-sized rows (`height <= 1`) apply immediately.
   `end()` is also called from `onDisappear` so the gate can't stick frozen.

**Rationale:** The measured height is only cacheable/stable if the render is
a pure function of (content, device width). Fixing idempotency makes the
existing `visualHeight != height` dedup absorb all steady-state
re-measurements for free; the freeze gate then only ever buffers genuine
changes. A height seed cache (considered first) would have cached the
output of a non-converging pipeline — wrong order.

**Consequences:**
- Foreground re-fit is now a no-op for already-fitted documents (fonts
  stable across background cycles).
- Mid-scroll height application is deferred to scroll-idle; rows cannot
  resize under the user's finger.
- A late image load while scrolling keeps the stale row height until the
  scroll idles (acceptable: sub-second, and strictly better than overlap).
- If a future code path needs a genuine re-fit (e.g. content injected into
  an existing document), it MUST go through the reset path, not bare `fit()`.
- Regression tests: `EmailRenderPipelineTests` (idempotency guard, stamped
  width, vp fallback chain, reset semantics) + `ScrollFreezeGateTests`.

**Related:** PROJECT_MEMORY.md "HTML Email Render Pipeline" section;
EmailHTMLWrapper height-arm overrides; WebKit bug 170595.

**Addendum (2026-06-09, same day — log evidence + HeightSeedCache):**
A post-fix device log (`logmain.log`) confirmed decisions 1–4 working (5×
foreground re-fits bailed as idempotent no-ops; all re-measurements
converged to identical values) but surfaced the residual overlap source:
SwiftUI List dismantles far-offscreen rows, and when an expanded card
scrolls back toward the viewport the whole `AutoSizingHTMLView` — INCLUDING
its `@State height` — is recreated. The same message reloaded 5× in one
scroll session with `frameH=1` at onload: the row collapses to 1 pt,
shifting rows below up by the card height, then re-inflates ~200–500 ms
later when the fresh WKWebView re-measures (the `height <= 1` freeze
exception correctly applies it mid-scroll). Fix: **HeightSeedCache** —
in-memory (NOT disk; ADR-004) map of headerId → last applied visual height,
written on every applied height, read in `AutoSizingHTMLView.init` to seed
`@State height`. The seeded row re-enters at its real height; the recreated
WKWebView's idempotent re-measure returns the identical value and the `!=`
guard drops it — the row never moves. Seeding is only sound BECAUSE of the
idempotency from decisions 1–3; a seed cache over the old non-convergent
pipeline would have cached drifting values (why this was sequenced last).
Width changes are accepted as a one-snap correction (~200 ms) rather than
keying the cache by width.

**Addendum (2026-07-04 — post-image-load width recheck):** hiding deferred
images during `measureMaxRight` (the 2026-06-29 phantom-overflow fix) makes
an IMAGE-DRIVEN width invisible to `fit()`: FleetOptics' centered 515px
table measured 307px with its 12 remote images hidden → fit committed a
400px layout viewport → the images loaded, the table re-expanded to 515px,
and the overflow stayed clipped forever (the idempotency guard correctly
blocks bare re-entry; height had post-load re-report paths, width had
none). Fix adds a THIRD sanctioned re-fit trigger alongside rotation/sheet
resize: `postImageWidthRecheckJS` waits (event-driven, load/error listeners
keyed exactly like the measure-hide) for the LAST deferred/in-flight image
to settle, re-measures the rightmost edge against `__tmLayoutVp ||
__tmDeviceWidth` with the same 8px slop, and posts a ONE-SHOT
`{requestWidthRefit:true}`; `Coordinator.resetAndFit()` then runs
`viewportResetJS + fitViewportJS` in a SINGLE JS turn (one WebKit
layout/scale commit — no intermediate device-width paint of the revealed
content). This preserves purity: the final state is still a function of
(content INCLUDING loaded images, device width); the one-shot flag plus the
reset-path discipline prevent loops. Companion widen-loop fix: the target
now includes the culprit's own width (`max(maxRight, culpritWidth)`,
measured while images are hidden) because a centered (`margin:auto`)
culprit re-centers on every pass and its `rect.right` closes only half the
overflow per pass — it exhausted `MAX_PASSES` still clipped and could trip
the runaway guard into reverting a fixed-width email to 1.0×. Tests:
`fitViewportWidenTargetsCulpritWidth`, `postImageWidthRecheckPolicy`.
