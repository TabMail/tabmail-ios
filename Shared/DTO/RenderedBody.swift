/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Output of `BodyRenderer.render` — the single source of truth for message body
/// shape across main app and NSE. Persisted to `MessageBody` (main app) or
/// `nse_processed_message` columns (NSE).
struct RenderedBody: Sendable {
    /// Rendered HTML. CIDs may remain unresolved (NSE path — no attachment fetcher).
    let htmlContent: String?
    /// Plain text — always populated when there is content (extracted from HTML if needed).
    let textContent: String?
    let attachments: [AttachmentRef]
    /// Raw ICS text (when a text/calendar part is present). Parsed lazily on display.
    let icsText: String?
    /// True when HTML contains `cid:` refs but no attachment fetcher was supplied.
    /// Main app merge leaves bodyComplete=false on NSE-rendered rows so the main
    /// app's body queue re-renders on first user open with a fetcher.
    let hasUnresolvedCIDs: Bool

    /// True when the message has a `text/calendar` (invite) part that this render
    /// was responsible for resolving — i.e. an attachment fetcher was supplied and
    /// there were no pre-fetched ICS bytes — but the on-demand fetch yielded no
    /// usable ICS data this attempt. That on-demand fetch is a SEPARATE network
    /// round-trip (Gmail/Exchange attachment API, or IMAP batch when the pipelined
    /// part fetch dropped the calendar section) and can fail transiently.
    ///
    /// Callers MUST treat this as retryable and NOT persist an empty/attachment-only
    /// body — otherwise the unfetched invite is masked as "This message has no
    /// content." until the user manually reloads. (NSE supplies no fetcher and
    /// intentionally defers ICS rendering to the main app, so it never sets this.)
    let hasUnresolvedICS: Bool

    /// Empty body (confirmed no content). Used by both main app and NSE on verified-empty fetches.
    static let empty = RenderedBody(
        htmlContent: nil, textContent: nil, attachments: [],
        icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
    )
}

/// Ingredients fed to `BodyRenderer.render`. Provider-specific parsers produce this.
/// Keeps rendering logic completely independent of which provider supplied the bytes.
struct RawBodyIngredients: Sendable {
    let rawHTML: String?
    let rawText: String?
    let attachments: [AttachmentRef]
    let inlineImages: [InlineImageRef]
    /// Pre-fetched ICS bytes (IMAP batch fetch). When present, renderer skips calling
    /// the attachment fetcher for text/calendar parts.
    let icsData: Data?
}
