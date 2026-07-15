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

    /// Complete provider-neutral address required before a message action may
    /// mutate local state or enter the durable queue. Scope is validated here
    /// with the RFC identity so producers cannot independently forget one of
    /// the three admission fields.
    public struct DurableActionAddress: Sendable, Equatable {
        public let accountId: String
        public let folderPath: String
        public let rfc822MessageId: String
    }

    /// Canonical durable identity for provider-agnostic message actions.
    ///
    /// Every provider ultimately exposes RFC `Message-ID`, while its transport
    /// identifier may change after a move (Graph), be folder-local (IMAP), or
    /// be provider-specific (Gmail). Durable queue rows therefore carry this
    /// normalized RFC value and providers resolve it to their current transport
    /// identifier only when the row drains.
    public static func durableActionRFC822MessageId(_ rawValue: String?) -> String? {
        guard let rawValue,
              !rawValue.utf8.contains(0x0D),
              !rawValue.utf8.contains(0x0A) else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasOpeningBracket = trimmed.hasPrefix("<")
        let hasClosingBracket = trimmed.hasSuffix(">")
        guard hasOpeningBracket == hasClosingBracket else { return nil }

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

    public static func durableActionAddress(
        accountId: String,
        folderPath: String,
        rfc822MessageId: String?
    ) -> DurableActionAddress? {
        guard !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rfc822MessageId = durableActionRFC822MessageId(rfc822MessageId)
        else { return nil }
        return DurableActionAddress(
            accountId: accountId,
            folderPath: folderPath,
            rfc822MessageId: rfc822MessageId
        )
    }

    /// Unambiguous opaque-key encoding for recently-completed provenance.
    /// Components are UTF-8 byte-length-prefixed, so colons (and even the
    /// delimiter itself) inside IMAP folder paths or RFC Message-IDs cannot
    /// shift a boundary and collide with a different tuple.
    private static func recentlyCompletedKey(
        kind: String,
        components: [String]
    ) -> String {
        let encoded = ([kind] + components).map { component in
            "\(component.utf8.count)#\(component)"
        }.joined()
        return "recent-v1:\(encoded)"
    }

    /// Independently mutable server fields protected by a recently completed
    /// local operation. These keys are purpose-scoped so, for example, a
    /// completed read toggle cannot hide a concurrent remote flag change.
    public enum RecentlyCompletedField: String, CaseIterable, Sendable {
        case read
        case flagged
        case actionTag
    }

    /// Exact value written by a completed local field operation. Both positive
    /// and negative variants remain in the expiry map so consumers can choose the
    /// latest evidence without destroying a snapshot another observer already read.
    public enum RecentlyCompletedFieldValue: Sendable, Equatable, Hashable {
        case read(Bool)
        case flagged(Bool)
        case actionTag(String?)

        public var field: RecentlyCompletedField {
            switch self {
            case .read: .read
            case .flagged: .flagged
            case .actionTag: .actionTag
            }
        }

        fileprivate var keyComponents: [String] {
            switch self {
            case .read(let value):
                [field.rawValue, "bool", value ? "true" : "false"]
            case .flagged(let value):
                [field.rawValue, "bool", value ? "true" : "false"]
            case .actionTag(.none):
                [field.rawValue, "nil"]
            case .actionTag(.some(let value)):
                [field.rawValue, "value", value]
            }
        }
    }

    /// Directional membership intention carried through pending and completed states.
    /// A removed source blocks stale re-insertion; an added destination blocks
    /// stale deletion. Keeping the directions distinct prevents one move from
    /// freezing unrelated label/folder membership on the same message.
    public enum RecentlyCompletedMembership: String, Sendable {
        case removedSource = "removed-source"
        case addedDestination = "added-destination"
    }

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

    /// Opaque key for field-specific recently-completed protection.
    /// Account scope is part of the key because provider message ids are only
    /// authoritative within one account.
    public static func recentlyCompletedFieldKey(
        accountId: String,
        messageId: String,
        field: RecentlyCompletedField
    ) -> String {
        recentlyCompletedKey(
            kind: "field-account",
            components: [field.rawValue, accountId, messageId]
        )
    }

    /// Account-scoped exact value receipt for a completed field operation.
    public static func recentlyCompletedFieldValueKey(
        accountId: String,
        messageId: String,
        value: RecentlyCompletedFieldValue
    ) -> String {
        recentlyCompletedKey(
            kind: "field-value-account",
            components: value.keyComponents + [accountId, messageId]
        )
    }

    /// Account-qualified generic identity used by providers whose message ids
    /// are stable across folders. Sync must never consume the legacy bare id:
    /// the recently-completed actor map is shared by every account.
    public static func recentlyCompletedAccountKey(
        accountId: String,
        messageId: String
    ) -> String {
        recentlyCompletedKey(
            kind: "identity-account",
            components: [accountId, messageId]
        )
    }

    /// Folder-qualified generic completion identity for providers whose ids are
    /// mailbox-local. Unlike `headerId`, this key carries explicit completion
    /// provenance and cannot be mistaken for a legacy move-membership marker.
    public static func recentlyCompletedFolderKey(
        accountId: String,
        folderPath: String,
        messageId: String
    ) -> String {
        recentlyCompletedKey(
            kind: "identity-folder",
            components: [accountId, folderPath, messageId]
        )
    }

    /// Folder-qualified field-completion key for providers whose message ids are
    /// only unique within one mailbox (IMAP UIDs). Gmail and Graph use the
    /// account-scoped overload above because their read/star state is message-wide.
    public static func recentlyCompletedFieldKey(
        accountId: String,
        folderPath: String,
        messageId: String,
        field: RecentlyCompletedField
    ) -> String {
        recentlyCompletedKey(
            kind: "field-folder",
            components: [field.rawValue, accountId, folderPath, messageId]
        )
    }

    /// Folder-scoped exact value receipt for a completed field operation.
    public static func recentlyCompletedFieldValueKey(
        accountId: String,
        folderPath: String,
        messageId: String,
        value: RecentlyCompletedFieldValue
    ) -> String {
        recentlyCompletedKey(
            kind: "field-value-folder",
            components: value.keyComponents + [accountId, folderPath, messageId]
        )
    }

    /// Explicit provenance for a row made durable by an NSE push merge. A generic
    /// provider id is also published for legacy stale-row checks, but cannot encode
    /// why it is recent and becomes ambiguous when an action completion adds a
    /// field-purpose key for the same message.
    public static func recentlyCompletedPushKey(
        accountId: String,
        folderPath: String,
        messageId: String
    ) -> String {
        recentlyCompletedKey(
            kind: "push",
            components: [accountId, folderPath, messageId]
        )
    }

    /// Exact, directional membership tuple shared by the pending-operation and
    /// recently-completed lifecycle containers. The source form is consumed only
    /// when sync is about to re-insert a locally removed row; the destination form
    /// is consumed only when sync is about to delete a locally added row.
    public static func membershipKey(
        accountId: String,
        folderPath: String,
        messageId: String,
        membership: RecentlyCompletedMembership
    ) -> String {
        recentlyCompletedKey(
            kind: "membership",
            components: [membership.rawValue, accountId, folderPath, messageId]
        )
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
