/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// CalDAV calendar provider conforming to CalendarProvider protocol.
/// Uses CalDAVClient for HTTP operations and ICSParser for response parsing.
actor CalDAVProvider: CalendarProvider {
    /// A CalDAV edit replaces only the master's RRULE line, with the edit's own, and keeps the
    /// rest of the series as stored; so the rule changes when the edit's RRULE differs from the
    /// stored one (`GoogleCalendarProvider.canonicalRRULE`), and an edit with none changes nothing.
    nonisolated func editResetsChangedOccurrences(_ event: GCalEvent, edit: GCalEventInput) -> Bool {
        func rule(_ lines: [String]?) -> String? {
            lines?.first { $0.uppercased().hasPrefix("RRULE:") }.map(GoogleCalendarProvider.canonicalRRULE)
        }
        guard let edited = rule(edit.recurrence) else { return false }
        return edited != rule(event.recurrence)
    }

    private let client: CalDAVClient
    private let calendarHomeURL: URL
    private let serverBaseURL: URL

    /// Cached ETag per resource URL for update conflict detection.
    private var etagCache: [String: String] = [:]

    init(client: CalDAVClient, calendarHomeURL: URL, serverBaseURL: URL) {
        self.client = client
        self.calendarHomeURL = calendarHomeURL
        self.serverBaseURL = serverBaseURL
    }

    // MARK: - CalendarProvider

    func listCalendars() async throws -> [GCalCalendar] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"
                    xmlns:cs="http://calendarserver.org/ns/"
                    xmlns:a="http://apple.com/ns/ical/">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <cs:getctag/>
            <d:current-user-privilege-set/>
            <a:calendar-color/>
            <c:supported-calendar-component-set/>
            <a:calendar-order/>
          </d:prop>
        </d:propfind>
        """

        let (data, _) = try await client.propfind(url: calendarHomeURL, body: body, depth: 1)
        let responses = try MultistatusParser.parse(data: data)

        struct CalEntry {
            let cal: GCalCalendar
            let order: Int
        }

        var entries: [CalEntry] = []

        for resp in responses {
            // Skip the calendar-home-set itself (only include calendar collections)
            guard resp.resourceType.contains("calendar") else { continue }
            // Skip non-calendar collections (e.g., outbox, notifications)
            if resp.resourceType.contains("schedule-outbox") || resp.resourceType.contains("schedule-inbox") { continue }

            // Skip VTODO-only collections (e.g., iCloud Reminders)
            let components = resp.supportedComponents
            if !components.isEmpty && !components.contains("VEVENT") {
                BackgroundSyncLogger.logDebug("[CalDAV] Skipping non-VEVENT collection: \(resp.properties["displayname"] ?? resp.href) (components: \(components))")
                continue
            }

            let isWritable = resp.properties["writable"] == "true"
            let isShared = resp.resourceType.contains("shared")
            let accessRole = isWritable && !isShared ? "owner" : "reader"
            let color = resp.properties["calendar-color"]
            let order = resp.properties["calendar-order"].flatMap { Int($0) } ?? Int.max

            entries.append(CalEntry(
                cal: GCalCalendar(
                    id: resp.href,
                    summary: resp.properties["displayname"],
                    primary: false,
                    accessRole: accessRole,
                    backgroundColor: color,
                    selected: nil
                ),
                order: order
            ))
        }

        // Sort: writable first (by calendar-order), then read-only (by calendar-order)
        entries.sort { a, b in
            let aWritable = a.cal.accessRole == "owner"
            let bWritable = b.cal.accessRole == "owner"
            if aWritable != bWritable { return aWritable }
            return a.order < b.order
        }

        // Mark the first writable calendar as primary (lowest calendar-order)
        var calendars = entries.map(\.cal)
        if let primaryIdx = calendars.firstIndex(where: { $0.accessRole == "owner" }) {
            calendars[primaryIdx] = GCalCalendar(
                id: calendars[primaryIdx].id,
                summary: calendars[primaryIdx].summary,
                primary: true,
                accessRole: calendars[primaryIdx].accessRole,
                backgroundColor: calendars[primaryIdx].backgroundColor,
                selected: calendars[primaryIdx].selected
            )
        }

        BackgroundSyncLogger.logDebug("[CalDAV] Listed \(calendars.count) calendars (\(calendars.filter { $0.accessRole == "owner" }.count) writable)")
        return calendars
    }

    func primaryCalendarId() async throws -> String {
        let calendars = try await listCalendars()
        if let primary = calendars.first(where: { $0.primary == true }) {
            return primary.id
        }
        // Fall back to first writable calendar
        if let writable = calendars.first(where: { $0.accessRole == "owner" }) {
            return writable.id
        }
        throw CalDAVError.noWritableCalendar
    }

    func listEvents(
        calendarId: String,
        timeMin: Date?,
        timeMax: Date?,
        query: String?,
        singleEvents: Bool,
        maxResults: Int,
        orderBy: String
    ) async throws -> [GCalEvent] {
        let calURL = try resolveURL(calendarId)

        // Build inner VEVENT filter parts — RFC 4791 allows combining time-range + prop-filter (ANDed)
        var innerParts = ""
        if let timeMin, let timeMax {
            innerParts += "<c:time-range start=\"\(formatUTCCalDAV(timeMin))\" end=\"\(formatUTCCalDAV(timeMax))\"/>\n"
        } else if let timeMin {
            innerParts += "<c:time-range start=\"\(formatUTCCalDAV(timeMin))\"/>\n"
        } else if let timeMax {
            innerParts += "<c:time-range end=\"\(formatUTCCalDAV(timeMax))\"/>\n"
        }
        if let query, !query.isEmpty {
            innerParts += """
            <c:prop-filter name="SUMMARY">
              <c:text-match collation="i;unicode-casemap" negate-condition="no">\(escapeXML(query))</c:text-match>
            </c:prop-filter>
            """
        }

        let filterXML: String
        if innerParts.isEmpty {
            filterXML = """
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
            """
        } else {
            filterXML = """
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                \(innerParts)
              </c:comp-filter>
            </c:comp-filter>
            """
        }

        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data/>
          </d:prop>
          <c:filter>
            \(filterXML)
          </c:filter>
        </c:calendar-query>
        """

        let (data, _) = try await client.report(url: calURL, body: body)
        let responses = try MultistatusParser.parse(data: data)

        var events: [GCalEvent] = []
        for resp in responses {
            guard let icsText = resp.calendarData, !icsText.isEmpty else { continue }
            // One row per occurrence in the range, as Google and Outlook list a
            // repeating event (ADR-IOS-108).
            let parsed = CalDAVOccurrences.listing(
                icsText: icsText, href: resp.href, timeMin: timeMin, timeMax: timeMax)
            // Cache ETags for later updates
            if let etag = resp.etag {
                etagCache[resp.href] = etag
            }
            events.append(contentsOf: parsed)
        }

        // Filter out cancelled events
        events = events.filter { $0.status != "cancelled" }

        // Post-fetch sort
        events.sort { a, b in
            let aDate = a.startDate ?? .distantPast
            let bDate = b.startDate ?? .distantPast
            return aDate < bDate
        }

        // Post-fetch trim
        if events.count > maxResults {
            events = Array(events.prefix(maxResults))
        }

        BackgroundSyncLogger.logDebug("[CalDAV] listEvents: \(events.count) events from \(calendarId)")
        return events
    }

    /// A series id reads the series (its first date, with its rule); an occurrence id a
    /// listing gave (`CalDAVOccurrences.OccurrenceId`) reads that one occurrence, as a
    /// listing shows it, and throws `notFound` when the series no longer has it.
    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
        let (seriesHref, occurrenceKey) = try CalDAVOccurrences.OccurrenceId.split(eventId)
        let eventURL = try resolveEventURL(seriesHref, calendarId: calendarId)

        let (data, response) = try await client.get(url: eventURL)
        guard let icsText = String(data: data, encoding: .utf8), !icsText.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }

        let etag = response.value(forHTTPHeaderField: "ETag")
        if let etag {
            etagCache[seriesHref] = etag
        }

        if let occurrenceKey {
            guard let occurrence = CalDAVOccurrences.occurrence(key: occurrenceKey, icsText: icsText, href: seriesHref) else {
                throw CalDAVError.notFound
            }
            return occurrence
        }
        let events = ICSParser.parse(icsText: icsText, resourceHref: seriesHref, etag: etag)
        guard let event = events.first else {
            throw CalDAVError.parseError("No VEVENT found in \(eventId)")
        }
        return event
    }

    func createEvent(
        calendarId: String,
        event: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        // Use pre-generated event.id for idempotent retries (same filename → If-None-Match:* catches duplicates)
        let uid = event.id ?? UUID().uuidString
        let filename = "\(uid).ics"
        let calURL = try resolveURL(calendarId)
        let eventURL = calURL.appendingPathComponent(filename)

        let icsBody = event.toICS(uid: uid)
        // CREATE ONLY on purpose — see the pre-generated-id comment above: the
        // 412 from `If-None-Match: *` is what makes an idempotent retry land on
        // the same resource instead of duplicating the event.
        let (_, _) = try await client.put(
            url: eventURL, body: icsBody, precondition: .ifNoneMatchAny)

        // Fetch back the created event to return it
        let href = eventURL.path
        return GCalEvent(
            id: href,
            summary: event.summary,
            location: event.location,
            description: event.description,
            start: nil,
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: event.recurrence,
            transparency: event.transparency,
            status: "confirmed",
            htmlLink: nil,
            created: nil,
            updated: nil
        )
    }

    func updateEvent(
        calendarId: String,
        eventId: String,
        event: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        // The edit of the whole event: edit_scope "all", which is also the scope an edit
        // given no recurrence_id gets. An occurrence id a listing gave is refused here, before
        // any request, so nothing is written (ADR-IOS-108): the assistant was shown, and the
        // user confirmed, ONE occurrence, and on CalDAV the whole event is the series, every
        // occurrence. One occurrence alone is `updateOccurrence` (edit_scope this_only); a
        // whole-series change made from one of its occurrences is not supported yet. The
        // series id edits the series, as it always has.
        if try CalDAVOccurrences.OccurrenceId.split(eventId).key != nil {
            throw CalendarProviderError.notSupported(
                "This event_id names one occurrence of a repeating event, so nothing was changed. To change this occurrence, call calendar_event_edit again with edit_scope this_only and recurrence_id set to the start_iso listed for it. Changing the whole series of a repeating CalDAV event from one of its occurrences is not supported yet, so ask the user to make that change in their calendar app.")
        }
        let eventURL = try resolveEventURL(eventId, calendarId: calendarId)

        // CalDAV PUT is a FULL-RESOURCE replace, not a PATCH — sending only the
        // patched fields wipes DTSTART/SUMMARY/VTIMEZONE/etc. (iCloud rejects
        // the resulting malformed VEVENT with 403; lax servers silently
        // corrupt). GET the existing ICS, surgically apply the patch to its
        // master VEVENT, then PUT the merged result.
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let existingICS = String(data: data, encoding: .utf8), !existingICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        // The stored resource's zone context, read once for every zone this write resolves.
        let zones = CalendarTimeZoneContext(calendarText: existingICS)
        let mergedICS = try Self.mergePatchIntoICS(existingICS, patch: event, zones: zones, mayChangeKind: true)
        // No ETag ⇒ `.unconditional`, NEVER `.ifNoneMatchAny`. The GET above
        // returned a non-empty body for this exact URL, so the resource
        // PROVABLY exists; `If-None-Match: *` asserts it does NOT, which
        // contradicts what we just observed and is a guaranteed 412 rather than
        // a conservative choice. RFC 4791 says servers SHOULD return an ETag,
        // not MUST, and `CalendarSetupView.connectCalDAV()` accepts an
        // arbitrary user-entered server URL — so the no-ETag branch is reachable
        // and is not an iCloud-only hypothetical. `splitSeries`' cap PUT follows
        // the same rule.
        let (_, _) = try await client.put(
            url: eventURL, body: mergedICS,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)

        // Clear cached ETag (it changed)
        etagCache.removeValue(forKey: eventId)

        return GCalEvent(
            id: eventId,
            summary: event.summary,
            location: event.location,
            description: event.description,
            start: nil,
            end: nil,
            attendees: nil,
            organizer: nil,
            recurrence: event.recurrence,
            transparency: event.transparency,
            status: "confirmed",
            htmlLink: nil,
            created: nil,
            updated: nil
        )
    }

    func deleteEvent(
        calendarId: String,
        eventId: String,
        sendUpdates: String
    ) async throws {
        // An occurrence id never reaches a WebDAV DELETE: that removes the whole resource,
        // which holds every occurrence of the series (ADR-IOS-108). One occurrence is removed
        // by an EXDATE written into the series (`deleteOccurrence`).
        let (seriesHref, occurrenceKey) = try CalDAVOccurrences.OccurrenceId.split(eventId)
        if let occurrenceKey {
            try await deleteOccurrence(calendarId: calendarId, seriesHref: seriesHref, key: occurrenceKey)
            return
        }
        let eventURL = try resolveEventURL(eventId, calendarId: calendarId)
        let (_, _) = try await client.delete(url: eventURL)
        etagCache.removeValue(forKey: eventId)
        BackgroundSyncLogger.logDebug("[CalDAV] Deleted event \(eventId)")
    }

    /// Delete one occurrence of a repeating event, as Google Calendar deletes one: the rest of
    /// the series stays. GET the series' resource, check that it has the occurrence now
    /// (`CalDAVOccurrences.deletion`, one parse of the resource), then
    /// ONE PUT of the resource with an EXDATE at the occurrence's place in the series and the
    /// occurrence's changed copy removed (`occurrenceDeletedResource`), conditional on the GET's
    /// ETag. A 412 is thrown as `preconditionFailed`, as every other conditional CalDAV write
    /// throws it. The PUT is an irreversible wire operation (memory 102): it removes the
    /// changed copy's content with no per-item recovery, so nothing is written unless the
    /// occurrence is found, and unless the resource it builds no longer has that occurrence
    /// and still has the series and every other changed occurrence, compared by what each
    /// VEVENT is (`CalDAVOccurrences.requireDeletedAlone`).
    private func deleteOccurrence(calendarId: String, seriesHref: String, key: String) async throws {
        let eventURL = try resolveEventURL(seriesHref, calendarId: calendarId)
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let storedICS = String(data: data, encoding: .utf8), !storedICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(seriesHref)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        let deletion = try CalDAVOccurrences.deletion(icsText: storedICS, href: seriesHref, key: key)
        // The occurrence's place is read as an instant in UTC, which has no wall time a change
        // of UTC offset skips or repeats; `recurrenceIdInMasterFrame` writes it in the series'
        // own frame, and leaves an all-day date or a floating wall time as it is.
        guard let slotInSeriesFrame = try Self.recurrenceIdInMasterFrame(
            deletion.slotInUTC, declaredZone: .gmt, kind: Self.masterDTStartKind(from: storedICS), zones: deletion.zones,
            zoneRefusal: .occurrenceDelete
        ) else {
            throw CalendarProviderError.notSupported(
                "This occurrence's place in the repeating event can't be written in the event's timezone, so it was not deleted. Nothing was deleted. The user can delete it in their calendar app.")
        }
        let updatedICS = try Self.occurrenceDeletedResource(
            storedICS: storedICS, deletion: deletion, slotNaive: slotInSeriesFrame)
        // The series and every other changed occurrence must still be there, by what each VEVENT
        // is, and the series must no longer read the occurrence.
        try CalDAVOccurrences.requireDeletedAlone(deletion, updatedICS: updatedICS, href: seriesHref)
        // No ETag ⇒ `.unconditional`, as every CalDAV write of a resource the GET above proved
        // exists (see `updateEvent`).
        _ = try await client.put(
            url: eventURL, body: updatedICS,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)
        etagCache.removeValue(forKey: seriesHref)
        BackgroundSyncLogger.logDebug("[CalDAV] Deleted occurrence \(key) of \(seriesHref)")
    }

    /// The day an all-day occurrence starts on now. CalDAV addresses an occurrence by its original
    /// slot (`RECURRENCE-ID`), so one moved on its own is read from the resource: its override's own
    /// `DTSTART` (`CalDAVProvider.occurrenceStartDay(storedICS:recurrenceIdNaive:)`).
    ///
    /// An occurrence id a listing gave addresses its series' resource, and the occurrence is the
    /// one `updateOccurrence` would change: the same `CalDAVOccurrences.scopedEditSlot` check,
    /// in the same frame (`recurrenceIdKind`), so the day checked is the day that edit writes.
    func occurrenceStartDay(
        calendarId: String,
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone
    ) async throws -> String? {
        let (seriesHref, occurrenceKey) = try CalDAVOccurrences.OccurrenceId.split(eventId)
        let eventURL = try resolveEventURL(seriesHref, calendarId: calendarId)
        let (data, _) = try await client.get(url: eventURL)
        guard let ics = String(data: data, encoding: .utf8), !ics.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let slot = try CalDAVOccurrences.scopedEditSlot(
            icsText: ics, href: seriesHref, key: occurrenceKey,
            recurrenceId: recurrenceId, zone: recurrenceIdZone, forSplit: false)
        let kind = Self.recurrenceIdKind(from: ics)
        guard let rid = try Self.recurrenceIdInMasterFrame(
            slot, declaredZone: recurrenceIdZone, kind: kind, zones: CalendarTimeZoneContext(calendarText: ics)
        ) else {
            throw CalendarProviderError.notSupported(
                "Could not express recurrence_id '\(recurrenceId)' (\(recurrenceIdZone.identifier)) in this event's timezone."
            )
        }
        return Self.occurrenceStartDay(storedICS: ics, recurrenceIdNaive: rid)
    }

    /// Single-occurrence override (this_only). CalDAV represents overrides as
    /// additional VEVENT blocks in the SAME .ics resource sharing the master's
    /// UID, distinguished by a RECURRENCE-ID property. We GET the resource,
    /// splice (or replace) an override VEVENT, PUT it back atomically.
    func updateOccurrence(
        calendarId: String,
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone,
        event: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        // An occurrence id addresses its series' resource, and its key names the occurrence.
        let (seriesHref, occurrenceKey) = try CalDAVOccurrences.OccurrenceId.split(eventId)
        let eventURL = try resolveEventURL(seriesHref, calendarId: calendarId)

        // 1. GET current ICS + ETag
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let masterICS = String(data: data, encoding: .utf8), !masterICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        // The occurrence this edit changes: one the resource has now, or nothing is written
        // (`CalDAVOccurrences.scopedEditSlot`, the same check `splitSeries` makes). In a
        // resource that holds only changed occurrences it is one of them, named by its id.
        let slot = try CalDAVOccurrences.scopedEditSlot(
            icsText: masterICS, href: seriesHref, key: occurrenceKey,
            recurrenceId: recurrenceId, zone: recurrenceIdZone, forSplit: false)

        // 2. The override: a copy of the occurrence as it stands (its existing override, else the
        //    series' VEVENT) with the patch applied (`occurrenceOverrideResource`), spliced into the
        //    resource in place of any override for the same occurrence.
        //    The slot is a wall clock in `recurrenceIdZone` (the operation's declared
        //    timezone, device by default). RFC 5545 requires
        //    RECURRENCE-ID to be expressed in the master's own frame — convert
        //    through the absolute instant. See `recurrenceIdInMasterFrame`. A resource
        //    with no series gives that frame through its overrides' own RECURRENCE-ID
        //    (`recurrenceIdKind`).
        //    The splice MUST use that SAME converted value: it decides whether an
        //    existing override is "the same occurrence", so comparing against a
        //    differently-framed string appends a duplicate VEVENT sharing
        //    UID+RECURRENCE-ID instead of replacing it — a malformed resource
        //    servers resolve nondeterministically.
        // The stored resource's zone context, read once for every zone this write resolves.
        let zones = CalendarTimeZoneContext(calendarText: masterICS)
        let frameKind = Self.recurrenceIdKind(from: masterICS)
        guard let masterFrameRecurrenceId = try Self.recurrenceIdInMasterFrame(
            slot, declaredZone: recurrenceIdZone, kind: frameKind, zones: zones
        ) else {
            throw CalendarProviderError.notSupported(
                "Could not express recurrence_id '\(recurrenceId)' (\(recurrenceIdZone.identifier)) in this event's timezone — refusing to write an override that may name a different occurrence."
            )
        }
        let updatedICS = try Self.occurrenceOverrideResource(
            storedICS: masterICS, recurrenceIdNaive: masterFrameRecurrenceId, patch: event, now: Date(), zones: zones
        )

        // 3. PUT back — atomic at the CalDAV resource level (one HTTP call).
        //    No ETag ⇒ `.unconditional`: step 1's GET proved this resource
        //    exists (we spliced the override into the body it returned), so
        //    `If-None-Match: *` would assert the opposite of what we observed.
        _ = try await client.put(
            url: eventURL, body: updatedICS,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)
        etagCache.removeValue(forKey: seriesHref)

        return GCalEvent(
            id: eventId, summary: event.summary, location: event.location,
            description: event.description, start: nil, end: nil, attendees: nil,
            organizer: nil, recurrence: nil, transparency: event.transparency,
            status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// Series split (this_and_following). Both resources are built from the
    /// stored series first (`seriesSplitResources`): the series capped before
    /// the split, and the new part as a copy of the series re-anchored at the
    /// split with the patch applied. Then the new part is created as a NEW .ics
    /// and only after that is the capped series PUT back over the existing one.
    ///
    /// **Create first, cap last.** The cap removes the series' occurrences after
    /// the split, and with them the changed occurrences and extra dates that the
    /// new part takes over. Written first, a cap whose response is lost leaves a
    /// series that no longer holds them, and the retry copies the new part from
    /// that series, so they are gone for good. Written last, the new part already
    /// holds them, and every interruption leaves at worst both parts showing the
    /// later occurrences until the retry writes the cap. The retry finds its own
    /// new part (a 412 on the create-only PUT whose resource carries our UID) and
    /// goes on to the cap. A failed cap is rethrown and nothing is rolled back.
    func splitSeries(
        calendarId: String,
        eventId: String,
        recurrenceId: String,
        recurrenceIdZone: TimeZone,
        patch: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        // An occurrence id addresses its series' resource, and its key names the occurrence.
        // The split's new part is named from the series' href and the checked slot whichever
        // id the edit was given, so a retry and the same split asked for through the series
        // id land on one resource.
        let (seriesHref, occurrenceKey) = try CalDAVOccurrences.OccurrenceId.split(eventId)
        let eventURL = try resolveEventURL(seriesHref, calendarId: calendarId)

        // 1. GET master ICS + ETag
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let masterICS = String(data: data, encoding: .utf8), !masterICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        // The occurrence the split starts at: one the series has, or nothing is written
        // (`CalDAVOccurrences.scopedEditSlot`, the same check `updateOccurrence` makes). Where
        // the series ends is left to `RecurrenceTail.newSeriesRule` below, which also knows a
        // series this split already capped.
        let slot = try CalDAVOccurrences.scopedEditSlot(
            icsText: masterICS, href: seriesHref, key: occurrenceKey,
            recurrenceId: recurrenceId, zone: recurrenceIdZone, forSplit: true)

        // 2. Parse the original RRULE so we can build the capped variant + the
        //    new-series RRULE (the original end carried over).
        guard let originalRRule = Self.extractRRule(from: masterICS) else {
            throw CalendarProviderError.notSupported("Master event has no RRULE; can't split.")
        }
        // RFC 5545 §3.3.10: the UNTIL value type must match DTSTART's. If the
        // master's DTSTART is a bare DATE (all-day), UNTIL must be a bare DATE.
        let masterIsAllDay = Self.icsIsAllDay(masterICS)
        // The cap is an ABSOLUTE boundary (RFC 5545 UNTIL is UTC for a timed
        // DTSTART), so it is computed from the declared frame directly — no
        // conversion, the instant is the instant.
        guard let untilValue = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: slot, allDay: masterIsAllDay, zone: recurrenceIdZone) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        // The new series' DTSTART, by contrast, is a WALL CLOCK the successor
        // resource carries in the master's frame, so it must be handed a
        // master-frame value AND the frame that value is now in. Capping in one
        // frame while starting the successor in another is how a split
        // duplicates or drops the boundary occurrence.
        //
        // `seriesSplitResources` writes this master-frame value straight into the
        // new part's DTSTART, in the master's own value type and TZID, so it is
        // never read back in another frame. (The successor used to be rebuilt
        // from fields, and a `.utc` master's value was re-read in the device
        // zone, which moved the successor's start by the device's UTC offset
        // while `untilValue` above stayed on the correct instant.)
        // The stored resource's zone context, read once for every zone this write resolves.
        let zones = CalendarTimeZoneContext(calendarText: masterICS)
        let masterKindForSplit = Self.masterDTStartKind(from: masterICS)
        guard let masterFrameRecurrenceId = try Self.recurrenceIdInMasterFrame(
            slot, declaredZone: recurrenceIdZone, kind: masterKindForSplit, zones: zones
        ) else {
            throw CalendarProviderError.notSupported(
                "Could not express recurrence_id '\(recurrenceId)' (\(recurrenceIdZone.identifier)) in this event's timezone — refusing to split a series at an occurrence we cannot name."
            )
        }
        // The new series ends where the original one did: the same UNTIL, or
        // what is left of its COUNT. Worked out here, before the cap PUT in
        // step 3, so a split the series cannot take (it already ends before the
        // split, or its COUNT cannot be counted) is refused with nothing written.
        // A patch that brings its own recurrence is still written as given
        // (`seriesSplitResources` applies it over this one), but the check runs all the same:
        // it is also what stops the cap from moving the end of a series that
        // already ended before the split.
        let newSeriesRRule = try RecurrenceTail.newSeriesRule(
            from: originalRRule,
            seriesStart: Self.masterDTStartDay(from: masterICS),
            split: RecurrenceTail.Day(iso: masterFrameRecurrenceId),
            capUntil: untilValue)
        let cappedRRule = GoogleCalendarProvider.replaceOrAppendUntil(in: originalRRule, untilValue: untilValue)
        // Both resources are built from the STORED series before anything is
        // written (`seriesSplitResources`): the new part is a copy of the series
        // re-anchored at the split, so it keeps every property the series has.
        // A series that can't be split safely is refused here, with nothing to
        // roll back.
        //
        // The UID/filename is DETERMINISTIC (derived from master id +
        // recurrence_id) so a retry after a lost ACK on the successor PUT below
        // re-targets the SAME resource instead of creating a duplicate series at
        // a fresh random URL.
        let newUid = GoogleCalendarProvider.deterministicSplitEventId(masterId: seriesHref, recurrenceId: slot)
        let resources = try Self.seriesSplitResources(
            storedICS: masterICS, slotNaiveISO: masterFrameRecurrenceId,
            cappedRRule: cappedRRule, newRRule: newSeriesRRule, newUid: newUid, patch: patch, now: Date(), zones: zones)
        // The new part read the way a listing reads it, so the caller gets the
        // series it will see. Read BEFORE any write: a part we cannot read back
        // is refused with nothing written.
        let calURL = try resolveURL(calendarId)
        let newEventURL = calURL.appendingPathComponent("\(newUid).ics")
        guard let created = ICSParser.parse(icsText: resources.newPart, resourceHref: newEventURL.path, etag: nil).first else {
            throw CalendarProviderError.notSupported("The new part of the repeating event could not be built, so it was not split.")
        }

        // 3. Create the new part at its own .ics resource, CREATE-ONLY
        //    (`.ifNoneMatchAny`): a retry never overwrites a new part the user may
        //    have edited since.
        do {
            _ = try await client.put(
                url: newEventURL, body: resources.newPart, precondition: .ifNoneMatchAny)
        } catch CalDAVError.preconditionFailed {
            // 412: something already occupies the DETERMINISTIC new-part URL. The
            // likely cause is a retry: an earlier attempt created the new part and
            // its response, or its cap, never completed. Only POSITIVE evidence
            // that the resource is the new part THIS split derives (its ICS
            // carries our deterministic UID) lets the split go on to the cap. A
            // probe that throws, 404s, or finds another UID rethrows the 412 with
            // nothing written; absence of evidence never becomes permission.
            //
            // The new-part PUT itself stays `.ifNoneMatchAny`. Widening it to an
            // overwrite would silently replace a series the user may have edited;
            // that direction is deliberately held (`MIS-026`).
            guard await Self.successorIsOurs(client: client, url: newEventURL, uid: newUid) else {
                throw CalDAVError.preconditionFailed
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CalDAV] splitSeries: new part \(newUid) already exists and is ours — going on to the cap")
            }
        }

        // 4. PUT the capped series back. No ETag ⇒ `.unconditional`: step 1's GET
        //    proved the series resource exists (its ICS is what we just capped),
        //    so `If-None-Match: *` would assert the opposite. With an ETag, a
        //    concurrent edit since the GET 412s and the retry caps the series as
        //    it now stands; the new part already exists, so nothing the series held at
        //    the split's read is lost. A change another client made to the later
        //    occurrences after that read is not on the new part and the cap removes it.
        etagCache.removeValue(forKey: seriesHref)
        _ = try await client.put(
            url: eventURL, body: resources.cappedSeries,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)

        return created
    }

    /// POSITIVE evidence that the resource now occupying `url` is the successor
    /// series THIS split derived — i.e. the server serves it and its master
    /// VEVENT carries `uid`, the deterministic id built from
    /// (master id, recurrence id).
    ///
    /// Every other outcome answers `false`: a throw, a 404, a body that will not
    /// decode, a body with no master UID, or a UID that is somebody else's. The
    /// caller treats `false` as "not ours" and stops with nothing written, so a
    /// probe outage can never manufacture a success. Deliberately `async` but not `throws` for that
    /// reason: there is no error path a caller could widen.
    ///
    /// The URL match alone is NOT sufficient. `newEventURL` is a path we chose,
    /// so an unrelated resource could sit there (a user-created `.ics`, a
    /// server that reuses hrefs). The UID inside the body is the only thing that
    /// says the *content* is ours, and content ownership is what "the split
    /// already happened" actually claims.
    private static func successorIsOurs(client: CalDAVClient, url: URL, uid: String) async -> Bool {
        do {
            let (data, _) = try await client.get(url: url)
            guard let ics = String(data: data, encoding: .utf8), !ics.isEmpty else { return false }
            return Self.extractUID(from: ics) == uid
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CalDAV] splitSeries: successor probe failed for \(url.path), not treated as ours. error=\(error)")
            }
            return false
        }
    }

    // MARK: - ICS Helpers (recurring edits)

    /// Pull the UID line from the MASTER VEVENT. Scoped via `masterTopLevelLines`
    /// so a VTIMEZONE, an override block or an alarm's own UID (RFC 9074) can't shadow it.
    static func extractUID(from ics: String) -> String? {
        for line in Self.masterTopLevelLines(ics) {
            if line.hasPrefix("UID:") {
                return String(line.dropFirst("UID:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pull the RRULE line (full text, incl. the `RRULE:` prefix) from the
    /// MASTER VEVENT. Scoped so a VTIMEZONE's DST RRULE can't be returned.
    static func extractRRule(from ics: String) -> String? {
        for line in Self.masterTopLevelLines(ics) {
            if line.hasPrefix("RRULE:") { return line }
        }
        return nil
    }

    /// The MASTER VEVENT's DTSTART day as written, which is the day in the
    /// frame its RRULE expands in (its TZID, UTC for a `Z` value, or floating).
    /// Scoped like `icsIsAllDay` so a VTIMEZONE's DTSTART can't stand in for it.
    static func masterDTStartDay(from ics: String) -> RecurrenceTail.Day? {
        for line in Self.masterTopLevelLines(ics) {
            guard line.uppercased().hasPrefix("DTSTART"), let colonIdx = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            return RecurrenceTail.Day(ical: value)
        }
        return nil
    }

    /// True when the MASTER VEVENT's DTSTART is a bare DATE (all-day event).
    /// RFC 5545: `DTSTART;VALUE=DATE:20260520` or a bare 8-digit value with no
    /// `T`. Scoped to the master VEVENT so a VTIMEZONE's `DTSTART:…T020000`
    /// can't mislead the check.
    static func icsIsAllDay(_ ics: String) -> Bool {
        for line in Self.masterTopLevelLines(ics) {
            guard line.hasPrefix("DTSTART") else { continue }
            guard let colonIdx = line.firstIndex(of: ":") else { return false }
            if ICSValueType.statesDate(line[..<colonIdx]) { return true }
            // Bare form: "DTSTART:20260520" (8 digits, no T after the colon).
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            return value.count == 8 && !value.contains("T")
        }
        return false
    }

    /// How the master VEVENT's DTSTART expresses its value. Drives the form an
    /// occurrence override (RECURRENCE-ID + DTSTART) and a split's new series
    /// must use so they match the master — RFC 5545 §3.8.4.4 requires
    /// RECURRENCE-ID to share the master DTSTART's value type.
    enum MasterDTStartKind: Equatable {
        case allDay              // DTSTART;VALUE=DATE:20260520
        case utc                 // DTSTART:20260520T170000Z
        case floating            // DTSTART:20260520T170000
        case zoned(String)       // DTSTART;TZID=America/Vancouver:20260520T170000
    }

    /// Classify the master VEVENT's DTSTART. Scoped via `masterTopLevelLines` so
    /// a leading VTIMEZONE's own DTSTART can't be mistaken for the event's.
    static func masterDTStartKind(from ics: String) -> MasterDTStartKind {
        for line in Self.masterTopLevelLines(ics) where line.uppercased().hasPrefix("DTSTART") {
            return valueKind(ofLine: line)
        }
        return .floating
    }

    /// The frame a resource's RECURRENCE-IDs are written in: its series VEVENT's DTSTART
    /// (`masterDTStartKind`). A resource that holds only changed occurrences (an invitation to
    /// single occurrences, RFC 4791 §4.1) has no series VEVENT, and gives the frame through its
    /// overrides' own RECURRENCE-ID: RFC 5545 §3.8.4.4 writes every RECURRENCE-ID of one event in
    /// its series' DTSTART value type and zone, so the first one names it for all. A resource that
    /// breaks that rule fails closed: the converted value names none of its overrides, and with no
    /// series to copy a new one from, `occurrenceOverrideResource` writes nothing.
    static func recurrenceIdKind(from ics: String) -> MasterDTStartKind {
        guard Self.masterTopLevelLines(ics).isEmpty,
              let recurrenceId = Self.icsLines(ics).first(where: { $0.uppercased().hasPrefix("RECURRENCE-ID") }) else {
            return masterDTStartKind(from: ics)
        }
        return valueKind(ofLine: recurrenceId)
    }

    /// How a date-time property line (`DTSTART`, `RECURRENCE-ID`) expresses its value.
    static func valueKind(ofLine line: String) -> MasterDTStartKind {
        guard let colonIdx = line.firstIndex(of: ":") else { return .floating }
        let params = line[..<colonIdx].split(separator: ";").dropFirst()  // skip the property name
        let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        // All-day: a VALUE=DATE param, or a bare 8-digit value with no time.
        if ICSValueType.statesDate(line[..<colonIdx])
            || (value.count == 8 && !value.contains("T")) {
            return .allDay
        }
        // Zoned: a TZID= parameter.
        for p in params where p.uppercased().hasPrefix("TZID=") {
            let tzid = String(p.dropFirst("TZID=".count))
            if !tzid.isEmpty { return .zoned(tzid) }
        }
        // UTC when the value carries a trailing Z; otherwise floating.
        return value.uppercased().hasSuffix("Z") ? .utc : .floating
    }

    /// Split an ICS resource into LOGICAL lines, performing RFC 5545 line
    /// unfolding first. Continuation lines (starting with a space or tab) are
    /// stitched onto the prior line, then the result is split on LF.
    /// Without unfolding, a long DESCRIPTION/LOCATION would be silently
    /// truncated when extracted (because the bytes past column 75 are on the
    /// next physical line). Tolerates CRLF and bare LF.
    static func icsLines(_ ics: String) -> [String] {
        ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Split ICS into PHYSICAL lines, normalizing CRLF and bare-LF endings but
    /// WITHOUT RFC 5545 unfolding. `replaceRRule`/`spliceOrReplaceOverride`
    /// rewrite the resource and must preserve its folded structure for a clean
    /// round-trip — they only need the line endings normalized so a server that
    /// emits bare `\n` (valid per RFC 5545 §3.1) isn't treated as one giant line.
    static func physicalICSLines(_ ics: String) -> [String] {
        ics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Replace the MASTER VEVENT's RRULE line with `newRRule`, keeping the rest
    /// of the resource untouched.
    ///
    /// CRITICAL: scoped to the master VEVENT (the first `BEGIN:VEVENT…END:VEVENT`
    /// with no `RECURRENCE-ID`). A naive "replace the first `RRULE:` in the
    /// resource" scan would clobber a leading `VTIMEZONE` block's DST rule —
    /// `STANDARD`/`DAYLIGHT` subcomponents carry their OWN `RRULE` — corrupting
    /// the calendar's timezone definition and leaving the event's recurrence
    /// untouched. CalDAV resources almost always lead with a VTIMEZONE, so the
    /// old whole-resource scan was reliably wrong on real servers.
    static func replaceRRule(in ics: String, newRRule: String) -> String {
        // Sanitized for the same reason as `replaceOrAppendInMasterVEvent`: this inserts a
        // caller-supplied property line into a resource we PUT, and CRLF is the property separator.
        let newRRule = GCalEventInput.sanitizeICSLine(newRRule)
        let lines = Self.physicalICSLines(ics)
        var output: [String] = []
        var replaced = false
        var i = 0
        while i < lines.count {
            guard Self.isMarker(lines[i], "BEGIN:VEVENT"), !replaced else {
                output.append(lines[i]); i += 1; continue
            }
            // Buffer the whole VEVENT block — we can't tell master from
            // override until we've seen (or not seen) a RECURRENCE-ID line.
            var block: [String] = [lines[i]]
            var hasRecurrenceId = false
            i += 1
            while i < lines.count && !Self.isMarker(lines[i], "END:VEVENT") {
                if lines[i].hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
                block.append(lines[i])
                i += 1
            }
            if i < lines.count { block.append(lines[i]); i += 1 }  // END:VEVENT
            // Master VEVENT (no RECURRENCE-ID) → replace its RRULE line.
            if !hasRecurrenceId {
                var rewritten: [String] = []
                var j = 0
                while j < block.count {
                    let line = block[j]
                    if !replaced && line.hasPrefix("RRULE:") {
                        rewritten.append(newRRule)
                        replaced = true
                        j += 1
                        // Drop any folded continuation lines belonging to the
                        // old RRULE (RFC 5545 §3.1: a long logical line is split
                        // across physical lines, continuations begin with a
                        // space or tab). Leaving them would orphan the old
                        // RRULE's tail onto `newRRule` when a parser unfolds.
                        while j < block.count,
                              let first = block[j].first, first == " " || first == "\t" {
                            j += 1
                        }
                        continue
                    }
                    rewritten.append(line)
                    j += 1
                }
                block = rewritten
            }
            output.append(contentsOf: block)
        }
        return output.joined(separator: "\r\n")
    }

    // MARK: - PATCH merge

    /// Apply a partial patch to an existing CalDAV resource. CalDAV PUT is a
    /// full-resource replace — sending a freshly-built ICS containing only the
    /// patched fields produces a VEVENT with no DTSTART/SUMMARY/etc., which
    /// strict servers (iCloud) reject with 403 and lax ones silently corrupt.
    /// This merge surgically writes the patched fields into the MASTER VEVENT
    /// of the existing ICS, leaving VTIMEZONE, ORGANIZER, RECURRENCE-ID
    /// overrides, and every other field untouched — except that a patch which
    /// moves the series' start also moves every value tied to it (EXDATE,
    /// RDATE, an UNTIL the patch did not write, each override's
    /// RECURRENCE-ID, and the DTEND when the patch gives no end; see
    /// `shiftSeriesAnchoredValues`). Throws, before any
    /// write, when one of those values cannot be moved correctly.
    ///
    /// Also applied to the copies a split and a one-occurrence edit make
    /// (`seriesSplitResources`, `occurrenceOverrideResource`), so the patch
    /// lands on them exactly as it lands on the series: a split's new part
    /// whose start the edit moves takes its excluded and added dates, its
    /// UNTIL and its changed occurrences' RECURRENCE-IDs along (their own
    /// times stay where the user put them). An override is merged without its
    /// RECURRENCE-ID and holds no dates or rule, so it has nothing to move.
    ///
    /// `zones` is the zone context of the stored resource the write started from. Throws the
    /// zone-naming refusal when a start or end has to be worked out in a zone TabMail does not
    /// recognize.
    ///
    /// A patch whose start or end is of the other kind than the stored event's
    /// (a time for an all-day event, a date for a timed one) is the user turning
    /// the event into the other kind. It is either written in full or refused,
    /// never dropped: see `kindToWrite`.
    static func mergePatchIntoICS(
        _ ics: String, patch: GCalEventInput, zones: CalendarTimeZoneContext, mayChangeKind: Bool = false
    ) throws -> String {
        var result = ics

        if let summary = patch.summary, !summary.isEmpty {
            result = replaceOrAppendInMasterVEvent(
                in: result, propertyKey: "SUMMARY",
                newLine: "SUMMARY:\(escapeICSText(summary))"
            )
        }
        if let location = patch.location {
            if location.isEmpty {
                result = removeFromMasterVEvent(in: result, propertyKey: "LOCATION")
            } else {
                result = replaceOrAppendInMasterVEvent(
                    in: result, propertyKey: "LOCATION",
                    newLine: "LOCATION:\(escapeICSText(location))"
                )
            }
        }
        if let description = patch.description {
            if description.isEmpty {
                result = removeFromMasterVEvent(in: result, propertyKey: "DESCRIPTION")
            } else {
                result = replaceOrAppendInMasterVEvent(
                    in: result, propertyKey: "DESCRIPTION",
                    newLine: "DESCRIPTION:\(escapeICSText(description))"
                )
            }
        }
        if let transparency = patch.transparency {
            result = replaceOrAppendInMasterVEvent(
                in: result, propertyKey: "TRANSP",
                newLine: "TRANSP:\(transparency.uppercased())"
            )
        }
        let patchedRRule = patch.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") })
        if let rrule = patchedRRule {
            // `replaceRRule` handles the existing-RRULE case AND the
            // master-has-no-RRULE case via its replaceOrAppendInMaster fallback.
            if extractRRule(from: result) != nil {
                result = replaceRRule(in: result, newRRule: rrule)
            } else {
                result = replaceOrAppendInMasterVEvent(
                    in: result, propertyKey: "RRULE", newLine: rrule
                )
            }
        }
        // DTSTART / DTEND — re-emit in the master's existing value type
        // (all-day / zoned / utc / floating) so RFC 5545 §3.8.4.4 is preserved,
        // unless the patch turns the event into the other kind.
        let storedKind = masterDTStartKind(from: result)
        let kind = try kindToWrite(in: result, stored: storedKind, patch: patch, mayChangeKind: mayChangeKind)
        let patchedEnd = try formatDTLine(name: "DTEND", patch: patch, isStart: false, kind: kind, zones: zones)
        if kind != storedKind {
            // The event changes kind: both lines are written in the new kind (the
            // end below), and a DURATION, which is in the old one, goes.
            // `kindToWrite` allowed this only for an event that does not repeat, so
            // nothing else is tied to the start. One line of each kind is not a
            // valid event, so a start or end missing, or not readable in the new
            // kind, refuses the edit.
            guard let dtstart = try formatDTLine(name: "DTSTART", patch: patch, isStart: true, kind: kind, zones: zones),
                  patchedEnd != nil else {
                throw CalendarProviderError.notSupported(Self.kindChangeNeedsBothMessage)
            }
            result = removeFromMasterVEvent(in: result, propertyKey: "DURATION")
            result = replaceOrAppendInMasterVEvent(in: result, propertyKey: "DTSTART", newLine: dtstart)
        } else if let dtstart = try formatDTLine(name: "DTSTART", patch: patch, isStart: true, kind: kind, zones: zones) {
            let oldStart = try masterStartWallTime(in: result)
            result = replaceOrAppendInMasterVEvent(in: result, propertyKey: "DTSTART", newLine: dtstart)
            // Moving the start moves everything RFC 5545 ties to it. An RRULE
            // the patch wrote was written for the new start, so its UNTIL stays.
            // A start moved with no end moves the existing DTEND by the same
            // shift, so the event keeps its length, as Google and Outlook do;
            // an end the patch gives is written below instead.
            if let oldStart, let newStart = try masterStartWallTime(in: result), newStart != oldStart {
                result = try shiftSeriesAnchoredValues(
                    in: result, by: SeriesStartShift(old: oldStart, new: newStart, zones: zones),
                    moveUntil: patchedRRule == nil, moveEnd: patchedEnd == nil)
            }
        }
        if let dtend = patchedEnd {
            result = replaceOrAppendInMasterVEvent(in: result, propertyKey: "DTEND", newLine: dtend)
        }
        if let attendees = patch.attendees {
            result = replaceAttendeesInMasterVEvent(in: result, attendees: attendees)
        }
        return result
    }

    static let kindChangeNeedsBothMessage =
        "To change this event between all-day and timed, give both its new start and its new end, each as a date or a date and time. Nothing was changed."
    static let kindChangeOnRepeatingMessage =
        "This edit gives the start or end as all-day where this event or occurrence is timed, or the other way round, and on this calendar TabMail can't change that for an event that repeats. Nothing was changed. If the user did not ask to change between all-day and timed, retry with all_day matching how this occurrence is shown; otherwise the user can change it in their calendar app."

    /// The value type the merge writes `DTSTART` / `DTEND` in. It is the stored
    /// event's, unless the patch gives a start or end of the other kind: a time
    /// for an all-day event (the user is making it timed) or a date for a timed
    /// one (making it all-day). `formatDTLine` cannot express such a value in
    /// the stored kind, so writing in it would leave the event as it was while
    /// the edit reported success.
    ///
    /// The change is made only on a whole event that does not repeat
    /// (`mayChangeKind`, no rule, no extra or excluded dates, no changed
    /// occurrence). The merge then writes both the start and the end in the new
    /// kind, and refuses when the patch does not give both: one line of each
    /// kind is not a valid event. Every other case throws before anything is
    /// written. A newly timed event is written in UTC, which names the same
    /// instants and needs no VTIMEZONE. The series is read as the writer sees
    /// it (`masterTopLevelLines`), so the two never disagree on what repeats.
    static func kindToWrite(
        in ics: String, stored: MasterDTStartKind, patch: GCalEventInput, mayChangeKind: Bool
    ) throws -> MasterDTStartKind {
        let givesTime = patch.startDateTime != nil || patch.endDateTime != nil
        let givesDate = patch.startDate != nil || patch.endDate != nil
        let toTimed = stored == .allDay && givesTime
        let toAllDay = stored != .allDay && givesDate
        guard toTimed || toAllDay else { return stored }
        let repeats = masterTopLevelLines(ics).contains { line in
            guard let name = icsProperty(line)?.name else { return false }
            return ["RRULE", "RDATE", "EXDATE"].contains(name)
        } || icsUnits(ics).contains { icsProperty($0.text)?.name == "RECURRENCE-ID" }
        guard mayChangeKind, !repeats else {
            throw CalendarProviderError.notSupported(kindChangeOnRepeatingMessage)
        }
        return toTimed ? .utc : .allDay
    }

    /// Replace the MASTER VEVENT's own property named `propertyKey` (the first one, with its folded
    /// continuation lines) with `newLine`, or insert `newLine` among its properties when it has none.
    /// Only the VEVENT's own properties count: an alarm's `DESCRIPTION` or `SUMMARY` is never taken
    /// for the event's.
    static func replaceOrAppendInMasterVEvent(in ics: String, propertyKey: String, newLine: String) -> String {
        // Sanitized HERE rather than at each caller, because this is the single point every
        // caller-supplied property line enters an ICS resource we then PUT. A value carrying CRLF
        // would otherwise become an extra property (see `GCalEventInput.sanitizeICSLine`). Today's
        // callers happen to be safe — SUMMARY/LOCATION/DESCRIPTION pass through `escapeICSText`,
        // TRANSP is normalized at the tool boundary, and RRULE is validated there — but that is a
        // property of the current call sites, not of this function, and the next caller inherits the
        // guard for free.
        let newLine = GCalEventInput.sanitizeICSLine(newLine)
        return rewriteMasterVEvent(in: ics) { block in
            var replaced = false
            let out = rewriteTopLevel(block) { _, name in
                guard name == propertyKey, !replaced else { return nil }
                replaced = true
                return [newLine]
            }
            return replaced ? out : insertBeforeSubcomponents(out, lines: [newLine])
        }
    }

    /// Remove the MASTER VEVENT's own property named `propertyKey` (the first one, with its folded
    /// continuation lines). Used to clear LOCATION/DESCRIPTION when the patch passes an empty string,
    /// and to drop a DURATION an explicit end replaces. An alarm's properties are never touched.
    static func removeFromMasterVEvent(in ics: String, propertyKey: String) -> String {
        rewriteMasterVEvent(in: ics) { block in
            var removed = false
            return rewriteTopLevel(block) { _, name in
                guard name == propertyKey, !removed else { return nil }
                removed = true
                return []
            }
        }
    }

    /// Replace the MASTER VEVENT's attendees with the supplied list.
    /// The queue resolves attendee deltas (add_attendees / remove_attendees)
    /// against the existing attendee list BEFORE calling updateEvent, so by
    /// the time we get here `attendees` is the desired final list.
    ///
    /// An attendee who stays keeps their own line: role, answer, RSVP and every other parameter the
    /// server holds. Rewriting it would reset all of them for everyone each time one attendee is added
    /// or removed. A new attendee is written where the attendees were, or else ahead of any nested
    /// component (RFC 5545 puts a VEVENT's properties before its alarms).
    static func replaceAttendeesInMasterVEvent(in ics: String, attendees: [(email: String, name: String?)]) -> String {
        rewriteMasterVEvent(in: ics) { block in
            var kept: [String: ICSUnit] = [:]
            var rest: [ICSUnit] = []
            var insertAt: Int?
            var depth = 0
            for unit in block {
                let upper = unit.text.uppercased()
                if upper.hasPrefix("BEGIN:") { depth += 1 } else if upper.hasPrefix("END:") { depth -= 1 }
                if depth == 1, let p = icsProperty(unit.text), p.name == "ATTENDEE" {
                    if let address = mailtoAddress(p.value), kept[address] == nil { kept[address] = unit }
                    if insertAt == nil { insertAt = rest.count }
                    continue
                }
                rest.append(unit)
            }
            // Sanitized for the same reason as `GCalEventInput.toICS`: `cn` and `a.email` are
            // model-supplied (an attendee name or address from tool arguments) and are
            // interpolated with only a quote swap, so a CRLF in either would split this into an
            // extra ICS property the CalDAV server honours — an injected ATTENDEE has the server
            // mail the invitation to an address the user never typed.
            //
            // Only the lines generated HERE are sanitized. The surrounding lines came from the
            // server's own ICS via `physicalICSLines`, which has already split on real line
            // breaks, so there is nothing left in them to strip and rewriting them would risk
            // altering a value the server round-trips.
            let attendeeUnits = attendees.map { a -> ICSUnit in
                if let existing = kept[a.email.lowercased()] { return existing }
                let cn = (a.name ?? a.email).replacingOccurrences(of: "\"", with: "'")
                let line = GCalEventInput.sanitizeICSLine(
                    "ATTENDEE;CN=\"\(cn)\";ROLE=REQ-PARTICIPANT:mailto:\(a.email)"
                )
                return ICSUnit(physical: [line], text: line)
            }
            // No attendees before: every line is new (a single physical line), and goes ahead of any
            // nested component.
            guard let insertAt else {
                return insertBeforeSubcomponents(rest, lines: attendeeUnits.map(\.text))
            }
            var out = rest
            out.insert(contentsOf: attendeeUnits, at: insertAt)
            return out
        }
    }

    /// Build a DTSTART / DTEND line for the merge path, re-using the master's
    /// existing value type so the line we substitute in keeps the same form
    /// (all-day / zoned / utc / floating). Throws the zone-naming refusal when the zone the line is
    /// written in is one TabMail does not recognize: its wall clock could not be worked out.
    private static func formatDTLine(
        name: String, patch: GCalEventInput, isStart: Bool, kind: MasterDTStartKind, zones: CalendarTimeZoneContext
    ) throws -> String? {
        if case .allDay = kind {
            let date = isStart ? patch.startDate : patch.endDate
            if let d = date {
                return "\(name);VALUE=DATE:\(d.replacingOccurrences(of: "-", with: ""))"
            }
            return nil
        }
        let iso = isStart ? patch.startDateTime : patch.endDateTime
        guard let iso, let date = Date.fromISO8601(iso) else { return nil }
        let tzid = isStart ? patch.startTimeZone : patch.endTimeZone
        switch kind {
        case .allDay:
            return nil // handled above
        case .zoned(let masterTz):
            let chosenTz = tzid?.isEmpty == false ? tzid! : masterTz
            let lineZone = try zone(forTZID: chosenTz, zones: zones)
            // An edit naming the event's own zone by another name (the IANA name of a stored
            // Windows name) keeps the TZID as stored: the resource's VTIMEZONE is for that TZID.
            let sameZone = chosenTz != masterTz
                && CalendarTimeZoneResolver.zone(named: masterTz, in: zones)?.identifier == lineZone.identifier
            let writtenTz = sameZone ? masterTz : chosenTz
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.timeZone = lineZone
            return "\(name);TZID=\(writtenTz):\(fmt.string(from: date))"
        case .utc:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return "\(name):\(fmt.string(from: date))"
        case .floating:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.timeZone = .current
            return "\(name):\(fmt.string(from: date))"
        }
    }

    /// RFC 5545 §3.3.11 text-value escape (`\` `;` `,` `\n`). Matches the impl
    /// in `GCalEventInput.toICS` — duplicated here because that file's
    /// version is private; calling sites are local so the duplication is
    /// cheap and prevents the `GCalEventInput` extension from leaking helpers.
    private static func escapeICSText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Re-express the caller's naive `recurrence_id` in the frame the master's
    /// DTSTART uses, so `RECURRENCE-ID` names the occurrence the caller meant.
    ///
    /// 🚨 **THE INPUT IS NOT IN THE MASTER'S ZONE — IT NEVER WAS.** Until
    /// 2026-08-07 the occurrence-override builder compacted the naive digits VERBATIM and
    /// stapled the master's `TZID` onto them, and the split's successor builder parsed the
    /// same string in the master's zone, both on the documented premise that "the
    /// naive recurrence_id is the occurrence's wall-clock time IN THE MASTER'S
    /// ZONE". That premise is false at the mint site:
    /// `CalendarToolHelpers.formatDetailedEvent` renders `start_iso` in
    /// `timezone ?? .current` — the DEVICE zone by default — and round 18 added a
    /// separate `event_timezone` field precisely because the two are different
    /// things. So for any series whose master zone differs from the device zone,
    /// CalDAV was writing an override keyed to a wall clock no occurrence has:
    /// at best an orphan override the user never sees take effect, at worst one
    /// that collides with a DIFFERENT real occurrence. Converting through the
    /// absolute instant is what makes CalDAV agree with Google and Exchange about
    /// what one `recurrence_id` means.
    ///
    /// Identity in the overwhelmingly common case (declared zone == master zone,
    /// or the value carries no time), so this is not a behaviour change for the
    /// single-timezone user.
    ///
    /// Returns nil when the value cannot be re-expressed; callers MUST fail closed
    /// rather than fall back to the raw digits, which is the pre-fix behaviour and
    /// the defect itself. Throws the zone-naming refusal (`zoneRefusal`) when the master's TZID
    /// is a zone TabMail does not recognize; `zones` is the master resource's zone context.
    static func recurrenceIdInMasterFrame(
        _ recurrenceId: String,
        declaredZone: TimeZone,
        kind: MasterDTStartKind,
        zones: CalendarTimeZoneContext,
        zoneRefusal: ZoneRefusal = .change
    ) throws -> String? {
        switch kind {
        case .allDay:
            // A calendar DATE has no zone. Shifting one by a UTC offset is how
            // you land on the adjacent day's occurrence.
            return recurrenceId
        case .floating:
            // RFC 5545 floating time is "local wherever the viewer is", so there
            // is no target frame to convert INTO. The declared wall clock is the
            // best available reading; inventing an offset would be worse.
            return recurrenceId
        case .utc:
            return RecurrenceOccurrenceResolver.renderNaive(
                recurrenceId, from: declaredZone, to: TimeZone(identifier: "UTC") ?? declaredZone
            )
        case .zoned(let tzid):
            let masterZone = try zone(forTZID: tzid, zones: zones, refusal: zoneRefusal)
            return RecurrenceOccurrenceResolver.renderNaive(recurrenceId, from: declaredZone, to: masterZone)
        }
    }

    /// Insert an override VEVENT into a CalDAV ICS resource. If the resource
    /// already has an override for the same RECURRENCE-ID, replace it; otherwise
    /// append the new override before END:VCALENDAR.
    static func spliceOrReplaceOverride(ics: String, recurrenceId: String, kind: MasterDTStartKind, newOverrideBlock: String) -> String {
        let lines = Self.physicalICSLines(ics)
        var output: [String] = []
        var i = 0
        var spliced = false

        while i < lines.count {
            let line = lines[i]
            if Self.isMarker(line, "BEGIN:VEVENT") {
                // Collect this VEVENT into `block` so we can decide whether to keep it.
                var block: [String] = [line]
                var blockRecurId: String? = nil
                i += 1
                while i < lines.count && !Self.isMarker(lines[i], "END:VEVENT") {
                    block.append(lines[i])
                    if lines[i].hasPrefix("RECURRENCE-ID") {
                        // Normalize RECURRENCE-ID value (strip params + parse).
                        let valuePart = lines[i].components(separatedBy: ":").last ?? ""
                        blockRecurId = valuePart.trimmingCharacters(in: .whitespaces)
                    }
                    i += 1
                }
                if i < lines.count { block.append(lines[i]) /* END:VEVENT */; i += 1 }

                // If this block IS an override for the target recurrence_id, drop it
                // and emit our new override instead.
                if let bid = blockRecurId, Self.recurrenceIdsMatch(bid, recurrenceId, allDay: kind == .allDay) {
                    output.append(newOverrideBlock)
                    spliced = true
                } else {
                    output.append(contentsOf: block)
                }
                continue
            }
            if Self.isMarker(line, "END:VCALENDAR") && !spliced {
                // No matching override existed — append ours before END:VCALENDAR.
                output.append(newOverrideBlock)
                spliced = true
            }
            output.append(line)
            i += 1
        }
        return output.joined(separator: "\r\n")
    }

    /// Compare two RECURRENCE-ID values for equality, tolerating naive-ISO vs
    /// compact-ICS formats (`2026-05-20T17:00:00` ↔ `20260520T170000`) and a
    /// trailing UTC `Z`. Uses EXACT equality after normalization — an earlier
    /// prefix-match here could false-positive (`20260520T17` "matches"
    /// `20260520T170000`), which would splice an override onto the wrong
    /// occurrence and corrupt the .ics resource.
    ///
    /// `allDay` relaxes the comparison to the DATE portion only. For an all-day
    /// master every RECURRENCE-ID is date-valued, but the caller-supplied
    /// `recurrence_id` may still carry a midnight time (`2026-05-20T00:00:00`)
    /// while the spliced override emitted a bare date (`20260520`). Comparing
    /// on the date alone makes the second edit of the same occurrence REPLACE
    /// its override instead of appending a duplicate — two VEVENTs sharing a
    /// UID+RECURRENCE-ID is a malformed resource that servers reject or resolve
    /// nondeterministically.
    static func recurrenceIdsMatch(_ a: String, _ b: String, allDay: Bool = false) -> Bool {
        let normalize = { (s: String) -> String in
            var t = s.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            // Tolerate the UTC suffix: `20260520T170000Z` ↔ `20260520T170000`.
            if t.hasSuffix("Z") { t = String(t.dropLast()) }
            if allDay { t = String(t.prefix(8)) }
            return t
        }
        return normalize(a) == normalize(b)
    }

    /// Parse the MASTER VEVENT's `DTSTART` plus **either** `DTEND` **or**
    /// `DURATION` (RFC 5545 §3.6.1 makes them alternatives, and forbids both in
    /// one VEVENT) and return the duration in seconds. With neither, the end is
    /// the one §3.6.1 implies (`ICSParser.impliedEndValue`): an all-day start lasts
    /// one day, and a timed start lasts no time, which is refused like any
    /// non-positive length. Returns nil if the start is missing/unparseable or no
    /// positive length can be recovered. Scoped to
    /// the master VEVENT so a VTIMEZONE's own `DTSTART:…T020000` lines can't be
    /// mistaken for the event's.
    ///
    /// ⚠️ The `DURATION` arm is not a nicety. This function read `DTEND` only
    /// until 2026-08-06, so an ordinary recurring master written by any other
    /// client as `DTSTART` + `DURATION:PT1H` returned nil,
    /// the split's successor builder threw, and — because the throw was classified by
    /// no terminal arm — the account's whole calendar lane wedged. Reuses
    /// `ICSParser.addDuration`, the tree's existing ISO-8601 duration parser,
    /// rather than adding a second grammar.
    ///
    /// `zones` is the resource's zone context. Throws the zone-naming refusal when a
    /// start or end is in a zone TabMail does not recognize.
    static func extractMasterDuration(from ics: String, zones: CalendarTimeZoneContext) throws -> TimeInterval? {
        var startDate: Date?
        var startLine: String?
        var endDate: Date?
        var durationValue: String?
        var hasEndOrDuration = false
        // The VEVENT's own lines only: a repeating alarm's `DURATION` is not the event's length.
        for line in masterTopLevelLines(ics) {
            if line.hasPrefix("DTSTART") {
                startDate = try parseICSDateTime(line, zones: zones)
                startLine = line
            } else if line.hasPrefix("DTEND") {
                hasEndOrDuration = true
                endDate = try parseICSDateTime(line, zones: zones)
            } else if line.hasPrefix("DURATION") {
                hasEndOrDuration = true
                guard let colonIdx = line.firstIndex(of: ":") else { continue }
                durationValue = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let s = startDate else { return nil }
        // Neither line at all: the end RFC 5545 implies. An end line that can't be read stays a refusal.
        if !hasEndOrDuration, let start = startLine.flatMap(icsProperty),
           let end = ICSParser.impliedEndValue(dtstartParams: start.params, dtstartValue: start.value) {
            endDate = try parseICSDateTime("DTEND\(start.params):\(end)", zones: zones)
        }
        // DTEND wins when present. A non-conforming resource carrying both then
        // keeps the pre-existing reading rather than silently changing meaning.
        if let e = endDate {
            guard e > s else { return nil }
            return e.timeIntervalSince(s)
        }
        guard let raw = durationValue,
              let e = ICSParser.addDuration(raw, to: s), e > s else { return nil }
        return e.timeIntervalSince(s)
    }

    /// Parse an ICS DTSTART/DTEND line into an absolute `Date`. Handles three
    /// forms: floating UTC (`DTSTART:20260520T170000Z`), TZID-qualified
    /// (`DTSTART;TZID=America/Los_Angeles:20260520T170000`), and date-only
    /// all-day (`DTSTART;VALUE=DATE:20260520` or `DTSTART:20260520`).
    /// Returns nil on any parse failure so callers can decide how to handle it.
    /// `zones` is the zone context of the resource the line is in (`.none` for a
    /// line from no resource). Throws the zone-naming refusal for a TZID TabMail
    /// does not recognize.
    static func parseICSDateTime(_ line: String, zones: CalendarTimeZoneContext) throws -> Date? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let header = String(line[..<colonIdx])  // e.g. "DTSTART;TZID=America/Los_Angeles"
        let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

        // Date-only (all-day) — emits midnight in the resource's effective tz.
        // ICS all-day uses VALUE=DATE; fall back on a bare 8-digit value too.
        let isDateOnly = ICSValueType.statesDate(header)
            || (value.count == 8 && !value.contains("T"))
        if isDateOnly {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            // All-day events are tz-agnostic at the data layer; interpret in
            // UTC for stable duration math.
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.date(from: value)
        }

        // UTC zulu form.
        if value.hasSuffix("Z") {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.date(from: value)
        }

        // TZID-qualified, or floating (no TZID).
        let tzid = extractTZID(from: header)
        let resolvedZone: TimeZone
        if let tzid {
            // A TZID TabMail does not recognize is refused rather than read in
            // the device timezone — a wrong absolute instant here would corrupt
            // `extractMasterDuration` (the new series would get a duration off
            // by the timezone offset) and every value written from it.
            resolvedZone = try zone(forTZID: tzid, zones: zones)
        } else {
            // No TZID → RFC 5545 "floating time": interpret in device-local.
            resolvedZone = .current
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = resolvedZone
        return fmt.date(from: value)
    }

    /// What a refusal of a zone TabMail does not recognize tells the user
    /// (`CalendarProviderError.unrecognizedTimeZone`): what was not done, and what to do instead.
    struct ZoneRefusal {
        let consequence: String
        let remedy: String

        /// Every write that changes an event.
        static let change = ZoneRefusal(
            consequence: "it did not change the event", remedy: "Change the time in your calendar app instead.")
        /// The delete of one occurrence (`deleteOccurrence`), on each route that needs the zone.
        static let occurrenceDelete = ZoneRefusal(
            consequence: "it can't delete one occurrence of it. Nothing was deleted",
            remedy: "The user can delete it in their calendar app.")
    }

    /// The zone a TZID names in a CalDAV resource whose zone context is `zones`,
    /// through `CalendarTimeZoneResolver`. Every CalDAV write that needs a stored
    /// zone reads it here, so a zone TabMail does not recognize is refused the same
    /// way on each: nothing is written, and the message names the zone and says what
    /// was not done (`refusal`).
    static func zone(forTZID tzid: String, zones: CalendarTimeZoneContext, refusal: ZoneRefusal = .change) throws -> TimeZone {
        guard let zone = CalendarTimeZoneResolver.zone(named: tzid, in: zones) else {
            BackgroundSyncLogger.logDebug("[CalDAV] unrecognized TZID '\(tzid)' — refusing to guess")
            throw CalendarProviderError.unrecognizedTimeZone(tzid, consequence: refusal.consequence, remedy: refusal.remedy)
        }
        return zone
    }

    /// Extract `TZID=Foo/Bar` from an ICS property header. Returns nil if no
    /// TZID parameter is present. Param order is unspecified in RFC 5545, so
    /// scan all `;`-separated parts.
    private static func extractTZID(from header: String) -> String? {
        for part in header.split(separator: ";") {
            let p = String(part)
            if p.uppercased().hasPrefix("TZID=") {
                return String(p.dropFirst("TZID=".count))
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Resolve a short or full eventId to its full URL using the calendar path.
    /// Short IDs (no `/`) come from the create flow (e.g., `tmXXX`). These must be
    /// resolved as `calendarURL/tmXXX.ics` — the same way createEvent builds the URL.
    /// Full hrefs (containing `/`) come from listEvents and are resolved normally.
    ///
    /// An id that still carries a `#` is refused: a URL drops its fragment from the request,
    /// so an occurrence id (`CalDAVOccurrences.OccurrenceId`) would address its whole
    /// series' resource. Every caller splits an occurrence id into its series href first.
    private func resolveEventURL(_ eventId: String, calendarId: String) throws -> URL {
        guard !eventId.contains(CalDAVOccurrences.OccurrenceId.separator) else {
            throw CalendarProviderError.notSupported(
                "'\(eventId)' names one occurrence of a repeating event, not a calendar resource; refusing to send a request for the whole series")
        }
        if eventId.contains("/") {
            return try resolveURL(eventId)
        }
        // Short ID — build URL the same way createEvent does: calendar + id.ics
        let calURL = try resolveURL(calendarId)
        let filename = eventId.hasSuffix(".ics") ? eventId : "\(eventId).ics"
        return calURL.appendingPathComponent(filename)
    }

    /// Resolve a calendarId or eventId (which is a path) to a full URL.
    /// Resolves against calendarHomeURL (not serverBaseURL) because iCloud redirects
    /// caldav.icloud.com → pXX-caldav.icloud.com. The calendarHomeURL has the correct
    /// post-redirect host. Using serverBaseURL would hit the pre-redirect host, and
    /// URLSession's 301/302 handling changes REPORT/PUT/DELETE to GET (losing the body).
    ///
    /// 🚨 **R13-U1 — ORIGIN CONTAINMENT. The returned URL's origin is checked, not
    /// assumed.** `CalDAVClient.setAuthHeader` attaches `Authorization: Basic …`
    /// UNCONDITIONALLY, with no host check and no `URLSession` delegate, so whatever
    /// origin this function returns is an origin the account's password is sent to.
    /// Two shapes reach here from a string this actor did not mint:
    ///   * an absolute `http(s)://…` — returned VERBATIM by the branch below; and
    ///   * an RFC 3986 **network-path reference** (`//host/path`), which is not
    ///     caught by the `hasPrefix` test yet takes its **authority from the string**
    ///     when resolved against a base, so `//attacker.example/x` resolves to
    ///     `https://attacker.example/x`.
    /// Both are reachable with an agent-authored `event_id`: the three calendar
    /// tools accept a non-numeric `event_id` verbatim (see the note in
    /// `CalendarEventReadTool`), and `resolveEventURL` routes anything containing
    /// `/` straight here.
    ///
    /// The check is **scheme + host + port only, never path**. Path containment
    /// would be wrong: on iCloud a calendar shared by another user lives under the
    /// OWNER's principal path (`/<their-id>/calendars/…`), outside our
    /// `calendarHomeURL`, and rejecting that would break shared calendars. Both
    /// configured origins are accepted because `calendarHomeURL` is the
    /// post-redirect host and a server may still hand back hrefs on the
    /// pre-redirect `serverBaseURL` host; both come from account configuration and
    /// neither is agent-authored.
    ///
    /// ⚠️ MIRROR IMAGE, deliberately avoided: this does NOT reject an id merely for
    /// being unfamiliar, and it does NOT normalize or rewrite the URL. Rewriting a
    /// foreign origin to ours would send the request somewhere the caller did not
    /// name; silently dropping it would lose the intention. It throws
    /// `CalendarProviderError.notSupported`, which `isCalendarUnsupportedError`
    /// already claims as a terminal drain arm — the same disposition
    /// `73be05616` gave its three other unexecutable-op guards. A request that can
    /// never be issued safely can never become issuable by retrying it.
    private func resolveURL(_ path: String) throws -> URL {
        let resolved: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://"),
           let url = URL(string: path) {
            resolved = url
        } else if let url = URL(string: path, relativeTo: calendarHomeURL)?.absoluteURL {
            // Resolve against calendarHomeURL (has correct post-redirect host for iCloud)
            resolved = url
        } else {
            resolved = calendarHomeURL.appendingPathComponent(path)
        }

        guard Self.sameOrigin(resolved, calendarHomeURL) || Self.sameOrigin(resolved, serverBaseURL) else {
            throw CalendarProviderError.notSupported(
                "CalDAV path '\(path)' resolves to a different origin than this account's calendar server; refusing to send the account credential there")
        }
        return resolved
    }

    /// Scheme + host + port equality, with the default port filled in so
    /// `https://h/x` and `https://h:443/x` compare equal. Host and scheme compare
    /// case-insensitively per RFC 3986 §3.1/§3.2.2.
    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            if let p = url.port { return p }
            switch url.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
        guard let lHost = lhs.host?.lowercased(), let rHost = rhs.host?.lowercased(), lHost == rHost else { return false }
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased() else { return false }
        return port(lhs) == port(rhs)
    }

    /// Format date as CalDAV UTC: YYYYMMDDTHHMMSSZ
    private func formatUTCCalDAV(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    /// Escape XML special characters.
    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
