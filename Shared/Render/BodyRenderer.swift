/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Provider-agnostic body rendering. Takes raw ingredients from any provider
/// (Gmail REST JSON, Graph REST JSON, IMAP parsed message), resolves CIDs into
/// data URIs when an attachment fetcher is available, extracts plain text from
/// HTML via the shared EmailFilter parser, and produces a canonical RenderedBody.
///
/// Main app calls with an attachment fetcher → CIDs resolve to data URIs,
/// hasUnresolvedCIDs = false. NSE calls without a fetcher (24MB budget) → CIDs
/// stay as cid: refs, hasUnresolvedCIDs = true, main app re-renders on open.
///
/// ICS invitation HTML rendering is separate: callers that want to embed the
/// parsed invite as HTML pass an `icsRenderer` closure. NSE passes nil (ICS
/// text stays raw; render happens on first display in main app).
///
/// THIS IS THE SINGLE SOURCE OF TRUTH FOR BODY RENDERING — any change here
/// lands in both main app and NSE simultaneously, per the locked architecture.
enum BodyRenderer {
    /// Maximum bytes for inline CID images before we skip resolution (memory guard).
    static let maxInlineImageBytes = 1_000_000

    /// Maximum number of CID inline images we'll try to resolve per message.
    /// Bounds both the `message.cids.prefix(...)` loop and the staged
    /// `inlineImages` array size. Shared between main-app IMAP body fetch
    /// and NSE body fetch so they decode the same subset.
    static let maxInlineImages = 20

    /// Fetch an attachment body (IMAP MIME section / Gmail attachment ID / Graph attachment ID).
    /// Providers supply their own closure; NSE + batched flows can pass nil.
    typealias AttachmentFetcher = @Sendable (_ section: String, _ encoding: String?) async throws -> Data

    /// Render a parsed ICS text into HTML for inline display.
    /// Main app supplies a closure that calls ICSBuilder; NSE passes nil.
    typealias ICSRenderer = @Sendable (_ icsText: String) -> String?

    /// Persist an inline image's bytes to a backing store and return the
    /// `<img src>` URL string for the rendered HTML to reference. Returning
    /// nil falls back to a `data:` URI for that single image (so partial
    /// failures don't break the whole render).
    ///
    /// Both main-app and NSE render paths bind this via
    /// `BodyAssetStore.makeInlineImageWriter(forHeaderId:)` so behavior is
    /// identical across targets by construction. Compose preview / Eml
    /// preview / tooltip paths pass nil and get inline data URIs.
    typealias InlineImageWriter = @Sendable (_ image: InlineImageRef) -> String?

    /// Render raw ingredients into a canonical RenderedBody.
    /// - Parameters:
    ///   - ingredients: parsed inputs from any provider.
    ///   - attachmentFetcher: optional — when present, CIDs resolve to data URIs.
    ///   - icsRenderer: optional — when present AND ICS text is available, produces
    ///                  inline invite HTML appended to or replacing the body.
    ///   - inlineImageWriter: optional — when present, each inline image goes through
    ///                  the writer (typically `BodyAssetStore`) and the HTML uses
    ///                  whatever URL the writer returns. Falls back to data URI on nil.
    static func render(
        ingredients: RawBodyIngredients,
        attachmentFetcher: AttachmentFetcher? = nil,
        icsRenderer: ICSRenderer? = nil,
        inlineImageWriter: InlineImageWriter? = nil
    ) async -> RenderedBody {
        var resolvedHtml = ingredients.rawHTML
        var rawIcsText: String?
        var hasUnresolvedICS = false

        // 1. ICS calendar invite handling.
        //    Use pre-fetched icsData if available (IMAP single/batch path), otherwise
        //    fetch on demand (Gmail/Exchange always; IMAP batch when the pipelined
        //    part fetch dropped the calendar section). The on-demand fetch is a
        //    SEPARATE network round-trip that can fail transiently — do NOT swallow
        //    that with `try?`. Surface it as `hasUnresolvedICS` so the caller retries
        //    instead of caching an empty body (rule: never mark unfetched content as
        //    fetched). NSE passes no fetcher and defers ICS to the main app.
        if let icsAtt = ingredients.attachments.first(where: { $0.contentType.lowercased().contains("text/calendar") }) {
            var icsDataResolved: Data? = ingredients.icsData
            // This render "owns" ICS resolution only when there's no prefetch AND a
            // fetcher exists. NSE (no fetcher) intentionally leaves ICS unresolved
            // without flagging it — the main app re-renders on open.
            let mustResolveOnDemand = (ingredients.icsData == nil) && (attachmentFetcher != nil)
            if icsDataResolved == nil, let attachmentFetcher {
                do {
                    icsDataResolved = try await attachmentFetcher(icsAtt.section, icsAtt.encoding)
                } catch {
                    icsDataResolved = nil
                }
            }
            if let icsData = icsDataResolved, let icsText = String(data: icsData, encoding: .utf8), !icsText.isEmpty {
                rawIcsText = icsText
                if let icsRenderer, let inviteHtml = icsRenderer(icsText) {
                    let hasExistingBody = (ingredients.rawHTML?.isEmpty == false) || (ingredients.rawText?.isEmpty == false)
                    if hasExistingBody {
                        resolvedHtml = (resolvedHtml ?? "") +
                            "<div class=\"tm-ics-collapsible\" style=\"margin-top:12px;\">" + inviteHtml + "</div>"
                    } else {
                        resolvedHtml = inviteHtml
                    }
                }
            } else if mustResolveOnDemand {
                // We were responsible for fetching the ICS bytes but got nothing
                // usable this attempt → transient. Flag for retry; never persist
                // an attachment-only empty body for an invite.
                hasUnresolvedICS = true
            }
        }

        // 2. CID inline image resolution.
        //    Replace cid: refs with either an `inlineImageWriter`-returned URL
        //    (typically a `tabmail-asset://` ref backed by BodyAssetStore on
        //    disk) or, if no writer / writer returned nil, a base64 data URI.
        //    Any cid: that remains afterwards is "unresolved" — flagged so the
        //    merge path defers MessageBody persistence to the main app's
        //    re-fetch (which has access to the attachments).
        if var html = resolvedHtml, !ingredients.inlineImages.isEmpty {
            for inline in ingredients.inlineImages {
                guard inline.data.count <= maxInlineImageBytes else { continue }
                let resolvedSrc: String
                if let writer = inlineImageWriter, let written = writer(inline) {
                    resolvedSrc = written
                } else {
                    let base64 = inline.data.base64EncodedString()
                    resolvedSrc = "data:\(inline.contentType);base64,\(base64)"
                }
                html = html.replacingOccurrences(of: "cid:\(inline.contentId)", with: resolvedSrc, options: .caseInsensitive)
            }
            resolvedHtml = html
        }
        // A whitespace-only HTML part counts as "no HTML part" EVERYWHERE — CID
        // detection, plain-text extraction, AND display. Otherwise a real text/plain
        // sibling is lost: `extractPlainText` prefers a non-empty htmlBody, so a
        // whitespace-only `text/html` alternative (some mailing lists emit one) would
        // strip to "" and blank out snippet/FTS even though the displayed body comes
        // from the real text/plain. Collapsing to a single `effectiveHtml` keeps the
        // html/text decision consistent across all three uses.
        let effectiveHtml: String? = resolvedHtml.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }

