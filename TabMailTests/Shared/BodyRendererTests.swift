/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates the shared `BodyRenderer.render` produces the same output as the
/// pre-refactor `BodyFetchProcessor.renderBody` for every path the main app
/// exercises: CID resolution, ICS handling, plain-text extraction, attachment
/// metadata. Any regression would desync display across main app + NSE.
@Suite("Shared/Render BodyRenderer")
struct BodyRendererTests {

    // MARK: - containsCIDReference: attribute-only scan (no false positives)

    /// The CID scan must only match inline-image attribute values, not arbitrary
    /// text. Pre-fix the scan was a substring search which over-reported on any
    /// email mentioning "cid:" in quoted text, script blocks, or comments.
    /// False positives made every such NSE-rendered body re-fetch on open.

    @Test("hasUnresolvedCIDs=false when 'cid:' appears only in <style> block")
    func noFalsePositiveInStyleBlock() async {
        let ing = RawBodyIngredients(
            rawHTML: "<style>.thing { background: url('data:...'); /* no cid: here but cid: in comment */ }</style><p>Hi</p>",
            rawText: "Hi", attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == false)
    }

    @Test("hasUnresolvedCIDs=false when 'cid:' appears only inside HTML comment")
    func noFalsePositiveInComment() async {
        let ing = RawBodyIngredients(
            rawHTML: "<!-- Original message contained cid:img@old which we stripped --><p>Hi</p>",
            rawText: "Hi", attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == false)
    }

    @Test("hasUnresolvedCIDs=false when 'cid:' appears only in quoted plain text")
    func noFalsePositiveInQuotedText() async {
        let ing = RawBodyIngredients(
            rawHTML: "<blockquote>&gt; see cid:whatever as reference</blockquote><p>Reply</p>",
            rawText: "see cid:whatever as reference\nReply",
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == false)
    }

    @Test("hasUnresolvedCIDs=true when cid: is in src= attribute (single quotes)")
    func positiveSingleQuotes() async {
        let ing = RawBodyIngredients(
            rawHTML: "<img src='cid:img1@test'/>", rawText: nil,
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == true)
    }

    @Test("hasUnresolvedCIDs=true when cid: is in background= attribute")
    func positiveBackgroundAttr() async {
        let ing = RawBodyIngredients(
            rawHTML: "<table background=\"cid:bg@test\"><tr><td>Hi</td></tr></table>",
            rawText: "Hi", attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == true)
    }

    @Test("hasUnresolvedCIDs matches case-insensitively (CID: uppercase)")
    func caseInsensitiveMatch() async {
        let ing = RawBodyIngredients(
            rawHTML: "<img SRC=\"CID:IMG@TEST\"/>", rawText: nil,
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.hasUnresolvedCIDs == true)
    }


    // MARK: - Basic render paths

    @Test("render with plain HTML and text produces RenderedBody with both")
    func basicRender() async {
        let ing = RawBodyIngredients(
            rawHTML: "<p>Hello</p>", rawText: "Hello",
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent == "<p>Hello</p>")
        #expect(r.textContent == "Hello")
        #expect(r.attachments.isEmpty)
        #expect(r.icsText == nil)
        #expect(r.hasUnresolvedCIDs == false)
    }

    // MARK: - Display-HTML conversion (BodyRenderer is the single conversion authority)

    @Test("plain-text-only body is converted to display HTML once (escaped + wrapped)")
    func plainOnlyConvertedToHTML() async {
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: "A < B & C > D",
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        // htmlContent is display-ready: escaped exactly once + pre-wrap wrapper.
        #expect(r.htmlContent?.contains("&lt;") == true)
        #expect(r.htmlContent?.contains("&amp;") == true)
        #expect(r.htmlContent?.contains("&gt;") == true)
        #expect(r.htmlContent?.contains("white-space:pre-wrap") == true)
        // No double-escape.
        #expect(r.htmlContent?.contains("&amp;amp;") == false)
        // textContent stays the raw plain text (for FTS/snippet), NOT html-derived.
        #expect(r.textContent == "A < B & C > D")
    }

