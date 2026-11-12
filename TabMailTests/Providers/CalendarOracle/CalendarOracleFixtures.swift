/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

// MARK: - Calendar oracle fixtures (ADR-IOS-110)
//
// Expected occurrences of repeating events, generated on a developer Mac by libical and by
// Thunderbird's ical.js (`Scripts/cal-oracle/generate.sh`) and committed as JSON under
// `TabMailTests/Fixtures/CalendarOracle/`. Where the two engines disagree, the fixture keeps
// both answers and names the one the test follows, and why.
//
// DATES: every date in these fixtures is fixed, 1896-2019 (every DTSTAMP is 2020-01-01). This uses
// the testing rules' exception for dates far in the past (2020 and earlier): the engines do not
// run at test time, so their answers cannot be relative to `Date()`. The earliest are the century
// leap pair (a yearly 29 February series across 1896-1904 and 1996-2004). Zoned cases use settled
// time-zone history (1996-2019), which a later tz data release does not change; the zone-data
// check below says so if it ever does.
//
// Loading never traps: a missing or unreadable file leaves the lists empty and records why in
// `CalendarOracle.loadErrors`, which `CalendarOracleIntegrityTests` fails on, so one bad file
// cannot crash the test process and hide every other result (testing rule 9's purpose).

/// One occurrence in the fixtures' normal form (`Scripts/cal-oracle/generate.mjs`).
struct OracleOccurrence: Decodable, Equatable, Sendable, CustomStringConvertible {
    /// The occurrence key: `CalDAVOccurrences`' RECURRENCE-ID normal form.
    let key: String
    /// `yyyy-MM-dd` (all-day), the wall time `yyyy-MM-ddTHH:mm:ss` (floating), or the UTC
    /// instant `yyyy-MM-ddTHH:mm:ssZ` (UTC and zoned).
    let start: String
    /// The same form as `start`; an all-day end date is exclusive.
    let end: String
    /// `confirmed` or `cancelled`.
    let status: String
    /// Whether a changed occurrence starts somewhere other than its slot in the series.
    let moved: Bool
    /// Zoned only: the UTC offset at `start` in the series zone, in seconds (the zone-data check).
    let offset: Int?

    /// What the listing comparison asserts: every field but the zone diagnostics.
    var compared: Compared { Compared(start: start, end: end, status: status, moved: moved) }

    struct Compared: Equatable, Sendable, CustomStringConvertible {
        let start: String
        let end: String
        let status: String
        let moved: Bool

        var description: String { "\(start) → \(end) \(status)\(moved ? " moved" : "")" }
    }

    var description: String { "\(key): \(compared)" }

    private enum CodingKeys: String, CodingKey {
        case key, start, end, status, moved, offset
    }
}

/// One fixture case.
struct OracleCase: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let from: String
        let to: String
    }

    struct Resolution: Decodable, Sendable {
        let follows: String
        let why: String
    }

    let id: String
    let ics: String
    let window: Window
    /// `allDay`, `floating`, `utc` or `zoned:<IANA zone>`.
    let frame: String
    /// `occurrences`, or `notListed` for a rule TabMail does not expand.
    let expect: String
    /// The occurrences the test asserts; nil for a disagreement resolved as `excluded`.
    let expected: [OracleOccurrence]?
    let resolution: Resolution?

    /// The zone a `zoned:` frame names.
    var zoneIdentifier: String? {
        let prefix = "zoned:"
        return frame.hasPrefix(prefix) ? String(frame.dropFirst(prefix.count)) : nil
    }
}

/// A case's id as a test argument, so each result names its case.
struct OracleCaseID: CustomTestStringConvertible, Hashable, Sendable {
    let id: String
    var testDescription: String { id }
}

enum CalendarOracle {

    // MARK: - Parked cases

    /// Cases that fail on `main`, each kept out of the asserting suites under the issue it is filed
    /// as (the repo's precedent: an invariant the base cannot satisfy is not `withKnownIssue`d,
    /// it lands with the fix it pins). The fixture stays; a fix PR removes its entry, and the case
    /// failing before the fix is that PR's red-first evidence.
    static let parked: [String: String] = [:]

