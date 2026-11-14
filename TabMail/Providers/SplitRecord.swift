/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What a "this and following" split has already written, kept on its queued operation so a
/// retry knows it (#601). `splitSeries` hands it to its recorder once the new part's create is
/// confirmed and BEFORE it caps the series, so a retry after a failed or lost cap finds it and
/// does not create the new part again:
/// - `seriesId`: the series the split caps;
/// - `newPartId`: the new part the split created (Google and Outlook: the event id; CalDAV: the
///   resource path);
/// - `splitAt`: where the split cuts the series (`SplitCarry.cut`), a naive wall clock in the
///   operation's zone: the place of the occurrence named, or, for an occurrence moved from its
///   place, the first place of the series at or after where it starts now (#687); "" on the
///   record of an edit past the series' last place (`isPastEnd`);
/// - `mode`: whether the split carries the later exceptions into the new part or resets them
///   (`SplitCarry.Mode`, #563);
/// - `fields`: the names of the fields the edit set, which overwrite a carried occurrence's own;
/// - `namedPlace`, `namedStart`: the place and the start of the occurrence named (`SplitCarry.key`),
///   which sort the series' exceptions around the cut (`SplitCarry.partition`); nil on a record
///   kept before they were, read as an occurrence named at the cut;
/// - `edits`: the place of each occurrence edited where it is on the old series
///   (`SplitCarry.Parts.edited`) and the start it is moved to ("" when it keeps its own), so a
///   retry writes each once (`SplitCarry.edits(of:targets:length:fields:)`);
/// - `editLength`: on the record of an edit past the series' end that sets the end, the length
///   it gives each occurrence it edits, so a retry ends each as the first attempt did.
///
/// An edit named at an occurrence moved past the series' last place (`SplitCarry.Cut.pastEnd`)
/// writes no new part and no cap, only the edits of the occurrences shown from the one named on.
/// Google and Outlook write those one by one, so they keep a record too (`pastEnd`) before the
/// first: `splitAt` is "", `newPartId` is the occurrence named (an id only; no new part is made, so the edit answers with no new series id), and the targets are absolute, so a retry
/// (`CalendarProvider.finishShownEdit`) never moves one twice and never looks for the one named
/// where it was.
/// It holds ids, instants, the mode and field names only, no event content (ADR-004): a
/// retry re-reads what it carries from the series, which is untouched until the cap but for the
/// occurrences it edits, whose targets it keeps.
///
/// A retry that finds the record asks the calendar whether the new part is still there
/// (`CalendarProvider.eventExists`). When it is, it only finishes the cap
/// (`CalendarProvider.finishSplit`); when the user deleted it, the change is refused with
/// `newPartDeleted`, and neither the new part nor the cap is written again.
struct SplitRecord: Sendable, Equatable {
    let seriesId: String
    let newPartId: String
    let splitAt: String
    let mode: SplitCarry.Mode
    let fields: Set<SplitCarry.Field>
    var namedPlace: String?
    var namedStart: String?
    var edits: [String: String] = [:]
    var editLength: TimeInterval?

    /// Whether this is the record of an edit past the series' last place (`pastEnd`).
    var isPastEnd: Bool { splitAt.isEmpty }

    /// The record of an edit past the series' last place: no new part, no cap, only `edits`.
    static func pastEnd(
        seriesId: String, namedId: String, fields: Set<SplitCarry.Field>, namedPlace: String, namedStart: String,
        edits: [String: String], editLength: TimeInterval?
    ) -> SplitRecord {
        var record = SplitRecord(
            seriesId: seriesId, newPartId: namedId, splitAt: "", mode: .carry, fields: fields,
            namedPlace: namedPlace, namedStart: namedStart, edits: edits)
        record.editLength = editLength
        return record
    }

    /// The reserved key in `PendingCalendarOperation.argumentsJSON`. Only the queue writes it
    /// (`AccountManager.recordSplit`); a tool call that carries it has it removed when the
    /// operation is queued.
    static let argumentKey = "_split_record"