    @Test("HTML part present → htmlContent is the raw HTML, not re-converted")
    func htmlPartUsedRaw() async {
        let ing = RawBodyIngredients(
            rawHTML: "<p>Tom &amp; Jerry &nbsp;hi</p>", rawText: "Tom & Jerry hi",
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent == "<p>Tom &amp; Jerry &nbsp;hi</p>")
        #expect(r.htmlContent?.contains("&amp;amp;") == false)
    }

    @Test("whitespace-only HTML part + real text/plain → display AND textContent come from text/plain")
    func whitespaceOnlyHtmlFallsBackToPlain() async {
        // A whitespace-only text/html alternative must NOT blank out snippet/FTS:
        // textContent must come from the real text/plain sibling (the regression was
        // extractPlainText stripping the whitespace html to "" and ignoring rawText).
        let ing = RawBodyIngredients(
            rawHTML: "   \n\t  ", rawText: "real content here",
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent?.contains("real content here") == true)
        #expect(r.htmlContent?.contains("white-space:pre-wrap") == true)
        // The critical assertion: textContent is the real plain text, NOT empty.
        #expect(r.textContent == "real content here")
    }

    @Test("ICS-only invite: inviteHtml is the display html and the source of textContent")
    func icsOnlyInviteRendered() async {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Sync\nEND:VEVENT\nEND:VCALENDAR"
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar", section: "2", size: 100, encoding: nil)],
            inlineImages: [], icsData: ics.data(using: .utf8)
        )
        let r = await BodyRenderer.render(
            ingredients: ing,
            icsRenderer: { _ in "<div class=\"invite\">Meeting: Sync</div>" }
        )
        #expect(r.htmlContent == "<div class=\"invite\">Meeting: Sync</div>")
        // textContent extracted from the synthetic invite html (for snippet) — not empty.
        #expect(r.textContent?.contains("Meeting: Sync") == true)
        #expect(r.icsText == ics)
    }

    @Test("plaintext containing code/tags is ESCAPED, never stored raw (no FP corruption)")
    func plaintextWithCodeIsEscaped() async {
        // The false-positive class the heuristic approach would corrupt: ordinary
        // plaintext (code-review mail, git notifications) containing both `<X>` and a
        // `</Y>`. It must be escaped + shown literally, NOT interpreted as HTML.
        let cases = [
            "Use Map<String,Int> and close </ul> tags",
            "if a<b then write </div> at the end",
            "compare vector<int> with the </footer> marker",
        ]
        for text in cases {
            let ing = RawBodyIngredients(rawHTML: nil, rawText: text, attachments: [], inlineImages: [], icsData: nil)
            let r = await BodyRenderer.render(ingredients: ing)
            #expect(r.htmlContent?.contains("&lt;") == true)               // escaped
            #expect(r.htmlContent?.contains("white-space:pre-wrap") == true)
            #expect(r.htmlContent?.contains("<ul>") == false)              // not interpreted
            #expect(r.htmlContent?.contains("</footer>") == false)
        }
    }

    @Test("empty body → BOTH htmlContent and textContent nil")
    func emptyBodyNilHtml() async {
        let ing = RawBodyIngredients(rawHTML: nil, rawText: nil, attachments: [], inlineImages: [], icsData: nil)
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent == nil)
        #expect(r.textContent == nil)
    }

    @Test("whitespace-only HTML with NO text → fully nil, never a space-only sentinel body")
    func whitespaceOnlyHtmlNoText_yieldsNilNotSentinel() async {
        // Guards the CLAUDE.md "never store body=\" \" sentinel" rule end-to-end:
        // a whitespace-only html part with no text/plain must render to nil (→ the
        // empty-fetch flag path), NOT a " " htmlContent that hasBody/bodyComplete
        // would treat as real content and never re-fetch.
        for ws in ["   ", "\n\t ", "\u{00A0}"] {  // ascii ws, tabs/newlines, non-breaking space
            let ing = RawBodyIngredients(rawHTML: ws, rawText: nil, attachments: [], inlineImages: [], icsData: nil)
            let r = await BodyRenderer.render(ingredients: ing)
            #expect(r.htmlContent == nil)
            #expect(r.textContent == nil)
        }
    }

    @Test("plain-only textContent stays VERBATIM (not an HTML round-trip) — load-bearing for FTS/snippet")
    func plainTextContentStaysVerbatim() async {
        // textContent feeds snippet/FTS; for plain-only it must be the original bytes,
        // not htmlToPlainText(plainTextToHTML(x)) which would collapse whitespace/unicode.
        for text in [
            "Line 1\n\nLine 2\twith tab",
            "café résumé — naïve  (double space)",
            "5 < 10 & x > 3 in code",
        ] {
            let ing = RawBodyIngredients(rawHTML: nil, rawText: text, attachments: [], inlineImages: [], icsData: nil)
            let r = await BodyRenderer.render(ingredients: ing)
            #expect(r.textContent == text)
        }
    }

    @Test("render is idempotent for plain-text bodies (no UI/FTS churn from re-render)")
    func renderIdempotentForPlainText() async {
        // BodyRenderer now runs plainTextToHTML on every render (no storage-layer cache),
        // so re-rendering the same message MUST be deterministic — otherwise htmlContent
        // would differ between fetch and re-open, churning the body store / FTS / UI.
        for text in [
            "Hello\n\nWorld\twith tab",
            "café — naïve  résumé",
            "> quoted line\nreply text\n-- \nSig",
            "5 < 10 & x > 3 </tag>",
        ] {
            let ing = RawBodyIngredients(rawHTML: nil, rawText: text, attachments: [], inlineImages: [], icsData: nil)
            let r1 = await BodyRenderer.render(ingredients: ing)
            let r2 = await BodyRenderer.render(ingredients: ing)
            #expect(r1.htmlContent == r2.htmlContent)
            #expect(r1.textContent == r2.textContent)
            // And plainTextToHTML itself is idempotent input→output.
            #expect(EmailFilter.plainTextToHTML(text) == EmailFilter.plainTextToHTML(text))
        }
    }

    @Test("ICS renderer returning whitespace-only invite → no body stored (graceful, not blank-cached)")
    func icsRendererWhitespaceYieldsNoBody() async {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VEVENT\nEND:VCALENDAR"
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "x.ics", contentType: "text/calendar", section: "2", size: 10, encoding: nil)],
            inlineImages: [], icsData: ics.data(using: .utf8)
        )
        let r = await BodyRenderer.render(ingredients: ing, icsRenderer: { _ in "   \n  " })
        // Whitespace-only invite collapses to nil everywhere → no body to cache; the
        // persist path skips it and the main app refetches. icsText is still captured.
        #expect(r.htmlContent == nil)
        #expect(r.textContent == nil)
        #expect(r.icsText == ics)
    }

    @Test("render extracts plain text from HTML when rawText is nil")
    func htmlToTextFallback() async {
        let ing = RawBodyIngredients(
            rawHTML: "<p>Hello <b>world</b></p>", rawText: nil,
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.textContent?.contains("Hello") == true)
        #expect(r.textContent?.contains("world") == true)
        #expect(r.textContent?.contains("<") == false)  // tags stripped
    }

    @Test("render with no content returns all-nil body but not .empty sentinel")
    func emptyInput() async {
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent == nil)
        #expect(r.textContent == nil)
    }

    // MARK: - CID resolution

    @Test("render resolves inline CID images to data URIs when images are provided")
    func cidResolved() async {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])  // tiny JPEG header
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:img1@test\"/>",
            rawText: nil,
            attachments: [],
            inlineImages: [InlineImageRef(contentId: "img1@test", contentType: "image/jpeg", data: imageData)],
            icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent?.contains("data:image/jpeg;base64,") == true)
        #expect(r.htmlContent?.contains("cid:img1@test") == false)
        #expect(r.hasUnresolvedCIDs == false)
    }

    @Test("render flags hasUnresolvedCIDs=true when html has cid: refs but no fetcher")
    func unresolvedCIDsFlagged() async {
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:img1@test\"/>",
            rawText: nil, attachments: [], inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)  // no attachmentFetcher
        #expect(r.hasUnresolvedCIDs == true)
        #expect(r.htmlContent?.contains("cid:img1@test") == true)  // left as-is
    }

    @Test("render hasUnresolvedCIDs reflects actual cid: refs remaining, not the fetcher presence")
    func fetcherDoesNotMaskUnresolvedCIDs() async {
        // Post-round-5 correctness fix: hasUnresolvedCIDs is now "does the
        // HTML still contain cid: refs?" rather than "was a fetcher
        // supplied?". Supplying a fetcher without the corresponding inline
        // images doesn't actually resolve anything — the flag must honestly
        // report the render state so merge's persistence decision is correct.
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:img@test\"/>",
            rawText: nil, attachments: [], inlineImages: [], icsData: nil
        )
        let fetcher: BodyRenderer.AttachmentFetcher = { _, _ in Data() }
        let r = await BodyRenderer.render(ingredients: ing, attachmentFetcher: fetcher)
        #expect(r.hasUnresolvedCIDs == true, "fetcher supplied but no inline images actually used — cid: ref remains")
    }

    @Test("render hasUnresolvedCIDs flags leftover cid: when some images exceeded maxInlineImageBytes")
    func partialResolutionFlagsUnresolved() async {
        let small = Data([0xFF, 0xD8])  // tiny, will resolve
        let large = Data(count: BodyRenderer.maxInlineImageBytes + 1)  // too big, skipped
        let ing = RawBodyIngredients(
            rawHTML: #"<img src="cid:small@x"/><img src="cid:big@x"/>"#,
            rawText: nil, attachments: [],
            inlineImages: [
                InlineImageRef(contentId: "small@x", contentType: "image/jpeg", data: small),
                InlineImageRef(contentId: "big@x", contentType: "image/png", data: large),
            ],
            icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.htmlContent?.contains("data:image/jpeg;base64,") == true)
        #expect(r.htmlContent?.contains("cid:big@x") == true)
        // Leftover cid: big@x means the body is not fully rendered → main app must re-render.
        #expect(r.hasUnresolvedCIDs == true)
    }

    @Test("render skips CID images exceeding memory limit")
    func cidOverLimit() async {
        let large = Data(count: BodyRenderer.maxInlineImageBytes + 1)
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:big@test\"/>",
            rawText: nil, attachments: [],
            inlineImages: [InlineImageRef(contentId: "big@test", contentType: "image/png", data: large)],
            icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)
        // Image too large → left as cid:, data URI NOT inserted.
        #expect(r.htmlContent?.contains("cid:big@test") == true)
        #expect(r.htmlContent?.contains("data:image/png") == false)
    }

    // MARK: - ICS handling

    @Test("render preserves raw ICS text when icsData is provided")
    func icsRaw() async {
        let ics = "BEGIN:VCALENDAR\nEND:VCALENDAR"
        let icsData = Data(ics.utf8)
        let ing = RawBodyIngredients(
            rawHTML: "<p>see attached</p>", rawText: "see attached",
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "1", size: icsData.count, encoding: nil)],
            inlineImages: [], icsData: icsData
        )
        let r = await BodyRenderer.render(ingredients: ing)
        #expect(r.icsText == ics)
    }

    @Test("render applies icsRenderer when supplied and appends invite HTML to existing body")
    func icsRendererAppends() async {
        let ics = "BEGIN:VCALENDAR\nEND:VCALENDAR"
        let icsData = Data(ics.utf8)
        let ing = RawBodyIngredients(
            rawHTML: "<p>see attached</p>", rawText: "see attached",
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "1", size: icsData.count, encoding: nil)],
            inlineImages: [], icsData: icsData
        )
        let renderer: BodyRenderer.ICSRenderer = { _ in "<div>INVITE_HTML</div>" }
        let r = await BodyRenderer.render(ingredients: ing, icsRenderer: renderer)
        #expect(r.htmlContent?.contains("<p>see attached</p>") == true)
        #expect(r.htmlContent?.contains("INVITE_HTML") == true)
        #expect(r.htmlContent?.contains("tm-ics-collapsible") == true)
    }

    @Test("render icsRenderer replaces body entirely when no existing content")
    func icsRendererReplaces() async {
        let icsData = Data("BEGIN:VCALENDAR\nEND:VCALENDAR".utf8)
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "1", size: icsData.count, encoding: nil)],
            inlineImages: [], icsData: icsData
        )
        let renderer: BodyRenderer.ICSRenderer = { _ in "<div>INVITE</div>" }
        let r = await BodyRenderer.render(ingredients: ing, icsRenderer: renderer)
        // Replaces rather than appending the collapsible wrapper.
        #expect(r.htmlContent == "<div>INVITE</div>")
        // Prefetched ICS bytes were present — nothing to resolve on demand.
        #expect(r.hasUnresolvedICS == false)
    }

    // MARK: - ICS unresolved (transient on-demand fetch failure)

    private struct ICSFetchError: Error {}

    /// The race this fixes: an ICS-only invite (Gmail/Exchange, or IMAP batch
    /// that dropped the text/calendar section) has no prefetched ICS bytes, so
    /// the renderer must fetch them on demand. When that separate network fetch
    /// throws transiently, the renderer must surface `hasUnresolvedICS=true`
    /// (NOT swallow it) so the caller retries instead of caching an empty body
    /// that displays "This message has no content." forever.
    @Test("render flags hasUnresolvedICS=true when on-demand ICS fetch throws")
    func unresolvedICSWhenFetchThrows() async {
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "2", size: 100, encoding: "base64")],
            inlineImages: [], icsData: nil  // no prefetch → must resolve on demand
        )
        let throwingFetcher: BodyRenderer.AttachmentFetcher = { _, _ in throw ICSFetchError() }
        let renderer: BodyRenderer.ICSRenderer = { _ in "<div>INVITE</div>" }
        let r = await BodyRenderer.render(
            ingredients: ing, attachmentFetcher: throwingFetcher, icsRenderer: renderer
        )
        #expect(r.hasUnresolvedICS == true)
        #expect(r.icsText == nil)
        #expect(r.htmlContent == nil)  // nothing rendered — must NOT be cached as empty
    }

    /// When the on-demand fetch succeeds, the invite renders and the flag is false.
    @Test("render resolves ICS on demand and clears hasUnresolvedICS")
    func resolvedICSOnDemand() async {
        let icsData = Data("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Standup\nEND:VEVENT\nEND:VCALENDAR".utf8)
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "2", size: icsData.count, encoding: nil)],
            inlineImages: [], icsData: nil
        )
        let fetcher: BodyRenderer.AttachmentFetcher = { _, _ in icsData }
        let renderer: BodyRenderer.ICSRenderer = { _ in "<div>INVITE</div>" }
        let r = await BodyRenderer.render(
            ingredients: ing, attachmentFetcher: fetcher, icsRenderer: renderer
        )
        #expect(r.hasUnresolvedICS == false)
        #expect(r.htmlContent == "<div>INVITE</div>")
    }

    /// NSE path: no attachment fetcher is supplied — ICS rendering is intentionally
    /// deferred to the main app. An unresolved invite here must NOT be flagged
    /// (it isn't this render's job to resolve), so NSE never spuriously "retries".
    @Test("render does NOT flag hasUnresolvedICS when no fetcher supplied (NSE path)")
    func noFlagWithoutFetcher() async {
        let ing = RawBodyIngredients(
            rawHTML: nil, rawText: nil,
            attachments: [AttachmentRef(filename: "invite.ics", contentType: "text/calendar",
                                        section: "2", size: 100, encoding: nil)],
            inlineImages: [], icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing)  // no fetcher, no renderer (NSE)
        #expect(r.hasUnresolvedICS == false)
    }

    // MARK: - Parity bridge: BodyFetchProcessor.renderBody delegates here

    @Test("BodyFetchProcessor.renderBody produces MessageBody from shared renderer")
    func bodyFetchProcessorDelegation() async {
        let full = FullMessageInfo(
            header: MessageHeaderInfo(
                messageId: "m1", rfc822MessageId: nil, inReplyTo: nil, references: [],
                threadId: nil, subject: "s", from: "f", fromAddress: "f@ex",
                to: "", cc: "", bcc: "", replyTo: nil, date: Date(),
                snippet: "", isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil, userLabelIds: []
            ),
            htmlBody: "<p>Body</p>", textBody: "Body",
            attachments: [], inlineImages: [], icsData: nil
        )
        let (body, plainText, hasUnresolvedICS) = await BodyFetchProcessor.renderBody(headerId: "h1", fullMessage: full)
        #expect(body.htmlContent == "<p>Body</p>")
        #expect(plainText == "Body")
        #expect(hasUnresolvedICS == false)
    }

    // MARK: - inlineImageWriter (BodyAssetStore integration hook)

    /// When a writer is supplied AND returns a URL, the rendered HTML must
    /// reference that URL — not a `data:` URI. This is the contract that lets
    /// `MessageBody.htmlContent` shrink from multi-MB (base64) to a few hundred
    /// bytes (per-image `tabmail-asset://` ref).
    @Test("render uses writer-returned URL when writer is supplied")
    func writerSuppliesURL() async {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:img1@test\"/>",
            rawText: nil, attachments: [],
            inlineImages: [InlineImageRef(contentId: "img1@test", contentType: "image/png", data: imageData)],
            icsData: nil
        )
        let writer: BodyRenderer.InlineImageWriter = { _ in "tabmail-asset://aabbccddeeff0011/2233445566778899" }
        let r = await BodyRenderer.render(ingredients: ing, inlineImageWriter: writer)
        #expect(r.htmlContent?.contains("tabmail-asset://aabbccddeeff0011/2233445566778899") == true)
        #expect(r.htmlContent?.contains("data:image/png;base64,") == false)
        #expect(r.htmlContent?.contains("cid:img1@test") == false)
        #expect(r.hasUnresolvedCIDs == false)
    }

    /// When a writer is supplied but returns nil for an image (write failed),
    /// the renderer must fall back to a `data:` URI for THAT specific image.
    /// Other images in the same render should still get the writer-returned
    /// URL — partial failures don't poison the whole body.
    @Test("render falls back to data URI when writer returns nil for one image")
    func writerNilFallsBackToDataURI() async {
        let img1Data = Data([0x01, 0x02])
        let img2Data = Data([0x03, 0x04])
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:a@x\"/><img src=\"cid:b@y\"/>",
            rawText: nil, attachments: [],
            inlineImages: [
                InlineImageRef(contentId: "a@x", contentType: "image/png", data: img1Data),
                InlineImageRef(contentId: "b@y", contentType: "image/png", data: img2Data),
            ],
            icsData: nil
        )
        let writer: BodyRenderer.InlineImageWriter = { img in
            // Succeed for "a@x", fail for "b@y".
            img.contentId == "a@x" ? "tabmail-asset://hash/asset1" : nil
        }
        let r = await BodyRenderer.render(ingredients: ing, inlineImageWriter: writer)
        #expect(r.htmlContent?.contains("tabmail-asset://hash/asset1") == true)
        #expect(r.htmlContent?.contains("data:image/png;base64,") == true,
                "image b@y should fall back to data URI when writer returns nil")
        #expect(r.hasUnresolvedCIDs == false)
    }

    /// Without a writer (e.g. compose preview, Eml preview), behavior must be
    /// the legacy path: data URIs baked into HTML.
    @Test("render preserves legacy data-URI behavior when writer is nil")
    func noWriterUsesDataURI() async {
        let imageData = Data([0xFF, 0xD8])
        let ing = RawBodyIngredients(
            rawHTML: "<img src=\"cid:img1@test\"/>",
            rawText: nil, attachments: [],
            inlineImages: [InlineImageRef(contentId: "img1@test", contentType: "image/png", data: imageData)],
            icsData: nil
        )
        let r = await BodyRenderer.render(ingredients: ing, inlineImageWriter: nil)
        #expect(r.htmlContent?.contains("data:image/png;base64,") == true)
        #expect(r.htmlContent?.contains("tabmail-asset://") == false)
    }
}
