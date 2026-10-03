/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

@Suite("AttachmentReadPdfTool")
struct AttachmentReadPdfToolTests {

    /// Records which attachment sections were downloaded and serves bytes per section.
    final class FakeServer: Sendable {
        let fetched = Mutex<[String]>([])
        let bodyLoads = Mutex(0)
        private let bytes: [String: Data]
        private let failing: Bool

        init(_ bytes: [String: Data] = [:], failing: Bool = false) {
            self.bytes = bytes
            self.failing = failing
        }

        var fetcher: AttachmentReadPdfTool.AttachmentFetcher {
            { [self] _, attachment in
                fetched.withLock { $0.append(attachment.section) }
                if failing { throw ProviderError.notConnected }
                return bytes[attachment.section] ?? Data()
            }
        }
    }

    private struct Fixture {
        let ctx: ToolContext
        let db: DatabaseQueue
        let header: MessageHeader
    }

    private func pdf(_ section: String, _ name: String, size: Int = 1000, parent: String? = nil) -> AttachmentInfo {
        AttachmentInfo(filename: name, contentType: "application/pdf", section: section, size: size,
                       encoding: "base64", parentEmlSection: parent)
    }

    private func file(_ section: String, _ name: String, type: String) -> AttachmentInfo {
        AttachmentInfo(filename: name, contentType: type, section: section, size: 1000, encoding: "base64")
    }

    private static func insertBody(_ db: DatabaseQueue, headerId: String, attachments: [AttachmentInfo]) throws {
        var body = MessageBody(contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>See attached</p>")
        body.attachmentsJSON = String(data: try JSONEncoder().encode(attachments), encoding: .utf8)
        try db.write { try body.insert($0) }
    }

    /// A message with numeric id 42 whose body lists `attachments` (no body row when nil).
    private func makeFixture(attachments: [AttachmentInfo]?) async throws -> Fixture {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "77", subject: "Invoice")
        if let attachments {
            try Self.insertBody(db, headerId: header.id, attachments: attachments)
        }
        await translator.seed(header.id, as: 42)
        return Fixture(ctx: ToolContext(db: db, translator: translator), db: db, header: header)
    }

    private func tool(_ fixture: Fixture, _ server: FakeServer,
                      loadBody: AttachmentReadPdfTool.BodyLoader? = nil,
                      limits: PDFTextExtractor.Limits? = nil) -> AttachmentReadPdfTool {
        AttachmentReadPdfTool(
            context: fixture.ctx,
            fetchAttachment: server.fetcher,
            loadBody: loadBody ?? { _ in Issue.record("body should not be loaded") },
            limits: limits)
    }

    private func errorMessage(_ result: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        return try #require(object?["error"] as? String)
    }

    // MARK: - Arguments

    @Test("Missing unique_id is rejected")
    func missingUniqueId() async throws {
        let fixture = try await makeFixture(attachments: [])
        let result = try await tool(fixture, FakeServer()).execute(arguments: [:])
        #expect(try errorMessage(result) == "invalid or missing unique_id")
    }

    @Test("Unknown unique_id is not found")
    func unknownId() async throws {
        let fixture = try await makeFixture(attachments: [])
        let result = try await tool(fixture, FakeServer()).execute(arguments: ["unique_id": .int(999)])
        #expect(try errorMessage(result) == "message not found for the given unique_id")
    }

