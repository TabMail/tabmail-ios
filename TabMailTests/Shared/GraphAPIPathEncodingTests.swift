/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `IOS-GRAPH-001` — the shared `GraphAPI` surface composes Graph URLs from
/// OPAQUE, server-minted resource ids.
///
/// **The invariant, stated as a system property:** *a Graph id containing `/`,
/// `?`, `#`, `+` or `=` cannot alter the route the request selects.* These
/// tests therefore assert the **composed URL that reached the HTTP boundary**,
/// not that an encoder was called — a mechanism-pinning test would stay green
/// if the encoder were applied to the wrong segment, or applied and then
/// discarded.
///
/// The oracle is `FakeHTTP.Scenario.recordedCalls()`, which records the request
/// BEFORE it looks for a matcher, so an unrouted request still shows up. No
/// matcher is registered on purpose: the helper's parse then fails and it
/// throws, which is irrelevant — the request has already been composed and
/// captured, and that string is the whole assertion. A non-empty recording is
/// also what proves the injected session carried the call rather than the live
/// internet.
@Suite("Shared/API GraphAPI — opaque ids cannot alter the composed route")
struct GraphAPIPathEncodingTests {

    private static let base = "https://graph.microsoft.com/v1.0/me"

    /// One id carrying every character that can re-route a URL: `/` adds a path
    /// segment, `?` starts the query, `#` starts the fragment, and `+` / `=`
    /// are how a raw id smuggles itself into the query the helper appends.
    private static let hostileId = "AA/BB?CC#DD+EE=FF"
    private static let hostileIdEncoded = "AA%2FBB%3FCC%23DD%2BEE%3DFF"

    /// A second hostile value, so the attachment route cannot pass by encoding
    /// one segment and interpolating the other raw.
    private static let hostileAttachmentId = "XX/YY?ZZ#WW+VV=UU"
    private static let hostileAttachmentIdEncoded = "XX%2FYY%3FZZ%23WW%2BVV%3DUU"

    /// An ordinary Graph id: RFC 3986 unreserved characters only. Nothing here
    /// may be escaped — that is the non-vacuity side of the invariant.
    private static let ordinaryId = "AAMkAD-x_y.z~1"

    private func makeHTTP(_ scenario: FakeHTTP.Scenario) -> AuthedHTTP {
        AuthedHTTP(
            auth: AccountAuthSource(accountId: "acc1") { _ in "fake-graph-token" },
            retry: .graph,
            logLabel: "GraphAPIPathEncodingTests",
            session: scenario.session
        )
    }

    /// The single URL the helper composed. Fails loudly if the call never
    /// reached the injected session (which would mean it escaped to the network)
    /// or if it made more than one request.
    /// `raw` as the session sends it: a space in the query is encoded once.
    private func composed(_ raw: String) throws -> String {
        try #require(URL(string: raw)).absoluteString
    }

    private func soleRecordedURL(_ scenario: FakeHTTP.Scenario) throws -> String {
        let calls = scenario.recordedCalls()
        try #require(calls.count == 1, "the helper must reach the injected session exactly once")
        return calls[0].url
    }

    // MARK: - messageMetadata

    @Test("messageMetadata: a hostile message id is one encoded path segment")
    func messageMetadataEncodesHostileId() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.messageMetadata(
            http: makeHTTP(scenario), id: Self.hostileId
        )

