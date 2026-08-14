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

    /// The per-message namespace `<root>/TabMailAttachmentPreviews/<message hash>/`
    /// that every attempt for one message shares. Derived from a staged file
    /// rather than recomputed, so no test re-implements the staging layout.
    private func namespace(of staged: URL) -> URL {
        staged.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
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

    /// ⚠️ **This test asserted a REDUCTION until 2026-08-12** — that
    /// `"../../escaped.pdf"` staged as `escaped.pdf` beneath the root. The owner
    /// replaced the reduction with a rejection, so the same input now throws and
    /// stages nothing at all. The INVARIANT is unchanged and is still what is
    /// asserted: no staged write lands outside the attempt directory. Refusing is
    /// simply the stronger way of holding it, and it is recoverable — the user is
    /// told the name is unsupported and no bytes are written.
    @Test("A filename carrying path separators is refused rather than staged")
    func craftedFilenameIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AttachmentFilenameError.self) {
            try AttachmentPreviewStager.stage(
                data: Data("BYTES".utf8),
                messageId: Self.messageId,
                originalFilename: "../../escaped.pdf",
                rootDirectory: root
            )
        }

        #expect(
            stagedFiles(under: root).isEmpty,
            "a refused name must not write bytes anywhere beneath the staging root"
        )
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "the refusal happens before the attempt directory is created, so nothing is left to clean up"
        )
    }

    /// The invariant: **a staged write lands inside the attempt directory the
    /// stager created for it — never one level up, in the per-message namespace
    /// that every other attempt for the same message shares.**
    ///
    /// Swift `String` iterates EXTENDED GRAPHEME CLUSTERS. `U+002F` followed by a
    /// combining mark (here `U+0301`) forms ONE cluster that is **not** equal to
    /// `Character("/")`, so a `Character`-wise `split(separator: "/")` does not
    /// split there — while the UTF-8 bytes still carry a real `0x2F` that the
    /// filesystem reads as a path separator. The name therefore came back
    /// UNREDUCED, still holding a separator, and `appendingPathComponent` walked
    /// on it: measured on pre-fix code, the bytes landed at
    /// `<namespace>/<tail>`, exactly the sibling-reachable position `05200112d`
    /// was written to close, reached through a different input.
    ///
    /// Asserted on the FILESYSTEM rather than on what the predicate returns:
    /// pinning the verdict would leave the same escape reachable through any other
    /// spelling of the same shape.
    ///
    /// ⚠️ **The assertion changed shape on 2026-08-12, the invariant did not.**
    /// This name used to be REDUCED and then staged, so the test asserted where the
    /// bytes landed; it is now REFUSED, so the test asserts that no bytes landed
    /// anywhere and that the sibling attempt is untouched. Both are the same
    /// statement about the write.
    @Test("A path separator hidden inside a grapheme cluster is refused, leaving the sibling attempt intact")
    func hiddenSeparatorFilenameIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A sibling attempt under the SAME messageId, so the namespace asserted
        // about below is the one a live preview's bytes actually sit in.
        let sibling = try AttachmentPreviewStager.stage(
            data: Data("FIRST".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root
        )
        let sharedNamespace = namespace(of: sibling).standardizedFileURL
        let siblingAttempt = sibling.deletingLastPathComponent()

        #expect(throws: AttachmentFilenameError.self) {
            try AttachmentPreviewStager.stage(
                data: Data("BYTES".utf8),
                messageId: Self.messageId,
                originalFilename: "..\u{2F}\u{0301}x.pdf",
                rootDirectory: root
            )
        }

        // Nothing new landed ANYWHERE beneath the root — not in the shared
        // namespace (the position the escape reached pre-fix), not in a new attempt.
        #expect(
            stagedFiles(under: root).map(\.standardizedFileURL) == [sibling.standardizedFileURL],
            "a refused name wrote bytes: the only staged file must still be the sibling"
        )
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: sharedNamespace.path))
                == [siblingAttempt.lastPathComponent],
            "a refused name created an attempt directory in the shared per-message namespace"
        )
        // Non-vacuity: the sibling attempt really is there, so the two assertions
        // above are about a refused write and not about an empty tree.
        #expect((try? Data(contentsOf: sibling)) == Data("FIRST".utf8))
    }

    /// The invariant: **no stager failure path deletes anything outside the
    /// attempt directory it created.**
    ///
    /// This is deliberately NOT an assertion about what `displayFilename`
    /// returns. The damage does not happen at the naming step — it happens when
    /// a name that resolves back to the attempt DIRECTORY makes the write fail
    /// and sends `stage`'s error path into the cleanup call (then named
    /// `discardAttempt`, now `discardAttemptDirectory`) — which, in the form
    /// it had when this test was written, walked UP from the staged file and so
    /// removed the per-message NAMESPACE rather than the attempt. Both preview
    /// call sites
    /// (`AttachmentListView.downloadAndPreview` and
    /// `EmlAttachmentPreview.downloadAndPreview`) stage under the same
    /// `messageId`, so a nested `.eml` part could take out a top-level
    /// attachment that a live QuickLook preview and its `ShareLink` are still
    /// reading. Pinning the naming would leave that reachable through any other
    /// name with the same shape.
    ///
    /// ⚠️ **This test no longer reaches the cleanup path, and must not be read as
    /// covering one.** It was written against the state where `displayFilename`
    /// returned `"/"` for `"/"`; `05200112d` made that name reduce to
    /// `"Attachment"` so the hostile attempt WROTE SUCCESSFULLY, and since
    /// 2026-08-12 it is REFUSED before an attempt directory is created — so
    /// `discardAttemptDirectory` is not called either way. What survives here is
    /// the weaker statement that this particular name is handled and confined; the
    /// cleanup-path invariant is pinned by `aFailedWriteDiscardsOnlyItsOwnAttempt`
    /// below, which forces the failure through the `writeData` seam instead of
    /// hoping a name still provokes one.
    ///
    /// ⚠️ The `@Test` DISPLAY NAME below still says "A failed attempt", and it is
    /// wrong for the reason this paragraph gives: read it as a legacy label, not
    /// as a description. It is left as it is because it is the searchable identity
    /// the two cross-references in this file point at, and because renaming it
    /// would make the test look new in the run log while covering strictly less
    /// than its name claims either way — but the invariant is NOT untested: the
    /// injected-failure test below covers it.
    @Test("A failed attempt never deletes a sibling attempt's staged bytes")
    func aFailedAttemptNeverDeletesASiblingAttempt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let good = try AttachmentPreviewStager.stage(
            data: Data("FIRST".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root
        )
        // `<root>/TabMailAttachmentPreviews/<message hash>` — shared by every
        // attempt for this message, which is exactly what must survive.
        let namespace = good.deletingLastPathComponent().deletingLastPathComponent()

        // A hostile name staged under the SAME messageId. Whether it succeeds or
        // fails is not the point and is not asserted; the point is that its
        // outcome is confined to its own attempt.
        _ = try? AttachmentPreviewStager.stage(
            data: Data("HOSTILE".utf8),
            messageId: Self.messageId,
            originalFilename: "/",
            rootDirectory: root
        )

        #expect(
            (try? Data(contentsOf: good)) == Data("FIRST".utf8),
            "a second attempt's failure must not destroy the bytes a live preview and its ShareLink are reading"
        )
        var isDirectory: ObjCBool = false
        let namespaceExists = FileManager.default.fileExists(
            atPath: namespace.path, isDirectory: &isDirectory
        )
        #expect(
            namespaceExists && isDirectory.boolValue,
            "the per-message namespace directory must outlive any single failed attempt"
        )
    }

    /// The invariant: **a failed attempt removes exactly the attempt directory
    /// the stager created for it, and nothing above it.**
    ///
    /// The failure is injected through the `writeData` seam rather than provoked
    /// by a crafted name, so the statement is about the CLEANUP PATH and does not
    /// silently stop exercising it the day the naming rule stops admitting the
    /// name that used to provoke it — which is exactly how
    /// `aFailedAttemptNeverDeletesASiblingAttempt` above went vacuous, and exactly
    /// what happened again on 2026-08-12 when the reduction became a REJECTION:
    /// this test's own fixture was `"..\u{2F}\u{0301}x.pdf"`, which now throws
    /// `AttachmentFilenameError` **before** `writeData` is ever called. A seam that
    /// injects the failure survives that; a hostile-name fixture does not. The
    /// filename below is therefore deliberately ORDINARY — the crafted one is now
    /// pinned by `hiddenSeparatorFilenameIsRefused` above, where refusal is the
    /// assertion rather than an obstacle to it.
    ///
    /// Pre-fix, the failure path re-derived its delete target from the
    /// destination it had just built out of the sender's filename
    /// (`stagedURL.deletingLastPathComponent()`). A name that resolved back above
    /// the attempt therefore aimed the delete at the per-message NAMESPACE,
    /// taking the sibling attempt whose bytes a live QuickLook preview and its
    /// `ShareLink` are still reading. Both preview call sites stage under the
    /// same `messageId` (`AttachmentListView.downloadAndPreview` passes
    /// `message.id`, `EmlAttachmentPreview.downloadAndPreview` passes
    /// `parentMessage.id`), so a nested `.eml` part reaches a top-level
    /// attachment's staged bytes.
    ///
    /// Goes red on either half of a partial revert: if the cleanup goes back to
    /// walking up from what it is handed, the namespace assertion fails; if the
    /// call site goes back to handing it the destination FILE, the attempt
    /// directory is left behind and the last assertion fails.
    @Test("A failed write discards only its own attempt, never a sibling or the shared namespace")
    func aFailedWriteDiscardsOnlyItsOwnAttempt() throws {
        struct StageFailure: Error {}
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sibling = try AttachmentPreviewStager.stage(
            data: Data("FIRST".utf8),
            messageId: Self.messageId,
            originalFilename: "invoice.pdf",
            rootDirectory: root
        )
        let siblingAttempt = sibling.deletingLastPathComponent()
        let sharedNamespace = namespace(of: sibling)

        #expect(throws: StageFailure.self) {
            try AttachmentPreviewStager.stage(
                data: Data("HOSTILE".utf8),
                messageId: Self.messageId,
                originalFilename: "second-attachment.pdf",
                rootDirectory: root,
                writeData: { _, _ in throw StageFailure() }
            )
        }

        #expect(
            (try? Data(contentsOf: sibling)) == Data("FIRST".utf8),
            "a failed attempt must not destroy the bytes a live preview and its ShareLink are reading"
        )
        #expect(
            isDirectory(sharedNamespace),
            "the per-message namespace must outlive a failed attempt"
        )
        #expect(
            isDirectory(siblingAttempt),
            "a sibling attempt directory must outlive a failed attempt"
        )
        // The other side of it, so the assertions above cannot pass merely by the
        // cleanup doing nothing at all: the failed attempt's OWN directory is
        // gone, leaving the namespace holding exactly the surviving sibling.
        let children = (try? FileManager.default.contentsOfDirectory(atPath: sharedNamespace.path)) ?? []
        #expect(
            children == [siblingAttempt.lastPathComponent],
            "the failed attempt's own directory must be removed, leaving only the sibling; found \(children)"
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
