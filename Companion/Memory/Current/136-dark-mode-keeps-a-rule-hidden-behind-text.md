# Dark mode keeps a rule hidden behind text, and a fitted table keeps its column width (#307, 2026-10-24)

**Symptom (owner report, a newsletter in dark mode).** A heading drew a horizontal rule behind a
centred date: `border-bottom` on an `h2` with `line-height: 0.1em`, which pulls the border up through
the text, and a white `background` on the inner `span` that hides the rule under the date (a common
email-builder pattern). In dark mode the rule ran straight through the date, and the rule only spanned
the date, not the column.

**Cause 1, the mask.** `fixDarkModeColorsJS` made the span's near-white fill transparent (page-colour
regime, or the near-white dimming branch), and with it gone nothing hid the rule. That fill is a mask,
not a surface.

**Fix 1.** `hidesAncestorBorder(el)`: an element whose box overlaps the painted top or bottom border
of an ancestor (any part of the stroke, so a fill over part of a thick rule counts; overlapping it
horizontally too; a fill ending exactly on the stroke's outer edge covers it, one ending exactly on its
inner edge overlaps none of it) keeps an opaque fill in the colour that shows through it, computed by `shownThrough(el)`
from the ancestors' already-rewritten fills over `BACKDROP`. `BACKDROP` is the colour the web view sits
on (the page is transparent in dark mode), passed in as `AutoSizingHTMLView(backdrop:)`: default
`Theme.cardBackground`, `Palette.previewPaneBg` for the compose quote preview. The check runs before
the page-colour and chrome branches, so it applies in either regime. The mask is marked
`data-tm-panel`, as the panel fill it replaces would be, so a light fill nested inside it that hides no
rule stays transparent rather than being darkened as a new panel (review r3, 2026-10-25). A rule hidden behind a solid
background stays hidden (owner, 2026-10-24).

