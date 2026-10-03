/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import PDFKit
import Synchronization

/// Bounded, text-only PDF extraction for `AttachmentReadPdfTool`, mirroring TB's
/// `chat/modules/pdfText.js`. PDFKit is used only for `PDFDocument(data:)` and each page's
/// `string`: nothing is rendered, and PDF scripts and form actions are never run.
///
/// Parsing runs in a detached task, off the main actor and off `ToolRegistry`'s actor, so a heavy
/// PDF cannot stall the UI or other tools.
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
        /// PDFKit returned no page object for this index.
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
    /// nothing is stored either way.
    ///
    /// Returns `.timeout` once `limits.timeout` has passed. PDFKit cannot be interrupted inside a
    /// call, so the abandoned work stops at its next page boundary.
    static func extract(data: Data, startPage: Int, endPage: Int?, limits: Limits) async -> Outcome {
        let deadline = ContinuousClock.now + limits.timeout
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task.detached {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                once.resume(.timeout)
            }
            Task.detached(priority: .userInitiated) {
                let outcome = readPages(data: data, startPage: startPage, endPage: endPage,
                                        limits: limits, deadline: deadline)
                timer.cancel()
                once.resume(outcome)
            }
        }
    }

    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<Outcome, Never>?>
        init(_ continuation: CheckedContinuation<Outcome, Never>) {
            self.continuation = Mutex(continuation)
        }
        func resume(_ outcome: Outcome) {
            continuation.withLock { $0.take() }?.resume(returning: outcome)
        }
    }

    private static func readPages(
        data: Data, startPage: Int, endPage: Int?, limits: Limits, deadline: ContinuousClock.Instant
    ) -> Outcome {
        let pastDeadline = { ContinuousClock.now >= deadline }
        if pastDeadline() { return .timeout }

        guard let document = PDFDocument(data: data) else { return .malformed }
        // `isLocked` stays true only when a non-empty user password is needed; a PDF with just an
        // owner password opens and is readable.
        if document.isLocked { return .encrypted }
        let totalPages = document.pageCount
        guard totalPages >= 1 else { return .malformed }
        if startPage > totalPages { return .pastEnd(totalPages: totalPages) }

        let capPage = startPage + limits.maxPages - 1
        let lastRequested = min(endPage ?? capPage, capPage, totalPages)

        var pages: [Page] = []
        var usedChars = 0
        var cutPage: Int?
        var stoppedAt: Int?

        for pageNumber in startPage...lastRequested {
            if pastDeadline() { return .timeout }
            let pdfPage = document.page(at: pageNumber - 1)
            let text = normalize(pdfPage?.string ?? "")
            let length = text.utf16.count

            if usedChars + length > limits.maxOutputChars {
                if pages.isEmpty {
                    pages.append(Page(page: pageNumber, text: cut(text, toUTF16Length: limits.maxOutputChars),
                                      unreadable: pdfPage == nil, cutFrom: length))
                    cutPage = pageNumber
                } else {
                    stoppedAt = pageNumber
                }
                break
            }
            pages.append(Page(page: pageNumber, text: text, unreadable: pdfPage == nil, cutFrom: nil))
            usedChars += length
        }

        let lastPage = pages[pages.count - 1].page
        let nextStartPage: Int?
        if let stoppedAt { nextStartPage = stoppedAt }
        else if lastPage < totalPages { nextStartPage = lastPage + 1 }
        else { nextStartPage = nil }

        return .ok(Pages(
            totalPages: totalPages, firstPage: startPage, lastPage: lastPage, pages: pages,
            cutPage: cutPage, stoppedAtOutputLimit: stoppedAt != nil, nextStartPage: nextStartPage))
    }

    /// Same shape as TB's page text: unified line breaks, no spaces before a line break, trimmed.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts `text` to at most `max` UTF-16 units without splitting a Unicode scalar.
    static func cut(_ text: String, toUTF16Length max: Int) -> String {
        let utf16 = text.utf16
        guard utf16.count > max else { return text }
        var end = utf16.index(utf16.startIndex, offsetBy: max)
        while end > utf16.startIndex, end.samePosition(in: text.unicodeScalars) == nil {
            end = utf16.index(before: end)
        }
        return String(text.unicodeScalars[..<end])
    }
}
