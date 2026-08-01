/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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
}
