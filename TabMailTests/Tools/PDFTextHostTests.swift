/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import WebKit
@testable import TabMail

@Suite("PDFTextHost")
@MainActor
struct PDFTextHostTests {

    private let limits = PDFTextExtractor.Limits(maxPages: 20, maxOutputChars: 100_000, timeout: .seconds(20))

    private static let pageURL = URL(string: "\(PDFTextHost.scheme)://local/host.html")!

    private func startedHost(
        _ document: Data = PDFFixtures.make([.text("Alpha")]), limits: PDFTextExtractor.Limits? = nil
    ) async -> (PDFTextHost, Task<PDFTextExtractor.Outcome, Never>) {
        let host = PDFTextHost(document: document, startPage: 1, endPage: nil, limits: limits ?? self.limits)
        let run = Task { await host.run() }
        while host.webView == nil { await Task.yield() }
        return (host, run)
    }

    /// Waits until the host page has loaded; the read itself has then started or is about to.
    private func loaded(_ webView: WKWebView?) async throws {
        while webView?.isLoading == true { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Waits up to `limit` for `webView` to be deallocated: its WebContent process goes with it.
    private func released(_ webView: () -> WKWebView?, within limit: Duration = .seconds(2)) async -> Bool {
        let start = ContinuousClock.now
        while webView() != nil, ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return webView() == nil
    }

    @Test("The WebContent process ending mid-read fails the call and releases the web view")
    func contentProcessEnded() async throws {
        let (host, run) = await startedHost()
        let webView = try #require(host.webView)
        host.webViewWebContentProcessDidTerminate(webView)
        #expect(await run.value == .failed)
        #expect(host.webView == nil)
    }

    @Test("A cancelled caller gets an answer at once and the web view is released")
    func cancelled() async {
        let (host, run) = await startedHost()
        run.cancel()
        #expect(await run.value == .failed)
        #expect(host.webView == nil)
    }

    @Test("A caller cancelled mid-read gets an answer at once, and the web view is deallocated, not left to the page")
    func cancelledWhileReading() async throws {
        let (host, run) = await startedHost(PDFFixtures.slowDocument())
        weak let webView = host.webView
        try await loaded(webView)
        // A page that is busy and will not answer: only the host can end the web view's life.
        webView?.evaluateJavaScript("for (;;) {}", in: nil, in: .defaultClient) { _ in }
        run.cancel()
        #expect(await run.value == .failed)
        #expect(await released { webView })
    }

    @Test("A page that never answers is released at the deadline plus the grace, and the call times out", .timeLimit(.minutes(1)))
    func pageNeverAnswers() async throws {
        let timeout = Duration.seconds(1)
        let start = ContinuousClock.now
        let (host, run) = await startedHost(
            PDFFixtures.slowDocument(), limits: PDFTextExtractor.Limits(maxPages: 20, maxOutputChars: 100_000, timeout: timeout))
        weak let webView = host.webView
        try await loaded(webView)
        // Wedge the page's main thread: pdf.js's own deadline (a timer there) and its answer can
        // no longer run, so only the host's backstop can end the call.
        webView?.evaluateJavaScript("for (;;) {}", in: nil, in: .defaultClient) { _ in }
        #expect(await run.value == .timeout)
        #expect(ContinuousClock.now - start >= timeout + AttachmentReadPdfTool.Config.hostTeardownGrace)
        #expect(host.webView == nil)
        #expect(await released { webView })
    }

    @Test("The page stays inside its sandbox: memory-only storage, the pdf.js directory only, no other origin, no eval, no navigation")
    func boundaries() async throws {
        let (host, run) = await startedHost(PDFFixtures.slowDocument())
        let webView = try #require(host.webView)
        try await loaded(webView)
        #expect(!webView.configuration.websiteDataStore.isPersistent)

        let probe = try await webView.callAsyncJavaScript("""
            const status = async (url) => { try { return (await fetch(url)).status } catch { return -1 } };
            let evalRefused = false;
            try { eval("1") } catch (e) { evalRefused = e instanceof EvalError }
            const worker = await fetch("./pdfjs/pdf.worker.min.mjs");
            return {
                pdfjs: await status("./pdfjs/pdf.min.mjs"),
                parentOfPdfjs: await status("./pdfjs/..%2Fpdf-text-host.mjs"),
                appBundle: await status("./pdfjs/..%2FInfo.plist"),
                unknownPath: await status("./Info.plist"),
                otherScheme: await status("data:text/plain,x"),
                evalRefused,
                workerPolicy: worker.headers.get("content-security-policy"),
            }
            """, contentWorld: .page) as? [String: Any]
        #expect(probe?["pdfjs"] as? Int == 200)
        // pdf-text-host.mjs and Info.plist exist in the app bundle, one level above pdfjs/.
        #expect(probe?["parentOfPdfjs"] as? Int == -1)
        #expect(probe?["appBundle"] as? Int == -1)
        #expect(probe?["unknownPath"] as? Int == -1)
        // A data: URL needs no network: only the policy can refuse it.
        #expect(probe?["otherScheme"] as? Int == -1)
        #expect(probe?["evalRefused"] as? Bool == true)
        #expect(probe?["workerPolicy"] as? String == PDFTextHost.contentSecurityPolicy)

        _ = try await webView.callAsyncJavaScript(
            "location.href = \"\(PDFTextHost.scheme)://local/document\"", contentWorld: .page)
        try await Task.sleep(for: .seconds(2))
        #expect(webView.url == Self.pageURL)

        run.cancel()
        #expect(await run.value == .failed)
    }

    @Test("A host that is left alone reads the page and releases the web view")
    func readsAndReleases() async throws {
        let (host, run) = await startedHost()
        guard case .ok(let pages) = await run.value else {
            Issue.record("expected text")
            return
        }
        #expect(pages.pages.map(\.text) == ["Alpha"])
        #expect(host.webView == nil)
    }

    @Test("The page's result object maps to outcomes; any other shape is a failed read")
    func resultMapping() {
        let page: [String: Any] = ["page": 2, "text": "Bravo", "unreadable": false, "cutFrom": NSNull()]
        let ok: [String: Any] = [
            "outcome": "ok", "totalPages": 3, "firstPage": 2, "lastPage": 2, "pages": [page],
            "cutPage": NSNull(), "stoppedAtOutputLimit": true, "nextStartPage": 3,
        ]
        #expect(PDFTextHost.outcome(from: ok) == .ok(PDFTextExtractor.Pages(
            totalPages: 3, firstPage: 2, lastPage: 2,
            pages: [PDFTextExtractor.Page(page: 2, text: "Bravo", unreadable: false, cutFrom: nil)],
            cutPage: nil, stoppedAtOutputLimit: true, nextStartPage: 3)))

