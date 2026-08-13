/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import WebKit
@testable import TabMail

// =====================================================================================
// P1d — asset ownership binding, pinned at the INVARIANT level.
//
// THE INVARIANT: *an asset is served only to the document that owns it.*
//
// Not "the handler holds a ContentKey", not "authorize() returns .notOwned" — the
// property is that bytes reach exactly one document. Every test below is written against
// an outcome (served / not served, and what the WIRE saw), so a re-implementation that
// keeps the property passes and one that loses it fails.
//
// The MOVED-MESSAGE case is this phase's gate and is the first test in the file.
// =====================================================================================

@Suite("P1d asset ownership — an asset is served only to the document that owns it",
       .serialized, .processGlobalState)
struct BodyAssetOwnershipTests {

    // Generic placeholders only — never a real address, sender or domain.
    private static let sourceKey = ContentKey(rawValue: "acct-1:INBOX:4001")
    private static let destinationKey = ContentKey(rawValue: "acct-1:Archive:9001")
    private static let strangerKey = ContentKey(rawValue: "acct-1:INBOX:4002")

    private static func setupTest() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetOwnership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try BodyAssetStore._makeTestQueue()
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        return dir
    }

    private static func teardown(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The decision the render path would reach for `assetId` under `ownerKey` —
    /// i.e. exactly what `BodyAssetSchemeHandler` computes before it touches the disk.
    private static func decision(assetId: String, ownerKey: ContentKey) -> BodyAssetServePolicy.Authorization {
        BodyAssetServePolicy.authorize(
            row: BodyAssetStore.assetManifestRow(assetId: assetId),
            ownerKey: ownerKey
        )
    }

    // MARK: - THE GATE: the moved message

    @Test("THE GATE — a moved message's cached inline images are still served, under the DESTINATION key")
    func movedMessageAssetsStayServableUnderTheDestinationKey() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let bytes = Data("moved-message-inline-image".utf8)
        guard let assetId = BodyAssetStore.writeInlineImage(
            contentKey: Self.sourceKey,
            contentId: "inline-1@example.com",
            contentType: "image/png",
            data: bytes
        ) else { Issue.record("write failed"); return }

        // The URL baked into the persisted HTML. It is minted ONCE, before the move, and
        // the move does not rewrite it — `rekeyContentKey` re-points the manifest row and
        // leaves the bytes and the row id alone, so the cached HTML keeps the OLD hash.
        let bakedURLString = BodyAssetStore.absoluteURL(forAssetId: assetId)
        guard let bakedURL = URL(string: bakedURLString) else { Issue.record("URL parse failed"); return }

        // Before the move: served to the source document.
        #expect(BodyAssetServePolicy.canonicalAssetId(from: bakedURL) == assetId)
        #expect(Self.decision(assetId: assetId, ownerKey: Self.sourceKey) == .serve(contentType: "image/png"),
                "non-vacuity: the asset IS servable to its owner before the move")

        // The move. `MessageHeaderRekey.finishMove` re-keys the row to the destination
        // address; `publishRekeys` mirrors that into the asset manifest.
        let rekeyed = BodyAssetStore.rekeyContentKey(from: Self.sourceKey, to: Self.destinationKey)
        #expect(rekeyed == 1, "the move must re-point exactly the one manifest row")

        // THE PROPERTY: the UNCHANGED baked URL is authorized once the view reopens under
        // the DESTINATION ContentKey. This is why the ownership predicate reads the
        // `headerId` COLUMN and never a hash recomputed from the URL — a computed
        // `headerHash(destinationKey)` would not match the URL's old host, and every
        // moved message's images would break.
        #expect(BodyAssetServePolicy.canonicalAssetId(from: bakedURL) == assetId,
                "the baked URL is unchanged by the move — it still carries the SOURCE header hash")
        #expect(Self.decision(assetId: assetId, ownerKey: Self.destinationKey) == .serve(contentType: "image/png"),
                "THE GATE: after the move the same URL is authorized by the RE-KEYED row")
        #expect(BodyAssetStore.read(assetId: assetId) == bytes,
                "the bytes on disk are untouched by the re-key")

        // And the other direction, which is the security half: a view still bound to the
        // SOURCE key fails closed — broken images until it is recreated, which is exactly
        // what the body-ContentKey view identity resolves.
        #expect(Self.decision(assetId: assetId, ownerKey: Self.sourceKey) == .refuse(.notOwned),
                "a view still bound to the source key fails closed after the move")
    }

    // MARK: - Cross-document refusal

    @Test("A document requesting ANOTHER document's asset id is refused")
    func crossDocumentAssetRequestIsRefused() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let mine = Data("owned-by-message-one".utf8)
        guard let myAsset = BodyAssetStore.writeInlineImage(
            contentKey: Self.sourceKey,
            contentId: "mine@example.com",
            contentType: "image/jpeg",
            data: mine
        ) else { Issue.record("write failed"); return }

        // Asset ids are NOT secrets — a message can simply name one. The refusal has to
        // come from ownership, not from obscurity.
        #expect(Self.decision(assetId: myAsset, ownerKey: Self.sourceKey) == .serve(contentType: "image/jpeg"),
                "non-vacuity: the owner is served")
        #expect(Self.decision(assetId: myAsset, ownerKey: Self.strangerKey) == .refuse(.notOwned),
                "another message naming this asset id gets nothing")
    }

    @Test("Message HTML cannot read its OWN message's file attachments through the image scheme")
    func attachmentsAreNotServableAsInlineImages() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        guard let attachmentAsset = BodyAssetStore.writeAttachment(
            contentKey: Self.sourceKey,
            section: "2",
            contentType: "image/png",
            data: Data("attachment-bytes".utf8),
            identityStamp: "rfc:kind-probe@example.com"
        ) else { Issue.record("write failed"); return }

        // Same owner, allowlisted content type — only the KIND differs, so this pins the
        // kind gate on its own rather than riding on ownership or MIME.
        #expect(Self.decision(assetId: attachmentAsset, ownerKey: Self.sourceKey) == .refuse(.wrongKind))
    }

    @Test("An unknown asset id is refused")
    func unknownAssetIdIsRefused() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }
        let ghost = String(repeating: "a", count: BodyAssetStore.hashHexLength)
            + "/" + String(repeating: "b", count: BodyAssetStore.hashHexLength)
        #expect(Self.decision(assetId: ghost, ownerKey: Self.sourceKey) == .refuse(.noManifestRow))
    }

    // MARK: - MIME allowlist

    @Test("A non-image asset is refused however plausible its stored type looks")
    func disallowedMIMETypeIsRefused() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        // `IMAPFetchMapping.extractInlineImages` passes `part.contentType` through
        // unfiltered, so a `cid:`-referenced part really can carry any of these.
        let cases = [
            "text/html", "application/javascript", "text/plain", "application/pdf", "",
            "image",                    // no subtype at all
            "image/",                   // empty subtype
            "imagex/png",               // top-level near-miss
            "image/png, text/html",     // a second type smuggled into one header value
            "image/p ng",               // space is not a restricted-name char
            "text/html; charset=utf-8", // parameters do not launder the type
        ]
        for (i, type) in cases.enumerated() {
            guard let id = BodyAssetStore.writeInlineImage(
                contentKey: Self.sourceKey,
                contentId: "mime-\(i)@example.com",
                contentType: type,
                data: Data("bytes".utf8)
            ) else { Issue.record("write failed for \(type)"); continue }
            #expect(Self.decision(assetId: id, ownerKey: Self.sourceKey) == .refuse(.disallowedMIME),
                    "\(type) must not be servable")
        }
    }

    @Test("The allowlist normalizes exactly: trim, split at ';', ASCII-lowercase")
    func mimeNormalization() {
        #expect(BodyAssetServePolicy.normalizedMIMEType("IMAGE/PNG") == "image/png")
        #expect(BodyAssetServePolicy.normalizedMIMEType("  image/png  ") == "image/png")
        #expect(BodyAssetServePolicy.normalizedMIMEType("image/png; name=logo.png") == "image/png")
        #expect(BodyAssetServePolicy.normalizedMIMEType("Image/Jpeg ;charset=utf-8") == "image/jpeg")
        // ASCII-only folding: U+212A KELVIN SIGN folds to "k" under Unicode case folding,
        // so a Unicode-aware lowercase would widen the allowlist past what is written down.
        #expect(BodyAssetServePolicy.normalizedMIMEType("image/\u{212A}") != "image/k")
    }

    @Test("The allowlist admits any well-formed image subtype and nothing else")
    func allowlistIsTheImageTopLevelType() {
        // Non-vacuity, and the reason the gate is stated at the TOP-LEVEL type: every one
        // of these is a real spelling some mailer emits, and an enumerated subtype list
        // would silently break whichever ones it forgot.
        for good in ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic",
                     "image/svg+xml", "image/x-icon", "image/pjpeg", "image/x-png",
                     "image/vnd.microsoft.icon", "image/avif", "image/jp2"] {
            #expect(BodyAssetServePolicy.isAllowedMIMEType(good), "\(good) must stay servable")
        }
        // SVG is the only image subtype carrying markup, and it is admitted on purpose —
        // in `<img>` it is a non-scripted image document, and excluding it would break a
        // sender's inline logo, which is a behaviour change rather than a security fix.
        #expect(BodyAssetServePolicy.isAllowedMIMEType("image/svg+xml"))

        for bad in ["text/html", "application/javascript", "text/xml", "application/pdf",
                    "", "image", "image/", "imagex/png", "image/png, text/html",
                    "image/p ng", "image/png\r\nx: y", "/png",
                    "image/" + String(repeating: "a", count: BodyAssetServePolicy.maxSubtypeLength + 1)] {
            #expect(!BodyAssetServePolicy.isAllowedMIMEType(bad), "\(bad) must be refused")
        }
    }

    @Test("A stored content type cannot forge a log line")
    func storedTypeCannotForgeALogLine() {
        let forged = "image/png\nX-Content-Type-Options: sniff\r[AssetServe] allowed"
        let logged = BodyAssetServePolicy.loggableMIMEType(forged)
        #expect(!logged.contains("\n"))
        #expect(!logged.contains("\r"))
        #expect(!logged.contains("["))
        #expect(logged.hasPrefix("image/png"))
        #expect(BodyAssetServePolicy.loggableMIMEType("") == "(empty)")
    }

    // MARK: - Canonical URL shape

    @Test("Only the exact minted URL shape resolves to an asset id")
    func canonicalURLShape() {
        let host = String(repeating: "a", count: BodyAssetStore.hashHexLength)
        let asset = String(repeating: "b", count: BodyAssetStore.hashHexLength)
        let scheme = BodyAssetConfig.urlScheme

        guard let good = URL(string: "\(scheme)://\(host)/\(asset)") else {
            Issue.record("URL parse failed"); return
        }
        #expect(BodyAssetServePolicy.canonicalAssetId(from: good) == "\(host)/\(asset)",
                "non-vacuity: the shape `absoluteURL(forAssetId:)` mints is accepted")

        let rejected: [String] = [
            "https://\(host)/\(asset)",                       // wrong scheme
            "\(scheme)://\(host)/\(asset)?x=1",               // query
            "\(scheme)://\(host)/\(asset)#frag",              // fragment
            "\(scheme)://user@\(host)/\(asset)",              // userinfo
            "\(scheme)://\(host)/\(asset)/extra",             // extra path segment
            "\(scheme)://\(host)/\(asset)/",                  // trailing slash = 2 segments
            "\(scheme)://\(host)/\(String(asset.dropLast()))", // short segment
            "\(scheme)://\(host)/\(asset.uppercased())",      // uppercase hex
            "\(scheme)://\(host)/\(String(repeating: "z", count: BodyAssetStore.hashHexLength))", // non-hex
            "\(scheme)://\(host)/\(host)%2F\(asset)",         // encoded separator
        ]
        for raw in rejected {
            guard let u = URL(string: raw) else { continue }
            #expect(BodyAssetServePolicy.canonicalAssetId(from: u) == nil, "must reject \(raw)")
        }

        // The per-load synthetic DOCUMENT url must never parse as an asset either.
        let doc = RenderDocumentURL.url(nonce: RenderDocumentURL.nonce())
        #expect(BodyAssetServePolicy.canonicalAssetId(from: doc) == nil)
    }
}

