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
        /// The `internalDate` the metadata GET serves and the key `/messages`
        /// lists by (newest first) and evaluates `before:` against — the real
        /// API's order. Nil serves "now".
        let internalDate: Date?
        /// Raw `Received:` header values, final hop first, served ONLY when the
        /// metadata GET asks for `metadataHeaders=Received` (the real API
        /// returns only the requested headers under `format=metadata`).
        let received: [String]
        /// The `text/plain` body the `format=full` GET serves (the backfill's
        /// fetch). Nil serves an empty body, as before.
        let bodyText: String?

        init(
            rfc822MessageId: String,
            providerMessageId: String,
            labels: Set<String>,
            internalDate: Date? = nil,
            received: [String] = [],
            bodyText: String? = nil
        ) {
            self.rfc822MessageId = rfc822MessageId
            self.providerMessageId = providerMessageId
            self.labels = labels
            self.internalDate = internalDate
            self.received = received
            self.bodyText = bodyText
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

    /// One `/messages/{id}/trash` (`trash == true`) or `/untrash` call.
    struct TrashCall: Sendable, Equatable {
        let providerMessageId: String
        let trash: Bool
    }

    /// The labels real Gmail refuses in `messages.modify`.
    static let gmailMaintainedLabelIds: Set<String> = ["SENT", "DRAFT"]

    private struct Message: Sendable {
        let rfc822MessageId: String
        let providerMessageId: String
        var labels: Set<String>
        var internalDate: Date? = nil
        var received: [String] = []
        var bodyText: String? = nil
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

    /// One change the fake applied, served back by `GET /history` the way
    /// Gmail's `history.list` reports it.
    private enum HistoryChange: Sendable {
        case messageAdded
        case messageDeleted
        case labelsAdded([String])
        case labelsRemoved([String])
    }

    private struct HistoryEvent: Sendable {
        let id: Int
        let providerMessageId: String
        let change: HistoryChange
        /// The message's labels after the change.
        let labels: [String]
    }

    private struct State: Sendable {
        var messagesByProviderId: [String: Message]
        /// The mailbox's current `historyId`; every recorded change advances it.
        var historyId = StatefulGmailActionServer.initialHistoryId
        var history: [HistoryEvent] = []
        var userLabels: [String: String]
        let createdLabelId: String?
        /// Label creates still to refuse with 409 whatever `/labels` lists: a
        /// conflicting label deleted elsewhere before the client looks it up.
        var createConflictsRemaining = 0
        var lookupFailuresRemaining = 0
        var lookupFailuresConsumed = 0
        /// Label ids `/messages/{id}/modify` and `/messages` (list) must
        /// reject as gone — simulates a label deleted remotely between
        /// enqueue and drain. Gmail's real shape for this is a structural
        /// `400` (not `404`): https://developers.google.com/workspace/gmail/api/guides/handle-errors
        var deletedLabelIds: Set<String> = []
        var trashLog: [TrashCall] = []
        /// Provider message ids whose `/messages/{id}/trash` and `/untrash`
        /// return Gmail's real `"Invalid id value"` `400`.
        var invalidId400OnTrashProviderIds: Set<String> = []
        /// Provider message ids whose `/messages/{id}/trash` and `/untrash`
        /// fail with an answer that is NOT stale (see `TrashFailure`).
        var trashFailureByProviderId: [String: TrashFailure] = [:]
        var trashFailuresServed = 0
        /// Provider message ids whose `/messages/{id}/modify` returns a
        /// structural `400` whose body matches no shape the adapter
        /// classifies (since #420 "Invalid label" is not one either; it is a
        /// counted failure too) — an UNCLASSIFIED permanent-shaped failure
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
        /// Seconds the `/messages/{id}/modify` response for a given provider
        /// message id is withheld for. Absent (the default) keeps the fixture
        /// instantaneous — only the tests that need a request to cost real
        /// wall-clock time against a deadline pay for it. PER ID rather than
        /// uniform because the shape those tests need is a batch whose members
        /// each fit the deadline while their SUM does not, which a single
        /// latency cannot express without putting every margin in the fixture on
        /// a knife edge. See `holdModify(providerMessageId:forSeconds:)`.
        var modifyLatencyByProviderId: [String: TimeInterval] = [:]
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
        /// Largest page the `/messages` listing serves, the rest behind a
        /// `nextPageToken`. Nil (the default): `maxResults` alone decides the
        /// page size. See `servePagedListings(pageSize:)`.
        var listPageSize: Int?
        /// The generation page tokens are minted in. A token is the offset its
        /// page starts at, `<offset>` in generation 0 and `<offset>~<generation>`
        /// after; one from an older generation (`expireIssuedPageTokens()`), or
        /// not in this form at all, is refused.
        var pageTokenGeneration = 0
        /// The page tokens the listing refused, in order.
        var rejectedPageTokens: [String] = []
        /// While true the listing refuses every request carrying a page token,
        /// the ones it handed out included.
        var rejectsEveryPageToken = false
        /// Injected failures of the message GET `GET /messages/{id}` (the
        /// backfill's full-format fetch included), per provider message id,
        /// served until `clearGetFailures()`.
        var getFailureByProviderId: [String: GetFailure] = [:]
        var getFailuresServedByProviderId: [String: Int] = [:]
        /// How long an injected message-GET failure is withheld before it is
        /// answered, per provider message id. See `injectGetFailure(providerMessageId:_:answeredAfter:)`.
        var getFailureDelayByProviderId: [String: TimeInterval] = [:]
        /// While true, a forced token refresh (the one a `401` triggers) fails,
        /// as when the provider refuses the refresh token or the refresh gets
        /// no answer. The first, unforced token read still succeeds.
        var failsTokenRefresh = false
        var failedTokenRefreshes = 0
        /// Called with the refused token each time the listing refuses a page
        /// token, before the refusal is answered. See `onRejectedPageToken(_:)`.
        var rejectedPageTokenHook: (@Sendable (String) -> Void)?
        /// Called each time a message GET of that provider message id is
        /// served, before it is answered. See `onGet(providerMessageId:_:)`.
        var getHookByProviderId: [String: @Sendable () -> Void] = [:]
        /// An injected failure of the `/messages` listing (action lookups
        /// excluded). See `failListings(status:label:onlyWithPageToken:times:)`.
        var listingFailure: ListingFailure?
        var listingFailuresServed = 0
        /// Seconds every `GET /messages/{id}` naming a provider id is withheld for.
        var getLatencyByProviderId: [String: TimeInterval] = [:]
        /// Seconds every account-wide `is:unread` / `is:starred` list is withheld for.
        var searchListLatency: TimeInterval = 0
        /// At most this many ids per page of an account-wide `is:unread` /
        /// `is:starred` list, whatever `maxResults` asks for (Gmail may answer a
        /// page with fewer than `maxResults`). Nil: `maxResults` alone decides.
        var searchListPageLimit: Int?
        /// At most this many ids per page of a folder list with no date bound (the
        /// backfill walk's), whatever `maxResults` asks for. Nil: `maxResults`.
        var walkListPageLimit: Int?
        /// Parks the next folder list with no date bound until signalled.
        var nextWalkListHold: WalkListHold?
        /// The next this many list requests carrying a page token are answered
        /// with a `400` whose wording says nothing about the page token.
        var tokenedListBadRequestsRemaining = 0
        var badRequestedPageTokens: [String] = []
        /// How far `/profile`'s history id runs ahead of the last record: changes
        /// no record here models (made while a full sync ran) moved it on.
        var profileAhead = 0
        /// `/history` answers `404` (expired) for any `startHistoryId` below this.
        var historyFloor = 0
        /// `/history` answers with more records than one delta takes on.
        var historyTooLong = false

        /// Record the label difference between `before` and `after` as history,
        /// as Gmail does for every label change it applies. Labels the message
        /// already had (or lacked) are not recorded.
        mutating func recordLabelChange(_ providerMessageId: String, before: Set<String>, after: Set<String>) {
            let added = after.subtracting(before).sorted()
            let removed = before.subtracting(after).sorted()
            if !added.isEmpty { record(providerMessageId, .labelsAdded(added), labels: after) }
            if !removed.isEmpty { record(providerMessageId, .labelsRemoved(removed), labels: after) }
        }

        /// Advance the history id and record `change`; `labels` are the message's
        /// labels after it, served as the record's `message.labelIds`.
        mutating func record(_ providerMessageId: String, _ change: HistoryChange, labels: Set<String>) {
            historyId += 1
            history.append(HistoryEvent(
                id: historyId, providerMessageId: providerMessageId, change: change, labels: labels.sorted()))
        }
    }

    private final class StateBox: Sendable {
        let value: Mutex<State>

        init(_ state: State) {
            value = Mutex(state)
        }
    }

    let http = FakeHTTP.Scenario()
    private let state: StateBox

    /// The `historyId` a fresh fake reports before any change is applied.
    static let initialHistoryId = 1000

    /// System labels (`INBOX`, `SENT`, …) served by `/labels` with
    /// `type: system`, so `GmailProvider.fetchFolders` — and therefore a real
    /// `fullSync` — sees the folders a test seeded. Empty by default: the
    /// action-drain tests never list folders.
    private let systemLabels: [String]

    init(
        messages: [Seed],
        userLabels: [String: String] = [:],
        createdLabelId: String? = nil,
        systemLabels: [String] = []
    ) {
        self.systemLabels = systemLabels
        state = StateBox(State(
            messagesByProviderId: Dictionary(
                uniqueKeysWithValues: messages.map {
                    ($0.providerMessageId, Message(
                        rfc822MessageId: $0.rfc822MessageId,
                        providerMessageId: $0.providerMessageId,
                        labels: $0.labels,
                        internalDate: $0.internalDate,
                        received: $0.received,
                        bodyText: $0.bodyText
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
            accessToken: { [state] forceRefresh in
                let refused = forceRefresh && state.value.withLock { model -> Bool in
                    guard model.failsTokenRefresh else { return false }
                    model.failedTokenRefreshes += 1
                    return true
                }
                if refused { throw TokenRefreshRefused() }
                return "stateful-test-token"
            },
            session: http.session
        )
    }

    /// What a refused token refresh throws from the access-token closure.
    struct TokenRefreshRefused: Error {}

    /// Make every forced token refresh fail (`true`) or succeed again (`false`).
    func failTokenRefresh(_ failing: Bool) {
        state.value.withLock { $0.failsTokenRefresh = failing }
    }

    /// How many forced token refreshes were refused.
    func failedTokenRefreshCount() -> Int {
        state.value.withLock { $0.failedTokenRefreshes }
    }

    /// Run `hook` with the refused token whenever the paged listing refuses a
    /// page token, before the refusal is answered: a stand-in for another
    /// writer acting on the folder while the walk's request is in flight.
    func onRejectedPageToken(_ hook: (@Sendable (String) -> Void)?) {
        state.value.withLock { $0.rejectedPageTokenHook = hook }
    }

    /// Run `hook` whenever `GET /messages/{providerMessageId}` is served,
    /// before it is answered (an injected failure included): a stand-in for
    /// another writer acting on the folder while the walk's fetch of that
    /// message is in flight. nil removes it.
    func onGet(providerMessageId: String, _ hook: (@Sendable () -> Void)?) {
        state.value.withLock { $0.getHookByProviderId[providerMessageId] = hook }
    }

    /// Refuse the next `POST /labels` with 409 "Label name exists or
    /// conflicts" while `/labels` keeps listing only what it already holds, as
    /// when the conflicting label is deleted on another device before the
    /// client looks it up by name.
    func refuseNextCreateWithConflict() {
        state.value.withLock { $0.createConflictsRemaining += 1 }
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
    /// but matches no terminal shape the adapter knows (the invalid-id
    /// wording; since #420 an "Invalid label" refusal is not terminal either) —
    /// permanent-SHAPED, not authoritative-terminal.
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

    /// Chronological log of every `/trash` and `/untrash` call.
    func trashLog() -> [TrashCall] {
        state.value.withLock { $0.trashLog }
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

    /// The message is gone from the mailbox (deleted from another client):
    /// every later request naming it gets Gmail's `404`.
    func removeMessage(providerMessageId: String) {
        state.value.withLock { model in
            guard let removed = model.messagesByProviderId.removeValue(forKey: providerMessageId) else { return }
            model.record(providerMessageId, .messageDeleted, labels: removed.labels)
        }
    }

    /// A new message arrives in the mailbox; `/history` reports it as added.
    func addMessage(_ seed: Seed) {
        state.value.withLock { model in
            model.messagesByProviderId[seed.providerMessageId] = Message(
                rfc822MessageId: seed.rfc822MessageId,
                providerMessageId: seed.providerMessageId,
                labels: seed.labels,
                internalDate: seed.internalDate,
                received: seed.received,
                bodyText: seed.bodyText
            )
            model.record(seed.providerMessageId, .messageAdded, labels: seed.labels)
        }
    }

    /// Another client changes a message's labels (read, star, archive, trash,
    /// a user label); `/history` reports the change like any other.
    func applyLabelChange(providerMessageId: String, add: Set<String> = [], remove: Set<String> = []) {
        state.value.withLock { model in
            guard var message = model.messagesByProviderId[providerMessageId] else { return }
            let before = message.labels
            message.labels.formUnion(add)
            message.labels.subtract(remove)
            model.messagesByProviderId[providerMessageId] = message
            model.recordLabelChange(providerMessageId, before: before, after: message.labels)
        }
    }

    /// The mailbox's current `historyId`, the cursor a synced client holds.
    func currentHistoryId() -> String {
        state.value.withLock { String($0.historyId) }
    }

    /// Gmail has dropped the history up to now: `/history` answers `404` for any
    /// `startHistoryId` older than the current one.
    func expireHistory() {
        state.value.withLock { $0.historyFloor = $0.historyId }
    }

    /// While on, `/history` answers with more records than one delta takes on
    /// (`GmailAPI.historyMaxChanges`), as after a burst of changes.
    func answerHistoryTooLong(_ on: Bool) {
        state.value.withLock { $0.historyTooLong = on }
    }

    /// Serve `/profile` with the mailbox's history id (plus `setProfileAhead`).
    /// Opt-in, so a full sync in a suite that never asked for it still captures
    /// no cursor, as before. `/history` is always served.
    func serveProfile() {
        http.register(path: "/profile", method: "GET") { [state] _ in
            let (historyId, total) = state.value.withLock { ($0.historyId + $0.profileAhead, $0.messagesByProviderId.count) }
            return .json(raw: #"{ "emailAddress": "user@example.com", "historyId": "\#(historyId)", "messagesTotal": \#(total) }"#)
        }
    }

    /// Make every `GET /messages/{providerMessageId}` take `seconds` to answer
    /// (0 ends it). The wait is off the transport's loader thread (`.parked`).
    func holdGet(providerMessageId: String, forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.getLatencyByProviderId[providerMessageId] = seconds }
    }

    /// Make every account-wide `is:unread` / `is:starred` list take `seconds`.
    func holdSearchLists(forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.searchListLatency = seconds }
    }

    /// One held backfill-walk list request: `reached` is signalled when the request
    /// arrives (its answer already computed from the server as it stood then),
    /// `release` lets the answer go out.
    final class WalkListHold: @unchecked Sendable {
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        /// Blocks the calling thread until the held request arrives or `seconds`
        /// pass. Synchronous on purpose: call it from a detached task, never
        /// directly from async test code.
        func waitUntilReached(seconds: Double) -> Bool {
            reached.wait(timeout: .now() + seconds) == .success
        }
    }

    /// Hold the next folder list with no date bound (a backfill walk page). Its
    /// answer is computed when it arrives and sent once `release` is signalled,
    /// so a test can change the server and the device in between.
    func holdNextWalkList() -> WalkListHold {
        let hold = WalkListHold()
        state.value.withLock { $0.nextWalkListHold = hold }
        return hold
    }

    /// Answer every folder list with no date bound (a backfill walk page) with at
    /// most `ids` ids, so a walk takes many pages.
    func limitWalkListPages(to ids: Int) {
        state.value.withLock { $0.walkListPageLimit = ids }
    }

    /// Answer the next `count` list requests that carry a page token with a `400`
    /// whose structured error is about something else (`failedPrecondition`).
    func answerTokenedListsWithUnrelatedBadRequest(count: Int) {
        state.value.withLock { $0.tokenedListBadRequestsRemaining = count }
    }

    /// The page tokens answered with that unrelated `400` so far.
    func badRequestedPageTokens() -> [String] {
        state.value.withLock { $0.badRequestedPageTokens }
    }

    /// Answer every account-wide `is:unread` / `is:starred` list page with at
    /// most `ids` ids, so a list takes many pages.
    func limitSearchListPages(to ids: Int) {
        state.value.withLock { $0.searchListPageLimit = ids }
    }

    /// `/profile` answers `ahead` past the last history record, as when changes
    /// land between a delta and the full sync's capture.
    func setProfileAhead(_ ahead: Int) {
        state.value.withLock { $0.profileAhead = ahead }
    }

    /// One `GET /messages` list request as the fake received it.
    struct ListRequest: Sendable, Equatable {
        let labelId: String?
        let query: String
        let includeSpamTrash: Bool
        let pageToken: String?

        /// The epoch seconds of the query's `after:` / `before:` bound, if any.
        func bound(_ name: String) -> Int? {
            query.split(separator: " ").first { $0.hasPrefix("\(name):") }
                .flatMap { Int($0.dropFirst(name.count + 1)) }
        }
    }

    /// Every list request received so far, in order.
    func listRequests() -> [ListRequest] {
        http.recordedCalls().compactMap { call in
            guard call.method == "GET", let components = URLComponents(string: call.url),
                  components.path.hasSuffix("/messages") else { return nil }
            let items = components.queryItems ?? []
            return ListRequest(
                labelId: items.first { $0.name == "labelIds" }?.value,
                query: items.first { $0.name == "q" }?.value ?? "",
                includeSpamTrash: items.first { $0.name == "includeSpamTrash" }?.value == "true",
                pageToken: items.first { $0.name == "pageToken" }?.value)
        }
    }

    /// The provider ids of every `GET /messages/{id}` received so far, in order.
    /// The ids of the `format=full` message GETs (the backfill's fetch), in order.
    func fullMessageGets() -> [String] {
        http.recordedCalls().compactMap { call in
            guard call.method == "GET", let components = URLComponents(string: call.url),
                  components.path.contains("/messages/"),
                  components.queryItems?.contains(where: { $0.name == "format" && $0.value == "full" }) == true
            else { return nil }
            return components.path.split(separator: "/").last.map(String.init)
        }
    }

    func messageGets() -> [String] {
        http.recordedCalls().compactMap { call in
            guard call.method == "GET", let components = URLComponents(string: call.url),
                  components.path.contains("/messages/") else { return nil }
            return components.path.split(separator: "/").last.map(String.init)
        }
    }

    /// A `/messages/{id}/trash` or `/untrash` failure that says nothing about
    /// the message being gone: a transient `503`, or a structural `400` whose
    /// body matches no shape the adapter classifies.
    enum TrashFailure: Sendable {
        case transient503, unclassified400
    }

    /// Fail every `/messages/{id}/trash` and `/untrash` naming
    /// `providerMessageId` with `failure` until `clearTrashFailures()`.
    func injectTrashFailure(providerMessageId: String, _ failure: TrashFailure) {
        state.value.withLock { $0.trashFailureByProviderId[providerMessageId] = failure }
    }

    /// Heal every injected trash/untrash failure, leaving the served count intact.
    func clearTrashFailures() {
        state.value.withLock { $0.trashFailureByProviderId.removeAll() }
    }

    /// How many trash/untrash attempts were refused with an injected failure.
    func trashFailuresServedCount() -> Int {
        state.value.withLock { $0.trashFailuresServed }
    }

    /// Inject Gmail's real `"Invalid id value"` `400` for every
    /// `/messages/{id}/trash` and `/untrash` naming `providerMessageId`.
    func injectInvalidId400OnTrash(providerMessageId: String) {
        _ = state.value.withLock { $0.invalidId400OnTrashProviderIds.insert(providerMessageId) }
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

    /// Make `/messages/{providerMessageId}/modify` take `seconds` to answer.
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
    func holdModify(providerMessageId: String, forSeconds seconds: TimeInterval) {
        state.value.withLock { $0.modifyLatencyByProviderId[providerMessageId] = seconds }
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

    /// Heal every injected exact-ID GET `400`, leaving the served count intact.
    func clearUnclassified400sOnGet() {
        state.value.withLock { $0.unclassified400OnGetProviderIds.removeAll() }
    }

    /// Serve at most `pageSize` ids per `/messages` response (or `maxResults`,
    /// if smaller). Every listing pages as Gmail does, with a `nextPageToken`
    /// while more remain; a request whose `pageToken` is not one this listing
    /// mints, or has since expired, gets a `400`. Gmail documents no wording
    /// for a page token it no longer accepts, so only the status is modelled.
    func servePagedListings(pageSize: Int) {
        state.value.withLock { $0.listPageSize = pageSize }
    }

    /// Expire every page token handed out so far; tokens handed out later
    /// are accepted again.
    func expireIssuedPageTokens() {
        state.value.withLock { $0.pageTokenGeneration += 1 }
    }

    /// While `rejecting`, refuse every paged listing request that carries a
    /// page token, including tokens handed out since.
    func rejectEveryPageToken(_ rejecting: Bool) {
        state.value.withLock { $0.rejectsEveryPageToken = rejecting }
    }

    /// How many listing requests were refused for their page token.
    func rejectedPageTokenCount() -> Int {
        state.value.withLock { $0.rejectedPageTokens.count }
    }

    /// The page tokens the listing refused with a `400`, in order.
    func rejectedPageTokens() -> [String] {
        state.value.withLock { $0.rejectedPageTokens }
    }

    /// A failure the message GET serves instead of the message: a bare HTTP
    /// status (the server answered), or a transport error (no answer at all).
    enum GetFailure: Sendable {
        case status(Int)
        case transport(URLError.Code)
    }

    /// Fail every `GET /messages/{providerMessageId}` with `failure` until
    /// `clearGetFailures()`.
    /// `answeredAfter` withholds each failure for that long before answering
    /// it, so a test can order it after another message's answer.
    func injectGetFailure(providerMessageId: String, _ failure: GetFailure, answeredAfter delay: TimeInterval = 0) {
        state.value.withLock {
            $0.getFailureByProviderId[providerMessageId] = failure
            $0.getFailureDelayByProviderId[providerMessageId] = delay
        }
    }

    /// Heal every injected message-GET failure, leaving the served counts intact.
    func clearGetFailures() {
        state.value.withLock { $0.getFailureByProviderId.removeAll() }
    }

    /// Heal the injected message-GET failure of one message only.
    func clearGetFailure(providerMessageId: String) {
        state.value.withLock { _ = $0.getFailureByProviderId.removeValue(forKey: providerMessageId) }
    }

    /// How many GETs of `providerMessageId` were answered with an injected failure.
    func getFailuresServedCount(providerMessageId: String) -> Int {
        state.value.withLock { $0.getFailuresServedByProviderId[providerMessageId] ?? 0 }
    }

    struct ListingFailure: Sendable {
        let status: Int
        /// When set, the listing gets no answer at all (this transport error)
        /// instead of `status`.
        var transport: URLError.Code?
        let label: String?
        let onlyWithPageToken: Bool
        var remaining: Int?
    }

    /// Answer `/messages` listings with a bare `status`: only those naming
    /// `label` when one is given, only those carrying a `pageToken` when
    /// `onlyWithPageToken`, and for the next `times` matching requests (nil:
    /// until `clearListingFailures()`). Action lookups are never failed by it.
    func failListings(status: Int, label: String? = nil, onlyWithPageToken: Bool = false, times: Int? = nil) {
        state.value.withLock {
            $0.listingFailure = ListingFailure(
                status: status, label: label, onlyWithPageToken: onlyWithPageToken, remaining: times)
        }
    }

    /// Like `failListings(status:label:onlyWithPageToken:times:)`, but the
    /// matching listings get no answer at all: the request fails with the
    /// transport error `code`.
    func failListings(transport code: URLError.Code, label: String? = nil, onlyWithPageToken: Bool = false, times: Int? = nil) {
        state.value.withLock {
            var failure = ListingFailure(
                status: 0, label: label, onlyWithPageToken: onlyWithPageToken, remaining: times)
            failure.transport = code
            $0.listingFailure = failure
        }
    }

    /// Stop failing listings, leaving the served count intact.
    func clearListingFailures() {
        state.value.withLock { $0.listingFailure = nil }
    }

    /// How many listing requests were answered with an injected failure.
    func listingFailuresServedCount() -> Int {
        state.value.withLock { $0.listingFailuresServed }
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

    /// Gmail's structured `400` shape for a page token it does not accept.
    /// The wording is this fake's: Gmail documents none, and the client reads
    /// only the status.
    private static func invalidPageTokenBody() -> Data {
        let message = "Invalid page token."
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

    /// A `400` in Gmail's structured shape whose wording names no parameter.
    private static func unrelatedBadRequestErrorBody() -> Data {
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

    /// Gmail's answer to creating a label whose name is already taken.
    private static func labelNameConflictBody() -> Data {
        let message = "Label name exists or conflicts"
        let object: [String: Any] = [
            "error": [
                "errors": [[
                    "domain": "global",
                    "reason": "duplicate",
                    "message": message,
                ]],
                "code": 409,
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
        http.register(path: "/labels", method: "GET") { [state, systemLabels] _ in
            let system = systemLabels.map {
                ["id": $0, "name": $0, "type": "system", "messagesTotal": 0, "messagesUnread": 0] as [String: Any]
            }
            let labels = system + state.value.withLock { model in
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
            // Gmail refuses a label whose name an existing label already has
            // with 409 "Label name exists or conflicts" (the observed response;
            // the API reference does not list it). Comparing without case is
            // this fake's assumption, the one `findLabelByName` makes. If Gmail
            // instead accepts a name that differs only in case, the client
            // simply creates a new label.
            let conflicts = state.value.withLock { model -> Bool in
                if model.createConflictsRemaining > 0 {
                    model.createConflictsRemaining -= 1
                    return true
                }
                guard let name else { return false }
                return model.userLabels.values.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            if conflicts {
                return .bytes(Self.labelNameConflictBody(), contentType: "application/json", statusCode: 409)
            }
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
        // `history.list`: every recorded change newer than `startHistoryId`,
        // one record each, with the mailbox's current `historyId`. Each record's
        // message carries its labels after the change, as Gmail's does. A cursor
        // below the floor `expireHistory()` set is answered `404` (expired); with
        // `answerHistoryTooLong(true)` the answer holds more records than one
        // delta takes on. A cursor older than the fake's first id is otherwise
        // answered (no expiry unless asked).
        http.register(path: "/history", method: "GET") { [state] request in
            let start = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .first(where: { $0.name == "startHistoryId" })?.value.flatMap(Int.init) ?? 0
            let (events, historyId, expired, tooLong) = state.value.withLock { model in
                (model.history.filter { $0.id > start }, model.historyId, start < model.historyFloor, model.historyTooLong)
            }
            if expired { return .status(404) }
            let records: [[String: Any]]
            if tooLong {
                records = (0...GmailAPI.historyMaxChanges).map { index in
                    ["id": String(historyId), "labelsAdded": [[
                        "message": ["id": "history-burst-\(index)", "threadId": "thread-history-burst-\(index)", "labelIds": ["UNREAD"]],
                        "labelIds": ["UNREAD"],
                    ]]]
                }
            } else {
                records = events.map { event -> [String: Any] in
                    let message: [String: Any] = [
                        "id": event.providerMessageId, "threadId": "thread-\(event.providerMessageId)", "labelIds": event.labels,
                    ]
                    var record: [String: Any] = ["id": String(event.id)]
                    switch event.change {
                    case .messageAdded: record["messagesAdded"] = [["message": message]]
                    case .messageDeleted: record["messagesDeleted"] = [["message": message]]
                    case .labelsAdded(let labels): record["labelsAdded"] = [["message": message, "labelIds": labels]]
                    case .labelsRemoved(let labels): record["labelsRemoved"] = [["message": message, "labelIds": labels]]
                    }
                    return record
                }
            }
            let body = (try? JSONSerialization.data(withJSONObject: [
                "history": records,
                "historyId": String(historyId),
            ])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
        http.register(path: "/messages/", method: "GET") { [state] request in
            let providerId = request.url.pathComponents.last ?? ""
            if let hook = state.value.withLock({ $0.getHookByProviderId[providerId] }) {
                hook()
            }
            let injected = state.value.withLock { model -> (failure: GetFailure, delay: TimeInterval)? in
                guard let failure = model.getFailureByProviderId[providerId] else { return nil }
                model.getFailuresServedByProviderId[providerId, default: 0] += 1
                return (failure, model.getFailureDelayByProviderId[providerId] ?? 0)
            }
            if let injected {
                let response: FakeHTTP.CannedResponse
                switch injected.failure {
                case .status(let code): response = .status(code)
                case .transport(let code): response = .transportError(code)
                }
                guard injected.delay > 0 else { return response }
                return .parked {
                    Thread.sleep(forTimeInterval: injected.delay)
                    return response
                }
            }
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
            let format = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .first { $0.name == "format" }?.value
            let requestedHeaders = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems ?? [])
                .filter { $0.name == "metadataHeaders" }
                .compactMap { $0.value?.lowercased() }
            let response = format == "minimal"
                ? Self.minimalResponse(message)
                : Self.metadataResponse(
                    message, requestedHeaders: Set(requestedHeaders), servesBody: format == "full")
            let latency = state.value.withLock { $0.getLatencyByProviderId[providerId] ?? 0 }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
        }
        http.register(path: "/messages", method: "GET") { [state] request in
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let rawQuery = queryItems.first(where: { $0.name == "q" })?.value ?? ""
            let tokens = rawQuery.split(separator: " ").map(String.init)
            // `before:<epoch>` and `after:<epoch>` are evaluated against
            // `internalDate`, as Gmail does: `before:` strictly below, `after:`
            // strictly above (the stricter reading of an undocumented edge).
            // `is:unread` / `is:starred` test the UNREAD / STARRED labels. These
            // tokens are removed so the remaining query compares as before.
            let beforeEpoch = tokens.first { $0.hasPrefix("before:") }.flatMap { Double($0.dropFirst("before:".count)) }
            let afterEpoch = tokens.first { $0.hasPrefix("after:") }.flatMap { Double($0.dropFirst("after:".count)) }
            let wantsUnread = tokens.contains("is:unread")
            let wantsStarred = tokens.contains("is:starred")
            let query = tokens
                .filter { !$0.hasPrefix("before:") && !$0.hasPrefix("after:") && $0 != "is:unread" && $0 != "is:starred" }
                .joined(separator: " ")
            let pageToken = queryItems.first(where: { $0.name == "pageToken" })?.value
            let label = queryItems.first(where: { $0.name == "labelIds" })?.value
            let includeSpamTrash = queryItems.first(where: { $0.name == "includeSpamTrash" })?.value == "true"
            let requestedMaxResults = queryItems.first(where: { $0.name == "maxResults" })?.value
                .flatMap(Int.init) ?? Int.max
            let searchPageLimit = (wantsUnread || wantsStarred) ? state.value.withLock { $0.searchListPageLimit } : nil
            let isWalkList = label != nil && beforeEpoch == nil && afterEpoch == nil && query.isEmpty
            let walkPageLimit = isWalkList ? state.value.withLock { $0.walkListPageLimit } : nil
            let maxResults = min(requestedMaxResults, searchPageLimit ?? walkPageLimit ?? Int.max)
            if let token = pageToken,
               state.value.withLock({ model -> Bool in
                   guard model.tokenedListBadRequestsRemaining > 0 else { return false }
                   model.tokenedListBadRequestsRemaining -= 1
                   model.badRequestedPageTokens.append(token)
                   return true
               }) {
                return .bytes(Self.unrelatedBadRequestErrorBody(), contentType: "application/json", statusCode: 400)
            }
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
            let listingFailure = state.value.withLock { model -> ListingFailure? in
                guard actionRFC == nil, var failure = model.listingFailure else { return nil }
                if let only = failure.label, only != label { return nil }
                if failure.onlyWithPageToken && pageToken == nil { return nil }
                if let remaining = failure.remaining {
                    failure.remaining = remaining - 1
                    model.listingFailure = remaining > 1 ? failure : nil
                }
                model.listingFailuresServed += 1
                return failure
            }
            if let listingFailure {
                if let code = listingFailure.transport { return .transportError(code) }
                return .status(listingFailure.status)
            }
            let matches = state.value.withLock { model in
                model.messagesByProviderId.values
                    .filter { message in
                        // Real Gmail excludes SPAM/TRASH-labeled messages from
                        // ANY list/search response unless includeSpamTrash=true
                        // is sent — regardless of an explicit labelIds= filter
                        // (SPEC-B2). Applies uniformly, matching the real API.
                        if !includeSpamTrash, !message.labels.isDisjoint(with: ["TRASH", "SPAM"]) {
                            return false
                        }
                        let internalEpoch = (message.internalDate ?? Date()).timeIntervalSince1970
                        if let beforeEpoch, internalEpoch >= beforeEpoch { return false }
                        if let afterEpoch, internalEpoch <= afterEpoch { return false }
                        if wantsUnread, !message.labels.contains("UNREAD") { return false }
                        if wantsStarred, !message.labels.contains("STARRED") { return false }
                        if let rfc822MessageId = actionRFC {
                            let isExactMatch = message.rfc822MessageId == rfc822MessageId
                            let isDecoyMatch = model.substringDecoyMatches[message.providerMessageId] == rfc822MessageId
                            guard isExactMatch || isDecoyMatch else { return false }
                            if let label { return message.labels.contains(label) }
                            return Self.satisfiesQueryExclusions(query, labels: message.labels)
                        }
                        // `labelIds` AND the query's tokens above.
                        if let label { return message.labels.contains(label) }
                        // An account-wide search (`is:unread`, `is:starred`).
                        if (wantsUnread || wantsStarred) && query.isEmpty { return true }
                        return query == GmailProvider.allMailExclusionQuery
                            && Self.satisfiesQueryExclusions(query, labels: message.labels)
                    }
                    // Real order: `internalDate` descending; the id is only a
                    // tiebreak so seeds without a date keep the old stable order.
                    .sorted {
                        let lhs = $0.internalDate ?? .distantPast
                        let rhs = $1.internalDate ?? .distantPast
                        if lhs != rhs { return lhs > rhs }
                        return $0.providerMessageId < $1.providerMessageId
                    }
                    .map { ["id": $0.providerMessageId, "threadId": "thread-\($0.providerMessageId)"] }
            }
            // Pages as Gmail serves them: at most `maxResults` ids (or a smaller
            // page this fake was told to serve) and a `nextPageToken` while more
            // remain. A token is the offset its page starts at, in the current
            // generation (`pageTokenGeneration`); any other token gets a `400`.
            let page = state.value.withLock { model -> (refs: [[String: String]], nextPageToken: String?)? in
                let pageSize = min(maxResults, model.listPageSize ?? Int.max)
                var start = 0
                if let pageToken {
                    let parts = pageToken.split(separator: "~", omittingEmptySubsequences: false)
                    let generation = parts.count == 2 ? Int(parts[1]) : (parts.count == 1 ? 0 : nil)
                    guard !model.rejectsEveryPageToken,
                          let offset = parts.first.flatMap({ Int($0) }), offset >= 0,
                          generation == model.pageTokenGeneration else {
                        model.rejectedPageTokens.append(pageToken)
                        return nil
                    }
                    start = min(offset, matches.count)
                }
                let end = pageSize >= matches.count - start ? matches.count : start + pageSize
                var next: String?
                if end < matches.count {
                    next = model.pageTokenGeneration == 0 ? "\(end)" : "\(end)~\(model.pageTokenGeneration)"
                }
                return (Array(matches[start..<end]), next)
            }
            guard let page else {
                if let pageToken, let hook = state.value.withLock({ $0.rejectedPageTokenHook }) {
                    hook(pageToken)
                }
                return .bytes(Self.invalidPageTokenBody(), contentType: "application/json", statusCode: 400)
            }
            var responseObject: [String: Any] = ["messages": page.refs]
            if let next = page.nextPageToken {
                responseObject["nextPageToken"] = next
            }
            if let rfc822MessageId = actionRFC,
               state.value.withLock({ $0.spuriousNextPageTokenTargets.contains(rfc822MessageId) }) {
                responseObject["nextPageToken"] = "spurious-canary-page-2"
            }
            let body = (try? JSONSerialization.data(withJSONObject: responseObject)) ?? Data()
            if isWalkList, let hold = state.value.withLock({ model -> WalkListHold? in
                defer { model.nextWalkListHold = nil }
                return model.nextWalkListHold
            }) {
                return .parked {
                    hold.reached.signal()
                    hold.release.wait()
                    return .bytes(body, contentType: "application/json")
                }
            }
            let latency = (wantsUnread || wantsStarred) ? state.value.withLock { $0.searchListLatency } : 0
            guard latency > 0 else { return .bytes(body, contentType: "application/json") }
            return .parked { Thread.sleep(forTimeInterval: latency); return .bytes(body, contentType: "application/json") }
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
            // Gmail keeps SENT and DRAFT itself: its labels guide marks both as
            // not manually applicable, and `messages.modify` naming either, to
            // add or to remove, is refused with this same `400`.
            if let maintained = (additions + removals).first(where: { Self.gmailMaintainedLabelIds.contains($0) }) {
                return .bytes(Self.invalidLabelErrorBody(maintained), contentType: "application/json", statusCode: 400)
            }
            // "You can't apply labels to draft messages": Gmail refuses adding a
            // label to a draft's message. Its exact wording is not modelled, so
            // the refusal carries no shape the adapter classifies.
            let isDraftMessage = state.value.withLock {
                $0.messagesByProviderId[providerId]?.labels.contains("DRAFT") == true
            }
            if isDraftMessage && !additions.isEmpty {
                return .bytes(Self.unclassifiedBadRequestBody(), contentType: "application/json", statusCode: 400)
            }
            let found = state.value.withLock { model -> Bool in
                guard var message = model.messagesByProviderId[providerId] else { return false }
                let before = message.labels
                message.labels.formUnion(additions)
                message.labels.subtract(removals)
                model.messagesByProviderId[providerId] = message
                model.recordLabelChange(providerId, before: before, after: message.labels)
                return true
            }
            return found ? .json(raw: "{}") : .status(404)
        }
        // `messages.trash` / `messages.untrash`: add or remove TRASH, on any
        // message, a draft's message included.
        let serveTrash: @Sendable (FakeHTTP.Request, Bool) -> FakeHTTP.CannedResponse = { [state] request, trash in
            let components = request.url.pathComponents
            guard components.count >= 2 else { return .status(404) }
            let providerId = components[components.count - 2]
            let (invalidId, failure) = state.value.withLock { model -> (Bool, TrashFailure?) in
                model.trashLog.append(TrashCall(providerMessageId: providerId, trash: trash))
                let failure = model.trashFailureByProviderId[providerId]
                if failure != nil { model.trashFailuresServed += 1 }
                return (model.invalidId400OnTrashProviderIds.contains(providerId), failure)
            }
            switch failure {
            case .transient503:
                return .status(503)
            case .unclassified400:
                return .bytes(Self.unclassifiedBadRequestBody(), contentType: "application/json", statusCode: 400)
            case nil:
                break
            }
            if invalidId {
                return .bytes(Self.invalidIdErrorBody(providerId), contentType: "application/json", statusCode: 400)
            }
            let found = state.value.withLock { model -> Bool in
                guard var message = model.messagesByProviderId[providerId] else { return false }
                let before = message.labels
                if trash { message.labels.insert("TRASH") } else { message.labels.remove("TRASH") }
                model.messagesByProviderId[providerId] = message
                model.recordLabelChange(providerId, before: before, after: message.labels)
                return true
            }
            return found ? .json(raw: "{}") : .status(404)
        }
        http.register(path: "/messages/", method: "POST") { [state] request in
            if request.url.path.hasSuffix("/trash") { return serveTrash(request, true) }
            if request.url.path.hasSuffix("/untrash") { return serveTrash(request, false) }
            let response = serveModify(request)
            let components = request.url.pathComponents
            let providerId = components.count >= 2 ? components[components.count - 2] : ""
            let latency = state.value.withLock { $0.modifyLatencyByProviderId[providerId] ?? 0 }
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
    static func satisfiesQueryExclusions(_ query: String, labels: Set<String>) -> Bool {
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

    /// A payload `body`: `text` base64url-encoded, as Gmail serves it; empty for nil.
    private static func bodyObject(_ text: String?) -> [String: Any] {
        guard let text else { return ["size": 0, "data": ""] }
        let data = Data(text.utf8)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ["size": data.count, "data": encoded]
    }

    /// `format=minimal`: ids, labels and dates only — no payload.
    private static func minimalResponse(_ message: Message) -> FakeHTTP.CannedResponse {
        let object: [String: Any] = [
            "id": message.providerMessageId,
            "threadId": "thread-\(message.providerMessageId)",
            "labelIds": Array(message.labels).sorted(),
            "internalDate": String(Int64((message.internalDate ?? Date()).timeIntervalSince1970 * 1_000)),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .bytes(data, contentType: "application/json")
    }

    private static func metadataResponse(
        _ message: Message, requestedHeaders: Set<String> = [], servesBody: Bool = false
    ) -> FakeHTTP.CannedResponse {
        let internalMs = String(Int64((message.internalDate ?? Date()).timeIntervalSince1970 * 1_000))
        var headers: [[String: String]] = message.received.map { ["name": "Received", "value": $0] }
        headers += [
            ["name": "Message-ID", "value": "<\(message.rfc822MessageId)>"],
            ["name": "Subject", "value": "Stateful action message"],
            ["name": "From", "value": "sender@example.com"],
            ["name": "To", "value": "recipient@example.com"],
        ]
        // `format=metadata` + `metadataHeaders=…` returns ONLY the named headers.
        if !requestedHeaders.isEmpty {
            headers = headers.filter { requestedHeaders.contains($0["name"]!.lowercased()) }
        }
        let object: [String: Any] = [
            "id": message.providerMessageId,
            "threadId": "thread-\(message.providerMessageId)",
            "labelIds": Array(message.labels).sorted(),
            "internalDate": internalMs,
            "payload": [
                "mimeType": "text/plain",
                "headers": headers,
                "body": Self.bodyObject(servesBody ? message.bodyText : nil),
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .bytes(data, contentType: "application/json")
    }
}
