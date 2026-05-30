/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates `Shared/Parse/GmailParse` output against the legacy-era expectations
/// preserved in `GmailProvider.parseGmailMessage`. Guards against the two
/// regressions fixed in commit 1m (`hasAttachments` filename-or-calendar rule,
/// raw `to`/`cc`/`bcc` header preservation).
@Suite("Shared/Parse GmailParse")
struct GmailParseTests {

    // MARK: - parseMessage: core metadata

    @Test("parseMessage returns nil when internalDate is missing")
    func missingInternalDate() {
        let json: [String: Any] = [
            "id": "m1",
            "payload": ["headers": [["name": "Subject", "value": "hi"]]]
        ]
        #expect(GmailParse.parseMessage(json) == nil)
    }

    @Test("parseMessage returns nil when internalDate is zero")
    func zeroInternalDate() {
        let json: [String: Any] = [
            "id": "m1",
            "internalDate": "0",
            "payload": ["headers": []]
        ]
        #expect(GmailParse.parseMessage(json) == nil)
    }

    @Test("parseMessage extracts subject, from, date, labels")
    func coreFields() {
        let json: [String: Any] = [
            "id": "m1",
            "threadId": "t1",
            "internalDate": "1700000000000",
            "labelIds": ["INBOX", "UNREAD"],
            "snippet": "hello there",
            "payload": [
                "headers": [
                    ["name": "Subject", "value": "Quarterly update"],
                    ["name": "From", "value": "Alice <alice@example.com>"],
                    ["name": "Message-Id", "value": "<rfc-123@example.com>"]
                ]
            ]
        ]
        let m = GmailParse.parseMessage(json)
        #expect(m != nil)
        #expect(m?.providerMessageId == "m1")
        #expect(m?.threadId == "t1")
        #expect(m?.subject == "Quarterly update")
        #expect(m?.from.name == "Alice")
        #expect(m?.from.email == "alice@example.com")
        #expect(m?.rfc822MessageId == "rfc-123@example.com")  // normalized (brackets stripped)
        #expect(m?.isRead == false)  // UNREAD present
        #expect(m?.providerLabels == ["INBOX", "UNREAD"])
        #expect(m?.snippet == "hello there")
    }

