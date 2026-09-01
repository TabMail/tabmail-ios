/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

enum IMAPPartialFetchAssemblyError: Error, Equatable, Sendable {
    case invalidExpectedSize(Int)
    case invalidChunkSize(Int)
    case chunkExceedsRequest(requested: Int, received: Int)
    case prematureEnd(expected: Int, received: Int)
}

/// Pure helpers shared between the NSE's one-shot IMAP fetch and the main-app
/// IMAP pipeline. Extracted into Shared/ so they compile into BOTH the TabMail
/// and TabMailNotificationService targets, and are reachable from TabMailTests.
///
/// Every function here is deterministic on its inputs (no IO, no globals) —
/// cover the invariants with unit tests that construct `MessageInfo` / `Message`
/// directly rather than spinning up a FakeIMAPServer.
enum IMAPFetchMapping {

    /// Maximum bytes the IMAP response parser may buffer for a single response.
    ///
    /// Dense mailboxes return large SEARCH/FETCH responses (thousands of UIDs)
    /// and individual messages can have large bodies; the SwiftMail default of
    /// 1 MB overflows on these and throws `PayloadTooLargeError`, contaminating
    /// the NIO buffer (the connection must then be discarded). 4 MB clears the
    /// dense-folder case observed in production.
    ///
    /// Single source of truth for both IMAP entry points — main-app
    /// `IMAPProvider` and the NSE's one-shot `NSEIMAPConnection` pass this to
    /// `IMAPServer(host:port:useTLS:responseBufferLimit:)` so the two behave
    /// identically. History: this was a fork-local deviation (a hardcoded
    /// `bufferLimit: 4 * 1024 * 1024` in the SwiftMail fork). Upstream PR #179
    /// made the limit a constructor parameter, so the fork is now a pure
    /// upstream mirror and the value lives here at the call sites instead.
    static let responseBufferLimit = 4 * 1024 * 1024

    /// One MiB keeps each literal comfortably below the ordinary four-MiB
    /// response parser limit while avoiding excessive command overhead.
    static let bodyPartChunkSize = 1024 * 1024

    /// BODYSTRUCTURE is enough for normal attachment rows. Background body
    /// work downloads only render ingredients: visible text, calendar data, and
    /// CID images. File attachments are fetched on demand.
    static func isRequiredBodyPart(_ part: MessagePart) -> Bool {
        let contentType = part.contentType.lowercased()
        let disposition = part.disposition?.lowercased()
        if contentType.hasPrefix("text/calendar") { return true }
        if (contentType.hasPrefix("text/plain") || contentType.hasPrefix("text/html"))
            && !isNormalAttachment(part) {
            return true
        }
        return contentType.hasPrefix("image/")
            && part.contentId != nil
            && disposition != "attachment"
    }

    /// BODYSTRUCTURE flattens the children of `message/rfc822` parts into the
    /// same array. A child text or CID part therefore has no disposition of its
    /// own that reveals it belongs to an attached message. Exclude descendants
    /// of normal attached messages component-wise; explicitly inline embedded
    /// messages may still contribute render ingredients.
    static func requiredBodyPartIndices(in parts: [MessagePart]) -> [Int] {
        let attachedMessageSections = parts.compactMap { part -> [Int]? in
            guard part.contentType.lowercased().hasPrefix("message/rfc822"),
                  isNormalAttachment(part) else { return nil }
            return part.section.components
        }
        return parts.indices.filter { index in
            let components = parts[index].section.components
            let belongsToAttachedMessage = attachedMessageSections.contains { parent in
                components.count > parent.count
                    && Array(components.prefix(parent.count)) == parent
            }
            return !belongsToAttachedMessage && isRequiredBodyPart(parts[index])
        }
    }

    private static func isNormalAttachment(_ part: MessagePart) -> Bool {
        let disposition = part.disposition?.lowercased()
        let hasFilename = !(part.filename?.isEmpty ?? true)
        return disposition == "attachment" || (hasFilename && disposition != "inline")
    }

