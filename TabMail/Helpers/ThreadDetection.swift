/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Thread detection using union of ALL available signals:
/// inReplyTo chain, References header, and native threadId.
/// No subject-based fallback — messages without real thread links are standalone.
enum ThreadDetection {

    /// Find related messages by collecting from ALL thread signals in parallel,
    /// then deduplicating and sorting. No priority/fallback — pure union. Returns the whole
    /// thread, with no length or depth limit.
    ///
    /// For a given message, any other message connected to it through one of the
    /// following is treated as related (direction-agnostic):
    ///
    /// 1. **Forward** — their `rfc822MessageId` appears in my `inReplyTo`/`References`
    ///    (i.e. I cite them as an ancestor).
    /// 2. **Reverse via inReplyTo** — their `inReplyTo` equals my `rfc822MessageId`
    ///    (i.e. they reply directly to me).
    /// 3. **Reverse via References** — their `References` header contains my
    ///    `rfc822MessageId` (i.e. they cite me as an ancestor).
    /// 4. **Lateral via inReplyTo** — their `inReplyTo` is one of *my* ancestors
    ///    (i.e. we reply to a common parent — classic sibling).
    /// 5. **Lateral via References** — their `References` shares any entry with
    ///    mine (i.e. we cite a common ancestor even though the ancestor row may
    ///    not exist in the local DB).
    ///
    /// (4) and (5) are what rescue Outlook/Exchange-rewritten threads where the
    /// local copies' `Message-ID`s have been reassigned but the original Gmail/IMAP
    /// References are preserved — neither message directly references the other,
    /// but they share a common `References` entry pointing at the original root.
    ///
    /// Implementation note — the five signals collapse into just **three**
    /// indexed `IN`-lookups when expressed over the canonical lookup set
    /// `L = {rfc822MessageId, inReplyTo} ∪ references`:
    ///
    /// - `messageHeader WHERE rfc822MessageId IN L` covers (1).
    /// - `messageHeader WHERE inReplyTo IN L` covers (2) + (4).
    /// - `messageReference WHERE referencedRfc822Id IN L` covers (3) + (5).
    ///
    /// All three use existing indexes (`messageHeader_rfc822MessageId`,
    /// `messageHeader_inReplyTo`, `messageReference_referencedRfc822Id`); the
    /// `inReplyTo` lookup names its index (`INDEXED BY`), see below.
    ///
    /// Messages whose `folderId` points at a Trash or Spam folder are excluded —
    /// deleted replies and junk should not reappear in thread bubbles. Applied as a
    /// post-index row filter so the existing indexes still drive each lookup.
    static func findRelatedMessages(for msg: MessageHeader, in dbPool: DatabasePool) throws -> [MessageHeader] {
        try related(to: msg, in: dbPool).messages
    }

