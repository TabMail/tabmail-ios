/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("parseSummaryResponse Edge Cases")
struct AISummaryResponseTests {

    @Test("Todos with various list prefix styles")
    func todosListPrefixes() async {
        let service = AIService.shared
        let text = """
        Todos:
        - Item one
        * Item two
        • Item three
        1. Item four
        2) Item five
        Two-line summary: Test.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        // All items should be normalized to bullet format
        #expect(result.todos?.contains("• Item one") == true)
        #expect(result.todos?.contains("• Item two") == true)
        #expect(result.todos?.contains("• Item three") == true)
        #expect(result.todos?.contains("• Item four") == true)
        #expect(result.todos?.contains("• Item five") == true)
    }

    @Test("Todos space-joined bullets like TB")
    func todosSpaceJoined() async {
        let service = AIService.shared
        let text = """
        Todos:
        1. First
        2. Second
        Two-line summary: Test.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        // TB joins with space: "• First • Second"
        #expect(result.todos == "• First • Second")
    }

    @Test("Multiline blurb collapsed to single line")
    func multilineBlurb() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Line one of summary.
        Line two of summary.
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        // Newlines in blurb should be replaced with spaces
        #expect(result.blurb?.contains("\n") == false)
        #expect(result.blurb?.contains("Line one") == true)
    }

    @Test("Reminder content None means all reminder fields nil")
    func reminderContentNoneMeansAllNil() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: 2024-03-20
        Reminder due time: 14:00
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        // When content is None, ALL reminder fields should be nil
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
        #expect(result.reminderContent == nil)
    }

    @Test("Quoted None also treated as none")
    func quotedNone() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: "None"
        Reminder due time: "None"
        Reminder content: "None"
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderContent == nil)
    }

    @Test("Reminder time must be HH:MM format")
    func reminderTimeValidation() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: 2024-03-20
        Reminder due time: 2:00 PM
        Reminder content: Check this
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderTime == nil) // "2:00 PM" doesn't match ^\d{2}:\d{2}$
        #expect(result.reminderContent == "Check this")
    }

    @Test("Valid reminder time stored")
    func validReminderTime() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: 2024-03-20
        Reminder due time: 09:30
        Reminder content: Morning standup
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.reminderTime == "09:30")
    }

    @Test("Markdown headings with multiple # levels stripped")
    func multiLevelMarkdownHeadings() async {
        let service = AIService.shared
        let text = """
        ### Todos: Do stuff
        ### Two-line summary: Summary here.
        # Reminder due date: 2024-05-01
        ## Reminder due time: 10:00
        # Reminder content: Check stuff
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.blurb == "Summary here.")
        #expect(result.todos?.contains("Do stuff") == true)
        #expect(result.reminderContent == "Check stuff")
    }

    @Test("Only whitespace in sections treated as empty")
    func whitespaceOnlySections() async {
        let service = AIService.shared
        let text = """
        Todos:
        Two-line summary:
        Reminder due date: None
        Reminder due time: None
        Reminder content: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
    }

    @Test("Case insensitive section headers")
    func caseInsensitiveSections() async {
        let service = AIService.shared
        let text = """
        TODOS: Review budget
        TWO-LINE SUMMARY: Budget review needed.
        REMINDER DUE DATE: None
        REMINDER DUE TIME: None
        REMINDER CONTENT: None
        """
        let result = await service.parseSummaryResponse(text)
        #expect(result.blurb?.contains("Budget review") == true)
        #expect(result.todos?.contains("Review budget") == true)
    }

    @Test("Non-date reminder date stored as-is when content present")
    func nonDateReminderDateStored() async {
        let service = AIService.shared
        let text = """
        Todos: None
        Two-line summary: Test.
        Reminder due date: next Tuesday
        Reminder due time: None
        Reminder content: Follow up
        """
        let result = await service.parseSummaryResponse(text)
        // TB stores any non-none value for due date
        #expect(result.reminderDate == "next Tuesday")
        #expect(result.reminderContent == "Follow up")
    }
}
