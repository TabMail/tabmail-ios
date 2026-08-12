/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// T11 (`PLAN_EMAIL_RENDER_SECURITY.md` §2.9) — the invariant this suite pins is
/// **no attachment write from the `.eml` preview lands outside the preview staging
/// root**, whatever the sender put in the MIME `filename` parameter.
///
/// It is deliberately NOT a test of `AttachmentPreviewStager`. The stager was
/// always correct, and `AttachmentPreviewStagingTests.craftedFilenameStaysInsideItsAttempt`
/// has been green the whole time this call site was writing
/// `temporaryDirectory.appendingPathComponent(attachment.filename)` — a test that
/// pins the mechanism cannot fail for a call site that never reaches the
/// mechanism. So this drives `EmlAttachmentPreview.downloadAndPreview` itself and
/// asserts on the filesystem, not on which helper was called.
///
/// `.serialized` + `.processGlobalState`: the assertions read the process-wide
/// temporary directory, and constructing the view touches `AccountManager.shared`.
@Suite("EmlAttachmentPreview nested-attachment staging (T11)", .serialized, .processGlobalState)
@MainActor
struct EmlAttachmentPreviewStagingTests {

    private static let canaryBytes = Data("CANARY-ORIGINAL".utf8)
    private static let attackerBytes = Data("ATTACKER-PAYLOAD".utf8)

    /// The directory `AttachmentPreviewStager` roots every attempt under.
    private var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TabMailAttachmentPreviews", isDirectory: true)
    }

    private func parentMessage() -> MessageHeader {
        MessageHeader(
            messageId: "1",
            subject: "Fwd: report",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "See attached",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
    }

    /// Every regular file named `name` anywhere beneath `root`.
    private func files(named name: String, under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            url.lastPathComponent == name
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    @Test("A crafted nested-attachment filename cannot write outside the preview staging root")
    func craftedNestedFilenameCannotWriteOutsideTheStagingRoot() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory

        // The real exploit aims `../Library/Application Support/TabMail/tabmail.sqlite`
        // at the live GRDB store (a brick, plus every undrained PendingOperation /
        // OutboxMessage row). A test must obviously not target that, and it does not
        // need to: the property is "the write never lands outside the staging root",
        // so a uniquely-named canary this test owns, sitting outside that root, is
        // the same property with a harmless landing site.
        let canaryName = "eml-preview-canary-\(UUID().uuidString).bin"
        let canary = temporaryDirectory.appendingPathComponent(canaryName)
        try Self.canaryBytes.write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }
        #expect(
            canary.path.hasPrefix(stagingRoot.path) == false,
            "the canary must sit OUTSIDE the staging root, or this test proves nothing"
        )

        // One directory level out of wherever the write is rooted, then back in by
        // name — a real escape whose target this test created.
        let crafted = "../\(temporaryDirectory.lastPathComponent)/\(canaryName)"
        let attachment = AttachmentInfo(
            filename: crafted,
            contentType: "application/octet-stream",
            section: "2.1",
            size: Self.attackerBytes.count,
            encoding: nil,
            parentEmlSection: "2"
        )
        let view = EmlAttachmentPreview(
            html: "<div class=\"tm-eml-section\"></div>",
            filename: "forwarded.eml",
            nestedAttachments: [attachment],
            parentMessage: parentMessage(),
            onDismiss: {}
        )

        await view.downloadAndPreview(attachment) { _ in Self.attackerBytes }

        // (1) THE INVARIANT — nothing outside the staging root was written.
        let canaryAfter = try Data(contentsOf: canary)
        #expect(
            canaryAfter == Self.canaryBytes,
            "a nested .eml attachment write escaped the staging root and overwrote \(canary.path)"
        )

        // (2) The other side of it, so (1) cannot pass merely because the download
        // wrote nothing at all: the bytes DID land, beneath the staging root.
        let landed = files(named: canaryName, under: stagingRoot)
        #expect(landed.count == 1, "the fetched bytes must be staged for QuickLook to read")
        guard landed.count == 1 else { return }
        defer { try? FileManager.default.removeItem(at: landed[0].deletingLastPathComponent()) }
        let stagedBytes = try Data(contentsOf: landed[0])
        #expect(stagedBytes == Self.attackerBytes)
    }
}
