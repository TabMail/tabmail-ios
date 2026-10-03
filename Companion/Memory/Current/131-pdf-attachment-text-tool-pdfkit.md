# `attachment_read_pdf`: PDF attachment text for the chat agent (PDFKit)

Added 2026-10-03 for tabmail-ios#189, mirroring tabmail-thunderbird#112. The backend offers the
schema from `common/attachment_read_pdf-v1.9.0.json`, so only 1.9.0+ clients see it; the TB and iOS
1.9.0 bumps ship with the tool.

## Shape

- `TabMail/Services/AI/Tools/AttachmentReadPdfTool.swift`: the tool. Arguments, limits, output
  lines and error strings are copied from TB's `chat/tools/attachment_read_pdf.js`. Change them
  in both places or the model sees two different tools under one name. The one intended
  difference is the unresolved-id error, which follows `EmailReadTool`'s "message not found".
- `TabMail/Services/AI/Tools/PDFTextExtractor.swift` ports TB's `chat/modules/pdfText.js`
  onto PDFKit:
  - it uses only `PDFDocument(data:)` and `PDFPage.string`;
  - nothing is rendered, and no scripts or form actions run;
  - output is counted in UTF-16 units, as JavaScript `length` counts them;
  - a cut never splits a surrogate pair.

## Invariants

- **Attachments come from the `MessageBody` row**, which is an evictable cache. When the row is
  missing, the tool calls `AccountManager.fetchBody(for:)`, the guarded body funnel, and reads
  the header and body again. It never fabricates an attachment list.
- **The bytes come from `AccountManager.fetchAttachment`**, which applies the C3
  pending-move address guard (`IOS-BODY-005`).
- **Nothing is stored (ADR-004).** The tool does not read or write `BodyAssetStore`; bytes and
  text exist only for the call.
- **Only top-level attachments are offered** (`parentEmlSection == nil`); parts of an attached
  `.eml` are not.
- **Parsing runs in a detached task.** One deadline (20 s) is checked before the document opens
  and between pages; a timer resumes the caller at the deadline even when PDFKit is stuck
  inside one call. The abandoned task then stops at its next page boundary, because PDFKit
  cannot be interrupted.
- **Encrypted PDFs:** `isLocked` is true only when a user password is needed. An owner-only PDF
  opens and is read, which matches pdf.js.

## Tests

`TabMailTests/Tools/PDFTextExtractorTests.swift` and `AttachmentReadPdfToolTests.swift` build
every PDF in memory (`TabMailTests/Helpers/PDFFixtures.swift`, `UIGraphicsPDFRenderer`, with
passwords set through `kCGPDFContextUserPassword` and `kCGPDFContextOwnerPassword`). No real
document is committed.

The demo boundary (`DemoToolGuard.headerAccessible`) has no dedicated test: toggling the global
`DemoModeStore` would race other suites.