    /// Concatenate transfer-encoded bytes first; callers decode once afterwards.
    /// Decoding each chunk independently would corrupt base64 and quoted-printable
    /// sequences that straddle a chunk boundary.
    static func concatenateEncodedPart(
        expectedSize: Int?,
        chunkSize: Int = bodyPartChunkSize,
        fetchChunk: (_ offset: Int, _ count: Int) async throws -> Data
    ) async throws -> Data {
        guard chunkSize > 0 else {
            throw IMAPPartialFetchAssemblyError.invalidChunkSize(chunkSize)
        }
        if let expectedSize, expectedSize < 0 {
            throw IMAPPartialFetchAssemblyError.invalidExpectedSize(expectedSize)
        }
        if expectedSize == 0 { return Data() }

        var result = Data()
        if let expectedSize { result.reserveCapacity(min(expectedSize, chunkSize)) }
        var offset = 0

        while true {
            if let expectedSize, offset >= expectedSize { break }
            let requested = expectedSize.map { min(chunkSize, $0 - offset) } ?? chunkSize
            let chunk = try await fetchChunk(offset, requested)
            guard chunk.count <= requested else {
                throw IMAPPartialFetchAssemblyError.chunkExceedsRequest(
                    requested: requested, received: chunk.count
                )
            }

            if chunk.isEmpty {
                try validatePartialEnd(expectedSize: expectedSize, received: offset)
                break
            }

            result.append(chunk)
            offset += chunk.count
            // RFC partial FETCH count is a maximum. A short non-empty response
            // still advances the origin; it is not proof of end-of-section.
            // Known BODYSTRUCTURE sizes terminate at the loop guard. Unknown-
            // size callers terminate only when the server returns an empty range.
        }
        return result
    }

    private static func validatePartialEnd(expectedSize: Int?, received: Int) throws {
        guard let expectedSize, received != expectedSize else { return }
        throw IMAPPartialFetchAssemblyError.prematureEnd(
            expected: expectedSize,
            received: received
        )
    }

    static func isDeterministicPartialFetchFailure(_ error: Error) -> Bool {
        if let partialError = error as? PartialFetchError {
            switch partialError {
                case .messageNotFound, .invalidRange:
                    return false
                default:
                    return true
            }
        }
        return error is IMAPPartialFetchAssemblyError
            || String(describing: error).contains("PayloadTooLargeError")
    }

    /// Build the `messageId` string used as `MessageHeader.messageId`.
    ///
    /// MUST match `IMAPProvider.buildMessageHeaderInfo`'s format so rows the
    /// NSE inserts (optimistic pre-sync header) align with rows the main-app
    /// sync produces: same `accountId` + same `messageId` → merge lookup hits
    /// the existing row.
    ///
    /// History: before the 2026-04-19 fix the NSE stored the RFC 5322
    /// Message-ID (`<local@domain>`) here, which never matched sync's UID
    /// format — every iCloud push produced a duplicate inbox entry.
    static func messageIdString(from info: MessageInfo) -> String {
        if let uid = info.uid {
            return "\(uid.value)"
        }
        if let mid = info.messageId {
            return "\(mid.localPart)@\(mid.domain)"
        }
        return "\(info.sequenceNumber.value)"
    }

    /// Normalized (bare, no angle brackets) RFC 5322 Message-ID for use as
    /// `rfc822MessageId` / AI cache key / dedup across devices.
    ///
    /// `MessageID(localPart:domain:)` is already structured so the string
    /// interpolation produces a bare form, but we run it through
    /// `EmailFilter.normalizeMessageId` for belt-and-suspenders parity with
    /// every other write site that normalizes before storage.
    static func rfc822MessageId(from info: MessageInfo) -> String? {
        info.messageId.map { EmailFilter.normalizeMessageId("\($0.localPart)@\($0.domain)") }
    }

    /// Bare `In-Reply-To` (local@domain) normalized the same way as
    /// `rfc822MessageId` — matches `IMAPProvider.buildMessageHeaderInfo`.
    static func inReplyTo(from info: MessageInfo) -> String? {
        info.inReplyTo.map { EmailFilter.normalizeMessageId("\($0.localPart)@\($0.domain)") }
    }

    /// Bare `References` chain — each entry in `local@domain` form.
    static func references(from info: MessageInfo) -> [String] {
        info.references?.map { "\($0.localPart)@\($0.domain)" } ?? []
    }

