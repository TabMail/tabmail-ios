/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

// MARK: - A CalDAV event with guests carries its organizer
//
// **INVARIANT**, checked on what the fake server holds after the real calendar queue drains, never
// on the request built. After any CalDAV write:
// - (I1) every stored VEVENT with an attendee of its own has an organizer of its own, whenever the
//   resource already names an organizer, or it is the user's own event (a series VEVENT, or a
//   create) and the server advertises a `mailto:` address for the user;
// - (I2) every organizer that existed before is byte-identical after;
// - (I3) every new organizer is the resource's own organizer or a `mailto:` member of the server's
//   advertised `calendar-user-address-set`, exactly as advertised, never anything else;
// - (I4) a resource's organizers are all equal (unless they already differed);
// - (I5) nothing advertised and no organizer in the resource: no organizer is written, and the
//   write goes ahead as before;
// - (I6) a resource that holds only changed occurrences never gains the account's address;
// - (I7) the operation lands on an iCloud-like server; a lookup that fails without a definite answer
//   leaves it queued with nothing written; it is never retired as "event not found".
//
// RFC 5545 §3.8.4.3 requires the organizer on a VEVENT with attendees, and iCloud refuses the write
// with a 403 without it (measured for a changed occurrence). RFC 6638 §3.1 makes a resource the
// user's organizer object only when the organizer is one of the user's own calendar addresses.
//
// Every date is relative to today; every address is at example.com. The sign-in is
// `user@example.com`.

// MARK: - Fixture

enum OrganizerFixture {
    static let home = URL(string: "https://caldav.example.com/cal/")!
    static let calendarId = "/cal/"
    static let path = "/cal/org-711.ics"
    static let uid = "org-711"
    static let signIn = "user@example.com"
    static let own = "mailto:user@example.com"
    static let guest = "guest@example.com"

    /// The principal's addresses as a scheduling server lists them: a `urn:uuid:` first, the
    /// user's other address, the sign-in, and the principal's own path.
    static let advertised = [
        "urn:uuid:6b2c1a52-0711-4000-8000-000000000711", "mailto:alias@example.com",
        "mailto:user@example.com", "/principals/user/",
    ]

    /// A whole UTC hour a week from now: the series' first occurrence.
    static let start: Date = {
        let hour: TimeInterval = 3_600
        let base = Date().addingTimeInterval(7 * 86_400)
        return Date(timeIntervalSince1970: (base.timeIntervalSince1970 / hour).rounded(.down) * hour)
    }()

    /// The weekly occurrence two weeks after the first.
    static var occurrence: Date { start.addingTimeInterval(14 * 86_400) }

    static func icsUTC(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt.string(from: date)
    }