        var cut = ok
        cut["pages"] = [["page": 2, "text": "Br", "unreadable": false, "cutFrom": 5]]
        cut["cutPage"] = 2
        guard case .ok(let cutPages) = PDFTextHost.outcome(from: cut) else {
            Issue.record("expected a cut page")
            return
        }
        #expect(cutPages.cutPage == 2)
        #expect(cutPages.pages.first?.cutFrom == 5)

        #expect(PDFTextHost.outcome(from: ["outcome": "encrypted"]) == .encrypted)
        #expect(PDFTextHost.outcome(from: ["outcome": "malformed"]) == .malformed)
        #expect(PDFTextHost.outcome(from: ["outcome": "timeout"]) == .timeout)
        #expect(PDFTextHost.outcome(from: ["outcome": "past_end", "totalPages": 4]) == .pastEnd(totalPages: 4))
        #expect(PDFTextHost.outcome(from: ["outcome": "failed", "error": "UnknownErrorException x"]) == .failed)

        var noPages = ok
        noPages["pages"] = [[String: Any]]()
        var badPage = ok
        badPage["pages"] = [["page": 2, "text": 7, "unreadable": false]]
        var missingTotal = ok
        missingTotal["totalPages"] = nil
        let malformed: [Any?] = [
            nil, "ok", ["outcome": 1], ["outcome": "unknown"], ["outcome": "past_end"],
            noPages, badPage, missingTotal,
        ]
        for value in malformed {
            #expect(PDFTextHost.outcome(from: value) == .failed)
        }
    }
}
