/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SummaryResult Struct")
struct SummaryResultTests {

    @Test("SummaryResult with all fields")
    func allFields() {
        let result = SummaryResult(
            blurb: "Meeting summary",
            todos: "• Follow up • Send notes",
            reminderDate: "2024-03-20",
            reminderTime: "14:00",
            reminderContent: "Follow up with team"
        )
        #expect(result.blurb == "Meeting summary")
        #expect(result.todos?.contains("Follow up") == true)
        #expect(result.reminderDate == "2024-03-20")
        #expect(result.reminderTime == "14:00")
        #expect(result.reminderContent == "Follow up with team")
    }

    @Test("SummaryResult with all nil")
    func allNil() {
        let result = SummaryResult(
            blurb: nil, todos: nil,
            reminderDate: nil, reminderTime: nil,
            reminderContent: nil
        )
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
        #expect(result.reminderDate == nil)
    }
}

@Suite("AIService.parseSummaryResponse")
struct AISummaryParsingTests {

    // AIService is an actor — we need an instance. For unit-testing the parsing
    // we create an isolated instance. parseSummaryResponse is a sync method on the actor.

    @Test("Parses blurb from Two-line summary section")
    func parsesBlurb() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Alice asks about the budget review.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.blurb?.contains("budget review") == true)
    }

    @Test("Parses todos with bullet normalization")
    func parsesTodos() async {
        let service = AIService.shared
        let text = """
        Todos:
        1. Review the budget
        2. Send feedback
        Two-line summary: Budget discussion email.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.todos?.contains("•") == true)
        #expect(result.todos?.contains("Review the budget") == true)
        #expect(result.todos?.contains("Send feedback") == true)
    }

    @Test("Parses reminder fields")
    func parsesReminder() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Meeting request.
        Reminder due date: 2024-03-20
        Reminder due time: 14:00
        Reminder content: Follow up with Bob about the proposal.
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderDate == "2024-03-20")
        #expect(result.reminderTime == "14:00")
        #expect(result.reminderContent == "Follow up with Bob about the proposal.")
    }

    @Test("None values result in nil")
    func noneValuesNil() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Simple email.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
        #expect(result.reminderContent == nil)
    }

    @Test("Empty response gives all nil")
    func emptyResponse() async {
        let service = AIService.shared
        let result = await service.parseSummaryResponse("")
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
    }

    @Test("Markdown heading markers stripped")
    func markdownHeadingsStripped() async {
        let service = AIService.shared
        let text = """
        ## Todos: Review budget
        ## Two-line summary: Quick summary of budget email.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.blurb?.contains("Quick summary") == true)
    }

    @Test("Invalid reminder time format not stored")
    func invalidReminderTime() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: 2024-03-20
        Reminder due time: afternoon
        Reminder content: Check something
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderTime == nil) // "afternoon" doesn't match HH:MM
        #expect(result.reminderContent == "Check something") // content still stored
    }
}
