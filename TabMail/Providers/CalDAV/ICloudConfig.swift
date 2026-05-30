/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Hardcoded iCloud server settings.
enum ICloudConfig {
    static let imapHost = "imap.mail.me.com"
    static let imapPort = 993
    static let smtpHost = "smtp.mail.me.com"
    static let smtpPort = 587
    static let caldavURL = "https://caldav.icloud.com"
    /// Apple domains that indicate iCloud email
    static let domains = ["icloud.com", "me.com", "mac.com"]

    /// Check if an email address is an iCloud/Apple domain.
    static func isAppleDomain(_ email: String) -> Bool {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        return domains.contains(domain) || domain.hasSuffix(".privaterelay.appleid.com")
    }
}
