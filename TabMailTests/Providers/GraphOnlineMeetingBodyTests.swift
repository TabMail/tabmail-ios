/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A join section layout and a join link it holds.
enum JoinLayout: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// A meeting made in Teams on a work account, checked live, with
    /// `onlineMeeting.joinUrl` on the "System reference" link or the "Join:" one.
    case liveByLongLink, liveByShortLink
    /// Graph's online-meeting samples (an older layout).
    case documentedSample

    var testDescription: String { rawValue }

    var section: String {
        self == .documentedSample ? GraphFixture.sampleJoinSection : GraphFixture.joinSection
    }

    var joinUrl: String { self == .liveByShortLink ? GraphFixture.shortJoinUrl : GraphFixture.joinUrl }
}

/// How an online meeting's stored body is rewritten for new notes (#511), for
/// the layout a live Teams meeting stored and the one in Graph's samples
/// (`GraphFixture.joinSection`, `GraphFixture.sampleJoinSection`).
@Suite("An online meeting's notes are replaced around its join section")
struct GraphOnlineMeetingBodyTests {
    private let joinUrl = GraphFixture.joinUrl
    private let section = GraphFixture.joinSection + GraphFixture.htmlTail

    @Test("notes written as bare text, as in Graph's create sample, are replaced and the join section kept",
          arguments: JoinLayout.allCases)
    func bareTextNotes(_ layout: JoinLayout) throws {
        let rest = layout.section + GraphFixture.htmlTail
        let html = GraphFixture.htmlHead + "Does this time work for you?\r\n" + rest

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: layout.joinUrl, with: "New time?"))

        #expect(out == GraphFixture.htmlHead + "New time?\r\n" + rest)
    }

    @Test("notes in elements, as a live meeting and Graph's update sample hold them, are replaced and the join section kept",
          arguments: JoinLayout.allCases)
    func elementNotes(_ layout: JoinLayout) throws {
        let rest = layout.section + GraphFixture.htmlTail
        let html = GraphFixture.htmlHead + "<p>Let's define <a href=\"https://example.com/doc\">our</a> strategy.</p>\r\n<div>More</div>\r\n" + rest

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: layout.joinUrl, with: "Agenda"))

        #expect(out == GraphFixture.htmlHead + "Agenda\r\n" + rest)
    }

    @Test("new notes are escaped and keep their line breaks", arguments: ["\n", "\r\n", "\r"])
    func notesAreEscaped(_ lineBreak: String) throws {
        let html = GraphFixture.htmlHead + "Old\r\n" + section

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(
            in: html, joinUrl: joinUrl, with: "Bring <laptop> & charger" + lineBreak + "Room 2"))

        #expect(out == GraphFixture.htmlHead + "Bring &lt;laptop&gt; &amp; charger<br>\r\nRoom 2\r\n" + section)
    }

    @Test("the notes start after a body tag with attributes, or at the start when there is none")
    func bodyTagForms() throws {
        let withAttributes = "<html><body lang=\"en\" dir=\"ltr\">Old" + section
        #expect(GraphOnlineMeetingBody.replacingNotes(in: withAttributes, joinUrl: joinUrl, with: "New")
            == "<html><body lang=\"en\" dir=\"ltr\">\r\nNew\r\n" + section)

        let fragment = "<div>Old</div>" + section
        #expect(GraphOnlineMeetingBody.replacingNotes(in: fragment, joinUrl: joinUrl, with: "New") == "\r\nNew\r\n" + section)
    }

    @Test("a join link written as given, not with &amp;, is found")
    func rawJoinLink() throws {
        let rawSection = GraphFixture.joinSection.replacingOccurrences(
            of: joinUrl.replacingOccurrences(of: "&", with: "&amp;"), with: joinUrl)
        #expect(rawSection.contains(joinUrl))
        let html = GraphFixture.htmlHead + "Old\r\n" + rawSection + GraphFixture.htmlTail

        #expect(GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: joinUrl, with: "New")
            == GraphFixture.htmlHead + "New\r\n" + rawSection + GraphFixture.htmlTail)
    }

    @Test("every element the separator line sits in belongs to the join section")
    func nestedSeparator() throws {
        let separator = "<div><div class=\"line\"> <span>" + String(repeating: "_", count: 40) + "</span></div></div>"
        let rest = separator + "<a href=\"" + joinUrl + "\">Join</a>" + GraphFixture.htmlTail
        let html = "<html><body><p>Old</p>\r\n" + rest

        #expect(GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: joinUrl, with: "New") == "<html><body>\r\nNew\r\n" + rest)
    }

    @Test("no join section is recognised without the join link, without a separator line before it, or in an unclosed body tag")
    func unrecognised() {
        let noLink = GraphFixture.htmlHead + "Old\r\n" + GraphFixture.joinSeparator + "<a href=\"https://meet.example.com/other\">Join</a>"
            + GraphFixture.joinSeparator + GraphFixture.htmlTail
        #expect(GraphOnlineMeetingBody.replacingNotes(in: noLink, joinUrl: joinUrl, with: "New") == nil)

        let separatorOnlyAfter = GraphFixture.htmlHead + "Old <a href=\"" + joinUrl + "\">Join</a>" + GraphFixture.joinSeparator
            + GraphFixture.htmlTail
        #expect(GraphOnlineMeetingBody.replacingNotes(in: separatorOnlyAfter, joinUrl: joinUrl, with: "New") == nil)

        let shortLine = GraphFixture.htmlHead + "Old " + String(repeating: "_", count: GraphOnlineMeetingBody.separatorMinUnderscores - 1)
            + "<a href=\"" + joinUrl + "\">Join</a>" + GraphFixture.htmlTail
        #expect(GraphOnlineMeetingBody.replacingNotes(in: shortLine, joinUrl: joinUrl, with: "New") == nil)

        #expect(GraphOnlineMeetingBody.replacingNotes(in: GraphFixture.joinSection + "<body lang=\"en\"", joinUrl: joinUrl, with: "New") == nil)
        #expect(GraphOnlineMeetingBody.replacingNotes(in: GraphFixture.onlineBody, joinUrl: "", with: "New") == nil)
    }

    /// The join link as it appears in notes: as given, or with `&` as `&amp;` (how
    /// `replacingNotes` writes notes the assistant was handed the link in).
    static let linkForms: [(layout: JoinLayout, escaped: Bool)] = JoinLayout.allCases.flatMap { [($0, false), ($0, true)] }

    @Test("a copy of the join link in the notes is passed over: the notes are replaced and the join section kept",
          arguments: linkForms)
    func joinLinkInTheNotes(_ form: (layout: JoinLayout, escaped: Bool)) throws {
        let link = form.escaped ? form.layout.joinUrl.replacingOccurrences(of: "&", with: "&amp;") : form.layout.joinUrl
        let start = GraphFixture.htmlHead + "<p>Join here: <a href=\"" + link + "\">" + link + "</a></p>\r\n"
        let rest = form.layout.section + GraphFixture.htmlTail

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(in: start + rest, joinUrl: form.layout.joinUrl, with: "New"))

        #expect(out == GraphFixture.htmlHead + "\r\nNew\r\n" + rest)
        #expect(GraphOnlineMeetingBody.beforeJoinSection(start + rest, joinUrl: form.layout.joinUrl).map(String.init) == start)
    }

    @Test("a line of underscores in the notes is part of the notes, not the join section's separator",
          arguments: JoinLayout.allCases)
    func separatorLikeLineInTheNotes(_ layout: JoinLayout) throws {
        // Outlook's divider above a pasted earlier message is such a line.
        let start = GraphFixture.htmlHead + "<p>Earlier thread</p>\r\n<div>" + String(repeating: "_", count: 32)
            + "</div>\r\n<p>From: someone@example.com</p>\r\n"
        let rest = layout.section + GraphFixture.htmlTail

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(in: start + rest, joinUrl: layout.joinUrl, with: "New"))

        #expect(out == GraphFixture.htmlHead + "\r\nNew\r\n" + rest)
        #expect(GraphOnlineMeetingBody.beforeJoinSection(start + rest, joinUrl: layout.joinUrl).map(String.init) == start)
    }

    @Test("with a line of underscores above a copy of the link in the notes, the whole join section is still kept",
          arguments: JoinLayout.allCases)
    func separatorLikeLineAboveALinkCopy(_ layout: JoinLayout) throws {
        // The one shape the recogniser cannot tell apart: it places the section at the notes' line, too
        // early, which keeps the old notes below that line and, above all, the join section.
        let start = GraphFixture.htmlHead + "<div>" + String(repeating: "_", count: 32) + "</div>\r\n<p>Join: "
            + layout.joinUrl + "</p>\r\n"
        let rest = layout.section + GraphFixture.htmlTail

        let out = try #require(GraphOnlineMeetingBody.replacingNotes(in: start + rest, joinUrl: layout.joinUrl, with: "New"))

        #expect(out.hasSuffix(rest), "the join section was not kept whole")
        #expect(out.hasPrefix(GraphFixture.htmlHead + "\r\nNew\r\n"))
    }

    @Test("trailing line breaks in new notes are dropped, so repeated edits do not grow the body")
    func trailingLineBreaks() throws {
        let rest = section
        let html = GraphFixture.htmlHead + "Old\r\n" + rest

        let once = try #require(GraphOnlineMeetingBody.replacingNotes(in: html, joinUrl: joinUrl, with: "Agenda\n\r\n"))
        let twice = try #require(GraphOnlineMeetingBody.replacingNotes(in: once, joinUrl: joinUrl, with: "Agenda\n"))

        #expect(once == GraphFixture.htmlHead + "\r\nAgenda\r\n" + rest)
        #expect(twice == once)
    }

    @Test("the document up to the join section is its start and the notes, for either layout and either join link",
          arguments: JoinLayout.allCases)
    func beforeJoinSection(_ layout: JoinLayout) {
        let start = GraphFixture.htmlHead + "<p>Notes with a <a href=\"https://example.com/doc\">link</a></p>\r\n"
        let html = start + layout.section + GraphFixture.htmlTail

        #expect(GraphOnlineMeetingBody.beforeJoinSection(html, joinUrl: layout.joinUrl).map(String.init) == start)
        #expect(GraphOnlineMeetingBody.beforeJoinSection(start + GraphFixture.htmlTail, joinUrl: layout.joinUrl) == nil)
    }
}