    static func naiveUTC(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: date)
    }

    /// A weekly series with `extra` among its own properties, then `overrides` (each a changed
    /// occurrence's own extra properties, at `occurrence`).
    static func series(_ extra: [String] = [], overrides: [[String]] = [], uid: String = uid) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(icsUTC(start))", "DTSTART:\(icsUTC(start))", "DURATION:PT1H",
            "RRULE:FREQ=WEEKLY", "SUMMARY:Planning",
        ] + extra + ["END:VEVENT"]
        for override in overrides { lines += overrideBlock(override, uid: uid) }
        return (lines + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    /// A resource that holds only one changed occurrence of someone else's series (RFC 4791 §4.1).
    static func overridesOnly(_ extra: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"]
         + overrideBlock(extra, uid: uid) + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    private static func overrideBlock(_ extra: [String], uid: String) -> [String] {
        ["BEGIN:VEVENT", "UID:\(uid)", "RECURRENCE-ID:\(icsUTC(occurrence))", "DTSTAMP:\(icsUTC(start))",
         "DTSTART:\(icsUTC(occurrence))", "DURATION:PT1H", "SUMMARY:Planning, room 2"] + extra + ["END:VEVENT"]
    }

    static func provider(_ http: FakeHTTP.Scenario) -> CalDAVProvider {
        CalDAVProvider(
            client: CalDAVClient(username: signIn, password: "pw", session: http.session),
            calendarHomeURL: home, serverBaseURL: home)
    }

    static var newPartPath: String {
        let uid = GoogleCalendarProvider.deterministicSplitEventId(masterId: path, recurrenceId: naiveUTC(occurrence))
        return "/cal/\(uid).ics"
    }

    // MARK: Edits

    static let addGuest: [String: JSONValue] = [
        "add_attendees": .array([.dictionary(["email": .string(guest), "name": .string("Guest")])]),
    ]

    static let rename: [String: JSONValue] = ["title": .string("Planning, new agenda")]

    static func scoped(_ edit: [String: JSONValue], _ scope: String) -> [String: JSONValue] {
        edit.merging([
            "edit_scope": .string(scope), "recurrence_id": .string(naiveUTC(occurrence)),
            "timezone": .string("UTC"),
        ]) { edited, _ in edited }
    }

    // MARK: Reading what the server holds (through the tests' own reader, `VEventOracle`)

    /// The physical lines of a VEVENT's own `ORGANIZER` property, folding included.
    static func organizerLines(_ block: [String]) -> [String] {
        var depth = 0
        var out: [String] = []
        var inOrganizer = false
        for line in block {
            if let first = line.first, first == " " || first == "\t" {
                if inOrganizer { out.append(line) }
                continue
            }
            inOrganizer = false
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") { depth -= 1; continue }
            if depth == 1, upper.hasPrefix("ORGANIZER:") || upper.hasPrefix("ORGANIZER;") {
                inOrganizer = true
                out.append(line)
            }
        }
        return out
    }

    static func recurrenceId(_ block: [String]) -> String? { VEventOracle.own(block, "RECURRENCE-ID").first }

    /// The series VEVENT's own property lines named `name`; none when there is no series VEVENT.
    static func masterOwn(_ ics: String, _ name: String) -> [String] {
        VEventOracle.master(ics).map { VEventOracle.own($0, name) } ?? []
    }

    /// The series VEVENT's `ORGANIZER` as physical lines; none when there is no series VEVENT.
    static func masterOrganizerLines(_ ics: String) -> [String] {
        VEventOracle.master(ics).map(organizerLines) ?? []
    }

    /// I1 to I4 over `after`, a resource the server holds once the write is done, against
    /// `before`, the resource it was written from.
    static func expectInvariant(
        before: String, after: String, advertised: [String]?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let beforeBlocks = VEventOracle.vevents(before)
        let afterBlocks = VEventOracle.vevents(after)
        let beforeOrganizers = Set(beforeBlocks.flatMap { VEventOracle.own($0, "ORGANIZER") })
        let ownAddresses = (advertised ?? []).filter { $0.lowercased().hasPrefix("mailto:") }
        let isOwnEvent = VEventOracle.master(after) != nil
        for block in afterBlocks {
            let organizers = VEventOracle.own(block, "ORGANIZER")
            // I1
            if !VEventOracle.own(block, "ATTENDEE").isEmpty,
               !beforeOrganizers.isEmpty || (isOwnEvent && !ownAddresses.isEmpty) {
                #expect(organizers.count == 1, "I1: a VEVENT with attendees has no organizer", sourceLocation: sourceLocation)
            }
            // I3
            for organizer in organizers {
                let known = beforeOrganizers.contains(organizer) || ownAddresses.contains { "ORGANIZER:\($0)" == organizer }
                #expect(known, "I3: '\(organizer)' is neither the resource's organizer nor an advertised address", sourceLocation: sourceLocation)
            }
        }
        // I2: matched by RECURRENCE-ID (the series VEVENT has none).
        for old in beforeBlocks where !organizerLines(old).isEmpty {
            guard let new = afterBlocks.first(where: { recurrenceId($0) == recurrenceId(old) }) else { continue }
            #expect(organizerLines(new) == organizerLines(old), "I2: an existing organizer changed", sourceLocation: sourceLocation)
        }
        // I4
        if beforeOrganizers.count <= 1 {
            let all = Set(afterBlocks.flatMap { VEventOracle.own($0, "ORGANIZER") })
            #expect(all.count <= 1, "I4: the resource has different organizers \(all)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - The principal's addresses

/// The principal side of a CalDAV server: `current-user-principal` (RFC 5397), the
/// `calendar-home-set` (RFC 4791 §6.2.1) and the `calendar-user-address-set` (RFC 6638 §2.4.1),
/// each answered to a `PROPFIND` that names it.
final class FakeCalDAVPrincipal: Sendable {
    static let principalPath = "/principals/user/"

    /// The hrefs of the principal's `calendar-user-address-set`, in order; nil when the server does
    /// not have the property (RFC 6638: the user is not enabled for scheduling there).
    let advertised: [String]?
    /// The answer to the address-set `PROPFIND`, in place of the property, when set.
    let addressSetAnswer: FakeHTTP.CannedResponse?
    /// The answer to every `current-user-principal` `PROPFIND`, in place of the principal, when set.
    let principalAnswer: FakeHTTP.CannedResponse?

    private let addressSetCount = Mutex(0)
    /// The answer to the FIRST address-set `PROPFIND` only, when set; later ones are answered as usual.
    private let firstAddressSetAnswer: Mutex<FakeHTTP.CannedResponse?>

    init(
        advertised: [String]?,
        addressSetAnswer: FakeHTTP.CannedResponse? = nil,
        firstAddressSetAnswer: FakeHTTP.CannedResponse? = nil,
        principalAnswer: FakeHTTP.CannedResponse? = nil
    ) {
        self.advertised = advertised
        self.addressSetAnswer = addressSetAnswer
        self.firstAddressSetAnswer = Mutex(firstAddressSetAnswer)
        self.principalAnswer = principalAnswer
    }

    /// How many `PROPFIND`s asked for the address set.
    var addressSetLookups: Int { addressSetCount.withLock { $0 } }

    func handlePROPFIND(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if body.contains("calendar-user-address-set") {
            addressSetCount.withLock { $0 += 1 }
            if let first = firstAddressSetAnswer.withLock({ answer in defer { answer = nil }; return answer }) {
                return first
            }
            if let addressSetAnswer { return addressSetAnswer }
            // `URL.path` drops a trailing slash; the components keep the path as sent.
            let path = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.path
            guard path == Self.principalPath else { return .status(404) }
            guard let advertised else {
                return Self.multistatus(path: request.url.path, prop: "<c:calendar-user-address-set/>", status: "404 Not Found")
            }
            let hrefs = advertised.map { "<d:href>\(Self.escaped($0))</d:href>" }.joined()
            return Self.multistatus(path: request.url.path, prop: "<c:calendar-user-address-set>\(hrefs)</c:calendar-user-address-set>")
        }
        if body.contains("calendar-home-set") {
            return Self.multistatus(path: request.url.path, prop: "<c:calendar-home-set><d:href>/cal/</d:href></c:calendar-home-set>")
        }
        if body.contains("current-user-principal") {
            if let principalAnswer { return principalAnswer }
            return Self.multistatus(path: request.url.path, prop: "<d:current-user-principal><d:href>\(Self.principalPath)</d:href></d:current-user-principal>")
        }
        return .status(400)
    }

    /// An href may carry an embedded line break, written as character references.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private static func multistatus(path: String, prop: String, status: String = "200 OK") -> FakeHTTP.CannedResponse {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:href>\(path)</d:href>
            <d:propstat><d:prop>\(prop)</d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat>
          </d:response>
        </d:multistatus>
        """
        return .raw(statusCode: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: Data(xml.utf8))
    }
}

// MARK: - Over the wire, through the queue

@Suite("A CalDAV event with guests carries its organizer", .serialized, .processGlobalState)
struct CalDAVOrganizerTests {
    typealias F = OrganizerFixture

    private struct Run {
        let store: FakeCalDAVStore
        let principal: FakeCalDAVPrincipal
        let http: FakeHTTP.Scenario
        let provider: CalDAVProvider

        var propfinds: Int { http.recordedCalls().filter { $0.method == "PROPFIND" }.count }
        var puts: [FakeCalDAVStore.RecordedPut] { store.recordedPuts() }
    }

    /// An iCloud-like server by default: it refuses a VEVENT with attendees and no organizer, and
    /// advertises `F.advertised`.
    private static func setUp(
        _ seed: [String: String] = [:],
        refuses: Bool = true,
        advertised: [String]? = F.advertised,
        addressSetAnswer: FakeHTTP.CannedResponse? = nil,
        firstAddressSetAnswer: FakeHTTP.CannedResponse? = nil,
        principalAnswer: FakeHTTP.CannedResponse? = nil,
        put: (@Sendable (FakeCalDAVStore, FakeHTTP.Request) -> FakeHTTP.CannedResponse)? = nil
    ) -> Run {
        let store = FakeCalDAVStore(servesETags: true, refusesAttendeesWithoutOrganizer: refuses)
        for (path, ics) in seed { store.seed(path: path, ics: ics) }
        let principal = FakeCalDAVPrincipal(
            advertised: advertised, addressSetAnswer: addressSetAnswer,
            firstAddressSetAnswer: firstAddressSetAnswer, principalAnswer: principalAnswer)
        let http = FakeHTTP.Scenario()
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { request in
            put.map { $0(store, request) } ?? store.handlePUT(request)
        }
        http.register(path: "/", method: "PROPFIND") { principal.handlePROPFIND($0) }
        return Run(store: store, principal: principal, http: http, provider: F.provider(http))
    }

    private static func edit(
        _ run: Run, _ arguments: [String: JSONValue], account: String, eventId: String = F.path, drains: Int = 1
    ) async throws -> [PendingCalendarOperation] {
        try await drainCalendarOperation(
            type: .edit, accountId: account, eventId: eventId, calendarId: F.calendarId,
            arguments: arguments, provider: run.provider, drains: drains)
    }

    private static func landed(_ rows: [PendingCalendarOperation]) -> Comment {
        Comment(rawValue: "the write did not land: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
    }

    private static func stored(_ run: Run, _ path: String = F.path) throws -> String {
        try #require(run.store.storedICS(path: path), "nothing is stored at \(path)")
    }

    // MARK: 1-5: the first guest, and a stored guest list, on the user's own event

    @Test("1: a create with guests is written with the user's advertised address as organizer")
    func createWithGuests() async throws {
        let run = Self.setUp()
        defer { run.http.close() }
        let rows = try await drainCalendarOperation(
            type: .create, accountId: "org711-create", eventId: "org711create", calendarId: F.calendarId,
            arguments: [
                "title": .string("Kickoff"), "start_iso": .string(F.naiveUTC(F.start)),
                "end_iso": .string(F.naiveUTC(F.start.addingTimeInterval(3_600))), "timezone": .string("UTC"),
                "attendees": .array([.dictionary(["email": .string(F.guest), "name": .string("Guest")])]),
            ],
            provider: run.provider)
        #expect(rows.isEmpty, Self.landed(rows))
        let created = try Self.stored(run, "/cal/org711create.ics")
        let event = try #require(VEventOracle.master(created), Comment(rawValue: created))
        #expect(VEventOracle.own(event, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: created))
        #expect(VEventOracle.own(event, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        F.expectInvariant(before: "", after: created, advertised: F.advertised)
    }

    @Test("2: the first guest of a whole series that has no organizer gives the series the user's address")
    func allFirstGuest() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-all-first")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        let series = try #require(VEventOracle.master(after))
        #expect(VEventOracle.own(series, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: after))
        #expect(VEventOracle.own(series, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    @Test("3: the first guest of one occurrence of a series with no organizer gives the changed occurrence, and the series, the user's address")
    func thisOnlyFirstGuest() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.scoped(F.addGuest, "this_only"), account: "org711-only-first")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        let override = try #require(VEventOracle.overrides(after).first, Comment(rawValue: after))
        #expect(VEventOracle.own(override, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: after))
        #expect(VEventOracle.own(override, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        // RFC 6638 §3.1: the organizer is set in every component, the guest-less series too.
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").isEmpty, Comment(rawValue: after))
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    @Test("3b: a changed occurrence given attendees gets the series' organizer, ahead of its attendees")
    func thisOnlyTakesTheSeriesOrganizer() async throws {
        let alice = "ATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@example.com"
        let seed = F.series(["ORGANIZER:mailto:other@example.com", alice], overrides: [[alice]])
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.scoped(F.rename, "this_only"), account: "org711-only-series-org")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        let override = try #require(VEventOracle.overrides(after).first)
        let text = Comment(rawValue: override.joined(separator: "\n"))
        let organizer = try #require(override.firstIndex(of: "ORGANIZER:mailto:other@example.com"), text)
        let attendee = try #require(override.firstIndex(of: alice), text)
        #expect(organizer < attendee, text)
        #expect(run.principal.addressSetLookups == 0, "the address set was read for a resource that names its organizer")
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    @Test("4: the first guest of a split gives the new part the user's address; the capped series has no guests and no organizer")
    func splitFirstGuest() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.scoped(F.addGuest, "this_and_following"), account: "org711-split-first")
        #expect(rows.isEmpty, Self.landed(rows))
        let newPart = try Self.stored(run, F.newPartPath)
        let first = try #require(VEventOracle.master(newPart))
        #expect(VEventOracle.own(first, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: newPart))
        #expect(VEventOracle.own(first, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        let capped = try Self.stored(run)
        #expect(VEventOracle.vevents(capped).allSatisfy { VEventOracle.own($0, "ORGANIZER").isEmpty }, Comment(rawValue: capped))
        F.expectInvariant(before: seed, after: newPart, advertised: F.advertised)
        F.expectInvariant(before: seed, after: capped, advertised: F.advertised)
    }

    @Test("5: a title-only split of a series whose stored guests have no organizer writes the organizer on both parts")
    func splitStoredGuests() async throws {
        let seed = F.series(["ATTENDEE;CN=Alice:mailto:alice@example.com"])
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.scoped(F.rename, "this_and_following"), account: "org711-split-stored")
        #expect(rows.isEmpty, Self.landed(rows))
        #expect(run.puts.count == 2 && run.puts.allSatisfy { $0.returnedETag != nil },
                "both parts must land: \(run.puts.map { "\($0.path) \($0.returnedETag ?? "refused")" })")
        for path in [F.newPartPath, F.path] {
            let resource = try Self.stored(run, path)
            let event = try #require(VEventOracle.master(resource))
            #expect(VEventOracle.own(event, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: resource))
            F.expectInvariant(before: seed, after: resource, advertised: F.advertised)
        }
    }

    // MARK: 6-8: the resource's own organizer comes first

    @Test("6: a changed occurrence with guests and no organizer takes the series' organizer, not the account's, with no lookup")
    func overrideTakesTheSeriesOrganizer() async throws {
        let organizer = ["ORGANIZER;CN=\"Other Person, Planning Lead and Owner of the Weekly Planning Meet",
                         " ing\":mailto:other@example.com"]
        let seed = F.series(organizer + ["ATTENDEE:mailto:alice@example.com"],
                            overrides: [["ATTENDEE:mailto:alice@example.com"]])
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.rename, account: "org711-all-override")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        let override = try #require(VEventOracle.overrides(after).first)
        #expect(F.organizerLines(override) == organizer, Comment(rawValue: after))
        #expect(F.masterOrganizerLines(after) == organizer, Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    @Test("7: an existing organizer the server does not advertise stays byte for byte when a guest is added, with no lookup")
    func existingOrganizerIsKept() async throws {
        let organizer = ["ORGANIZER;CN=Olivia:mailto:other@example.com"]
        let seed = F.series(organizer)
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-existing")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(F.masterOrganizerLines(after) == organizer, Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    @Test("8: a series with no organizer whose changed occurrence names one takes that organizer when it gets a guest")
    func seriesTakesTheOverridesOrganizer() async throws {
        let seed = F.series(overrides: [["ORGANIZER:mailto:other@example.com", "ATTENDEE:mailto:alice@example.com"]])
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-series-from-override")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        let series = try #require(VEventOracle.master(after))
        #expect(VEventOracle.own(series, "ORGANIZER") == ["ORGANIZER:mailto:other@example.com"], Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }

    // MARK: 9-11: which advertised address, and none

    @Test("9: a sign-in the server does not advertise is never written; the first advertised mailto is")
    func signInNotAdvertised() async throws {
        let advertised = ["urn:uuid:6b2c1a52-0711-4000-8000-000000000711", "mailto:alias@example.com",
                          "mailto:second@example.com", "/principals/user/"]
        let seed = F.series()
        let run = Self.setUp([F.path: seed], advertised: advertised)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-alias")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:mailto:alias@example.com"],
                Comment(rawValue: after))
        #expect(!after.lowercased().contains("organizer:mailto:user@"), Comment(rawValue: after))
        F.expectInvariant(before: seed, after: after, advertised: advertised)
    }

    @Test("10: the sign-in is matched in any letter case and written as the server spells it")
    func serverSpelling() async throws {
        let advertised = ["mailto:alias@example.com", "mailto:User@Example.com"]
        let seed = F.series()
        let run = Self.setUp([F.path: seed], advertised: advertised)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-spelling")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:mailto:User@Example.com"],
                Comment(rawValue: after))
        F.expectInvariant(before: seed, after: after, advertised: advertised)
    }

    @Test("11a: a server that advertises no address gets no organizer, and the write lands where it is accepted")
    func noneAdvertisedLenient() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, advertised: nil)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-none-lenient")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
    }

    @Test("11b: a server that advertises no address and refuses guests without an organizer: retired with the 403 reason, nothing changed")
    func noneAdvertisedRefusing() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: true, advertised: nil)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-none-refusing")
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue, Self.landed(rows))
        #expect(rows.first?.failureReason?.contains("ATTENDEE but no ORGANIZER") == true,
                "reason: \(rows.first?.failureReason ?? "<none>")")
        let after = try Self.stored(run)
        #expect(after == seed, Comment(rawValue: after))
    }

    // MARK: 12-13: a lookup that fails

    @Test("12: a lookup that fails without an answer writes nothing and leaves the edit queued",
          arguments: ["503", "transport"])
    func lookupFailureKeepsTheEditQueued(_ failure: String) async throws {
        let answer: FakeHTTP.CannedResponse = failure == "503" ? .status(503) : .transportError(.timedOut)
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, addressSetAnswer: answer)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-\(failure)")
        #expect(run.puts.isEmpty, "a PUT was sent without the lookup's answer: \(run.puts.map(\.path))")
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.queued.rawValue,
                "the edit is not queued: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let after = try Self.stored(run)
        #expect(after == seed, Comment(rawValue: after))
    }

    @Test("13: a lookup the server answers 404 is not 'event not found': the write goes ahead with no organizer")
    func lookup404IsNotEventNotFound() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, addressSetAnswer: .status(404))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-404")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
    }

    @Test("T1: a lookup the server refuses with another 4xx means none advertised: the write goes ahead with no organizer",
          arguments: [403, 405, 400])
    func lookupRefusedMeansNone(_ code: Int) async throws {
        let run = Self.setUp([F.path: F.series()], refuses: false, addressSetAnswer: .status(code))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-refused-\(code)")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        #expect(run.principal.addressSetLookups == 1, "the address set was read \(run.principal.addressSetLookups) times")
    }

    @Test("T2: a lookup answered 'come back later' writes nothing and leaves the edit queued",
          arguments: [408, 409, 423, 425, 429])
    func lookupComeBackLaterKeepsTheEditQueued(_ code: Int) async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, addressSetAnswer: .status(code))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-later-\(code)")
        #expect(run.puts.isEmpty, "a PUT was sent without the lookup's answer: \(run.puts.map(\.path))")
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.queued.rawValue,
                "the edit is not queued: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let after = try Self.stored(run)
        #expect(after == seed, Comment(rawValue: after))
    }

    @Test("T7: a lookup answered 401 is the account's sign-in refused: no PUT, and the auth arm retires the edit")
    func lookup401IsAnAuthFailure() async throws {
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, addressSetAnswer: .status(401))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-401")
        #expect(run.puts.isEmpty, "a PUT was sent after the sign-in was refused: \(run.puts.map(\.path))")
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue, Self.landed(rows))
        #expect(rows.first?.failureReason == AccountManager.calendarAuthFailureReason(CalDAVError.authFailed),
                "reason: \(rows.first?.failureReason ?? "<none>")")
        let after = try Self.stored(run)
        #expect(after == seed, Comment(rawValue: after))
    }

    @Test("T3: a failed lookup is never kept: the retry asks again and writes the user's address")
    func failedLookupIsNotKept() async throws {
        let run = Self.setUp([F.path: F.series()], firstAddressSetAnswer: .status(503))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-retry", drains: 2)
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: after))
        #expect(run.principal.addressSetLookups == 2, "the address set was read \(run.principal.addressSetLookups) times")
    }

    @Test("T4: an answer that can't be read, or a server with no principal, means none advertised",
          arguments: ["parse", "discovery"])
    func unreadableOrNoPrincipalMeansNone(_ failure: String) async throws {
        let noPrincipal = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href>\
        <d:propstat><d:prop><d:displayname>Server</d:displayname></d:prop>\
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """
        let run = failure == "parse"
            ? Self.setUp([F.path: F.series()], refuses: false,
                         addressSetAnswer: .raw(statusCode: 207, body: Data("this is not xml".utf8)))
            : Self.setUp([F.path: F.series()], refuses: false,
                         principalAnswer: .raw(statusCode: 207, body: Data(noPrincipal.utf8)))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-lookup-\(failure)")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
    }

    @Test("T5: a principal the server can't find is not 'event not found': the write goes ahead with no organizer")
    func discovery404IsNotEventNotFound() async throws {
        let run = Self.setUp([F.path: F.series()], refuses: false, principalAnswer: .status(404))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-discovery-404")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        #expect(run.principal.addressSetLookups == 0)
        // Both the `.well-known` try and the direct one were answered 404.
        #expect(run.propfinds == 2, "\(run.http.servedCallSequence())")
    }

    @Test("T6: a split whose capped series alone needs the address looks it up before its first PUT")
    func splitLooksUpBeforeItsFirstPut() async throws {
        // Guests on a changed occurrence BEFORE the split point: they stay with the capped series,
        // and the new part, copied from the guest-less series, needs no organizer.
        let earlier = F.start.addingTimeInterval(7 * 86_400)
        let override = [
            "BEGIN:VEVENT", "UID:\(F.uid)", "RECURRENCE-ID:\(F.icsUTC(earlier))", "DTSTAMP:\(F.icsUTC(F.start))",
            "DTSTART:\(F.icsUTC(earlier))", "DURATION:PT1H", "SUMMARY:Planning, with a guest",
            "ATTENDEE;CN=Guest:mailto:\(F.guest)", "END:VEVENT",
        ]
        var lines = F.series().components(separatedBy: "\r\n")
        let end = try #require(lines.lastIndex(of: "END:VCALENDAR"))
        lines.insert(contentsOf: override, at: end)
        let seed = lines.joined(separator: "\r\n")
        let run = Self.setUp([F.path: seed], refuses: false, addressSetAnswer: .status(503))
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.scoped(F.rename, "this_and_following"), account: "org711-split-capped-only")
        #expect(run.puts.isEmpty, "a PUT was sent before the lookup's answer: \(run.puts.map(\.path))")
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.queued.rawValue,
                "the edit is not queued: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        let after = try Self.stored(run)
        #expect(after == seed, Comment(rawValue: after))
        #expect(run.store.storedICS(path: F.newPartPath) == nil, "the new part was written")
        #expect(run.principal.addressSetLookups == 1)
    }

    // MARK: 14-16: nothing to add

    @Test("14: a title edit of an event with no guests anywhere makes no lookup and writes no organizer")
    func noGuestsNoLookup() async throws {
        let run = Self.setUp([F.path: F.series()])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.rename, account: "org711-no-guests")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
    }

    @Test("15: an email alert's recipient is not a guest: no lookup, no organizer")
    func alarmAttendeeIsNotAGuest() async throws {
        let alarm = ["BEGIN:VALARM", "ACTION:EMAIL", "SUMMARY:Reminder", "DESCRIPTION:Soon",
                     "ATTENDEE:mailto:alerts@example.com", "TRIGGER:-PT15M", "END:VALARM"]
        let run = Self.setUp([F.path: F.series(alarm)])
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.rename, account: "org711-alarm")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
    }

    @Test("16: a resource that holds only someone else's changed occurrence never gets the account's address")
    func overridesOnlyNeverGetsTheAccountsAddress() async throws {
        let seed = F.overridesOnly(["ATTENDEE:mailto:alice@example.com", "ATTENDEE:mailto:user@example.com"])
        let run = Self.setUp([F.path: seed], refuses: false)
        defer { run.http.close() }
        let occurrenceId = "\(F.path)#\(F.icsUTC(F.occurrence))"
        // Through the provider's one-occurrence edit, as `CalDAVOccurrenceWireTests` edits such a
        // resource: the queue's series read (`CalendarSeriesScope.read`) reads its series first.
        var patch = GCalEventInput()
        patch.summary = "Planning, new agenda"
        _ = try await run.provider.updateOccurrence(
            calendarId: F.calendarId, eventId: occurrenceId, recurrenceId: F.naiveUTC(F.occurrence),
            recurrenceIdZone: try #require(TimeZone(identifier: "UTC")), event: patch, sendUpdates: "all")
        #expect(run.puts.map(\.path) == [F.path], "PUTs: \(run.puts.map(\.path))")
        let after = try Self.stored(run)
        #expect(after.contains("SUMMARY:Planning\\, new agenda"), Comment(rawValue: after))
        #expect(!after.contains("ORGANIZER"), Comment(rawValue: after))
        #expect(run.propfinds == 0, "the address set was read: \(run.http.servedCallSequence())")
    }

    // MARK: 17-19: once per provider, a hostile href, a replay

    @Test("17: two guest writes on one provider read the address set once")
    func addressSetIsReadOnce() async throws {
        let other = "/cal/org-711-b.ics"
        let run = Self.setUp([F.path: F.series(), other: F.series(uid: "org-711-b")])
        defer { run.http.close() }
        let first = try await Self.edit(run, F.addGuest, account: "org711-once-a")
        let second = try await Self.edit(run, F.addGuest, account: "org711-once-b", eventId: other)
        #expect(first.isEmpty && second.isEmpty, Self.landed(first + second))
        for path in [F.path, other] {
            let resource = try Self.stored(run, path)
            #expect(F.masterOwn(resource, "ORGANIZER") == ["ORGANIZER:\(F.own)"],
                    Comment(rawValue: resource))
        }
        #expect(run.principal.addressSetLookups == 1, "the address set was read \(run.principal.addressSetLookups) times")
    }

    @Test("17b: an answer read as none is not kept: the next guest write on the provider asks again")
    func noneIsNotKept() async throws {
        let other = "/cal/org-711-b.ics"
        let run = Self.setUp([F.path: F.series(), other: F.series(uid: "org-711-b")], refuses: false,
                             firstAddressSetAnswer: .status(403))
        defer { run.http.close() }
        let first = try await Self.edit(run, F.addGuest, account: "org711-none-once-a")
        let second = try await Self.edit(run, F.addGuest, account: "org711-none-once-b", eventId: other)
        #expect(first.isEmpty && second.isEmpty, Self.landed(first + second))
        let firstResource = try Self.stored(run)
        #expect(!firstResource.contains("ORGANIZER"), Comment(rawValue: firstResource))
        let secondResource = try Self.stored(run, other)
        #expect(F.masterOwn(secondResource, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: secondResource))
        #expect(run.principal.addressSetLookups == 2, "the address set was read \(run.principal.addressSetLookups) times")
    }

    @Test("18: an advertised href with a line break in it is skipped, and never adds a property")
    func hrefWithLineBreakIsSkipped() async throws {
        let advertised = ["mailto:user@example.com\r\nATTENDEE:mailto:intruder@example.com", "mailto:alias@example.com"]
        let seed = F.series()
        let run = Self.setUp([F.path: seed], refuses: false, advertised: advertised)
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-hostile")
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(!after.contains("intruder"), Comment(rawValue: after))
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:mailto:alias@example.com"],
                Comment(rawValue: after))
    }

    @Test("19: a replay after a lost PUT response leaves the server byte for byte as the first write left it")
    func replayAfterLostResponse() async throws {
        let seed = F.series()
        let lostResponse = LostFirstResponse()
        let run = Self.setUp([F.path: seed], put: { store, request in
            let answer = store.handlePUT(request)
            guard lostResponse.take(store.storedICS(path: request.url.path)) else { return answer }
            return .transportError(.timedOut)
        })
        defer { run.http.close() }
        let rows = try await Self.edit(run, F.addGuest, account: "org711-replay", drains: 2)
        #expect(rows.isEmpty, Self.landed(rows))
        let first = try #require(lostResponse.storedAfterFirst, "the first PUT did not land")
        #expect(F.masterOwn(first, "ORGANIZER") == ["ORGANIZER:\(F.own)"],
                Comment(rawValue: first))
        let after = try Self.stored(run)
        #expect(after == first, "the replay changed the server:\n\(after)")
        #expect(run.puts.count == 2, "PUTs: \(run.puts.map(\.path))")
    }

    // MARK: 20: the delete of one occurrence

    @Test("20: deleting one occurrence of a series whose guests have no organizer writes its EXDATE with the user's address")
    func occurrenceDeleteGetsTheOrganizer() async throws {
        let seed = F.series(["ATTENDEE;CN=Guest:mailto:\(F.guest)"])
        let run = Self.setUp([F.path: seed])
        defer { run.http.close() }
        let occurrence = CalDAVOccurrences.OccurrenceId.make(seriesHref: F.path, key: F.icsUTC(F.occurrence))
        let rows = try await drainCalendarOperation(
            type: .delete, accountId: "org711-occurrence-delete", eventId: occurrence, calendarId: F.calendarId,
            arguments: [:], provider: run.provider)
        #expect(rows.isEmpty, Self.landed(rows))
        let after = try Self.stored(run)
        #expect(F.masterOwn(after, "ORGANIZER") == ["ORGANIZER:\(F.own)"], Comment(rawValue: after))
        #expect(F.masterOwn(after, "ATTENDEE").compactMap(VEventOracle.address) == [F.guest])
        let exdates = F.masterOwn(after, "EXDATE")
        #expect(exdates.count == 1 && exdates.first?.hasSuffix(":\(F.icsUTC(F.occurrence))") == true, Comment(rawValue: after))
        #expect(run.puts.count == 1, "PUTs: \(run.puts.map(\.path))")
        F.expectInvariant(before: seed, after: after, advertised: F.advertised)
    }
}

