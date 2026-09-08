/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Inbox trailing swipe actions")
@MainActor
struct InboxTrailingSwipeActionsTests {
    @Test("Drafts full swipe offers and performs Delete, never Archive")
    func draftsDelete() throws {
        var archived = 0
        var deleted = 0
        let controls = InboxTrailingSwipeActions(
            isDrafts: true, isArchive: false, isTrash: false,
            archive: { archived += 1 }, delete: { deleted += 1 })
        #expect(controls.actions.map(\.title) == ["Delete"])
        controls.perform(try #require(controls.actions.first))
        #expect(deleted == 1)
        #expect(archived == 0)
        controls.perform(.archive)
        #expect(archived == 0)
    }

    @Test("Ordinary mail keeps Archive first and Trash available", arguments: [false, true])
    func ordinaryMail(isArchive: Bool) {
        var archived = 0
        var deleted = 0
        let controls = InboxTrailingSwipeActions(
            isDrafts: false, isArchive: isArchive, isTrash: false,
            archive: { archived += 1 }, delete: { deleted += 1 })
        #expect(controls.actions.map(\.title) == ["Archive", "Trash"])
        controls.actions.forEach(controls.perform)
        #expect(archived == (isArchive ? 0 : 1))
        #expect(deleted == 1)
    }

    @Test("Trash stays inert in Trash")
    func trashIsInert() {
        var deleted = false
        let controls = InboxTrailingSwipeActions(
            isDrafts: false, isArchive: false, isTrash: true,
            archive: {}, delete: { deleted = true })
        controls.perform(.trash)
        #expect(!deleted)
    }
}
