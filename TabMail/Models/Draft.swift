/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent draft for compose sessions. Stores draft state (recipients, subject, body)
/// and inline edit history so compose chat can resume on reopen.
///
/// Draft keys:
/// - Reply: `"reply:{replyTo.id}"`
/// - Forward: `"forward:{replyTo.id}"`
/// - New compose: `"new:{uuid}"`
struct Draft: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "draft"

    let id: String              // draftKey
    let accountId: String
    var toJSON: String          // JSON array of recipient emails
    var ccJSON: String
    var bccJSON: String
    var subject: String
    var body: String
    let replyToId: String?      // original message header ID for reply/forward
    let isForward: Bool
    var editHistoryJSON: String? // JSON array of InlineEditTurn
    let createdAt: Double       // epoch seconds
    var updatedAt: Double       // epoch seconds

    // v24: Server draft sync
    var serverDraftId: String?    // Gmail draft ID / Exchange message ID / IMAP UID
    var serverPushStatus: String? // nil (not pushed), "pushed", "dirty"
    var rfc822MessageId: String?  // Stable Message-ID for IMAP dedup
    var attachmentsDirName: String? // Disk directory under draft_attachments/

    /// PORT — v2final `Draft.lastTouchedSeq` (its v78; ours is v79). The monotonic
    /// eviction-recency key. Assigned `MAX(lastTouchedSeq) + 1` INSIDE the save
    /// transaction (`DraftStore.applySave`), so under GRDB's single serialized
    /// writer it is strictly increasing with no wall-clock ties and no clock
    /// rollback. `DraftStore.evictImpl` orders by this (DESC) instead of
    /// `updatedAt`, so a just-saved draft can never be mis-ranked beyond the
    /// keep-limit and evicted.
    ///
    /// It is EVICTION RECENCY, NEVER A CONFLICT VERSION — that is
    /// `pushAttemptVersion`, which the Stage A/B CAS compares. Nothing may CAS,
    /// fence, or admit on `lastTouchedSeq`.
    ///
    /// Contract: distinct and increasing among CURRENTLY-RETAINED rows, which is
    /// all eviction needs. It is NOT a global-across-time identity — a value freed
    /// by deleting the MAX row may be reused, which is harmless because eviction
    /// only ever compares survivors (`MAX+1` always exceeds every survivor).
    ///
    /// The declaration default `0` keeps every memberwise-init caller compiling;
    /// the value a caller's snapshot carries is IGNORED — `applySave` overrides it
    /// in-transaction (migration `v79` seeds pre-existing rows with a distinct rank).
    var lastTouchedSeq: Int = 0

    /// PORT — compose generation from v2final commit 3f2cc4c34.
    var instanceEpoch: String? = nil
    /// PORT — conflict version used by the v2final Stage A/B CAS. SEPARATE from
    /// `lastTouchedSeq` above (eviction recency, never a conflict version).
    var pushAttemptVersion: Int = 0
    /// Mailbox component of the strong IMAP draft address.
    var serverDraftFolderPath: String? = nil

    /// v72: the IMAP UIDVALIDITY epoch `serverDraftId` was MINTED under — the
    /// value the SELECT that carried the draft's APPEND reported, returned by the
    /// provider as `DraftCreatedAddress.imap` and written here in the same
    /// statement as `serverDraftId`.
    ///
    /// A bare UID is an ADDRESS scoped to exactly one `(mailbox, UIDVALIDITY)`
    /// pair. Without the epoch it was minted under, nothing downstream can tell a
    /// still-valid address from one the server has since re-pointed at a different
    /// message, so a bare UID with a nil or stale epoch must never activate a
    /// destructive match. Carrying the epoch is what lets
    /// `IMAPProvider.deleteDraft` take its STRONG arm at all: `deleteDraftStrong`
    /// compares the live SELECT's epoch against this one (three outcomes — equal,
    /// provably different, or unknown-because-the-server-omitted-it) and deletes the
    /// addressed UID only on equality.
    ///
    /// ⚠️ CORRECTED 2026-08-06. This used to say the strong arm "FETCH[es] and
    /// corroborate[s]" the Message-ID and that the alternative was "degrading to a
    /// Message-ID search". Neither exists on v3: `deleteDraft(identity:)` accepts
    /// ONLY `.imap(folder, uidValidity, uid)` and `deleteDraftStrong`'s own doc
    /// states it omits the reference's optional RFC corroboration "because v3's
    /// typed identity has no RFC leg". There is no weaker arm to degrade TO — the
    /// alternative to a usable epoch is REFUSAL (`actionIdentityResolutionFailed`),
    /// not a delete. ⚠️ **THAT REFUSAL IS TERMINAL, NOT RETRYABLE — this sentence
    /// said "which is a retryable throw" until 2026-08-06 and it was the wrong
    /// disposition.** `ProviderError.actionIdentityResolutionFailed`'s own
    /// declaration states it is *"DETERMINISTIC and PRE-WIRE: it cannot change on
    /// retry. The drain terminalizes it instead"*, and `drainPendingQueue`'s arm
    /// does exactly that — `PendingOperation.deleteOne`, an adjudicated drop
    /// (`IOS-QUEUE-003` item 4). Do not re-litigate the disposition here: what a
    /// dropped `.deleteDraft` costs, and why the arm must never be split per-id, are
    /// argued at that arm. An RFC 822 Message-ID never selects
    /// or authorizes a mutation target (ADR-IOS-068/D4), so a comment describing one
    /// is not merely stale: it reads as an instruction to restore the banned path.
    ///
    /// nil for a never-pushed draft, for every non-IMAP provider (Gmail/Graph
    /// resource ids are stable and epoch-free), and for any row written before
    /// v72. nil means UNKNOWN — never "unchanged", never zero.
    ///
    /// Ported from `v2final:TabMail/Models/Draft.swift`'s `serverDraftUidValidity`.
    var serverDraftUidValidity: Int?

    /// v80 — the PROVIDER's own id (`MessageHeader.messageId`: an IMAP UID, a Gmail
    /// message id, a Graph message id) for the copy the user actually pressed
    /// Reply/Forward on. Written once, beside `replyToId`, when the reply draft is
    /// first created; never rewritten (`DraftStore.applySave`'s update path starts
    /// from the stored row and does not copy it forward from an incoming snapshot).
    ///
    /// ⚑ NO REFERENCE — INVENTED **key**. The reference (`v2final:Draft
    /// .expectedReplyToRfc` / `acceptStrategy1ReplyHit`) discriminates the reply
    /// target by RFC 822 Message-ID, which only recovers a baseline for a
    /// numeric-IMAP source. This column belongs to the **provider-id (action)**
    /// keying scheme, not the RFC (content) one, because the question it answers is
    /// action-shaped: *which physical copy did the user reply to* — not *which
    /// content*. See `MessageIdentity`'s `ContentKeySpace` doc for why the two
    /// schemes coexist on purpose.
    ///
    /// WHY IT IS NEEDED AT ALL. `replyToId` is a `MessageHeader` PRIMARY KEY, and
    /// that PK is MUTABLE: it is `accountId:folderPath:messageId`, so a folder move
    /// re-keys it, and a UIDVALIDITY reset + purge-and-resync can seat a DIFFERENT
    /// physical message at the very same PK. Accepting the PK hit unconditionally
    /// and then quoting the body found there is how another correspondent's mail
    /// gets quoted into the user's OUTGOING reply.
    ///
    /// nil means UNKNOWN — never "matches", never "differs". Every row written
    /// before v80 has nil here (see `v80_addDraftReplyTargetAddress`: no backfill,
    /// deliberately).
    var replyToProviderMessageId: String? = nil

    /// v80 — the IMAP UIDVALIDITY epoch that was OBSERVED for the reply target when
    /// this draft was created (`MessageHeader.observedUidValidity`, itself set by
    /// the exact SELECT/FETCH that supplied that row's UID).
    ///
    /// This is the half that actually catches the dangerous case: a UIDVALIDITY
    /// reset re-seats a DIFFERENT message at the SAME `(mailbox, uid)` address, so
    /// the provider id alone still compares equal and only the epoch disagrees.
    ///
    /// nil for every non-IMAP provider (Gmail/Graph ids are stable and epoch-free),
    /// for an IMAP row whose address was never proven, and for every pre-v80 row.
    /// nil means UNKNOWN — an *unknown* epoch is retryable/inconclusive, NEVER a
    /// proven mismatch (`CLAUDE.md` "Never Drop User Intention", exit 4 vs clause 2).
    var replyToUidValidity: Int? = nil

    // MARK: - JSON Helpers

    var toArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(toJSON.utf8))) ?? []
    }

    var ccArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(ccJSON.utf8))) ?? []
    }

    var bccArray: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(bccJSON.utf8))) ?? []
    }

    static func encodeStringArray(_ arr: [String]) -> String {
        (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
    }

    // MARK: - Edit History JSON

    /// Codable wrapper for InlineEditTurn (which isn't Codable itself).
    private struct EditTurnCodable: Codable {
        let userRequest: String
        let bodyAtRequest: String
        let subjectAtRequest: String
        let assistantResponse: String
    }

    var editHistory: [InlineEditTurn] {
        guard let json = editHistoryJSON, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EditTurnCodable].self, from: data) else { return [] }
        return decoded.map {
            InlineEditTurn(userRequest: $0.userRequest, bodyAtRequest: $0.bodyAtRequest,
                           subjectAtRequest: $0.subjectAtRequest, assistantResponse: $0.assistantResponse)
        }
    }

    static func encodeEditHistory(_ turns: [InlineEditTurn]) -> String? {
        let codable = turns.map {
            EditTurnCodable(userRequest: $0.userRequest, bodyAtRequest: $0.bodyAtRequest,
                            subjectAtRequest: $0.subjectAtRequest, assistantResponse: $0.assistantResponse)
        }
        guard let data = try? JSONEncoder().encode(codable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Draft Key Helpers

    /// Build a draft key for reply/forward/new compose.
    static func draftKey(replyTo: String?, isForward: Bool, newId: String?) -> String {
        if let replyId = replyTo {
            return isForward ? "forward:\(replyId)" : "reply:\(replyId)"
        }
        return "new:\(newId ?? UUID().uuidString)"
    }

    // MARK: - Reply-target identity guard (T5.8)
    //
    // ONE mechanism, four parts, and reading any part alone will mislead:
    //   `expectedReplyToRfc` + `acceptStrategy1ReplyHit`  — PORT of the reference's
    //       RFC baseline, which is the ONLY baseline a pre-v80 row has;
    //   `ReplyTargetVerdict` + `replyTargetAddressVerdict` — ⚑ INVENTED, v3's
    //       (provider id, UIDVALIDITY) baseline, which is the ONLY baseline that
    //       catches a UIDVALIDITY reset on an RFC-less IMAP message;
    //   `acceptsReplyTargetHit` — the composition, and the whole predicate;
    //   `resolveReplyToHeader` / `resolveReplyQuote` — the ONE-SNAPSHOT consumers.

    /// The verdict of the v80 ADDRESS baseline about a candidate row.
    ///
    /// Three cases, not two, deliberately: "we could not determine the answer" is
    /// NOT a mismatch. Collapsing the two is, per `CLAUDE.md`, "the single most
    /// repeated defect in this codebase's history".
    enum ReplyTargetVerdict: Sendable, Equatable {
        /// The candidate row is PROVABLY the address the draft was stamped against.
        case confirmed
        /// The candidate row PROVABLY names a different address (or a different
        /// UIDVALIDITY epoch at the same address). This — and only this — authorizes
        /// dropping the quote.
        case mismatch
        /// No stamp, or one side's epoch is unknown. Carries no authority in either
        /// direction; the RFC baseline decides.
        case unverifiable
    }

    /// ⚑ NO REFERENCE — INVENTED. The v3 address baseline: does the row now at the
    /// draft's `replyToId` still name the SAME provider copy, under the SAME
    /// UIDVALIDITY epoch, that the user actually replied to?
    ///
    /// - A nil `expectedProviderMessageId` (every pre-v80 row) is `.unverifiable` —
    ///   absence of a stamp is absence of evidence, never evidence of substitution.
    /// - Different provider ids ⇒ `.mismatch` (a positive, proven disagreement).
    /// - Same provider id, both epochs nil, **NOT epoch-addressed** ⇒ `.confirmed`.
    ///   Both nil is the NORMAL, correct state for Gmail/Graph, whose ids are stable
    ///   and never reused, so the address itself is durable identity there.
    /// - Same provider id, both epochs nil, **epoch-addressed** ⇒ `.unverifiable`.
    ///   ⚠ AUDIT ROUND 1 / C-2: this cell used to return `.confirmed` for every
    ///   provider. On IMAP/iCloud a bare UID with no epoch on EITHER side is two
    ///   absences, not an agreement — the id space is renumberable, so "same UID"
    ///   is an address match and nothing more. Confirming it laundered a pair of
    ///   unknowns into positive per-copy identity.
    /// - Same provider id, both epochs present ⇒ equality decides. THIS is the cell
    ///   that catches the UIDVALIDITY reset: the resynced row keeps UID 42 and
    ///   changes only the epoch.
    /// - Same provider id, exactly ONE epoch present ⇒ `.unverifiable`. An unknown
    ///   epoch is retryable/inconclusive, never a proven turnover (`CLAUDE.md`:
    ///   exit 4 requires a PROVEN epoch change and "does not widen clause 2").
    ///
    /// `.unverifiable` carries no authority in EITHER direction — read
    /// `acceptsReplyTargetHit` for what actually admits a candidate.
    static func replyTargetAddressVerdict(
        expectedProviderMessageId: String?,
        expectedUidValidity: Int?,
        hitProviderMessageId: String,
        hitUidValidity: Int?,
        isEpochAddressed: Bool
    ) -> ReplyTargetVerdict {
        guard let expectedProviderMessageId else { return .unverifiable }
        guard expectedProviderMessageId == hitProviderMessageId else { return .mismatch }
        switch (expectedUidValidity, hitUidValidity) {
        case (nil, nil):
            return isEpochAddressed ? .unverifiable : .confirmed
        case let (expected?, hit?):
            return expected == hit ? .confirmed : .mismatch
        default:
            return .unverifiable
        }
    }

    /// Whether an account addresses its messages by a RENUMBERABLE id, i.e. an IMAP
    /// UID inside one `(mailbox, UIDVALIDITY)` epoch. Account-side mirror of
    /// `EmailProvider.staleWindowMode == .uid`, and deliberately the SAME three
    /// clauses as `AIWriteTarget.isEpochAddressed` and
    /// `AccountManager.newGestureRefusedForUnknownEpoch`: `.icloud` is IMAP, and the
    /// demo account is stored as `.imap` but served by `DemoProvider`, so it has no
    /// server, no SELECT and no epoch, ever.
    ///
    /// Fails CLOSED (`true`) when the account row cannot be read: this predicate
    /// only ever TIGHTENS acceptance, so an unknown provider must get the strict
    /// treatment, never the lenient one.
    static func replyTargetIsEpochAddressed(accountId: String, db: Database) throws -> Bool {
        guard let account = try Account.fetchOne(db, key: accountId) else { return true }
        guard accountId != DemoSeed.demoAccountId else { return false }
        return account.provider == .imap || account.provider == .icloud
    }

    /// PORT — `v2final:Draft.expectedReplyToRfc(draftKey:isForward:)`.
    ///
    /// Recover the EXPECTED reply-to RFC 822 Message-ID encoded in a reply/forward
    /// draft key (`"reply:{accountId}:{stableId}"` / `"forward:…"` — `ComposeView`
    /// builds them from `reply.accountId:reply.stableId`). For a numeric-IMAP source
    /// the `stableId` IS the RFC Message-ID (`MessageHeader.stableId`), so this
    /// recovers a real baseline; for Gmail/Graph the `stableId` is the provider
    /// message id, which does not normalize as an RFC Message-ID → nil (the accepted
    /// RFC-less tail — those providers' ids are stable and never reused).
    ///
    /// Because the baseline is EXTERNAL to the mutable `replyToId` PK and to any
    /// candidate row, the guard built on it is not self-referential. It is also
    /// present on EVERY row including pre-v80 ones, which is exactly why the v80
    /// stamp does not replace it.
    ///
    /// ⚑ v3 uses `MessageIdentity.comparableRfc822Identity`, this branch's rename of
    /// the reference's `durableActionRFC822MessageId`. `usableRfc822Tail` is the
    /// WRONG helper here: it additionally rejects a `':'` for CONTENT-KEY folder
    /// scoping, and a server-originated no-fold-literal domain (`<a@[IPv6:…]>`) would
    /// then read as "never the same message" for a message that plainly is.
    static func expectedReplyToRfc(draftKey: String, isForward: Bool) -> String? {
        let prefix = isForward ? "forward:" : "reply:"
        guard draftKey.hasPrefix(prefix) else { return nil }
        let rest = String(draftKey.dropFirst(prefix.count))
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let stableId = String(rest[rest.index(after: colonIdx)...])
        return MessageIdentity.comparableRfc822Identity(stableId)
    }

    /// PORT — `v2final:Draft.acceptStrategy1ReplyHit(expectedRfc:hitRfc:)`.
    ///
    /// The RFC half of the impostor guard. When an `expectedRfc` was recovered from
    /// the draft key, accept the candidate ONLY IF its OWN `rfc822MessageId`
    /// normalizes to the SAME identity — a nil / malformed / different hit RFC means
    /// a purge-and-resync (or a re-key) may have put a DIFFERENT physical message at
    /// that PK. Fail-open belongs ONLY to the RFC-less case (`expectedRfc == nil`),
    /// which is Gmail/Graph plus RFC-less IMAP.
    static func acceptStrategy1ReplyHit(expectedRfc: String?, hitRfc: String?) -> Bool {
        guard let expectedRfc else { return true }
        return MessageIdentity.comparableRfc822Identity(hitRfc) == expectedRfc
    }

    /// THE PREDICATE. May the row currently at the draft's `replyToId` be accepted
    /// as the message the user replied to?
    ///
    /// **On a renumberable (epoch-addressed) id space, accept ONLY on POSITIVE
    /// proof from at least one baseline; elsewhere, accept unless one positively
    /// disagrees.** This is not a "fallback chain" (`CLAUDE.md` rule 4) — nothing
    /// here retries a failed operation, and no branch re-attempts a rejected
    /// candidate a laxer way.
    ///
    /// 🚨 AUDIT ROUND 1 / C-2 — WHY THE RULE IS ASYMMETRIC. This used to be "accept
    /// iff NEITHER baseline positively disagrees", implemented as
    /// `guard addressVerdict != .mismatch` followed by the RFC check. Two silences
    /// therefore ACCEPTED: an RFC-less IMAP message whose draft carried no epoch
    /// (`.unverifiable`) and whose key yielded no RFC baseline (`nil` ⇒ the RFC half
    /// returns `true`) was admitted purely because it sat at the same UID. A
    /// UIDVALIDITY reset during compose re-seats that UID, and `resolveReplyQuote`
    /// then loads the NEW occupant's attribution, body and attachments into the
    /// user's OUTGOING reply — another correspondent's mail leaving the device. An
    /// absence of evidence must never authorize a disclosure; and unlike a durable
    /// queue entry there is nothing to drop here, because omitting a quote costs the
    /// user a paragraph they can re-add, not their intention.
    ///
    /// The asymmetry is not a hedge: on Gmail/Graph the provider id IS durable
    /// identity (never reused, never renumbered), so "no baseline disagrees" really
    /// is proof there. Only a UID needs its epoch to mean anything.
    ///
    /// Where each baseline is load-bearing:
    /// - pre-v80 (legacy) row, IMAP with an RFC id → stamp `.unverifiable`, RFC
    ///   baseline PROVES it. Exactly the reference's behaviour.
    /// - pre-v80 row, Gmail/Graph → both baselines silent → accept, because that id
    ///   space is not renumberable and there is no hazard to guard.
    /// - stamped row, RFC-less IMAP, UIDVALIDITY reset → RFC baseline silent, stamp
    ///   says `.mismatch` → reject. This is what v80 adds over the reference.
    /// - RFC-less IMAP with no epoch on either side → NOTHING proves the copy →
    ///   reject (the C-2 case; the reply is still composable, just unquoted).
    static func acceptsReplyTargetHit(
        expectedRfc: String?,
        expectedProviderMessageId: String?,
        expectedUidValidity: Int?,
        hit: MessageHeader,
        hitIsEpochAddressed: Bool
    ) -> Bool {
        let addressVerdict = replyTargetAddressVerdict(
            expectedProviderMessageId: expectedProviderMessageId,
            expectedUidValidity: expectedUidValidity,
            hitProviderMessageId: hit.messageId,
            hitUidValidity: hit.observedUidValidity,
            isEpochAddressed: hitIsEpochAddressed)
        guard addressVerdict != .mismatch else { return false }
        // Either baseline may still VETO; a veto outranks the other's proof.
        guard acceptStrategy1ReplyHit(expectedRfc: expectedRfc, hitRfc: hit.rfc822MessageId) else { return false }
        // A non-renumberable id space: the address IS the identity, so surviving both
        // vetoes is proof.
        guard hitIsEpochAddressed else { return true }
        // Renumberable: require a POSITIVE confirmation. `expectedRfc != nil` here
        // means the RFC baseline ran AND matched (the veto above would have returned
        // otherwise), which pins the exact physical copy — an RFC identity cannot be
        // borne by two rows at one PK.
        return addressVerdict == .confirmed || expectedRfc != nil
    }

    /// Resolve the reply-to `MessageHeader` from a draft key + `replyToId`, guarding
    /// the PK hit against an impostor. The SOLE entry point; every caller supplies
    /// its own `db` snapshot.
    ///
    /// ⚠️ DO NOT RE-ADD A NON-`db` CONVENIENCE OVERLOAD. One existed
    /// (`v2final:Draft.resolveReplyToHeader(draftKey:replyToId:isForward:)`, ported
    /// with the v80 stamp parameters) whose whole body was
    /// `try? AppDatabase.dbPool.read { … }`. That `try?` collapsed a THROWN read
    /// into the same nil a genuine refusal returns, so a busy or suspended database
    /// was reported to `DraftComposePresenter` as "this draft has no reply parent"
    /// — "we could not look" manufactured into an authoritative negative, the
    /// never-drop clause-2 error. Its last caller moved to this overload in the
    /// reply-target send fix and it was deleted as dead code. A caller that wants
    /// the convenience must decide for ITSELF what a thrown read means.
    ///
    /// PORT — `v2final:Draft.resolveReplyToHeader(draftKey:replyToId:isForward:db:)`.
    /// The `db`-scoped resolver (and the testable seam).
    ///
    /// Strategy 1 = direct PK lookup, GUARDED by `acceptsReplyTargetHit`; on a
    /// refusal it falls through to Strategy 2 = account + RFC scoped lookup, which
    /// is a POSITIVE identity match and therefore survives the IMAP folder move that
    /// re-keys the PK. Both strategies run inside the SAME `db` snapshot.
    ///
    /// Strategy 2 is deliberately NOT re-checked against the v80 address stamp: a
    /// legitimate MOVE gives the same message a new UID, so the stamp would refuse
    /// the very case Strategy 2 exists to recover. Its own `accountId` + normalized
    /// `rfc822MessageId` predicate is the positive identity proof — but ONLY when it
    /// names exactly ONE row; see the cardinality guard at that query.
    static func resolveReplyToHeader(
        draftKey: String,
        replyToId: String?,
        isForward: Bool,
        expectedProviderMessageId: String?,
        expectedUidValidity: Int?,
        db: Database
    ) throws -> MessageHeader? {
        let expectedRfc = expectedReplyToRfc(draftKey: draftKey, isForward: isForward)
        // Strategy 1: direct PK lookup — accepted only when it cannot be an impostor.
        if let replyId = replyToId,
           let header = try MessageHeader.fetchOne(db, key: replyId),
           try acceptsReplyTargetHit(
               expectedRfc: expectedRfc,
               expectedProviderMessageId: expectedProviderMessageId,
               expectedUidValidity: expectedUidValidity,
               hit: header,
               hitIsEpochAddressed: replyTargetIsEpochAddressed(accountId: header.accountId, db: db)) {
            return header
        }
        // Strategy 2: parse accountId + stableId from the draft key, look up by
        // account + rfc822MessageId.
        let prefix = isForward ? "forward:" : "reply:"
        guard draftKey.hasPrefix(prefix) else { return nil }
        let rest = String(draftKey.dropFirst(prefix.count))
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        let normalized = EmailFilter.normalizeMessageId(stableId)
        // An EMPTY normalized id is not an identity — without this it would match any
        // header in the account whose `rfc822MessageId` is the empty string, which is
        // a wrong-message resolution (C3). `DraftStore.evictImpl`'s twin of this query
        // already carries the same guard.
        guard !normalized.isEmpty else { return nil }
        // 🚨 AUDIT ROUND 1 / C-2 — CARDINALITY IS PART OF THE PROOF. This was a bare
        // `fetchOne`, which silently picked an ARBITRARY row whenever more than one
        // matched. `(accountId, rfc822MessageId)` has no uniqueness constraint and is
        // genuinely non-unique in practice: one Gmail message lives under several
        // labels as several header rows, and a Message-ID collision (a buggy sender,
        // a list rewriter) puts two DIFFERENT messages under one identity. What this
        // resolver returns is not content — it drives the reply ADDRESS, the
        // attribution line, the quoted body and the forwarded attachments — so
        // picking "one of them" is exactly the header-specific decision the RFC
        // (content) key cannot make. Two candidates therefore fail CLOSED: the draft
        // and its authored body are untouched, the quote is simply omitted, and the
        // user can still send. `limit(2)` because the only question is one-or-more
        // than-one.
        //
        // 🚨 AUDIT ROUND 3 — REVERTED TO THIS GUARD, DELIBERATELY, AFTER AN ATTEMPT
        // TO REPLACE IT WITH AN IDENTITY WITNESS. Round 2 swapped the cardinality
        // question for agreement on a `(fromAddress, subject, date)` witness, on the
        // reasoning that several rows for ONE message are interchangeable and only a
        // genuine Message-ID COLLISION should refuse. The witness is wrong in BOTH
        // directions, which is what makes it the wrong predicate rather than a
        // predicate needing a fourth field:
        //
        //  - TOO WEAK to prove sameness. It omits everything this resolver actually
        //    consumes — the BODY, the ATTACHMENTS and `replyTo`. Two distinct
        //    messages that share a Message-ID, sender, subject and timestamp both
        //    satisfy it, and the resolver then returns an arbitrary representative
        //    whose body `resolveReplyQuote` loads. A forward can carry content and
        //    attachments from a message the user never selected. That is C3.
        //  - TOO STRICT to prove agreement. Its `date` component is INTERNALDATE
        //    (`IMAPProvider.mapMessageInfo` prefers it over the envelope `Date:`
        //    header), which is per-mailbox-copy: RFC 3501 §6.4.7 makes preserving it
        //    across a COPY a SHOULD, not a MUST, and this app's own APPEND path
        //    stamps `internalDate: Date()`. Legitimate copies of one message can
        //    therefore disagree on it.
        //
        // DO NOT DESIGN A BETTER WITNESS — not a content hash, not a row-incarnation
        // token, not "just add attachments to the tuple". C3 says failing closed is
        // ALWAYS acceptable, and cardinality is the fail-closed predicate.
        //
        // THE ACCEPTED COST, stated rather than hidden: a message legitimately
        // present in several folders or under several Gmail labels will sometimes
        // fail Strategy 2, and the reply ships without its quoted body or the
        // forward without its attachments. The user's own authored text is never
        // touched. Note that shipped `07a4bb703` used a bare `.fetchOne` here — an
        // arbitrary row, i.e. the FAIL-OPEN version — so this guard was already an
        // improvement over the release, and this is a restoration of it, not a
        // regression to it.
        //
        // ⚠️ CORRECTED — "and the send still works" USED TO STAND HERE AND NO
        // LONGER DOES. It was true of this function (which only omits a quote) and
        // false of the system: a refusal ALSO left `ComposeView.send` with no
        // reply parent, so the reply left as a brand-new message — no `In-Reply-To`,
        // no `References`, and `AccountManager.persistQueuedSend` skipped the
        // parent's `isReplied`/`isForwarded` write and the Reply action-tag clear —
        // while the compose dismissed and the draft became deletable on delivery.
        // The cost was adjudicated as "quote and attribution only" on that
        // understated premise. `ComposeView` now derives the SEND's parent from
        // this same resolution (`ComposeDraftGuards.sendReplyTarget`) and BLOCKS the
        // send when a claimed parent resolves to nothing; the local draft stays
        // openable, editable, savable and discardable. So the cost of a refusal is
        // now: no quote, and no send until the user starts the reply again from the
        // original message. See `KNOWN_ISSUES.md` `IOS-DRAFT-009`.
        //
        // This comment edit changes NO executable line in this file.
        let candidates = try MessageHeader
            .filter(Column("accountId") == accountId && Column("rfc822MessageId") == normalized)
            .limit(2)
            .fetchAll(db)
        guard candidates.count == 1 else {
            if candidates.count > 1, DebugModeManager.isLoggingEnabled() {
                print("[Draft] T5.8 Strategy 2 refused for \(draftKey.prefix(40)) — \(candidates.count)+ rows share this account's RFC identity; no single physical copy is proven")
            }
            return nil
        }
        return candidates[0]
    }

    /// PORT — `v2final:Draft.ReplyQuote`.
    ///
    /// The verified reply target paired with its own quoted body — the FULL
    /// `MessageBody`, so callers can also carry forward its attachments (never an
    /// impostor's). `body` is nil when the row simply has no stored body; it is
    /// NEVER an unconfirmed row's body.
    /// `Sendable` because `PrioritizedDatabase`'s ASYNC `read` requires `T: Sendable`
    /// — both stored members already are.
    struct ReplyQuote: Sendable {
        let header: MessageHeader
        let body: MessageBody?
        var bodyHTML: String? { body?.htmlContent }
    }

    /// PORT — `v2final:Draft.resolveReplyQuote(draftKey:replyToId:isForward:providedReplyTo:db:)`,
    /// minus its `providedReplyTo` parameter (see SUBTRACT below) and plus the v80
    /// stamp parameters (⚑ INVENTED).
    ///
    /// Resolve the reply target AND fetch its quoted body in ONE `db` snapshot, so a
    /// reset / re-key landing BETWEEN two independent reads can never pair a
    /// verified header with an impostor's body. Quoting another correspondent's
    /// content into the user's OUTGOING reply is a cross-correspondent leak, which
    /// is why the body is DROPPED rather than guessed.
    ///
    /// Returns nil when no reply target can be positively established. Callers must
    /// render NO attribution and NO quote in that case — the attribution line
    /// carries the correspondent's display name and date, so an unconfirmed
    /// attribution is the same class of leak as an unconfirmed body.
    ///
    /// **SUBTRACT — the reference's `providedReplyTo:` arm is not ported.**
    /// Unreachability proof: the reference's own note records that "every PRODUCTION
    /// caller currently passes `providedReplyTo: nil`", and its two call sites
    /// (`v2final:ComposeView.loadDraftOrPrepopulate` and
    /// `v2final:ComposeView.prepopulate`) both pass nil with the comment "do NOT
    /// trust the pre-captured `replyTo` param, which may be stale". This
    /// forward-port's two call sites are the same two functions and both pass the
    /// stored/held identity through `replyToId` + the stamp instead. A parameter no
    /// caller can supply is dead code (`CLAUDE.md` Code Quality rule 5).
    static func resolveReplyQuote(
        draftKey: String,
        replyToId: String?,
        isForward: Bool,
        expectedProviderMessageId: String?,
        expectedUidValidity: Int?,
        db: Database
    ) throws -> ReplyQuote? {
        guard let header = try resolveReplyToHeader(
            draftKey: draftKey, replyToId: replyToId, isForward: isForward,
            expectedProviderMessageId: expectedProviderMessageId,
            expectedUidValidity: expectedUidValidity, db: db)
        else { return nil }
        // The resolver already validated identity (Strategy-1 guarded, or Strategy-2's
        // exact account+RFC match proven UNIQUE within the account). The body is read
        // from the RESOLVED header's own id in THIS SAME snapshot — never from the
        // caller's mutable `replyToId`.
        let body = try MessageBody.fetchOne(db, key: header.id)
        return ReplyQuote(header: header, body: body)
    }

    /// Whether this draft key represents a reply or forward (vs new compose).
    var isReplyOrForward: Bool { replyToId != nil }

    /// Parse a raw "To" header string into individual email addresses.
    /// Handles: "alice@co.com, bob@co.com" and "Alice <alice@co.com>, Bob <bob@co.com>".
    /// Extracts the bare email address from angle-bracket format.
    static func parseRecipients(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        // Split on commas that are NOT inside angle brackets or quotes
        var result: [String] = []
        var current = ""
        var inAngleBracket = false
        var inQuote = false
        for char in raw {
            if char == "\"" && !inAngleBracket { inQuote.toggle() }
            if char == "<" && !inQuote { inAngleBracket = true }
            if char == ">" && !inQuote { inAngleBracket = false }
            if char == "," && !inAngleBracket && !inQuote {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(extractEmail(from: trimmed)) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(extractEmail(from: trimmed)) }
        return result
    }

    /// Extract bare email from "Name <email>" format. Returns as-is if no angle brackets.
    private static func extractEmail(from token: String) -> String {
        if let start = token.firstIndex(of: "<"), let end = token.firstIndex(of: ">"), start < end {
            return String(token[token.index(after: start)..<end])
        }
        return token
    }
}

// MARK: - Draft Attachment Disk Storage

/// PORT — `v2final:TabMail/Models/Draft.swift`'s `enum DraftAttachmentLoadError`
/// (commit `d2f0c96a3`), verbatim.
///
/// Failure modes for `DraftAttachmentStorage.loadAttachments`. Outbox Reliability
/// Rule 5 applied to drafts: the loader FAILS CLOSED — a compose reopen or a
/// server-draft push must never silently proceed with a SUBSET of the attachments
/// the user attached. Any of these cases throws all-or-nothing rather than
/// dropping a file.
enum DraftAttachmentLoadError: Error {
    /// A draft referenced an attachments directory (non-nil `attachmentsDirName`)
    /// but the directory is missing or its contents could not be enumerated.
    /// A referenced-but-absent dir is NOT "no attachments" — fail closed.
    case directoryUnreadable(dirName: String, underlying: Error)
    /// A present attachment data file could not be read. Never drop it.
    case fileUnreadable(name: String, underlying: Error)
    /// A `.meta`-suffixed file has no corresponding data sibling, so it is
    /// AMBIGUOUS with a real attachment literally named `*.meta` (stored as
    /// `<idx>_*.meta`). The current index-prefix format cannot disambiguate this
    /// from a metadata sidecar, so fail closed rather than silently drop the
    /// real attachment. A disambiguating on-disk manifest is the tracked follow-up.
    case ambiguousMetaFilename(name: String)
}

/// Failure modes that are about the storage LOCATION rather than about a file's
/// contents, so they are shared by `saveAttachments` and `loadAttachments`
/// (`DraftAttachmentLoadError` is a verbatim `v2final` port and stays that way).
enum DraftAttachmentStorageError: Error {
    /// The constructed directory is NOT a descendant of the storage root, so the
    /// operation was refused. See `DraftAttachmentStorage.containedDirURL`.
    case escapesStorageRoot(dirName: String)
}

/// A sender-authored attachment filename this app REFUSES to use.
///
/// Thrown by both attachment stores (`DraftAttachmentStorage.saveAttachments`,
/// `OutboxMessage.saveAttachments`) and by `AttachmentPreviewStager`, because all
/// three ask `AttachmentFilename` the same question and one condition must not
/// have three spellings. It is a peer of `DraftAttachmentStorageError` rather than
/// a case on it because the preview stager is not a draft store.
enum AttachmentFilenameError: LocalizedError {
    /// `name` failed `AttachmentFilename.isSafeFileComponent`. The raw name is
    /// carried for LOGGING (escaped at the sink) and never for display — see
    /// `errorDescription`.
    case unsupported(name: String)

    /// Deliberately REASON-AGNOSTIC, and deliberately not the sender's name.
    ///
    /// - Reason-agnostic because six independent rules can refuse a name and only
    ///   one of them is length: a 48-unit name with a 32-mark combining run is
    ///   refused nowhere near the length budget, so "the file name is too long"
    ///   would be simply false for five of the six (owner decision, 2026-08-12:
    ///   one message for all six rules, no per-rule table, no diagnostic
    ///   breadcrumb).
    /// - Not the sender's name, because the name is exactly the string that was
    ///   refused for being able to misrepresent itself — `"report\u{202E}fdp.exe"`
    ///   renders to a human as `reportexe.pdf`. Quoting it into an error banner
    ///   would put the spoof back on screen at the moment the user is deciding
    ///   what went wrong.
    var errorDescription: String? { AttachmentFilename.unsupportedMessage }
}

/// THE one decision about a sender-authored attachment filename: may it be used
/// VERBATIM as a single path component, and what does the user read when it may
/// not.
///
/// **This replaced a REDUCER on 2026-08-12 (owner decision).** The previous
/// design transformed a hostile name into a safe one — a strip filter, an
/// unassigned-scalar filter, a combining-run cap, a length truncation with
/// extension preservation, and an emptied-stem refill. Five confirmed defects
/// across three audit rounds all lived in that machinery: a name that must be
/// TRANSFORMED to be safe has a large and delicate correctness surface, while a
/// name that is merely TESTED has almost none. This is `CLAUDE.md`'s THE MANTRA
/// applied — *"Simplicity and robustness trumps complications for minor rare edge
/// cases. Edge cases still must be recoverable … if so, fail closed and let it
/// be."* A refused attachment is recoverable: the message is still on the server
/// and the user can reach the file another way, so refusing is a fail-closed edge
/// and not a dropped intention.
///
/// **Accepted cost, stated rather than hidden (owner, 2026-08-12): a LEGITIMATE
/// name can be refused.** A long Hangul or Devanagari name is the realistic case —
/// NFD decomposes each syllable into two or three units, so such a name reaches
/// the 230-unit budget at well under 230 characters. It is refused with the same
/// generic message as a crafted one and with no breadcrumb, and that is
/// deliberate: no debug affordance, no "show original name" escape hatch, no
/// telemetry hook, no per-rule diagnostic.
enum AttachmentFilename {

    /// What a display site renders IN PLACE OF a refused name. A bare literal,
    /// matching the surrounding views (this app has no `String(localized:)`
    /// convention in them).
    static let unsupportedLabel = "Unsupported file name"

    /// What a refused ACTION says. See `AttachmentFilenameError.errorDescription`
    /// for why it names no reason and quotes no name.
    static let unsupportedMessage = "This attachment's file name isn't supported."

    /// The MEASURED upper bound on one path component, in the unit the
    /// filesystem actually counts in: NFD-normalised UTF-16 code units. Bisected
    /// against a real filesystem rather than read off a document — see
    /// `isSafeFileComponent`'s doc for the two guesses this refutes, and
    /// `AttachmentFilenameContainmentTests`' measured-cap test, which re-derives
    /// it wherever the suite runs instead of trusting this constant.
    private static let maxPathComponentUnits = 255

    /// What a filename may spend, i.e. the component limit minus the widest
    /// wrapper any caller adds to it. `saveAttachments`' sidecar is that widest
    /// name: `"\(index)_" + component + ".meta"`. The index comes from
    /// `enumerated()`, so `String(Int.max).count` is the only bound that cannot be
    /// wrong; the `1` is the `"_"`.
    ///
    /// `AttachmentPreviewStager` adds no wrapper at all, so the same budget is
    /// merely conservative there — one shared budget is what keeps every caller
    /// asking one question.
    private static let attachmentComponentBudgetUnits =
        maxPathComponentUnits - String(Int.max).count - 1 - ".meta".count

    /// The MEASURED upper bound on one CANONICAL COMBINING SEQUENCE inside a path
    /// component — a starter plus the non-starters that follow it — counted on the
    /// NFD form. INDEPENDENT of `maxPathComponentUnits`, which is why it needs its
    /// own budget: see `isSafeFileComponent`'s doc for the sweep behind both the
    /// value and the unit.
    private static let maxCombiningSequenceScalars = 32

    /// What a filename may spend on CONSECUTIVE NON-STARTERS. The sequence limit
    /// above is spent by the starter too, and a caller's wrapper can supply that
    /// starter — `saveAttachments`' `"\(index)_"` puts a `_` immediately in front
    /// of a LEADING run — so one scalar is reserved for it and one more is left as
    /// margin. Ten times the widest run measured in any real orthography (3).
    private static let combiningRunBudgetScalars = maxCombiningSequenceScalars - 2

    /// The scalars a filename may not CONTAIN. Enumerated deliberately, because
    /// the two halves are here for two DIFFERENT reasons and a future reader has
    /// to be able to tell which is which before touching either.
    ///
    /// ⚠️ These 79 scalars were STRIPPED from a name until 2026-08-12; a name
    /// carrying one is now refused whole. The measurements below are why each
    /// range is in the set, and they are unchanged by that — a scalar that could
    /// make a name misrepresent itself is exactly as unacceptable in a name that
    /// is kept verbatim.
    ///
    /// **Cc — `U+0000...U+001F` and `U+007F...U+009F`.** `U+0000` truncates any C
    /// string the name is handed to, and none of the rest render, so a name
    /// carrying them displays as something other than what it is. Measured on
    /// this toolchain (Apple Swift 6.3.3) by sweeping `U+0000...U+10FFFF`: these
    /// two ranges are EXACTLY Unicode general category Cc, with no member
    /// outside them.
    ///
    /// **The bidi embeddings, overrides and isolates — `U+202A...U+202E` and
    /// `U+2066...U+2069`.** These let a SENDER pick an extension the user never
    /// sees. Measured through CoreText — the real bidi algorithm — by differencing
    /// the visible glyph order against the same name without the scalar:
    /// `"report\u{202E}fdp.exe"` lays out to a human as `reportexe.pdf`, so the
    /// user opens what reads as a PDF. On an all-Latin name `U+202E` is the ONLY
    /// one that does this; the embeddings and isolates changed nothing there, but
    /// they DO reposition runs once the name also holds a strong RTL character
    /// (the Trojan-Source shape, CVE-2021-42574) and they have no legitimate role
    /// in a filename, so the whole enumerated block goes.
    ///
    /// ⚠️ **This was `CharacterSet.controlCharacters` until 2026-08-12, and that
    /// is the thing not to go back to.** That set is NOT category Cc, and it is
    /// not Cc ∪ Cf either — swept on this toolchain it holds **24,970** scalars:
    /// Cc 65, Cf 170, 97 nonspacing marks, and 24,638 scalars the standard
    /// library reports UNASSIGNED (essentially all of plane 14). So
    /// `controlCharacters.subtracting(<the Cf scalars>)` is NOT a way to get back
    /// to Cc; the explicit ranges above are. Using it mangled ordinary names with
    /// no truncation involved: `U+200D` ZWJ went, so `👨‍👩‍👦report.pdf` was
    /// stored as `👨👩👦report.pdf` — one family emoji flattened into three — and
    /// the `U+E0020...U+E007F` tag characters went, turning the Scotland flag
    /// `🏴󠁧󠁢󠁳󠁣󠁴󠁿` into a plain black flag AT THE SAME CHARACTER COUNT.
    /// `U+200C` ZWNJ is a letter-shaping distinction in Persian, not decoration.
    /// Under REJECTION the same over-wide set would be worse still: every one of
    /// those ordinary names would now be refused outright rather than mangled,
    /// which is why the set stays enumerated and narrow.
    ///
    /// **The directional MARKS — `U+200E` LRM, `U+200F` RLM, `U+061C` ALM — are
    /// in the set as well (owner decision, 2026-08-12: "strip them everywhere").**
    /// They were deliberately KEPT until then, on the measured ground that they
    /// "cannot reverse a run of strong LTR characters, so they cannot manufacture
    /// the all-Latin extension swap". The premise is still true and the
    /// conclusion drawn from it was wrong: a mark does not have to reverse
    /// anything INSIDE a run, because it reorders the RUNS. Re-measured through
    /// the same CoreText glyph-position harness, with the mark LEADING so no
    /// strong-LTR character anchors the paragraph direction:
    ///
    ///     "\u{200F}pdf\u{200F}.exe"    logical ext .exe    VISIBLE  exe.pdf   <-- SPOOF
    ///     "\u{061C}pdf\u{061C}.exe"    logical ext .exe    VISIBLE  exe.pdf   <-- SPOOF
    ///     "report\u{200F}fdp.exe"      logical ext .exe    VISIBLE  reportfdp.exe
    ///
    /// ⚠️ **Why two rounds of measurement missed this, which is the transferable
    /// part:** every earlier fixture inserted the mark into a name BEGINNING with
    /// strong-LTR text (`report…`), which fixes the paragraph direction and makes
    /// the swap impossible. A `report`-prefixed fixture is green on the unfixed
    /// code and proves nothing, so `AttachmentFilenameContainmentTests` pins the
    /// LEADING-mark shape instead.
    ///
    /// `U+200E` LRM alone did NOT reorder that fixture (`"\u{200E}pdf\u{200E}.exe"`
    /// lays out as `pdf.exe`); it goes with the other two because the owner's
    /// decision covers the set, and because "this mark reorders runs and that one
    /// does not, in this paragraph context" is not a distinction a filename can
    /// carry. The legitimate use these had — fixing the order of a mixed Arabic
    /// or Hebrew filename — does not need them: a name's own strong-RTL letters
    /// order correctly with no explicit mark present (measured, `דוח.pdf` lays
    /// out as `pdf.חוד`).
    ///
    /// **`U+2028` (Zl) and `U+2029` (Zp) — the mandatory line breaks outside
    /// Cc.** Measured with `CTTypesetterSuggestLineBreak` at 100,000pt, so the
    /// break is mandatory rather than width-driven: `"invoice.pdf\u{2028}.exe"`
    /// breaks after `invoice.pdf`, so a one-line label shows a PDF and the `.exe`
    /// is on a line nobody sees. Sweeping for that property found exactly seven
    /// mandatory-break scalars — `U+000A`, `U+000B`, `U+000C`, `U+000D`,
    /// `U+0085`, `U+2028`, `U+2029` — and the first five are already covered,
    /// because they are Cc. These two were the only ones the set missed.
    ///
    /// ⚠️ **WHAT THIS BUYS, STATED AT THE WIDTH IT ACTUALLY HOLDS: no INVISIBLE
    /// scalar can make an ACCEPTED filename render as a different type. NOT "a
    /// filename cannot render as a different type" — that is not achievable by
    /// refusing a scalar set, and this comment must never be widened back to
    /// it.** The vector survives in ORDINARY VISIBLE LETTERS. Measured 2026-08-12
    /// through the same CoreText glyph-position harness: of the 63 visible
    /// strong-RTL letters swept (Hebrew `U+05D0...U+05EA`, Arabic
    /// `U+0621...U+063A` and `U+0641...U+064A`), **all 63** make
    /// `"<X>pdf<X>.exe"` lay out with a rendered extension different from the
    /// stored one — `"\u{05D0}pdf\u{05D0}.exe"` reads as `exe.אpdfא`. They are
    /// letters, not format characters; refusing them would refuse every Hebrew
    /// and Arabic filename, which is strictly worse than the spoof.
    ///
    /// And the reorder is not even a reliable SIGNAL of a spoof, which is why no
    /// membership rule can separate the two cases: the legitimate Hebrew name
    /// `דוח.pdf` lays out as `pdf.חוד` on exactly the same measurement. That is
    /// CORRECT bidi rendering of a genuine RTL name, and it is indistinguishable
    /// from the crafted case by layout alone. So the residual risk is BOUNDED, not
    /// eliminated: a filename holding strong-RTL letters can still read to a human
    /// as a different type. Directional isolates (`U+2066`/`U+2069`) around the
    /// name AT EACH DISPLAY SITE are the mitigation for that, and they are
    /// deliberately NOT applied here — `displayLabel`'s output also names a real
    /// staged file, so wrapping it would corrupt the filename on disk. It is a
    /// display-layer follow-up, tracked, not done.
    ///
    /// Pinned by `AttachmentFilenameContainmentTests`.
    private static let refusedFilenameScalars: CharacterSet =
        CharacterSet(charactersIn: "\u{0000}"..."\u{001F}")
        .union(CharacterSet(charactersIn: "\u{007F}"..."\u{009F}"))
        .union(CharacterSet(charactersIn: "\u{061C}"..."\u{061C}"))
        .union(CharacterSet(charactersIn: "\u{200E}"..."\u{200F}"))
        .union(CharacterSet(charactersIn: "\u{2028}"..."\u{2029}"))
        .union(CharacterSet(charactersIn: "\u{202A}"..."\u{202E}"))
        .union(CharacterSet(charactersIn: "\u{2066}"..."\u{2069}"))

    /// What a display site renders for `filename`: the sender's own name when it
    /// is safe, and `unsupportedLabel` when it is not.
    ///
    /// Every ATTACHMENT-LIST, COMPOSE-CHIP and `.eml`-SHEET display site renders
    /// this rather than `attachment.filename`, and that requirement came from a
    /// defect rather than from tidiness: `AttachmentListView.body` rendered
    /// `Text(attachment.filename)` — the RAW sender-authored MIME parameter — so
    /// measured, `"report\u{202E}fdp.exe"` appeared in the list row as
    /// `reportexe.pdf`, on the exact screen where the user decides whether to tap.
    ///
    /// ⚠️ **NOT "every display site".** Two sites render a RAW attachment filename
    /// and are outside the scan that pins this property
    /// (`attachmentFilenamesAreRenderedThroughThePredicate` walks three view
    /// files):
    /// - `EmlMarker.embeddedHeadersHtml` puts the filename in a `<b>` banner. It is
    ///   CSS-hidden in BOTH view modes — `EmailHTMLWrapper` emits
    ///   `.tm-eml-section { display: none !important; }` in main view, and
    ///   `body.tm-preview-mode .tm-eml-headers { display: none !important; }` in
    ///   preview mode — so it does not reach the screen. Confirmed by reading both
    ///   branches, not inferred from the class name.
    /// - `EmlMarker.embeddedHeadersPlainText` emits `--- <filename> ---` into the
    ///   PLAIN-TEXT body, and that one is **NOT** hidden: its own call site in
    ///   `IMAPFetchMapping.renderBodyWithEmbeddedHeaders` says so in as many words
    ///   ("Plain text mode: keep the historical flat interleaving (no CSS to
    ///   apply, no preview sheet — users read plain text inline)"), and
    ///   `BodyRenderer` renders that text through `EmailFilter.plainTextToHTML`
    ///   when the message has no HTML part. So a message with no `text/html` part
    ///   and a nested `.eml` shows the sender's RAW attachment filename inline. It
    ///   is escaped exactly once, so this is a rendering-order exposure and not an
    ///   injection one.
    /// Neither site is a regression from this round; both predate it. They are
    /// recorded rather than fixed because routing them through this label changes
    /// the FTS-indexed and wire-visible body text, which is a different blast
    /// radius from a label.
    ///
    /// The two `data-filename` MATCH-KEY sites are deliberately RAW as well:
    /// `AutoSizingHTMLView(previewFilename:)` and
    /// `EmailFilter.parseEmlSectionMetadata` match the value against the
    /// `data-filename` attribute the renderer wrote from the same MIME parameter,
    /// so labelling it there would stop the section from being found.
    static func displayLabel(_ filename: String) -> String {
        isSafeFileComponent(filename) ? filename : unsupportedLabel
    }

    /// Whether `filename` may be used VERBATIM as ONE path component — the whole
    /// question this type exists to answer, asked identically by
    /// `DraftAttachmentStorage.saveAttachments`, `OutboxMessage.saveAttachments`,
    /// `AttachmentPreviewStager` and every display site.
    ///
    /// `att.filename` reaches all of them UNREDUCED from `AttachmentInfo.filename`
    /// — the sender-authored MIME `filename` parameter — carried in by
    /// `ComposeView.carryForwardAttachments` on the compose side and straight off
    /// the wire on the display side. A name is safe iff ALL SIX hold. Each rule
    /// below existed as a TRANSFORMATION in the reducer this replaced, and carries
    /// the measurement that sized it.
    ///
    /// **1 — it is not empty and does not spell `.` or `..`, in any encoding.**
    /// Asserted as an OUTCOME, not as a list of refused names: the candidate is
    /// appended to a probe directory, the result standardised, and its parent must
    /// be the probe.
    ///
    /// ⚠️ **It WAS a list of refused names until 2026-08-12, and the list was
    /// incomplete in a way no list could have fixed.** The guard refused exactly
    /// the strings `"."` and `".."`, and `URL.appendingPathComponent` DROPS a
    /// trailing NUL — so `"..\u{0}"` passed the guard and resolved to the PARENT of
    /// the directory it was appended to, and `"\u{0}"` collapsed to that directory
    /// itself. Measured against a real filesystem: the write fails
    /// `NSCocoaErrorDomain` 512, no bytes land and a planted sibling survives, so
    /// it was not exploitable — but the post-condition was false, and adding
    /// `"..\u{0}"` to the list would have been the same mistake one entry longer.
    ///
    /// ⚠️ **THE PROBE DIRECTORY IS NOT ARBITRARY: IT MUST HAVE DEPTH ≥ 1.** This
    /// comment claimed until 2026-08-12 that it *was* arbitrary "because
    /// `appendingPathComponent` transforms the component independently of the base,
    /// so the verdict cannot depend on which directory it is checked against". The
    /// claim is false and so is the mechanism it cites.
    /// - Measured: **at the root, `"."`, `".."`, `""`, `"\u{0}"` and `"..\u{0}"` all
    ///   PASS**; at every depth ≥ 1 they all fail. `/probe` (depth 1) is what makes
    ///   rule 1 able to refuse anything at all.
    /// - The verdict turns on **`.standardized`**, not on `appendingPathComponent`.
    ///   `.standardized` collapses `..` against the base's own DEPTH: `/a/..`
    ///   collapses to `/`, whose parent `/` differs from `/a`, so the test says
    ///   ESCAPED — while `/..` also collapses to `/`, and there
    ///   `deletingLastPathComponent` is a FIXPOINT, so the test says CONTAINED.
    ///   `appendingPathComponent` really is base-oblivious; it is simply not the
    ///   step the verdict comes from.
    /// The property that actually holds — invariance across bases of depth ≥ 1,
    /// PLUS the divergence at depth 0, PLUS this predicate's own probe being
    /// non-root — is pinned by
    /// `containmentVerdictIsInvariantBelowTheRootAndDivergesAtIt`. **If this probe
    /// is ever relocated, it must stay below the root**, or rule 1 silently accepts
    /// every traversal name it exists to refuse.
    ///
    /// **2 — it contains no `U+002F`, and appending it nests below nothing.** Both
    /// halves are needed and neither implies the other. The probe alone accepts
    /// `"invoice.pdf/"`, because `appendingPathComponent` DROPS a trailing
    /// separator — the name would then be used verbatim in a string context (the
    /// `"\(index)_\(name)"` data name and its `"\(that).meta"` sidecar) while
    /// resolving to something else on disk. The scalar test alone accepts `".."`.
    ///
    /// ⚠️ The scalar test runs over UNICODE SCALARS, not `Character`s, and that is
    /// load-bearing. Swift `String` iterates EXTENDED GRAPHEME CLUSTERS, so
    /// `U+002F` followed by a combining mark (e.g. `U+0301`) forms ONE cluster that
    /// is **not** equal to `Character("/")` — a `Character`-wise test does not see
    /// it, while the UTF-8 bytes still carry a real `0x2F` that the filesystem
    /// treats as a path separator. Measured pre-fix: such a name came back
    /// unreduced, so `"\(index)_\(name)"` was a MULTI-COMPONENT path
    /// (`0_../́x.pdf`) whose first component the slot does not contain, the write
    /// threw, and the draft was unsavable and the message unsendable. On the
    /// preview path the same name landed the bytes one level up, in the
    /// per-message namespace a sibling preview reads from.
    ///
    /// **3 — it contains no scalar in `refusedFilenameScalars`** (79 scalars: C0,
    /// C1, the bidi overrides/embeddings/isolates, ALM, LRM/RLM, LS/PS). The
    /// measurement behind each range is on that constant.
    ///
    /// **4 — it contains no scalar whose general category is `unassigned`, and
    /// that one is a FILESYSTEM requirement rather than a rendering one.**
    /// Measured 2026-08-12 by sweeping every scalar `U+0000...U+10FFFF` as a real
    /// path component on APFS: the set the filesystem refuses is EXACTLY the
    /// scalars whose general category is `unassigned` — 814,730 of them, with zero
    /// disagreements in either direction. `open(2)` itself raises `EILSEQ` (errno
    /// 92, confirmed with a raw POSIX open), surfacing as `NSCocoaErrorDomain` 512
    /// / `NSPOSIXErrorDomain` 92. The predicate is the scalar's OWN Unicode
    /// property rather than a range list, because a range list goes stale at every
    /// Unicode revision while the property tracks whatever this toolchain knows —
    /// which is also what decides whether the name normalises to something the
    /// filesystem will accept.
    ///
    /// **5 — no canonical combining SEQUENCE is longer than
    /// `combiningRunBudgetScalars`, counted on the NFD form.** A path component may
    /// not contain a canonical combining sequence — one starter plus the
    /// non-starters that follow it — longer than `maxCombiningSequenceScalars`, and
    /// `open(2)` raises `EILSEQ` when it does. Measured 2026-08-12:
    /// `"invoice" + 32 × U+0301 + "-2026.pdf"` is 48 NFD units against a 230-unit
    /// budget and still fails the write.
    ///
    /// ⚠️ **THE PREDICATE IS THE CANONICAL COMBINING CLASS, NOT GENERAL CATEGORY
    /// `Mn`/`Mc`/`Me`, AND IT IS MEASURED ON THE NFD FORM.** Both halves were
    /// swept rather than assumed:
    /// - Every `ccc != 0` scalar tried failed at exactly the same length —
    ///   `U+0301` (230), `U+0323` (220), `U+0345` (240), `U+05B0` (10), `U+0E48`
    ///   (107), `U+3099` (8), `U+0483` (230), `U+0F71` (129), `U+064B` (27),
    ///   `U+0655` (220) — while every `ccc == 0` scalar was unlimited to 60
    ///   repetitions **including the marks** `U+0E31` (Mn), `U+0903` (Mc),
    ///   `U+093E` (Mc), `U+20DD` (Me) and `U+FE0F` (Mn). A category test would be
    ///   wrong in both directions.
    /// - `U+00E1 + 31` marks is REFUSED although its literal sequence is 32,
    ///   because it decomposes to `a` + 32 marks; `U+1EC7` (which decomposes to
    ///   `e` + two marks) fails two marks earlier again. So the count runs on
    ///   `decomposedStringWithCanonicalMapping`.
    /// - Any `ccc == 0` scalar RESETS the run, so the `"\(index)_"` prefix and the
    ///   `".meta"` suffix cannot lengthen one — but a `_` immediately before a
    ///   LEADING run does occupy one slot of the sequence, which is why
    ///   `combiningRunBudgetScalars` reserves a starter.
    /// - The two caps are INDEPENDENT and the length one never engages first:
    ///   `200 × "a" + 32` marks is 232 units and fails `EILSEQ`, while
    ///   `240 × "a" + 31` marks is 271 units and fails `ENAMETOOLONG` instead.
    /// Cross-checked over 3,999 randomised names (runs 0–40, 0–4 runs per name,
    /// leading/interior/trailing, precomposed and decomposed bases, lengths
    /// straddling 255) plus 968 non-starter scalars × two boundary lengths: zero
    /// disagreements with `nfd units <= 255 && longest sequence <= 32 && nothing
    /// unassigned`.
    ///
    /// Legitimate orthography is nowhere near the cap: the widest sequence in a
    /// 41-name multi-script fixture set is 4 scalars, and the widest run any single
    /// assigned scalar produces through its own decomposition is 3 (`U+1F82`).
    ///
    /// **6 — it fits `attachmentComponentBudgetUnits`, in NFD UTF-16 units.**
    ///
    /// ⚠️ **THE UNIT IS MEASURED, AND IT IS NEITHER OF THE TWO OBVIOUS GUESSES.**
    /// Bisected against the real filesystem 2026-08-12 (macOS host APFS, and
    /// re-measured inside the simulator by the test named below): a path component
    /// is accepted iff `decomposedStringWithCanonicalMapping.utf16.count <= 255` —
    /// NFD-normalised UTF-16 code units.
    /// - NOT 255 UTF-8 bytes. 86 × `U+6F22` is 258 bytes and stores fine.
    /// - NOT 255 `Character`s. 128 × `U+00E9` is 128 characters and 128 UTF-16
    ///   units, and is REFUSED, because APFS decomposes it to 256 units.
    /// - Cross-checked over 400 randomised mixed strings straddling the boundary:
    ///   0 disagreements with that predicate.
    /// Both wrong units are wrong in the UNSAFE direction, which is why neither is
    /// an acceptable conservative stand-in.
    ///
    /// **THE BUDGET IS THE COMPONENT LIMIT MINUS THE WIDEST WRAPPER ANY CALLER
    /// ADDS**, because what has to fit is the DERIVED name, not this argument:
    /// `saveAttachments` writes `"\(index)_\(name)"` and a `"\(that).meta"`
    /// sidecar, so the sidecar is the longest of the three and it is what overflows
    /// first. Accepted cost, stated rather than hidden: a name between the budget
    /// and the raw component limit is refused although it would have fitted the
    /// preview path, which adds no wrapper. That is ~25 units off a name already at
    /// the filesystem ceiling.
    ///
    /// ⚠️ **WHAT REFUSAL COSTS, so it is not discovered later as a surprise.** On
    /// the OUTGOING path the user cannot save the draft or send the message while
    /// that attachment is attached — `saveAttachments` throws
    /// `AttachmentFilenameError` and compose shows it without dismissing (Outbox
    /// Reliability Rules 1 and 5: never dropped, never sent with a wrong or missing
    /// attachment). On the INCOMING path the row is labelled `unsupportedLabel` and
    /// the download/preview is refused. The message itself is untouched on the
    /// server either way, which is the recoverability the mantra requires.
    ///
    /// **LOADING needs no migration. RE-SAVING a legacy draft CAN fail closed, and
    /// that is an accepted cost, not a guarantee.**
    ///
    /// The loader half is unconditional and unchanged: neither loader ever
    /// recomputes an attachment's DATA filename in order to locate it —
    /// `loadAttachments` here and `OutboxMessage.loadAttachments` both
    /// `contentsOfDirectory` the slot and strip the `<index>_` prefix off whatever
    /// they find — so every name already on disk still loads, and its row still
    /// renders (through `displayLabel`, as `unsupportedLabel` when the name is
    /// refused).
    ///
    /// ⚠️ **This comment also claimed, until 2026-08-12, that every name already on
    /// disk — "including every name the old reducer transformed" — is ACCEPTED by
    /// this predicate "because the reducer's output satisfied exactly these six
    /// rules by construction", so a draft saved before this round could always be
    /// reopened AND RE-SAVED. That is FALSE, and the premise under it never
    /// existed: NO SHIPPED BUILD EVER RAN A REDUCER.** `v1.7.6`, `v1.7.7` and
    /// `v1.7.8` (the newest tag) contain neither `safeAttachmentFileComponent` nor
    /// `isSafeFileComponent`, and `v1.7.8`'s two stores write
    /// `"\(index)_\(att.filename)"` verbatim and unchecked. The reducer was
    /// introduced by `711afc6b8` and deleted by `c35cfdca2` on the same unreleased
    /// line, ~15 hours apart. So the population on disk in any shipped install is
    /// RAW SENDER-AUTHORED names.
    ///
    /// The at-risk set is narrower than "refused names", because `v1.7.8` wrote
    /// unchecked but `open(2)` still had to accept the data file AND its `.meta`
    /// sidecar. Measured intersection — three shapes: **any of the 79 refused
    /// scalars** (all 79 wrote, zero filesystem refusals); **231–248 NFD units at a
    /// single-digit index**, 18 units wide, because the 230 budget reserves
    /// `String(Int.max).count` while a real index spends two characters; and **a
    /// combining run of exactly 31**, one value wide, because
    /// `combiningRunBudgetScalars` is `32 - 2` while the filesystem accepts a
    /// 32-scalar sequence. Unassigned scalars, runs ≥ 32, separators and every
    /// containment failure CANNOT be on disk — `v1.7.8` could not write them.
    ///
    /// What that costs, stated at the width it actually holds:
    /// - **Loading and display are unaffected** — the loader half above.
    /// - **Every WRITE path throws `AttachmentFilenameError.unsupported`:**
    ///   `ComposeView.saveDraftAndDismiss` and `ComposeView.send`'s COW staging,
    ///   `DynamicIslandChatButton.autoSaveDraft`, and `AccountManager.queueSend` →
    ///   `persistQueuedSend` → `OutboxMessage.saveAttachments`. Compose shows the
    ///   generic message and does NOT dismiss (Outbox Reliability Rules 1 and 5).
    /// - **Recovery is one ordinary gesture — remove the attachment.** The draft
    ///   then saves and the message sends; the original is untouched on the server.
    /// - **An outbox row ALREADY QUEUED before the upgrade is unaffected.** The
    ///   drain runs `OutboxMessage.toDraftMessage` → `loadAttachments`, which reads
    ///   the files that are already there and never re-saves them, so a send in
    ///   flight still goes out.
    ///
    /// Registered as `IOS-ATTACH-001`. Per THE MANTRA this is a recoverable
    /// fail-closed edge, so it is registered rather than mechanised: **do NOT add a
    /// migration, a rename-on-load, or a grandfathering path.** Re-introducing a
    /// transformation is exactly what `ADR-IOS-077` deleted.
    static func isSafeFileComponent(_ filename: String) -> Bool {
        // Rules 2, 3 and 4, in one pass over the scalars the SENDER wrote.
        for scalar in filename.unicodeScalars {
            if scalar == "/" { return false }
            if refusedFilenameScalars.contains(scalar) { return false }
            if scalar.properties.generalCategory == .unassigned { return false }
        }
        // Rules 5 and 6, on the DECOMPOSED form, because that is what the
        // filesystem counts: a precomposed base contributes its own marks to both.
        let decomposed = filename.decomposedStringWithCanonicalMapping
        var run = 0
        for scalar in decomposed.unicodeScalars {
            run = scalar.properties.canonicalCombiningClass == .notReordered ? 0 : run + 1
            if run > combiningRunBudgetScalars { return false }
        }
        guard decomposed.utf16.count <= attachmentComponentBudgetUnits else { return false }
        // Rule 1, and the half of rule 2 no scalar test can express: the OUTCOME.
        let probe = URL(fileURLWithPath: "/", isDirectory: true)
            .appendingPathComponent("probe", isDirectory: true)
        return probe.appendingPathComponent(filename).standardized
            .deletingLastPathComponent().path == probe.standardized.path
    }
}

/// Mirrors OutboxMessage's attachment storage pattern for drafts.
/// Attachments stored under `Application Support/TabMail/draft_attachments/{dirName}/`.
enum DraftAttachmentStorage {

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("draft_attachments", isDirectory: true)
    }

    /// `root` is a test seam: when nil (production) the global `baseDir` is used;
    /// tests inject a temporary directory so they can create/mutate real files.
    ///
    /// ⚠️ RAW CONSTRUCTION — performs NO containment check, because a `dirName`
    /// containing `/` or `..` escapes the storage root (see `newStagingDirName`'s
    /// doc for why a `draftId` is not a safe path component). Every entry point
    /// that actually touches the filesystem goes through `containedDirURL`
    /// instead. This one stays raw so a test can still ask "where would this name
    /// land?" without the answer being filtered.
    static func dirURL(for dirName: String, root: URL? = nil) -> URL {
        (root ?? baseDir).appendingPathComponent(dirName, isDirectory: true)
    }

    /// THE containment chokepoint for every filesystem-touching entry point
    /// (`saveAttachments`, `loadAttachments`, `deleteAttachments`, and eviction
    /// via `deleteAttachments`). Returns the directory URL iff it is a strict
    /// DESCENDANT of the storage root; `nil` means the caller must fail closed.
    ///
    /// WHY IT IS "CONTAINMENT", NOT "REJECT ANY `/`". v3 fixed only the WRITE
    /// side of the unsafe-path-component hazard — both `ComposeView` COW staging
    /// sites now mint `newStagingDirName()` — but the DELETE side was never
    /// ported: `DraftStore.deleteAsync` still passes the raw draft id, and every
    /// other call site passes a persisted `attachmentsDirName` which, on a
    /// `v1.6.38 → v3` upgrade, holds shipped's `draftId` value. Shipped saved
    /// those with `createDirectory(withIntermediateDirectories: true)`, so a
    /// legacy reply draft whose id is `reply:<acct>:<local/part>@<domain>` REALLY
    /// HAS its attachments at a nested-but-contained path under the root.
    ///
    /// ⚠️ NEGATIVE CASE, stated because the mirror-image fix is the tempting one:
    /// a predicate of "refuse any `dirName` containing `/`" would make exactly
    /// those legacy attachments permanently unloadable and unreclaimable — it
    /// would trade a containment bug for silent loss of user content, which is
    /// strictly worse. Contained nesting MUST keep working; only escape ABOVE the
    /// root is refused. An empty or `.`-only name is also refused: it resolves to
    /// the root itself, which is not a draft's slot and whose recursive delete
    /// would take every other draft's attachments with it.
    ///
    /// Symlinks are deliberately NOT resolved (`standardizedFileURL`, not
    /// `resolvingSymlinksInPath()`): the candidate usually does not exist yet, so
    /// symlink resolution is partial and asymmetric with the root's, which would
    /// refuse legitimate saves. Textual `..` collapsing is what the escape
    /// primitive actually needs.
    static func containedDirURL(for dirName: String, root: URL? = nil) -> URL? {
        let base = (root ?? baseDir).standardizedFileURL
        let candidate = dirURL(for: dirName, root: root).standardizedFileURL
        let basePath = base.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    /// PORT — `v2final:TabMail/Models/Draft.swift`'s
    /// `DraftAttachmentStorage.newStagingDirName()` (F0f), verbatim.
    ///
    /// The ONE source of truth for a copy-on-write staging directory name. An
    /// OPAQUE UUID: a single filesystem path component containing no `/`, `:` or
    /// any other path character. This is what makes the COW staging safe on TWO
    /// axes:
    ///
    /// 1. **Copy-on-write.** A fresh, never-referenced name means the new
    ///    attachment set is written somewhere the durable row does not point at,
    ///    so a save that fails or is superseded can be cleaned up without ever
    ///    touching the LIVE directory (persist-before-destroy).
    /// 2. **Path containment.** The superseded call sites derived the directory
    ///    name from `draftId`, and a `draftId` is NOT a safe path component: a
    ///    reply/forward key is `reply:<accountId>:<stableId>` where `stableId` is
    ///    an RFC 822 Message-ID whose local part may legally contain `/` (RFC 5322
    ///    `atext` includes `/`), and an Exchange/Graph resource id is base64 which
    ///    also contains `/`. `appendingPathComponent` treats those as SEPARATORS,
    ///    so the "directory" silently NESTS under an attacker/provider-chosen
    ///    subpath — escaping the intended `draft_attachments/<name>` slot, and
    ///    leaving `deleteAttachments` unable to reclaim the parent. A UUID has no
    ///    separator, so `dirURL(for:root:)` always resolves to exactly ONE child
    ///    of the storage root and every consumer (save, load, delete, eviction)
    ///    can treat the on-disk directory as exactly its stored name.
    ///
    /// Both `ComposeView` COW staging sites (close-Save and Send) call this.
    static func newStagingDirName() -> String {
        UUID().uuidString
    }

    /// Save attachments to disk. Throws if any write fails, throws
    /// `DraftAttachmentStorageError.escapesStorageRoot` rather than creating
    /// directories and writing attachment bytes outside the storage root, and
    /// throws `AttachmentFilenameError.unsupported` rather than storing an
    /// attachment under a name the app refuses (see
    /// `AttachmentFilename.isSafeFileComponent` for the six rules and for what a
    /// refusal costs the user).
    ///
    /// ⚠️ Every name is checked BEFORE the directory is created, so a refused set
    /// writes nothing at all and leaves no partial slot behind. Refusing per
    /// attachment inside the write loop would leave the earlier attachments on
    /// disk under a directory the caller is about to abandon.
    static func saveAttachments(_ attachments: [DraftAttachment], dirName: String, root: URL? = nil) throws {
        guard !attachments.isEmpty else { return }
        if let refused = attachments.first(where: { !AttachmentFilename.isSafeFileComponent($0.filename) }) {
            throw AttachmentFilenameError.unsupported(name: refused.filename)
        }
        guard let dir = containedDirURL(for: dirName, root: root) else {
            throw DraftAttachmentStorageError.escapesStorageRoot(dirName: dirName)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, att) in attachments.enumerated() {
            // The name is used VERBATIM, and the guard above is what makes that
            // safe: it is one path component of `dir` rather than a sub-path the
            // sender chose. See `AttachmentFilename.isSafeFileComponent`.
            let dataName = "\(index)_\(att.filename)"
            try att.data.write(to: dir.appendingPathComponent(dataName))
            // Write metadata sidecar — uses indexed name to avoid collision when
            // multiple attachments share the same filename (e.g., two "document.pdf").
            let meta = "\(att.mimeType)\n\(att.isAlternative)"
            try meta.write(to: dir.appendingPathComponent("\(dataName).meta"), atomically: true, encoding: .utf8)
        }
    }

    /// `name` with a trailing `".meta"` removed, or `nil` when it does not end in
    /// `".meta"` at all. THE one place either loader decides whether a filename
    /// names a metadata sidecar.
    ///
    /// ⚠️ SCALAR-WISE, and that is the whole reason this function exists.
    /// `hasSuffix` and `dropLast` operate on `Character`s — extended grapheme
    /// clusters — and a trailing scalar whose grapheme-break property is `Prepend`
    /// merges with the FOLLOWING `.` into ONE `Character`. For a data file
    /// `0_invoice\u{0605}` the sidecar `0_invoice\u{0605}.meta` has last five
    /// `Character`s `"\u{0605}."`, `m`, `e`, `t`, `a`, so `hasSuffix(".meta")` is
    /// FALSE and `dropLast(5)` returns `0_invoice` — the wrong base, having eaten
    /// the sender's own scalar. Measured 2026-08-12 by sweeping every scalar
    /// `U+0000...U+10FFFF`: 27 assigned scalars have that property (`U+0600` …
    /// `U+11F02`), and `AttachmentFilename.isSafeFileComponent` ACCEPTS every name
    /// carrying one — they are assigned, they carry no combining class, they are
    /// outside `refusedFilenameScalars` and they cost one unit — so a
    /// sender-authored MIME `filename` parameter reaches the loaders intact.
    ///
    /// ⚠️ **Refusing hostile names at SAVE time did not make this unnecessary, and
    /// deleting it would reopen the defect.** `"invoice\u{0605}"` is SAFE by all
    /// six rules; it is stored verbatim, and it is its SIDECAR
    /// `0_invoice\u{0605}.meta` that grapheme-merges the `.`. The name that breaks
    /// the loader is a name the predicate has no reason to refuse.
    ///
    /// Both consequences landed in the SAME function: the sidecar was classified
    /// as a DATA file, so `loadAttachments` returned two attachments for one saved
    /// file, and the `ambiguousMetaFilename` fail-closed guard — which tested the
    /// same `hasSuffix(".meta")` — never fired for it either. On the outbox side
    /// that is the SEND path, so the mail went out carrying the sidecar's bytes as
    /// an extra attachment (Outbox Reliability Rule 5). The classifier and the
    /// guard both key off THIS function now, so they cannot disagree again.
    ///
    /// Existing on-disk files parse identically: for every name whose last five
    /// scalars are not `.meta` this returns `nil`, exactly as the old suffix test
    /// answered false; for every name that does end in those scalars AND has no
    /// `Prepend` scalar in front of the `.`, the scalar-wise and `Character`-wise
    /// answers coincide. Only the 27-scalar class changes, and it changes from a
    /// wrong answer to the right one.
    static func metaBase(_ name: String) -> String? {
        let suffix = ".meta".unicodeScalars
        let scalars = name.unicodeScalars
        guard scalars.count >= suffix.count,
              scalars.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        var base = String.UnicodeScalarView()
        base.append(contentsOf: scalars.dropLast(suffix.count))
        return String(base)
    }

    /// Recovers the sender's filename from a stored `"<index>_<name>"` path
    /// component by dropping everything up to and including the FIRST `_` SCALAR.
    /// THE one place either loader undoes the `"\(index)_"` prefix
    /// `saveAttachments` adds.
    ///
    /// ⚠️ SCALAR-WISE, and both halves of the `Character`-wise version were wrong.
    /// It was
    /// `fullName.contains("_") ? String(fullName.drop(while: { $0 != "_" }).dropFirst()) : fullName`,
    /// and a filename BEGINNING with a combining mark makes the stored component
    /// `0_\u{0301}foo.pdf`, in which `_` and the mark are ONE `Character`:
    /// - `contains("_")` is FALSE, so the store's own `0_` prefix was handed back
    ///   as the user's filename — on screen, and on the wire as the MIME
    ///   `filename` parameter of a sent message.
    /// - With a LATER `_` in the sender's own name, `contains("_")` is true and
    ///   `drop(while:)` ran past the merged cluster to the SECOND `_`:
    ///   `\u{0301}foo_bar.pdf`, stored as `0_\u{0301}foo_bar.pdf`, came back as
    ///   `bar.pdf`. **`foo` was silently cut.**
    /// Measured 2026-08-12 by sweeping every scalar `U+0000...U+10FFFF`: 2,619
    /// assigned scalars trigger both shapes, and
    /// `AttachmentFilename.isSafeFileComponent` ACCEPTS every name that begins
    /// with one — they are ordinary combining marks, from every script that has
    /// them, and a run of ONE is nowhere near `combiningRunBudgetScalars`.
    ///
    /// ⚠️ **Refusing hostile names at SAVE time did not make this unnecessary, and
    /// deleting it would reopen the defect.** `"\u{0301}foo.pdf"` is SAFE by all
    /// six rules — short, assigned, unrefused, run length 1 — and it is the
    /// store's OWN `"\(index)_"` prefix that merges with the sender's leading mark
    /// into one `Character`. The name that breaks the loader is a name the
    /// predicate has no reason to refuse.
    ///
    /// Existing on-disk files parse identically. `saveAttachments` always writes
    /// `"\(index)_"`, so the first `_` scalar of a stored component is always the
    /// store's own separator; for any name where the old expression found that
    /// same `_`, the two agree exactly. Only the merged-cluster class changes, and
    /// it changes from a wrong answer to the right one. A component with no `_`
    /// scalar at all is returned unchanged, as before.
    static func afterIndexPrefix(_ name: String) -> String {
        let scalars = name.unicodeScalars
        guard let underscore = scalars.firstIndex(of: "_") else { return name }
        var recovered = String.UnicodeScalarView()
        recovered.append(contentsOf: scalars[scalars.index(after: underscore)...])
        return String(recovered)
    }

    /// PORT — `v2final`'s `DraftAttachmentStorage.loadAttachments(dirName:root:)`
    /// (commit `d2f0c96a3`), verbatim.
    ///
    /// Load attachments from disk, FAIL-CLOSED. Returns `[]` ONLY for a nil
    /// `dirName` (the sole clean attachment-less case). Otherwise it throws rather
    /// than return a partial set: a missing/unenumerable directory, an unreadable
    /// data file, or a `.meta`-ambiguous filename all THROW. A missing/unreadable
    /// metadata sidecar is NOT a data-loss case (the bytes are intact) — it keeps
    /// the existing MIME fallback.
    static func loadAttachments(dirName: String?, root: URL? = nil) throws -> [DraftAttachment] {
        // nil dirName is the ONLY clean attachment-less case.
        guard let dirName else { return [] }
        // A name that escapes the storage root is refused before any read: fail
        // closed rather than load bytes from outside the slot.
        guard let dir = containedDirURL(for: dirName, root: root) else {
            throw DraftAttachmentStorageError.escapesStorageRoot(dirName: dirName)
        }
        // A referenced-but-absent directory (or an enumeration failure) is NOT
        // "no attachments" — fail closed instead of returning [].
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            throw DraftAttachmentLoadError.directoryUnreadable(dirName: dirName, underlying: error)
        }

        // Classify. A ".meta" file is a metadata SIDECAR iff its base (name minus
        // ".meta") is a present file: `0_x.pdf.meta` is the sidecar of data
        // `0_x.pdf`, and `0_settings.meta.meta` is the sidecar of a real attachment
        // literally named `settings.meta` (stored as data `0_settings.meta`). A
        // ".meta" file whose base is ABSENT is itself a DATA file.
        let allNames = Set(files.map { $0.lastPathComponent })
        func isSidecar(_ name: String) -> Bool {
            metaBase(name).map(allNames.contains) ?? false
        }
        let dataFiles = files.filter { !isSidecar($0.lastPathComponent) }
        // Fail closed on a DATA file whose name ends in ".meta" but whose OWN
        // sidecar ("<name>.meta") is absent: it is indistinguishable from a
        // lost-data orphan (the real data file gone, only its ".meta" sidecar
        // left), so throw rather than load metadata bytes as the attachment.
        // Keyed off `metaBase` — the same decision the classifier makes — because
        // when the two disagreed BOTH failed for the same input.
        for url in dataFiles where metaBase(url.lastPathComponent) != nil {
            guard allNames.contains(url.lastPathComponent + ".meta") else {
                throw DraftAttachmentLoadError.ambiguousMetaFilename(name: url.lastPathComponent)
            }
        }

        let sorted = dataFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try sorted.map { fileURL in
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                // A present-but-unreadable data file must NEVER be dropped.
                throw DraftAttachmentLoadError.fileUnreadable(name: fileURL.lastPathComponent, underlying: error)
            }
            let fullName = fileURL.lastPathComponent
            // Strip index prefix: "0_filename.pdf" → "filename.pdf". Scalar-wise —
            // see `afterIndexPrefix` for the two ways the `Character`-wise version
            // handed back the prefix or cut the sender's name.
            let filename = afterIndexPrefix(fullName)
            // Meta sidecar uses full indexed name (matching save). A missing/
            // unreadable sidecar is not data loss (bytes are intact) — keep the
            // MIME fallback rather than throwing.
            let metaURL = dir.appendingPathComponent("\(fullName).meta")
            let meta = (try? String(contentsOf: metaURL, encoding: .utf8))?.split(separator: "\n")
            let mimeType = meta?.first.map(String.init) ?? "application/octet-stream"
            let isAlternative = meta?.dropFirst().first == "true"
            return DraftAttachment(filename: filename, mimeType: mimeType, data: data, isAlternative: isAlternative)
        }
    }

    /// Delete attachments directory for a draft. A name that escapes the storage
    /// root is a NO-OP — a recursive `removeItem` on an out-of-root path is the
    /// most damaging of the three entry points, and there is nothing to reclaim
    /// there anyway because save refuses to write there.
    static func deleteAttachments(dirName: String, root: URL? = nil) {
        guard let dir = containedDirURL(for: dirName, root: root) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
