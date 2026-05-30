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
}
