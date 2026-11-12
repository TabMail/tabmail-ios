/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

/// #434 — reading an Outlook message downloads the bytes of its inline images,
/// once each and up to the cap, and of no other attachment.
///
/// **The invariant, stated as a system property:** *the attachment bytes Graph
/// serves while a message is read are inline images' (`isInline`, `image/*`),
/// each once, only when the HTML has a `cid:` reference, and at most the
/// inline-image cap of them; no other file's, the files of an attached email
/// included. Every attachment is still listed or shown inline (except an
/// inline image whose content id the body does not reference, #550), an
/// attached email's files when the user opens it, and every referenced image
/// still resolves.* The list does not carry a content id, so
/// which image a `cid:` names is known only from the image's own GET. Both
/// readers are held to it: the notification service extension
/// (`GraphAPI.messageFull`) and the main app (`ExchangeProvider.fetchMessage`).
///
/// The oracle is `GraphAttachmentServer`, which serves bytes the way Graph does
/// and counts them: a message read with `$expand=attachments`, an attachment
/// list without a `$select`, or an attached email expanded with its
/// attachments, carries every file's bytes. A reader that pulls bytes it does
/// not show is therefore caught at the HTTP boundary, whatever route it takes.
@Suite("Graph attachment bytes — a read downloads only the inline images it shows")
struct GraphAttachmentBytesTests {

    enum Reader: String, CaseIterable, CustomTestStringConvertible {
        case notificationService, mainApp
        var testDescription: String { rawValue }
    }

    /// What a reader returned, in the terms the invariant needs.
    struct Read {
        /// File names listed as attachments.
        let listed: [String]
        /// Content ids of the inline images resolved.
        let resolvedImages: [String]
        /// Whether a `cid:` reference was left without its image.
        let unresolved: Bool
    }

    private static let messageId = "m1"

    private static let logo = GraphAttachmentServer.File(
        id: "logo", name: "logo.png", contentType: "image/png", isInline: true,
        contentId: "<logo@example.com>", bytes: Data(repeating: 0x89, count: 300))
    private static let chart = GraphAttachmentServer.File(
        id: "chart", name: "chart.png", contentType: "image/png", isInline: true,
        contentId: "chart@example.com", bytes: Data(repeating: 0x50, count: 500))
    private static let report = GraphAttachmentServer.File(
        id: "report", name: "report.pdf", contentType: "application/pdf", isInline: false,
        contentId: nil, bytes: Data(repeating: 0x25, count: 64 * 1024))
    private static let notes = GraphAttachmentServer.File(
        id: "notes", name: "notes.txt", contentType: "text/plain", isInline: false,
        contentId: nil, bytes: Data("notes".utf8))
    /// An image attached as a file, not shown in the body.
    private static let attachedPhoto = GraphAttachmentServer.File(
        id: "photo", name: "photo.jpg", contentType: "image/jpeg", isInline: false,
        contentId: nil, bytes: Data(repeating: 0xD8, count: 2048))
    /// An inline part that is not an image.
    private static let inlineCard = GraphAttachmentServer.File(
        id: "card", name: "card.vcf", contentType: "text/vcard", isInline: true,
        contentId: "card@example.com", bytes: Data("BEGIN:VCARD".utf8))

    private static let showsBothImages = "<p>Hi</p><img src=\"cid:logo@example.com\"><img src=\"CID:chart@example.com\">"

