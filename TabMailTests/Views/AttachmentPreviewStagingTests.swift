/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// T4.V18 — QuickLook is presented imperatively here, so two things must hold at
/// once: exactly one presentation may be in flight (the single-slot reservation),
/// and no attempt may ever write over the bytes an active preview is reading (the
/// per-attempt staging directory).
///
/// The reservation is the dangerous half: a slot that is claimed and never
/// released is a PERMANENT freeze — every later attachment tap is silently
/// refused for the rest of the process. Each release path is pinned below.
///
/// `.serialized` + `.processGlobalState`: `AttachmentQuickLook`'s slot is
/// process-global static state on the MainActor. Every test here leaves the slot
/// free on exit.
@Suite("Attachment preview staging + QuickLook reservation (T4.V18)", .serialized, .processGlobalState)
@MainActor
struct AttachmentPreviewStagingTests {

    /// A content key shaped like the real thing (`<accountId>:<folderPath>:<tail>`).
    private static let messageId = "acc1:INBOX:1"

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("v18-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every regular file staged anywhere beneath `root`. Empty means nothing
    /// survived — the staging tree may still hold empty parent directories, but
    /// no attachment bytes are leaked.
    private func stagedFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    // MARK: - Single-slot reservation

    @Test("Two concurrent preview attempts admit exactly one presentation")
    func exactlyOneAttemptIsAdmitted() {
        AttachmentQuickLook.cancelReservedPresentation()

        #expect(AttachmentQuickLook.reservePresentation())
        #expect(AttachmentQuickLook.reservePresentation() == false)
        #expect(AttachmentQuickLook.reservePresentation() == false)

        AttachmentQuickLook.cancelReservedPresentation()
    }

    @Test("A cancelled attempt frees the slot instead of wedging every later preview")
    func cancelledAttemptFreesTheSlot() {
        AttachmentQuickLook.cancelReservedPresentation()
        #expect(AttachmentQuickLook.reservePresentation())

        // The download/staging path failed. This is exactly what
        // `downloadAndPreview`'s `defer` runs on every exit that did not present.
        AttachmentQuickLook.cancelReservedPresentation()

        #expect(
            AttachmentQuickLook.reservePresentation(),
            "a released reservation must be re-claimable — a stuck one is a permanent freeze"
        )
        AttachmentQuickLook.cancelReservedPresentation()
    }

    @Test("Completing a presentation that was never reserved is refused and leaves the slot claimable")
    func unreservedPresentationIsRefused() {
        AttachmentQuickLook.cancelReservedPresentation()

        // Refused by the reservation guard before `topViewController()` is ever
        // consulted, so this cannot present anything in the test host.
        #expect(AttachmentQuickLook.presentReserved(url: URL(fileURLWithPath: "/dev/null")) == false)

        #expect(
            AttachmentQuickLook.reservePresentation(),
            "a refused completion must not leave the slot held"
        )
        AttachmentQuickLook.cancelReservedPresentation()
    }

    // MARK: - Per-attempt staging

    @Test("Two attempts on the same message and filename never share a staging directory")
    func attemptsNeverShareADirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try AttachmentPreviewStager.stage(
            data: Data("FIRST".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root
        )
        let second = try AttachmentPreviewStager.stage(
            data: Data("SECOND".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root
        )

        #expect(first != second)
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        // The user-meaningful name survives on both, so QuickLook keeps its title
        // and its UTType-from-extension hint.
        #expect(first.lastPathComponent == "invoice.pdf")
        #expect(second.lastPathComponent == "invoice.pdf")
        // The invariant that matters: staging the second attempt did NOT overwrite
        // the bytes a live preview of the first attempt is reading.
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        #expect(firstBytes == Data("FIRST".utf8))
        #expect(secondBytes == Data("SECOND".utf8))
    }

    @Test("A filename carrying path separators cannot escape its attempt directory")
    func craftedFilenameStaysInsideItsAttempt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try AttachmentPreviewStager.stage(
            data: Data("BYTES".utf8),
            messageId: Self.messageId,
            originalFilename: "../../escaped.pdf",
            rootDirectory: root
        )

        #expect(staged.lastPathComponent == "escaped.pdf")
        #expect(
            staged.path.hasPrefix(root.path),
            "a staged file must always land beneath the staging root"
        )
    }

    // MARK: - Attempt lifetime (no unbounded tmp/ growth)

    @Test("A refused presentation removes the attempt directory it staged")
    func refusedPresentationDiscardsItsAttempt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try AttachmentPreviewStager.stageAndPresent(
            data: Data("BYTES".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root,
            presenter: { _ in false }
        )

        #expect(staged == nil)
        #expect(
            stagedFiles(under: root).isEmpty,
            "a refused attempt must not leak its staged bytes into tmp/"
        )
    }

    @Test("A staging write failure leaves no attempt behind")
    func failedWriteDiscardsItsAttempt() throws {
        struct StageFailure: Error {}
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: StageFailure.self) {
            try AttachmentPreviewStager.stage(
                data: Data("BYTES".utf8),
                messageId: Self.messageId,
                originalFilename: "invoice.pdf",
                rootDirectory: root,
                writeData: { _, _ in throw StageFailure() }
            )
        }

        #expect(
            stagedFiles(under: root).isEmpty,
            "the attempt directory is created before the write, so a failed write must remove it"
        )
    }

    @Test("A successful presentation keeps its staged bytes for QuickLook to read")
    func successfulPresentationRetainsItsAttempt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try AttachmentPreviewStager.stageAndPresent(
            data: Data("BYTES".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root,
            presenter: { _ in true }
        )

        let url = try #require(staged)
        // Two-sided against the cleanup tests above: cleanup must not be so eager
        // that it deletes the file the live preview, ShareLink and the re-present
        // path all read after this call returns.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let retainedBytes = try Data(contentsOf: url)
        #expect(retainedBytes == Data("BYTES".utf8))
    }
}
