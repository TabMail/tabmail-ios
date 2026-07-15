/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Stateful Microsoft Graph boundary for RFC-identity action E2E tests. The
/// model deliberately allocates a new Graph resource ID on every move while
/// preserving the message's RFC identity and mutable field state.
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

    func failNextMutation() {
        state.value.withLock { $0.mutationFailuresRemaining += 1 }
    }

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
            return found ? .json(raw: "{}") : .status(404)
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
            "parentFolderId": message.folderId,
        ]
    }
}