    private static func mainApp(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    private static func read(_ reader: Reader, from http: FakeHTTP.Scenario) async throws -> Read {
        switch reader {
        case .notificationService:
            let authed = AuthedHTTP(
                auth: AccountAuthSource(accountId: "acc1") { _ in "token" },
                retry: .graph, logLabel: "GraphAttachmentBytesTests", session: http.session)
            let (_, rendered) = try await GraphAPI.messageFull(http: authed, id: messageId)
            let html = rendered.htmlContent ?? ""
            let resolved = [logo, chart].filter {
                html.contains("data:\($0.contentType);base64,\($0.bytes.base64EncodedString())")
            }
            return Read(
                listed: rendered.attachments.map(\.filename),
                resolvedImages: resolved.map(\.id),
                unresolved: rendered.hasUnresolvedCIDs)
        case .mainApp:
            let info = try await mainApp(http).fetchMessage(id: messageId, folder: "inbox-id")
            let byContentId = Dictionary(uniqueKeysWithValues: [logo, chart].map {
                ($0.contentId!.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), $0)
            })
            let resolved = info.inlineImages.compactMap { image in
                byContentId[image.contentId].flatMap { $0.bytes == image.data ? $0.id : nil }
            }
            let html = info.htmlBody ?? ""
            let unresolved = byContentId.keys.contains {
                html.range(of: "cid:\($0)", options: .caseInsensitive) != nil && !resolved.contains(byContentId[$0]!.id)
            }
            return Read(listed: info.attachments.map(\.filename), resolvedImages: resolved, unresolved: unresolved)
        }
    }

