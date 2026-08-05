/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Utilities for email thread grouping — subject normalization and synthetic threadId computation.
enum ThreadUtils {

    // MARK: - Computed Thread ID (insert-time, unified across providers)

    /// Compute the computedThreadId for a message at insert time.
    ///
    /// Chain-walk first: looks up `inReplyTo`/`References`/`rfc822MessageId`
    /// connections to existing local messages and adopts the matched thread.
    /// This is the same logic the inbox should believe in, so two messages
    /// that Gmail split into separate conversations (subject change, time
    /// gap, etc.) but that share an `In-Reply-To`/`References` chain end up
    /// in the same inbox group.
    ///
    /// Native `threadId` (Gmail/Exchange) is used only when no chain link
    /// exists yet — it seeds a fresh group for new conversations and acts
    /// as the canonical identifier for a brand-new Gmail conversation.
    ///
    /// Sets `header.computedThreadId` but does NOT insert messageReference rows —
    /// call `insertMessageReferences(for:db:)` AFTER `header.insert(db)` to satisfy FK constraints.
    /// Must be called inside a GRDB write transaction.
    static func assignComputedThreadId(
        to header: inout MessageHeader,
        nativeThreadId: String?,
        db: Database
    ) throws {
        // 1. Chain-walk first — adopt an existing thread if any local message
        //    is in our inReplyTo/References lookup set. Catches Gmail thread
        //    fragmentation where two conversation IDs share a reply chain.
        if let adopted = try findAdoptableThreadId(
            myHeaderId: header.id,
            rfc822MessageId: header.rfc822MessageId,
            inReplyTo: header.inReplyTo,
            references: header.references,
            db: db
        ) {
            header.computedThreadId = adopted
            return
        }

        // 2. No chain match. Use native threadId (Gmail/Exchange) as the
        //    fresh-group seed; IMAP falls back to the message's own rfc822.
        if let tid = nativeThreadId, !tid.isEmpty, !tid.hasPrefix("subj:") {
            header.computedThreadId = tid
            return
        }
        header.computedThreadId = header.rfc822MessageId ?? header.id
    }

    /// Look up an existing `computedThreadId` to adopt for a message being
    /// inserted (or repaired), using the full forward + reverse + lateral
    /// signal set expressed as three indexed `IN` probes over
    /// `L = {rfc822MessageId, inReplyTo} ∪ references`.
    ///
    /// Returns nil if no connected message exists yet. Callers fall back to
    /// `rfc822MessageId` (or the row id) as a fresh thread root.
    ///
    /// Used by `assignComputedThreadId` at insert time and by the v28 repair
    /// migration when walking historical rows whose original chain-walk missed
    /// a shared-ancestor sibling.
    static func findAdoptableThreadId(
        myHeaderId: String,
        rfc822MessageId: String?,
        inReplyTo: String?,
        references: [String],
        db: Database
    ) throws -> String? {
        var lookups: [String] = []
        if let irt = inReplyTo, !irt.isEmpty { lookups.append(irt) }
        lookups.append(contentsOf: references)
        if let rfc = rfc822MessageId, !rfc.isEmpty { lookups.append(rfc) }
        var dedupe = Set<String>()
        let L = lookups.filter { dedupe.insert($0).inserted }
        guard !L.isEmpty else { return nil }

        let placeholders = L.map { _ in "?" }.joined(separator: ",")

        // (1) Forward: ancestors whose rfc822MessageId is in L. Exclude self to
        // handle re-inserts/upserts of the same row.
        if let found = try String.fetchOne(db, sql: """
            SELECT computedThreadId FROM messageHeader
            WHERE rfc822MessageId IN (\(placeholders))
              AND id != ?
              AND computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }

        // (2) + (4) Reverse + lateral via inReplyTo.
        if let found = try String.fetchOne(db, sql: """
            SELECT computedThreadId FROM messageHeader
            WHERE inReplyTo IN (\(placeholders))
              AND id != ?
              AND computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }

        // (3) + (5) Reverse + lateral via References, via the junction table.
        if let found = try String.fetchOne(db, sql: """
            SELECT m.computedThreadId FROM messageReference r
            JOIN messageHeader m ON m.id = r.messageHeaderId
            WHERE r.referencedRfc822Id IN (\(placeholders))
              AND m.id != ?
              AND m.computedThreadId != ''
            LIMIT 1
        """, arguments: StatementArguments(L + [myHeaderId])), !found.isEmpty {
            return found
        }

        return nil
    }

