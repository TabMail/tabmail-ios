/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Graph's change model for `StatefulExchangeActionServer`: per-folder message
/// delta (`/mailFolders/{id}/messages/delta`), the mail-folder delta
/// (`/mailFolders/delta`), the folder tree `fetchFolders` lists, and JSON
/// batching (`POST /$batch`).
///
/// What it models, from Graph's documentation (message-delta,
/// delta-query-overview) and the 2026-11-11 measurements:
/// - a round chain keeps the `$select` of its first request; every later link
///   carries it, so a `$select` on a link is ignored;
/// - the first round lists every message in the folder, each with every
///   selected field;
/// - a later round lists what changed since the previous round's delta link:
///   a message created in or moved into the folder carries every selected field;
///   a read-state-only change carries `id` and `isRead`; a flag or category
///   change carries every selected field; a message deleted or moved out is
///   `@removed`;
/// - pages are keyset-paged by id, so a message removed during a round never
///   shifts another out of it; a change made during a round is in the next one;
/// - the page size is `Prefer: odata.maxpagesize` (Graph's observed default 10
///   without it).
/// Every message change, the client's own included, is logged, as Graph reports
/// both.
struct DeltaModel: Sendable {
    enum Kind: Sendable { case created, read, flag, categories, removed }

    struct Entry: Sendable {
        let seq: Int
        let folderId: String
        let messageId: String
        let kind: Kind
    }

    /// A link the model handed out. `from` nil = the chain's first round.
    struct Token: Sendable {
        let folderId: String
        let select: [String]?
        let from: Int?
        let end: Int
        /// Keyset position inside the round; nil = a delta link (the next round
        /// starts at `end`).
        let after: String?
        let isDeltaLink: Bool
    }

    struct FakeFolder: Sendable {
        let id: String
        var name: String
        var wellKnownName: String?
        var parentId: String?
        var hidden: Bool
        var odataType: String?
    }

    var seq = 0
    var entries: [Entry] = []
    var tokens: [String: Token] = [:]
    var tokenSerial = 0
    /// Folder id -> the status every link issued for it so far answers.
    var refusedTokens: [String: (status: Int, tokens: Set<String>)] = [:]
    /// One-shot failures of message delta pages, served in order.
    var pageFailures: [FakeHTTP.CannedResponse] = []
    var pageFailuresServed = 0
    /// Seconds a message delta page is withheld for.
    var pageLatency: TimeInterval = 0
    /// One-shot failures of `$batch` requests, served in order.
    var batchFailures: [FakeHTTP.CannedResponse] = []
    var batchWidths: [Int] = []
    var batchLatency: TimeInterval = 0
    /// Per message id, the answer its `$batch` item gets instead of the message:
    /// a status and a raw JSON body (any JSON value), served until cleared.
    var batchItemAnswers: [String: (status: Int, body: String?)] = [:]

    // Folder tree
    var folders: [String: FakeFolder] = [:]
    var folderOrder: [String] = []
    /// (seq, folder id, removed)
    var folderEntries: [(seq: Int, folderId: String, removed: Bool)] = []
    var folderTokens: [String: Int] = [:]
    /// Whether the mail-folder delta lists hidden folders (not documented; the
    /// risky reading is that it does not).
    var folderDeltaListsHidden = false
    /// Whether a message change in a folder produces a mail-folder delta record
    /// for it (its counts changed).
    var countChangesProduceFolderRecords = true
    var refuseFolderTokens: Int?

    mutating func log(folderId: String, messageId: String, kind: Kind) {
        seq += 1
        entries.append(Entry(seq: seq, folderId: folderId, messageId: messageId, kind: kind))
        if countChangesProduceFolderRecords, folders[folderId] != nil {
            folderEntries.append((seq, folderId, false))
        }
    }

    mutating func issue(_ token: Token) -> String {
        tokenSerial += 1
        let value = "t\(tokenSerial)"
        tokens[value] = token
        return value
    }
}

extension StatefulExchangeActionServer {

    static let graphRoot = "https://graph.microsoft.com/v1.0/me"

    // MARK: - Other clients (the web, desktop Outlook, a server rule)