    @Test("A read downloads each inline image it shows once, and no other attachment's bytes",
          arguments: Reader.allCases)
    func readDownloadsOnlyTheInlineImagesItShows(reader: Reader) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Two per page, so the list spans three pages and all must be read.
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [Self.report, Self.logo, Self.attachedPhoto, Self.notes, Self.inlineCard, Self.chart],
            pageSize: 2)
        server.install(on: http)

        let read = try await Self.read(reader, from: http)

        #expect(server.bytesServed() == ["logo": 1, "chart": 1],
                "only the shown inline images' bytes are downloaded, once each")
        #expect(Set(read.resolvedImages) == ["logo", "chart"])
        #expect(!read.unresolved)
        #expect(Set(read.listed).isSuperset(of: ["report.pdf", "photo.jpg", "notes.txt", "card.vcf"]),
                "every file is listed, including those on later pages")
    }

    @Test("A body with no cid: reference downloads no attachment bytes", arguments: Reader.allCases)
    func bodyWithoutReferencesDownloadsNothing(reader: Reader) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: "<p>No images here</p>",
            files: [Self.report, Self.logo], pageSize: 10)
        server.install(on: http)

        let read = try await Self.read(reader, from: http)

        #expect(server.bytesServed().isEmpty)
        #expect(read.resolvedImages.isEmpty)
        #expect(!read.unresolved)
        #expect(read.listed.contains("report.pdf"))
    }

    @Test("A list Graph fails to return fails the read, so no body is kept without its attachments",
          arguments: Reader.allCases)
    func failedListFailsTheRead(reader: Reader) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [Self.report, Self.logo], pageSize: 10, listStatus: 500)
        server.install(on: http)

        await #expect(throws: (any Error).self) { _ = try await Self.read(reader, from: http) }
        #expect(server.bytesServed().isEmpty)
    }

    @Test("Main app: an inline image Graph returns without a content id is listed as a file")
    func inlineImageWithoutContentIdIsListed() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let unnamed = GraphAttachmentServer.File(
            id: "photo", name: "photo.jpg", contentType: "image/jpeg", isInline: true,
            contentId: nil, bytes: Data(repeating: 0xFF, count: 40))
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [unnamed, Self.logo], pageSize: 10)
        server.install(on: http)

        let read = try await Self.read(.mainApp, from: http)

        #expect(read.listed == ["photo.jpg"], "an image the body cannot reference is not lost")
        #expect(read.resolvedImages == ["logo"])
        #expect(server.bytesServed() == ["photo": 1, "logo": 1])
    }

    @Test("A body that references an image only by an upper-case CID: still resolves it",
          arguments: Reader.allCases)
    func upperCaseReferenceResolves(reader: Reader) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: "<p>Hi</p><img src=\"CID:logo@example.com\">",
            files: [Self.report, Self.logo], pageSize: 10)
        server.install(on: http)

        let read = try await Self.read(reader, from: http)

        #expect(server.bytesServed() == ["logo": 1])
        #expect(read.resolvedImages == ["logo"])
        #expect(!read.unresolved)
    }

    @Test("A read fetches the bytes of at most the inline-image cap, the first ones listed",
          arguments: Reader.allCases)
    func readFetchesAtMostTheCap(reader: Reader) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let cap = BodyRenderer.maxInlineImages
        let files = (0...cap).map { index in
            GraphAttachmentServer.File(
                id: "img\(index)", name: "img\(index).png", contentType: "image/png", isInline: true,
                contentId: "img\(index)@example.com", bytes: Data(repeating: UInt8(index % 256), count: 16))
        }
        let server = GraphAttachmentServer(
            messageId: Self.messageId,
            html: files.map { "<img src=\"cid:\($0.contentId ?? "")\">" }.joined(),
            files: files, pageSize: files.count)
        server.install(on: http)

        _ = try await Self.read(reader, from: http)

        #expect(server.bytesServed() == Dictionary(uniqueKeysWithValues: (0..<cap).map { ("img\($0)", 1) }))
    }

    enum InlineGetFailure: String, CaseIterable, CustomTestStringConvertible {
        /// The image's own GET answers with a server error.
        case serverError
        /// The image's own GET answers 200 without `contentBytes`.
        case withoutBytes
        var testDescription: String { rawValue }
        var answer: GraphAttachmentServer.File.GetAnswer {
            switch self {
            case .serverError: .status(500)
            case .withoutBytes: .withoutBytes
            }
        }
    }

    @Test("An inline image whose own GET fails is not lost: it is listed and its cid: stays unresolved",
          arguments: Reader.allCases, InlineGetFailure.allCases)
    func failedInlineFetchIsNotLost(reader: Reader, failure: InlineGetFailure) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var failing = Self.logo
        failing.getAnswer = failure.answer
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [failing, Self.chart], pageSize: 10)
        server.install(on: http)

        let read = try await Self.read(reader, from: http)

        #expect(read.listed.contains("logo.png"), "the image is listed, so the user still sees it exists")
        #expect(read.resolvedImages == ["chart"])
        #expect(read.unresolved, "the failed image's cid: is left for a later fetch")
        #expect(server.bytesServed() == ["chart": 1])
    }

    @Test("Main app: opening a file returns its bytes, and fails when Graph returns none")
    func openingAFileNeedsItsBytes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var empty = Self.report
        empty.getAnswer = .withoutBytes
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: "<p>Files</p>", files: [empty, Self.notes], pageSize: 10)
        server.install(on: http)
        let provider = Self.mainApp(http)

        let notes = try await provider.fetchAttachment(messageId: Self.messageId, attachmentId: Self.notes.id)
        #expect(notes == Self.notes.bytes)
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchAttachment(messageId: Self.messageId, attachmentId: empty.id)
        }
    }

    enum NotShown: String, CaseIterable, CustomTestStringConvertible {
        /// The body has no `cid:` reference at all.
        case noReference
        /// The body references more inline images than a read resolves.
        case pastTheCap
        var testDescription: String { rawValue }
    }

    @Test("Main app: an inline image the body does not show is listed as a file, without its bytes",
          arguments: NotShown.allCases)
    func inlineImageNotShownIsListed(_ notShown: NotShown) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let cap = SyncConfig.maxInlineImages
        let html: String
        let files: [GraphAttachmentServer.File]
        let expectedListed: Set<String>
        let expectedServed: [String: Int]
        switch notShown {
        case .noReference:
            let unnamed = GraphAttachmentServer.File(
                id: "photo", name: "photo.jpg", contentType: "image/jpeg", isInline: true,
                contentId: nil, bytes: Data(repeating: 0xFF, count: 40))
            html = "<p>No images here</p>"
            files = [unnamed, Self.logo]
            expectedListed = ["photo.jpg", "logo.png"]
            expectedServed = [:]
        case .pastTheCap:
            files = (0...cap).map { index in
                GraphAttachmentServer.File(
                    id: "img\(index)", name: "img\(index).png", contentType: "image/png", isInline: true,
                    contentId: "img\(index)@example.com", bytes: Data(repeating: UInt8(index % 256), count: 16))
            }
            html = files.map { "<img src=\"cid:\($0.contentId!)\">" }.joined()
            expectedListed = ["img\(cap).png"]
            expectedServed = Dictionary(uniqueKeysWithValues: (0..<cap).map { ("img\($0)", 1) })
        }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: html, files: files, pageSize: files.count)
        server.install(on: http)

        let read = try await Self.read(.mainApp, from: http)

        #expect(Set(read.listed) == expectedListed, "an inline image TabMail does not show is not lost")
        #expect(server.bytesServed() == expectedServed)
    }

    // MARK: - An attached email (an Outlook itemAttachment)

    private static let forwarded = GraphAttachmentServer.File(
        id: "fwd", name: "Fwd: plan.eml", contentType: "message/rfc822", isInline: false,
        contentId: nil, bytes: Data(), isAttachedEmail: true)

    private static func attachedEmailServer(
        dated: Bool = true, failingOpens: Int = 0, listContinues: Bool = false
    ) -> GraphAttachmentServer {
        GraphAttachmentServer(
            messageId: messageId, html: "<p>See the attached mail</p>",
            files: [forwarded], pageSize: 10, attachedEmailFiles: [report, notes],
            attachedEmailDated: dated, failingAttachedEmailOpens: failingOpens,
            attachedEmailListContinues: listContinues)
    }

    /// The attached email's files, as `EmlAttachmentPreview` lists them when the
    /// user opens it.
    @MainActor
    private static func open(_ provider: ExchangeProvider) async -> EmlAttachmentPreview.FilesOnOpen {
        await EmlAttachmentPreview.filesOnOpen {
            try await provider.fetchAttachedEmailAttachments(messageId: messageId, section: forwarded.id)
        }
    }

    @Test("Main app: reading a message previews its attached email and downloads none of its files' bytes")
    func readingAnAttachedEmailDownloadsNoFileBytes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = Self.attachedEmailServer()
        server.install(on: http)

        let info = try await Self.mainApp(http).fetchMessage(id: Self.messageId, folder: "inbox-id")

        #expect(server.bytesServed().isEmpty, "no file of the attached email is downloaded")
        let html = info.htmlBody ?? ""
        #expect(html.contains("class=\"tm-eml-section\""), "the attached email is previewed")
        #expect(html.contains(GraphAttachmentServer.attachedEmailBody))
        #expect(html.contains("data-subject=\"Plan\""))
        #expect(html.contains("data-date="))
        let chip = info.attachments.first { $0.section == Self.forwarded.id }
        #expect(chip?.parentEmlSection == nil)
        #expect(chip?.filesListedOnOpen == true, "its files are listed when the user opens it")
        #expect(!info.attachments.contains { $0.parentEmlSection != nil })
    }

    @Test("Main app: an attached email Graph returns without a date has no date in its preview")
    func attachedEmailWithoutDateHasNone() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.attachedEmailServer(dated: false).install(on: http)

        let info = try await Self.mainApp(http).fetchMessage(id: Self.messageId, folder: "inbox-id")

        let html = info.htmlBody ?? ""
        #expect(html.contains("data-subject=\"Plan\""))
        #expect(!html.contains("data-date="), "no date is made up")
        #expect(!html.contains("<b>Date:</b>"))
    }

    @Test("Main app: opening an attached email lists every one of its files")
    @MainActor
    func openingAnAttachedEmailListsItsFiles() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.attachedEmailServer().install(on: http)

        guard case .listed(let files) = await Self.open(Self.mainApp(http)) else {
            Issue.record("the attached email's files are listed")
            return
        }
        #expect(Set(files.map(\.filename)) == ["report.pdf", "notes.txt"])
        #expect(files.allSatisfy { $0.parentEmlSection == Self.forwarded.id })
    }

    @Test("Main app: an attached email whose files cannot be listed shows the failure, and opening it again lists them")
    @MainActor
    func failedOpenIsShownAndRetried() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.attachedEmailServer(failingOpens: 1).install(on: http)
        let provider = Self.mainApp(http)

        guard case .failed(let message) = await Self.open(provider) else {
            Issue.record("a list that failed is shown as a failure, not as no files")
            return
        }
        #expect([EmlAttachmentPreview.filesFailedMessage, EmlAttachmentPreview.filesFailedOfflineMessage].contains(message))
        guard case .listed(let files) = await Self.open(provider) else {
            Issue.record("opening the attached email again lists its files")
            return
        }
        #expect(Set(files.map(\.filename)) == ["report.pdf", "notes.txt"])
    }

    @Test("Main app: an attached email whose file list continues on another page is shown as a failure, never in part")
    @MainActor
    func continuedListIsAFailure() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.attachedEmailServer(listContinues: true).install(on: http)

        guard case .failed = await Self.open(Self.mainApp(http)) else {
            Issue.record("a list that cannot be read in full is not shown")
            return
        }
    }

    @Test("Main app: opening a file of an attached email returns its bytes")
    func openingAFileOfAnAttachedEmailGetsItsBytes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.attachedEmailServer().install(on: http)
        let provider = Self.mainApp(http)

        let section = "\(Self.forwarded.id)\(ExchangeProvider.nestedSeparator)\(Self.notes.id)"
        let bytes = try await provider.fetchAttachment(messageId: Self.messageId, attachmentId: section)

        #expect(bytes == Self.notes.bytes)
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetchAttachment(
                messageId: Self.messageId,
                attachmentId: "\(Self.forwarded.id)\(ExchangeProvider.nestedSeparator)missing")
        }
    }

    @Test("Notification service: a next link off Graph is refused before any request")
    func foreignNextLinkIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [Self.report, Self.logo], pageSize: 1,
            nextLinkHost: "graph.example.com")
        server.install(on: http)

        await #expect(throws: (any Error).self) { _ = try await Self.read(.notificationService, from: http) }
        #expect(!http.recordedCalls().contains { URL(string: $0.url)?.host == "graph.example.com" },
                "the token never goes to a host that is not Graph")
    }

    @Test("Notification service: a list that never ends stops at the page cap and fails the read")
    func endlessListStopsAtTheCap() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let server = GraphAttachmentServer(
            messageId: Self.messageId, html: Self.showsBothImages,
            files: [Self.report], pageSize: 1, endless: true)
        server.install(on: http)

        await #expect(throws: (any Error).self) { _ = try await Self.read(.notificationService, from: http) }
        let listReads = http.recordedCalls().filter { URL(string: $0.url)?.path.hasSuffix("/attachments") == true }
        #expect(listReads.count == GraphAPI.maxAttachmentListPages)
    }
}

