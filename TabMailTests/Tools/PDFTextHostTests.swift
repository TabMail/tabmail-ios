/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PDFTextHost")
@MainActor
struct PDFTextHostTests {

    private let limits = PDFTextExtractor.Limits(maxPages: 20, maxOutputChars: 100_000, timeout: .seconds(20))

    private func startedHost() async -> (PDFTextHost, Task<PDFTextExtractor.Outcome, Never>) {
        let host = PDFTextHost(document: PDFFixtures.make([.text("Alpha")]), startPage: 1, endPage: nil, limits: limits)
        let run = Task { await host.run() }
        while host.webView == nil { await Task.yield() }
        return (host, run)
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
