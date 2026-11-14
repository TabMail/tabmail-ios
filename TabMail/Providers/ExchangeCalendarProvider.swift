/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

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
        var listed: [MSCalendar] = []
        try await readPages(path: "/calendars?$select=id,name,isDefaultCalendar,color", logLabel: "listCalendars raw") { (page: [MSCalendar]) in
            listed += page
            return false
        }
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listCalendars listed \(listed.count)")
        return listed.map { cal in
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
        queryItems.append("$top=\(ExchangeCalendarConfig.listPageSize)")
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

        // The query filter is applied client-side (Graph calendarView doesn't support $search),
        // to each page as it is read, so `maxResults` counts matching events, never the rows
        // a page happened to hold. Reading stops once `maxResults` events are listed.
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listEvents endpoint: \(endpoint)")
        let lower = query.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        var events: [GCalEvent] = []
        try await readPages(path: endpoint, logLabel: "listEvents response") { (page: [MSEvent]) in
            events += page
                .filter { $0.isCancelled != true }
                .filter { e in
                    if isEmptySurfaceEvent(e) {
                        BackgroundSyncLogger.logDebug("[ExchangeCalendar] dropping empty event id=\(e.id ?? "nil")")
                        return false
                    }
                    return true
                }
                .map { toGCalEvent($0) }
                .filter { event in
                    guard let lower else { return true }
                    return (event.summary ?? "").lowercased().contains(lower) ||
                        (event.location ?? "").lowercased().contains(lower) ||
                        (event.description ?? "").lowercased().contains(lower)
                }
            return events.count >= maxResults
        }
        BackgroundSyncLogger.logDebug("[ExchangeCalendar] listEvents listed \(events.count)")
        return Array(events.prefix(maxResults))
    }

    /// Reads a Graph collection page by page, following `@odata.nextLink` until Graph
    /// returns none: "To read all results, you must continue to call Microsoft Graph with
    /// the @odata.nextLink property returned in each response until the @odata.nextLink
    /// property is no longer returned" (learn.microsoft.com/graph/paging). `take` gets each
    /// page's items in order and returns true when the caller has what it asked for, which
    /// ends the walk there. Every page is read through `request`, so each carries the same
    /// `Prefer: outlook.timezone` and every listed time is in one zone.
    ///
    /// A next link that is not a Graph page link (`GraphAPI.isGraphPageLink`) throws
    /// `ExchangeCalendarError.invalidPageLink` before any request is sent to it, and a
    /// collection that has not ended within `ExchangeCalendarConfig.maxListPages` pages
    /// throws `ExchangeCalendarError.listingIncomplete`: neither returns part of the listing.
    /// `logLabel` names each page's debug log.
    private func readPages<Item: Decodable>(
        path: String, logLabel: String, _ take: ([Item]) -> Bool
    ) async throws {
        var data = try await request(path: path)
        var pages = 1
        while true {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] \(logLabel) page \(pages): \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
            let page = try JSONDecoder().decode(MSPage<Item>.self, from: data)
            if take(page.value) { return }
            guard let link = page.nextLink else { return }
            guard GraphAPI.isGraphPageLink(link) else { throw ExchangeCalendarError.invalidPageLink }
            guard pages < ExchangeCalendarConfig.maxListPages else { throw ExchangeCalendarError.listingIncomplete }
            data = try await request(url: link)
            pages += 1
        }
    }

    /// What an event read selects (`listEvents`, `getEvent`, and an edit's
    /// `fetchForEdit`). `body` and `onlineMeeting` give the description and the
    /// join link (`notes(of:)`), and the stored body an edit keeps (#511).
    /// `originalStart` gives an occurrence's place in its series (`originalStartTime`).
    /// Graph's calendarView page says "The createdDateTime and lastModifiedDateTime properties of
    /// event don't support $select" (learn.microsoft.com/graph/api/user-list-calendarview). A personal
    /// account was measured selecting both on 2026-11-13, but nothing here uses them, so neither is
    /// read and an Outlook event carries no `created` or `updated`.
    private static let eventSelect = "id,subject,location,body,bodyPreview,onlineMeeting,start,end,attendees,organizer,recurrence,showAs,isCancelled,webLink,isAllDay,seriesMasterId,originalStart"

    /// What `getEvent` reads: what a listing reads, and the event's own zone
    /// (`originalStartTimeZone`), the zone a series whose range names none repeats in
    /// (`GCalEvent.seriesZoneName`), so the confirmation card dates a series as its write does.
    /// A listing does not read it: nothing there needs it. With it, the zone the event's end was
    /// stored in (`originalEndTimeZone`): a new last date alone is no reset only when the write
    /// restates both as stored (`restatesStoredTimes`).
    private static let readSelect = eventSelect + ",originalStartTimeZone,originalEndTimeZone"

    /// What a split reads from the stored series: what `getEvent` reads, and every property the
    /// new part copies (`splitCopiedKeys`).
    private static let splitSelect = readSelect
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
        let data = try await request(path: "/events/\(encodedEventId)?$select=\(Self.readSelect)")
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
        return try await patchEdit(eventId: eventId, event: event, existing: existing)
    }

    /// The PATCH of `updateEvent`: only what `event` changes on `existing` (`graphPatchJSON`), and
    /// nothing when it changes nothing. The event as Graph answers it, or `existing`'s when nothing
    /// was written.
    private func patchEdit(eventId: String, event: GCalEventInput, existing: EditSnapshot) async throws -> GCalEvent {
        let json = try graphPatchJSON(patch: event, existing: existing, allowRecurrence: true)
        guard !json.isEmpty else {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateEvent: the edit changes nothing — no PATCH")
            return existing.event
        }
        return try await sendPatch(eventId: eventId, json: json, ifMatch: nil)
    }

    /// PATCHes the event `eventId` with `json`, sent conditional on `ifMatch` (the event's
    /// `@odata.etag`, `If-Match`) when given: Graph then refuses it with 412, writing nothing, when
    /// the event changed since. The event as Graph answers it.
    private func sendPatch(eventId: String, json: [String: Any], ifMatch: String?) async throws -> GCalEvent {
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
        let data = try await request(
            path: "/events/\(encodedEventId)", method: "PATCH", body: body, headers: ifMatch.map { ["If-Match": $0] } ?? [:])
        if DebugModeManager.isLoggingEnabled() {
            if let respStr = String(data: data, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateEvent response=\(respStr.prefix(4000))")
            }
        }
        let updated = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(updated)
    }

    /// An edit of every occurrence (`CalendarProvider.updateSeries`). Graph resets a series' changed
    /// and deleted occurrences on any change of its start or end (measured, #423), and for a change
    /// of its end alone no request shape avoids it (measured 2026-11-11: with or without the start,
    /// under three zone labels), where Google Calendar keeps them: each changed occurrence keeps its
    /// own start and other changes and takes the new length, and deleted ones stay deleted. So a
    /// change of the length (`SplitCarry.lengthChange`) of a series that has any:
    /// 1. reads and plans them before anything is written (`lengthChangeExceptions`, the plan the
    ///    edit's card also runs), refused unwritten when they can't be read or planned;
    /// 2. keeps them on the queued operation (`record`) before the write, with the series' etag
    ///    the read gave (`SeriesEditRecord.seriesEtag`);
    /// 3. PATCHes the series, as `updateEvent` does (Graph resets them), conditional on that etag
    ///    (`If-Match`; Graph's etag is series-wide and moves with any write anywhere in the series,
    ///    measured 2026-11-14), or on the read's when it found nothing to keep;
    /// 4. puts them back onto the series itself with the split's carry (`carry`, `putBack`), found
    ///    by their place: each deleted one deleted again, each changed one written with its own
    ///    values but the edit's fields, a moved one at its own start lasting the new length, its
    ///    guests its own with the series' change applied.
    /// Whether the series' write was sent is kept in the record (`SeriesEditRecord.Write`): `sent`
    /// before the PATCH, `landed` once it is answered, `notSent` again when Graph answers this
    /// attempt's first send of it with a refusal. Once sent, a retry puts back the kept record,
    /// which is never replaced or shrunk but by the put-back itself, while the series is the one
    /// it was read from or already holds the write; one `landed` is not sent again. The write is
    /// sent again only while the series does not hold it yet (the read shows whether it does), and
    /// on the kept etag: when Graph refuses it (412), the series changed since the capture (the
    /// user deleted or changed an occurrence in another app before the retry), so nothing is
    /// written and the occurrences are read and kept again, with what the first read captured at
    /// the places this read holds nothing at (`stillCaptured`; that write may have landed and reset
    /// them) and the files it saved (`stillHeld`), at most `ExchangeCalendarConfig.putBackConflictReads` reads, then `seriesBusy`
    /// (the operation stays queued). A record whose write is `notSent` is read and kept again too:
    /// the series still holds its occurrences. Every put-back write is absolute, and a DELETE
    /// answered 404 is done, so one that lands twice changes nothing. A put-back that fails for
    /// good after the PATCH (`putBackFailsForGood`) retires the operation with how many were not
    /// put back (`CalendarProviderError.seriesPutBackIncomplete`). Any other edit is `updateEvent`'s.
    func updateSeries(
        calendarId: String = "primary", eventId: String, event: GCalEventInput, sendUpdates: String = "all",
        record: SeriesEditRecorder
    ) async throws -> GCalEvent {
        try Self.refuseUnrepresentableRule(event.recurrence)
        // What the operation holds, as this attempt keeps it.
        var held = record.kept
        // Whether an earlier attempt sent the write of the record the operation holds: it may have
        // landed, so the files that record names may be on no occurrence now.
        let sentBefore = record.kept.map { $0.seriesId == eventId && $0.write == .sent } ?? false
        // Whether the series changed since `held`'s capture was read (its write refused by its etag).
        var stale = false
        var reads = 0
        while true {
            reads += 1
            let existing = try await fetchForEdit(eventId: eventId, select: Self.readSelect)
            let capture: SeriesCapture
            var kept: SeriesEditRecord?
            // Whether this attempt kept the record it writes from: its write is then sent for the
            // first time below.
            var keptHere = false
            if let earlier = held, earlier.seriesId == eventId, earlier.write != .notSent, !stale {
                capture = try seriesCapture(from: earlier.capture, series: existing.event)
                kept = earlier
            } else {
                let read = try await lengthChangeExceptions(eventId: eventId, existing: existing, edit: event, files: record.files)
                capture = SeriesCapture(
                    seriesRaw: existing.raw,
                    exceptions: read.exceptions + (sentBefore ? try stillCaptured(held, besides: read.exceptions, series: existing.event) : []))
                // A record an earlier read kept is replaced, an empty one included, so a later retry
                // never puts back what this read no longer holds. The files it saved that this read
                // does not hold are released once the new record is kept: when its write was never
                // sent or was refused, nothing of ours removed them from their occurrences. When an
                // earlier attempt sent it, it may have landed and reset them, so what it captured
                // is kept with this read's (`stillCaptured`, `stillHeld`).
                if !capture.exceptions.isEmpty || held != nil {
                    let fresh: SeriesEditRecord
                    do {
                        guard let etag = existing.raw["@odata.etag"] as? String, !etag.isEmpty else {
                            throw CalendarProviderError.notSupported(Self.seriesVersionUnreadable)
                        }
                        let carried = sentBefore ? try await stillHeld(held?.files ?? [], besides: read.files) : []
                        fresh = SeriesEditRecord(
                            seriesId: eventId, capture: try capture.text(), files: read.files + carried, write: .sent, seriesEtag: etag)
                        try await record.keep(fresh)
                    } catch {
                        Self.release(read.files, keeping: held?.files ?? [], from: record.files)
                        throw error
                    }
                    Self.release(held?.files ?? [], keeping: fresh.files, from: record.files)
                    kept = fresh
                    held = fresh
                    keptHere = true
                } else {
                    kept = nil
                }
            }
            let written: GCalEvent
            var json = kept?.write == .landed ? nil : try graphPatchJSON(patch: event, existing: existing, allowRecurrence: true)
            // A write an earlier attempt sent that the series holds now landed with its answer
            // lost (the series' etag moved with it, so it is not sent again): the record it was
            // kept with is put back. Graph applies a PATCH whole, so the series holding every
            // value of it is that write landed.
            if !keptHere, !stale, kept?.write == .sent, let sent = json, !sent.isEmpty,
               Self.holdsValues(existing.raw, sent, allDay: sent["isAllDay"] as? Bool ?? existing.raw["isAllDay"] as? Bool ?? false) {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateSeries: the series \(eventId) holds the write an earlier attempt sent")
                }
                json = nil
            }
            if let json, !json.isEmpty {
                // The etag the write is conditional on: the record's, or with no record (this read
                // found nothing changed or deleted) this read's, so an occurrence the user changes
                // between the read and the write is read and kept before the write resets it.
                let ifMatch: String?
                if let kept {
                    ifMatch = kept.seriesEtag
                } else {
                    guard let etag = existing.raw["@odata.etag"] as? String, !etag.isEmpty else {
                        throw CalendarProviderError.notSupported(Self.seriesVersionUnreadable)
                    }
                    ifMatch = etag
                }
                // Nil when the series changed since it was read (Graph refused the write by its
                // etag, 412) or the record, kept by an earlier version, holds no etag: nothing was
                // written, and the occurrences are read again.
                var answer: GCalEvent?
                if let ifMatch {
                    do {
                        answer = try await sendPatch(eventId: eventId, json: json, ifMatch: ifMatch)
                    } catch ExchangeCalendarError.httpError(let code, _) where code == Self.preconditionFailed {
                        answer = nil
                    } catch where keptHere && !sentBefore && Self.refusedUnwritten(error) {
                        // Graph answered the first send of this record's write with a refusal:
                        // nothing was written, and the series still holds its occurrences. A write
                        // an earlier attempt sent stays `sent`: that send may have landed.
                        if let sent = kept { await Self.keepUnsent(sent, eventId: eventId, record: record) }
                        throw error
                    }
                }
                guard let answer else {
                    guard reads < ExchangeCalendarConfig.putBackConflictReads else {
                        if keptHere, !sentBefore, let sent = kept { await Self.keepUnsent(sent, eventId: eventId, record: record) }
                        throw ExchangeCalendarError.seriesBusy
                    }
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[ExchangeCalendar] the write of \(eventId) refused by its etag (read \(reads)): reading it again")
                    }
                    stale = true
                    continue
                }
                written = answer
            } else {
                // Landed, or the series holds the write already: an earlier attempt's landed and
                // its answer was lost.
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateSeries: the series holds the edit — no PATCH")
                written = existing.event
            }
            if let sent = kept, sent.write != .landed {
                let landed = sent.writing(.landed)
                try await record.keep(landed)
                kept = landed
            }
            return try await putBackAfterWrite(
                written, existing: existing, capture: capture, kept: kept, eventId: eventId, event: event, record: record)
        }
    }

    /// `updateSeries`' put-back once the series holds its write (`written`): what `kept` names,
    /// read as `capture`, onto the series as `existing` was read before the write.
    private func putBackAfterWrite(
        _ written: GCalEvent, existing: EditSnapshot, capture: SeriesCapture, kept: SeriesEditRecord?,
        eventId: String, event: GCalEventInput, record: SeriesEditRecorder
    ) async throws -> GCalEvent {
        let series = existing.event
        guard let kept else { return written }
        let fields = SplitCarry.fields(of: event)
        let ledger = PutBackLedger(record: kept, keep: record.keep, files: record.files)
        guard !capture.exceptions.isEmpty else {
            // Files kept from an earlier read whose occurrence this read no longer holds as changed.
            guard ledger.held.isEmpty else {
                throw CalendarProviderError.seriesPutBackIncomplete(Self.putBackOutcome(events: 0, files: ledger.held.count))
            }
            return written
        }
        guard let plan = SplitCarry.plan(
            exceptions: capture.exceptions.map(\.carried), series: series, newPart: written, fields: fields)
        else {
            throw CalendarProviderError.seriesPutBackIncomplete(Self.putBackOutcome(events: capture.exceptions.count, files: ledger.held.count))
        }
        try await putBack(
            plan, capture: capture, series: series, seriesId: eventId, fields: fields, guests: event.attendeeChange,
            seriesZone: series.seriesZoneName, zone: try? Self.seriesTimeZone(existing, refusal: .lengthChange), ledger: ledger)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] updateSeries put back \(plan.deleted.count) deleted and \(plan.changed.count) changed occurrences of \(eventId)")
        }
        return written
    }

    /// Keeps `sent` as not sent: Graph refused its write, so nothing was written. Kept as `sent`
    /// when the record can't be written, which only keeps its files longer.
    private static func keepUnsent(_ sent: SeriesEditRecord, eventId: String, record: SeriesEditRecorder) async {
        do {
            try await record.keep(sent.writing(.notSent))
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] the refused write of \(eventId) stays kept as sent: \(error)")
            }
        }
    }

    /// The occurrences the capture of `earlier` (a record whose write an earlier attempt sent, now
    /// read again) holds as changed or deleted at a place this read (`besides`) holds none at: that
    /// write may have landed and reset them, and the record is their only copy, so they are put
    /// back with this read's. This read's wins at a place both hold: it is the newer. One the user
    /// changed or deleted since the reset is left as it is by the put-back (`guardedPatch`, and a
    /// deleted place is deleted only while a plain occurrence), so keeping them is safe where the
    /// write did not land too.
    private func stillCaptured(_ earlier: SeriesEditRecord?, besides read: [TailException], series: GCalEvent) throws -> [TailException] {
        guard let earlier else { return [] }
        let places = Set(read.compactMap { $0.carried.place.map(SplitCarry.key) })
        return try seriesCapture(from: earlier.capture, series: series).exceptions
            .filter { $0.carried.place.map { !places.contains(SplitCarry.key($0)) } ?? false }
    }

    /// The files of `files` (a record whose write an earlier attempt sent, now read again) that a
    /// new read (`besides`) does not name and that are still held: the write may have landed and
    /// erased them, and these are their only copies, so each is kept unless its occurrence is
    /// proven gone (Graph answers its id 404 or 410: deleted since, its files with it). Any other
    /// answer to that read is rethrown (the operation stays queued). Kept, a file whose occurrence
    /// the new record holds as changed (this read's, or the earlier capture's: `stillCaptured`) is
    /// attached to it again, and one whose occurrence it does not is counted as not restored, its
    /// bytes kept for the user.
    private func stillHeld(_ files: [PutBackFile], besides read: [PutBackFile]) async throws -> [PutBackFile] {
        let named = Set(read.map { "\($0.occurrence)\n\($0.sha256)" })
        var gone: [String: Bool] = [:]
        var out: [PutBackFile] = []
        for file in files where !named.contains("\(file.occurrence)\n\(file.sha256)") {
            if gone[file.occurrence] == nil {
                let encoded = try Self.encodedGraphPathSegment(file.occurrence, context: "Graph event instance id")
                do {
                    _ = try await request(path: "/events/\(encoded)?$select=id")
                    gone[file.occurrence] = false
                } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {
                    gone[file.occurrence] = true
                }
            }
            if gone[file.occurrence] == false { out.append(file) }
        }
        return out
    }

    /// The changed and deleted occurrences of the series `existing` that the whole-series `edit`
    /// resets and `updateSeries` puts back, read and planned before anything is written: empty
    /// when `edit` is not a change of the series' length (`SplitCarry.lengthChange`) or the series
    /// has none. Planned against the series as the write will leave it (`plannedSeries`), so a
    /// move Graph can't take in order (`carryOrder`) is refused while nothing has changed. A timed
    /// series whose zone can't be read (`seriesTimeZone`, in `.lengthChange`'s words) is refused
    /// when it holds an occurrence deleted or moved on its own (`deletedOrMoved`): the put-back
    /// can't place the one or date the other. Throws too when they can't be read. The one plan the
    /// write (`updateSeries`) and the edit's card (`refuseSeriesWrite`) make.
    ///
    /// The changed occurrences' own attachments are classified too (`ownFiles`): a linked file,
    /// or an attached Outlook item the series does not hold, is refused; with `files` (the
    /// write), each file an occurrence holds of its own is saved and named in the result.
    private func lengthChangeExceptions(
        eventId: String, existing: EditSnapshot, edit: GCalEventInput, files: SavedFiles? = nil
    ) async throws -> LengthChangeCapture {
        let series = existing.event
        guard series.recurrence?.isEmpty == false, movesSeriesTime(edit, existing: series),
              SplitCarry.lengthChange(edit, series: series) else { return LengthChangeCapture() }
        var zone: TimeZone?
        var zoneRefusal: Error?
        do { zone = try Self.seriesTimeZone(existing, refusal: .lengthChange) } catch { zoneRefusal = error }
        let exceptions = try await seriesExceptions(
            seriesId: eventId, series: series, seriesZone: series.seriesZoneName, zone: zone,
            refusal: Self.lengthChangeUnreadable, unplaced: zoneRefusal)
        guard !exceptions.isEmpty else { return LengthChangeCapture() }
        if let zoneRefusal, exceptions.contains(where: Self.deletedOrMoved) { throw zoneRefusal }
        guard let plan = SplitCarry.plan(
            exceptions: exceptions.map(\.carried), series: series,
            newPart: Self.plannedSeries(series, edit: edit), fields: SplitCarry.fields(of: edit))
        else { throw CalendarProviderError.notSupported(Self.lengthChangeUnreadable) }
        _ = try Self.carryOrder(plan.changed, zone: zone)
        let saved = try await ownFiles(of: exceptions, seriesId: eventId, files: files)
        return LengthChangeCapture(exceptions: exceptions, files: saved)
    }

    /// What `lengthChangeExceptions` read: the occurrences to put back and the files saved for them.
    struct LengthChangeCapture {
        var exceptions: [TailException] = []
        var files: [PutBackFile] = []
    }

    /// The attachments the changed occurrences in `exceptions` hold of their own, classified
    /// before anything is written (#718). Outlook's reset erases a changed occurrence's whole
    /// attachment set and leaves it reading the series' own (measured 2026-11-14); a changed
    /// occurrence holds its own COPIES of the series' attachments (new ids, the same name, kind
    /// and content), so what it holds of its own is what does not pair with the series' list by
    /// name, kind and content (`AttachmentPairing.unpaired`). Read only for an occurrence Graph
    /// does not say holds none (`hasAttachments`); the series' list is read once, when needed.
    /// - A linked file (`isReferenceAttachment`) is refused (`lengthChangeLinkedFileRefusal`):
    ///   Graph v1.0 shows no link's target, so it can't be compared or written back.
    /// - An attached Outlook item the series does not hold, or an attachment of a kind TabMail
    ///   does not know, is refused (`lengthChangeItemRefusal`): no copy of an item is faithful
    ///   (#854). An item pairs by the JSON Graph expands it to (`itemDigest`).
    /// - A file of its own, with `files`: its bytes are read and saved (`SavedFiles.save`), and it
    ///   is named in the result (`PutBackFile`). Without `files` (the card's check) no file is read.
    /// Throws, with nothing written, when a list or a file can't be read or saved; the files it
    /// saved before are released then, as no record names them.
    private func ownFiles(of exceptions: [TailException], seriesId: String, files: SavedFiles?) async throws -> [PutBackFile] {
        var saved: [PutBackFile] = []
        do {
            try await ownFiles(of: exceptions, seriesId: seriesId, files: files, saving: &saved)
        } catch {
            if let files { Self.release(saved, keeping: [], from: files) }
            throw error
        }
        if DebugModeManager.isLoggingEnabled(), !saved.isEmpty {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] saved \(saved.count) file(s) of changed occurrences of \(seriesId) before its write")
        }
        return saved
    }

    /// `ownFiles`' walk, adding each file it saves to `saved` as it goes.
    private func ownFiles(of exceptions: [TailException], seriesId: String, files: SavedFiles?, saving saved: inout [PutBackFile]) async throws {
        let seriesPath = try "/events/" + Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
        let seriesList = SeriesAttachmentList()
        func seriesAttachments() async throws -> [EventAttachment] {
            try await seriesList.read { try await self.attachments(of: seriesPath).map { EventAttachment(eventPath: seriesPath, meta: $0) } }
        }
        for exception in exceptions {
            guard case .changed = exception.carried, let id = exception.raw["id"] as? String,
                  exception.raw["hasAttachments"] as? Bool != false else { continue }
            let path = try "/events/" + Self.encodedGraphPathSegment(id, context: "Graph event instance id")
            let held = try await attachments(of: path).map { EventAttachment(eventPath: path, meta: $0) }
            guard !held.isEmpty else { continue }
            if held.contains(where: { Self.isReferenceAttachment($0.meta) }) {
                throw CalendarProviderError.notSupported(Self.lengthChangeLinkedFileRefusal)
            }
            let fileList = held.filter { ExchangeProvider.isFileAttachment($0.meta) }
            let others = held.filter { !ExchangeProvider.isFileAttachment($0.meta) }
            if !others.isEmpty {
                if others.contains(where: { !Self.isItemAttachment($0.meta) }) {
                    throw CalendarProviderError.notSupported(Self.lengthChangeItemRefusal)
                }
                let seriesItems = try await seriesAttachments().filter { Self.isItemAttachment($0.meta) }
                let added = try await AttachmentPairing.unpaired(
                    others, against: seriesItems, name: { Self.attachmentName($0.meta) }, kind: { Self.attachmentKind($0.meta) },
                    content: { try await self.itemDigest($0) })
                if !added.isEmpty { throw CalendarProviderError.notSupported(Self.lengthChangeItemRefusal) }
            }
            guard let files, !fileList.isEmpty else { continue }
            let seriesFiles = try await seriesAttachments().filter { ExchangeProvider.isFileAttachment($0.meta) }
            let reads = SourceFileReads()
            let own = try await AttachmentPairing.unpaired(
                fileList, against: seriesFiles, name: { Self.attachmentName($0.meta) }, kind: { Self.attachmentKind($0.meta) },
                content: { file in
                    let read = try await self.fileBytes(file)
                    if file.eventPath == path { reads.keep(read, for: file.meta.id) }
                    return AttachmentPairing.contentDigest(read.data)
                })
            for file in own {
                let content = if let kept = reads.take(file.meta.id) { kept } else { try await fileBytes(file) }
                let name = try files.save(content.data)
                guard name == AttachmentPairing.contentDigest(content.data) else {
                    throw CalendarProviderError.notSupported(Self.lengthChangeUnreadable)
                }
                saved.append(PutBackFile(
                    occurrence: id, name: Self.attachmentName(file.meta),
                    contentType: file.meta.contentType ?? Self.defaultFileContentType,
                    isInline: file.meta.isInline ?? false, contentId: content.contentId, sha256: name))
            }
        }
    }

    /// The content type a file with none is written with, as a split's copy writes it.
    static let defaultFileContentType = "application/octet-stream"

    /// What an attached Outlook item pairs by: the SHA-256 of the JSON Graph expands it to
    /// (`$expand=microsoft.graph.itemattachment/item`), keys sorted, without what differs between
    /// an item and an occurrence's copy of it (measured 2026-11-14: its id, its own times and
    /// change key, a message's `webLink`, and OData annotations).
    private func itemDigest(_ attachment: EventAttachment) async throws -> String {
        let encoded = try Self.encodedGraphPathSegment(attachment.meta.id, context: "Graph attachment id")
        let data = try await request(path: "\(attachment.eventPath)/attachments/\(encoded)?$expand=microsoft.graph.itemattachment/item")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = object["item"] as? [String: Any] else {
            throw CalendarProviderError.notSupported(Self.lengthChangeItemRefusal)
        }
        return AttachmentPairing.contentDigest(try JSONSerialization.data(withJSONObject: Self.comparableItem(item), options: [.sortedKeys]))
    }

    /// The keys of an expanded item that differ between an item and a copy of it (`itemDigest`).
    static let itemCopyKeys: Set<String> = ["id", "createdDateTime", "lastModifiedDateTime", "changeKey", "webLink"]

    /// `item` without `itemCopyKeys` and without any OData annotation, at any depth.
    nonisolated static func comparableItem(_ item: Any) -> Any {
        if let object = item as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in object where !key.hasPrefix("@odata.") && !itemCopyKeys.contains(key) {
                out[key] = comparableItem(value)
            }
            return out
        }
        if let list = item as? [Any] { return list.map(comparableItem) }
        return item
    }

    /// The refusals of a new length of every occurrence when a changed occurrence holds a linked
    /// file, or an attached Outlook item the series does not hold (`ownFiles`).
    static let lengthChangeLinkedFileRefusal =
        "This repeating event has an occurrence with a linked file TabMail can't put back, so its length was not changed. Make the change in your calendar app."
    static let lengthChangeItemRefusal =
        "This repeating event has an occurrence with an attached Outlook item TabMail can't put back, so its length was not changed. Make the change in your calendar app."

    /// Whether `exception` is an occurrence deleted on its own, or one changed to another start
    /// than its place in the series.
    nonisolated static func deletedOrMoved(_ exception: TailException) -> Bool {
        switch exception.carried {
        case .deleted: return true
        case .changed(let event):
            guard let start = event.start, let place = event.originalStartTime else { return true }
            return SplitCarry.key(start) != SplitCarry.key(place)
        }
    }

    static let lengthChangeUnreadable =
        "the occurrences of this repeating event changed or deleted one by one can't be read, so its length was not changed"

    /// What the user is told when the read of a series gives no version (`@odata.etag`) its
    /// write can be made conditional on: nothing is written.
    static let seriesVersionUnreadable = "the repeating event's version can't be read, so it was not changed"

    /// What the user is told when the put-back after a series' PATCH fails for good
    /// (`putBackFailsForGood`): the series was written, and `remaining` of the occurrences changed
    /// or deleted on their own were not put back.
    nonisolated static func putBackFailure(_ remaining: Int) -> String {
        "The series was changed, but \(remaining == 1 ? "1 event" : "\(remaining) events") you had changed on their own could not be restored. Check them in your calendar."
    }

    /// What the user is told about the files of changed occurrences a put-back has not attached
    /// again: `held` files still saved on the device (or lost from it this time).
    nonisolated static func putBackFilesFailure(_ held: Int) -> String { PutBackFile.notRestoredMessage(held) }

    /// The outcome of a put-back that did not restore everything: `events` occurrences not put
    /// back (`putBackFailure`) and `files` files not attached again (`putBackFilesFailure`), each
    /// sentence only when its count is not zero.
    nonisolated static func putBackOutcome(events: Int, files: Int) -> String {
        [events > 0 ? putBackFailure(events) : nil, files > 0 ? putBackFilesFailure(files) : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// What the user is told when Outlook refuses to attach the file `name` again to the
    /// occurrence on `date` because the event would be over the mailbox's size limit
    /// (`ErrorMessageSizeExceeded`): every retry would be refused the same way.
    nonisolated static func putBackTooLarge(_ name: String, on date: String) -> String {
        "\(name) could not be put back on \(date): too large for Outlook."
    }

    /// Whether a put-back write's error fails for good, so a retry can't put the rest back: a
    /// refusal of the carry (`CalendarProviderError`), or a 4xx that is no sign-in, permission,
    /// not-found or come-back-later answer, as the queue retires one (`isCalendarBadRequestError`).
    nonisolated static func putBackFailsForGood(_ error: Error) -> Bool {
        if error is CalendarProviderError { return true }
        guard case ExchangeCalendarError.httpError(let code, _) = error else { return false }
        return (400...499).contains(code) && code != 401 && code != 403 && code != 404 && !CalendarHTTPStatus.isComeBackLater(code)
    }

    /// Whether the series' write (`patchEdit`) failed with nothing written: refused before it was
    /// sent (`CalendarProviderError`, an id that can't be a path segment), or answered by Graph
    /// with a refusal (4xx: a request it validated and refused, a missing permission, a full
    /// mailbox, a series that is gone). Anything else may have landed: a lost answer, a 5xx (the
    /// write may have been made behind it), an answer that can't be read.
    nonisolated static func refusedUnwritten(_ error: Error) -> Bool {
        if error is CalendarProviderError { return true }
        switch error as? ExchangeCalendarError {
        case .invalidPathSegment?, .missingScope?, .mailboxFull?, .eventNotFound?: return true
        case .httpError(let code, _)?: return (400...499).contains(code)
        default: return false
        }
    }

    /// Releases the saved bytes of `files` that no entry of `keeping` names: a record that named
    /// them is replaced, or never kept. A release that fails leaves them for the drain-start sweep
    /// once the row is gone.
    nonisolated static func release(_ files: [PutBackFile], keeping: [PutBackFile], from saved: SavedFiles) {
        for name in Set(files.map(\.sha256)).subtracting(keeping.map(\.sha256)) {
            do {
                try saved.release(name)
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] a saved file could not be released: \(error)")
                }
            }
        }
    }

    /// The start and end of `series` once `edit` is written, as the write merges them
    /// (`mergeExistingEventWithPatch`): what the put-back's plan needs of the series it writes onto.
    nonisolated static func plannedSeries(_ series: GCalEvent, edit: GCalEventInput) -> GCalEvent {
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: series, patch: edit)
        return GCalEvent(
            id: nil, summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: merged.startDateTime, date: merged.startDate, timeZone: merged.startTimeZone),
            end: GCalDateTime(dateTime: merged.endDateTime, date: merged.endDate, timeZone: merged.endTimeZone),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil, recurringEventId: nil)
    }

    /// What `updateSeries` reads before its write and puts back after it: the series' guests as
    /// they were (a guest change reaches each occurrence as the series' difference), its changed
    /// occurrences and its deleted ones.
    struct SeriesCapture {
        let seriesRaw: [String: Any]
        let exceptions: [TailException]

        /// The properties of the series and of each changed occurrence the capture keeps: what the
        /// carry writes (`carriedJSON`, its guests and times) and what places and names it.
        static let keptKeys = splitCopiedKeys.union(["id", "originalStart", "start", "end", "attendees", "type", "seriesMasterId"])

        /// The capture as `SeriesEditRecord.capture` keeps it.
        func text() throws -> String {
            var changed: [[String: Any]] = []
            var deleted: [String] = []
            for exception in exceptions {
                switch exception.carried {
                case .changed: changed.append(exception.raw.filter { Self.keptKeys.contains($0.key) })
                case .deleted(let place): deleted.append(SplitCarry.key(place))
                }
            }
            let object: [String: Any] = [
                "series": seriesRaw.filter { $0.key == "attendees" }, "changed": changed, "deleted": deleted,
            ]
            guard let text = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) else {
                throw CalendarProviderError.notSupported(ExchangeCalendarProvider.lengthChangeUnreadable)
            }
            return text
        }
    }

    /// The capture `SeriesCapture.text()` kept, read back for the series `series`.
    private func seriesCapture(from text: String, series: GCalEvent) throws -> SeriesCapture {
        let unreadable = CalendarProviderError.notSupported(
            "what this change must put back on the repeating event can't be read, so it was not finished. Check the event's changed occurrences in your calendar app.")
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seriesRaw = object["series"] as? [String: Any],
              let changed = object["changed"] as? [[String: Any]],
              let deleted = object["deleted"] as? [String] else { throw unreadable }
        var exceptions: [TailException] = []
        for raw in changed {
            guard let exception = try changedException(raw, series: series) else { throw unreadable }
            exceptions.append(exception)
        }
        for key in deleted {
            guard let place = SplitCarry.time(key) else { throw unreadable }
            exceptions.append(TailException(carried: .deleted(place: place), raw: [:]))
        }
        return SeriesCapture(seriesRaw: seriesRaw, exceptions: exceptions)
    }

    /// A changed occurrence of `series` as Graph expands it (`raw`, read with `Prefer` naming the
    /// series' zone): the neutral value with its place, and the JSON. Nil when its place can't be
    /// read.
    private func changedException(_ raw: [String: Any], series: GCalEvent) throws -> TailException? {
        let read = try JSONDecoder().decode(MSEvent.self, from: JSONSerialization.data(withJSONObject: raw))
        var event = toGCalEvent(read)
        if series.isAllDay { event.originalStartTime = Self.allDayPlace(read.originalStart) }
        guard event.originalStartTime != nil else { return nil }
        return TailException(carried: .changed(event), raw: raw)
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
    /// 3. Copy the series' attachments onto the new part (`copy`, as `copyPlan` decided before
    ///    any write), then carry the later changed and deleted occurrences onto it
    ///    (`writeSplitOccurrences`).
    /// 4. PATCH the master's recurrence.range to {type: "endDate", endDate: splitDate - 1 day}
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
        // Everything the split writes, read and worked out before its first write (`splitPlan`,
        // the plan the edit's card checks too).
        let plan: SplitPlan
        switch try await splitPlan(eventId: eventId, recurrenceId: recurrenceId, recurrenceIdZone: recurrenceIdZone, patch: patch) {
        case .shown(let shown):
            _ = try await editShown(shown, patch: patch, record: record)
            return nil
        case .split(let split):
            plan = split
        }
        let eventId = plan.seriesId, snapshot = plan.snapshot, master = plan.snapshot.event
        let seriesZone = plan.seriesZone, zone = plan.zone, place = plan.place, splitPlace = plan.splitPlace
        let namedStart = plan.namedStart, namedPlace = plan.namedPlace, partPatch = plan.partPatch, mode = plan.mode
        let createJSON = plan.createJSON, exceptions = plan.exceptions, parts = plan.parts
        let seriesCopy = plan.seriesCopy, carriedCopies = plan.carriedCopies, cappedBody = plan.cappedBody

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
        guard let edits = SplitCarry.edits(
            of: parts.edited, shift: SplitCarry.shift(cut: splitPlace, newPart: created), length: SplitCarry.length(of: created), fields: fields) else {
            throw CalendarProviderError.notSupported("the new part of this repeating event has a time TabMail can't read, so the change can't be finished")
        }
        let splitRecord = SplitRecord(
            seriesId: eventId, newPartId: createdId, splitAt: place, mode: mode, fields: fields,
            namedPlace: SplitCarry.key(namedPlace), namedStart: SplitCarry.key(namedStart), edits: SplitCarry.targets(of: edits))
        try await record(splitRecord)

        // 3. Copy the series' files onto the new part, as Outlook's own split keeps them (measured
        //    2026-11-13), before the carry, so each occurrence carried onto the new part is made
        //    from a part that holds them. A copy that fails stops the split here, before the cap.
        try await copy(seriesCopy, from: eventId, to: createdId, context: "Graph series master id")

        // 4. Carry onto the new part, and edit the occurrences shown after the one named that stay
        //    on the series. A write that fails stops the split here, before the cap: the series is
        //    still whole, and the retry writes again.
        try await writeSplitOccurrences(
            record: splitRecord, cut: splitPlace, exceptions: exceptions, series: master, seriesRaw: snapshot.raw,
            newPart: created, guests: partPatch.attendeeChange, seriesZone: seriesZone, zone: zone, copies: carriedCopies)

        // 5. Cap the master. A failure is rethrown; the record is kept.

        try await writeSplitCap(seriesId: eventId, body: cappedBody)
        return created
    }

    /// What a split of `eventId` at `recurrenceId` (read in `recurrenceIdZone`) with `patch` writes,
    /// read and worked out before anything is written: the split's own (`SplitPlan`), or, named at
    /// an occurrence moved past the series' last place, the edits of the occurrences shown
    /// (`shownPlan`). Throws, with nothing written, everything the split refuses before its first
    /// write: a zone it can't read (#681), a cap it can't date, an occurrence it can't place or
    /// move in order, a linked file (#834) and an attached item it can't carry (#847). The one
    /// plan `splitSeries` writes and the edit's card checks (`refuseSeriesWrite`).
    private func splitPlan(
        eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, patch: GCalEventInput
    ) async throws -> SplitPlanned {
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
        // The zone the series' dates are read in, the one its cap is dated in (`seriesTimeZone`,
        // #681): a timed series whose zone is missing or not recognized is refused here, before
        // anything is read or written. `seriesZone` is its name, the zone Graph is asked to read in.
        let zone = try Self.seriesTimeZone(snapshot)
        let seriesZone = snapshot.event.seriesZoneName
        let point = try await splitPoint(
            named: named, masterId: eventId, master: master, recurrenceId: recurrenceId, zone: recurrenceIdZone, seriesZone: zone)
        let found = point.found, namedStart = point.namedStart, namedPlace = point.namedPlace
        guard let place = point.place, case .at(let splitPlace) = point.cut else {
            return .shown(try await shownPlan(seriesId: eventId, series: master, named: found, patch: patch, seriesZone: seriesZone, zone: zone))
        }
        guard let partPatch = SplitCarry.partEdit(patch, namedStart: namedStart, cut: splitPlace, zone: zone) else {
            throw CalendarProviderError.notSupported("where the occurrence named falls in its series can't be read, so the series can't be split at it")
        }
        let mode = SplitCarry.mode(edit: partPatch, place: splitPlace, storedRules: masterRecurrence, seriesZone: zone)
        // The cap ends the series on the day before the cut's day in the series' own zone, worked
        // out before anything is written (`splitCapEndDate`, #681).
        let capEndDate = try Self.splitCapEndDate(stored: snapshot, splitNaiveISO: place, splitZone: recurrenceIdZone)
        guard let cappedJSON = Self.splitCapJSON(master: master, storedRecurrence: storedRecurrence, capEndDate: capEndDate) else {
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
        let exceptions = try await seriesExceptions(seriesId: eventId, series: master, seriesZone: seriesZone, zone: zone)
        guard let parts = SplitCarry.partition(exceptions.map(\.carried), cut: point.cut, namedStart: namedStart) else {
            throw CalendarProviderError.notSupported("a changed occurrence of this repeating event has a time TabMail can't read, so it was not split")
        }
        // The order the carry and the edits are written in dates their moves, and only their moves,
        // in the series' zone (`moveOrder`). They are planned here as they are written, against
        // the new part's times as the create gives them (`plannedPart`), so a move whose time
        // can't be read is refused before the new part is created.
        let carriedIds = try Self.dateSplitMoves(
            parts: parts, mode: mode, namedStart: namedStart, namedPlace: namedPlace, cut: splitPlace, series: master, zone: zone,
            newPart: try Self.plannedPart(master: master, patch: partPatch, place: place, zone: recurrenceIdZone, createJSON: createJSON),
            fields: SplitCarry.fields(of: partPatch))
        // What the split copies onto the new part and onto each changed occurrence it carries,
        // decided before anything is written (`copyPlan`). A linked file (a reference attachment:
        // a OneDrive or SharePoint link) can't be copied (Graph v1.0 can't create one on an
        // event), so a series or a carried occurrence holding one is refused here (owner
        // decision 2026-11-13, #834). An attached Outlook item is never copied (`copyPlan`, #854):
        // on the series the old part keeps it, but a carried occurrence holding one is refused
        // here too: the cap takes that occurrence off the old part, so the item would be on
        // neither (#847).
        let seriesCopy = try await copyPlan(of: eventId, context: "Graph series master id")
        var carriedCopies: [String: AttachmentCopyPlan] = [:]
        for id in carriedIds where carriedCopies[id] == nil {
            carriedCopies[id] = try await copyPlan(of: id, context: "Graph event instance id")
        }
        if seriesCopy.hasLinkedFile || carriedCopies.values.contains(where: \.hasLinkedFile) {
            throw CalendarProviderError.notSupported(Self.linkedFileRefusal)
        }
        if carriedCopies.values.contains(where: \.holdsItem) {
            throw CalendarProviderError.notSupported(Self.uncopiedItemRefusal)
        }
        let cappedBody = try JSONSerialization.data(withJSONObject: cappedJSON)
        return .split(SplitPlan(
            seriesId: eventId, snapshot: snapshot, seriesZone: seriesZone, zone: zone, place: place, splitPlace: splitPlace,
            namedStart: namedStart, namedPlace: namedPlace, partPatch: partPatch, mode: mode, createJSON: createJSON,
            exceptions: exceptions, parts: parts, seriesCopy: seriesCopy, carriedCopies: carriedCopies, cappedBody: cappedBody))
    }

    /// What `splitPlan` worked out: a split, or the edit of the occurrences shown past the series'
    /// last place.
    private enum SplitPlanned {
        case split(SplitPlan)
        case shown(ShownPlan)
    }

    /// A split as `splitPlan` worked it out, before anything is written: the series (`seriesId`,
    /// read as `snapshot`) and its zone, where it is cut (`place`, `splitPlace`), the occurrence
    /// named (`namedStart`, `namedPlace`), the edit moved to the cut (`partPatch`) and its `mode`,
    /// the new part's create body, the series' exceptions sorted around the cut, what is copied
    /// onto the new part and onto each carried occurrence, and the cap's body.
    private struct SplitPlan {
        let seriesId: String
        let snapshot: EditSnapshot
        let seriesZone: String?
        let zone: TimeZone?
        let place: String
        let splitPlace: GCalDateTime
        let namedStart: GCalDateTime
        let namedPlace: GCalDateTime
        let partPatch: GCalEventInput
        let mode: SplitCarry.Mode
        let createJSON: [String: Any]
        let exceptions: [TailException]
        let parts: SplitCarry.Parts
        let seriesCopy: AttachmentCopyPlan
        let carriedCopies: [String: AttachmentCopyPlan]
        let cappedBody: Data
    }

    /// `CalendarProvider.refuseSeriesWrite`: each write's own plan, with nothing written.
    /// - An edit of every occurrence that changes the series' length reads what its write puts
    ///   back (`lengthChangeExceptions`, from the series as the write reads it); any other makes no
    ///   request.
    /// - A split runs `splitPlan`.
    /// - A delete of an occurrence and every later one runs `endPlan`.
    func refuseSeriesWrite(calendarId: String = "primary", write: SeriesWrite) async throws {
        switch write {
        case .everyOccurrence(let seriesId, let series, let edit):
            try Self.refuseUnrepresentableRule(edit.recurrence)
            guard series.recurrence?.isEmpty == false, movesSeriesTime(edit, existing: series),
                  SplitCarry.lengthChange(edit, series: series) else { return }
            let existing = try await fetchForEdit(eventId: seriesId, select: Self.readSelect)
            _ = try await lengthChangeExceptions(eventId: seriesId, existing: existing, edit: edit, files: nil)
        case .split(let eventId, let recurrenceId, let zone, let edit):
            _ = try await splitPlan(eventId: eventId, recurrenceId: recurrenceId, recurrenceIdZone: zone, patch: edit)
        case .followingDelete(let seriesId, let slot, let zone):
            _ = try await endPlan(seriesId: seriesId, before: slot, zone: zone, refusal: .followingDelete)
        }
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

    /// The rest of the split `record` names (`CalendarProvider.finishSplit`), by `endSeries`: its
    /// carry and then its cap, worked out from the series as it is now, and nothing when the series
    /// already ends before the split (`splitAlreadyEnded`). The cap is the split's last write, so an
    /// uncapped series may not be carried yet: the carry is planned again from the series'
    /// exceptions, untouched until the cap, and the new part as it is now (#563).
    func finishSplit(calendarId: String = "primary", record: SplitRecord, zone: TimeZone, guests: AttendeeChange?) async throws {
        try await endSeries(seriesId: record.seriesId, before: record.splitAt, zone: zone, refusal: .change, finishing: (record, guests))
    }

    /// End the series `seriesId` just before `slot` (`CalendarProvider.endSeries`): the cap
    /// `splitSeries` writes, worked out from the series as it is now, and nothing when the series
    /// already ends before `slot` (`splitAlreadyEnded`). Graph's PATCH has no `sendUpdates`, so it
    /// is unused here, as in every write of this provider.
    func endSeries(calendarId: String = "primary", seriesId: String, before slot: String, zone: TimeZone, sendUpdates: String) async throws {
        try await endSeries(seriesId: seriesId, before: slot, zone: zone, refusal: .followingDelete, finishing: nil)
    }

    /// `endSeries` for a split's finish (`refusal` `.change`; the split `finishing` names, whose carry
    /// is written after the check that the series does not already end and before the cap,
    /// `finishSplitOccurrences`) and for a delete of an
    /// occurrence and every later one (`.followingDelete`): the same cap, refused for a zone TabMail
    /// does not recognize in the words that fit what the user asked for.
    private func endSeries(
        seriesId: String, before slot: String, zone: TimeZone, refusal: ZoneRefusal,
        finishing split: (record: SplitRecord, guests: AttendeeChange?)?
    ) async throws {
        let plan = try await endPlan(seriesId: seriesId, before: slot, zone: zone, refusal: refusal)
        guard let cappedJSON = plan.cappedJSON else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] endSeries: series \(seriesId) already ends before \(slot) — nothing to write")
            }
            return
        }
        if let split {
            try await finishSplitOccurrences(record: split.record, stored: plan.stored, zone: zone, guests: split.guests)
        }
        try await writeSplitCap(seriesId: seriesId, body: try JSONSerialization.data(withJSONObject: cappedJSON))
    }

    /// `endSeries`' plan, read and worked out before anything is written: the series as stored now,
    /// and the cap's body, nil when the series already ends before `slot` (`splitAlreadyEnded`).
    /// Throws, with nothing written, what the cap refuses: a series that no longer repeats, and
    /// one whose zone can't be read, in `refusal`'s words (`splitCapEndDate`). The one plan
    /// `endSeries` writes and a delete's card checks (`refuseSeriesWrite`).
    private func endPlan(
        seriesId: String, before slot: String, zone: TimeZone, refusal: ZoneRefusal
    ) async throws -> (stored: EditSnapshot, cappedJSON: [String: Any]?) {
        let stored = try await fetchForEdit(eventId: seriesId, select: Self.splitSelect)
        guard let storedRecurrence = stored.raw["recurrence"] as? [String: Any],
              let storedRange = storedRecurrence["range"] as? [String: Any] else {
            throw CalendarProviderError.notSupported("Can't finish this change to the repeating event: it no longer repeats. Check the event in your calendar app.")
        }
        let capEndDate = try Self.splitCapEndDate(stored: stored, splitNaiveISO: slot, splitZone: zone, refusal: refusal)
        guard let cappedJSON = Self.splitCapJSON(master: stored.event, storedRecurrence: storedRecurrence, capEndDate: capEndDate) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(slot)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        if try Self.splitAlreadyEnded(
            stored: stored, storedRange: storedRange, capEndDate: capEndDate, splitNaiveISO: slot, splitZone: zone) {
            return (stored, nil)
        }
        return (stored, cappedJSON)
    }

    /// A split's retry before its cap (`finishSplit`): the plan, its refusals, the series' files and
    /// the carry, from the series `stored` as it is now.
    private func finishSplitOccurrences(record: SplitRecord, stored: EditSnapshot, zone: TimeZone, guests: AttendeeChange?) async throws {
        let seriesZone = stored.event.seriesZoneName
        let seriesTimeZone = try Self.seriesTimeZone(stored)
        guard let split = Self.splitPlace(naiveISO: record.splitAt, allDay: stored.event.isAllDay, zone: zone) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(record.splitAt)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let exceptions = try await seriesExceptions(seriesId: record.seriesId, series: stored.event, seriesZone: seriesZone, zone: seriesTimeZone)
        let newPart = try await getEvent(eventId: record.newPartId)
        // What the retry copies, decided before its first write, as `splitSeries` decides it: the
        // series' files the first attempt did not copy, and each changed occurrence it
        // carries. A linked file or an attached Outlook item on the SERIES stays on the old part,
        // which keeps the series. One a carried occurrence gained since the first attempt would be
        // on neither part once the cap takes that occurrence off the old part, so the retry is
        // refused before it writes anything, and the user sees both parts showing the later
        // occurrences, as the first attempt left them (#834, #847).
        let seriesCopy = try await copyPlan(of: record.seriesId, context: "Graph series master id")
        let (_, carried) = try Self.splitCarry(record: record, cut: split, exceptions: exceptions, series: stored.event, zone: seriesTimeZone, newPart: newPart)
        var carriedCopies: [String: AttachmentCopyPlan] = [:]
        for id in carried.changed.compactMap(\.exception.id) where carriedCopies[id] == nil {
            carriedCopies[id] = try await copyPlan(of: id, context: "Graph event instance id")
        }
        if carriedCopies.values.contains(where: \.hasLinkedFile) {
            throw CalendarProviderError.notSupported(Self.retryLinkedFileRefusal)
        }
        if carriedCopies.values.contains(where: \.holdsItem) {
            throw CalendarProviderError.notSupported(Self.retryUncopiedItemRefusal)
        }
        try await copy(seriesCopy, from: record.seriesId, to: record.newPartId, context: "Graph series master id")
        try await writeSplitOccurrences(
            record: record, cut: split, exceptions: exceptions, series: stored.event, seriesRaw: stored.raw,
            newPart: newPart, guests: guests, seriesZone: seriesZone, zone: seriesTimeZone, copies: carriedCopies)
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
            guard let seriesStart = counted.seriesStart,
                  let before = RecurrenceTail.occurrences(
                      of: counted.rule, seriesStart: seriesStart, before: counted.split, anchor: .patternStart, missingDay: .lastDay)
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
    /// naming the series' zone `seriesZone`, so an all-day place is its date; a deleted timed
    /// one is placed at the series' time of day on its date in `zone` (`seriesTimeZone`). Nothing
    /// is written; a deletion that can't be placed is refused, with `unplaced` when given. A read
    /// that can't be used is refused in the caller's words (`refusal`).
    private func seriesExceptions(
        seriesId: String, series: GCalEvent, seriesZone: String?, zone: TimeZone?,
        refusal: String = "the occurrences of this repeating event changed or deleted one by one can't be read, so it was not split",
        unplaced: Error? = nil
    ) async throws -> [TailException] {
        let unreadable = CalendarProviderError.notSupported(refusal)
        let encodedId = try Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
        let expanded = try await request(path: "/events/\(encodedId)?$expand=exceptionOccurrences", timeZoneName: seriesZone)
        guard let expandedJSON = try JSONSerialization.jsonObject(with: expanded) as? [String: Any] else { throw unreadable }
        var found: [TailException] = []
        for raw in expandedJSON["exceptionOccurrences"] as? [[String: Any]] ?? [] {
            guard let exception = try changedException(raw, series: series) else { throw unreadable }
            found.append(exception)
        }
        let cancelled = try await request(path: "/events/\(encodedId)?$select=cancelledOccurrences", timeZoneName: seriesZone)
        guard let cancelledJSON = try JSONSerialization.jsonObject(with: cancelled) as? [String: Any] else { throw unreadable }
        for name in cancelledJSON["cancelledOccurrences"] as? [String] ?? [] {
            let date = String(name.suffix(10))
            guard RecurrenceTail.Day(iso: date) != nil else { throw unreadable }
            guard let place = Self.deletedPlace(date: date, series: series, zone: zone) else { throw unplaced ?? unreadable }
            found.append(TailException(carried: .deleted(place: place), raw: [:]))
        }
        return found
    }

    /// Outlook's deleted occurrences: the series' `cancelledOccurrences`, each named by its date in
    /// the series' zone (measured), placed as `seriesExceptions` places them (`deletedPlace`). One
    /// read, with `Prefer` naming the series' zone. Throws `notSupported` when it can't be read or
    /// a date can't be placed (a timed series whose zone can't be read).
    func deletedOccurrencePlaces(calendarId: String, seriesId: String, series: GCalEvent) async throws -> [GCalDateTime] {
        let unreadable = CalendarProviderError.notSupported("the occurrences deleted from this repeating event can't be read")
        let encodedId = try Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
        let data = try await request(path: "/events/\(encodedId)?$select=cancelledOccurrences", timeZoneName: series.seriesZoneName)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unreadable }
        return try (json["cancelledOccurrences"] as? [String] ?? []).map { name in
            let date = String(name.suffix(10))
            guard RecurrenceTail.Day(iso: date) != nil,
                  let place = Self.deletedPlace(date: date, series: series, zone: series.seriesZone) else { throw unreadable }
            return place
        }
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
    /// `copies` holds what `copyPlan` decided for a carried occurrence before the split wrote
    /// anything; one it does not hold (a retry) is decided here, before the carry writes.
    private func writeSplitOccurrences(
        record: SplitRecord, cut: GCalDateTime, exceptions: [TailException], series: GCalEvent, seriesRaw: [String: Any],
        newPart: GCalEvent, guests: AttendeeChange?, seriesZone: String?, zone: TimeZone?, copies: [String: AttachmentCopyPlan]
    ) async throws {
        let unreadable = Self.splitOccurrenceUnreadable
        let (parts, plan) = try Self.splitCarry(record: record, cut: cut, exceptions: exceptions, series: series, zone: zone, newPart: newPart)
        var copies = copies
        for id in plan.changed.compactMap(\.exception.id) where copies[id] == nil {
            copies[id] = try await copyPlan(of: id, context: "Graph event instance id")
        }
        try await carry(
            plan, exceptions: exceptions, series: series, seriesRaw: seriesRaw, newPartId: record.newPartId,
            fields: record.fields, guests: guests, seriesZone: seriesZone, zone: zone, copies: copies)
        guard let edits = SplitCarry.edits(
            of: parts.edited, targets: record.edits, length: SplitCarry.length(of: newPart), fields: record.fields) else { throw unreadable }
        let values = SplitCarry.values(of: newPart, fields: record.fields)
        for edit in try Self.editOrder(edits, zone: zone) {
            guard let id = edit.exception.id else { throw unreadable }
            _ = try await patchOccurrence(instanceId: id, event: SplitCarry.input(for: edit, values: values, guests: guests))
        }
    }

    /// The series' exceptions sorted around the cut `cut` (`SplitCarry.partition`, named as
    /// `record` keeps) and the carry onto the new part `newPart` (`SplitCarry.carryPlan`), as
    /// `writeSplitOccurrences` writes them.
    private static func splitCarry(
        record: SplitRecord, cut: GCalDateTime, exceptions: [TailException], series: GCalEvent, zone: TimeZone?, newPart: GCalEvent
    ) throws -> (parts: SplitCarry.Parts, plan: SplitCarry.Plan) {
        let namedStart = record.namedStart.flatMap(SplitCarry.time) ?? cut
        let namedPlace = record.namedPlace.flatMap(SplitCarry.time) ?? cut
        guard let parts = SplitCarry.partition(exceptions.map(\.carried), cut: .at(cut), namedStart: namedStart),
              let plan = try SplitCarry.carryPlan(
                parts: parts, mode: record.mode, namedStart: namedStart, namedPlace: namedPlace, cut: cut, series: series,
                zone: zone, newPart: newPart, fields: record.fields, missingDay: .lastDay)
        else { throw splitOccurrenceUnreadable }
        return (parts, plan)
    }

    private static let splitOccurrenceUnreadable =
        CalendarProviderError.notSupported("a changed occurrence of this repeating event has a time TabMail can't read, so the change can't be finished")

    /// A "this and following" edit at an occurrence moved past the series' last place
    /// (`SplitCarry.Cut.pastEnd`): no new part and no cap; the edit is written onto every
    /// occurrence shown from the one named on, each as a "this occurrence" edit in the order
    /// Graph takes moves (`editOrder`), to an absolute target worked out once and kept on the
    /// operation's record before the first write (`SplitCarry.shownEdits`), so a retry
    /// (`finishShownEdit`) never moves one twice. An edit of the rule is refused: no part is left
    /// to take it.
    private func editShown(_ shown: ShownPlan, patch: GCalEventInput, record: SplitRecorder) async throws -> GCalEvent {
        try await record(shown.record)
        return try await writeShownEdits(
            shown.ordered, values: SplitCarry.values(of: patch, fields: shown.record.fields), guests: patch.attendeeChange) ?? shown.named
    }

    /// An edit past the series' last place as `editShown` writes it, worked out before its record
    /// and first write: the occurrence named, the record, and the edits in the order Graph takes.
    private struct ShownPlan {
        let named: GCalEvent
        let record: SplitRecord
        let ordered: [SplitCarry.Edit]
    }

    /// `editShown`'s plan for the series `series` (`seriesId`) named at `named`, with nothing
    /// written: an edit of the rule is refused, and so are edits whose times can't be read or that
    /// Graph can't take in order.
    private func shownPlan(
        seriesId: String, series: GCalEvent, named: GCalEvent, patch: GCalEventInput, seriesZone: String?, zone: TimeZone?
    ) async throws -> ShownPlan {
        guard patch.recurrence == nil, patch.ruleDayMove == nil else {
            throw CalendarProviderError.notSupported(SplitCarry.pastEndRuleRefusal)
        }
        let exceptions = try await seriesExceptions(seriesId: seriesId, series: series, seriesZone: seriesZone, zone: zone)
        guard let shown = SplitCarry.shownEdits(exceptions: exceptions.map(\.carried), named: named, seriesId: seriesId, patch: patch) else {
            throw CalendarProviderError.notSupported(Self.shownEditUnreadable)
        }
        // Ordered before the record and the first write, so edits Graph can't take are refused
        // with nothing written.
        return ShownPlan(named: named, record: shown.record, ordered: try Self.editOrder(shown.edits, zone: zone))
    }

    /// `CalendarProvider.finishShownEdit`: the edits of `record` still to write, from the series'
    /// exceptions as they are now (`SplitCarry.shownEdits(exceptions:record:)`).
    func finishShownEdit(calendarId: String = "primary", record: SplitRecord, edit: GCalEventInput, guests: AttendeeChange?) async throws {
        let (seriesId, snapshot) = try await resolveToMaster(eventId: record.seriesId, select: Self.splitSelect)
        let zone = try Self.seriesTimeZone(snapshot)
        let exceptions = try await seriesExceptions(seriesId: seriesId, series: snapshot.event, seriesZone: snapshot.event.seriesZoneName, zone: zone)
        guard let edits = SplitCarry.shownEdits(exceptions: exceptions.map(\.carried), record: record) else {
            throw CalendarProviderError.notSupported(Self.shownEditUnreadable)
        }
        _ = try await writeShownEdits(
            try Self.editOrder(edits, zone: zone), values: SplitCarry.values(of: edit, fields: record.fields), guests: guests)
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
    /// and refused: the split stops before its cap, with the series whole. (`updateSeries`' put-back
    /// onto the series itself is `putBack`.)
    private func carry(
        _ plan: SplitCarry.Plan, exceptions: [TailException], series: GCalEvent, seriesRaw: [String: Any], newPartId: String,
        fields: Set<SplitCarry.Field>, guests: AttendeeChange?, seriesZone: String?, zone: TimeZone?, copies: [String: AttachmentCopyPlan]
    ) async throws {
        guard !plan.deleted.isEmpty || !plan.changed.isEmpty else { return }
        let listed = try await instances(around: plan, series: series, partId: newPartId, seriesZone: seriesZone, zone: zone)

        // 1. The deleted places first: each frees its date for a move.
        for place in plan.deleted {
            guard let id = listed.instance(at: place)?["id"] as? String else { continue }
            let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
            do {
                _ = try await request(path: "/events/\(encoded)", method: "DELETE")
            } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {
                continue
            }
        }

        // 2. The changed ones, each move once the date it moves to is free.
        let difference = Self.guestDifference(guests, seriesRaw: seriesRaw)
        for change in try Self.carryOrder(plan.changed, zone: zone) {
            // A changed occurrence the new part does not list can't be carried: refused before the
            // cap, with the series whole. (A deleted place not listed is done, above.)
            guard let id = listed.instance(at: change.place)?["id"] as? String else {
                throw CalendarProviderError.notSupported("a changed occurrence of this repeating event isn't on its new part, so its change can't be carried")
            }
            let json = carriedWrite(change, exceptions: exceptions, fields: fields, difference: difference, series: series, seriesZone: seriesZone)
            let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
            _ = try await request(path: "/events/\(encoded)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: json))
            // The occurrence's own attachments, as the series' are copied onto the new part. Its
            // copies of the series' files pair with the copies this instance now holds (name, kind
            // and content, `copy`), so only its own files are written, and a retry adds only what
            // is missing.
            if let source = change.exception.id, let planned = copies[source] {
                try await copy(planned, from: source, to: id, context: "Graph event instance id")
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] split carried a changed occurrence onto \(id): keys=\(json.keys.sorted()) times=\(change.start != nil)")
            }
        }
    }

    /// The occurrences of the series `partId` (a split's new part, or a series put back onto
    /// itself) listed around every place `plan` names and every time a carried one moves to, each
    /// found by its place (`originalStart`): instant equality for a timed series, the date in the
    /// series' zone for an all-day place. The window is dated in UTC: its two days before and
    /// three after cover any zone's offset. Every page is read.
    private func instances(
        around plan: SplitCarry.Plan, series: GCalEvent, partId: String, seriesZone: String?, zone: TimeZone?
    ) async throws -> ListedInstances {
        let unplaced = CalendarProviderError.notSupported(
            "an occurrence of this repeating event can't be dated in its time zone, so its change can't be carried")
        let windowZone = series.isAllDay ? nil : TimeZone.gmt
        var dates: [String] = []
        for time in plan.deleted + plan.changed.flatMap({ [$0.place] + ($0.start.map { [$0] } ?? []) }) {
            guard let date = Self.seriesDate(of: time, seriesZone: windowZone) else { throw unplaced }
            dates.append(date)
        }
        guard let first = dates.min().flatMap({ RecurrenceTail.Day(iso: $0) }), let last = dates.max().flatMap({ RecurrenceTail.Day(iso: $0) }),
              let from = GoogleCalendarProvider.naiveInstant(first.description, zone: .gmt)?.addingTimeInterval(-2 * 86_400),
              let to = GoogleCalendarProvider.naiveInstant(last.description, zone: .gmt)?.addingTimeInterval(3 * 86_400) else { throw unplaced }
        let encodedPart = try Self.encodedGraphPathSegment(partId, context: "Graph event id")
        var instances: [[String: Any]] = []
        var next: String? = "/events/\(encodedPart)/instances?startDateTime=\(from.iso8601String())&endDateTime=\(to.iso8601String())&$top=1000"
        while let path = next {
            let listed = try await request(path: path, timeZoneName: seriesZone)
            guard let page = try JSONSerialization.jsonObject(with: listed) as? [String: Any] else {
                throw CalendarProviderError.notSupported("the new part's occurrences can't be read, so the changed ones can't be carried")
            }
            instances += page["value"] as? [[String: Any]] ?? []
            next = try (page["@odata.nextLink"] as? String).map { try graphPath(ofNextLink: $0) }
        }
        return ListedInstances(instances: instances, allDay: series.isAllDay, zone: zone)
    }

    /// A series' occurrences as `instances(around:)` read them, found by place.
    struct ListedInstances {
        let instances: [[String: Any]]
        let allDay: Bool
        let zone: TimeZone?

        func instance(at place: GCalDateTime) -> [String: Any]? {
            instances.first { instance in
                guard let original = instance["originalStart"] as? String, let at = Date.fromISO8601(original) else { return false }
                if let date = place.date {
                    let originalDate = allDay ? String(original.prefix(10)) : zone.map { String(SplitCarry.naive(at, in: $0).prefix(10)) }
                    return originalDate == String(date.prefix(10))
                }
                return place.dateTime.flatMap(Date.fromISO8601) == at
            }
        }
    }

    /// The series' guest change `guests` as the difference each carried occurrence's own guests
    /// take (`AttendeeChange.seriesDifference`), from the series' guests in `seriesRaw`.
    nonisolated static func guestDifference(_ guests: AttendeeChange?, seriesRaw: [String: Any]) -> AttendeeChange? {
        let seriesGuests = seriesRaw["attendees"] as? [[String: Any]] ?? []
        return guests.map { change in
            change.seriesDifference(before: seriesGuests, after: appliedAttendeesJSON(change, to: seriesGuests)) {
                (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased()
            }
        }
    }

    /// The PATCH a carry writes for the changed occurrence `change`: its own values of the fields
    /// the edit did not set (`carriedJSON`), its own guests with the series' difference applied,
    /// and its own times labelled in the series' zone (#747).
    private func carriedWrite(
        _ change: SplitCarry.Change, exceptions: [TailException], fields: Set<SplitCarry.Field>,
        difference: AttendeeChange?, series: GCalEvent, seriesZone: String?
    ) -> [String: Any] {
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
        return json
    }

    /// `updateSeries`' put-back onto the series `seriesId` itself, after its PATCH reset it (#718):
    /// the occurrences are found among the series' `/instances` by their place, as a split's carry
    /// finds them (`instances(around:)`), and written one at a time, in order.
    ///
    /// Each write is guarded so it never overwrites a change made since the reset by anyone else:
    /// - a deleted place is deleted again only while Graph lists a plain occurrence there (`type`
    ///   "occurrence"); one changed since is the user's, left as it is and counted;
    /// - a changed occurrence is written only while it is a plain occurrence, read right before
    ///   its PATCH, which sends that read's etag (`If-Match`, `guardedPatch`): Graph refuses it
    ///   with 412 when anything in the series changed in between (the etag is series-wide,
    ///   measured 2026-11-14), and it is read and judged again. One that already holds what the
    ///   PATCH sends (an earlier attempt's write, `holdsValues`) is done; any other is left as it
    ///   is and counted.
    /// - A changed occurrence is found by its place among the listed instances, else by its own id
    ///   (Graph keeps an occurrence's id through the reset, measured): the listing reads a window
    ///   by each occurrence's start NOW, so one moved since out of the window is not listed, and
    ///   its absence proves nothing. Only Graph's 404 or 410 for its id proves it was deleted
    ///   since: it is done, and the files saved for it are released.
    ///
    /// The files a changed occurrence held of its own (`PutBackFile`, saved before the series'
    /// PATCH) are attached again (`reattach`), on an occurrence left as it is too: an add only adds.
    ///
    /// Every write that fails for good (`putBackFailsForGood`) and every refusal stops it, with
    /// how many occurrences and files were not put back (`putBackOutcome`), as
    /// `CalendarProviderError.seriesPutBackIncomplete`, which the inbox shows as it is. Any other
    /// error is rethrown, and a retry puts back from the kept record. It ends so too, with the same
    /// counts, when an occurrence was left as it is, a saved file was lost, or a file is too large
    /// for Outlook (`putBackTooLarge`); and it ends with `putBackNotConfirmed` (the operation stays
    /// queued) when a file it attached does not read back, until that has happened on
    /// `ExchangeCalendarConfig.putBackUnconfirmedAttempts` attempts (counted in the record), when
    /// it ends with the files counted as not restored.
    private func putBack(
        _ plan: SplitCarry.Plan, capture: SeriesCapture, series: GCalEvent, seriesId: String,
        fields: Set<SplitCarry.Field>, guests: AttendeeChange?, seriesZone: String?, zone: TimeZone?, ledger: PutBackLedger
    ) async throws {
        let total = plan.deleted.count + plan.changed.count
        var done = 0
        var left = 0
        var lost = 0
        var unconfirmed = 0
        var tooLarge: [String] = []
        do {
            let listed = try await instances(around: plan, series: series, partId: seriesId, seriesZone: seriesZone, zone: zone)
            for place in plan.deleted {
                guard let instance = listed.instance(at: place), let id = instance["id"] as? String else { done += 1; continue }
                // Changed since the reset: the user's, never deleted.
                guard instance["type"] as? String == "occurrence" else { left += 1; continue }
                let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
                do {
                    _ = try await request(path: "/events/\(encoded)", method: "DELETE")
                } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {}
                done += 1
            }
            let seriesPath = try "/events/" + Self.encodedGraphPathSegment(seriesId, context: "Graph series master id")
            let seriesList = SeriesAttachmentList()
            let difference = Self.guestDifference(guests, seriesRaw: capture.seriesRaw)
            for change in try Self.carryOrder(plan.changed, zone: zone) {
                let entries = ledger.held.filter { $0.occurrence == change.exception.id }
                // Not listed at its place: moved out of the window since, or deleted; its own id
                // tells which (`guardedPatch`). Without an id it can't be told: left, its files kept.
                guard let id = listed.instance(at: change.place)?["id"] as? String ?? change.exception.id else {
                    left += 1
                    continue
                }
                let json = carriedWrite(change, exceptions: capture.exceptions, fields: fields, difference: difference, series: series, seriesZone: seriesZone)
                let guarded = try await guardedPatch(id, json: json, seriesZone: seriesZone, allDay: series.isAllDay)
                if guarded == .gone {
                    // Graph says the occurrence is gone: deleted since, its files with it.
                    try await ledger.confirm(entries)
                    done += 1
                    continue
                }
                let restored = guarded == .restored
                if !entries.isEmpty {
                    let outcome = try await reattach(
                        entries, to: id,
                        seriesFiles: {
                            try await seriesList.read { try await self.attachments(of: seriesPath).map { EventAttachment(eventPath: seriesPath, meta: $0) } }
                                .filter { ExchangeProvider.isFileAttachment($0.meta) }
                        },
                        date: Self.occurrenceDate(change.start ?? change.place, seriesZone: seriesZone), ledger: ledger)
                    lost += outcome.lost
                    unconfirmed += outcome.unconfirmed
                    tooLarge += outcome.tooLarge
                }
                if restored { done += 1 } else { left += 1 }
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] put back onto \(id): restored=\(restored) files=\(entries.count)")
                }
            }
        } catch where Self.putBackFailsForGood(error) {
            let remaining = total - done
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ExchangeCalendar] put-back onto \(seriesId) stopped with \(remaining) left: \(error)")
            }
            throw CalendarProviderError.seriesPutBackIncomplete(Self.putBackOutcome(events: remaining, files: ledger.held.count + lost))
        }
        // A file that never reads back is added again by each retry, so the retries are bounded:
        // past the bound the files stay saved with the failed operation, as a refused one does.
        if unconfirmed > 0, try await ledger.countUnconfirmed() < ExchangeCalendarConfig.putBackUnconfirmedAttempts {
            throw ExchangeCalendarError.putBackNotConfirmed
        }
        let files = ledger.held.count + lost
        guard left > 0 || files > 0 else { return }
        throw CalendarProviderError.seriesPutBackIncomplete((tooLarge + [Self.putBackOutcome(events: left, files: files)]).joined(separator: " "))
    }

    /// The date an occurrence starting at `time` is on, as the user is told it: plain Gregorian
    /// English ("December 7, 2026"), in the series' zone `seriesZone` (an all-day date as written).
    nonisolated static func occurrenceDate(_ time: GCalDateTime, seriesZone: String?) -> String {
        let zone = seriesZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } ?? .gmt
        let day: Date?
        if let date = time.date {
            day = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: zone).date(from: String(date.prefix(10)))
        } else {
            day = time.dateTime.flatMap(Date.fromISO8601)
        }
        guard let day else { return String((time.date ?? time.dateTime ?? "").prefix(10)) }
        return FixedDateFormat.formatter("MMMM d, yyyy", timeZone: zone).string(from: day)
    }

    /// The occurrence `id` written with `json` only while it is a plain occurrence (`type`
    /// "occurrence": nobody wrote to it since the reset): read right before the PATCH, which
    /// sends the read's `@odata.etag` as `If-Match`. Graph's etag is series-wide and moves with
    /// any write in the series, so a 412 means something in the series changed since the read:
    /// it is read and judged again, at most `ExchangeCalendarConfig.putBackConflictReads` times,
    /// then `seriesBusy` (the operation stays queued). `restored` when the occurrence holds
    /// `json`'s values: written, or already (`holdsValues`, an earlier attempt's write); `gone`
    /// when Graph answers its read 404 or 410; `left` when it is left as it is: changed by someone
    /// else, or a read that can't be judged.
    private func guardedPatch(_ id: String, json: [String: Any], seriesZone: String?, allDay: Bool) async throws -> GuardedPatch {
        let encoded = try Self.encodedGraphPathSegment(id, context: "Graph event instance id")
        let body = try JSONSerialization.data(withJSONObject: json)
        var reads = 0
        while true {
            reads += 1
            let data: Data
            do {
                data = try await request(path: "/events/\(encoded)", timeZoneName: seriesZone)
            } catch ExchangeCalendarError.httpError(let code, _) where code == 404 || code == 410 {
                return .gone
            }
            guard let instance = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .left }
            switch instance["type"] as? String {
            case "occurrence":
                guard let etag = instance["@odata.etag"] as? String, !etag.isEmpty else { return .left }
                do {
                    _ = try await request(path: "/events/\(encoded)", method: "PATCH", body: body, headers: ["If-Match": etag])
                    return .restored
                } catch ExchangeCalendarError.httpError(let code, _) where code == Self.preconditionFailed {
                    guard reads < ExchangeCalendarConfig.putBackConflictReads else { throw ExchangeCalendarError.seriesBusy }
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[ExchangeCalendar] put-back of \(id) refused by its etag (read \(reads)): reading it again")
                    }
                }
            case "exception":
                return Self.holdsValues(instance, json, allDay: allDay) ? .restored : .left
            default:
                return .left
            }
        }
    }

    /// What `guardedPatch` found the occurrence to be.
    enum GuardedPatch {
        case restored
        case left
        case gone
    }

    /// The status Graph refuses a write whose `If-Match` etag is stale with (`ErrorIrresolvableConflict`).
    static let preconditionFailed = 412

    /// Whether the occurrence `instance` (read with `Prefer` naming the series' zone) holds every
    /// value of the PATCH `sent`, compared as Graph gives them back: times as instants (an all-day
    /// one as its date), guests as a set of address and type (their answers are theirs),
    /// categories as a set, a place by its name, the body by its type and its text with the HTML
    /// stripped and the spaces collapsed (Exchange rewrites the markup), a series' rule by every
    /// value sent (Graph gives back more: its own defaults; names in any case, lists as sets),
    /// anything else as JSON. Any value it can't read is not equal (the occurrence is then left as
    /// it is).
    nonisolated static func holdsValues(_ instance: [String: Any], _ sent: [String: Any], allDay: Bool) -> Bool {
        func canonical(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return "null" }
            return (try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
        func instant(_ value: Any?) -> String? {
            guard let time = value as? [String: Any], let wall = time["dateTime"] as? String else { return nil }
            if allDay { return String(wall.prefix(10)) }
            guard let label = time["timeZone"] as? String, let zone = CalendarTimeZoneResolver.zone(named: label, in: .none),
                  let at = FixedDateFormat.formatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: zone).date(from: String(wall.prefix(19)))
            else { return nil }
            return String(at.timeIntervalSince1970)
        }
        func guests(_ value: Any?) -> Set<String>? {
            guard let list = value as? [[String: Any]] else { return value == nil || value is NSNull ? [] : nil }
            return Set(list.map { guest in
                let address = ((guest["emailAddress"] as? [String: Any])?["address"] as? String ?? "").lowercased()
                return "\(address)|\(guest["type"] as? String ?? "")"
            })
        }
        func place(_ value: Any?) -> String { (value as? [String: Any])?["displayName"] as? String ?? "" }
        func rule(_ held: Any?, holds value: Any?) -> Bool {
            switch value {
            case let sent as [String: Any]:
                guard let held = held as? [String: Any] else { return false }
                return sent.allSatisfy { rule(held[$0.key], holds: $0.value) }
            case let sent as [String]:
                guard let held = held as? [String] else { return false }
                return Set(sent.map { $0.lowercased() }) == Set(held.map { $0.lowercased() })
            case let sent as String:
                return (held as? String)?.caseInsensitiveCompare(sent) == .orderedSame
            case let sent as NSNumber:
                return (held as? NSNumber) == sent
            default:
                let a = canonical(value), b = canonical(held)
                return a != nil && a == b
            }
        }
        func text(_ value: Any?) -> String? {
            guard let body = value as? [String: Any] else { return value == nil || value is NSNull ? "" : nil }
            let content = (body["content"] as? String ?? "")
                .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "\((body["contentType"] as? String ?? "").lowercased())|\(content)"
        }
        for (key, value) in sent {
            let held = instance[key]
            let same: Bool
            switch key {
            case "start", "end":
                let a = instant(value), b = instant(held)
                same = a != nil && a == b
            case "attendees":
                let a = guests(value), b = guests(held)
                same = a != nil && a == b
            case "categories":
                same = Set(value as? [String] ?? []) == Set(held as? [String] ?? [])
                    && (value as? [String] != nil || value is NSNull) && (held == nil || held is NSNull || held as? [String] != nil)
            case "location":
                same = place(value) == place(held)
            case "locations":
                same = ((value as? [[String: Any]]) ?? []).map(place) == ((held as? [[String: Any]]) ?? []).map(place)
            case "body":
                let a = text(value), b = text(held)
                same = a != nil && a == b
            case "recurrence":
                same = rule(held, holds: value)
            default:
                let a = canonical(value), b = canonical(held)
                same = a != nil && a == b
            }
            guard same else { return false }
        }
        return true
    }

    /// The series' attachments, read once, when first needed.
    final class SeriesAttachmentList: Sendable {
        private let list = Mutex<[EventAttachment]?>(nil)
        func read(_ load: @Sendable () async throws -> [EventAttachment]) async throws -> [EventAttachment] {
            if let held = list.withLock({ $0 }) { return held }
            let read = try await load()
            list.withLock { $0 = read }
            return read
        }
    }

    /// What `reattach` did not finish: saved copies lost (missing or corrupt, their entries
    /// dropped), files attached that did not read back, and the refusals of files too large.
    struct ReattachOutcome {
        var lost = 0
        var unconfirmed = 0
        var tooLarge: [String] = []
    }

    /// Attaches again to the occurrence `targetId` the files `entries` it held of its own before
    /// the series' write (#718), add-only, from their saved copies (`SavedFiles.load`), as a
    /// split's copy adds a file (`ExchangeProvider.addFileAttachment`, with its inline placement).
    ///
    /// What the occurrence holds of its own is what does not pair with the series' files by name,
    /// kind and content (`AttachmentPairing.unpaired`; an exception holds copies of the series');
    /// an entry it pairs with is there. Only the missing ones are added, so a retry adds each file
    /// once, and nothing is ever removed. After the adds the occurrence is read again: an entry is
    /// released (`PutBackLedger.confirm`) only once a read shows it there, never on an add's 201.
    /// A saved copy that is missing or no longer matches is dropped and counted (`lost`); a file
    /// Outlook refuses as too large (`ErrorMessageSizeExceeded`) stays saved and is counted
    /// (`tooLarge`); any other failure is thrown.
    private func reattach(
        _ entries: [PutBackFile], to targetId: String, seriesFiles: @Sendable () async throws -> [EventAttachment],
        date: String, ledger: PutBackLedger
    ) async throws -> ReattachOutcome {
        let target = try "/events/" + Self.encodedGraphPathSegment(targetId, context: "Graph event instance id")
        let fileKind = "#microsoft.graph.fileattachment"
        @Sendable func digest(_ file: EventAttachment) async throws -> String { AttachmentPairing.contentDigest(try await fileBytes(file).data) }
        func own() async throws -> [EventAttachment] {
            let held = try await attachments(of: target).filter(ExchangeProvider.isFileAttachment).map { EventAttachment(eventPath: target, meta: $0) }
            return try await AttachmentPairing.unpaired(
                held, against: try await seriesFiles(), name: { Self.attachmentName($0.meta) }, kind: { Self.attachmentKind($0.meta) },
                content: digest)
        }
        func missing(_ wanted: [PutBackFile], from own: [EventAttachment]) async throws -> [PutBackFile] {
            let paired = try await AttachmentPairing.unpaired(
                wanted.map(PairedFile.saved), against: own.map(PairedFile.listed),
                name: { file in
                    switch file {
                    case .saved(let entry): entry.name
                    case .listed(let listed): Self.attachmentName(listed.meta)
                    }
                },
                kind: { file in
                    switch file {
                    case .saved: fileKind
                    case .listed(let listed): Self.attachmentKind(listed.meta)
                    }
                },
                content: { file in
                    switch file {
                    case .saved(let entry): entry.sha256
                    case .listed(let listed): try await digest(listed)
                    }
                })
            return paired.compactMap { if case .saved(let entry) = $0 { entry } else { nil } }
        }
        var outcome = ReattachOutcome()
        let toAdd = try await missing(entries, from: try await own())
        var added: [PutBackFile] = []
        var lostEntries: [PutBackFile] = []
        for entry in toAdd {
            let data: Data
            do {
                data = try ledger.load(entry.sha256)
            } catch {
                lostEntries.append(entry)
                continue
            }
            do {
                try await ExchangeProvider.addFileAttachment(
                    DraftAttachment(filename: entry.name, mimeType: entry.contentType, data: data),
                    itemPath: target,
                    inline: GraphInlinePlacement(isInline: entry.isInline, contentId: entry.contentId),
                    post: { path, body in try await self.request(path: path, method: "POST", body: body) },
                    rangeRefused: { status, body in
                        if GraphAPI.isMailboxFull(statusCode: status, errorBody: body) { return ExchangeCalendarError.mailboxFull }
                        if GraphAPI.isMessageTooLarge(errorBody: body) { return ExchangeCalendarError.httpError(status, body) }
                        return ExchangeProvider.uploadRangeRefusal(status: status, body: body)
                    },
                    session: testSession ?? sharedEphemeralSession, gate: mailboxGate)
                added.append(entry)
            } catch ExchangeCalendarError.httpError(let status, let body) where GraphAPI.isMessageTooLarge(errorBody: body) {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[ExchangeCalendar] put-back file refused as too large (\(status)) on \(targetId)")
                }
                outcome.tooLarge.append(Self.putBackTooLarge(entry.name, on: date))
            }
        }
        if !lostEntries.isEmpty {
            try await ledger.drop(lostEntries)
            outcome.lost = lostEntries.count
        }
        // Read back: what the occurrence shows is restored; the rest of `added` is not confirmed.
        let stillMissing = added.isEmpty ? toAdd : try await missing(entries, from: try await own())
        let restored = Self.subtracting(entries, stillMissing)
        try await ledger.confirm(restored)
        outcome.unconfirmed = Self.subtracting(stillMissing, Self.subtracting(toAdd, added)).count
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] re-attached \(added.count) of \(entries.count) file(s) to \(targetId); \(restored.count) read back")
        }
        return outcome
    }

    /// `entries` without one entry for each in `removed` (a multiset difference).
    nonisolated static func subtracting(_ entries: [PutBackFile], _ removed: [PutBackFile]) -> [PutBackFile] {
        var left = entries
        for entry in removed {
            if let index = left.firstIndex(of: entry) { left.remove(at: index) }
        }
        return left
    }

    /// A file `reattach` pairs: one saved for the put-back, or one an occurrence lists.
    enum PairedFile: Sendable {
        case saved(PutBackFile)
        case listed(EventAttachment)
    }

    /// The files an edit of every occurrence still has to attach again (`SeriesEditRecord.files`),
    /// and the record they are kept in. An entry leaves it (`confirm`, `drop`) by a kept record
    /// that no longer names it, and only then are bytes no remaining entry names released
    /// (persist before destroy).
    final class PutBackLedger: Sendable {
        private let record: Mutex<SeriesEditRecord>
        private let keep: @Sendable (SeriesEditRecord) async throws -> Void
        private let files: SavedFiles

        init(record: SeriesEditRecord, keep: @escaping @Sendable (SeriesEditRecord) async throws -> Void, files: SavedFiles) {
            self.record = Mutex(record)
            self.keep = keep
            self.files = files
        }

        /// The files not yet attached again.
        var held: [PutBackFile] { record.withLock { $0.files } }

        /// The saved bytes named `name`.
        func load(_ name: String) throws -> Data { try files.load(name) }

        /// `entries` are attached again, or their occurrence is gone.
        func confirm(_ entries: [PutBackFile]) async throws { try await remove(entries) }

        /// `entries`' saved copies are lost: dropped, counted by the caller.
        func drop(_ entries: [PutBackFile]) async throws { try await remove(entries) }

        /// One more attempt attached a file that did not read back: kept in the record, and the
        /// number of such attempts so far returned.
        func countUnconfirmed() async throws -> Int {
            let next = record.withLock { $0 }.countingUnconfirmed()
            try await keep(next)
            record.withLock { $0 = next }
            return next.unconfirmedAttempts
        }

        private func remove(_ entries: [PutBackFile]) async throws {
            guard !entries.isEmpty else { return }
            let next = record.withLock { $0 }.without(entries)
            try await keep(next)
            record.withLock { $0 = next }
            let named = Set(next.files.map(\.sha256))
            for name in Set(entries.map(\.sha256)).subtracting(named) {
                do {
                    try files.release(name)
                } catch {
                    // The bytes stay in the operation's directory; the drain-start sweep removes it once the row is gone.
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[ExchangeCalendar] a saved file could not be released: \(error)")
                    }
                }
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

    /// The new part a split creates, as far as its writes after it need it: its start and end, as
    /// the create body gives them (`mergeMasterAndPatch`, as `splitNewPartJSON` dates them), the
    /// rule it repeats by, read from the create body `createJSON` as a read of the part gives it
    /// (`rrule`: the edit's rule, else the series' pattern with its days turned by a move to another
    /// day and its range ending where the new part does, a numbered one with what is left of its
    /// number, `newPartRecurrence`), and the zone it repeats in, the series' (`seriesZoneName`) as
    /// `splitNewPartJSON` writes it with either rule. Throws when the create body's recurrence
    /// can't be read.
    nonisolated static func plannedPart(
        master: GCalEvent, patch: GCalEventInput, place: String, zone: TimeZone, createJSON: [String: Any]
    ) throws -> GCalEvent {
        let times = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master, patch: patch, newStartNaiveISO: place, newStartZone: zone, newRecurrence: [])
        let rules = try createJSON["recurrence"].map { recurrence in
            rrule(try JSONDecoder().decode(MSPatternedRecurrence.self, from: try JSONSerialization.data(withJSONObject: recurrence)))
        }
        var part = GCalEvent(
            id: nil, summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: times.startDateTime, date: times.startDate, timeZone: times.startTimeZone),
            end: GCalDateTime(dateTime: times.endDateTime, date: times.endDate, timeZone: times.endTimeZone),
            attendees: nil, organizer: nil, recurrence: rules, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil, recurringEventId: nil)
        part.recurrenceTimeZoneName = master.seriesZoneName
        return part
    }

    /// Orders, before anything is written, the moves a split's writes make (`carryPlan` and the
    /// edits of `Parts.edited`) as `carryOrder` and `editOrder` will: throws when one moves by
    /// date and can't be dated in the series' zone, or when a time can't be read. Returns the ids
    /// of the changed occurrences the carry writes onto the new part, whose own attachments it
    /// copies there (`copyPlan`).
    @discardableResult
    nonisolated static func dateSplitMoves(
        parts: SplitCarry.Parts, mode: SplitCarry.Mode, namedStart: GCalDateTime, namedPlace: GCalDateTime, cut: GCalDateTime,
        series: GCalEvent, zone: TimeZone?, newPart: GCalEvent, fields: Set<SplitCarry.Field>
    ) throws -> [String] {
        let shift = SplitCarry.shift(cut: cut, newPart: newPart)
        guard let plan = try SplitCarry.carryPlan(
                parts: parts, mode: mode, namedStart: namedStart, namedPlace: namedPlace, cut: cut, series: series, zone: zone,
                newPart: newPart, fields: fields, missingDay: .lastDay),
              let edits = SplitCarry.edits(of: parts.edited, shift: shift, length: SplitCarry.length(of: newPart), fields: fields) else {
            throw CalendarProviderError.notSupported("a time of this repeating event, its new part or a changed occurrence can't be read, so it was not split")
        }
        _ = try carryOrder(plan.changed, zone: zone)
        _ = try editOrder(edits, zone: zone)
        return plan.changed.compactMap(\.exception.id)
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
    /// master. So the cap is computed directly: endDate = the day before the split occurrence's
    /// day in the series' zone (`splitCapEndDate`). The stored pattern and the rest of the stored
    /// range (its `startDate`, which Graph requires, and its zone) are written back as they are.
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

    /// What a split copies from one event (the series, or a changed occurrence it carries) onto
    /// its counterpart on the new part, decided before any write: every file, in the order the
    /// event lists them, whether the event holds a linked file (`isReferenceAttachment`), which
    /// can't be copied, and whether it holds an attached Outlook item (`isItemAttachment`), which
    /// is never copied (`copyPlan`).
    struct AttachmentCopyPlan {
        var files: [GraphAttachmentMeta] = []
        var hasLinkedFile = false
        var holdsItem = false
    }

    /// Reads what a split copies from the event `sourceId` (`AttachmentCopyPlan`), writing nothing:
    /// its attachment list only. Outlook web's own "this and all following" keeps the series' files
    /// and attached items on the new part (measured 2026-11-13), and a create (`POST /events`)
    /// carries none, since attachments are a separate endpoint. TabMail copies files only. An
    /// attached Outlook item (an email, event, contact or any other kind) is never copied (owner
    /// decision 2026-11-13, #854): Graph's copy of an email reads as an unsent draft without its
    /// own files (#845, #846), an event's as a draft without its meeting options, and a contact's
    /// photo can't be read or written (#852); items of 3 MB or more have no route at all (#835).
    /// On the series the old part keeps it; `splitSeries` and `finishSplit` refuse a carried
    /// occurrence holding one (#847).
    private func copyPlan(of sourceId: String, context: String) async throws -> AttachmentCopyPlan {
        let encodedSource = try Self.encodedGraphPathSegment(sourceId, context: context)
        var plan = AttachmentCopyPlan()
        for attachment in try await attachments(of: "/events/\(encodedSource)") {
            if Self.isReferenceAttachment(attachment) {
                plan.hasLinkedFile = true
            } else if ExchangeProvider.isFileAttachment(attachment) {
                plan.files.append(attachment)
            } else if Self.isItemAttachment(attachment) {
                plan.holdsItem = true
            }
        }
        if DebugModeManager.isLoggingEnabled(), plan.holdsItem {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] split copies no attached item of \(sourceId)")
        }
        return plan
    }

    /// Adds the files `plan` copies from the event `sourceId` onto the event `targetId` (the new
    /// part, or its occurrence at a carried occurrence's place). A file's bytes are read as a mail
    /// attachment's are (its `contentBytes` and `contentId`, one GET by id) and added by the same
    /// code as an Outlook draft's (`ExchangeProvider.addFileAttachment`: one POST under 3 MB, an
    /// upload session from there), with its inline placement (`isInline`, `contentId`), so a
    /// picture placed in the body stays placed there and the body's `cid:` link still finds it.
    ///
    /// Only the files the target does not already hold are added: a file pairs with one the target
    /// holds by name, kind and content, one to one (`AttachmentPairing.unpaired`), never by id,
    /// size or timestamp. So a carried occurrence's copies of the series' files (which its
    /// instance on the new part holds as copies of the new part's) are not written again, while a
    /// same-name file with other bytes (an edited `agenda.pdf`) is its own and is written (#863);
    /// and a retry (`finishSplit`) adds only what an earlier attempt did not. Each source file is
    /// read at most once (a file read to compare is written from those bytes); a target file is
    /// read only to compare with a source file of its name and kind, since Graph gives no content
    /// hash. A series copy the user removed or replaced on a carried occurrence still shows on its
    /// new-part instance, which made its own copies of the new part's files: a known limitation
    /// (#871); nothing is deleted there. Any failure throws
    /// before the cap, with the record kept: the series is still whole, and the retry copies what
    /// is missing.
    private func copy(_ plan: AttachmentCopyPlan, from sourceId: String, to targetId: String, context: String) async throws {
        guard !plan.files.isEmpty else { return }
        let source = try "/events/" + Self.encodedGraphPathSegment(sourceId, context: context)
        let target = try "/events/" + Self.encodedGraphPathSegment(targetId, context: "Graph event id")
        let held = try await attachments(of: target).map { EventAttachment(eventPath: target, meta: $0) }
        // A source file read for its digest is written from those bytes: one GET per file.
        let sourceReads = SourceFileReads()
        let missing = try await AttachmentPairing.unpaired(
            plan.files.map { EventAttachment(eventPath: source, meta: $0) }, against: held,
            name: { Self.attachmentName($0.meta) }, kind: { Self.attachmentKind($0.meta) },
            content: { file in
                let read = try await self.fileBytes(file)
                if file.eventPath == source { sourceReads.keep(read, for: file.meta.id) }
                return AttachmentPairing.contentDigest(read.data)
            })
        for file in missing {
            let kept = sourceReads.take(file.meta.id)
            let bytes = if let kept { kept } else { try await fileBytes(file) }
            try await ExchangeProvider.addFileAttachment(
                DraftAttachment(filename: Self.attachmentName(file.meta), mimeType: file.meta.contentType ?? "application/octet-stream", data: bytes.data),
                itemPath: target,
                inline: GraphInlinePlacement(isInline: file.meta.isInline, contentId: bytes.contentId),
                post: { path, body in try await self.request(path: path, method: "POST", body: body) },
                rangeRefused: { status, body in
                    GraphAPI.isMailboxFull(statusCode: status, errorBody: body)
                        ? ExchangeCalendarError.mailboxFull
                        : ExchangeProvider.uploadRangeRefusal(status: status, body: body)
                },
                session: testSession ?? sharedEphemeralSession, gate: mailboxGate)
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] split copied \(missing.count) of \(plan.files.count) file(s) onto \(targetId)")
        }
    }

    /// An attachment of the event at `eventPath` (`/events/{id}`, encoded), as `copy` pairs it.
    struct EventAttachment: Sendable {
        let eventPath: String
        let meta: GraphAttachmentMeta
    }

    /// A file's bytes and `contentId`, as `fileBytes` reads them.
    struct FileContent: Sendable {
        let data: Data
        let contentId: String?
    }

    /// The source files `copy` read for their digest, by attachment id, so each is written from the
    /// bytes already read; taken once written.
    final class SourceFileReads: Sendable {
        private let reads = Mutex<[String: FileContent]>([:])
        func keep(_ content: FileContent, for id: String) { reads.withLock { $0[id] = content } }
        func take(_ id: String) -> FileContent? { reads.withLock { $0.removeValue(forKey: id) } }
    }

    /// A file's bytes and `contentId`, one GET by id (`contentBytes`), as a mail attachment's are
    /// read. Throws when they can't be read.
    private func fileBytes(_ file: EventAttachment) async throws -> FileContent {
        let encodedFile = try Self.encodedGraphPathSegment(file.meta.id, context: "Graph attachment id")
        let detail = try JSONDecoder().decode(
            GraphAttachmentDetail.self, from: try await request(path: "\(file.eventPath)/attachments/\(encodedFile)"))
        guard let base64 = detail.contentBytes, let data = Data(base64Encoded: base64) else {
            throw CalendarProviderError.notSupported(
                "a file attached to this repeating event can't be read, so it can't be copied to the new part")
        }
        return FileContent(data: data, contentId: detail.contentId)
    }

    /// The kind a split pairs an attachment by: its Graph `@odata.type`.
    nonisolated static func attachmentKind(_ attachment: GraphAttachmentMeta) -> String {
        (attachment.odataType ?? "").lowercased()
    }

    /// Every attachment of the event at `eventPath` (`/events/{id}`), id, name, type and kind,
    /// following Graph's `@odata.nextLink` within Graph (`graphPath(ofNextLink:)`), at most
    /// `GraphAPI.maxAttachmentListPages` pages, as a message's list is read.
    private func attachments(of eventPath: String) async throws -> [GraphAttachmentMeta] {
        var found: [GraphAttachmentMeta] = []
        var next: String? = "\(eventPath)/attachments?$select=id,name,contentType,size,isInline"
        var pages = 0
        while let path = next {
            guard pages < GraphAPI.maxAttachmentListPages else { throw ExchangeProvider.GraphAttachmentListIncomplete() }
            let page = try JSONDecoder().decode(GraphAttachmentListResponse.self, from: try await request(path: path))
            found += page.value
            pages += 1
            next = try page.odataNextLink.map { try graphPath(ofNextLink: $0) }
        }
        return found
    }

    /// Whether a Graph attachment is a linked file (`#microsoft.graph.referenceAttachment`).
    nonisolated static func isReferenceAttachment(_ attachment: GraphAttachmentMeta) -> Bool {
        (attachment.odataType ?? "").lowercased().contains("referenceattachment")
    }

    /// The refusal of a split of a series that holds a linked file (`isReferenceAttachment`).
    static let linkedFileRefusal =
        "This repeating event has a linked file TabMail can't copy to the new part, so it was not changed. Make the change in your calendar app."

    /// The refusal of a split that carries a changed occurrence holding an attached Outlook item
    /// (`AttachmentCopyPlan.holdsItem`, #847, #854).
    static let uncopiedItemRefusal =
        "This repeating event has an attached Outlook item TabMail can't copy to the new part, so it was not changed. Make the change in your calendar app."

    /// The refusals of a split's retry (`finishSplit`) when a changed occurrence it carries gained
    /// an attached Outlook item, or a linked file, since the first attempt (#847, #834).
    static let retryUncopiedItemRefusal =
        "This change to the repeating event wasn't finished: a later occurrence now has an attached Outlook item TabMail can't copy, so both parts show the later occurrences. Remove the item from that occurrence or finish the change in your calendar app."
    static let retryLinkedFileRefusal =
        "This change to the repeating event wasn't finished: a later occurrence now has a linked file TabMail can't copy, so both parts show the later occurrences. Remove the file from that occurrence or finish the change in your calendar app."

    /// Whether a Graph attachment is an attached Outlook item (`#microsoft.graph.itemAttachment`),
    /// named by its `@odata.type` as a file is (`ExchangeProvider.isFileAttachment`).
    nonisolated static func isItemAttachment(_ attachment: GraphAttachmentMeta) -> Bool {
        (attachment.odataType ?? "").lowercased().contains("itemattachment")
    }

    /// The name a split pairs and writes a copied file under: its own, or the name a draft read
    /// gives a file with none (`DraftReadConfig.unnamedAttachmentFilename`).
    private static func attachmentName(_ attachment: GraphAttachmentMeta) -> String {
        attachment.name?.isEmpty == false ? attachment.name ?? "" : DraftReadConfig.unnamedAttachmentFilename
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

    /// Graph `recurrenceRange.endDate` for capping the stored series `stored` so the occurrence at
    /// `splitNaiveISO` (read in `splitZone`) and every later one are excluded: the day before the
    /// split occurrence's day in the series' zone (`splitDay`). Graph's `endDate` is
    /// date-inclusive and read in the range's `recurrenceTimeZone`, whatever zone the request
    /// names (measured 2026-11-11), so a day worked out in the `recurrence_id`'s zone capped the series
    /// a day off whenever the two zones date the split occurrence differently (#681): the split
    /// occurrence stayed on the old part too, or the one before it fell out of both parts. The day
    /// before is date arithmetic, so a clock change can't move it. Throws as `splitDay` does.
    nonisolated static func splitCapEndDate(
        stored: EditSnapshot, splitNaiveISO: String, splitZone: TimeZone, refusal: ZoneRefusal = .change
    ) throws -> String {
        try splitDay(stored: stored, splitNaiveISO: splitNaiveISO, splitZone: splitZone, refusal: refusal).adding(days: -1).description
    }

    /// What a refusal of a series' zone TabMail does not recognize tells the user
    /// (`CalendarProviderError.unrecognizedTimeZone`): what was not done, and what to do instead.
    struct ZoneRefusal: Sendable {
        let consequence: String
        let remedy: String
        /// What the user is told when the series names no zone at all (`seriesTimeZone`).
        let noZone: String

        /// A change of the series: a split, and its finish.
        static let change = ZoneRefusal(
            consequence: "it did not change the event", remedy: "Make the change in your calendar app instead.",
            noZone: "Outlook gives no time zone for this repeating event, so the day of the occurrence named can't be worked out and the occurrences from it on can't be split off. Make the change in your calendar app instead.")
        /// A delete of an occurrence and every later one (`endSeries`).
        static let followingDelete = ZoneRefusal(
            consequence: "it did not delete these occurrences", remedy: "Delete them in your calendar app instead.",
            noZone: "Outlook gives no time zone for this repeating event, so it did not delete these occurrences. Delete them in your calendar app instead.")
        /// A new length of every occurrence, whose put-back places each deleted occurrence and
        /// dates each moved one in the series' zone (`updateSeries`, #718). Decided (2026-11-13).
        static let lengthChange = ZoneRefusal(
            consequence: "its occurrences changed or deleted one by one can't be kept, and its length was not changed",
            remedy: "Make the change in your calendar app instead.",
            noZone: "Outlook gives no time zone for this repeating event, so its occurrences changed or deleted one by one can't be kept, and its length was not changed. Make the change in your calendar app instead.")
    }

    /// The day the split occurrence at `splitNaiveISO` falls on in the stored series' own zone, the
    /// zone Graph reads the series' range dates in: the date given for an all-day series (its
    /// places are dates, no zone is read); for a timed one, the wall time read in `splitZone` (the
    /// zone the `recurrence_id` is read in) dated in the zone the series' range dates are read in
    /// (`GCalEvent.seriesZoneName`: the range's `recurrenceTimeZone`, else the event's `originalStartTimeZone`; `day(of:in:seriesZone:)`; a `recurrence_id` that is a date alone names the
    /// occurrence on that date and is taken as written). The split's cap, its retry (`finishSplit`,
    /// `splitAlreadyEnded`) and a numbered range's count (`numberedRange`) all read the split's day
    /// here, so they agree with each other and with the new part's `startDate` (`seriesDay`).
    ///
    /// Throws `notSupported`, before anything is written, when the split time can't be read, and
    /// for a timed series that names no zone (neither the range nor the event) or one TabMail does not recognize
    /// (`CalendarTimeZoneResolver`; the message in `refusal`'s words, a change's or a delete's): its day can't be worked out, and one dated in another zone
    /// may be a day off (a timed series' day in an unknown zone is refused, never guessed; #746).
    nonisolated static func splitDay(
        stored: EditSnapshot, splitNaiveISO: String, splitZone: TimeZone, refusal: ZoneRefusal = .change
    ) throws -> RecurrenceTail.Day {
        let unreadable = CalendarProviderError.notSupported(
            "Invalid recurrence_id '\(splitNaiveISO)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        guard let seriesZone = try seriesTimeZone(stored, refusal: refusal) else {
            guard let day = RecurrenceTail.Day(iso: splitNaiveISO) else { throw unreadable }
            return day
        }
        guard let day = day(of: splitNaiveISO, in: splitZone, seriesZone: seriesZone).flatMap({ RecurrenceTail.Day(iso: $0) }) else {
            throw unreadable
        }
        return day
    }

    /// The zone a timed stored series' dates are read in, `GCalEvent.seriesZoneName` (its range's
    /// zone, else the event's own, `originalStartTimeZone`) as `CalendarTimeZoneResolver` reads it,
    /// the zone the confirmation card reads (`GCalEvent.seriesZone`); nil for an all-day series, whose places are dates. A
    /// split, its finish and its carry all date the series in this zone (#681, #563). Throws
    /// `notSupported`, before anything is written, for a timed series that names no zone (neither
    /// the range nor the event) and `unrecognizedTimeZone` (in `refusal`'s words) for one TabMail
    /// does not recognize: its days are refused, never guessed (#746).
    nonisolated static func seriesTimeZone(_ stored: EditSnapshot, refusal: ZoneRefusal = .change) throws -> TimeZone? {
        if stored.event.isAllDay { return nil }
        guard let zoneName = stored.event.seriesZoneName else {
            throw CalendarProviderError.notSupported(refusal.noZone)
        }
        guard let zone = CalendarTimeZoneResolver.zone(named: zoneName, in: .none) else {
            throw CalendarProviderError.unrecognizedTimeZone(zoneName, consequence: refusal.consequence, remedy: refusal.remedy)
        }
        return zone
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
    ///   past it). A rule in the patch replaces the stored recurrence, in the series' zone
    ///   (`GCalEvent.seriesZoneName`): its range's dates read and named in it and the start and end
    ///   labelled with it (`inSeriesZone`), as an edit of the whole series writes a rule
    ///   (`graphPatchJSON`). Graph refuses a range zone other than the start's (400
    ///   `ErrorPropertyValidationFailure`, measured 2026-11-13) and repeats a part created with no
    ///   range zone in its start's zone, the device's, so without this the part would repeat on
    ///   the device's clock, an hour off the series' across a change of offset in one of them.
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
        // The zone the new part is written in and repeats in, whichever rule it takes: the
        // series' (`seriesZoneName`: its range's, else the event's own, as `seriesTimeZone` reads
        // it), so the plan's slots (`plannedPart`) and the occurrences Graph lists agree. Dated in
        // it (#719), its start and its range's `startDate` name the same day.
        let seriesZone = stored.event.seriesZoneName
        guard let newDay = Self.seriesDay(edited.startDate, edited.startDateTime, in: edited.startTimeZone, seriesZone: seriesZone) else {
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
        // A rule the edit gives is dated in the series' zone (`graphPatchJSON`); `splitSeries` has
        // refused a timed series whose zone it does not recognize (`seriesTimeZone`).
        let givenRule = !(patch.recurrence?.isEmpty ?? true)
        let rangeZone = givenRule && !stored.event.isAllDay ? seriesZone.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) } : nil
        for (key, value) in toGraphEventJSON(written, attendeeTypes: stored.attendeeTypes, rangeZone: rangeZone) { json[key] = value }
        // New notes on an online series keep its join section, as an edit of the series does.
        if let description = patch.description, let body = Self.onlineMeetingBody(stored.raw, notes: description) {
            json["body"] = body
        }
        if !givenRule, let recurrence = stored.raw["recurrence"] as? [String: Any] {
            json["recurrence"] = try Self.newPartRecurrence(
                stored: stored, storedRecurrence: recurrence, newDay: newDay,
                splitNaiveISO: newStartNaiveISO, splitZone: newStartZone, move: patch.ruleDayMove)
        }
        // The new part is written in the series' zone, with either rule: a timed one at the same
        // instant (#719), as Google Calendar keeps a series' zone on "this and following", an
        // all-day one on the same dates (#747), or Graph stores it two days longer; its range
        // names that zone, which Graph requires to be its start's (400 otherwise, measured
        // 2026-11-13) and lists the occurrences on.
        if let seriesZone {
            let allDay = json["isAllDay"] as? Bool ?? (written.startDate != nil)
            for key in ["start", "end"] {
                if let time = json[key] as? [String: Any] { json[key] = Self.inSeriesZone(time, seriesZone: seriesZone, allDay: allDay) }
            }
            if var rule = json["recurrence"] as? [String: Any], var range = rule["range"] as? [String: Any] {
                range["recurrenceTimeZone"] = seriesZone
                rule["range"] = range
                json["recurrence"] = rule
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
        return try await splitPoint(
            named: eventId, masterId: masterId, master: snapshot.event, recurrenceId: recurrenceId, zone: zone,
            seriesZone: try Self.seriesTimeZone(snapshot)).cut
    }

    /// Where a split of `master` named at `recurrenceId` (read in `zone`) cuts it: the occurrence
    /// named is the one that starts at `recurrenceId` now (`occurrence`), and the cut the first
    /// place of the series at or after where it starts (`SplitCarry.cut`, read as Outlook places
    /// a pattern: from the range's start, a missing month day on the month's last, its wall clocks
    /// in the series' zone `seriesZone`, `seriesTimeZone`'s). `place` is the
    /// cut as a naive wall clock in `zone`, nil past the series' end. The one computation
    /// `splitSeries` writes and the card shows (`dayMovedRules`).
    private func splitPoint(
        named: String, masterId: String, master: GCalEvent, recurrenceId: String, zone: TimeZone, seriesZone: TimeZone?
    ) async throws -> (found: GCalEvent, namedStart: GCalDateTime, namedPlace: GCalDateTime, cut: SplitCarry.Cut, place: String?) {
        let found = try await occurrence(named: named, masterId: masterId, series: master, recurrenceId: recurrenceId, zone: zone)
        let unreadable = CalendarProviderError.notSupported("where the occurrence named falls in its series can't be read, so the series can't be split at it")
        guard let namedStart = found.start, let namedPlace = found.originalStartTime,
              let cut = SplitCarry.cut(named: found, series: master, zone: seriesZone, anchor: .patternStart, missingDay: .lastDay) else { throw unreadable }
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
                named: eventId, masterId: masterId, master: snapshot.event, recurrenceId: recurrenceId, zone: zone,
                seriesZone: try Self.seriesTimeZone(snapshot))
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
    /// `startDate`, and the split occurrence's day in the series' zone (`splitDay`). Throws
    /// `notSupported` when the range gives no count, or as `splitDay` does.
    nonisolated static func numberedRange(
        stored: EditSnapshot,
        storedRange: [String: Any],
        splitNaiveISO: String,
        splitZone: TimeZone
    ) throws -> (count: Int, rule: String, seriesStart: RecurrenceTail.Day?, split: RecurrenceTail.Day) {
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
        let split = try splitDay(stored: stored, splitNaiveISO: splitNaiveISO, splitZone: splitZone)
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
        guard let rebuilt = rebuiltRule(patch, existing: existing, stored: stored, rangeZone: rangeZone),
              Self.sameRule(rebuilt, as: stored)
        else { return rule }
        return nil
    }

    /// The rule of the whole-series edit `patch` in Graph's form, as the write builds it
    /// (`seriesRuleToWrite`): merged with the series `existing` as the write merges it, written by
    /// `toGraphEventJSON` beside that start, in `rangeZone`, with the first day of the week of
    /// `stored` unless the rule names its own. Nil when the edit gives no rule.
    nonisolated func rebuiltRule(
        _ patch: GCalEventInput, existing: GCalEvent, stored: [String: Any], rangeZone: TimeZone?
    ) -> [String: Any]? {
        guard let rule = patch.recurrence else { return nil }
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existing, patch: patch)
        var probe = GCalEventInput()
        probe.recurrence = rule
        probe.startDate = merged.startDate
        probe.startDateTime = merged.startDateTime
        probe.startTimeZone = merged.startTimeZone
        let storedFirstDay = (stored["pattern"] as? [String: Any])?["firstDayOfWeek"] as? String
        return toGraphEventJSON(probe, rangeZone: rangeZone, firstDayOfWeek: storedFirstDay)["recurrence"] as? [String: Any]
    }

    /// The new last date (`yyyy-MM-dd`, in the range's zone) of a whole-series edit `patch` that
    /// changes only where the series `existing` ends (#718): its rule (`rebuiltRule`) and
    /// `stored`, the series' recurrence in Graph's form, both end on a date, on different dates,
    /// and are otherwise the same rule (`sameRule` with the end left out). Nil for any other edit.
    /// Graph keeps a series' changed and deleted occurrences on such a change, either way, and
    /// removes the occurrences after an earlier end, changed ones with them (measured on a work
    /// account, 2026-11-14). A rule that gains or loses an end, or ends after a count, is another
    /// rule.
    nonisolated func newRangeEnd(
        _ patch: GCalEventInput, existing: GCalEvent, stored: [String: Any], rangeZone: TimeZone?
    ) -> String? {
        guard let rebuilt = rebuiltRule(patch, existing: existing, stored: stored, rangeZone: rangeZone),
              let mine = rebuilt["range"] as? [String: Any], let theirs = stored["range"] as? [String: Any],
              mine["type"] as? String == "endDate", theirs["type"] as? String == "endDate",
              let end = mine["endDate"] as? String, end != theirs["endDate"] as? String,
              Self.sameRule(rebuilt, as: stored, ignoringEnd: true)
        else { return nil }
        return end
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
    /// the same through an RRULE (`rrule(_:)`), so its RRULE does not say what is stored. A rule
    /// that changes only the series' last date (`newRangeEnd`) is no reset: Graph keeps them
    /// (measured on a work account, 2026-11-14).
    nonisolated func editResetsChangedOccurrences(_ event: GCalEvent, edit: GCalEventInput) -> Bool {
        // A change between all-day and timed changes the event as a whole: a series' changed
        // occurrences are reset, and a single event has none.
        if CalendarToolHelpers.editChangesKind(edit, storedIsAllDay: event.start?.date != nil) {
            return !(event.recurrence ?? []).isEmpty
        }
        // A new length resets them too, but the write puts them back (`updateSeries`, #718), so the
        // series ends as Google Calendar leaves it: no reset.
        if movesSeriesTime(edit, existing: event), !SplitCarry.lengthChange(edit, series: event) { return true }
        guard edit.recurrence != nil else { return false }
        guard let baseline = storedRuleBaseline(event) else { return true }
        // A rule that changes only where the series ends keeps them (`newRangeEnd`, #718), when
        // the start and end written beside it are the stored ones, zone label included
        // (`restatesStoredTimes`): a relabelled start was not measured, so it is a reset.
        return seriesRuleToWrite(edit, existing: event, stored: baseline.recurrence, rangeZone: baseline.rangeZone) != nil
            && !(newRangeEnd(edit, existing: event, stored: baseline.recurrence, rangeZone: baseline.rangeZone) != nil
                 && restatesStoredTimes(edit, series: event))
    }

    /// Whether the start and end the write sends beside a rule (`graphPatchJSON`) are the series'
    /// stored ones exactly (#718): the same instants (`movesSeriesTime` false), each labelled with
    /// the zone Graph stored it in (`GCalEvent.eventZoneName`, `eventEndZoneName`: its
    /// `originalStartTimeZone` and `originalEndTimeZone`), the same name, not only the same zone.
    /// The write labels them with the series' range zone (`inSeriesZone`), else as the merge gives
    /// them. False when a stored label was not read.
    nonisolated func restatesStoredTimes(_ edit: GCalEventInput, series: GCalEvent) -> Bool {
        guard !movesSeriesTime(edit, existing: series),
              let storedStart = series.eventZoneName, let storedEnd = series.eventEndZoneName else { return false }
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: series, patch: edit)
        let json = toGraphEventJSON(merged)
        let allDay = json["isAllDay"] as? Bool ?? (merged.startDate != nil || merged.endDate != nil)
        func label(_ key: String) -> String? {
            (json[key] as? [String: Any]).map { Self.inSeriesZone($0, seriesZone: series.recurrenceTimeZoneName, allDay: allDay) }?["timeZone"] as? String
        }
        return label("start") == storedStart && label("end") == storedEnd
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
    /// date with its own rule is a date move. With `ignoringEnd`, the range's `endDate` is left
    /// out too (`newRangeEnd`).
    nonisolated static func sameRule(_ rebuilt: [String: Any], as stored: [String: Any], ignoringEnd: Bool = false) -> Bool {
        for part in ["pattern", "range"] {
            guard let mine = rebuilt[part] as? [String: Any], var theirs = stored[part] as? [String: Any] else { return false }
            if part == "pattern" {
                theirs["index"] = Self.storedIndex(type: theirs["type"] as? String, index: theirs["index"] as? String)
            }
            for (key, value) in mine where key != "startDate" && !(ignoringEnd && part == "range" && key == "endDate") {
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
        return day(of: dateTime, in: given, seriesZone: series)
    }

    /// The day, `yyyy-MM-dd`, the wall time `dateTime` read in `given` falls on in `seriesZone`.
    /// The one place a time is dated in a series' zone: the series' start and range (`seriesDay`)
    /// and a split's day (`splitDay`). A value shorter than a wall time (a date) is dated as
    /// written (`renderNaive`); nil when a wall time can't be read.
    nonisolated static func day(of dateTime: String, in given: TimeZone, seriesZone: TimeZone) -> String? {
        RecurrenceOccurrenceResolver.renderNaive(String(graphNaiveDateTime(dateTime).prefix(19)), from: given, to: seriesZone)
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
    /// `headers`: more request headers (`If-Match`).
    private func request(
        path: String, method: String = "GET", body: Data? = nil, timeZoneName: String? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        try await request(url: baseURL + path, method: method, body: body, timeZoneName: timeZoneName, headers: headers)
    }

    /// `request(path:)` by a whole URL: the base URL plus a path, or a page link Graph returned
    /// (`readPages`, which checks it is one first).
    private func request(
        url: String, method: String = "GET", body: Data? = nil, timeZoneName: String? = nil, headers more: [String: String] = [:]
    ) async throws -> Data {
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
        let headers = more.merging(["Prefer": "outlook.timezone=\"\(prefTz)\""]) { _, prefer in prefer }
        // Throttling (429) and 503 are retried after Graph's `Retry-After`, like the
        // mail provider's requests (#426).
        let policy = HTTPRetryPolicy.graph
        let result = try await performHTTPRequestWithRetry(
            url: url, method: method, body: body, token: token, extraHeaders: headers,
            retryableStatusCodes: policy.retryableStatusCodes, maxAttempts: policy.maxAttempts,
            initialDelay: policy.initialDelay, session: testSession, logLabel: "ExchangeCalendar", gate: mailboxGate)

        if let data = result.data {
            return data
        }

        // 401 — token expired, force refresh and retry once
        if result.statusCode == 401 {
            BackgroundSyncLogger.logDebug("[ExchangeCalendar] Token expired, refreshing...")
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: url, method: method, body: body, token: freshToken, extraHeaders: headers, session: testSession, logLabel: "ExchangeCalendar", gate: mailboxGate)
            // `headers` already carries the local-tz Prefer from the first attempt above.
            if let data = retry.data {
                return data
            }
            if GraphAPI.isMailboxFull(statusCode: retry.statusCode, errorBody: retry.errorBody) {
                throw ExchangeCalendarError.mailboxFull
            }
            throw ExchangeCalendarError.httpError(retry.statusCode, retry.errorBody)
        }

        // 403 for a full mailbox (#865): told apart from a missing scope by Graph's error code.
        if GraphAPI.isMailboxFull(statusCode: result.statusCode, errorBody: result.errorBody) {
            throw ExchangeCalendarError.mailboxFull
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
            created: nil,
            updated: nil,
            // Graph's seriesMasterId → our recurringEventId, so calendar_search
            // enrichment can fetch the master's rule for Exchange instances too.
            recurringEventId: e.seriesMasterId,
            conferenceUrl: e.onlineMeeting?.joinUrl
        )
        event.recurrenceTimeZoneName = e.recurrence?.range?.recurrenceTimeZone.flatMap { $0.isEmpty ? nil : $0 }
        event.recurrenceFirstDayOfWeek = e.recurrence?.pattern?.firstDayOfWeek.flatMap { $0.isEmpty ? nil : $0 }
        // Graph counts a series from its range start, an occurrence only on a pattern day, and holds
        // a month's missing day of the month on its last day (measured; `RecurrenceTail`).
        if e.recurrence != nil {
            event.recurrenceAnchor = .patternStart
            event.recurrenceMissingDay = .lastDay
        }
        event.originalStartTime = Self.originalStartTime(e.originalStart)
        event.eventZoneName = e.originalStartTimeZone.flatMap { $0.isEmpty ? nil : $0 }
        event.eventEndZoneName = e.originalEndTimeZone.flatMap { $0.isEmpty ? nil : $0 }
        // The read's start is in the zone the read asked for (`request`'s `Prefer`), not the
        // event's own: no date is read in it (`seriesZone`).
        event.startZoneIsDisplay = true
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
            // `splitSeries` / `splitCapEndDate`. This path exists for plain
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
    /// Graph refused a write because the mailbox is over its storage quota (403
    /// `ErrorQuotaExceeded`, `GraphAPI.isMailboxFull`). Not a missing permission: the calendar
    /// queue keeps the change queued until the user frees space (#865).
    case mailboxFull
    case httpError(Int, Data?)
    case eventNotFound
    /// A Graph resource id could not be encoded as one strict path segment.
    /// The associated value names which id, matching `ProviderError.invalidURL`'s
    /// contract on the mail side.
    case invalidPathSegment(String)
    /// A collection's `@odata.nextLink` is not a Graph page link (`GraphAPI.isGraphPageLink`),
    /// so it is not followed and the listing is not returned.
    case invalidPageLink
    /// A collection did not end within `ExchangeCalendarConfig.maxListPages` pages.
    case listingIncomplete
    /// A put-back's guarded write kept meeting a changed series (412 on every read,
    /// `ExchangeCalendarConfig.putBackConflictReads`): someone is editing it. No terminal arm
    /// claims it, so the operation stays queued (#718).
    case seriesBusy
    /// A file a put-back attached again does not read back on its occurrence. No terminal arm
    /// claims it, so the operation stays queued and the retry reads and adds again (#718), at
    /// most `ExchangeCalendarConfig.putBackUnconfirmedAttempts` times.
    case putBackNotConfirmed
}

/// Paging of the Outlook calendar listings (`ExchangeCalendarProvider.readPages`).
enum ExchangeCalendarConfig {
    /// Reads of one occurrence a put-back makes (`guardedPatch`) while its write keeps being
    /// refused for a stale etag (412): the series' etag moves with every write anywhere in it, so
    /// a few reads ride out another write landing; more mean the series is being edited, and the
    /// operation waits for a later drain (`seriesBusy`).
    static let putBackConflictReads = 3

    /// Attempts of one edit of every occurrence whose put-back may attach a file that then does
    /// not read back on its occurrence (`putBackNotConfirmed`) before the edit stops with the file
    /// counted as not restored and kept saved. Each such attempt adds the file again, since it is
    /// still missing, so this bounds the copies a calendar that never shows it can collect, and
    /// how long the account's other calendar changes wait behind it; a few ride out a read that
    /// lags behind the add.
    static let putBackUnconfirmedAttempts = 3

    /// Events asked for per page (`$top`) of an event listing. The `$top` every event listing
    /// sent before it read further pages (the search tool's `maxResults`), so Graph takes it
    /// and a search's usual window is still one request. The calendar list sends no `$top`
    /// and reads Graph's own pages.
    static let listPageSize = 250
    /// Pages of one listing read before giving up. A window the read tool asks for
    /// (`maxResults` 2,500 per calendar) is 10 pages; the rest is room for the cancelled,
    /// empty and non-matching rows a page also holds. The cap bounds the walk at 10,000 rows
    /// (`listPageSize` times this). A listing can reach it: a search with explicit dates years
    /// apart on a very busy calendar. It then throws `listingIncomplete`, the assistant's tools
    /// skip that calendar, and a narrower window lists it.
    static let maxListPages = 40
}

// MARK: - Microsoft Graph Calendar Response Models

private struct MSCalendar: Decodable {
    let id: String
    let name: String?
    let isDefaultCalendar: Bool?
    let color: String?
}

// Decodable shapes for Microsoft Graph calendar payloads. Internal (not private)
// so unit tests in `TabMailTests/Providers/ExchangeCalendarTests.swift` can decode
// JSON fixtures into `MSEvent` to exercise `toGCalEvent`.
/// One page of a Graph collection: its items, and the link to the next page when there is one
/// (learn.microsoft.com/graph/paging).
struct MSPage<Item: Decodable>: Decodable {
    let value: [Item]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
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
    /// Set on `occurrence`/`exception` rows (calendarView expansion) — points
    /// to the series master. Graph's analogue of Google's `recurringEventId`.
    /// We map it onto `GCalEvent.recurringEventId` so the calendar_search
    /// enrichment (`resolveMasterRecurrence`) can fetch the master's rule.
    let seriesMasterId: String?
    /// Set on `occurrence`/`exception` rows: the start the series gives the occurrence, which a
    /// moved one keeps (`ExchangeCalendarProvider.originalStartTime`).
    let originalStart: String?
    /// The zone the event was created in, Graph's `originalStartTimeZone` (read by `getEvent` and a
    /// split, not by a listing): a series whose range names no zone repeats in it.
    let originalStartTimeZone: String?
    /// The zone the event's end was stored in, Graph's `originalEndTimeZone` (read with
    /// `originalStartTimeZone`).
    let originalEndTimeZone: String?
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