    /// `findRelatedMessages`, and the ids its reference search reached: `msg` and every email,
    /// copies included, linked to it through the five signals above, before the native
    /// `threadId` members are added, less the emails across a forward (`threadsAcrossForwards`).
    /// The links are direction-agnostic, so the search reaches this same set from any of its ids: a
    /// lookup started at one of them, with the same `threadId`, returns the same thread. The chat
    /// walk uses it to look each thread up once; an email across a forward is not in it, so the
    /// walk looks its thread up from that email.
    ///
    /// `copies` are the rows the search found that `excludeCopies` left out of `messages`: other
    /// copies of an email already shown (the opened one's included), in another folder or account.
    /// Neither `messages` nor `copies` holds an email across a forward.
    /// The chat shows each email once but acts on every row it loaded, each by its own id
    /// (ADR-IOS-068 D4: a Message-ID is never mutation authority).
    static func related(to msg: MessageHeader, in dbPool: DatabasePool) throws -> (messages: [MessageHeader], copies: [MessageHeader], linkedIds: Set<String>) {
        // Fetch trash + spam folder IDs once upfront. Typically one row each per
        // account, so this is a trivial read; the resulting set is closed over by
        // each sub-query below.
        let excludedFolderIds: Set<String> = try dbPool.read { db in
            let excludedRoles = [FolderRole.trash.rawValue, FolderRole.spam.rawValue]
            let ids = try String.fetchAll(db,
                Folder.select(Column("id"))
                    .filter(excludedRoles.contains(Column("role"))))
            return Set(ids)
        }

        var collected: [MessageHeader] = []
        var seenIds = Set<String>()
        seenIds.insert(msg.id)
        // Memoize lookup sets across BFS — two messages in the same cluster tend
        // to share the same canonical lookup set, so this avoids redundant IO.
        var expandedLookupKeys = Set<String>()

        func add(_ results: [MessageHeader]) -> [MessageHeader] {
            var newlyAdded: [MessageHeader] = []
            for result in results where !seenIds.contains(result.id) {
                seenIds.insert(result.id)
                collected.append(result)
                newlyAdded.append(result)
            }
            return newlyAdded
        }

        /// Run the three unified index lookups for a given message's (rfc822, inReplyTo, references).
        func findConnected(rfc822MessageId: String?, inReplyTo: String?, references: [String]) throws -> [MessageHeader] {
            // Build the canonical lookup set L = {rfc822, inReplyTo} ∪ references.
            var lookups: [String] = []
            if let irt = inReplyTo, !irt.isEmpty { lookups.append(irt) }
            lookups.append(contentsOf: references)
            if let rfc = rfc822MessageId, !rfc.isEmpty { lookups.append(rfc) }
            var dedupe = Set<String>()
            let L = lookups.filter { dedupe.insert($0).inserted }
            guard !L.isEmpty else { return [] }

            let key = L.sorted().joined(separator: ",")
            if expandedLookupKeys.contains(key) { return [] }
            expandedLookupKeys.insert(key)

            return try dbPool.read { db in
                // (1) Forward: ancestors whose rfc822MessageId is in L.
                let forward = try MessageHeader
                    .filter(L.contains(Column("rfc822MessageId"))
                            && !seenIds.contains(Column("id"))
                            && !excludedFolderIds.contains(Column("folderId")))
                    .order(Column("date").desc)
                    .fetchAll(db)

                // (2) + (4) Reverse + lateral via inReplyTo: messages whose inReplyTo is in L.
                // - in L because of my rfc822 → classic direct children (reverse).
                // - in L because of one of my ancestors → classic siblings (lateral).
                // Named index: where the stored mail has no In-Reply-To (Outlook stores
                // none), ANALYZE counts all its rows under one value and the planner
                // walked the date index over the whole table instead (#1563). The index
                // is migration-built (v13), never deferred or dropped.
                let seen = Array(seenIds)
                let excluded = Array(excludedFolderIds)
                let inReplyToMatches = try MessageHeader.fetchAll(db, sql: """
                    SELECT * FROM messageHeader INDEXED BY messageHeader_inReplyTo
                    WHERE inReplyTo IN (\(Self.placeholders(L.count)))
                      AND id NOT IN (\(Self.placeholders(seen.count)))
                      AND folderId NOT IN (\(Self.placeholders(excluded.count)))
                    ORDER BY date DESC
                    """, arguments: StatementArguments(L + seen + excluded))

                // (3) + (5) Reverse + lateral via References: messages whose References
                // header contains any entry of L. The messageReference junction table is
                // the inverted index over References, so this is a single indexed IN probe.
                let refAlias = TableAlias(name: "r")
                let refMatches = try MessageHeader
                    .joining(required: MessageHeader.messageReferences.aliased(refAlias)
                        .filter(L.contains(Column("referencedRfc822Id"))))
                    .filter(!seenIds.contains(Column("id"))
                            && !excludedFolderIds.contains(Column("folderId")))
                    .order(Column("date").desc)
                    .fetchAll(db)

                return forward + inReplyToMatches + refMatches
            }
        }

        // Initial expansion from the opened message.
        let initial = try findConnected(rfc822MessageId: msg.rfc822MessageId,
                                        inReplyTo: msg.inReplyTo,
                                        references: msg.references)
        var newlyFound = add(initial)

        // BFS: for each newly found message, expand their references too. This
        // rescues transitive connections — e.g., messages B and C both cite a
        // common ancestor A that does exist in the DB; B finds A directly, then
        // expanding A finds C. It runs until the thread is complete: each round adds only emails
        // not seen yet, so it ends after at most one round per email of the thread.
        while !newlyFound.isEmpty {
            var nextRound: [MessageHeader] = []
            for found in newlyFound {
                let expanded = try findConnected(rfc822MessageId: found.rfc822MessageId,
                                                 inReplyTo: found.inReplyTo,
                                                 references: found.references)
                nextRound.append(contentsOf: add(expanded))
            }
            newlyFound = nextRound
        }
        let linkedIds = seenIds

        // Native threadId (Gmail/Exchange server-side threading). Synthetic "subj:"
        // ids (our IMAP fallback) are excluded — they would pull in every unrelated
        // message that happens to share a subject.
        if let threadId = msg.threadId, !threadId.isEmpty, !threadId.hasPrefix("subj:") {
            let _ = add(try findByThreadId(threadId, excluding: msg, in: dbPool, excludedFolderIds: excludedFolderIds))
        }

        if collected.isEmpty { return ([], [], linkedIds) }

        // A forward's thread and its source's stay apart (ADR-IOS-043, forward split): the emails
        // across a forward leave the shown emails, their copies and the reached ids alike, so the
        // chat neither shows nor acts on them, and its walk looks their threads up on their own.
        let acrossForwards = threadsAcrossForwards(collected, of: msg)
        let kept = collected.filter { !acrossForwards.contains($0.computedThreadId) }
        let leftOut = Set(collected.filter { acrossForwards.contains($0.computedThreadId) }.map(\.id))

        // Deduplicate cross-folder copies, sort by date. The whole thread, however long: the chat
        // shows every email of it, all the way back (ADR-IOS-114).
        let deduped = excludeCopies(kept, of: msg)
        let shownIds = Set(deduped.map(\.id))
        let copies = kept.filter { !shownIds.contains($0.id) }
        return (deduped.sorted { $0.date > $1.date }, copies.sorted { $0.date > $1.date }, linkedIds.subtracting(leftOut))
    }

