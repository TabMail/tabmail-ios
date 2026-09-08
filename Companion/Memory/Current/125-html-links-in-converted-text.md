# HTML links in converted text — issue 100

`EmailFilter.htmlToPlainText` retains visible anchor destinations as `[label](address)`.
This is the shared conversion used by `extractPlainText` for new FTS body writes and by
`EmailReadTool` for cached HTML reads. The existing FTS read path retains the same text
after display-cache eviction. Snippets and outgoing plain-text conversion also use this helper.

The byte scanner reads quoted and unquoted href values, decodes entities, and escapes
Markdown label/destination delimiters. Existing hidden-content suppression remains in place.
Anchors without a nonempty href remain plain text; empty labels still retain the address.

Owner scope: forward-only conversion. No backfill, cache sweep, historical repair, or
older-client compatibility work. Existing FTS rows change only through ordinary future writes.

Regression coverage: `EmailFilterLinkTests` and
`HTMLLinkIngestionTests.linkAddressesReachAgentAndSearch`, including Markdown destination
round trips and the real fetch/render/persistence/FTS pipeline.
