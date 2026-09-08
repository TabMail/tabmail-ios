# Email render timing diagnostics

`EmailRenderTiming`, `EmailHTMLWrapper.wrapHTML`, and
`HTMLWebView.Coordinator.wrapAndLoad` emit console-only `[RenderTiming]` events
when `DebugModeManager.isLoggingEnabled()` is true, including in release builds
with debug logging unlocked. Rendering behavior is unchanged.

Group by web-view id and generation. Native `+Nms` uses a monotonic clock from
the wrapping request; generation zero measures web-view creation separately.
The immutable clock travels into the detached task. Successive `wrap.*.done`
events delimit document unwrapping, lazy-attribute removal, stylesheet removal,
and each remote-image rewrite. `wrap.detached.done` versus `wrap.main-resumed`
separates processing from waiting for the main actor. `loadHTMLString` and
navigation timings cover the handoff to WebKit. Navigation text carries its
existing tracked/committed identity evidence; the clock alone does not prove
that a late navigation callback belongs to the latest issued generation.

`imageLoadDiagnosticJS` adds document/animation-frame/font lifecycle events to
`[ImageLoadDiag]`, using its existing document-start clock. An optional
`PerformanceObserver` reports completed resources, including fonts and CSS
images, with origin only (no path/query), capped at 80 entries per document.
Detailed cross-origin timing fields may be zero/unavailable; zero transfer
size alone does not prove a cache hit. The two-second inventory exposes images
still pending and font-set status. These observers initiate no requests.

`epochMs` on native events, JS lifecycle events and the fit/reveal event allows
cross-process correlation. Use monotonic relative clocks for durations; wall
clock changes invalidate comparisons across epochs. A JS animation callback is
not proof that the native loading placeholder has disappeared: compare
`reveal` with native `reveal.received`. `placeholder.safety-timeout` also reports
whether its existing task was cancelled; it is not by itself proof of a full
four-second wait. The timeout event has no web-view id, so correlate cautiously
when several cards are open.

The investigation motivating these diagnostics found a reopened cached message
with a multi-second gap before the wrapped-document load log, while visible
images completed quickly after document start. That establishes a measurement
gap, not a proven slow regex or network cause. Capture the new stage timings
before choosing a fix. `EmailRenderPipelineTests.renderResourceTimingDiagnostics`
checks the emitted resource/font events and exclusion of request paths/queries;
the existing tests retain no-request, disabled-script and log-line safety checks.

## Follow-up capture: lazy-attribute regex isolated (2026-09-08)

The new instrument resolved the earlier measurement gap on two openings of the
same HTML: `wrap.unwrap.done` to `wrap.lazy-attribute.done` took **6,964 ms** and
**6,722 ms**. The latter opening spent 9 ms unwrapping, about 3 ms on the
remaining wrapper stages, and returned to the main actor immediately. Remote
fonts took 54 ms, visible images 10–12 ms, and the tracking image 200 ms.

The costly operation is `EmailHTMLWrapper.wrapHTML`'s unanchored
`\s+loading\s*=\s*"lazy"` replacement. A standalone Foundation reproduction
using that exact expression on synthetic whitespace followed by ordinary text
(no lazy attribute to remove) measured about 213/903/3733/15603 ms for
2k/4k/8k/16k spaces. Doubling the run roughly quadruples work: the regex retries
overlapping whitespace suffixes. These are host-dependent timings, not a
production performance bound; the complete captured HTML was not available to
identify its exact expensive whitespace span. The logged replacement stage is
confirmed; long-whitespace retry behavior is independently reproduced. No
production fix was made as part of the log analysis.

The same capture also shows `reveal.received committedGen=- wasRevealed=false`
at +162 ms, before `loadHTMLString.begin` at +6771 ms. The corresponding fit
measured `maxRight=0`. An empty web-view fit can therefore dismiss the native
loading placeholder while HTML preparation is still running, exposing a blank
area during the real wait. The actual document's reveal arrives at +7090 ms
with `committedGen=1 wasRevealed=true`. Keep that presentation defect separate
from the expensive preparation stage.

## Correction

Lazy-attribute removal now starts only at the beginning of a whitespace run and
consumes that run possessively. This preserves the existing replacement while
avoiding overlapping retries on long non-matching whitespace. A synthetic
16,000-space body pins both output preservation and a generous two-second bound.
The original expression took 14.76 seconds in the red-proof harness; the corrected
wrapper passed in 4 milliseconds on the same synthetic body.

Native reveal handling now uses the existing committed-document one-shot gate.
An initial empty-view fit cannot consume the pending document's reveal; each
committed document receives its own reveal slot. Timing diagnostics remain
console-only and gated by `DebugModeManager.isLoggingEnabled()` (including the
existing explicit debug unlock on release builds).
