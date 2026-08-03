/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - T4.D1 — DraftAttachmentStorage.loadAttachments fails closed
//
// Invariant under test (Outbox Reliability Rule 5, applied to drafts):
// `loadAttachments` NEVER returns a SUBSET of what the user attached. The only
// clean attachment-less result is a nil `dirName`. A referenced-but-absent
// directory, a present-but-unreadable data file, and a `.meta`-ambiguous
// filename each THROW, so no compose reopen and no server-draft push can
// silently proceed with fewer attachments than the draft owns.
//
// PORT — `v2final:TabMailTests/Services/ChatPillSessionTests.swift`'s
// `DraftAttachmentStorageTests` fail-closed battery (commit `d2f0c96a3`),
// adapted to a dedicated file and to display names that state the invariant
// rather than the reference's internal vet id.

@Suite("Draft attachment fail-closed loading")
struct DraftAttachmentFailClosedTests {

    /// Create a unique, isolated temporary root so fail-closed tests can create
    /// and mutate real files without touching the global Application Support dir.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftAttachFailClosed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Run `body`, returning the `DraftAttachmentLoadError` it threw, or nil if it
    /// did not throw one. Lets a test pin the EXACT failure mode instead of only
    /// "some error", without depending on `#expect(throws:)`'s return value.
    private func loadError(_ body: () throws -> [DraftAttachment]) -> DraftAttachmentLoadError? {
        do {
            _ = try body()
            return nil
        } catch let error as DraftAttachmentLoadError {
            return error
        } catch {
            return nil
        }
    }

    @Test("A nil dirName is the only clean attachment-less case and returns empty")
    func nilDirNameReturnsEmpty() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: nil, root: root)
        #expect(loaded.isEmpty)
    }

    @Test("A present directory with three readable files returns all three")
    func readableFilesReturnFullCount() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "readable"
        let attachments = (0..<3).map { index in
            DraftAttachment(filename: "f\(index).txt", mimeType: "text/plain",
                            data: Data("data-\(index)".utf8))
        }
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName, root: root)

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        #expect(loaded.count == 3)
        guard loaded.count == 3 else { return }
        #expect(loaded.map(\.filename) == ["f0.txt", "f1.txt", "f2.txt"])
        #expect(String(data: loaded[1].data, encoding: .utf8) == "data-1")
        #expect(loaded[2].mimeType == "text/plain")
    }

    @Test("One unreadable data file among several throws instead of returning a subset")
    func unreadableDataFileThrows() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "unreadable"
        let attachments = [
            DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("aaa".utf8)),
            DraftAttachment(filename: "b.txt", mimeType: "text/plain", data: Data("bbb".utf8)),
            DraftAttachment(filename: "c.txt", mimeType: "text/plain", data: Data("ccc".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName, root: root)
        // Make ONE data file unreadable so `Data(contentsOf:)` fails. The directory
        // stays enumerable, so the file is present-but-unreadable — the exact
        // "silent subset" case the pre-fix `compactMap` dropped.
        let victim = DraftAttachmentStorage.dirURL(for: dirName, root: root)
            .appendingPathComponent("1_b.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: victim.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: victim.path) }

        guard let error = loadError({
            try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        }) else {
            Issue.record("expected a DraftAttachmentLoadError; the loader returned a subset instead")
            return
        }
        guard case .fileUnreadable(let name, _) = error else {
            Issue.record("expected .fileUnreadable, got \(error)")
            return
        }
        #expect(name == "1_b.txt")
    }

    @Test("A referenced-but-missing attachments directory throws instead of returning empty")
    func missingReferencedDirectoryThrows() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A non-nil dirName that was never created under `root`. A referenced-but-
        // absent directory is NOT "no attachments" — the draft still owns them.
        guard let error = loadError({
            try DraftAttachmentStorage.loadAttachments(dirName: "ghost", root: root)
        }) else {
            Issue.record("expected a DraftAttachmentLoadError; the loader returned empty instead")
            return
        }
        guard case .directoryUnreadable(let dirName, _) = error else {
            Issue.record("expected .directoryUnreadable, got \(error)")
            return
        }
        #expect(dirName == "ghost")
    }

    @Test("An attachment literally named *.meta round-trips and is neither dropped nor rejected")
    func literalMetaFilenameRoundTrips() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "literal-meta"
        // A real attachment whose filename ends in ".meta" is stored as data
        // "0_settings.meta" with its OWN sidecar "0_settings.meta.meta", so it is
        // distinguishable from a metadata sidecar and must LOAD. The pre-fix
        // `!hasSuffix(".meta")` filter silently dropped it.
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "settings.meta", mimeType: "text/plain", data: Data("cfg".utf8))],
            dirName: dirName, root: root)

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        #expect(loaded.count == 1)
        guard loaded.count == 1 else { return }
        #expect(loaded[0].filename == "settings.meta")
        #expect(loaded[0].data == Data("cfg".utf8))
        #expect(loaded[0].mimeType == "text/plain")
    }

    @Test("An orphaned .meta file whose data sibling is gone throws")
    func orphanedMetaFileThrows() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "orphan"
        let dir = DraftAttachmentStorage.dirURL(for: dirName, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Only a ".meta" file, with neither a base data file nor its own sidecar —
        // indistinguishable from a lost-data orphan (the real data file gone), so
        // fail closed rather than load metadata bytes as if they were the attachment.
        try Data("text/plain\nfalse".utf8).write(to: dir.appendingPathComponent("0_lost.pdf.meta"))

        guard let error = loadError({
            try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        }) else {
            Issue.record("expected a DraftAttachmentLoadError; the loader accepted the orphan instead")
            return
        }
        guard case .ambiguousMetaFilename(let name) = error else {
            Issue.record("expected .ambiguousMetaFilename, got \(error)")
            return
        }
        #expect(name == "0_lost.pdf.meta")
    }

    @Test("A missing metadata sidecar is not data loss and still loads with the MIME fallback")
    func missingSidecarStillLoads() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "no-sidecar"
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("aaa".utf8))],
            dirName: dirName, root: root)
        // The attachment BYTES are intact; only the descriptive sidecar is gone.
        // Fail-closed applies to lost DATA, not to lost metadata — this must NOT throw.
        let dir = DraftAttachmentStorage.dirURL(for: dirName, root: root)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("0_a.txt.meta"))

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        #expect(loaded.count == 1)
        guard loaded.count == 1 else { return }
        #expect(loaded[0].filename == "a.txt")
        #expect(loaded[0].data == Data("aaa".utf8))
        #expect(loaded[0].mimeType == "application/octet-stream")
        #expect(loaded[0].isAlternative == false)
    }
}