    @Test("Invalid page arguments are rejected with TB's messages", arguments: [
        (["start_page": JSONValue.int(0)], "start_page must be a whole number of 1 or more"),
        (["start_page": .double(1.5)], "start_page must be a whole number of 1 or more"),
        (["start_page": .string("abc")], "start_page must be a whole number of 1 or more"),
        (["start_page": .bool(true)], "start_page must be a whole number of 1 or more"),
        (["end_page": .int(-2)], "end_page must be a whole number of 1 or more"),
        (["start_page": .int(3), "end_page": .int(2)], "end_page must not be before start_page"),
    ])
    func invalidPages(extra: [String: JSONValue], expected: String) async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "a.pdf")])
        let server = FakeServer()
        var arguments: [String: JSONValue] = ["unique_id": .int(42)]
        arguments.merge(extra) { _, new in new }
        let result = try await tool(fixture, server).execute(arguments: arguments)
        #expect(try errorMessage(result) == expected)
        #expect(server.fetched.withLock { $0 }.isEmpty)
    }

    @Test("Page arguments accept numeric strings and whole doubles")
    func parsePage() {
        #expect(AttachmentReadPdfTool.parsePage(nil) == .absent)
        #expect(AttachmentReadPdfTool.parsePage(.null) == .absent)
        #expect(AttachmentReadPdfTool.parsePage(.string("")) == .absent)
        #expect(AttachmentReadPdfTool.parsePage(.string(" 3 ")) == .page(3))
        #expect(AttachmentReadPdfTool.parsePage(.double(4)) == .page(4))
        #expect(AttachmentReadPdfTool.parsePage(.int(1)) == .page(1))
        #expect(AttachmentReadPdfTool.parsePage(.double(1e300)) == .invalid)
        #expect(AttachmentReadPdfTool.parsePage(.string("2.5")) == .invalid)
    }

    // MARK: - Reading

    @Test("The only PDF is read with TB's output format")
    func readsOnlyPdf() async throws {
        let data = PDFFixtures.make([.text("Total due 120 EUR"), .text("Thank you")])
        let fixture = try await makeFixture(attachments: [file("2", "photo.jpg", type: "image/jpeg"), pdf("3", "invoice.pdf")])
        let server = FakeServer(["3": data])
        let result = try await tool(fixture, server).execute(arguments: ["unique_id": .int(42)])

        let lines = result.components(separatedBy: "\n")
        try #require(lines.count >= 6)
        #expect(Array(lines[0...4]) == [
            "unique_id: 42", "attachment: invoice.pdf", "total_pages: 2", "pages_read: 1-2", "text:",
        ])
        #expect(lines[5] == "[page 1]")
        #expect(result.contains("Total due 120 EUR"))
        #expect(result.contains("[page 2]"))
        #expect(!result.contains("next_start_page"))
        #expect(!result.contains("note:"))
        #expect(server.fetched.withLock { $0 } == ["3"])
    }

    @Test("A string unique_id and a single-page range read one page")
    func singlePageRange() async throws {
        let data = PDFFixtures.make((1...4).map { .text("Page body \($0)") })
        let fixture = try await makeFixture(attachments: [pdf("2", "report.pdf")])
        let result = try await tool(fixture, FakeServer(["2": data])).execute(arguments: [
            "unique_id": .string("42"), "start_page": .string("2"), "end_page": .int(2),
        ])
        #expect(result.contains("pages_read: 2\n"))
        #expect(result.contains("next_start_page: 3"))
        #expect(result.contains("Page body 2"))
        #expect(!result.contains("Page body 3"))
    }

    @Test("A long PDF is read 20 pages per call and continues from next_start_page")
    func pagesPerCall() async throws {
        let data = PDFFixtures.make((1...23).map { .text("Section \($0)") })
        let fixture = try await makeFixture(attachments: [pdf("2", "long.pdf")])
        let reader = tool(fixture, FakeServer(["2": data]))

        let first = try await reader.execute(arguments: ["unique_id": .int(42)])
        #expect(first.contains("total_pages: 23"))
        #expect(first.contains("pages_read: 1-20"))
        #expect(first.contains("next_start_page: 21"))

        let rest = try await reader.execute(arguments: ["unique_id": .int(42), "start_page": .int(21)])
        #expect(rest.contains("pages_read: 21-23"))
        #expect(!rest.contains("next_start_page"))
    }

    @Test("Output limit notes: a stopped call and a cut first page")
    func outputLimitNotes() async throws {
        let data = PDFFixtures.make([.text("Alpha"), .text(String(repeating: "Bravo Charlie ", count: 10))])
        let fixture = try await makeFixture(attachments: [pdf("2", "notes.pdf")])
        let small = PDFTextExtractor.Limits(maxPages: 20, maxOutputChars: 30, timeout: .seconds(20))
        let reader = tool(fixture, FakeServer(["2": data]), limits: small)

        let stopped = try await reader.execute(arguments: ["unique_id": .int(42)])
        #expect(stopped.contains("pages_read: 1\n"))
        #expect(stopped.contains("next_start_page: 2"))
        #expect(stopped.contains("note: stopped at the per-call text limit; continue with start_page 2"))

        let cut = try await reader.execute(arguments: ["unique_id": .int(42), "start_page": .int(2)])
        #expect(cut.contains("note: page 2 is longer than one call can return; only its first 30 of "))
        #expect(!cut.contains("next_start_page"))
    }

    @Test("Image-only pages get the scanned-PDF note and per-page placeholders")
    func imageOnly() async throws {
        let data = PDFFixtures.make([.image, .empty])
        let fixture = try await makeFixture(attachments: [pdf("2", "scan.pdf")])
        let result = try await tool(fixture, FakeServer(["2": data])).execute(arguments: ["unique_id": .int(42)])
        #expect(result.contains("note: none of these pages has any text; the PDF is probably scanned images, and text recognition is not available"))
        #expect(result.contains("[page 1]\n(no text on this page)\n[page 2]\n(no text on this page)"))
    }

    @Test("An unreadable page is shown as such and suppresses the scanned note")
    func unreadablePageFormatting() {
        let result = AttachmentReadPdfTool.format(
            numericId: 7, attachment: pdf("2", "x.pdf"),
            pages: PDFTextExtractor.Pages(
                totalPages: 2, firstPage: 1, lastPage: 2,
                pages: [PDFTextExtractor.Page(page: 1, text: "", unreadable: true, cutFrom: nil),
                        PDFTextExtractor.Page(page: 2, text: "", unreadable: false, cutFrom: nil)],
                cutPage: nil, stoppedAtOutputLimit: false, nextStartPage: nil))
        #expect(result.contains("[page 1]\n(this page could not be read)\n[page 2]\n(no text on this page)"))
        #expect(!result.contains("note:"))
    }

    // MARK: - Choosing the attachment

    @Test("Several PDFs need attachment_name, and the named one is read")
    func severalPdfs() async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "a.pdf"), pdf("3", "b.pdf")])
        let server = FakeServer(["3": PDFFixtures.make([.text("Bravo document")])])
        let reader = tool(fixture, server)

        let ambiguous = try await reader.execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(ambiguous) == #"this email has several PDF attachments; set attachment_name to one of: "a.pdf", "b.pdf""#)

        let named = try await reader.execute(arguments: ["unique_id": .int(42), "attachment_name": .string("b.pdf")])
        #expect(named.contains("attachment: b.pdf"))
        #expect(named.contains("Bravo document"))
        #expect(server.fetched.withLock { $0 } == ["3"])
    }

    @Test("Attachment choice errors match TB")
    func choiceErrors() {
        let a = pdf("2", "a.pdf"), b = pdf("3", "b.pdf")
        let doc = file("4", "notes.docx", type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        func message(_ attachments: [AttachmentInfo], _ name: String) -> String? {
            if case .failure(let error) = AttachmentReadPdfTool.chooseAttachment(attachments, requestedName: name) {
                return error.message
            }
            return nil
        }
        #expect(message([a, b], "c.pdf") == #"no attachment named "c.pdf"; PDF attachments on this email: "a.pdf", "b.pdf""#)
        #expect(message([doc], "c.pdf") == #"no attachment named "c.pdf", and this email has no PDF attachments"#)
        #expect(message([a, pdf("5", "a.pdf")], "a.pdf") == #"this email has several attachments named "a.pdf", so this tool cannot tell which one to read"#)
        #expect(message([a, doc], "notes.docx") == #"attachment "notes.docx" is not a PDF"#)
        #expect(message([doc], "") == "this email has no PDF attachments")
        #expect(message([], "") == "this email has no PDF attachments")
    }

    @Test("A PDF is recognised by its content type or its .pdf name")
    func pdfRecognition() {
        #expect(AttachmentReadPdfTool.isPdfAttachment(file("2", "scan", type: "Application/PDF; name=scan")))
        #expect(AttachmentReadPdfTool.isPdfAttachment(file("2", "REPORT.PDF", type: "application/octet-stream")))
        #expect(!AttachmentReadPdfTool.isPdfAttachment(file("2", "pdf.txt", type: "text/plain")))
    }

    @Test("PDFs inside an attached .eml are not offered")
    func nestedPdfIgnored() async throws {
        let fixture = try await makeFixture(attachments: [
            file("2", "forwarded.eml", type: "message/rfc822"), pdf("2.2", "inner.pdf", parent: "2"),
        ])
        let server = FakeServer()
        let result = try await tool(fixture, server).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "this email has no PDF attachments")
        #expect(server.fetched.withLock { $0 }.isEmpty)
    }

    @Test("Names with quotes are returned as valid JSON")
    func quotedNameIsValidJson() async throws {
        let fixture = try await makeFixture(attachments: [file("2", #"say "hi".txt"#, type: "text/plain")])
        let result = try await tool(fixture, FakeServer()).execute(arguments: [
            "unique_id": .int(42), "attachment_name": .string(#"say "hi".txt"#),
        ])
        #expect(try errorMessage(result) == #"attachment "say "hi".txt" is not a PDF"#)
    }

    // MARK: - Size and download

    @Test("A PDF listed above the size limit is refused without downloading")
    func listedTooLarge() async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "big.pdf", size: 30 * 1024 * 1024)])
        let server = FakeServer()
        let result = try await tool(fixture, server).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "the PDF is too large to read (30.0 MB; the limit is 25.0 MB)")
        #expect(server.fetched.withLock { $0 }.isEmpty)
    }

    @Test("Downloaded bytes above the size limit are refused even when the listing was small")
    func downloadedTooLarge() async throws {
        let oversized = Data("%PDF-1.7\n".utf8) + Data(count: AttachmentReadPdfTool.Config.maxFileBytes)
        let fixture = try await makeFixture(attachments: [pdf("2", "big.pdf", size: 10)])
        let result = try await tool(fixture, FakeServer(["2": oversized])).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "the PDF is too large to read (25.0 MB; the limit is 25.0 MB)")
    }

    @Test("A failed download is reported")
    func downloadFails() async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "a.pdf")])
        let result = try await tool(fixture, FakeServer(failing: true)).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "could not download the attachment")
    }

    // MARK: - Unreadable files

    @Test("Bytes that are not a PDF are refused before parsing")
    func notAPdf() async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "fake.pdf")])
        let result = try await tool(fixture, FakeServer(["2": Data("PK\u{03}\u{04}zip".utf8)])).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "the file is not a readable PDF (it is damaged or not really a PDF)")
    }

    @Test("A damaged PDF is reported as not readable")
    func damaged() async throws {
        let fixture = try await makeFixture(attachments: [pdf("2", "broken.pdf")])
        let result = try await tool(fixture, FakeServer(["2": Data("%PDF-1.7\ngarbage\n%%EOF".utf8)])).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "the file is not a readable PDF (it is damaged or not really a PDF)")
    }

    @Test("A password-protected PDF is reported")
    func encrypted() async throws {
        let data = PDFFixtures.make([.text("Secret")], userPassword: "user-pass", ownerPassword: "owner-pass")
        let fixture = try await makeFixture(attachments: [pdf("2", "locked.pdf")])
        let result = try await tool(fixture, FakeServer(["2": data])).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "the PDF is password-protected, so its text cannot be read")
    }

    @Test("A start page past the end names the page count")
    func pastEnd() async throws {
        let data = PDFFixtures.make([.text("one"), .text("two")])
        let fixture = try await makeFixture(attachments: [pdf("2", "short.pdf")])
        let result = try await tool(fixture, FakeServer(["2": data])).execute(arguments: ["unique_id": .int(42), "start_page": .int(5)])
        #expect(try errorMessage(result) == "start_page 5 is past the last page (the PDF has 2 pages)")
    }

    @Test("Parsing past the deadline is reported as a timeout")
    func timeout() async throws {
        let data = PDFFixtures.make([.text("one")])
        let fixture = try await makeFixture(attachments: [pdf("2", "slow.pdf")])
        let expired = PDFTextExtractor.Limits(maxPages: 20, maxOutputChars: 100_000, timeout: .zero)
        let result = try await tool(fixture, FakeServer(["2": data]), limits: expired).execute(arguments: ["unique_id": .int(42)])
        #expect(try errorMessage(result) == "reading the PDF took too long and was stopped")
    }

    // MARK: - Evicted body

    @Test("An evicted body is loaded through the body funnel, then the PDF is read")
    func evictedBodyIsLoaded() async throws {
        let fixture = try await makeFixture(attachments: nil)
        let server = FakeServer(["2": PDFFixtures.make([.text("Loaded later")])])
        let db = fixture.db
        let reader = tool(fixture, server, loadBody: { header in
            server.bodyLoads.withLock { $0 += 1 }
            try Self.insertBody(db, headerId: header.id, attachments: [AttachmentInfo(
                filename: "late.pdf", contentType: "application/pdf", section: "2", size: 100, encoding: nil)])
        })
        let result = try await reader.execute(arguments: ["unique_id": .int(42)])
        #expect(server.bodyLoads.withLock { $0 } == 1)
        #expect(result.contains("attachment: late.pdf"))
        #expect(result.contains("Loaded later"))
    }

    @Test("A body that cannot be loaded means the attachments cannot be listed")
    func bodyLoadFails() async throws {
        let fixture = try await makeFixture(attachments: nil)
        let server = FakeServer()
        let failing = tool(fixture, server, loadBody: { _ in throw ProviderError.notConnected })
        #expect(try errorMessage(try await failing.execute(arguments: ["unique_id": .int(42)])) == "could not list the email's attachments")

        let silent = tool(fixture, server, loadBody: { _ in })
        #expect(try errorMessage(try await silent.execute(arguments: ["unique_id": .int(42)])) == "could not list the email's attachments")
        #expect(server.fetched.withLock { $0 }.isEmpty)
    }

    // MARK: - Registration

    @Test("The tool is registered with an activity label")
    func registered() {
        #expect(ToolRegistry.makeDefaultTools().contains { $0.name == "attachment_read_pdf" })
        #expect(ToolRegistry.activityLabel(for: "attachment_read_pdf") == "Reading PDF")
    }
}