/// A page link (`@odata.nextLink`) is followed with the bearer token, so both
/// readers send it only where `GraphAPI.isGraphPageLink` allows: https on
/// graph.microsoft.com, the default port, no user info.
@Suite("Graph page links — the token is sent only to Graph over https")
struct GraphPageLinkTests {
    @Test("A page link is followed only on graph.microsoft.com over https, default port, no user info",
          arguments: [
              ("https://graph.microsoft.com/v1.0/me/messages/m1/attachments?$skiptoken=2", true),
              ("https://graph.microsoft.com:443/v1.0/me/messages/m1/attachments", true),
              ("https://GRAPH.Microsoft.com/v1.0/me/messages/m1/attachments", true),
              ("http://graph.microsoft.com/v1.0/me/messages/m1/attachments", false),
              ("https://u:p@graph.microsoft.com/v1.0/me/messages/m1/attachments", false),
              ("https://u@graph.microsoft.com/v1.0/me/messages/m1/attachments", false),
              ("https://graph.microsoft.com:8443/v1.0/me/messages/m1/attachments", false),
              ("/v1.0/me/messages/m1/attachments?$skiptoken=2", false),
              ("https://graph.example.com/v1.0/me/messages/m1/attachments", false),
              ("https://graph.microsoft.com.example.com/v1.0/me/messages/m1/attachments", false),
          ])
    func pageLink(url: String, followed: Bool) {
        #expect(GraphAPI.isGraphPageLink(url) == followed)
    }
}

