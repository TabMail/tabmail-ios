/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// `BodyAssetStore` core round-trip + dedup + URL-helper tests.
///
/// All tests run against an in-memory manifest queue + a per-test temporary
/// container directory injected via `BodyAssetStore._setTestEnvironment(...)`.
/// No App Group entitlement required.
@Suite("BodyAssetStore", .serialized, .processGlobalState)
struct BodyAssetStoreTests {

    private static func setupTest() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try BodyAssetStore._makeTestQueue()
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        return dir
    }

    private static func teardown(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Hash determinism

    @Test("headerHash is deterministic across calls")
    func headerHashDeterministic() {
        let h1 = BodyAssetStore.headerHash(ContentKey(rawValue: "acc1:INBOX:42"))
        let h2 = BodyAssetStore.headerHash(ContentKey(rawValue: "acc1:INBOX:42"))
        #expect(h1 == h2)
        #expect(h1.count == 16)
        #expect(h1.allSatisfy { $0.isHexDigit })
    }

    @Test("headerHash differs across distinct inputs")
    func headerHashDistinct() {
        let h1 = BodyAssetStore.headerHash(ContentKey(rawValue: "acc1:INBOX:42"))
        let h2 = BodyAssetStore.headerHash(ContentKey(rawValue: "acc1:INBOX:43"))
        #expect(h1 != h2)
    }

    @Test("headerHash handles pathological characters")
    func headerHashPathological() {
        // Colons, slashes, angle brackets, Unicode — all the things that
        // historically broke filesystem paths in IMAP messageId space.
        let inputs = [
            "acc1:INBOX:<msg.id@example.com>",
            "acc1:Path/With/Slashes:42",
            "acc1:🔥:42",
            String(repeating: "a", count: 10_000),
        ]
        for input in inputs {
            let h = BodyAssetStore.headerHash(ContentKey(rawValue: input))
            #expect(h.count == 16)
            #expect(h.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: - URL helpers

    @Test("absoluteURL/assetId round-trip")
    func urlRoundTrip() {
        let id = "abcd1234abcd1234/1234abcd1234abcd"
        let urlStr = BodyAssetStore.absoluteURL(forAssetId: id)
        #expect(urlStr == "tabmail-asset://abcd1234abcd1234/1234abcd1234abcd")
        guard let url = URL(string: urlStr) else { Issue.record("URL parse failed"); return }
        let parsed = BodyAssetStore.assetId(fromURL: url)
        #expect(parsed == id)
    }

    @Test("assetId(fromURL:) rejects wrong scheme")
    func assetIdRejectsWrongScheme() {
        let url = URL(string: "https://abcd1234abcd1234/1234abcd1234abcd")!
        #expect(BodyAssetStore.assetId(fromURL: url) == nil)
    }

    @Test("assetId(fromURL:) rejects malformed paths")
    func assetIdRejectsMalformed() {
        // Missing path
        #expect(BodyAssetStore.assetId(fromURL: URL(string: "tabmail-asset://aabb")!) == nil)
        // Wrong-length host
        let u = URL(string: "tabmail-asset://shortname/abcd1234abcd1234")
        if let u { #expect(BodyAssetStore.assetId(fromURL: u) == nil) }
    }

    // MARK: - Write/read round-trip

    @Test("writeInlineImage round-trip — read returns same bytes")
    func writeReadInlineImage() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }
        let bytes = Data("hello, world".utf8)
        guard let id = BodyAssetStore.writeInlineImage( contentKey: ContentKey(rawValue: "acc1:INBOX:42"),
            contentId: "img1@test",
            contentType: "image/png",
            data: bytes
        ) else { Issue.record("write failed"); return }
        #expect(BodyAssetStore.read(assetId: id) == bytes)
        #expect(BodyAssetStore.contentType(assetId: id) == "image/png")
    }

    @Test("writeAttachment round-trip — assetId lookup works")
    func writeReadAttachment() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }
        let bytes = Data(repeating: 0xAB, count: 1_000)
        guard let id = BodyAssetStore.writeAttachment( contentKey: ContentKey(rawValue: "acc1:INBOX:42"),
            section: "1.2",
            contentType: "application/pdf",
            data: bytes
        ) else { Issue.record("write failed"); return }
        let lookedUpId = BodyAssetStore.attachmentAssetId( contentKey: ContentKey(rawValue: "acc1:INBOX:42"), section: "1.2")
        #expect(lookedUpId == id)
        #expect(BodyAssetStore.read(assetId: id) == bytes)
        #expect(BodyAssetStore.contentType(assetId: id) == "application/pdf")
        #expect(BodyAssetStore.urlOnDisk(assetId: id) != nil)
    }

    @Test("dedup: writing same (headerId, contentId) twice returns same id, single file")
    func writeDedup() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }
        let v1 = Data("first".utf8)
        let v2 = Data("second-different-content".utf8)
        let id1 = BodyAssetStore.writeInlineImage( contentKey: ContentKey(rawValue: "acc1:INBOX:42"), contentId: "cid", contentType: "image/png", data: v1
        )
        let id2 = BodyAssetStore.writeInlineImage( contentKey: ContentKey(rawValue: "acc1:INBOX:42"), contentId: "cid", contentType: "image/png", data: v2
        )
        #expect(id1 == id2)
        // Latest write wins.
        #expect(BodyAssetStore.read(assetId: id2!) == v2)
    }

    // MARK: - Cross-target identity

    /// The MessageIdentity-derived headerId is the basis for every cross-target
    /// path. `BodyAssetStore.makeInlineImageWriter( forContentKey: ContentKey(rawValue: ))` is the SINGLE
    /// factory both NSE and main-app callers use; given the same headerId, they
    /// produce identical output URLs by construction.
    @Test("makeInlineImageWriter produces identical URLs across targets for same headerId")
    func writerCrossTargetIdentity() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let accountId = "acc1"
        let folderPath = "INBOX"
        let messageId = "msg-42"
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: messageId
        )

        // Writer used by main-app BodyFetchProcessor.renderBody.
        let mainAppWriter = BodyAssetStore.makeInlineImageWriter( forContentKey: ContentKey(rawValue: headerId))
        // Writer used by NSE (IMAPFetchMapping.renderBody / GmailAPI.messageFull /
        // GraphAPI.messageFull, all via the same factory).
        let nseWriter = BodyAssetStore.makeInlineImageWriter( forContentKey: ContentKey(rawValue: headerId))

        let img = InlineImageRef(
            contentId: "image001@test",
            contentType: "image/png",
            data: Data("png-bytes".utf8)
        )
        let urlA = mainAppWriter(img)
        let urlB = nseWriter(img)
        #expect(urlA != nil)
        #expect(urlA == urlB)
    }
}