    // MARK: - Files

    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let file: String
            let family: String
            let cases: Int
            let sha256: String
        }

        let files: [File]
        let oracles: Oracles
    }

    struct Oracles: Decodable, Sendable {
        struct Libical: Decodable, Sendable {
            let version: String
            let tzdata: String
        }

        let libical: Libical
    }

    struct Family: Decodable, Sendable {
        let family: String
        let cases: [OracleCase]
    }

    static let manifestName = "cal-oracle-manifest"

    private final class BundleToken {}

    /// What loading found: the manifest, every case by family file, and anything that went wrong.
    struct Loaded: Sendable {
        var manifest: Manifest?
        /// Each manifest file's bytes as the bundle holds them, by file name.
        var fileData: [String: Data] = [:]
        /// Each family file's cases, by file name.
        var casesByFile: [String: [OracleCase]] = [:]
        var errors: [String] = []
    }

    static let loaded: Loaded = load()

    private static func resource(_ fileName: String) -> Data? {
        let base = (fileName as NSString).deletingPathExtension
        guard let url = Bundle(for: BundleToken.self).url(forResource: base, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func load() -> Loaded {
        var result = Loaded()
        guard let manifestData = resource(manifestName + ".json") else {
            result.errors.append("\(manifestName).json is not in the test bundle (run ./Scripts/xcodegen.sh)")
            return result
        }
        do {
            result.manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            result.errors.append("\(manifestName).json does not decode: \(error)")
            return result
        }
        for file in result.manifest?.files ?? [] {
            guard let data = resource(file.file) else {
                result.errors.append("\(file.file) is not in the test bundle (run ./Scripts/xcodegen.sh)")
                continue
            }
            result.fileData[file.file] = data
            do {
                result.casesByFile[file.file] = try JSONDecoder().decode(Family.self, from: data).cases
            } catch {
                result.errors.append("\(file.file) does not decode: \(error)")
            }
        }
        return result
    }

    static var loadErrors: [String] { loaded.errors }

    static var allCases: [OracleCase] {
        (loaded.manifest?.files ?? []).flatMap { loaded.casesByFile[$0.file] ?? [] }
    }

    static let casesByID: [String: OracleCase] = Dictionary(allCases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The fixture's zone data, as the generator recorded it, for the drift message.
    static var fixtureTzdata: String { loaded.manifest?.oracles.libical.tzdata ?? "unknown" }

    // MARK: - Arguments

    /// Cases the listing suite asserts: every case with an expected list, less the parked ones.
    static var listingCases: [OracleCaseID] {
        allCases.filter { $0.expected != nil && parked[$0.id] == nil }.map { OracleCaseID(id: $0.id) }
    }

    // MARK: - Normal form

    private static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter
    }

    /// An instant in the fixtures' form for `frame`: UTC for a zoned or UTC series, the
    /// device's wall time for a floating one.
    static func text(_ instant: Date, frame: String) -> String {
        frame == "floating"
            ? formatter("yyyy-MM-dd'T'HH:mm:ss", .current).string(from: instant)
            : formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", .gmt).string(from: instant)
    }

    /// The instant a fixture's `start` names, for a zoned or UTC occurrence.
    static func instant(_ text: String) -> Date? {
        formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", .gmt).date(from: text)
    }

    /// A listing row in the fixtures' normal form, or a description of why it has none.
    static func normalize(_ row: GCalEvent, frame: String) -> Result<OracleOccurrence, NormalizeFailure> {
        let id = row.id ?? ""
        guard let key = (try? CalDAVOccurrences.OccurrenceId.split(id))?.key else {
            return .failure(NormalizeFailure(description: "row \(id) has no occurrence key"))
        }
        let status = row.status?.lowercased() == "cancelled" ? "cancelled" : "confirmed"
        if frame == "allDay" {
            guard let start = row.start?.date, let end = row.end?.date else {
                return .failure(NormalizeFailure(description: "all-day row \(id) has no dates"))
            }
            let moved = row.originalStartTime?.date.map { $0 != start } ?? true
            return .success(OracleOccurrence(key: key, start: start, end: end, status: status, moved: moved, offset: nil))
        }
        guard let start = row.startDate, let end = row.endDate else {
            return .failure(NormalizeFailure(description: "row \(id) has a time TabMail can't read"))
        }
        let moved = row.originalStartTime?.dateTime.flatMap(Date.fromISO8601).map { $0 != start } ?? true
        return .success(OracleOccurrence(
            key: key, start: text(start, frame: frame), end: text(end, frame: frame), status: status, moved: moved, offset: nil))
    }

    struct NormalizeFailure: Error, CustomStringConvertible {
        let description: String
    }
}
