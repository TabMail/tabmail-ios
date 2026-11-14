/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

// MARK: - Date-filtered folder listings (the Outlook catch-up, ADR-IOS-107)
//
// A folder listing with a `receivedDateTime` `$filter`: the terms `ge`, `gt`,
// `lt` and `le` joined by `and`, `$orderby=receivedDateTime desc` (ties by id),
// `$top`, and the `$select`ed fields. Graph's dates have whole-second precision,
// so a message is compared at its whole second. When more messages match than a
// page holds, the page carries an `@odata.nextLink` that repeats the query with
// `$skip=<offset>`, as Graph's message listings do: an offset into the matches
// as they stand when the link is followed, so a message delivered or removed
// between two pages shifts what the next page holds (drift).

/// The catch-up listing's knobs and counters, inside `State`.
struct CatchUpListingModel: Sendable {
    /// Most messages one date-filtered page serves; nil serves up to `$top`.
    var pageCap: Int?
    /// The next date-filtered listings answer these, one each, in order.
    var failures: [FakeHTTP.CannedResponse] = []
    var failuresServed = 0
    /// Ids every listing leaves out (the message still answers a GET or a
    /// `$batch` item), to make a local row the listing does not name.
    var hiddenIds: Set<String> = []
    /// Date-filtered pages served so far.
    var pagesServed = 0
    /// Called after every date-filtered page is served, outside the lock,
    /// with that page's serial (1 for the first): the place a test changes the
    /// mail between two pages.
    var afterPage: (@Sendable (Int) -> Void)?
}

extension StatefulExchangeActionServer {

    /// Serve at most `size` messages per date-filtered page (a smaller `$top`
    /// still wins); nil serves up to `$top`.
    func setCatchUpListingPageCap(_ size: Int?) {
        state.value.withLock { $0.catchUp.pageCap = size }
    }

    /// The next date-filtered listings answer these, one each, in order.
    func failCatchUpListings(_ responses: [FakeHTTP.CannedResponse]) {
        state.value.withLock { $0.catchUp.failures += responses }
    }

    /// How many date-filtered listings were answered with an injected failure.
    func catchUpListingFailuresServed() -> Int {
        state.value.withLock { $0.catchUp.failuresServed }
    }

    /// Leave `ids` out of every listing, filtered or not.
    func hideFromListings(_ ids: Set<String>) {
        state.value.withLock { $0.catchUp.hiddenIds = ids }
    }

    /// Run `hook` after every date-filtered page, with the page's serial.
    func afterCatchUpListingPage(_ hook: (@Sendable (Int) -> Void)?) {
        state.value.withLock { $0.catchUp.afterPage = hook }
    }

    /// Requests received so far, by kind.
    struct RequestCounts: Equatable, Sendable {
        /// Folder listings without a `receivedDateTime` filter (the walk).
        var listings = 0
        /// Folder listings with one, their linked pages included (the catch-up).
        var dateFilteredListings = 0
        /// `$batch` requests, and the items they carried.
        var batches = 0
        var batchItems = 0
        /// `GET /messages/{id}` (the backfill fetch, the direct load).
        var messageGets = 0
        var total = 0
    }

    func requestCounts() -> RequestCounts {
        var counts = RequestCounts()
        for call in http.recordedCalls() {
            counts.total += 1
            guard let url = URL(string: call.url) else { continue }
            if call.method == "POST", url.path.hasSuffix("/$batch") {
                counts.batches += 1
                let root = call.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                counts.batchItems += (root?["requests"] as? [Any])?.count ?? 0
            } else if call.method == "GET", url.path.contains("/mailFolders/"), url.path.hasSuffix("/messages") {
                if Self.isDateFilteredListing(url) { counts.dateFilteredListings += 1 } else { counts.listings += 1 }
            } else if call.method == "GET", Self.messageId(from: url, move: false) != nil {
                counts.messageGets += 1
            }
        }
        return counts
    }

    /// The date-filtered listing requests received, in order.
    func dateFilteredListingURLs() -> [URL] {
        http.recordedCalls().compactMap { call in
            guard call.method == "GET", let url = URL(string: call.url),
                  url.path.contains("/mailFolders/"), url.path.hasSuffix("/messages"),
                  Self.isDateFilteredListing(url) else { return nil }
            return url
        }
    }

    static func isDateFilteredListing(_ url: URL) -> Bool {
        let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "$filter" }?.value
        return filter?.contains("receivedDateTime") == true
    }

    /// A `receivedDateTime` `$filter` as whole-second bounds, or nil when it is
    /// not one this model reads.
    static func dateBounds(_ filter: String) -> [(op: String, second: Int)]? {
        var bounds: [(op: String, second: Int)] = []
        for term in filter.components(separatedBy: " and ") {
            let parts = term.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0] == "receivedDateTime", ["ge", "gt", "lt", "le"].contains(parts[1]),
                  let date = Date.fromISO8601(parts[2]) else { return nil }
            bounds.append((parts[1], Int(date.timeIntervalSince1970.rounded(.down))))
        }
        return bounds.isEmpty ? nil : bounds
    }

    static func second(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    /// The `/mailFolders/{id}/messages` route's answer to a `receivedDateTime`
    /// `$filter`.
    static func serveDateFilteredListing(_ request: FakeHTTP.Request, folderId: String, state: StateBox) -> FakeHTTP.CannedResponse {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { return .status(400) }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let filter = value("$filter"), let bounds = dateBounds(filter) else { return .status(400) }
        let top = value("$top").flatMap(Int.init) ?? Int.max
        let skip = value("$skip").flatMap(Int.init) ?? 0
        let selected = value("$select")?.split(separator: ",").map(String.init)

        let served = state.value.withLock { model -> (response: FakeHTTP.CannedResponse, serial: Int, hook: (@Sendable (Int) -> Void)?) in
            if !model.catchUp.failures.isEmpty {
                model.catchUp.failuresServed += 1
                return (model.catchUp.failures.removeFirst(), 0, nil)
            }
            let matches = model.messagesByProviderId.values
                .filter { message in
                    guard message.folderId == folderId, !model.catchUp.hiddenIds.contains(message.providerMessageId) else { return false }
                    let s = second(message.receivedAt)
                    return bounds.allSatisfy { bound in
                        switch bound.op {
                        case "ge": return s >= bound.second
                        case "gt": return s > bound.second
                        case "lt": return s < bound.second
                        default: return s <= bound.second
                        }
                    }
                }
                .sorted {
                    let l = second($0.receivedAt), r = second($1.receivedAt)
                    return l != r ? l > r : $0.providerMessageId < $1.providerMessageId
                }
            let size = min(top, model.catchUp.pageCap ?? top)
            let start = min(skip, matches.count)
            let end = min(matches.count, start + size)
            let rows: [[String: Any]] = matches[start..<end].map { message in
                let row = graphRow(message)
                guard let selected else { return row }
                return row.filter { selected.contains($0.key) }
            }
            var object: [String: Any] = ["value": rows]
            if end < matches.count {
                components.queryItems = items.filter { $0.name != "$skip" } + [URLQueryItem(name: "$skip", value: String(end))]
                object["@odata.nextLink"] = components.url?.absoluteString
            }
            model.catchUp.pagesServed += 1
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return (.bytes(body, contentType: "application/json"), model.catchUp.pagesServed, model.catchUp.afterPage)
        }
        if served.serial > 0, let hook = served.hook { hook(served.serial) }
        return served.response
    }
}
