/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The CalDAV writes that make a new VEVENT out of an existing one: a `this_and_following` split's
/// new part (`seriesSplitResources`) and a `this_only` occurrence override
/// (`occurrenceOverrideResource`).
///
/// **The new VEVENT is a copy, not a rebuild.** Every property of the VEVENT it is copied from goes
/// across byte for byte: the access class, the organizer, the alarms, the categories, the status, the
/// URL, the attachments, the priority, every `X-` property, and each attendee's role, answer and other
/// parameters. Only what the operation is about changes (identity, anchor, rule), and then the user's
/// patch is applied with `mergePatchIntoICS`, exactly as an edit of the whole series applies it.
///
/// Attendee answers: the copy keeps them, unless the patch reschedules it (a different start, end,
/// rule or location), in which case every attendee other than the organizer is asked again
/// (`PARTSTAT=NEEDS-ACTION;RSVP=TRUE`). Attendees the patch adds are always asked. The Thunderbird
/// add-on applies the same rule to a split's new part only, and leaves a one-occurrence edit's
/// answers as stored. Here the override is asked again too. A scheduling CalDAV server resets the
/// stored answers itself when a change of start, end or rule moves an occurrence (RFC 6638 §3.2.8);
/// a change of location is one the RFC lets the organizer's client reset.
///
/// Every throw here is `CalendarProviderError.notSupported`. Each is a pure function of the stored
/// resource and the arguments, so a retry would throw the same way; an unclassified error would
/// instead be retried forever and hold up the account's other calendar edits. Nothing has been
/// written when one is thrown.
extension CalDAVProvider {

    // MARK: - Series split

    struct SeriesSplitResources: Equatable {
        /// The series' own resource with its rule capped before the split.
        let cappedSeries: String
        /// The new part's resource.
        let newPart: String
        /// Whether the new part carries the changed and deleted occurrences after the split or
        /// resets them (`SplitCarry.mode`).
        let mode: SplitCarry.Mode
    }

    /// Build both resources of a split from the STORED series.
    ///
    /// The new part is the series' resource with:
    /// 1. **Identity.** Every VEVENT gets the new UID; `DTSTAMP` is the time of the split; `SEQUENCE`,
    ///    `CREATED` and `LAST-MODIFIED` describe the old resource's history and are left off.
    /// 2. **Anchor.** `DTSTART` becomes the split occurrence's slot, in the series' own value type and
    ///    zone, and `DTEND` moves with it (a `DURATION` line needs no change).
    /// 3. **Rule.** `newRRule`: the series' rule ending where the series did, with the same `UNTIL` or
    ///    what is left of its `COUNT`.
    /// 4. **What belongs to which part.** Excluded dates (`EXDATE`), extra dates (`RDATE`) and changed
    ///    occurrences (override VEVENTs) before the slot stay with the capped series; those at or after
    ///    it go to the new part as the split's mode says (`SplitCarry.mode`, #563): a split that
    ///    carries them keeps their absolute times; one that resets them (the edit moves the new
    ///    part's start or changes its rule, as Google Calendar resets them) drops the changed
    ///    occurrences and the excluded dates, so they come back plain. Added dates are kept.
    ///    Whatever the mode, an override placed at or after the slot but shown before the
    ///    occurrence named keeps what it shows, whole (`named`).
    /// 5. **The user's patch**, applied last. A time change in the patch is therefore measured from the
    ///    slot. On a carry, the fields it sets also overwrite the own of each carried changed
    ///    occurrence shown from the one named on, and an end it gives makes each of them last as long
    ///    as the new part from its own start (`editOverrides`), as Google Calendar does.
    ///
    /// The capped series changes its `RRULE` (the cap), drops what moved to the new part, and has
    /// the edit written over each override it keeps that is shown from the occurrence named on, so
    /// the two resources together hold exactly the series' occurrences.
    ///
    /// - Parameters:
    ///   - storedICS: the series' resource exactly as the server returned it.
    ///   - slotNaiveISO: the split occurrence's start, already in the series' frame
    ///     (`recurrenceIdInMasterFrame`).
    ///   - cappedRRule: the series' rule capped before the split.
    ///   - newRRule: the new part's rule, ending where the series did (`RecurrenceTail.newSeriesRule`).
    ///   - newUid: the new part's UID (deterministic, so a retry targets the same resource).
    ///   - patch: the user's edit.
    ///   - now: the split's time, written as the new part's `DTSTAMP`.
    ///   - zones: the zone context of `storedICS`.
    ///   - named: where the occurrence named starts now and its place (`RECURRENCE-ID`), as
    ///     instants read as `parseICSDateTime` reads them, when it was moved: the overrides are
    ///     sorted around the split by calendar order (`SplitCarry.partition`'s rule). Those shown
    ///     before it keep what they show, whole, on the new part; those shown after it but placed
    ///     before the slot get the edit where they are, on the capped series; on a reset the one
    ///     named stays on the new part, moved as the edit moves it. Nil: named at the slot.
    static func seriesSplitResources(
        storedICS: String,
        slotNaiveISO: String,
        cappedRRule: String,
        newRRule: String,
        newUid: String,
        patch: GCalEventInput,
        now: Date,
        zones: CalendarTimeZoneContext,
        named: (start: Date, place: Date)? = nil
    ) throws -> SeriesSplitResources {
        let (slotLine, slotInstant) = try splitSlot(storedICS: storedICS, slotNaiveISO: slotNaiveISO, zones: zones)
        let place = masterDTStartKind(from: storedICS) == .allDay
            ? GCalDateTime(dateTime: nil, date: String(slotNaiveISO.prefix(10)), timeZone: nil)
            : GCalDateTime(dateTime: slotInstant.iso8601String(), date: nil, timeZone: "UTC")
        let mode = SplitCarry.mode(edit: patch, place: place, storedRules: extractRRule(from: storedICS).map { [$0] } ?? [], seriesZone: try seriesStartZone(slotLine, zones: zones))
        guard let duration = try extractMasterDuration(from: storedICS, zones: zones) else {
            throw CalendarProviderError.notSupported("The repeating event's length can't be read, so it can't be split.")
        }
        let stamp = utcStamp(now)

        let shownFrom = named?.start ?? slotInstant

        // 1. The new part, re-anchored at the slot: the overrides placed at or after it that a
        //    carry takes (shown from the one named on), those shown before the one named, and on a
        //    reset the one named.
        let anchored = try rewriteVEvents(in: storedICS) { block, isMaster in
            if !isMaster {
                let place = try recurrenceInstant(of: block, zones: zones)
                guard place >= slotInstant else { return nil }
                let shownAfter = try startInstant(of: block, zones: zones) >= shownFrom
                guard mode == .carry || !shownAfter || place == named?.place else { return nil }
            }
            var sawStamp = false
            var out = try rewriteTopLevel(block) { unit, name in
                switch name {
                case "UID":
                    return ["UID:\(newUid)"]
                case "DTSTAMP":
                    sawStamp = true
                    return ["DTSTAMP:\(stamp)"]
                case "SEQUENCE", "CREATED", "LAST-MODIFIED":
                    return []
                case "DTSTART" where isMaster:
                    return [slotLine]
                case "DTEND" where isMaster:
                    guard let end = try formatLike(unit.text, instant: slotInstant.addingTimeInterval(duration), zones: zones) else {
                        throw CalendarProviderError.notSupported("The repeating event's end time zone can't be read, so it can't be split.")
                    }
                    return [end]
                case "RRULE" where isMaster:
                    return [newRRule]
                case "EXDATE" where isMaster && mode == .reset:
                    return []
                case "EXDATE" where isMaster, "RDATE" where isMaster:
                    return try filterDateList(unit.text, zones: zones, keep: { $0 >= slotInstant })
                default:
                    return nil
                }
            }
            if !sawStamp { out = insertBeforeSubcomponents(out, lines: ["DTSTAMP:\(stamp)"]) }
            return out
        }

        // 2. The user's patch, carried onto the overrides it reaches, then 3. attendee answers.
        var patched = try mergePatchKeepingLength(patch, into: anchored, length: duration, zones: zones)
        let edit = try occurrenceEdit(fields: SplitCarry.fields(of: patch), from: patched, slotInstant: slotInstant, shownFrom: shownFrom, zones: zones)
        patched = try editOverrides(patched, edit: mode == .carry ? edit.unmoved : edit, zones: zones) { block in
            mode == .carry
                ? try startInstant(of: block, zones: zones) >= shownFrom
                : try recurrenceInstant(of: block, zones: zones) == named?.place
        }
        let newPart = try applyAttendeeRule(before: anchored, after: patched, zones: zones)

        // 4. The capped series, the overrides shown after the one named edited where they are.
        let capped = try cappedSeriesResource(
            storedICS: storedICS, slotInstant: slotInstant, cappedRRule: cappedRRule, zones: zones, edit: edit)
        return SeriesSplitResources(cappedSeries: capped, newPart: newPart, mode: mode)
    }

