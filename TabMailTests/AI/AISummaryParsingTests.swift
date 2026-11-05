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
            reminderContent: "Follow up with team",
            textMessage: "Can you follow up with the team?"
        )
        #expect(result.blurb == "Meeting summary")
        #expect(result.todos?.contains("Follow up") == true)
        #expect(result.reminderDate == "2024-03-20")
        #expect(result.reminderTime == "14:00")
        #expect(result.reminderContent == "Follow up with team")
        #expect(result.textMessage == "Can you follow up with the team?")
    }

    @Test("SummaryResult.empty has every field nil")
    func emptyIsAllNil() {
        let result = SummaryResult.empty
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
        #expect(result.reminderContent == nil)
        #expect(result.textMessage == nil)
    }

    @Test("init(from:) carries the text message")
    func fromSharedCarriesTextMessage() {
        let shared = AIResponseParser.parseSummaryResponse(
            #"{"todos": [], "summary": "S.", "reminder": null, "text_message": "Hi there."}"#
        )
        let result = SummaryResult(from: shared)
        #expect(result.blurb == "S.")
        #expect(result.textMessage == "Hi there.")
    }
}

@Suite("AIService.parseSummaryResponse (JSON)")
struct AISummaryParsingTests {

    private func parse(_ text: String) async -> SummaryResult {
        await AIService.shared.parseSummaryResponse(text)
    }

    @Test("Parses every field of a full summary object")
    func parsesFullObject() async {
        let result = await parse("""
        {"todos": ["Review the budget", "Send feedback"],
         "summary": "Alice asks about the budget review.",
         "reminder": {"due_date": "2099-03-20", "due_time": "14:00", "content": "Reply to Alice about the budget."},
         "text_message": "Hey, can you look at the budget and send me feedback by Friday?"}
        """)
        #expect(result.blurb == "Alice asks about the budget review.")
        #expect(result.todos == "• Review the budget • Send feedback")
        #expect(result.reminderDate == "2099-03-20")
        #expect(result.reminderTime == "14:00")
        #expect(result.reminderContent == "Reply to Alice about the budget.")
        #expect(result.textMessage == "Hey, can you look at the budget and send me feedback by Friday?")
    }

    @Test("A null reminder gives no reminder fields")
    func nullReminder() async {
        let result = await parse(#"{"todos": [], "summary": "Simple email.", "reminder": null, "text_message": "Just saying hi."}"#)
        #expect(result.blurb == "Simple email.")
        #expect(result.todos == nil)
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
        #expect(result.reminderContent == nil)
        #expect(result.textMessage == "Just saying hi.")
    }

    @Test("Reminder date and time without content are dropped")
    func reminderNeedsContent() async {
        let result = await parse("""
        {"todos": [], "summary": "S.", "reminder": {"due_date": "2099-03-20", "due_time": "09:00", "content": null}, "text_message": "T."}
        """)
        #expect(result.reminderContent == nil)
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
    }

    @Test("Reminder time must be HH:MM; content and date are kept")
    func reminderTimeFormat() async {
        let result = await parse("""
        {"todos": [], "summary": "S.", "reminder": {"due_date": "2099-03-20", "due_time": "afternoon", "content": "Check something"}, "text_message": "T."}
        """)
        #expect(result.reminderTime == nil)
        #expect(result.reminderDate == "2099-03-20")
        #expect(result.reminderContent == "Check something")
    }

    @Test("A null reminder time with content keeps date and content")
    func reminderNullTime() async {
        let result = await parse("""
        {"todos": [], "summary": "S.", "reminder": {"due_date": "2099-03-20", "due_time": null, "content": "Pay the invoice"}, "text_message": "T."}
        """)
        #expect(result.reminderTime == nil)
        #expect(result.reminderDate == "2099-03-20")
        #expect(result.reminderContent == "Pay the invoice")
    }

    @Test("Not JSON gives an all-nil result")
    func notJSON() async {
        let result = await parse("""
        Todos: None
        Two-line summary: Alice asks about the budget review.
        Reminder due date: None
        """)
        #expect(result.blurb == nil)
        #expect(result.todos == nil)
        #expect(result.reminderContent == nil)
        #expect(result.textMessage == nil)
    }

    @Test("Empty and non-object JSON give an all-nil result")
    func emptyAndNonObject() async {
        for text in ["", "   ", "[]", #"["a"]"#, "null", "42", #""summary""#] {
            let result = await parse(text)
            #expect(result.blurb == nil, "\(text)")
            #expect(result.textMessage == nil, "\(text)")
        }
    }

    @Test("Surrounding whitespace around the object is accepted")
    func surroundingWhitespace() async {
        let result = await parse("\n  {\"todos\": [], \"summary\": \"S.\", \"reminder\": null, \"text_message\": \"T.\"}  \n")
        #expect(result.blurb == "S.")
        #expect(result.textMessage == "T.")
    }
}
