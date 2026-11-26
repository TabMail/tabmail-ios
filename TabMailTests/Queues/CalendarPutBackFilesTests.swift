/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// The files an Outlook edit of every occurrence saves on the device until it has attached them
// again (#718, `CalendarPutBackFiles`) are the only copy of what the user had attached to events
// changed on their own. **INVARIANT:** their bytes are deleted only by a read showing the file back,
// a proven-gone occurrence, the user's warned dismissal of the failed change, or the user's warned
// removal of its account; every other path that deletes calendar operation rows spares a row that
// holds saved bytes, and the store holds nothing whose row is gone.

@Suite("Saved put-back files outlive every path but the user's own (#718)", .serialized, .processGlobalState)
@MainActor
struct CalendarPutBackFilesTests {

    private static let notes = Data("own notes".utf8)

    /// A row of `accountId` whose record names `files` of `bytes`, its series' write at `write`,
    /// saved on the device when `saved`; failed (seen on its card) unless `failed` is false, and
    /// queued `ageDays` days ago.
    private static func row(
        _ db: CalendarQueueTestDatabase, accountId: String, files names: [String] = ["notes.txt"], bytes: Data = notes,
        write: SeriesEditRecord.Write = .landed, saved: Bool = true, failed: Bool = true, ageDays: Int = 0
    ) async throws -> PendingCalendarOperation {
        let sha = SavedFileName.of(bytes)
        let files = names.map {
            PutBackFile(occurrence: "occ-1", name: $0, contentType: "text/plain", isInline: false, contentId: nil, sha256: sha)
        }
        let recordData = try JSONSerialization.data(
            withJSONObject: [SeriesEditRecord.argumentKey: SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: files, write: write, seriesEtag: "W/\"ser-1-0\"").jsonObject])
        var args = try JSONDecoder().decode([String: JSONValue].self, from: recordData)
        args["edit_scope"] = .string("all")
        var op = PendingCalendarOperation(
            operationType: .edit, accountId: accountId, eventId: "ser-1", calendarId: "primary", arguments: args, eventTitle: "Planning")
        if failed {
            op.status = PendingStatus.failed.rawValue
            op.failureReason = PutBackFile.notRestoredMessage(files.count)
            op.setReservedArguments([
                PendingCalendarOperation.failureKindKey: .string(CalendarFailureKind.unsupported.rawValue),
                PendingCalendarOperation.failureSeenKey: .bool(true),
            ])
        }
        op.createdAt = Calendar.current.date(byAdding: .day, value: -ageDays, to: Date()) ?? Date()
        try await db.pool.write { [op] d in try op.insert(d) }
        if saved { _ = try CalendarPutBackFiles.save(bytes, opId: op.id) }
        return op
    }

    private static func ids(_ db: CalendarQueueTestDatabase) async throws -> Set<String> {
        try await db.pool.read { d in try String.fetchSet(d, sql: "SELECT id FROM pendingCalendarOperation") }
    }

    @Test("the reclaim of old failed rows spares a row that holds saved bytes, and reclaims one that holds none")
    func reclaimSparesAHeldRow() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-reclaim")
        defer { db.finish() }
        let old = SyncConfig.retiredCalendarOpRetentionDays + 10
        let held = try await Self.row(db, accountId: "put-back-reclaim", ageDays: old)
        let plain = try await Self.row(db, accountId: "put-back-reclaim", saved: false, ageDays: old)
        SyncEngine.runReclaimRetiredCalendarOps(dbPool: PrioritizedDatabase(pool: db.pool))
        let left = try await Self.ids(db)
        #expect(left == [held.id], "rows left: \(left); held \(held.id) plain \(plain.id)")
        #expect(CalendarPutBackFiles.holdsBytes(held.id), "the held row's bytes went")
    }

    @Test("a row whose series' write was never sent holds no files, whatever its directory holds: the inbox shows it as an ordinary failure, account removal counts none, and the reclaim takes it")
    func unsentWriteHoldsNoFiles() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-unsent")
        defer { db.finish() }
        let old = SyncConfig.retiredCalendarOpRetentionDays + 10
        let unsent = try await Self.row(db, accountId: "put-back-unsent", write: .notSent, ageDays: old)
        let sent = try await Self.row(db, accountId: "put-back-unsent", write: .sent, ageDays: old)
        #expect(CalendarPutBackFiles.held(unsent).isEmpty && CalendarPutBackFiles.held(sent).count == 1)
        let store = LateCalendarFailureStore()
        await store.reload()
        // Both were seen on their cards: only the one holding files stays shown.
        #expect(store.failures.map(\.id) == [sent.id], "shown: \(store.failures.map(\.id))")
        let found = await LateCalendarFailureStore.heldFiles(accountId: "put-back-unsent")
        #expect(found.map(\.opId) == [sent.id], "\(found.map(\.opId))")
        SyncEngine.runReclaimRetiredCalendarOps(dbPool: PrioritizedDatabase(pool: db.pool))
        let left = try await Self.ids(db)
        #expect(left == [sent.id], "rows left: \(left); unsent \(unsent.id) sent \(sent.id)")
    }

    @Test("a row whose record this build can't read holds every file its directory holds: retired by a refusal it keeps them, the reclaim spares it, and the banner offers them to save")
    func unreadableRecordHoldsItsFiles() async throws {
        let account = "put-back-unreadable"
        let db = try CalendarQueueTestDatabase(accountId: account)
        defer { db.finish() }
        let file = PutBackFile(
            occurrence: "occ-1", name: "notes.txt", contentType: "text/plain", isInline: false, contentId: nil,
            sha256: SavedFileName.of(Self.notes))
        var record = SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: [file], write: .landed, seriesEtag: "W/\"ser-1-1\"").jsonObject
        record["version"] = SeriesEditRecord.version + 1
        var args = try JSONDecoder().decode(
            [String: JSONValue].self, from: try JSONSerialization.data(withJSONObject: [SeriesEditRecord.argumentKey: record]))
        // A zone no resolver knows: the drain refuses the change for good before it reads the record.
        args["edit_scope"] = .string("all")
        args["timezone"] = .string("Not/A_Zone")
        args["title"] = .string("Retitled")
        var op = PendingCalendarOperation(
            operationType: .edit, accountId: account, eventId: "ser-1", calendarId: "primary", arguments: args, eventTitle: "Planning")
        op.createdAt = Calendar.current.date(byAdding: .day, value: -(SyncConfig.retiredCalendarOpRetentionDays + 10), to: Date()) ?? Date()
        try await db.pool.write { [op] d in try op.insert(d) }
        let opId = op.id
        _ = try CalendarPutBackFiles.save(Self.notes, opId: opId)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        FakeGraphCalendar([]).install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: provider)
        await AccountManager.shared.drainCalendarQueue()
        await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account)

        let retired = try #require(try await db.pool.read { d in try PendingCalendarOperation.fetchOne(d, key: opId) })
        #expect(retired.status == PendingStatus.failed.rawValue, "the row: \(retired.status) \(retired.failureReason ?? "")")
        #expect(CalendarPutBackFiles.holdsBytes(opId), "retiring the row deleted its bytes")
        #expect(CalendarPutBackFiles.held(retired) == [CalendarPutBackFiles.unnamed(SavedFileName.of(Self.notes))], "held: \(CalendarPutBackFiles.held(retired))")
        SyncEngine.runReclaimRetiredCalendarOps(dbPool: PrioritizedDatabase(pool: db.pool))
        #expect(try await Self.ids(db) == [opId], "the reclaim took the row")
        #expect(CalendarPutBackFiles.holdsBytes(opId), "the reclaim's bytes went")
        let store = LateCalendarFailureStore()
        await store.reload()
        let failure = try #require(store.failures.first)
        #expect(failure.holdsFiles && failure.heldFiles.count == 1, "\(failure)")
        let urls = try CalendarPutBackFiles.exportCopies(of: failure.heldFiles, opId: failure.id)
        #expect(urls.map(\.lastPathComponent) == [DraftReadConfig.unnamedAttachmentFilename], "\(urls)")
        #expect(try urls.map { try Data(contentsOf: $0) } == [Self.notes])
    }

    @Test("Settings' local index wipe and a release boundary leave calendar rows and their saved bytes")
    func wipesLeaveHeldRows() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-wipe")
        defer { db.finish() }
        let held = try await Self.row(db, accountId: "put-back-wipe")
        try await db.pool.write { d in try SyncEngine.localIndexWipeTxn(d) }
        try await db.pool.write { d in
            try d.execute(sql: "INSERT INTO appReleaseStamp (id, release) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET release = excluded.release",
                          arguments: ["an earlier release"])
        }
        #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: db.pool, currentRelease: AppDatabase.currentAppRelease),
                "the boundary was not crossed")
        #expect(try await Self.ids(db) == [held.id], "the held row went")
        #expect(CalendarPutBackFiles.holdsBytes(held.id), "the held row's bytes went")
    }

    @Test("the drain-start sweep removes saved bytes whose row is gone and stray entries, and keeps every row's, queued or failed")
    func drainStartSweepRemovesOnlyOrphans() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-sweep")
        defer { db.finish() }
        let held = try await Self.row(db, accountId: "put-back-sweep")
        let orphan = UUID().uuidString
        _ = try CalendarPutBackFiles.save(Self.notes, opId: orphan)
        let stray = CalendarPutBackFiles.baseDirectory().appendingPathComponent("not-an-operation")
        try Data("stray".utf8).write(to: stray)
        await AccountManager.shared.drainCalendarQueue()
        #expect(CalendarPutBackFiles.holdsBytes(held.id), "the failed row's bytes went")
        #expect(!CalendarPutBackFiles.holdsBytes(orphan) && CalendarPutBackFiles.directory(of: orphan).map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                "the orphan's bytes stayed")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "the stray entry stayed")
    }

    @Test("a failed row holding saved bytes is shown, seen or not, until the user dismisses it; dismissing deletes its bytes")
    func failureStoreShowsHeldRowUntilDismissed() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-banner")
        defer { db.finish() }
        let held = try await Self.row(db, accountId: "put-back-banner")
        _ = try await Self.row(db, accountId: "put-back-banner", saved: false)
        let store = LateCalendarFailureStore()
        await store.reload()
        #expect(store.failures.map(\.id) == [held.id], "shown: \(store.failures.map(\.id))")
        let failure = try #require(store.failures.first)
        #expect(failure.holdsFiles && failure.heldFiles.count == 1, "\(failure)")
        #expect(failure.bannerText.contains(PutBackFile.notRestoredMessage(1)), "\(failure.bannerText)")
        await store.dismiss(failure)
        #expect(!(try await Self.ids(db)).contains(held.id), "the row stayed")
        #expect(!CalendarPutBackFiles.holdsBytes(held.id) && CalendarPutBackFiles.directory(of: held.id).map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                "the bytes stayed")
        #expect(store.failures.isEmpty, "still shown: \(store.failures.map(\.id))")
    }

    @Test("the files an account's removal deletes are its operations' saved ones, and Save File copies them under their own names")
    func accountHeldFilesAndExport() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-account")
        defer { db.finish() }
        let held = try await Self.row(db, accountId: "put-back-account", files: ["notes.txt", "notes.txt"], failed: false)
        _ = try await Self.row(db, accountId: "put-back-account", saved: false)
        let found = await LateCalendarFailureStore.heldFiles(accountId: "put-back-account")
        #expect(found.map(\.opId) == [held.id] && found.first?.files.count == 2, "\(found.map(\.opId))")
        let urls = try LateCalendarFailureStore.exportFiles(found)
        #expect(urls.map(\.lastPathComponent) == ["notes.txt", "notes 2.txt"], "\(urls)")
        #expect(try urls.map { try Data(contentsOf: $0) } == [Self.notes, Self.notes])
    }

    @Test("save, load and release: content is checked by its name, saved once, and released one file at a time")
    func saveLoadRelease() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-store")
        defer { db.finish() }
        let opId = UUID().uuidString
        let name = try CalendarPutBackFiles.save(Self.notes, opId: opId)
        #expect(name == SavedFileName.of(Self.notes) && SavedFileName.isValid(name))
        #expect(try CalendarPutBackFiles.save(Self.notes, opId: opId) == name)
        #expect(try CalendarPutBackFiles.load(name, opId: opId) == Self.notes)
        #expect(CalendarPutBackFiles.heldOperationIds() == [opId])
        // A changed copy is no copy.
        let dir = try #require(CalendarPutBackFiles.directory(of: opId))
        try Data("changed".utf8).write(to: dir.appendingPathComponent(name))
        #expect(throws: SavedFiles.Missing.self) { try CalendarPutBackFiles.load(name, opId: opId) }
        #expect(throws: SavedFiles.Missing.self) { try CalendarPutBackFiles.load("../\(name)", opId: opId) }
        try CalendarPutBackFiles.release(name, opId: opId)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "the empty directory stayed")
        #expect(throws: CalendarPutBackFiles.InvalidOperationId.self) { try CalendarPutBackFiles.save(Self.notes, opId: "../x") }
    }

    @Test("Save File names a copy by its last path component, and a hidden or empty name as an unnamed attachment")
    func exportNamesAreSafe() async throws {
        let db = try CalendarQueueTestDatabase(accountId: "put-back-names")
        defer { db.finish() }
        let opId = UUID().uuidString
        let sha = try CalendarPutBackFiles.save(Self.notes, opId: opId)
        let files = ["../../evil.txt", ".hidden", "", "a.txt", "a.txt"].map {
            PutBackFile(occurrence: "occ-1", name: $0, contentType: "text/plain", isInline: false, contentId: nil, sha256: sha)
        }
        let urls = try CalendarPutBackFiles.exportCopies(of: files, opId: opId)
        let unnamed = DraftReadConfig.unnamedAttachmentFilename
        let stem = (unnamed as NSString).deletingPathExtension
        let ext = (unnamed as NSString).pathExtension
        let second = ext.isEmpty ? "\(stem) 2" : "\(stem) 2.\(ext)"
        #expect(urls.map(\.lastPathComponent) == ["evil.txt", unnamed, second, "a.txt", "a 2.txt"], "\(urls)")
        #expect(Set(urls.map { $0.deletingLastPathComponent() }).count == 1, "copies left their directory: \(urls)")
    }
}
