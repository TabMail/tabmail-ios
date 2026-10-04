/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit

/// Runs the bundled pdf.js (`TabMail/Vendor/pdfjs`, the same release the Thunderbird add-on
/// ships) in a hidden web view to read a PDF's text for `PDFTextExtractor` (ADR-IOS-088).
///
/// pdf.js parses inside WebKit's WebContent process, not in the app: a PDF that exhausts memory
/// there ends that process, which reports `webViewWebContentProcessDidTerminate`, and the call
/// returns `.failed` while the app keeps running. Every call gets its own web view, a
/// non-persistent data store (nothing reaches disk, ADR-004) and its own pdf.js worker
/// (`pdf-text-host.mjs`), and the web view is released when the call ends.
///
/// The page loads only bundled files from the `tabmail-pdf` scheme, and the PDF bytes are served
/// to it as data at `tabmail-pdf://local/document`, never navigated to.
@MainActor
final class PDFTextHost: NSObject, WKNavigationDelegate {

    static let scheme = "tabmail-pdf"
    private static let host = "local"
    private static let pageURL = URL(string: "\(scheme)://\(host)/host.html")!
    /// Sent with every response, so it governs both the page and the pdf.js worker (a worker
    /// takes its policy from its own script's response, not from the page): scripts, the worker
    /// and fetches come from this scheme only, and nothing can be evaluated from a string.
    static let contentSecurityPolicy =
        "default-src 'none'; script-src \(scheme):; worker-src \(scheme):; connect-src \(scheme):; base-uri 'none'; form-action 'none'"

    private let document: Data
    private let startPage: Int
    private let endPage: Int?
    private let limits: PDFTextExtractor.Limits

    private(set) var webView: WKWebView?
    private var continuation: CheckedContinuation<PDFTextExtractor.Outcome, Never>?
    private var backstop: Task<Void, Never>?

    init(document: Data, startPage: Int, endPage: Int?, limits: PDFTextExtractor.Limits) {
        self.document = document
        self.startPage = startPage
        self.endPage = endPage
        self.limits = limits
    }

    /// Reads pages `startPage...endPage` as `pdf-text-host.mjs` does. pdf.js stops itself at
    /// `limits.timeout` by terminating its worker; if the page does not answer by then plus
    /// `AttachmentReadPdfTool.Config.hostTeardownGrace`, the web view is released and the call
    /// returns `.timeout` anyway. A cancelled caller releases the web view at once.
    static func extract(
        data: Data, startPage: Int, endPage: Int?, limits: PDFTextExtractor.Limits
    ) async -> PDFTextExtractor.Outcome {
        await PDFTextHost(document: data, startPage: startPage, endPage: endPage, limits: limits).run()
    }

