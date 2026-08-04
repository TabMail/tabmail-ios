/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - UserLabel

/// A user-visible label (Gmail label, IMAP keyword, or Exchange category).
/// TabMail's internal `tm_*` labels are NOT stored here — those are handled by ActionTag.
///
/// 🚨 **IDENTITY AND WIRE VALUE ARE TWO DIFFERENT COLUMNS (D10 / `IOS-LABEL-001`).**
/// `id` is a deterministic account-prefixed SURROGATE; `providerLabelId` is the BARE
/// value the provider knows. This is the same split `Folder` already has — `Folder.id`
/// is `"\(accountId):\(path)"` while `Folder.path` holds the server-side identifier —
/// and `messageHeader` (`id` = `"<accountId>:<folderPath>:<messageId>"` beside the bare
/// `messageId`). `userLabel` was the one table that tried to make a single column serve
/// as both, and a provider label id is unique only WITHIN an account: two accounts with
/// a `Receipts` Gmail label, or two IMAP accounts using a `work` keyword, collided on
/// the primary key. That single shared row made the owning `accountId`/`name` flap with
/// whichever account synced last, and — because `messageUserLabel.userLabelId`
/// references this table `onDelete: .cascade` while the Gmail stale sweep's FILTER is
/// account-scoped but the ROW it deletes was global — let account A's server-side label
/// removal destroy every association row belonging to account B's messages.
///
/// ⚠️ **NEVER split `id` back apart on `:` to recover either half.** A provider label id
/// may itself contain a colon; the prefix exists to make the value unique, not to be
/// re-parsed. Read the account from `accountId` and the wire value from
/// `providerLabelId`. (This repo has a live defect from exactly that assumption — a
/// reply-draft `headerId` carrying four colons.)
struct UserLabel: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "userLabel"

    /// Deterministic surrogate primary key: `"\(accountId):\(providerLabelId)"`.
    /// Account-unique by construction — `accountId` is a colon-free UUID string
    /// (`Account.init` / `DemoSeed.demoAccountId`), so the concatenation is injective and
    /// `(accountId, providerLabelId)` is unique without a second index.
    /// **Never goes on the wire.** See `providerLabelId`.
    var id: String
    var accountId: String     // FK → account.id
    /// The BARE provider value — Gmail: label ID (e.g. `"Label_123"`), IMAP: keyword
    /// string (lowercased). **This is the only member any wire path may read.** It is
    /// what `PendingOperation.userLabelId` carries and what reaches Gmail's
    /// `addLabelIds`/`removeLabelIds` and IMAP's `STORE ±FLAGS (<keyword>)`.
    var providerLabelId: String
    var name: String          // Display name
    var isSystem: Bool        // Gmail system labels (STARRED, IMPORTANT, etc.) — stored but filtered from display

    /// The ONLY constructor, mirroring `Folder.init(name:path:role:accountId:)`. It takes
    /// the bare provider value and mints `id` itself, so no caller can write a bare id
    /// into the primary key and silently re-create `IOS-LABEL-001`. Declaring it
    /// suppresses the memberwise `init(id:accountId:…)` on purpose — a construction site
    /// that has not been routed through here is a compile error, not a latent collision.
    init(accountId: String, providerLabelId: String, name: String, isSystem: Bool) {
        self.id = "\(accountId):\(providerLabelId)"
        self.accountId = accountId
        self.providerLabelId = providerLabelId
        self.name = name
        self.isSystem = isSystem
    }
}

// MARK: - MessageUserLabel

/// Join table associating a message with a user label.
struct MessageUserLabel: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "messageUserLabel"

    var messageId: String     // FK → messageHeader.id
    /// FK → `userLabel.id` — the account-prefixed SURROGATE, never the bare provider
    /// value. Because the id carries the owning account, a join through this column
    /// can only ever reach that account's row (D10 / `IOS-LABEL-001`).
    var userLabelId: String

    // MARK: - Associations

    static let userLabel = belongsTo(UserLabel.self, using: ForeignKey(["userLabelId"]))
}

// MARK: - MessageUserLabelWithUserLabel

/// JOIN result struct for eager-loading labels with messages.
struct MessageUserLabelWithUserLabel: FetchableRecord, Decodable, Sendable {
    var messageUserLabel: MessageUserLabel
    var userLabel: UserLabel

    var messageId: String { messageUserLabel.messageId }
}

// MARK: - Helper Types

/// Thrown when Gmail API createLabel takes too long (10s timeout).
struct UserLabelCreationTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Label creation timed out. Please try again." }
}
