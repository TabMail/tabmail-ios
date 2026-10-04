/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Bounded, text-only PDF extraction for `AttachmentReadPdfTool`, mirroring TB's
/// `chat/modules/pdfText.js` with the same bundled pdf.js (ADR-IOS-088). `PDFTextHost` runs it
/// in a hidden web view, so parsing happens in WebKit's WebContent process: a PDF that exhausts
/// memory there ends that process, not the app, and the call returns `.failed`.
enum PDFTextExtractor {

    struct Limits: Sendable {
        let maxPages: Int
        /// Counted in UTF-16 code units, like TB (JavaScript string length).
        let maxOutputChars: Int
        let timeout: Duration
    }

    struct Page: Sendable, Equatable {
        let page: Int
        let text: String
        /// pdf.js could not read this page; the rest of the document still is.
        let unreadable: Bool
        /// The page's full length when it was cut at the output limit; nil otherwise.
        let cutFrom: Int?
    }

    struct Pages: Sendable, Equatable {
        let totalPages: Int
        let firstPage: Int
        let lastPage: Int
        let pages: [Page]
        let cutPage: Int?
        let stoppedAtOutputLimit: Bool
        let nextStartPage: Int?
    }

    enum Outcome: Sendable, Equatable {
        case ok(Pages)
        case encrypted
        case malformed
        /// pdf.js failed on the file, or the WebContent process running it ended (memory).
        case failed
        case timeout
        case pastEnd(totalPages: Int)
    }

    private static let signature: [UInt8] = Array("%PDF-".utf8)

    /// True when "%PDF-" occurs within the first `scanBytes` bytes. Readers accept leading junk
    /// before the header, so the check is a window, not offset 0.
    static func hasPdfSignature(_ data: Data, scanBytes: Int) -> Bool {
        let window = Array(data.prefix(scanBytes))
        guard window.count >= signature.count else { return false }
        for start in 0...(window.count - signature.count)
        where window[start..<(start + signature.count)].elementsEqual(signature) {
            return true
        }
        return false
    }

    /// Extracts the text of pages `startPage...endPage` (1-based, inclusive; `endPage` nil means
    /// as far as the page cap allows), clamped to the document and to `limits.maxPages`.
    ///
    /// Text accumulates up to `limits.maxOutputChars`: a page that would overflow is left for the
    /// next call (`nextStartPage`), except the FIRST page of the call, which is cut at the limit
    /// so every call makes progress. The cap bounds what reaches the model's context window;
    /// nothing is stored either way. Returns `.timeout` once `limits.timeout` has passed.
    static func extract(data: Data, startPage: Int, endPage: Int?, limits: Limits) async -> Outcome {
        await PDFTextHost.extract(data: data, startPage: startPage, endPage: endPage, limits: limits)
    }
}
