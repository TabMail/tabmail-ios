/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum AccountProvider: String, Codable, Sendable {
    case gmail
    case outlook
    case imap
    case icloud
    case caldav

    /// Brand-correct name for display in UI. `rawValue.capitalized` mangles
    /// these ("Icloud", "Imap", "Caldav") — always use this instead.
    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .imap: return "IMAP"
        case .icloud: return "iCloud"
        case .caldav: return "CalDAV"
        }
    }
}

struct Account: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "account"

    var id: String
    var emailAddress: String
    var displayName: String
    var provider: AccountProvider
    var isActive: Bool
    var isPrimary: Bool = false

    var signature: String?
    var signatureBelowQuote: Bool = false

    // IMAP-only fields
    var imapUsername: String?
    var imapHost: String?
    var imapPort: Int?
    var smtpHost: String?
    var smtpPort: Int?

    var createdAt: Date
    var lastSyncedAt: Date?
    var lastFullSyncAt: Date? // Tracks when the last full sync completed (delta syncs don't update this)

    /// Calendar-only accounts have no email provider. Hidden from email sidebar.
    var calendarOnly: Bool = false

    // Incremental sync cursors
    var lastHistoryId: String? // Gmail only — tracks history.list cursor

    /// Whether this account type supports server-side push notifications.
    /// Gmail (Pub/Sub) and Outlook (Graph subscriptions) have push; IMAP/iCloud do not.
    var hasPushSupport: Bool {
        provider == .gmail || provider == .outlook
    }

    init(
        emailAddress: String,
        displayName: String,
        provider: AccountProvider
    ) {
        self.id = UUID().uuidString
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.provider = provider
        self.isActive = true
        self.createdAt = Date()
    }
}
