/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates `Shared/Parse/GraphParse` — the Microsoft Graph (Outlook) JSON
/// parser shared between main-app ExchangeProvider and the future
/// OutlookNSEClient. Same acceptance bar as `GmailParseTests`.
@Suite("Shared/Parse GraphParse")
struct GraphParseTests {

    // MARK: - parseMessage core metadata

    @Test("parseMessage returns nil when receivedDateTime is missing")
    func missingReceivedDateTime() {
        let json: [String: Any] = ["id": "m1", "subject": "hi"]
        #expect(GraphParse.parseMessage(json) == nil)
    }

    @Test("parseMessage returns nil when receivedDateTime is unparseable")
    func unparseableReceivedDateTime() {
        let json: [String: Any] = [
            "id": "m1",
            "subject": "hi",
            "receivedDateTime": "not-a-date"
        ]
        #expect(GraphParse.parseMessage(json) == nil)
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
        let m = GraphParse.parseMessage(json)
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
        let m = GraphParse.parseMessage(json)
        #expect(m != nil)
    }

    @Test("parseMessage handles missing from (no emailAddress)")
    func missingFrom() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
        ]
        let m = GraphParse.parseMessage(json)
        #expect(m?.from.name == "")
        #expect(m?.from.email == "")
    }

    @Test("parseMessage: In-Reply-To and References are nil (Graph uses conversationId)")
    func noInReplyToReferences() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
        ]
        let m = GraphParse.parseMessage(json)
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
        let m = GraphParse.parseMessage(json)
        #expect(m?.isFlagged == true)
    }

    @Test("parseMessage flag.flagStatus == 'notFlagged' yields isFlagged=false")
    func notFlagged() {
        let json: [String: Any] = [
            "id": "m1",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            "flag": ["flagStatus": "notFlagged"]
        ]
        let m = GraphParse.parseMessage(json)
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
        let m = GraphParse.parseMessage(json)
        // Must match exactly what main-app sync uses for `MessageHeader.folderPath`.
        // NSE depends on this to construct a composite id that sync will hit
        // via its existing-row lookup.
        #expect(m?.folderPath == "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMD")
    }

    @Test("parseMessage returns folderPath=nil when parentFolderId is missing (regression guard)")
    func missingParentFolderId() {
        // Graph's $select guarantees parentFolderId is in every response.
        // If the field is absent (schema drift / partial payload), parse
        // MUST surface nil rather than substituting a default. The NSE
        // client checks for nil and refuses to stage — otherwise we would
        // reinstate the duplicate-row bug (Outlook folderPath=="INBOX"
        // NSE header vs folderPath=<AQMk...> sync header).
        let json: [String: Any] = [
            "id": "AQMk-msg",
            "receivedDateTime": "2023-11-14T22:13:20Z",
            // no parentFolderId
        ]
        let m = GraphParse.parseMessage(json)
        #expect(m != nil)
        #expect(m?.folderPath == nil)
    }

    // Note: parseDeltaPage / extractBody / extractAttachmentRefs were removed
    // in round-3 dead-code cleanup. They'll be re-added (with tests) when
    // OutlookNSEClient actually consumes them.

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
