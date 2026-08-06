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

    // MARK: - T4.D3 — copy-on-write attachment staging
    //
    // Invariant: the compose save/send paths NEVER write the new attachment set
    // over the LIVE directory, and never derive a directory name from a `draftId`.
    //   (i)   a save that fails leaves the live directory byte-intact;
    //   (ii)  a save that commits publishes the new set (two-sided — a guard that
    //         simply never wrote anything would satisfy (i) alone);
    //   (iii) a `draftId` containing `/` cannot escape the storage root.

    @Test("A staging directory name is one path component a slash-bearing draftId cannot escape")
    func stagingDirNameCannotEscapeTheRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The HAZARD, demonstrated on the superseded naming. A reply draft key is
        // `reply:<accountId>:<stableId>` and an RFC 5322 Message-ID local part may
        // legally contain `/` (`atext` includes it); an Exchange/Graph resource id
        // is base64, which also contains `/`. `appendingPathComponent` treats those
        // as SEPARATORS, so the "directory" resolves somewhere other than a direct
        // child of the storage root.
        let hostileDraftId = "reply:user@example.com:a/b/c@example.com"
        let escaped = DraftAttachmentStorage.dirURL(for: hostileDraftId, root: root)
        #expect(escaped.deletingLastPathComponent().standardizedFileURL.path
                != root.standardizedFileURL.path)

        // The ported staging name cannot: it is an opaque UUID with no separator,
        // so it always resolves to exactly ONE child of the root.
        let staging = DraftAttachmentStorage.newStagingDirName()
        #expect(!staging.contains("/"))
        #expect(!staging.contains(":"))
        #expect(!staging.contains(".."))
        let contained = DraftAttachmentStorage.dirURL(for: staging, root: root)
        #expect(contained.deletingLastPathComponent().standardizedFileURL.path
                == root.standardizedFileURL.path)
        #expect(contained.lastPathComponent == staging)

        // Copy-on-write premise: a staging name is never a directory already in use.
        #expect(DraftAttachmentStorage.newStagingDirName()
                != DraftAttachmentStorage.newStagingDirName())
    }

    @Test("A failed save leaves the live attachment directory intact and removes only the staging copy")
    func failedSaveLeavesLiveDirectoryIntact() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveDir = DraftAttachmentStorage.newStagingDirName()
        let original = [
            DraftAttachment(filename: "contract.pdf", mimeType: "application/pdf",
                            data: Data("original-contract".utf8)),
            DraftAttachment(filename: "notes.txt", mimeType: "text/plain",
                            data: Data("original-notes".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(original, dirName: liveDir, root: root)

        // The compose stages a REPLACEMENT set copy-on-write, then the DB save fails.
        let staging = DraftAttachmentStorage.newStagingDirName()
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "replacement.txt", mimeType: "text/plain",
                             data: Data("replacement".utf8))],
            dirName: staging, root: root)
        let disposition = ComposeDraftGuards.attachmentDisposition(
            saveApplied: false, stagingDir: staging, previousDir: liveDir)
        #expect(disposition == .deleteStaging(dirName: staging))
        guard case .deleteStaging(let toDelete) = disposition else { return }
        DraftAttachmentStorage.deleteAttachments(dirName: toDelete, root: root)

        // The user's live attachments are byte-intact and still fully loadable.
        let survivors = try DraftAttachmentStorage.loadAttachments(dirName: liveDir, root: root)
        #expect(survivors.count == 2)
        guard survivors.count == 2 else { return }
        #expect(survivors.map(\.filename) == ["contract.pdf", "notes.txt"])
        #expect(survivors[0].data == Data("original-contract".utf8))
        #expect(survivors[1].data == Data("original-notes".utf8))
    }

    @Test("A failed drop-all save leaves the live attachment directory intact")
    func failedDropAllSaveLeavesLiveDirectoryIntact() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveDir = DraftAttachmentStorage.newStagingDirName()
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "keep.txt", mimeType: "text/plain",
                             data: Data("keep".utf8))],
            dirName: liveDir, root: root)

        // N→0 with a save that does NOT commit: nothing durable dropped the
        // directory, so nothing on disk may be destroyed. The superseded call site
        // deleted the old directory BEFORE the database write, so a subsequent save
        // failure destroyed files a surviving row still pointed at.
        let disposition = ComposeDraftGuards.attachmentDisposition(
            saveApplied: false, stagingDir: nil, previousDir: liveDir)
        #expect(disposition == .noCleanup)

        let survivors = try DraftAttachmentStorage.loadAttachments(dirName: liveDir, root: root)
        #expect(survivors.count == 1)
        guard survivors.count == 1 else { return }
        #expect(survivors[0].data == Data("keep".utf8))
    }

    @Test("A committed save publishes the staged attachments and destroys only the superseded directory")
    func committedSavePublishesStagedAttachments() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveDir = DraftAttachmentStorage.newStagingDirName()
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "old.txt", mimeType: "text/plain",
                             data: Data("old".utf8))],
            dirName: liveDir, root: root)

        let staging = DraftAttachmentStorage.newStagingDirName()
        let published = [
            DraftAttachment(filename: "new-a.txt", mimeType: "text/plain", data: Data("aaa".utf8)),
            DraftAttachment(filename: "new-b.txt", mimeType: "text/plain", data: Data("bbb".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(published, dirName: staging, root: root)

        // TWO-SIDED: the committed leg must actually publish, or (i) above would be
        // satisfied by a change that simply never writes attachments at all.
        let disposition = ComposeDraftGuards.attachmentDisposition(
            saveApplied: true, stagingDir: staging, previousDir: liveDir)
        #expect(disposition == .deleteSuperseded(dirName: liveDir))
        guard case .deleteSuperseded(let toDelete) = disposition else { return }
        #expect(toDelete != staging)
        DraftAttachmentStorage.deleteAttachments(dirName: toDelete, root: root)

        let live = try DraftAttachmentStorage.loadAttachments(dirName: staging, root: root)
        #expect(live.count == 2)
        guard live.count == 2 else { return }
        #expect(live.map(\.filename) == ["new-a.txt", "new-b.txt"])
        #expect(live[0].data == Data("aaa".utf8))
        #expect(live[1].data == Data("bbb".utf8))
        // The superseded directory is gone — and its absence is detected as a
        // referenced-but-missing directory, not as "no attachments".
        #expect(loadError({
            try DraftAttachmentStorage.loadAttachments(dirName: liveDir, root: root)
        }) != nil)
    }

    @Test("The post-commit cleanup can never name the directory the row now points at")
    func cleanupNeverNamesTheLiveDirectory() {
        // Degenerate guard: even if a staging name somehow equalled the previous
        // one, a committed save destroys nothing.
        #expect(ComposeDraftGuards.attachmentDisposition(
            saveApplied: true, stagingDir: "same-dir", previousDir: "same-dir") == .noCleanup)
        // First-ever save (no previous directory) destroys nothing.
        #expect(ComposeDraftGuards.attachmentDisposition(
            saveApplied: true, stagingDir: "fresh", previousDir: nil) == .noCleanup)
        // A committed drop-all destroys the superseded directory and nothing else.
        #expect(ComposeDraftGuards.attachmentDisposition(
            saveApplied: true, stagingDir: nil, previousDir: "old")
            == .deleteSuperseded(dirName: "old"))
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

    // MARK: - R11-A — path containment for every storage entry point
    //
    // INVARIANT (the system property, not the mechanism): no
    // `DraftAttachmentStorage` entry point may read, write, or delete outside the
    // storage root. `save` and `load` throw; `delete` is a no-op. The escape
    // primitive is real on upgraded installs — the WRITE side was ported to
    // `newStagingDirName()` but the DELETE side was not, so `DraftStore
    // .deleteAsync` still passes a raw draft id and every other call site passes
    // a persisted `attachmentsDirName` that on a `v1.6.38 → v3` upgrade holds
    // shipped's `draftId` value.
    //
    // ⚠️ TWO-SIDED, deliberately. The mirror-image fix — refuse any `dirName`
    // containing `/` — would make legacy nested-but-CONTAINED attachment
    // directories permanently unloadable and unreclaimable, i.e. silent loss of
    // user content, which is strictly worse than the containment bug. So the
    // contained-nesting cases below are not decoration: they are the half of the
    // invariant that a naive predicate breaks.

    /// The `DraftAttachmentStorageError` `body` threw, or nil if it threw
    /// something else or did not throw.
    private func storageError(_ body: () throws -> Void) -> DraftAttachmentStorageError? {
        do {
            try body()
            return nil
        } catch let error as DraftAttachmentStorageError {
            return error
        } catch {
            return nil
        }
    }

    @Test("A dirName that escapes the storage root is refused by save, load and delete")
    func escapingDirNameIsRefusedByEveryEntryPoint() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A sibling of the storage root: what a `..`-bearing name would reach.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("DraftAttachEscapee-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escaping = "../\(outside.lastPathComponent)"

        // SAVE must throw and must create nothing outside the root.
        let saveError = storageError {
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("aaa".utf8))],
                dirName: escaping, root: root)
        }
        guard case .escapesStorageRoot(let savedName)? = saveError else {
            Issue.record("expected .escapesStorageRoot from save, got \(String(describing: saveError))")
            return
        }
        #expect(savedName == escaping)
        #expect(!FileManager.default.fileExists(atPath: outside.path))

        // LOAD must throw rather than read bytes from outside the root. Plant a
        // real, readable attachment out there so a passing load would be a
        // genuine out-of-root read and not merely an ENOENT.
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("planted".utf8).write(to: outside.appendingPathComponent("0_planted.txt"))
        let loadFailure = storageError {
            _ = try DraftAttachmentStorage.loadAttachments(dirName: escaping, root: root)
        }
        guard case .escapesStorageRoot? = loadFailure else {
            Issue.record("expected .escapesStorageRoot from load, got \(String(describing: loadFailure))")
            return
        }

        // DELETE must be a no-op: the planted directory survives.
        DraftAttachmentStorage.deleteAttachments(dirName: escaping, root: root)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("0_planted.txt").path))
    }

    @Test("A legacy nested-but-contained dirName still saves, loads and deletes")
    func containedNestedDirNameStillRoundTrips() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Exactly the shape a shipped reply draft persisted: the raw draft id,
        // whose Message-ID local part legally contains `/`. Shipped's
        // `withIntermediateDirectories: true` really put the attachments there.
        let legacy = "reply:user@example.com:a/b/c@example.com"
        let attachments = [
            DraftAttachment(filename: "contract.pdf", mimeType: "application/pdf",
                            data: Data("legacy-contract".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: legacy, root: root)

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: legacy, root: root)
        #expect(loaded.count == 1)
        guard loaded.count == 1 else { return }
        #expect(loaded[0].filename == "contract.pdf")
        #expect(loaded[0].data == Data("legacy-contract".utf8))

        DraftAttachmentStorage.deleteAttachments(dirName: legacy, root: root)
        #expect(!FileManager.default.fileExists(
            atPath: DraftAttachmentStorage.dirURL(for: legacy, root: root).path))
    }

    @Test("A UUID staging name is unaffected and a root-resolving name is refused")
    func containmentPredicateBoundaries() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The ordinary production case is untouched.
        let staging = DraftAttachmentStorage.newStagingDirName()
        #expect(DraftAttachmentStorage.containedDirURL(for: staging, root: root)?.lastPathComponent
                == staging)

        // A name that resolves to the ROOT ITSELF is not a draft's slot, and a
        // recursive delete of it would take every other draft's attachments.
        #expect(DraftAttachmentStorage.containedDirURL(for: "", root: root) == nil)
        #expect(DraftAttachmentStorage.containedDirURL(for: ".", root: root) == nil)
        #expect(DraftAttachmentStorage.containedDirURL(for: "..", root: root) == nil)
        #expect(DraftAttachmentStorage.containedDirURL(for: "../..", root: root) == nil)
        #expect(DraftAttachmentStorage.containedDirURL(for: "a/../../b", root: root) == nil)

        // Contained nesting, including a `..` that stays inside, is allowed.
        #expect(DraftAttachmentStorage.containedDirURL(for: "a/b@x", root: root) != nil)
        #expect(DraftAttachmentStorage.containedDirURL(for: "a/../b", root: root) != nil)
    }
}
