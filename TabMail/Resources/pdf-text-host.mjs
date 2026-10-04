/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// pdf-text-host.mjs – bounded, text-only PDF extraction for the attachment_read_pdf tool, run by
// PDFTextHost in a hidden web view (its own WebContent process).
//
// A port of the Thunderbird add-on's chat/modules/pdfText.js (extractPdfText and readPages):
// same pdf.js build and options, same limits, outcomes and page text. Change both together, or the
// model sees two different tools under one name. Only the text layer is read: no rendering, no
// fonts, no forms or XFA, and no scripting (that lives in pdf.js's viewer sandbox, which is not
// bundled). pdf.js 6 has no eval path, and the CSP PDFTextHost sends with every response forbids eval
// in the page and in the worker.

import * as pdfjs from "./pdfjs/pdf.min.mjs";

pdfjs.GlobalWorkerOptions.workerSrc = new URL("./pdfjs/pdf.worker.min.mjs", import.meta.url).href;
const CMAP_URL = new URL("./pdfjs/cmaps/", import.meta.url).href;
const DOCUMENT_URL = new URL("./document", import.meta.url).href;

const PDF_TEXT_OUTCOME = Object.freeze({
  OK: "ok",
  ENCRYPTED: "encrypted",
  MALFORMED: "malformed",
  TIMEOUT: "timeout",
  PAST_END: "past_end",
  FAILED: "failed",
});

function pageTextFromContent(textContent) {
  let text = "";
  for (const item of textContent?.items || []) {
    // Marked-content markers carry no `str`.
    if (typeof item?.str !== "string") continue;
    text += item.str;
    if (item.hasEOL) text += "\n";
  }
  return text.replace(/[ \t]+\n/g, "\n").trim();
}

// page.getTextContent() without its `for await` over a ReadableStream, which WebKit cannot
// iterate (measured 2026-10-04 on iOS 26.5: "undefined is not a function" inside getTextContent).
// The add-on calls getTextContent(); both read the same stream with the same default options.
async function textContentOf(page) {
  const reader = page.streamTextContent().getReader();
  const items = [];
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return { items };
    items.push(...value.items);
  }
}

// Cut `text` to `max` UTF-16 units without splitting a surrogate pair.
function cutToLength(text, max) {
  let end = max;
  const code = text.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  return text.slice(0, end);
}

/**
 * Reads the PDF the host serves at ./document and extracts the text of pages
 * [range.startPage, range.endPage] (1-based, inclusive; endPage null means as far as the page cap
 * allows). See pdfText.js extractPdfText: each call gets its own pdf.js worker, terminated
 * outright at the deadline, because loadingTask.destroy() waits for a worker that may be busy in
 * one long step.
 */
async function readDocument(range, limits) {
  const data = new Uint8Array(await (await fetch(DOCUMENT_URL)).arrayBuffer());
  const worker = new pdfjs.PDFWorker();
  const loadingTask = pdfjs.getDocument({
    data,
    worker,
    cMapUrl: CMAP_URL,
    cMapPacked: true,
    disableFontFace: true,
    useSystemFonts: false,
    enableXfa: false,
    isOffscreenCanvasSupported: false,
    stopAtErrors: false,
    verbosity: 0,
  });

  let timer = null;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ outcome: PDF_TEXT_OUTCOME.TIMEOUT }), limits.timeoutMs);
  });
  // Once the deadline wins, `work` is abandoned; the catch keeps a later rejection from surfacing.
  const work = readPages(loadingTask, range, limits).catch(classifyError);

  const result = await Promise.race([work, deadline]);
  clearTimeout(timer);
  if (result.outcome === PDF_TEXT_OUTCOME.TIMEOUT) {
    worker.destroy();
    loadingTask.destroy().catch(() => {});
    return result;
  }
  try {
    await loadingTask.destroy();
  } catch {
    // The text is already read; a failed teardown changes nothing for the caller.
  }
  worker.destroy();
  return result;
}

function classifyError(e) {
  const name = e?.name || "";
  if (name === "PasswordException") return { outcome: PDF_TEXT_OUTCOME.ENCRYPTED };
  if (name === "InvalidPDFException") return { outcome: PDF_TEXT_OUTCOME.MALFORMED };
  return { outcome: PDF_TEXT_OUTCOME.FAILED, error: `${name} ${e?.message || e}` };
}

async function readPages(loadingTask, range, limits) {
  const doc = await loadingTask.promise;
  const totalPages = doc.numPages;
  if (!Number.isInteger(totalPages) || totalPages < 1) {
    return { outcome: PDF_TEXT_OUTCOME.MALFORMED };
  }
  if (range.startPage > totalPages) {
    return { outcome: PDF_TEXT_OUTCOME.PAST_END, totalPages };
  }

  const firstPage = range.startPage;
  const capPage = firstPage + limits.maxPages - 1;
  const lastRequested = Math.min(range.endPage ?? capPage, capPage, totalPages);

  const pages = [];
  let usedChars = 0;
  let cutPage = null;
  let stoppedAt = null;

  for (let pageNumber = firstPage; pageNumber <= lastRequested; pageNumber++) {
    let text = "";
    let unreadable = false;
    try {
      const page = await doc.getPage(pageNumber);
      text = pageTextFromContent(await textContentOf(page));
      page.cleanup();
    } catch (e) {
      // A damaged page does not make the rest of the document unreadable.
      if (e?.name === "PasswordException") throw e;
      unreadable = true;
    }

    if (usedChars + text.length > limits.maxOutputChars) {
      if (pages.length === 0) {
        pages.push({ page: pageNumber, text: cutToLength(text, limits.maxOutputChars), unreadable, cutFrom: text.length });
        cutPage = pageNumber;
      } else {
        stoppedAt = pageNumber;
      }
      break;
    }
    pages.push({ page: pageNumber, text, unreadable, cutFrom: null });
    usedChars += text.length;
  }

  const lastPage = pages[pages.length - 1].page;
  let nextStartPage = null;
  if (stoppedAt !== null) nextStartPage = stoppedAt;
  else if (lastPage < totalPages) nextStartPage = lastPage + 1;

  return {
    outcome: PDF_TEXT_OUTCOME.OK,
    totalPages,
    firstPage,
    lastPage,
    pages,
    cutPage,
    stoppedAtOutputLimit: stoppedAt !== null,
    nextStartPage,
  };
}

// The one entry point PDFTextHost calls (it imports this module with callAsyncJavaScript). Never
// rejects: every failure is an outcome.
export function extractPdfText(range, limits) {
  return readDocument(range, limits).catch((e) => ({ outcome: PDF_TEXT_OUTCOME.FAILED, error: `${e?.name || ""} ${e?.message || e}` }));
}