Only a border that draws a line counts (`drawnWidth`: a width, a style other than `none`/`hidden`,
and a colour that is not fully transparent unless a `border-image` paints it); a fill over a
transparent border keeps the treatment it would get with no border. Cost: the check runs for every
near-white fill, so it must not walk and measure every ancestor (that made an 8,000-element nested
mail about 29% slower in review). The main loop records each element's drawn top and bottom border
widths on the element (`__tmRuleEdges`) at the END of its iteration, after its own colour rewrite (a
`currentColor` border on transparent text only shows once the text gets a colour), and before its
descendants, which come later in document order. The check returns at once while no rule has been
recorded (`ruleCount`), reads border style, colour and image only for a border with a width, and
measures rectangles only for ancestors that draw a rule. The fill's own box is the one the main loop
already measured, and each rule-drawing ancestor is measured once per pass (`ruleRects`, a `Map`
local to the pass, so nothing persists on the nodes); the pass only recolours, so those boxes stay
valid. Measuring the ancestor again for every fill under it made a 6,400-element ruled mail 6 to 9%
slower (review r4, 2026-10-25). The ancestor walk includes `body`, which the main loop records like
any element: a fragment's `body { border-top }` rule under a positioned label is masked too. The
fill's box is cut to what its background colour paints (`paintBox`: the last layer's
`background-clip`, inset by the border for `padding-box` and by border and padding for
`content-box`), so a box whose border reaches the rule but whose clipped fill stops short of it hides
nothing (363 messages in the owner's mailbox set such a clip inline; review r4, 2026-10-25).

**Cause 2, the width.** `constrainWidthsJS` set every over-wide element to `width: auto`. A table set
to `auto` shrinks to its content, so a 468px date table narrowed to its date and the heading inside it
(and its rule) spanned only the date.

**Fix 2.** An over-wide `TABLE` goes to `width: -webkit-fill-available`, the container's width less
the table's own margins (auto margins count as zero); every other element stays `auto`, which already
fills its container for blocks and cells. The rule spans the full column (owner, 2026-10-24). The
first version used `100%`, which overflowed by the margins of a table inset with `margin-left` /
`margin-right` (review, 2026-10-24).

**Tests.** `EmailRuleBehindTextTests` renders a synthetic fixture through the production
`HostedRenderView` and reads snapshot pixels: the rule is light beside the text and dark (hidden)
behind it in dark mode, on a white page and on no page colour; and the table, the rule and the cell
widths equal the column's width in light and dark. Also: fills ending or starting exactly on the
stroke's edge; a fill over part of a thick top or bottom rule; light mode keeps the email's own
colours (white fill over the rule, grey rule beside it); a light fill that hides no drawn rule (a
transparent border, a fill beside the ruled box, a fill ending on the stroke's inner edge) is treated
as with no border; a light fill nested in a mask, clear of the rule, is treated as with no rule; the mask's pixel equals the panel around it on an opaque and on a translucent panel
under a translucent wrapper; an over-wide
table with margins (inset or auto) fits its container in both modes; a `currentColor` rule and a
`border-image` rule stay hidden; a supplied backdrop (the compose quote preview) is the mask's colour;
a fill under a nearer ruled box it does not touch still masks the outer rule it hangs over, written
with the `background` shorthand and with `background-color` alone; a fill clipped to its padding or
content box clear of the rule is treated as with no rule; a rule on the body stays hidden
under a positioned label; the fixtures construct the view with its production default backdrop; and a
long nested mail with no rule under any fill gets no extra layout reads, border reads or
recorded-rule lookups, and with a rule under every section only one layout read per rule. Panel fixtures sit inside a plain section: the email wrapper clears the fill of
a top-level block, which emptied the first panel fixtures without anyone noticing. Geometry fixtures must
also allow for `EmailHTMLWrapper` forcing `box-sizing: border-box !important` on every `table`,
`div` and `p`: a div's stated height includes its border, and an inline `content-box` does not
override it. A "fill touching the stroke's inner edge" fixture written in content-box terms
actually overlapped the stroke, and "partial overlap" fixtures covered the whole stroke (review r4,
2026-10-25). The real newsletter and the owner's screenshots stay
local and are never committed (they hold the owner's address).

**Known edge (P5, GitHub #312).** The quote wrappers (`collapseQuotesJS`, light rgba tint) are
inserted after the dark-mode pass, so a mask inside a quoted reply is painted without the quote's tint
(about a 5% shade difference).

**Known edge (P5, GitHub #317).** The whole dark-mode pass reads computed colours with `parseRGB`
(`rgb()`/`rgba()` only); CSS Color 4 values (`color()`, `lab()`, `oklch()`) stay in their own syntax
and are treated as unknown, including by the mask colour and the transparent-border check. Almost
absent from real mail.

**Known edge (P5, GitHub #318).** Rule edges are recorded in the main loop, before the later
contrast pass. A heading whose text starts fully transparent, with a `currentColor` rule, records no
rule; the contrast pass then colours the text and with it the rule, which cuts through the fill. 0
occurrences in the owner's mailbox.

**Known edge (P5, GitHub #319).** A rule painted only by a border image (`border-style: none` with a
nonzero `border-image-width`) is not recorded, since `drawnWidth` starts from the ordinary border
width. 0 occurrences in the owner's mailbox.

**Known edge (P5, GitHub #321).** A rule drawn on `html` is not recorded: the main loop walks
`body, body *`. At most 2 messages in the owner's mailbox have a rule on `body`/`html` with any
absolutely positioned element.

**Known edge (P5, GitHub #322).** Border widths are untransformed CSS pixels while the boxes include
transforms: under `transform: scale()` a fill covering only the scaled stroke's outer part is missed.
No message in the owner's mailbox scales a ruled element inline.

**Known edge (P5, GitHub #323).** `shownThrough` takes the nearest ancestor fill without checking
that it paints under the mask: a mask overflowing a short coloured wrapper onto an outer rule, or
an ancestor fill clipped by `background-clip: padding-box`/`content-box` clear of the stroke, gets
that fill's colour instead of the colour actually behind it (review cx-307-r5 F1; cosmetic, the text
stays readable). 384 of 256,378 HTML messages in the owner's mailbox use an inner `background-clip`.

**Known gap (P4, GitHub #320).** No test constructs the compose quote preview's
`AutoSizingHTMLView(html:backdrop: Palette.previewPaneBg)`; covering it needs a hosted reply compose.

**Known edge (P4, GitHub #316).** `shownThrough` composes `background-color` only. On a panel that
paints a `background-image` (a gradient), the mask is painted in the colour under the image and shows
as a card-coloured rectangle.

Related: `037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md`
(`fixDarkModeColorsJS` regimes), ADR-IOS-039.
