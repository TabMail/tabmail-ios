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
    private static let eventSelect = "id,subject,location,body,bodyPreview,onlineMeeting,start,end,attendees,organizer,recurrence,showAs,isCancelled,webLink,createdDateTime,lastModifiedDateTime,isAllDay,seriesMasterId,originalStart"

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

    /// Series split (this_and_following). For Graph:
    /// 1. PATCH the master's recurrence.range to {type: "endDate", endDate: splitDate - 1 day}
    ///    — Graph's `endDate` is inclusive and date-only, so we set the day before splitDate. The
    ///    stored pattern is written back exactly.
    /// 2. POST the new part: a copy of the stored series (`splitNewPartJSON`) starting at
    ///    recurrenceId, with `patch` applied.
    /// On step-2 failure, attempt a best-effort revert of step 1 to the stored recurrence.
    func splitSeries(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone,
        patch: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
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
              let storedRecurrence = snapshot.raw["recurrence"] as? [String: Any],
              let storedRange = storedRecurrence["range"] as? [String: Any]
        else {
            throw CalendarProviderError.notSupported("Event \(eventId) is not recurring; can't split.")
        }

        // 1. Cap the master via PATCH.
        //    IMPORTANT: Graph's recurrenceRange uses a DATE-inclusive `endDate`
        //    ("occurrences ... between startDate and endDate inclusive"). We
        //    therefore can NOT round-trip through an RRULE `UNTIL` instant —
        //    its precision is lost when collapsed to a whole date, and the
        //    naive date-part of (split − 1s) is still the split day, which
        //    Graph would keep on the master. So compute the cap directly:
        //    endDate = local date of (split occurrence − 1 day). The stored
        //    pattern and the rest of the stored range (its `startDate`, which
        //    Graph requires, and its zone) are written back as they are.
        guard let capEndDate = Self.graphEndDateBefore(naiveISO: recurrenceId, allDay: master.isAllDay, zone: recurrenceIdZone) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        // The split is at an occurrence that starts at `recurrenceId` now, the one `occurrence`
        // finds, and was not moved from its place in the series; otherwise it throws with nothing
        // written. Not asked on a retry after this split's own cap, which ended the series before
        // that occurrence.
        if !isOwnSplitCap(of: master, at: recurrenceId, zone: recurrenceIdZone) {
            let found = try await occurrence(
                named: named, masterId: eventId, series: master, recurrenceId: recurrenceId, zone: recurrenceIdZone)
            if RecurrenceOccurrenceResolver.wasMoved(found) {
                // A split at an occurrence moved from its place is not supported (#563): a plain
                // error, nothing written.
                throw CalendarProviderError.notSupported("split at a moved occurrence")
            }
        }
        var capRange = storedRange
        capRange["type"] = "endDate"
        capRange["endDate"] = capEndDate
        capRange.removeValue(forKey: "numberOfOccurrences")
        var cappedRecurrence = storedRecurrence
        cappedRecurrence["range"] = capRange
        // Built before the cap is written, so a series that can't be copied is
        // refused while nothing has changed.
        let transactionId = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: eventId, recurrenceId: recurrenceId
        )
        let createJSON = try splitNewPartJSON(
            stored: snapshot,
            patch: patch,
            newStartNaiveISO: recurrenceId,
            newStartZone: recurrenceIdZone,
            capEndDate: capEndDate,
            transactionId: transactionId
        )
        // CRITICAL: include the master's existing start/end on the cap PATCH.
        // If we send ONLY `recurrence`, Graph silently rewrites the master's
        // `start.dateTime`/`start.timeZone` to UTC midnight at the
        // recurrence range's `startDate` — shifting the master's first
        // occurrence by the device's UTC offset (17:00 Vancouver → 00:00 UTC,
        // i.e. the previous day in PDT). Re-sending the existing wall time
        // pins the master in place. `graphNaiveDateTime` strips the offset so
        // the `dateTime` is naive in `timeZone`, per Graph's spec.
        var cappedJSON: [String: Any] = ["recurrence": cappedRecurrence]
        if let startISO = master.start?.dateTime, let startTz = master.start?.timeZone {
            cappedJSON["start"] = [
                "dateTime": Self.graphNaiveDateTime(startISO),
                "timeZone": startTz,
            ]
        }
        if let endISO = master.end?.dateTime, let endTz = master.end?.timeZone {
            cappedJSON["end"] = [
                "dateTime": Self.graphNaiveDateTime(endISO),
                "timeZone": endTz,
            ]
        }
        let cappedBody = try JSONSerialization.data(withJSONObject: cappedJSON)
        if DebugModeManager.isLoggingEnabled() {
            if let bodyStr = String(data: cappedBody, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries cap PATCH body=\(bodyStr.prefix(4000))")
            }
        }
        let encodedMasterId = try Self.encodedGraphPathSegment(eventId, context: "Graph series master id")
        let capRespData = try await request(path: "/events/\(encodedMasterId)", method: "PATCH", body: cappedBody)
        // Log the response so we can see what Graph stored — particularly the
        // master's start/end/recurrence after capping, to diagnose visible
        // "occurrence moved to earlier day" symptoms after a split.
        if DebugModeManager.isLoggingEnabled() {
            if let capRespStr = String(data: capRespData, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries cap PATCH response=\(capRespStr.prefix(4000))")
            }
        }

        // 2. Create the new part (`createJSON`, built above). Its DETERMINISTIC
        // `transactionId` (derived from master id + recurrence_id) lets Graph
        // dedupe POSTs — so a retry after a lost ACK on the create below won't
        // produce a duplicate series. The two-step cap-then-create is
        // otherwise not idempotent (the PATCH is, the POST isn't).
        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = try Self.encodedGraphPathSegment(calendarId, context: "Graph calendar id")
            calPath = "/calendars/\(encodedCalId)"
        }
        do {
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
            let created = try JSONDecoder().decode(MSEvent.self, from: data)
            return toGCalEvent(created)
        } catch {
            // ⚠️ THERE IS DELIBERATELY NO `catch ExchangeCalendarError.httpError(409, _)`
            // AHEAD OF THIS (R13-U3). Until 2026-08-06 a 409 here returned a
            // FABRICATED `GCalEvent(id: "")` — a synthetic success with no id, no
            // start and no end, built entirely from the request we had just failed
            // to send. The queue then reported the split done and deleted the
            // durable op, leaving a truncated master with no successor series.
            //
            // Its premise — "Graph rejected the POST as a duplicate transactionId"
            // — is not what Microsoft documents. The `event` resource defines
            // `transactionId` as a value *"for the server to AVOID REDUNDANT POST
            // operations in case of client retries"*: a deduped retry receives the
            // ORIGINAL success response, so a 409 is evidence AGAINST the dedup
            // reading, not for it. Graph's observed calendar-POST 409s are
            // store-level save conflicts (`ConcurrentItemSave`,
            // `IrresolvableConflict`) which say nothing about whether the item
            // exists. A 409 therefore takes this arm now: the master cap is
            // reverted and the error is rethrown for the drain to classify as
            // indeterminate-and-retryable, and the retry re-runs the whole split
            // against an uncapped master.
            //
            // 🚨 R13-U4 — A FAILED ROLLBACK IS NOT THE SAME OUTCOME AS A SUCCESSFUL
            // ONE, and this used to report them identically via `try?`. If the
            // create failed with a 400/415/422, `isCalendarBadRequestError` claims
            // the rethrown error and the drain DELETES the durable row — so when
            // the revert had also failed, the master was left permanently capped,
            // with no successor and no queued work to make one. Later sync imports
            // the truncated master and cannot reconstruct the original recurrence.
            //
            // On a revert failure this now raises `CalDAVError.inconsistentState`,
            // which the drain claims at its own dedicated arm with exactly this
            // rationale already written there (*"retrying would re-cap an
            // already-capped master and create duplicate successor series"*). That
            // arm is terminal-with-a-reason and surfaces the message to the user —
            // NOT transient: this is deliberately not "make every rollback failure
            // retryable", which would put a two-step write that has already half
            // landed into an unbounded retry.
            // The stored recurrence exactly as it was. SAME Graph quirk as the
            // cap PATCH above — sending ONLY `recurrence` causes Graph to
            // silently rewrite the master's start/end to UTC midnight at
            // `range.startDate` — so the master's existing start/end, which the
            // cap carried, go with it and its first occurrence stays put.
            var revertJSON = cappedJSON
            revertJSON["recurrence"] = storedRecurrence
            var revertFailure: Error?
            if let revertBody = try? JSONSerialization.data(withJSONObject: revertJSON) {
                if DebugModeManager.isLoggingEnabled() {
                    if let bodyStr = String(data: revertBody, encoding: .utf8) {
                        BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries revert PATCH body=\(bodyStr.prefix(4000))")
                    }
                }
                do {
                    _ = try await request(path: "/events/\(encodedMasterId)", method: "PATCH", body: revertBody)
                } catch let revertError {
                    revertFailure = revertError
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries revert PATCH FAILED: \(revertError)")
                }
            } else {
                // The revert request could not even be built, so the master is
                // still capped — the same end state as a failed PATCH, and it must
                // not be reported as a successful rollback.
                revertFailure = CalendarProviderError.notSupported("the revert payload could not be encoded")
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] splitSeries revert PATCH body could not be encoded — master left capped")
            }
            throw GoogleCalendarProvider.splitRollbackError(original: error, revertFailure: revertFailure)
        }
    }

    /// The cap `splitSeries` writes, as the series' RRULE reads it: Graph's range `endDate`
    /// (`graphEndDateBefore`), which the mapping to `GCalEvent.recurrence` gives as an `UNTIL` of
    /// that date without its dashes when the range type is `endDate`.
    nonisolated func splitCapUntil(beforeNaiveISO recurrenceId: String, allDay: Bool, zone: TimeZone) -> String? {
        Self.graphEndDateBefore(naiveISO: recurrenceId, allDay: allDay, zone: zone)?
            .replacingOccurrences(of: "-", with: "")
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
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dtFmt.timeZone = zone
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = zone
        let parsed = dtFmt.date(from: naiveISO)
            ?? dateFmt.date(from: String(naiveISO.prefix(10)))
        guard let date = parsed else { return nil }
        // Calendar arithmetic, not a flat 86400s — a DST-transition day is 23h
        // or 25h of local time, so `addingTimeInterval(-86400)` can land on the
        // wrong calendar day and cap the series a day early/late.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let dayBefore = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd"
        out.timeZone = zone
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
    /// - Attendees keep their address, name and type; one the patch adds is `required`. Their
    ///   answers are not copied: Graph lets only the attendee write a response, so the new part's
    ///   attendees start unanswered, as they do when Outlook splits a series itself.
    /// - The recurrence keeps the stored pattern exactly. Its range keeps its end date and zone and
    ///   starts on the new start's date; a range that ended after a number of occurrences has no
    ///   end, because the number left after the split is not known here. A range that already
    ///   ends on this split's cap (`capEndDate`) has no end either: it is a retry after the cap was
    ///   written and the create was not, and that end is the cap, not the series' own (the rule
    ///   `RecurrenceTail.newSeriesRule` applies on Google and CalDAV). A rule in the patch
    ///   replaces the stored recurrence.
    /// - A new place in the patch replaces the stored places (`locations`).
    /// - New notes on an online series replace only the notes in the copied body; its join section
    ///   is kept as stored (`onlineMeetingBody`). The new part is not an online meeting of its own:
    ///   its body carries the series' join link.
    ///
    /// Throws `notSupported` when the new start can't be dated; nothing has been written then.
    nonisolated func splitNewPartJSON(
        stored: EditSnapshot,
        patch: GCalEventInput,
        newStartNaiveISO: String,
        newStartZone: TimeZone,
        capEndDate: String,
        transactionId: String
    ) throws -> [String: Any] {
        // The recurrence comes from the stored series' range below, or from the patch's rule.
        let edited = GoogleCalendarProvider.mergeMasterAndPatch(
            master: stored.event, patch: patch, newStartNaiveISO: newStartNaiveISO,
            newStartZone: newStartZone, newRecurrence: [])
        guard let newDay = Self.day(edited.startDate, edited.startDateTime, in: edited.startTimeZone) else {
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
        written.attendees = patch.attendees ?? (stored.event.attendees ?? []).compactMap { attendee in
            guard let email = attendee.email, !email.isEmpty else { return nil }
            return (email: email, name: attendee.displayName)
        }

        var json = stored.raw.filter { Self.splitCopiedKeys.contains($0.key) }
        if patch.location != nil { json.removeValue(forKey: "locations") }
        for (key, value) in toGraphEventJSON(written, attendeeTypes: stored.attendeeTypes) { json[key] = value }
        // New notes on an online series keep its join section, as an edit of the series does.
        if let description = patch.description, let body = Self.onlineMeetingBody(stored.raw, notes: description) {
            json["body"] = body
        }
        if patch.recurrence?.isEmpty ?? true,
           var recurrence = stored.raw["recurrence"] as? [String: Any],
           var range = recurrence["range"] as? [String: Any] {
            range["startDate"] = newDay
            if range["type"] as? String == "numbered" { range["type"] = "noEnd" }
            if range["type"] as? String == "endDate", range["endDate"] as? String == capEndDate {
                range["type"] = "noEnd"
            }
            if range["type"] as? String != "endDate" { range.removeValue(forKey: "endDate") }
            range.removeValue(forKey: "numberOfOccurrences")
            recurrence["range"] = range
            json["recurrence"] = recurrence
        }
        json["transactionId"] = transactionId
        return json
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
    /// - attendees the edit keeps are written as stored, a new one `required` and unanswered
    ///   (`editAttendeesJSON`, #622);
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
        sparse.attendees = patch.attendees
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
        // A rule that changes the series keeps the series' zone (#423): the rebuilt rule names
        // no zone, and Graph stores a range written without a zone as UTC. With none stored, the
        // zone is the one the start is written in.
        if var rule = json["recurrence"] as? [String: Any],
           var range = rule["range"] as? [String: Any] {
            range["recurrenceTimeZone"] = storedZoneName ?? (json["start"] as? [String: Any])?["timeZone"] as? String
            rule["range"] = range
            json["recurrence"] = rule
        }
        if let wanted = sparse.attendees {
            json["attendees"] = Self.editAttendeesJSON(stored: existing.raw["attendees"] as? [[String: Any]] ?? [], wanted: wanted)
        }
        if allowRecurrence, sparse.recurrence == nil, movesTime,
           var stored = existing.raw["recurrence"] as? [String: Any],
           var range = stored["range"] as? [String: Any],
           let newDay = Self.day(merged.startDate, merged.startDateTime, in: merged.startTimeZone),
           newDay != Self.day(current.start?.date, current.start?.dateTime, in: current.start?.timeZone) {
            range["startDate"] = newDay
            stored["range"] = range
            json["recurrence"] = stored
        }
        if let description = patch.description, let body = Self.onlineMeetingBody(existing.raw, notes: description) {
            json["body"] = body
        }
        return json
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
        let wall = DateFormatter()
        wall.locale = Locale(identifier: "en_US_POSIX")
        wall.calendar = Calendar(identifier: .gregorian)
        wall.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        for (key, value) in json {
            guard let part = value as? [String: Any], let label = part["timeZone"] as? String else { continue }
            guard let zone = CalendarTimeZoneResolver.zone(named: label, in: .none),
                  let dateTime = part["dateTime"] as? String
            else { return nil }
            wall.timeZone = zone
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

    /// The attendee list an edit writes when it changes who attends (#622): each attendee it
    /// keeps exactly as the edit's read holds them (type, answer and name, matched by address in
    /// any letter case), in the order the edit asks for; each one it adds as `required` and
    /// unanswered. Measured on an Outlook.com account: Graph refuses with 405 an attendee list
    /// in which any entry has no `status`, and an attendee sent with their stored status keeps
    /// their answer.
    nonisolated static func editAttendeesJSON(stored: [[String: Any]], wanted: [(email: String, name: String?)]) -> [[String: Any]] {
        wanted.map { want in
            if let kept = stored.first(where: {
                (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased() == want.email.lowercased()
            }) {
                return kept
            }
            var address: [String: Any] = ["address": want.email]
            if let name = want.name { address["name"] = name }
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
    nonisolated static func day(_ date: String?, _ dateTime: String?, in timeZone: String?) -> String? {
        if let date { return String(date.prefix(10)) }
        guard let dateTime else { return nil }
        let wall = DateFormatter()
        wall.locale = Locale(identifier: "en_US_POSIX")
        wall.calendar = Calendar(identifier: .gregorian)
        wall.timeZone = timeZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .current
        wall.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let instant = wall.date(from: String(graphNaiveDateTime(dateTime).prefix(19))) else {
            return String(dateTime.prefix(10))
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
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
        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        utcFmt.timeZone = TimeZone(identifier: "UTC")
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
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fmt.timeZone = startZone
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = zone

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
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = zone
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let instant = fmt.date(from: String(wall.prefix(19))) else { return wall }
        fmt.timeZone = other
        return fmt.string(from: instant)
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
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.calendar = Calendar(identifier: .gregorian)
                f.timeZone = rangeZone
                if let startWallTime {
                    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    return f.date(from: String(startWallTime.prefix(19)))
                }
                if let sd = input.startDate {
                    f.dateFormat = "yyyy-MM-dd"
                    return f.date(from: sd)
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
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        if compact.count == 16, compact.hasSuffix("Z") {
            parser.timeZone = TimeZone(identifier: "UTC")
            parser.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            return ownDate
        }
        guard let instant = parser.date(from: compact) else { return ownDate }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = timeZone
        var lastInstant = instant
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let startWallTime, let start = local.date(from: String(startWallTime.prefix(19))) {
            local.dateFormat = "HHmmss"
            if local.string(from: instant) < local.string(from: start) {
                lastInstant = calendar.startOfDay(for: instant).addingTimeInterval(-1)
            }
        }
        local.dateFormat = "yyyy-MM-dd"
        return local.string(from: lastInstant)
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
