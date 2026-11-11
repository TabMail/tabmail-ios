/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The organizer of a CalDAV event that has guests (RFC 5545 §3.8.4.3: a VEVENT with attendees
/// carries its organizer; iCloud refuses the write with a 403 without one).
///
/// One step, `organized(_:own:)`, runs on the final body of every CalDAV `PUT`
/// (`CalDAVProvider.putEvent`). For each VEVENT, looking at its own properties only (an EMAIL
/// alarm's `ATTENDEE` is the alarm's, not the event's):
/// 1. A VEVENT with an attendee and no organizer gets one. A VEVENT that has an organizer, or no
///    attendee, is never changed.
/// 2. The organizer is the resource's own, copied byte for byte: the series VEVENT's, else the first
///    changed occurrence's in document order. So every VEVENT of the resource names the same
///    organizer (RFC 6638 §3.2.4.2).
/// 3. Only when no VEVENT names one, and the resource is the user's own event (it has a series
///    VEVENT, as every create does), the user's own address: one the server itself advertises in
///    the principal's `calendar-user-address-set` (RFC 6638 §2.4.1), so RFC 6638 §3.1 makes the
///    resource the user's organizer object and the server invites the guests. The sign-in when it
///    is advertised, written as the server spells it; else the first advertised `mailto:`. When
///    nothing is advertised, no organizer is written and the server decides. The sign-in is never
///    written unchecked: a wrong organizer misattributes the meeting and can send the guests'
///    answers elsewhere, which is worse than none.
/// 4. A resource that holds only changed occurrences (an invitation to single occurrences of
///    someone else's series, RFC 4791 §4.1) never gets the account's address: that would forge the
///    meeting's identity (ADR-IOS-052). It only gets an organizer another of its VEVENTs names.
/// 5. When nothing needs an organizer, the body is returned as it was, byte for byte.
extension CalDAVProvider {

    /// `ics` with every VEVENT that has an attendee and no organizer given one (rules 1 to 5 above).
    /// `own` is the user's advertised address (`organizerHref`), or nil when there is none.
    static func organized(_ ics: String, own: String?) -> String {
        let blocks = veventBlocks(icsUnits(ics))
        guard blocks.contains(where: needsOrganizer) else { return ics }
        let organizer: ICSUnit
        if let copied = resourceOrganizer(blocks) {
            organizer = copied
        } else if let own, blocks.contains(where: { !isOverride($0) }) {
            let line = "ORGANIZER:\(own)"
            organizer = ICSUnit(physical: [line], text: line)
        } else {
            return ics
        }
        return rewriteVEvents(in: ics) { block, _ in
            needsOrganizer(block) ? insertAfterUID(block, organizer) : block
        }
    }

    /// True when writing `ics` takes the user's own address: some VEVENT has an attendee and no
    /// organizer, no VEVENT names an organizer to copy, and the resource has a series VEVENT.
    /// Only then does `withOrganizer` look the address up, so an ordinary edit makes no request.
    static func needsOwnAddress(_ ics: String) -> Bool {
        let blocks = veventBlocks(icsUnits(ics))
        return blocks.contains(where: needsOrganizer)
            && resourceOrganizer(blocks) == nil
            && blocks.contains { !isOverride($0) }
    }

    /// The address to write as the user's organizer, from the hrefs the server advertises: the one
    /// whose address is `signIn` (compared in any letter case) as the server spells it, else the
    /// first `mailto:`, else nil. An href that is not a `mailto:` with an address, or that carries
    /// a control character or a line break, is skipped.
    static func organizerHref(advertised: [String], signIn: String) -> String? {
        let usable = advertised.filter { href in
            guard !href.unicodeScalars.contains(where: GCalEventInput.isForbiddenICSScalar) else { return false }
            return mailtoAddress(href) != nil
        }
        let wanted = signIn.trimmingCharacters(in: .whitespaces).lowercased()
        return usable.first { mailtoAddress($0) == wanted } ?? usable.first
    }

    /// The hrefs of the principal's `calendar-user-address-set`, in the server's order; empty when
    /// the server gives a definite answer that names none.
    ///
    /// The principal is found the way the account was set up (`CalDAVDiscovery.discover`). A
    /// definite answer means none is advertised: a 404, 403 or other refusal, a principal or a
    /// property the server does not have, an answer that can't be read. Those return empty, and
    /// the write goes ahead without an organizer. A lookup 404 must never surface as
    /// `CalDAVError.notFound`, which the calendar queue reads as "the event is gone" and retires.
    /// Everything else is rethrown: a 401 (the write would be refused too, and the queue's auth
    /// arm handles it), and an answer that says nothing yet (a transport error, a 5xx, a 408, 409,
    /// 423, 425 or 429), which keeps the edit queued for a retry with nothing written.
    static func advertisedAddresses(client: CalDAVClient, serverURL: URL) async throws -> [String] {
        do {
            let principal = try await CalDAVDiscovery.discover(serverURL: serverURL, client: client).principalURL
            return try await CalDAVDiscovery.calendarUserAddresses(principalURL: principal, client: client)
        } catch {
            guard isDefiniteNoAddress(error) else { throw error }
            BackgroundSyncLogger.logDebug("[CalDAV] organizer: no calendar-user-address-set (\(error)); writing no organizer")
            return []
        }
    }

    /// True when a lookup error is the server's definite answer (see `advertisedAddresses`).
    private static func isDefiniteNoAddress(_ error: Error) -> Bool {
        switch error {
        case CalDAVError.notFound, CalDAVError.preconditionFailed,
             CalDAVError.discoveryFailed, CalDAVError.parseError:
            return true
        case CalDAVError.httpError(let code, _):
            let comeBackLater: Set<Int> = [408, 409, 423, 425, 429]
            return (400...499).contains(code) && !comeBackLater.contains(code)
        default:
            return false
        }
    }

    // MARK: - Private

    /// A VEVENT with an attendee of its own and no organizer of its own.
    private static func needsOrganizer(_ block: [ICSUnit]) -> Bool {
        let names = topLevel(block).compactMap { icsProperty($0.text)?.name }
        return names.contains("ATTENDEE") && !names.contains("ORGANIZER")
    }

    /// The resource's own organizer: the series VEVENT's, else the first changed occurrence's in
    /// document order.
    private static func resourceOrganizer(_ blocks: [[ICSUnit]]) -> ICSUnit? {
        func organizer(_ block: [ICSUnit]) -> ICSUnit? {
            topLevel(block).first { icsProperty($0.text)?.name == "ORGANIZER" }
        }
        if let series = blocks.first(where: { !isOverride($0) }), let found = organizer(series) { return found }
        return blocks.lazy.compactMap(organizer).first
    }
}
