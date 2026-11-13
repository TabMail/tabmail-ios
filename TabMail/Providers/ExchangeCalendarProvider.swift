/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Microsoft Graph Calendar API provider for Exchange/Outlook accounts.
/// Mirrors `GoogleCalendarProvider` actor pattern — same `accessToken` closure, same retry logic.
/// Conforms to `CalendarProvider` protocol — maps Graph responses to shared `GCalEvent`/`GCalCalendar` models.
actor ExchangeCalendarProvider: CalendarProvider {
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let baseURL = "https://graph.microsoft.com/v1.0/me"
    /// The mailbox's Graph concurrency limit (#426): the same gate as the
    /// mailbox's `ExchangeProvider`, so calendar and mail requests share Graph's
    /// four concurrent requests per mailbox.
    private let mailboxGate: HTTPConcurrencyGate
    /// Test-only transport override. `nil` on every production path, where
    /// `performHTTPRequest` falls back to `sharedEphemeralSession`.
    private let testSession: URLSession?

    /// - Parameter mailbox: the address of the Outlook mailbox this calendar
    ///   belongs to; it selects the mailbox's gate (`GraphMailboxGates.gate(for:)`).
    init(
        mailbox: String,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String
    ) {
        self.init(mailbox: mailbox, accessToken: accessToken, testSession: nil)
    }

    /// Explicit-session initializer, used by tests to route this provider's HTTP
    /// through `FakeHTTP`. A separate initializer with a NON-optional session,
    /// for the reason `GoogleCalendarProvider`'s twin gives: a nil-defaulted seam
    /// that is silently dropped leaves a unit test talking to the live service.
    ///
    /// It exists because whether calendar and mail requests of one mailbox share
    /// Graph's four concurrent requests is a property of the transport, visible
    /// only at the wire.
    init(
        mailbox: String,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        session: URLSession
    ) {
        self.init(mailbox: mailbox, accessToken: accessToken, testSession: session)
    }

    /// The one place the mailbox's gate is chosen, so the production and test
    /// initializers cannot pick different gates.
    private init(
        mailbox: String,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        testSession: URLSession?
    ) {
        self.accessToken = accessToken
        self.mailboxGate = GraphMailboxGates.gate(for: mailbox)
        self.testSession = testSession
    }

    // MARK: - Calendars

    func listCalendars() async throws -> [GCalCalendar] {
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listCalendars starting...")
        let data = try await request(path: "/calendars?$select=id,name,isDefaultCalendar,color")
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listCalendars raw: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
        let response = try JSONDecoder().decode(MSCalendarListResponse.self, from: data)
        return response.value.map { cal in
            GCalCalendar(
                id: cal.id,
                summary: cal.name,
                primary: cal.isDefaultCalendar,
                accessRole: "owner",
                backgroundColor: msColorToHex(cal.color),
                selected: nil
            )
        }
    }

    func primaryCalendarId() async throws -> String {
        let calendars = try await listCalendars()
        let primary = calendars.first(where: { $0.primary == true })?.id ?? "primary"
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] primaryCalendarId = \(primary)")
        return primary
    }

    // MARK: - Events

    func listEvents(
        calendarId: String = "primary",
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        query: String? = nil,
        singleEvents: Bool = true,
        maxResults: Int = 250,
        orderBy: String = "startTime"
    ) async throws -> [GCalEvent] {
        var queryItems: [String] = []
        queryItems.append("$top=\(maxResults)")
        queryItems.append("$orderby=start/dateTime")
        queryItems.append("$select=\(Self.eventSelect)")

        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = try Self.encodedGraphPathSegment(calendarId, context: "Graph calendar id")
            calPath = "/calendars/\(encodedCalId)"
        }

        // Use calendarView for time-windowed queries (expands recurring events), events endpoint otherwise
        let endpoint: String
        if let timeMin, let timeMax {
            // startDateTime/endDateTime are calendarView-only params
            queryItems.append("startDateTime=\(timeMin.iso8601String())")
            queryItems.append("endDateTime=\(timeMax.iso8601String())")
            endpoint = "\(calPath)/calendarView?\(queryItems.joined(separator: "&"))"
        } else {
            // Without both time bounds, use events endpoint with $filter
            var filterParts: [String] = []
            if let timeMin { filterParts.append("start/dateTime ge '\(timeMin.iso8601String())'") }
            if let timeMax { filterParts.append("end/dateTime le '\(timeMax.iso8601String())'") }
            if !filterParts.isEmpty {
                queryItems.append("$filter=\(filterParts.joined(separator: " and "))")
            }
            endpoint = "\(calPath)/events?\(queryItems.joined(separator: "&"))"
        }

        // Apply query filter client-side if provided (Graph calendarView doesn't support $search)
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listEvents endpoint: \(endpoint)")
        let data = try await request(path: endpoint)
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listEvents response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
        let response = try JSONDecoder().decode(MSEventListResponse.self, from: data)

        var events = response.value
            .filter { $0.isCancelled != true }
            .filter { e in
                if isEmptySurfaceEvent(e) {
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] dropping empty event id=\(e.id ?? "nil")")
                    return false
                }
                return true
            }
            .map { toGCalEvent($0) }

        if let query, !query.isEmpty {
            let lower = query.lowercased()
            events = events.filter { event in
                (event.summary ?? "").lowercased().contains(lower) ||
                (event.location ?? "").lowercased().contains(lower) ||
                (event.description ?? "").lowercased().contains(lower)
            }
        }

        return events
    }

    /// What an event read selects (`listEvents`, `getEvent`, and an edit's
    /// `fetchForEdit`). `body` and `onlineMeeting` give the description and the
    /// join link (`notes(of:)`), and the stored body an edit keeps (#511).
    /// `originalStart` gives an occurrence's place in its series (`originalStartTime`).
    private static let eventSelect = "id,subject,location,body,bodyPreview,onlineMeeting,start,end,attendees,organizer,recurrence,showAs,isCancelled,webLink,createdDateTime,lastModifiedDateTime,isAllDay,seriesMasterId,originalStart,originalStartTimeZone"

    /// What a split reads from the stored series: what `getEvent` reads, and every property the
    /// new part copies (`splitCopiedKeys`).
    private static let splitSelect = eventSelect
        + ",importance,sensitivity,categories,isReminderOn,reminderMinutesBeforeStart,locations,responseRequested,allowNewTimeProposals,hideAttendees"

    /// The stored series' properties a split's new part copies as they are; Graph accepts each on a
    /// create. Attendees, start, end and recurrence are written by `splitNewPartJSON` itself.
    private static let splitCopiedKeys: Set<String> = [
        "subject", "body", "importance", "sensitivity", "showAs", "categories", "isReminderOn",
        "reminderMinutesBeforeStart", "location", "locations", "isAllDay", "responseRequested",
        "allowNewTimeProposals", "hideAttendees",
    ]

    func getEvent(calendarId: String = "primary", eventId: String) async throws -> GCalEvent {
        let encodedEventId = try Self.encodedGraphPathSegment(eventId, context: "Graph event id")
        let data = try await request(path: "/events/\(encodedEventId)?$select=\(Self.eventSelect)")
        let event = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(event)
    }

    /// The exact JSON body `createEvent` POSTs — `toGraphEventJSON` plus Graph's
    /// client-supplied idempotency key.
    ///
    /// 🚨 A PLAIN `POST /events` IS NOT IDEMPOTENT, AND THE QUEUE NOW RETRIES IT
    /// (R12-T5). `AccountManagerCalendarQueue` classifies `408 Request Timeout`
    /// as INDETERMINATE — correctly: the server gave up waiting and the write may
    /// or may not have landed, so retiring the op would drop the user's
    /// intention. But `toGraphEventJSON` never reads `input.id`, so a retry after
    /// a committed-then-408 create sent Graph a brand-new event: **two events on
    /// the calendar, and potentially two invitations to every attendee**. Both
    /// are authoritative server objects, so no sync converges them back to one
    /// and the user has to find and delete the duplicate by hand.
    ///
    /// Graph dedupes POSTs by `transactionId` within a bounded window, which is
    /// exactly this problem — and `ExchangeCalendarProvider.splitSeries` already
    /// uses that mechanism for lost-ACK dedup on its own create. This follows
    /// that existing pattern rather than inventing one.
    ///
    /// ⚠️ CORRECTED 2026-08-06 (R13-U3). This paragraph used to end *"the drain's
    /// `catch ExchangeCalendarError.httpError(409, _)` arm already treats Graph's
    /// duplicate-transaction refusal as success"* — and that arm has been removed,
    /// because Microsoft documents no such refusal. `transactionId` is defined as a
    /// value *"for the server to AVOID REDUNDANT POST operations in case of client
    /// retries"*: a deduped retry receives the ORIGINAL success response, not a
    /// conflict. Graph's calendar-POST 409s are store-level save conflicts. The
    /// idempotency this method provides is therefore what makes the RETRY safe, and
    /// it never depended on a 409 arm; the arm was leaning on this comment and this
    /// comment was leaning on the arm.
    ///
    /// The key is the queue's own durable pre-generated event id
    /// (`if let pregenId = op.eventId { input.id = pregenId }`), so it is stable
    /// across retries of ONE op and distinct for every distinct user create —
    /// two genuinely separate "book the same meeting twice" requests carry
    /// different UUID-derived ids and both go through.
    ///
    /// ⚠️ THE COUNTERFACTUAL. Doing nothing keeps the duplicate-event exposure.
    /// The mirror image — restoring shipped's "408 retires the op" — reinstates
    /// the dropped intention the round-11 fix removed, and drops it on
    /// *"we could not determine the answer"*, which never-drop clause 2 names as
    /// retryable, never authoritative. Idempotency is the disposition that is
    /// neither.
    ///
    /// ⚠️ The length guard is a real Graph constraint (`transactionId` is capped
    /// at 256 characters), not defensive padding: an over-long value makes Graph
    /// reject the whole create with a 400, which `isCalendarBadRequestError`
    /// retires — turning an idempotency measure into a dropped intention. An id
    /// past the cap simply degrades to today's non-idempotent behaviour.
    nonisolated func createEventJSON(_ event: GCalEventInput) -> [String: Any] {
        var json = toGraphEventJSON(event)
        if let pregenId = event.id, !pregenId.isEmpty, pregenId.count <= 256 {
            json["transactionId"] = pregenId
        }
        return json
    }

    func createEvent(
        calendarId: String = "primary",
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = try Self.encodedGraphPathSegment(calendarId, context: "Graph calendar id")
            calPath = "/calendars/\(encodedCalId)"
        }

        try Self.refuseUnrepresentableRule(event.recurrence)
        let body = try JSONSerialization.data(withJSONObject: createEventJSON(event))
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: body, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] createEvent POST body=\(bodyStr.prefix(4000))")
            }
        }
        let data = try await request(path: "\(calPath)/events", method: "POST", body: body)
        if DebugModeManager.isLoggingEnabled() {
            if let respStr = String(data: data, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] createEvent response=\(respStr.prefix(4000))")
            }
        }
        let created = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(created)
    }

    func updateEvent(
        calendarId: String = "primary",
        eventId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // PATCH ONLY WHAT THE USER CHANGED (#421). Graph's event-update: "supply
        // only the values for properties to update. Existing properties that
        // aren't included in the request body maintain their previous values".
        // This used to merge the patch onto a read and PATCH every property back,
        // and the read is lossy: `showAs` comes back as free or busy, `locations`
        // as one display name, every attendee as required, and a series'
        // recurrence rebuilt from an RRULE, which resets the series' exceptions
        // (#423). The description was then the 255-character `bodyPreview`; it is
        // now the full notes (`notes(of:)`). Every edit wrote all of that back.
        // `graphPatchJSON` says what rides along and why.
        try Self.refuseUnrepresentableRule(event.recurrence)
        let existing = try await fetchForEdit(eventId: eventId)
        let json = try graphPatchJSON(patch: event, existing: existing, allowRecurrence: true)
        guard !json.isEmpty else {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateEvent: the edit changes nothing — no PATCH")
            return existing.event
        }
        let encodedEventId = try Self.encodedGraphPathSegment(eventId, context: "Graph event id")
        let body = try JSONSerialization.data(withJSONObject: json)
        // Dump the body so we can diagnose date/tz drift in smoke tests.
        // Graph responses are silent on success; without this we can't tell
        // if a wrong-time symptom came from a wrong-time request.
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: body, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateEvent PATCH body=\(bodyStr.prefix(4000))")
            }
        }
        let data = try await request(path: "/events/\(encodedEventId)", method: "PATCH", body: body)
        if DebugModeManager.isLoggingEnabled() {
            if let respStr = String(data: data, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateEvent response=\(respStr.prefix(4000))")
            }
        }
        let updated = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(updated)
    }

    func deleteEvent(
        calendarId: String = "primary",
        eventId: String,
        sendUpdates: String = "all"
    ) async throws {
        let encodedEventId = try Self.encodedGraphPathSegment(eventId, context: "Graph event id")
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] deleteEvent id=\(eventId)")
        _ = try await request(path: "/events/\(encodedEventId)", method: "DELETE")
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] deleteEvent success")
    }

    /// Single-occurrence override (this_only): Graph exposes occurrences as
    /// distinct event resources via `/events/{master}/instances?startDateTime&endDateTime`.
    /// We find the instance whose start matches `recurrenceId`, then PATCH it
    /// directly — Graph materializes the override.
    func updateOccurrence(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // The agent often passes an INSTANCE id (Graph instance events carry
        // their parent's id in `seriesMasterId`). Graph's
        // `/events/{id}/instances` endpoint requires the master id — resolve
        // via seriesMasterId before the instance lookup.
        let named = eventId
        let (eventId, master) = try await resolveToMaster(eventId: eventId)
        let instanceId = try await resolveInstanceId(
            masterId: eventId, series: master.event, recurrenceId: recurrenceId, zone: recurrenceIdZone,
            naming: named == eventId ? nil : named)
        return try await patchOccurrence(instanceId: instanceId, event: event)
    }

    /// The write of a "this occurrence" edit onto the occurrence `instanceId` (`updateOccurrence`,
    /// and a split's edit of an occurrence where it is).
    private func patchOccurrence(instanceId: String, event: GCalEventInput) async throws -> GCalEvent {
        let encodedInstanceId = try Self.encodedGraphPathSegment(instanceId, context: "Graph event instance id")
        // Only the properties the user changed, as in `updateEvent` (#421), and
        // never `recurrence`: an instance cannot carry a series rule and Graph
        // 400s on a PATCH that includes one.
        let existingInstance = try await fetchForEdit(eventId: instanceId)
        let json = try graphPatchJSON(patch: event, existing: existingInstance, allowRecurrence: false)
        guard !json.isEmpty else {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateOccurrence: the edit changes nothing — no PATCH")
            return existingInstance.event
        }
        let body = try JSONSerialization.data(withJSONObject: json)
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: body, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateOccurrence PATCH body=\(bodyStr.prefix(4000))")
            }
        }
        let data = try await request(path: "/events/\(encodedInstanceId)", method: "PATCH", body: body)
        if DebugModeManager.isLoggingEnabled() {
            if let respStr = String(data: data, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateOccurrence response=\(respStr.prefix(4000))")
            }
        }
        let updated = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(updated)
    }

    /// The occurrence of `eventId`'s series that starts at `recurrenceId` now
    /// (`CalendarProvider.occurrence`): the one `updateOccurrence` would change, found by the same
    /// lookup (`resolveInstanceId`), read as `getEvent` reads it (with its `originalStart`).
    /// Nothing is written. A moved occurrence is found here; only `splitSeries` refuses a split at
    /// one.
    func occurrence(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone
    ) async throws -> GCalEvent {
        let (masterId, master) = try await resolveToMaster(eventId: eventId)
        return try await occurrence(
            named: eventId, masterId: masterId, series: master.event,
            recurrenceId: recurrenceId, zone: recurrenceIdZone)
    }

    /// `occurrence`, with the series already read (`resolveToMaster`): `named` is the id the edit
    /// gave, `masterId` its series, `series` the series as read. Also the split's own lookup
    /// (`splitSeries`).
    ///
    /// An occurrence of an all-day series is read in the series' own zone (`allDayOccurrence`), so
    /// its place in the series is a date.
    private func occurrence(
        named: String, masterId: String, series: GCalEvent, recurrenceId: String, zone: TimeZone
    ) async throws -> GCalEvent {
        let instanceId = try await resolveInstanceId(
            masterId: masterId, series: series, recurrenceId: recurrenceId, zone: zone, naming: named == masterId ? nil : named)
        guard series.isAllDay else { return try await getEvent(eventId: instanceId) }
        return try await allDayOccurrence(instanceId: instanceId, series: series)
    }

    /// The all-day occurrence `instanceId` of `series`, its place in the series
    /// (`originalStartTime`) given as a date: the date of Graph's `originalStart`, read in the
    /// series' own zone.
    ///
    /// Measured (2026-11-11, all-day series in Pacific Standard Time, Tokyo Standard Time and
    /// Asia/Kathmandu, a plain and a moved occurrence each, read by id and in `/instances`): an
    /// all-day occurrence's `originalStart` is the instant its original date begins in the series'
    /// zone. Read with `Prefer: outlook.timezone` naming that zone, it is written as that local
    /// midnight with the zone's offset (`…-11-20T00:00:00+09:00`), so its date text is the original
    /// date. Read in UTC (no `Prefer`, or `Prefer` UTC) it is the UTC instant, the day before for a
    /// zone ahead of UTC. So the read names the series' zone exactly as Graph gave it
    /// (`recurrence.range.recurrenceTimeZone`, a Windows or an IANA name) and the date is taken as
    /// text: no zone is looked up on the device, so a zone TabMail does not recognize is read the
    /// same way. A series whose range names no zone is refused, with nothing written: the date of
    /// its occurrences' places is not known (Graph names one on every series read so far; a range
    /// written without one is read back as UTC, measured 2026-11-07).
    private func allDayOccurrence(instanceId: String, series: GCalEvent) async throws -> GCalEvent {
        guard let seriesZone = series.recurrenceTimeZoneName else {
            throw CalendarProviderError.notSupported(
                "Outlook gives no time zone for this all-day repeating event, so the date of the occurrence named can't be read; change it in your calendar app instead")
        }
        let encodedInstanceId = try Self.encodedGraphPathSegment(instanceId, context: "Graph event id")
        let data = try await request(
            path: "/events/\(encodedInstanceId)?$select=\(Self.eventSelect)", timeZoneName: seriesZone)
        let read = try JSONDecoder().decode(MSEvent.self, from: data)
        var occurrence = toGCalEvent(read)
        occurrence.originalStartTime = Self.allDayPlace(read.originalStart)
        return occurrence
    }

    /// An all-day occurrence's `originalStart`, read in its series' zone (`allDayOccurrence`), as
    /// its place in the series: the date it names, as written. Nil when it is no ISO 8601
    /// date-time.
    nonisolated static func allDayPlace(_ originalStart: String?) -> GCalDateTime? {
        guard let originalStart, Date.fromISO8601(originalStart) != nil else { return nil }
        return GCalDateTime(dateTime: nil, date: String(originalStart.prefix(10)), timeZone: nil)
    }

    /// Series split (this_and_following). For Graph, create first, then cap (#601, the order
    /// Google and CalDAV use, ADR-IOS-106):
    /// 1. POST the new part: a copy of the stored series (`splitNewPartJSON`) starting at
    ///    recurrenceId, ending where the series did (a numbered series: what is left of its
    ///    number, `occurrencesLeft`), with `patch` applied, under a DETERMINISTIC
    ///    `transactionId`, so Graph answers a retried POST with the part it already made.
    /// 2. `record` keeps the `SplitRecord` (the new part's Graph id).
    /// 3. PATCH the master's recurrence.range to {type: "endDate", endDate: splitDate - 1 day}
    ///    (`splitCapJSON`). The stored pattern is written back exactly.
    /// Nothing is rolled back: a failed cap is rethrown, and the retry finds the record and
    /// writes the cap alone (`finishSplit`). Until then both parts show the occurrences after
    /// the split.
    func splitSeries(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone,
        patch: GCalEventInput,
        sendUpdates: String = "all",
        record: SplitRecorder
    ) async throws -> GCalEvent? {
        // The agent may have passed an INSTANCE id — Graph instance events
        // don't carry the series `recurrence`; only the master does. Resolve
        // via `seriesMasterId` (mapped onto `recurringEventId` by toGCalEvent)
        // so a split aimed at an occurrence id still finds the series to cap.
        try Self.refuseUnrepresentableRule(patch.recurrence)
        let named = eventId
        let (eventId, snapshot) = try await resolveToMaster(eventId: eventId, select: Self.splitSelect)
        let master = snapshot.event
        guard let masterRecurrence = master.recurrence, !masterRecurrence.isEmpty,
              masterRecurrence.contains(where: { $0.uppercased().hasPrefix("RRULE:") }),
              let storedRecurrence = snapshot.raw["recurrence"] as? [String: Any]
        else {
            throw CalendarProviderError.notSupported("Event \(eventId) is not recurring; can't split.")
        }
        // The occurrence named: the one that starts at `recurrenceId` now, as `occurrence` finds it.
        // The split cuts the series in calendar order (owner rule, 2026-11-12): at the first place
        // at or after where that occurrence starts now (`SplitCarry.cut`, read as Outlook places
        // a pattern), so it and every occurrence shown after it change, and none shown before it
        // does. Each time the edit gives moves the new part as far from the cut as it moves the
        // occurrence named (`SplitCarry.partEdit`).
        let point = try await splitPoint(
            named: named, masterId: eventId, master: master, recurrenceId: recurrenceId, zone: recurrenceIdZone)
        let found = point.found, namedStart = point.namedStart, namedPlace = point.namedPlace
        let seriesZone = master.recurrenceTimeZoneName
        guard let place = point.place, case .at(let splitPlace) = point.cut else {
            _ = try await editShown(seriesId: eventId, series: master, named: found, patch: patch, record: record)
            return nil
        }
        guard let partPatch = SplitCarry.partEdit(patch, namedStart: namedStart, cut: splitPlace) else {
            throw CalendarProviderError.notSupported("where the occurrence named falls in its series can't be read, so the series can't be split at it")
        }
        let mode = SplitCarry.mode(edit: partPatch, place: splitPlace, storedRules: masterRecurrence, seriesZone: master.isAllDay ? nil : master.seriesZone)
        guard let capEndDate = Self.graphEndDateBefore(naiveISO: place, allDay: master.isAllDay, zone: recurrenceIdZone),
              let cappedJSON = Self.splitCapJSON(master: master, storedRecurrence: storedRecurrence, capEndDate: capEndDate) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        // Built before anything is written, so a series that can't be copied is refused while
        // nothing has changed.
        let transactionId = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: eventId, recurrenceId: place
        )
        let createJSON = try splitNewPartJSON(
            stored: snapshot,
            patch: partPatch,
            newStartNaiveISO: place,
            newStartZone: recurrenceIdZone,
            transactionId: transactionId
        )
        // The occurrences deleted or changed one by one (#563), read before anything is written
        // and sorted around the cut when they are written (`writeSplitOccurrences`).
        let exceptions = try await seriesExceptions(seriesId: eventId, series: master)
        guard let parts = SplitCarry.partition(exceptions.map(\.carried), cut: point.cut, namedStart: namedStart) else {
            throw CalendarProviderError.notSupported("a changed occurrence of this repeating event has a time TabMail can't read, so it was not split")
        }
        // The order the carry and the edits are written in dates their moves, and only their moves,
        // in the series' zone (`moveOrder`): a timed series with none whose split moves an
        // occurrence (`movesAnOccurrence`) is refused here, before the new part is created. A
        // deletion or a rename needs no zone.
        guard master.isAllDay || master.seriesZone != nil
              || !Self.movesAnOccurrence(exceptions.map(\.carried), edit: partPatch) else {
            throw CalendarProviderError.notSupported("an occurrence of this repeating event can't be dated in its time zone, so its change can't be carried")
        }
        let cappedBody = try JSONSerialization.data(withJSONObject: cappedJSON)

        // 1. Create the new part. Graph defines `transactionId` as a value "for the server to
        // avoid redundant POST operations in case of client retries": a retried POST receives
        // the original success response, so a retry after a lost answer gets the same part
        // back. A 409 is a store-level save conflict, not proof of anything: it is rethrown,
        // nothing has been capped, and the drain retries it.
        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = try Self.encodedGraphPathSegment(calendarId, context: "Graph calendar id")
            calPath = "/calendars/\(encodedCalId)"
        }
        let createBody = try JSONSerialization.data(withJSONObject: createJSON)
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: createBody, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries new-series POST body=\(bodyStr.prefix(4000))")
            }
        }
        let data = try await request(path: "\(calPath)/events", method: "POST", body: createBody)
        if DebugModeManager.isLoggingEnabled() {
            if let respStr = String(data: data, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries new-series response=\(respStr.prefix(4000))")
            }
        }
        let created = toGCalEvent(try JSONDecoder().decode(MSEvent.self, from: data))
        guard let createdId = created.id, !createdId.isEmpty else {
            throw CalendarProviderError.notSupported("Outlook gave no id for the new part of the repeating event, so the change can't be finished. Check the event's later occurrences in your calendar app.")
        }

        // 2. Keep the record before the carry and the cap: a retry after this point carries and
        //    caps alone (`finishSplit`), from the series, untouched until the cap but for the
        //    occurrences edited where they are, whose targets the record keeps.
        let fields = SplitCarry.fields(of: partPatch)
        guard let shift = SplitCarry.shift(cut: splitPlace, newPart: created),
              let edits = SplitCarry.edits(of: parts.edited, shift: shift, length: SplitCarry.length(of: created), fields: fields) else {
            throw CalendarProviderError.notSupported("the new part of this repeating event has a time TabMail can't read, so the change can't be finished")
        }
        let splitRecord = SplitRecord(
            seriesId: eventId, newPartId: createdId, splitAt: place, mode: mode, fields: fields,
            namedPlace: SplitCarry.key(namedPlace), namedStart: SplitCarry.key(namedStart), edits: SplitCarry.targets(of: edits))
        try await record(splitRecord)

        // 3. Carry onto the new part, and edit the occurrences shown after the one named that stay
        //    on the series. A write that fails stops the split here, before the cap: the series is
        //    still whole, and the retry writes again.
        try await writeSplitOccurrences(
            record: splitRecord, cut: splitPlace, exceptions: exceptions, series: master, seriesRaw: snapshot.raw,
            newPart: created, guests: partPatch.attendeeChange, seriesZone: seriesZone)

        // 4. Cap the master. A failure is rethrown; the record is kept.

        try await writeSplitCap(seriesId: eventId, body: cappedBody)
        return created
    }

    func eventExists(calendarId: String = "primary", eventId: String) async throws -> Bool {
        let encodedId = try Self.encodedGraphPathSegment(eventId, context: "Graph event id")
        do {
            _ = try await request(path: "/events/\(encodedId)?$select=id")
            return true
        } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {
            return false
        }
    }

    /// The cap of the split `record` names, written alone (`CalendarProvider.finishSplit`): the
    /// cap `splitSeries` writes, worked out from the series as it is now, and nothing when the
    /// series already ends before the split (`splitAlreadyEnded`).
    func finishSplit(calendarId: String = "primary", record: SplitRecord, zone: TimeZone, guests: AttendeeChange?) async throws {
        let stored = try await fetchForEdit(eventId: record.seriesId, select: Self.splitSelect)
        guard let storedRecurrence = stored.raw["recurrence"] as? [String: Any],
              let storedRange = storedRecurrence["range"] as? [String: Any] else {
            throw CalendarProviderError.notSupported("Can't finish this change to the repeating event: it no longer repeats. Check the event in your calendar app.")
        }
        guard let capEndDate = Self.graphEndDateBefore(naiveISO: record.splitAt, allDay: stored.event.isAllDay, zone: zone),
              let cappedJSON = Self.splitCapJSON(master: stored.event, storedRecurrence: storedRecurrence, capEndDate: capEndDate) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(record.splitAt)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        if try Self.splitAlreadyEnded(
            stored: stored, storedRange: storedRange, capEndDate: capEndDate, splitNaiveISO: record.splitAt, splitZone: zone) {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] finishSplit: series \(record.seriesId) already ends before \(record.splitAt) — nothing to write")
            }
            return
        }
        // The cap is the split's last write, so an uncapped series may not be carried yet: the
        // carry is planned again from the series' exceptions, untouched until the cap, and the
        // new part as it is now, and written before the cap (#563).
        let seriesZone = stored.event.recurrenceTimeZoneName
        guard let split = Self.splitPlace(naiveISO: record.splitAt, allDay: stored.event.isAllDay, zone: zone) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(record.splitAt)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let exceptions = try await seriesExceptions(seriesId: record.seriesId, series: stored.event)
        let newPart = try await getEvent(eventId: record.newPartId)
        try await writeSplitOccurrences(
            record: record, cut: split, exceptions: exceptions, series: stored.event, seriesRaw: stored.raw,
            newPart: newPart, guests: guests, seriesZone: seriesZone)
        try await writeSplitCap(seriesId: record.seriesId, body: try JSONSerialization.data(withJSONObject: cappedJSON))
    }

    /// Whether the stored series already ends before the split, so `finishSplit` writes no cap:
    /// an `endDate` range ending on or before the cap's `capEndDate` (this split's own cap among
    /// them), or a numbered range whose occurrences are all before the split, counted as
    /// `occurrencesLeft` counts them. A range with no end does not. Throws `notSupported` when a
    /// numbered range can't be counted.
    nonisolated static func splitAlreadyEnded(
        stored: EditSnapshot,
        storedRange: [String: Any],
        capEndDate: String,
        splitNaiveISO: String,
        splitZone: TimeZone
    ) throws -> Bool {
        switch storedRange["type"] as? String {
        case "endDate":
            guard let endDate = storedRange["endDate"] as? String, RecurrenceTail.Day(iso: endDate) != nil else {
                throw CalendarProviderError.notSupported("Can't finish this change to the repeating event: Outlook gives no end date for it. Check the event's later occurrences in your calendar app.")
            }
            return endDate <= capEndDate
        case "numbered":
            let counted = try numberedRange(stored: stored, storedRange: storedRange, splitNaiveISO: splitNaiveISO, splitZone: splitZone)
            guard let seriesStart = counted.seriesStart, let split = counted.split,
                  let before = RecurrenceTail.occurrences(
                      of: counted.rule, seriesStart: seriesStart, before: split, anchor: .patternStart, missingDay: .lastDay)
            else {
                throw CalendarProviderError.notSupported("Can't finish this change to the repeating event: its occurrences can't be counted. Check the event's later occurrences in your calendar app.")
            }
            return before >= counted.count
        default:
            return false
        }
    }

    /// One exception of a series from a split on, as Graph gives it: the neutral value the carry
    /// plans with (`SplitCarry.Exception`; a deleted one's place is its date in the series' zone)
    /// and the stored JSON a changed one's own values are copied from.
    struct TailException {
        let carried: SplitCarry.Exception
        let raw: [String: Any]
    }

    /// The place a split at `naiveISO` (read in `zone`) starts at: its date for an all-day series,
    /// else its instant. Nil when it can't be read.
    nonisolated static func splitPlace(naiveISO: String, allDay: Bool, zone: TimeZone) -> GCalDateTime? {
        if allDay { return RecurrenceTail.Day(iso: String(naiveISO.prefix(10))) != nil ? GCalDateTime(dateTime: nil, date: String(naiveISO.prefix(10)), timeZone: nil) : nil }
        guard let instant = GoogleCalendarProvider.naiveInstant(naiveISO, zone: zone) else { return nil }
        return GCalDateTime(dateTime: instant.iso8601String(), date: nil, timeZone: "UTC")
    }

    /// The date `time` starts on in the series' zone `seriesZone`: an all-day date as written, a
    /// timed instant dated there. Nil when it can't be read.
    /// The name a series' times are read in (`Prefer: outlook.timezone`). All day: the range's
    /// stored name as it is, recognized or not, so an all-day place reads as the date Graph keeps
    /// it on (measured, see `allDayOccurrence`). Timed: the one its `seriesZone` was recognized by, the
    /// range's zone when recognized, else the zone the event was created in; nil when neither is,
    /// and no timed date is then placed (`deletedPlace`).
    nonisolated static func readZoneName(of series: GCalEvent) -> String? {
        if series.isAllDay { return series.recurrenceTimeZoneName }
        let recognized = { (name: String?) in name.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } != nil ? name : nil }
        return recognized(series.recurrenceTimeZoneName) ?? recognized(series.ownZoneName)
    }

    nonisolated static func seriesDate(of time: GCalDateTime, seriesZone: TimeZone?) -> String? {
        if let date = time.date { return String(date.prefix(10)) }
        guard let seriesZone, let instant = time.dateTime.flatMap(Date.fromISO8601) else { return nil }
        return String(SplitCarry.naive(instant, in: seriesZone).prefix(10))
    }

    /// Every exception of the series `seriesId`: its changed
    /// occurrences (`exceptionOccurrences`, each with its `originalStart`) and its deleted ones
    /// (`cancelledOccurrences`, each named by its date in the series' zone, measured). Two reads,
    /// never combined: only a plain `$expand=exceptionOccurrences`, with no `$select` anywhere,
    /// gives each exception's `originalStart` and fields (measured). Both are read with `Prefer`
    /// naming the series' zone, so an all-day place is its date. Nothing is written.
    private func seriesExceptions(seriesId: String, series: GCalEvent) async throws -> [TailException] {
        let unreadable = CalendarProviderError.notSupported(
            "the occurrences of this repeating event changed or deleted one by one can't be read, so it was not split")
        let seriesZone = Self.readZoneName(of: series)
        let zone = series.seriesZone
        let encodedId = try Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
        let expanded = try await request(path: "/events/\(encodedId)?$expand=exceptionOccurrences", timeZoneName: seriesZone)
        guard let expandedJSON = try JSONSerialization.jsonObject(with: expanded) as? [String: Any] else { throw unreadable }
        var found: [TailException] = []
        for raw in expandedJSON["exceptionOccurrences"] as? [[String: Any]] ?? [] {
            let read = try JSONDecoder().decode(MSEvent.self, from: JSONSerialization.data(withJSONObject: raw))
            var event = toGCalEvent(read)
            if series.isAllDay { event.originalStartTime = Self.allDayPlace(read.originalStart) }
            guard event.originalStartTime != nil else { throw unreadable }
            found.append(TailException(carried: .changed(event), raw: raw))
        }
        let cancelled = try await request(path: "/events/\(encodedId)?$select=cancelledOccurrences", timeZoneName: seriesZone)
        guard let cancelledJSON = try JSONSerialization.jsonObject(with: cancelled) as? [String: Any] else { throw unreadable }
        for name in cancelledJSON["cancelledOccurrences"] as? [String] ?? [] {
            let date = String(name.suffix(10))
            guard RecurrenceTail.Day(iso: date) != nil else { throw unreadable }
            guard let place = Self.deletedPlace(date: date, series: series, zone: zone) else { throw unreadable }
            found.append(TailException(carried: .deleted(place: place), raw: [:]))
        }
        return found
    }

    /// The place of an occurrence Graph names deleted by its date `date` (in the series' zone): the
    /// date for an all-day series, else the series' time of day on it in `zone`, so it compares
    /// with a cut. Nil when it can't be read.
    nonisolated static func deletedPlace(date: String, series: GCalEvent, zone: TimeZone?) -> GCalDateTime? {
        if series.isAllDay { return GCalDateTime(dateTime: nil, date: date, timeZone: nil) }
        guard let zone, let start = series.start?.dateTime.flatMap(Date.fromISO8601),
              let instant = GoogleCalendarProvider.naiveInstant("\(date)T\(SplitCarry.naive(start, in: zone).dropFirst(11))", zone: zone)
        else { return nil }
        return GCalDateTime(dateTime: instant.iso8601String(), date: nil, timeZone: "UTC")
    }

    /// What a split writes after its record and before its cap, in `splitSeries` and again in
    /// `finishSplit`: the series' exceptions sorted around the cut `cut` (`SplitCarry.partition`,
    /// named as `record` keeps), the carry onto the new part (`SplitCarry.plan`: the deleted and
    /// changed occurrences after the cut on a carry, those shown before the one named whole in
    /// either mode, and on a reset the one named, moved as the edit moves it), then the edit of
    /// each occurrence shown after the one named that stays on the series, to the start the
    /// record keeps for it, as a "this occurrence" edit writes it (`patchOccurrence`).
    private func writeSplitOccurrences(
        record: SplitRecord, cut: GCalDateTime, exceptions: [TailException], series: GCalEvent, seriesRaw: [String: Any],
        newPart: GCalEvent, guests: AttendeeChange?, seriesZone: String?
    ) async throws {
        let unreadable = CalendarProviderError.notSupported("a changed occurrence of this repeating event has a time TabMail can't read, so the change can't be finished")
        let namedStart = record.namedStart.flatMap(SplitCarry.time) ?? cut
        let namedPlace = record.namedPlace.flatMap(SplitCarry.time) ?? cut
        guard let parts = SplitCarry.partition(exceptions.map(\.carried), cut: .at(cut), namedStart: namedStart),
              let shift = SplitCarry.shift(cut: cut, newPart: newPart) else { throw unreadable }
        let moved = SplitCarry.key(namedStart) != SplitCarry.key(namedPlace)
        let named = record.mode == .reset && moved ? SplitCarry.named(in: parts, place: namedPlace) : nil
        guard let plan = SplitCarry.plan(
            exceptions: record.mode == .carry ? parts.tail : [], kept: parts.kept, named: named, shift: shift,
            series: series, newPart: newPart, fields: record.fields) else { throw unreadable }
        try await carry(
            plan, exceptions: exceptions, series: series, seriesRaw: seriesRaw, newPartId: record.newPartId,
            fields: record.fields, guests: guests, seriesZone: seriesZone)
        guard let edits = SplitCarry.edits(
            of: parts.edited, targets: record.edits, length: SplitCarry.length(of: newPart), fields: record.fields) else { throw unreadable }
        let values = SplitCarry.values(of: newPart, fields: record.fields)
        for edit in try Self.editOrder(edits, zone: series.seriesZone) {
            guard let id = edit.exception.id else { throw unreadable }
            _ = try await patchOccurrence(instanceId: id, event: SplitCarry.input(for: edit, values: values, guests: guests))
        }
    }

    /// A "this and following" edit at an occurrence moved past the series' last place
    /// (`SplitCarry.Cut.pastEnd`): no new part and no cap; the edit is written onto every
    /// occurrence shown from the one named on, each as a "this occurrence" edit in the order
    /// Graph takes moves (`editOrder`), to an absolute target worked out once and kept on the
    /// operation's record before the first write (`SplitCarry.shownEdits`), so a retry
    /// (`finishShownEdit`) never moves one twice. An edit of the rule is refused: no part is left
    /// to take it.
    private func editShown(
        seriesId: String, series: GCalEvent, named: GCalEvent, patch: GCalEventInput, record: SplitRecorder
    ) async throws -> GCalEvent {
        guard patch.recurrence == nil, patch.ruleDayMove == nil else {
            throw CalendarProviderError.notSupported(SplitCarry.pastEndRuleRefusal)
        }
        let exceptions = try await seriesExceptions(seriesId: seriesId, series: series)
        guard let shown = SplitCarry.shownEdits(exceptions: exceptions.map(\.carried), named: named, seriesId: seriesId, patch: patch) else {
            throw CalendarProviderError.notSupported(Self.shownEditUnreadable)
        }
        // Ordered before the record and the first write, so edits Graph can't take are refused
        // with nothing written.
        let ordered = try Self.editOrder(shown.edits, zone: series.seriesZone)
        try await record(shown.record)
        return try await writeShownEdits(
            ordered, values: SplitCarry.values(of: patch, fields: shown.record.fields), guests: patch.attendeeChange) ?? named
    }

    /// `CalendarProvider.finishShownEdit`: the edits of `record` still to write, from the series'
    /// exceptions as they are now (`SplitCarry.shownEdits(exceptions:record:)`).
    func finishShownEdit(calendarId: String = "primary", record: SplitRecord, edit: GCalEventInput, guests: AttendeeChange?) async throws {
        let (seriesId, snapshot) = try await resolveToMaster(eventId: record.seriesId, select: Self.splitSelect)
        let exceptions = try await seriesExceptions(seriesId: seriesId, series: snapshot.event)
        guard let edits = SplitCarry.shownEdits(exceptions: exceptions.map(\.carried), record: record) else {
            throw CalendarProviderError.notSupported(Self.shownEditUnreadable)
        }
        _ = try await writeShownEdits(
            try Self.editOrder(edits, zone: snapshot.event.seriesZone), values: SplitCarry.values(of: edit, fields: record.fields), guests: guests)
    }

    private static let shownEditUnreadable = "a changed occurrence of this repeating event has a time TabMail can't read, so it was not changed"

    /// Writes `edits`, already in the order Graph takes moves (`editOrder`), each as a "this
    /// occurrence" edit; the last one written, nil when none.
    private func writeShownEdits(
        _ edits: [SplitCarry.Edit], values: GCalEventInput, guests: AttendeeChange?
    ) async throws -> GCalEvent? {
        var last: GCalEvent?
        for edit in edits {
            guard let id = edit.exception.id else {
                throw CalendarProviderError.notSupported("a changed occurrence of this repeating event can't be addressed, so it was not changed")
            }
            last = try await patchOccurrence(instanceId: id, event: SplitCarry.input(for: edit, values: values, guests: guests))
        }
        return last
    }

    /// Writes the carry of `exceptions` onto the new part `newPartId` (`SplitCarry.plan`): each
    /// deleted place's occurrence there is deleted, and each changed one is written with its own
    /// values of the fields the edit did not set, its own times (labelled in the series' zone,
    /// #747), and its own guests with the edit's change applied as the series' difference. The
    /// occurrences are found among the new part's `/instances` by their place (`originalStart`);
    /// one not listed is done. Every write is absolute, so one that runs again changes nothing, and
    /// a DELETE answered 404 is done.
    ///
    /// Graph refuses an occurrence moved onto a date another occurrence of the series still holds
    /// (`ErrorOccurrenceCrossingBoundary`, measured), so the deletes go first, then the moves, each
    /// once the date it moves to is free. A move that can't be ordered so is written all the same
    /// and refused: the split stops before its cap, with the series whole.
    private func carry(
        _ plan: SplitCarry.Plan, exceptions: [TailException], series: GCalEvent, seriesRaw: [String: Any], newPartId: String,
        fields: Set<SplitCarry.Field>, guests: AttendeeChange?, seriesZone: String?
    ) async throws {
        guard !plan.deleted.isEmpty || !plan.changed.isEmpty else { return }
        let zone = series.seriesZone
        let unplaced = CalendarProviderError.notSupported(
            "an occurrence of this repeating event can't be dated in its time zone, so its change can't be carried")

        // The new part's occurrences around every place and every time a carried one moves to. The
        // window is dated in UTC: its two days before and three after cover any zone's offset, so
        // it needs no series zone (a deletion or a rename of a series with none is carried).
        let windowZone = series.isAllDay ? nil : TimeZone.gmt
        var dates: [String] = []
        for time in plan.deleted + plan.changed.flatMap({ [$0.place] + ($0.start.map { [$0] } ?? []) }) {
            guard let date = Self.seriesDate(of: time, seriesZone: windowZone) else { throw unplaced }
            dates.append(date)
        }
        guard let first = dates.min().flatMap({ RecurrenceTail.Day(iso: $0) }), let last = dates.max().flatMap({ RecurrenceTail.Day(iso: $0) }),
              let from = GoogleCalendarProvider.naiveInstant(first.description, zone: .gmt)?.addingTimeInterval(-2 * 86_400),
              let to = GoogleCalendarProvider.naiveInstant(last.description, zone: .gmt)?.addingTimeInterval(3 * 86_400) else { throw unplaced }
        let encodedPart = try Self.encodedGraphPathSegment(newPartId, context: "Graph event id")
        // Every page: an occurrence past the first is carried like any other.
        var instances: [[String: Any]] = []
        var next: String? = "/events/\(encodedPart)/instances?startDateTime=\(from.iso8601String())&endDateTime=\(to.iso8601String())&$top=1000"
        while let path = next {
            let listed = try await request(path: path, timeZoneName: Self.readZoneName(of: series))
            guard let page = try JSONSerialization.jsonObject(with: listed) as? [String: Any] else {
                throw CalendarProviderError.notSupported("the new part's occurrences can't be read, so the changed ones can't be carried")
            }
            instances += page["value"] as? [[String: Any]] ?? []
            next = try (page["@odata.nextLink"] as? String).map { try graphPath(ofNextLink: $0) }
        }
        func instanceId(at place: GCalDateTime) -> String? {
            instances.first { instance in
                guard let original = instance["originalStart"] as? String, let at = Date.fromISO8601(original) else { return false }
                if let date = place.date {
                    let originalDate = series.isAllDay ? String(original.prefix(10)) : zone.map { String(SplitCarry.naive(at, in: $0).prefix(10)) }
                    return originalDate == String(date.prefix(10))
                }
                return place.dateTime.flatMap(Date.fromISO8601) == at
            }?["id"] as? String
        }

        // 1. The deleted places first: each frees its date for a move.
        for place in plan.deleted {
            guard let id = instanceId(at: place) else { continue }
            let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
            do {
                _ = try await request(path: "/events/\(encoded)", method: "DELETE")
            } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {
                continue
            }
        }

        // 2. The changed ones, each move once the date it moves to is free.
        let seriesGuests = seriesRaw["attendees"] as? [[String: Any]] ?? []
        let difference = guests.map { change in
            change.seriesDifference(before: seriesGuests, after: Self.appliedAttendeesJSON(change, to: seriesGuests)) {
                (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased()
            }
        }
        for change in try Self.carryOrder(plan.changed, zone: zone) {
            // A changed occurrence the new part does not list can't be carried: refused before the
            // cap, with the series whole. (A deleted place not listed is done, above.)
            guard let id = instanceId(at: change.place) else {
                throw CalendarProviderError.notSupported("a changed occurrence of this repeating event isn't on its new part, so its change can't be carried")
            }
            let own = exceptions.first { $0.raw["id"] as? String == change.exception.id }?.raw ?? [:]
            var json = Self.carriedJSON(own, fields: change.whole ? [] : fields)
            let held = own["attendees"] as? [[String: Any]] ?? []
            json["attendees"] = change.whole ? held : difference.map { Self.appliedAttendeesJSON($0, to: held) } ?? held
            if let start = change.start, let end = change.end {
                var times = GCalEventInput()
                times.startDate = start.date
                times.startDateTime = start.dateTime
                times.startTimeZone = start.timeZone
                times.endDate = end.date
                times.endDateTime = end.dateTime
                times.endTimeZone = end.timeZone
                let written = toGraphEventJSON(times)
                for key in ["start", "end"] {
                    if let time = written[key] as? [String: Any] {
                        json[key] = Self.inSeriesZone(time, seriesZone: seriesZone, allDay: series.isAllDay)
                    }
                }
            }
            let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
            _ = try await request(path: "/events/\(encoded)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: json))
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] split carried a changed occurrence onto \(id): keys=\(json.keys.sorted()) times=\(change.start != nil)")
            }
        }
    }

    /// The JSON a carry writes for the changed occurrence `exception` (read with every property):
    /// each property a split's new part copies (`splitCopiedKeys`) but `isAllDay` (an occurrence
    /// keeps its series' form), and but those the edit set (`fields`), which the new part already
    /// holds. Guests and times are written by the carry itself.
    nonisolated static func carriedJSON(_ exception: [String: Any], fields: Set<SplitCarry.Field>) -> [String: Any] {
        var set: Set<String> = ["isAllDay"]
        for field in fields {
            switch field {
            case .summary: set.insert("subject")
            case .location: set.formUnion(["location", "locations"])
            case .description: set.insert("body")
            case .transparency: set.insert("showAs")
            case .attendees, .end: break
            }
        }
        return exception.filter { splitCopiedKeys.contains($0.key) && !set.contains($0.key) }
    }

    /// The path, under `baseURL`, of a Graph `@odata.nextLink`. A link to anywhere else is
    /// refused: the token is never sent off Graph.
    func graphPath(ofNextLink link: String) throws -> String {
        guard link.hasPrefix(baseURL + "/") else {
            throw CalendarProviderError.notSupported("Graph gave a next page outside Microsoft Graph, so it was not read")
        }
        return String(link.dropFirst(baseURL.count))
    }

    /// `changes` in the order Graph takes them (`moveOrder`): each carried occurrence is on the new
    /// part at its place, and moves to its own start.
    nonisolated static func carryOrder(_ changes: [SplitCarry.Change], zone: TimeZone?) throws -> [SplitCarry.Change] {
        try moveOrder(changes, at: \.place, to: { $0.start }, zone: zone)
    }

    /// `edits` of occurrences where they are (`SplitCarry.Edit`) in the order Graph takes them
    /// (`moveOrder`): each is at its own start now, and moves to its target.
    nonisolated static func editOrder(_ edits: [SplitCarry.Edit], zone: TimeZone?) throws -> [SplitCarry.Edit] {
        try moveOrder(edits, at: { $0.exception.start ?? $0.exception.originalStartTime ?? GCalDateTime(dateTime: nil, date: nil, timeZone: nil) },
                      to: { $0.start }, zone: zone)
    }

    /// Whether a split with `edit` of a series with `exceptions` moves an occurrence, so its carry
    /// or its edits date a move in the series' zone (`moveOrder`): an edit that sets a time, with
    /// any exception, or a changed occurrence that starts away from its place. A deletion or a
    /// rename moves nothing.
    nonisolated static func movesAnOccurrence(_ exceptions: [SplitCarry.Exception], edit: GCalEventInput) -> Bool {
        let setsTime = edit.startDateTime != nil || edit.startDate != nil || edit.endDateTime != nil || edit.endDate != nil
        return exceptions.contains { exception in
            guard case .changed(let event) = exception else { return setsTime }
            guard let start = event.start, let place = event.originalStartTime else { return true }
            return setsTime || SplitCarry.key(start) != SplitCarry.key(place)
        }
    }

    /// `moves` in the order Graph takes them: an occurrence moved to another date goes once no
    /// occurrence not yet moved still holds that date (the date it is `at`), so none is moved onto
    /// a date another occurrence holds (`ErrorOccurrenceCrossingBoundary`). Those that don't move
    /// (no target, or a target at the instant they are at) go first and are not dated: no zone is
    /// needed for them. Those that stay on their
    /// date go next. Moves that hold each other's dates in a ring keep their order; Graph
    /// refuses the first of them.
    nonisolated static func moveOrder<Move>(
        _ moves: [Move], at: (Move) -> GCalDateTime, to: (Move) -> GCalDateTime?, zone: TimeZone?
    ) throws -> [Move] {
        let unplaced = CalendarProviderError.notSupported(
            "an occurrence of this repeating event can't be dated in its time zone, so its change can't be carried")
        func stays(_ move: Move) -> Bool { to(move).map { SplitCarry.key($0) == SplitCarry.key(at(move)) } ?? true }
        var ordered = moves.filter(stays)
        var pending: [(move: Move, place: String, target: String)] = try moves.compactMap { move in
            guard !stays(move), let start = to(move) else { return nil }
            guard let place = seriesDate(of: at(move), seriesZone: zone),
                  let target = seriesDate(of: start, seriesZone: zone) else { throw unplaced }
            return (move, place, target)
        }
        while !pending.isEmpty {
            let held = pending.map(\.place)
            let next = pending.firstIndex { $0.target == $0.place }
                ?? pending.firstIndex { move in !held.contains(move.target) }
                ?? 0
            ordered.append(pending.remove(at: next).move)
        }
        return ordered
    }

    /// The PATCH that caps the master at `capEndDate`, or nil when the stored recurrence has no
    /// range.
    ///
    /// IMPORTANT: Graph's recurrenceRange uses a DATE-inclusive `endDate` ("occurrences ...
    /// between startDate and endDate inclusive"). We therefore can NOT round-trip through an
    /// RRULE `UNTIL` instant — its precision is lost when collapsed to a whole date, and the
    /// naive date-part of (split − 1s) is still the split day, which Graph would keep on the
    /// master. So the cap is computed directly: endDate = local date of (split occurrence − 1
    /// day) (`graphEndDateBefore`). The stored pattern and the rest of the stored range (its
    /// `startDate`, which Graph requires, and its zone) are written back as they are.
    ///
    /// CRITICAL: the master's existing start/end go on the cap PATCH. If we send ONLY
    /// `recurrence`, Graph silently rewrites the master's `start.dateTime`/`start.timeZone` to
    /// UTC midnight at the recurrence range's `startDate` — shifting the master's first
    /// occurrence by the device's UTC offset (17:00 Vancouver → 00:00 UTC, i.e. the previous day
    /// in PDT). Re-sending the existing wall time pins the master in place. `graphNaiveDateTime`
    /// strips the offset so the `dateTime` is naive in `timeZone`, per Graph's spec.
    nonisolated static func splitCapJSON(master: GCalEvent, storedRecurrence: [String: Any], capEndDate: String) -> [String: Any]? {
        guard var capRange = storedRecurrence["range"] as? [String: Any] else { return nil }
        capRange["type"] = "endDate"
        capRange["endDate"] = capEndDate
        capRange.removeValue(forKey: "numberOfOccurrences")
        var cappedRecurrence = storedRecurrence
        cappedRecurrence["range"] = capRange
        // Restated in the series' own zone at the same instant (#719): Exchange refuses a series
        // start labelled with another zone, and the read's label is the device's. Timed only: an
        // all-day master's start and end are read as dates, so an all-day cap writes the
        // recurrence alone (measured to keep the series' length and start). The first split and
        // a retried one (`finishSplit`) both write this cap.
        let seriesZone = capRange["recurrenceTimeZone"] as? String
        var cappedJSON: [String: Any] = ["recurrence": cappedRecurrence]
        if let startISO = master.start?.dateTime, let startTz = master.start?.timeZone {
            cappedJSON["start"] = inSeriesZone([
                "dateTime": graphNaiveDateTime(startISO),
                "timeZone": startTz,
            ], seriesZone: seriesZone, allDay: false)
        }
        if let endISO = master.end?.dateTime, let endTz = master.end?.timeZone {
            cappedJSON["end"] = inSeriesZone([
                "dateTime": graphNaiveDateTime(endISO),
                "timeZone": endTz,
            ], seriesZone: seriesZone, allDay: false)
        }
        return cappedJSON
    }

    /// The silent cap PATCH of a split (`splitCapJSON`'s body) on the series `seriesId`.
    private func writeSplitCap(seriesId: String, body: Data) async throws {
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: body, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries cap PATCH body=\(bodyStr.prefix(4000))")
            }
        }
        let encodedMasterId = try Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
        let capRespData = try await request(path: "/events/\(encodedMasterId)", method: "PATCH", body: body)
        // Log the response so we can see what Graph stored — particularly the
        // master's start/end/recurrence after capping, to diagnose visible
        // "occurrence moved to earlier day" symptoms after a split.
        if DebugModeManager.isLoggingEnabled() {
            if let capRespStr = String(data: capRespData, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries cap PATCH response=\(capRespStr.prefix(4000))")
            }
        }
    }

    /// Graph `recurrenceRange.endDate` for capping a series so the occurrence
    /// at `naiveISO` and everything after is excluded. Graph's endDate is
    /// DATE-inclusive, so this is the local date of (split occurrence − 1 day).
    /// `allDay` doesn't change the math here (the result is a date either way)
    /// but is accepted for signature symmetry with the Google helper.
    /// `naiveISO` is read in `zone` — the operation's declared timezone (see the
    /// invariant on `RecurrenceOccurrenceResolver`), which is the device zone
    /// unless the caller supplied `timezone`.
    /// Returns nil if `naiveISO` can't be parsed.
    static func graphEndDateBefore(naiveISO: String, allDay: Bool, zone: TimeZone) -> String? {
        let dtFmt = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)
        let dateFmt = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone)
        let parsed = dtFmt.date(from: naiveISO)
            ?? dateFmt.date(from: String(naiveISO.prefix(10)))
        guard let date = parsed else { return nil }
        // Calendar arithmetic, not a flat 86400s — a DST-transition day is 23h
        // or 25h of local time, so `addingTimeInterval(-86400)` can land on the
        // wrong calendar day and cap the series a day early/late.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let dayBefore = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
        let out = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone)
        return out.string(from: dayBefore)
    }

    /// If `eventId` points to an OCCURRENCE of a recurring series, fetch the
    /// master and return its id + event. Otherwise return the fetched event
    /// as the master. Graph's instance events carry the parent series id in
    /// `seriesMasterId`, which `toGCalEvent` maps onto `GCalEvent.recurringEventId`.
    /// Same rationale as GoogleCalendarProvider.resolveToMaster — the agent
    /// commonly passes an instance id from calendar_read output, and the
    /// series-level operations (splitSeries / updateOccurrence instances
    /// endpoint) require the master id.
    private func resolveToMaster(eventId: String, select: String = eventSelect) async throws -> (id: String, master: EditSnapshot) {
        let fetched = try await fetchForEdit(eventId: eventId, select: select)
        if let masterId = fetched.event.recurringEventId, !masterId.isEmpty, masterId != eventId {
            return (masterId, try await fetchForEdit(eventId: masterId, select: select))
        }
        return (eventId, fetched)
    }

    /// The new part of a split: the stored series' properties (`splitCopiedKeys`) as they are,
    /// re-anchored at the split (`mergeMasterAndPatch`) with the patch applied, under
    /// `transactionId`.
    ///
    /// - Attendees are the series' with the edit's guest change applied (`AttendeeChange.apply`), and
    ///   keep their address, name and type; one the change adds is `required`. Their
    ///   answers are not copied: Graph lets only the attendee write a response, so the new part's
    ///   attendees start unanswered, as they do when Outlook splits a series itself.
    /// - The recurrence keeps the stored pattern exactly, its named days turned when the split
    ///   moves the new part to another day (`patch.ruleDayMove`, `newPartRecurrence`). Its range keeps its end date (verbatim)
    ///   and zone and starts on the new start's date; a range that ends after a number of
    ///   occurrences stays numbered with what is left of the number (`occurrencesLeft`), as on
    ///   Google and CalDAV. A range whose end date is before the new start is refused, so no new
    ///   part starts after its own end: reached by a split whose edit moves the new part's start
    ///   past the series' end date (the occurrence lookup already refuses a split at an occurrence
    ///   past it). A rule in the patch replaces the stored recurrence.
    /// - A new place in the patch replaces the stored places (`locations`).
    /// - New notes on an online series replace only the notes in the copied body; its join section
    ///   is kept as stored (`onlineMeetingBody`). The new part is not an online meeting of its own:
    ///   its body carries the series' join link.
    ///
    /// Throws `notSupported` when the new start can't be dated, when the series ends before the
    /// split, or when a numbered series has no occurrence left from the split on or can't be
    /// counted (`occurrencesLeft`); nothing has been written then.
    nonisolated func splitNewPartJSON(
        stored: EditSnapshot,
        patch: GCalEventInput,
        newStartNaiveISO: String,
        newStartZone: TimeZone,
        transactionId: String
    ) throws -> [String: Any] {
        // The recurrence comes from the stored series' range below, or from the patch's rule.
        let edited = GoogleCalendarProvider.mergeMasterAndPatch(
            master: stored.event, patch: patch, newStartNaiveISO: newStartNaiveISO,
            newStartZone: newStartZone, newRecurrence: [])
        // Dated in the zone the new part is written in (#719): the copied range's, so its start
        // and its range's `startDate` name the same day.
        let copiedZone = patch.recurrence?.isEmpty ?? true
            ? ((stored.raw["recurrence"] as? [String: Any])?["range"] as? [String: Any])?["recurrenceTimeZone"] as? String
            : nil
        guard let newDay = Self.seriesDay(edited.startDate, edited.startDateTime, in: edited.startTimeZone, seriesZone: copiedZone) else {
            throw CalendarProviderError.notSupported("The repeating event's start can't be read, so it can't be split.")
        }
        var written = GCalEventInput()
        written.summary = patch.summary
        written.location = patch.location
        written.description = patch.description
        written.transparency = patch.transparency
        written.startDate = edited.startDate
        written.startDateTime = edited.startDateTime
        written.startTimeZone = edited.startTimeZone
        written.endDate = edited.endDate
        written.endDateTime = edited.endDateTime
        written.endTimeZone = edited.endTimeZone
        written.recurrence = edited.recurrence
        let storedAttendees: [(email: String, name: String?)] = (stored.event.attendees ?? []).compactMap { attendee in
            guard let email = attendee.email, !email.isEmpty else { return nil }
            return (email: email, name: attendee.displayName)
        }
        written.attendees = patch.attendeeChange.map { change in
            change.apply(to: storedAttendees, address: { $0.email.lowercased() }) { (email: $0.email, name: $0.name) }
        } ?? storedAttendees

        var json = stored.raw.filter { Self.splitCopiedKeys.contains($0.key) }
        if patch.location != nil { json.removeValue(forKey: "locations") }
        for (key, value) in toGraphEventJSON(written, attendeeTypes: stored.attendeeTypes) { json[key] = value }
        // New notes on an online series keep its join section, as an edit of the series does.
        if let description = patch.description, let body = Self.onlineMeetingBody(stored.raw, notes: description) {
            json["body"] = body
        }
        if patch.recurrence?.isEmpty ?? true, let recurrence = stored.raw["recurrence"] as? [String: Any] {
            json["recurrence"] = try Self.newPartRecurrence(
                stored: stored, storedRecurrence: recurrence, newDay: newDay,
                splitNaiveISO: newStartNaiveISO, splitZone: newStartZone, move: patch.ruleDayMove)
            // The new part is written in the zone its copied range names: a timed one at the same
            // instant (#719), as Google Calendar keeps a series' zone on "this and following", an
            // all-day one on the same dates (#747), or Graph stores it two days longer.
            if let storedRange = recurrence["range"] as? [String: Any] {
                let seriesZone = storedRange["recurrenceTimeZone"] as? String
                let allDay = json["isAllDay"] as? Bool ?? (written.startDate != nil)
                for key in ["start", "end"] {
                    if let time = json[key] as? [String: Any] { json[key] = Self.inSeriesZone(time, seriesZone: seriesZone, allDay: allDay) }
                }
            }
        }
        json["transactionId"] = transactionId
        return json
    }

    /// The recurrence of a split's new part, from the stored series' (`storedRecurrence`): the
    /// stored pattern, turned by `move` when the split moves it to another day (`turned`), and the
    /// stored range starting on `newDay` with what is left of its end (see `splitNewPartJSON`).
    /// The one computation the split writes and its card shows (`dayMovedRules`). Unchanged when it
    /// has no range.
    nonisolated static func newPartRecurrence(
        stored: EditSnapshot, storedRecurrence: [String: Any], newDay: String,
        splitNaiveISO: String, splitZone: TimeZone, move: RecurrenceDayShift.Move?
    ) throws -> [String: Any] {
        guard let storedRange = storedRecurrence["range"] as? [String: Any] else { return storedRecurrence }
        var recurrence = storedRecurrence
        var range = storedRange
        range["startDate"] = newDay
        switch range["type"] as? String {
        case "numbered":
            // What is left of the count, as Google and CalDAV write it (`RecurrenceTail`). The
            // stored `endDate` of a numbered range is a placeholder ("0001-01-01", measured).
            range["numberOfOccurrences"] = try occurrencesLeft(
                stored: stored, storedRange: storedRange, splitNaiveISO: splitNaiveISO, splitZone: splitZone)
            range.removeValue(forKey: "endDate")
        case "endDate":
            if let endDate = range["endDate"] as? String, endDate < newDay {
                throw CalendarProviderError.notSupported(
                    "Can't split this series at the occurrence on \(newDay): the series already ends before it (on \(endDate)), so there are no occurrences from that point on to change.")
            }
            range.removeValue(forKey: "numberOfOccurrences")
        default:
            range.removeValue(forKey: "endDate")
            range.removeValue(forKey: "numberOfOccurrences")
        }
        recurrence["range"] = range
        // A move of the new part to another day turns the days the pattern names.
        if let move { recurrence = try turned(recurrence, by: move) }
        return recurrence
    }

    /// Outlook's split cut (`CalendarProvider.splitCut`): `splitPoint`'s, with the series read as
    /// `splitSeries` reads it.
    func splitCut(calendarId: String = "primary", eventId: String, recurrenceId: String, zone: TimeZone) async throws -> SplitCarry.Cut {
        let (masterId, snapshot) = try await resolveToMaster(eventId: eventId, select: Self.splitSelect)
        return try await splitPoint(named: eventId, masterId: masterId, master: snapshot.event, recurrenceId: recurrenceId, zone: zone).cut
    }

    /// Where a split of `master` named at `recurrenceId` (read in `zone`) cuts it: the occurrence
    /// named is the one that starts at `recurrenceId` now (`occurrence`), and the cut the first
    /// place of the series at or after where it starts (`SplitCarry.cut`, read as Outlook places
    /// a pattern: from the range's start, a missing month day on the month's last). `place` is the
    /// cut as a naive wall clock in `zone`, nil past the series' end. The one computation
    /// `splitSeries` writes and the card shows (`dayMovedRules`).
    private func splitPoint(
        named: String, masterId: String, master: GCalEvent, recurrenceId: String, zone: TimeZone
    ) async throws -> (found: GCalEvent, namedStart: GCalDateTime, namedPlace: GCalDateTime, cut: SplitCarry.Cut, place: String?) {
        let found = try await occurrence(named: named, masterId: masterId, series: master, recurrenceId: recurrenceId, zone: zone)
        let unreadable = CalendarProviderError.notSupported("where the occurrence named falls in its series can't be read, so the series can't be split at it")
        guard let namedStart = found.start, let namedPlace = found.originalStartTime,
              let cut = SplitCarry.cut(named: found, series: master, anchor: .patternStart, missingDay: .lastDay) else { throw unreadable }
        guard case .at(let at) = cut else { return (found, namedStart, namedPlace, cut, nil) }
        guard let place = SplitCarry.splitAt(at, named: found, recurrenceId: recurrenceId, zone: zone) else { throw unreadable }
        return (found, namedStart, namedPlace, cut, place)
    }

    /// Outlook's rules for a move to another day (`CalendarProvider.dayMovedRules`): the series'
    /// recurrence as Graph stores it, read as the write reads it, turned (`turned`) with its range
    /// starting on the move's day for an edit of every occurrence (`graphPatchJSON`), or as the
    /// split's new part (`newPartRecurrence`), read back as an RRULE with the first day of the
    /// week Graph keeps for a weekly series every few weeks. A recurrence that can't be read back
    /// is refused, so the card never leaves out a change the write makes.
    func dayMovedRules(calendarId: String, eventId: String, series: GCalEvent, scope: String, recurrenceId: String?,
                       zone: TimeZone, move: RecurrenceDayShift.Move) async throws -> [String] {
        let unreadable = CalendarProviderError.notSupported(
            "this repeating event's pattern can't be read back as a rule, so its days can't be moved with it")
        let (masterId, snapshot) = try await resolveToMaster(eventId: eventId, select: Self.splitSelect)
        guard var stored = snapshot.raw["recurrence"] as? [String: Any],
              var range = stored["range"] as? [String: Any] else { throw unreadable }
        let recurrence: [String: Any]
        if scope == "this_and_following" {
            guard let recurrenceId else { throw unreadable }
            // The split point the write cuts at (`splitPoint`), found as `splitSeries` finds it.
            let point = try await splitPoint(
                named: eventId, masterId: masterId, master: snapshot.event, recurrenceId: recurrenceId, zone: zone)
            guard let place = point.place else { throw CalendarProviderError.notSupported(SplitCarry.pastEndRuleRefusal) }
            recurrence = try Self.newPartRecurrence(
                stored: snapshot, storedRecurrence: stored, newDay: move.to.description,
                splitNaiveISO: place, splitZone: zone, move: move)
        } else {
            range["startDate"] = move.to.description
            stored["range"] = range
            recurrence = try Self.turned(stored, by: move)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: recurrence),
              let decoded = try? JSONDecoder().decode(MSPatternedRecurrence.self, from: data),
              var rule = Self.rrule(decoded).first else { throw unreadable }
        let pattern = recurrence["pattern"] as? [String: Any]
        if pattern?["type"] as? String == "weekly", (pattern?["interval"] as? Int ?? 1) > 1,
           let first = pattern?["firstDayOfWeek"] as? String,
           let index = Self.graphWeekdays.firstIndex(of: first.lowercased()) {
            rule += ";WKST=" + RecurrenceDayShift.weekdayCodes[index]
        }
        return [rule]
    }

    /// The `numberOfOccurrences` of a split's new part when the stored series' range is numbered:
    /// the stored count less the occurrences the series keeps before the split
    /// (`RecurrenceTail.newSeriesEnd`), so the two parts hold the series' count between them and
    /// the new part ends on the series' last occurrence.
    ///
    /// Measured on Outlook (a weekly series of six, its third occurrence deleted and its fourth
    /// moved a day): the range stayed numbered with six, and the series still ended on its sixth
    /// week. A deleted and a moved occurrence still count toward `numberOfOccurrences`, so the
    /// occurrences before the split are the ones the pattern generates, whatever has happened to
    /// them since; the instances list is not read for this.
    ///
    /// Counted as Graph applies the pattern: from the range's `startDate`, a date in the range's
    /// zone that is an occurrence only when the pattern names it (`.patternStart`; measured: a
    /// `startDate` the pattern does not name does not count toward the number, and Graph moves
    /// such a `startDate`, with the event's start, forward to the first pattern day when the series
    /// is created); the split
    /// occurrence's day in the same zone (`GCalEvent.seriesZone`; an all-day split is a date); and
    /// weeks starting on the pattern's `firstDayOfWeek` (the rule's `WKST`), which decides which
    /// weeks a series repeating every few weeks falls in; and a month without the pattern's
    /// `dayOfMonth` (`absoluteMonthly`, `absoluteYearly`) holding the occurrence on its last day,
    /// counted (`MissingMonthDay.lastDay`; measured: monthly on the 31st, numbered 4, gave January
    /// 31, February 28, March 31 and April 30), where RFC 5545, and so Google and CalDAV, skip it.
    ///
    /// Throws `notSupported`, before anything is written, when no occurrence is left from the split
    /// on, or the count can't be worked out (a day that can't be placed, a pattern
    /// `RecurrenceTail` does not count, or a stored count that is no number of occurrences).
    nonisolated static func occurrencesLeft(
        stored: EditSnapshot,
        storedRange: [String: Any],
        splitNaiveISO: String,
        splitZone: TimeZone
    ) throws -> Int {
        let counted = try numberedRange(stored: stored, storedRange: storedRange, splitNaiveISO: splitNaiveISO, splitZone: splitZone)
        return try RecurrenceTail.newSeriesEnd(
            count: counted.count, of: counted.rule, seriesStart: counted.seriesStart, split: counted.split,
            anchor: .patternStart, missingDay: .lastDay)
    }

    /// A numbered range as `occurrencesLeft` and `splitAlreadyEnded` count it: the stored count,
    /// the series' rule with the pattern's `firstDayOfWeek` as its `WKST`, the range's
    /// `startDate`, and the split occurrence's day in the series' zone (nil when one can't be
    /// placed). Throws `notSupported` when the range gives no count.
    nonisolated static func numberedRange(
        stored: EditSnapshot,
        storedRange: [String: Any],
        splitNaiveISO: String,
        splitZone: TimeZone
    ) throws -> (count: Int, rule: String, seriesStart: RecurrenceTail.Day?, split: RecurrenceTail.Day?) {
        guard let count = storedRange["numberOfOccurrences"] as? Int, count >= 1,
              let rrule = stored.event.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else {
            throw CalendarProviderError.notSupported(
                "Can't split this series: Outlook gives no number of occurrences for it, so the new series' length can't be worked out. Edit the whole series instead.")
        }
        let weekStarts = ["sunday": "SU", "monday": "MO", "tuesday": "TU", "wednesday": "WE",
                          "thursday": "TH", "friday": "FR", "saturday": "SA"]
        let wkst = stored.event.recurrenceFirstDayOfWeek.flatMap { weekStarts[$0.lowercased()] }
        let rule = rrule + (wkst.map { ";WKST=\($0)" } ?? "")
        let seriesStart = (storedRange["startDate"] as? String).flatMap { RecurrenceTail.Day(iso: $0) }
        let split: RecurrenceTail.Day?
        if stored.event.isAllDay {
            split = RecurrenceTail.Day(iso: splitNaiveISO)
        } else {
            split = stored.event.seriesZone
                .flatMap { RecurrenceOccurrenceResolver.renderNaive(splitNaiveISO, from: splitZone, to: $0) }
                .flatMap { RecurrenceTail.Day(iso: $0) }
        }
        return (count, rule, seriesStart, split)
    }

    // MARK: - Edits (#421)

    /// An event as an edit reads it: the `GCalEvent` the shared merge helper works
    /// on, plus the Graph JSON of the same read for what that mapping narrows and
    /// an edit must keep (the stored `recurrence`, each attendee's type, and an
    /// online meeting's stored HTML `body` and `onlineMeeting`, which
    /// `onlineMeetingBody` writes new notes around).
    struct EditSnapshot {
        let event: GCalEvent
        let raw: [String: Any]

        /// Lowercased attendee address → Graph attendee type
        /// (`required`, `optional`, `resource`).
        var attendeeTypes: [String: String] {
            var types: [String: String] = [:]
            for attendee in raw["attendees"] as? [[String: Any]] ?? [] {
                guard let address = (attendee["emailAddress"] as? [String: Any])?["address"] as? String,
                      let type = attendee["type"] as? String else { continue }
                types[address.lowercased()] = type
            }
            return types
        }
    }

    private func fetchForEdit(eventId: String, select: String = eventSelect) async throws -> EditSnapshot {
        let encodedEventId = try Self.encodedGraphPathSegment(eventId, context: "Graph event id")
        let data = try await request(path: "/events/\(encodedEventId)?$select=\(select)")
        let decoded = try JSONDecoder().decode(MSEvent.self, from: data)
        let raw = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return EditSnapshot(event: toGCalEvent(decoded), raw: raw)
    }

    /// The PATCH body for an edit: only the properties `patch` sets, plus what a
    /// changed property needs with it —
    ///
    /// - start and end together when either moves (`mergeExistingEventWithPatch`
    ///   derives the side the user did not give from the event's duration); for a
    ///   series, only when the edit moves them (`movesSeriesTime`), since Graph resets
    ///   a series' changed occurrences on any start or end change (#423, measured);
    /// - `recurrence` (when `allowRecurrence`) only when the edit gives a rule
    ///   the series does not already have (`sameRule`), with start and end
    ///   beside it: PATCHing `recurrence` alone makes Graph rewrite a master's
    ///   start and end to UTC midnight at the range's `startDate` (see
    ///   `splitSeries`' cap PATCH). The rule keeps the stored `firstDayOfWeek`
    ///   unless it names its own (`WKST`), and the stored `recurrenceTimeZone`
    ///   (the start's zone when none is stored);
    /// - when a series' start moves to another date and the rule does not
    ///   change, the stored recurrence exactly as Graph holds it, with only the
    ///   range's `startDate` moved, because Graph requires it to match the start.
    ///   A series edit that keeps its date writes no recurrence: any recurrence
    ///   write that differs from the stored one resets the series' exceptions
    ///   (#423, measured);
    /// - a series' start and end, when sent, labelled with its stored zone: a timed one at the
    ///   same instant, an all-day one on the same dates (`inSeriesZone`, #719, #747);
    /// - the edit's guest change applied to the stored attendees of the item read: each one kept
    ///   is written as stored, a new one `required` and unanswered (`appliedAttendeesJSON`, #622,
    ///   #620). A series write is the only write the app makes for a change of every occurrence:
    ///   Graph carries the series' resulting difference to each of its occurrences, on top of that
    ///   occurrence's own guests: each guest the written list drops from the series' stored list is
    ///   removed, each guest it holds that the stored list did not is added, and every other guest
    ///   the occurrence holds stays (a guest it added on its own stays; one it dropped on its own
    ///   comes back only when the series gains them), renamed and moved ones too, and an exception
    ///   stays an exception. Measured on a test account (2026-11-11) for an added and a removed
    ///   guest, for a series emptied of its guests (an exception kept the guest it held on its
    ///   own) and for a series list written back unchanged (an exception that had dropped a guest
    ///   stayed without them), as on Google (`AttendeeChange.seriesDifference`);
    /// - a new description of an online meeting replaces only the notes in the
    ///   stored body, keeping its join section (`onlineMeetingBody`, #511); the
    ///   description the assistant read is those notes (`notes(of:)`).
    ///
    /// Empty when the patch changes nothing.
    ///
    /// Throws when the edit gives a rule and the series' stored `recurrenceTimeZone` is a zone
    /// `CalendarTimeZoneResolver` does not recognize: the rule's end is dated in that zone.
    nonisolated func graphPatchJSON(patch: GCalEventInput, existing: EditSnapshot, allowRecurrence: Bool) throws -> [String: Any] {
        let current = existing.event
        // A whole-series edit sends start and end only when they move the series (#423): the
        // card asks the same question (`editResetsChangedOccurrences`).
        let movesTime = allowRecurrence && current.recurrence?.isEmpty == false
            ? movesSeriesTime(patch, existing: current)
            : patch.startDate != nil || patch.startDateTime != nil || patch.endDate != nil || patch.endDateTime != nil
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: current, patch: patch)

        var sparse = GCalEventInput()
        sparse.summary = patch.summary
        sparse.location = patch.location
        sparse.description = patch.description
        sparse.transparency = patch.transparency
        // The series' own zone (#423): a rule the edit gives is dated and labelled in it.
        let storedRecurrence = existing.raw["recurrence"] as? [String: Any]
        let storedZoneName = ((storedRecurrence?["range"] as? [String: Any])?["recurrenceTimeZone"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        var rangeZone: TimeZone?
        if allowRecurrence, patch.recurrence != nil, let storedZoneName {
            guard let zone = CalendarTimeZoneResolver.zone(named: storedZoneName, in: .none) else {
                throw CalendarProviderError.unrecognizedTimeZone(storedZoneName, consequence: "it did not change the event")
            }
            rangeZone = zone
        }
        // A rule the series already has is no rule (#423), so an equal rule leaves the
        // date-move step below to keep the range.
        if allowRecurrence {
            sparse.recurrence = seriesRuleToWrite(patch, existing: current, stored: storedRecurrence, rangeZone: rangeZone)
        }
        let storedFirstDay = (storedRecurrence?["pattern"] as? [String: Any])?["firstDayOfWeek"] as? String
        if movesTime || sparse.recurrence != nil {
            sparse.startDate = merged.startDate
            sparse.startDateTime = merged.startDateTime
            sparse.startTimeZone = merged.startTimeZone
            sparse.endDate = merged.endDate
            sparse.endDateTime = merged.endDateTime
            sparse.endTimeZone = merged.endTimeZone
        }
        // The encoder writes the series' first day of the week unless the rule names its own
        // (`WKST`), the same output `seriesRuleToWrite` compared.
        var json = toGraphEventJSON(sparse, rangeZone: rangeZone, firstDayOfWeek: storedFirstDay)
        // A series' start and end are written in the series' own zone: a timed one at the same
        // instant (#719), as Exchange refuses a series start labelled with another zone; an
        // all-day one on the same dates (#747), as Graph otherwise stores every occurrence two
        // days longer. After the `movesTime` decision, so a relabel never makes a same-instant
        // edit a move.
        if allowRecurrence {
            let allDay = json["isAllDay"] as? Bool ?? (sparse.startDate != nil || sparse.endDate != nil)
            for key in ["start", "end"] {
                if let time = json[key] as? [String: Any] { json[key] = Self.inSeriesZone(time, seriesZone: storedZoneName, allDay: allDay) }
            }
        }
        // A rule that changes the series keeps the series' zone (#423): the rebuilt rule names
        // no zone, and Graph stores a range written without a zone as UTC. With none stored, the
        // zone is the one the start is written in.
        if var rule = json["recurrence"] as? [String: Any],
           var range = rule["range"] as? [String: Any] {
            range["recurrenceTimeZone"] = storedZoneName ?? (json["start"] as? [String: Any])?["timeZone"] as? String
            rule["range"] = range
            json["recurrence"] = rule
        }
        if let change = patch.attendeeChange {
            let own = existing.raw["attendees"] as? [[String: Any]] ?? []
            let after = Self.appliedAttendeesJSON(change, to: own)
            json["attendees"] = after
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] graphPatchJSON: guest change applied to 1 item, guests \(own.count)->\(after.count)")
            }
        }
        // A move to another day whose rule names its days (`ruleDayMove`, decided in the series'
        // own zone) writes the stored pattern turned, its range starting on the move's day, whatever
        // day the edit's own zone dates the start on.
        if allowRecurrence, sparse.recurrence == nil, movesTime, let move = patch.ruleDayMove,
           var stored = existing.raw["recurrence"] as? [String: Any],
           var range = stored["range"] as? [String: Any] {
            range["startDate"] = move.to.description
            stored["range"] = range
            json["recurrence"] = try Self.turned(stored, by: move)
        } else if allowRecurrence, sparse.recurrence == nil, movesTime,
           var stored = existing.raw["recurrence"] as? [String: Any],
           var range = stored["range"] as? [String: Any],
           let newDay = Self.seriesDay(merged.startDate, merged.startDateTime, in: merged.startTimeZone, seriesZone: storedZoneName),
           newDay != Self.seriesDay(current.start?.date, current.start?.dateTime, in: current.start?.timeZone, seriesZone: storedZoneName) {
            range["startDate"] = newDay
            stored["range"] = range
            json["recurrence"] = stored
        }
        if let description = patch.description, let body = Self.onlineMeetingBody(existing.raw, notes: description) {
            json["body"] = body
        }
        return json
    }

    /// Graph's day names, in the order of `RecurrenceDayShift.weekdayCodes`.
    static let graphWeekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// A stored recurrence (Graph's `patternedRecurrence`) with the days its pattern names turned by
    /// `move`, by the rule an RRULE's are (`RecurrenceDayShift`): weekdays (`daysOfWeek`) turn, and
    /// the first day of the week with them when a weekly pattern repeats every few weeks; a day of
    /// the month (`dayOfMonth`) and a month (`month`) move. A pattern naming a day by its position
    /// (`relativeMonthly`, `relativeYearly`) is kept, as an RRULE's `BYDAY=2TU` is. Its range is
    /// kept. Throws `notSupported` for a day a move can't carry.
    nonisolated static func turned(_ recurrence: [String: Any], by move: RecurrenceDayShift.Move) throws -> [String: Any] {
        guard move.days != 0, var pattern = recurrence["pattern"] as? [String: Any] else { return recurrence }
        let type = pattern["type"] as? String
        guard type != "relativeMonthly", type != "relativeYearly" else { return recurrence }
        func turn(_ name: String) throws -> String {
            guard let index = graphWeekdays.firstIndex(of: name.lowercased()) else {
                throw CalendarProviderError.notSupported("this repeating event's days (\(name)) can't be moved to another day")
            }
            let code = try RecurrenceDayShift.weekday(RecurrenceDayShift.weekdayCodes[index], by: move.days)
            return graphWeekdays[RecurrenceDayShift.weekdayCodes.firstIndex(of: code) ?? index]
        }
        if let days = pattern["daysOfWeek"] as? [String], !days.isEmpty {
            pattern["daysOfWeek"] = try days.map(turn)
            if type == "weekly", (pattern["interval"] as? Int ?? 1) > 1, let first = pattern["firstDayOfWeek"] as? String {
                pattern["firstDayOfWeek"] = try turn(first)
            }
        }
        if let day = pattern["dayOfMonth"] as? Int, day != 0 {
            pattern["dayOfMonth"] = try RecurrenceDayShift.monthDay(day, by: move.monthDays)
        }
        if let month = pattern["month"] as? Int, month != 0 {
            pattern["month"] = RecurrenceDayShift.month(month, by: move.months)
        }
        var turned = recurrence
        turned["pattern"] = pattern
        return turned
    }

    /// The rule a whole-series edit `patch` writes on the series `existing` (#423): nil when it
    /// gives none, or gives the series' own. The assistant re-sends the rule it read, and
    /// writing it rebuilt would reset the series' exceptions. The edit is merged with the series
    /// as the write merges it (`mergeExistingEventWithPatch`: the edit's start, zone and rule),
    /// its rule built as `toGraphEventJSON` writes it beside that start, in `rangeZone`, and
    /// compared with `stored`, the series' recurrence in Graph's form (`sameRule`). With nothing
    /// stored, the rule is written. The one decision both the write (`graphPatchJSON`) and the
    /// edit's card (`editResetsChangedOccurrences`) take, so the two cannot differ.
    nonisolated func seriesRuleToWrite(
        _ patch: GCalEventInput, existing: GCalEvent, stored: [String: Any]?, rangeZone: TimeZone?
    ) -> [String]? {
        guard let rule = patch.recurrence else { return nil }
        guard let stored else { return rule }
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existing, patch: patch)
        var probe = GCalEventInput()
        probe.recurrence = rule
        probe.startDate = merged.startDate
        probe.startDateTime = merged.startDateTime
        probe.startTimeZone = merged.startTimeZone
        let storedFirstDay = (stored["pattern"] as? [String: Any])?["firstDayOfWeek"] as? String
        guard let rebuilt = toGraphEventJSON(probe, rangeZone: rangeZone, firstDayOfWeek: storedFirstDay)["recurrence"] as? [String: Any],
              Self.sameRule(rebuilt, as: stored)
        else { return rule }
        return nil
    }

    /// Whether the whole-series edit `edit` resets the occurrences of `event` changed one by one
    /// (#423). Graph resets a series' deleted and moved occurrences when a PATCH changes its
    /// rule, and when it changes its start or end (measured on a work account, 2026-11-10: a
    /// start/end PATCH alone brought a deleted occurrence back and made a moved one a plain
    /// occurrence at the new time). So: when the edit moves the series' start or end
    /// (`movesSeriesTime`), or when the rule the write would write (`seriesRuleToWrite`) is not
    /// the stored one. The stored rule is `event`'s RRULE in Graph's form, beside the event's
    /// own start, in the series' zone (`recurrenceTimeZoneName`, read with the event). The rule
    /// changes when the event has none, when its zone is one `CalendarTimeZoneResolver` does not
    /// recognize (the write refuses that edit), and when its Graph pattern does not come back
    /// the same through an RRULE (`rrule(_:)`), so its RRULE does not say what is stored.
    nonisolated func editResetsChangedOccurrences(_ event: GCalEvent, edit: GCalEventInput) -> Bool {
        if movesSeriesTime(edit, existing: event) { return true }
        guard edit.recurrence != nil else { return false }
        guard let baseline = storedRuleBaseline(event) else { return true }
        return seriesRuleToWrite(edit, existing: event, stored: baseline.recurrence, rangeZone: baseline.rangeZone) != nil
    }

    /// The card's stand-in for the recurrence Graph stores for `event` (#423): its RRULE rebuilt in
    /// Graph's form beside the event's own start, in the series' zone (`recurrenceTimeZoneName`),
    /// with that zone and its stored first day of the week (`recurrenceFirstDayOfWeek`). Nil when it can't stand in: no RRULE, a zone `CalendarTimeZoneResolver` does
    /// not recognize, or a rebuilt pattern whose RRULE (`rrule(_:)`) is not the event's.
    nonisolated func storedRuleBaseline(_ event: GCalEvent) -> (recurrence: [String: Any], rangeZone: TimeZone?)? {
        guard let storedRule = event.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else { return nil }
        var rangeZone: TimeZone?
        if let name = event.recurrenceTimeZoneName {
            guard let zone = CalendarTimeZoneResolver.zone(named: name, in: .none) else { return nil }
            rangeZone = zone
        }
        let start = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: event, patch: GCalEventInput())
        var storedInput = GCalEventInput()
        storedInput.recurrence = [storedRule]
        storedInput.startDate = start.startDate
        storedInput.startDateTime = start.startDateTime
        storedInput.startTimeZone = start.startTimeZone
        guard let stored = toGraphEventJSON(storedInput, rangeZone: rangeZone, firstDayOfWeek: event.recurrenceFirstDayOfWeek)["recurrence"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: stored),
              let decoded = try? JSONDecoder().decode(MSPatternedRecurrence.self, from: data),
              Self.rrule(decoded).map(GoogleCalendarProvider.canonicalRRULE) == [GoogleCalendarProvider.canonicalRRULE(storedRule)]
        else { return nil }
        return (stored, rangeZone)
    }

    /// Whether the whole-series edit `patch` moves the series `existing`'s start or end (#423).
    /// A series' time moves when the instant of its start or end changes, or its all-day date, or
    /// anything else the encoder writes beside them (all-day or timed): the whole of what
    /// `toGraphEventJSON` writes for the start and end the write would send (the edit merged as
    /// the write merges it) against the same for the series' own, each timed start and end read
    /// as its instant (`graphTimes`). The same instant under another zone name is no move: a read
    /// gives the times in the zone it asks for, so an edit that echoes them restates the series'
    /// own. A time that can't be read as an instant is a move. The one decision both the write
    /// (`graphPatchJSON`, which sends a series' start and end only for a move or beside a rule)
    /// and the edit's card (`editResetsChangedOccurrences`) take, so the two cannot differ.
    nonisolated func movesSeriesTime(_ patch: GCalEventInput, existing: GCalEvent) -> Bool {
        guard patch.startDate != nil || patch.startDateTime != nil || patch.endDate != nil || patch.endDateTime != nil
        else { return false }
        guard let sent = graphTimes(GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existing, patch: patch)),
              let own = graphTimes(GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existing, patch: GCalEventInput()))
        else { return true }
        return !sent.isEqual(own)
    }

    /// What `toGraphEventJSON` writes for `merged`'s start and end, with each timed start and end
    /// replaced by the instant it names: its wall time in the zone `CalendarTimeZoneResolver`
    /// resolves its label to. An all-day start and end stay as written (dates). Nil when a label
    /// does not resolve or a wall time does not parse.
    nonisolated func graphTimes(_ merged: GCalEventInput) -> NSDictionary? {
        var times = GCalEventInput()
        times.startDate = merged.startDate
        times.startDateTime = merged.startDateTime
        times.startTimeZone = merged.startTimeZone
        times.endDate = merged.endDate
        times.endDateTime = merged.endDateTime
        times.endTimeZone = merged.endTimeZone
        var json = toGraphEventJSON(times)
        guard json["isAllDay"] as? Bool != true else { return NSDictionary(dictionary: json) }
        for (key, value) in json {
            guard let part = value as? [String: Any], let label = part["timeZone"] as? String else { continue }
            guard let zone = CalendarTimeZoneResolver.zone(named: label, in: .none),
                  let dateTime = part["dateTime"] as? String
            else { return nil }
            let wall = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)
            guard let instant = wall.date(from: String(dateTime.prefix(19))) else { return nil }
            json[key] = ["instant": instant.timeIntervalSince1970]
        }
        return NSDictionary(dictionary: json)
    }

    /// Whether `rebuilt`, an edit's rule as `toGraphEventJSON` writes it, means the rule the
    /// series already has (`stored`, as Graph holds it) (#423). Graph fills the properties a
    /// pattern or range does not use with defaults, and the rebuilt rule names every property
    /// its own type uses, so only those are compared, the days of the week in any order. The
    /// first day of the week is compared like the rest: the encoder writes the stored one unless
    /// the rule names its own (`WKST`), so a rule without `WKST` matches it by construction and a
    /// changed `WKST` is a rule change. Whether Graph resets a series' exceptions on a change of
    /// only the first day is not measured; it is assumed to, like any other pattern change. The
    /// range's `startDate` is left out: it follows the start, and a series moved to another
    /// date with its own rule is a date move.
    nonisolated static func sameRule(_ rebuilt: [String: Any], as stored: [String: Any]) -> Bool {
        for part in ["pattern", "range"] {
            guard let mine = rebuilt[part] as? [String: Any], var theirs = stored[part] as? [String: Any] else { return false }
            if part == "pattern" {
                theirs["index"] = Self.storedIndex(type: theirs["type"] as? String, index: theirs["index"] as? String)
            }
            for (key, value) in mine where key != "startDate" {
                if key == "daysOfWeek" {
                    guard Set(value as? [String] ?? []) == Set(theirs[key] as? [String] ?? []) else { return false }
                } else if !(value as AnyObject).isEqual(theirs[key]) {
                    return false
                }
            }
        }
        return true
    }

    /// The status a new attendee is written with: unanswered, with no response time (the form
    /// measured accepted on an Outlook.com account, #622).
    nonisolated static var unansweredAttendeeStatus: [String: Any] { ["response": "none", "time": "0001-01-01T00:00:00Z"] }

    /// The attendee list an edit writes when it changes who attends (#622): `change` applied to the
    /// edit's read of the item (`AttendeeChange.apply`, #620). Each attendee it keeps goes back
    /// exactly as the read holds them (type, answer and name, matched by address in any letter
    /// case); each one it adds as `required` and unanswered. Measured on an Outlook.com account:
    /// Graph refuses with 405 an attendee list in which any entry has no `status`, and an attendee
    /// sent with their stored status keeps their answer.
    nonisolated static func appliedAttendeesJSON(_ change: AttendeeChange, to stored: [[String: Any]]) -> [[String: Any]] {
        change.apply(to: stored, address: {
            (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased()
        }) { add in
            var address: [String: Any] = ["address": add.email]
            if let name = add.name { address["name"] = name }
            return ["emailAddress": address, "type": "required", "status": unansweredAttendeeStatus]
        }
    }

    /// The `body` a description edit of an online meeting writes: the stored HTML
    /// with only its notes replaced and the join section kept as stored
    /// (`GraphOnlineMeetingBody`, #511). Nil for an event that is no online
    /// meeting, or whose join section is not recognised: the description is then
    /// written as the whole body, as for any event, and an online meeting with a layout
    /// unlike the recognised ones loses its join section and is turned off, as
    /// every description edit of an online meeting did before #511.
    nonisolated static func onlineMeetingBody(_ stored: [String: Any], notes description: String) -> [String: Any]? {
        guard let joinUrl = (stored["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String else { return nil }
        guard let body = stored["body"] as? [String: Any],
              (body["contentType"] as? String)?.lowercased() == "html",
              let html = body["content"] as? String,
              let kept = GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: joinUrl, with: description)
        else {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] online meeting: join section not recognised, the description is written as the whole body")
            return nil
        }
        return ["contentType": "html", "content": kept]
    }

    /// The date a start falls on for the device: an all-day start's own date, a
    /// timed one's instant dated in the device's zone (the zone `request` asks
    /// Graph to read starts in). The instant is the one Graph stores: the wall
    /// time `toGraphEventJSON` writes (`graphNaiveDateTime`, which drops an
    /// offset or `Z` without converting) in the zone the start is labelled with
    /// (`timeZone`, the device's when nil, as `toGraphEventJSON` labels it).
    /// The tools spell a start with its label's offset, so that wall time is the
    /// instant the start names. A string in no `yyyy-MM-ddTHH:mm:ss` form (no
    /// wall time, or a one-digit hour such as `…T9:00`) is dated as written.
    /// The day a start falls on in the series' zone `seriesZone` (its range's `recurrenceTimeZone`,
    /// as Graph returned it): the day a series' start is written on since #719, so a range's
    /// `startDate` and the start it is written beside name the same day, and a move changes the
    /// series' date exactly when it changes that day. An all-day `date` is its own day. When the
    /// series names no zone, or one TabMail does not recognize (#746), the device's day (`day`), as
    /// before #719, because the start is then written as it was given.
    nonisolated static func seriesDay(_ date: String?, _ dateTime: String?, in timeZone: String?, seriesZone: String?) -> String? {
        if let date { return String(date.prefix(10)) }
        guard let dateTime, let seriesZone, let series = CalendarTimeZoneResolver.zone(named: seriesZone, in: .none),
              let given = CalendarTimeZoneResolver.zone(named: timeZone ?? TimeZone.current.identifier, in: .none)
        else { return day(date, dateTime, in: timeZone) }
        return RecurrenceOccurrenceResolver.renderNaive(String(graphNaiveDateTime(dateTime).prefix(19)), from: given, to: series)
            .map { String($0.prefix(10)) }
    }

    nonisolated static func day(_ date: String?, _ dateTime: String?, in timeZone: String?) -> String? {
        if let date { return String(date.prefix(10)) }
        guard let dateTime else { return nil }
        let wall = FixedDateFormat.formatter(
            "yyyy-MM-dd'T'HH:mm:ss",
            timeZone: timeZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .current
        )
        guard let instant = wall.date(from: String(graphNaiveDateTime(dateTime).prefix(19))) else {
            return String(dateTime.prefix(10))
        }
        let fmt = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .current)
        return fmt.string(from: instant)
    }

    /// Find the Graph instance id for the occurrence `recurrenceId` names when
    /// read in `zone`, by enumerating a wide-enough window around that instant to
    /// tolerate DST and device/event timezone deltas. See
    /// `GoogleCalendarProvider.resolveInstanceId` for the ±25h rationale and for
    /// the full statement of why each failure mode gets its OWN error; we use the
    /// same window and the same shared `RecurrenceOccurrenceResolver` so the two
    /// backends cannot drift apart again (A7 — both copies of the day-prefix
    /// defect existed because the selection logic was duplicated, so the fix is
    /// one implementation, not two).
    ///
    /// Graph-specific note: `request` sends `Prefer: outlook.timezone="<device zone>"`,
    /// so a timed instance start comes back as a naive `dateTime` plus the IANA `timeZone`
    /// we asked for. That pairing is what makes the instant computable at all —
    /// unlike Google, the wire value carries NO offset. If Graph ever answers with
    /// a zone identifier Foundation cannot resolve (a Windows-style name such as
    /// "Pacific Standard Time"), we do not guess: an unplaceable candidate could
    /// be the one being addressed, and defaulting it to UTC would compute a wrong
    /// instant, which is how a wrong occurrence gets PATCHed. An all-day series is
    /// read differently (next paragraph).
    ///
    /// An occurrence of an ALL-DAY `series` is a date, not an instant (the resolver's Rule 3): each
    /// start is taken as its date, as every all-day start is read (`toGCalDateTime(_:isAllDay:
    /// true)`). Graph RELABELS an all-day start, it does not convert it (measured): every read gives
    /// midnight of the occurrence's own date, labelled with the zone `Prefer` names, so the zone the
    /// instances are read in changes no date. Read as an instant, that was midnight on the DEVICE, so
    /// an edit whose zone differs from the device's matched it in another frame: from a zone west of
    /// the device's, a date named the next day's occurrence, and the start the read tools show
    /// named none (#647).
    ///
    /// `named` is the occurrence id the edit gave, when it gave one (nil for the series' own id):
    /// that occurrence answers to `recurrenceId` before any other
    /// (`RecurrenceOccurrenceResolver.select(_:recurrenceId:zone:naming:)`), and another one is
    /// refused (`namesAnotherOccurrence`).
    private func resolveInstanceId(
        masterId: String, series: GCalEvent, recurrenceId: String, zone: TimeZone, naming named: String?
    ) async throws -> String {
        guard let centerDate = RecurrenceOccurrenceResolver.windowCenter(recurrenceId: recurrenceId, zone: zone) else {
            throw CalendarProviderError.notSupported(
                "Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00') or a date (e.g. '2026-05-20')."
            )
        }
        let windowSeconds: TimeInterval = 25 * 60 * 60
        let minDate = centerDate.addingTimeInterval(-windowSeconds)
        let maxDate = centerDate.addingTimeInterval(windowSeconds)
        let utcFmt = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: .gmt)
        let startQS = utcFmt.string(from: minDate)
        let endQS = utcFmt.string(from: maxDate)

        let encodedMaster = try Self.encodedGraphPathSegment(masterId, context: "Graph series master id")
        let encodedStart = startQS.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? startQS
        let encodedEnd = endQS.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? endQS
        let data = try await request(
            path: "/events/\(encodedMaster)/instances?startDateTime=\(encodedStart)&endDateTime=\(encodedEnd)&$select=id,start")

        struct InstancesResponse: Decodable { let value: [MSEvent] }
        let resp = try JSONDecoder().decode(InstancesResponse.self, from: data)

        var candidates: [OccurrenceCandidate] = []
        for ev in resp.value {
            guard let id = ev.id, let start = ev.start, let dt = start.dateTime else { continue }
            if series.isAllDay {
                candidates.append(OccurrenceCandidate(id: id, instant: nil, dateOnly: toGCalDateTime(start, isAllDay: true)?.date))
                continue
            }
            guard let startZone = CalendarTimeZoneResolver.zone(named: start.timeZone ?? "UTC", in: .none) else {
                throw CalendarProviderError.notSupported(
                    "Microsoft Graph returned an occurrence of \(masterId) in an unrecognized timezone ('\(start.timeZone ?? "")') — refusing to edit an occurrence that may not be the one you named."
                )
            }
            let fmt = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: startZone)
            guard let instant = fmt.date(from: String(dt.prefix(19))) else {
                throw CalendarProviderError.notSupported(
                    "Could not interpret the start time of an occurrence of \(masterId) returned by Microsoft Graph ('\(dt)') — refusing to edit an occurrence that may not be the one you named."
                )
            }
            candidates.append(OccurrenceCandidate(id: id, instant: instant, dateOnly: nil))
        }

        switch RecurrenceOccurrenceResolver.select(candidates, recurrenceId: recurrenceId, zone: zone, naming: named) {
        case .resolved(let id):
            if let named, id != named {
                throw CalendarProviderError.notSupported(RecurrenceOccurrenceResolver.namesAnotherOccurrence(recurrenceId))
            }
            return id
        case .absent:
            throw ExchangeCalendarError.eventNotFound
        case .ambiguous(let count):
            throw CalendarProviderError.notSupported(
                "recurrence_id '\(recurrenceId)' (\(zone.identifier)) matched \(count) occurrences of \(masterId) — refusing to guess which one you meant. Re-read the event and use the exact start_iso of the occurrence you want."
            )
        case .malformed:
            throw CalendarProviderError.notSupported(
                "Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00') or a date (e.g. '2026-05-20')."
            )
        }
    }

    // MARK: - HTTP

    /// Encode `value` as exactly ONE Graph path segment, or throw.
    ///
    /// Every id below is a Graph resource id: opaque, server-minted, and free to
    /// contain `/`, `+`, `=`, `?` or `#`. This used to be
    /// `value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value`
    /// at nine sites, which is wrong twice over:
    ///
    ///  - `.urlPathAllowed` is a PATH set, not a SEGMENT set — it permits `/`,
    ///    `;`, `=`, `+`, `@` and `,` literally. A `/` inside an event or calendar
    ///    id therefore survives encoding and changes which ROUTE Graph selects,
    ///    so a PATCH or DELETE meant for one resource can address another. On a
    ///    calendar path that is a wrong-event mutation.
    ///  - `?? value` fell back to the RAW string on failure. A fail-dangerous
    ///    default on a guard is worse than no guard: it is silent, and it fires
    ///    exactly on the inputs the guard exists for.
    ///
    /// `GraphAPI.encodedGraphPathSegment` is the single source of truth for the
    /// allowed set (RFC 3986 unreserved) and is already what `ExchangeProvider`
    /// uses on the mail side; this wrapper exists only to put the failure in
    /// THIS type's error domain, exactly as `ExchangeProvider`'s does.
    private static func encodedGraphPathSegment(
        _ value: String,
        context: String
    ) throws -> String {
        guard let encoded = GraphAPI.encodedGraphPathSegment(value) else {
            throw ExchangeCalendarError.invalidPathSegment(context)
        }
        return encoded
    }

    /// 🚨 **R14-F1 — THE ERROR PAYLOAD IS `errorBody`, NEVER `data`.** Identical
    /// to `GoogleCalendarProvider.request`'s note, kept in step deliberately:
    /// `performHTTPRequest` nils `data` on every non-2xx and puts the server's
    /// bytes in `errorBody`, so `httpError(_, result.data)` could only ever carry
    /// `nil`. Every reason string `badRequestReason` / `parseHttpReason` surfaced
    /// to the user and to the LLM was therefore the code-only fallback.
    /// `timeZoneName`: the zone `Prefer: outlook.timezone` names, exactly as given; the device's
    /// when nil (see below).
    private func request(path: String, method: String = "GET", body: Data? = nil, timeZoneName: String? = nil) async throws -> Data {
        let token = try await accessToken(false)
        // `Prefer: outlook.timezone` controls the timezone Graph uses in the
        // response's `start.timeZone` / `end.timeZone`. Without it Graph
        // defaults to UTC. We used to set it to `"UTC"` explicitly, which
        // caused a nasty round-trip bug: a freshly-created event stored in
        // the user's local zone was returned as `{dateTime: "...UTC time...",
        // timeZone: "UTC"}`; `mergeMasterAndPatch` then inherited that "UTC"
        // for the split's new series, and the POST stored the new series with
        // `timeZone: "UTC"` — shifting the displayed wall time of every
        // post-split occurrence by the user's UTC offset (e.g. 16:00 PDT →
        // 16:00 UTC = 09:00 PDT visible). Use the device's IANA zone so the
        // round-trip preserves the user's intended wall time.
        let prefTz = timeZoneName ?? TimeZone.current.identifier
        let headers = ["Prefer": "outlook.timezone=\"\(prefTz)\""]
        // Throttling (429) and 503 are retried after Graph's `Retry-After`, like the
        // mail provider's requests (#426).
        let policy = HTTPRetryPolicy.graph
        let result = try await performHTTPRequestWithRetry(
            url: baseURL + path, method: method, body: body, token: token, extraHeaders: headers,
            retryableStatusCodes: policy.retryableStatusCodes, maxAttempts: policy.maxAttempts,
            initialDelay: policy.initialDelay, session: testSession, logLabel: "ExchangeCalendar", gate: mailboxGate)

        if let data = result.data {
            return data
        }

        // 401 — token expired, force refresh and retry once
        if result.statusCode == 401 {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] Token expired, refreshing...")
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: freshToken, extraHeaders: headers, session: testSession, logLabel: "ExchangeCalendar", gate: mailboxGate)
            // `headers` already carries the local-tz Prefer from the first attempt above.
            if let data = retry.data {
                return data
            }
            throw ExchangeCalendarError.httpError(retry.statusCode, retry.errorBody)
        }

        // 403 — missing scope
        if result.statusCode == 403 {
            throw ExchangeCalendarError.missingScope
        }

        throw ExchangeCalendarError.httpError(result.statusCode, result.errorBody)
    }

    // MARK: - Model Mapping (Graph → GCal)

    /// True when Graph returned an event with no subject, no attendees, no location,
    /// and no body. Such rows come from room-mailbox calendar processing
    /// (`DeleteSubject=$True`) or from private events on shared calendars — the user
    /// can't reference them, and surfacing them to the agent crowds out real events.
    /// Applied only on list paths (`listEvents`); single-event lookups
    /// (`getEvent`/`createEvent`/`updateEvent`) keep returning the underlying event.
    /// Internal (not private) so unit tests can call it.
    func isEmptySurfaceEvent(_ e: MSEvent) -> Bool {
        let hasSubject = !(e.subject?.isEmpty ?? true)
        let hasAttendees = !(e.attendees?.isEmpty ?? true)
        let hasLocation = !(e.location?.displayName?.isEmpty ?? true)
        let hasBody = !(e.bodyPreview?.isEmpty ?? true)
        return !hasSubject && !hasAttendees && !hasLocation && !hasBody
    }

    /// A stored relative pattern's `index`, with a missing one read as `first`, Graph's
    /// default for `relativeMonthly` and `relativeYearly`. Measured: a relative series created
    /// with no index comes back with `first`; normalized here in case an older item lacks it. The reader (`rrule(_:)`) and the comparison (`sameRule`) both read the stored
    /// index through this, so the card and the write compare the same pattern.
    nonisolated static func storedIndex(type: String?, index: String?) -> String? {
        guard index == nil, let type = type?.lowercased(), type == "relativemonthly" || type == "relativeyearly" else { return index }
        return "first"
    }

    /// A Graph recurrence as an RFC 5545 RRULE (`toGCalEvent`); `[]` when it has no pattern.
    nonisolated static func rrule(_ rec: MSPatternedRecurrence) -> [String] {
        guard let pattern = rec.pattern else { return [] }
        let dayMap = ["sunday": "SU", "monday": "MO", "tuesday": "TU", "wednesday": "WE", "thursday": "TH", "friday": "FR", "saturday": "SA"]
        let byDay = (pattern.daysOfWeek ?? []).compactMap { dayMap[$0.lowercased()] }.joined(separator: ",")
        let indexToSetPos = ["first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1]
        let bySetPos = Self.storedIndex(type: pattern.type, index: pattern.index).flatMap { indexToSetPos[$0.lowercased()] }

        var parts: [String] = []
        switch pattern.type?.lowercased() {
        case "daily":
            parts.append("FREQ=DAILY")
        case "weekly":
            parts.append("FREQ=WEEKLY")
            if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
        case "absolutemonthly":
            parts.append("FREQ=MONTHLY")
            if let d = pattern.dayOfMonth { parts.append("BYMONTHDAY=\(d)") }
        case "relativemonthly":
            parts.append("FREQ=MONTHLY")
            if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
            if let sp = bySetPos { parts.append("BYSETPOS=\(sp)") }
        case "absoluteyearly":
            parts.append("FREQ=YEARLY")
            if let m = pattern.month { parts.append("BYMONTH=\(m)") }
            if let d = pattern.dayOfMonth { parts.append("BYMONTHDAY=\(d)") }
        case "relativeyearly":
            parts.append("FREQ=YEARLY")
            if let m = pattern.month { parts.append("BYMONTH=\(m)") }
            if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
            if let sp = bySetPos { parts.append("BYSETPOS=\(sp)") }
        default:
            // Unknown Graph type — emit a bare weekly so the value is at
            // least a valid FREQ rather than garbage.
            parts.append("FREQ=WEEKLY")
            if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
        }
        if let interval = pattern.interval, interval > 1 { parts.append("INTERVAL=\(interval)") }
        // Gate UNTIL/COUNT emission on `range.type` — Graph ALWAYS fills
        // `endDate` (with the sentinel "0001-01-01" for `noEnd`) and
        // ALWAYS fills `numberOfOccurrences` (with 0 for non-numbered).
        // Without the type check we emit `UNTIL=00010101` for every
        // open-ended series, which (a) shows the LLM/user a garbage RRULE
        // and (b) round-trips on subsequent edits into Graph as a real
        // capped series ending in year 0001.
        let rangeType = rec.range?.type?.lowercased()
        if rangeType == "enddate",
           let endDate = rec.range?.endDate, !endDate.isEmpty, endDate != "0001-01-01" {
            parts.append("UNTIL=\(endDate.replacingOccurrences(of: "-", with: ""))")
        } else if rangeType == "numbered",
                  let count = rec.range?.numberOfOccurrences, count > 0 {
            parts.append("COUNT=\(count)")
        }
        // `noEnd` (or any unknown type) → emit no UNTIL/COUNT.
        return ["RRULE:" + parts.joined(separator: ";")]
    }

    func toGCalEvent(_ e: MSEvent) -> GCalEvent {
        let transparency: String?
        switch e.showAs {
        case "free": transparency = "transparent"
        case "busy", "tentative", "oof", "workingElsewhere": transparency = "opaque"
        default: transparency = nil
        }

        let attendees: [GCalAttendee]? = e.attendees?.map { att in
            GCalAttendee(
                email: att.emailAddress?.address,
                displayName: att.emailAddress?.name,
                responseStatus: mapResponseStatus(att.status?.response),
                organizer: false,
                self: false
            )
        }

        let organizer: GCalOrganizer? = e.organizer.map { org in
            GCalOrganizer(
                email: org.emailAddress?.address,
                displayName: org.emailAddress?.name,
                self: false
            )
        }

        // Map recurrence from Graph PatternedRecurrence → RFC 5545 RRULE.
        // CRITICAL: Graph's `pattern.type` is NOT an RFC 5545 FREQ value —
        // `absoluteMonthly`/`relativeMonthly`/`absoluteYearly`/`relativeYearly`
        // must be classified into `FREQ=MONTHLY`/`FREQ=YEARLY` with the
        // distinguishing BY* parts. Blindly uppercasing the Graph type emits
        // `FREQ=ABSOLUTEMONTHLY` — an invalid RRULE that (a) shows garbage to
        // the LLM and (b) round-trips through `parseRRULEToGraphRecurrence` to
        // `default → daily`, silently turning a monthly Exchange series daily
        // on split.
        let recurrence: [String]? = e.recurrence.map(Self.rrule)

        var event = GCalEvent(
            id: e.id,
            summary: e.subject,
            location: e.location?.displayName,
            description: Self.notes(of: e),
            start: toGCalDateTime(e.start, isAllDay: e.isAllDay ?? false),
            end: toGCalDateTime(e.end, isAllDay: e.isAllDay ?? false),
            attendees: attendees,
            organizer: organizer,
            recurrence: recurrence,
            transparency: transparency,
            status: e.isCancelled == true ? "cancelled" : "confirmed",
            htmlLink: e.webLink,
            created: e.createdDateTime,
            updated: e.lastModifiedDateTime,
            // Graph's seriesMasterId → our recurringEventId, so calendar_search
            // enrichment can fetch the master's rule for Exchange instances too.
            recurringEventId: e.seriesMasterId,
            conferenceUrl: e.onlineMeeting?.joinUrl
        )
        event.recurrenceTimeZoneName = e.recurrence?.range?.recurrenceTimeZone.flatMap { $0.isEmpty ? nil : $0 }
        event.recurrenceFirstDayOfWeek = e.recurrence?.pattern?.firstDayOfWeek.flatMap { $0.isEmpty ? nil : $0 }
        event.originalStartTime = Self.originalStartTime(e.originalStart)
        // The read's start is in the zone the read asked for (`request`'s `Prefer`), not the
        // event's own: `seriesZone` falls back only to the zone the event was created in.
        event.ownZoneName = e.originalStartTimeZone ?? ""
        return event
    }

    /// An occurrence's `originalStart` as `GCalEvent.originalStartTime`: the start the series gave
    /// it, which a moved one keeps, as the instant it names. Graph gives it as an ISO 8601 date-time
    /// in UTC (`…T17:00:00Z`), or with an offset when the read asks for a zone, both measured; an
    /// all-day occurrence's is the instant its date begins in the series' zone, so its date is read
    /// only where the read names that zone (`allDayOccurrence`, `allDayPlace`). Nil when there is
    /// none (a series, a one-off event) or it is no ISO 8601 date-time; a listing or read shows the
    /// event all the same.
    nonisolated static func originalStartTime(_ originalStart: String?) -> GCalDateTime? {
        guard let originalStart, let instant = Date.fromISO8601(originalStart) else { return nil }
        return GCalDateTime(dateTime: instant.iso8601String(), date: nil, timeZone: "UTC")
    }

    /// An event's description: the notes in its stored body as text, at full
    /// length, as the page shows them (`EmailFilter.htmlToPlainText`, keeping the
    /// spacing, as for a draft's editable text). An online meeting's notes stop
    /// where its join section starts (`GraphOnlineMeetingBody`); the join link is
    /// `conferenceUrl`. So the description the assistant edits is the notes, and
    /// a description edit writes them back in place of the notes (#511), as HTML
    /// whose read gives the same notes again, up to white space at the ends of
    /// lines and of the notes (`GraphNotesHTML`, #577). Never
    /// `bodyPreview`, which is cut at 255 characters and renders the join section
    /// as text. Nil when the read carries no body.
    nonisolated static func notes(of e: MSEvent) -> String? {
        guard let content = e.body?.content else { return nil }
        guard e.body?.contentType?.lowercased() == "html" else { return content }
        let notes = e.onlineMeeting?.joinUrl.flatMap { GraphOnlineMeetingBody.beforeJoinSection(content, joinUrl: $0) }
            .map(String.init) ?? content
        return EmailFilter.htmlToPlainText(notes, keepingSpacing: true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toGCalDateTime(_ dt: MSDateTimeZone?, isAllDay: Bool) -> GCalDateTime? {
        guard let dt else { return nil }
        if isAllDay {
            // All-day: extract date-only from dateTime (format: "2024-01-15T00:00:00.0000000")
            let dateOnly = String((dt.dateTime ?? "").prefix(10))
            return GCalDateTime(dateTime: nil, date: dateOnly, timeZone: nil)
        }
        // Timed event: convert to RFC 3339
        let rfc3339 = convertToRFC3339(dt.dateTime ?? "", timeZone: dt.timeZone ?? "UTC")
        return GCalDateTime(dateTime: rfc3339, date: nil, timeZone: dt.timeZone)
    }

    private func convertToRFC3339(_ dateTime: String, timeZone: String) -> String {
        // Graph returns "2024-01-15T14:30:00.0000000" with separate timeZone
        // We need to convert to RFC 3339: "2024-01-15T14:30:00+00:00"
        // A read: a zone the resolver does not recognize is read in the device's zone, as before.
        let zone = CalendarTimeZoneResolver.zone(named: timeZone, in: .none) ?? .current
        let fmt = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)

        // Try parsing with fractional seconds
        let cleanDateTime = String(dateTime.prefix(19)) // Strip fractional seconds
        guard let date = fmt.date(from: cleanDateTime) else { return dateTime }

        return date.iso8601String(timeZone: zone)
    }

    /// Drop the trailing offset/`Z` from an ISO 8601 datetime so the resulting
    /// string is the naive wall-time form Graph expects in `start.dateTime` /
    /// `end.dateTime`. Searches AFTER the `T` so the date's `-` separators
    /// aren't mistaken for an offset.
    ///
    /// The tools hand every start and end over with the offset of the zone it is
    /// labelled with (`CalendarToolHelpers.toRFC3339`), so the wall time kept here
    /// is the instant's wall time in that label.
    nonisolated static func graphNaiveDateTime(_ iso: String) -> String {
        guard let tIdx = iso.firstIndex(of: "T") else { return iso }
        let timePart = iso[iso.index(after: tIdx)...]
        guard let offsetIdx = timePart.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return iso }
        return String(iso[..<offsetIdx])
    }

    /// A naive `yyyy-MM-ddTHH:mm:ss` wall time in `zone` as the same instant's wall time in
    /// `other`; as given when the two are the same zone or the wall time does not parse.
    nonisolated static func wallTime(_ wall: String, from zone: TimeZone, to other: TimeZone) -> String {
        guard zone != other else { return wall }
        let fmt = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone)
        guard let instant = fmt.date(from: String(wall.prefix(19))) else { return wall }
        return FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: other).string(from: instant)
    }

    /// A start or end (`{dateTime, timeZone}`, as `toGraphEventJSON` writes it) for an existing
    /// series kept in `seriesZone` (its range's `recurrenceTimeZone`, as Graph returned it),
    /// labelled with that name verbatim. A timed one is the same instant as its wall time in that
    /// zone (#719); an all-day one keeps its date, only the label changes (#747).
    /// Exchange refuses a series PATCH whose start is labelled with another zone (400
    /// `ErrorPropertyValidationFailure`, `IanaTimeZoneConstraint`; measured 2026-11-11 with
    /// `America/Vancouver` and `America/New_York` on a series kept in `Pacific Standard Time`), and
    /// the stored name is the one label measured accepted that needs no mapping table.
    ///
    /// Given as it is when there is no series zone, or when the label, the series zone or the wall
    /// time can't be read: the write keeps the label it had before #719. (A wall time a clock change
    /// skips is read, as the instant an hour on, as the tools read it; a time that can't be read at
    /// all is refused before the card, `CalendarToolHelpers.unreadableWallTime`.) What Exchange does with a
    /// series kept in a zone the app does not recognize (`Customized Time Zone`) is not measured
    /// (#746).
    ///
    /// All day: Graph stores an all-day series whose start and end are labelled with a zone other
    /// than its range's (the app's `UTC`) with every occurrence two days longer, and east of UTC a
    /// day early with its range moved to UTC (measured 2026-11-11 on series kept in
    /// `Pacific Standard Time` and `Tokyo Standard Time`, with and without a recurrence in the
    /// same write, and on a create carrying the range); labelled with the range's own name the
    /// length is kept. The date is a date, so no zone is read: any stored name is written back.
    nonisolated static func inSeriesZone(_ time: [String: Any], seriesZone: String?, allDay: Bool) -> [String: Any] {
        guard let seriesZone, !seriesZone.isEmpty else { return time }
        if allDay {
            var relabelled = time
            relabelled["timeZone"] = seriesZone
            return relabelled
        }
        guard let stored = CalendarTimeZoneResolver.zone(named: seriesZone, in: .none),
              let label = time["timeZone"] as? String, let given = CalendarTimeZoneResolver.zone(named: label, in: .none),
              let wall = time["dateTime"] as? String
        else { return time }
        let format = "yyyy-MM-dd'T'HH:mm:ss"
        guard let instant = FixedDateFormat.formatter(format, timeZone: given).date(from: String(wall.prefix(19)))
        else { return time }
        return ["dateTime": FixedDateFormat.formatter(format, timeZone: stored).string(from: instant), "timeZone": seriesZone]
    }

    /// `attendeeTypes` (lowercased address → Graph type) keeps an existing
    /// attendee's type; an attendee it does not name is `required`.
    /// `rangeZone` is the zone a rule's range is read in when it is not the
    /// start's: an edit's series' stored `recurrenceTimeZone` (`graphPatchJSON`).
    /// `firstDayOfWeek` is an edit's series' stored first day of the week, written
    /// unless the rule names its own (`WKST`).
    nonisolated func toGraphEventJSON(_ input: GCalEventInput, attendeeTypes: [String: String] = [:], rangeZone storedRangeZone: TimeZone? = nil, firstDayOfWeek storedFirstDay: String? = nil) -> [String: Any] {
        var json: [String: Any] = [:]

        if let summary = input.summary { json["subject"] = summary }
        if let location = input.location { json["location"] = ["displayName": location] }
        if let desc = input.description { json["body"] = ["contentType": "html", "content": GraphNotesHTML.html(desc)] }

        // showAs (transparency mapping)
        if let transparency = input.transparency {
            json["showAs"] = transparency == "transparent" ? "free" : "busy"
        }

        // Start. Graph's `dateTime` is a "combined date and time representation
        // in ISO 8601 format" WITHOUT a timezone designator — the separate
        // `timeZone` field supplies that. Sending the RFC 3339 offset-bearing
        // form (e.g. "2026-05-15T20:00:00-0700") alongside `timeZone:"…"`
        // double-specifies the instant; Outlook web then renders the event in
        // the user's account timezone with the wall-time shifted by the
        // double-conversion, which manifests as a calendar entry appearing on
        // the wrong DAY. Strip the offset so the value is unambiguously
        // "20:00:00 in <timeZone>".
        if let startDateTime = input.startDateTime {
            json["start"] = [
                "dateTime": Self.graphNaiveDateTime(startDateTime),
                "timeZone": input.startTimeZone ?? TimeZone.current.identifier,
            ]
            json["isAllDay"] = false
        } else if let startDate = input.startDate {
            json["start"] = [
                "dateTime": "\(startDate)T00:00:00",
                "timeZone": "UTC",
            ]
            json["isAllDay"] = true
        }

        // End
        if let endDateTime = input.endDateTime {
            json["end"] = [
                "dateTime": Self.graphNaiveDateTime(endDateTime),
                "timeZone": input.endTimeZone ?? TimeZone.current.identifier,
            ]
        } else if let endDate = input.endDate {
            json["end"] = [
                "dateTime": "\(endDate)T00:00:00",
                "timeZone": "UTC",
            ]
        }

        // Attendees
        if let attendees = input.attendees {
            json["attendees"] = attendees.map { a -> [String: Any] in
                var obj: [String: Any] = ["emailAddress": ["address": a.email]]
                if let name = a.name {
                    obj["emailAddress"] = ["address": a.email, "name": name]
                }
                obj["type"] = attendeeTypes[a.email.lowercased()] ?? "required"
                return obj
            }
        }

        // Recurrence. Graph REQUIRES `recurrenceRange.startDate` for every
        // range type (per the recurrenceRange spec). `parseRRULEToGraphRecurrence`
        // can't know the start (an RRULE has no DTSTART), so we inject it here
        // from the event's own start — which is exactly what Graph wants
        // ("Must be the same value as the start property of the recurring event").
        if let recurrence = input.recurrence, let rrule = recurrence.first {
            // The event's zone, as a timed `start` is sent above (`input.startTimeZone`, else the
            // device's): Graph reads the range's dates there, unless the range names its own zone
            // (`storedRangeZone`, #423). The start's wall time is the one sent above, read in the
            // range's zone; an all-day series has none, and its rule's UNTIL is a bare date, which
            // `graphEndDate` keeps as written in any zone.
            let startZone = input.startTimeZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .current
            let rangeZone = storedRangeZone ?? startZone
            let startWallTime = input.startDateTime.map {
                Self.wallTime(Self.graphNaiveDateTime($0), from: startZone, to: rangeZone)
            }
            // Derive the event's start so weekly/monthly/yearly rules that omit
            // BYDAY/BYMONTHDAY get the implied field filled from it (Graph
            // rejects a weekly pattern with no daysOfWeek, etc.). A timed start is
            // its wall time in the range's zone, where Graph reads the pattern; an
            // all-day start is its date there.
            let recEventStart: Date? = {
                if let startWallTime {
                    return FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: rangeZone)
                        .date(from: String(startWallTime.prefix(19)))
                }
                if let sd = input.startDate {
                    return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: rangeZone).date(from: sd)
                }
                return nil
            }()
            var graphRec = parseRRULEToGraphRecurrence(rrule, eventStart: recEventStart, timeZone: rangeZone, startWallTime: startWallTime, firstDayOfWeek: storedFirstDay)
            if var range = graphRec["range"] as? [String: Any], range["startDate"] == nil {
                let startDateStr: String? = {
                    if let sd = input.startDate { return sd }                       // already YYYY-MM-DD
                    // Graph reads the range's start date in the stored zone and requires it to
                    // match the start: the start's wall time there (#423).
                    if storedRangeZone != nil, let startWallTime { return String(startWallTime.prefix(10)) }
                    if let sdt = input.startDateTime { return String(sdt.prefix(10)) } // RFC3339 → date part
                    return nil
                }()
                if let startDateStr {
                    range["startDate"] = startDateStr
                    graphRec["range"] = range
                }
            }
            json["recurrence"] = graphRec
        }

        return json
    }

    /// Graph's `recurrenceRange.endDate` for an RFC 5545 `UNTIL`: the series' LAST DAY, a bare
    /// `yyyy-MM-dd` date that Graph reads INCLUSIVELY in the event's zone.
    ///
    /// `UNTIL` comes in three forms (RFC 5545 §3.3.10):
    /// - `YYYYMMDD` is already a date (all-day series, and every rule `toGCalEvent` derives from
    ///   Graph's own range), so its digits are the answer.
    /// - `YYYYMMDDTHHMMSS` is floating wall time in the event's zone. No producer emits it for
    ///   Outlook; it keeps its own date digits, like any other non-UTC shape.
    /// - `YYYYMMDDTHHMMSSZ` is a UTC INSTANT, the form `CalendarToolHelpers.validatedRRuleUntil`
    ///   emits for every timed series (a date-only end becomes 23:59:59 in the event's zone, then
    ///   UTC). Its own date digits are the UTC date. Behind UTC that is the NEXT day, and Graph,
    ///   reading the end inclusively, added one extra day of occurrences for every attendee
    ///   (UTC−8: Dec 31 23:59:59 local is Jan 1 07:59:59Z). Ahead of UTC an early-morning end
    ///   lands on the PREVIOUS UTC day and dropped the last day. So the instant is dated in
    ///   `timeZone`.
    ///
    /// A UTC-instant `UNTIL` whose time of day in `timeZone` is earlier than the series' own start time
    /// ends the series the day before. RFC 5545 bounds the last occurrence's START by the `UNTIL`
    /// instant, inclusively, and on the `UNTIL`'s local day an occurrence starts at the series'
    /// start time: a 10:00 series with
    /// `UNTIL` at 05:00 on the 20th last meets on the 19th, as Google Calendar and CalDAV servers
    /// expand it. So the end date is the last local day whose start time is at or before the
    /// `UNTIL`: that day when the `UNTIL`'s time of day in `timeZone` is at or after the start's,
    /// else the day before. A date-only end reaches here as 23:59:59 in the event's zone, so it is
    /// always the day the user named. `startWallTime` is the series' start as Graph stores it, the
    /// naive `yyyy-MM-ddTHH:mm:ss` wall time `graphNaiveDateTime` writes, read in `timeZone`; nil
    /// (an all-day series) or a start in no such form keeps the `UNTIL`'s own local day.
    ///
    /// nil when fewer than 8 date digits can be recovered (the caller leaves the range `noEnd`).
    /// A value that is not a 16-character `Z` instant, or one that does not parse, keeps its date
    /// digits, as every form did before.
    nonisolated static func graphEndDate(until: String, in timeZone: TimeZone, startWallTime: String?) -> String? {
        let compact = until
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        let digits = compact.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let d = String(digits.prefix(8))
        let ownDate = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"

        // The UNTIL's instant: only a UTC one is read; every other shape keeps its own date.
        guard compact.count == 16, compact.hasSuffix("Z") else { return ownDate }
        let parser = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt)
        guard let instant = parser.date(from: compact) else { return ownDate }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var lastInstant = instant
        let wall = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
        if let startWallTime, let start = wall.date(from: String(startWallTime.prefix(19))) {
            let clock = FixedDateFormat.formatter("HHmmss", timeZone: timeZone)
            if clock.string(from: instant) < clock.string(from: start) {
                lastInstant = calendar.startOfDay(for: instant).addingTimeInterval(-1)
            }
        }
        return FixedDateFormat.formatter("yyyy-MM-dd", timeZone: timeZone).string(from: lastInstant)
    }

    /// Why Graph cannot hold `rrule`, or nil when `parseRRULEToGraphRecurrence` maps it exactly (#513).
    ///
    /// Graph's `recurrencePattern` holds one shape per type: `daily`; `weekly` (`daysOfWeek`);
    /// `absoluteMonthly` (one `dayOfMonth`, 1 to 31); `relativeMonthly` (`daysOfWeek` and one `index`,
    /// first to fourth or last); `absoluteYearly` (one `month` and one `dayOfMonth`); `relativeYearly`
    /// (one `month`, `daysOfWeek` and `index`). With several `daysOfWeek` a relative pattern falls on
    /// the first of them that matches, not on each. A rule outside these shapes would be written as a
    /// different series, so it is refused, naming the field, and the assistant can offer one Outlook
    /// can hold. Every shape an everyday request makes maps exactly: weekly on several days, monthly
    /// on a date or on the nth (or last) weekday, yearly on a date or on the nth weekday of a month.
    /// A rule that leaves the day out (the start's day is implied) is not checked here.
    nonisolated static func graphRecurrenceRefusal(_ rrule: String) -> String? {
        var fields: [String: [String]] = [:]
        for part in rrule.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            fields[kv[0].uppercased()] = kv[1].uppercased().split(separator: ",").map(String.init)
        }
        let freq = fields["FREQ"]?.first ?? ""
        let byDay = fields["BYDAY"] ?? []
        let byMonthDay = fields["BYMONTHDAY"] ?? []
        let byMonth = fields["BYMONTH"] ?? []
        let ordinals = byDay.map { Int($0.dropLast(2)) }
        func refuse(_ field: String, _ values: [String], _ why: String) -> String {
            "Outlook calendars can't repeat \(why), so recurrence.\(field) [\(values.joined(separator: ","))] can't be saved there. Offer the user a repeat Outlook can hold"
        }
        guard ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq) else {
            return "Outlook calendars can't repeat with freq \(freq). Offer the user a repeat Outlook can hold"
        }
        // A position over plain weekdays is Graph's relative pattern: `index` counts over the
        // union of `daysOfWeek` ("the second Thursday or Friday"), which is RFC 5545's
        // BYDAY=TH,FR;BYSETPOS=2. The reader writes a stored relative pattern this way (`rrule(_:)`).
        let bySetPos = fields["BYSETPOS"] ?? []
        if !bySetPos.isEmpty {
            if freq != "MONTHLY", freq != "YEARLY" { return refuse("bySetPos", bySetPos, "on a position over the chosen days except with freq MONTHLY or YEARLY") }
            if bySetPos.count > 1 { return refuse("bySetPos", bySetPos, "on more than one position") }
            if let n = Int(bySetPos[0]), !(1...4).contains(n), n != -1 {
                return refuse("bySetPos", bySetPos, "on a position other than first to fourth or last")
            }
            if Int(bySetPos[0]) == nil { return refuse("bySetPos", bySetPos, "on that position") }
            if byDay.isEmpty || ordinals.contains(where: { $0 != nil }) || !byMonthDay.isEmpty {
                return refuse("bySetPos", bySetPos, "on a position over anything but weekdays without their own positions (give byDay as day codes such as TU,TH)")
            }
        }
        if freq != "YEARLY", !byMonth.isEmpty { return refuse("byMonth", byMonth, "in chosen months except with freq YEARLY") }
        if byMonth.count > 1 { return refuse("byMonth", byMonth, "yearly in more than one month") }
        if freq == "DAILY", !byDay.isEmpty { return refuse("byDay", byDay, "daily on chosen weekdays (use freq WEEKLY with these days)") }
        if freq == "DAILY", !byMonthDay.isEmpty { return refuse("byMonthDay", byMonthDay, "daily on chosen days of the month") }
        if freq == "MONTHLY" || freq == "YEARLY" {
            if !byDay.isEmpty, !byMonthDay.isEmpty { return refuse("byMonthDay", byMonthDay, "on a weekday and a day of the month together") }
            if byMonthDay.count > 1 { return refuse("byMonthDay", byMonthDay, "on more than one day of the month") }
            if let day = byMonthDay.first.flatMap({ Int($0) }), day < 1 {
                return refuse("byMonthDay", byMonthDay, day == -1 ? "on the last day of the month" : "on a day counted from the end of the month")
            }
            if freq == "YEARLY", !byMonthDay.isEmpty, byMonth.isEmpty {
                return refuse("byMonthDay", byMonthDay, "yearly on a day of the month without the month (add byMonth)")
            }
            if !byDay.isEmpty, !bySetPos.isEmpty, freq == "YEARLY", byMonth.isEmpty {
                return refuse("bySetPos", bySetPos, "yearly on a position over weekdays without the month (add byMonth)")
            }
            if !byDay.isEmpty, bySetPos.isEmpty {
                if ordinals.contains(where: { $0 == nil }) {
                    return refuse("byDay", byDay, "on every such weekday of the \(freq == "MONTHLY" ? "month" : "year") (give one position, such as 1MO or -1FR)")
                }
                if byDay.count > 1 { return refuse("byDay", byDay, "on more than one numbered weekday") }
                if let n = ordinals.first ?? nil, !(1...4).contains(n), n != -1 {
                    return refuse("byDay", byDay, "on a weekday numbered other than first to fourth or last")
                }
                if freq == "YEARLY", byMonth.isEmpty {
                    return refuse("byDay", byDay, "yearly on a numbered weekday without the month (add byMonth)")
                }
            }
        }
        return nil
    }

    nonisolated func recurrenceRuleRefusal(_ rrule: String) -> String? { Self.graphRecurrenceRefusal(rrule) }

    /// The writer's half of `graphRecurrenceRefusal`: a rule Graph can't hold is refused before
    /// anything is sent, for an operation that reaches the writer without the tools' check.
    nonisolated static func refuseUnrepresentableRule(_ recurrence: [String]?) throws {
        guard let rrule = recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }),
              let reason = graphRecurrenceRefusal(rrule) else { return }
        throw CalendarProviderError.notSupported(reason)
    }

    /// Convert an RFC 5545 `RRULE` to a Microsoft Graph `patternedRecurrence`.
    ///
    /// Graph's `recurrencePattern.type` is a CLOSED enum — `daily`, `weekly`,
    /// `absoluteMonthly`, `relativeMonthly`, `absoluteYearly`, `relativeYearly`
    /// — and "any property that does not have a supported value results in an
    /// error". So `FREQ=MONTHLY`/`FREQ=YEARLY` can NOT be passed through as
    /// `type: "monthly"`/`"yearly"`; they must be classified into the
    /// absolute/relative variants. Each variant also has REQUIRED companion
    /// fields (`weekly` → `daysOfWeek`, `absoluteMonthly` → `dayOfMonth`, …).
    ///
    /// When the RRULE omits the field Graph needs, RFC 5545 says it's implied
    /// by `DTSTART` (e.g. `FREQ=WEEKLY` with no `BYDAY` recurs on DTSTART's
    /// weekday). `eventStart` is that DTSTART — it lets us fill the implied
    /// field correctly instead of emitting a body Graph rejects with HTTP 400.
    ///
    /// `timeZone` is the zone Graph reads the range in: the event's start zone
    /// (a create sends no `recurrenceTimeZone`, so Graph uses the event's own), or
    /// the series' stored `recurrenceTimeZone` for an edit's rule, which is
    /// labelled with it (`graphPatchJSON`). An
    /// `UNTIL` that names a UTC instant is dated there, and one earlier in its
    /// day than the series' start time (`startWallTime`, the start's wall time
    /// in that zone) ends the series the day before; see `graphEndDate`.
    ///
    /// `firstDayOfWeek` is the series' stored first day of the week, kept unless the rule names
    /// its own (`WKST`); with neither, a weekly pattern starts its weeks on Sunday.
    nonisolated func parseRRULEToGraphRecurrence(_ rrule: String, eventStart: Date?, timeZone: TimeZone, startWallTime: String?, firstDayOfWeek storedFirstDay: String? = nil) -> [String: Any] {
        let parts = rrule.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";")
        var freq = "weekly"
        var interval = 1
        var count: Int?
        var until: String?
        var byDay: [String] = []   // raw tokens, may carry an ordinal prefix ("2FR", "-1MO")
        var byMonthDay: Int?
        var byMonth: Int?
        var bySetPos: Int?
        var wkst: String?

        let abbrevToDay = ["SU": "sunday", "MO": "monday", "TU": "tuesday", "WE": "wednesday", "TH": "thursday", "FR": "friday", "SA": "saturday"]

        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch String(kv[0]).uppercased() {
            case "FREQ": freq = String(kv[1]).lowercased()
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            case "COUNT": count = Int(kv[1])
            case "UNTIL": until = String(kv[1])
            case "BYDAY": byDay = String(kv[1]).split(separator: ",").map { String($0).uppercased() }
            case "BYMONTHDAY": byMonthDay = Int(kv[1])
            case "BYMONTH": byMonth = Int(kv[1])
            case "BYSETPOS": bySetPos = Int(kv[1])
            case "WKST": wkst = abbrevToDay[String(kv[1]).uppercased()]
            default: break
            }
        }

        var range: [String: Any] = ["type": "noEnd"]
        if let count {
            range = ["type": "numbered", "numberOfOccurrences": count]
        } else if let until, let endDate = Self.graphEndDate(until: until, in: timeZone, startWallTime: startWallTime) {
            // NOTE: callers that need a precise split should NOT route through
            // here (Graph's date-inclusive endDate loses the instant). See
            // `splitSeries` / `graphEndDateBefore`. This path exists for plain
            // create/update of an already-date-bounded series.
            // If `graphEndDate` can't recover 8 date digits, the range stays
            // noEnd rather than a malformed endDate that Graph would reject.
            range = ["type": "endDate", "endDate": endDate]
        }

        // Calendar fields implied by DTSTART when the RRULE doesn't spell them out, on its
        // date in the zone Graph reads the range in (#655).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let startComps = eventStart.map { cal.dateComponents([.weekday, .day, .month], from: $0) }
        let startWeekday = startComps?.weekday.map { weekdayNames[($0 - 1) % 7] }
        let startDayOfMonth = startComps?.day
        let startMonth = startComps?.month

        // BYDAY tokens → plain day names; the ordinal prefix ("2FR") feeds `index`.
        let plainDays = byDay.compactMap { abbrevToDay[String($0.suffix(2))] }
        let byDayOrdinal: Int? = {
            guard let first = byDay.first else { return nil }
            let prefix = first.dropLast(2)
            return prefix.isEmpty ? nil : Int(prefix)
        }()
        func weekIndex(_ n: Int) -> String {
            switch n {
            case 1: return "first"
            case 2: return "second"
            case 3: return "third"
            case 4: return "fourth"
            default: return "last"   // 5+ or negative ("-1FR" = last Friday)
            }
        }

        var pattern: [String: Any] = ["interval": interval]
        switch freq {
        case "daily":
            pattern["type"] = "daily"

        case "weekly":
            pattern["type"] = "weekly"
            // Graph REQUIRES daysOfWeek + firstDayOfWeek for weekly. RFC 5545:
            // FREQ=WEEKLY with no BYDAY recurs on DTSTART's weekday.
            pattern["daysOfWeek"] = !plainDays.isEmpty ? plainDays
                : (startWeekday.map { [$0] } ?? ["monday"])
            pattern["firstDayOfWeek"] = wkst ?? storedFirstDay ?? "sunday"

        case "monthly":
            if !plainDays.isEmpty {
                // BYDAY present → "the 2nd Friday" style → relativeMonthly.
                pattern["type"] = "relativeMonthly"
                pattern["daysOfWeek"] = plainDays
                pattern["index"] = weekIndex(byDayOrdinal ?? bySetPos ?? 1)
            } else {
                // absoluteMonthly REQUIRES dayOfMonth — from BYMONTHDAY or DTSTART.
                pattern["type"] = "absoluteMonthly"
                pattern["dayOfMonth"] = byMonthDay ?? startDayOfMonth ?? 1
            }

        case "yearly":
            if !plainDays.isEmpty {
                pattern["type"] = "relativeYearly"
                pattern["daysOfWeek"] = plainDays
                pattern["month"] = byMonth ?? startMonth ?? 1
                pattern["index"] = weekIndex(byDayOrdinal ?? bySetPos ?? 1)
            } else {
                // absoluteYearly REQUIRES dayOfMonth + month.
                pattern["type"] = "absoluteYearly"
                pattern["dayOfMonth"] = byMonthDay ?? startDayOfMonth ?? 1
                pattern["month"] = byMonth ?? startMonth ?? 1
            }

        default:
            // Unknown FREQ (SECONDLY/MINUTELY/HOURLY — not expressible in Graph).
            // Emit a well-formed daily body rather than an invalid `type`.
            pattern["type"] = "daily"
        }
        // An edit's other pattern kinds keep the series' first day of the week too, unless the
        // rule names its own (#423).
        if pattern["firstDayOfWeek"] == nil, let storedFirstDay {
            pattern["firstDayOfWeek"] = wkst ?? storedFirstDay
        }

        return [
            "pattern": pattern,
            "range": range,
        ]
    }

    private func mapResponseStatus(_ status: String?) -> String? {
        switch status {
        case "accepted": return "accepted"
        case "declined": return "declined"
        case "tentativelyAccepted": return "tentative"
        case "notResponded", "none": return "needsAction"
        default: return status
        }
    }

    private func msColorToHex(_ color: String?) -> String? {
        // Graph uses named colors; return a reasonable hex
        switch color {
        case "auto", nil: return nil
        case "lightBlue": return "#4285F4"
        case "lightGreen": return "#0B8043"
        case "lightOrange": return "#F4511E"
        case "lightGray": return "#616161"
        case "lightYellow": return "#E4C441"
        case "lightTeal": return "#039BE5"
        case "lightPink": return "#D81B60"
        case "lightBrown": return "#795548"
        case "lightRed": return "#D50000"
        default: return nil
        }
    }

}

