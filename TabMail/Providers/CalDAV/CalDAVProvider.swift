/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// CalDAV calendar provider conforming to CalendarProvider protocol.
/// Uses CalDAVClient for HTTP operations and ICSParser for response parsing.
actor CalDAVProvider: CalendarProvider {
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
                print("[CalDAV] Skipping non-VEVENT collection: \(resp.properties["displayname"] ?? resp.href) (components: \(components))")
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

        print("[CalDAV] Listed \(calendars.count) calendars (\(calendars.filter { $0.accessRole == "owner" }.count) writable)")
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
        let calURL = resolveURL(calendarId)

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
            let parsed = ICSParser.parse(icsText: icsText, resourceHref: resp.href, etag: resp.etag)
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

        print("[CalDAV] listEvents: \(events.count) events from \(calendarId)")
        return events
    }

    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
        let eventURL = resolveEventURL(eventId, calendarId: calendarId)

        let (data, response) = try await client.get(url: eventURL)
        guard let icsText = String(data: data, encoding: .utf8), !icsText.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }

        let etag = response.value(forHTTPHeaderField: "ETag")
        if let etag {
            etagCache[eventId] = etag
        }

        let events = ICSParser.parse(icsText: icsText, resourceHref: eventId, etag: etag)
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
        let calURL = resolveURL(calendarId)
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
        let eventURL = resolveEventURL(eventId, calendarId: calendarId)

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

        let mergedICS = Self.mergePatchIntoICS(existingICS, patch: event)
        // No ETag ⇒ `.unconditional`, NEVER `.ifNoneMatchAny`. The GET above
        // returned a non-empty body for this exact URL, so the resource
        // PROVABLY exists; `If-None-Match: *` asserts it does NOT, which
        // contradicts what we just observed and is a guaranteed 412 rather than
        // a conservative choice. RFC 4791 says servers SHOULD return an ETag,
        // not MUST, and `CalendarSetupView.connectCalDAV()` accepts an
        // arbitrary user-entered server URL — so the no-ETag branch is reachable
        // and is not an iCloud-only hypothetical. See `revertMasterCap` below
        // for the same defect at the rollback site.
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
        let eventURL = resolveEventURL(eventId, calendarId: calendarId)
        let (_, _) = try await client.delete(url: eventURL)
        etagCache.removeValue(forKey: eventId)
        print("[CalDAV] Deleted event \(eventId)")
    }

    /// Single-occurrence override (this_only). CalDAV represents overrides as
    /// additional VEVENT blocks in the SAME .ics resource sharing the master's
    /// UID, distinguished by a RECURRENCE-ID property. We GET the resource,
    /// splice (or replace) an override VEVENT, PUT it back atomically.
    func updateOccurrence(
        calendarId: String,
        eventId: String,
        recurrenceId: String,
        event: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        let eventURL = resolveEventURL(eventId, calendarId: calendarId)

        // 1. GET current ICS + ETag
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let masterICS = String(data: data, encoding: .utf8), !masterICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        // 2. Extract the master's UID for the override.
        let uid = eventURL.deletingPathExtension().lastPathComponent
        let masterUID = Self.extractUID(from: masterICS) ?? uid

        // 3. Build a "full" patch that inherits every display-relevant field
        //    from the master and overrides only what the LLM is changing.
        //    RFC 5545 §3.8.4.1 says properties absent from an override
        //    inherit from the master, but iCloud / Apple Calendar / many
        //    CalDAV clients DISPLAY only the fields present in the override
        //    VEVENT — so a sparse override (just DTSTART/DTEND) makes the
        //    occurrence look like an empty event with no title/details.
        //    Same principle as our defensive PATCH everywhere else: send
        //    the full state, not the delta. Extracts directly from the ICS
        //    we already have in hand (no extra round trip).
        var inheritedPatch = event
        if inheritedPatch.summary == nil {
            inheritedPatch.summary = Self.extractScalar(from: masterICS, key: "SUMMARY")
        }
        if inheritedPatch.location == nil {
            inheritedPatch.location = Self.extractScalar(from: masterICS, key: "LOCATION")
        }
        if inheritedPatch.description == nil {
            inheritedPatch.description = Self.extractScalar(from: masterICS, key: "DESCRIPTION")
        }
        if inheritedPatch.transparency == nil {
            inheritedPatch.transparency = Self.extractScalar(from: masterICS, key: "TRANSP")
        }
        if inheritedPatch.attendees == nil {
            let masterAttendees = Self.extractAttendees(from: masterICS)
            if !masterAttendees.isEmpty {
                inheritedPatch.attendees = masterAttendees
            }
        }

        // 4. Build the override VEVENT block (no VCALENDAR wrapper).
        //    RFC 5545 §3.8.4.4: RECURRENCE-ID's value type MUST match the
        //    master's DTSTART value type — classify the master's DTSTART
        //    (all-day / zoned / UTC / floating) and emit a matching override.
        //    Also extract the master's ORGANIZER: RFC 5545 §3.8.4.3 requires
        //    every VEVENT that carries ATTENDEE to also carry ORGANIZER, and
        //    iCloud's CalDAV enforces this strictly — without it, a PUT that
        //    adds an attendee to the override fails with HTTP 403 (empty body).
        let masterKind = Self.masterDTStartKind(from: masterICS)
        let masterOrganizerLine = Self.masterVEventLines(from: masterICS)
            .first(where: { $0.uppercased().hasPrefix("ORGANIZER") })
        let overrideBlock = Self.buildOverrideVEvent(
            patch: inheritedPatch, uid: masterUID, recurrenceId: recurrenceId,
            kind: masterKind, organizerLine: masterOrganizerLine
        )

        // 4. Splice it into the ICS — replace any pre-existing override with
        //    the same RECURRENCE-ID, otherwise append before END:VCALENDAR.
        let updatedICS = Self.spliceOrReplaceOverride(
            ics: masterICS, recurrenceId: recurrenceId, kind: masterKind, newOverrideBlock: overrideBlock
        )

        // 5. PUT back — atomic at the CalDAV resource level (one HTTP call).
        //    No ETag ⇒ `.unconditional`: step 1's GET proved this resource
        //    exists (we spliced the override into the body it returned), so
        //    `If-None-Match: *` would assert the opposite of what we observed.
        _ = try await client.put(
            url: eventURL, body: updatedICS,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)
        etagCache.removeValue(forKey: eventId)

        return GCalEvent(
            id: eventId, summary: event.summary, location: event.location,
            description: event.description, start: nil, end: nil, attendees: nil,
            organizer: nil, recurrence: nil, transparency: event.transparency,
            status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// Series split (this_and_following). Cap the master's RRULE in-place via a
    /// string-level UNTIL replacement (one PUT on the existing .ics), then
    /// create a NEW .ics with the new series. If the new-series PUT fails,
    /// attempt to revert the master cap.
    func splitSeries(
        calendarId: String,
        eventId: String,
        recurrenceId: String,
        patch: GCalEventInput,
        sendUpdates: String
    ) async throws -> GCalEvent {
        let eventURL = resolveEventURL(eventId, calendarId: calendarId)

        // 1. GET master ICS + ETag
        let (data, getResponse) = try await client.get(url: eventURL)
        guard let masterICS = String(data: data, encoding: .utf8), !masterICS.isEmpty else {
            throw CalDAVError.parseError("Empty response for event \(eventId)")
        }
        let etag = getResponse.value(forHTTPHeaderField: "ETag")

        // 2. Parse the original RRULE so we can build the capped variant + the
        //    new-series RRULE (without UNTIL/COUNT).
        guard let originalRRule = Self.extractRRule(from: masterICS) else {
            throw CalendarProviderError.notSupported("Master event has no RRULE; can't split.")
        }
        // RFC 5545 §3.3.10: the UNTIL value type must match DTSTART's. If the
        // master's DTSTART is a bare DATE (all-day), UNTIL must be a bare DATE.
        let masterIsAllDay = Self.icsIsAllDay(masterICS)
        guard let untilValue = GoogleCalendarProvider.googleUntilString(beforeNaiveISO: recurrenceId, allDay: masterIsAllDay) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let cappedRRule = GoogleCalendarProvider.replaceOrAppendUntil(in: originalRRule, untilValue: untilValue)
        let cappedICS = Self.replaceRRule(in: masterICS, newRRule: cappedRRule)

        // 3. PUT capped master back. No ETag ⇒ `.unconditional`: step 1's GET
        //    proved the master resource exists (its ICS is what we just capped),
        //    so `If-None-Match: *` would assert the opposite. It is also the
        //    precondition `revertMasterCap` must later be able to undo — a cap
        //    that 412s never happens, but a cap that lands under a precondition
        //    the revert cannot reproduce is the split-rollback defect again.
        let (_, capResponse) = try await client.put(
            url: eventURL, body: cappedICS,
            precondition: etag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)
        // The entity tag the server assigned to the body we JUST wrote. This is
        // the only witness `revertMasterCap` can use to make its rollback
        // conditional: `.ifMatch(capETag)` overwrites our own capped write and
        // REFUSES to overwrite anything a concurrent editor has put there since.
        // `etag` (step 1's GET tag) is already stale by this line, and
        // `etagCache` is cleared immediately below for exactly that reason, so
        // the response header is the only place this value exists.
        //
        // RFC 4791 §5.3.4 says a server SHOULD return an ETag on a successful
        // PUT, not MUST. When it does not, the rollback falls back to
        // `.unconditional` — the round-9 behaviour, byte-identical for that
        // server population — because the alternative (refusing to roll back at
        // all) leaves the master capped with no successor, which is strictly
        // worse than a best-effort overwrite. Note it must NOT fall back to
        // `.ifNoneMatchAny`: that asserts the master is absent at a resource we
        // just proved present, which is the round-9 bug (`MIS-005`'s chain).
        let capETag = capResponse.value(forHTTPHeaderField: "ETag")
        etagCache.removeValue(forKey: eventId)

        // 4. Build new series and PUT to a .ics resource. The UID/filename is
        //    DETERMINISTIC (derived from master id + recurrence_id) so a retry
        //    after a lost ACK on the PUT below re-targets the SAME resource
        //    instead of creating a duplicate series at a fresh random URL.
        //    ⚠ That PUT is CREATE-ONLY (`.ifNoneMatchAny`), not an overwrite —
        //    this comment claimed "unconditional PUT → overwrite" until
        //    2026-08-05, which the code has never done. The consequence is
        //    deliberate and unchanged here: a retry after a lost ACK gets 412
        //    rather than silently replacing the successor series someone may
        //    have edited in the meantime, and the 412 routes to the rollback
        //    below. Do not "fix" the comment by widening the precondition —
        //    that is a behaviour change with its own overwrite risk.
        let newUid = GoogleCalendarProvider.deterministicSplitEventId(masterId: eventId, recurrenceId: recurrenceId)
        let rruleWithoutCap = GoogleCalendarProvider.stripUntilAndCount(originalRRule)
        let newSeriesInput: GCalEventInput
        do {
            newSeriesInput = try Self.buildNewSeriesInput(
                masterICS: masterICS, patch: patch,
                newStartNaiveISO: recurrenceId,
                newRRule: rruleWithoutCap
            )
        } catch {
            // Couldn't construct the new series — revert the master cap before
            // bailing so the calendar isn't left truncated with no replacement.
            try await Self.revertMasterCap(client: client, eventURL: eventURL,
                                           originalICS: masterICS,
                                           capETag: capETag, cause: error)
        }
        let calURL = resolveURL(calendarId)
        let newEventURL = calURL.appendingPathComponent("\(newUid).ics")
        let newICS = newSeriesInput.toICS(uid: newUid)

        do {
            _ = try await client.put(
                url: newEventURL, body: newICS, precondition: .ifNoneMatchAny)
        } catch CalDAVError.preconditionFailed {
            // 412 from the CREATE-ONLY successor PUT means something already
            // occupies the DETERMINISTIC successor URL. The overwhelmingly
            // likely cause is a LOST ACK: a previous attempt's successor PUT
            // committed, its response never reached us, the queue retried, and
            // this attempt has just re-capped the master and collided with its
            // own earlier write.
            //
            // Neither of the two unconditional responses is acceptable there:
            //  - rolling back un-caps the master while a live open-ended
            //    successor still exists ⇒ every occurrence after the split point
            //    is duplicated on the user's calendar;
            //  - rethrowing wedges the account. `preconditionFailed` is a
            //    dedicated `CalDAVError` case that
            //    `AccountManagerCalendarQueue.isCalendarBadRequestError` (which
            //    only matches `.httpError`) does not classify, so the op lands
            //    on the "transient — always retry" arm and its account goes into
            //    `failedAccounts`, skipping every later calendar op on that
            //    account, forever. That is the wedge corollary of the
            //    never-drop-a-user-intention rule, not a recoverable edge.
            //
            // So DISCRIMINATE rather than assume. Read the resource back and
            // require POSITIVE evidence that it is the successor THIS call
            // derived (its ICS carries our deterministic UID). Only that is
            // provider-authoritative "already done". A probe that throws, 404s,
            // returns an unparseable body, or names a different UID keeps the
            // pre-existing rollback — absence of evidence never becomes
            // permission (the queue's exit-2 rule: "we could not determine" is
            // not "the provider says it is complete").
            //
            // The successor PUT itself stays `.ifNoneMatchAny`. Widening it to
            // an overwrite would silently replace a series the user may have
            // edited; that direction is deliberately held (`MIS-026`).
            guard await Self.successorIsOurs(client: client, url: newEventURL, uid: newUid) else {
                try await Self.revertMasterCap(client: client, eventURL: eventURL,
                                               originalICS: masterICS,
                                               capETag: capETag,
                                               cause: CalDAVError.preconditionFailed)
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[CalDAV] splitSeries: successor \(newUid) already exists and is ours — treating the split as already complete (lost ACK)")
            }
        } catch {
            // Revert the master cap so the calendar isn't left truncated with
            // no replacement series.
            try await Self.revertMasterCap(client: client, eventURL: eventURL,
                                           originalICS: masterICS,
                                           capETag: capETag, cause: error)
        }

        return GCalEvent(
            id: newEventURL.path, summary: newSeriesInput.summary, location: newSeriesInput.location,
            description: newSeriesInput.description, start: nil, end: nil, attendees: nil,
            organizer: nil, recurrence: [rruleWithoutCap], transparency: newSeriesInput.transparency,
            status: "confirmed", htmlLink: nil, created: nil, updated: nil
        )
    }

    /// Roll the master resource back to `originalICS` after a `splitSeries`
    /// step failed. Always throws — never returns:
    ///  - revert succeeds → rethrows `cause` (the split failed, but the
    ///    calendar is back in a consistent state, so the queue can retry).
    ///  - revert ALSO fails → throws `CalDAVError.inconsistentState` so the
    ///    queue surfaces a clear "needs manual attention" message instead of
    ///    silently leaving the master capped with no successor series.
    /// The revert PUT carries `.ifMatch(capETag)` where `capETag` is the entity
    /// tag the CAP PUT's own 2xx response returned — by construction the tag of
    /// the body we ourselves just stored. That is what makes the rollback safe
    /// AND targeted: it overwrites our own write, and it refuses to overwrite a
    /// concurrent editor's, which an unconditional PUT would silently destroy
    /// (a lost user edit is not recoverable by syncing).
    ///
    /// A 412 here therefore means "the master is no longer what we capped", and
    /// the correct response is the failure arm below (`inconsistentState`, which
    /// the queue retires with a user-visible message), NOT a retry loop.
    ///
    /// `capETag == nil` (a server that returns no ETag on PUT — RFC 4791 §5.3.4
    /// says SHOULD, not MUST) falls back to `.unconditional`, the round-9
    /// behaviour. It must never fall back to `.ifNoneMatchAny`: that asserts
    /// absence at a resource we just proved present, which is the round-9 bug
    /// this function was rewritten to kill.
    ///
    /// ⚠ This comment said "unconditional (`etag: nil`)" from the day it was
    /// written until 2026-08-05, and the code did the OPPOSITE of what it
    /// claimed: `etag: nil` was the *assert-absence* mode (`If-None-Match: *`),
    /// so a compliant server answered 412 to every revert of a master resource
    /// that — by construction, we had just PUT to it — existed. The rollback
    /// could never succeed and this function always took its own failure arm.
    /// `CalDAVPutPrecondition` now makes the three states distinct so the
    /// comment and the request cannot drift apart again.
    private static func revertMasterCap(
        client: CalDAVClient, eventURL: URL, originalICS: String,
        capETag: String?, cause: Error
    ) async throws -> Never {
        do {
            _ = try await client.put(
                url: eventURL, body: originalICS,
                precondition: capETag.map(CalDAVPutPrecondition.ifMatch) ?? .unconditional)
        } catch {
            // The revert PUT itself failed — the master is capped with no
            // replacement. Surface loudly so the queue/LLM/user knows.
            print("[CalDAV] splitSeries: REVERT FAILED — master is capped with no successor series. revertError=\(error) cause=\(cause)")
            throw CalDAVError.inconsistentState(
                "Calendar event split failed and could not be rolled back — the recurring series may be cut short with no replacement. Please check the event in your calendar app. (cause: \(cause); revert error: \(error))"
            )
        }
        // Revert succeeded — the calendar is back to consistent state. Surface
        // the ORIGINAL failure (thrown outside the do/catch so it isn't caught
        // by our own revert handler) so the queue can retry the split cleanly.
        print("[CalDAV] splitSeries: reverted master cap after failure: \(cause)")
        throw cause
    }

    /// POSITIVE evidence that the resource now occupying `url` is the successor
    /// series THIS split derived — i.e. the server serves it and its master
    /// VEVENT carries `uid`, the deterministic id built from
    /// (master id, recurrence id).
    ///
    /// Every other outcome answers `false`: a throw, a 404, a body that will not
    /// decode, a body with no master UID, or a UID that is somebody else's. The
    /// caller must treat `false` as "roll back", so this function's failure
    /// direction is the pre-existing behaviour and a probe outage can never
    /// manufacture a success. Deliberately `async` but not `throws` for that
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
                print("[CalDAV] splitSeries: successor probe failed for \(url.path) — rolling back. error=\(error)")
            }
            return false
        }
    }

    // MARK: - ICS Helpers (recurring edits)

    /// Return the lines of the MASTER VEVENT in a CalDAV `.ics` resource — the
    /// first `BEGIN:VEVENT…END:VEVENT` block that has NO `RECURRENCE-ID` line
    /// (override VEVENTs carry one; the series master does not).
    ///
    /// CRITICAL: a CalDAV resource typically leads with a `VTIMEZONE` block
    /// whose nested `STANDARD`/`DAYLIGHT` subcomponents have their OWN
    /// `DTSTART` and `RRULE` lines (the timezone's DST rule). A naive
    /// whole-resource scan for the "first RRULE/DTSTART" would pick up the
    /// timezone's rule — catastrophic for `splitSeries` (it would cap the
    /// series using `FREQ=YEARLY;BYMONTH=…`). Every VEVENT-scoped extractor
    /// MUST go through this so it only ever sees the master event's lines.
    static func masterVEventLines(from ics: String) -> [String] {
        let all = Self.icsLines(ics)
        var i = 0
        while i < all.count {
            guard all[i] == "BEGIN:VEVENT" else { i += 1; continue }
            var block: [String] = []
            var hasRecurrenceId = false
            i += 1
            while i < all.count && all[i] != "END:VEVENT" {
                if all[i].hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
                block.append(all[i])
                i += 1
            }
            i += 1  // step past END:VEVENT
            // The master is the VEVENT with no RECURRENCE-ID. Override blocks
            // (which carry one) are skipped — keep scanning.
            if !hasRecurrenceId { return block }
        }
        return []
    }

    /// Pull the UID line from the MASTER VEVENT. Scoped via `masterVEventLines`
    /// so a VTIMEZONE or override block can't shadow it.
    static func extractUID(from ics: String) -> String? {
        for line in Self.masterVEventLines(from: ics) {
            if line.hasPrefix("UID:") {
                return String(line.dropFirst("UID:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pull the RRULE line (full text, incl. the `RRULE:` prefix) from the
    /// MASTER VEVENT. Scoped so a VTIMEZONE's DST RRULE can't be returned.
    static func extractRRule(from ics: String) -> String? {
        for line in Self.masterVEventLines(from: ics) {
            if line.hasPrefix("RRULE:") { return line }
        }
        return nil
    }

    /// True when the MASTER VEVENT's DTSTART is a bare DATE (all-day event).
    /// RFC 5545: `DTSTART;VALUE=DATE:20260520` or a bare 8-digit value with no
    /// `T`. Scoped to the master VEVENT so a VTIMEZONE's `DTSTART:…T020000`
    /// can't mislead the check.
    static func icsIsAllDay(_ ics: String) -> Bool {
        for line in Self.masterVEventLines(from: ics) {
            guard line.hasPrefix("DTSTART") else { continue }
            let upper = line.uppercased()
            if upper.contains("VALUE=DATE") { return true }
            // Bare form: "DTSTART:20260520" (8 digits, no T after the colon).
            if let colonIdx = line.firstIndex(of: ":") {
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                return value.count == 8 && !value.contains("T")
            }
            return false
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

    /// Classify the master VEVENT's DTSTART. Scoped via `masterVEventLines` so
    /// a leading VTIMEZONE's own DTSTART can't be mistaken for the event's.
    static func masterDTStartKind(from ics: String) -> MasterDTStartKind {
        for line in Self.masterVEventLines(from: ics) {
            guard line.uppercased().hasPrefix("DTSTART") else { continue }
            guard let colonIdx = line.firstIndex(of: ":") else { return .floating }
            let params = line[..<colonIdx].split(separator: ";").dropFirst()  // skip "DTSTART"
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            // All-day: a VALUE=DATE param, or a bare 8-digit value with no time.
            if params.contains(where: { $0.uppercased() == "VALUE=DATE" })
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
        return .floating
    }

    /// Split an ICS resource into LOGICAL lines, performing RFC 5545 line
    /// unfolding first. Continuation lines (starting with a space or tab) are
    /// stitched onto the prior line, then the result is split on LF.
    /// Without unfolding, a long DESCRIPTION/LOCATION would be silently
    /// truncated when extracted (because the bytes past column 75 are on the
    /// next physical line). Tolerates CRLF and bare LF.
    private static func icsLines(_ ics: String) -> [String] {
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
    private static func physicalICSLines(_ ics: String) -> [String] {
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
        let lines = Self.physicalICSLines(ics)
        var output: [String] = []
        var replaced = false
        var i = 0
        while i < lines.count {
            guard lines[i] == "BEGIN:VEVENT", !replaced else {
                output.append(lines[i]); i += 1; continue
            }
            // Buffer the whole VEVENT block — we can't tell master from
            // override until we've seen (or not seen) a RECURRENCE-ID line.
            var block: [String] = [lines[i]]
            var hasRecurrenceId = false
            i += 1
            while i < lines.count && lines[i] != "END:VEVENT" {
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

    // MARK: - Non-recurring PATCH merge

    /// Apply a partial patch to an existing CalDAV resource. CalDAV PUT is a
    /// full-resource replace — sending a freshly-built ICS containing only the
    /// patched fields produces a VEVENT with no DTSTART/SUMMARY/etc., which
    /// strict servers (iCloud) reject with 403 and lax ones silently corrupt.
    /// This merge surgically writes the patched fields into the MASTER VEVENT
    /// of the existing ICS, leaving VTIMEZONE, ORGANIZER, RECURRENCE-ID
    /// overrides, and every other field untouched.
    ///
    /// NOT used for: occurrence overrides (`spliceOrReplaceOverride`) or
    /// split-series (`splitSeries`). Those paths have their own ICS surgery.
    static func mergePatchIntoICS(_ ics: String, patch: GCalEventInput) -> String {
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
        if let recurrence = patch.recurrence,
           let rrule = recurrence.first(where: { $0.uppercased().hasPrefix("RRULE:") }) {
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
        // (all-day / zoned / utc / floating) so RFC 5545 §3.8.4.4 is preserved.
        let kind = masterDTStartKind(from: result)
        if let dtstart = formatDTLine(name: "DTSTART", patch: patch, isStart: true, kind: kind) {
            result = replaceOrAppendInMasterVEvent(in: result, propertyKey: "DTSTART", newLine: dtstart)
        }
        if let dtend = formatDTLine(name: "DTEND", patch: patch, isStart: false, kind: kind) {
            result = replaceOrAppendInMasterVEvent(in: result, propertyKey: "DTEND", newLine: dtend)
        }
        if let attendees = patch.attendees {
            result = replaceAttendeesInMasterVEvent(in: result, attendees: attendees)
        }
        return result
    }

    /// Replace the first line in the MASTER VEVENT whose property name matches
    /// `propertyKey` (`<KEY>:` or `<KEY>;…`), preserving folded continuation
    /// lines being dropped along with it. If no match exists, insert `newLine`
    /// just before `END:VEVENT`. Scoped to the master block (no RECURRENCE-ID).
    static func replaceOrAppendInMasterVEvent(in ics: String, propertyKey: String, newLine: String) -> String {
        let prefix1 = "\(propertyKey):"
        let prefix2 = "\(propertyKey);"
        let lines = physicalICSLines(ics)
        var output: [String] = []
        var i = 0
        var handledMaster = false
        while i < lines.count {
            guard lines[i] == "BEGIN:VEVENT", !handledMaster else {
                output.append(lines[i]); i += 1; continue
            }
            var block: [String] = [lines[i]]
            var hasRecurrenceId = false
            i += 1
            while i < lines.count && lines[i] != "END:VEVENT" {
                if lines[i].hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
                block.append(lines[i])
                i += 1
            }
            if i < lines.count { block.append(lines[i]); i += 1 }

            if !hasRecurrenceId {
                var replaced = false
                var rewritten: [String] = []
                var j = 0
                while j < block.count {
                    let line = block[j]
                    if !replaced && (line.hasPrefix(prefix1) || line.hasPrefix(prefix2)) {
                        rewritten.append(newLine)
                        replaced = true
                        j += 1
                        while j < block.count, let first = block[j].first, first == " " || first == "\t" {
                            j += 1
                        }
                        continue
                    }
                    rewritten.append(line)
                    j += 1
                }
                if !replaced {
                    // Insert before END:VEVENT, or at the end if missing.
                    if let endIdx = rewritten.firstIndex(of: "END:VEVENT") {
                        rewritten.insert(newLine, at: endIdx)
                    } else {
                        rewritten.append(newLine)
                    }
                }
                block = rewritten
                handledMaster = true
            }
            output.append(contentsOf: block)
        }
        return output.joined(separator: "\r\n")
    }

    /// Remove the first matching line (and its folded continuations) from the
    /// MASTER VEVENT. Used to clear LOCATION/DESCRIPTION when the patch passes
    /// an empty string for those fields.
    static func removeFromMasterVEvent(in ics: String, propertyKey: String) -> String {
        let prefix1 = "\(propertyKey):"
        let prefix2 = "\(propertyKey);"
        let lines = physicalICSLines(ics)
        var output: [String] = []
        var i = 0
        var handledMaster = false
        while i < lines.count {
            guard lines[i] == "BEGIN:VEVENT", !handledMaster else {
                output.append(lines[i]); i += 1; continue
            }
            var block: [String] = [lines[i]]
            var hasRecurrenceId = false
            i += 1
            while i < lines.count && lines[i] != "END:VEVENT" {
                if lines[i].hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
                block.append(lines[i])
                i += 1
            }
            if i < lines.count { block.append(lines[i]); i += 1 }

            if !hasRecurrenceId {
                var rewritten: [String] = []
                var j = 0
                var removed = false
                while j < block.count {
                    let line = block[j]
                    if !removed && (line.hasPrefix(prefix1) || line.hasPrefix(prefix2)) {
                        removed = true
                        j += 1
                        while j < block.count, let first = block[j].first, first == " " || first == "\t" {
                            j += 1
                        }
                        continue
                    }
                    rewritten.append(line)
                    j += 1
                }
                block = rewritten
                handledMaster = true
            }
            output.append(contentsOf: block)
        }
        return output.joined(separator: "\r\n")
    }

    /// Replace ALL ATTENDEE lines in the MASTER VEVENT with the supplied list.
    /// The queue resolves attendee deltas (add_attendees / remove_attendees)
    /// against the existing attendee list BEFORE calling updateEvent, so by
    /// the time we get here `attendees` is the desired final list — a full
    /// replace correctly applies that.
    static func replaceAttendeesInMasterVEvent(in ics: String, attendees: [(email: String, name: String?)]) -> String {
        let lines = physicalICSLines(ics)
        var output: [String] = []
        var i = 0
        var handledMaster = false
        while i < lines.count {
            guard lines[i] == "BEGIN:VEVENT", !handledMaster else {
                output.append(lines[i]); i += 1; continue
            }
            var block: [String] = [lines[i]]
            var hasRecurrenceId = false
            i += 1
            while i < lines.count && lines[i] != "END:VEVENT" {
                if lines[i].hasPrefix("RECURRENCE-ID") { hasRecurrenceId = true }
                block.append(lines[i])
                i += 1
            }
            if i < lines.count { block.append(lines[i]); i += 1 }

            if !hasRecurrenceId {
                var rewritten: [String] = []
                var j = 0
                while j < block.count {
                    let line = block[j]
                    if line.hasPrefix("ATTENDEE;") || line.hasPrefix("ATTENDEE:") {
                        j += 1
                        while j < block.count, let first = block[j].first, first == " " || first == "\t" {
                            j += 1
                        }
                        continue
                    }
                    rewritten.append(line)
                    j += 1
                }
                let attendeeLines = attendees.map { a -> String in
                    let cn = (a.name ?? a.email).replacingOccurrences(of: "\"", with: "'")
                    return "ATTENDEE;CN=\"\(cn)\";ROLE=REQ-PARTICIPANT:mailto:\(a.email)"
                }
                if let endIdx = rewritten.firstIndex(of: "END:VEVENT") {
                    rewritten.insert(contentsOf: attendeeLines, at: endIdx)
                } else {
                    rewritten.append(contentsOf: attendeeLines)
                }
                block = rewritten
                handledMaster = true
            }
            output.append(contentsOf: block)
        }
        return output.joined(separator: "\r\n")
    }

    /// Build a DTSTART / DTEND line for the merge path, re-using the master's
    /// existing value type so the line we substitute in keeps the same form
    /// (all-day / zoned / utc / floating).
    private static func formatDTLine(name: String, patch: GCalEventInput, isStart: Bool, kind: MasterDTStartKind) -> String? {
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
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.timeZone = TimeZone(identifier: chosenTz) ?? .current
            return "\(name);TZID=\(chosenTz):\(fmt.string(from: date))"
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
    /// in `GCalEventInputICS.toICS` — duplicated here because that file's
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

    /// Build a single VEVENT block (no VCALENDAR wrapper) for use as an
    /// occurrence override. Shares the master's UID and adds RECURRENCE-ID.
    /// Only the fields present in `patch` are emitted; unspecified fields fall
    /// through to the master's values at expansion time.
    ///
    /// `kind` MUST reflect the master's DTSTART representation — RFC 5545
    /// §3.8.4.4 requires RECURRENCE-ID (and, for a moved occurrence, DTSTART)
    /// to use the SAME value type as the master's DTSTART. So an all-day master
    /// yields `RECURRENCE-ID;VALUE=DATE:…`, a zoned master `…;TZID=…:…`, a UTC
    /// master `…:…Z`, a floating master a bare local time. The override is
    /// spliced into the master's existing VCALENDAR, which already carries the
    /// matching VTIMEZONE for the zoned case.
    static func buildOverrideVEvent(patch: GCalEventInput, uid: String, recurrenceId: String, kind: MasterDTStartKind, organizerLine: String? = nil) -> String {
        let dtstampFmt = DateFormatter()
        dtstampFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dtstampFmt.timeZone = TimeZone(identifier: "UTC")

        // Compact the naive recurrence_id ("2026-05-20T17:00:00" → "20260520T170000").
        // It is the occurrence's wall-clock time; preserve the digits and attach
        // the type marker that matches the master.
        let ridDigits = recurrenceId
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")

        var lines: [String] = []
        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(uid)")
        lines.append("DTSTAMP:\(dtstampFmt.string(from: Date()))")

        switch kind {
        case .allDay:
            lines.append("RECURRENCE-ID;VALUE=DATE:\(String(ridDigits.prefix(8)))")
        case .zoned(let tzid):
            lines.append("RECURRENCE-ID;TZID=\(tzid):\(ridDigits)")
        case .utc:
            lines.append("RECURRENCE-ID:\(ridDigits.uppercased().hasSuffix("Z") ? ridDigits : ridDigits + "Z")")
        case .floating:
            lines.append("RECURRENCE-ID:\(ridDigits)")
        }

        if let summary = patch.summary, !summary.isEmpty {
            lines.append("SUMMARY:\(summary)")
        }
        if let location = patch.location, !location.isEmpty {
            lines.append("LOCATION:\(location)")
        }
        if let description = patch.description, !description.isEmpty {
            lines.append("DESCRIPTION:\(description)")
        }
        if let transp = patch.transparency {
            lines.append("TRANSP:\(transp.uppercased())")
        }
        if let attendees = patch.attendees, !attendees.isEmpty {
            // RFC 5545 §3.8.4.3 + iCloud requirement: a VEVENT carrying
            // ATTENDEE must also carry ORGANIZER. Without this iCloud rejects
            // the PUT with HTTP 403. Echo the master's ORGANIZER on the
            // override; if the master has none (rare — iCloud auto-adds
            // when an attendee is first added), fall back to a self-organized
            // form using the FIRST attendee's domain owner. Best-effort.
            if let org = organizerLine {
                lines.append(org)
            }
            for a in attendees {
                // Escape `"` in the CN so it can't break out of the quoted
                // parameter value (RFC 5545 §3.2 — DQUOTE is the delimiter).
                let cn = (a.name ?? a.email).replacingOccurrences(of: "\"", with: "'")
                lines.append("ATTENDEE;CN=\"\(cn)\";ROLE=REQ-PARTICIPANT:mailto:\(a.email)")
            }
        }

        // DTSTART/DTEND — emitted only when the patch moves the occurrence.
        // Value type matches the master (RFC 5545 §3.8.4.4).
        switch kind {
        case .allDay:
            let dateOnlyParse = DateFormatter()
            dateOnlyParse.dateFormat = "yyyy-MM-dd"
            dateOnlyParse.timeZone = .current
            let icsDateFmt = DateFormatter()
            icsDateFmt.dateFormat = "yyyyMMdd"
            icsDateFmt.timeZone = .current
            if let startStr = patch.startDate ?? patch.startDateTime,
               let d = dateOnlyParse.date(from: String(startStr.prefix(10))) {
                lines.append("DTSTART;VALUE=DATE:\(icsDateFmt.string(from: d))")
            }
            if let endStr = patch.endDate ?? patch.endDateTime,
               let d = dateOnlyParse.date(from: String(endStr.prefix(10))) {
                lines.append("DTEND;VALUE=DATE:\(icsDateFmt.string(from: d))")
            }
        case .zoned(let tzid):
            let zfmt = DateFormatter()
            zfmt.dateFormat = "yyyyMMdd'T'HHmmss"
            zfmt.timeZone = TimeZone(identifier: tzid) ?? .current
            if let iso = patch.startDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTSTART;TZID=\(tzid):\(zfmt.string(from: d))")
            }
            if let iso = patch.endDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTEND;TZID=\(tzid):\(zfmt.string(from: d))")
            }
        case .utc:
            let ufmt = DateFormatter()
            ufmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            ufmt.timeZone = TimeZone(identifier: "UTC")
            if let iso = patch.startDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTSTART:\(ufmt.string(from: d))")
            }
            if let iso = patch.endDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTEND:\(ufmt.string(from: d))")
            }
        case .floating:
            let ffmt = DateFormatter()
            ffmt.dateFormat = "yyyyMMdd'T'HHmmss"
            ffmt.timeZone = .current
            if let iso = patch.startDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTSTART:\(ffmt.string(from: d))")
            }
            if let iso = patch.endDateTime, let d = Date.fromISO8601(iso) {
                lines.append("DTEND:\(ffmt.string(from: d))")
            }
        }
        lines.append("END:VEVENT")
        return lines.joined(separator: "\r\n")
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
            if line == "BEGIN:VEVENT" {
                // Collect this VEVENT into `block` so we can decide whether to keep it.
                var block: [String] = [line]
                var blockRecurId: String? = nil
                i += 1
                while i < lines.count && lines[i] != "END:VEVENT" {
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
            if line == "END:VCALENDAR" && !spliced {
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

    /// Construct the input for a new series of a split. Inherits the master's
    /// title/location/description/transparency from the source ICS unless the
    /// patch overrides; copies attendees from patch (already resolved) or
    /// falls back to the master.
    /// Throws `CalDAVError.parseError` if the master's start/end can't be
    /// recovered — silently defaulting the duration would produce a new series
    /// with wrong length, which is worse than failing fast.
    static func buildNewSeriesInput(
        masterICS: String,
        patch: GCalEventInput,
        newStartNaiveISO: String,
        newRRule: String
    ) throws -> GCalEventInput {
        var out = GCalEventInput()
        out.summary = patch.summary ?? extractScalar(from: masterICS, key: "SUMMARY")
        out.location = patch.location ?? extractScalar(from: masterICS, key: "LOCATION")
        out.description = patch.description ?? extractScalar(from: masterICS, key: "DESCRIPTION")
        out.transparency = patch.transparency ?? extractScalar(from: masterICS, key: "TRANSP")
        // Recurrence: caller's stripped-RRULE is the default, but if the LLM
        // asked for a different pattern on the new series via patch.recurrence,
        // honor that — matches Google/Exchange (mergeMasterAndPatch) and the
        // TB bridge.
        if let patchRecurrence = patch.recurrence, !patchRecurrence.isEmpty {
            out.recurrence = patchRecurrence
        } else {
            out.recurrence = [newRRule]
        }

        // Inherit duration from master's DTSTART/DTEND. If we can't recover it,
        // refuse to invent one — the caller surfaces the error to the LLM/user.
        guard let duration = extractMasterDuration(from: masterICS) else {
            throw CalDAVError.parseError("buildNewSeriesInput: could not extract master event duration from ICS")
        }

        // CRITICAL: preserve the master's all-day-ness. An all-day master must
        // produce an all-day new series (date-only DTSTART/DTEND) — emitting
        // the timed form would silently convert the series to a timed event.
        if icsIsAllDay(masterICS) {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            dateFmt.timeZone = .current
            // Prefer the patch's explicit new date when the LLM is moving
            // the series with the split. `newStartNaiveISO` only identifies
            // WHICH occurrence the split anchors at — `patch.startDate` is
            // the user's desired NEW date. Falling back to the recurrence_id
            // silently ignores a move the LLM was asked to perform.
            let preferredStart = patch.startDate ?? newStartNaiveISO
            guard let startDate = dateFmt.date(from: String(preferredStart.prefix(10))) else {
                throw CalDAVError.parseError("buildNewSeriesInput: invalid start '\(preferredStart)'")
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            out.startDate = dateFmt.string(from: startDate)
            // End: patch's explicit end wins; else start + master's duration.
            if let patchEnd = patch.endDate, let endDate = dateFmt.date(from: String(patchEnd.prefix(10))) {
                out.endDate = dateFmt.string(from: endDate)
            } else {
                let days = max(1, Int((duration / 86400).rounded()))
                if let endDate = cal.date(byAdding: .day, value: days, to: startDate) {
                    out.endDate = dateFmt.string(from: endDate)
                }
            }
        } else {
            // The naive recurrence_id is the occurrence's wall-clock time IN
            // THE MASTER'S ZONE — parse it there, not in the device zone, so
            // the absolute instant is correct even when they differ. The new
            // series then inherits the master's zone (via startTimeZone), so
            // `toICS` emits `DTSTART;TZID=…` + a matching VTIMEZONE instead of
            // a UTC time that would drift across DST.
            let masterKind = Self.masterDTStartKind(from: masterICS)
            let zone: TimeZone
            if case .zoned(let tzid) = masterKind, let tz = TimeZone(identifier: tzid) {
                zone = tz
            } else {
                zone = .current
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fmt.timeZone = zone
            // Same prefer-patch rule as the all-day branch above — see comment.
            let startInstant: Date? = {
                if let pISO = patch.startDateTime, let d = Date.fromISO8601(pISO) { return d }
                return fmt.date(from: newStartNaiveISO)
            }()
            guard let startDate = startInstant else {
                throw CalDAVError.parseError("buildNewSeriesInput: invalid start (patch.startDateTime='\(patch.startDateTime ?? "")', newStartNaiveISO='\(newStartNaiveISO)')")
            }
            let endDate: Date = {
                if let pISO = patch.endDateTime, let d = Date.fromISO8601(pISO) { return d }
                return startDate.addingTimeInterval(duration)
            }()
            out.startDateTime = startDate.iso8601String(timeZone: zone)
            out.endDateTime = endDate.iso8601String(timeZone: zone)
            if case .zoned(let tzid) = masterKind {
                out.startTimeZone = tzid
                out.endTimeZone = tzid
            }
        }

        // Attendees: patch's resolved list wins; otherwise inherit master's.
        if let pa = patch.attendees {
            out.attendees = pa
        } else {
            out.attendees = extractAttendees(from: masterICS)
        }
        return out
    }

    /// Extract a simple scalar property (`SUMMARY`, `LOCATION`, etc.) — does
    /// not unescape ICS escapes; good enough for round-trip preservation.
    /// Uses `icsLines` so folded lines (RFC 5545 §3.1) are joined first —
    /// otherwise long descriptions would be silently truncated at column 75.
    /// Scoped to the MASTER VEVENT — a VTIMEZONE's STANDARD/DAYLIGHT
    /// subcomponents could also carry these keys, so a whole-resource scan
    /// would be unsafe.
    private static func extractScalar(from ics: String, key: String) -> String? {
        let prefix = "\(key):"
        for line in masterVEventLines(from: ics) {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Parse the MASTER VEVENT's DTSTART/DTEND lines (with or without TZID) and
    /// return the duration in seconds. Returns nil if either line is
    /// missing/unparseable. Scoped to the master VEVENT so a VTIMEZONE's own
    /// `DTSTART:…T020000` lines can't be mistaken for the event's.
    static func extractMasterDuration(from ics: String) -> TimeInterval? {
        var startDate: Date?
        var endDate: Date?
        for line in masterVEventLines(from: ics) {
            if line.hasPrefix("DTSTART") {
                startDate = parseICSDateTime(line)
            } else if line.hasPrefix("DTEND") {
                endDate = parseICSDateTime(line)
            }
        }
        guard let s = startDate, let e = endDate, e > s else { return nil }
        return e.timeIntervalSince(s)
    }

    /// Parse an ICS DTSTART/DTEND line into an absolute `Date`. Handles three
    /// forms: floating UTC (`DTSTART:20260520T170000Z`), TZID-qualified
    /// (`DTSTART;TZID=America/Los_Angeles:20260520T170000`), and date-only
    /// all-day (`DTSTART;VALUE=DATE:20260520` or `DTSTART:20260520`).
    /// Returns nil on any parse failure so callers can decide how to handle it.
    static func parseICSDateTime(_ line: String) -> Date? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let header = String(line[..<colonIdx])  // e.g. "DTSTART;TZID=America/Los_Angeles"
        let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

        // Date-only (all-day) — emits midnight in the resource's effective tz.
        // ICS all-day uses VALUE=DATE; fall back on a bare 8-digit value too.
        let isDateOnly = header.uppercased().contains("VALUE=DATE")
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
            // A TZID is present but unresolvable (e.g. a Windows-style name
            // like "Central European Standard Time" from an Outlook export).
            // Refuse to parse rather than silently reinterpreting in the
            // device timezone — a wrong absolute instant here would corrupt
            // `extractMasterDuration` (the new series would get a duration off
            // by the timezone offset). Returning nil makes the caller
            // (`buildNewSeriesInput`) fail fast with a clear error instead.
            guard let zone = TimeZone(identifier: tzid) else {
                print("[CalDAV] parseICSDateTime: unresolvable TZID '\(tzid)' — refusing to guess")
                return nil
            }
            resolvedZone = zone
        } else {
            // No TZID → RFC 5545 "floating time": interpret in device-local.
            resolvedZone = .current
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = resolvedZone
        return fmt.date(from: value)
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

    /// Scoped to the MASTER VEVENT (`masterVEventLines` unfolds folded lines
    /// first — long CN values can push an ATTENDEE line past 75 chars).
    private static func extractAttendees(from ics: String) -> [(email: String, name: String?)] {
        var result: [(email: String, name: String?)] = []
        for line in masterVEventLines(from: ics) {
            guard line.hasPrefix("ATTENDEE") else { continue }
            // ATTENDEE;CN="Name";ROLE=REQ-PARTICIPANT:mailto:foo@bar.com
            guard let mailtoRange = line.range(of: "mailto:", options: .caseInsensitive) else { continue }
            let email = String(line[mailtoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var name: String?
            if let cnRange = line.range(of: "CN=\"", options: .caseInsensitive) {
                let after = line[cnRange.upperBound...]
                if let endQuote = after.firstIndex(of: "\"") {
                    name = String(after[..<endQuote])
                }
            }
            result.append((email: email, name: name))
        }
        return result
    }

    // MARK: - Helpers

    /// Resolve a short or full eventId to its full URL using the calendar path.
    /// Short IDs (no `/`) come from the create flow (e.g., `tmXXX`). These must be
    /// resolved as `calendarURL/tmXXX.ics` — the same way createEvent builds the URL.
    /// Full hrefs (containing `/`) come from listEvents and are resolved normally.
    private func resolveEventURL(_ eventId: String, calendarId: String) -> URL {
        if eventId.contains("/") {
            return resolveURL(eventId)
        }
        // Short ID — build URL the same way createEvent does: calendar + id.ics
        let calURL = resolveURL(calendarId)
        let filename = eventId.hasSuffix(".ics") ? eventId : "\(eventId).ics"
        return calURL.appendingPathComponent(filename)
    }

    /// Resolve a calendarId or eventId (which is a path) to a full URL.
    /// Resolves against calendarHomeURL (not serverBaseURL) because iCloud redirects
    /// caldav.icloud.com → pXX-caldav.icloud.com. The calendarHomeURL has the correct
    /// post-redirect host. Using serverBaseURL would hit the pre-redirect host, and
    /// URLSession's 301/302 handling changes REPORT/PUT/DELETE to GET (losing the body).
    private func resolveURL(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://"),
           let url = URL(string: path) {
            return url
        }
        // Resolve against calendarHomeURL (has correct post-redirect host for iCloud)
        return URL(string: path, relativeTo: calendarHomeURL)?.absoluteURL
            ?? calendarHomeURL.appendingPathComponent(path)
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
