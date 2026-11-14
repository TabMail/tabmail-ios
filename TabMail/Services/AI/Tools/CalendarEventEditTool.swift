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
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // The device's zone, snapshotted as this operation's first step (#753): a `timezone` the
        // assistant did not give is this zone for the occurrence read, the routing, the card, the
        // queued edit and the result, so the edit is written where the card showed it even if the
        // device's zone changes before the queue drains.
        let deviceZone = ctx.deviceZone
        // `CalendarSeriesScope.route` may make an edit of every occurrence a split before the card.
        var arguments = arguments
        guard case .string(let rawEventId) = arguments["event_id"],
              !rawEventId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing event_id — use calendar_event_read or calendar_search to look up the event first"}"#
        }

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to compound event ID
        // R13-U1: a numeric id the translator cannot resolve is REFUSED rather than
        // used as a literal event id (mail-tool parity). Full rationale, including
        // why the non-numeric branch is deliberately kept, is on the same block in
        // `CalendarEventReadTool.execute`.
        let compoundId: String
        let numericId: Int?
        if let n = Int(rawEventId) {
            guard let realId = await ctx.translator.toRealId(n) else {
                BackgroundSyncLogger.logDebug("[CalendarEventEditTool] Failed to resolve numeric id \(n)")
                return #"{"error": "calendar_event_edit failed: no event found for the given event_id. Call calendar_event_read or calendar_search to look up the event again, then retry."}"#
            }
            compoundId = realId
            numericId = n
            BackgroundSyncLogger.logDebug("[CalendarEventEditTool] Resolved numeric id \(n) → \(realId.prefix(50))...")
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
            provider = await CalendarProviderDispatch.resolve(db: ctx.db)?.provider
        }

        // `exdates_add` deletes occurrences, in a call of its own (#694): its own checks come
        // first, and once the event is read it goes its own way (`CalendarEventEditExdates`).
        var exdates: (dates: [String], zone: TimeZone)?
        if CalendarEventEditExdates.isRequested(arguments) {
            switch CalendarEventEditExdates.check(arguments, compoundId: compoundId, deviceZone: deviceZone) {
            case .refused(let output): return output
            case .dates(let dates, let zone): exdates = (dates, zone)
            }
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
        do {
            if let desc = try CalendarToolHelpers.recurrenceSummary(arguments) {
                changes.append("recurrence → \(desc)")
            }
        } catch CalendarProviderError.notSupported(let reason) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason). The event was NOT changed. Correct the arguments and call calendar_event_edit again.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        // A repeat rule this event's calendar can't hold is refused before the card, naming the
        // field, so the assistant can offer one it can (#513).
        if let reason = try? CalendarToolHelpers.recurrenceProviderRefusal(arguments, provider: provider) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason). The event was NOT changed.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        // A `timezone` TabMail does not recognize is refused before the card, rather than read as
        // the device's zone (which would move the event to the wrong time). The queue refuses it
        // the same way (`resolveWriteTimeZone`) for an edit that reaches it.
        let tz: TimeZone
        do {
            tz = try CalendarToolHelpers.resolveWriteTimeZone(arguments, deviceZone: deviceZone, consequence: "it did not change the event")
            // A start or end that names no instant can't be written at a time the card shows:
            // refused here, with nothing written, rather than sent and refused after the card
            // (#719: an Outlook series write is converted to the series' zone, which needs the
            // instant).
            if let reason = CalendarToolHelpers.unreadableWallTime(arguments, in: tz) {
                return ToolJSON.string(from: [
                    "ok": false,
                    "error": "calendar_event_edit failed: \(reason) The event was NOT changed. Correct the time and call calendar_event_edit again.",
                    "event_id": compoundId,
                ] as [String: Any])
            }
        } catch CalendarProviderError.notSupported(let reason) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason) The event was NOT changed. Name the zone by its IANA name (e.g. 'America/Los_Angeles') and call calendar_event_edit again.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        // The edit names the zone its times are in from here on (`stampingZone`): every check below
        // that reads the arguments, the card, and the queued edit, which the drain reads in it.
        arguments = CalendarToolHelpers.stampingZone(arguments, tz)
        // `recurrence_id` is copied from read output, which prints it in the device's zone: it is
        // read there, whatever `timezone` names for the new times (#794, as the Thunderbird add-on).
        // Queued with the edit, so the drain reads it in the same zone.
        let ridZone = deviceZone
        arguments = CalendarToolHelpers.stampingRecurrenceIdZone(arguments, ridZone)
        // Resolve the recurring-edit scope up front — it drives both the
        // confirmation-card date math (which occurrence to show) and the
        // scope clause appended to `changes`. Resolved here, before the API
        // fetch, so a missing recurrence_id fails fast.
        // (calendar_event_edit-v1.5.21+.)
        let scopeRaw = CalendarToolHelpers.stringArgOpt(arguments, "edit_scope")?.lowercased()
        var recurrenceIdArg = CalendarToolHelpers.stringArgOpt(arguments, "recurrence_id")
        var resolvedScope: String = scopeRaw
            ?? (recurrenceIdArg != nil ? "this_only" : "all")
        if resolvedScope == "this_only" || resolvedScope == "this_and_following" {
            guard recurrenceIdArg != nil else {
                throw ToolDeclinedError(output: ToolJSON.string(from: [
                    "error": "edit_scope='\(resolvedScope)' requires recurrence_id (the start_iso of the target occurrence). Use calendar_event_read or calendar_read to find it, then retry.",
                ] as [String: Any]))
            }
        }

        // Fetch current event details from API for confirmation card: the event, and when it names
        // an occurrence of a series, its series and that occurrence (`CalendarSeriesScope.read`), as
        // the queue reads them again before the write. calendarId unknown — the default calendar.
        var fetchedEvent: GCalEvent?
        var fetchedCalendarId: String?
        if let provider {
            let lookupCalId: String
            if let calendarId {
                lookupCalId = calendarId
            } else {
                lookupCalId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
            }
            fetchedCalendarId = lookupCalId
            fetchedEvent = try? await provider.getEvent(calendarId: lookupCalId, eventId: eventId)
            if let event = fetchedEvent {
                // Cache it so future edit/delete use the calendar it was found on
                let accId = resolvedAccountId
                let translator = ctx.translator
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: accId, calendarId: lookupCalId,
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
        guard let provider, let lookupCalId = fetchedCalendarId, let fetchedEvent else {
            BackgroundSyncLogger.logDebug("[CalendarEventEditTool] Could not dereference event_id='\(eventId.prefix(50))' (compound='\(compoundId.prefix(50))') — refusing edit")
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: could not find event with id '\(compoundId)'. The id may be wrong or the event may have been deleted. Call calendar_event_read or calendar_search to look up the correct event, then retry.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        if let exdates {
            return try await CalendarEventEditExdates.execute(
                dates: exdates.dates, zone: exdates.zone,
                target: .init(
                    event: fetchedEvent, eventId: eventId, compoundId: compoundId,
                    accountId: resolvedAccountId, lookupCalendarId: lookupCalId,
                    calendarId: calendarId, calendarName: calendarName),
                provider: provider, translator: ctx.translator, invocation: invocation)
        }

        // The occurrence the edit names, found by the provider's own lookup (the one its write
        // makes), and refused here, before the card, when none starts there, it was deleted, the
        // event id and recurrence_id name different ones, or the provider's write would refuse it.
        let named: CalendarSeriesScope.Named
        do {
            named = try await CalendarSeriesScope.read(
                event: fetchedEvent, eventId: eventId, recurrenceId: recurrenceIdArg, scope: resolvedScope,
                calendarId: lookupCalId, zone: ridZone, provider: provider)
        } catch let refused as CalendarProviderError {
            // A provider's refusal, worded for an edit (`reason`): `notSupported`'s own, and the
            // edit's words for a neutral case (a series not in this calendar, #729).
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(refused.reason). The event was NOT changed.",
                "event_id": compoundId,
            ] as [String: Any])
        } catch where AccountManager.isCalendarNotFoundError(error) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(CalendarSeriesScope.namesNoOccurrence(recurrenceIdArg)). The event was NOT changed.",
                "event_id": compoundId,
            ] as [String: Any])
        } catch {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: could not read the occurrence this edit names (\(error.localizedDescription)). The event was NOT changed. Check event_id and recurrence_id with calendar_event_read, then retry.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        // An edit of a series goes where Google Calendar takes it, before the card
        // (`CalendarSeriesScope.route`), so the card, the queued edit and the result all say where:
        // named at the first occurrence it is the whole series; a new date named from a later
        // occurrence is a change of it and the following ones; a new time of day named from one is
        // the whole series' new time, its start and end moved to the first occurrence's date. When
        // the assistant must ask the user which occurrences, it is refused here. A move to another
        // date of a series whose rule names its days turns those days with it
        // (`CalendarSeriesScope.dayMove`, which the queue applies again before the write).
        let queuedEventId: String
        // A move to another day that turns the rule's days, of the whole series or a split's new
        // part, which resets every occurrence changed or deleted one by one there
        // (`CalendarToolHelpers.exceptionsResetNote`).
        var turnsDays = false
        // A split named at an occurrence moved past the series' last place (`SplitCarry.Cut.pastEnd`).
        var pastEnd = false
        do {
            let given = arguments
            let routed = try CalendarSeriesScope.route(arguments, scope: resolvedScope, named: named, zone: tz, recurrenceIdZone: ridZone)
            arguments = routed.args
            resolvedScope = routed.scope
            recurrenceIdArg = routed.recurrenceId
            queuedEventId = routed.eventId
            // The card lists the start and end the edit now writes.
            for (key, label) in [("start_iso", "start"), ("end_iso", "end")] {
                if let old = CalendarToolHelpers.stringArgOpt(given, key),
                   let new = CalendarToolHelpers.stringArgOpt(arguments, key), new != old,
                   let line = changes.firstIndex(of: "\(label) → \(old)") {
                    changes[line] = "\(label) → \(new)"
                }
            }
            // A split named at a moved occurrence cuts where the calendar's write cuts
            // (`splitCut`). Past the series' last place it makes no new part: only the occurrences
            // shown are edited, nothing is reset, and a change of the repeat is refused here, in the
            // write's words, before the user confirms.
            if resolvedScope == "this_and_following", let rid = recurrenceIdArg,
               let occurrence = named.occurrence, RecurrenceOccurrenceResolver.wasMoved(occurrence),
               case .pastEnd = try await provider.splitCut(calendarId: lookupCalId, eventId: queuedEventId, recurrenceId: rid, zone: ridZone) {
                pastEnd = true
                let changesRule = try CalendarToolHelpers.buildGCalEventInput(arguments, isAllDay: occurrence.isAllDay).recurrence != nil
                if try changesRule || (CalendarSeriesScope.dayMove(arguments, named: named, scope: resolvedScope, zone: tz)) != nil {
                    throw CalendarProviderError.notSupported(SplitCarry.pastEndRuleRefusal)
                }
            }
            // A move to another day of a series whose rule names its days turns them with it; the
            // card says how the repeat changes.
            // The rules shown are every one the calendar writes (`dayMovedRules`): the whole
            // series' or the new part's, its end as the split carries it. One it can't tell is
            // refused here, with nothing queued.
            if let move = try CalendarSeriesScope.dayMove(arguments, named: named, scope: resolvedScope, zone: tz) {
                let series = try named.readSeries()
                // A split's rule starts at its cut, which the calendar works out as its write does
                // (`dayMovedRules`, from the occurrence named at `recurrenceIdArg`).
                let rules = try await provider.dayMovedRules(
                    calendarId: lookupCalId, eventId: queuedEventId, series: series,
                    scope: resolvedScope, recurrenceId: recurrenceIdArg, zone: ridZone, move: move)
                // A move that leaves the rule as it is (one named by position) changes nothing the
                // card should name, and resets no exception. One that turns it resets them on every
                // calendar, for the whole series or the split's new part.
                let stored = (series.recurrence ?? []).filter { $0.uppercased().hasPrefix("RRULE:") }
                if try stored.contains(where: {
                    GoogleCalendarProvider.canonicalRRULE(try RecurrenceDayShift.shifted($0, by: move)) != GoogleCalendarProvider.canonicalRRULE($0)
                }) {
                    turnsDays = true
                    for rule in rules {
                        changes.append("repeat → \(rule.dropFirst("RRULE:".count))")
                    }
                }
            }
        } catch CalendarProviderError.notSupported(let reason) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason). The event was NOT changed.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        if let rid = recurrenceIdArg {
            if resolvedScope == "this_only" {
                changes.append("scope → just this occurrence (\(rid))")
            } else if resolvedScope == "this_and_following" {
                changes.append("scope → this and all future occurrences (starting \(rid))")
            }
        }
        // The event the card shows and the checks below read: the series on an edit of every
        // occurrence, which is what the queue writes; otherwise the event named.
        let shown = resolvedScope == "all" ? try named.readSeries() : fetchedEvent

        // An all-day event given a time of day without `all_day`, an all-day end on or before
        // its start, or a stated `all_day` of the other kind (the event's, or the named
        // occurrence's when it was changed on its own) without both a start and an end, is refused
        // here, before the card, now that the stored kind is known: the
        // assistant asks the user instead of the user confirming an edit that is then refused.
        // The queue applies the same rule again before the write.
        //
        // On `this_only` an end given alone is checked against the start the occurrence has now,
        // which is not `recurrence_id`'s date when the occurrence was moved on its own. It is read
        // from the provider; when that read fails the edit is not offered, since the card would
        // show an end that may be refused.
        //
        // An edit of one occurrence is read with that occurrence's kind, as the queue reads it: one
        // changed on its own can be of the other kind than its series.
        let kindSource = resolvedScope == "this_only" ? named.occurrence ?? shown : shown
        var occurrenceStartDay: String?
        if let rid = recurrenceIdArg,
           CalendarToolHelpers.needsOccurrenceStartDay(arguments, storedStart: kindSource.start, scope: resolvedScope) {
            do {
                occurrenceStartDay = try await provider.occurrenceStartDay(
                    calendarId: lookupCalId, eventId: eventId, recurrenceId: rid,
                    recurrenceIdZone: ridZone)
            } catch {
                return ToolJSON.string(from: [
                    "ok": false,
                    "error": "calendar_event_edit failed: could not read the occurrence at \(rid) to check the new end (\(error.localizedDescription)). The event was NOT changed. Check recurrence_id with calendar_event_read, then retry.",
                    "event_id": compoundId,
                ] as [String: Any])
            }
        }
        if let reason = CalendarToolHelpers.allDayEditRefusal(
            arguments, storedStart: kindSource.start, scope: resolvedScope, recurrenceId: recurrenceIdArg,
            occurrenceStartDay: occurrenceStartDay, namedOccurrenceStart: named.occurrence?.start) {
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit failed: \(reason). The event was NOT changed.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        // Resolve proposed dates — prefer arguments (new values), fall back to current event state.
        // For a single-occurrence / split edit (scope is this_only / this_and_following), the
        // card must show the TARGET OCCURRENCE — not the series master — otherwise it
        // misleadingly displays the wrong date (e.g. the master on the 14th when the user is
        // editing the occurrence on the 21st). Keyed off `resolvedScope`, NOT raw recurrence_id
        // presence, so an `all`-scope edit shows the series it writes.
        //
        // A whole-series edit may reset the occurrences the user changed one by one (#423): on
        // Outlook any change of the series' rule, start or end does. Say so on the card. The
        // series' calendar decides, as its write does, from the series the edit writes
        // (`shown`, the series read above) and the edit as routed, which is what the queue writes; a
        // rename, or a rule equal to the stored one, which the assistant re-sends with other edits,
        // gets no line.
        //
        // A change between all-day and timed of every occurrence, or of a split's new part, changes
        // the series as a whole, and every occurrence changed or deleted on its own there is reset,
        // as the Thunderbird add-on resets it. The series' kind is the one the edit's `all_day` is
        // compared with, and the series' calendar answers whether its write resets anything
        // (`editResetsChangedOccurrences`), from what it holds: no line for a single event.
        //
        // A split resets the occurrences after it that were changed or deleted one by one when
        // its new part's start moves or its rule changes, and carries them otherwise: the one
        // predicate every calendar's write calls (`SplitCarry.mode`), fed the edit as the queue
        // builds it, against where the occurrence named starts now (#563): the write checks the
        // edit moved to its cut (`SplitCarry.partEdit`) against the cut, which is the same check.
        var splitResets = false
        if resolvedScope == "this_and_following", !pastEnd, let occurrence = named.occurrence, let start = occurrence.start,
           var edit = try? CalendarToolHelpers.buildGCalEventInput(
               arguments, isAllDay: CalendarToolHelpers.boolArg(arguments, "all_day") ?? occurrence.isAllDay) {
            edit.ruleDayMove = try? CalendarSeriesScope.dayMove(arguments, named: named, scope: resolvedScope, zone: tz)
            let series = try named.readSeries()
            splitResets = SplitCarry.mode(edit: edit, place: start, storedRules: series.recurrence ?? [], seriesZone: series.isAllDay ? nil : series.seriesZone) == .reset
        }
        if turnsDays || splitResets {
            changes.append(CalendarToolHelpers.exceptionsResetNote)
        } else if resolvedScope != "this_only", let stated = CalendarToolHelpers.boolArg(arguments, "all_day"),
                  let series = named.series, stated != series.isAllDay,
                  let edit = try? CalendarToolHelpers.buildGCalEventInput(arguments, isAllDay: stated),
                  provider.editResetsChangedOccurrences(series, edit: edit) {
            changes.append(CalendarToolHelpers.exceptionsResetNote)
        } else if resolvedScope == "all", shown.recurrence?.isEmpty == false,
           let edit = try? CalendarToolHelpers.buildGCalEventInput(
               arguments, isAllDay: CalendarToolHelpers.boolArg(arguments, "all_day") ?? shown.isAllDay),
           provider.editResetsChangedOccurrences(shown, edit: edit) {
            changes.append(CalendarToolHelpers.ruleChangeResetNote)
        }
        let showsOccurrence = resolvedScope != "all"
        let masterDuration: TimeInterval? = {
            guard let s = shown.startDate, let e = shown.endDate else { return nil }
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
        // current = the specific occurrence (recurrence_id, the start it has
        // now, + master duration) rather than the master: one time per occurrence.
        let cardStart: Date?
        if showsOccurrence, let rid = recurrenceIdArg,
           let occ = EKEventStoreHelper.parseNaiveISO(rid, timeZone: ridZone) {
            cardStart = occ
        } else {
            cardStart = shown.startDate
        }
        let cardEnd: Date?
        if showsOccurrence, let start = cardStart, let dur = masterDuration {
            cardEnd = start.addingTimeInterval(dur)
        } else {
            cardEnd = shown.endDate
        }

        // Resolve event title: prefer argument, then current event state, then fallback
        let proposedTitle = CalendarToolHelpers.stringArgOpt(arguments, "title")
            ?? shown.summary
            ?? "(Event)"

        // The guest change, as the people added and removed (`AttendeeChange.cardLines`), never a
        // resulting list: the write applies the change to each item the edit covers, whose guests
        // can differ (#620), as the Thunderbird add-on's card shows it.
        if let change = AttendeeChange(arguments: arguments) {
            changes.append(contentsOf: change.cardLines)
        }

        // ADR-IOS-024: Show confirmation card. Title/start/end/all-day
        // intentionally reflect the event's CURRENT state — the changes
        // list below enumerates every patched field. `proposedTitle` is
        // used downstream (queue, LLM result string) since it represents
        // the FINAL title; the card itself shows the old title at top.
        let currentTitle: String = (shown.summary?.isEmpty == false ? shown.summary ?? "(Event)" : "(Event)")
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventEdit,
            calendarEvents: [.init(
                eventId: eventId,
                calendarId: calendarName ?? "",
                title: currentTitle,
                startDate: cardStart ?? Date(),
                endDate: cardEnd ?? Date(),
                isAllDay: shown.isAllDay,
                changes: changes,
                attendees: [],
                timeZoneId: tz.identifier,
                notes: CalendarToolHelpers.stringArgOpt(arguments, "description")
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            BackgroundSyncLogger.logDebug("[CalendarEventEditTool] User declined edit for event_id=\(eventId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to edit this event.",
            ] as [String: Any]))
        }

        guard !resolvedAccountId.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }
        // Queued with the id `route` gives: the series' for a new time of every occurrence named from
        // one of them, which the queue reads as a move of the series on its own date.
        return try await queueCalendarEdit(accountId: resolvedAccountId, calendarId: calendarId, calendarName: calendarName, eventId: eventId, queuedEventId: queuedEventId, compoundId: compoundId, arguments: arguments, resolvedScope: resolvedScope, recurrenceId: recurrenceIdArg, zone: tz, cardState: cardState, eventTitle: proposedTitle, cardTitle: currentTitle, translator: ctx.translator)
    }

    // MARK: - Calendar (Queued)

    private func queueCalendarEdit(accountId: String, calendarId: String?, calendarName: String?, eventId: String, queuedEventId: String, compoundId: String, arguments: [String: JSONValue], resolvedScope: String, recurrenceId: String?, zone resolvedTz: TimeZone, cardState: AgentToolRouter.ActionConfirmation.ResponseState, eventTitle: String, cardTitle: String, translator: any ChatIdTranslating) async throws -> String {
        let manager = AccountManager.shared
        let op = try await manager.queueCalendarOperation(
            type: .edit,
            accountId: accountId,
            eventId: queuedEventId,
            calendarId: calendarId,
            arguments: arguments,
            eventTitle: cardTitle
        )

        // Prefer the LLM's new title when changing it; otherwise the
        // proposedTitle from execute() (fetched event or fallback). Used both
        // for the result string and the new-series pill caching after a split.
        let title = CalendarToolHelpers.stringArgOpt(arguments, "title") ?? eventTitle
        let touchesDateTime = CalendarToolHelpers.stringArgOpt(arguments, "start_iso") != nil
            || CalendarToolHelpers.stringArgOpt(arguments, "end_iso") != nil
        BackgroundSyncLogger.logDebug("[CalendarEventEditTool] Queued edit (op: \(op.id), event: \(eventId)) scope=\(resolvedScope)")

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
            BackgroundSyncLogger.logDebug("[CalendarEventEditTool] Permanent failure for op \(op.id): \(reason)")
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