/// A Graph-shaped server for one message and its file attachments, which counts
/// the attachment bytes it serves. Its shapes follow Microsoft Graph v1.0:
/// - the message GET with `$expand=attachments` embeds every attachment with its
///   `contentBytes` (message-get, "expand");
/// - the attachment list returns every file's `contentBytes` unless the request
///   carries a `$select` (outlook-large-attachments, Step 4); a `$select` naming
///   `contentId`, a property of the derived `fileAttachment` type, is refused
///   with 400; pages are joined by `@odata.nextLink`;
/// - an attachment GET returns that file with its `contentId` and bytes
///   (attachment-get);
/// - an attached email's GET with the plain
///   `$expand=microsoft.graph.itemattachment/item` returns the item with its
///   own attachments, each file with its bytes (no `attachments` key when it has
///   none); with `item($select=...)` casting each property to
///   `microsoft.graph.message/`, only those properties, no attachments and no
///   bytes, and a nested `;$expand=microsoft.graph.message/attachments(...)`
///   is accepted and dropped from the answer; an uncast message property in
///   that `$select`, or an uncast nested `$expand=attachments`, is a 400;
/// - anything below an attachment, such as the attached email's own list
///   `.../microsoft.graph.itemattachment/item/attachments` or one of its files by
///   id, plain or cast through `microsoft.graph.message`, is a 400.
/// All of these were measured on a test mailbox. Not measured, and modelled so a
/// reader cannot show part of a list: `attachedEmailListContinues` adds an
/// `attachments@odata.nextLink` to the expanded item.
final class GraphAttachmentServer: Sendable {
    struct File: Sendable {
        let id: String
        let name: String
        let contentType: String
        let isInline: Bool
        let contentId: String?
        let bytes: Data
        /// An attached email (`itemAttachment`): it has no bytes of its own,
        /// and its files are `attachedEmailFiles`.
        var isAttachedEmail = false
        /// How this file's own GET answers.
        var getAnswer: GetAnswer = .bytes