// =====================================================================================
// The WIRE boundary. Every refusal reason must be indistinguishable to the document.
// =====================================================================================

/// Records exactly what a `WKURLSchemeTask` was told, so a test can compare two refusals
/// byte for byte instead of trusting that they "both fail".
/// Deliberately NOT `@MainActor`: `WKURLSchemeTask`'s callbacks are nonisolated in the
/// SDK, so an isolated conformance does not compile. A lock covers the mutable state
/// (Resilience rule 5's `@unchecked Sendable`-on-a-guarded-value shape).
private final class RecordingURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var _responses: [URLResponse] = []
    private var _data: [Data] = []
    private var _finished = false
    private var _errors: [NSError] = []

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) { lock.lock(); _responses.append(response); lock.unlock() }
    func didReceive(_ data: Data) { lock.lock(); _data.append(data); lock.unlock() }
    func didFinish() { lock.lock(); _finished = true; lock.unlock() }
    func didFailWithError(_ error: any Error) { lock.lock(); _errors.append(error as NSError); lock.unlock() }

    var responses: [URLResponse] { lock.lock(); defer { lock.unlock() }; return _responses }
    var data: [Data] { lock.lock(); defer { lock.unlock() }; return _data }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var errors: [NSError] { lock.lock(); defer { lock.unlock() }; return _errors }

    /// Everything the document can observe, as one comparable value.
    var observableOutcome: String {
        let statuses = responses.map { ($0 as? HTTPURLResponse)?.statusCode ?? -1 }
        let errs = errors.map { "\($0.domain)/\($0.code)" }
        return "responses=\(statuses) bytes=\(data.map(\.count)) finished=\(finished) errors=\(errs)"
    }
}