    /// The reserved key in `PendingCalendarOperation.argumentsJSON` for when the calendar first
    /// answered "not found" for a new part it had reported as already created
    /// (`SplitRecorder.partNotFound`), in seconds since 1970. Only the queue writes it
    /// (`AccountManager.noteSplitPartNotFound`); a tool call that carries it has it removed when
    /// the operation is queued.
    static let partNotFoundSinceKey = "_split_part_not_found_since"

    private static let seriesKey = "series_id"
    private static let newPartKey = "new_part_id"
    private static let splitAtKey = "split_at"
    private static let modeKey = "mode"
    private static let fieldsKey = "fields"
    private static let namedPlaceKey = "named_place"
    private static let namedStartKey = "named_start"
    private static let editsKey = "edits"
    private static let editLengthKey = "edit_length"

    /// The refusal when the new part of an unfinished split is gone.
    static let newPartDeleted = "This change to the repeating event wasn't finished because its new part was deleted. Check the event's later occurrences, and make the change again if you still want it."

    init(
        seriesId: String, newPartId: String, splitAt: String, mode: SplitCarry.Mode, fields: Set<SplitCarry.Field>,
        namedPlace: String? = nil, namedStart: String? = nil, edits: [String: String] = [:]
    ) {
        self.seriesId = seriesId
        self.newPartId = newPartId
        self.splitAt = splitAt
        self.mode = mode
        self.fields = fields
        self.namedPlace = namedPlace
        self.namedStart = namedStart
        self.edits = edits
    }

    /// The record in a queued operation's arguments, or nil when it has none.
    init?(_ arguments: [String: JSONValue]) {
        guard case .dictionary(let d)? = arguments[Self.argumentKey],
              case .string(let series)? = d[Self.seriesKey],
              case .string(let part)? = d[Self.newPartKey],
              case .string(let at)? = d[Self.splitAtKey],
              case .string(let modeName)? = d[Self.modeKey], let mode = SplitCarry.Mode(rawValue: modeName),
              case .array(let names)? = d[Self.fieldsKey] else { return nil }
        var fields = Set<SplitCarry.Field>()
        for name in names {
            guard case .string(let text) = name, let field = SplitCarry.Field(rawValue: text) else { return nil }
            fields.insert(field)
        }
        var place: String?
        var start: String?
        if case .string(let text)? = d[Self.namedPlaceKey] { place = text }
        if case .string(let text)? = d[Self.namedStartKey] { start = text }
        var edits: [String: String] = [:]
        if case .dictionary(let targets)? = d[Self.editsKey] {
            for (at, target) in targets {
                guard case .string(let text) = target else { return nil }
                edits[at] = text
            }
        }
        self.init(seriesId: series, newPartId: part, splitAt: at, mode: mode, fields: fields,
                  namedPlace: place, namedStart: start, edits: edits)
        switch d[Self.editLengthKey] {
        case .int(let seconds)?: editLength = TimeInterval(seconds)
        case .double(let seconds)?: editLength = seconds
        case nil, .null?: break
        default: return nil
        }
    }

    /// The operation the record was for is no longer queued, so the record was not kept.
    struct OperationGone: Error {}

    /// The record as a queued operation's argument (`argumentKey`).
    var argument: JSONValue {
        var d: [String: JSONValue] = [
            Self.seriesKey: .string(seriesId), Self.newPartKey: .string(newPartId), Self.splitAtKey: .string(splitAt),
            Self.modeKey: .string(mode.rawValue), Self.fieldsKey: .array(fields.sorted().map { .string($0.rawValue) }),
            Self.editsKey: .dictionary(edits.mapValues { .string($0) }),
        ]
        if let namedPlace { d[Self.namedPlaceKey] = .string(namedPlace) }
        if let namedStart { d[Self.namedStartKey] = .string(namedStart) }
        if let editLength { d[Self.editLengthKey] = .double(editLength) }
        return .dictionary(d)
    }

    /// The record as stored under `argumentKey`.
    var jsonObject: [String: Any] {
        var d: [String: Any] = [Self.seriesKey: seriesId, Self.newPartKey: newPartId, Self.splitAtKey: splitAt,
                                Self.modeKey: mode.rawValue, Self.fieldsKey: fields.sorted().map(\.rawValue), Self.editsKey: edits]
        if let namedPlace { d[Self.namedPlaceKey] = namedPlace }
        if let namedStart { d[Self.namedStartKey] = namedStart }
        if let editLength { d[Self.editLengthKey] = editLength }
        return d
    }
}

