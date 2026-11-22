/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIResponseParser.parseReplyResponse")
struct AIReplyParseTests {

    @Test("Extracts the body and the text message")
    func bodyAndTextMessage() {
        let result = AIResponseParser.parseReplyResponse(
            #"{"subject": "Re: Budget", "body": "Thanks for your email.", "text_message": "Thanks, got it."}"#
        )
        #expect(result?.body == "Thanks for your email.")
        #expect(result?.textMessage == "Thanks, got it.")
    }

    @Test("Extracts the change command; nil when absent or blank")
    func changeCommand() {
        let with = AIResponseParser.parseReplyResponse(
            #"{"subject": "S", "body": "Thanks.", "text_message": "Thanks!", "change_command": " ask for Friday "}"#)
        #expect(with?.changeCommand == "ask for Friday")
        let without = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "Thanks.", "text_message": "Thanks!"}"#)
        #expect(without?.body == "Thanks.")
        #expect(without?.changeCommand == nil)
        let blank = AIResponseParser.parseReplyResponse(#"{"body": "Thanks.", "change_command": "  "}"#)
        #expect(blank?.changeCommand == nil)
    }

    @Test("A multiline body keeps its line breaks")
    func multilineBody() {
        let result = AIResponseParser.parseReplyResponse(
            #"{"subject": "Re: Meeting", "body": "Hi there,\n\nI'll be available at 3pm.\n\nBest regards,\nAlice", "text_message": "3pm works."}"#
        )
        #expect(result?.body == "Hi there,\n\nI'll be available at 3pm.\n\nBest regards,\nAlice")
    }

    @Test("Body and text message are trimmed")
    func trims() {
        let result = AIResponseParser.parseReplyResponse(#"  {"subject": "S", "body": "  Hello world  \n", "text_message": "  Hi.  "}  "#)
        #expect(result?.body == "Hello world")
        #expect(result?.textMessage == "Hi.")
    }

    @Test("No body, an empty or blank body, or a non-string body gives nil")
    func noBody() {
        for text in [
            #"{"subject": "S", "text_message": "T"}"#,
            #"{"subject": "S", "body": "", "text_message": "T"}"#,
            #"{"subject": "S", "body": "   ", "text_message": "T"}"#,
            #"{"subject": "S", "body": 7, "text_message": "T"}"#,
        ] {
            #expect(AIResponseParser.parseReplyResponse(text) == nil, "\(text)")
        }
    }

    @Test("A body or text message that is the word None is kept: the backend has no None word for them")
    func noneIsData() {
        let result = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "None", "text_message": "None"}"#)
        #expect(result?.body == "None")
        #expect(result?.textMessage == "None")
    }

    @Test("A missing or empty text message keeps the body")
    func missingTextMessage() {
        let missing = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "B"}"#)
        #expect(missing?.body == "B")
        #expect(missing?.textMessage == nil)
        let empty = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "B", "text_message": ""}"#)
        #expect(empty?.body == "B")
        #expect(empty?.textMessage == nil)
    }

    @Test("Labelled text, empty input and non-object JSON give nil")
    func notTheObject() {
        for text in ["Subject: Hello\nBody: Thanks for your email.", "", "Just a plain reply.", "[]", "null", #""body""#] {
            #expect(AIResponseParser.parseReplyResponse(text) == nil, "\(text)")
        }
    }
}
