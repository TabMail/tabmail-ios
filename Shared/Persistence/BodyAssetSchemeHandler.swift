/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit

/// `WKURLSchemeHandler` for the `tabmail-asset://` scheme. Serves bytes from
/// `BodyAssetStore` in-process so WKWebView's sandboxed WebContent process can
/// render `<img src>` refs without requiring `file://` access to the App Group
/// container (which doesn't work on device).
///
/// Lives in `Shared/` so both targets can use it. NSE doesn't render HTML so it
/// never instantiates the handler — but the type compiles into the NSE bundle
/// at near-zero cost (one class definition, no static state).
///
/// **Does NOT bump LRU.** LRU bumps fire only on user tap
/// (`MessageDetailViewModel.loadBody()` and the attachment tap-time fetcher).
/// Rendering an already-cached message's images via the scheme handler is not
/// considered "tapping" the message — only the explicit message open is.
///
/// Returns `Cache-Control: no-store` so WKWebView always invokes the handler
/// (rather than caching responses) — matters for fresh re-renders after a
/// cap-change or eviction. The handler itself is fast (single SQLite read +
/// `Data(contentsOf:)`).
final class BodyAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let assetId = BodyAssetStore.assetId(fromURL: url),
              let data = BodyAssetStore.read(assetId: assetId),
              let contentType = BodyAssetStore.contentType(assetId: assetId),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": contentType,
                      "Content-Length": "\(data.count)",
                      "Cache-Control": "no-store",
                  ]
              )
        else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op: the start handler completes synchronously, so there's nothing to stop.
    }
}
