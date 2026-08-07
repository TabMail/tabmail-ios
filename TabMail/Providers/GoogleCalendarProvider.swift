/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CryptoKit

/// Protocol for calendar providers (Google Calendar, Microsoft Graph Calendar).
/// Both providers return shared `GCalEvent`/`GCalCalendar` model types to keep calendar tools provider-agnostic.
protocol CalendarProvider: Sendable {
    func listCalendars() async throws -> [GCalCalendar]
    func primaryCalendarId() async throws -> String
    func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent]
    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent
    func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
    func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
    func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws

    /// Update a SINGLE OCCURRENCE of a recurring event (this_only edit_scope).
    /// `recurrenceId` is the start datetime of the target occurrence in naive
    /// ISO8601 form (e.g. "2026-05-20T17:00:00"). The provider materializes the
    /// occurrence as an override and applies `event` to it.
    /// Default implementation falls back to series-wide updateEvent so existing
    /// callers stay correct; recurring-aware providers (Google) override.
    func updateOccurrence(calendarId: String, eventId: String, recurrenceId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent

    /// Split a recurring series at `recurrenceId` (this_and_following edit_scope):
    /// cap the original series with UNTIL = recurrenceId - 1, then create a new
    /// series with the same RRULE starting at `recurrenceId` with `patch` applied.
    /// `sendUpdates` controls invitation emails for the NEW series only — the
    /// master cap is silent so attendees see one notification, not two.
    /// Default implementation throws `CalendarProviderError.notSupported` —
    /// providers that don't natively expose split semantics surface this to the
    /// LLM so it can fall back to manual orchestration or ask the user.
    func splitSeries(calendarId: String, eventId: String, recurrenceId: String, patch: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
}

/// Errors common to calendar providers when an operation isn't supported.
enum CalendarProviderError: Error {
    /// The provider can't natively perform this operation (e.g. recurring-series
    /// split on Exchange/CalDAV/Demo before those implementations land).
    case notSupported(String)
}

// Default protocol methods: provide a fallback for providers that haven't
// implemented the recurring-aware paths yet. These keep existing callers
// compiling while letting newly-aware providers override.
extension CalendarProvider {
    func updateOccurrence(calendarId: String, eventId: String, recurrenceId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("Editing a single occurrence of a recurring event is not yet supported on this calendar provider. Edit the whole series or use the Thunderbird add-on for fine-grained occurrence edits.")
    }
    func splitSeries(calendarId: String, eventId: String, recurrenceId: String, patch: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("Splitting a recurring series at a given occurrence is not yet supported on this calendar provider. Edit the whole series or use the Thunderbird add-on for this-and-following edits.")
    }
}

/// Google Calendar API v3 provider for Gmail accounts.
/// Mirrors `GmailProvider` actor pattern — same `accessToken` closure, same retry logic.
/// Google handles invitations natively via `sendUpdates=all` — no ICS generation needed.
actor GoogleCalendarProvider: CalendarProvider {
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let baseURL = "https://www.googleapis.com/calendar/v3"
    /// Test-only transport override. `nil` on every production path, where
    /// `performHTTPRequest` falls back to `sharedEphemeralSession`.
    private let testSession: URLSession?

    init(accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.accessToken = accessToken
        self.testSession = nil
    }

    /// Explicit-session initializer, used by tests to route this provider's HTTP
    /// through `FakeHTTP`.
    ///
    /// ⚠️ Deliberately a SEPARATE initializer taking a NON-OPTIONAL session,
    /// mirroring `CalDAVClient`'s pair rather than `GmailProvider`'s
    /// `session: URLSession? = nil` parameter. A nil-defaulted seam is
    /// fail-DANGEROUS: an injection that is silently dropped leaves the unit
    /// suite talking to the live internet, and nothing in the run says so
    /// (`feedback_nil_defaulted_seam_is_fail_dangerous`). Omitting *this*
    /// initializer is a compile error instead.
    ///
    /// This seam exists because `CalendarConflictDispositionTests` has to prove a
    /// property of the TRANSPORT SEAM — that the bytes Google sends with a 409
    /// reach the queue's duplicate-id classifier — and that is unreachable from a
    /// mock `CalendarProvider`, which by construction hands the classifier a body
    /// the test itself authored. The neighbouring path-containment proofs still
    /// need no session at all (see `CalendarPathContainmentTests` § Google).
    init(
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        session: URLSession
    ) {
        self.accessToken = accessToken
        self.testSession = session
    }

    // MARK: - Calendars

    func listCalendars() async throws -> [GCalCalendar] {
        var allCalendars: [GCalCalendar] = []
        var pageToken: String?

        repeat {
            var path = "/users/me/calendarList?maxResults=250"
            if let token = pageToken {
                path += "&pageToken=\(token)"
            }
            let data = try await request(path: path)
            let response = try JSONDecoder().decode(GCalCalendarListResponse.self, from: data)
            allCalendars.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        // Sort: primary first, then writable, then read-only
        allCalendars.sort { a, b in
            if a.primary != b.primary { return a.primary == true }
            let aWritable = a.accessRole == "owner" || a.accessRole == "writer"
            let bWritable = b.accessRole == "owner" || b.accessRole == "writer"
            if aWritable != bWritable { return aWritable }
            return (a.summary ?? "") < (b.summary ?? "")
        }

        // Google's calendarList omits `selected` for unselected calendars (returns
        // it only when true). The API doc states the default is `false`, so
        // normalize nil → false here. This lets the caller filter purely on
        // `selected == false` and keeps Exchange/CalDAV's nil-means-include
        // semantics intact (those providers never set `selected`).
        let normalized = allCalendars.map { cal in
            GCalCalendar(
                id: cal.id,
                summary: cal.summary,
                primary: cal.primary,
                accessRole: cal.accessRole,
                backgroundColor: cal.backgroundColor,
                selected: cal.selected ?? false
            )
        }
        print("[GoogleCalendar] Listed \(normalized.count) calendars")
        for cal in normalized {
            print("[GoogleCalendar]   id=\(cal.id) name='\(cal.summary ?? "?")' primary=\(cal.primary == true) selected=\(cal.selected.map(String.init(describing:)) ?? "nil") accessRole=\(cal.accessRole ?? "?")")
        }
        return normalized
    }

    func primaryCalendarId() async throws -> String {
        let calendars = try await listCalendars()
        return calendars.first(where: { $0.primary == true })?.id ?? "primary"
    }

    // MARK: - Path segment encoding

    /// 🚨 **R13-U1 — a calendar/event/instance id must occupy exactly ONE URL path
    /// segment.** Every id below is interpolated into `/calendars/{id}/events/{id}`,
    /// and `.urlPathAllowed` **passes `/` through unescaped** — so an id containing
    /// `/` silently adds path segments, and `..` segments let the result walk out of
    /// `/calendar/v3/` into a sibling Google API surface under the same OAuth token.
    /// Reachable with an agent-authored `event_id`: the three calendar tools accept a
    /// non-numeric `event_id` verbatim (see the note in `CalendarEventReadTool`).
    ///
    /// **Why this VALIDATES rather than re-encoding.** `GraphAPI.encodedGraphPathSegment`
    /// is the sibling for Exchange and is deliberately NOT reused here: it allows only
    /// RFC 3986 *unreserved*, which would newly percent-encode the `@` that every
    /// Google secondary-calendar id contains (`x@group.calendar.google.com` →
    /// `x%40group…`). `%40` and `@` are not formally equivalent in a path segment
    /// (RFC 3986 §6.2.2.2 — `@` is a `pchar`, not unreserved), so adopting it would be
    /// a wire change to a working primary path in the name of a hazard that only `/`
    /// and dot-segments create. Instead the existing charset is kept byte-for-byte and
    /// the OUTPUT is checked for the structural property that actually matters. Every
    /// id that works today still produces the identical bytes.
    ///
    /// ⚠️ The `?? id` fallbacks this replaces were unreachable in practice
    /// (`addingPercentEncoding` returns nil only for invalid Unicode, which a Swift
    /// `String` cannot hold) — but per the precedent stated in
    /// `AccountManagerCalendarQueue`, *"the caller never produces the value" is a
    /// property of today's callers, not an invariant*, and the fallback's behaviour
    /// was to emit the RAW id, i.e. the exact string this guard exists to refuse.
    ///
    /// Internal rather than private so `CalendarPathContainmentTests` can assert
    /// the *bytes* this produces for an ordinary secondary-calendar id. That
    /// assertion cannot be made through the provider: `GoogleCalendarProvider`
    /// takes no `URLSession`, and adding a nil-defaulted one purely to observe the
    /// wire would be a fail-DANGEROUS seam (a dropped injection silently reaches
    /// the live internet).
    static func encodedPathSegment(_ value: String, _ role: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw GoogleCalendarError.invalidPathSegment(role)
        }
        guard !encoded.contains("/"), encoded != ".", encoded != ".." else {
            throw GoogleCalendarError.invalidPathSegment(role)
        }
        return encoded
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
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        var queryItems: [String] = []
        // Restrict to default calendar entries; excludes workingLocation / focusTime /
        // outOfOffice / birthday / fromGmail (these often have empty `summary` and
        // are status markers, not user-actionable events).
        queryItems.append("eventTypes=default")
        queryItems.append("singleEvents=\(singleEvents)")
        queryItems.append("maxResults=\(maxResults)")
        if singleEvents {
            queryItems.append("orderBy=\(orderBy)")
        }
        if let timeMin {
            queryItems.append("timeMin=\(timeMin.iso8601String().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        if let timeMax {
            queryItems.append("timeMax=\(timeMax.iso8601String().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        if let query, !query.isEmpty {
            queryItems.append("q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
        }

        let path = "/calendars/\(encodedCalId)/events?\(queryItems.joined(separator: "&"))"
        print("[GoogleCalendar] listEvents calendarId='\(calendarId)' path=\(path)")
        let data = try await request(path: path)
        if let preview = String(data: data, encoding: .utf8) {
            print("[GoogleCalendar] listEvents response (first 800 chars): \(preview.prefix(800))")
        }
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: data)
        let raw = response.items ?? []
        let filtered = raw.filter { $0.status != "cancelled" }
        print("[GoogleCalendar] listEvents calendarId='\(calendarId)' rawCount=\(raw.count) afterCancelFilter=\(filtered.count)")
        for ev in filtered {
            let isEmpty = (ev.summary?.isEmpty ?? true)
                && (ev.attendees?.isEmpty ?? true)
                && (ev.location?.isEmpty ?? true)
                && (ev.description?.isEmpty ?? true)
            let marker = isEmpty ? "EMPTY" : "ok"
            print("[GoogleCalendar]   [\(marker)] id=\(ev.id ?? "?") iCalUID=\(ev.iCalUID ?? "?") eventType=\(ev.eventType ?? "?") kind=\(ev.kind ?? "?") visibility=\(ev.visibility ?? "?") status=\(ev.status ?? "?") summary='\(ev.summary ?? "")' attendees=\(ev.attendees?.count ?? 0) location='\(ev.location ?? "")' desc.len=\(ev.description?.count ?? 0) htmlLink=\(ev.htmlLink ?? "?")")
        }
        return filtered
    }

    func getEvent(calendarId: String = "primary", eventId: String) async throws -> GCalEvent {
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        let encodedEventId = try Self.encodedPathSegment(eventId, "Google event id")
        let data = try await request(path: "/calendars/\(encodedCalId)/events/\(encodedEventId)")
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func createEvent(
        calendarId: String = "primary",
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        let body = try JSONSerialization.data(withJSONObject: event.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events?sendUpdates=\(sendUpdates)",
            method: "POST",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func updateEvent(
        calendarId: String = "primary",
        eventId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // Always fetch the existing event and merge the patch onto it, so we
        // PATCH a FULL payload. Google's docs say partial PATCH preserves
        // unspecified fields and even recommend "prefer GET + UPDATE over
        // PATCH" for events — this matches CalDAV's natural full-resource
        // PUT and the Exchange Graph fix where partial PATCH on master
        // recurrence silently rewrote start/end. Defense-in-depth.
        let existing = try await getEvent(calendarId: calendarId, eventId: eventId)
        let merged = Self.mergeExistingEventWithPatch(existing: existing, patch: event)
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        let encodedEventId = try Self.encodedPathSegment(eventId, "Google event id")
        let body = try JSONSerialization.data(withJSONObject: merged.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedEventId)?sendUpdates=\(sendUpdates)",
            method: "PATCH",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func deleteEvent(
        calendarId: String = "primary",
        eventId: String,
        sendUpdates: String = "all"
    ) async throws {
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        let encodedEventId = try Self.encodedPathSegment(eventId, "Google event id")
        _ = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedEventId)?sendUpdates=\(sendUpdates)",
            method: "DELETE"
        )
    }

    /// Update a single occurrence of a recurring series — Google Calendar exposes
    /// instances as their own event resources with id of the form
    /// `{masterId}_{YYYYMMDDTHHMMSSZ}`. We resolve the instance via the
    /// `events/{masterId}/instances` endpoint (which gives us the actual
    /// instance id, including DST-adjusted time), then PATCH that instance.
    func updateOccurrence(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // The agent often passes an INSTANCE id (Google format
        // `<masterId>_<startTime>Z`) when editing a single occurrence. Google's
        // `/events/{id}/instances` endpoint requires the master id — passing an
        // instance returns 400. Resolve up front via the instance's
        // `recurringEventId` pointer.
        let (eventId, _) = try await resolveToMaster(calendarId: calendarId, eventId: eventId)
        let encodedCalId = try Self.encodedPathSegment(calendarId, "Google calendar id")
        let encodedMasterId = try Self.encodedPathSegment(eventId, "Google master event id")

        // Find the instance whose start matches recurrenceId. Google's instances
        // endpoint accepts originalStart query (in RFC 3339) but parsing that
        // requires the master's timezone; safer to fetch a small window around
        // the recurrenceId and match by start.
        let instanceId = try await resolveInstanceId(
            calendarId: encodedCalId,
            masterId: encodedMasterId,
            recurrenceId: recurrenceId
        )
        let encodedInstanceId = try Self.encodedPathSegment(instanceId, "Google occurrence id")

        // Fetch the actual instance event and merge the patch onto it — same
        // defensive full-payload pattern as `updateEvent`. Then strip
        // `recurrence`: an instance/exception cannot carry a series rule and
        // Google rejects PATCHes that include one.
        let existingInstance = try await getEvent(calendarId: calendarId, eventId: instanceId)
        var instancePatch = Self.mergeExistingEventWithPatch(existing: existingInstance, patch: event)
        instancePatch.recurrence = nil
        let body = try JSONSerialization.data(withJSONObject: instancePatch.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedInstanceId)?sendUpdates=\(sendUpdates)",
            method: "PATCH",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    /// Split a recurring series at `recurrenceId`:
    /// 1. PATCH the master to add UNTIL = recurrenceId - 1 second (silent — sendUpdates="none")
    /// 2. POST a new event with the same fields as the master, the `patch` applied,
    ///    DTSTART = recurrenceId, and the master's RRULE without UNTIL/COUNT.
    /// If step 2 fails after step 1 succeeded, attempt to revert step 1.
    /// Invitations (`sendUpdates`) fire only on the new series.
    func splitSeries(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        patch: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // 1. Fetch the master so we can preserve its fields and read its RRULE.
        //    The agent may have passed an INSTANCE id (Google format
        //    `<masterId>_<startTime>Z`) — instances don't carry the RRULE, only
        //    the master does. Resolve via `recurringEventId` so a split aimed at
        //    an occurrence id still finds the series to cap.
        let (eventId, master) = try await resolveToMaster(calendarId: calendarId, eventId: eventId)
        guard let masterRecurrence = master.recurrence, !masterRecurrence.isEmpty else {
            throw CalendarProviderError.notSupported("Event \(eventId) is not recurring; can't split.")
        }

        // 2. Locate the master's RRULE line and compute the capped variant.
        guard let originalRRule = masterRecurrence.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else {
            throw CalendarProviderError.notSupported("Master event has no RRULE; can't split.")
        }
        guard let untilValue = Self.googleUntilString(beforeNaiveISO: recurrenceId, allDay: master.isAllDay) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let cappedRRule = Self.replaceOrAppendUntil(in: originalRRule, untilValue: untilValue)
        let rruleWithoutCap = Self.stripUntilAndCount(originalRRule)

        // 3. Build the capped-master patch. The semantic change is recurrence-
        //    only, but defensive-include the master's existing start/end so
        //    the provider can't silently re-anchor them on partial PATCH.
        //    Google's docs explicitly recommend "prefer GET + UPDATE over
        //    PATCH" for events — sending the unchanged fields makes the
        //    intent crystal clear and parallels the Exchange Graph fix where
        //    omitting start/end caused the master to be rewritten to UTC
        //    midnight at `range.startDate`.
        var cappedMasterInput = GCalEventInput()
        cappedMasterInput.recurrence = [cappedRRule]
        if master.isAllDay {
            if let s = master.start?.date { cappedMasterInput.startDate = s }
            if let e = master.end?.date { cappedMasterInput.endDate = e }
        } else {
            if let s = master.start?.dateTime { cappedMasterInput.startDateTime = s }
            if let tz = master.start?.timeZone { cappedMasterInput.startTimeZone = tz }
            if let e = master.end?.dateTime { cappedMasterInput.endDateTime = e }
            if let tz = master.end?.timeZone { cappedMasterInput.endTimeZone = tz }
        }

        // 4. PATCH master silently.
        let _: GCalEvent = try await updateEvent(
            calendarId: calendarId,
            eventId: eventId,
            event: cappedMasterInput,
            sendUpdates: "none"
        )

        // 5. Build the new series — inherit master fields, apply patch overrides.
        //    Pin a DETERMINISTIC id so a retry after a lost ACK on step 6
        //    re-targets the same series instead of creating a duplicate.
        var newSeriesInput = Self.mergeMasterAndPatch(
            master: master,
            patch: patch,
            newStartNaiveISO: recurrenceId,
            newRecurrence: [rruleWithoutCap]
        )
        let newSeriesId = Self.deterministicSplitEventId(masterId: eventId, recurrenceId: recurrenceId)
        newSeriesInput.id = newSeriesId

        // 6. Create the new series.
        do {
            return try await createEvent(
                calendarId: calendarId,
                event: newSeriesInput,
                sendUpdates: sendUpdates
            )
        } catch GoogleCalendarError.httpError(409, let conflictBody)
                    where Self.isDuplicateIdConflict(conflictBody) {
            // 🚨 R14-F2 — POSITIVELY IDENTIFIED, and the proof-GET's failure may
            // not masquerade as anything else.
            //
            // Until 2026-08-06 this arm was `catch GoogleCalendarError.httpError(409, _)`
            // and DISCARDED the body. End to end: step 4 caps the master, step 6's
            // create returns a NON-duplicate 409, this arm assumes lost-ACK
            // success, `getEvent(newSeriesId)` answers 404 because nothing was
            // created, the sibling rollback `catch` below is skipped — a throw
            // inside a `catch` clause is not claimed by a sibling `catch` of the
            // same `do` — and that 404 reaches `isCalendarNotFoundError`, which
            // deletes the `PendingCalendarOperation` and signals
            // `.permanentFailure`. The recurring master stays truncated, the
            // successor never exists, and the only durable intention that could
            // repair it is gone. Later sync imports the truncated master and
            // cannot reconstruct the recurrence.
            //
            // The `where` clause is the whole fix's first half: an unproven,
            // empty or unparseable 409 now falls into the rollback `catch`, which
            // restores the master's recurrence and rethrows through
            // `splitRollbackError`. The siblings already did this — `CalDAVProvider`
            // verifies the successor exists AND is ours before treating a
            // collision as completion, and `ExchangeCalendarProvider` carries an
            // explicit "THERE IS DELIBERATELY NO `catch …httpError(409, _)`" so
            // every create failure routes through rollback accounting. Google was
            // the only one accepting any 409 as proof.
            //
            // ⚠️ WHAT BREAKS THE OTHER WAY (`MIS-026`). A genuine duplicate whose
            // body Google failed to send now rolls the cap back and retries the
            // whole split instead of returning the existing successor. That
            // converges (the cap is recomputed from the master's own RRULE and is
            // idempotent) and is the same disposition the `.create` path already
            // gives a body-less 409, which `googleBodylessConflictKeepsTheIntentionQueued`
            // pins. Failing closed on absent evidence is always acceptable;
            // deleting the durable row on it is never-drop clause 2.
            do {
                return try await getEvent(calendarId: calendarId, eventId: newSeriesId)
            } catch {
                // The successor EXISTS — Google just said so — we merely could not
                // read it back. Two dispositions are forbidden here and both are
                // reachable-looking:
                //  * letting this error escape, because a 404/`eventNotFound` from
                //    the proof-GET is claimed by `isCalendarNotFoundError` and
                //    deletes the durable row on "the original event is gone",
                //    which is exactly the defect above;
                //  * falling into the rollback `catch`, because UNCAPPING a master
                //    whose successor exists duplicates every future occurrence —
                //    F2's own mirror image.
                // Rethrowing the ORIGINAL 409 is the only honest answer: it says
                // "we could not determine the outcome", no terminal arm claims a
                // 409 (`isCalendarBadRequestError` excludes it as indeterminate),
                // so the op stays queued and the next drain re-runs the split
                // against the already-capped master — which re-conflicts, re-proves
                // the duplicate, and retries the read. The server state is stable
                // across that retry, so it terminates as soon as the GET succeeds.
                print("[GoogleCalendar] splitSeries proof-GET for \(newSeriesId) FAILED after a proven duplicate: \(error) — keeping the operation queued")
                throw GoogleCalendarError.httpError(409, conflictBody)
            }
        } catch {
            // Best-effort revert of step 1 so we don't leave the master truncated
            // with no replacement series. Same defensive include-start/end as
            // the cap above — partial PATCH could in principle re-anchor.
            //
            // 🚨 R13-U4 — A FAILED ROLLBACK IS NOT THE SAME OUTCOME AS A SUCCESSFUL
            // ONE, and `try?` reported them identically. If the create failed with a
            // 400/415/422, `isCalendarBadRequestError` claims the rethrown error and
            // the drain DELETES the durable row — so when the revert had also
            // failed, the master was left permanently capped, with no successor and
            // no queued work to make one. Later sync imports the truncated master
            // and cannot reconstruct the original recurrence.
            //
            // On a revert failure this raises `CalDAVError.inconsistentState`, whose
            // drain arm is terminal-with-a-reason and surfaces the message to the
            // user — deliberately NOT transient, because retrying a two-step write
            // that has already half landed re-caps an already-capped master.
            // Identical treatment to the Exchange sibling: one invariant, two
            // spellings, kept in step on purpose.
            var revertInput = GCalEventInput()
            revertInput.recurrence = masterRecurrence
            if master.isAllDay {
                if let s = master.start?.date { revertInput.startDate = s }
                if let e = master.end?.date { revertInput.endDate = e }
            } else {
                if let s = master.start?.dateTime { revertInput.startDateTime = s }
                if let tz = master.start?.timeZone { revertInput.startTimeZone = tz }
                if let e = master.end?.dateTime { revertInput.endDateTime = e }
                if let tz = master.end?.timeZone { revertInput.endTimeZone = tz }
            }
            var revertFailure: Error?
            do {
                _ = try await updateEvent(
                    calendarId: calendarId,
                    eventId: eventId,
                    event: revertInput,
                    sendUpdates: "none"
                )
            } catch let revertError {
                revertFailure = revertError
                print("[GoogleCalendar] splitSeries revert FAILED: \(revertError)")
            }
            throw Self.splitRollbackError(original: error, revertFailure: revertFailure)
        }
    }

    /// 🚨 **R13-U4 — the error a half-landed split reports depends on whether its
    /// ROLLBACK worked.** Shared by both `splitSeries` implementations so the two
    /// spellings of one invariant cannot drift apart.
    ///
    /// A split is cap-then-create. If the create fails, both providers try to
    /// restore the master's original recurrence and then rethrow. Until
    /// 2026-08-06 the restore was `_ = try? await updateEvent(…)`, which reports a
    /// failed rollback and a successful one IDENTICALLY. That matters because the
    /// rethrown error decides the queue's disposition: when the create failed with
    /// a 400/415/422, `isCalendarBadRequestError` claims it and the drain DELETES
    /// the durable row — so a rollback that had ALSO failed left the master
    /// permanently capped, with no successor series and no queued work to make
    /// one. Later sync imports the truncated master and cannot reconstruct the
    /// original recurrence.
    ///
    /// - `revertFailure == nil` ⇒ the original error, verbatim. The master is back
    ///   to its pre-split state, so the pre-existing disposition is still right and
    ///   this deliberately changes nothing about it.
    /// - `revertFailure != nil` ⇒ `CalDAVError.inconsistentState`, carrying BOTH
    ///   causes. The drain has a dedicated arm for that case whose own comment
    ///   already states the rationale (*"retrying would re-cap an already-capped
    ///   master and create duplicate successor series"*): terminal, with the reason
    ///   surfaced to the user.
    ///
    /// ⚠️ NOT "make every rollback failure retryable" — that is the mirror image,
    /// and it would put a two-step write that has already half landed into an
    /// unbounded retry against a master that is already capped. Terminal-with-a-
    /// reason is the disposition that is neither a silent drop nor a wedge.
    ///
    /// The case is `CalDAVError.inconsistentState` rather than a Google- or
    /// Graph-domain twin because that is the case the drain already claims;
    /// inventing a third spelling of one state is how classifiers drift.
    static func splitRollbackError(original: Error, revertFailure: Error?) -> Error {
        guard let revertFailure else { return original }
        return CalDAVError.inconsistentState(
            "the recurring series was capped but its replacement series could not be created (\(original)), and restoring the original recurrence also failed (\(revertFailure)). The series now ends early on the server and needs its recurrence fixed by hand.")
    }

    /// Does this Google Calendar 409 body positively say *"the identifier you
    /// supplied already exists"* (R13-U3)?
    ///
    /// Google documents exactly two 409 reasons on `events.insert`:
    ///   * `"duplicate"` — *"The requested identifier already exists."* The event
    ///     is there. This is the only one that is proof of anything.
    ///   * `"conflict"` — *"a batched item inside an `events.batch` operation
    ///     can't be executed due to an operational conflict."* Transient, and
    ///     retryable per Google's own guidance.
    /// Source: developers.google.com/workspace/calendar/api/guides/errors.
    ///
    /// ⚠️ FAIL-CLOSED, and the direction is load-bearing. Unparseable, empty and
    /// unrecognised bodies all return `false`, which routes the error to the
    /// drain's indeterminate/retry path — the SAFE side, because the retry is
    /// duplicate-safe (Google rejects a second insert of the same client-supplied
    /// id) while a wrong `true` would delete the user's intention on a conflict
    /// that never created anything. A nil-defaulted or optimistic reading here
    /// would be fail-DANGEROUS.
    ///
    /// ⚠️ **IT LIVES HERE, NOT ON THE QUEUE (R14-F2).** It was
    /// `AccountManagerCalendarQueue`'s `isGoogleDuplicateIdConflict` until
    /// 2026-08-06, and `splitSeries` — in THIS file — needs the identical
    /// question answered before it may treat a 409 as proof the successor series
    /// exists. Copying it in would have produced two spellings of one invariant,
    /// which is precisely the drift `splitRollbackError` above was created to
    /// prevent. Parsing a Google error payload is the Google provider's job, and
    /// `deterministicSplitEventId` / `splitRollbackError` already establish that
    /// a cross-provider helper lives on this type. Still `static` (hence
    /// nonisolated), so the discrimination stays table-testable against real
    /// Google error payloads exactly as before.
    static func isDuplicateIdConflict(_ body: Data?) -> Bool {
        guard let body, !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let err = json["error"] as? [String: Any] else { return false }
        // Google puts the machine-readable reason on the per-error entries; the
        // top-level object carries only `code` and `message`.
        guard let errors = err["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ($0["reason"] as? String) == "duplicate" }
    }

    // MARK: - Recurring helpers

    /// If `eventId` points to an OCCURRENCE of a recurring series (Google
    /// format: `<masterId>_<startTime>Z`), fetch the master and return its
    /// id + event. Otherwise return the originally-fetched event as the master.
    ///
    /// Google instance events do NOT carry the series `recurrence` — only the
    /// master does. So `splitSeries` / `updateOccurrence` called directly with
    /// an instance id would either fail ("not recurring; can't split") or hit
    /// the `/events/{id}/instances` endpoint with the wrong id and 400. The
    /// agent commonly passes an instance id because that's what
    /// `calendar_search` / `calendar_read` returns for an occurrence — resolve
    /// up front so split/updateOccurrence see the master regardless.
    private func resolveToMaster(calendarId: String, eventId: String) async throws -> (id: String, event: GCalEvent) {
        let fetched = try await getEvent(calendarId: calendarId, eventId: eventId)
        if let masterId = fetched.recurringEventId, !masterId.isEmpty, masterId != eventId {
            let master = try await getEvent(calendarId: calendarId, eventId: masterId)
            return (masterId, master)
        }
        return (eventId, fetched)
    }

    /// Find the Google instance id for `recurrenceId` by hitting the instances
    /// endpoint with a wide-enough window to tolerate DST transitions and
    /// device/event timezone mismatches.
    /// Window rationale: ±25 hours covers (a) DST shifts of up to 1h either
    /// way, (b) a worst-case device-vs-event timezone delta (e.g. UTC+14 vs
    /// UTC-12 = 26h difference — close to the limit but covered by the
    /// instances-endpoint's recurrence-aware filtering), and (c) all-day
    /// events where the instance start may be midnight in a different zone.
    /// We narrow back to the correct instance via day-prefix matching below.
    private func resolveInstanceId(calendarId: String, masterId: String, recurrenceId: String) async throws -> String {
        // recurrenceId is naive ISO; treat as device-local for the window math.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        guard let centerDate = fmt.date(from: String(recurrenceId)) else {
            // Fall back to date-only form (e.g. "2026-05-20" for an all-day event)
            // before declaring the recurrenceId malformed.
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            dateFmt.timeZone = TimeZone(identifier: "UTC")
            guard dateFmt.date(from: String(recurrenceId.prefix(10))) != nil else {
                throw GoogleCalendarError.eventNotFound
            }
            // Recurse with a normalized full-day form so the rest of the path
            // can use a single code branch.
            return try await resolveInstanceId(
                calendarId: calendarId, masterId: masterId,
                recurrenceId: "\(recurrenceId.prefix(10))T00:00:00"
            )
        }
        let windowSeconds: TimeInterval = 25 * 60 * 60
        let minDate = centerDate.addingTimeInterval(-windowSeconds)
        let maxDate = centerDate.addingTimeInterval(windowSeconds)
        let rfc3339 = ISO8601DateFormatter()
        rfc3339.formatOptions = [.withInternetDateTime]
        let timeMin = rfc3339.string(from: minDate)
        let timeMax = rfc3339.string(from: maxDate)

        let encodedTimeMin = timeMin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timeMin
        let encodedTimeMax = timeMax.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timeMax
        let data = try await request(
            path: "/calendars/\(calendarId)/events/\(masterId)/instances?timeMin=\(encodedTimeMin)&timeMax=\(encodedTimeMax)"
        )
        let resp = try JSONDecoder().decode(GCalEventListResponse.self, from: data)
        let items = resp.items ?? []
        let dayPrefix = String(recurrenceId.prefix(10))
        // First try strict day-prefix match against the instance's start (handles
        // DST inside the window). Fall back to the first instance only if exactly
        // ONE instance came back — multiple instances + no day-match means we
        // can't pick safely, so throw.
        if let dayMatch = items.first(where: { ev in
            guard let start = ev.start?.dateTime ?? ev.start?.date else { return false }
            return start.hasPrefix(dayPrefix)
        }), let id = dayMatch.id {
            return id
        }
        if items.count == 1, let id = items[0].id {
            return id
        }
        throw GoogleCalendarError.eventNotFound
    }

    /// Produce an RFC 5545 UNTIL value for capping a series just before the
    /// occurrence at naive-ISO `naive`.
    ///
    /// RFC 5545 §3.3.10: the UNTIL value type MUST match DTSTART's value type.
    ///   - Timed event (DTSTART is a date-time with a timezone) → UNTIL must be
    ///     a UTC date-time: `YYYYMMDDTHHMMSSZ`. We use (split − 1 second).
    ///   - All-day event (DTSTART is VALUE=DATE) → UNTIL must be a bare DATE:
    ///     `YYYYMMDD`. We use (split − 1 day) so the split day's occurrence is
    ///     excluded (UNTIL is inclusive of the date for all-day rules).
    ///
    /// `naive` is interpreted as device-local time. Accepts both the full
    /// `2026-05-20T17:00:00` form and the date-only `2026-05-20` form (the
    /// latter is what an all-day occurrence's recurrence_id looks like).
    /// Returns nil if the input is unparseable — callers MUST handle this
    /// (silently emitting "now-1s" would cap the series in the past with
    /// nothing in the new series).
    static func googleUntilString(beforeNaiveISO naive: String, allDay: Bool) -> String? {
        // Parse: try full date-time first, then fall back to date-only.
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dtFmt.timeZone = .current
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = .current
        let parsed = dtFmt.date(from: naive)
            ?? dateFmt.date(from: String(naive.prefix(10)))
        guard let date = parsed else { return nil }

        if allDay {
            // Day before, bare DATE form. Use Calendar arithmetic — subtracting
            // a flat 86400s lands on the wrong wall-clock day across a DST
            // transition (a 23h or 25h local day), which would cap the series
            // a day early/late.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            guard let dayBefore = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
            let out = DateFormatter()
            out.dateFormat = "yyyyMMdd"
            out.timeZone = .current
            return out.string(from: dayBefore)
        }
        // One second before, UTC date-time form.
        let untilDate = date.addingTimeInterval(-1)
        let out = DateFormatter()
        out.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        out.timeZone = TimeZone(identifier: "UTC")
        return out.string(from: untilDate)
    }

    /// Drop any existing UNTIL=... or COUNT=... segments, then append the new UNTIL.
    static func replaceOrAppendUntil(in rrule: String, untilValue: String) -> String {
        // RRULE format: "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10"
        let prefix = "RRULE:"
        let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
        let kept = body.split(separator: ";")
            .map(String.init)
            .filter { part in
                let upper = part.uppercased()
                return !upper.hasPrefix("UNTIL=") && !upper.hasPrefix("COUNT=")
            }
        return prefix + (kept + ["UNTIL=\(untilValue)"]).joined(separator: ";")
    }

    /// Drop UNTIL/COUNT from an RRULE, returning the open-ended pattern.
    static func stripUntilAndCount(_ rrule: String) -> String {
        let prefix = "RRULE:"
        let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
        let kept = body.split(separator: ";")
            .map(String.init)
            .filter { part in
                let upper = part.uppercased()
                return !upper.hasPrefix("UNTIL=") && !upper.hasPrefix("COUNT=")
            }
        return prefix + kept.joined(separator: ";")
    }

    /// Deterministic identifier for the NEW series produced by a
    /// `this_and_following` split. Derived purely from inputs that are STABLE
    /// across queue retries (`masterId` + `recurrenceId`), so retrying a split
    /// after a lost ACK targets the SAME resource instead of creating a
    /// duplicate series (the two-step cap-then-create is otherwise not
    /// idempotent — step 1 is, step 2 isn't).
    ///
    /// SHA-256 hex: 64 chars of `[0-9a-f]` — simultaneously a valid subset of
    /// Google's base32hex event-id charset (`a`–`v`, `0`–`9`; length 5–1024),
    /// a safe CalDAV `.ics` filename / URL path component, and well within
    /// Microsoft Graph's `transactionId` length limit.
    static func deterministicSplitEventId(masterId: String, recurrenceId: String) -> String {
        let seed = "tabmail-split|\(masterId)|\(recurrenceId)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a "full" `GCalEventInput` representing the patched state of an
    /// existing event, by inheriting unchanged fields from `existing` and
    /// applying `patch` overrides. Used to defend against partial-PATCH
    /// server quirks like Exchange Graph silently rewriting `start`/`end` to
    /// UTC midnight at `range.startDate` when only `recurrence` is sent.
    /// Google's docs even recommend "prefer GET + UPDATE over PATCH" — this
    /// helper makes that pattern available everywhere.
    ///
    /// Attendees are deliberately NOT inherited from `existing`: re-sending
    /// the existing attendees in a PATCH would reset their `responseStatus`
    /// fields (Graph/Google treat re-sent attendees as newly invited). We
    /// only include attendees when `patch` explicitly changes them; the
    /// caller is responsible for delta-resolving against the existing list
    /// (see `AccountManagerCalendarQueue.resolveAttendeeDelta`).
    static func mergeExistingEventWithPatch(existing: GCalEvent, patch: GCalEventInput) -> GCalEventInput {
        var merged = GCalEventInput()
        merged.summary = patch.summary ?? existing.summary
        merged.location = patch.location ?? existing.location
        merged.description = patch.description ?? existing.description
        merged.transparency = patch.transparency ?? existing.transparency

        // Date/time. When the patch moves ONE side (start OR end) without
        // specifying the other, preserve the master's wall-clock duration
        // by deriving the missing side. Without this, "move start to 3 PM"
        // on a 30-min event leaves end at the original wall time, stretching
        // (or inverting) the duration. This matches the LLM's implicit
        // intent — when it omits end_iso, it almost always means "keep the
        // same length, just shift the start."
        let hasPatchStart = patch.startDate != nil || patch.startDateTime != nil
        let hasPatchEnd = patch.endDate != nil || patch.endDateTime != nil
        let masterDuration: TimeInterval? = {
            guard let s = existing.startDate, let e = existing.endDate else { return nil }
            let d = e.timeIntervalSince(s)
            return d > 0 ? d : nil
        }()

        // Resolve start.
        if hasPatchStart {
            merged.startDate = patch.startDate
            merged.startDateTime = patch.startDateTime
            merged.startTimeZone = patch.startTimeZone
        } else if existing.isAllDay {
            merged.startDate = existing.start?.date
        } else {
            merged.startDateTime = existing.start?.dateTime
            merged.startTimeZone = existing.start?.timeZone
        }

        // Resolve end.
        if hasPatchEnd {
            merged.endDate = patch.endDate
            merged.endDateTime = patch.endDateTime
            merged.endTimeZone = patch.endTimeZone
        } else if hasPatchStart, let duration = masterDuration {
            // Derive end = newStart + masterDuration. The LLM moved start
            // without end; preserve duration so a 30-min event stays 30 min.
            if existing.isAllDay, let sd = patch.startDate {
                // For all-day, work in whole days using a calendar so DST
                // boundaries roll correctly.
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
                if let startDate = df.date(from: String(sd.prefix(10))) {
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
                    let days = max(1, Int((duration / 86400).rounded()))
                    if let endDate = cal.date(byAdding: .day, value: days, to: startDate) {
                        merged.endDate = df.string(from: endDate)
                    }
                }
            } else if let sdt = patch.startDateTime, let startInstant = Date.fromISO8601(sdt) {
                let endInstant = startInstant.addingTimeInterval(duration)
                let tz = patch.startTimeZone.flatMap { TimeZone(identifier: $0) } ?? .current
                merged.endDateTime = endInstant.iso8601String(timeZone: tz)
                merged.endTimeZone = patch.startTimeZone ?? existing.end?.timeZone
            } else {
                // Couldn't parse — fall back to inheriting existing end.
                if existing.isAllDay { merged.endDate = existing.end?.date }
                else { merged.endDateTime = existing.end?.dateTime; merged.endTimeZone = existing.end?.timeZone }
            }
        } else if hasPatchEnd, let duration = masterDuration {
            // Symmetric case: patch moves END only — derive start = newEnd - masterDuration.
            if existing.isAllDay, let ed = patch.endDate {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
                if let endDate = df.date(from: String(ed.prefix(10))) {
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
                    let days = max(1, Int((duration / 86400).rounded()))
                    if let startDate = cal.date(byAdding: .day, value: -days, to: endDate) {
                        merged.startDate = df.string(from: startDate)
                    }
                }
            } else if let edt = patch.endDateTime, let endInstant = Date.fromISO8601(edt) {
                let startInstant = endInstant.addingTimeInterval(-duration)
                let tz = patch.endTimeZone.flatMap { TimeZone(identifier: $0) } ?? .current
                merged.startDateTime = startInstant.iso8601String(timeZone: tz)
                merged.startTimeZone = patch.endTimeZone ?? existing.start?.timeZone
            }
        } else if existing.isAllDay {
            merged.endDate = existing.end?.date
        } else {
            merged.endDateTime = existing.end?.dateTime
            merged.endTimeZone = existing.end?.timeZone
        }

        // Recurrence: patch wins; else inherit. (For instance PATCHes,
        // caller must `merged.recurrence = nil` AFTER — instances can't
        // carry a series rule and providers will 400.)
        merged.recurrence = patch.recurrence ?? existing.recurrence

        // Attendees: only set when the patch is changing them. See doc.
        merged.attendees = patch.attendees

        return merged
    }

    /// Build a `GCalEventInput` for the NEW series of a split. Inherits the
    /// master's fields, applies the caller's `patch` on top, and rewrites
    /// start/end/recurrence to the split point.
    static func mergeMasterAndPatch(
        master: GCalEvent,
        patch: GCalEventInput,
        newStartNaiveISO: String,
        newRecurrence: [String]
    ) -> GCalEventInput {
        var out = GCalEventInput()

        out.summary = patch.summary ?? master.summary
        out.location = patch.location ?? master.location
        out.description = patch.description ?? master.description
        out.transparency = patch.transparency ?? master.transparency

        // Start = new split point. End = split point + master's duration.
        // CRITICAL: preserve the master's all-day-ness. An all-day master must
        // produce an all-day new series — emitting startDateTime/endDateTime
        // (the timed form) would silently convert the series to a timed event.
        let durationSec: TimeInterval = {
            guard let s = master.startDate, let e = master.endDate else {
                return master.isAllDay ? 86400 : 3600
            }
            return e.timeIntervalSince(s)
        }()
        if master.isAllDay {
            // All-day: emit date-only start/end. Google's all-day `end.date` is
            // EXCLUSIVE, so a 1-day event is start=D, end=D+1 (durationSec≈86400).
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let dateOnlyFmt = DateFormatter()
            dateOnlyFmt.dateFormat = "yyyy-MM-dd"
            dateOnlyFmt.timeZone = .current
            let parseFmt = DateFormatter()
            parseFmt.dateFormat = "yyyy-MM-dd"
            parseFmt.timeZone = .current
            // Prefer the patch's explicit new date when the LLM is moving the
            // series with the split. `recurrence_id` only identifies WHICH
            // occurrence the split anchors at — `start_iso` is the user's
            // desired NEW date. Falling back to the recurrence_id silently
            // ignores a move the LLM was asked to perform.
            let preferredStart = patch.startDate ?? String(newStartNaiveISO.prefix(10))
            if let startDate = parseFmt.date(from: String(preferredStart.prefix(10))) {
                out.startDate = dateOnlyFmt.string(from: startDate)
                // End: patch's explicit end wins; else start + master's duration.
                if let patchEnd = patch.endDate, let endDate = parseFmt.date(from: String(patchEnd.prefix(10))) {
                    out.endDate = dateOnlyFmt.string(from: endDate)
                } else {
                    let days = max(1, Int((durationSec / 86400).rounded()))
                    if let endDate = cal.date(byAdding: .day, value: days, to: startDate) {
                        out.endDate = dateOnlyFmt.string(from: endDate)
                    }
                }
            }
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fmt.timeZone = .current
            // Prefer the patch's explicit new datetime — same rationale as
            // above. The recurrence_id is the "WHICH occurrence" anchor; the
            // patch's start_iso/end_iso is the "WHAT TIME" the new series
            // should be at. Conflating them was silently dropping LLM-issued
            // moves like "split at the 15:00 occurrence and put the new
            // series at 15:30".
            let startInstant: Date? = {
                if let pISO = patch.startDateTime, let d = Date.fromISO8601(pISO) { return d }
                return fmt.date(from: newStartNaiveISO)
            }()
            if let startDate = startInstant {
                let endDate: Date = {
                    if let pISO = patch.endDateTime, let d = Date.fromISO8601(pISO) { return d }
                    return startDate.addingTimeInterval(durationSec)
                }()
                // Use device-local TZ — `iso8601String(timeZone:)` emits the form
                // Google's events API expects (`2026-05-20T17:00:00-07:00`).
                out.startDateTime = startDate.iso8601String(timeZone: .current)
                out.endDateTime = endDate.iso8601String(timeZone: .current)
                // CRITICAL: Google REQUIRES a named `timeZone` on start/end when
                // creating a RECURRING event — an offset alone is ambiguous
                // across DST for recurrence expansion. Without this the new-
                // series POST is rejected with HTTP 400 "Missing time zone
                // definition for start time". Inherit the master's IANA zone;
                // fall back to the device zone if the master didn't carry one.
                out.startTimeZone = master.start?.timeZone ?? TimeZone.current.identifier
                out.endTimeZone = master.end?.timeZone ?? master.start?.timeZone ?? TimeZone.current.identifier
            }
        }

        // Attendees: prefer patch's resolved list, else inherit master's.
        if let patchAttendees = patch.attendees {
            out.attendees = patchAttendees
        } else {
            out.attendees = (master.attendees ?? []).compactMap { att in
                guard let email = att.email, !email.isEmpty else { return nil }
                return (email: email, name: att.displayName)
            }
        }

        // Recurrence: caller-supplied `newRecurrence` is the default (master's
        // RRULE stripped of UNTIL/COUNT). If `patch.recurrence` is non-nil, the
        // LLM/user explicitly asked for a different pattern on the new series —
        // honor that. This keeps iOS consistent with the TB bridge, which also
        // respects patch.recurrence when present.
        if let patchRecurrence = patch.recurrence, !patchRecurrence.isEmpty {
            out.recurrence = patchRecurrence
        } else {
            out.recurrence = newRecurrence
        }
        return out
    }

    // MARK: - HTTP

    /// 🚨 **R14-F1 — THE ERROR PAYLOAD IS `errorBody`, NEVER `data`.**
    /// `performHTTPRequest` returns `data: nil` on *every* non-2xx and puts the
    /// bytes the server sent in `errorBody` (`HTTPRequestResult`'s own doc states
    /// this). Both throws below reached this line only because `result.data` was
    /// nil, so `httpError(_, result.data)` could never carry anything but `nil` —
    /// which made `AccountManagerCalendarQueue.isGoogleDuplicateIdConflict`
    /// VACUOUS in production (it returns `false` at its first `guard let body`)
    /// and left `badRequestReason` / `parseHttpReason` permanently on their
    /// code-only fallback. The classifier was provably correct and provably
    /// unreachable: its tests construct `httpError(409, body)` directly and so
    /// bypass this seam.
    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let token = try await accessToken(false)
        let result = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: token, session: testSession, logLabel: "GoogleCalendar")

        if let data = result.data {
            return data
        }

        // 401 — token expired, force refresh and retry once
        if result.statusCode == 401 {
            print("[GoogleCalendar] Token expired, refreshing...")
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: freshToken, session: testSession, logLabel: "GoogleCalendar")
            if let data = retry.data {
                return data
            }
            throw GoogleCalendarError.httpError(retry.statusCode, retry.errorBody)
        }

        // 403 — missing calendar scope
        if result.statusCode == 403 {
            throw GoogleCalendarError.missingScope
        }

        throw GoogleCalendarError.httpError(result.statusCode, result.errorBody)
    }

    // MARK: - Helpers

}

// MARK: - Errors

enum GoogleCalendarError: Error {
    case missingScope
    case httpError(Int, Data?)
    case eventNotFound
    /// R13-U1 — a calendar/event/instance id could not be expressed as ONE URL
    /// path segment, so the request was never issued. Deterministic in the stored
    /// id, therefore never transient: `isCalendarBadRequestError` claims it so the
    /// drain retires the op with a reason instead of retrying it forever.
    /// Payload is the id's ROLE (e.g. "Google calendar id"), never the id itself —
    /// this string reaches the user-facing failure reason.
    case invalidPathSegment(String)
}

// MARK: - Response Models

struct GCalCalendar: Codable, Sendable {
    let id: String
    let summary: String?
    let primary: Bool?
    let accessRole: String?
    let backgroundColor: String?
    /// Google Calendar's "show in UI" flag on the calendarList entry. Calendars
    /// the user has unchecked in Google Calendar / iOS Calendar / Thunderbird
    /// come back with `selected: false`. Other providers don't surface this
    /// field — leave nil and treat nil as "selected" (caller decides).
    let selected: Bool?
}

struct GCalCalendarListResponse: Codable, Sendable {
    let items: [GCalCalendar]?
    let nextPageToken: String?
}

struct GCalEvent: Codable, Sendable {
    let id: String?
    let summary: String?
    let location: String?
    let description: String?
    let start: GCalDateTime?
    let end: GCalDateTime?
    let attendees: [GCalAttendee]?
    let organizer: GCalOrganizer?
    let recurrence: [String]?
    let transparency: String?
    let status: String?
    let htmlLink: String?
    let created: String?
    let updated: String?
    /// Diagnostic-only fields — populated from the API response so we can
    /// understand the provenance of empty-title rows. Not consumed by the
    /// rest of the app today; safe to ignore. Add to GCalEventInput as well
    /// before relying on these for write paths.
    let eventType: String?       // "default" / "workingLocation" / "focusTime" / "outOfOffice" / "birthday" / "fromGmail"
    let iCalUID: String?         // RFC 5545 UID — survives across imports / sync
    let kind: String?            // "calendar#event" — sanity check
    let visibility: String?      // "default" / "public" / "private" / "confidential"
    /// Back-reference to the series master when `singleEvents=true` expansion
    /// returned this row as an individual occurrence instance. Google's API
    /// populates this field; the `recurrence` array is then empty on the
    /// instance (the rule lives on the master only). We use this to enrich
    /// the LLM-facing search output with the master's RRULE so a recurring
    /// series's UNTIL/COUNT is visible on every occurrence line.
    let recurringEventId: String?
}

// Convenience initializer that fills in `eventType`/`iCalUID`/`kind`/`visibility`
// with nil so existing call sites (Exchange, CalDAV, ICSParser, tests) don't have
// to thread the diagnostic-only fields. Google's Decodable path uses the
// synthesized memberwise init via `JSONDecoder` and gets the real values.
extension GCalEvent {
    init(
        id: String?,
        summary: String?,
        location: String?,
        description: String?,
        start: GCalDateTime?,
        end: GCalDateTime?,
        attendees: [GCalAttendee]?,
        organizer: GCalOrganizer?,
        recurrence: [String]?,
        transparency: String?,
        status: String?,
        htmlLink: String?,
        created: String?,
        updated: String?,
        recurringEventId: String? = nil
    ) {
        self.init(
            id: id, summary: summary, location: location, description: description,
            start: start, end: end, attendees: attendees, organizer: organizer,
            recurrence: recurrence, transparency: transparency, status: status,
            htmlLink: htmlLink, created: created, updated: updated,
            eventType: nil, iCalUID: nil, kind: nil, visibility: nil,
            recurringEventId: recurringEventId
        )
    }
}

struct GCalDateTime: Codable, Sendable {
    let dateTime: String?  // RFC 3339 for timed events
    let date: String?      // YYYY-MM-DD for all-day events
    let timeZone: String?
}

struct GCalAttendee: Codable, Sendable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let organizer: Bool?
    let `self`: Bool?
}

struct GCalOrganizer: Codable, Sendable {
    let email: String?
    let displayName: String?
    let `self`: Bool?
}

struct GCalEventListResponse: Codable, Sendable {
    let items: [GCalEvent]?
    let nextPageToken: String?
}

// MARK: - Input Model

struct GCalEventInput: Sendable {
    /// Pre-generated event ID for idempotent creates (crash recovery).
    var id: String?
    var summary: String?
    var location: String?
    var description: String?
    var startDateTime: String?   // RFC 3339
    var startDate: String?       // YYYY-MM-DD (all-day)
    var startTimeZone: String?
    var endDateTime: String?
    var endDate: String?
    var endTimeZone: String?
    var attendees: [(email: String, name: String?)]?
    var transparency: String?
    var recurrence: [String]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [:]

        if let id { json["id"] = id }
        if let summary { json["summary"] = summary }
        if let location { json["location"] = location }
        if let description { json["description"] = description }
        if let transparency { json["transparency"] = transparency }

        // Start
        var startObj: [String: Any] = [:]
        if let startDateTime { startObj["dateTime"] = startDateTime }
        if let startDate { startObj["date"] = startDate }
        if let startTimeZone { startObj["timeZone"] = startTimeZone }
        if !startObj.isEmpty { json["start"] = startObj }

        // End
        var endObj: [String: Any] = [:]
        if let endDateTime { endObj["dateTime"] = endDateTime }
        if let endDate { endObj["date"] = endDate }
        if let endTimeZone { endObj["timeZone"] = endTimeZone }
        if !endObj.isEmpty { json["end"] = endObj }

        // Attendees
        if let attendees {
            json["attendees"] = attendees.map { a -> [String: Any] in
                var obj: [String: Any] = ["email": a.email]
                if let name = a.name { obj["displayName"] = name }
                return obj
            }
        }

        // Recurrence
        if let recurrence { json["recurrence"] = recurrence }

        return json
    }
}

// MARK: - GCalEvent Helpers

extension GCalEvent {
    /// Parse start date from either dateTime (timed) or date (all-day).
    var startDate: Date? {
        if let dt = start?.dateTime { return parseRFC3339(dt) }
        if let d = start?.date { return parseDateOnly(d) }
        return nil
    }

    /// Parse end date from either dateTime (timed) or date (all-day).
    var endDate: Date? {
        if let dt = end?.dateTime { return parseRFC3339(dt) }
        if let d = end?.date { return parseDateOnly(d) }
        return nil
    }

    /// Whether this is an all-day event (uses date instead of dateTime).
    var isAllDay: Bool {
        start?.date != nil
    }

    private func parseRFC3339(_ str: String) -> Date? {
        Date.fromISO8601(str)
    }

    private func parseDateOnly(_ str: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.date(from: str)
    }
}
