# MIS-IOS-027 — I subtracted a screen-px bounding rect from a CSS-px margin

**Class:** units / coordinate spaces · rendering
**Severity:** low (found by Codex review round 2, before merge; no release shipped it)
**First seen:** 2026-10-25 · **Recurrences:** 1 · **Status:** Active
**Related:** memory topic 137 · `fitQuoteContentJS` / `tmFitQuoteContent` / `tmQuoteFitLeaves`

## The tell

A value from `getBoundingClientRect()` (or any transformed / painted geometry) is written back
into a style property (`margin`, `width`, `top`, `height`) as `... + 'px'`. The rect is in screen
px after every ancestor transform; the style value is in the element's own CSS px. They agree only
while nothing above the element is transformed, which is exactly what a test page never does.

## What actually happened

The expanded-quote fit scaled an over-wide table with `transform: scale(s)` and took back the blank
layout height with `margin-bottom: mb - r.height * (1 - s)`, `r` being the table's bounding rect.
`tmQuoteFitLeaves` excluded transforms between the table and the quote content, and I reasoned that
this made the rect safe. Codex wrapped the whole message in a sender `transform: scale(2)` above the
quote content: the rect doubled, the margin over-reclaimed, the next text overlapped the table and the
quote clipped its bottom. Fixed by using `el.offsetHeight`, the element's own layout height in CSS px.
An adversarial consult on that fix also found the second hole in the same reasoning: the separate CSS
`scale` and `rotate` properties never show in the computed `transform`, so "no transform between"
was not even true inside the walk. `tmQuoteFitTransformed` now checks all three.

## The rule

Never write rect geometry back into a style as px. Ratios of two rects (both screen px) are fine;
absolute lengths written into styles come from layout values (`offsetWidth`/`offsetHeight`,
computed style) in the element's own CSS px. When a check says "nothing is transformed here",
check `transform`, `scale` and `rotate`, and test with a transform ABOVE the region too.

---

## Pre-compaction index line (verbatim, 2026-11-09)

Routed out of `tabmail-ios/MISTAKES.md` by the `companion-compact` skill (13026 B against
its 12,000 B budget). The index keeps a shortened line; this is the line it replaced,
**byte-for-byte**, source line 53 at `6597c3a7`.

<!-- BEGIN VERBATIM INDEX LINE MIS-IOS-027 2026-11-09 -->

```text
- **MIS-IOS-027** — **subtracted the quoted table's screen-px `getBoundingClientRect().height` from its CSS-px `margin-bottom`** in `tmFitQuoteContent`; a sender `transform` above the quote doubled it and the next text overlapped the table; fixed with `offsetHeight`, and `tmQuoteFitTransformed` checks `transform`/`scale`/`rotate` (separate properties hide from computed `transform`); tell = rect geometry written back into a style as px (×1)
```

<!-- END VERBATIM INDEX LINE MIS-IOS-027 2026-11-09 -->
