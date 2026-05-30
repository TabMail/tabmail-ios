/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionTag")
struct ActionTagTests {

    @Test("All cases have correct rawValue")
    func rawValues() {
        #expect(ActionTag.reply.rawValue == "reply")
        #expect(ActionTag.none.rawValue == "none")
        #expect(ActionTag.archive.rawValue == "archive")
        #expect(ActionTag.delete.rawValue == "delete")
    }

    @Test("IMAP keyword format is tm_ prefixed")
    func imapKeyword() {
        #expect(ActionTag.reply.imapKeyword == "tm_reply")
        #expect(ActionTag.none.imapKeyword == "tm_none")
        #expect(ActionTag.archive.imapKeyword == "tm_archive")
        #expect(ActionTag.delete.imapKeyword == "tm_delete")
    }

    @Test("fromIMAPKeyword parses all valid keywords")
    func fromIMAPKeyword() {
        #expect(ActionTag.fromIMAPKeyword("tm_reply") == ActionTag.reply)
        #expect(ActionTag.fromIMAPKeyword("tm_none") == ActionTag.none)
        #expect(ActionTag.fromIMAPKeyword("tm_archive") == ActionTag.archive)
        #expect(ActionTag.fromIMAPKeyword("tm_delete") == ActionTag.delete)
    }

    @Test("fromIMAPKeyword returns nil for unknown keyword")
    func fromIMAPKeywordUnknown() {
        #expect(ActionTag.fromIMAPKeyword("tm_unknown") == nil)
        #expect(ActionTag.fromIMAPKeyword("") == nil)
    }

    @Test("fromIMAPKeyword also accepts plain raw values without prefix")
    func fromIMAPKeywordPlain() {
        #expect(ActionTag.fromIMAPKeyword("archive") == ActionTag.archive)
        #expect(ActionTag.fromIMAPKeyword("reply") == ActionTag.reply)
    }

    @Test("sortOrder ordering: reply < none < archive < delete")
    func sortOrder() {
        #expect(ActionTag.reply.sortOrder == 0)
        #expect(ActionTag.none.sortOrder == 1)
        #expect(ActionTag.archive.sortOrder == 2)
        #expect(ActionTag.delete.sortOrder == 3)
    }

    @Test("displayName is human-readable")
    func displayName() {
        #expect(ActionTag.reply.displayName == "Reply")
        #expect(ActionTag.archive.displayName == "Archive")
        #expect(ActionTag.delete.displayName == "Delete")
    }

    @Test("letter returns correct single character or nil for none")
    func letter() {
        #expect(ActionTag.reply.letter == "R")
        #expect(ActionTag.archive.letter == "A")
        #expect(ActionTag.delete.letter == "D")
        #expect(ActionTag.none.letter == nil)
    }

    @Test("CaseIterable includes all 4 cases")
    func allCases() {
        #expect(ActionTag.allCases.count == 4)
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        for tag in ActionTag.allCases {
            let data = try JSONEncoder().encode(tag)
            let decoded = try JSONDecoder().decode(ActionTag.self, from: data)
            #expect(decoded == tag)
        }
    }

    @Test("Decoder handles tm_ prefix for backward compat")
    func decoderStripsTmPrefix() throws {
        let json = "\"tm_archive\""
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ActionTag.self, from: data)
        #expect(decoded == .archive)
    }
}