    /// A message delivered to `seed.folderId`.
    func deliver(_ seed: Seed) {
        state.value.withLock { model in
            model.messagesByProviderId[seed.providerMessageId] = Message(
                rfc822MessageId: seed.rfc822MessageId, providerMessageId: seed.providerMessageId,
                folderId: seed.folderId, isRead: seed.isRead, isFlagged: seed.isFlagged,
                receivedAt: seed.receivedAt, categories: seed.categories)
            model.delta.log(folderId: seed.folderId, messageId: seed.providerMessageId, kind: .created)
        }
    }

    /// Another client moves a message; Graph gives it a new id. Returns it.
    @discardableResult
    func moveFromOtherClient(providerMessageId: String, to folderId: String) -> String? {
        state.value.withLock { model in
            guard let prior = model.messagesByProviderId.removeValue(forKey: providerMessageId) else { return nil }
            let movedId = "graph/other-move+\(model.nextMoveGeneration)="
            model.nextMoveGeneration += 1
            model.messagesByProviderId[movedId] = Message(
                rfc822MessageId: prior.rfc822MessageId, providerMessageId: movedId, folderId: folderId,
                isRead: prior.isRead, isFlagged: prior.isFlagged, receivedAt: prior.receivedAt,
                categories: prior.categories)
            model.delta.log(folderId: prior.folderId, messageId: providerMessageId, kind: .removed)
            model.delta.log(folderId: folderId, messageId: movedId, kind: .created)
            return movedId
        }
    }

    func deleteFromOtherClient(providerMessageId: String) {
        state.value.withLock { model in
            guard let gone = model.messagesByProviderId.removeValue(forKey: providerMessageId) else { return }
            model.delta.log(folderId: gone.folderId, messageId: providerMessageId, kind: .removed)
        }
    }

    func setReadFromOtherClient(providerMessageId: String, isRead: Bool) {
        state.value.withLock { model in
            guard var message = model.messagesByProviderId[providerMessageId] else { return }
            message.isRead = isRead
            model.messagesByProviderId[providerMessageId] = message
            model.delta.log(folderId: message.folderId, messageId: providerMessageId, kind: .read)
        }
    }

    func setFlagFromOtherClient(providerMessageId: String, isFlagged: Bool) {
        state.value.withLock { model in
            guard var message = model.messagesByProviderId[providerMessageId] else { return }
            message.isFlagged = isFlagged
            model.messagesByProviderId[providerMessageId] = message
            model.delta.log(folderId: message.folderId, messageId: providerMessageId, kind: .flag)
        }
    }

    // MARK: - Folder tree

    /// Adds a folder to the tree `fetchFolders` lists and the mail-folder delta
    /// reports. `wellKnownName` is Graph's (`inbox`, `archive`, …).
    func addFolder(id: String, name: String, wellKnownName: String? = nil, parentId: String? = nil,
                   hidden: Bool = false, odataType: String? = nil) {
        state.value.withLock { model in
            model.delta.folders[id] = DeltaModel.FakeFolder(
                id: id, name: name, wellKnownName: wellKnownName, parentId: parentId,
                hidden: hidden, odataType: odataType)
            model.delta.folderOrder.append(id)
            model.delta.seq += 1
            model.delta.folderEntries.append((model.delta.seq, id, false))
        }
    }

    func renameFolder(id: String, to name: String) {
        state.value.withLock { model in
            model.delta.folders[id]?.name = name
            model.delta.seq += 1
            model.delta.folderEntries.append((model.delta.seq, id, false))
        }
    }

    /// Removes a folder and every folder under it.
    func removeFolder(id: String) {
        state.value.withLock { model in
            var doomed: Set<String> = [id]
            var grew = true
            while grew {
                grew = false
                for folder in model.delta.folders.values where !doomed.contains(folder.id) {
                    if let parent = folder.parentId, doomed.contains(parent) { doomed.insert(folder.id); grew = true }
                }
            }
            for folderId in model.delta.folderOrder where doomed.contains(folderId) {
                model.delta.folders[folderId] = nil
                model.delta.seq += 1
                model.delta.folderEntries.append((model.delta.seq, folderId, true))
            }
            model.delta.folderOrder.removeAll { doomed.contains($0) }
        }
    }

    func setFolderDeltaListsHidden(_ lists: Bool) {
        state.value.withLock { $0.delta.folderDeltaListsHidden = lists }
    }

    func refuseFolderDeltaLinks(status: Int?) {
        state.value.withLock { $0.delta.refuseFolderTokens = status }
    }

    // MARK: - Faults

