# An expanded quote fits a wide table, and quote levels are capped coloured bars (#327, 2026-10-25)

## 1. A forwarded table wider than the column was clipped inside an expanded quote

**Symptom (owner report, logmain.log 2026-10-25).** A forwarded ticket confirmation (Apple Mail
forward: `Begin forwarded message:` then two top-level `<blockquote type="cite">`) held a 401px
table on a 288px column. With the quote expanded, the table's right side was cut off.

**Cause.** `fitViewportJS` is the only width fit, and it runs while every quote is collapsed:
`.tm-quote-content` is `display:none`, so the log shows `maxRight=0` / `maxRight=288` and "no
overflow, staying at 1.0x". Expanding is an in-document class toggle that never re-runs the fit, and
`.tm-quote-content { overflow: hidden }` clips the overflow. The wrapper's
`table { max-width: 100% !important }` does not help: a table never lays out narrower than its
min-content width.

**Fix.** `fitQuoteContentJS` (`tmFitQuoteContent(content)`), injected into `collapseQuotesJS`.
Like Apple Mail it scales the over-wide block down, fonts included. It picks only the OUTERMOST
element of each branch whose box passes the quote content's right edge (inline non-replaced boxes
are skipped, so the block or table inside them is picked), so the surrounding quoted text keeps its
size. Scale = room from the element's left to the content edge / its width, rounded DOWN
(`QuoteFitConfig.scaleSteps`), with `QuoteFitConfig.overflowSlop`. It runs on expand (both toggle
handlers), on any `load` event inside the content (capture listener; an image that widens its
table), and from a `ResizeObserver` on the content (rotation, sheet resize). It is idempotent: each
run removes the scale it set before (`data-tm-quote-scale`), then measures, so the observer settles
after one pass.

🚨 **`transform: scale()`, NOT CSS `zoom`.** The first version used `zoom` (it shrinks the layout
box, which looked cleaner). It does not work for text: WebKit clamps zoomed text to its minimum
logical font size (about 9px), so as the zoom drops the table re-lays out wider in its own units and
its visible width barely moves. Measured in the simulator: a 576px table at zoom 0.562 laid out 628px
wide, and at 0.436 807px wide, painting about 352px either way on a 324px quote; iterating the zoom
never converges. A transform scales the painted block exactly, in one pass. Its layout box keeps the
full height, so a negative `margin-bottom` (computed margin minus height x (1 - scale)) takes back
the difference; the block's own inline `margin-bottom` value and priority are saved in
`data-tm-quote-scale` and restored on the next run. Origin is top left: the over-wide block starts
at its container's left edge and overflows to the right (an RTL block overflowing LEFT is not
measured, since the check is the right edge).

🚨 **Overflow the sender already handles is left alone (`tmQuoteFitLeaves`).** Codex review round 1
caught two regressions in the first version. (a) A table inside the sender's own `overflow-x:auto`
scroller (the usual receipt / markdown-render pan pattern) passes the quote's edge by its rect, but it
already pans in its own box; scaling it shrank the text to about 40% while keeping the scroll extent.
Any ancestor between the block and `.tm-quote-content` with `overflow-x` auto/scroll/hidden/clip now
exempts the block, the same containment rule as `fitViewportJS`'s `measureMaxRight` (the walk stops
at the quote content, which is itself `overflow:hidden`). A scroller that itself overflows is still
scaled. The wrapper's own `overflow-x:auto` rules (`pre`/`code`, `.tm-eml-section` tables) are
scrollers too, so they keep panning. (b) A block with the sender's own `transform` (or under a
transformed ancestor) had it overwritten, and the reset restores only `margin-bottom`, so a later
refit with room erased the sender's transform. Such a block is now left as authored (fail closed:
it may stay clipped). Either way the block still ends its branch, so its descendants are skipped too.

**Why not re-run the page fit on expand.** ADR-IOS-039 says a re-fit of injected content must go
through `resetAndFit`; that widens the layout viewport and shrinks the WHOLE message, the reply text
included, and a collapse would need another re-fit back. Scaling only the quoted block leaves the
page fit untouched, so ADR-IOS-039's idempotency and the height seed cache are unaffected.

**Tests.** `EmailQuoteFitTests` (production `HostedRenderView`): the expanded table ends at the
quote content's edge and still spans it, the quoted paragraph keeps the reply's line height, the
paragraph after the scaled table sits one margin below its painted bottom (no blank space left by the
full-height layout box), collapse-and-expand gives the same fit, and a widened table refits on a
`load` event. After review round 1 it also pins: a table in a sender scroller (every
`overflow-x` value) and a sender-transformed block or subtree keep their size; the scaled table's
text is scaled once (descendants are not picked again); the column narrowing refits (observer);
a load that widens the table without changing the quote box's height refits (load listener); the
inline-reply layout's trailing quote fits; the sender's `margin-bottom` and priority return; an
inline-block inside an inline wrapper is the scaled block. Red-first: each fails with its mutation.

## 2. Quote levels: thin coloured bars, and the indent stops at a depth (#327)

**Before.** #286/#303 made a level cost its 3px border and 12px padding (15px), with no limit, and
the rule was not `!important`, so Gmail's inline `margin:0 0 0 0.8ex;border-left:1px solid;
padding-left:1ex` kept its own indent at every level.

**Now.** `QuoteLevelConfig` in `EmailHTMLWrapper.swift` generates the CSS: a level is a
`barWidth` (2px) bar plus `barGap` (8px), colours cycling by level (Apple system blue, green,
purple; `darkBarColors` in the dark `@media` block), and levels past `maxIndentedDepth` (5) draw no
bar and add no indent, so any thread's innermost text keeps all but 50px of its column. The rules are
`!important` to beat senders' inline quote styles. The selector is every `blockquote` EXCEPT one
with an inline `border:none`, which is Gmail's Indent button (`margin:0 0 0 40px;border:none;
padding:0px`): an indented paragraph, not a quote, so it keeps the sender's style and does not
count as a level. Precedent: Apple Mail draws each quote level as a coloured bar with per-level
colours; Gmail's own quote indent is about 1ex.

**Tests.** `EmailQuoteWidthTests`: 20 levels on a 320px page keep the innermost width within the
cap; each drawn level has the bar width and the level's colour in light and dark, deeper levels
none; a Gmail inline-styled thread is bounded; a Gmail Indent blockquote keeps its 40px and no bar.
