/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// D2 — the attachment-loss window between staging and commit.
///
/// `queueSend` writes the outbox attachment directory to disk BEFORE the gated
/// write that commits the row referencing it (Outbox Reliability Rule 6: file
/// I/O never runs inside a DB transaction). For the whole staging→commit window
/// the live directory is referenced by NO committed row, so an orphan sweep that
/// treats "unreferenced" as "orphan" DELETES live user attachments — and
/// `loadAttachments` then fails closed (Outbox Rule 5), permanently failing the
/// send.
///
/// The property pinned here is the SYSTEM property, not the guard's mechanism:
/// **an attachment directory that has been staged but whose row has not yet
/// committed still holds its attachments after a sweep runs** — i.e. the send is
/// still completable. The complementary tests keep the guard from silently
/// disabling the sweep (an aged orphan is still reclaimed) and keep a referenced
/// directory untouchable regardless of age.
@Suite("Outbox attachment staging grace window (D2)", .serialized, .processGlobalState)
struct OutboxAttachmentStagingGraceTests {

    // MARK: - Helpers

    private func makeAttachments() -> [DraftAttachment] {
        [
            DraftAttachment(filename: "quarterly.pdf", mimeType: "application/pdf",
                            data: Data("quarterly-report-bytes".utf8)),
            DraftAttachment(filename: "notes.txt", mimeType: "text/plain",
                            data: Data("meeting-notes-bytes".utf8))
        ]
    }

    /// A throwaway base directory so the age-advancing tests can never reclaim a
    /// directory another concurrently running suite staged into the shared
    /// production store.
    private func makeTempBaseDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A directory holding attachment bytes, created directly so the temp-dir
    /// cases do not depend on any particular store's layout.
    @discardableResult
    private func makeDirWithBytes(named name: String, in base: URL) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("0_report.pdf-bytes".utf8).write(to: dir.appendingPathComponent("0_report.pdf"))
        return dir
    }

    /// Every directory currently in `base` EXCEPT `exclude`. Used as the sweep's
    /// `referenced` set so the sweep under test can only ever act on the one
    /// directory the test staged — exactly the DB's mid-window view, in which
    /// every committed row is referenced and the in-flight one is not.
    private func referencedExcluding(_ exclude: String, in base: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent) ?? []
        return Set(names).subtracting([exclude])
    }

    // MARK: - The window (red-proof)

    @Test("A staged-but-uncommitted outbox attachment dir survives a concurrent sweep, attachments intact")
    func stagedOutboxDirSurvivesConcurrentSweep() throws {
        let attachments = makeAttachments()
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "with attachments",
                                 body: "body", attachments: attachments)
        // The PRODUCTION staging call, exactly as `persistQueuedSend` makes it
        // before its gated write: the directory is named by the row id.
        let outbox = OutboxMessage(accountId: "acct-staging-grace", draft: draft)
        try OutboxMessage.saveAttachments(attachments, dirName: outbox.id)
        let base = OutboxMessage.attachmentsBaseDir
        let stagedDir = base.appendingPathComponent(outbox.id, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagedDir) }

        #expect(FileManager.default.fileExists(atPath: stagedDir.path))

        // The concurrent sweep lands HERE — after the files are on disk, before
        // the row commits, so the new id is absent from the committed set.
        let sweep = AccountManager.reclaimUnreferencedAttachmentDirs(
            baseDir: base,
            referenced: referencedExcluding(outbox.id, in: base)
        )

        // THE INVARIANT: the send is still completable — the fail-closed loader
        // (Outbox Rule 5) still returns every attachment, byte for byte.
        #expect(FileManager.default.fileExists(atPath: stagedDir.path))
        let loaded = try outbox.loadAttachments()
        #expect(loaded.count == attachments.count)
        guard loaded.count == attachments.count else { return }
        #expect(loaded.map(\.filename).sorted() == attachments.map(\.filename).sorted())
        #expect(Set(loaded.map(\.data)) == Set(attachments.map(\.data)))

        #expect(!sweep.reclaimed.contains(outbox.id))
        #expect(sweep.deferredInFlight.contains(outbox.id))
    }

    // MARK: - The guard must not become a disk leak

    @Test("An unreferenced dir observed past the grace window is still reclaimed")
    func agedUnreferencedDirIsReclaimed() throws {
        let base = try makeTempBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let orphan = UUID().uuidString
        let orphanDir = try makeDirWithBytes(named: orphan, in: base)
        #expect(FileManager.default.fileExists(atPath: orphanDir.path))

        // Age is simulated by advancing the observer's clock — never by
        // backdating filesystem attributes.
        let sweep = AccountManager.reclaimUnreferencedAttachmentDirs(
            baseDir: base,
            referenced: [],
            now: Date().addingTimeInterval(SyncConfig.attachmentOrphanReclaimGraceSeconds + 60)
        )

        #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
        #expect(sweep.reclaimed.contains(orphan))
        #expect(!sweep.deferredInFlight.contains(orphan))
    }

    @Test("A referenced dir is never reclaimed, however old the sweep believes it is")
    func referencedDirIsNeverReclaimed() throws {
        let base = try makeTempBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let live = UUID().uuidString
        let liveDir = try makeDirWithBytes(named: live, in: base)

        let sweep = AccountManager.reclaimUnreferencedAttachmentDirs(
            baseDir: base,
            referenced: [live],
            now: Date().addingTimeInterval(SyncConfig.attachmentOrphanReclaimGraceSeconds * 100)
        )

        #expect(sweep.reclaimed.isEmpty)
        #expect(sweep.deferredInFlight.isEmpty)
        #expect(FileManager.default.fileExists(atPath: liveDir.appendingPathComponent("0_report.pdf").path))
    }
}
