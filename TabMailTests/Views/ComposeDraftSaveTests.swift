/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Compose's Save and the chat's new email write a draft through `ComposeDraftSave.run`. Against a
/// real database: what a first save, an update, a superseded save and a failed save leave in the
/// row and on disk. A failed or superseded save removes only the directory it staged; the live
/// row and its files stay as they were.
@Suite("Draft save shared by compose and the chat", .serialized, .processGlobalState)
@MainActor
struct ComposeDraftSaveTests {
    nonisolated private static let accountId = "compose-draft-save"
    nonisolated private static let generation = "generation"
    nonisolated private static let history = "edit-history-of-this-draft"

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
    }

    private struct SaveFailed: Error {}
    private struct ReadFailed: Error {}

    private func fixture() throws -> Fixture {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: Self.accountId, provider: .imap, pool: pool)
        return Fixture(pool: pool, directory: directory, previous: previous)
    }

    /// Removes the rows' directories and any `staged` one the test left, then the database.
    private func finish(_ fixture: Fixture, staged: [String?] = []) {
        let dirs = (try? fixture.pool.read { db in try Draft.fetchAll(db).compactMap(\.attachmentsDirName) }) ?? []
        for dir in dirs + staged.compactMap({ $0 }) { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft? {
        try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) }
    }

    private func dirExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: DraftAttachmentStorage.dirURL(for: name).path)
    }

    /// Every folder in the attachment store, staged or live. A listing that fails throws: it is
    /// never an empty store.
    private static func attachmentFolders() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: DraftAttachmentStorage.baseDir.path))
    }

    /// A file the store refuses to keep under its name (`AttachmentFilename.isSafeFileComponent`:
    /// a name is one path component).
    private static let refusedFile = DraftAttachment(filename: "notes/today.txt", mimeType: "text/plain", data: Data([5, 6]))

    private static let oldFile = DraftAttachment(filename: "old.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
    private static let newFile = DraftAttachment(filename: "new.txt", mimeType: "text/plain", data: Data([7, 8, 9]))

    /// A row as an earlier save left it, a minute ago: one attachment in its own directory, an AI
    /// edit history, already pushed to the server, saved under `generation`.
    private func earlierRow(_ fixture: Fixture, id: String) async throws -> Draft {
        let dirName = DraftAttachmentStorage.newStagingDirName()
        try DraftAttachmentStorage.saveAttachments([Self.oldFile], dirName: dirName)
        let updatedAt = Date().addingTimeInterval(-60).timeIntervalSince1970
        var draft = Draft(
            id: id, accountId: Self.accountId,
            toJSON: Draft.encodeStringArray(["old@example.com"]), ccJSON: Draft.encodeStringArray(["oldcc@example.com"]),
            bccJSON: Draft.encodeStringArray([]), subject: "Old subject", body: "Old words", replyToId: nil,
            isForward: false, editHistoryJSON: Self.history, createdAt: updatedAt, updatedAt: updatedAt,
            serverDraftId: "server-draft", serverPushStatus: "pushed", rfc822MessageId: nil, attachmentsDirName: dirName)
        draft.instanceEpoch = Self.generation
        let toInsert = draft
        try await fixture.pool.write { db in try toInsert.insert(db) }
        return draft
    }

    private static func fields(to: [String] = ["new@example.com"], body: String = "New words") -> ComposeDraftSave.Fields {
        ComposeDraftSave.Fields(
            to: to, cc: ["cc@example.com"], bcc: ["bcc@example.com"], subject: "New subject", body: body,
            replyTo: nil, isForward: false, isReplyAll: true)
    }

    @Test("A first save inserts the row with the editor's fields, its files staged under their own name, and is told there was no row")
    func firstSaveInserts() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-first-save"
        let now = Date().timeIntervalSince1970
        var seen: [Draft?] = []
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: now,
            fields: { existing in
                seen.append(existing)
                return Self.fields()
            },
            admit: { draft in try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: nil) })
        let savedRow = try await row(fixture, id)
        let saved = try #require(savedRow)
        let dir = try #require(saved.attachmentsDirName)
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dir)
        let loadedNames = loaded.map(\.filename)
        let loadedData = loaded.map(\.data)
        #expect(outcome == .committed(previousPushStatus: nil))
        #expect(seen.count == 1)
        guard seen.count == 1 else { return }
        #expect(seen[0] == nil, "the fields are given no row on a first save")
        #expect(saved.accountId == Self.accountId)
        #expect(saved.toArray == ["new@example.com"])
        #expect(saved.ccArray == ["cc@example.com"])
        #expect(saved.bccArray == ["bcc@example.com"])
        #expect(saved.subject == "New subject")
        #expect(saved.body == "New words")
        #expect(saved.isReplyAll)
        #expect(saved.isForward == false)
        #expect(saved.editHistoryJSON == nil)
        #expect(saved.updatedAt == now)
        #expect(saved.instanceEpoch == Self.generation)
        #expect(dir != id, "the files are staged under an opaque name, never the draft key")
        #expect(loadedNames == ["new.txt"])
        #expect(loadedData == [Self.newFile.data])
    }

    @Test("An update is given the row it read, keeps the row's edit history, marks the pushed copy changed, and removes the directory it replaced")
    func updateKeepsHistoryAndReplacesFiles() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-update"
        let earlier = try await earlierRow(fixture, id: id)
        let oldDir = try #require(earlier.attachmentsDirName)
        var seen: [Draft?] = []
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: Date().timeIntervalSince1970,
            fields: { existing in
                seen.append(existing)
                return Self.fields()
            },
            admit: { draft in
                try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        let savedRow = try await row(fixture, id)
        let saved = try #require(savedRow)
        let newDir = try #require(saved.attachmentsDirName)
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: newDir)
        let loadedNames = loaded.map(\.filename)
        let oldDirRemains = dirExists(oldDir)
        #expect(outcome == .committed(previousPushStatus: "pushed"))
        #expect(seen.count == 1)
        guard seen.count == 1 else { return }
        let seenBody = seen[0]?.body
        let seenDir = seen[0]?.attachmentsDirName
        #expect(seenBody == "Old words", "the fields are given the row read at the start")
        #expect(seenDir == oldDir)
        #expect(saved.body == "New words")
        #expect(saved.toArray == ["new@example.com"])
        #expect(saved.editHistoryJSON == Self.history, "the row's edit history is kept")
        #expect(saved.serverDraftId == "server-draft")
        #expect(saved.serverPushStatus == "dirty", "the pushed copy is marked changed so the next push sends it")
        #expect(newDir != oldDir)
        #expect(loadedNames == ["new.txt"])
        #expect(!oldDirRemains, "the replaced directory is removed once the save committed")
    }

    @Test("Dropping every file saves no directory and removes the old one once the save committed")
    func droppingAllFilesRemovesTheOldDirectory() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-drop-files"
        let earlier = try await earlierRow(fixture, id: id)
        let oldDir = try #require(earlier.attachmentsDirName)
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [], now: Date().timeIntervalSince1970,
            fields: { _ in Self.fields() },
            admit: { draft in
                try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        let savedRow = try await row(fixture, id)
        let saved = try #require(savedRow)
        let oldDirRemains = dirExists(oldDir)
        #expect(outcome == .committed(previousPushStatus: "pushed"))
        #expect(saved.attachmentsDirName == nil)
        #expect(!oldDirRemains)
    }

    @Test("A snapshot older than the row is superseded: its staged directory is removed and the live row and files are untouched")
    func supersededLeavesTheLiveRow() async throws {
        let fixture = try fixture()
        var staged: String?
        defer { finish(fixture, staged: [staged]) }
        let id = "compose-superseded"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: earlier.updatedAt - 1,
            fields: { _ in Self.fields() },
            admit: { draft in
                staged = draft.attachmentsDirName
                return try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let stagedDir = try #require(staged)
        let stagedRemains = dirExists(stagedDir)
        let live = try DraftAttachmentStorage.loadAttachments(dirName: liveDir)
        let liveData = live.map(\.data)
        #expect(outcome == .superseded)
        #expect(after.body == "Old words")
        #expect(after.updatedAt == earlier.updatedAt)
        #expect(after.attachmentsDirName == liveDir)
        #expect(after.serverPushStatus == "pushed")
        #expect(stagedDir != liveDir)
        #expect(!stagedRemains, "the superseded snapshot's staged directory is removed")
        #expect(liveData == [Self.oldFile.data], "the live files are untouched")
    }

    @Test("A save that throws removes only its staged directory and leaves the row and its files as they were")
    func failedSaveLeavesTheRow() async throws {
        let fixture = try fixture()
        var staged: String?
        defer { finish(fixture, staged: [staged]) }
        let id = "compose-failed"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: Date().timeIntervalSince1970,
            fields: { _ in Self.fields() },
            admit: { draft in
                staged = draft.attachmentsDirName
                throw SaveFailed()
            })
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let stagedDir = try #require(staged)
        let stagedRemains = dirExists(stagedDir)
        let live = try DraftAttachmentStorage.loadAttachments(dirName: liveDir)
        let liveData = live.map(\.data)
        var failed = false
        if case .saveFailed = outcome { failed = true }
        #expect(failed, "the save's failure is reported: \(outcome)")
        #expect(after.body == "Old words")
        #expect(after.updatedAt == earlier.updatedAt)
        #expect(after.attachmentsDirName == liveDir)
        #expect(after.editHistoryJSON == Self.history)
        #expect(stagedDir != liveDir)
        #expect(!stagedRemains, "the failed save's staged directory is removed")
        #expect(liveData == [Self.oldFile.data], "the live files are untouched")
    }

    @Test("A read that throws is not absence: the editor's fields are never asked for, nothing is admitted, and the row and its files stay as they were")
    func failedReadWritesNothing() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-read-failed"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        var asked = 0
        var admitted = 0
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: Date().timeIntervalSince1970,
            read: { _ in throw ReadFailed() },
            fields: { _ in
                asked += 1
                return Self.fields()
            },
            admit: { draft in
                admitted += 1
                return try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let live = try DraftAttachmentStorage.loadAttachments(dirName: liveDir)
        let liveData = live.map(\.data)
        #expect(outcome == .readFailed)
        #expect(asked == 0, "nothing is built from a read that did not happen")
        #expect(admitted == 0, "nothing is saved")
        #expect(after.body == "Old words")
        #expect(after.updatedAt == earlier.updatedAt)
        #expect(after.attachmentsDirName == liveDir)
        #expect(after.editHistoryJSON == Self.history)
        #expect(liveData == [Self.oldFile.data], "the live files are untouched")
    }

    @Test("The real row read failing in the database is a failed read too: nothing asked, admitted or staged, the row and its files as they were")
    func productionReadFailureWritesNothing() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-production-read-failed"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        let foldersBefore = try Self.attachmentFolders()
        #expect(foldersBefore.contains(liveDir), "control: the listing sees the row's own folder")
        let table = Draft.databaseTableName
        let hidden = "\(table)_hidden_by_test"
        try await fixture.pool.write { db in try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(hidden)") }
        var asked = 0
        var admitted = 0
        // The production read (`ComposeDraftSave.readRow`): no read is passed.
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: Date().timeIntervalSince1970,
            fields: { _ in
                asked += 1
                return Self.fields()
            },
            admit: { draft in
                admitted += 1
                return try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        try await fixture.pool.write { db in try db.execute(sql: "ALTER TABLE \(hidden) RENAME TO \(table)") }
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let live = try DraftAttachmentStorage.loadAttachments(dirName: liveDir)
        let liveData = live.map(\.data)
        #expect(outcome == .readFailed, "a read the database refused is not an absent row")
        #expect(asked == 0)
        #expect(admitted == 0)
        #expect(after.body == "Old words")
        #expect(after.updatedAt == earlier.updatedAt)
        #expect(after.attachmentsDirName == liveDir)
        #expect(liveData == [Self.oldFile.data])
        let foldersAfter = try Self.attachmentFolders()
        #expect(foldersAfter == foldersBefore, "no staging folder is left behind")
    }

    @Test("Files the store refuses to stage are a failed save: nothing asked or admitted, no folder left, the row and its files as they were")
    func refusedStagingWritesNothing() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let id = "compose-staging-refused"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        let foldersBefore = try Self.attachmentFolders()
        #expect(foldersBefore.contains(liveDir), "control: the listing sees the row's own folder")
        let refused = AttachmentFilename.isSafeFileComponent(Self.refusedFile.filename)
        #expect(!refused, "control: the store refuses this name")
        var asked = 0
        var admitted = 0
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile, Self.refusedFile],
            now: Date().timeIntervalSince1970,
            fields: { _ in
                asked += 1
                return Self.fields()
            },
            admit: { draft in
                admitted += 1
                return try await DraftStore.shared.saveAsync(draft, epoch: Self.generation, expectedPredecessor: Self.generation)
            })
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let live = try DraftAttachmentStorage.loadAttachments(dirName: liveDir)
        let liveData = live.map(\.data)
        let foldersAfter = try Self.attachmentFolders()
        var notStaged = false
        if case .attachmentsNotStaged = outcome { notStaged = true }
        #expect(notStaged, "the refusal is reported as files not staged: \(outcome)")
        #expect(asked == 0, "the editor's fields are not taken for a save that cannot happen")
        #expect(admitted == 0, "nothing is saved")
        #expect(after.body == "Old words")
        #expect(after.updatedAt == earlier.updatedAt)
        #expect(after.attachmentsDirName == liveDir, "the row still names its own files")
        #expect(after.editHistoryJSON == Self.history)
        #expect(liveData == [Self.oldFile.data], "the live files are untouched")
        #expect(foldersAfter == foldersBefore, "no staging folder is left behind")
    }

    @Test("A save another editor's generation refuses is a failed save: the row and files stay as they were")
    func refusedGenerationLeavesTheRow() async throws {
        let fixture = try fixture()
        var staged: String?
        defer { finish(fixture, staged: [staged]) }
        let id = "compose-refused"
        let earlier = try await earlierRow(fixture, id: id)
        let liveDir = try #require(earlier.attachmentsDirName)
        let outcome = await ComposeDraftSave.run(
            draftId: id, accountId: Self.accountId, attachments: [Self.newFile], now: Date().timeIntervalSince1970,
            fields: { _ in Self.fields() },
            admit: { draft in
                staged = draft.attachmentsDirName
                // This editor saw no earlier generation, but the row carries one.
                return try await DraftStore.shared.saveAsync(draft, epoch: "another-generation", expectedPredecessor: nil)
            })
        let afterRow = try await row(fixture, id)
        let after = try #require(afterRow)
        let stagedDir = try #require(staged)
        let stagedRemains = dirExists(stagedDir)
        let refusal = DraftStore.DraftEpochAdmissionError.staleOrReserved.localizedDescription
        #expect(outcome == .saveFailed(reason: refusal))
        #expect(after.body == "Old words")
        #expect(after.instanceEpoch == Self.generation)
        #expect(after.attachmentsDirName == liveDir)
        #expect(!stagedRemains)
    }
}