    /// Re-run `findAdoptableThreadId` over every row in date-ASC order until
    /// no more adoptions happen (fixpoint). Used by the v54 migration to
    /// merge Gmail-fragmented threads in historic data.
    ///
    /// Iteration is necessary because `findAdoptableThreadId` returns the
    /// first connected ctid (no ORDER BY). For a chain M1(T1) ← M2(T2) ←
    /// M3(T3), the date-ASC pass can leave M1=T2, M2=T3, M3=T3 — fully
    /// merging requires another pass that sees M2's now-adopted T3 and
    /// pulls M1 along. Each pass propagates one hop; realistic email
    /// threads converge in 1-3 passes.
    ///
    /// `maxPasses` bounds pathological cases (e.g., a 100-message chain
    /// where each adoption walks one step). Returns total adoptions.
    ///
    /// ⚠️ KNOWN, DELIBERATELY UNFIXED — `KNOWN_ISSUES.md` `IOS-THREAD-001`.
    /// `merged == 0` is a MUTATION count, not candidate coverage. Because
    /// `findAdoptableThreadId` answers with the FIRST connected ctid it finds
    /// (`LIMIT 1`, no ORDER BY), a row connected to two fragments whose probe
    /// names the id it already carries never adopts — and the probe is
    /// deterministic on unchanged state, so no later pass changes that answer.
    /// Convergence can therefore be declared with fragments still split.
    /// NOT fixed here because the only production caller is the APPLIED,
    /// IMMUTABLE `v54` migration; the blast radius is display-only threading
    /// of pre-v54 rows. If it is ever fixed, fix the PROBE (return the whole
    /// connected set, adopt a deterministic minimum) — not this loop.
    @discardableResult
    static func runFragmentMergeToFixpoint(db: Database, maxPasses: Int = 20) throws -> Int {
        var totalMerged = 0
        for pass in 1...maxPasses {
            let merged = try runFragmentMergeOnce(db: db)
            totalMerged += merged
            if merged == 0 {
                if pass > 1, DebugModeManager.isLoggingEnabled() { print("[ThreadUtils] Fragment merge converged after \(pass) pass(es), \(totalMerged) total adoption(s)") }
                return totalMerged
            }
        }
        if DebugModeManager.isLoggingEnabled() { print("[ThreadUtils] WARNING: Fragment merge did not converge in \(maxPasses) passes; \(totalMerged) adoption(s) so far") }
        return totalMerged
    }