    @Test("parseMessage Message-Id header is case-insensitive")
    func messageIdCaseInsensitive() {
        let json: [String: Any] = [
            "id": "m1",
            "internalDate": "1700000000000",
            "payload": [
                "headers": [["name": "message-id", "value": "<abc@ex.com>"]]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.rfc822MessageId == "abc@ex.com")
    }

    @Test("parseMessage extracts References as ordered list of normalized IDs")
    func referencesExtracted() {
        let json: [String: Any] = [
            "id": "m1",
            "internalDate": "1700000000000",
            "payload": [
                "headers": [
                    ["name": "References", "value": "<a@x.com> <b@y.com>\n <c@z.com>"]
                ]
            ]
        ]
        let m = GmailParse.parseMessage(json)
        #expect(m?.references == ["a@x.com", "b@y.com", "c@z.com"])
    }

    @Test("parseMessage isFlagged reflects STARRED label")
    func starredFlag() {
        let json: [String: Any] = [
            "id": "m1",
            "internalDate": "1700000000000",
            "labelIds": ["INBOX", "STARRED"],
            "payload": ["headers": []]
        ]
        #expect(GmailParse.parseMessage(json)?.isFlagged == true)
    }

    // MARK: - rawHeader

    @Test("rawHeader returns header value verbatim")
    func rawHeaderVerbatim() {
        let json: [String: Any] = [
            "payload": [
                "headers": [
                    ["name": "To", "value": "\"Alice\" <a@ex.com>, Bob <b@ex.com>"]
                ]
            ]
        ]
        #expect(GmailParse.rawHeader(json, name: "To") == "\"Alice\" <a@ex.com>, Bob <b@ex.com>")
    }

    @Test("rawHeader is case-insensitive — covers legacy Cc/CC/BCC fallback")
    func rawHeaderCaseInsensitive() {
        let json: [String: Any] = [
            "payload": [
                "headers": [["name": "CC", "value": "c@ex.com"]]
            ]
        ]
        // Old code special-cased "Cc" || "CC"; new code via case-insensitive compare works.
        #expect(GmailParse.rawHeader(json, name: "Cc") == "c@ex.com")
        #expect(GmailParse.rawHeader(json, name: "CC") == "c@ex.com")
    }

    @Test("rawHeader returns nil for missing header")
    func rawHeaderMissing() {
        let json: [String: Any] = ["payload": ["headers": []]]
        #expect(GmailParse.rawHeader(json, name: "To") == nil)
    }

    // MARK: - hasAttachments (via parseMessage — regression from 1m)

    @Test("hasAttachments=true when any part has non-empty filename")
    func hasAttachmentsFilename() {
        let json: [String: Any] = [
            "id": "m1", "internalDate": "1700000000000",
            "payload": [
                "headers": [],
                "parts": [
                    ["mimeType": "application/pdf", "filename": "doc.pdf"]
                ]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.hasAttachments == true)
    }

    @Test("hasAttachments=true for text/calendar even with no filename")
    func hasAttachmentsTextCalendar() {
        let json: [String: Any] = [
            "id": "m1", "internalDate": "1700000000000",
            "payload": [
                "headers": [],
                "parts": [
                    ["mimeType": "text/calendar", "filename": ""]
                ]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.hasAttachments == true)
    }

    @Test("hasAttachments=false when only plain text body with attachmentId")
    func hasAttachmentsLargeBody() {
        // Regression guard: Gmail assigns attachmentId to LARGE body parts too.
        // The old rule (filename OR text/calendar) correctly excludes these;
        // the broken-briefly rule (filename OR attachmentId) over-reported.
        let json: [String: Any] = [
            "id": "m1", "internalDate": "1700000000000",
            "payload": [
                "headers": [],
                "parts": [
                    ["mimeType": "text/plain", "filename": "",
                     "body": ["attachmentId": "large-body-chunk-1", "size": 5_000_000]]
                ]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.hasAttachments == false)
    }

    @Test("hasAttachments walks nested parts")
    func hasAttachmentsNested() {
        let json: [String: Any] = [
            "id": "m1", "internalDate": "1700000000000",
            "payload": [
                "headers": [],
                "parts": [[
                    "mimeType": "multipart/mixed", "filename": "",
                    "parts": [[
                        "mimeType": "application/pdf", "filename": "deep.pdf"
                    ]]
                ]]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.hasAttachments == true)
    }

    @Test("hasAttachments=false for multipart without any attachment part")
    func hasAttachmentsInlineOnly() {
        let json: [String: Any] = [
            "id": "m1", "internalDate": "1700000000000",
            "payload": [
                "headers": [],
                "parts": [
                    ["mimeType": "multipart/alternative", "filename": "",
                     "parts": [
                        ["mimeType": "text/plain", "filename": ""],
                        ["mimeType": "text/html", "filename": ""]
                     ]]
                ]
            ]
        ]
        #expect(GmailParse.parseMessage(json)?.hasAttachments == false)
    }

    // MARK: - body extraction

    @Test("extractHTML walks nested multipart for text/html")
    func extractHTML() {
        let json: [String: Any] = [
            "payload": [
                "parts": [
                    ["mimeType": "text/plain", "body": ["data": base64URL("plain")]],
                    ["mimeType": "text/html", "body": ["data": base64URL("<p>html</p>")]]
                ]
            ]
        ]
        #expect(GmailParse.extractHTML(from: json) == "<p>html</p>")
    }

    @Test("extractTextPlain walks nested multipart for text/plain")
    func extractText() {
        let json: [String: Any] = [
            "payload": [
                "parts": [
                    ["mimeType": "text/html", "body": ["data": base64URL("<p>html</p>")]],
                    ["mimeType": "text/plain", "body": ["data": base64URL("plain body")]]
                ]
            ]
        ]
        #expect(GmailParse.extractTextPlain(from: json) == "plain body")
    }

    // MARK: - parseHistory

    @Test("parseHistory collects added + removed + label changes")
    func parseHistoryFull() {
        let json: [String: Any] = [
            "historyId": "100",
            "history": [[
                "messagesAdded": [[
                    "message": ["id": "m1", "labelIds": ["INBOX"]]
                ]],
                "messagesDeleted": [[
                    "message": ["id": "m2", "labelIds": []]
                ]],
                "labelsRemoved": [[
                    "message": ["id": "m3", "labelIds": ["UNREAD"]],
                    "labelIds": ["INBOX"]
                ]],
                "labelsAdded": [[
                    "message": ["id": "m4", "labelIds": ["INBOX", "UNREAD"]],
                    "labelIds": ["UNREAD"]
                ]]
            ]]
        ]
        let delta = GmailParse.parseHistory(json)
        #expect(delta.cursor == "100")
        #expect(delta.added.first?.providerMessageId == "m1")
        #expect(delta.added.first?.providerLabels == ["INBOX"])
        #expect(delta.removed.first?.providerMessageId == "m2")
        #expect(delta.labelsRemoved.first?.providerMessageId == "m3")
        #expect(delta.labelsRemoved.first?.labelIds == ["INBOX"])
        #expect(delta.labelsRemoved.first?.currentLabels == ["UNREAD"])
        #expect(delta.labelsAdded.first?.providerMessageId == "m4")
    }

    // MARK: - extractInlineImageRefs

    /// Parts with a non-empty Content-ID header AND `image/*` MIME type are
    /// surfaced as inline image candidates. Content-ID angle brackets and
    /// whitespace must be stripped so the `contentId` matches `cid:` refs in
    /// the HTML body verbatim (same normalization `BodyRenderer` does).
    @Test("extractInlineImageRefs returns image parts with Content-ID")
    func inlineImagesBasic() {
        let json: [String: Any] = [
            "id": "m1",
            "payload": [
                "mimeType": "multipart/related",
                "parts": [
                    [
                        "mimeType": "text/html",
                        "body": ["data": "PHA+aGk8L3A+"], // <p>hi</p>
                    ],
                    [
                        "mimeType": "image/png",
                        "headers": [["name": "Content-ID", "value": "<img001@host>"]],
                        "body": ["attachmentId": "att_abc", "size": 2048],
                    ],
                    [
                        "mimeType": "image/jpeg",
                        "headers": [["name": "Content-Id", "value": " <img002@host> "]],
                        "body": ["data": "aGVsbG8"], // small image returned inline
                    ],
                ],
            ],
        ]

        let images = GmailParse.extractInlineImageRefs(from: json)
        #expect(images.count == 2)
        #expect(images[0].contentId == "img001@host") // angle brackets stripped
        #expect(images[0].contentType == "image/png")
        #expect(images[0].attachmentId == "att_abc")
        #expect(images[0].inlineBase64URL == nil)
        #expect(images[1].contentId == "img002@host") // surrounding whitespace stripped
        #expect(images[1].inlineBase64URL == "aGVsbG8")
    }

    /// A part without a Content-ID header isn't a CID reference — skip.
    /// A non-image part with a Content-ID header is also not considered an
    /// inline image (matches `GmailProvider.extractInlineImageMeta` which
    /// gates on `image/*`).
    @Test("extractInlineImageRefs skips parts without Content-ID or non-image")
    func inlineImagesSkip() {
        let json: [String: Any] = [
            "id": "m1",
            "payload": [
                "parts": [
                    // image but no Content-ID
                    ["mimeType": "image/png", "body": ["attachmentId": "a"]],
                    // has Content-ID but not an image
                    ["mimeType": "application/pdf",
                     "headers": [["name": "Content-ID", "value": "<p@h>"]],
                     "body": ["attachmentId": "b"]],
                ],
            ],
        ]
        #expect(GmailParse.extractInlineImageRefs(from: json).isEmpty)
    }

    @Test("decodeBase64URLToData round-trips URL-safe base64 without padding")
    func decodeBase64URLToDataRoundTrip() {
        // Standard base64url, no padding. Encodes bytes [0xFB, 0xFF, 0xBF].
        let decoded = GmailParse.decodeBase64URLToData("-_-_")
        #expect(decoded == Data([0xFB, 0xFF, 0xBF]))
    }

    // MARK: - extractInlineImageRefs edge cases (91ae2b8 regression coverage)

    @Test("extractInlineImageRefs returns empty when payload is missing entirely")
    func inlineImagesNoPayload() {
        // Gmail messages.get with minimal projection (e.g. partial error) may
        // omit `payload`. Must not crash — return [].
        let json: [String: Any] = ["id": "m1"]
        #expect(GmailParse.extractInlineImageRefs(from: json).isEmpty)
    }

    @Test("extractInlineImageRefs skips parts with empty-string Content-ID after trimming")
    func inlineImagesEmptyContentId() {
        // An empty-after-trim Content-ID is unusable — `cid:` refs in the HTML
        // can't point to it. Must be skipped to avoid emitting a bogus entry.
        let json: [String: Any] = [
            "payload": [
                "parts": [
                    [
                        "mimeType": "image/png",
                        "headers": [["name": "Content-ID", "value": "<  >"]],  // brackets + whitespace
                        "body": ["attachmentId": "empty-cid"],
                    ],
                    [
                        "mimeType": "image/png",
                        "headers": [["name": "Content-ID", "value": ""]],  // empty header value
                        "body": ["attachmentId": "empty-cid-2"],
                    ],
                ],
            ],
        ]
        #expect(GmailParse.extractInlineImageRefs(from: json).isEmpty)
    }

    @Test("extractInlineImageRefs recurses into nested multipart sub-trees")
    func inlineImagesNestedParts() {
        // multipart/mixed → multipart/related → image/png. walkParts must
        // visit every branch, not just the top-level parts array.
        let json: [String: Any] = [
            "payload": [
                "mimeType": "multipart/mixed",
                "parts": [
                    [
                        "mimeType": "multipart/related",
                        "parts": [
                            [
                                "mimeType": "text/html",
                                "body": ["data": "PGh0bWw-"],
                            ],
                            [
                                "mimeType": "image/gif",
                                "headers": [["name": "Content-ID", "value": "<nested-gif@h>"]],
                                "body": ["attachmentId": "nested-att-id"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let images = GmailParse.extractInlineImageRefs(from: json)
        #expect(images.count == 1)
        #expect(images[0].contentId == "nested-gif@h")
        #expect(images[0].contentType == "image/gif")
        #expect(images[0].attachmentId == "nested-att-id")
    }

    @Test("extractInlineImageRefs matches uppercase Content-ID header and mixed-case mime type")
    func inlineImagesCaseInsensitive() {
        // RFC 822 allows any capitalization for header names. Gmail sometimes
        // emits "image/PNG" (depends on source email). Both must normalize.
        let json: [String: Any] = [
            "payload": [
                "parts": [
                    [
                        "mimeType": "image/PNG",
                        "headers": [["name": "CONTENT-ID", "value": "<case@h>"]],
                        "body": ["attachmentId": "att-case"],
                    ],
                ],
            ],
        ]
        let images = GmailParse.extractInlineImageRefs(from: json)
        #expect(images.count == 1)
        #expect(images[0].contentId == "case@h")
    }

}
