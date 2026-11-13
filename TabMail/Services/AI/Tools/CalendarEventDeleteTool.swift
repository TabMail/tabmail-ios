/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_event_delete` tool matching TB addon's `calendar_event_delete.js`.
/// Deletes a calendar event with user confirmation (ADR-IOS-024).
/// Queued for crash-safe async execution via PendingCalendarOperation.
struct CalendarEventDeleteTool: AgentTool, Sendable {
    let name = "calendar_event_delete"
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
        // The device's zone, read once: a `recurrence_id` is read in it, where the read tools print
        // an occurrence's start, whatever `timezone` names (#794), and the card shows its times in it.
        let deviceZone = ctx.deviceZone
        guard case .string(let rawEventId) = arguments["event_id"],
              !rawEventId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing event_id — use calendar_event_read or calendar_search to look up the event first"}"#
        }

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to compound event ID
        // R13-U1: a numeric id the translator cannot resolve is REFUSED rather than
        // used as a literal event id (mail-tool parity). Full rationale, including
        // why the non-numeric branch is deliberately kept, is on the same block in
        // `CalendarEventReadTool.execute`. This tool reaches irreversible wire op #5
        // (`CalDAVProvider.deleteEvent` — RFC 4918/4791 define no trash), so the
        // refusal matters most here; it happens before `queueCalendarOperation`, so
        // nothing durable and nothing acknowledged is discarded.
        let compoundId: String
        let numericId: Int?
        if let n = Int(rawEventId) {
            guard let realId = await ctx.translator.toRealId(n) else {
                BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Failed to resolve numeric id \(n)")
                return #"{"error": "calendar_event_delete failed: no event found for the given event_id. Call calendar_event_read or calendar_search to look up the event again, then retry."}"#
            }
            compoundId = realId
            numericId = n
            BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Resolved numeric id \(n) → \(realId.prefix(50))...")
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
        let resolvedAccountId = calInfo?.accountId ?? accountId
        let calendarId = calInfo?.calendarId
        let calendarName = calInfo?.calendarName

        // Fetch current event details from API for confirmation card
        var fetchedEvent: GCalEvent?

        let provider: (any CalendarProvider)?
        if !resolvedAccountId.isEmpty {
            provider = await AccountManager.shared.calendarProviders[resolvedAccountId]
        } else {
            provider = await CalendarProviderDispatch.resolve(db: ctx.db)?.provider
        }

        var lookupCalendarId: String?
        if let provider, let calId = calendarId {
            lookupCalendarId = calId
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
            let defaultCalId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
            lookupCalendarId = defaultCalId
            fetchedEvent = try? await provider.getEvent(calendarId: defaultCalId, eventId: eventId)
            if let event = fetchedEvent {
                // Update cache with discovered calendarId for this session
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: defaultCalId,
                        calendarName: nil, translator: ctx.translator
                    )
                }
            }
        }

        // 🚨 A DELETE IS NOT CONFIRMABLE ON AN UNESTABLISHED IDENTITY (R12-T2).
        // This mirrors `CalendarEventEditTool`'s existing refusal, verbatim in
        // shape, because the two tools were disagreeing and the DESTRUCTIVE one was
        // the permissive one. Without this guard the confirmation card rendered the
        // placeholder title "(Event)" with `Date()` for both ends — the user
        // confirmed THAT — and `queueCalendarDelete` then persisted an
        // irreversible delete against an href whose current occupant had never been
        // read. On CalDAV that reaches `CalDAVProvider.deleteEvent`, a WebDAV
        // `DELETE` for which RFC 4918/4791 define no trash, undelete or restore, so
        // being wrong there cannot be undone (C3).
        //
        // ⚠️ THIS IS NOT A DROPPED INTENTION, and the distinction is the whole
        // argument: the refusal happens BEFORE `queueCalendarOperation`, so no
        // `PendingCalendarOperation` row and no user-visible acknowledgement exists
        // yet. Never-drop governs intentions that were persisted or acknowledged;
        // this one is neither. The agent is handed a structured error naming the
        // re-lookup tools and can retry with a real id.
        //
        // ⚠️ THE COUNTERFACTUAL. Keeping the permissive path would buy exactly one
        // thing — deleting an event whose id we hold but cannot read (a transient
        // provider outage during the confirmation). That is recoverable by one
        // ordinary gesture (ask again once the provider answers). Its opposite,
        // deleting the wrong or an already-replaced event, is not recoverable at
        // all. Fail closed.
        guard let resolvedEvent = fetchedEvent, let provider, let lookupCalendarId else {
            BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Could not dereference event_id='\(eventId.prefix(50))' (compound='\(compoundId.prefix(50))') — refusing delete")
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_delete failed: could not find event with id '\(compoundId)'. The id may be wrong or the event may have been deleted. Call calendar_event_read or calendar_search to look up the correct event, then retry.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        // A repeating event is deleted by the scope the assistant names (`delete_scope`), worked
        // out here, before the card, so the card, the queued delete and the result say the same.
        let target: Target
        switch await Self.target(
            arguments, event: resolvedEvent, eventId: eventId, calendarId: lookupCalendarId,
            deviceZone: deviceZone, provider: provider) {
        case .success(let found): target = found
        case .failure(let refusal):
            BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Refused before the card for event_id=\(eventId.prefix(50)): \(refusal.reason)")
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_delete failed: \(refusal.reason) The event was NOT deleted.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        let shownEvent = target.cardEvent
        let confirmTitle = [shownEvent.summary, resolvedEvent.summary].compactMap { $0 }.first { !$0.isEmpty } ?? "(No title)"
        let confirmStart = shownEvent.startDate ?? Date()
        let confirmEnd = shownEvent.endDate ?? Date()
        let confirmIsAllDay = shownEvent.isAllDay
        let confirmNotes = shownEvent.description ?? resolvedEvent.description
        // The card says which occurrences go, as Google Calendar does (#639): the whole series with
        // its rule, one occurrence and the rest staying, or one and every later one (#695).
        let seriesLines = target.lines

        // ADR-IOS-024: Show confirmation card and await user response
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventDelete,
            calendarEvents: [.init(
                eventId: target.eventId,
                calendarId: calendarName ?? "",
                title: confirmTitle,
                startDate: confirmStart,
                endDate: confirmEnd,
                isAllDay: confirmIsAllDay,
                changes: seriesLines,
                notes: confirmNotes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] User declined delete for event_id=\(eventId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete this event.",
            ] as [String: Any]))
        }

        guard !resolvedAccountId.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }
        return try await queueCalendarDelete(accountId: resolvedAccountId, calendarId: calendarId, target: target, compoundId: compoundId, arguments: target.queuedArguments(arguments, deviceZone: deviceZone), eventTitle: confirmTitle, cardState: cardState)
    }

    // MARK: - Scope (#695)

    /// What a delete removes, worked out before the card: the event id the queue deletes, the
    /// event the card shows, its lines, and the scope written (`delete_scope`, nil for an event
    /// that does not repeat). A delete of an occurrence and every later one ends the series
    /// before `cut` (`CalendarProvider.endSeries`) instead of deleting an event.
    struct Target: Sendable {
        let eventId: String
        let cardEvent: GCalEvent
        let lines: [String]
        let scope: String?
        let cut: String?

        /// The arguments queued with the delete: the scope as decided here, and for a cut, where
        /// and in which zone (`deleteCutKey`, `recurrenceIdZoneKey`). An event that does not
        /// repeat drops a scope it was given: it is deleted as it is.
        func queuedArguments(_ arguments: [String: JSONValue], deviceZone: TimeZone) -> [String: JSONValue] {
            var queued = arguments
            queued.removeValue(forKey: CalendarToolHelpers.deleteCutKey)
            if let scope { queued["delete_scope"] = .string(scope) } else { queued.removeValue(forKey: "delete_scope") }
            if let cut {
                queued[CalendarToolHelpers.deleteCutKey] = .string(cut)
                queued = CalendarToolHelpers.stampingRecurrenceIdZone(queued, deviceZone)
            }
            return queued
        }
    }

    struct Refusal: Error {
        let reason: String
    }

    static let scopes = ["this_only", "this_and_following", "all"]

    /// What the assistant is told when a repeating event is to be deleted and no scope was named:
    /// the Thunderbird add-on's `ASK_DELETE_SCOPE`.
    static let askDeleteScope =
        "This event repeats. Ask the user \"Just this one, this and following, or all of them?\" (unless their words already said which), then call calendar_event_delete again with delete_scope 'this_only', 'this_and_following' or 'all', and for 'this_only' or 'this_and_following' with recurrence_id (the occurrence's start_iso as calendar_event_read shows it)."

    /// What is deleted for `arguments`, `event` being what `eventId` names (read from `calendarId`).
    ///
    /// - An event that does not repeat: itself, whatever scope was given.
    /// - A repeating event: the scope must be named (there is no default; the assistant is told to
    ///   ask the user), and a scope of occurrences names its occurrence, by `recurrence_id` (read in
    ///   `deviceZone`) or by the occurrence's own id.
    ///   - "all": the series, from any of its occurrences.
    ///   - "this_only": the occurrence, by the provider's own lookup when a `recurrence_id` names
    ///     it (`CalendarSeriesScope.read`); an occurrence id alone is deleted as it is.
    ///   - "this_and_following": the series ended before the occurrence's place
    ///     (`CalendarSeriesScope.followingDelete`); at the series' first occurrence, the series.
    ///
    /// Refused, before the card and with nothing queued: no scope, an unknown scope, a scope of
    /// occurrences with a series id and no `recurrence_id`, an occurrence that can't be found or is
    /// before the series' first, and a series that can't be read.
    static func target(
        _ arguments: [String: JSONValue], event: GCalEvent, eventId: String, calendarId: String,
        deviceZone: TimeZone, provider: any CalendarProvider
    ) async -> Result<Target, Refusal> {
        let seriesOf = event.recurringEventId.flatMap { $0.isEmpty || $0 == eventId ? nil : $0 }
        guard seriesOf != nil || !(event.recurrence ?? []).isEmpty else {
            return .success(Target(eventId: eventId, cardEvent: event, lines: [], scope: nil, cut: nil))
        }
        guard let scope = CalendarToolHelpers.stringArgOpt(arguments, "delete_scope")?.lowercased(), !scope.isEmpty else {
            return .failure(Refusal(reason: askDeleteScope))
        }
        guard scopes.contains(scope) else {
            return .failure(Refusal(reason: "delete_scope '\(scope)' is not one of 'this_only', 'this_and_following' or 'all'. \(askDeleteScope)"))
        }
        let recurrenceId = CalendarToolHelpers.stringArgOpt(arguments, "recurrence_id").flatMap { $0.isEmpty ? nil : $0 }
        if scope != "all", seriesOf == nil, recurrenceId == nil {
            return .failure(Refusal(reason: "delete_scope '\(scope)' needs recurrence_id: the occurrence's start_iso as calendar_event_read or calendar_read shows it, with the series' event_id, or the event_id listed for that occurrence."))
        }
        do {
            switch scope {
            case "all":
                // From an occurrence, its series, read for the card.
                guard let seriesOf else { return .success(wholeSeries(event, id: eventId)) }
                return .success(wholeSeries(try await provider.getEvent(calendarId: calendarId, eventId: seriesOf), id: seriesOf))
            case "this_only":
                // An occurrence id alone names the occurrence it was read as.
                guard let recurrenceId else {
                    return .success(Target(eventId: eventId, cardEvent: event, lines: [CalendarToolHelpers.occurrenceDeleteNote], scope: scope, cut: nil))
                }
                let named = try await CalendarSeriesScope.read(
                    event: event, eventId: eventId, recurrenceId: recurrenceId, scope: scope,
                    calendarId: calendarId, zone: deviceZone, provider: provider)
                guard let occurrence = named.occurrence, let occurrenceId = occurrence.id, !occurrenceId.isEmpty else {
                    return .failure(Refusal(reason: CalendarSeriesScope.namesNoOccurrence(recurrenceId) + "."))
                }
                return .success(Target(eventId: occurrenceId, cardEvent: occurrence, lines: [CalendarToolHelpers.occurrenceDeleteNote], scope: scope, cut: nil))
            default:
                let named = try await CalendarSeriesScope.read(
                    event: event, eventId: eventId, recurrenceId: recurrenceId, scope: scope,
                    calendarId: calendarId, zone: deviceZone, provider: provider)
                let series = try named.readSeries()
                let following = try CalendarSeriesScope.followingDelete(named: named, recurrenceId: recurrenceId, recurrenceIdZone: deviceZone)
                // From the first occurrence on is every occurrence: the whole series.
                if following.isFirst { return .success(wholeSeries(series, id: named.seriesId)) }
                return .success(Target(
                    eventId: named.seriesId, cardEvent: named.occurrence ?? event,
                    lines: CalendarToolHelpers.followingDeleteLines(series: series, moved: following.moved),
                    scope: scope, cut: following.cut))
            }
        } catch CalendarProviderError.seriesNotInThisCalendar {
            return .failure(Refusal(reason: seriesNotInThisCalendarReason))
        } catch let refused as CalendarProviderError {
            return .failure(Refusal(reason: refused.reason.hasSuffix(".") ? refused.reason : refused.reason + "."))
        } catch where AccountManager.isCalendarNotFoundError(error) {
            return .failure(Refusal(reason: CalendarSeriesScope.namesNoOccurrence(recurrenceId) + "."))
        } catch {
            return .failure(Refusal(reason: "could not read the repeating event this delete names (\(error.localizedDescription)). Check event_id and recurrence_id with calendar_event_read, then retry."))
        }
    }

    /// The whole series `id`, `series` as read: the card says every occurrence goes, with its rule.
    private static func wholeSeries(_ series: GCalEvent, id: String) -> Target {
        Target(eventId: id, cardEvent: series, lines: CalendarToolHelpers.seriesDeleteLines(series), scope: "all", cut: nil)
    }

    /// What a delete of the whole series, or from one occurrence on, is told when the calendar holds
    /// only changed occurrences of it (`CalendarProviderError.seriesNotInThisCalendar`).
    static let seriesNotInThisCalendarReason =
        "The series of this repeating event is not in this calendar, which holds only changed occurrences of it (an invitation to single occurrences of someone else's series), so it can't be deleted as a whole or from one occurrence on here. One of those occurrences can be deleted on its own: delete_scope 'this_only', with the event_id listed for it."

    // MARK: - Calendar (Queued)

    private func queueCalendarDelete(accountId: String, calendarId: String?, target: Target, compoundId: String, arguments: [String: JSONValue], eventTitle: String, cardState: AgentToolRouter.ActionConfirmation.ResponseState) async throws -> String {
        let eventId = target.eventId
        let manager = AccountManager.shared
        let op = try await manager.queueCalendarOperation(
            type: .delete,
            accountId: accountId,
            eventId: eventId,
            calendarId: calendarId,
            arguments: arguments,
            eventTitle: eventTitle
        )

        // Evict cached details — event is being deleted
        await ctx.translator.evictEventDetail(realId: compoundId)
        BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Queued delete (op: \(op.id), event: \(eventId))")

        // Mirror edit/create: wait briefly for the drain to surface a terminal
        // outcome so a provider-side failure (404, permission denied, etc.)
        // flips the card to its failed state and tells the LLM the truth.
        let outcome = await manager.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 10.0)
        if case .permanentFailure(let reason) = outcome {
            BackgroundSyncLogger.logDebug("[CalendarEventDeleteTool] Permanent failure for op \(op.id): \(reason)")
            await MainActor.run { cardState.failureReason = reason }
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_delete failed: \(reason). The event was NOT deleted.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        let confirmedSync: Bool = if case .success = outcome { true } else { false }
        // What went, by the scope written, in the Thunderbird add-on's words.
        let deleted = switch target.scope {
        case "this_only": "Occurrence deleted successfully; the rest of the series stays."
        case "this_and_following": "This and every later occurrence deleted successfully; earlier ones stay."
        case "all": "Repeating event deleted successfully: every occurrence."
        default: "Calendar event deleted successfully."
        }
        return [
            confirmedSync ? deleted : "Calendar event deletion queued successfully.",
            target.scope.map { "delete_scope: \($0)" },
            "event_id: \(compoundId)",
            confirmedSync ? nil : "The event will be removed from the calendar shortly. Cancellation notices will be sent to attendees.",
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
