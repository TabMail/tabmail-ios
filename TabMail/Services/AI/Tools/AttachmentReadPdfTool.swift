/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `attachment_read_pdf` tool matching TB addon's `attachment_read_pdf.js`:
/// returns the text of a PDF attachment, a page range per call.
///
/// The PDF is downloaded through `AccountManager.fetchAttachment` (the same guarded path the
/// attachment preview uses) and parsed locally by `PDFTextExtractor`. The bytes and the text live
/// only for this call: nothing is cached or written to `BodyAssetStore` (ADR-004).
struct AttachmentReadPdfTool: AgentTool, Sendable {
    let name = "attachment_read_pdf"

    enum Config {
        static let maxFileBytes = 25 * 1024 * 1024
        static let maxPagesPerCall = 20
        /// Bounds the text handed to the model's context window per call; the reader continues
        /// with next_start_page. UTF-16 units, like TB.
        static let maxOutputChars = 100_000
        static let parseTimeout: Duration = .seconds(20)
        /// How far into the file the "%PDF-" header may sit (readers tolerate leading junk).
        static let signatureScanBytes = 1024
        /// Decompression caps checked before PDFKit opens the file (`PDFStreamBudget`). Per stream
        /// as pypdf (75 MB); in total because CoreGraphics keeps decoded font maps.
        static let maxDecodedStreamBytes = 75_000_000
        static let maxDecodedTotalBytes = 256_000_000
        /// Drawn-string bytes a page may have before PDFKit lays it out, at ~430 bytes per
        /// character (`PDFPageGlyphCounter`): at most ~86 MB for one page.
        static let maxPageTextBytes = 200_000
    }

    typealias AttachmentFetcher = @Sendable (MessageHeader, AttachmentInfo) async throws -> Data
    typealias BodyLoader = @Sendable (MessageHeader) async throws -> Void

    private let ctx: ToolContext
    private let fetchAttachment: AttachmentFetcher
    private let loadBody: BodyLoader
    private let limits: PDFTextExtractor.Limits

