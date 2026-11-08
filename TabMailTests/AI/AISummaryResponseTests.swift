/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("parseSummaryResponse Edge Cases (JSON)")
struct AISummaryResponseTests {

    private func parse(_ text: String) -> AIResponseParser.SummaryResult {
        AIResponseParser.parseSummaryResponse(text)
    }

    @Test("Todos are space-joined bullets like TB")
    func todosSpaceJoined() {
        let result = parse(#"{"todos": ["First", "Second"], "summary": "S.", "reminder": null, "text_message": "T."}"#)
        #expect(result.todos == "• First • Second")
    }

    @Test("Empty, blank, None and non-string todo items are skipped")
    func todosSkipEmpty() {
        let result = parse(#"{"todos": ["", "  ", "None", 7, null, "Real item"], "summary": "S.", "reminder": null, "text_message": "T."}"#)
        #expect(result.todos == "• Real item")
    }

    @Test("Todos that are not a list give no todos")
    func todosNotAList() {
        let result = parse(#"{"todos": "Do it", "summary": "S.", "reminder": null, "text_message": "T."}"#)
        #expect(result.todos == nil)
        #expect(result.blurb == "S.")
    }

    @Test("A todo with a newline is stored on one line")
    func todoOneLine() {
        let result = parse(#"{"todos": ["Line one\nline two"], "summary": "S.", "reminder": null, "text_message": "T."}"#)
        #expect(result.todos == "• Line one line two")
    }

    @Test("Multiline blurb collapsed to a single line")
    func multilineBlurb() {
        let result = parse(#"{"todos": [], "summary": "Line one.\nLine two.", "reminder": null, "text_message": "T."}"#)
        #expect(result.blurb == "Line one. Line two.")
    }

    @Test("The text message keeps its line breaks")
    func textMessageKeepsNewlines() {
        let result = parse(#"{"todos": [], "summary": "S.", "reminder": null, "text_message": "  First line.\nSecond line.  "}"#)
        #expect(result.textMessage == "First line.\nSecond line.")
    }

    @Test("None, quoted None and blank reminder values are nil; the summary and text message are kept as written")
    func noneValues() {
        let result = parse(#"{"todos": [], "summary": "None", "reminder": {"due_date": "none", "due_time": "\"None\"", "content": "  "}, "text_message": "NONE"}"#)
        // The backend accepts any nonblank summary and sends it as is: "None" is a summary.
        #expect(result.blurb == "None")
        #expect(result.reminderDate == nil)
        #expect(result.reminderTime == nil)
        #expect(result.reminderContent == nil)
        // The backend sends the text message as a plain string with no "None" word.
        #expect(result.textMessage == "NONE")
    }

    @Test("A blank summary is no summary; a multi-line one is stored on one line")
    func blankAndMultiLineSummary() {
        #expect(parse(#"{"todos": [], "summary": " \n ", "reminder": null, "text_message": "T."}"#).blurb == nil)
        #expect(parse(#"{"todos": [], "summary": "One.\nTwo.", "reminder": null, "text_message": "T."}"#).blurb == "One. Two.")
    }

    @Test("A missing text message leaves the summary intact")
    func missingTextMessage() {
        let result = parse(#"{"todos": ["A"], "summary": "S.", "reminder": null}"#)
        #expect(result.blurb == "S.")
        #expect(result.todos == "• A")
        #expect(result.textMessage == nil)
    }

    @Test("A reminder that is not an object gives no reminder")
    func reminderNotObject() {
        let result = parse(#"{"todos": [], "summary": "S.", "reminder": "tomorrow", "text_message": "T."}"#)
        #expect(result.reminderContent == nil)
        #expect(result.reminderDate == nil)
    }

    @Test("Valid reminder time stored; three-digit hour rejected")
    func reminderTimes() {
        let ok = parse(#"{"todos": [], "summary": "S.", "reminder": {"due_date": "2099-01-01", "due_time": "09:30", "content": "C"}, "text_message": "T."}"#)
        #expect(ok.reminderTime == "09:30")
        let bad = parse(#"{"todos": [], "summary": "S.", "reminder": {"due_date": "2099-01-01", "due_time": "109:30", "content": "C"}, "text_message": "T."}"#)
        #expect(bad.reminderTime == nil)
        let short = parse(#"{"todos": [], "summary": "S.", "reminder": {"due_date": "2099-01-01", "due_time": "9:30", "content": "C"}, "text_message": "T."}"#)
        #expect(short.reminderTime == nil)
    }

    @Test("A non-date reminder date is stored as-is when content is present")
    func nonDateReminderDate() {
        let result = parse(#"{"todos": [], "summary": "S.", "reminder": {"due_date": "next week", "due_time": null, "content": "C"}, "text_message": "T."}"#)
        #expect(result.reminderDate == "next week")
    }

    @Test("A code-fenced object is not parsed (the backend strips fences)")
    func codeFenceNotParsed() {
        let result = parse("```json\n{\"todos\": [], \"summary\": \"S.\", \"reminder\": null, \"text_message\": \"T.\"}\n```")
        #expect(result.blurb == nil)
    }
}
