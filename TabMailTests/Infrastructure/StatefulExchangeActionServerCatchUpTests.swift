/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Self-checks of the fake's date-filtered listings (`StatefulExchangeActionServer+CatchUp.swift`),
/// driven through the provider's own catch-up listing request, so a seam the
/// Outlook catch-up tests lean on is proven to do what they assume.
@Suite("Stateful Exchange fake: date-filtered listings")
struct StatefulExchangeActionServerCatchUpTests {

    static let folder = "fld-cu"
    static let base = Int(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970.rounded(.down))

    static func seed(_ id: String, second: Int, folder: String = folder, isRead: Bool = false, isFlagged: Bool = false)
        -> StatefulExchangeActionServer.Seed {
        .init(rfc822MessageId: "\(id)@example.com", providerMessageId: id, folderId: folder,
              isRead: isRead, isFlagged: isFlagged, receivedAt: Date(timeIntervalSince1970: TimeInterval(second)))
    }

    @Test("A date filter serves the folder's messages in [ge, lt), newest first then by id, with the selected fields")
    func filterOrderAndSelection() async throws {
        let server = StatefulExchangeActionServer(messages: [
            Self.seed("below", second: Self.base - 1),
            Self.seed("at-from-b", second: Self.base), Self.seed("at-from-a", second: Self.base),
            Self.seed("mid", second: Self.base + 5, isRead: true, isFlagged: true),
            Self.seed("at-upper", second: Self.base + 10),
            Self.seed("elsewhere", second: Self.base + 5, folder: "fld-other"),
        ])
        defer { server.close() }
        let provider = server.provider()

        let page = try await provider.catchUpListingPage(
            folder: Self.folder, fromSecond: Self.base, beforeSecond: Self.base + 10, nextLink: nil)

        #expect(page.messages.map(\.id) == ["mid", "at-from-a", "at-from-b"])
        #expect(page.nextLink == nil)
        let mid = try #require(page.messages.first)
        #expect(mid.isRead == true && mid.flag?.flagStatus == "flagged" && mid.receivedSecond == Self.base + 5)
        #expect(server.requestCounts().dateFilteredListings == 1 && server.requestCounts().listings == 0)

        // No lower bound when `fromSecond` is 0.
        let all = try await provider.catchUpListingPage(folder: Self.folder, fromSecond: 0, beforeSecond: Self.base + 11, nextLink: nil)
        #expect(all.messages.map(\.id) == ["at-upper", "mid", "at-from-a", "at-from-b", "below"])
    }

    @Test("Pages hold at most the page cap; the link repeats the query with $skip and follows the folder as it is then (drift)")
    func pagingAndDrift() async throws {
        let server = StatefulExchangeActionServer(messages: (0..<5).map { Self.seed("m\($0)", second: Self.base + $0) })
        defer { server.close() }
        let provider = server.provider()
        server.setCatchUpListingPageCap(2)

        let first = try await provider.catchUpListingPage(folder: Self.folder, fromSecond: 0, beforeSecond: Self.base + 100, nextLink: nil)
        #expect(first.messages.map(\.id) == ["m4", "m3"])
        let link = try #require(first.nextLink)
        #expect(GraphAPI.isGraphPageLink(link), "the link must pass the provider's own check")
        #expect(link.contains("skip=2"))

        // A message of the first page leaves: the offset now skips m1's slot.
        server.deleteFromOtherClient(providerMessageId: "m4")
        let second = try await provider.catchUpListingPage(folder: Self.folder, fromSecond: 0, beforeSecond: Self.base + 100, nextLink: link)
        #expect(second.messages.map(\.id) == ["m1", "m0"], "the offset paging did not drift: m2 should be skipped")
        #expect(second.nextLink == nil)
        #expect(server.requestCounts().dateFilteredListings == 2)
    }

    @Test("Injected failures answer the next listings in order and are counted; hidden ids are left out of every listing; the hook sees each page")
    func failuresHidingAndHook() async throws {
        let server = StatefulExchangeActionServer(messages: [
            Self.seed("shown", second: Self.base + 2), Self.seed("hidden", second: Self.base + 1),
        ])
        defer { server.close() }
        let provider = server.provider()
        let serials = Mutex<[Int]>([])
        server.afterCatchUpListingPage { serial in serials.withLock { $0.append(serial) } }
        server.failCatchUpListings([.status(500), .status(502)])
        server.hideFromListings(["hidden"])

        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                _ = try await provider.catchUpListingPage(folder: Self.folder, fromSecond: 0, beforeSecond: Self.base + 10, nextLink: nil)
            }
        }
        #expect(server.catchUpListingFailuresServed() == 2)
        #expect(serials.withLock { $0 }.isEmpty, "a failed page ran the hook")

        let page = try await provider.catchUpListingPage(folder: Self.folder, fromSecond: 0, beforeSecond: Self.base + 10, nextLink: nil)
        #expect(page.messages.map(\.id) == ["shown"])
        #expect(serials.withLock { $0 } == [1])
        let walk = try await provider.listMessageIdsPage(folder: Self.folder, pageToken: nil, pageSize: 10)
        #expect(walk.ids == ["shown"], "the unfiltered listing showed a hidden id")
        // The hidden message still answers its own GET.
        #expect(try await provider.fetchMessageDetails(ids: ["hidden"]).details.map(\.header.messageId) == ["hidden"])

        let counts = server.requestCounts()
        #expect(counts.listings == 1)
        #expect(counts.batches == 1 && counts.batchItems == 1)
    }
}