        enum GetAnswer: Sendable {
            /// The file with its `contentId` and bytes (attachment-get).
            case bytes
            /// An HTTP error status, no body.
            case status(Int)
            /// A 200 that carries the file's metadata and `contentId` but no
            /// `contentBytes`.
            case withoutBytes
        }
    }

    let messageId: String
    let html: String
    let files: [File]
    let pageSize: Int
    let listStatus: Int?
    let nextLinkHost: String?
    let endless: Bool
    /// The files of the attached email in `files`, if there is one.
    let attachedEmailFiles: [File]
    /// Whether the attached email has a `receivedDateTime`.
    let attachedEmailDated: Bool
    /// Whether its expanded file list says it continues.
    let attachedEmailListContinues: Bool
    /// Plain expansions of the attached email still to answer with 500.
    private let failingAttachedEmailOpens: Mutex<Int>
    /// File id -> times its bytes were served.
    private let served = Mutex<[String: Int]>([:])

    init(
        messageId: String, html: String, files: [File], pageSize: Int,
        listStatus: Int? = nil, nextLinkHost: String? = nil, endless: Bool = false,
        attachedEmailFiles: [File] = [], attachedEmailDated: Bool = true,
        failingAttachedEmailOpens: Int = 0, attachedEmailListContinues: Bool = false
    ) {
        self.messageId = messageId
        self.html = html
        self.files = files
        self.pageSize = pageSize
        self.listStatus = listStatus
        self.nextLinkHost = nextLinkHost
        self.endless = endless
        self.attachedEmailFiles = attachedEmailFiles
        self.attachedEmailDated = attachedEmailDated
        self.failingAttachedEmailOpens = Mutex(failingAttachedEmailOpens)
        self.attachedEmailListContinues = attachedEmailListContinues
    }