    /// The edit a split writes onto an override where it is (`editOverrides`): the fields it set
    /// (`set`, their property names) as `lines` hold them (the new part's series VEVENT, or the
    /// edit itself when no part is written), the new length when it set the end, and how far it
    /// moves an occurrence (`shift`). It reaches the overrides shown from `shownFrom` on.
    struct OccurrenceEdit {
        let shownFrom: Date
        let set: [String]
        let lines: [String]
        let length: TimeInterval?
        let shift: TimeInterval

        /// The same edit, moving nothing (a carry: its start is the place's).
        var unmoved: OccurrenceEdit { OccurrenceEdit(shownFrom: shownFrom, set: set, lines: lines, length: length, shift: 0) }
    }

    /// The property each field an edit sets is written as.
    private static let fieldProperties: [(SplitCarry.Field, String)] = [
        (.summary, "SUMMARY"), (.location, "LOCATION"), (.description, "DESCRIPTION"), (.transparency, "TRANSP"),
    ]

    /// The edit read from a split's new part `part` (its series VEVENT patched), for an edit that
    /// set `fields`: the shift is from the slot to the part's start.
    static func occurrenceEdit(
        fields: Set<SplitCarry.Field>, from part: String, slotInstant: Date, shownFrom: Date, zones: CalendarTimeZoneContext
    ) throws -> OccurrenceEdit {
        let set = fieldProperties.filter { fields.contains($0.0) }.map(\.1)
        let series = masterTopLevelLines(part)
        let lines = series.filter { line in icsProperty(line).map { set.contains($0.name) } ?? false }
        let length = fields.contains(.end) ? try extractMasterDuration(from: part, zones: zones) : nil
        guard let start = series.first(where: { icsProperty($0)?.name == "DTSTART" }),
              let partStart = try parseICSDateTime(start, zones: zones), !fields.contains(.end) || length != nil else {
            throw CalendarProviderError.notSupported("The repeating event's new part can't be read, so it can't be split.")
        }
        return OccurrenceEdit(shownFrom: shownFrom, set: set, lines: lines, length: length, shift: partStart.timeIntervalSince(slotInstant))
    }

    /// `ics` with `edit` written over each override VEVENT `picks` picks: the fields it set, as
    /// `edit.lines` hold them, and its start and end moved by `edit.shift`, or, when it set the
    /// end, an end at its (moved) start plus `edit.length`. Its other properties stay its own.
    static func editOverrides(
        _ ics: String, edit: OccurrenceEdit, zones: CalendarTimeZoneContext, picks: ([ICSUnit]) throws -> Bool
    ) throws -> String {
        guard !edit.set.isEmpty || edit.length != nil || edit.shift != 0 else { return ics }
        let unreadable = CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be split.")
        return try rewriteVEvents(in: ics) { block, isMaster in
            guard !isMaster, try picks(block) else { return block }
            let start = try startInstant(of: block, zones: zones).addingTimeInterval(edit.shift)
            var startLine: String?
            var out = try rewriteTopLevel(block) { unit, name in
                if edit.set.contains(name) { return [] }
                switch name {
                case "DTSTART":
                    guard let moved = try formatLike(unit.text, instant: start, zones: zones) else { throw unreadable }
                    startLine = moved
                    return edit.shift == 0 ? nil : [moved]
                case "DTEND" where edit.length != nil, "DURATION" where edit.length != nil:
                    return []
                case "DTEND" where edit.shift != 0:
                    guard let end = try parseICSDateTime(unit.text, zones: zones),
                          let moved = try formatLike(unit.text, instant: end.addingTimeInterval(edit.shift), zones: zones) else { throw unreadable }
                    return [moved]
                default:
                    return nil
                }
            }
            var added = edit.lines
            if let length = edit.length {
                guard let startLine,
                      let end = try formatLike("DTEND" + startLine.dropFirst("DTSTART".count), instant: start.addingTimeInterval(length), zones: zones)
                else { throw unreadable }
                added.append(end)
            }
            out = insertBeforeSubcomponents(out, lines: added)
            return out
        }
    }

