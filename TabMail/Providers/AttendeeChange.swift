/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A change of who attends an event, as `calendar_event_edit` gives it: guests added
/// (`add_attendees`), guests removed (`remove_attendees`), `"*"` removing everyone.
///
/// An edit carries the change itself (`GCalEventInput.attendeeChange`), never a list worked out
/// from one item. Each provider's write applies it (`apply`) to the stored guest list of every item
/// the write covers, so each item keeps its own guests (#620): a CalDAV write to every VEVENT of
/// the resource it covers (`CalDAVProvider.applyAttendeeChange`), a Google or Outlook write to the
/// event or occurrence it reads. The Thunderbird add-on applies the same rule (`applyGuestChange`).
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

    /// The change `adds` and `removes` describe. A removal of `"*"` removes everyone; every other
    /// removal is an address, matched in any letter case, with any `mailto:` prefix stripped.
    init(adds: [Add] = [], removes: [String] = []) {
        self.adds = adds
        let addresses = removes.map { CalendarToolHelpers.stripMailto($0).lowercased() }
        self.clearAll = addresses.contains("*")
        var seen = Set<String>()
        self.removes = addresses.filter { $0 != "*" && !$0.isEmpty && seen.insert($0).inserted }
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

    // MARK: - The confirmation card

    /// How many added, and how many removed, guests the card names before "and N more" (as many as
    /// the Thunderbird add-on's card names).
    static let cardNamesShown = 3

    /// The edit card's lines for the change: each guest added (by name, else address) and each
    /// removed (by address; `"*"` as all attendees), up to `cardNamesShown` of each. No resulting
    /// list or count is shown: the change is applied to each item the edit covers, and their guests
    /// can differ.
    var cardLines: [String] {
        func lines(_ labels: [String], _ sign: String) -> [String] {
            let shown = labels.prefix(Self.cardNamesShown).map { "attendees \(sign) \($0)" }
            let more = labels.count - shown.count
            return shown + (more > 0 ? ["attendees \(sign) and \(more) more"] : [])
        }
        return lines(adds.map { $0.name ?? $0.email }, "+")
            + lines((clearAll ? ["all attendees"] : []) + removes, "−")
    }

    // MARK: - A changed occurrence under a change of its series

    /// What a changed occurrence (one with its own copy: a CalDAV override VEVENT) holds after a
    /// guest change of its whole series, or of the new part of a split that carries it.
    enum ChangedOccurrenceGuests: Sendable {
        /// The change applied to the occurrence's own guests: a guest it added on its own stays, and
        /// one it dropped on its own is not invited back. The Thunderbird add-on's rule.
        case ownGuestsChanged
        /// The series' guests after the change, each guest the occurrence held kept as it stored
        /// them: Google Calendar web's rule for the fields an "All events" edit writes (measured
        /// for the title and the place, not for guests).
        case seriesGuests
    }

    /// The one rule every write applies (decided 2026-11-11: the Thunderbird add-on's, until
    /// Google Calendar web is measured for guests).
    static let changedOccurrenceGuests: ChangedOccurrenceGuests = .ownGuestsChanged

    /// A changed occurrence's guests after the change, under `rule`: `own` is what the occurrence
    /// stored, `seriesAfter` the series' guests with the change already applied.
    func applyToChangedOccurrence<Entry>(
        own: [Entry], seriesAfter: [Entry], address: (Entry) -> String?, make: (Add) -> Entry,
        rule: ChangedOccurrenceGuests = Self.changedOccurrenceGuests
    ) -> [Entry] {
        switch rule {
        case .ownGuestsChanged:
            return apply(to: own, address: address, make: make)
        case .seriesGuests:
            return seriesAfter.map { entry in
                guard let guest = address(entry) else { return entry }
                return own.first { address($0) == guest } ?? entry
            }
        }
    }
}
