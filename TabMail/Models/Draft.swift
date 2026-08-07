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
        // no `References`, and `AccountManagerOutbox.persistQueuedSend` skipped the
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

    /// Save attachments to disk. Throws if any write fails, and throws
    /// `DraftAttachmentStorageError.escapesStorageRoot` rather than creating
    /// directories and writing attachment bytes outside the storage root.
    static func saveAttachments(_ attachments: [DraftAttachment], dirName: String, root: URL? = nil) throws {
        guard !attachments.isEmpty else { return }
        guard let dir = containedDirURL(for: dirName, root: root) else {
            throw DraftAttachmentStorageError.escapesStorageRoot(dirName: dirName)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, att) in attachments.enumerated() {
            let dataName = "\(index)_\(att.filename)"
            try att.data.write(to: dir.appendingPathComponent(dataName))
            // Write metadata sidecar — uses indexed name to avoid collision when
            // multiple attachments share the same filename (e.g., two "document.pdf").
            let meta = "\(att.mimeType)\n\(att.isAlternative)"
            try meta.write(to: dir.appendingPathComponent("\(dataName).meta"), atomically: true, encoding: .utf8)
        }
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
            name.hasSuffix(".meta") && allNames.contains(String(name.dropLast(".meta".count)))
        }
        let dataFiles = files.filter { !isSidecar($0.lastPathComponent) }
        // Fail closed on a DATA file whose name ends in ".meta" but whose OWN
        // sidecar ("<name>.meta") is absent: it is indistinguishable from a
        // lost-data orphan (the real data file gone, only its ".meta" sidecar
        // left), so throw rather than load metadata bytes as the attachment.
        for url in dataFiles where url.lastPathComponent.hasSuffix(".meta") {
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
            // Strip index prefix: "0_filename.pdf" → "filename.pdf"
            let filename = fullName.contains("_") ? String(fullName.drop(while: { $0 != "_" }).dropFirst()) : fullName
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
