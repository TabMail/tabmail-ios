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
/// - `splitAt`: the PLACE in the series of the occurrence the split starts at, a naive wall clock
///   in the operation's zone: its `recurrence_id`, or, for an occurrence moved from its place,
///   where the series had it (#687, `SplitCarry.placeNaive`);
/// - `mode`: whether the split carries the later exceptions into the new part or resets them
///   (`SplitCarry.Mode`, #563);
/// - `fields`: the names of the fields the edit set, which overwrite a carried occurrence's own;
/// - `namedPlace`, `namedStart`: the place and the start of the occurrence named (`SplitCarry.key`),
///   which sort the series' exceptions around the cut (`SplitCarry.partition`); nil on a record
///   kept before they were, read as an occurrence named at the cut;
/// - `edits`: the place of each occurrence edited where it is on the old series
///   (`SplitCarry.Parts.edited`) and the start it is moved to ("" when it keeps its own), so a
///   retry writes each once (`SplitCarry.edits(of:targets:length:fields:)`).
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
        return .dictionary(d)
    }

    /// The record as stored under `argumentKey`.
    var jsonObject: [String: Any] {
        var d: [String: Any] = [Self.seriesKey: seriesId, Self.newPartKey: newPartId, Self.splitAtKey: splitAt,
                                Self.modeKey: mode.rawValue, Self.fieldsKey: fields.sorted().map(\.rawValue), Self.editsKey: edits]
        if let namedPlace { d[Self.namedPlaceKey] = namedPlace }
        if let namedStart { d[Self.namedStartKey] = namedStart }
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