    /// The series' resource of a "this and following" edit at an occurrence moved past its last
    /// place (`CalDAVProvider.editShown`): the stored series with `patch`'s fields, moved by `shift`
    /// and lasting `length` when it gives an end, written over each override shown from
    /// `shownFrom` on. Nothing else changes.
    static func pastEndResource(
        storedICS: String, patch: GCalEventInput, shownFrom: Date, shift: TimeInterval, length: TimeInterval?, zones: CalendarTimeZoneContext
    ) throws -> String {
        guard let duration = try extractMasterDuration(from: storedICS, zones: zones) else {
            throw CalendarProviderError.notSupported("The repeating event's length can't be read, so it can't be changed.")
        }
        let fields = SplitCarry.fields(of: patch)
        let values = SplitCarry.values(of: patch, fields: fields)
        let patched = try mergePatchKeepingLength(values, into: storedICS, length: duration, zones: zones)
        let set = fieldProperties.filter { fields.contains($0.0) }.map(\.1)
        let lines = masterTopLevelLines(patched).filter { line in icsProperty(line).map { set.contains($0.name) } ?? false }
        let edit = OccurrenceEdit(shownFrom: shownFrom, set: set, lines: lines, length: length, shift: shift)
        return try editOverrides(storedICS, edit: edit, zones: zones) { block in
            try startInstant(of: block, zones: zones) >= shownFrom
        }
    }

