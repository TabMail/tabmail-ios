/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates `Shared/Parse/GraphParse` — the Microsoft Graph (Outlook) JSON
/// parser shared between main-app ExchangeProvider and the live
/// OutlookNSEClient reached by NotificationService. Same acceptance bar as
/// `GmailParseTests`.
@Suite("Shared/Parse GraphParse")
struct GraphParseTests {

    // MARK: - parseMessage core metadata

    @Test("parseMessage returns nil when receivedDateTime is missing")
    func missingReceivedDateTime() {
        let json: [String: Any] = ["id": "m1", "subject": "hi"]
        #expect(GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection) == nil)
    }

    @Test("parseMessage returns nil when receivedDateTime is unparseable")
    func unparseableReceivedDateTime() {
        let json: [String: Any] = [
            "id": "m1",
            "subject": "hi",
            "receivedDateTime": "not-a-date"
        ]
        #expect(GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection) == nil)
    }

    @Test("parseMessage extracts core fields from valid JSON")
    func coreFields() {
        let json: [String: Any] = [
            "id": "AQMk", "subject": "Quarterly",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "from": ["emailAddress": ["name": "Alice", "address": "alice@example.com"]],
            "toRecipients": [
                ["emailAddress": ["name": "Bob", "address": "bob@example.com"]]
            ],
            "ccRecipients": [
                ["emailAddress": ["address": "cc@example.com"]]
            ],
            "isRead": true,
            "hasAttachments": true,
            "internetMessageId": "<rfc-123@example.com>",
            "conversationId": "conv-1",
            "bodyPreview": "preview",
            "categories": ["work", "urgent"]
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m?.providerMessageId == "AQMk")
        #expect(m?.subject == "Quarterly")
        #expect(m?.from.name == "Alice")
        #expect(m?.from.email == "alice@example.com")
        #expect(m?.to.first?.email == "bob@example.com")
        #expect(m?.cc.first?.email == "cc@example.com")
        #expect(m?.rfc822MessageId == "rfc-123@example.com")  // brackets stripped
        #expect(m?.threadId == "conv-1")
        #expect(m?.isRead == true)
        #expect(m?.hasAttachments == true)
        #expect(m?.snippet == "preview")
        #expect(m?.providerLabels == ["work", "urgent"])
    }

