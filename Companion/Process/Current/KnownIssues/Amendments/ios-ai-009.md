# IOS-AI-009

- Register classification: `accepted`
- New post-freeze record (2026-10-03) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-03, owner decision).** `attachment_read_pdf`'s decompression
pre-check (`PDFStreamBudget`) cannot measure the streams of a PDF encrypted with only an owner
password. Their bytes are ciphertext, so they fail to inflate and count as nothing. A crafted
owner-password PDF with a font `/ToUnicode` decompression bomb can therefore still drive
CoreGraphics past the iOS memory limit when the user asks the agent to read it.

Asked to choose between a 75 MB cap without decryption and the same cap plus RC4/AES decryption,
the owner chose the cap without decryption, with this case recorded as a known issue.

## Effect and recoverability

- **Trigger:** a hostile sender crafts the file, and the user asks the chat agent to read that
  attachment. Nothing reads PDFs automatically.
- **Effect:** iOS ends the app (jetsam). No user intention, message, or stored state is touched.
  The tool stores nothing (ADR-004), and the chat request is not replayed on relaunch.
- **Recovery:** relaunch. The same file triggers again only if the user asks again.
- **Not affected:** user-password PDFs (refused as encrypted before parsing), unencrypted PDFs (the
  pre-check covers them), and the per-page text cap (`PDFPageGlyphCounter` reads decrypted
  content through CoreGraphics, so encryption does not bypass it).

## Remedy if reopened

Decrypt each stream before counting, as PDF readers do: the standard security handler's RC4
(revisions 2 to 4) and AES-128/256 (V4/V5, revisions 4 to 6), keyed from the empty user password
and the file ID. This needs the `/Encrypt` dictionary resolved from the trailer and per-object keys,
which is more than the pre-check's raw-object pass reads today.

## Subsystem and search terms

`attachment_read_pdf`; `PDFStreamBudget`; `PDFPageGlyphCounter`; `PDFTextExtractor`; decompression
bomb; FlateDecode; `/ToUnicode`; CMap; `CGPDFStreamCopyData`; owner password; `kCGPDFContextOwnerPassword`;
jetsam; memory

## Related

Memory topic `131-pdf-attachment-text-tool-pdfkit.md` (measurements and design);
`PDFStreamBudgetTests`; tabmail-ios#189