    /// `hasAttachments` computed from `MessageInfo.parts` — matches
    /// `IMAPProvider.buildMessageHeaderInfo`'s inline predicate.
    static func hasAttachments(from info: MessageInfo) -> Bool {
        info.parts.contains { part in
            let ct = part.contentType.lowercased()
            let disposition = part.disposition?.lowercased()
            let hasFilename = !(part.filename?.isEmpty ?? true)
            let isExplicitAttachment = disposition == "attachment"
            let hasFileNotInline = hasFilename && disposition != "inline"
            let isCalendar = ct.hasPrefix("text/calendar")
            return isExplicitAttachment || hasFileNotInline || isCalendar
        }
    }

    /// Provider-label list — extracts non-`tm_*`, non-excluded IMAP custom
    /// keywords. Matches the user-label extraction in
    /// `IMAPProvider.buildMessageHeaderInfo`. Returns lowercase keywords —
    /// UI uppercasing happens at display time.
    ///
    /// NOTE: on the NSE side we stage the RAW custom keyword list without
    /// exclusion filtering so the merge can resolve `tm_*` to ActionTag if
    /// another device set it, then filter the remainder via
    /// `UserLabelStore.isExcludedKeyword` the same way sync does. The
    /// exclusion check isn't available in the NSE target without extra
    /// plumbing — see callers for how they handle that.
    static func customKeywords(from info: MessageInfo) -> [String] {
        var out: [String] = []
        for flag in info.flags {
            if case .custom(let keyword) = flag {
                out.append(keyword)
            }
        }
        return out
    }

    // MARK: - Body ingredient extraction (shared with main-app IMAPProvider)

    /// Attachment metadata extraction for a fetched message — parity with
    /// `IMAPProvider.buildFullMessageInfo`'s attachment loop (top-level parts
    /// classified as attachments) PLUS its nested-inside-`.eml` pass that
    /// parses opaque file-uploaded `.eml` attachments to surface what's inside.
    ///
    /// Returns `AttachmentRef`s (the render-time type; main-app maps these
    /// to `AttachmentInfo` which adds `parentEmlSection` for tap-time
    /// fetching — a concern the renderer doesn't need).
    static func extractAttachments(info: MessageInfo, message: Message) -> [AttachmentRef] {
        var out: [AttachmentRef] = info.parts.compactMap { part in
            let ct = part.contentType.lowercased()
            let disposition = part.disposition?.lowercased()
            let hasFilename = part.filename != nil
            let isExplicitAttachment = disposition == "attachment"
            let hasFileNotInline = hasFilename && disposition != "inline"
            // text/calendar (ICS invites) are attachments even without explicit
            // disposition or filename — Outlook often omits both.
            let isCalendar = ct.hasPrefix("text/calendar")
            let isAttachment = isExplicitAttachment || hasFileNotInline || isCalendar
            guard isAttachment else { return nil }
            let filename = part.filename ?? part.suggestedFilename
            return AttachmentRef(
                filename: filename,
                contentType: part.contentType,
                section: part.section.description,
                size: part.size ?? part.data?.count ?? 0,
                encoding: part.encoding
            )
        }

        // Surface attachments nested INSIDE file-uploaded `.eml` parts.
        // Server-parsed `message/rfc822` parts already have their children
        // visible at the top level (BODYSTRUCTURE exposes them at numeric
        // sub-sections like `2.1`, caught above). File-uploaded `.eml`s are
        // opaque blobs server-side, and their nested attachments are available
        // only when a caller supplied the parent bytes on demand. `encoding` on each nested
        // entry is set to the PARENT's transfer encoding so tap-time
        // resolution can re-fetch parent bytes with the right encoding.
        for part in message.parts where EmlParsing.isEmlFilename(part.filename)
            && !part.contentType.lowercased().hasPrefix("message/rfc822") {
            guard let raw = part.decodedData() ?? part.data,
                  let parsed = EmlParsing.parse(rawBytes: raw) else { continue }
            let parentSection = part.section.description
            let parentEncoding = part.encoding
            for (index, meta) in parsed.nested.enumerated() {
                out.append(AttachmentRef(
                    filename: meta.filename,
                    contentType: meta.contentType,
                    section: EmlParsing.nestedSection(parent: parentSection, index: index),
                    size: meta.size,
                    encoding: parentEncoding
                ))
            }
        }
        return out
    }