        // Ground truth: are there STILL cid: refs in the rendered HTML?
        // NSE path: empty inlineImages → any cid: ref stays → flagged true.
        // Main-app path: inlineImages supplied → most cid: refs resolved;
        //   if any leftover (e.g. image exceeded maxInlineImageBytes), also true.
        let hasUnresolvedCIDs = effectiveHtml.map { containsCIDReference($0) } ?? false

        // 3. Plain text extraction — HTML wins when present (shared parser).
        let textContent = EmailFilter.extractPlainText(htmlBody: effectiveHtml, textBody: ingredients.rawText)

        // 4. Final DISPLAY html — BodyRenderer is the SINGLE body-conversion authority.
        //    When the message has an HTML part, use it. Otherwise convert the
        //    plain-text body to HTML HERE (exactly once) so every consumer — main app
        //    + NSE, all providers — receives a display-ready `htmlContent` and no
        //    downstream layer (e.g. MessageBody.create) ever re-converts it. That
        //    downstream re-conversion is what used to double-escape an HTML email
        //    that arrived in a text/plain slot; centralizing the single plain→HTML
        //    pass here removes that site entirely.
        //
        //    We deliberately do NOT try to guess whether a text/plain part "looks
        //    like HTML" and store it raw: that heuristic corrupts ordinary plaintext
        //    (code/notifications containing both `<X>` and `</Y>`). A genuinely
        //    HTML-bearing message keeps its real HTML part present via the IMAP
        //    dropped-part guard (IMAPProvider.fetchMessagesBatch) and the Gmail
        //    attachment-body fetch (GmailAPI.messageFull) — so we never reach this
        //    branch for a true HTML email. A message that truly has only text/plain
        //    is plain text and is escaped exactly once (correct, and safe).
        let displayHtml: String?
        if let html = effectiveHtml {
            displayHtml = html
        } else if let text = ingredients.rawText, !text.isEmpty {
            displayHtml = EmailFilter.plainTextToHTML(text)
        } else {
            displayHtml = nil
        }

        return RenderedBody(
            htmlContent: displayHtml,
            textContent: textContent,
            attachments: ingredients.attachments,
            icsText: rawIcsText,
            hasUnresolvedCIDs: hasUnresolvedCIDs,
            hasUnresolvedICS: hasUnresolvedICS
        )
    }

    /// True if HTML contains at least one `cid:` reference **as an attribute
    /// value** (src="cid:..." / href="cid:..." / background="cid:..."). A plain
    /// substring match would false-positive on `<script>`/`<style>` bodies,
    /// HTML comments, and quoted email threads — triggering unnecessary
    /// main-app re-fetches on every open for NSE-rendered messages.
    private static func containsCIDReference(_ html: String) -> Bool {
        // Attribute values can use single or double quotes; whitespace around
        // `=` is legal per HTML spec. Match all three common inline-image
        // attributes. Unquoted attributes (bare `src=cid:...`) are non-
        // conformant HTML and vanishingly rare — not worth the regex burden.
        let pattern = #"(?:src|href|background)\s*=\s*['"]\s*cid:"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            // Regex compile failure → fall back to substring scan (safe over-report).
            return html.range(of: "cid:", options: .caseInsensitive) != nil
        }
        let range = NSRange(html.startIndex..., in: html)
        return re.firstMatch(in: html, options: [], range: range) != nil
    }
}
