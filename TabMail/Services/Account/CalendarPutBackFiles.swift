//
//  CalendarPutBackFiles.swift
//  TabMail
//
//  The files an Outlook edit of every occurrence saves before its write, so it can attach them
//  again after the write erases them (#718).
//

import Foundation
import GRDB

/// Where the files of a queued calendar edit wait (`SavedFiles`, `PutBackFile`): beside the
/// database, one directory per operation (its row id), one file per distinct content, named by
/// its SHA-256 (`SavedFileName`):
/// `<database directory>/calendar_put_back/<operation id>/<sha256 hex>`.
///
/// As the Outbox keeps a queued send's attachments: the operation's record (in the database)
/// names the files, and their bytes are files, written atomically, in the app's default data
/// protection class and in the device backup, as the database is (the row and its files restore
/// together).
///
/// The bytes are the only copy of a file the calendar erased, so they are deleted only:
/// - one by one (`release`), once the record that no longer names them is kept: a read showed
///   the file back on its occurrence, the occurrence is proven gone, or the saved copy is
///   missing or corrupt;
/// - a whole operation's (`remove`), when the user removes its account or dismisses its failure
///   after being warned, or the whole store (`removeAll`) when the app's data is wiped;
/// - by the drain-start sweep (`sweep`), for a directory whose operation row no longer exists;
/// - a whole operation's (`remove`), when it is retired holding none (`held`): its series' write
///   was never sent or was refused, so the calendar still holds every file, or its record names
///   none.
/// Every other path that deletes an operation row spares a row that holds saved files (`held`).
enum CalendarPutBackFiles {
    /// The files operation `row` holds saved on this device: those its record names
    /// (`SeriesEditRecord.files`) once its series' write was sent (`SeriesEditRecord.Write`), while
    /// any of its bytes are here. Before the write is sent, or once Graph refused it, the calendar
    /// still holds every file, so the row holds none, whatever its directory holds. Empty when the
    /// row has no record this build can read. The one definition of a row that holds files: the
    /// inbox banner and its warning, account removal, the reclaim of old failed rows and the
    /// queue's retirement all read it.
    static func held(_ row: PendingCalendarOperation) -> [PutBackFile] {
        guard let record = (try? SeriesEditRecord.stored(row.arguments)) ?? nil, record.write != .notSent,
              !record.files.isEmpty, holdsBytes(row.id) else { return [] }
        return record.files
    }

    /// The directory's name beside the database.
    static let directoryName = "calendar_put_back"

    /// The store's directory, beside the database in use.
    static func baseDirectory() -> URL {
        URL(fileURLWithPath: AppDatabase.rawPool.path).deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The directory of operation `opId`, nil unless the id is a UUID (so it is one safe path
    /// component).
    static func directory(of opId: String) -> URL? {
        guard UUID(uuidString: opId) != nil else { return nil }
        return baseDirectory().appendingPathComponent(opId, isDirectory: true)
    }

    struct InvalidOperationId: Error {}

    /// `SavedFiles` for the operation `opId`.
    static func savedFiles(opId: String) -> SavedFiles {
        SavedFiles(
            save: { data in try save(data, opId: opId) },
            load: { name in try load(name, opId: opId) },
            release: { name in try release(name, opId: opId) })
    }

    /// Keeps `data` for operation `opId` and returns its name. Content already kept under its name
    /// is not written again.
    static func save(_ data: Data, opId: String) throws -> String {
        guard let dir = directory(of: opId) else { throw InvalidOperationId() }
        let name = SavedFileName.of(data)
        let file = dir.appendingPathComponent(name, isDirectory: false)
        if let held = try? Data(contentsOf: file), SavedFileName.of(held) == name { return name }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalendarPutBack] saved \(data.count) bytes for op \(opId)")
        }
        return name
    }

    /// The bytes kept under `name` for operation `opId`, checked against it. Throws
    /// `SavedFiles.Missing` when there are none or they no longer match.
    static func load(_ name: String, opId: String) throws -> Data {
        guard SavedFileName.isValid(name), let dir = directory(of: opId) else { throw SavedFiles.Missing() }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name, isDirectory: false), options: .mappedIfSafe),
              SavedFileName.of(data) == name else { throw SavedFiles.Missing() }
        return data
    }

    /// Deletes the bytes kept under `name` for operation `opId` (one exact file; nothing when it
    /// is not there), then the operation's directory once it is empty.
    static func release(_ name: String, opId: String) throws {
        guard SavedFileName.isValid(name), let dir = directory(of: opId) else { return }
        let file = dir.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        removeEmptyDirectory(of: opId)
    }

    /// Whether operation `opId` holds saved bytes.
    static func holdsBytes(_ opId: String) -> Bool {
        guard let dir = directory(of: opId) else { return false }
        return !savedNames(in: dir).isEmpty
    }

    /// The ids of every operation that holds saved bytes.
    static func heldOperationIds() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: baseDirectory().path)) ?? []
        return Set(entries.filter(holdsBytes))
    }

    /// The names of the files saved in `dir`.
    private static func savedNames(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter(SavedFileName.isValid)
    }

    /// Removes operation `opId`'s directory when it holds nothing; leaves one that does.
    static func removeEmptyDirectory(of opId: String) {
        guard let dir = directory(of: opId),
              ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Deletes every file kept for operation `opId`. Only for the user's warned removal of its
    /// account or warned dismissal of its failure, after the row's deletion committed, or for an
    /// operation retired holding none (`held`).
    static func remove(opId: String) {
        guard let dir = directory(of: opId) else { return }
        try? FileManager.default.removeItem(at: dir)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalendarPutBack] removed the saved files of op \(opId)")
        }
    }

    /// Deletes the whole store: the app's data is wiped.
    static func removeAll() {
        try? FileManager.default.removeItem(at: baseDirectory())
    }

    /// Removes every entry of the store that is not the directory of an operation row in
    /// `keeping` (non-UUID names and stray files included). Run at the start of a drain with
    /// every row's id, of any status, so only bytes whose row is gone are removed.
    static func sweep(keeping: Set<String>) {
        let base = baseDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for entry in entries where !keeping.contains(entry) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(entry))
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CalendarPutBack] swept \(entry): no operation holds it")
            }
        }
    }

    /// The saved files of operation `opId` under the names the record gives them, copied into a
    /// fresh temporary directory for the share sheet ("Save File"). Entries naming the same
    /// bytes twice are copied once per name; a name used twice gets a numbered copy.
    static func exportCopies(of files: [PutBackFile], opId: String) throws -> [URL] {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var urls: [URL] = []
        var used: Set<String> = []
        for file in files {
            let data = try load(file.sha256, opId: opId)
            let last = (file.name as NSString).lastPathComponent
            let base = last.isEmpty || last == "." || last == ".." || last.hasPrefix(".") ? DraftReadConfig.unnamedAttachmentFilename : last
            var name = base
            var n = 1
            while used.contains(name) {
                n += 1
                let ext = (base as NSString).pathExtension
                let stem = (base as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            }
            used.insert(name)
            let url = out.appendingPathComponent(name, isDirectory: false)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}
