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
        /// Graph categories the server already holds for this message — the
        /// stand-in for categories set by Outlook desktop, Outlook web or a
        /// server-side rule. Defaults to empty so every pre-existing seed
        /// keeps its meaning.
        let categories: [String]

        init(
            rfc822MessageId: String,
            providerMessageId: String,
            folderId: String,
            isRead: Bool = false,
            isFlagged: Bool = false,
            receivedAt: Date = Date(),
            categories: [String] = []
        ) {
            self.rfc822MessageId = rfc822MessageId
            self.providerMessageId = providerMessageId
            self.folderId = folderId
            self.isRead = isRead
            self.isFlagged = isFlagged
            self.receivedAt = receivedAt
            self.categories = categories
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
        var categories: [String] = []
    }

    private struct State: Sendable {
        var messagesByProviderId: [String: Message]
        var nextMoveGeneration = 1
        var lookupFailuresRemaining = 0
        var lookupFailuresConsumed = 0
        var mutationFailuresRemaining = 0
        /// PATCH-only failure budget. Separate from `mutationFailuresRemaining`
        /// (which any mutating verb consumes) so a test can fail the FOLLOWER's
        /// verb without touching the `/move` that precedes it in the same lane.
        var patchFailuresRemaining = 0
        /// When true EVERY mutating verb answers 503, for as long as it is set —
        /// a permanent fault, as opposed to the one-shot budgets above. Modeled
        /// as its own flag rather than a huge budget so a test asserts "the lane
        /// is halted", not "the budget outlived the drain".
        var allMutationsFail = false
        /// Provider ids whose NEXT `/move` answers 503 and applies nothing.
        /// One-shot per id — the id is removed when it fires. Scoped to an id
        /// rather than to a count because the shape it exists for is a BATCH
        /// whose earlier member must succeed.
        var oneShotMoveFailureIds: Set<String> = []
        /// Handed to the NEXT `/move` to arrive, which blocks on it until the
        /// TEST signals it. One-shot; a second move is not held.
        var nextMoveHold: DispatchSemaphore?
        var heldMoveCount = 0
        /// RFC Message-IDs whose source-folder `$filter` search
        /// (`resolveActionMessageId`'s first-page fetch) returns a
        /// structural `400` whose body matches NO known terminal shape (not
        /// `ErrorInvalidIdMalformed`, not 404/410) — an UNCLASSIFIED
        /// permanent-shaped failure. Drives the persistent-failure
        /// chain-demotion path for RFC members.
        var unclassified400RFCs: Set<String> = []
        var unclassified400Served = 0
        /// Seconds a `PATCH /messages/{id}` response is withheld for, per
        /// provider message id. Absent (the default) keeps the fixture
        /// instantaneous. PER ID rather than uniform because the shape the
        /// deadline tests need is a batch whose members each fit the operation
        /// deadline while their SUM does not, which one latency cannot express
        /// without putting every margin on a knife edge.
        /// See `holdPatch(providerMessageId:forSeconds:)`.
        var patchLatencyByProviderId: [String: TimeInterval] = [:]
        /// The `/move` counterpart of `patchLatencyByProviderId`.
        /// See `holdMove(providerMessageId:forSeconds:)`.
        var moveLatencyByProviderId: [String: TimeInterval] = [:]
    }

    private final class StateBox: Sendable {
        let value: Mutex<State>

        init(_ state: State) {
            value = Mutex(state)
        }
    }

    let http = FakeHTTP.Scenario()
    private let state: StateBox
    /// Whether `/move` REALLOCATES the resource id, which is what Graph does on
    /// the default mutable-id scheme and therefore the default here.
    ///
    /// `false` models the other real tenant configuration — an id that survives
    /// the move — and exists so a test can prove that an assertion about the
    /// churning case is not passing for a reason unrelated to the churn
    /// (two-sided non-vacuity). Both arms still answer `/move` with the moved
    /// message resource, because Graph does; only the `id` on it differs.
    private let churnsIdOnMove: Bool

    init(messages: [Seed], churnsIdOnMove: Bool = true) {
        self.churnsIdOnMove = churnsIdOnMove
        state = StateBox(State(messagesByProviderId: Dictionary(
            uniqueKeysWithValues: messages.map {
                ($0.providerMessageId, Message(
                    rfc822MessageId: $0.rfc822MessageId,
                    providerMessageId: $0.providerMessageId,
                    folderId: $0.folderId,
                    isRead: $0.isRead,
                    isFlagged: $0.isFlagged,
                    receivedAt: $0.receivedAt,
                    categories: $0.categories
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

    /// The minimal request shape `failNextLookup()` can consume: a
    /// source-folder listing whose `$filter` names an RFC identity in angle
    /// brackets. The `$filter` is the only part the hook keys on, because the
    /// `/mailFolders/` route extracts the bracketed identity via
    /// `rfcIdentity(fromLookupURL:)` and rejects a `$filter` carrying none.
    ///
    /// ⚑ NO REFERENCE — INVENTED. This is NOT the reference's request shape:
    /// `v2final:TabMail/Providers/ExchangeProvider.swift`'s
    /// `resolveActionMessageId` sent `$select=id,parentFolderId,internetMessageId`
    /// and `$top=2` alongside the `$filter`, where this sends `$select=id` and
    /// no `$top`. `v3` has no production path that sends any such request — the
    /// RFC-resolution layer is exactly what D4 removed, and
    /// `ExchangeProvider.search` routes a caller's query into `$search`, never
    /// into an `internetMessageId` `$filter` — so this URL exists only so a
    /// FIXTURE SELF-CHECK can prove the hook, route and counter are alive.
    /// Without one, every `consumedLookupFailureCount() == 0` assertion in the
    /// suite would be STRUCTURALLY zero: unfalsifiable, and therefore no
    /// evidence at all. It does not stand in for the reference's adapter-level
    /// `== 1`, which nothing on `v3` can produce.
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

    /// Fail the next PATCH (and only a PATCH) with 503.
    ///
    /// `failNextMutation()` is consumed by whichever mutating verb happens to
    /// arrive first, which in a move-then-flag lane is the MOVE. This seam exists
    /// so a test can fail the FOLLOWER while letting its predecessor's move
    /// succeed — the shape that proves a re-addressed follower stays queued at its
    /// NEW id rather than being retried at the dead one.
    func failNextPatch() {
        state.value.withLock { $0.patchFailuresRemaining += 1 }
    }

    /// Turn a PERMANENT mutation fault on or off: while on, every mutating verb
    /// answers 503 and no wire effect lands.
    ///
    /// Distinct from the one-shot budgets on purpose. A fuzz round that wants
    /// "this lane halts and stays halted for the whole round" cannot express that
    /// with a budget — a budget that runs out mid-round silently turns the round
    /// into a transient-fault round, and the round's oracle ("exactly the halted
    /// state is retained") would then be asserted against the wrong scenario.
    func failAllMutations(_ failing: Bool) {
        state.value.withLock { $0.allMutationsFail = failing }
    }

    /// Fail the NEXT `/move` of exactly ONE provider id with 503, applying
    /// nothing, and let every other member of the same batch through.
    ///
    /// Neither existing mutation seam can express this. `failNextMutation()` is
    /// a COUNT, consumed by whichever mutating verb arrives first — in a
    /// two-member move that is the FIRST member — and `failAllMutations(_:)`
    /// fails every member. The shape this exists for is the opposite one: a
    /// batch whose EARLIER member the provider proved (so Graph has already
    /// reallocated that member's id) while a LATER member failed, which is what
    /// routes an operation through `AccountManager.retirePartiallyCompletedOp`
    /// rather than the whole-op retirement. Nothing else in the fixture can
    /// produce a partial `MoveOutcome`.
    ///
    /// One-shot per id, in the style of `holdNextMove()`: the id is removed the
    /// moment it fires, so the retry after the fault lands normally. 503 rather
    /// than 404 deliberately — a transient refusal leaves the unproven member
    /// durably queued, where a 404 would make it an authoritative-stale drop and
    /// change what the calling test measures.
    func failMoveOnce(providerMessageId: String) {
        _ = state.value.withLock { $0.oneShotMoveFailureIds.insert(providerMessageId) }
    }

    /// Make `PATCH /messages/{providerMessageId}` take `seconds` to answer.
    ///
    /// Distinct from `holdNextMove()`, which is a GATE the test opens: this is a
    /// fixed cost the request pays on its own, which is what a deadline test
    /// needs — a loop must be able to outrun the operation deadline with no
    /// participation from the test body. The wait happens in
    /// `CannedResponse.parked`, i.e. off the transport's loader thread, and the
    /// handler's synchronous part (state mutation, failure budgets) still runs in
    /// request order before it.
    func holdPatch(providerMessageId: String, forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.patchLatencyByProviderId[providerMessageId] = seconds }
    }

    /// The `/move` counterpart of `holdPatch(providerMessageId:forSeconds:)`.
    func holdMove(providerMessageId: String, forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.moveLatencyByProviderId[providerMessageId] = seconds }
    }

    /// Block the NEXT `/move` inside the route until the returned closure is
    /// called. One-shot: a later move is not held.
    ///
    /// The wait happens inside the parked closure the `/move` route hands to
    /// `FakeHTTP.CannedResponse.parked`, which the transport evaluates on a
    /// BACKGROUND QUEUE — not on the loader thread `URLProtocol.startLoading()`
    /// runs on, and not on the test's thread, so the release closure can be
    /// called from the test body and every other route keeps being served while
    /// this move waits. It is deliberately BOUNDED: a test that forgets to
    /// release must fail on its own assertion, not hang the suite forever, and
    /// the bound is comfortably inside `SyncConfig.pendingOperationTimeoutSeconds`
    /// (15 s) so a held move never becomes a queue TIMEOUT — which would change
    /// what the test is measuring from "ordering" to "timeout handling".
    ///
    /// ⚠️ THIS IS A HOLD, NOT AN OVERLAP DETECTOR, AND THIS FIXTURE HAS NO
    /// OVERLAP DETECTOR — deliberately. An earlier revision added a
    /// `movesInFlight`/`maxMovesInFlight` counter sampled inside the `/move`
    /// route, plus a positive control that parked one move and drove a second
    /// concurrently. The control FAILED: peak stayed at `1` across a 3 s window
    /// (`i114-iso1.log`, 2026-09-05).
    ///
    /// ⚠️ THAT MEASUREMENT WAS OF THE OLD, BLOCKING HOLD, AND ITS STATED REASON IS
    /// NOW STALE. It concluded that `URLProtocol`-backed transports do not admit a
    /// second request while an earlier one blocks inside `startLoading()`. What
    /// was actually true is that the hold ITSELF occupied the loader thread, and
    /// whether a concurrent request got a loader thread of its own was a
    /// scheduling race — measured 3 red in 8 runs of the failed-account requeue
    /// test, which needs a DIFFERENT route served while a move is parked. Parking
    /// the response off the loader thread removed that race, so a second request
    /// IS now served while a move is held. The conclusion nevertheless stands for
    /// the reason the counter was removed: a route-level `overlapObserved` still
    /// measures the transport's scheduling, not whether the QUEUE serialized, so
    /// asserting on it would be vacuous in exactly the direction the assertion was
    /// supposed to exclude — and a counter that now reports overlap would be worse
    /// than one that never did, because it would look like evidence.
    ///
    /// The overlap oracle for the drain therefore lives one layer up, where
    /// concurrency is real: `AccountManagerQueueDrainTests`'
    /// `setMoveHook` in-flight counter, and — for Graph — the ORDER a follower's
    /// verb reaches the wire in (`OutlookQueueHandoffTests` T1) plus
    /// `PendingQueueLaneTests`' direct assertion on `buildLanes`.
    func holdNextMove() -> @Sendable () -> Void {
        let gate = DispatchSemaphore(value: 0)
        state.value.withLock { $0.nextMoveHold = gate }
        return { gate.signal() }
    }

    /// How many `/move` requests were actually held by `holdNextMove()`. A test
    /// that arms the hold and then reads `0` here is not exercising the hold at
    /// all, and its conclusion would be structurally vacuous.
    func heldMoveCount() -> Int {
        state.value.withLock { $0.heldMoveCount }
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

    /// The Graph categories the server currently holds for `providerMessageId`,
    /// or `nil` if no such resource exists. Deliberately NOT folded into
    /// `Snapshot`: that type is `Equatable` and compared whole by an existing
    /// test, so widening it would silently change what that comparison asserts.
    ///
    /// This is the wire oracle for Outlook user labels — a label on Outlook IS a
    /// message category, so "did the user's label reach the server, and did it
    /// leave the server's other categories alone" is exactly a question about
    /// this array.
    func categories(providerMessageId: String) -> [String]? {
        state.value.withLock { $0.messagesByProviderId[providerMessageId]?.categories }
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
        let servePatch: @Sendable (FakeHTTP.Request) -> FakeHTTP.CannedResponse = { [state] request in
            let patchFailed = state.value.withLock { model -> Bool in
                guard model.patchFailuresRemaining > 0 else { return false }
                model.patchFailuresRemaining -= 1
                return true
            }
            guard !patchFailed else { return .status(503) }
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
                // Graph REPLACES the whole `categories` array on PATCH — it is
                // not a merge. Modeling the replacement is the entire point:
                // an adapter that PATCHed blindly would visibly destroy a
                // category this fixture was seeded with.
                if let categories = body["categories"] as? [String] {
                    message.categories = categories
                }
                model.messagesByProviderId[providerId] = message
                return true
            }
            return found
                ? .json(raw: "{\"id\":\"\(providerId)\"}")
                : .status(404)
        }
        http.register(path: "/messages/", method: "PATCH") { [state] request in
            let response = servePatch(request)
            let providerId = Self.messageId(from: request.url, move: false) ?? ""
            let latency = state.value.withLock { $0.patchLatencyByProviderId[providerId] ?? 0 }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
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
        http.register(path: "/messages/", method: "POST") { [state, churnsIdOnMove] request in
            // One-shot hold, taken before any early return so a test that arms it
            // parks every move that reaches the route, not only the ones that
            // would have succeeded. Taking it is the SYNCHRONOUS part and stays
            // on the loader thread, so `heldMoveCount` still rises the moment the
            // move reaches the route and `awaitHeldMoves` keeps its meaning.
            if let gate = state.value.withLock({ model -> DispatchSemaphore? in
                guard let gate = model.nextMoveHold else { return nil }
                model.nextMoveHold = nil
                model.heldMoveCount += 1
                return gate
            }) {
                // 🚨 THE WAIT HAPPENS OFF THE TRANSPORT. `FakeHTTP.CannedResponse.parked`
                // evaluates this closure on a background queue, so the loader
                // thread returns immediately and every OTHER route keeps being
                // served while this move sits in the gate. Waiting here directly
                // used to occupy the loader thread, which made "a second, different
                // request is served while a move is parked" a scheduling race and
                // flaked the failed-account requeue test (measured 3 red in 8
                // standalone runs on unmodified production code).
                //
                // Nothing else about the hold changed: the model is still mutated
                // only AFTER the release, because the whole rest of the handler is
                // inside the parked closure.
                //
                // Bounded: 10 s is comfortably inside the queue's 15 s
                // `pendingOperationTimeoutSeconds`, so a forgotten release fails an
                // assertion instead of converting the test into a timeout test.
                return .parked {
                    _ = gate.wait(timeout: .now() + 10)
                    return Self.serveMove(request, state: state, churnsIdOnMove: churnsIdOnMove)
                }
            }
            let response = Self.serveMove(request, state: state, churnsIdOnMove: churnsIdOnMove)
            let providerId = Self.messageId(from: request.url, move: true) ?? ""
            let latency = state.value.withLock { $0.moveLatencyByProviderId[providerId] ?? 0 }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
        }
    }

    /// The `/move` route's whole body, verbatim, factored out so the held and
    /// unheld paths run the SAME code — the held one just runs it after the gate
    /// opens, on a background queue rather than the transport's loader thread.
    private static func serveMove(
        _ request: FakeHTTP.Request, state: StateBox, churnsIdOnMove: Bool
    ) -> FakeHTTP.CannedResponse {
        guard !Self.consumeMutationFailure(state) else { return .status(503) }
        guard let providerId = Self.messageId(from: request.url, move: true) else {
            return .status(404)
        }
        // The id-scoped one-shot fault (`failMoveOnce(providerMessageId:)`).
        // Checked HERE, after the id is parsed, because it keys on that id, and
        // it consumes only when it actually fires — so an armed id that a test
        // never moves stays armed rather than being eaten by a sibling member.
        guard !state.value.withLock({ $0.oneShotMoveFailureIds.remove(providerId) != nil }) else {
            return .status(503)
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
            let movedId = churnsIdOnMove
                ? "graph/moved+\(model.nextMoveGeneration)="
                : prior.providerMessageId
            model.nextMoveGeneration += 1
            let next = Message(
                rfc822MessageId: prior.rfc822MessageId,
                providerMessageId: movedId,
                folderId: destination,
                isRead: prior.isRead,
                isFlagged: prior.isFlagged,
                receivedAt: prior.receivedAt,
                categories: prior.categories
            )
            model.messagesByProviderId[movedId] = next
            return next
        }
        guard let moved else { return .status(404) }
        let response = (try? JSONSerialization.data(withJSONObject: Self.graphRow(moved))) ?? Data()
        return .bytes(response, contentType: "application/json")
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
            // The permanent fault is checked FIRST and consumes nothing — a
            // one-shot budget must not be silently eaten by a round that is
            // failing everything anyway.
            if model.allMutationsFail { return true }
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
            "categories": message.categories,
            "bodyPreview": "",
            "body": ["contentType": "text", "content": "Stateful draft body"],
            "parentFolderId": message.folderId,
        ]
    }
}