/// The first `PUT` lands on the server and its response is lost.
private final class LostFirstResponse: Sendable {
    private let state = Mutex<(taken: Bool, stored: String?)>((false, nil))

    /// True for the first `PUT` only, recording what the server held after it.
    func take(_ stored: String?) -> Bool {
        state.withLock { value in
            guard !value.taken else { return false }
            value = (true, stored)
            return true
        }
    }

    var storedAfterFirst: String? { state.withLock { $0.stored } }
}

// MARK: - The organizer step, the chooser and the PUT fence

/// The pure step every CalDAV PUT runs (`CalDAVProvider.organized`), the address chooser
/// (`organizerHref`), and the fence that keeps every PUT going through `putEvent`.
@Suite("CalDAV organizer step")
struct CalDAVOrganizerStepTests {

    private static func ics(_ lines: [String]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//EN"] + lines + ["END:VCALENDAR"])
            .joined(separator: "\r\n") + "\r\n"
    }

    private static let series = [
        "BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H",
        "RRULE:FREQ=WEEKLY", "SUMMARY:Sync",
        "ATTENDEE;CN=Guest:mailto:guest@example.com", "END:VEVENT",
    ]

    private static func override(_ extra: [String]) -> [String] {
        ["BEGIN:VEVENT", "UID:step-1", "RECURRENCE-ID:20990520T170000Z",
         "DTSTART:20990520T170000Z", "DURATION:PT1H", "SUMMARY:Sync"] + extra + ["END:VEVENT"]
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\r\n")
    }

