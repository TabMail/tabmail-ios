/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The chat view's summary requests (ADR-IOS-114): what a shown chat (its open, its database
/// observation and its re-checks, a row coming on screen) and the background walk ask the queue for.
extension ActiveAIQueue {
    /// Whether a chat summary may be asked for this email: never for a draft. A draft's text is the
    /// user's unsent words, and they never leave the device for a summary (ADR-IOS-114 decision 8),
    /// whichever caller asks: the shown chat (its open, its database observation and its re-checks,
    /// an email joining it), a row coming on screen, the walk or a twin's hand-back. Decided from
    /// the email's OWN folder role, read with the row, so it never depends on what a screen loaded
    /// (the chat's context reads only its members' accounts' folders). An email whose folder row is
    /// missing is refused too (fail closed): its role is unknown, and the next sync writes the
    /// folder and a later ask or walk asks again.
    nonisolated static func chatSummaryAllowed(_ message: MessageHeader, db: Database) throws -> Bool {
        guard let folder = try Folder.fetchOne(db, key: message.folderId) else { return false }
        return folder.role != .drafts
    }

    /// Summaries for the emails a shown chat asks for (ADR-IOS-114): its newest
    /// `ChatViewConfig.summaryWindow` and the emails shown, newest first, at the open, each re-show
    /// and each queue rebuild; each that changed in the database; and each older email as it comes
    /// on screen. Each one that lacks a summary with a text message, the user's own included,
    /// goes to the FRONT of the queues in the order given: every request goes in front of the
    /// earlier ones. A member with its body gets a chat summary job now; one without goes to the
    /// front of the body queue (`ActiveBodyQueue`; tests pass `requestBodies`), and nothing is kept
    /// for it: the shown chat observes the row and asks again once its body lands, whatever writes
    /// it. A draft is never asked for (`chatSummaryAllowed`), whatever the caller passed: it gets no
    /// job and no body request. The caller checks `ChatViewConfig`.
    func enqueueChatSummaries(
        _ members: [MessageHeader],
        requestBodies: (@Sendable ([MessageHeader]) async -> Void)? = nil
    ) async {
        let ids = members.map(\.id)
        guard let rows = try? await dbPool.read({ db in
            try MessageHeader.filter(keys: ids).fetchAll(db).filter { try Self.chatSummaryAllowed($0, db: db) }
        }) else { return }
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = rows.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        var ready: [(headerId: String, accountId: String)] = []
        var needBody: [MessageHeader] = []
        for member in fresh where !Self.summaryDone(member, forChat: true) {
            if member.bodyComplete {
                ready.append((member.id, member.accountId))
            } else {
                needBody.append(member)
            }
        }
        if !needBody.isEmpty {
            if let requestBodies {
                await requestBodies(needBody)
            } else {
                await ActiveBodyQueue.shared.enqueueBatch(needBody, first: true)
            }
        }
        enqueueChatSummaryJobs(ready, origin: "open", first: true)
    }

    /// Admit chat summary jobs (summary only, window-exempt, any folder). `first`: they go to the
    /// front of the queue in the given order, pending ones already queued included.
    func enqueueChatSummaryJobs(
        _ items: [(headerId: String, accountId: String)], origin: String, first: Bool = false
    ) {
        var admitted = 0
        var jobs: [AIJob] = []
        for item in items {
            let job = AIJob(headerId: item.headerId, accountId: item.accountId, jobType: .summary,
                            windowExempt: true, forChat: true)
            guard !retiredForProcess(job) else { continue }
            jobs.append(job)
            if admitOrUpgrade(job) != .rejected { admitted += 1 }
        }
        if first { storage.moveToFront(jobs) }
        guard admitted > 0 || (first && !jobs.isEmpty) else { return }
        BackgroundSyncLogger.logAIProcessing("Enqueued \(admitted) chat summary job(s) (\(origin), total: \(storage.count))")
        scheduleDispatch()
    }

    /// The background walk: the newest `ChatViewConfig.summaryWindow` emails of each thread of the
    /// newest `SyncConfig.maxRecentEmails` Inbox rows (any folder), each that has its body and no
    /// summary with a text message: what a chat asks for when it opens. Drafts are not the chat's
    /// to ask for, so they are left out before the window is taken: no chat job is ever asked for a
    /// draft, and the window holds the thread's newest real emails. A member whose body is not
    /// downloaded yet is picked up by a later walk once backfill has fetched it.
    ///
    /// Each thread is looked up once: an Inbox row that an earlier lookup reached through the
    /// thread's reference links, started from a row with the same `threadId`, has the same thread
    /// (`ThreadDetection.related`), so it is skipped. A row reached only through a native thread id,
    /// or started under another one, is looked up itself, so no email of its thread is lost.
    ///
    /// It runs at the end of `repopulateFromDatabase` with the chat view on: every `syncStartup`
    /// (launch, each foreground return and foreground poll, every push wake, BGAppRefresh and
    /// BGProcessing), AI re-enable and the AI redrives; never on drain.
    nonisolated static func chatWalkCandidates(
        pool: DatabasePool
    ) throws -> [(headerId: String, accountId: String)] {
        let (inbox, draftFolderIds) = try pool.read { db in
            let rows = try MessageHeader.fetchAll(db, sql: """
                SELECT * FROM messageHeader
                WHERE isInInbox = 1
                ORDER BY date DESC, id DESC
                LIMIT ?
            """, arguments: [SyncConfig.maxRecentEmails])
            let drafts = try String.fetchAll(db, Folder.select(Column("id"))
                .filter(Column("role") == FolderRole.drafts.rawValue))
            return (rows, Set(drafts))
        }
        var seen = Set<String>()
        var members: [MessageHeader] = []
        /// Per `threadId` of the row a lookup started from: the ids its reference search reached.
        var linkedByThreadId: [String: Set<String>] = [:]
        for row in inbox {
            let threadKey = row.threadId ?? ""
            if linkedByThreadId[threadKey]?.contains(row.id) == true { continue }
            let related = try ThreadDetection.related(to: row, in: pool)
            linkedByThreadId[threadKey, default: []].formUnion(related.linkedIds)
            let thread = ([row] + related.messages)
                .filter { !draftFolderIds.contains($0.folderId) }
                .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            for member in thread.prefix(ChatViewConfig.summaryWindow) where seen.insert(member.id).inserted {
                members.append(member)
            }
        }
        return members
            .filter { $0.bodyComplete && !Self.summaryDone($0, forChat: true) }
            .map { ($0.id, $0.accountId) }
    }
}
