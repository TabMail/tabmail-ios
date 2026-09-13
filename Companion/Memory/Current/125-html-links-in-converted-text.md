# HTML links in converted text — issue 100

`EmailFilter.htmlToPlainText` retains visible anchor destinations as `[label](address)`.
This is the shared conversion used by `extractPlainText` for new FTS body writes and by
`EmailReadTool` for cached HTML reads. The existing FTS read path retains the same text
after display-cache eviction. Snippets and outgoing plain-text conversion also use this helper.

The byte scanner reads quoted and unquoted href values, uses SwiftSoup attribute
decoding once, and escapes literal labels and destinations without hiding decoded URL letters.
Whitespace inside link labels becomes spaces. The app and NSE use the same converter and decoder. Inline hidden-content
suppression reads only actual style declarations, ignoring quoted values and comments.
Anchors without a nonempty href remain plain text; empty labels still retain the address.

Owner scope: forward-only conversion. No backfill, cache sweep, historical repair, or
older-client compatibility work. Existing FTS rows change only through ordinary future writes.

Regression coverage: `EmailFilterLinkTests` and
`HTMLLinkIngestionTests.linkAddressesReachAgentAndSearch`, including Markdown destination
round trips and the real fetch/render/persistence/FTS pipeline.

## Snippet link window and the linear unwrapper — issue 162 (PR #163, 2026-09-13)

`EmailFilter.snippetFromPlainText` unwraps `[label](destination)` to `label` for the DISPLAY
snippet only; FTS and agent text keep the full form above. It does so inside a
`snippetLinkScanChars` input window measured in Unicode scalars. At 4,000 scalars an
image-heavy newsletter (dozens of `<a><img></a>` before the first sentence, each converting to a
~180-scalar empty-label link) filled the window with links that unwrap to nothing; the link cut
at the window edge stopped matching and its `[](https://…` prefix became the whole preview,
written durably by `BodyFetchProcessor`, the inbox loader's FTS tier and
`NSEDataBridge.stagedDisplaySnippet` alike.

- Window is now **32,000 scalars** (~180 such links). The 4,000 figure had no measured basis
  once the original per-opener re-walking parser was replaced by a regex.
- **A regex over a wide window is quadratic on unclosed-opener runs**: every `[` in a
  `[](` × 10,000 or `\[` × 16,000 run re-scans the same suffix to the window's end (3.5 s and
  6.8 s measured on a Mac, main actor). Two regex patches were REJECTED in review: a per-group
  length cap turned complete links longer than the cap back into raw Markdown (the bug's mirror
  image, MIS-005 instance 28), and a failure-consuming alternative skipped a valid link whose
  label begins inside a failed destination (`[a](x[b c](y)`).
- `unwrapMarkdownLinks` is now a **linear scanner**: two right-to-left passes precompute where a
  label or destination scan starting at each position closes, and the left-to-right pass decides
  each `[` in O(1). Escape rule: a backslash escapes the next scalar unless it is one of the
  seven ICU line terminators (LF VT FF CR NEL U+2028 U+2029) — review caught a first version that
  admitted VT and FF. Fuzzed identical to the regex on 600,000 random strings; hostile fixtures
  ~2 ms. The regex and label-unescape regex are deleted.
- Regression tests: `EmailFilterTests.snippetSurvivesLongRunOfImageLinks`,
  `snippetLongLinksUnwrapAndUnterminatedLinksStayBounded`,
  `snippetLinkNeverSpansALineTerminator`; writer-level
  `HTMLLinkIngestionTests.imageHeavyNewsletterPreviewsItsFirstSentence` and
  `textPlainLinkSoupPreviewsDeterministically`; loader tier 1
  `tierOneNewsletterSnippetIsTheFirstSentence`; NSE `displaySnippetSurvivesLongRunOfImageLinks`.