    /// One date-ASC pass of fragment-merge. Returns rows updated this pass.
    /// Exposed for tests; production callers want `runFragmentMergeToFixpoint`.
    static func runFragmentMergeOnce(db: Database) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, rfc822MessageId, inReplyTo, referencesJSON, computedThreadId
            FROM messageHeader
            WHERE computedThreadId != ''
            ORDER BY date ASC
        """)
        var merged = 0
        for row in rows {
            let id: String = row["id"]
            let rfc822: String? = row["rfc822MessageId"]
            let inReplyTo: String? = row["inReplyTo"]
            let refsJSON: String? = row["referencesJSON"]
            let currentCtid: String = row["computedThreadId"]

            var references: [String] = []
            if let json = refsJSON, let data = json.data(using: .utf8),
               let refs = try? JSONSerialization.jsonObject(with: data) as? [String] {
                references = refs
            }

            guard let adopted = try findAdoptableThreadId(
                myHeaderId: id,
                rfc822MessageId: rfc822,
                inReplyTo: inReplyTo,
                references: references,
                db: db
            ), adopted != currentCtid else { continue }

            try db.execute(
                sql: "UPDATE messageHeader SET computedThreadId = ? WHERE id = ?",
                arguments: [adopted, id]
            )
            merged += 1
        }
        return merged
    }

    /// Insert rows into the messageReference junction table for indexed reverse lookups.
    /// Must be called AFTER `header.insert(db)` to satisfy the FK constraint on messageHeaderId.
    /// Safe to call on upsert paths — deletes existing rows first to avoid duplicates.
    static func insertMessageReferences(for header: MessageHeader, db: Database) throws {
        var refIds: [String] = []
        if let irt = header.inReplyTo, !irt.isEmpty { refIds.append(irt) }
        refIds.append(contentsOf: header.references)
        guard !refIds.isEmpty else { return }
        // Delete any existing rows for this header (idempotent for upsert paths)
        try db.execute(sql: "DELETE FROM messageReference WHERE messageHeaderId = ?",
                       arguments: [header.id])
        // Batch the inserts into one multi-VALUES statement instead of N round-trips
        // through prepare/bind/step. On a 500-message backfill batch this drops the
        // per-message reference writes from O(refs) SQL executions to 1.
        let valuesClauses = refIds.map { _ in "(?, ?)" }.joined(separator: ", ")
        var args: [DatabaseValueConvertible] = []
        args.reserveCapacity(refIds.count * 2)
        for refId in refIds {
            args.append(header.id)
            args.append(refId)
        }
        try db.execute(
            sql: "INSERT INTO messageReference (messageHeaderId, referencedRfc822Id) VALUES " + valuesClauses,
            arguments: StatementArguments(args)
        )
    }

    /// Common reply/forward subject prefixes across languages.
    /// English (Re/Fwd/Fw), German (Aw), Swedish (Sv), Norwegian/Danish (Vs).
    private static let prefixes = ["re:", "fwd:", "fw:", "aw:", "sv:", "vs:"]

    /// Strip reply/forward prefixes recursively and trim whitespace.
    /// e.g. "Re: Fwd: Re: Meeting notes" → "Meeting notes"
    static func normalizeSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            let lower = result.lowercased()
            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// Build a reply subject by stripping any existing Re:/Fwd:/Fw:/Aw:/Sv:/Vs: prefix
    /// (any case, any depth) and prepending a single canonical "Re:". Matches iOS Mail
    /// behavior of never producing "Re: RE: ..." or "Re: Re: ...".
    static func replySubject(for subject: String) -> String {
        let base = normalizeSubject(subject)
        return base.isEmpty ? "Re:" : "Re: \(base)"
    }

    /// Build a forward subject. See `replySubject(for:)` for prefix handling rules.
    static func forwardSubject(for subject: String) -> String {
        let base = normalizeSubject(subject)
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    /// Known "no subject" sentinels — must not form thread groups.
    private static let noSubjectSentinels: Set<String> = ["(no subject)"]

    /// Compute a deterministic subject-based threadId for IMAP messages (which lack native threading).
    /// Returns nil if the normalized subject is empty or a "no subject" sentinel.
    static func computeSubjectThreadId(accountId: String, subject: String) -> String? {
        let normalized = normalizeSubject(subject)
        guard !normalized.isEmpty, !noSubjectSentinels.contains(normalized.lowercased()) else { return nil }
        return "subj:\(accountId):\(normalized.lowercased())"
    }

    // MARK: - Outgoing Threading Headers (send path)

    /// The threading fields a reply/forward must carry so the provider files it
    /// into the source conversation. See `PLAN_THREAD_FIX.md` and ADR-IOS-043.
    ///
    /// - `inReplyTo` / `references` are bare (normalized) RFC 2822 message IDs;
    ///   each provider adds the `<…>` brackets at the wire boundary.
    /// - `threadId` is Gmail's native conversation id (used only by the Gmail
    ///   REST send); `nil` for non-Gmail providers and for new compositions.
    struct OutgoingThreadHeaders: Sendable, Equatable {
        var inReplyTo: String?
        var references: [String]
        var threadId: String?

        static let none = OutgoingThreadHeaders(inReplyTo: nil, references: [], threadId: nil)
    }

    /// Derive the outgoing threading headers for a reply, reply-all, or forward.
    ///
    /// Reply and forward share ONE derivation path: per Gmail convention a
    /// forward stays under the source conversation on the sender's side, so it
    /// gets the same headers as a reply (the forward-specific differences —
    /// empty `To`, `Fwd:` subject, quoted block — live in ComposeView, not here).
    /// A `nil` `replyTo` (a true new composition) yields `.none`.
    ///
    /// Adapter over the scalar core below; ComposeView passes the resolved header.
    static func outgoingThreadHeaders(
        replyTo: MessageHeader?,
        sendAccountId: String,
        sendSubject: String,
        providerKind: AccountProvider
    ) -> OutgoingThreadHeaders {
        guard let parent = replyTo else { return .none }
        return outgoingThreadHeaders(
            parentRfc822MessageId: parent.rfc822MessageId,
            parentReferences: parent.references,
            parentThreadId: parent.threadId,
            parentAccountId: parent.accountId,
            parentSubject: parent.subject,
            sendAccountId: sendAccountId,
            sendSubject: sendSubject,
            providerKind: providerKind
        )
    }

    /// Pure scalar core — unit-testable without constructing a `MessageHeader`.
    static func outgoingThreadHeaders(
        parentRfc822MessageId: String?,
        parentReferences: [String],
        parentThreadId: String?,
        parentAccountId: String,
        parentSubject: String,
        sendAccountId: String,
        sendSubject: String,
        providerKind: AccountProvider
    ) -> OutgoingThreadHeaders {
        // In-Reply-To = the parent's own Message-ID (bare/normalized). Many IMAP
        // messages lack a Message-ID, in which case there is nothing to thread on.
        let parentMsgId: String? = parentRfc822MessageId
            .map { EmailFilter.normalizeMessageId($0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // References chain = parent.references ++ parent's Message-ID, normalized,
        // order-preserving, de-duplicated (RFC 5322 §3.6.4).
        var references: [String] = []
        var seen = Set<String>()
        for raw in parentReferences {
            let r = EmailFilter.normalizeMessageId(raw)
            if !r.isEmpty, seen.insert(r).inserted { references.append(r) }
        }
        if let pid = parentMsgId, seen.insert(pid).inserted { references.append(pid) }

        // threadId: Gmail only, and only when the stored id belongs to the
        // sending mailbox AND the subject still matches the thread. Both guards
        // prevent a Gmail 400 (invalid thread / subject mismatch) and correctly
        // start a NEW thread when the user switched accounts or changed the
        // subject. `normalizeSubject` strips Re:/Fwd:, so "Re: X"/"Fwd: X" match "X".
        var threadId: String? = nil
        if providerKind == .gmail,
           let tid = parentThreadId, !tid.isEmpty,
           parentAccountId == sendAccountId,
           normalizeSubject(sendSubject) == normalizeSubject(parentSubject) {
            threadId = tid
        }

        return OutgoingThreadHeaders(inReplyTo: parentMsgId, references: references, threadId: threadId)
    }
}