    @Test("a body that needs no organizer is returned byte for byte", arguments: [
        // Organizer already there.
        ["BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H", "SUMMARY:Sync",
         "ORGANIZER:mailto:other@example.com", "ATTENDEE:mailto:guest@example.com", "END:VEVENT"],
        // No guests.
        ["BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H", "SUMMARY:Sync", "END:VEVENT"],
        // An EMAIL alarm's attendee is the alarm's.
        ["BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H", "SUMMARY:Sync",
         "BEGIN:VALARM", "ACTION:EMAIL", "TRIGGER:-PT15M", "SUMMARY:Soon", "DESCRIPTION:Soon",
         "ATTENDEE:mailto:guest@example.com", "END:VALARM", "END:VEVENT"],
        // A series with its organizer and guests, and a changed occurrence with neither: no VEVENT
        // has an attendee without an organizer, so the occurrence gets nothing.
        ["BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H", "RRULE:FREQ=WEEKLY",
         "SUMMARY:Sync", "ORGANIZER:mailto:other@example.com", "ATTENDEE:mailto:guest@example.com", "END:VEVENT",
         "BEGIN:VEVENT", "UID:step-1", "RECURRENCE-ID:20990520T170000Z", "DTSTART:20990520T170000Z",
         "DURATION:PT1H", "SUMMARY:Sync", "END:VEVENT"],
    ])
    func untouched(_ vevent: [String]) {
        let body = Self.ics(vevent)
        #expect(CalDAVProvider.organized(body, own: "mailto:user@example.com") == body)
        #expect(!CalDAVProvider.needsOwnAddress(body))
    }

