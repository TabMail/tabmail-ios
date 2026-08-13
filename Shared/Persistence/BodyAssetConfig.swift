/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Cross-module constants for the disk-backed asset store.
///
/// Only values that are referenced from outside `BodyAssetStore.swift` live here.
/// Store-internal tunables (hash length, hysteresis, batch sizes, sweep min-age,
/// thermal prune ratio) are `private static let` inside `BodyAssetStore.swift`.
///
/// Why this is the only public config:
/// - `appGroup` — referenced by `BodyAssetStore`, NSE clients, future ticket
///   to consolidate the 8+ `"group.ai.tabmail"` literals across the codebase.
/// - `urlScheme` — referenced by `BodyAssetSchemeHandler` (registered on the
///   WKWebViewConfiguration) and by `BodyAssetStore.absoluteURL(forAssetId:)`.
/// - `baseURL` — passed to `WKWebView.loadHTMLString(_:baseURL:)` purely so
///   the document has a non-nil origin (some CORS / mixed-content policies
///   require this). NOT used for URL resolution — HTML `src` refs are absolute.
/// - `defaultAttachmentsBudgetMB` — initial value for the user-visible
///   "Email Attachments Limit" picker in Settings.
enum BodyAssetConfig {
    /// App Group identifier shared by main app and NSE.
    /// Canonical for new code in this plan; existing 8+ literal sites across
    /// the codebase are NOT consolidated here (separate ticket).
    static let appGroup = "group.ai.tabmail"

    /// Custom URL scheme registered on `WKWebViewConfiguration` so HTML `<img src>`
    /// refs to `tabmail-asset://...` route through `BodyAssetSchemeHandler`,
    /// which serves bytes from the App Group container in-process.
    /// Required because WKWebView's sandboxed WebContent process cannot read
    /// the App Group container via `file://` baseURL — that approach works in
    /// Simulator and silently fails on device.
    static let urlScheme = "tabmail-asset"

    /// The fixed baseURL that `loadHTMLString` used **before P1c**, so the document had a
    /// non-nil origin. Never used for URL resolution — HTML `src` refs are absolute
    /// `tabmail-asset://` URLs that resolve via the registered scheme handler.
    ///
    /// ⚠️ **No production code loads under this URL any more.** Being FIXED is exactly what
    /// made it forgeable: a message document can simply name `tabmail-asset://asset/` in a
    /// `<meta http-equiv="refresh">`, producing a navigation action shape-identical to an
    /// app load. `RenderDocumentURL.url(nonce:)` replaced it with a per-load synthetic URL
    /// carrying 128 random bits in its path (ADR-IOS-076 decision 2). It is kept because
    /// the P1a/P1c canary measures the new behaviour AGAINST it — several assertions read
    /// "…and it is NOT this" — and because it still names the origin the nonce preserves.
    static let baseURL = URL(string: "\(urlScheme)://asset/")!

    /// UserDefaults key (in the App Group suite) backing the user-visible
    /// "Email Attachments Limit" picker. Both main app and NSE read via
    /// `UserDefaults(suiteName: BodyAssetConfig.appGroup)` so the value is
    /// consistent across targets.
    static let attachmentsBudgetMBKey = "attachmentsBudgetMB"

    /// Initial value for `attachmentsBudgetMBKey` if not already set.
    /// 1 GB matches the Settings picker tier.
    static let defaultAttachmentsBudgetMB = 1024

    /// Sentinel value meaning "no cap enforcement" — selectable from Settings picker.
    static let unlimitedBudgetMB = Int.max
}
