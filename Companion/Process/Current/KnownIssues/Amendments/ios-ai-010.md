# IOS-AI-010

- Register classification: `accepted`
- New post-freeze record (2026-10-03) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-03, owner decision).** `attachment_read_pdf`'s decompression
pre-check (`PDFStreamBudget`, 75 MB per stream / 256 MB in total) counts every stream it can
decode, image streams included, although `PDFPage.string` never decodes an image. A valid PDF
with large lossless (Flate) images is therefore refused with "the PDF is too large or complex to
read safely", while the Thunderbird add-on (pdf.js) reads its text.

Measured by the round-2 review: one page with a 5100×5100 lossless RGB image (78 MB decoded, a
0.36 MB file) is refused, and so are 15 pages each with a 2600×2600 lossless image (304 MB in
total). PDFKit reads either at about 73 MB. JPEG (`DCTDecode`), JPEG 2000, JBIG2 and CCITT images
are not counted, so typical scans and photos are not affected. CoreGraphics decodes such a stream
to read text only where it is not an image (page content, a form, a colour space, a font), and
`PDFPageGlyphCounter` leaves out a page whose content or resources reach one. Roughly 17 full-screen Retina
screenshots stored losslessly pass the total cap.

Asked to choose between this honest refusal and exempting image streams (which needs a
CoreGraphics walk of every page's resources, because CoreGraphics still decodes a `/ToUnicode` map
falsely labelled `/Subtype /Image`: 923 MB measured), the owner chose the refusal with a truthful
message, recorded here.

The same message covers files whose layout the check cannot follow (a dictionary still open at the
next object, a `stream` keyword no counted object claims, an indirect `/Filter`): it fails closed
on those, as they are how decompression bombs were hidden from it.

## Effect and recoverability

- **Trigger:** the user asks the chat agent to read such an attachment.
- **Effect:** the agent reports that the PDF is too large or complex to read safely. Nothing is
  stored or changed (ADR-004).
- **Recovery:** the user opens the PDF in the attachment viewer. The refusal is per file and
  repeats for the same file.

## Remedy if reopened

Skip streams whose dictionary says `/Subtype /Image` in the raw pre-check, and before PDFKit
reads a page, walk its resources through CoreGraphics (dictionaries only, nothing decoded):
refuse when a stream labelled as an image is reached in any role other than an image (an
`/XObject` entry, `/SMask`, `/Mask`, `/Thumb`, `/Alternates`).

## Subsystem and search terms

`attachment_read_pdf`; `PDFStreamBudget`; `PDFTextExtractor.Outcome.tooLarge`; "too large or
complex to read safely"; lossless image; FlateDecode; `/Subtype /Image`; false refusal; TB parity

## Related

IOS-AI-009 (the owner-password gap in the same pre-check); memory topic
`131-pdf-attachment-text-tool-pdfkit.md`; `PDFStreamBudgetTests`; tabmail-ios#189