/// What a split keeps on the queued operation that is splitting (#601).
struct SplitRecorder: Sendable {
    /// Keeps a `SplitRecord` with the operation. A throw stops the split before the cap: the
    /// cap is written only once the record is kept.
    let keep: @Sendable (SplitRecord) async throws -> Void

    /// Notes that the calendar answered "not found" for a new part it had reported as already
    /// created, and returns how long ago, in seconds, it first answered so for this operation
    /// (zero the first time). The first time is kept on the operation, so the answer counts
    /// from the first attempt that got it, across retries and launches.
    let partNotFound: @Sendable () async throws -> TimeInterval

    /// Keeps `record` (`keep`).
    func callAsFunction(_ record: SplitRecord) async throws {
        try await keep(record)
    }
}

/// What an edit of every occurrence must put back after its write, kept on its queued operation
/// BEFORE the write (#718), so a retry can put it back too. Outlook resets a series' changed and
/// deleted occurrences on any change of its time, its end alone included, where Google Calendar
/// keeps them (measured); a retry after a lost answer would read the series already reset and
/// find nothing to put back, so what it puts back is read before the write and kept here.
/// - `seriesId`: the series the edit writes;
/// - `capture`: what the calendar read, in its own form, opaque to the queue
///   (`ExchangeCalendarProvider.updateSeries`).
///
/// - `files`: the files a changed occurrence held of its own (added, not copies of the series'),
///   which the write erases with the occurrence's other values (measured 2026-11-14) and the
///   put-back attaches again (`PutBackFile`). Their bytes are saved on the device beside the
///   database (`SavedFiles`, `CalendarPutBackFiles`); this list is the ledger of the ones not yet
///   restored: an entry leaves it, in a record kept BEFORE its bytes are released, once a read of
///   the occurrence shows the file there, or the occurrence is proven gone.
///
/// Unlike `SplitRecord`, it holds event content: the changed occurrences' own titles, notes,
/// places and guests, which the write erases on the server and only this copy can put back. It
/// lives on the operation's row until the operation completes, beside the edit's own fields the row
/// already holds; ADR-004 covers email content only.
///
/// Stored with a `version`: an operation can wait across app updates, so every later build reads
/// every earlier version, and a record this build can't read (`stored(_:)` throws) leaves the
/// operation untouched rather than being taken for none (after its write a record read as none
/// would read the occurrences already reset, and their files would be lost).
struct SeriesEditRecord: Sendable, Equatable {
    let seriesId: String
    let capture: String
    let files: [PutBackFile]

    /// The format this build writes, and the newest it reads.
    static let version = 1

    /// The reserved key in `PendingCalendarOperation.argumentsJSON`. Only the queue writes it
    /// (`AccountManager.recordSeriesEdit`); a tool call that carries it has it removed when the
    /// operation is queued.
    static let argumentKey = "_series_edit_record"

    private static let versionKey = "version"
    private static let seriesKey = "series_id"
    private static let captureKey = "capture"
    private static let filesKey = "files"

    init(seriesId: String, capture: String, files: [PutBackFile] = []) {
        self.seriesId = seriesId
        self.capture = capture
        self.files = files
    }

    /// A record kept on an operation that this build can't read: of a later version, or not
    /// whole. No terminal arm claims it, so the operation stays queued as it is.
    struct Unreadable: Error, Equatable {}

    /// The record in a queued operation's arguments: nil when it has none, and throws
    /// `Unreadable` when it has one this build can't read.
    static func stored(_ arguments: [String: JSONValue]) throws -> SeriesEditRecord? {
        guard let value = arguments[argumentKey] else { return nil }
        guard case .dictionary(let d) = value,
              let stored = d[versionKey]?.wholeNumber, stored >= 1, stored <= version,
              case .string(let series)? = d[seriesKey],
              case .string(let capture)? = d[captureKey],
              case .array(let list)? = d[filesKey] else { throw Unreadable() }
        var files: [PutBackFile] = []
        for entry in list {
            guard let file = PutBackFile(entry) else { throw Unreadable() }
            files.append(file)
        }
        return SeriesEditRecord(seriesId: series, capture: capture, files: files)
    }