    /// Inline image extraction from a fetched message. Mirrors
    /// `IMAPProvider.buildFullMessageInfo`'s CID loop — uses
    /// `message.cids.prefix(maxInlineImages)` with `decodedData()` to
    /// handle base64/quoted-printable transfer encoding before the
    /// renderer re-encodes as a `data:` URI. Strips angle brackets +
    /// whitespace from the Content-ID.
    static func extractInlineImages(message: Message, maxInlineImages: Int) -> [InlineImageRef] {
        message.cids.prefix(maxInlineImages).compactMap { part in
            guard let rawId = part.contentId, let data = part.decodedData() else { return nil }
            let contentId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentId.isEmpty else { return nil }
            return InlineImageRef(contentId: contentId, contentType: part.contentType, data: data)
        }
    }

    /// First `text/calendar` part's decoded bytes, if any. Mirrors
    /// `IMAPProvider.buildFullMessageInfo`'s ICS-data extraction — lets
    /// the renderer skip calling `attachmentFetcher` for invite bodies
    /// when we already have the bytes in memory from the batch fetch.
    static func extractICSData(message: Message) -> Data? {
        message.parts.first(where: {
            $0.contentType.lowercased().contains("text/calendar")
        })?.decodedData()
    }

    /// Convert a fetched IMAP `(info, message)` pair into the canonical
    /// `RawBodyIngredients` consumed by `BodyRenderer.render`.
    ///
    /// Single source of truth for IMAP → ingredients shape: both
    /// main-app `IMAPProvider.buildFullMessageInfo` and NSE
    /// `NSEIMAPConnection` route through this function, so any drift
    /// between the two targets is impossible by construction.
    ///
    /// `maxInlineImages` bounds the CID loop; defaults to the shared
    /// `BodyRenderer.maxInlineImages` so both targets pick the same
    /// subset without plumbing the constant through.
    static func buildRawBodyIngredients(
        info: MessageInfo,
        message: Message,
        maxInlineImages: Int = BodyRenderer.maxInlineImages
    ) -> RawBodyIngredients {
        let htmlBody = renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        let textBody = renderBodyWithEmbeddedHeaders(message: message, type: "text/plain")
        return RawBodyIngredients(
            rawHTML: htmlBody,
            rawText: textBody,
            attachments: extractAttachments(info: info, message: message),
            inlineImages: extractInlineImages(message: message, maxInlineImages: maxInlineImages),
            icsData: extractICSData(message: message)
        )
    }

    /// Section descriptions of the TOP-LEVEL `text/html` body parts in BODYSTRUCTURE
    /// (`info.parts`) — those NOT nested inside an attached `message/rfc822`. Checks
    /// structure only, mirroring the rfc822 section-prefix nesting rule used by
    /// `renderBodyWithEmbeddedHeaders`.
    static func topLevelHTMLSections(info: MessageInfo) -> [String] {
        let rfc822Sections: [[Int]] = info.parts.compactMap {
            $0.contentType.lowercased().hasPrefix("message/rfc822") ? $0.section.components : nil
        }
        return info.parts.compactMap { part in
            guard isRequiredBodyPart(part),
                  part.contentType.lowercased().hasPrefix("text/html") else { return nil }
            let comp = part.section.components
            let nested = rfc822Sections.contains { rfc in
                comp.count > rfc.count && Array(comp.prefix(rfc.count)) == rfc
            }
            return nested ? nil : part.section.description
        }
    }

    /// True when BODYSTRUCTURE lists a top-level `text/html` body part. (Convenience
    /// over `topLevelHTMLSections`.)
    static func hasTopLevelHTMLBodyPart(info: MessageInfo) -> Bool {
        return !topLevelHTMLSections(info: info).isEmpty
    }

    /// True when a top-level `text/html` section listed in BODYSTRUCTURE was NOT
    /// returned by the pipelined part fetch (its section is absent from
    /// `fetchedSections`) — i.e. the HTML content was silently DROPPED under NIO
    /// buffer pressure. The batch fetch path throws on this so the message retries
    /// rather than being cached as an HTML email rendered as plaintext.
    ///
    /// Crucially this distinguishes a true DROP (section absent) from a
    /// GENUINELY-EMPTY top-level `text/html` part (section present but empty/
    /// whitespace — some mailing-list systems emit one alongside a real
    /// `text/plain`). The latter must NOT throw, or the batch would churn that
    /// message forever; it renders as plain text and is cached normally.
    static func hasDroppedTopLevelHTMLSection(info: MessageInfo, fetchedSections: Set<String>) -> Bool {
        return topLevelHTMLSections(info: info).contains { !fetchedSections.contains($0) }
    }

