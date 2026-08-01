/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The key a CONTENT row is stored under — the FTS `message_ids` /
/// `message_meta` rows, `messageBody.id`, and `bodyAsset.headerId`.
///
/// ⚑ THIS TYPE EXISTS BECAUSE A CONTENT KEY AND A `messageHeader.id` ARE ABOUT
/// TO STOP BEING THE SAME STRING, AND TODAY NOTHING TELLS THEM APART.
///
/// `messageHeader.id` addresses a *provider copy* of a message: the durable
/// action queue must be able to archive **this** copy without archiving **that**
/// one, so its tail stays the provider message id. A content key addresses the
/// *content*: same content IS same content, so under `.uidAddressed` providers
/// its tail may instead be the RFC 822 Message-ID, which survives the
/// `UIDVALIDITY` renumber that would otherwise invalidate every body and search
/// row in the folder. See `ContentKeySpace` and `MessageIdentity.contentKey`.
///
/// While the two are the same string, every conflation is invisible. The moment
/// they diverge, each one becomes a silent, un-loud failure:
///
/// - a content key fed to `UPDATE messageHeader … WHERE id IN (…)` matches
///   **nothing**, so `headerComplete` never flips and the user's mail never
///   becomes visible in the inbox (`NSEDataBridge`);
/// - a content key fed to `UPDATE messageHeader … SET bodyComplete = 1 WHERE
///   id = ?` matches nothing, so the body is re-fetched forever
///   (`BodyFetchProcessor.flushBatch`);
/// - a `messageHeader.id` fed to an FTS lookup misses its own row, so the
///   message is searchable-but-unopenable.
///
/// The whole value of this type is that **the compiler refuses to mix the two**.
/// That is why it is deliberately NOT `ExpressibleByStringLiteral` and NOT
/// implicitly convertible to `String`: an implicit conversion silently restores
/// exactly the bug the type exists to prevent.
public struct ContentKey: Hashable, Sendable {

    /// The stored key string. Shape is `"<accountId>:<folderPath>:<tail>"`, the
    /// same three-field composite `MessageIdentity.headerId` builds — only the
    /// tail can ever differ, and only under `.uidAddressed`.
    public let rawValue: String

    /// ⚠ UNCHECKED — asserts "this string already IS a content key" without
    /// proving it.
    ///
    /// Two legitimate uses:
    ///   1. **Re-hydration.** A value read back out of a content store (the FTS
    ///      `message_meta.headerId` column, the `bodyAsset` manifest,
    ///      `messageBody.id`) is a content key by construction — it is the value
    ///      a previous mint wrote there.
    ///   2. **The Stage E1 worklist.** Everywhere else, this initializer marks a
    ///      site that is passing a `messageHeader.id` into a content subsystem
    ///      and getting away with it *only* because the two are still the same
    ///      string. Those sites must switch to `forHeader(…)` when the mint
    ///      moves.
    ///
    /// Both uses are deliberately spelled the same way so the audit is ONE grep
    /// (`ContentKey(rawValue:`) with no second spelling to forget.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The sanctioned mint for a message's content key.
    ///
    /// ⚑ **INERT AS OF STAGE B — this returns `messageHeader.id` verbatim.** The
    /// parameters it does not yet read (`rfc822MessageId`, `space`) are present
    /// so that Stage E1 changes **exactly this one function body** and no call
    /// site: the swap is `MessageIdentity.headerId(…)` →
    /// `MessageIdentity.contentKey(accountId:folderPath:providerMessageId:rfc822MessageId:space:)`,
    /// which takes precisely these five arguments.
    ///
    /// - Parameters:
    ///   - accountId: `MessageHeader.accountId`.
    ///   - folderPath: `MessageHeader.folderPath` — the provider-canonical path
    ///     (Gmail label name, Graph folder id, IMAP mailbox path).
    ///   - providerMessageId: `MessageHeader.messageId` — the provider's own id
    ///     for this copy (IMAP UID, Gmail/Graph message id).
    ///   - rfc822MessageId: `MessageHeader.rfc822MessageId`, unvalidated;
    ///     `MessageIdentity.usableRfc822Tail` does the validating at E1.
    ///   - space: which identity space this provider's content rows draw their
    ///     tail from — bridge in through `AccountProvider.contentKeySpace`.
    public static func forHeader(
        accountId: String,
        folderPath: String,
        providerMessageId: String,
        rfc822MessageId: String?,
        space: ContentKeySpace
    ) -> ContentKey {
        // ⚠ STAGE B: byte-identical to `MessageHeader.id`, which is built by this
        // same helper (`MessageHeader.init` → `MessageIdentity.headerId`).
        // `rfc822MessageId` and `space` are intentionally UNREAD until Stage E1 —
        // do not "clean up" the unused parameters, carrying them now is precisely
        // what keeps E1 a one-body change with no call-site churn.
        ContentKey(
            rawValue: MessageIdentity.headerId(
                accountId: accountId,
                folderPath: folderPath,
                messageId: providerMessageId
            )
        )
    }
}

// MARK: - Conformances
//
// Each one is here because a call site needs it, not preemptively (a newtype
// that conforms to everything is a `String` with extra steps).

extension ContentKey: CustomStringConvertible {
    /// The BARE key, so `"\(contentKey)"` interpolates byte-identically to the
    /// `String` it replaced at every existing log site. This is a *rendering*,
    /// not a conversion — it does not let a `ContentKey` be passed where a
    /// `String` is expected, which is the property that matters.
    public var description: String { rawValue }
}

extension ContentKey: Codable {
    /// Single-value coding, so `MessageBody` (a `Codable` GRDB record whose
    /// primary key is a content key) round-trips through a plain TEXT column
    /// rather than a JSON object. GRDB's record encoder prefers
    /// `DatabaseValueConvertible` over `Encodable` for values that are both, so
    /// the persisted representation is the bare string either way — this
    /// conformance covers the non-GRDB encoders (`JSONEncoder` in payloads).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ContentKey: DatabaseValueConvertible {
    /// Binds as the bare TEXT the column already holds — required by
    /// `MessageBody.fetchOne(db, key:)`, by every `WHERE headerId = ?` bind in
    /// `SearchIndex` / `BodyAssetStore`, and by `Row` decoding of those columns.
    public var databaseValue: DatabaseValue { rawValue.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ContentKey? {
        String.fromDatabaseValue(dbValue).map(ContentKey.init(rawValue:))
    }
}