    /// The record as stored under `argumentKey`.
    var jsonObject: [String: Any] {
        [Self.versionKey: Self.version, Self.seriesKey: seriesId, Self.captureKey: capture, Self.filesKey: files.map(\.jsonObject)]
    }

    /// This record without the entries `released` names.
    func without(_ released: [PutBackFile]) -> SeriesEditRecord {
        var left = files
        for file in released {
            if let index = left.firstIndex(of: file) { left.remove(at: index) }
        }
        return SeriesEditRecord(seriesId: seriesId, capture: capture, files: left)
    }
}

/// A file a changed occurrence held of its own before an edit of every occurrence erased it
/// (`SeriesEditRecord.files`): which occurrence (its id when read, as the record's capture names
/// it), how Outlook lists it, and the SHA-256 of its bytes, by which its saved copy is named and
/// checked. Neutral: no path, no provider type.
struct PutBackFile: Sendable, Equatable, Hashable {
    let occurrence: String
    let name: String
    let contentType: String
    let isInline: Bool
    let contentId: String?
    let sha256: String

    init(occurrence: String, name: String, contentType: String, isInline: Bool, contentId: String?, sha256: String) {
        self.occurrence = occurrence
        self.name = name
        self.contentType = contentType
        self.isInline = isInline
        self.contentId = contentId
        self.sha256 = sha256
    }

    init?(_ value: JSONValue) {
        guard case .dictionary(let d) = value,
              case .string(let occurrence)? = d["occurrence"], case .string(let name)? = d["name"],
              case .string(let contentType)? = d["content_type"], case .bool(let isInline)? = d["is_inline"],
              case .string(let sha)? = d["sha256"], SavedFileName.isValid(sha) else { return nil }
        let contentId: String?
        switch d["content_id"] {
        case .string(let id)?: contentId = id
        case nil, .null?: contentId = nil
        default: return nil
        }
        self.init(occurrence: occurrence, name: name, contentType: contentType, isInline: isInline, contentId: contentId, sha256: sha)
    }

    /// What the user is told about `held` files of changed occurrences an edit of every
    /// occurrence has not attached again yet.
    static func notRestoredMessage(_ held: Int) -> String {
        "The series was changed, but \(held == 1 ? "1 file attached to events you had changed on their own is" : "\(held) files attached to events you had changed on their own are") not restored yet."
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "occurrence": occurrence, "name": name, "content_type": contentType, "is_inline": isInline, "sha256": sha256,
        ]
        object["content_id"] = contentId
        return object
    }
}

/// The name a saved file is kept under: the lowercase hex SHA-256 of its bytes, the digest
/// attachments are paired by (`AttachmentPairing.contentDigest`).
enum SavedFileName {
    static func of(_ data: Data) -> String { AttachmentPairing.contentDigest(data) }

    /// Whether `name` is one `of(_:)` gives: 64 lowercase hex digits, so it is one safe path
    /// component.
    static func isValid(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// The bytes of the files an edit of every occurrence saves before its write (`PutBackFile`),
/// bound by the queue to the operation writing it, so the calendar never sees where they are.
/// - `save`: keeps `data` and returns its SHA-256 (`SavedFileName`);
/// - `load`: the bytes saved under that name, checked against it; throws `Missing` when there
///   are none, or they no longer match;
/// - `release`: deletes the bytes saved under that name. Called only once the record no longer
///   names them is kept.
struct SavedFiles: Sendable {
    let save: @Sendable (Data) throws -> String
    let load: @Sendable (String) throws -> Data
    let release: @Sendable (String) throws -> Void

    /// A saved file that is gone or no longer matches its name.
    struct Missing: Error, Equatable {}
}

/// What an edit of every occurrence keeps on the queued operation that is writing it (#718).
struct SeriesEditRecorder: Sendable {
    /// What an earlier attempt of this operation kept, nil when none did.
    let kept: SeriesEditRecord?

    /// Keeps a `SeriesEditRecord` with the operation, replacing one kept before. A throw stops the
    /// edit before its write.
    let keep: @Sendable (SeriesEditRecord) async throws -> Void

    /// Where the files the record names are saved.
    let files: SavedFiles
}
