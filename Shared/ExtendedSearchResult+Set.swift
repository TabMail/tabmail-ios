/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

extension ExtendedSearchResult {
    /// The matched identifiers, from whichever field lists them: `.all` when
    /// ESEARCH is supported, `.ordered` when `extendedSearch` falls back to plain
    /// SEARCH. Throws `ExtendedSearchUnlisted` for an answer that reports matches
    /// without listing them. Private: every caller reads through
    /// `listed(within:)`, so no answer is read without the scope it was asked in.
    private func listed() throws -> MessageIdentifierSet<T> {
        guard let listed = listedMatches else { throw ExtendedSearchUnlisted() }
        return listed
    }

    /// The only way to read an answer as a set, for a SEARCH restricted to
    /// `requested` (a criteria-only SEARCH passes its selection's scope,
    /// `MessageIdentifierSet.selectionScope(uidNext:)`): an answer naming any
    /// identifier outside the request cannot be attributed to it and proves
    /// nothing, so it throws `ExtendedSearchUnlisted` rather than being trimmed
    /// to the request (a trimmed answer could read a present identifier as
    /// absent). Compared range by range, never expanded.
    func listed(within requested: MessageIdentifierSet<T>) throws -> MessageIdentifierSet<T> {
        let answer = try listed()
        var allowed = IndexSet()
        for range in requested.ranges { allowed.insert(integersIn: range) }
        for range in answer.ranges where !allowed.contains(integersIn: range) {
            throw ExtendedSearchUnlisted()
        }
        return answer
    }

    /// The matched identifiers when the answer lists every one of them, or `nil`
    /// when it reports matches without listing them (COUNT above zero, MIN, MAX,
    /// or a PARTIAL page). An answer that does not list its matches proves no
    /// identifier absent, so a caller deciding absence from it must read `nil`
    /// as "not proven". An answer with no matches at all lists the empty set.
    ///
    /// A list that contradicts the answer's own COUNT, MIN or MAX is not a
    /// complete list either: it is read as unlisted.
    private var listedMatches: MessageIdentifierSet<T>? {
        if let all {
            guard Self.agrees(all, count: count, min: min, max: max) else { return nil }
            return all
        }
        if let ordered { return MessageIdentifierSet(ordered) }
        if partial != nil || (count ?? 0) > 0 || min != nil || max != nil { return nil }
        return MessageIdentifierSet()
    }

    /// Whether a listed set agrees with the COUNT, MIN and MAX sent with it.
    /// Read from the set's ranges, never expanded.
    private static func agrees(
        _ set: MessageIdentifierSet<T>, count: Int?, min: T?, max: T?
    ) -> Bool {
        let ranges = set.ranges
        if let count {
            var total = 0
            for range in ranges { total += range.count }
            guard total == count else { return false }
        }
        if let min { guard ranges.first?.lowerBound == Int(min.value) else { return false } }
        if let max { guard ranges.last?.upperBound == Int(max.value) else { return false } }
        return true
    }
}

/// A SEARCH answer that reported matches without listing them (COUNT, MIN, MAX
/// or a PARTIAL page but no ALL): the caller's read fails rather than taking it
/// as an empty or partial result.
struct ExtendedSearchUnlisted: Error, CustomStringConvertible {
    var description: String { "SEARCH answer reported matches without listing them" }
}

extension MessageIdentifierSet<UID> {
    /// Every UID a selection can hold, the scope of a SEARCH over the whole
    /// selected mailbox: the UIDs below its UIDNEXT, none when UIDNEXT is 1 (an
    /// empty mailbox), every valid UID when the selection reported none (0).
    static func selectionScope(uidNext: UID) -> MessageIdentifierSet<UID> {
        var scope = MessageIdentifierSet<UID>()
        switch uidNext.value {
        case 0: scope.insert(range: 1...Int(UInt32.max))
        case 1: break
        default: scope.insert(range: 1...(Int(uidNext.value) - 1))
        }
        return scope
    }
}