    /// One read; a host is used once.
    func run() async -> PDFTextExtractor.Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failed) }
        }
    }

    private func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(SchemeHandler(document: document), forURLScheme: Self.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let wait = limits.timeout + AttachmentReadPdfTool.Config.hostTeardownGrace
        backstop = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[PDFTextHost] No answer from the page by the deadline; releasing the web view")
            self?.finish(.timeout)
        }
        webView.load(URLRequest(url: Self.pageURL))
    }

    /// Imports `pdf-text-host.mjs` and calls it. The import, not `didFinish`, is what waits for
    /// pdf.js: WebKit reports the page finished before a module's imports have loaded (measured
    /// 2026-10-04: `pdf.min.mjs` was requested after `didFinish`). The completion handler holds
    /// neither the web view nor the host, so `finish` releases the web view, and with it the
    /// WebContent process, even while the page is still working or will never answer.
    private func readPages() {
        guard let webView else { return }
        let range: [String: Any] = ["startPage": startPage, "endPage": endPage.map { $0 as Any } ?? NSNull()]
        let limits: [String: Any] = [
            "maxPages": self.limits.maxPages,
            "maxOutputChars": self.limits.maxOutputChars,
            "timeoutMs": Int(self.limits.timeout / .milliseconds(1)),
        ]
        webView.callAsyncJavaScript(
            "const host = await import(\"./pdf-text-host.mjs\"); return await host.extractPdfText(range, limits)",
            arguments: ["range": range, "limits": limits], in: nil, in: .page
        ) { [weak self] result in
            switch result {
            case .success(let value):
                self?.finish(Self.outcome(from: value))
            case .failure(let error):
                BackgroundSyncLogger.logDebug("[PDFTextHost] Page call failed: \(String(describing: error))")
                self?.finish(.failed)
            }
        }
    }

    /// Resumes the caller once and releases the web view; later calls do nothing.
    private func finish(_ outcome: PDFTextExtractor.Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        backstop?.cancel()
        backstop = nil
        if let webView {
            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil
        }
        continuation.resume(returning: outcome)
    }

    // MARK: - Result

    /// Maps the page's result object (`pdf-text-host.mjs` `readPages`) to an outcome. Anything
    /// that does not have that shape is `.failed`.
    static func outcome(from value: Any?) -> PDFTextExtractor.Outcome {
        guard let result = value as? [String: Any], let outcome = result["outcome"] as? String else {
            return .failed
        }
        switch outcome {
        case "encrypted": return .encrypted
        case "malformed": return .malformed
        case "timeout": return .timeout
        case "past_end":
            guard let totalPages = result["totalPages"] as? Int else { return .failed }
            return .pastEnd(totalPages: totalPages)
        case "ok":
            guard let totalPages = result["totalPages"] as? Int,
                  let firstPage = result["firstPage"] as? Int,
                  let lastPage = result["lastPage"] as? Int,
                  let rawPages = result["pages"] as? [[String: Any]],
                  let stoppedAtOutputLimit = result["stoppedAtOutputLimit"] as? Bool
            else { return .failed }
            var pages: [PDFTextExtractor.Page] = []
            for raw in rawPages {
                guard let page = raw["page"] as? Int, let text = raw["text"] as? String,
                      let unreadable = raw["unreadable"] as? Bool
                else { return .failed }
                pages.append(PDFTextExtractor.Page(
                    page: page, text: text, unreadable: unreadable, cutFrom: raw["cutFrom"] as? Int))
            }
            guard !pages.isEmpty else { return .failed }
            return .ok(PDFTextExtractor.Pages(
                totalPages: totalPages, firstPage: firstPage, lastPage: lastPage, pages: pages,
                cutPage: result["cutPage"] as? Int, stoppedAtOutputLimit: stoppedAtOutputLimit,
                nextStartPage: result["nextStartPage"] as? Int))
        default:
            if let error = result["error"] as? String {
                BackgroundSyncLogger.logDebug("[PDFTextHost] pdf.js could not read the PDF: \(error)")
            }
            return .failed
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readPages()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        BackgroundSyncLogger.logDebug("[PDFTextHost] Page failed: \(String(describing: error))")
        finish(.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        BackgroundSyncLogger.logDebug("[PDFTextHost] Page failed to load: \(String(describing: error))")
        finish(.failed)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.request.url == Self.pageURL ? .allow : .cancel
    }

    /// The WebContent process ended, most likely because pdf.js ran out of memory on this PDF.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        BackgroundSyncLogger.logDebug("[PDFTextHost] WebContent process ended while reading a PDF")
        finish(.failed)
    }

    // MARK: - Scheme handler

    /// Serves the host page, `pdf-text-host.mjs`, the bundled pdf.js directory and the PDF bytes.
    /// Nothing else exists on the scheme, and no path leaves the pdf.js directory.
    @MainActor
    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        private let document: Data

        init(document: Data) {
            self.document = document
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.host == PDFTextHost.host,
                  let (data, type) = resource(at: url.path)
            else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            guard let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": type, "Content-Length": String(data.count),
                    "Content-Security-Policy": PDFTextHost.contentSecurityPolicy,
                ])
            else {
                urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        private func resource(at path: String) -> (Data, String)? {
            switch path {
            case "/host.html":
                return bundled("pdf-text-host", "html").map { ($0, "text/html") }
            case "/pdf-text-host.mjs":
                return bundled("pdf-text-host", "mjs").map { ($0, "text/javascript") }
            case "/document":
                return (document, "application/pdf")
            default:
                let prefix = "/pdfjs/"
                guard path.hasPrefix(prefix),
                      let directory = Bundle.main.resourceURL?.appendingPathComponent("pdfjs", isDirectory: true)
                        .standardizedFileURL
                else { return nil }
                let file = directory.appendingPathComponent(String(path.dropFirst(prefix.count))).standardizedFileURL
                guard file.path.hasPrefix(directory.path + "/"), let data = try? Data(contentsOf: file) else {
                    return nil
                }
                return (data, file.pathExtension == "mjs" ? "text/javascript" : "application/octet-stream")
            }
        }

        private func bundled(_ name: String, _ ext: String) -> Data? {
            Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) }
        }
    }
}