    @Test("parseMessage handles ISO8601 with fractional seconds")
    func iso8601Fractional() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20.123Z",
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m != nil)
    }

    @Test("parseMessage handles missing from (no emailAddress)")
    func missingFrom() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m?.from.name == "")
        #expect(m?.from.email == "")
    }

    @Test("parseMessage: In-Reply-To and References are nil (Graph uses conversationId)")
    func noInReplyToReferences() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m?.inReplyTo == nil)
        #expect(m?.references == [])
    }

    @Test("parseMessage handles flag.flagStatus == 'flagged'")
    func flaggedStatus() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "flag": ["flagStatus": "flagged"]
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m?.isFlagged == true)
    }

    @Test("parseMessage flag.flagStatus == 'notFlagged' yields isFlagged=false")
    func notFlagged() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "flag": ["flagStatus": "notFlagged"]
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection)
        #expect(m?.isFlagged == false)
    }

    // MARK: - parentFolderId → folderPath

    @Test("parseMessage extracts parentFolderId into folderPath for NSE-side id matching")
    func parentFolderIdIntoFolderPath() {
        let json: [String: Any] = [
            "id": "AQMk-msg",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "parentFolderId": "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMD",
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.metadataSelection)
        // Must match exactly what main-app sync uses for `MessageHeader.folderPath`.
        // NSE depends on this to construct a composite id that sync will hit
        // via its existing-row lookup.
        #expect(m?.folderPath == "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMD")
    }

    @Test("parseMessage returns folderPath=nil when parentFolderId is missing (regression guard)")
    func missingParentFolderId() {
        // The URLs that $select parentFolderId (GraphAPI.messageMetadata /
        // messageFull, and ExchangeProvider's detail + full fetches) expect it
        // in every response. If the field is absent (schema drift / partial
        // payload), parse MUST surface nil rather than substituting a default.
        // The NSE client checks for nil and refuses to stage — otherwise we
        // would reinstate the duplicate-row bug (Outlook folderPath=="INBOX"
        // NSE header vs folderPath=<AQMk...> sync header).
        let json: [String: Any] = [
            "id": "AQMk-msg",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            // no parentFolderId
        ]
        let m = GraphParse.parseMessage(json, selection: GraphAPI.metadataSelection)
        #expect(m != nil)
        #expect(m?.folderPath == nil)
    }

    // MARK: - parentFolderId drift detector

    /// `GraphParse.parseMessage` warns "missing parentFolderId — check $select"
    /// when the field is absent. That is only evidence of Graph schema drift if
    /// the caller's `$select` actually named the field. It does not on the
    /// main-app header/backfill paths, where `JSONEncoder` also drops the nil
    /// optional, so the key was ALWAYS absent and the warning always fired —
    /// 94 lines in one ~2.5-minute device session, which is what made the real
    /// signal undetectable.
    ///
    /// Both directions are asserted: silencing the detector outright would pass
    /// the first test and fail the second.
    @Test("Drift detector stays silent when the caller never $selected parentFolderId")
    func driftDetectorSilentWhenFieldWasNotRequested() {
        #expect(
            GraphParse.parentFolderIdDriftDetected(
                parentFolderId: nil, selection: GraphAPI.headerOnlySelection) == false)
    }

    @Test("Drift detector fires when a $selecting caller gets no parentFolderId back")
    func driftDetectorFiresWhenRequestedButAbsent() {
        #expect(
            GraphParse.parentFolderIdDriftDetected(
                parentFolderId: nil, selection: GraphAPI.metadataSelection) == true)
    }

    @Test("Drift detector stays silent when a $selecting caller does get the field")
    func driftDetectorSilentWhenRequestedAndPresent() {
        #expect(
            GraphParse.parentFolderIdDriftDetected(
                parentFolderId: "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMD",
                selection: GraphAPI.metadataSelection) == false)
    }

    /// The selection only gates the diagnostic — parsing is identical either way.
    /// Both parses are required before comparing fields so two nil results cannot
    /// satisfy the equality vacuously.
    @Test("Request selection does not change what parseMessage produces")
    func requestSelectionDoesNotAlterParsing() throws {
        let json: [String: Any] = [
            "id": "AQMk-msg",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            // no parentFolderId — the shape every header/backfill fetch produces
        ]
        let strict = try #require(
            GraphParse.parseMessage(json, selection: GraphAPI.metadataSelection))
        let relaxed = try #require(
            GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection))
        #expect(strict.providerMessageId == relaxed.providerMessageId)
        #expect(strict.folderPath == nil)
        #expect(relaxed.folderPath == nil)
    }

    /// Pins the exact production parser-route census. Each route uses this same
    /// typed selection for URL construction and parsing, so changing a field
    /// list cannot leave a stale Boolean behind.
    @Test("Exchange parser routes derive parentFolderId expectation from their request selection")
    func exchangeRouteSelectionsMatchTheirRequestShapes() throws {
        let expected: [ExchangeGraphMessageRequest: Bool] = [
            .fetchMessages: false,
            .fetchMessage: true,
            .fetchSingleBackfill: false,
            .search: false,
            .fetchMessageHeaders: false,
            .fetchOlderMessages: false,
            .fetchMessageDetails: true
        ]

        #expect(ExchangeGraphMessageRequest.allCases.count == expected.count)
        for route in ExchangeGraphMessageRequest.allCases {
            let expectsParentFolderId = try #require(expected[route] as Bool?)
            #expect(route.selection.contains("parentFolderId") == expectsParentFolderId)
        }

        #expect(expected.values.filter { $0 }.count == 2)
        #expect(expected.values.filter { !$0 }.count == 5)
    }

    @Test("Direct GraphAPI parser routes select parentFolderId")
    func directGraphAPIRoutesAreStrict() {
        #expect(GraphAPI.metadataSelection.contains("parentFolderId"))
        #expect(GraphAPI.fullSelection.contains("parentFolderId"))
    }

    /// This literal is the local wire-format oracle for `$select=` plus comma
    /// joining. `GraphAPIPathEncodingTests` derive expected URLs from the
    /// production selections to isolate path encoding; Exchange provider
    /// integration tests use independent literal field-list oracles.
    @Test("Selection membership is exact and two-sided")
    func selectionMembershipMutants() {
        let withoutParent = GraphMessageSelection(fields: ["id", "parentFolderIdSuffix"])
        let withParent = withoutParent.appending("parentFolderId")

        #expect(withoutParent.contains("parentFolderId") == false)
        #expect(withParent.contains("parentFolderId"))
        #expect(withParent.queryParameter == "$select=id,parentFolderIdSuffix,parentFolderId")
    }

    /// The other half of why the warning fired unconditionally on the sync
    /// path: `ExchangeProvider.parseGraphMessage` re-serializes the decoded
    /// `GraphMessage` with `JSONEncoder`, which omits a nil optional. So on a
    /// header/backfill fetch the key is absent from the parser's input BY
    /// CONSTRUCTION — never because Graph withheld it.
    @Test("JSONEncoder omits parentFolderId when GraphMessage decoded it as nil")
    func encoderOmitsNilParentFolderId() throws {
        let headerOnlyResponse = """
        {
            "id": "AQMk-msg",
            "subject": "Quarterly",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "isRead": false,
            "hasAttachments": false
        }
        """
        let msg = try JSONDecoder().decode(
            GraphMessage.self, from: Data(headerOnlyResponse.utf8))
        #expect(msg.parentFolderId == nil)

        let reencoded = try JSONEncoder().encode(msg)
        let object = try JSONSerialization.jsonObject(with: reencoded)
        let json = try #require(object as? [String: Any])
        #expect(json.keys.contains("parentFolderId") == false)
        #expect(json["id"] as? String == "AQMk-msg")
    }

    // Production census: extractBody / extractAttachmentRefs and the inline
    // image extractor are live through OutlookNSEClient -> GraphAPI.messageFull.
    // GraphParse.parseDeltaPage is an internal helper reached only through
    // GraphAPI.deltaWalk, itself called only by GraphAPI.inboxDelta; that path
    // currently has neither a production caller nor a test.

    // MARK: - extractInlineImageRefs

    /// `$expand=attachments` returns FileAttachment objects with `contentBytes`
    /// inline; inline images are identified by `isInline=true` + non-empty
    /// `contentId` + `image/*` content type. Bytes are standard base64 (NOT
    /// base64url), mirroring Graph's wire format.
    @Test("extractInlineImageRefs decodes inline FileAttachments")
    func inlineImagesBasic() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let b64 = bytes.base64EncodedString()
        let attachments: [[String: Any]] = [
            [
                "id": "att1",
                "isInline": true,
                "contentType": "image/png",
                "contentId": "<logo@host>",
                "contentBytes": b64,
                "size": bytes.count,
            ],
            // not inline — skipped
            [
                "id": "att2",
                "isInline": false,
                "contentType": "image/png",
                "contentId": "<other@host>",
                "contentBytes": b64,
            ],
            // not an image — skipped
            [
                "id": "att3",
                "isInline": true,
                "contentType": "application/pdf",
                "contentId": "<doc@host>",
                "contentBytes": b64,
            ],
            // no contentId — skipped
            [
                "id": "att4",
                "isInline": true,
                "contentType": "image/jpeg",
                "contentBytes": b64,
            ],
        ]

        let images = GraphParse.extractInlineImageRefs(from: attachments)
        #expect(images.count == 1)
        #expect(images[0].contentId == "logo@host") // angle brackets stripped
        #expect(images[0].contentType == "image/png")
        #expect(images[0].data == bytes)
    }

    @Test("extractInlineImageRefs returns empty for nil / empty input")
    func inlineImagesEmpty() {
        #expect(GraphParse.extractInlineImageRefs(from: nil).isEmpty)
        #expect(GraphParse.extractInlineImageRefs(from: []).isEmpty)
    }

    // MARK: - extractInlineImageRefs edge cases (91ae2b8 regression coverage)

    @Test("extractInlineImageRefs skips attachments with missing contentBytes")
    func inlineImagesMissingContentBytes() {
        // `$expand=attachments` may omit `contentBytes` if it exceeds the
        // Graph inline-expansion size limit. Without bytes we can't resolve
        // the CID — skip rather than inserting an empty-data entry that
        // would crash BodyRenderer.
        let attachments: [[String: Any]] = [
            [
                "id": "att-nobytes",
                "isInline": true,
                "contentType": "image/png",
                "contentId": "<nobytes@host>",
                // no contentBytes
            ],
        ]
        #expect(GraphParse.extractInlineImageRefs(from: attachments).isEmpty)
    }

    @Test("extractInlineImageRefs skips attachments with invalid base64 contentBytes")
    func inlineImagesInvalidBase64() {
        // Defense-in-depth: a corrupted contentBytes string must not produce
        // a broken InlineImageRef. Data(base64Encoded:) returns nil → skip.
        let attachments: [[String: Any]] = [
            [
                "id": "att-bad",
                "isInline": true,
                "contentType": "image/png",
                "contentId": "<bad@host>",
                "contentBytes": "not-valid-base64!!",
            ],
        ]
        #expect(GraphParse.extractInlineImageRefs(from: attachments).isEmpty)
    }

    @Test("extractInlineImageRefs skips attachments with empty-string contentId")
    func inlineImagesEmptyContentId() {
        // An empty Content-ID can't match a cid: ref in the HTML body. The
        // trim + isEmpty guard must drop it.
        let bytes = Data([0x01])
        let b64 = bytes.base64EncodedString()
        let attachments: [[String: Any]] = [
            [
                "isInline": true,
                "contentType": "image/png",
                "contentId": "<>",          // brackets only, empty after trim
                "contentBytes": b64,
            ],
            [
                "isInline": true,
                "contentType": "image/png",
                "contentId": "   ",         // whitespace only
                "contentBytes": b64,
            ],
        ]
        #expect(GraphParse.extractInlineImageRefs(from: attachments).isEmpty)
    }

    @Test("extractInlineImageRefs treats missing isInline key as NOT inline")
    func inlineImagesMissingIsInlineKey() {
        // `(att["isInline"] as? Bool) == true` returns false when the key
        // is absent. Graph rarely omits it but older serializations have.
        // Skip to preserve the same-as-false behavior.
        let bytes = Data([0x01])
        let b64 = bytes.base64EncodedString()
        let attachments: [[String: Any]] = [
            [
                "contentType": "image/png",
                "contentId": "<noflag@host>",
                "contentBytes": b64,
            ],
        ]
        #expect(GraphParse.extractInlineImageRefs(from: attachments).isEmpty)
    }

    @Test("extractInlineImageRefs matches mixed-case contentType prefix")
    func inlineImagesCaseInsensitiveMime() {
        // `contentType.lowercased().hasPrefix("image/")` — verify the
        // normalization handles IMAGE/PNG, Image/Jpeg, etc.
        let bytes = Data([0x42])
        let b64 = bytes.base64EncodedString()
        let attachments: [[String: Any]] = [
            [
                "isInline": true,
                "contentType": "IMAGE/PNG",
                "contentId": "<upper@host>",
                "contentBytes": b64,
            ],
            [
                "isInline": true,
                "contentType": "Image/Jpeg",
                "contentId": "<title@host>",
                "contentBytes": b64,
            ],
        ]
        let images = GraphParse.extractInlineImageRefs(from: attachments)
        #expect(images.count == 2)
        #expect(images.contains { $0.contentId == "upper@host" })
        #expect(images.contains { $0.contentId == "title@host" })
    }
}