    /// Render a fetched `(info, message)` pair into our canonical
    /// `RenderedBody` via the shared `BodyRenderer` — the SAME pipeline
    /// `BodyFetchProcessor.renderBody` runs for main-app IMAP body
    /// fetches. Guarantees byte-identical output between main-app and
    /// NSE paths: both build `RawBodyIngredients` via
    /// `buildRawBodyIngredients` and hand them to `BodyRenderer.render`
    /// with the same `icsRenderer` closure (`ICSBuilder`-backed).
    ///
    /// NSE contract (see `BodyRenderer.swift:8-10`): no attachment
    /// fetcher, so remaining `cid:` refs without a matching inline
    /// image stay unresolved and `hasUnresolvedCIDs = true`. Main-app
    /// merge leaves `bodyComplete=0` in that case so the body queue
    /// re-renders on first user open with a real attachment fetcher.
    ///
    /// History: before the 2026-04-19 fix NSE used raw HTML as
    /// `textContent` when `textBody` was nil, poisoning MessageBody,
    /// FTS, and snippet computation. Before the 2026-04-21 fix NSE
    /// applied a 4KB cap, silently truncating every pushed IMAP
    /// message. Before this commit NSE hand-rolled a simplified path
    /// that skipped attachments / inline images / ICS entirely — so
    /// pushed messages lost ICS invite rendering, inline images
    /// weren't resolved, and the output drifted from main-app render.
    static func renderBody(
        info: MessageInfo,
        message: Message,
        contentKey: ContentKey? = nil,
        maxInlineImages: Int = BodyRenderer.maxInlineImages
    ) async -> RenderedBody {
        let ingredients = buildRawBodyIngredients(
            info: info, message: message, maxInlineImages: maxInlineImages
        )
        // ICS renderer mirrors `BodyFetchProcessor.renderBody` — when an
        // invite is present, `BodyRenderer` appends the built invite HTML
        // to the body. Both targets now invoke the same `ICSBuilder`
        // (moved to `Shared/ICS/`), so rendered output is byte-identical.
        let icsRenderer: BodyRenderer.ICSRenderer = { icsText in
            guard let invite = ICSBuilder.parseIncoming(icsText) else { return nil }
            return ICSBuilder.buildIncomingInviteBody(invite)
        }
        // When `contentKey` is supplied, route inline images through
        // `BodyAssetStore` so they land on disk and the rendered HTML
        // references `tabmail-asset://` URLs rather than baked-in data URIs.
        // Both main-app (`BodyFetchProcessor.renderBody`) and NSE
        // (`NSEIMAPConnection.fetchRenderedBody`) callers pass the content key
        // — so the disk-asset path is exercised identically by both targets,
        // by construction. Compose preview / Eml preview pass nil → data URIs.
        let inlineImageWriter: BodyRenderer.InlineImageWriter? =
            contentKey.map { BodyAssetStore.makeInlineImageWriter(forContentKey: $0) }
        return await BodyRenderer.render(
            ingredients: ingredients,
            attachmentFetcher: nil,
            icsRenderer: icsRenderer,
            inlineImageWriter: inlineImageWriter
        )
    }

    // MARK: - Embedded Message Header Rendering (moved from IMAPProvider)