    init(
        context: ToolContext? = nil,
        fetchAttachment: AttachmentFetcher? = nil,
        loadBody: BodyLoader? = nil,
        limits: PDFTextExtractor.Limits? = nil
    ) {
        self.ctx = context ?? ToolContext()
        self.fetchAttachment = fetchAttachment ?? { header, attachment in
            try await AccountManager.shared.fetchAttachment(
                for: header, section: attachment.section, encoding: attachment.encoding)
        }
        self.loadBody = loadBody ?? { header in
            try await AccountManager.shared.fetchBody(for: header)
        }
        self.limits = limits ?? PDFTextExtractor.Limits(
            maxPages: Config.maxPagesPerCall,
            maxOutputChars: Config.maxOutputChars,
            timeout: Config.parseTimeout)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let numericId: Int
        if case .int(let n) = arguments["unique_id"] {
            numericId = n
        } else if case .string(let s) = arguments["unique_id"], let n = Int(s) {
            numericId = n
        } else if case .double(let d) = arguments["unique_id"], let n = Int(exactly: d) {
            numericId = n
        } else {
            return Self.error("invalid or missing unique_id")
        }

        let startPage: Int
        switch Self.parsePage(arguments["start_page"]) {
        case .absent: startPage = 1
        case .page(let n): startPage = n
        case .invalid: return Self.error("start_page must be a whole number of 1 or more")
        }
        let endPage: Int?
        switch Self.parsePage(arguments["end_page"]) {
        case .absent: endPage = nil
        case .page(let n): endPage = n
        case .invalid: return Self.error("end_page must be a whole number of 1 or more")
        }
        if let endPage, endPage < startPage {
            return Self.error("end_page must not be before start_page")
        }
        let requestedName: String
        if case .string(let s) = arguments["attachment_name"] { requestedName = s } else { requestedName = "" }

        guard let realId = await ctx.translator.toRealId(numericId) else {
            BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] Failed to resolve numeric id \(numericId)")
            return Self.error("message not found for the given unique_id")
        }
        guard var header = try await readHeader(realId) else {
            BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] MessageHeader not found for realId=\(realId.prefix(30))")
            return Self.error("message not found")
        }
        // Demo boundary (ADR-IOS-038): never read across the demo/real line.
        guard DemoToolGuard.headerAccessible(header) else {
            BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] Blocked cross-boundary access to \(realId.prefix(30))")
            return Self.error("message not found")
        }

        // The attachment list lives on the MessageBody row, an evictable cache. When it is gone,
        // load the body through the guarded funnel and read both rows again.
        var body = try await readBody(realId)
        if body == nil {
            do {
                try await loadBody(header)
            } catch {
                BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] Body load failed for \(realId.prefix(30)): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                return Self.error("could not list the email's attachments")
            }
            guard let reread = try await readHeader(realId), DemoToolGuard.headerAccessible(reread) else {
                return Self.error("message not found")
            }
            header = reread
            body = try await readBody(realId)
        }
        guard let body else {
            return Self.error("could not list the email's attachments")
        }

        // Only top-level attachments, as the attachment list shows them; parts inside an
        // attached .eml belong to that message.
        let attachments = body.attachments.filter { $0.parentEmlSection == nil }
        let attachment: AttachmentInfo
        switch Self.chooseAttachment(attachments, requestedName: requestedName) {
        case .failure(let failure): return Self.error(failure.message)
        case .success(let chosen): attachment = chosen
        }

        if attachment.size > Config.maxFileBytes {
            return Self.error(Self.tooLarge(attachment.size))
        }

        let data: Data
        do {
            data = try await fetchAttachment(header, attachment)
        } catch {
            BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] Download failed for \(realId.prefix(30)) section=\(DebugModeManager.escapedForLogLine(attachment.section)): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
            return Self.error("could not download the attachment")
        }
        // The listed size is only advisory (IMAP lists 0); the downloaded bytes are the authority.
        if data.count > Config.maxFileBytes {
            return Self.error(Self.tooLarge(data.count))
        }
        guard PDFTextExtractor.hasPdfSignature(data, scanBytes: Config.signatureScanBytes) else {
            return Self.error("the file is not a readable PDF (it is damaged or not really a PDF)")
        }

        let outcome = await PDFTextExtractor.extract(
            data: data, startPage: startPage, endPage: endPage, limits: limits)
        BackgroundSyncLogger.logDebug("[AttachmentReadPdfTool] realId=\(realId.prefix(30)) section=\(DebugModeManager.escapedForLogLine(attachment.section)) bytes=\(data.count) outcome=\(Self.outcomeName(outcome))")

        switch outcome {
        case .ok(let pages):
            return Self.format(numericId: numericId, attachment: attachment, pages: pages)
        case .encrypted:
            return Self.error("the PDF is password-protected, so its text cannot be read")
        case .malformed:
            return Self.error("the file is not a readable PDF (it is damaged or not really a PDF)")
        case .tooLarge:
            // iOS only: TB's pdf.js has no such cap (IOS-AI-010).
            return Self.error("the PDF is too large or complex to read safely")
        case .timeout:
            return Self.error("reading the PDF took too long and was stopped")
        case .pastEnd(let totalPages):
            return Self.error("start_page \(startPage) is past the last page (the PDF has \(totalPages) pages)")
        }
    }

    private func readHeader(_ realId: String) async throws -> MessageHeader? {
        try await ctx.db.read { db in try MessageHeader.fetchOne(db, key: realId) }
    }

    private func readBody(_ realId: String) async throws -> MessageBody? {
        try await ctx.db.read { db in try MessageBody.fetchOne(db, key: realId) }
    }

    // MARK: - Helpers (internal for tests)

    static func isPdfAttachment(_ attachment: AttachmentInfo) -> Bool {
        let type = attachment.contentType.lowercased()
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return type == "application/pdf" || attachment.filename.lowercased().hasSuffix(".pdf")
    }

    enum PageArgument: Equatable {
        case absent
        case page(Int)
        case invalid
    }

    /// Absent (missing, null or "") or a whole number of 1 or more; a numeric string counts, as
    /// in TB.
    static func parsePage(_ value: JSONValue?) -> PageArgument {
        let number: Double
        switch value {
        case .none, .null: return .absent
        case .string(let s) where s.isEmpty: return .absent
        case .int(let n): return n >= 1 ? .page(n) : .invalid
        case .double(let d): number = d
        case .string(let s):
            guard let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .invalid }
            number = d
        default: return .invalid
        }
        guard number >= 1, number <= Double(Int32.max), number.rounded() == number else { return .invalid }
        return .page(Int(number))
    }

    private static func quoteNames(_ attachments: [AttachmentInfo]) -> String {
        attachments.map { "\"\($0.filename)\"" }.joined(separator: ", ")
    }

    struct ChoiceError: Error, Equatable { let message: String }

    static func chooseAttachment(_ attachments: [AttachmentInfo], requestedName: String) -> Result<AttachmentInfo, ChoiceError> {
        let pdfs = attachments.filter(isPdfAttachment)
        if !requestedName.isEmpty {
            let named = attachments.filter { $0.filename == requestedName }
            if named.isEmpty {
                return .failure(ChoiceError(message: pdfs.isEmpty
                    ? "no attachment named \"\(requestedName)\", and this email has no PDF attachments"
                    : "no attachment named \"\(requestedName)\"; PDF attachments on this email: \(quoteNames(pdfs))"))
            }
            if named.count > 1 {
                return .failure(ChoiceError(message: "this email has several attachments named \"\(requestedName)\", so this tool cannot tell which one to read"))
            }
            if !isPdfAttachment(named[0]) {
                return .failure(ChoiceError(message: "attachment \"\(requestedName)\" is not a PDF"))
            }
            return .success(named[0])
        }
        if pdfs.isEmpty { return .failure(ChoiceError(message: "this email has no PDF attachments")) }
        if pdfs.count > 1 {
            return .failure(ChoiceError(message: "this email has several PDF attachments; set attachment_name to one of: \(quoteNames(pdfs))"))
        }
        return .success(pdfs[0])
    }

    private static func tooLarge(_ bytes: Int) -> String {
        "the PDF is too large to read (\(megabytes(bytes)); the limit is \(megabytes(Config.maxFileBytes)))"
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / (1024 * 1024))
    }

    static func format(numericId: Int, attachment: AttachmentInfo, pages result: PDFTextExtractor.Pages) -> String {
        var lines: [String] = []
        lines.append("unique_id: \(numericId)")
        lines.append("attachment: \(attachment.filename)")
        lines.append("total_pages: \(result.totalPages)")
        lines.append("pages_read: \(result.firstPage == result.lastPage ? "\(result.firstPage)" : "\(result.firstPage)-\(result.lastPage)")")
        if let next = result.nextStartPage { lines.append("next_start_page: \(next)") }

        var notes: [String] = []
        if let cutPage = result.cutPage, let first = result.pages.first, let cutFrom = first.cutFrom {
            notes.append("page \(cutPage) is longer than one call can return; only its first \(first.text.utf16.count) of \(cutFrom) characters are shown")
        }
        if result.stoppedAtOutputLimit, let next = result.nextStartPage {
            notes.append("stopped at the per-call text limit; continue with start_page \(next)")
        }
        if result.pages.allSatisfy({ $0.text.isEmpty && !$0.unreadable }) {
            notes.append("none of these pages has any text; the PDF is probably scanned images, and text recognition is not available")
        }
        for note in notes { lines.append("note: \(note)") }

        lines.append("text:")
        for page in result.pages {
            lines.append("[page \(page.page)]")
            if page.unreadable { lines.append("(this page could not be read)") }
            else { lines.append(page.text.isEmpty ? "(no text on this page)" : page.text) }
        }
        return lines.joined(separator: "\n")
    }

    private static func outcomeName(_ outcome: PDFTextExtractor.Outcome) -> String {
        switch outcome {
        case .ok: return "ok"
        case .encrypted: return "encrypted"
        case .malformed: return "malformed"
        case .tooLarge: return "too_large"
        case .timeout: return "timeout"
        case .pastEnd: return "past_end"
        }
    }

    private static func error(_ message: String) -> String {
        ToolJSON.string(from: ["error": message])
    }
}
