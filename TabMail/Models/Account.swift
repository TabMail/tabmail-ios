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

    /// Which identity space this provider's CONTENT rows (FTS, `messageBody`,
    /// `bodyAsset`) draw their key tail from — the main-app bridge into
    /// `MessageIdentity.contentKey`. Mirrors the provider ladder in branch
    /// `v2final`'s `DisplayedAttachmentIdentity.resolve(for:)`.
    ///
    /// ⚑ Written EXHAUSTIVELY with no `default:` clause on purpose: a sixth
    /// provider must be a compile error here, not a silent mis-keying of that
    /// provider's bodies and search rows.
    var contentKeySpace: ContentKeySpace {
        switch self {
        // Server-assigned message ids that are never reassigned. The provider id
        // IS durable identity, so these keys must not move.
        case .gmail, .outlook: return .stableProviderId
        // UIDs — a mutable address the server reuses across a UIDVALIDITY change.
        case .imap, .icloud: return .uidAddressed
        // Calendar-only. `AccountManager.connectAccount` returns for `.caldav`
        // before any `EmailProvider` is created, so no header, body, FTS or
        // body-asset row is ever minted under this provider and the case is
        // unreachable from every content-key call site. The reference ladder
        // THROWS here, which a non-optional key mint cannot do (see
        // `MessageIdentity.contentKey`). `.stableProviderId` is the fail-safe
        // choice for an unreachable case: it reproduces `MessageIdentity.headerId`
        // byte-for-byte, so were the case ever to become reachable it would key
        // exactly as it does today rather than silently re-key a store that has no
        // migration behind it.
        case .caldav: return .stableProviderId
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

    /// True when this iCloud account's email connected but CalDAV (calendar)
    /// setup failed during add (the best-effort path in `addICloudAccount`).
    /// Drives the add-time "Calendar Not Connected" alert (read off the
    /// returned account) and the persistent note in Settings (read off the
    /// row). Defaults false; existing rows backfill false via the additive
    /// `v61` migration.
    var calendarSetupFailed: Bool = false

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