    /// Every link issued so far for `folderId` answers `status` (an expired or
    /// reset round); new chains are served.
    func refuseIssuedLinks(folderId: String, status: Int = 410) {
        state.value.withLock { model in
            let issued = Set(model.delta.tokens.filter { $0.value.folderId == folderId }.map(\.key))
            model.delta.refusedTokens[folderId] = (status, issued)
        }
    }

    /// The next message delta pages answer these, one each, in order.
    func failDeltaPages(_ responses: [FakeHTTP.CannedResponse]) {
        state.value.withLock { $0.delta.pageFailures += responses }
    }

    func deltaPageFailuresServed() -> Int {
        state.value.withLock { $0.delta.pageFailuresServed }
    }

    func setDeltaPageLatency(_ seconds: TimeInterval) {
        state.value.withLock { $0.delta.pageLatency = seconds }
    }

    /// The next `$batch` requests answer these, one each, in order.
    func failBatches(_ responses: [FakeHTTP.CannedResponse]) {
        state.value.withLock { $0.delta.batchFailures += responses }
    }

    func setBatchLatency(_ seconds: TimeInterval) {
        state.value.withLock { $0.delta.batchLatency = seconds }
    }

    /// The `$batch` item for `providerMessageId` answers `status` with `body`
    /// (raw JSON, any value) until `clearBatchItemAnswers()`.
    func answerBatchItem(providerMessageId: String, status: Int, body: String?) {
        state.value.withLock { $0.delta.batchItemAnswers[providerMessageId] = (status, body) }
    }

    func clearBatchItemAnswers() {
        state.value.withLock { $0.delta.batchItemAnswers = [:] }
    }

    /// The width of every `$batch` served, in order.
    func batchWidths() -> [Int] {
        state.value.withLock { $0.delta.batchWidths }
    }

    func messageIds(inFolder folderId: String) -> Set<String> {
        state.value.withLock { model in
            Set(model.messagesByProviderId.values.filter { $0.folderId == folderId }.map(\.providerMessageId))
        }
    }

    /// Requests whose URL contains `fragment`.
    func requestCount(containing fragment: String) -> Int {
        http.recordedCalls().filter { $0.url.contains(fragment) }.count
    }

    // MARK: - Routes

    func registerDeltaRoutes() {
        http.register(path: "/messages/delta", method: "GET") { [state] request in
            let response = Self.serveMessageDelta(request, state: state)
            let latency = state.value.withLock { $0.delta.pageLatency }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
        }
        http.register(path: "/mailFolders/delta", method: "GET") { [state] request in
            Self.serveFolderDelta(request, state: state)
        }
        http.register(path: "/mailFolders?", method: "GET") { [state] request in
            let includeHidden = request.url.absoluteString.contains("includeHiddenFolders=true")
            return Self.folderListing(parentId: nil, includeHidden: includeHidden, state: state)
        }
        http.register(path: "/$batch", method: "POST") { [state] request in
            let response = Self.serveBatch(request, state: state)
            let latency = state.value.withLock { $0.delta.batchLatency }
            guard latency > 0 else { return response }
            return .parked { Thread.sleep(forTimeInterval: latency); return response }
        }
    }