    /// The instant an override VEVENT starts at now (its `DTSTART`), read as `parseICSDateTime`
    /// reads it.
    private static func startInstant(of block: [ICSUnit], zones: CalendarTimeZoneContext) throws -> Date {
        guard let unit = topLevel(block).first(where: { icsProperty($0.text)?.name == "DTSTART" }),
              let instant = try parseICSDateTime(unit.text, zones: zones) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be split.")
        }
        return instant
    }

    /// The split occurrence's `DTSTART` line in the series' own form (its parameters and value
    /// type) and the instant it names. `slotNaiveISO` is already in the series' frame.
    static func splitSlot(
        storedICS: String, slotNaiveISO: String, zones: CalendarTimeZoneContext
    ) throws -> (line: String, instant: Date) {
        let kind = masterDTStartKind(from: storedICS)
        guard let dtstart = masterTopLevelLines(storedICS).first(where: { icsProperty($0)?.name == "DTSTART" }),
              let dtstartProperty = icsProperty(dtstart) else {
            throw CalendarProviderError.notSupported("The repeating event has no start, so it can't be split.")
        }
        guard let slotValue = icsDateValue(fromNaive: slotNaiveISO, kind: kind) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(slotNaiveISO)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let slotLine = "DTSTART\(dtstartProperty.params):\(slotValue)"
        guard let slotInstant = try parseICSDateTime(slotLine, zones: zones) else {
            throw CalendarProviderError.notSupported("The repeating event's time zone can't be read, so it can't be split.")
        }
        return (slotLine, slotInstant)
    }

    /// The zone the series' start line `line` is kept in: its TZID's zone, UTC for a UTC value,
    /// nil for a floating or all-day one (no zone of its own).
    static func seriesStartZone(_ line: String, zones: CalendarTimeZoneContext) throws -> TimeZone? {
        guard let property = icsProperty(line) else { return nil }
        if let tzid = ICSParser.extractTZID(property.params) { return try zone(forTZID: tzid, zones: zones) }
        return line.uppercased().hasSuffix("Z") ? .gmt : nil
    }

    /// The series' half of a split (`seriesSplitResources`, and `finishSplit` on its own): the
    /// stored series with `cappedRRule` as its rule, and nothing at or after `slotInstant` (its
    /// changed occurrences, excluded and added dates there go to the new part). Each override it
    /// keeps that is shown from the occurrence named on (`edit.shownFrom`) gets `edit` where it is
    /// (`editOverrides`).
    static func cappedSeriesResource(
        storedICS: String, slotInstant: Date, cappedRRule: String, zones: CalendarTimeZoneContext, edit: OccurrenceEdit? = nil
    ) throws -> String {
        let capped = try rewriteVEvents(in: storedICS) { block, isMaster in
            if !isMaster {
                return try recurrenceInstant(of: block, zones: zones) < slotInstant ? block : nil
            }
            return try rewriteTopLevel(block) { unit, name in
                switch name {
                case "RRULE":
                    return [cappedRRule]
                case "EXDATE", "RDATE":
                    return try filterDateList(unit.text, zones: zones, keep: { $0 < slotInstant })
                default:
                    return nil
                }
            }
        }
        guard let edit else { return capped }
        return try editOverrides(capped, edit: edit, zones: zones) { block in
            try startInstant(of: block, zones: zones) >= edit.shownFrom
        }
    }

    // MARK: - One-occurrence override

    /// The day (`yyyy-MM-dd`) an all-day occurrence starts on now: its override's own `DTSTART`
    /// when the occurrence was changed on its own, else its slot (`recurrenceIdNaive`, already in
    /// the series' frame). Nil when the occurrence is timed.
    static func occurrenceStartDay(storedICS: String, recurrenceIdNaive: String) -> String? {
        let kind = recurrenceIdKind(from: storedICS)
        let override = existingOverride(in: icsUnits(storedICS), recurrenceIdNaive: recurrenceIdNaive, kind: kind)
        guard let override else {
            guard case .allDay = kind else { return nil }
            return String(recurrenceIdNaive.prefix(10))
        }
        guard let start = topLevel(override).first(where: { icsProperty($0.text)?.name == "DTSTART" }),
              let parts = icsProperty(start.text) else { return nil }
        let digits = parts.value.trimmingCharacters(in: .whitespaces)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    /// The override VEVENT the resource already holds for the occurrence `recurrenceIdNaive` names
    /// (its `RECURRENCE-ID` matches in the series' frame), or nil when the occurrence has no changes
    /// of its own. `occurrenceStartDay` (the check of an end given alone) and
    /// `occurrenceOverrideResource` (the write, which copies the block found here) both use it, so
    /// the start the check compares with is the start the write keeps.
    private static func existingOverride(in units: [ICSUnit], recurrenceIdNaive: String, kind: MasterDTStartKind) -> [ICSUnit]? {
        veventBlocks(units).first { block in
            guard let rid = topLevel(block).first(where: { icsProperty($0.text)?.name == "RECURRENCE-ID" }),
                  let value = icsProperty(rid.text)?.value else { return false }
            return recurrenceIdsMatch(value, recurrenceIdNaive, allDay: kind == .allDay)
        }
    }

    /// The series' resource after a `this_only` edit of one occurrence.
    ///
    /// The override VEVENT is a copy of the occurrence as it stands: the existing override for that
    /// occurrence when there is one, otherwise the series' VEVENT with `RECURRENCE-ID` naming the
    /// occurrence, its start and end set to the occurrence's own, `DTSTAMP` set to `now`, and its
    /// `RRULE`/`RDATE`/`EXDATE` left off (they belong to the series, not to one occurrence). Then the
    /// patch, without any repeat rule it gives, and the attendee rule are applied as for a split. A full copy matters beyond fidelity:
    /// RFC 5545 lets an override inherit nothing, and iCloud and Apple Calendar show only what the
    /// override itself carries.
    ///
    /// A resource that holds only changed occurrences (an invitation to single occurrences,
    /// RFC 4791 §4.1) has no series VEVENT: an edit of one of its overrides changes that override
    /// in place, and an occurrence it does not hold can't be copied from anything, so it is
    /// refused with nothing written.
    ///
    /// - Parameters:
    ///   - storedICS: the series' resource exactly as the server returned it.
    ///   - recurrenceIdNaive: the occurrence's original start, already in the resource's
    ///     RECURRENCE-ID frame (`recurrenceIdInMasterFrame` with `recurrenceIdKind`).
    ///   - patch: the user's edit.
    ///   - now: the edit's time, written as a new override's `DTSTAMP`.
    ///   - zones: the zone context of `storedICS`. The override is merged on its own, outside the
    ///     resource, and its zones are read through this.
    static func occurrenceOverrideResource(
        storedICS: String,
        recurrenceIdNaive: String,
        patch: GCalEventInput,
        now: Date,
        zones: CalendarTimeZoneContext
    ) throws -> String {
        let kind = recurrenceIdKind(from: storedICS)
        let units = icsUnits(storedICS)
        let masterBlock = veventBlocks(units).first(where: { !isOverride($0) })

        let base: [ICSUnit]
        if let existing = existingOverride(in: units, recurrenceIdNaive: recurrenceIdNaive, kind: kind) {
            base = existing
        } else {
            guard let masterBlock,
                  let dtstart = topLevel(masterBlock).first(where: { icsProperty($0.text)?.name == "DTSTART" }),
                  let dtstartProperty = icsProperty(dtstart.text) else {
                throw CalendarProviderError.notSupported("The repeating event has no start, so one occurrence of it can't be changed.")
            }
            guard let ridValue = icsDateValue(fromNaive: recurrenceIdNaive, kind: kind) else {
                throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceIdNaive)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
            }
            let ridLine = slotLine("RECURRENCE-ID", dtstartParams: dtstartProperty.params, value: ridValue, kind: kind)
            guard let ridInstant = try parseICSDateTime(ridLine, zones: zones) else {
                throw CalendarProviderError.notSupported("The repeating event's time zone can't be read, so one occurrence of it can't be changed.")
            }
            guard let duration = try copyLength(storedICS, zones: zones) else {
                throw CalendarProviderError.notSupported("The repeating event's length can't be read, so one occurrence of it can't be changed.")
            }
            let stamp = utcStamp(now)
            var sawStamp = false
            var copy = try rewriteTopLevel(masterBlock) { unit, name in
                switch name {
                case "DTSTAMP":
                    sawStamp = true
                    return ["DTSTAMP:\(stamp)"]
                case "RRULE", "RDATE", "EXDATE":
                    return []
                case "DTSTART":
                    return ["DTSTART\(dtstartProperty.params):\(ridValue)"]
                case "DTEND":
                    guard let end = try formatLike(unit.text, instant: ridInstant.addingTimeInterval(duration), zones: zones) else {
                        throw CalendarProviderError.notSupported("The repeating event's end time zone can't be read, so one occurrence of it can't be changed.")
                    }
                    return [end]
                default:
                    return nil
                }
            }
            if !sawStamp { copy = insertBeforeSubcomponents(copy, lines: ["DTSTAMP:\(stamp)"]) }
            copy = insertAfterUID(copy, ICSUnit(physical: [ridLine], text: ridLine))
            base = copy
        }

        // The merge helpers address a resource's series VEVENT, the one with no RECURRENCE-ID, so the
        // override is merged on its own, without its RECURRENCE-ID, and gets it back afterwards.
        guard let ridUnit = topLevel(base).first(where: { icsProperty($0.text)?.name == "RECURRENCE-ID" }) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be changed again.")
        }
        let bare = base.filter { icsProperty($0.text)?.name != "RECURRENCE-ID" }
        let wrapped = (["BEGIN:VCALENDAR"] + bare.flatMap(\.physical) + ["END:VCALENDAR"]).joined(separator: "\r\n")
        guard let length = try copyLength(wrapped, zones: zones) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be changed again.")
        }
        // A repeat rule belongs to the series: an occurrence never takes one from the edit.
        var occurrencePatch = patch
        occurrencePatch.recurrence = nil
        let patched = try mergePatchKeepingLength(occurrencePatch, into: wrapped, length: length, zones: zones)
        let answered = try applyAttendeeRule(before: wrapped, after: patched, zones: zones)
        guard var block = veventBlocks(icsUnits(answered)).first else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be changed again.")
        }
        block = insertAfterUID(block, ridUnit)
        let spliced = spliceOrReplaceOverride(
            ics: storedICS, recurrenceId: recurrenceIdNaive, kind: kind,
            newOverrideBlock: block.flatMap(\.physical).joined(separator: "\r\n"))
        // An all-day occurrence made timed is written in a zone (`kindToWrite`) whose VTIMEZONE the
        // merge added to the override's own calendar; the resource needs it too (RFC 5545 §3.2.19).
        if masterDTStartKind(from: wrapped) != masterDTStartKind(from: answered),
           case .zoned(let tzid) = masterDTStartKind(from: answered) {
            return try addingVTimeZone(named: tzid, to: spliced)
        }
        return spliced
    }

    /// A line naming one occurrence's place in the series (`RECURRENCE-ID`, `EXDATE`): RFC 5545
    /// §3.8.4.4 gives it the series DTSTART's value type and zone, so it carries DTSTART's
    /// parameters, and a date value says so even where the series' own DTSTART leaves it implicit.
    private static func slotLine(_ name: String, dtstartParams: String, value: String, kind: MasterDTStartKind) -> String {
        var params = dtstartParams
        if case .allDay = kind, !ICSValueType.statesDate(params) { params += ";VALUE=DATE" }
        return "\(name)\(params):\(value)"
    }

    // MARK: - One occurrence's delete

    /// The series' resource after one occurrence is deleted, as Google Calendar deletes one: an
    /// `EXDATE` added to the series VEVENT at the occurrence's place in the series, in the series
    /// DTSTART's value type and zone (a DATE for an all-day series), and the occurrence's changed
    /// copy, if it has one, removed. A moved occurrence is excluded at its place in the series,
    /// the slot its RECURRENCE-ID names, not where it was moved to. Which VEVENT is the series
    /// and which are the changed copies comes from the delete's one parse of `storedICS`
    /// (`CalDAVOccurrences.OccurrenceDeletion`), by position: `rewriteVEvents` takes the VEVENTs
    /// in the order and framing `ICSParser.components` reads them (`isMarker`, `takeVEvent`),
    /// so a changed copy is matched by its occurrence key as the listing reads it, never by
    /// RECURRENCE-ID text read again here. Every other line goes back byte for byte.
    ///
    /// - Parameters:
    ///   - storedICS: the series' resource exactly as the server returned it.
    ///   - deletion: what the delete's check read from `storedICS`.
    ///   - slotNaive: the occurrence's place in the series, already in the series' frame
    ///     (`recurrenceIdInMasterFrame`).
    static func occurrenceDeletedResource(
        storedICS: String, deletion: CalDAVOccurrences.OccurrenceDeletion, slotNaive: String
    ) throws -> String {
        let kind = masterDTStartKind(from: storedICS)
        guard let value = icsDateValue(fromNaive: slotNaive, kind: kind) else {
            throw CalendarProviderError.notSupported("The occurrence's place in the repeating event can't be written, so it can't be deleted. Nothing was deleted. The user can delete it in their calendar app.")
        }
        var position = -1
        return try rewriteVEvents(in: storedICS) { block, _ in
            position += 1
            if position == deletion.seriesPosition {
                guard let dtstart = topLevel(block).first(where: { icsProperty($0.text)?.name == "DTSTART" }),
                      let dtstartProperty = icsProperty(dtstart.text) else {
                    throw CalendarProviderError.notSupported("The repeating event has no start, so one occurrence of it can't be deleted. Nothing was deleted. The user can delete it in their calendar app.")
                }
                return insertBeforeSubcomponents(block, lines: [
                    slotLine("EXDATE", dtstartParams: dtstartProperty.params, value: value, kind: kind),
                ])
            }
            return deletion.changedCopyPositions.contains(position) ? nil : block
        }
    }

    // MARK: - Patch and attendee answers

    /// Apply the user's patch to a copy (`mergePatchIntoICS` on the resource's series VEVENT). A
    /// zoned copy stays in its own zone, so the patch's zones are dropped (`Date.fromISO8601` has
    /// already resolved its times). A floating copy keeps them: its wall clock is the patch's time
    /// in the zone the patch names (`formatDTLine`, #753), and a derived end is named in the
    /// start's zone. An all-day copy has no zone of its own and keeps them too: times given for it
    /// make it timed (`kindToWrite`), in the zone the edit names. A new start with no end keeps
    /// the copy's `length`; an end replaces a `DURATION`, since RFC 5545 forbids both in one VEVENT.
    private static func mergePatchKeepingLength(
        _ patch: GCalEventInput, into ics: String, length: TimeInterval, zones: CalendarTimeZoneContext
    ) throws -> String {
        var effective = patch
        let kind = masterDTStartKind(from: ics)
        if kind != .floating, kind != .allDay {
            effective.startTimeZone = nil
            effective.endTimeZone = nil
        }
        var base = ics
        let hasDuration = masterTopLevelLines(ics).contains { icsProperty($0)?.name == "DURATION" }
        if case .allDay = kind {
            if effective.endDate != nil {
                if hasDuration { base = removeFromMasterVEvent(in: base, propertyKey: "DURATION") }
            } else if let start = effective.startDate, !hasDuration {
                effective.endDate = shiftedDate(start, days: max(1, Int((length / 86400).rounded())))
            }
        } else {
            if effective.endDateTime != nil {
                if hasDuration { base = removeFromMasterVEvent(in: base, propertyKey: "DURATION") }
            } else if let start = effective.startDateTime, let startDate = Date.fromISO8601(start), !hasDuration {
                effective.endDateTime = startDate.addingTimeInterval(length).iso8601String(timeZone: TimeZone(identifier: "UTC") ?? .current)
                effective.endTimeZone = effective.startTimeZone
            }
        }
        return try mergePatchIntoICS(base, patch: effective, zones: zones)
    }

    /// `after` with the attendee rule applied to its series VEVENT: an attendee who was in `before`
    /// keeps their answer unless the patch rescheduled the event; anyone else other than the organizer
    /// is asked (`PARTSTAT=NEEDS-ACTION;RSVP=TRUE`).
    private static func applyAttendeeRule(before: String, after: String, zones: CalendarTimeZoneContext) throws -> String {
        let prior = masterTopLevelLines(before)
        let organizer = prior.first(where: { icsProperty($0)?.name == "ORGANIZER" })
            .flatMap { icsProperty($0) }.flatMap { mailtoAddress($0.value) }
        let priorAttendees = Set(prior.compactMap { line -> String? in
            guard let p = icsProperty(line), p.name == "ATTENDEE" else { return nil }
            return mailtoAddress(p.value)
        })
        let rescheduled = try reschedules(before: before, after: after, zones: zones)
        return rewriteMasterVEvent(in: after) { block in
            rewriteTopLevel(block) { unit, name in
                guard name == "ATTENDEE", let p = icsProperty(unit.text),
                      let address = mailtoAddress(p.value) else { return nil }
                if address == organizer { return nil }
                if !rescheduled && priorAttendees.contains(address) { return nil }
                return [askAgain(p)]
            }
        }
    }

    // MARK: - Reschedule test

    /// True when the patch moved the start or end, changed the rule, or changed the location: the
    /// changes after which attendees are asked again. Compared on effective values, so restating the
    /// same start is not a change. Anything that can't be read counts as a change; a zone TabMail does
    /// not recognize is refused (`zone(forTZID:zones:)`). `zones` is the stored resource's zone context.
    static func reschedules(before: String, after: String, zones: CalendarTimeZoneContext) throws -> Bool {
        let a = masterTopLevelLines(before)
        let b = masterTopLevelLines(after)
        guard let startA = try effectiveStart(a, zones: zones), let startB = try effectiveStart(b, zones: zones),
              let endA = try effectiveEnd(a, start: startA, zones: zones),
              let endB = try effectiveEnd(b, start: startB, zones: zones) else {
            return true
        }
        if startA != startB || endA != endB { return true }
        if normalizedRule(a) != normalizedRule(b) { return true }
        return propertyText(a, "LOCATION") != propertyText(b, "LOCATION")
    }

    private static func effectiveStart(_ lines: [String], zones: CalendarTimeZoneContext) throws -> Date? {
        guard let dtstart = lines.first(where: { icsProperty($0)?.name == "DTSTART" }) else { return nil }
        return try parseICSDateTime(dtstart, zones: zones)
    }

    private static func effectiveEnd(_ lines: [String], start: Date, zones: CalendarTimeZoneContext) throws -> Date? {
        if let dtend = lines.first(where: { icsProperty($0)?.name == "DTEND" }) {
            return try parseICSDateTime(dtend, zones: zones)
        }
        if let duration = lines.first(where: { icsProperty($0)?.name == "DURATION" }).flatMap(icsProperty) {
            return ICSParser.addDuration(duration.value.trimmingCharacters(in: .whitespaces), to: start)
        }
        // No end and no duration: the end RFC 5545 §3.6.1 implies.
        guard let dtstart = lines.first(where: { icsProperty($0)?.name == "DTSTART" }).flatMap(icsProperty),
              let end = ICSParser.impliedEndValue(dtstartParams: dtstart.params, dtstartValue: dtstart.value) else {
            return nil
        }
        return try parseICSDateTime("DTEND\(dtstart.params):\(end)", zones: zones)
    }

    /// The length of the resource's series VEVENT (its end minus its start), or nil when either can't
    /// be read.
    private static func copyLength(_ ics: String, zones: CalendarTimeZoneContext) throws -> TimeInterval? {
        let lines = masterTopLevelLines(ics)
        guard let start = try effectiveStart(lines, zones: zones), let end = try effectiveEnd(lines, start: start, zones: zones),
              end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func normalizedRule(_ lines: [String]) -> Set<String> {
        guard let rule = lines.first(where: { icsProperty($0)?.name == "RRULE" }).flatMap(icsProperty) else { return [] }
        return Set(rule.value.uppercased().split(separator: ";").map(String.init))
    }

    private static func propertyText(_ lines: [String], _ name: String) -> String {
        guard let p = lines.first(where: { icsProperty($0)?.name == name }).flatMap(icsProperty) else { return "" }
        return ICSParser.unescapeText(p.value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Attendee parameters

    /// The attendee line with `PARTSTAT=NEEDS-ACTION;RSVP=TRUE` in place of any answer it carried;
    /// every other parameter is kept.
    private static func askAgain(_ p: ICSPropertyParts) -> String {
        let kept = splitParams(p.params).filter { param in
            let upper = param.uppercased()
            return !upper.hasPrefix("PARTSTAT=") && !upper.hasPrefix("RSVP=")
        }
        let params = (kept + ["PARTSTAT=NEEDS-ACTION", "RSVP=TRUE"]).map { ";\($0)" }.joined()
        return "\(p.rawName)\(params):\(p.value)"
    }

    /// The lowercased address of a `mailto:` value, or nil when the value is not one.
    static func mailtoAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(trimmed.dropFirst("mailto:".count)).lowercased()
        return address.isEmpty ? nil : address
    }

    // MARK: - Property parsing

    struct ICSPropertyParts {
        /// The property name as written.
        let rawName: String
        /// The property name, uppercased.
        let name: String
        /// Every parameter with its leading `;` (empty when there are none).
        let params: String
        let value: String
    }

    /// Split one LOGICAL (unfolded) content line into name, parameters and value. Quote-aware: a `:`
    /// or `;` inside a quoted parameter value (`CN="Doe; Jane"`) does not end the name or parameters.
    static func icsProperty(_ line: String) -> ICSPropertyParts? {
        var inQuotes = false
        var nameEnd: String.Index?
        for idx in line.indices {
            let ch = line[idx]
            if ch == "\"" { inQuotes.toggle(); continue }
            guard !inQuotes else { continue }
            if (ch == ";" || ch == ":") && nameEnd == nil { nameEnd = idx }
            if ch == ":" {
                let rawName = String(line[..<(nameEnd ?? idx)])
                guard !rawName.isEmpty else { return nil }
                return ICSPropertyParts(
                    rawName: rawName,
                    name: rawName.uppercased(),
                    params: String(line[(nameEnd ?? idx)..<idx]),
                    value: String(line[line.index(after: idx)...]))
            }
        }
        return nil
    }

    /// Split a parameter string (`;A=1;CN="x;y"`) into its parameters, quote-aware.
    private static func splitParams(_ params: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in params {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Resource surgery

    /// One logical content line together with the physical lines it was folded across, so a line we
    /// do not change goes back out byte for byte.
    struct ICSUnit {
        var physical: [String]
        var text: String

        /// True when this is the line `marker` (`isMarker(_:_:)`).
        func isMarker(_ marker: String) -> Bool {
            CalDAVProvider.isMarker(text, marker)
        }
    }

    /// True when `line` is the component line `marker` (`BEGIN:VEVENT`, `END:VEVENT`,
    /// `END:VCALENDAR`) with any trailing whitespace, so a server's trailing space after such a
    /// line does not hide the VEVENT from the reader (`ICSParser`) or from any writer. The one rule
    /// for every match of these lines in the CalDAV path. Leading whitespace is not ignored: on a
    /// physical line it makes a folded continuation, never a component line.
    static func isMarker(_ line: String, _ marker: String) -> Bool {
        line.hasPrefix(marker) && line.dropFirst(marker.count).allSatisfy(\.isWhitespace)
    }

    static func icsUnits(_ ics: String) -> [ICSUnit] {
        var units: [ICSUnit] = []
        for line in physicalICSLines(ics) {
            if let first = line.first, first == " " || first == "\t", !units.isEmpty {
                units[units.count - 1].physical.append(line)
                units[units.count - 1].text += String(line.dropFirst())
            } else {
                units.append(ICSUnit(physical: [line], text: line))
            }
        }
        return units
    }

    /// The VEVENT starting at `units[i]` (`BEGIN:VEVENT` through `END:VEVENT` inclusive); advances `i`
    /// past it.
    private static func takeVEvent(_ units: [ICSUnit], at i: inout Int) -> [ICSUnit] {
        var block: [ICSUnit] = []
        while i < units.count {
            block.append(units[i])
            i += 1
            if block.last?.isMarker("END:VEVENT") == true { break }
        }
        return block
    }

    /// Every VEVENT of a resource, `BEGIN:VEVENT` through `END:VEVENT` inclusive, in document order.
    /// `ICSParser` reads each one through `topLevel`, as the writer does.
    static func veventBlocks(_ units: [ICSUnit]) -> [[ICSUnit]] {
        var blocks: [[ICSUnit]] = []
        var i = 0
        while i < units.count {
            guard units[i].isMarker("BEGIN:VEVENT") else { i += 1; continue }
            blocks.append(takeVEvent(units, at: &i))
        }
        return blocks
    }

    /// True for an occurrence override: a VEVENT with its own `RECURRENCE-ID`.
    static func isOverride(_ block: [ICSUnit]) -> Bool {
        topLevel(block).contains { icsProperty($0.text)?.name == "RECURRENCE-ID" }
    }

    /// The series VEVENT's own properties (not those of its alarms), as logical lines.
    ///
    /// Every reader of the series' properties goes through this, so it never sees a VTIMEZONE's
    /// `STANDARD`/`DAYLIGHT` `DTSTART` and `RRULE` (a split capped by the zone's DST rule), an
    /// override's lines, or a nested component's (an alarm's `UID`, RFC 9074).
    static func masterTopLevelLines(_ ics: String) -> [String] {
        guard let block = veventBlocks(icsUnits(ics)).first(where: { !isOverride($0) }) else { return [] }
        return topLevel(block).map(\.text)
    }

    /// Rewrite every VEVENT of a resource. `transform` gets the block (from `BEGIN:VEVENT` to
    /// `END:VEVENT` inclusive) and whether it is the series' master (no `RECURRENCE-ID`), and returns
    /// the block to write or nil to drop it. Everything outside the VEVENTs is kept as it was.
    static func rewriteVEvents(
        in ics: String,
        _ transform: ([ICSUnit], Bool) throws -> [ICSUnit]?
    ) rethrows -> String {
        let units = icsUnits(ics)
        var out: [ICSUnit] = []
        var i = 0
        while i < units.count {
            guard units[i].isMarker("BEGIN:VEVENT") else { out.append(units[i]); i += 1; continue }
            let block = takeVEvent(units, at: &i)
            if let rewritten = try transform(block, !isOverride(block)) { out.append(contentsOf: rewritten) }
        }
        return out.flatMap(\.physical).joined(separator: "\r\n")
    }

    /// Rewrite the series VEVENT (the first VEVENT with no `RECURRENCE-ID`); every other line of the
    /// resource is kept as it was.
    static func rewriteMasterVEvent(in ics: String, _ transform: ([ICSUnit]) throws -> [ICSUnit]) rethrows -> String {
        let units = icsUnits(ics)
        var out: [ICSUnit] = []
        var i = 0
        var done = false
        while i < units.count {
            guard !done, units[i].isMarker("BEGIN:VEVENT") else { out.append(units[i]); i += 1; continue }
            let block = takeVEvent(units, at: &i)
            if isOverride(block) {
                out.append(contentsOf: block)
            } else {
                out.append(contentsOf: try transform(block))
                done = true
            }
        }
        return out.flatMap(\.physical).joined(separator: "\r\n")
    }

    /// The VEVENT's own properties: those not inside a nested component such as a VALARM.
    static func topLevel(_ block: [ICSUnit]) -> [ICSUnit] {
        var depth = 0
        var out: [ICSUnit] = []
        for unit in block {
            let upper = unit.text.uppercased()
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") { depth -= 1; continue }
            if depth == 1 { out.append(unit) }
        }
        return out
    }

    /// Rewrite the VEVENT's own properties. `rewrite` returns nil to keep a property as it was, an
    /// empty array to drop it, or replacement logical lines. Nested components are kept untouched.
    static func rewriteTopLevel(
        _ block: [ICSUnit],
        _ rewrite: (ICSUnit, String) throws -> [String]?
    ) rethrows -> [ICSUnit] {
        var depth = 0
        var out: [ICSUnit] = []
        for unit in block {
            let upper = unit.text.uppercased()
            if upper.hasPrefix("BEGIN:") { depth += 1; out.append(unit); continue }
            if upper.hasPrefix("END:") { depth -= 1; out.append(unit); continue }
            guard depth == 1, let name = icsProperty(unit.text)?.name,
                  let replacement = try rewrite(unit, name) else {
                out.append(unit)
                continue
            }
            out.append(contentsOf: replacement.map {
                let line = GCalEventInput.sanitizeICSLine($0)
                return ICSUnit(physical: [line], text: line)
            })
        }
        return out
    }

    /// Insert lines among the VEVENT's own properties, ahead of any nested component (RFC 5545 puts a
    /// VEVENT's properties before its alarms).
    static func insertBeforeSubcomponents(_ block: [ICSUnit], lines: [String]) -> [ICSUnit] {
        let units = lines.map { ICSUnit(physical: [$0], text: $0) }
        let at = block.indices.dropFirst().first { idx in
            let upper = block[idx].text.uppercased()
            return upper.hasPrefix("BEGIN:") || isMarker(upper, "END:VEVENT")
        } ?? block.endIndex
        var out = block
        out.insert(contentsOf: units, at: at)
        return out
    }

    /// Insert one unit right after the VEVENT's `UID`, or right after `BEGIN:VEVENT` when it has none.
    static func insertAfterUID(_ block: [ICSUnit], _ unit: ICSUnit) -> [ICSUnit] {
        var depth = 0
        var at = min(1, block.count)
        for (idx, u) in block.enumerated() {
            let upper = u.text.uppercased()
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") { depth -= 1; continue }
            if depth == 1, icsProperty(u.text)?.name == "UID" { at = idx + 1; break }
        }
        var out = block
        out.insert(unit, at: at)
        return out
    }

    /// The instant an override VEVENT's `RECURRENCE-ID` names, in a resource whose zone context is `zones`.
    private static func recurrenceInstant(of block: [ICSUnit], zones: CalendarTimeZoneContext) throws -> Date {
        guard let unit = topLevel(block).first(where: { icsProperty($0.text)?.name == "RECURRENCE-ID" }),
              let instant = try parseICSDateTime(unit.text, zones: zones) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be split.")
        }
        return instant
    }

    /// Keep the values of an `EXDATE`/`RDATE` line whose instant passes `keep`; an empty result drops
    /// the line. A `PERIOD` value is placed by its start. Also splits a Google series' `recurrence`
    /// lines (`GoogleCalendarProvider.splitRecurrence`). `zones` is the zone context of the resource
    /// the line is in (`.none` for a Google `recurrence` line, which comes from no resource).
    static func filterDateList(_ line: String, zones: CalendarTimeZoneContext, keep: (Date) -> Bool) throws -> [String] {
        guard let p = icsProperty(line) else { return [line] }
        var kept: [String] = []
        for value in p.value.split(separator: ",").map(String.init) {
            let start = value.split(separator: "/").first.map(String.init) ?? value
            guard let instant = try parseICSDateTime("\(p.rawName)\(p.params):\(start)", zones: zones) else {
                throw CalendarProviderError.notSupported("An excluded or added date of the repeating event can't be read, so it can't be split.")
            }
            if keep(instant) { kept.append(value) }
        }
        return kept.isEmpty ? [] : ["\(p.rawName)\(p.params):\(kept.joined(separator: ","))"]
    }

    // MARK: - Date values

    /// The ICS value for a naive ISO wall clock in the series' value type: `20260520` for an all-day
    /// series, `20260520T170000Z` for a UTC one, `20260520T170000` otherwise. A time without seconds
    /// (`17:00`) is read as `17:00:00`.
    static func icsDateValue(fromNaive naive: String, kind: MasterDTStartKind) -> String? {
        let digits = naive.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let date = String(digits.prefix(8))
        guard date.count == 8, date.allSatisfy(\.isNumber) else { return nil }
        if case .allDay = kind { return date }
        let parts = digits.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var time = String(parts[1].prefix(while: \.isNumber))
        if time.count == 4 { time += "00" }
        guard time.count >= 6 else { return nil }
        let value = "\(date)T\(time.prefix(6))"
        if case .utc = kind { return value + "Z" }
        return value
    }

    /// Write `instant` in the same form as `line` (date, UTC, zoned or floating), keeping its name and
    /// parameters. Nil when the line can't be read; throws the zone-naming refusal when it names a zone
    /// TabMail does not recognize. `zones` is the zone context of the resource the line is in.
    private static func formatLike(_ line: String, instant: Date, zones: CalendarTimeZoneContext) throws -> String? {
        guard let p = icsProperty(line) else { return nil }
        let value = p.value.trimmingCharacters(in: .whitespaces)
        let fmt: DateFormatter
        if ICSValueType.statesDate(p.params) || (value.count == 8 && !value.contains("T")) {
            // `parseICSDateTime` reads a date at midnight UTC; write it back the same way.
            fmt = FixedDateFormat.formatter("yyyyMMdd", timeZone: .gmt)
        } else if value.uppercased().hasSuffix("Z") {
            fmt = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt)
        } else if let tzid = splitParams(p.params).first(where: { $0.uppercased().hasPrefix("TZID=") }) {
            let lineZone = try zone(forTZID: String(tzid.dropFirst("TZID=".count)), zones: zones)
            fmt = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: lineZone)
        } else {
            fmt = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss", timeZone: .current)
        }
        return "\(p.rawName)\(p.params):\(fmt.string(from: instant))"
    }

    private static func utcStamp(_ date: Date) -> String {
        let fmt = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt)
        return fmt.string(from: date)
    }

    /// `yyyy-MM-dd` plus whole days, on the Gregorian calendar in UTC (a calendar date has no zone).
    private static func shiftedDate(_ ymd: String, days: Int) -> String? {
        let fmt = FixedDateFormat.formatter("yyyy-MM-dd", timeZone: .gmt)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let start = fmt.date(from: String(ymd.prefix(10))),
              let end = cal.date(byAdding: .day, value: days, to: start) else { return nil }
        return fmt.string(from: end)
    }
}