@MainActor
@Suite("P1d asset scheme handler — the wire response is uniform for every refusal",
       .serialized, .processGlobalState)
struct BodyAssetSchemeHandlerWireTests {

    private static let ownerKey = ContentKey(rawValue: "acct-1:INBOX:7001")
    private static let strangerKey = ContentKey(rawValue: "acct-1:INBOX:7002")

    private static func setupTest() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetWire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try BodyAssetStore._makeTestQueue()
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        return dir
    }

    private static func teardown(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(urlString: String, ownerKey: ContentKey, log: inout [String]) -> RecordingURLSchemeTask? {
        guard let url = URL(string: urlString) else { Issue.record("URL parse failed: \(urlString)"); return nil }
        let captured = LogBox()
        let handler = BodyAssetSchemeHandler(ownerKey: ownerKey) { line in captured.append(line) }
        let task = RecordingURLSchemeTask(url: url)
        handler.webView(WKWebView(), start: task)
        log = captured.lines
        return task
    }

    /// Tiny `Sendable` sink so the handler's `@Sendable` log closure can capture it.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("Unowned, wrong-kind, disallowed-MIME, missing-file and malformed are ONE wire outcome")
    func everyRefusalLooksIdenticalOnTheWire() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        // 1. An asset owned by a DIFFERENT message.
        guard let strangerAsset = BodyAssetStore.writeInlineImage(
            contentKey: Self.strangerKey, contentId: "a@example.com",
            contentType: "image/png", data: Data("x".utf8)
        ) else { Issue.record("write failed"); return }

        // 2. An attachment of the SAME message (wrong kind).
        guard let attachment = BodyAssetStore.writeAttachment(
            contentKey: Self.ownerKey, section: "2", contentType: "image/png",
            data: Data("x".utf8), identityStamp: "rfc:wire@example.com"
        ) else { Issue.record("write failed"); return }

        // 3. An inline image of the SAME message with a disallowed type.
        guard let badMIME = BodyAssetStore.writeInlineImage(
            contentKey: Self.ownerKey, contentId: "b@example.com",
            contentType: "text/html", data: Data("x".utf8)
        ) else { Issue.record("write failed"); return }

        // 4. An inline image of the SAME message whose bytes were deleted underneath us.
        guard let vanished = BodyAssetStore.writeInlineImage(
            contentKey: Self.ownerKey, contentId: "c@example.com",
            contentType: "image/png", data: Data("x".utf8)
        ) else { Issue.record("write failed"); return }
        guard let vanishedURL = BodyAssetStore.urlOnDisk(assetId: vanished) else {
            Issue.record("no on-disk URL"); return
        }
        try FileManager.default.removeItem(at: vanishedURL)

        // 5. A URL that is not even the canonical shape.
        let malformed = "\(BodyAssetConfig.urlScheme)://not-hex/also-not-hex"

        let probes: [(String, String)] = [
            ("not-owned", BodyAssetStore.absoluteURL(forAssetId: strangerAsset)),
            ("wrong-kind", BodyAssetStore.absoluteURL(forAssetId: attachment)),
            ("disallowed-mime", BodyAssetStore.absoluteURL(forAssetId: badMIME)),
            ("missing-file", BodyAssetStore.absoluteURL(forAssetId: vanished)),
            ("malformed-url", malformed),
        ]

        var outcomes: [String: String] = [:]
        var reasons: Set<String> = []
        for (label, urlString) in probes {
            var log: [String] = []
            guard let task = run(urlString: urlString, ownerKey: Self.ownerKey, log: &log) else { return }
            outcomes[label] = task.observableOutcome
            #expect(task.responses.isEmpty, "\(label): no response may be delivered")
            #expect(task.data.isEmpty, "\(label): no bytes may be delivered")
            #expect(!task.finished, "\(label): an empty 200 would look like a completed transaction and hide the failure")
            #expect(task.errors.count == 1, "\(label): exactly one failure")
            guard task.errors.count == 1 else { return }
            #expect(task.errors[0].domain == URLError.errorDomain)
            #expect(task.errors[0].code == URLError.resourceUnavailable.rawValue)
            // The distinction exists in the LOG and ONLY in the log — that is what makes
            // these diagnostics load-bearing rather than decorative.
            let refusalLines = log.filter { $0.contains("refused reason=") }
            #expect(refusalLines.count == 1, "\(label): the log must say exactly once why")
            guard let line = refusalLines.first else { return }
            reasons.insert(line)
        }

        let distinctWireOutcomes = Set(outcomes.values)
        #expect(distinctWireOutcomes.count == 1,
                "all five refusals must be ONE wire outcome, got \(distinctWireOutcomes)")
        #expect(reasons.count == 5,
                "…while the log distinguishes all five, or a failed smoke test is undiagnosable")
    }

    @Test("The owner IS served, with nosniff and the normalized type")
    func theOwnerIsServed() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let bytes = Data("png-bytes".utf8)
        // A parameterised type, as a real MIME header carries it. The response must echo
        // the NORMALIZED token, not the stored, attacker-influenced string.
        guard let id = BodyAssetStore.writeInlineImage(
            contentKey: Self.ownerKey, contentId: "d@example.com",
            contentType: "IMAGE/PNG; name=logo.png", data: bytes
        ) else { Issue.record("write failed"); return }

        var log: [String] = []
        guard let task = run(urlString: BodyAssetStore.absoluteURL(forAssetId: id),
                             ownerKey: Self.ownerKey, log: &log) else { return }

        #expect(task.errors.isEmpty)
        #expect(task.finished)
        #expect(task.data == [bytes])
        #expect(task.responses.count == 1)
        guard task.responses.count == 1 else { return }
        guard let http = task.responses[0] as? HTTPURLResponse else {
            Issue.record("not an HTTPURLResponse"); return
        }
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(http.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(bytes.count)")
        #expect(log.contains { $0.contains("allowed type=image/png") })
    }

    @Test("The log never carries a whole asset id or a whole owner key")
    func logsAreTruncated() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }
        let longKey = ContentKey(rawValue: "acct-1:A/Very/Deeply/Nested/Folder/Path:12345")
        guard let id = BodyAssetStore.writeInlineImage(
            contentKey: longKey, contentId: "e@example.com",
            contentType: "image/png", data: Data("x".utf8)
        ) else { Issue.record("write failed"); return }

        var log: [String] = []
        _ = run(urlString: BodyAssetStore.absoluteURL(forAssetId: id), ownerKey: longKey, log: &log)
        #expect(!log.isEmpty)
        for line in log {
            #expect(!line.contains(longKey.rawValue), "the full owner key must never be logged")
            #expect(!line.contains(id), "the full asset id must never be logged")
        }
    }
}
