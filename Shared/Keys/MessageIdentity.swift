/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Which identity space a **content** row draws its key TAIL from.
///
/// Durable rows are keyed `"<accountId>:<folderPath>:<tail>"`. For the ACTION
/// queue the tail is always the provider message id, because two copies of the
/// same content are different targets and archiving *this* one must not archive
/// *that* one. For the CONTENT stores (the FTS `message_ids` / `message_meta`
/// rows, `messageBody`, `bodyAsset.headerId`) there is nothing to distinguish —
/// same content IS same content — so the tail may instead be the RFC 822
/// Message-ID, which survives the `UIDVALIDITY` renumber that would otherwise
/// invalidate every body and search row in the folder and force a full
/// re-download. This is Thunderbird parity: `fts/incrementalIndexer.js` queues by
/// `headerMessageId`, "stable, NOT weId (unstable)".
///
/// ⚑ This is a standalone enum rather than `AccountProvider` ON PURPOSE.
/// `AccountProvider` is declared in `TabMail/Models/Account.swift`, which is NOT
/// a member of the notification-service target, while this file is compiled into
/// BOTH targets (`project.yml` lists `Shared` under `TabMail` and under
/// `TabMailNotificationService`). Keying the helper on the provider enum would
/// break the NSE build. Main-app callers bridge through
/// `AccountProvider.contentKeySpace`.
public enum ContentKeySpace: Sendable {
    /// The provider assigns message ids it never reassigns (Gmail, Microsoft
    /// Graph). The provider id is itself durable identity, so the tail stays the
    /// provider id and content keys are byte-identical to `MessageIdentity.headerId`.
    case stableProviderId
    /// The provider addresses messages by a mutable, reusable number (IMAP and
    /// iCloud UIDs, which a `UIDVALIDITY` change reassigns to different messages).
    /// Prefer a usable RFC 822 Message-ID for the tail; fall back to the provider
    /// id when the message has none.
    case uidAddressed
}

/// Deterministic identity helpers shared between the main app and the NSE so
/// both sides emit identical GRDB row IDs and AI-cache keys for the same
/// message. A drift here breaks `MessageHeader.fetchOne(db, key:)` lookups
/// and silently duplicates rows (see Outlook NSE C-3a bug: NSE hardcoded
/// `folderPath = "INBOX"` while main-app sync used the Graph folder ID,
/// producing two headers + a missed AI-cache hit that triggered a full LLM
/// re-run on every arrival).
///
/// Any change to these formats MUST land in one commit across both targets.
/// Ad-hoc `"\(accountId):\(folderPath):\(messageId)"` interpolations elsewhere
/// are a code-smell — route through here so a single place owns the contract.
public enum MessageIdentity {

    /// GRDB `MessageHeader.id` primary key.
    ///
    /// Format: `<accountId>:<folderPath>:<messageId>`. `folderPath` is the
    /// provider-canonical folder path (Gmail label name, Graph folder ID,
    /// IMAP mailbox path — whatever that provider's sync layer stores in
    /// `MessageHeader.folderPath`).
    public static func headerId(accountId: String, folderPath: String, messageId: String) -> String {
        "\(accountId):\(folderPath):\(messageId)"
    }

    /// GRDB `MessageHeader.folderId` secondary key (also used as the
    /// composite key for per-folder queries).
    ///
    /// Format: `<accountId>:<folderPath>`.
    public static func folderId(accountId: String, folderPath: String) -> String {
        "\(accountId):\(folderPath)"
    }

    /// `MessageAICache` row key. Returns `nil` when `rfc822MessageId` is
    /// missing — those messages intentionally don't cache (no cross-device
    /// identity → no peer dedup).
    ///
    /// Format: `<accountId>:<folderPath>:<rfc822MessageId>`. Note it does
    /// NOT wrap `folderPath` inside another `accountId:` prefix — a prior
    /// bug in `NSEDataBridge` did exactly that, producing
    /// `accountId:accountId:INBOX:rfc` and missing every cross-device probe.
    public static func aiCacheKey(accountId: String, folderPath: String, rfc822MessageId: String?) -> String? {
        guard let rfc = rfc822MessageId, !rfc.isEmpty else { return nil }
        return "\(accountId):\(folderPath):\(rfc)"
    }

    // MARK: - Prefix matching over `headerId`-keyed sidecar tables (T4.S6)
    //
    // Several sidecars are keyed by the FULL `headerId` string but hold no
    // `folderId`/`folderPath` column of their own (`chatIdMapping.realId`, the FTS
    // `message_ids.headerId`, `BodyAssetStore`'s manifest). Purging one folder from
    // them is therefore a PREFIX match — and a bare prefix match is wrong on IMAP
    // servers whose hierarchy delimiter is ':' (RFC 3501 allows any character).
    // There, `acct:INBOX:` is a prefix of `acct:INBOX:Sub:42` — a DIFFERENT folder's
    // header — so the prefix must be paired with the no-deeper-colon guard below.

