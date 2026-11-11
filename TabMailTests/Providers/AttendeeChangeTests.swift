/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// The one function every provider write applies a guest change with (`AttendeeChange.apply`), and
// how a change is read from an edit's arguments. The provider suites
// (`CalendarGuestChangeTests.swift`) check the same rule on what each fake server stores.

@Suite("A guest change applied to one stored guest list")
struct AttendeeChangeApplyTests {
    /// A stored guest: its lowercased address (nil when it has none) and the whole stored entry.
    struct Entry: Equatable, CustomStringConvertible {
        let address: String?
        let raw: String
        var description: String { raw }
    }

    static func stored(_ address: String?, _ raw: String) -> Entry { Entry(address: address, raw: raw) }
    static let alice = stored("alice@example.com", "Alice <alice@example.com> accepted")
    static let bob = stored("bob@example.com", "Bob <bob@example.com> tentative")
    static let carol = stored("carol@example.com", "Carol <carol@example.com> declined")
    static let frontDesk = stored(nil, "Front desk (no address)")

    /// `change` applied to `list`, a new guest written as `new <address> (name)`.
    static func apply(_ change: AttendeeChange, to list: [Entry]) -> [Entry] {
        change.apply(to: list, address: \.address) { add in
            Entry(address: add.email.lowercased(), raw: "new \(add.email) (\(add.name ?? "no name"))")
        }
    }

    static func add(_ email: String, _ name: String? = nil) -> AttendeeChange.Add { .init(email: email, name: name) }

    @Test("a change naming nobody leaves the list as stored")
    func emptyChange() {
        #expect(Self.apply(AttendeeChange(), to: [Self.alice, Self.bob]) == [Self.alice, Self.bob])
    }

    @Test("an added guest is appended, new, after everyone stored")
    func addAppends() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("dave@example.com", "Dave")]), to: [Self.alice, Self.bob])
        #expect(out == [Self.alice, Self.bob, Self.stored("dave@example.com", "new dave@example.com (Dave)")])
    }

    @Test("a removal in any letter case drops only that guest")
    func removeInAnyCase() {
        let out = Self.apply(AttendeeChange(removes: ["BOB@EXAMPLE.COM"]), to: [Self.alice, Self.bob, Self.carol])
        #expect(out == [Self.alice, Self.carol])
    }

    @Test("a removal of someone not there changes nothing")
    func removeAbsent() {
        #expect(Self.apply(AttendeeChange(removes: ["nobody@example.com"]), to: [Self.alice]) == [Self.alice])
    }

    @Test("adding a guest already there in another letter case and name keeps their stored entry")
    func addPresentKeepsStored() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("ALICE@example.com", "Different Alice")]), to: [Self.alice])
        #expect(out == [Self.alice])
    }

    @Test("a guest removed and added back in one change keeps their stored entry, moved to the end")
    func removedAndAddedBack() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("bob@example.com", "Someone else")], removes: ["bob@example.com"]),
                             to: [Self.alice, Self.bob, Self.carol])
        #expect(out == [Self.alice, Self.carol, Self.bob])
    }

    @Test("* removes everyone, a guest with no address too")
    func starClearsAll() {
        #expect(Self.apply(AttendeeChange(removes: ["*"]), to: [Self.alice, Self.frontDesk, Self.bob]).isEmpty)
    }

    @Test("* with additions leaves only the additions, each as stored when the list held them")
    func starThenAdd() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("dave@example.com"), Self.add("Bob@Example.com")], removes: ["*"]),
                             to: [Self.alice, Self.bob])
        #expect(out == [Self.stored("dave@example.com", "new dave@example.com (no name)"), Self.bob])
    }

    @Test("a guest with no address stays through an add and a removal (#597)")
    func addresslessStays() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("dave@example.com")], removes: ["alice@example.com"]),
                             to: [Self.alice, Self.frontDesk])
        #expect(out == [Self.frontDesk, Self.stored("dave@example.com", "new dave@example.com (no name)")])
    }

    @Test("a guest added twice in one change is appended once")
    func addedTwiceOnce() {
        let out = Self.apply(AttendeeChange(adds: [Self.add("dave@example.com", "Dave"), Self.add("DAVE@example.com", "Dave 2")]),
                             to: [Self.alice])
        #expect(out == [Self.alice, Self.stored("dave@example.com", "new dave@example.com (Dave)")])
    }

    @Test("removals strip every mailto: prefix, in any letter case")
    func removalsStripMailto() {
        let change = AttendeeChange(removes: ["MAILTO:mailto: Bob@Example.com"])
        #expect(change.removes == ["bob@example.com"])
        #expect(Self.apply(change, to: [Self.alice, Self.bob]) == [Self.alice])
    }
}

@Suite("A guest change read from an edit's arguments")
struct AttendeeChangeArgumentsTests {
    @Test("arguments that name nobody give no change", arguments: [
        [:],
        ["add_attendees": JSONValue.array([])],
        ["add_attendees": .array([]), "remove_attendees": .array([])],
        ["add_attendees": .array([.dictionary(["email": .string("")]), .string("*")])],
        ["title": .string("Renamed")],
    ] as [[String: JSONValue]])
    func namesNobody(_ arguments: [String: JSONValue]) {
        #expect(AttendeeChange(arguments: arguments) == nil)
    }

    @Test("adds, removals and * are read with their names, every mailto: stripped")
    func readsTheChange() throws {
        let change = try #require(AttendeeChange(arguments: [
            "add_attendees": .array([
                .dictionary(["email": .string("mailto:MAILTO:Dave@Example.com"), "name": .string("Dave")]),
                .string("erin@example.com"),
            ]),
            "remove_attendees": .array([.dictionary(["email": .string("Mailto:bob@example.com")]), .string("*")]),
        ]))
        #expect(change.adds == [.init(email: "Dave@Example.com", name: "Dave"), .init(email: "erin@example.com", name: nil)])
        #expect(change.removes == ["bob@example.com"])
        #expect(change.clearAll)
    }

    @Test("a removal alone is a change")
    func removalAlone() {
        #expect(AttendeeChange(arguments: ["remove_attendees": .array([.string("bob@example.com")])])
                == AttendeeChange(removes: ["bob@example.com"]))
    }
}

@Suite("A changed occurrence under a guest change of its series")
struct AttendeeChangeChangedOccurrenceTests {
    typealias T = AttendeeChangeApplyTests

    @Test("the change on the occurrence's own guests: a guest it added stays, one it dropped is not invited back")
    func ownGuestsChanged() {
        // The series has Alice, Bob and Carol; the occurrence dropped Bob and added Erin on its own.
        let change = AttendeeChange(adds: [T.add("dave@example.com", "Dave")], removes: ["carol@example.com"])
        let erin = T.stored("erin@example.com", "Erin <erin@example.com> accepted")
        let out = T.apply(change, to: [T.alice, T.carol, erin])
        #expect(out == [T.alice, erin, T.stored("dave@example.com", "new dave@example.com (Dave)")])
    }
}
