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
        let stamp = "rfc:round-trip@example.com"
        guard let id = BodyAssetStore.writeAttachment( contentKey: ContentKey(rawValue: "acc1:INBOX:42"),
            section: "1.2",
            contentType: "application/pdf",
            data: bytes,
            identityStamp: stamp
        ) else { Issue.record("write failed"); return }
        let lookedUpId = BodyAssetStore.attachmentAssetId( contentKey: ContentKey(rawValue: "acc1:INBOX:42"), section: "1.2", identityStamp: stamp)
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

    // MARK: - ADR-IOS-066 / T5.1 — attachment cache identity
    //
    // THE INVARIANT, pinned here in every test below: **a cached attachment is
    // served only for the message it was fetched for.** Not "a token is present",
    // not "a stamp column holds value X" — the system property, so a different
    // future mechanism that still upholds it keeps these green and any mechanism
    // that serves a stranger's bytes goes red.
    //
    // Every test is TWO-SIDED. A store that simply never serves anything would
    // satisfy "the wrong message is refused" vacuously, so each run must also
    // observe the LEGITIMATE hit succeed.

    /// Builds a header the way sync does, then overrides the two identity-bearing
    /// columns. `date` is derived from `Date()` — never a literal.
    private static func makeHeader(
        accountId: String, folderPath: String, messageId: String,
        rfc822MessageId: String?, observedUidValidity: Int?
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subject",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId
        header.observedUidValidity = observedUidValidity
        return header
    }

    /// THE C3 CASE FOR THE ATTACHMENT CACHE. A `UIDVALIDITY` change reassigns UID
    /// 42 to a different physical message, and the reset reaction's asset purge is
    /// explicitly best-effort (`AccountManagerUidValidityReset` step 4) — so the old
    /// row is reachable at the new occupant's own content key. Serving it hands the
    /// user a stranger's attachment under their own message's name.
    @Test("A cached attachment is never served to a different message that reused its address")
    func attachmentIsRefusedForAReplacementOccupantOfTheSameAddress() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        // ONE address. Two messages, in sequence, on either side of a reset.
        let sharedKey = ContentKey(rawValue: "acc1:INBOX:42")
        let original = Self.makeHeader(
            accountId: "acc1", folderPath: "INBOX", messageId: "42",
            rfc822MessageId: "original@example.com", observedUidValidity: 111)
        let replacement = Self.makeHeader(
            accountId: "acc1", folderPath: "INBOX", messageId: "42",
            rfc822MessageId: "replacement@example.com", observedUidValidity: 222)
        #expect(original.id == replacement.id,
                "precondition: both messages address the SAME content key — that is the hazard")

        guard let originalStamp = AttachmentCacheIdentity.stamp(for: original),
              let replacementStamp = AttachmentCacheIdentity.stamp(for: replacement)
        else { Issue.record("both messages have provable identities"); return }

        let bytes = Data("the original message's confidential attachment".utf8)
        guard let assetId = BodyAssetStore.writeAttachment(
            contentKey: sharedKey, section: "2", contentType: "application/pdf",
            data: bytes, identityStamp: originalStamp
        ) else { Issue.record("write failed"); return }

        // THE REFUSAL: the replacement occupant asks at the very same address.
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: sharedKey, section: "2", identityStamp: replacementStamp) == nil,
            "a different message at the same address must get a cache MISS, not these bytes")

        // THE NON-VACUITY CONTROL, in the same run: the message these bytes actually
        // belong to is still served. Without this, a store that answered nil to
        // everything would pass.
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: sharedKey, section: "2", identityStamp: originalStamp) == assetId,
            "the message these bytes were fetched for must still get its cache hit")

        // AND THE REFUSAL DESTROYED NOTHING. A refused read means RE-FETCH, never
        // invalidate: the row and the bytes must both survive it.
        #expect(BodyAssetStore.read(assetId: assetId) == bytes)
    }

    /// Rows written before the identity binding existed carry no stamp. Absence of
    /// evidence is not evidence of mismatch — so they are strict cache MISSES that
    /// re-fetch, and nothing deletes them for being unstamped.
    @Test("A stampless legacy attachment row is a strict cache miss and is never destroyed by the refusal")
    func stamplessLegacyAttachmentRowIsAStrictMiss() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        // A pre-binding row, produced through the real publish path with no stamp.
        let legacyKey = ContentKey(rawValue: "acc1:INBOX:7")
        let legacyBytes = Data("legacy-cached-bytes".utf8)
        guard let legacyPrepared = BodyAssetStore.prepare(
            contentKey: legacyKey, kind: .attachment, key: "2",
            contentType: "application/pdf", data: legacyBytes, identityStamp: nil
        ) else { Issue.record("prepare failed"); return }
        guard let legacyId = BodyAssetStore.publish(legacyPrepared) else {
            Issue.record("publish failed"); return
        }

        // A stamped row in the SAME manifest — the two-sided control.
        let currentKey = ContentKey(rawValue: "acc1:INBOX:8")
        let currentStamp = "rfc:current@example.com"
        guard let currentId = BodyAssetStore.writeAttachment(
            contentKey: currentKey, section: "2", contentType: "application/pdf",
            data: Data("current-bytes".utf8), identityStamp: currentStamp
        ) else { Issue.record("write failed"); return }

        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: legacyKey, section: "2", identityStamp: "rfc:anything@example.com") == nil,
            "an unstamped row cannot prove which message it belongs to, so it must not be served")
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: currentKey, section: "2", identityStamp: currentStamp) == currentId,
            "a stamped row in the same manifest must still be served — otherwise this passes vacuously")

        // NEVER DESTROY. The legacy row keeps its bytes; it re-fetches on demand and
        // is reclaimed only by the ordinary cap/orphan paths, which key by content
        // key alone exactly as before.
        #expect(BodyAssetStore.read(assetId: legacyId) == legacyBytes,
                "refusing to SERVE an unprovable row must never delete it")
    }

    /// PINS THE PREMISE OF THE WHOLE BINDING. `ContentKey` separates two key SPACES
    /// (content vs. `messageHeader.id`); it does not separate two MESSAGES at one
    /// reused address. Deliberately framed with rfc-LESS messages, which mint the
    /// identical tail at Stage B *and* after the Stage E1 mint swap
    /// (`MessageIdentity.contentKey` falls back to the provider id when
    /// `usableRfc822Tail` is nil) — so this stays true across that migration and goes
    /// red only if `ContentKey` genuinely starts distinguishing them, at which point
    /// the stamp's necessity must be re-argued rather than silently assumed.
    @Test("ContentKey cannot distinguish two messages at a reused UID — the attachment stamp must")
    func contentKeyDoesNotSeparateMessagesAtAReusedAddress() {
        let preReset = Self.makeHeader(
            accountId: "acc1", folderPath: "INBOX", messageId: "42",
            rfc822MessageId: nil, observedUidValidity: 111)
        let postReset = Self.makeHeader(
            accountId: "acc1", folderPath: "INBOX", messageId: "42",
            rfc822MessageId: nil, observedUidValidity: 222)

        let preKey = ContentKey.forHeader(
            accountId: preReset.accountId, folderPath: preReset.folderPath,
            providerMessageId: preReset.messageId,
            rfc822MessageId: preReset.rfc822MessageId, space: .uidAddressed)
        let postKey = ContentKey.forHeader(
            accountId: postReset.accountId, folderPath: postReset.folderPath,
            providerMessageId: postReset.messageId,
            rfc822MessageId: postReset.rfc822MessageId, space: .uidAddressed)

        #expect(preKey == postKey,
                "the content key is the same string for both messages — it is an ADDRESS, not an identity")

        // …and the stamp is what tells them apart.
        let preStamp = AttachmentCacheIdentity.stamp(for: preReset)
        let postStamp = AttachmentCacheIdentity.stamp(for: postReset)
        #expect(preStamp != nil, "a UID proven under a known epoch is a provable identity")
        #expect(postStamp != nil)
        #expect(preStamp != postStamp,
                "two different messages at one address must never mint the same attachment stamp")
    }

    /// The slot is addressed by `(contentKey, section)`, and `prepare` ALWAYS
    /// re-materialises its bytes — so a republish overwrites the file. The manifest
    /// row must follow the bytes: leaving the previous occupant's stamp would make
    /// the row describe one message while holding another's content, and the lie
    /// would point at the message whose attachment it is NOT.
    @Test("Re-publishing an attachment slot rebinds the row to the message whose bytes it now holds")
    func republishingASlotRebindsItToTheNewMessage() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let sharedKey = ContentKey(rawValue: "acc1:INBOX:99")
        let firstStamp = "rfc:first@example.com"
        let secondStamp = "rfc:second@example.com"
        let firstBytes = Data("first-occupant-bytes".utf8)
        let secondBytes = Data("second-occupant-bytes".utf8)

        guard let firstId = BodyAssetStore.writeAttachment(
            contentKey: sharedKey, section: "2", contentType: "application/pdf",
            data: firstBytes, identityStamp: firstStamp
        ) else { Issue.record("first write failed"); return }
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: sharedKey, section: "2", identityStamp: firstStamp) == firstId)

        guard let secondId = BodyAssetStore.writeAttachment(
            contentKey: sharedKey, section: "2", contentType: "application/pdf",
            data: secondBytes, identityStamp: secondStamp
        ) else { Issue.record("second write failed"); return }
        #expect(secondId == firstId, "precondition: the same logical slot, so this is the CONFLICT path")

        // The bytes are the second message's…
        #expect(BodyAssetStore.read(assetId: secondId) == secondBytes)
        // …so the row must answer to the second message…
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: sharedKey, section: "2", identityStamp: secondStamp) == secondId,
            "the row must be served to the message whose bytes it now holds")
        // …and must no longer answer to the first.
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: sharedKey, section: "2", identityStamp: firstStamp) == nil,
            "a stale stamp left by the conflict update would serve the first message the second's bytes")
    }
}
