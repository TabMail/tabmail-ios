/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Stateful Microsoft Graph boundary for provider-id action E2E tests. The
/// model deliberately allocates a new Graph resource ID on every move while
/// preserving the message's RFC identity and mutable field state.
///
/// v3 (D4): the durable action queue keys on Graph's native `message.id`. The
/// move-time id reallocation modeled here is exactly the C3-X2 case — the old
/// id resolves to a stale no-op, and the op is dropped rather than re-searched
/// by RFC. The model still STORES an RFC Message-ID (a real server has one),
/// but it is never the handle an action resolves against.
final class StatefulExchangeActionServer: @unchecked Sendable {
    struct Seed: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        let folderId: String
        let isRead: Bool
        let isFlagged: Bool
        let receivedAt: Date

        init(
            rfc822MessageId: String,
            providerMessageId: String,
            folderId: String,
            isRead: Bool = false,
            isFlagged: Bool = false,
            receivedAt: Date = Date()
        ) {
            self.rfc822MessageId = rfc822MessageId
            self.providerMessageId = providerMessageId
            self.folderId = folderId
            self.isRead = isRead
            self.isFlagged = isFlagged
            self.receivedAt = receivedAt
        }
    }

    struct Snapshot: Sendable, Equatable {
        let providerMessageId: String
        let folderId: String
        let isRead: Bool
        let isFlagged: Bool
    }

    private struct Message: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        var folderId: String
        var isRead: Bool
        var isFlagged: Bool
        let receivedAt: Date
    }

    private struct State: Sendable {
        var messagesByProviderId: [String: Message]
        var nextMoveGeneration = 1
        var lookupFailuresRemaining = 0
        var lookupFailuresConsumed = 0
        var mutationFailuresRemaining = 0
        /// RFC Message-IDs whose source-folder `$filter` search
        /// (`resolveActionMessageId`'s first-page fetch) returns a
        /// structural `400` whose body matches NO known terminal shape (not
        /// `ErrorInvalidIdMalformed`, not 404/410) — an UNCLASSIFIED
        /// permanent-shaped failure. Drives the persistent-failure
        /// chain-demotion path for RFC members.
        var unclassified400RFCs: Set<String> = []
        var unclassified400Served = 0
    }

    private final class StateBox: Sendable {
        let value: Mutex<State>

        init(_ state: State) {
            value = Mutex(state)
        }
    }

    let http = FakeHTTP.Scenario()
    private let state: StateBox

    init(messages: [Seed]) {
        state = StateBox(State(messagesByProviderId: Dictionary(
            uniqueKeysWithValues: messages.map {
                ($0.providerMessageId, Message(
                    rfc822MessageId: $0.rfc822MessageId,
                    providerMessageId: $0.providerMessageId,
                    folderId: $0.folderId,
                    isRead: $0.isRead,
                    isFlagged: $0.isFlagged,
                    receivedAt: $0.receivedAt
                ))
            }
        )))
        registerRoutes()
    }

    func close() {
        http.close()
    }

    func provider() -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "user@example.com",
            accessToken: { _ in "stateful-test-token" },
            session: http.session
        )
    }

    func failNextLookup() {
        state.value.withLock { $0.lookupFailuresRemaining += 1 }
    }

    func consumedLookupFailureCount() -> Int {
        state.value.withLock { $0.lookupFailuresConsumed }
    }

    /// The EXACT request shape `v2final`'s `resolveActionMessageId` sent, and
    /// the only shape `failNextLookup()` can consume: a source-folder listing
    /// whose `$filter` names an RFC identity in angle brackets.
    ///
    /// Exposed so a POSITIVE CONTROL can drive the lookup-failure oracle
    /// directly through this scenario's own `http.session`. `v3` has no
    /// production path that sends this shape (the RFC-resolution layer is
    /// exactly what D4 removed), so without such a control every
    /// `consumedLookupFailureCount() == 0` assertion in the suite would be
    /// STRUCTURALLY zero — unfalsifiable, and therefore no evidence at all.
    /// The reference got its `== 1` half for free because an action really did
    /// send this request; here the control has to send it.
    ///
    /// Built here rather than in the test so the URL grammar lives next to
    /// `rfcIdentity(fromLookupURL:)`/`folderId(fromLookupURL:)`, which parse it.
    static func rfcFilterLookupURL(folderId: String, rfc822MessageId: String) -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/\(folderId)/messages")!
        components.queryItems = [
            URLQueryItem(name: "$select", value: "id"),
            URLQueryItem(name: "$filter", value: "internetMessageId eq '<\(rfc822MessageId)>'"),
        ]
        return components.url!
    }

    func failNextMutation() {
        state.value.withLock { $0.mutationFailuresRemaining += 1 }
    }

    /// Inject an UNCLASSIFIED structural 400 for the source-folder `$filter`
    /// search naming `rfc822MessageId` — the body is Graph's structured error
    /// shape but matches neither `ErrorInvalidIdMalformed` nor any other
    /// terminal shape the adapter knows. Drives the persistent-failure
    /// chain-demotion path for RFC members (`resolveActionMessageId`'s
    /// first-page fetch).
    func injectUnclassified400OnFilterSearch(rfc822MessageId: String) {
        _ = state.value.withLock { $0.unclassified400RFCs.insert(rfc822MessageId) }
    }

    /// How many `$filter` search attempts were rejected with the injected
    /// unclassified 400 — one per provider attempt on the failing op.
    func unclassified400ServedCount() -> Int {
        state.value.withLock { $0.unclassified400Served }
    }

    /// v3 adaptation (D4): the durable action op records Graph's native
    /// `message.id`, so an assertion about "did the op's mutation land" reads
    /// the model by PROVIDER ID, never by RFC. `nil` when no message with that
    /// id currently exists — either genuinely gone, or Graph having
    /// REALLOCATED the id on move, which is the expected stale-no-op (C3-X2).
    func snapshot(providerMessageId: String) -> Snapshot? {
        state.value.withLock { model in
            model.messagesByProviderId[providerMessageId].map {
                Snapshot(
                    providerMessageId: $0.providerMessageId,
                    folderId: $0.folderId,
                    isRead: $0.isRead,
                    isFlagged: $0.isFlagged
                )
            }
        }
    }

    /// Every copy currently sharing one RFC Message-ID. Under D4 this is an
    /// OBSERVATION helper only — it exists precisely so a test can construct
    /// and inspect the alias case (several distinct provider ids, one RFC)
    /// that motivated the provider-id refactor, and to follow a message across
    /// Graph's move-time id reallocation. It must never be used to pick a
    /// mutation target.
    func snapshots(rfc822MessageId: String) -> [Snapshot] {
        state.value.withLock { model in
            model.messagesByProviderId.values
                .filter { $0.rfc822MessageId == rfc822MessageId }
                .sorted { $0.providerMessageId < $1.providerMessageId }
                .map { Snapshot(
                    providerMessageId: $0.providerMessageId,
                    folderId: $0.folderId,
                    isRead: $0.isRead,
                    isFlagged: $0.isFlagged
                ) }
        }
    }

    private func registerRoutes() {
        http.register(path: "/mailFolders/", method: "GET") { [state] request in
            guard let folderId = Self.folderId(fromLookupURL: request.url) else {
                return .status(404)
            }
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let filter = queryItems.first(where: { $0.name == "$filter" })?.value
            let rfc822MessageId = Self.rfcIdentity(fromLookupURL: request.url)
            if filter != nil {
                guard rfc822MessageId != nil else { return .status(400) }
                if let rfc822MessageId,
                   state.value.withLock({ model -> Bool in
                       guard model.unclassified400RFCs.contains(rfc822MessageId) else { return false }
                       model.unclassified400Served += 1
                       return true
                   }) {
                    return .bytes(Self.unclassifiedBadRequestBody(), contentType: "application/json", statusCode: 400)
                }
                let lookupFailed = state.value.withLock { model -> Bool in
                    guard model.lookupFailuresRemaining > 0 else { return false }
                    model.lookupFailuresRemaining -= 1
                    model.lookupFailuresConsumed += 1
                    return true
                }
                guard !lookupFailed else { return .status(503) }
            }
            let top = queryItems.first(where: { $0.name == "$top" })?.value
                .flatMap(Int.init) ?? Int.max
            let skip = queryItems.first(where: { $0.name == "$skip" })?.value
                .flatMap(Int.init) ?? 0

            let rows = state.value.withLock { model in
                model.messagesByProviderId.values
                    .filter {
                        $0.folderId == folderId
                            && (rfc822MessageId == nil || $0.rfc822MessageId == rfc822MessageId)
                    }
                    .sorted {
                        if $0.receivedAt != $1.receivedAt {
                            return $0.receivedAt > $1.receivedAt
                        }
                        return $0.providerMessageId < $1.providerMessageId
                    }
                    .dropFirst(skip)
                    .prefix(top)
                    .map(Self.graphRow)
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["value": rows])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        // Exact resource lookup (`GET /messages/{id}?$select=…`) — the same
        // resource Graph exposes for provider-ID (token) action resolution.
        // A gone/churned ID is a plain 404, Graph's authoritative-stale shape.
        http.register(path: "/messages/", method: "GET") { [state] request in
            if let providerId = Self.messageIdForAttachmentCollection(from: request.url) {
                let exists = state.value.withLock { $0.messagesByProviderId[providerId] != nil }
                guard exists else { return .status(404) }
                return .json(raw: #"{"value":[]}"#)
            }
            guard let providerId = Self.messageId(from: request.url, move: false) else {
                return .status(404)
            }
            let message = state.value.withLock { $0.messagesByProviderId[providerId] }
            guard let message else { return .status(404) }
            let body = (try? JSONSerialization.data(withJSONObject: Self.graphRow(message))) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        http.register(path: "/messages/", method: "PATCH") { [state] request in
            guard !Self.consumeMutationFailure(state) else { return .status(503) }
            guard let providerId = Self.messageId(from: request.url, move: false) else {
                return .status(404)
            }
            let body = request.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let found = state.value.withLock { model -> Bool in
                guard var message = model.messagesByProviderId[providerId] else { return false }
                if let isRead = body["isRead"] as? Bool {
                    message.isRead = isRead
                }
                if let flag = body["flag"] as? [String: Any],
                   let status = flag["flagStatus"] as? String {
                    message.isFlagged = status == "flagged"
                }
                model.messagesByProviderId[providerId] = message
                return true
            }
            return found
                ? .json(raw: "{\"id\":\"\(providerId)\"}")
                : .status(404)
        }
        http.register(path: "/messages/", method: "DELETE") { [state] request in
            guard !Self.consumeMutationFailure(state) else { return .status(503) }
            guard let providerId = Self.messageId(from: request.url, move: false) else {
                return .status(404)
            }
            let removed = state.value.withLock { model in
                model.messagesByProviderId.removeValue(forKey: providerId) != nil
            }
            return removed ? .status(204) : .status(404)
        }
        http.register(path: "/messages/", method: "POST") { [state] request in
            guard !Self.consumeMutationFailure(state) else { return .status(503) }
            guard let providerId = Self.messageId(from: request.url, move: true) else {
                return .status(404)
            }
            let body = request.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            guard let destination = body["destinationId"] as? String else {
                return .status(400)
            }

            let moved = state.value.withLock { model -> Message? in
                guard let prior = model.messagesByProviderId.removeValue(forKey: providerId) else {
                    return nil
                }
                let movedId = "graph/moved+\(model.nextMoveGeneration)="
                model.nextMoveGeneration += 1
                let next = Message(
                    rfc822MessageId: prior.rfc822MessageId,
                    providerMessageId: movedId,
                    folderId: destination,
                    isRead: prior.isRead,
                    isFlagged: prior.isFlagged,
                    receivedAt: prior.receivedAt
                )
                model.messagesByProviderId[movedId] = next
                return next
            }
            guard let moved else { return .status(404) }
            let response = (try? JSONSerialization.data(withJSONObject: Self.graphRow(moved))) ?? Data()
            return .bytes(response, contentType: "application/json")
        }
    }

    /// Graph's structured `400` error body with a `code` that matches NO
    /// terminal classification the adapter knows (not
    /// `ErrorInvalidIdMalformed`, not 404/410) — the "unrecognized REST 400"
    /// that used to wedge the queue before persistent-failure chain demotion.
    private static func unclassifiedBadRequestBody() -> Data {
        let object: [String: Any] = [
            "error": [
                "code": "ErrorInvalidRequest",
                "message": "The request is malformed or incorrect.",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func consumeMutationFailure(_ state: StateBox) -> Bool {
        state.value.withLock { model in
            guard model.mutationFailuresRemaining > 0 else { return false }
            model.mutationFailuresRemaining -= 1
            return true
        }
    }

    private static func folderId(fromLookupURL url: URL) -> String? {
        let components = url.pathComponents
        guard let folderIndex = components.firstIndex(of: "mailFolders"),
              components.indices.contains(folderIndex + 2),
              components[folderIndex + 2] == "messages"
        else { return nil }
        return components[folderIndex + 1]
    }

    /// Decode exactly one Graph message resource path segment. Reserved
    /// characters inside the opaque ID must remain percent-encoded on the wire;
    /// a raw slash therefore fails this route instead of being misread as shape.
    private static func messageId(from url: URL, move: Bool) -> String? {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let messagesIndex = segments.firstIndex(of: "messages") else { return nil }
        let expectedTailCount = move ? 2 : 1
        guard segments.distance(from: messagesIndex, to: segments.endIndex) == expectedTailCount + 1,
              (!move || segments[segments.index(messagesIndex, offsetBy: 2)] == "move")
        else { return nil }
        return String(segments[segments.index(after: messagesIndex)]).removingPercentEncoding
    }

    private static func messageIdForAttachmentCollection(from url: URL) -> String? {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let messagesIndex = segments.firstIndex(of: "messages"),
              segments.distance(from: messagesIndex, to: segments.endIndex) == 3,
              segments[segments.index(messagesIndex, offsetBy: 2)] == "attachments"
        else { return nil }
        return String(segments[segments.index(after: messagesIndex)]).removingPercentEncoding
    }

    private static func rfcIdentity(fromLookupURL url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let filter = components?.queryItems?.first(where: { $0.name == "$filter" })?.value,
              let opening = filter.firstIndex(of: "<"),
              let closing = filter[filter.index(after: opening)...].firstIndex(of: ">")
        else { return nil }
        return String(filter[filter.index(after: opening)..<closing])
            .replacingOccurrences(of: "''", with: "'")
    }

    private static func graphRow(_ message: Message) -> [String: Any] {
        [
            "id": message.providerMessageId,
            "subject": "Stateful action message",
            "from": [
                "emailAddress": [
                    "name": "Sender",
                    "address": "sender@example.com",
                ],
            ],
            "toRecipients": [[
                "emailAddress": [
                    "name": "Recipient",
                    "address": "recipient@example.com",
                ],
            ]],
            "ccRecipients": [],
            "bccRecipients": [],
            "replyTo": [],
            "receivedDateTime": message.receivedAt.iso8601String(),
            "isRead": message.isRead,
            "flag": ["flagStatus": message.isFlagged ? "flagged" : "notFlagged"],
            "hasAttachments": false,
            "internetMessageId": "<\(message.rfc822MessageId)>",
            "conversationId": "conversation-\(message.rfc822MessageId)",
            "categories": [],
            "bodyPreview": "",
            "body": ["contentType": "text", "content": "Stateful draft body"],
            "parentFolderId": message.folderId,
        ]
    }
}