    private static func serveMessageDelta(_ request: FakeHTTP.Request, state: StateBox) -> FakeHTTP.CannedResponse {
        let pageSize = request.header("Prefer")
            .flatMap { $0.components(separatedBy: "odata.maxpagesize=").last }
            .flatMap { Int($0) } ?? 10
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let tokenValue = query.first { $0.name == "$skiptoken" || $0.name == "$deltatoken" }?.value
        return state.value.withLock { model -> FakeHTTP.CannedResponse in
            if !model.delta.pageFailures.isEmpty {
                model.delta.pageFailuresServed += 1
                return model.delta.pageFailures.removeFirst()
            }
            // The round to serve.
            let token: DeltaModel.Token
            if let tokenValue {
                guard let stored = model.delta.tokens[tokenValue] else { return .status(400) }
                if let refusal = model.delta.refusedTokens[stored.folderId], refusal.tokens.contains(tokenValue) {
                    return .json(raw: #"{"error":{"code":"SyncStateNotFound","message":"The sync state is not found."}}"#,
                                 statusCode: refusal.status)
                }
                token = stored.isDeltaLink
                    ? DeltaModel.Token(folderId: stored.folderId, select: stored.select, from: stored.end,
                                       end: model.delta.seq, after: nil, isDeltaLink: false)
                    : stored
            } else {
                guard let folderId = folderId(fromDeltaURL: request.url) else { return .status(404) }
                let select = query.first { $0.name == "$select" }?.value?.components(separatedBy: ",")
                token = DeltaModel.Token(folderId: folderId, select: select, from: nil, end: model.delta.seq,
                                         after: nil, isDeltaLink: false)
            }
            let items = deltaItems(token, model: model)
            let remaining = items.filter { token.after == nil || $0.id > token.after! }
            let page = Array(remaining.prefix(pageSize))
            var object: [String: Any] = ["value": page.map(\.row)]
            let base = "\(graphRoot)/mailFolders/\(token.folderId)/messages/delta"
            if remaining.count > page.count, let last = page.last {
                let next = model.delta.issue(DeltaModel.Token(
                    folderId: token.folderId, select: token.select, from: token.from, end: token.end,
                    after: last.id, isDeltaLink: false))
                object["@odata.nextLink"] = "\(base)?$skiptoken=\(next)"
            } else {
                let next = model.delta.issue(DeltaModel.Token(
                    folderId: token.folderId, select: token.select, from: token.from, end: token.end,
                    after: nil, isDeltaLink: true))
                object["@odata.deltaLink"] = "\(base)?$deltatoken=\(next)"
            }
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
    }

    /// The round's records, by id.
    private static func deltaItems(_ token: DeltaModel.Token, model: State) -> [(id: String, row: [String: Any])] {
        let inFolder = model.messagesByProviderId.values.filter { $0.folderId == token.folderId }
        func selected(_ message: Message) -> [String: Any] {
            let row = graphRow(message)
            guard let select = token.select else { return row }
            return row.filter { $0.key == "id" || select.contains($0.key) }
        }
        guard let from = token.from else {
            return inFolder.sorted { $0.providerMessageId < $1.providerMessageId }
                .map { ($0.providerMessageId, selected($0)) }
        }
        var kinds: [String: [DeltaModel.Kind]] = [:]
        for entry in model.delta.entries where entry.folderId == token.folderId && entry.seq > from && entry.seq <= token.end {
            kinds[entry.messageId, default: []].append(entry.kind)
        }
        var items: [(id: String, row: [String: Any])] = []
        for (id, changes) in kinds {
            if let message = inFolder.first(where: { $0.providerMessageId == id }) {
                if changes.allSatisfy({ $0 == .read }) {
                    items.append((id, ["id": id, "isRead": message.isRead]))
                } else {
                    items.append((id, selected(message)))
                }
            } else if changes.contains(.removed) {
                items.append((id, ["id": id, "@removed": ["reason": "deleted"]]))
            }
        }
        return items.sorted { $0.id < $1.id }
    }

    private static func folderId(fromDeltaURL url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "mailFolders"), components.indices.contains(index + 3),
              components[index + 2] == "messages", components[index + 3] == "delta" else { return nil }
        return components[index + 1]
    }

    // MARK: Folders

    private static func folderRow(_ folder: DeltaModel.FakeFolder, model: State) -> [String: Any] {
        let messages = model.messagesByProviderId.values.filter { $0.folderId == folder.id }
        var row: [String: Any] = [
            "id": folder.id, "displayName": folder.name,
            "totalItemCount": messages.count, "unreadItemCount": messages.filter { !$0.isRead }.count,
            "childFolderCount": model.delta.folders.values.filter { $0.parentId == folder.id }.count,
        ]
        if let parent = folder.parentId { row["parentFolderId"] = parent }
        if let type = folder.odataType { row["@odata.type"] = type }
        return row
    }

