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
  - Flate content streams are the exception: `CGPDFScanner` decodes them incrementally (9 MB on
    a 1 GB flate bomb). A content stream or form under an image codec (CCITT) is decoded whole:
    a 100 KB file reached 845 MB (round-4 review).
  - `CGPDFScanner` cannot read a CMap: `CGPDFOperatorTableSetCallback` refuses non-operator
    keywords such as `endbfchar`, and the scan clears the operand stack when it ends.

So two checks run before PDFKit sees anything:

- `PDFStreamBudget` is a pypdf-style decompression cap, the standard fix (pypdf
  CVE-2025-55197, 75 MB per stream; PDFium caps at 1 GiB).
  - It finds every `N G obj` in the raw bytes and lexes each object's dictionary separately, up
    to the next header, so the walk stays linear and a fake `endstream` cannot hide a later
    object. A dictionary still open at the next header is refused: an unclosed string, or a
    header inside a string or comment, means the walk cannot tell which object the following
    bytes belong to (a 9-byte `/X (9 0 obj)` decoy once hid a 300 MB `/ToUnicode` map, 1.19 GB
    RSS).
  - A final linear sweep refuses any `stream` keyword after `>>` (or first on its line after a
    line holding a `%`, which may start a comment) that no counted object claimed. A `%` earlier
    on the keyword's own line does not count: refusing it rejected valid files whose title or
    text reads "12% … stream" (round-4 review), such as one whose header is glued
    to the previous byte (`x4 0 obj`): CoreGraphics reaches it through the xref, the walk does not.
  - After `stream`, CoreGraphics skips whatever else is on the line (spaces, a comment, any
    token) and the data starts after its end of line (CR LF, LF or CR); a second EOL is data.
    Measured 2026-10-03; the walk does the same.
  - It reads the top-level `/Filter`, resolving `#xx` name escapes.
  - It undoes ASCII85/ASCIIHex layers, which Illustrator writes as `[/ASCII85Decode /FlateDecode]`.
  - It counts Flate, LZW and RunLength output with counting-only decoders, each fed the rest of
    the file and stopping where its data ends, so `/Length` is never trusted.
  - Caps: 75 MB per stream and 256 MB in total (the total is needed because CoreGraphics keeps
    decoded maps). A refused file is `.tooLarge`: "the PDF is too large or complex to read
    safely", an iOS-only message (TB's pdf.js has no such cap).
  - **Known false refusal (IOS-AI-010, owner-accepted 2026-10-03):** image streams count too,
    though `page.string` never decodes them, so valid PDFs with large lossless (Flate) images are
    refused. Skipping `/Subtype /Image` alone is unsafe: CoreGraphics still decodes a
    `/ToUnicode` map labelled as an image (923 MB).
  - It refuses two expanding filters in one chain, an expanding filter behind an image codec, and
    an indirect `/Filter` or `/Filter` array entry (CoreGraphics follows `[5 0 R]`). With
    duplicate `/Filter` keys CoreGraphics uses the last, as the walk does.
  - **Known gap:** streams in owner-password-encrypted PDFs are ciphertext and count as nothing.
    Closing it needs RC4/AES; the owner chose the cap without decryption on 2026-10-03.