    /// Escape a value destined for the **`messageId` slot** of a `headerId` so the
    /// tail after `headerIdPrefix` stays colon-free.
    ///
    /// ⚑ WHY THIS EXISTS — the invariant, not an instance. `headerId` is a
    /// three-field concatenation with `:` as the separator, and the ONLY field that
    /// may contain a `:` is `folderPath` (the prefix match consumes it verbatim, so
    /// it is harmless there). A `:` in the `messageId` tail makes the row fail BOTH
    /// folder-scoping guards below — `headerIdBelongsToFolder` and
    /// `headerIdLikeNoDeeperColonSQLFragment` — which EXCLUDE rather than error, so
    /// the row is SILENTLY skipped by every headerId-prefix purge (the FTS
    /// `message_ids` sweep, the `chatIdMapping` sweep, the `BodyAssetStore` manifest
    /// sweep) and its sidecar state orphans on a folder purge or a UIDVALIDITY reset.
    ///
    /// ⚠ THE FIX FOR THAT IS ALWAYS HERE, AT THE MINT — never a relaxation of the
    /// guards. The guards are what makes folder scoping correct under a ':'-delimiter
    /// IMAP server; widening them lets a nested sibling folder's rows into another
    /// folder's purge, which is strictly worse than an orphan. Server-assigned message
    /// ids (IMAP UIDs, Gmail/Graph ids) are colon-free by construction and need no
    /// escaping; TabMail-MINTED synthetic ids built from an internal key that may
    /// itself be a colon-joined composite (`AccountManager.queueDraftSave`'s
    /// `draft-<Draft.id>`, where `Draft.id` is `reply:<accountId>:<stableId>`) MUST
    /// pass the composite part through here first.
    ///
    /// Injective, and therefore collision-free: `%` is escaped before `:`, so the
    /// escape alphabet is prefix-free and distinct inputs always yield distinct
    /// outputs (a manufactured collision between two drafts would be a wrong-row
    /// update/delete). Reversible in principle (`%3A` → `:`, `%25` → `%`), though
    /// nothing in the codebase reverse-parses a synthetic placeholder id today —
    /// consumers only test its `draft-`/`sent-` PREFIX (`isSyntheticPlaceholderId`).
    /// Identity for any colon-free, percent-free input, so existing colon-free
    /// callers are byte-for-byte unchanged and no stored id is re-keyed.
    public static func colonSafeMessageIdComponent(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "%": out += "%25"
            case ":": out += "%3A"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The `headerId` prefix every message in `(accountId, folderPath)` starts with,
    /// RAW (no LIKE escaping). Use as the argument to
    /// `headerIdLikeNoDeeperColonSQLFragment` and for Swift-side `hasPrefix` scans.
    public static func headerIdPrefix(accountId: String, folderPath: String) -> String {
        "\(accountId):\(folderPath):"
    }

    /// `headerIdPrefix` with SQL-LIKE wildcards escaped for `ESCAPE '\'`. A folder
    /// path legitimately containing `%` or `_` would otherwise widen the match to
    /// other folders.
    public static func escapedHeaderIdLikePrefix(accountId: String, folderPath: String) -> String {
        escapeForLike(headerIdPrefix(accountId: accountId, folderPath: folderPath))
    }

    /// Escape `\`, `%` and `_` for use in a SQL `LIKE ... ESCAPE '\'` pattern.
    public static func escapeForLike(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// SQL fragment asserting that `column`'s tail AFTER the folder prefix contains
    /// no further `:` — i.e. the row belongs to THIS folder and not to a nested
    /// sibling under a ':'-delimiter server. Bind the RAW (unescaped)
    /// `headerIdPrefix` as the single argument; `INSTR(..., ':') = 0` is true for an
    /// empty tail too, so a hypothetical empty `messageId` is not excluded.
    public static func headerIdLikeNoDeeperColonSQLFragment(column: String) -> String {
        "INSTR(SUBSTR(\(column), LENGTH(?) + 1), ':') = 0"
    }

    /// Swift-side twin of the two SQL helpers, for manifests that are not queryable
    /// (`BodyAssetStore.allManifestHeaderIds()`).
    public static func headerIdBelongsToFolder(_ headerId: String, accountId: String, folderPath: String) -> Bool {
        let prefix = headerIdPrefix(accountId: accountId, folderPath: folderPath)
        guard headerId.hasPrefix(prefix) else { return false }
        return !headerId.dropFirst(prefix.count).contains(":")
    }

    // MARK: - Content-store keys (RFC-first tail)

    /// The RFC 822 Message-ID of a message, normalized into a form that is safe to
    /// use as the TAIL of a `headerId` — or `nil` when the raw value cannot serve
    /// as one and the caller must fall back.
    ///
    /// The validation semantics are ported from branch `v2final`'s
    /// `MessageIdentity.durableActionRFC822MessageId` (same file path there).
    /// Deliberately RENAMED: `v3` reversed that branch's decision to key the ACTION
    /// queue by RFC id, so reintroducing the old name would read to a future
    /// reader as reinstating a rejected design. Rejected, in order: `nil`; any
    /// `CR` or `LF`; empty after trimming; UNBALANCED angle brackets
    /// (`hasPrefix("<") != hasSuffix(">")`). Then normalized via
    /// `EmailFilter.normalizeMessageId`, after which a residual `<`/`>`, any
    /// whitespace or control character, and anything other than exactly one `@`
    /// with a non-empty local part and a non-empty domain are also rejected.
    ///
    /// ⚑ ONE TERM IS NEW ON THIS BRANCH: A `':'` IS REJECTED. The reference permits
    /// it, and RFC 5322 genuinely allows one inside a no-fold-literal domain
    /// (`<a@[IPv6:2001:db8::1]>`); `EmailFilter.normalizeMessageId` performs no
    /// validation at all (it trims and strips one leading `<` / trailing `>`), so
    /// such a value survives intact. On `v3` that is fatal to folder scoping, which
    /// is "shares the prefix AND has no deeper colon" — `headerIdBelongsToFolder`
    /// and its SQL twin `headerIdLikeNoDeeperColonSQLFragment`, both just above.
    /// Both EXCLUDE a colon-bearing tail rather than erroring, so such a key would
    /// stop belonging to its own folder in every folder-scoped query and every SQL
    /// sweep — silent invisibility, not a loud failure — and its FTS row, chat-id
    /// mapping and body assets would orphan on the next folder purge or UIDVALIDITY
    /// reset.
    ///
    /// ⚠ THE FIX FOR THAT IS ALWAYS HERE, AT THE MINT — never a relaxation of those
    /// guards. A `folderPath` may legitimately contain `':'` (RFC 3501 allows any
    /// hierarchy delimiter), so a message in `Drafts/Sub` has the id
    /// `acct:Drafts:Sub:77`, which MATCHES the `acct:Drafts:` prefix and is saved
    /// from the parent folder's purge ONLY by the no-deeper-colon term. Widening
    /// the guards admits a genuinely foreign folder's rows into another folder's
    /// purge, which is strictly worse than an orphan. Same rule, same reason as
    /// `colonSafeMessageIdComponent` above; the tripwire is
    /// `DraftPlaceholderFolderPurgeTests.nestedSiblingFolderSurvivesTheParentPurge`.
    public static func usableRfc822Tail(_ rawValue: String?) -> String? {
        // ⚑ The v3-only term, and the ONLY thing this adds to
        // `comparableRfc822Identity`. See the doc comment: a colon here makes the
        // row stop belonging to its own folder in both scoping guards.
        guard let normalized = comparableRfc822Identity(rawValue),
              !normalized.contains(":")
        else { return nil }
        return normalized
    }

    /// The same RFC 822 Message-ID normalization as `usableRfc822Tail`, MINUS its
    /// `':'` rejection — for the only other question this value is ever asked:
    /// **are these two Message-IDs the SAME identity?**
    ///
    /// This is `v2final`'s `MessageIdentity.durableActionRFC822MessageId`, ported
    /// verbatim in semantics (same file there; the two bodies differ by exactly the
    /// one `!normalized.contains(":")` guard above, which is why the shared work
    /// lives here and `usableRfc822Tail` is expressed as this plus that guard —
    /// there is no second validator to drift).
    ///
    /// ⚑ WHY THE TWO QUESTIONS NEED DIFFERENT ANSWERS. The `':'` rejection exists
    /// for CONTENT-KEY FOLDER SCOPING — a colon in a key's tail escapes the
    /// `no-deeper-colon` prefix match, so such a row stops belonging to its own
    /// folder (see `usableRfc822Tail`'s doc comment in full). Identity COMPARISON
    /// builds no key and scopes nothing: it normalizes two values and asks whether
    /// they are equal. Carrying the scoping term into it is not merely redundant,
    /// it is HARMFUL — RFC 5322 permits a colon inside a `no-fold-literal` domain
    /// (`<x@[IPv6:2001:db8::1]>`) and `EmailFilter.normalizeMessageId` passes it
    /// through intact, so a caller comparing SERVER-ORIGINATED ids through the
    /// strict form gets `nil` for every such id, i.e. "never the same message" for a
    /// message that plainly IS the same one. Where the caller fails CLOSED on a
    /// failed verdict — `IMAPProvider.deleteDraft` — that is a delete that can never
    /// converge for the affected drafts.
    ///
    /// Use this ONLY to compare identities. Anything that MINTS a stored key must
    /// keep using `usableRfc822Tail`.
    public static func comparableRfc822Identity(_ rawValue: String?) -> String? {
        guard let rawValue,
              !rawValue.utf8.contains(0x0D),
              !rawValue.utf8.contains(0x0A)
        else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("<") == trimmed.hasSuffix(">") else { return nil }

        let normalized = EmailFilter.normalizeMessageId(trimmed)
        guard !normalized.isEmpty,
              !normalized.contains("<"),
              !normalized.contains(">"),
              normalized.rangeOfCharacter(
                  from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
              ) == nil
        else { return nil }

        let addressParts = normalized.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard addressParts.count == 2,
              !addressParts[0].isEmpty,
              !addressParts[1].isEmpty
        else { return nil }

        return normalized
    }

    /// The key a CONTENT row is stored under — the FTS `message_ids` /
    /// `message_meta` rows, `messageBody`, and `bodyAsset.headerId`.
    ///
    /// The SHAPE is UNCHANGED: `"<accountId>:<folderPath>:<tail>"`, built through
    /// `headerId` rather than re-interpolated (this file's own header comment calls
    /// ad-hoc interpolation of that format a code smell). Only the tail can differ,
    /// and only under `.uidAddressed`. `messageHeader.id` and the durable action
    /// queue are NOT affected — see `ContentKeySpace` for why the two key spaces
    /// differ on purpose.
    ///
    /// ⚑ THE rfc-LESS RUNG DEVIATES FROM `v2final`, ON OWNER INSTRUCTION
    /// (2026-07-31). The reference ladder — `DisplayedAttachmentIdentity.resolve(for:)`
    /// in `v2final`'s `TabMail/Services/BodyAssetMaintenance.swift` — REFUSES when an
    /// IMAP/iCloud message has neither a usable RFC id nor a settled mailbox epoch.
    /// Refusal is available to it because it gates *attachment access*, where
    /// refusing is a degraded but safe UX. It is not available here: a content key
    /// that cannot be produced means the body cannot be STORED at all. Falling back
    /// to the provider id leaves rfc-less rows keyed exactly as they are today,
    /// still covered by the existing ADR-IOS-061 epoch guards.
    ///
    /// It also does NOT synthesize a `synth:<hash>` tail. That supersedes the
    /// 2026-07-18 draft decision in `PLAN_RFC_KEY_MIGRATION_ADR062.md` §3 (which now
    /// carries a supersession banner), for three reasons: (1) SYNTHESIZE existed so
    /// the epoch guards could be DELETED, and this branch has spent ~15 audit rounds
    /// BUILDING them out (ADR-IOS-061 plus the T4.S6 purge-and-resync reaction), so
    /// the premise does not hold here; (2) `synth:<hash>` contains a `':'` — see
    /// `usableRfc822Tail`; (3) a hash over envelope fields creates a NEW collapse
    /// surface between genuinely DIFFERENT messages, strictly worse than the
    /// accepted duplicate-RFC collapse.
    ///
    /// ACCEPTED LIMITATION (owner-decided, `PLAN_RFC_KEY_MIGRATION_ADR062.md` §1):
    /// two messages in ONE folder carrying the same normalized Message-ID collapse
    /// onto a single content key. That matches Thunderbird/Gloda and Gmail, both of
    /// which dedup by Message-ID, and the derived stores already assume it
    /// (`messageAICache`'s key, `nse_badge_counted`, `pendingAIRefinement`). It is
    /// the only collapse channel — distinct messages otherwise mint distinct tails.
    public static func contentKey(
        accountId: String,
        folderPath: String,
        providerMessageId: String,
        rfc822MessageId: String?,
        space: ContentKeySpace
    ) -> String {
        let tail: String
        switch space {
        case .stableProviderId:
            tail = providerMessageId
        case .uidAddressed:
            tail = usableRfc822Tail(rfc822MessageId) ?? providerMessageId
        }
        return headerId(accountId: accountId, folderPath: folderPath, messageId: tail)
    }
}