    private static func folderListing(parentId: String?, includeHidden: Bool, state: StateBox) -> FakeHTTP.CannedResponse {
        state.value.withLock { model in
            let rows = model.delta.folderOrder.compactMap { model.delta.folders[$0] }
                .filter { $0.parentId == parentId && (includeHidden || !$0.hidden) }
                .map { folderRow($0, model: model) }
            let body = (try? JSONSerialization.data(withJSONObject: ["value": rows])) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
    }

    /// `/mailFolders/{well-known name or id}` and `/mailFolders/{id}/childFolders`,
    /// when the folder tree is seeded; nil otherwise (the message routes).
    static func serveFolderResource(_ request: FakeHTTP.Request, state: StateBox) -> FakeHTTP.CannedResponse? {
        let components = request.url.pathComponents
        guard let index = components.firstIndex(of: "mailFolders"), components.indices.contains(index + 1),
              !(components.indices.contains(index + 2) && components[index + 2] == "messages") else { return nil }
        let seeded = state.value.withLock { !$0.delta.folders.isEmpty }
        guard seeded else { return nil }
        let key = components[index + 1]
        if components.indices.contains(index + 2), components[index + 2] == "childFolders" {
            let includeHidden = request.url.absoluteString.contains("includeHiddenFolders=true")
            return folderListing(parentId: key, includeHidden: includeHidden, state: state)
        }
        return state.value.withLock { model in
            guard let folder = model.delta.folders[key]
                    ?? model.delta.folders.values.first(where: { $0.wellKnownName == key }) else { return .status(404) }
            let body = (try? JSONSerialization.data(withJSONObject: folderRow(folder, model: model))) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
    }

    private static func serveFolderDelta(_ request: FakeHTTP.Request, state: StateBox) -> FakeHTTP.CannedResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let tokenValue = query.first { $0.name == "$deltatoken" }?.value
        return state.value.withLock { model -> FakeHTTP.CannedResponse in
            var rows: [[String: Any]] = []
            if let tokenValue {
                if let status = model.delta.refuseFolderTokens { return .status(status) }
                guard let from = model.delta.folderTokens[tokenValue] else { return .status(400) }
                var latest: [String: Bool] = [:]
                var order: [String] = []
                for entry in model.delta.folderEntries where entry.seq > from {
                    if latest[entry.folderId] == nil { order.append(entry.folderId) }
                    latest[entry.folderId] = entry.removed
                }
                for folderId in order {
                    if let folder = model.delta.folders[folderId] {
                        guard model.delta.folderDeltaListsHidden || !folder.hidden else { continue }
                        rows.append(folderRow(folder, model: model))
                    } else if latest[folderId] == true {
                        rows.append(["id": folderId, "@removed": ["reason": "deleted"]])
                    }
                }
            } else {
                rows = model.delta.folderOrder.compactMap { model.delta.folders[$0] }
                    .filter { model.delta.folderDeltaListsHidden || !$0.hidden }
                    .map { folderRow($0, model: model) }
            }
            model.delta.tokenSerial += 1
            let next = "f\(model.delta.tokenSerial)"
            model.delta.folderTokens[next] = model.delta.seq
            let object: [String: Any] = [
                "value": rows, "@odata.deltaLink": "\(graphRoot)/mailFolders/delta?$deltatoken=\(next)",
            ]
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return .bytes(body, contentType: "application/json")
        }
    }

    // MARK: Batch

    private static func serveBatch(_ request: FakeHTTP.Request, state: StateBox) -> FakeHTTP.CannedResponse {
        guard let body = request.body,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let requests = root["requests"] as? [[String: Any]] else { return .status(400) }
        return state.value.withLock { model -> FakeHTTP.CannedResponse in
            if !model.delta.batchFailures.isEmpty { return model.delta.batchFailures.removeFirst() }
            guard requests.count <= SyncConfig.graphBatchMaxRequests else { return .status(400) }
            model.delta.batchWidths.append(requests.count)
            var responses: [[String: Any]] = []
            for item in requests {
                let id = item["id"] as? String ?? ""
                guard let path = item["url"] as? String,
                      let url = URL(string: "https://graph.microsoft.com/v1.0" + path),
                      let providerId = messageId(from: url, move: false) else {
                    responses.append(["id": id, "status": 400])
                    continue
                }
                if let answer = model.delta.batchItemAnswers[providerId] {
                    var item: [String: Any] = ["id": id, "status": answer.status]
                    if let raw = answer.body,
                       let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) {
                        item["body"] = value
                    }
                    responses.append(item)
                    continue
                }
                if let status = model.getFailureStatusByProviderId[providerId] {
                    model.getFailuresServedByProviderId[providerId, default: 0] += 1
                    responses.append(["id": id, "status": status,
                                      "body": ["error": ["code": "Injected", "message": "Injected failure"]]])
                    continue
                }
                guard let message = model.messagesByProviderId[providerId] else {
                    responses.append(["id": id, "status": 404,
                                      "body": ["error": ["code": "ErrorItemNotFound", "message": "Not found"]]])
                    continue
                }
                responses.append(["id": id, "status": 200, "body": graphRow(message)])
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["responses": responses])) ?? Data()
            return .bytes(data, contentType: "application/json")
        }
    }
}
