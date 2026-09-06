/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Stateful Gmail REST boundary for provider-id action E2E tests. The model
/// stores Gmail resource IDs separately from RFC Message-IDs and mutates only
/// Gmail labels, matching the provider's action vocabulary.
///
/// v3 (D4): the durable action queue keys on Gmail's native `message.id`. The
/// model still STORES an RFC Message-ID per message — a real server has one,
/// and threading / the AI cache probe / Outbox send-dedup legitimately still
/// use it — but it is never the handle an action resolves against.
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

    /// One attempted `/messages/{id}/modify` call, in chronological order —
    /// including attempts the fixture rejected (injected 400s). Lets tests
    /// assert cross-op provider ordering and per-message attempt counts.
    struct ModifyCall: Sendable, Equatable {
        let providerMessageId: String
        let addLabelIds: [String]
        let removeLabelIds: [String]
    }

    private struct Message: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        var labels: Set<String>
    }

    /// Which injected failure (if any) `/messages/{id}/modify` must serve for
    /// this attempt. Decided under one lock so the attempt is logged exactly
    /// once regardless of which arm fires.
    ///
    /// `noneInjected`, not `none` — a case named `none` collides with
    /// `Optional.none` at any callsite where type inference has room, a trap
    /// this codebase has been bitten by before (`ActionTag.none`).
    private enum ModifyInjection: Sendable {
        case noneInjected
        case unclassified400
        case invalidId400
        case transient503
        case gone410
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
        /// Provider message ids whose `/messages/{id}/modify` returns a
        /// structural `400` whose body does NOT match the known
        /// invalid-label shape — an UNCLASSIFIED permanent-shaped failure
        /// (persistent-failure chain-demotion tests). Cleared via
        /// `clearUnclassified400s()` to simulate the condition resolving.
        var unclassified400ProviderIds: Set<String> = []
        var unclassified400Served = 0
        /// Provider message ids whose `/messages/{id}/modify` returns Gmail's
        /// real `"Invalid id value"` `400` — the MODIFY-path counterpart of
        /// `invalidIdOnGetProviderIds`. Gmail proves the exact id can never
        /// resolve, so `GmailProvider.isGmailInvalidIdError` classifies it as
        /// an authoritative stale no-op (C3-G2).
        var invalidId400OnModifyProviderIds: Set<String> = []
        var invalidId400OnModifyServed = 0
        /// Provider message ids whose `/messages/{id}/modify` returns a
        /// TRANSIENT `503`. Outside `HTTPRetryPolicy.gmail`'s retryable set
        /// (429/403 only), so it surfaces as a plain bodyless
        /// `HTTPError.networkError(503)` — the control that proves a terminal
        /// disposition is not being applied to every failure alike.
        var transient503OnModifyProviderIds: Set<String> = []
        var transient503OnModifyServed = 0
        /// Provider message ids whose `/messages/{id}/modify` returns a bare
        /// `410 Gone`. NOT a synonym for the unseeded-id `404` this fixture
        /// already serves: `410` is the status the drain has never treated as a
        /// retirement, so it is the control that proves per-member absorption did
        /// not silently widen what retires an operation.
        var gone410OnModifyProviderIds: Set<String> = []
        var gone410OnModifyServed = 0
        var modifyLog: [ModifyCall] = []
        /// Seconds every `/messages/{id}/modify` response is withheld for.
        /// `0` (the default) keeps the fixture instantaneous — only the tests
        /// that need a loop to outrun a deadline pay for it. See
        /// `holdEachModify(forSeconds:)`.
        var modifyLatencySeconds: TimeInterval = 0
        /// Provider message ids whose exact-ID metadata `GET /messages/{id}`
        /// (token-member resolution, `resolveTokenMember`) returns a
        /// structural `400` whose body matches NO known terminal shape — the
        /// GET-path counterpart of `unclassified400ProviderIds` (which only
        /// covers the modify/POST path). Drives the persistent-failure
        /// chain-demotion path for token members.
        var unclassified400OnGetProviderIds: Set<String> = []
        var unclassified400OnGetServed = 0
        /// Provider message ids whose exact-ID metadata `GET /messages/{id}`
        /// returns Gmail's real "Invalid id value" `400` — the Gmail mirror
        /// of Graph's `ErrorInvalidIdMalformed`, an authoritative-stale
        /// no-op per `isGmailInvalidIdError`.
        var invalidIdOnGetProviderIds: Set<String> = []
        /// Provider ids that should ALSO match an `rfc822msgid:` search for a
        /// DIFFERENT (superstring) Message-ID — models a real observed Gmail
        /// search-index quirk where a message whose Message-ID is a
        /// superstring of the queried id can surface as a decoy candidate
        /// alongside the true match (SPEC-B1). Keyed by provider id so the
        /// decoy's OWN Message-ID (returned by metadata fetch) stays truthful.
        var substringDecoyMatches: [String: String] = [:]
        /// rfc822 Message-IDs whose next search response should carry a
        /// spurious `nextPageToken` even though the implied next page is
        /// empty — models a dangling-pagination edge case (SPEC-B3).
        var spuriousNextPageTokenTargets: Set<String> = []
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

    /// Inject an UNCLASSIFIED structural 400 for every `/messages/{id}/modify`
    /// naming `providerMessageId`: the body is Gmail's structured error shape
    /// but matches neither the invalid-label wording nor any other terminal
    /// shape the adapter knows — permanent-SHAPED, not authoritative-terminal.
    /// Drives the persistent-failure chain-demotion path.
    func injectUnclassified400(providerMessageId: String) {
        _ = state.value.withLock { $0.unclassified400ProviderIds.insert(providerMessageId) }
    }

    /// Clear every injected unclassified 400 — simulates the provider-side
    /// condition resolving so a later drain completes the demoted chain.
    func clearUnclassified400s() {
        state.value.withLock { $0.unclassified400ProviderIds.removeAll() }
    }

    /// How many modify attempts were rejected with the injected unclassified
    /// 400 — one per provider attempt on the failing op.
    func unclassified400ServedCount() -> Int {
        state.value.withLock { $0.unclassified400Served }
    }

    /// Chronological log of every attempted modify call (including rejected
    /// ones) for ordering/attempt-count assertions.
    func modifyLog() -> [ModifyCall] {
        state.value.withLock { $0.modifyLog }
    }

    /// Inject Gmail's real `"Invalid id value"` `400` for every
    /// `/messages/{id}/modify` naming `providerMessageId` — the MODIFY-path
    /// counterpart of `injectInvalidIdOnGet`. Models Gmail rejecting a
    /// never-valid message id on the ACTION write itself, which is the only
    /// body-classifying Gmail call site v3 has (D4 removed the RFC-search
    /// resolution layer the reference classified on the GET path).
    func injectInvalidId400OnModify(providerMessageId: String) {
        _ = state.value.withLock { $0.invalidId400OnModifyProviderIds.insert(providerMessageId) }
    }

    /// How many modify attempts were rejected with the injected invalid-id 400.
    func invalidId400OnModifyServedCount() -> Int {
        state.value.withLock { $0.invalidId400OnModifyServed }
    }

    /// Inject a TRANSIENT `503` for every `/messages/{id}/modify` naming
    /// `providerMessageId` — the non-terminal control for the structural-400
    /// classification tests.
    func injectTransient503OnModify(providerMessageId: String) {
        _ = state.value.withLock { $0.transient503OnModifyProviderIds.insert(providerMessageId) }
    }

    /// How many modify attempts were rejected with the injected 503.
    func transient503OnModifyServedCount() -> Int {
        state.value.withLock { $0.transient503OnModifyServed }
    }

    /// Heal every injected modify `503`, leaving the served count intact.
    ///
    /// A transient fault is only transient if the test can end it: a fixture that
    /// can never recover proves retention but can never prove CONVERGENCE, and
    /// convergence is half of every never-drop property. Mirrors
    /// `clearUnclassified400s()`.
    func clearTransient503sOnModify() {
        state.value.withLock { $0.transient503OnModifyProviderIds.removeAll() }
    }

    /// Inject a bare `410 Gone` for every `/messages/{id}/modify` naming
    /// `providerMessageId`.
    ///
    /// ⚠️ DELIBERATELY DISTINCT FROM AN UNSEEDED ID, which this fixture answers
    /// with `404`. `AccountManager.isMessageNotFoundError` — the gate a not-found
    /// must pass before the drain may retire an operation — accepts `404` and has
    /// never accepted `410`, so a `410` is the control for "a member-addressed
    /// failure that is NOT authoritative absence". Its only other appearance is
    /// inside `isConfirmedGoneError`, which runs after that gate has already
    /// admitted the error and therefore never sees one.
    func injectGone410OnModify(providerMessageId: String) {
        _ = state.value.withLock { $0.gone410OnModifyProviderIds.insert(providerMessageId) }
    }

    /// How many modify attempts were rejected with the injected 410.
    func gone410OnModifyServedCount() -> Int {
        state.value.withLock { $0.gone410OnModifyServed }
    }

    /// Make every `/messages/{id}/modify` take `seconds` to answer.
    ///
    /// The per-member provider loops are SEQUENTIAL, so this is the only way a
    /// test can make one of them cost real wall-clock time and collide with the
    /// operation deadline `AccountManager.executeSingleOp` wraps it in. Without
    /// it the whole loop finishes in microseconds and the deadline is
    /// unreachable, which is precisely the condition under which the starvation
    /// this models is invisible.
    ///
    /// The wait happens in `CannedResponse.parked`, i.e. on a background queue,
    /// so it delays THIS request without occupying the transport's loader thread
    /// and starving every other route — see that method's note on the
    /// `OutlookQueueHandoffTests` flake. The handler's synchronous part (the
    /// `modifyLog` append, the injection budgets, the state mutation) still runs
    /// in request order before the wait, so ordering of what was RECEIVED is
    /// unchanged.
    func holdEachModify(forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.modifyLatencySeconds = seconds }
    }

    /// Inject an UNCLASSIFIED structural 400 for the exact-ID metadata `GET
    /// /messages/{id}` naming `providerMessageId` — the GET-path counterpart
    /// of `injectUnclassified400` (which only covers the modify/POST path).
    /// Drives the persistent-failure chain-demotion path for token-member
    /// resolution (`GmailProvider.resolveTokenMember`).
    func injectUnclassified400OnGet(providerMessageId: String) {
        _ = state.value.withLock { $0.unclassified400OnGetProviderIds.insert(providerMessageId) }
    }

    /// How many exact-ID metadata GET attempts were rejected with the
    /// injected unclassified 400 — one per provider attempt on the failing op.
    func unclassified400OnGetServedCount() -> Int {
        state.value.withLock { $0.unclassified400OnGetServed }
    }

    /// Inject Gmail's real "Invalid id value" `400` (structured,
    /// `reason == "invalidArgument"`) for the exact-ID metadata `GET
    /// /messages/{id}` naming `providerMessageId` — models Gmail rejecting a
    /// malformed/never-valid message id, the Gmail mirror of Graph's
    /// `ErrorInvalidIdMalformed`.
    func injectInvalidIdOnGet(providerMessageId: String) {
        _ = state.value.withLock { $0.invalidIdOnGetProviderIds.insert(providerMessageId) }
    }

    /// SPEC-B1: simulate Gmail's real `rfc822msgid:` search occasionally
    /// surfacing a DECOY message alongside the true match for a DIFFERENT
    /// queried id — a superstring/substring search-index collision (e.g. a
    /// decoy whose real Message-ID is `xabc@x.com` also matching a search
    /// for `abc@x.com`). `decoyProviderMessageId` must already be seeded;
    /// its own Message-ID is untouched, so metadata verification still sees
    /// its TRUE identity — only the SEARCH RESULT LIST gains the extra ref.
    func addSubstringDecoyMatchForTesting(decoyProviderMessageId: String, matchesQuery rfc822MessageId: String) {
        state.value.withLock { $0.substringDecoyMatches[decoyProviderMessageId] = rfc822MessageId }
    }

    /// SPEC-B3: the next `rfc822msgid:` search for `rfc822MessageId` returns
    /// its normal ref(s) PLUS a spurious `nextPageToken` — modeling Gmail
    /// claiming more results exist when the implied next page is actually
    /// empty. Persists until cleared; a real drain only searches once per op.
    func armSpuriousNextPageTokenForTesting(rfc822MessageId: String) {
        _ = state.value.withLock { $0.spuriousNextPageTokenTargets.insert(rfc822MessageId) }
    }

    /// Gmail's structured error-body shape with a reason/message that matches
    /// NO terminal classification the adapter knows (not invalid-label, not
    /// 404/410) — the "unrecognized REST 400" that used to wedge the queue.
    private static func unclassifiedBadRequestBody() -> Data {
        let message = "Precondition check failed."
        let object: [String: Any] = [
            "error": [
                "errors": [[
                    "domain": "global",
                    "reason": "failedPrecondition",
                    "message": message,
                ]],
                "code": 400,
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
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

    /// Gmail's real `400` error body for a malformed/never-valid message id
    /// on exact-ID `GET /messages/{id}` — literal wording `"Invalid id value
    /// <id>"` (matched by `GmailProvider.isGmailInvalidIdError`'s
    /// `hasPrefix("Invalid id value")` check).
    private static func invalidIdErrorBody(_ id: String) -> Data {
        let message = "Invalid id value \(id)"
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

    /// v3 adaptation (D4): the durable action op records Gmail's native
    /// `message.id`, so an assertion about "did the op's mutation land" reads
    /// the model by PROVIDER ID, never by RFC. `nil` when no message with that
    /// id currently exists — the stale-no-op case (C3-G2).
    func snapshot(providerMessageId: String) -> Snapshot? {
        state.value.withLock { model in
            model.messagesByProviderId[providerMessageId].map {
                Snapshot(providerMessageId: $0.providerMessageId, labels: $0.labels)
            }
        }
    }

    /// Every copy currently sharing one RFC Message-ID. Under D4 this is an
    /// OBSERVATION helper only — it exists precisely so a test can construct
    /// and inspect the alias case (several distinct provider ids, one RFC)
    /// that motivated the provider-id refactor. It must never be used to pick
    /// a mutation target.
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
            if state.value.withLock({ $0.invalidIdOnGetProviderIds.contains(providerId) }) {
                return .bytes(Self.invalidIdErrorBody(providerId), contentType: "application/json", statusCode: 400)
            }
            let injectedUnclassified400 = state.value.withLock { model -> Bool in
                guard model.unclassified400OnGetProviderIds.contains(providerId) else { return false }
                model.unclassified400OnGetServed += 1
                return true
            }
            if injectedUnclassified400 {
                return .bytes(Self.unclassifiedBadRequestBody(), contentType: "application/json", statusCode: 400)
            }
            let message = state.value.withLock { $0.messagesByProviderId[providerId] }
            guard let message else { return .status(404) }
            return Self.metadataResponse(message)
        }
        http.register(path: "/messages", method: "GET") { [state] request in
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let query = queryItems.first(where: { $0.name == "q" })?.value ?? ""
            let label = queryItems.first(where: { $0.name == "labelIds" })?.value
            let includeSpamTrash = queryItems.first(where: { $0.name == "includeSpamTrash" })?.value == "true"
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
                        // Real Gmail excludes SPAM/TRASH-labeled messages from
                        // ANY list/search response unless includeSpamTrash=true
                        // is sent — regardless of an explicit labelIds= filter
                        // (SPEC-B2). Applies uniformly, matching the real API.
                        if !includeSpamTrash, !message.labels.isDisjoint(with: ["TRASH", "SPAM"]) {
                            return false
                        }
                        if let rfc822MessageId = actionRFC {
                            let isExactMatch = message.rfc822MessageId == rfc822MessageId
                            let isDecoyMatch = model.substringDecoyMatches[message.providerMessageId] == rfc822MessageId
                            guard isExactMatch || isDecoyMatch else { return false }
                            if let label { return message.labels.contains(label) }
                            return Self.satisfiesQueryExclusions(query, labels: message.labels)
                        }
                        if let label { return message.labels.contains(label) }
                        return query == GmailProvider.allMailExclusionQuery
                            && Self.satisfiesQueryExclusions(query, labels: message.labels)
                    }
                    .sorted { $0.providerMessageId < $1.providerMessageId }
                    .prefix(maxResults)
                    .map { ["id": $0.providerMessageId, "threadId": "thread-\($0.providerMessageId)"] }
            }
            var responseObject: [String: Any] = ["messages": refs]
            if let rfc822MessageId = actionRFC,
               state.value.withLock({ $0.spuriousNextPageTokenTargets.contains(rfc822MessageId) }) {
                responseObject["nextPageToken"] = "spurious-canary-page-2"
            }
            let body = (try? JSONSerialization.data(withJSONObject: responseObject)) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        let serveModify: @Sendable (FakeHTTP.Request) -> FakeHTTP.CannedResponse = { [state] request in
            guard request.url.path.hasSuffix("/modify") else { return .status(404) }
            let components = request.url.pathComponents
            guard components.count >= 2 else { return .status(404) }
            let providerId = components[components.count - 2]
            let body = request.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let additions = body["addLabelIds"] as? [String] ?? []
            let removals = body["removeLabelIds"] as? [String] ?? []
            // ONE log append for every attempt, injected or not — the
            // modifyLog is the wire-side non-vacuity oracle for the
            // classification tests, so a rejected attempt must still count.
            let injection = state.value.withLock { model -> ModifyInjection in
                model.modifyLog.append(ModifyCall(
                    providerMessageId: providerId,
                    addLabelIds: additions,
                    removeLabelIds: removals
                ))
                if model.unclassified400ProviderIds.contains(providerId) {
                    model.unclassified400Served += 1
                    return .unclassified400
                }
                if model.invalidId400OnModifyProviderIds.contains(providerId) {
                    model.invalidId400OnModifyServed += 1
                    return .invalidId400
                }
                if model.transient503OnModifyProviderIds.contains(providerId) {
                    model.transient503OnModifyServed += 1
                    return .transient503
                }
                if model.gone410OnModifyProviderIds.contains(providerId) {
                    model.gone410OnModifyServed += 1
                    return .gone410
                }
                return .noneInjected
            }
            switch injection {
            case .unclassified400:
                return .bytes(Self.unclassifiedBadRequestBody(), contentType: "application/json", statusCode: 400)
            case .invalidId400:
                return .bytes(Self.invalidIdErrorBody(providerId), contentType: "application/json", statusCode: 400)
            case .transient503:
                return .status(503)
            case .gone410:
                return .status(410)
            case .noneInjected:
                break
            }
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
        http.register(path: "/messages/", method: "POST") { [state] request in
            let response = serveModify(request)
            let latency = state.value.withLock { $0.modifyLatencySeconds }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
        }
    }

    private static func rfcIdentity(fromSearchQuery query: String) -> String? {
        guard let range = query.range(of: "rfc822msgid:") else { return nil }
        let suffix = query[range.upperBound...]
        return String(suffix.prefix(while: { !$0.isWhitespace }))
    }

    /// Honor the `-in:<role>` exclusions the QUERY itself carries against the
    /// message's labels — real Gmail evaluates whatever query the client sent,
    /// so the fixture must too instead of hardcoding one exclusion set (Fix 1
    /// audit: fixtures model the provider, never our adapter). The LISTING
    /// query (`allMailExclusionQuery`) carries `-in:sent`, so Sent-only mail
    /// stays out of the Archive list (shipped UI behavior); the ACTION-scope
    /// query does NOT, so a self-sent message (labels `{SENT}` or
    /// `{SENT, UNREAD}`) resolves in archive scope — the OLD hardcoded set
    /// mirrored the provider bug that silently no-opped Undo-of-archive for
    /// self-sent mail.
    private static func satisfiesQueryExclusions(_ query: String, labels: Set<String>) -> Bool {
        let roleByToken: [String: String] = [
            "-in:inbox": "INBOX",
            "-in:sent": "SENT",
            "-in:trash": "TRASH",
            "-in:spam": "SPAM",
            "-in:draft": "DRAFT",
        ]
        for (token, label) in roleByToken where query.contains(token) {
            if labels.contains(label) { return false }
        }
        return true
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
