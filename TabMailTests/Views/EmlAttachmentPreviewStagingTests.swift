/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// ADR-IOS-076 decision 9 — the invariant this suite pins is
/// **no attachment write from the `.eml` preview lands outside the preview staging
/// root**, whatever the sender put in the MIME `filename` parameter.
///
/// It is deliberately NOT a test of `AttachmentPreviewStager`. The defect at THIS
/// call site was a half-port, not a stager bug:
/// `AttachmentPreviewStagingTests.craftedFilenameIsRefused` (named
/// `craftedFilenameStaysInsideItsAttempt` until 2026-08-12) has been
/// green the whole time this call site was writing
/// `temporaryDirectory.appendingPathComponent(attachment.filename)` — a test that
/// pins the mechanism cannot fail for a call site that never reaches the
/// mechanism. So this drives `EmlAttachmentPreview.downloadAndPreview` itself and
/// asserts on the filesystem, not on which helper was called.
///
/// ⚠️ **Retracted 2026-08-12:** this passage read "**The stager was always
/// correct**". That is an absolute and it is false — `05200112d` fixed
/// `AttachmentPreviewStager.displayFilename` accepting a separator-bearing name,
/// and `7ce64e44b` fixed the same reduction missing a `U+002F` hidden inside a
/// grapheme cluster plus the failure path deleting the per-message namespace.
/// Both landed after this suite was written. The scoped claim — the traversal at
/// this call site was a half-port rather than a stager bug — survives and is kept
/// above; the absolute does not. Same retraction as ADR-IOS-076 decision 9,
/// recorded as MIS-019 instance 13.
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

    /// ⚠️ **Part (2) changed shape on 2026-08-12; part (1), the invariant, did
    /// not.** The crafted name used to be REDUCED and then staged, so the
    /// non-vacuity half asserted the bytes landed beneath the staging root. The
    /// owner replaced the reduction with a rejection, so the name is now refused
    /// **before the fetch** and nothing is staged at all — a strictly stronger
    /// outcome, and the one this test now pins. The non-vacuity burden moves with
    /// it: "nothing was written" is exactly the assertion that passes for free if
    /// the call site silently did nothing, so the replacement half asserts what IS
    /// observable from here — the fetch was never issued, and the name really is
    /// one the shared predicate refuses — plus the companion test below, which
    /// proves a legitimate name still reaches both the fetch and the disk.
    ///
    /// ⚠️ What the user is TOLD is deliberately not asserted here: `error` is
    /// `@State private` on the view and there is no seam to it. That half is
    /// pinned where it can be — on `AttachmentFilenameError.errorDescription` in
    /// `AttachmentFilenameContainmentTests.theRefusalMessageIsReasonAgnostic`.
    @Test("A crafted nested-attachment filename is refused before it can be fetched or staged")
    func craftedNestedFilenameIsRefusedBeforeFetching() async throws {
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

        var fetched = false
        await view.downloadAndPreview(attachment) { _ in
            fetched = true
            return Self.attackerBytes
        }

        // (1) THE INVARIANT — nothing outside the staging root was written.
        let canaryAfter = try Data(contentsOf: canary)
        #expect(
            canaryAfter == Self.canaryBytes,
            "a nested .eml attachment write escaped the staging root and overwrote \(canary.path)"
        )

        // (2) Nothing landed INSIDE the staging root either — the refusal precedes
        // the write entirely, so there is no attempt directory to leak.
        #expect(
            files(named: canaryName, under: stagingRoot).isEmpty,
            "a refused nested attachment staged its bytes"
        )

        // (3) The observable consequences, so (1) and (2) cannot pass merely
        // because this call site silently does nothing at all. The refusal happens
        // BEFORE the fetch — the user does not pay for bytes nothing can open —
        // and the view reports it rather than failing quietly.
        #expect(fetched == false, "a refused nested attachment was fetched anyway")
        #expect(!AttachmentFilename.isSafeFileComponent(crafted), "fixture check: this name is no longer refused")
    }

    /// The other side of the test above: a LEGITIMATE nested attachment must still
    /// be fetched and staged. Without this, "nothing was written" would be
    /// satisfied by a call site that never writes anything, and the refusal above
    /// would prove nothing about the crafted name in particular.
    @Test("A legitimate nested-attachment filename is fetched and staged beneath the preview staging root")
    func legitimateNestedFilenameIsStaged() async throws {
        let name = "nested-report-\(UUID().uuidString).pdf"
        let attachment = AttachmentInfo(
            filename: name,
            contentType: "application/pdf",
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

        var fetched = false
        await view.downloadAndPreview(attachment) { _ in
            fetched = true
            return Self.attackerBytes
        }

        #expect(fetched, "a legitimate nested attachment was never fetched")
        let landed = files(named: name, under: stagingRoot)
        #expect(landed.count == 1, "the fetched bytes must be staged for QuickLook to read")
        guard landed.count == 1 else { return }
        defer { try? FileManager.default.removeItem(at: landed[0].deletingLastPathComponent()) }
        #expect((try? Data(contentsOf: landed[0])) == Self.attackerBytes)
    }
}
