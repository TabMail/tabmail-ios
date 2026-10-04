## ADR-IOS-088: PDF Attachment Text Is Read by the Bundled pdf.js in a Hidden Web View, Not PDFKit

**Status:** Active (2026-10-04)

**Context:** `attachment_read_pdf` (tabmail-ios#189, memory topic 131) first shipped on PDFKit.
PDFKit and CoreGraphics parse inside the app, have no memory bound of their own, and a PDF from any
sender can make them allocate gigabytes, which on iOS is a jetsam kill of the whole app. Seven
review rounds added two guards in front of PDFKit: `PDFStreamBudget`, a decompression pre-check
over the raw bytes (75 MB per stream, 256 MB in total), and `PDFPageGlyphCounter`, a per-page text
cap plus a walk of every stream a page reaches. Every round found another way past them (decoy
object headers, image codecs in non-image roles, form names resolved as PDFKit resolves them), and
two gaps were accepted rather than closed: IOS-AI-009 (owner-password PDFs are ciphertext to the
pre-check) and IOS-AI-010 (valid PDFs with large lossless images are refused). The Thunderbird
add-on reads the same attachments with pdf.js (pdfjs-dist 6.3.289, vendored unmodified), which
runs in its own worker. Owner, 2026-10-04: use pdf.js on iOS too, since TabMail already ships it,
and add it to the vulnerability scan (both skill copies) to keep watch on it.

**Decision:**

1. iOS bundles the same pdf.js release as the add-on, byte for byte, under `TabMail/Vendor/pdfjs/`
   (legacy build `pdf.min.mjs` and `pdf.worker.min.mjs`, `cmaps/`, `LICENSE`; a folder reference in
   `project.yml`, about 3.4 MB). One upgrade moves both apps; the `tabmail-vulnerability-scan`
   skill checks the version against GitHub advisories and OSV.
2. `PDFTextHost` runs it in a hidden `WKWebView`, one per call, with a non-persistent data store
   (nothing reaches disk, ADR-004). The page is `pdf-text-host.html` plus `pdf-text-host.mjs`, a
   port of the add-on's `chat/modules/pdfText.js` (`extractPdfText`, `readPages`): same options
   (`enableXfa: false`, `disableFontFace: true`, no scripting sandbox, CMaps bundled), same
   limits, page text, cut and outcomes. Change the two together. Two WebKit adaptations: the host
   imports the module inside `callAsyncJavaScript` (WebKit reports `didFinish` before a module's
   imports load), and page text is read from `streamTextContent()` with a reader (WebKit cannot
   `for await` a `ReadableStream`, which `getTextContent()` does).
3. Everything is served from the app's `tabmail-pdf://local/` scheme: the page, the script,
   the pdf.js directory (no path leaves it), and the PDF bytes as data at `/document`, which the
   page fetches; the PDF is never navigated to. The page's CSP allows scripts, the worker and
   fetches from that scheme only; navigation to anything but the host page is cancelled.
4. pdf.js parses in WebKit's WebContent process. If the PDF exhausts memory there, that process
   ends, `webViewWebContentProcessDidTerminate` fires, and the call returns `.failed` ("the PDF
   could not be read", the add-on's wording); the app keeps running. pdf.js stops itself at the
   deadline by terminating its worker, as in the add-on; `PDFTextHost` additionally releases the
   web view `hostTeardownGrace` after the deadline if the page has not answered, and at once when
   the caller is cancelled.
5. `PDFStreamBudget`, `PDFPageGlyphCounter`, their tests and the `.tooLarge` outcome are deleted.
   IOS-AI-009 and IOS-AI-010 are resolved: no pre-check exists to be bypassed or to refuse.

**Trade-offs:**

- **Gained:** a memory bomb costs a WebContent process, not the app; no hand-written PDF parser to
  keep correct; one parser and one set of behaviours on both clients (ADR-IOS-008 parity); a
  deadline that really stops the parse, where PDFKit could not be interrupted.
- **Cost:** about 3.4 MB of app size; a vendored JavaScript dependency to keep patched (pdf.js has
  had code-execution CVEs, such as CVE-2024-4367 in font handling); a web view's start-up time
  per call; page lifecycle on the main actor; slower tests, which start a web view each.
- **Text differences from PDFKit, measured 2026-10-04 on macOS PDFs written by CoreGraphics:**
  CJK text in fonts without `/ToUnicode` (Hiragino, Apple SD Gothic Neo) is recovered by pdf.js as
  by PDFKit, which was the main risk. pdf.js follows the PDF's own maps where PDFKit sometimes
  repairs them: PingFang's map gives Kangxi radical code points (U+2F47 `⽇` for `日`); one
  system-font Cyrillic `к` came out as `ĸ`; and Latin text in a Helvetica fallback subset after
  Korean text lost two accented letters. The add-on has the same behaviour.
- **Backgrounding:** WebKit suspends the WebContent process while the app is suspended, so a read
  started just before the user leaves the app finishes, or times out, when they return.

**Alternatives rejected:** keep PDFKit with the guards (each review round found a new bypass, and
the two known gaps stayed open); run PDFKit in an app extension for process isolation (no
extension point fits parsing on demand for the chat agent); a native third-party parser such as PDFium (a larger binary dependency with its own CVE
stream, and a second parser to keep in step with the add-on).

**Related:** ADR-004 (nothing stored), ADR-IOS-008 (AI tool parity with Thunderbird), ADR-IOS-076
(message web views run no author script; this web view loads only bundled code), memory topic 131,
IOS-AI-009, IOS-AI-010, tabmail-ios#189, tabmail-thunderbird#112.
