# `attachment_read_pdf`: PDF attachment text for the chat agent (PDFKit)

Added 2026-10-03 for tabmail-ios#189, mirroring tabmail-thunderbird#112. The backend offers the
schema from `common/attachment_read_pdf-v1.9.0.json`, so only 1.9.0+ clients see it; the TB and iOS
1.9.0 bumps ship with the tool.

⚠️ **The version the backend sees is `TABMAIL_PROTOCOL_VERSION`, not `MARKETING_VERSION`.** The
`X-Client-Version` header is `BackendClient.clientVersion`, read from Info.plist
`TabMailProtocolVersion`, which is `TABMAIL_PROTOCOL_VERSION` in `project.yml`. Bumping only the
marketing version leaves the tool invisible. `AttachmentReadPdfToolTests.advertisesToolVersion`
pins this.

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
- **Parsing runs in its own task (`withTimeout`).** One deadline (20 s) is checked before the
  document opens, inside both memory checks, and between pages; `withTimeout` resumes the caller
  at the deadline even when PDFKit is stuck inside one call. The abandoned task then stops at its
  next page boundary, because PDFKit cannot be interrupted.

## Memory bounds: Apple's PDF stack has none

Measured 2026-10-03 on macOS 26 (peak RSS via `/usr/bin/time -l`). On iOS each of these is a
jetsam kill, not a catchable error:

- **`PDFPage.string` lays out every glyph first**, at about 430 bytes per character with no
  limit. A 31 KB PDF drawing 3.6M characters on one page reached **1.55 GB**.
- **CoreGraphics inflates some streams whole, with no output cap, and keeps them.** A 1 MB PDF
  whose font `/ToUnicode` CMap inflates to 1 GB took `page.string` to **2.66 GB**; ten 70 MB
  maps on one page reached 1.56 GB.
  - `CGPDFStreamCopyData` behaves the same, and CoreGraphics repairs a false `/Length` (a stream
    declaring 100 bytes still inflated 1 GB).
  - Content streams are the exception: `CGPDFScanner` decodes them incrementally (9 MB on a 1 GB
    flate bomb).
  - `CGPDFScanner` cannot read a CMap: `CGPDFOperatorTableSetCallback` refuses non-operator
    keywords such as `endbfchar`, and the scan clears the operand stack when it ends.

So two checks run before PDFKit sees anything:

- `PDFStreamBudget` is a pypdf-style decompression cap, the standard fix (pypdf
  CVE-2025-55197, 75 MB per stream; PDFium caps at 1 GiB).
  - It finds every `N G obj` in the raw bytes and lexes each object's dictionary separately, up
    to the next header, so an unclosed string or a fake `endstream` cannot hide a later object.
  - It reads the top-level `/Filter`, resolving `#xx` name escapes.
  - It undoes ASCII85/ASCIIHex layers, which Illustrator writes as `[/ASCII85Decode /FlateDecode]`.
  - It counts Flate, LZW and RunLength output with counting-only decoders, each fed the rest of
    the file and stopping where its data ends, so `/Length` is never trusted.
  - Caps: 75 MB per stream and 256 MB in total (the total is needed because CoreGraphics keeps
    decoded maps). A refused file is `.malformed`.
  - It refuses two expanding filters in one chain, an expanding filter behind an image codec, and
    an indirect `/Filter`.
  - **Known gap:** streams in owner-password-encrypted PDFs are ciphertext and count as nothing.
    Closing it needs RC4/AES; the owner chose the cap without decryption on 2026-10-03.
- `PDFPageGlyphCounter` adds up the bytes of strings drawn by `Tj`, `'`, `"` and `TJ`, including
  nested forms (depth 4, at most 2,000 invocations), using `CGPDFScanner`. It decodes no fonts
  and stops at the cap (200,000 bytes, about 86 MB in PDFKit). A page over the cap is left out
  as `unreadable` without calling `page.string`.

A basic CGPDFScanner text extractor was prototyped and dropped. Apple's own PDF writer omits
`/ToUnicode` for some CID fonts (CJK fallback fonts in `UIGraphicsPDFRenderer` output), and only
PDFKit recovers that text, from the embedded font program. The extractor also still needed
`CGPDFStreamCopyData` for every CMap.

Validation without false positives: 400 PDFs shipped with macOS and Xcode, and 60 large
real-world PDFs (up to 4,053 pages and 69 MB), all passed both checks in at most 0.5 s.
- **Encrypted PDFs:** `isLocked` is true only when a user password is needed. An owner-only PDF
  opens and is read, which matches pdf.js.

## Tests

`TabMailTests/Tools/PDFTextExtractorTests.swift`, `AttachmentReadPdfToolTests.swift`,
`PDFStreamBudgetTests.swift` and `PDFPageGlyphCounterTests.swift` build every PDF in memory (`TabMailTests/Helpers/PDFFixtures.swift`, `UIGraphicsPDFRenderer`, with
passwords set through `kCGPDFContextUserPassword` and `kCGPDFContextOwnerPassword`; raw objects
through `PDFFixtures.raw`/`streamObject`). No real document is committed. The bomb tests use
small caps, so each case is a few KB. They are two-sided: the same generated document without
the bomb must still read under the same caps.

The demo boundary (`DemoToolGuard.headerAccessible`) has no dedicated test: toggling the global
`DemoModeStore` would race other suites.