    @Test("the own address goes in right after UID, and nothing else changes")
    func ownAfterUID() throws {
        let body = Self.ics(Self.series)
        #expect(CalDAVProvider.needsOwnAddress(body))
        let out = Self.lines(CalDAVProvider.organized(body, own: "mailto:user@example.com"))
        var expected = Self.lines(body)
        let uid = try #require(expected.firstIndex(of: "UID:step-1"))
        expected.insert("ORGANIZER:mailto:user@example.com", at: uid + 1)
        #expect(out == expected)
    }

    @Test("with no own address and nothing to copy, nothing is written")
    func noAddressNoOrganizer() {
        let body = Self.ics(Self.series)
        #expect(CalDAVProvider.organized(body, own: nil) == body)
    }

    @Test("an override takes the series' folded organizer, every physical line, ahead of its own guest")
    func foldedCopy() throws {
        let organizer = ["ORGANIZER;CN=\"Olivia Organizer of the Weekly Sync\";SENT-BY=\"mailto:as", " sistant@example.com\":mailto:olivia@example.com"]
        var seriesLines = Self.series
        seriesLines.insert(contentsOf: organizer, at: 2)
        let body = Self.ics(seriesLines + Self.override(["ATTENDEE:mailto:guest@example.com"]))
        #expect(!CalDAVProvider.needsOwnAddress(body))
        let out = Self.lines(CalDAVProvider.organized(body, own: "mailto:user@example.com"))
        let overrideStart = try #require(out.lastIndex(of: "BEGIN:VEVENT"))
        let overrideLines = Array(out[overrideStart...])
        #expect(overrideLines.contains("RECURRENCE-ID:20990520T170000Z"))
        let at = try #require(overrideLines.firstIndex(of: organizer[0]))
        let guest = try #require(overrideLines.firstIndex(of: "ATTENDEE:mailto:guest@example.com"))
        guard overrideLines.count > at + 1 else { return }
        #expect(overrideLines[at + 1] == organizer[1])
        #expect(at < guest)
        #expect(!out.contains("ORGANIZER:mailto:user@example.com"))
    }

