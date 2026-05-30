/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_event_edit` tool matching TB addon's `calendar_event_edit.js`.
/// Edits an existing calendar event with user confirmation (ADR-IOS-024).
/// Queued for crash-safe async execution via PendingCalendarOperation.
struct CalendarEventEditTool: AgentTool, Sendable {
    let name = "calendar_event_edit"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let rawEventId) = arguments["event_id"],
              !rawEventId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing event_id — use calendar_event_read or calendar_search to look up the event first"}"#
        }

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to compound event ID
        let compoundId: String
        let numericId: Int?
        if let n = Int(rawEventId), let realId = await ctx.translator.toRealId(n) {
            compoundId = realId
            numericId = n
            print("[CalendarEventEditTool] Resolved numeric id \(n) → \(realId.prefix(50))...")
        } else {
            compoundId = rawEventId.trimmingCharacters(in: .whitespaces)
            numericId = nil
        }

        // Extract accountId + rawEventId from compound ID
        let accountId: String
        let eventId: String
        if let parts = CompoundEventId.split(compoundId) {
            accountId = parts.accountId
            eventId = parts.eventId
        } else {
            // Legacy bare event ID — try preferred account
            accountId = ""
            eventId = compoundId
        }

        // Resolve calendarId from cache
        let calInfo: EventCalendarInfo?
        if let numId = numericId {
            calInfo = await ctx.translator.resolveEventCalendarInfo(numId)
        } else {
            calInfo = nil
        }
        let calendarId = calInfo?.calendarId
        let calendarName = calInfo?.calendarName

        // Resolve provider — single main-actor hop for dict lookup
        let resolvedAccountId = calInfo?.accountId ?? accountId
        let provider: (any CalendarProvider)?
        if !resolvedAccountId.isEmpty {
            provider = await AccountManager.shared.calendarProviders[resolvedAccountId]
        } else {
            provider = await CalendarProviderDispatch.resolve(db: ctx.db).resolved?.provider
        }

        // Build change descriptions for confirmation card from arguments alone
        var changes: [String] = []
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "title") {
            changes.append("title → \(v)")
        }
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "start_iso") {
            changes.append("start → \(v)")
        }
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "end_iso") {
            changes.append("end → \(v)")
        }
        if let v = CalendarToolHelpers.boolArg(arguments, "all_day") {
            changes.append("all day → \(v ? "yes" : "no")")
        }
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "location") {
            changes.append("location → \(v.isEmpty ? "(cleared)" : v)")
        }
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "description") {
            // Full body is surfaced in the dedicated `notes` block on the
            // confirmation card; the changes list just flags that it's being
            // updated (or cleared) so a long agenda/meeting-link doesn't blow
            // up the single-line delta row.
            changes.append("description → \(v.isEmpty ? "(cleared)" : "(updated)")")
        }
        if let v = CalendarToolHelpers.stringArgOpt(arguments, "transparency") {
            changes.append("availability → \(v)")
        }
        if case .dictionary(let rec) = arguments["recurrence"],
           case .string(let freq) = rec["freq"] {
            var desc = freq.lowercased()
            if case .int(let n) = rec["interval"], n > 1 { desc = "every \(n) \(desc)" }
            if case .int(let count) = rec["count"] { desc += " (\(count) times)" }
            else if case .string(let until) = rec["until"] { desc += " (until \(until))" }
            changes.append("recurrence → \(desc)")
        }

        // Resolve the recurring-edit scope up front — it drives both the
        // confirmation-card date math (which occurrence to show) and the
        // scope clause appended to `changes`. Resolved here, before the API
        // fetch, so a missing recurrence_id fails fast.
        // (calendar_event_edit-v1.5.21+.)
        let scopeRaw = CalendarToolHelpers.stringArgOpt(arguments, "edit_scope")?.lowercased()
        let recurrenceIdArg = CalendarToolHelpers.stringArgOpt(arguments, "recurrence_id")
        let resolvedScope: String = scopeRaw
            ?? (recurrenceIdArg != nil ? "this_only" : "all")
        if resolvedScope == "this_only" || resolvedScope == "this_and_following" {
            guard let rid = recurrenceIdArg else {
                throw ToolDeclinedError(output: ToolJSON.string(from: [
                    "error": "edit_scope='\(resolvedScope)' requires recurrence_id (the start_iso of the target occurrence). Use calendar_event_read or calendar_read to find it, then retry.",
                ] as [String: Any]))
            }
            if resolvedScope == "this_only" {
                changes.append("scope → just this occurrence (\(rid))")
            } else {
                changes.append("scope → this and all future occurrences (starting \(rid))")
            }
        }

        // Fetch current event details from API for confirmation card
        var fetchedEvent: GCalEvent?
        if let provider, let calId = calendarId {
            fetchedEvent = try? await provider.getEvent(calendarId: calId, eventId: eventId)
            if let event = fetchedEvent {
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: calId,
                        calendarName: calendarName, translator: ctx.translator
                    )
                }
            }
        } else if let provider {
            // calendarId unknown — try default calendar, then scan all calendars
            let defaultCalId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
            fetchedEvent = try? await provider.getEvent(calendarId: defaultCalId, eventId: eventId)
            if let event = fetchedEvent {
                // Found on default calendar — update cache so future edit/delete use correct calendarId
                let accId = resolvedAccountId
                let translator = ctx.translator
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: accId, calendarId: defaultCalId,
                        calendarName: calendarName, translator: translator
                    )
                }
            }
        }

        // Could not dereference the event — refuse rather than show a placeholder
        // confirmation card with "(Event)" + zero-duration times. The LLM either
        // passed a numeric id the translator no longer knows (idMap miss) or the
        // provider returned 404. Either way we cannot meaningfully describe what
        // the user would be confirming. Surface a structured error so the agent
        // can re-search (calendar_event_read / calendar_search) and retry.
        guard fetchedEvent != nil else {
            print("[CalendarEventEditTool] Could not dereference event_id='\(eventId.prefix(50))' (compound='\(compoundId.prefix(50))') — refusing edit")
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: could not find event with id '\(compoundId)'. The id may be wrong or the event may have been deleted. Call calendar_event_read or calendar_search to look up the correct event, then retry.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        // Resolve proposed dates — prefer arguments (new values), fall back to current event state.
        // For a single-occurrence / split edit (scope is this_only / this_and_following), the
        // card must show the TARGET OCCURRENCE — not the series master — otherwise it
        // misleadingly displays the wrong date (e.g. the master on the 14th when the user is
        // editing the occurrence on the 21st). Keyed off `resolvedScope`, NOT raw recurrence_id
        // presence, so an `all`-scope edit that happens to carry a stale recurrence_id still
        // shows the master.
        let tz = CalendarToolHelpers.resolveTimeZone(arguments)
        let showsOccurrence = resolvedScope != "all"
        let masterDuration: TimeInterval? = {
            guard let s = fetchedEvent?.startDate, let e = fetchedEvent?.endDate else { return nil }
            return e.timeIntervalSince(s)
        }()
        // The confirmation card shows the event's CURRENT state — i.e. what
        // the user is editing FROM. The changes list (built above) already
        // enumerates every patched field via "field → newValue" notation,
        // so the date row at the top doesn't need to preview the post-edit
        // values. Showing current state keeps the card free of preview
        // math that could mis-derive a side (the "19:30 – 19:30" bug came
        // from end-side derivation falling back to OLD end), and matches
        // the user's expectation of "old at top, changes below".
        //
        // For an occurrence-scope edit (this_only / this_and_following),
        // current = the specific occurrence (recurrence_id + master
        // duration) rather than the master.
        let cardStart: Date?
        if showsOccurrence, let rid = recurrenceIdArg,
           let occ = EKEventStoreHelper.parseNaiveISO(rid, timeZone: tz) {
            cardStart = occ
        } else {
            cardStart = fetchedEvent?.startDate
        }
        let cardEnd: Date?
        if showsOccurrence, let start = cardStart, let dur = masterDuration {
            cardEnd = start.addingTimeInterval(dur)
        } else {
            cardEnd = fetchedEvent?.endDate
        }

        // Resolve event title: prefer argument, then current event state, then fallback
        let proposedTitle = CalendarToolHelpers.stringArgOpt(arguments, "title")
            ?? fetchedEvent?.summary
            ?? "(Event)"

        // Attendees are delta-based (v1.5.21+): parse add_attendees / remove_attendees,
        // merge against the freshly-fetched event's attendees for the projected final list
        // shown on the confirmation card. The queue path re-resolves the delta at execute
        // time against the latest provider state — the card here is best-effort preview.
        let addAttendees = CalendarToolHelpers.parseAttendeeAdds(arguments["add_attendees"])
        let removeAttendees = CalendarToolHelpers.parseAttendeeRemoves(arguments["remove_attendees"])
        var attendeeNames: [String] = []
        let baseAttendees: [(email: String, name: String?)] = (fetchedEvent?.attendees ?? []).compactMap { att in
            guard let raw = att.email, !raw.isEmpty else { return nil }
            let email = CalendarToolHelpers.stripMailto(raw)
            return (email: email, name: att.displayName)
        }
        if !addAttendees.isEmpty || !removeAttendees.isEmpty {
            let merged = CalendarToolHelpers.applyAttendeeDelta(
                base: baseAttendees, adds: addAttendees, removes: removeAttendees
            )
            attendeeNames = merged.map { entry in
                if let n = entry.name, !n.isEmpty { return "\(n) <\(entry.email)>" }
                return entry.email
            }
            let deltaSummary = [
                addAttendees.isEmpty ? nil : "+\(addAttendees.count)",
                removeAttendees.isEmpty ? nil : "-\(removeAttendees.count)"
            ].compactMap { $0 }.joined(separator: " / ")
            if !deltaSummary.isEmpty {
                changes.append("attendees → \(deltaSummary)")
            }
        }

        // ADR-IOS-024: Show confirmation card. Title/start/end/all-day
        // intentionally reflect the event's CURRENT state — the changes
        // list below enumerates every patched field. `proposedTitle` is
        // used downstream (queue, LLM result string) since it represents
        // the FINAL title; the card itself shows the old title at top.
        let currentTitle: String = (fetchedEvent?.summary?.isEmpty == false ? fetchedEvent!.summary! : "(Event)")
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventEdit,
            calendarEvents: [.init(
                eventId: eventId,
                calendarId: calendarName ?? "",
                title: currentTitle,
                startDate: cardStart ?? Date(),
                endDate: cardEnd ?? Date(),
                isAllDay: fetchedEvent?.isAllDay ?? false,
                changes: changes,
                attendees: attendeeNames,
                timeZoneId: CalendarToolHelpers.stringArgOpt(arguments, "timezone"),
                notes: CalendarToolHelpers.stringArgOpt(arguments, "description")
            )]
        )

        guard confirmed else {
            print("[CalendarEventEditTool] User declined edit for event_id=\(eventId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to edit this event.",
            ] as [String: Any]))
        }

        guard !resolvedAccountId.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }
        return try await queueCalendarEdit(accountId: resolvedAccountId, calendarId: calendarId, calendarName: calendarName, eventId: eventId, compoundId: compoundId, arguments: arguments, resolvedScope: resolvedScope, recurrenceId: recurrenceIdArg, cardState: cardState, eventTitle: proposedTitle, translator: ctx.translator)
    }

    // MARK: - Calendar (Queued)

    private func queueCalendarEdit(accountId: String, calendarId: String?, calendarName: String?, eventId: String, compoundId: String, arguments: [String: JSONValue], resolvedScope: String, recurrenceId: String?, cardState: AgentToolRouter.ActionConfirmation.ResponseState, eventTitle: String, translator: any ChatIdTranslating) async throws -> String {
        let manager = AccountManager.shared
        let op = try await manager.queueCalendarOperation(
            type: .edit,
            accountId: accountId,
            eventId: eventId,
            calendarId: calendarId,
            arguments: arguments
        )

        // Prefer the LLM's new title when changing it; otherwise the
        // proposedTitle from execute() (fetched event or fallback). Used both
        // for the result string and the new-series pill caching after a split.
        let title = CalendarToolHelpers.stringArgOpt(arguments, "title") ?? eventTitle
        let resolvedTz = CalendarToolHelpers.resolveTimeZone(arguments)
        let touchesDateTime = CalendarToolHelpers.stringArgOpt(arguments, "start_iso") != nil
            || CalendarToolHelpers.stringArgOpt(arguments, "end_iso") != nil
        print("[CalendarEventEditTool] Queued edit (op: \(op.id), event: \(eventId)) scope=\(resolvedScope)")

        // Wait briefly for the drain to surface a terminal outcome so the LLM
        // gets ACCURATE feedback in-turn. Without this, the tool returns
        // "queued successfully" optimistically, the async drain later fails
        // (e.g. HTTP 400 from the provider), and the op is silently dropped —
        // the LLM has already told the user "done" based on a false success.
        // On permanent failure the agent gets a structured error and can
        // retry with corrected args; on timeout we fall through to the async
        // "queued" message so the user is not blocked forever.
        let outcome = await manager.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 10.0)
        if case .permanentFailure(let reason) = outcome {
            print("[CalendarEventEditTool] Permanent failure for op \(op.id): \(reason)")
            // Flip the confirmation card to its red/⚠ failed state so the user
            // sees the failure inline in chat — not just in the LLM's text
            // follow-up.
            await MainActor.run { cardState.failureReason = reason }
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason). The event was NOT changed. Do not tell the user the edit succeeded — report the failure and, if the arguments can be corrected, call calendar_event_edit again.",
                "event_id": compoundId,
                "event_title": title,
            ] as [String: Any])
        }

        // Echo the RESOLVED edit_scope back to the LLM so it can accurately tell
        // the user what slice of the series changed. Critical for the inferred
        // case: when the LLM passes recurrence_id without edit_scope, the scope
        // is silently inferred as 'this_only' — without this line the model
        // would have no way to know only one occurrence was affected.
        let confirmed: Bool
        let newSeriesId: String?
        if case .success(let nsId, _) = outcome {
            confirmed = true
            newSeriesId = nsId
        } else {
            confirmed = false
            newSeriesId = nil
        }

        // Refresh the cached event details on success so a subsequent
        // [Event](N) pill tap — or another in-turn tool call —
        // sees the post-edit state without requiring another
        // calendar_event_read. The pre-confirmation fetch above seeded
        // the cache with the OLD state; without this overwrite, the
        // cache stays stale until the session is torn down.
        //
        // NOTE: we deliberately do NOT call evictEventDetail here —
        // it clears the calendar-provenance cache (eventCalendarCache
        // + persisted v55 row) too, which would then break the
        // resolveEventDetail live-fetch path on the next tap (it
        // needs the calendarId to call provider.getEvent). Re-fetch
        // and overwrite the detail entry instead; the provenance
        // entry stays intact.
        //
        // For `this_and_following`, also fetch+cache the new series
        // so its first pill render shows real data instead of
        // waiting on a resolveEventDetail miss.
        if confirmed, let calId = calendarId,
           let provider = await AccountManager.shared.calendarProviders[accountId] {
            let nsIdLocal = newSeriesId
            if let fresh = try? await provider.getEvent(calendarId: calId, eventId: eventId) {
                await CalendarToolHelpers.cacheEventDetailsForPills(
                    [fresh], accountId: accountId, calendarId: calId,
                    calendarName: calendarName, translator: translator
                )
            }
            if let nsId = nsIdLocal, !nsId.isEmpty,
               let freshNew = try? await provider.getEvent(calendarId: calId, eventId: nsId) {
                await CalendarToolHelpers.cacheEventDetailsForPills(
                    [freshNew], accountId: accountId, calendarId: calId,
                    calendarName: calendarName, translator: translator
                )
            }
        }
        // Past tense ONLY when the drain confirmed the write in-turn. On timeout
        // the op is still queued (status below says "queued / will be applied
        // shortly"), so the scope clause must not claim the change already
        // happened — describe it in future tense to stay consistent.
        let scopeVerb = confirmed ? "was changed" : "will be changed"
        let scopeVerbPlural = confirmed ? "were changed" : "will be changed"
        let scopeLine: String
        switch resolvedScope {
        case "this_only":
            scopeLine = "edit_scope: this_only — only the occurrence on \(recurrenceId ?? "?") \(scopeVerb); other occurrences are untouched"
        case "this_and_following":
            scopeLine = "edit_scope: this_and_following — this occurrence and all later ones (from \(recurrenceId ?? "?")) \(scopeVerbPlural); earlier occurrences are untouched"
        default:
            scopeLine = "edit_scope: all — the change applies to the entire event/series"
        }
        // For a `this_and_following` split, the SERVER created a brand-new
        // series for the second half. The master is now truncated to before
        // `recurrence_id` — any subsequent edit/delete to occurrences on or
        // after that date must address the NEW series id, not the master's.
        // Surface it as `new_series_event_id:` so `processToolOutputForLLM`
        // assigns it a numeric id the LLM can route to. The trailing
        // `event_title:` is what `extractEventTitles` keys off to cache the
        // pill display name; without it the new-series pill resolves to the
        // default "Event" instead of the actual title.
        let newSeriesLine: String? = {
            guard let nsId = newSeriesId, !nsId.isEmpty else { return nil }
            let newCompound = CompoundEventId.make(accountId: accountId, eventId: nsId)
            var lines = ["new_series_event_id: \(newCompound)"]
            if !title.isEmpty { lines.append("event_title: \(title)") }
            lines.append("note: For dates on/after \(recurrenceId ?? "?"), use new_series_event_id — the master event_id above only covers occurrences before that date.")
            return lines.joined(separator: "\n")
        }()
        return [
            confirmed ? "Calendar event updated successfully." : "Calendar event update queued successfully.",
            "event_id: \(compoundId)",
            title.isEmpty ? nil : "event_title: \(title)",
            scopeLine,
            newSeriesLine,
            // Only surface the timezone when this edit reinterpreted any
            // datetime — otherwise it's irrelevant noise (the event keeps its
            // existing stored timezone).
            touchesDateTime ? "timezone: \(resolvedTz.identifier)" : nil,
            confirmed ? nil : "Changes will be applied shortly.",
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