// MARK: - Errors

enum ExchangeCalendarError: Error {
    case missingScope
    case httpError(Int, Data?)
    case eventNotFound
    /// A Graph resource id could not be encoded as one strict path segment.
    /// The associated value names which id, matching `ProviderError.invalidURL`'s
    /// contract on the mail side.
    case invalidPathSegment(String)
}

// MARK: - Microsoft Graph Calendar Response Models

private struct MSCalendarListResponse: Decodable {
    let value: [MSCalendar]
}

private struct MSCalendar: Decodable {
    let id: String
    let name: String?
    let isDefaultCalendar: Bool?
    let color: String?
}

// Decodable shapes for Microsoft Graph calendar payloads. Internal (not private)
// so unit tests in `TabMailTests/Providers/ExchangeCalendarTests.swift` can decode
// JSON fixtures into `MSEvent` to exercise `toGCalEvent`.
struct MSEventListResponse: Decodable {
    let value: [MSEvent]
}

struct MSEvent: Decodable {
    let id: String?
    let subject: String?
    let location: MSLocation?
    let bodyPreview: String?
    let body: MSItemBody?
    let onlineMeeting: MSOnlineMeeting?
    let start: MSDateTimeZone?
    let end: MSDateTimeZone?
    let attendees: [MSAttendee]?
    let organizer: MSOrganizer?
    let recurrence: MSPatternedRecurrence?
    let showAs: String?
    let isCancelled: Bool?
    let isAllDay: Bool?
    let webLink: String?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    /// Set on `occurrence`/`exception` rows (calendarView expansion) — points
    /// to the series master. Graph's analogue of Google's `recurringEventId`.
    /// We map it onto `GCalEvent.recurringEventId` so the calendar_search
    /// enrichment (`resolveMasterRecurrence`) can fetch the master's rule.
    let seriesMasterId: String?
    /// Set on `occurrence`/`exception` rows: the start the series gives the occurrence, which a
    /// moved one keeps (`ExchangeCalendarProvider.originalStartTime`).
    let originalStart: String?
    /// The zone the event was created in, as Graph keeps it (a Windows or IANA name, or a custom
    /// zone's), whatever zone the read asked for.
    let originalStartTimeZone: String?
}

