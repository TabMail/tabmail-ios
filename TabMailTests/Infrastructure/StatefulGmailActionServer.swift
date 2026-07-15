/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Stateful Gmail REST boundary for RFC-identity action E2E tests. The model
/// stores Gmail resource IDs separately from RFC Message-IDs and mutates only
/// Gmail labels, matching the provider's action vocabulary.
final class StatefulGmailActionServer: @unchecked Sendable {
    struct Seed: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        let labels: Set<String>

        init(
            rfc822MessageId: String,
            providerMessageId: String,
            labels: Set<String>
        ) {
            self.rfc822MessageId = rfc822MessageId
            self.providerMessageId = providerMessageId
            self.labels = labels
        }
    }

    struct Snapshot: Sendable, Equatable {
        let providerMessageId: String
        let labels: Set<String>

        var isRead: Bool { !labels.contains("UNREAD") }
        var isFlagged: Bool { labels.contains("STARRED") }
    }

    private struct Message: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        var labels: Set<String>
    }

    private struct State: Sendable {
        var messagesByProviderId: [String: Message]
        var userLabels: [String: String]
        let createdLabelId: String?
        var lookupFailuresRemaining = 0
        var lookupFailuresConsumed = 0
        /// Label ids `/messages/{id}/modify` and `/messages` (list) must
        /// reject as gone — simulates a label deleted remotely between
        /// enqueue and drain. Gmail's real shape for this is a structural
        /// `400` (not `404`): https://developers.google.com/workspace/gmail/api/guides/handle-errors
        var deletedLabelIds: Set<String> = []
    }

    private final class StateBox: Sendable {
        let value: Mutex<State>

        init(_ state: State) {
            value = Mutex(state)
        }
    }

    let http = FakeHTTP.Scenario()
    private let state: StateBox

    init(
        messages: [Seed],
        userLabels: [String: String] = [:],
        createdLabelId: String? = nil
    ) {
        state = StateBox(State(
            messagesByProviderId: Dictionary(
                uniqueKeysWithValues: messages.map {
                    ($0.providerMessageId, Message(
                        rfc822MessageId: $0.rfc822MessageId,
                        providerMessageId: $0.providerMessageId,
                        labels: $0.labels
                    ))
                }
            ),
            userLabels: userLabels,
            createdLabelId: createdLabelId
        ))
        registerRoutes()
    }

    func close() {
        http.close()
    }

    func provider() -> GmailProvider {
        GmailProvider(
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

    /// Simulate `labelId` deleted remotely between enqueue and drain: any
    /// `/messages/{id}/modify` add/remove naming it, and any source-scoped
    /// `/messages` list query naming it, now returns Gmail's real structural
    /// 400 invalid-label error body instead of succeeding.
    func markLabelDeleted(_ labelId: String) {
        _ = state.value.withLock { $0.deletedLabelIds.insert(labelId) }
    }

    /// Gmail's real `400` error body for an invalid/gone label — the shape
    /// documented at https://developers.google.com/workspace/gmail/api/guides/handle-errors
    /// and confirmed by real-world reports of `messages.modify` rejecting a
    /// deleted/system label (e.g. googleapis/google-api-php-client#1254).
    private static func invalidLabelErrorBody(_ labelId: String) -> Data {
        let message = "Invalid label: \(labelId)"
        let object: [String: Any] = [
            "error": [
                "errors": [[
                    "domain": "global",
                    "reason": "invalidArgument",
                    "message": message,
                ]],
                "code": 400,
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func snapshots(rfc822MessageId: String) -> [Snapshot] {
        state.value.withLock { model in
            model.messagesByProviderId.values
                .filter { $0.rfc822MessageId == rfc822MessageId }
                .sorted { $0.providerMessageId < $1.providerMessageId }
                .map { Snapshot(
                    providerMessageId: $0.providerMessageId,
                    labels: $0.labels
                ) }
        }
    }

    private func registerRoutes() {
        http.register(path: "/labels", method: "GET") { [state] _ in
            let labels = state.value.withLock { model in
                model.userLabels
                    .sorted { $0.key < $1.key }
                    .map { id, name in
                        [
                            "id": id,
                            "name": name,
                            "type": "user",
                            "messagesTotal": 0,
                            "messagesUnread": 0,
                        ] as [String: Any]
                    }
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["labels": labels])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        http.register(path: "/labels", method: "POST") { [state] request in
            let name = request.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?["name"] as? String
            let created = state.value.withLock { model -> (id: String, name: String)? in
                guard let id = model.createdLabelId, let name else { return nil }
                model.userLabels[id] = name
                return (id, name)
            }
            guard let created else { return .status(404) }
            let body = (try? JSONSerialization.data(withJSONObject: [
                "id": created.id,
                "name": created.name,
                "type": "user",
            ])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        http.register(path: "/messages/", method: "GET") { [state] request in
            let providerId = request.url.pathComponents.last ?? ""
            let message = state.value.withLock { $0.messagesByProviderId[providerId] }
            guard let message else { return .status(404) }
            return Self.metadataResponse(message)
        }
        http.register(path: "/messages", method: "GET") { [state] request in
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let query = queryItems.first(where: { $0.name == "q" })?.value ?? ""
            let label = queryItems.first(where: { $0.name == "labelIds" })?.value
            let maxResults = queryItems.first(where: { $0.name == "maxResults" })?.value
                .flatMap(Int.init) ?? Int.max
            let actionRFC = Self.rfcIdentity(fromSearchQuery: query)
            if actionRFC != nil {
                let lookupFailed = state.value.withLock { model -> Bool in
                    guard model.lookupFailuresRemaining > 0 else { return false }
                    model.lookupFailuresRemaining -= 1
                    model.lookupFailuresConsumed += 1
                    return true
                }
                guard !lookupFailed else { return .status(503) }
            }
            // A source-scoped action lookup (`resolveActionMessageId`) whose
            // recorded label id was deleted remotely gets Gmail's real
            // invalid-label 400 — this SOURCE-label variant is distinct from
            // the modify-path DESTINATION variant below.
            if let label, actionRFC != nil,
               state.value.withLock({ $0.deletedLabelIds.contains(label) }) {
                return .bytes(Self.invalidLabelErrorBody(label), contentType: "application/json", statusCode: 400)
            }
            let refs = state.value.withLock { model in
                model.messagesByProviderId.values
                    .filter { message in
                        if let rfc822MessageId = actionRFC {
                            guard message.rfc822MessageId == rfc822MessageId else {
                                return false
                            }
                            if let label { return message.labels.contains(label) }
                            return Self.isArchiveMembership(message.labels)
                        }
                        if let label { return message.labels.contains(label) }
                        return query == GmailProvider.allMailExclusionQuery
                            && Self.isArchiveMembership(message.labels)
                    }
                    .sorted { $0.providerMessageId < $1.providerMessageId }
                    .prefix(maxResults)
                    .map { ["id": $0.providerMessageId, "threadId": "thread-\($0.providerMessageId)"] }
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["messages": refs])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        http.register(path: "/messages/", method: "POST") { [state] request in
            guard request.url.path.hasSuffix("/modify") else { return .status(404) }
            let components = request.url.pathComponents
            guard components.count >= 2 else { return .status(404) }
            let providerId = components[components.count - 2]
            let body = request.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let additions = body["addLabelIds"] as? [String] ?? []
            let removals = body["removeLabelIds"] as? [String] ?? []
            if let deletedLabel = state.value.withLock({ model in
                (additions + removals).first(where: { model.deletedLabelIds.contains($0) })
            }) {
                return .bytes(Self.invalidLabelErrorBody(deletedLabel), contentType: "application/json", statusCode: 400)
            }
            let found = state.value.withLock { model -> Bool in
                guard var message = model.messagesByProviderId[providerId] else { return false }
                message.labels.formUnion(additions)
                message.labels.subtract(removals)
                model.messagesByProviderId[providerId] = message
                return true
            }
            return found ? .json(raw: "{}") : .status(404)
        }
    }

    private static func rfcIdentity(fromSearchQuery query: String) -> String? {
        guard let range = query.range(of: "rfc822msgid:") else { return nil }
        let suffix = query[range.upperBound...]
        return String(suffix.prefix(while: { !$0.isWhitespace }))
    }

    private static func isArchiveMembership(_ labels: Set<String>) -> Bool {
        let excluded: Set<String> = ["INBOX", "SENT", "TRASH", "SPAM", "DRAFT"]
        return excluded.isDisjoint(with: labels)
    }

    private static func metadataResponse(_ message: Message) -> FakeHTTP.CannedResponse {
        let nowMs = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let object: [String: Any] = [
            "id": message.providerMessageId,
            "threadId": "thread-\(message.providerMessageId)",
            "labelIds": Array(message.labels).sorted(),
            "internalDate": nowMs,
            "payload": [
                "mimeType": "text/plain",
                "headers": [
                    ["name": "Message-ID", "value": "<\(message.rfc822MessageId)>"],
                    ["name": "Subject", "value": "Stateful action message"],
                    ["name": "From", "value": "sender@example.com"],
                    ["name": "To", "value": "recipient@example.com"],
                ],
                "body": ["size": 0, "data": ""],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .bytes(data, contentType: "application/json")
    }
}
