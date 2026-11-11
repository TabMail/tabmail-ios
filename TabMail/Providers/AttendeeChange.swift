/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A change of who attends an event, as `calendar_event_edit` gives it: guests added
/// (`add_attendees`), guests removed (`remove_attendees`), `"*"` removing everyone.
///
/// An edit carries the change itself (`GCalEventInput.attendeeChange`), never a list worked out
/// from one item. Each provider's write applies it (`apply`) to the stored guest list of the item
/// it writes, so each item keeps its own guests (#620): the event, the series, or the one
/// occurrence an edit names. The Thunderbird add-on's `applyGuestChange` is the same rule.
///
/// A change of a whole series reaches each of its changed occurrences as the series' resulting
/// difference (`seriesDifference`): the guests the series lost are removed from the occurrence, the
/// guests it gained are added, on top of the occurrence's own guests. That is what Google Calendar
/// and Outlook do with a series' guest list, measured on test accounts (2026-11-11): a series
/// emptied of its guests left an occurrence the extra guest it held on its own, and a series list
/// written back unchanged did not invite back a guest an occurrence had dropped on its own. Google
/// is the reference, so every provider ends the same (CalDAV in
/// `CalDAVProvider.applyAttendeeChange`; Google and Outlook write the series alone and the server
/// carries it). The add-on applies the change itself to each changed occurrence instead
/// (`applyGuestChangeToSeries`); the two differ only for `"*"`, for an add of a guest the series
/// already holds (or a remove and re-add of one), and for a removal of a guest the series does not
/// hold (an occurrence's own guest stays).
///
/// Nothing here is persisted: the queue stores the tool's arguments, and the change is built from
/// them when the edit is written (`CalendarToolHelpers.buildGCalEventInput`).
struct AttendeeChange: Sendable, Equatable {
    /// A guest added: the address as given (no `mailto:`), and the name when one was given.
    struct Add: Sendable, Equatable {
        let email: String
        let name: String?
    }

    /// The guests added, in the order given.
    let adds: [Add]
    /// The addresses removed, lowercased, each once, in the order given.
    let removes: [String]
    /// `"*"` was among the removals: everyone goes.
    let clearAll: Bool

    /// The change `adds` and `removes` describe. A removal of `"*"` (only that, so `mailto:*`
    /// names nobody, as in the add-on) removes everyone; every other removal is an address, matched
    /// in any letter case, with any `mailto:` prefix stripped. A guest added twice, in any letter
    /// case, is added once, as first given.
    init(adds: [Add] = [], removes: [String] = []) {
        self.init(
            adds: adds,
            addresses: removes.map { CalendarToolHelpers.stripMailto($0).lowercased() }.filter { $0 != "*" },
            clearAll: removes.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "*" })
    }

    private init(adds: [Add], addresses: [String], clearAll: Bool) {
        var added = Set<String>()
        self.adds = adds.filter { added.insert($0.email.lowercased()).inserted }
        var seen = Set<String>()
        self.removes = addresses.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.clearAll = clearAll
    }

    /// The change an edit's arguments name, or nil when they name nobody: no `add_attendees` and no
    /// `remove_attendees`, or lists with no address in them. Nil writes no guest list at all, so an
    /// edit that names nobody does not re-notify every guest.
    init?(arguments: [String: JSONValue]) {
        let adds = CalendarToolHelpers.parseAttendeeAdds(arguments["add_attendees"])
        let removes = CalendarToolHelpers.parseAttendeeRemoves(arguments["remove_attendees"])
        guard !adds.isEmpty || !removes.isEmpty else { return nil }
        self.init(adds: adds.map { Add(email: $0.email, name: $0.name) }, removes: removes)
    }

    /// `stored` with the change applied, in this order:
    /// 1. everyone goes on `"*"`; otherwise each guest whose address is removed goes;
    /// 2. every other stored guest stays exactly as stored, one with no address too (`address`
    ///    gives nil: a Google guest with no email, a CalDAV attendee that is not `mailto:`);
    /// 3. each added address not already there is appended once, as the list stored them when it
    ///    held them (removed and added back), else as `make` writes a new, unanswered guest.
    ///
    /// `address` gives an entry's lowercased address, or nil when it has none.
    func apply<Entry>(to stored: [Entry], address: (Entry) -> String?, make: (Add) -> Entry) -> [Entry] {
        let removed = Set(removes)
        var out = clearAll ? [] : stored.filter { entry in
            guard let guest = address(entry) else { return true }
            return !removed.contains(guest)
        }
        var present = Set(out.compactMap(address))
        for add in adds {
            let key = add.email.lowercased()
            guard present.insert(key).inserted else { continue }
            out.append(stored.first { address($0) == key } ?? make(add))
        }
        return out
    }

    /// The series' resulting difference as a change: `before` is the series' guest list, `after`
    /// the same list with this change applied (`apply`). It removes each address `before` holds
    /// and `after` does not, and adds each address `after` holds and `before` did not, as this
    /// change adds it (a new, unanswered guest). Matched by address, lowercased; a guest with no
    /// address is in neither. A whole-series write applies it to each changed occurrence, as Google
    /// and Outlook do (see the type's comment): a guest the series held before and after (an add
    /// of a guest it held, or one removed and added back) is no change for an occurrence, and
    /// `"*"` removes from an occurrence only the guests the series held.
    func seriesDifference<Entry>(before: [Entry], after: [Entry], address: (Entry) -> String?) -> AttendeeChange {
        let had = Set(before.compactMap(address))
        let has = Set(after.compactMap(address))
        return AttendeeChange(
            adds: adds.filter { has.contains($0.email.lowercased()) && !had.contains($0.email.lowercased()) },
            addresses: before.compactMap(address).filter { !has.contains($0) },
            clearAll: false)
    }

    // MARK: - The confirmation card

    /// How many added, and how many removed, guests the card names before "and N more" (as many as
    /// the Thunderbird add-on's card names).
    static let cardNamesShown = 3

    /// The edit card's lines for the change: each guest added, as "Name <address>" (the address
    /// alone when no name is given), so the user sees where the invitation goes before confirming;
    /// and each removed (by address; `"*"` as all attendees), up to `cardNamesShown` of each. No
    /// resulting list or count is shown: the change is applied to each item the edit covers, and
    /// their guests can differ.
    var cardLines: [String] {
        func lines(_ labels: [String], _ sign: String) -> [String] {
            let shown = labels.prefix(Self.cardNamesShown).map { "attendees \(sign) \($0)" }
            let more = labels.count - shown.count
            return shown + (more > 0 ? ["attendees \(sign) and \(more) more"] : [])
        }
        return lines(adds.map { add in add.name.map { "\($0) <\(add.email)>" } ?? add.email }, "+")
            + lines((clearAll ? ["all attendees"] : []) + removes, "−")
    }
}