    func bytesServed() -> [String: Int] { served.withLock { $0 } }

    func install(on http: FakeHTTP.Scenario) {
        http.register(path: "/messages/\(messageId)?", method: "GET") { [self] request in
            message(request)
        }
        http.register(path: "/messages/\(messageId)/attachments", method: "GET") { [self] request in
            let components = request.url.pathComponents
            guard let index = components.firstIndex(of: "attachments") else { return .status(404) }
            switch components.count - index - 1 {
            case 0: return list(request, of: files)
            case 1: return attachment(request)
            // Below an attachment: an attached email's own list, or one of its
            // files by id, plain or cast. Graph v1.0 answers 400 "Resource not
            // found for the segment ...", with or without `$select` (measured).
            default: return .status(400)
            }
        }
    }

    /// A list entry: a file's bytes travel with it unless the list was selected.
    private func entry(_ file: File, selected: Bool) -> [String: Any] {
        selected || file.isAttachedEmail ? metadata(file) : serve(file)
    }

    private func serve(_ file: File) -> [String: Any] {
        served.withLock { $0[file.id, default: 0] += 1 }
        var entry = metadata(file)
        entry["contentId"] = file.contentId ?? NSNull()
        entry["contentBytes"] = file.bytes.base64EncodedString()
        return entry
    }

    private func metadata(_ file: File) -> [String: Any] {
        ["@odata.type": file.isAttachedEmail ? "#microsoft.graph.itemAttachment" : "#microsoft.graph.fileAttachment",
         "id": file.id, "name": file.name,
         "contentType": file.contentType, "size": file.bytes.count, "isInline": file.isInline]
    }

    private func message(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        var json: [String: Any] = [
            "id": messageId, "subject": "Plan", "conversationId": "conv-1",
            "from": ["emailAddress": ["name": "Sender", "address": "sender@example.com"]],
            "toRecipients": [["emailAddress": ["address": "owner@example.com"]]],
            "receivedDateTime": ISO8601DateFormatter().string(from: Date()),
            "isRead": false, "hasAttachments": true, "parentFolderId": "inbox-id",
            "body": ["contentType": "html", "content": html],
        ]
        if Self.query(request, "$expand")?.contains("attachments") == true {
            json["attachments"] = files.map { entry($0, selected: false) }
        }
        return Self.json(json)
    }

    private func list(_ request: FakeHTTP.Request, of files: [File]) -> FakeHTTP.CannedResponse {
        if let listStatus { return .status(listStatus) }
        let select = Self.query(request, "$select")
        if let select, select.split(separator: ",").contains("contentId") { return .status(400) }
        let skip = Int(Self.query(request, "$skiptoken") ?? "0") ?? 0
        let page = endless ? Array(files.prefix(pageSize)) : Array(files.dropFirst(skip).prefix(pageSize))
        var json: [String: Any] = ["value": page.map { entry($0, selected: select != nil) }]
        if endless || skip + pageSize < files.count {
            var next = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            if let nextLinkHost { next.host = nextLinkHost }
            next.queryItems = (next.queryItems ?? []).filter { $0.name != "$skiptoken" }
                + [URLQueryItem(name: "$skiptoken", value: String(skip + pageSize))]
            json["@odata.nextLink"] = next.url!.absoluteString
        }
        return Self.json(json)
    }

