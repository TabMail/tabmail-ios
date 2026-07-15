/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Provider label identifiers are unique only within an account.
struct UserLabelIdentity: Hashable, Sendable {
    let accountId: String
    let id: String
}

// MARK: - UserLabel

/// A user-visible remote label (Gmail label or IMAP keyword).
/// TabMail's internal `tm_*` labels are NOT stored here — those are handled by ActionTag.
struct UserLabel: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "userLabel"

    var id: String            // Account-local Gmail label ID or IMAP keyword
    var accountId: String     // FK → account.id; forms the durable identity with id
    var name: String          // Display name
    var isSystem: Bool        // Gmail system labels (STARRED, IMPORTANT, etc.) — stored but filtered from display

    var scopedIdentity: UserLabelIdentity {
        UserLabelIdentity(accountId: accountId, id: id)
    }
}

// MARK: - MessageUserLabel

/// Join table associating a message with a user label.
struct MessageUserLabel: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "messageUserLabel"

    var messageId: String     // FK → messageHeader.id
    var accountId: String     // FK component → userLabel.accountId
    var userLabelId: String   // FK component → userLabel.id

    // MARK: - Associations

    static let userLabel = belongsTo(
        UserLabel.self,
        using: ForeignKey(["accountId", "userLabelId"], to: ["accountId", "id"])
    )
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