- `PDFPageGlyphCounter` adds up the bytes of strings drawn by `Tj`, `'`, `"` and `TJ`, including
  every invocation of a form, using `CGPDFScanner`. It decodes no fonts and stops at the cap
  (200,000 bytes, about 86 MB in PDFKit). A page over the cap, or nesting forms deeper than 4, is
  left out as `unreadable` without calling `page.string`.
  - Every invocation counts, because PDFKit lays out every one: an earlier 2,000-invocation cap
    stopped counting silently, and 10,000 invocations of a 100-character form (1 KB of PDF) took
    PDFKit to 329 MB. A fail-closed invocation cap is no answer either: a real page in the
    460-PDF sample drew forms 89,744 times, and 9 of its 5,973 pages passed 2,000. One million
    invocations of an empty form take the counter 2.7 s at 7 MB, so the deadline bounds the work.
  - Depth 4 never tripped on the sample, and it stops a self-drawing form.
  - **Fonts (round-3 review, 2026-10-03).** It also follows every font the page selects (`Tf`, or
    an `ExtGState` `/Font`) through CoreGraphics' dictionaries, decoding nothing, and leaves the
    page out when the font reaches a stream whose filters `PDFStreamBudget.counts` rejects
    (CCITT, JBIG2, DCT, JPX, `/Crypt`, an unknown name, a `/Filter` that is not names). The
    pre-check leaves image codecs uncounted, and CoreGraphics decodes such a stream whole when a
    font reaches it: a 5 KB CCITT `/ToUnicode` map decoding to 40 MB took `page.string` to
    212 MB, and a variant with more code words pegged a core for about 400 s (the review's
    measurement), which the deadline cannot stop. Measured roles that decode: `/ToUnicode`,
    `/FontFile2` (83 MB), a stream `/Encoding` CMap, `/CIDToGIDMap`, a Type 3 font's resources,
    and a font set by `gs`. Not decoded: a font in the resources that no operator selects, an
    annotation's appearance, and an image a Type 3 glyph draws, so an image entry of an
    `/XObject` dictionary is not followed (in any other role it is checked, as labels lie). Each
    dictionary is followed once per role (a font dictionary that is also an `/XObject`
    dictionary is still checked as a font), and a font reaching deeper than 16 objects is left
    out. On the 460-PDF sample (11,267 pages) no page was left out.
  - **Every stream the page reaches (round-4 review, 2026-10-03), replacing the font check.**
    The round-4 review found the same CCITT bypass outside fonts: as page `/Contents` or a form
    (845 MB from a 100 KB file), and as an `ICCBased` or `Indexed` colour space a `cs` or an
    inline image's `/CS` selects. Following operators one role at a time kept missing roles, so
    the counter now walks, before scanning, every object reachable from the page's `/Contents`,
    `/Group` and nearest `/Resources` (inherited through `/Parent`), and leaves the page out
    when any stream has filters `PDFStreamBudget.counts` rejects. The one stream skipped is an
    entry of an `/XObject` dictionary with `/Subtype /Image` (an image drawn by `Do` is not
    decoded to read text, measured; Type 3 glyph images included). It deliberately also refuses
    roles CoreGraphics was measured not to decode when reading text (a font no operator
    selects, stroke colour spaces, shading functions, `/Properties`): following the invariant
    rather than the measured list is what stops the next missed role. Each dictionary is walked
    once per role, and a page reaching deeper than 64 objects is left out (16 falsely refused
    3 of 400 Xcode icon PDFs, which nest soft-mask groups). On the 460-PDF sample (11,267
    pages) no page was left out, and every CCITT probe that decodes was.
  Both `CGPDFContentStreamCreate…` results must be released (`CGPDFContentStreamRelease`; not
  CF-bridged, so ARC does not), or each page and form leaks about 170 B.

A basic CGPDFScanner text extractor was prototyped and dropped. Apple's own PDF writer omits
`/ToUnicode` for some CID fonts (CJK fallback fonts in `UIGraphicsPDFRenderer` output), and only
PDFKit recovers that text, from the embedded font program. The extractor also still needed
`CGPDFStreamCopyData` for every CMap.

Validation: 400 PDFs shipped with macOS and Xcode, and 60 large real-world PDFs (up to 4,053
pages and 69 MB), all passed both checks in at most 0.5 s, before and after the round-2 fixes.
That sample has no large lossless images, so it did not show the IOS-AI-010 false refusal.
The font check (round-3 fix) and the page stream check that replaced it (round-4 fix) left out
none of its 11,267 pages.
- **Encrypted PDFs:** `isLocked` is true only when a user password is needed. An owner-only PDF
  opens and is read, which matches pdf.js.

## Tests

`TabMailTests/Tools/PDFTextExtractorTests.swift`, `AttachmentReadPdfToolTests.swift`,
`PDFStreamBudgetTests.swift` and `PDFPageGlyphCounterTests.swift` build every PDF in memory (`TabMailTests/Helpers/PDFFixtures.swift`, `UIGraphicsPDFRenderer`, with
passwords set through `kCGPDFContextUserPassword` and `kCGPDFContextOwnerPassword`; raw objects
through `PDFFixtures.raw`/`streamObject`). No real document is committed. The bomb tests use
small caps, so each case is a few KB. They are two-sided: the same generated document without
the bomb must still read under the same caps.

The demo boundary (`DemoToolGuard.headerAccessible`) is tested in normal mode only, with a header
whose `accountId` is `DemoSeed.demoAccountId`, on the first read and after a body load: toggling
the global `DemoModeStore` would race other suites. The bypass tests in `PDFStreamBudgetTests`
use CoreGraphics' own decode (`CGPDFStreamCopyData`) as the oracle; keep the `CGPDFPage` alive
while reading its dictionary, which does not retain it.