        let url = try soleRecordedURL(scenario)
        let expected = try composed("\(Self.base)/messages/\(Self.hostileIdEncoded)"
            + "?\(GraphAPI.metadataSelection.withExtendedProperties.queryParameter)")
        #expect(url == expected)
        // The id cannot reach the query, the fragment, or a second path segment.
        #expect(!url.contains("/messages/AA/BB"))
        #expect(url.split(separator: "?").count == 2)
        #expect(!url.contains("#"))
    }

    @Test("messageMetadata: an ordinary id is not escaped and the $select is verbatim")
    func messageMetadataLeavesOrdinaryIdAlone() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.messageMetadata(
            http: makeHTTP(scenario), id: Self.ordinaryId
        )

        let url = try soleRecordedURL(scenario)
        let expected = try composed("\(Self.base)/messages/\(Self.ordinaryId)"
            + "?\(GraphAPI.metadataSelection.withExtendedProperties.queryParameter)")
        #expect(url == expected)
        // No percent escape before the expand: neither `-._~` in the id nor `$`
        // and `,` in the query string may be touched. Encoding the whole URL
        // instead of the segment would break exactly this. The expand's spaces
        // are encoded once, when the request is sent.
        let selectPart = try #require(url.components(separatedBy: "&$expand=").first)
        #expect(!selectPart.contains("%"))
        #expect(url.contains("?$select=id,subject,from,"))
        #expect(selectPart.hasSuffix(",parentFolderId"))
        // The threading ids come with the metadata, so a row the notification
        // extension stages threads as a synced one does (#1559).
        let decoded = try #require(url.removingPercentEncoding)
        #expect(decoded.hasSuffix(
            "&$expand=singleValueExtendedProperties($filter=id eq 'Integer 0x1081'"
                + " or id eq 'String 0x1042' or id eq 'String 0x1039')"))
    }

    /// What the notification extension stages: the threading ids of the
    /// expanded answer reach `MessageMetadata`, which `OutlookNSEClient` copies
    /// onto the staged row as it does for Gmail (#1559).
    @Test("messageMetadata returns the threading ids the expanded answer carries")
    func messageMetadataReadsThreadingIds() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        scenario.register(path: "/messages/\(Self.ordinaryId)", response: .json(raw: """
            {"id": "\(Self.ordinaryId)", "receivedDateTime": "2023-11-14T22:13:20Z", "parentFolderId": "fld-inbox",
             "singleValueExtendedProperties": [
               {"id": "String 0x1042", "value": "<parent@example.com>"},
               {"id": "String 0x1039", "value": "<root@example.com> <parent@example.com>"}]}
            """))

        let metadata = try await GraphAPI.messageMetadata(http: makeHTTP(scenario), id: Self.ordinaryId)

        #expect(metadata.inReplyTo == "parent@example.com")
        #expect(metadata.references == ["root@example.com", "parent@example.com"])
    }

    // MARK: - messageFull

    @Test("messageFull: a hostile message id is one encoded path segment")
    func messageFullEncodesHostileId() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.messageFull(
            http: makeHTTP(scenario), id: Self.hostileId
        )

        let url = try soleRecordedURL(scenario)
        #expect(url == "\(Self.base)/messages/\(Self.hostileIdEncoded)"
                + "?\(GraphAPI.fullSelection.queryParameter)")
        #expect(!url.contains("/messages/AA/BB"))
        #expect(url.split(separator: "?").count == 2)
        #expect(!url.contains("#"))
    }

    @Test("messageFull: an ordinary id is not escaped, $select is verbatim, nothing is expanded")
    func messageFullLeavesOrdinaryIdAlone() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.messageFull(
            http: makeHTTP(scenario), id: Self.ordinaryId
        )

        let url = try soleRecordedURL(scenario)
        #expect(url == "\(Self.base)/messages/\(Self.ordinaryId)"
                + "?\(GraphAPI.fullSelection.queryParameter)")
        #expect(!url.contains("%"))
        #expect(!url.contains("$expand"))
    }

    // MARK: - attachment (two segments)

    @Test("attachment: BOTH the message id and the attachment id are encoded")
    func attachmentEncodesBothSegments() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.attachment(
            http: makeHTTP(scenario),
            messageId: Self.hostileId,
            attachmentId: Self.hostileAttachmentId
        )

        let url = try soleRecordedURL(scenario)
        #expect(url == "\(Self.base)/messages/\(Self.hostileIdEncoded)"
                + "/attachments/\(Self.hostileAttachmentIdEncoded)")
        // The route still has exactly the segments the helper owns —
        // `https:`, ``, `graph.microsoft.com`, `v1.0`, `me`, `messages`,
        // `<id>`, `attachments`, `<attId>`. An unencoded `/` in either id would
        // add more, which is the whole re-routing hazard.
        #expect(url.components(separatedBy: "/").count == 9)
        #expect(!url.contains("?"))
        #expect(!url.contains("#"))
    }

    @Test("attachment: ordinary ids compose the bare two-segment route")
    func attachmentLeavesOrdinaryIdsAlone() async throws {
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }

        _ = try? await GraphAPI.attachment(
            http: makeHTTP(scenario),
            messageId: Self.ordinaryId,
            attachmentId: "AAMkAGI-att_1.2~3"
        )

        let url = try soleRecordedURL(scenario)
        #expect(url == "\(Self.base)/messages/\(Self.ordinaryId)/attachments/AAMkAGI-att_1.2~3")
        #expect(!url.contains("%"))
    }

    // MARK: - The encoder itself

    @Test("encodedGraphPathSegment keeps exactly the RFC 3986 unreserved set")
    func encoderKeepsOnlyUnreserved() {
        // Unreserved survives verbatim.
        #expect(GraphAPI.encodedGraphPathSegment("Aa0-._~") == "Aa0-._~")
        // Every reserved character that can re-route is escaped.
        #expect(GraphAPI.encodedGraphPathSegment("/") == "%2F")
        #expect(GraphAPI.encodedGraphPathSegment("?") == "%3F")
        #expect(GraphAPI.encodedGraphPathSegment("#") == "%23")
        #expect(GraphAPI.encodedGraphPathSegment("+") == "%2B")
        #expect(GraphAPI.encodedGraphPathSegment("=") == "%3D")
        // A percent already present is itself escaped, so a pre-encoded id
        // cannot be double-decoded by the server into a different route.
        #expect(GraphAPI.encodedGraphPathSegment("%2F") == "%252F")
    }
}
