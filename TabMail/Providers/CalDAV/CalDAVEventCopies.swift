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
/// Attendee answers follow one rule shared with the Thunderbird add-on: the copy keeps them, unless
/// the patch reschedules it (a different start, end, rule or location), in which case every attendee
/// other than the organizer is asked again (`PARTSTAT=NEEDS-ACTION;RSVP=TRUE`). Attendees the patch
/// adds are always asked.
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
    ///    it move to the new part, keeping their absolute times. Re-anchoring is not a series move, so
    ///    nothing is shifted here.
    /// 5. **The user's patch**, applied last. A time change in the patch is therefore measured from the
    ///    slot.
    ///
    /// The capped series changes only its `RRULE` (the cap) and drops what moved to the new part, so
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
    static func seriesSplitResources(
        storedICS: String,
        slotNaiveISO: String,
        cappedRRule: String,
        newRRule: String,
        newUid: String,
        patch: GCalEventInput,
        now: Date
    ) throws -> SeriesSplitResources {
        let kind = masterDTStartKind(from: storedICS)
        guard let dtstart = masterTopLevelLines(storedICS).first(where: { icsProperty($0)?.name == "DTSTART" }),
              let dtstartProperty = icsProperty(dtstart) else {
            throw CalendarProviderError.notSupported("The repeating event has no start, so it can't be split.")
        }
        guard let slotValue = icsDateValue(fromNaive: slotNaiveISO, kind: kind) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(slotNaiveISO)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let slotLine = "DTSTART\(dtstartProperty.params):\(slotValue)"
        guard let slotInstant = parseICSDateTime(slotLine) else {
            throw CalendarProviderError.notSupported("The repeating event's time zone can't be read, so it can't be split.")
        }
        guard let duration = extractMasterDuration(from: storedICS) else {
            throw CalendarProviderError.notSupported("The repeating event's length can't be read, so it can't be split.")
        }
        let stamp = utcStamp(now)

        // 1. The capped series: the cap, and nothing at or after the slot.
        let capped = try rewriteVEvents(in: storedICS) { block, isMaster in
            if !isMaster {
                return try recurrenceInstant(of: block) < slotInstant ? block : nil
            }
            return try rewriteTopLevel(block) { unit, name in
                switch name {
                case "RRULE":
                    return [cappedRRule]
                case "EXDATE", "RDATE":
                    return try filterDateList(unit.text, keep: { $0 < slotInstant })
                default:
                    return nil
                }
            }
        }

        // 2. The new part, re-anchored at the slot.
        let anchored = try rewriteVEvents(in: storedICS) { block, isMaster in
            if !isMaster {
                guard try recurrenceInstant(of: block) >= slotInstant else { return nil }
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
                    guard let end = formatLike(unit.text, instant: slotInstant.addingTimeInterval(duration)) else {
                        throw CalendarProviderError.notSupported("The repeating event's end time zone can't be read, so it can't be split.")
                    }
                    return [end]
                case "RRULE" where isMaster:
                    return [newRRule]
                case "EXDATE" where isMaster, "RDATE" where isMaster:
                    return try filterDateList(unit.text, keep: { $0 >= slotInstant })
                default:
                    return nil
                }
            }
            if !sawStamp { out = insertBeforeSubcomponents(out, lines: ["DTSTAMP:\(stamp)"]) }
            return out
        }

        // 3. The user's patch, then 4. attendee answers.
        let patched = try mergePatchKeepingLength(patch, into: anchored, length: duration)
        let newPart = applyAttendeeRule(before: anchored, after: patched)
        return SeriesSplitResources(cappedSeries: capped, newPart: newPart)
    }

    // MARK: - One-occurrence override

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
    /// - Parameters:
    ///   - storedICS: the series' resource exactly as the server returned it.
    ///   - recurrenceIdNaive: the occurrence's original start, already in the series' frame
    ///     (`recurrenceIdInMasterFrame`).
    ///   - patch: the user's edit.
    ///   - now: the edit's time, written as a new override's `DTSTAMP`.
    static func occurrenceOverrideResource(
        storedICS: String,
        recurrenceIdNaive: String,
        patch: GCalEventInput,
        now: Date
    ) throws -> String {
        let kind = masterDTStartKind(from: storedICS)
        let units = icsUnits(storedICS)
        guard let masterBlock = veventBlocks(units).first(where: { !isOverride($0) }),
              let dtstart = topLevel(masterBlock).first(where: { icsProperty($0.text)?.name == "DTSTART" }),
              let dtstartProperty = icsProperty(dtstart.text) else {
            throw CalendarProviderError.notSupported("The repeating event has no start, so one occurrence of it can't be changed.")
        }
        guard let ridValue = icsDateValue(fromNaive: recurrenceIdNaive, kind: kind) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceIdNaive)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        // RFC 5545 §3.8.4.4: RECURRENCE-ID takes the series DTSTART's value type and zone. A date
        // value must say so, even where the series' own DTSTART leaves it implicit.
        var ridParams = dtstartProperty.params
        if case .allDay = kind, !ridParams.uppercased().contains("VALUE=DATE") { ridParams += ";VALUE=DATE" }
        let ridLine = "RECURRENCE-ID\(ridParams):\(ridValue)"
        guard let ridInstant = parseICSDateTime(ridLine) else {
            throw CalendarProviderError.notSupported("The repeating event's time zone can't be read, so one occurrence of it can't be changed.")
        }

        let base: [ICSUnit]
        if let existing = veventBlocks(units).first(where: { block in
            guard let rid = topLevel(block).first(where: { icsProperty($0.text)?.name == "RECURRENCE-ID" }),
                  let value = icsProperty(rid.text)?.value else { return false }
            return recurrenceIdsMatch(value, recurrenceIdNaive, allDay: kind == .allDay)
        }) {
            base = existing
        } else {
            guard let duration = copyLength(storedICS) else {
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
                    guard let end = formatLike(unit.text, instant: ridInstant.addingTimeInterval(duration)) else {
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
        guard let length = copyLength(wrapped) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be changed again.")
        }
        // A repeat rule belongs to the series: an occurrence never takes one from the edit.
        var occurrencePatch = patch
        occurrencePatch.recurrence = nil
        let patched = try mergePatchKeepingLength(occurrencePatch, into: wrapped, length: length)
        let answered = applyAttendeeRule(before: wrapped, after: patched)
        guard var block = veventBlocks(icsUnits(answered)).first else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be changed again.")
        }
        block = insertAfterUID(block, ridUnit)
        // RFC 5545 §3.8.4.3, enforced by iCloud with an HTTP 403: a VEVENT with attendees carries
        // its organizer. A copy of the series already has it; an override written without one gets
        // the series' organizer.
        let top = topLevel(block).compactMap { icsProperty($0.text)?.name }
        if top.contains("ATTENDEE"), !top.contains("ORGANIZER"),
           let organizer = topLevel(masterBlock).first(where: { icsProperty($0.text)?.name == "ORGANIZER" }) {
            block = insertAfterUID(block, organizer)
        }
        return spliceOrReplaceOverride(
            ics: storedICS, recurrenceId: recurrenceIdNaive, kind: kind,
            newOverrideBlock: block.flatMap(\.physical).joined(separator: "\r\n"))
    }

    // MARK: - Patch and attendee answers

    /// Apply the user's patch to a copy (`mergePatchIntoICS` on the resource's series VEVENT). The
    /// copy stays in its own zone, so the patch's zones are dropped (`Date.fromISO8601` has already
    /// resolved its times). A new start with no end keeps the copy's `length`; an end replaces a
    /// `DURATION`, since RFC 5545 forbids both in one VEVENT. An all-day copy takes the date of a
    /// start or end the patch gives as a date-time.
    private static func mergePatchKeepingLength(_ patch: GCalEventInput, into ics: String, length: TimeInterval) throws -> String {
        var effective = patch
        effective.startTimeZone = nil
        effective.endTimeZone = nil
        var base = ics
        let hasDuration = masterTopLevelLines(ics).contains { icsProperty($0)?.name == "DURATION" }
        if case .allDay = masterDTStartKind(from: ics) {
            effective.startDate = effective.startDate ?? effective.startDateTime.map { String($0.prefix(10)) }
            effective.endDate = effective.endDate ?? effective.endDateTime.map { String($0.prefix(10)) }
            effective.startDateTime = nil
            effective.endDateTime = nil
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
            }
        }
        return try mergePatchIntoICS(base, patch: effective)
    }

    /// `after` with the attendee rule applied to its series VEVENT: an attendee who was in `before`
    /// keeps their answer unless the patch rescheduled the event; anyone else other than the organizer
    /// is asked (`PARTSTAT=NEEDS-ACTION;RSVP=TRUE`).
    private static func applyAttendeeRule(before: String, after: String) -> String {
        let prior = masterTopLevelLines(before)
        let organizer = prior.first(where: { icsProperty($0)?.name == "ORGANIZER" })
            .flatMap { icsProperty($0) }.flatMap { mailtoAddress($0.value) }
        let priorAttendees = Set(prior.compactMap { line -> String? in
            guard let p = icsProperty(line), p.name == "ATTENDEE" else { return nil }
            return mailtoAddress(p.value)
        })
        let rescheduled = reschedules(before: before, after: after)
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
    /// same start is not a change. Anything that can't be read counts as a change.
    static func reschedules(before: String, after: String) -> Bool {
        let a = masterTopLevelLines(before)
        let b = masterTopLevelLines(after)
        guard let startA = effectiveStart(a), let startB = effectiveStart(b),
              let endA = effectiveEnd(a, start: startA), let endB = effectiveEnd(b, start: startB) else {
            return true
        }
        if startA != startB || endA != endB { return true }
        if normalizedRule(a) != normalizedRule(b) { return true }
        return propertyText(a, "LOCATION") != propertyText(b, "LOCATION")
    }

    private static func effectiveStart(_ lines: [String]) -> Date? {
        lines.first(where: { icsProperty($0)?.name == "DTSTART" }).flatMap(parseICSDateTime)
    }

    private static func effectiveEnd(_ lines: [String], start: Date) -> Date? {
        if let dtend = lines.first(where: { icsProperty($0)?.name == "DTEND" }) {
            return parseICSDateTime(dtend)
        }
        if let duration = lines.first(where: { icsProperty($0)?.name == "DURATION" }).flatMap(icsProperty) {
            return ICSParser.addDuration(duration.value.trimmingCharacters(in: .whitespaces), to: start)
        }
        // No end and no duration: the end RFC 5545 §3.6.1 implies.
        guard let dtstart = lines.first(where: { icsProperty($0)?.name == "DTSTART" }).flatMap(icsProperty),
              let end = ICSParser.impliedEndValue(dtstartParams: dtstart.params, dtstartValue: dtstart.value) else {
            return nil
        }
        return parseICSDateTime("DTEND\(dtstart.params):\(end)")
    }

    /// The length of the resource's series VEVENT (its end minus its start), or nil when either can't
    /// be read.
    private static func copyLength(_ ics: String) -> TimeInterval? {
        let lines = masterTopLevelLines(ics)
        guard let start = effectiveStart(lines), let end = effectiveEnd(lines, start: start), end >= start else { return nil }
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
            if block.last?.text == "END:VEVENT" { break }
        }
        return block
    }

    private static func veventBlocks(_ units: [ICSUnit]) -> [[ICSUnit]] {
        var blocks: [[ICSUnit]] = []
        var i = 0
        while i < units.count {
            guard units[i].text == "BEGIN:VEVENT" else { i += 1; continue }
            blocks.append(takeVEvent(units, at: &i))
        }
        return blocks
    }

    /// True for an occurrence override: a VEVENT with its own `RECURRENCE-ID`.
    private static func isOverride(_ block: [ICSUnit]) -> Bool {
        topLevel(block).contains { icsProperty($0.text)?.name == "RECURRENCE-ID" }
    }

    /// The series VEVENT's own properties (not those of its alarms), as logical lines.
    static func masterTopLevelLines(_ ics: String) -> [String] {
        guard let block = veventBlocks(icsUnits(ics)).first(where: { !isOverride($0) }) else { return [] }
        return topLevel(block).map(\.text)
    }

    /// Rewrite every VEVENT of a resource. `transform` gets the block (from `BEGIN:VEVENT` to
    /// `END:VEVENT` inclusive) and whether it is the series' master (no `RECURRENCE-ID`), and returns
    /// the block to write or nil to drop it. Everything outside the VEVENTs is kept as it was.
    private static func rewriteVEvents(
        in ics: String,
        _ transform: ([ICSUnit], Bool) throws -> [ICSUnit]?
    ) rethrows -> String {
        let units = icsUnits(ics)
        var out: [ICSUnit] = []
        var i = 0
        while i < units.count {
            guard units[i].text == "BEGIN:VEVENT" else { out.append(units[i]); i += 1; continue }
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
            guard !done, units[i].text == "BEGIN:VEVENT" else { out.append(units[i]); i += 1; continue }
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
            return upper.hasPrefix("BEGIN:") || upper == "END:VEVENT"
        } ?? block.endIndex
        var out = block
        out.insert(contentsOf: units, at: at)
        return out
    }

    /// Insert one unit right after the VEVENT's `UID`, or right after `BEGIN:VEVENT` when it has none.
    private static func insertAfterUID(_ block: [ICSUnit], _ unit: ICSUnit) -> [ICSUnit] {
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

    /// The instant an override VEVENT's `RECURRENCE-ID` names.
    private static func recurrenceInstant(of block: [ICSUnit]) throws -> Date {
        guard let unit = topLevel(block).first(where: { icsProperty($0.text)?.name == "RECURRENCE-ID" }),
              let instant = parseICSDateTime(unit.text) else {
            throw CalendarProviderError.notSupported("A changed occurrence of the repeating event can't be read, so it can't be split.")
        }
        return instant
    }

    /// Keep the values of an `EXDATE`/`RDATE` line whose instant passes `keep`; an empty result drops
    /// the line. A `PERIOD` value is placed by its start. Also splits a Google series' `recurrence`
    /// lines (`GoogleCalendarProvider.splitRecurrence`).
    static func filterDateList(_ line: String, keep: (Date) -> Bool) throws -> [String] {
        guard let p = icsProperty(line) else { return [line] }
        var kept: [String] = []
        for value in p.value.split(separator: ",").map(String.init) {
            let start = value.split(separator: "/").first.map(String.init) ?? value
            guard let instant = parseICSDateTime("\(p.rawName)\(p.params):\(start)") else {
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
    /// parameters. Nil when the line names a zone that can't be resolved.
    private static func formatLike(_ line: String, instant: Date) -> String? {
        guard let p = icsProperty(line) else { return nil }
        let value = p.value.trimmingCharacters(in: .whitespaces)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if p.params.uppercased().contains("VALUE=DATE") || (value.count == 8 && !value.contains("T")) {
            // `parseICSDateTime` reads a date at midnight UTC; write it back the same way.
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "UTC")
        } else if value.uppercased().hasSuffix("Z") {
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
        } else if let tzid = splitParams(p.params).first(where: { $0.uppercased().hasPrefix("TZID=") }) {
            guard let zone = TimeZone(identifier: String(tzid.dropFirst("TZID=".count))) else { return nil }
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.timeZone = zone
        } else {
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.timeZone = .current
        }
        return "\(p.rawName)\(p.params):\(fmt.string(from: instant))"
    }

    private static func utcStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    /// `yyyy-MM-dd` plus whole days, on the Gregorian calendar in UTC (a calendar date has no zone).
    private static func shiftedDate(_ ymd: String, days: Int) -> String? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let start = fmt.date(from: String(ymd.prefix(10))),
              let end = cal.date(byAdding: .day, value: days, to: start) else { return nil }
        return fmt.string(from: end)
    }
}