struct MSLocation: Decodable {
    let displayName: String?
}

/// Graph's `itemBody`.
struct MSItemBody: Decodable {
    let contentType: String?
    let content: String?
}

/// Graph's `onlineMeetingInfo`, the part the app reads.
struct MSOnlineMeeting: Decodable {
    let joinUrl: String?
}

struct MSDateTimeZone: Decodable {
    let dateTime: String?
    let timeZone: String?
}

struct MSAttendee: Decodable {
    let emailAddress: MSEmailAddress?
    let status: MSResponseStatus?
    let type: String?
}

struct MSEmailAddress: Decodable {
    let name: String?
    let address: String?
}

struct MSResponseStatus: Decodable {
    let response: String?
}

struct MSOrganizer: Decodable {
    let emailAddress: MSEmailAddress?
}

struct MSPatternedRecurrence: Decodable {
    let pattern: MSRecurrencePattern?
    let range: MSRecurrenceRange?
}

struct MSRecurrencePattern: Decodable {
    let type: String?
    let interval: Int?
    let daysOfWeek: [String]?
    let dayOfMonth: Int?
    let index: String?   // first | second | third | fourth | last
    let month: Int?
    let firstDayOfWeek: String?
}

struct MSRecurrenceRange: Decodable {
    let type: String?
    let endDate: String?
    let numberOfOccurrences: Int?
    let recurrenceTimeZone: String?
}