    /// Render body content with TB-style header blocks before nested message/rfc822 content.
    /// Uses component-level section prefix matching to detect nesting (avoids false positives
    /// like section "11.2" matching rfc822 at section "1").
    ///
    /// Special case: when rendering HTML and the main message body is text/plain only
    /// (no top-level text/html parts) but embedded .eml parts have HTML bodies, the
    /// main message's text/plain is converted to HTML and prepended. Without this,
    /// `MessageBody.create` would pick the .eml-only HTML and the main body would be
    /// invisible to the user.
    static func renderBodyWithEmbeddedHeaders(message: Message, type: String) -> String? {
        let isHtml = type == "text/html"
        let matching = message.bodies.filter { $0.contentType.lowercased().hasPrefix(type) }

        let rfc822Parts = message.parts.filter {
            $0.contentType.lowercased().hasPrefix("message/rfc822") && $0.embeddedMessageInfo != nil
        }

        // File-uploaded `.eml`s (typically `application/octet-stream` with a
        // `.eml` filename) — BODYSTRUCTURE doesn't expose them as rfc822, so
        // we parse the raw bytes ourselves via SwiftMail's EMLParser.
        let emlFileParts = message.parts.filter { part in
            EmlParsing.isEmlFilename(part.filename)
                && !part.contentType.lowercased().hasPrefix("message/rfc822")
                && part.data != nil
        }

        guard !matching.isEmpty || !emlFileParts.isEmpty else { return nil }

        // Helper: is `body` nested inside `rfc822` (section prefix match)?
        func isNested(_ body: MessagePart, inside rfc822: MessagePart) -> Bool {
            let bodyComp = body.section.components
            let rfcComp = rfc822.section.components
            return bodyComp.count > rfcComp.count
                && Array(bodyComp.prefix(rfcComp.count)) == rfcComp
        }

        // Plain text mode: keep the historical flat interleaving (no CSS to apply,
        // no preview sheet — users read plain text inline).
        if !isHtml {
            var result = ""
            var insertedHeaders = Set<String>()
            for bodyPart in matching {
                for rfc822 in rfc822Parts where isNested(bodyPart, inside: rfc822) {
                    let key = rfc822.section.description
                    if !insertedHeaders.contains(key), let info = rfc822.embeddedMessageInfo {
                        insertedHeaders.insert(key)
                        let envelope = EmlMarker.Envelope(
                            subject: info.subject, from: info.from, date: info.date,
                            to: info.to, cc: info.cc
                        )
                        result += EmlMarker.embeddedHeadersPlainText(envelope: envelope, filename: rfc822.filename)
                    }
                }
                if let content = bodyPart.textContent {
                    result += content
                }
            }
            // Append plain-text headers for file-uploaded `.eml`s too — FTS
            // picks these up and search works across uploaded-eml content.
            for part in emlFileParts {
                guard let raw = part.decodedData() ?? part.data,
                      let parsed = EmlParsing.parse(rawBytes: raw) else { continue }
                result += EmlMarker.embeddedHeadersPlainText(envelope: parsed.envelope, filename: part.filename)
                // Append plain text equivalent of the body so FTS indexes it.
                if !parsed.bodyHtml.isEmpty {
                    result += EmailFilter.htmlToPlainText(parsed.bodyHtml)
                }
            }
            return result.isEmpty ? nil : result
        }

        // HTML mode: top-level parts render directly; nested .eml parts become
        // `<div class="tm-eml-section">` blocks via the shared `EmlMarker.build`
        // (same shape as Gmail/Exchange) — hidden in main view, shown in
        // EmlAttachmentPreview sheet, still indexed by FTS.
        let topLevelHtml = matching.filter { bodyPart in
            !rfc822Parts.contains { isNested(bodyPart, inside: $0) }
        }

        var topLevelContent = ""
        for part in topLevelHtml {
            if let content = part.textContent {
                topLevelContent += content
            }
        }

        // Fallback: when there are rfc822 parts but no top-level HTML, promote the
        // main message's text/plain to HTML so the primary body is visible.
        if topLevelContent.isEmpty && !rfc822Parts.isEmpty {
            let topLevelText = message.bodies.filter { part in
                guard part.contentType.lowercased().hasPrefix("text/plain") else { return false }
                return !rfc822Parts.contains { isNested(part, inside: $0) }
            }
            for textPart in topLevelText {
                if let content = textPart.textContent, !content.isEmpty {
                    topLevelContent += EmailFilter.plainTextToHTML(content)
                    // Debug-gated per global rule 12. `#if DEBUG` rather than
                    // `DebugModeManager.isLoggingEnabled()` because `Shared/` also
                    // compiles into the notification-service extension, where
                    // `DebugModeManager` does not exist — the same constraint
                    // `Shared/Persistence/BodyAssetStore.swift` documents at the
                    // `#if DEBUG` prints in its `catch` arms. Nothing
                    // sender-authored is interpolated here.
                    #if DEBUG
                    print("[EmlRender] Prepending main message text/plain (len=\(content.count)) as HTML for .eml-only HTML message")
                    #endif
                }
            }
        }

        var result = topLevelContent

        // Emit one marker per rfc822 part that has matching HTML bodies nested
        // inside it. Delegates to `EmlMarker.build` for the HTML shape so IMAP,
        // Gmail, and Exchange all produce identical marker output.
        for rfc822 in rfc822Parts {
            guard let info = rfc822.embeddedMessageInfo else { continue }
            let nestedBodies = matching.filter { isNested($0, inside: rfc822) }
            guard !nestedBodies.isEmpty else { continue }

            let filename = rfc822.filename ?? "attached-email.eml"
            let sectionId = rfc822.section.description
            // Concatenate all nested bodies (usually exactly one); extractBodyContent
            // strips document chrome and wraps in .tm-email-body.
            var nestedBodyHtml = ""
            for bodyPart in nestedBodies {
                if let content = bodyPart.textContent {
                    nestedBodyHtml += content
                }
            }
            let envelope = EmlMarker.Envelope(
                subject: info.subject,
                from: info.from,
                date: info.date,
                to: info.to,
                cc: info.cc
            )
            result += EmlMarker.build(
                filename: filename,
                partSection: sectionId,
                envelope: envelope,
                bodyHtml: nestedBodyHtml
            )
        }

        // Emit markers for file-uploaded `.eml`s (non-rfc822 BODYSTRUCTURE).
        // Raw bytes get parsed here via SwiftMail's EMLParser; envelope + body
        // are both available without any extra network round-trip because
        // `fetchAllMessageParts` already fetched `part.data` for every part.
        for part in emlFileParts {
            guard let raw = part.decodedData() ?? part.data,
                  let parsed = EmlParsing.parse(rawBytes: raw) else {
                // Debug-gated per global rule 12, by `#if DEBUG` for the reason
                // above — this file compiles into the NSE target too.
                //
                // ⚠️ KNOWN RESIDUAL, recorded rather than fixed: `part.filename` is
                // the sender's raw MIME `filename` parameter and it is NOT escaped
                // here, so in a DEBUG build a CR/LF/U+2028 in it still forges an
                // extra diagnostic line. The escaper is
                // `DebugModeManager.escapedForLogLine`, which lives in the app
                // target and is not visible from `Shared/`. Closing it means moving
                // the escaper into `Shared/` — a wider change than this fix, and not
                // taken here. Release builds no longer emit the line at all, which
                // is the half that was reaching users.
                //
                // `RenderPathLogSinkTests` does NOT cover this file, for the same
                // visibility reason; its doc comment says so.
                #if DEBUG
                print("[EmlRender] IMAP: could not parse \(part.filename ?? "?.eml") as RFC 822 — rendering as plain attachment")
                #endif
                continue
            }
            let filename = part.filename ?? "attached-email.eml"
            result += EmlMarker.build(
                filename: filename,
                partSection: part.section.description,
                envelope: parsed.envelope,
                bodyHtml: parsed.bodyHtml
            )
        }

        return result.isEmpty ? nil : result
    }

    /// Given a part's section components and the list of all rfc822 section
    /// component paths in the message, return the nearest enclosing rfc822
    /// section as a dot-joined string (e.g. `"2"` or `"1.3"`), or `nil` if
    /// `partComponents` is at top level.
    ///
    /// "Nearest" = longest matching prefix, which matters for `.eml`-within-`.eml`:
    /// a part at `2.3.2` with rfc822s at `2` and `2.3` returns `"2.3"`.
    ///
    /// Prefix matching is component-wise (not string), so `[1, 2]` is NOT a
    /// prefix of `[1, 20]`.
    static func parentEmlSection(for partComponents: [Int], rfc822Sections: [[Int]]) -> String? {
        let enclosing = rfc822Sections
            .filter { rfcComp in
                partComponents.count > rfcComp.count
                    && Array(partComponents.prefix(rfcComp.count)) == rfcComp
            }
            .max(by: { $0.count < $1.count })
        return enclosing.map { $0.map(String.init).joined(separator: ".") }
    }
}