    /// The related emails on `msg`'s side of every forward among them.
    ///
    /// A forward shares References with the thread it came from (and on Gmail its
    /// thread id), so the search above reaches across it both ways. Its own thread
    /// (`ThreadUtils.assignComputedThreadId`: the forward, its copies and replies)
    /// is told apart by `computedThreadId`:
    /// - a forward in another thread than `msg`'s: that thread is left out;
    /// - a forward in `msg`'s thread (`msg` is it, or is a reply to it): the
    ///   threads of the emails it forwards are left out.
    /// A forward stored before the split shares its source's thread and shows with
    /// it; seen from another thread of the conversation it is a forward elsewhere and
    /// its whole thread is left out (IOS-THREAD-002). An email not stored yet (opened
    /// from its notification before the merge) has no thread, so nothing is left out.
    static func excludeAcrossForwards(_ results: [MessageHeader], of msg: MessageHeader) -> [MessageHeader] {
        let excluded = threadsAcrossForwards(results, of: msg)
        guard !excluded.isEmpty else { return results }
        return results.filter { !excluded.contains($0.computedThreadId) }
    }

    /// The `computedThreadId`s `excludeAcrossForwards` leaves out of `results`.
    static func threadsAcrossForwards(_ results: [MessageHeader], of msg: MessageHeader) -> Set<String> {
        let own = msg.computedThreadId
        guard !own.isEmpty else { return [] }
        let all = [msg] + results
        var threadByMessageId: [String: String] = [:]
        for header in all {
            if let rfc = header.rfc822MessageId, !rfc.isEmpty, threadByMessageId[rfc] == nil {
                threadByMessageId[rfc] = header.computedThreadId
            }
        }
        var excluded = Set<String>()
        for forward in all where ThreadUtils.hasForwardPrefix(forward.subject) && !forward.computedThreadId.isEmpty {
            if forward.computedThreadId != own {
                excluded.insert(forward.computedThreadId)
            } else {
                let sources = (forward.inReplyTo.map { [$0] } ?? []) + forward.references
                for source in sources {
                    if let thread = threadByMessageId[source], !thread.isEmpty, thread != own { excluded.insert(thread) }
                }
            }
        }
        return excluded
    }

    /// Filter out copies of the same email that exist in different folders.
    /// Uses RFC 822 Message-ID only — the canonical globally-unique email identifier.
    static func excludeCopies(_ results: [MessageHeader], of msg: MessageHeader) -> [MessageHeader] {
        var seenRfc822 = Set<String>()
        if let myRfc822 = msg.rfc822MessageId, !myRfc822.isEmpty {
            seenRfc822.insert(myRfc822)
        }
        return results.filter { result in
            if let rfc822 = result.rfc822MessageId, !rfc822.isEmpty {
                if seenRfc822.contains(rfc822) { return false }
                seenRfc822.insert(rfc822)
            }
            return true
        }
    }

    // MARK: - Signal: Native Thread ID

    private static func findByThreadId(_ threadId: String, excluding msg: MessageHeader, in dbPool: DatabasePool, excludedFolderIds: Set<String>) throws -> [MessageHeader] {
        return try dbPool.read { db in
            try MessageHeader
                .filter(Column("threadId") == threadId
                        && Column("id") != msg.id
                        && !excludedFolderIds.contains(Column("folderId")))
                .order(Column("date").desc)
                .fetchAll(db)
        }
    }

    /// `count` comma-separated `?` placeholders for a SQL `IN` list.
    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

}