    @Test("a series without an organizer takes its override's")
    func seriesTakesOverrides() {
        let body = Self.ics(Self.series + Self.override(["ORGANIZER:mailto:other@example.com", "ATTENDEE:mailto:guest@example.com"]))
        #expect(!CalDAVProvider.needsOwnAddress(body))
        let out = CalDAVProvider.organized(body, own: "mailto:user@example.com")
        #expect(Self.lines(out).filter { $0 == "ORGANIZER:mailto:other@example.com" }.count == 2)
        #expect(!out.contains("user@example.com"))
    }

    @Test("once one VEVENT needs an organizer, every VEVENT without one gets the same one; one that has its own keeps it")
    func everyComponentGetsTheOrganizer() {
        let guestless = ["BEGIN:VEVENT", "UID:step-1", "DTSTART:20990506T170000Z", "DURATION:PT1H",
                         "RRULE:FREQ=WEEKLY", "SUMMARY:Sync", "END:VEVENT"]
        let other = ["BEGIN:VEVENT", "UID:step-1", "RECURRENCE-ID:20990513T170000Z",
                     "DTSTART:20990513T180000Z", "DURATION:PT1H", "SUMMARY:Sync", "END:VEVENT"]
        // The account's address: the series and both changed occurrences.
        let body = Self.ics(guestless + other + Self.override(["ATTENDEE:mailto:guest@example.com"]))
        #expect(CalDAVProvider.needsOwnAddress(body))
        let out = Self.lines(CalDAVProvider.organized(body, own: "mailto:user@example.com"))
        #expect(out.filter { $0 == "ORGANIZER:mailto:user@example.com" }.count == 3, Comment(rawValue: out.joined(separator: "\n")))
        // A copied organizer: the occurrence that names one keeps it; the one given a guest and the
        // guest-less series take it.
        var otherWithGuest = other
        otherWithGuest.insert("ATTENDEE:mailto:guest@example.com", at: otherWithGuest.count - 1)
        let named = Self.ics(guestless + otherWithGuest + Self.override([
            "ORGANIZER;CN=Other:mailto:other@example.com", "ATTENDEE:mailto:guest@example.com",
        ]))
        let copied = Self.lines(CalDAVProvider.organized(named, own: "mailto:user@example.com"))
        #expect(copied.filter { $0 == "ORGANIZER;CN=Other:mailto:other@example.com" }.count == 3,
                Comment(rawValue: copied.joined(separator: "\n")))
        #expect(!copied.contains { $0.contains("user@example.com") })
        // Nothing needs one: a VEVENT without an organizer is left alone.
        let quiet = Self.ics(guestless + Self.override(["ORGANIZER:mailto:other@example.com"]))
        #expect(CalDAVProvider.organized(quiet, own: "mailto:user@example.com") == quiet)
    }

    @Test("a resource of changed occurrences only never gets the account's address")
    func overridesOnly() {
        let body = Self.ics(Self.override(["ATTENDEE:mailto:guest@example.com"]))
        #expect(!CalDAVProvider.needsOwnAddress(body))
        #expect(CalDAVProvider.organized(body, own: "mailto:user@example.com") == body)
    }

    @Test("the step is idempotent")
    func idempotent() {
        for body in [Self.ics(Self.series), Self.ics(Self.series + Self.override(["ATTENDEE:mailto:guest@example.com"]))] {
            let once = CalDAVProvider.organized(body, own: "mailto:user@example.com")
            #expect(CalDAVProvider.organized(once, own: "mailto:alias@example.com") == once)
            #expect(!CalDAVProvider.needsOwnAddress(once))
        }
    }

    @Test("the chooser", arguments: [
        (["urn:uuid:0711", "mailto:alias@example.com", "mailto:User@Example.com", "/principals/user/"],
         "user@example.com", Optional("mailto:User@Example.com")),
        (["mailto:alias@example.com", "mailto:second@example.com"], "user@example.com", Optional("mailto:alias@example.com")),
        (["urn:uuid:0711", "/principals/user/", "mailto:"], "user@example.com", nil),
        ([], "user@example.com", nil),
        (["mailto:intruder@example.com\r\nATTENDEE:mailto:x@example.com", "mailto:alias@example.com"],
         "intruder@example.com", Optional("mailto:alias@example.com")),
        (["MAILTO:user@example.com"], "user", Optional("MAILTO:user@example.com")),
        // The sign-in as the user typed it: any letter case, surrounding spaces.
        (["mailto:alias@example.com", "mailto:user@example.com"], "User@Example.com", Optional("mailto:user@example.com")),
        (["mailto:alias@example.com", "mailto:user@example.com"], "  user@example.com ", Optional("mailto:user@example.com")),
    ])
    func chooser(_ advertised: [String], _ signIn: String, _ expected: String?) {
        #expect(CalDAVProvider.organizerHref(advertised: advertised, signIn: signIn) == expected)
    }

    @Test("every CalDAV PUT goes through putEvent: one client.put call site")
    func onePutCallSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Providers
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        // `CalDAVClient.put(url:body:precondition:)`, whatever the receiver is called and however
        // the call is wrapped.
        let call = try NSRegularExpression(pattern: #"\.put\(\s*(url\s*:|$)"#)
        var sites: [String] = []
        var scanned = 0
        for directory in ["TabMail", "Shared", "TabMailNotificationService"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                scanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for (number, line) in source.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    let range = NSRange(code.startIndex..., in: code)
                    if call.firstMatch(in: code, range: range) != nil { sites.append("\(url.lastPathComponent):\(number + 1)") }
                }
            }
        }
        #expect(scanned > 100, "the scan found the sources")
        try #require(sites.count == 1 && sites.first?.hasPrefix("CalDAVProvider.swift:") == true, Comment(rawValue: sites.joined(separator: ", ")))
        let provider = try String(contentsOf: root.appendingPathComponent("TabMail/Providers/CalDAV/CalDAVProvider.swift"), encoding: .utf8)
        let putEvent = try #require(provider.range(of: "private func putEvent("))
        let put = try #require(provider.range(of: "client.put(", range: putEvent.upperBound..<provider.endIndex))
        let body = provider[putEvent.upperBound..<put.lowerBound]
        #expect(body.contains("withOrganizer(") && !body.contains("\n    }\n"), "client.put is called inside putEvent, after the organizer step")
    }
}