    private func attachment(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        guard let file = files.first(where: { $0.id == request.url.lastPathComponent }) else { return .status(404) }
        guard file.isAttachedEmail else {
            switch file.getAnswer {
            case .bytes:
                return Self.json(serve(file))
            case .status(let code):
                return .status(code)
            case .withoutBytes:
                var json = metadata(file)
                json["contentId"] = file.contentId ?? NSNull()
                return Self.json(json)
            }
        }
        var json = metadata(file)
        let expand = Self.query(request, "$expand") ?? ""
        if expand == Self.plainExpand {
            // The attached email with its own attachments, every file with its
            // `contentBytes`; no `attachments` key when it has none (measured).
            let failed = failingAttachedEmailOpens.withLock { remaining in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if failed { return .status(500) }
            var item = attachedEmailItem()
            if !attachedEmailFiles.isEmpty {
                item["attachments"] = attachedEmailFiles.map { serve($0) }
                if attachedEmailListContinues {
                    item["attachments@odata.nextLink"] =
                        "https://graph.microsoft.com/v1.0/me/messages/\(messageId)/attachments/\(file.id)?$skiptoken=1"
                }
            }
            json["item"] = item
            return Self.json(json)
        }
        guard expand.hasPrefix(Self.plainExpand + "("), expand.hasSuffix(")") else {
            return .status(Self.notModelled)
        }
        var selected: [String]?
        let options = Self.splitOutsideParentheses(
            String(expand.dropFirst(Self.plainExpand.count + 1).dropLast()), on: ";")
        for option in options {
            if option.hasPrefix("$select=") {
                var names: [String] = []
                for property in option.dropFirst("$select=".count).split(separator: ",").map(String.init) {
                    if property.hasPrefix(Self.messageCast) {
                        names.append(String(property.dropFirst(Self.messageCast.count)))
                    } else if Self.outlookItemProperties.contains(property) {
                        names.append(property)
                    } else {
                        // "Could not find a property named 'subject' on type
                        // 'microsoft.graph.outlookItem'" (measured).
                        return .status(400)
                    }
                }
                selected = names
            } else if option.hasPrefix("$expand=attachments") {
                // An uncast nested expansion of the item's attachments (measured).
                return .status(400)
            } else if !option.hasPrefix("$expand=" + Self.messageCast + "attachments") {
                return .status(Self.notModelled)
            }
            // A cast nested expansion of the item's attachments is accepted and
            // dropped from the answer (measured).
        }
        guard let selected else { return .status(Self.notModelled) }
        let full = attachedEmailItem()
        var item: [String: Any] = ["@odata.type": "#microsoft.graph.message", "id": "\(file.id)-item"]
        for name in selected {
            if let value = full[name] { item[name] = value }
        }
        json["item"] = item
        return Self.json(json)
    }

    /// The attached email's own properties, without its attachments.
    private func attachedEmailItem() -> [String: Any] {
        var item: [String: Any] = [
            "@odata.type": "#microsoft.graph.message", "subject": "Plan",
            "from": ["emailAddress": ["name": "Sender", "address": "sender@example.com"]],
            "toRecipients": [["emailAddress": ["address": "owner@example.com"]]],
            "body": ["contentType": "html", "content": Self.attachedEmailBody],
            "hasAttachments": !attachedEmailFiles.isEmpty,
        ]
        if attachedEmailDated {
            item["receivedDateTime"] = ISO8601DateFormatter().string(from: Date())
        }
        return item
    }

    private static let plainExpand = "microsoft.graph.itemattachment/item"
    private static let messageCast = "microsoft.graph.message/"

    /// The status for a request shape this fake does not model, so a reader
    /// that starts sending one fails loudly instead of meeting a guess.
    static let notModelled = 501

    /// The properties of Graph's `outlookItem`, the declared type of an item
    /// attachment's `item`; a `$select` inside the expansion may name only
    /// these without a type cast.
    static let outlookItemProperties: Set<String> = [
        "id", "categories", "changeKey", "createdDateTime", "lastModifiedDateTime",
    ]

    /// `text` split on `separator` where it is not inside parentheses.
    private static func splitOutsideParentheses(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// The body of the attached email in `files`.
    static let attachedEmailBody = "<p>The attached plan</p>"

    private static func query(_ request: FakeHTTP.Request, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private static func json(_ object: [String: Any]) -> FakeHTTP.CannedResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .json(raw: String(decoding: data, as: UTF8.self))
    }
}
