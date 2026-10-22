/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// #238: a text-only draft another app wrote as `format=flowed` (RFC 3676) opens
/// with its soft line breaks joined, and a draft that does not declare it opens
/// exactly as written.
@Suite("EmailFilter.decodeFormatFlowed")
struct EmailFilterFormatFlowedTests {

    @Test("Text not declared flowed is returned unchanged, trailing spaces and all", arguments: [
        "text/plain",
        "text/plain; charset=UTF-8",
        "text/plain; format=fixed",
        // `format=flowed` inside another parameter's quoted value is that value's text.
        "text/plain; x-note=\"keep; format=flowed\"",
    ])
    func undeclaredIsUnchanged(contentType: String) {
        let typed = "Hi Bob, \n  indented line \n> quoted \n-- \nAlice "
        #expect(EmailFilter.decodeFormatFlowed(typed, contentType: contentType) == typed)
    }

    @Test("A flowed body is decoded to the text it stands for", arguments: [
        // A soft break (trailing space) joins the next line; a hard break stays.
        ("This is a long \nparagraph.\nNext line", "This is a long paragraph.\nNext line"),
        // Blank lines stay blank lines.
        ("Hi Bob,\n\nSee \nyou.\n\nAlice", "Hi Bob,\n\nSee you.\n\nAlice"),
        // Space-stuffing is removed (a stuffed line starting with ">" is not a quote).
        (" >not a quote\n From here", ">not a quote\nFrom here"),
        // Quoted lines join within their depth and are written back as "> " per depth.
        ("> quoted \n> more\n>> deep \n>>er\nreply", "> quoted more\n>> deep er\nreply"),
        // A change of quote depth ends the paragraph.
        ("> soft \nnot quoted", "> soft \nnot quoted"),
        // The signature separator is a line of its own.
        ("Thanks \n-- \nAlice", "Thanks \n-- \nAlice"),
        // CRLF line ends decode the same as LF.
        ("a \r\nb\r\n", "a b\n"),
    ])
    func flowedDecodes(flowed: String, expected: String) {
        #expect(EmailFilter.decodeFormatFlowed(flowed, contentType: "text/plain; charset=UTF-8; format=flowed") == expected)
    }

    @Test("delsp=yes removes the space that marked the soft break; parameters are case-insensitive and may be quoted")
    func delSpRemovesTheMarkerSpace() {
        let contentType = "text/plain; Format=\"Flowed\"; DelSp=Yes"
        #expect(EmailFilter.decodeFormatFlowed("Hel \nlo wor \nld", contentType: contentType) == "Hello world")
        #expect(EmailFilter.decodeFormatFlowed("Hel \nlo", contentType: "text/plain; format=flowed; delsp=no") == "Hel lo")
    }

    @Test("A comment after a parameter value is not part of it (RFC 2045)")
    func commentIsNotPartOfTheValue() {
        let contentType = "text/plain; format=flowed (wrapped); delsp=yes (marker)"
        #expect(EmailFilter.decodeFormatFlowed("Hel \nlo", contentType: contentType) == "Hello")
    }
}
