/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftMail

/// How TabMail connects to the user's own mail server: always over an
/// encrypted connection.
///
/// - The implicit-TLS ports (RFC 8314: 993 for IMAP, 465 for SMTP) speak TLS
///   from the first byte.
/// - Every other port connects and then REQUIRES STARTTLS. A server that does
///   not offer it is refused before sign-in and before any mail is sent; only
///   the greeting and the capability exchange that finds STARTTLS missing take
///   place unencrypted (SwiftMail's `.startTLS` is its STARTTLS-required mode).
///
/// SwiftMail's `.automatic` is never used: it upgrades only when the server
/// offers STARTTLS on 143 and 587, and for SMTP on any other port it never
/// upgrades. `.plainText` is never used outside the DEBUG test seam that
/// reaches the plain-TCP fake IMAP server.
///
/// Compiled into the app and the notification service extension, so both
/// IMAP entry points (`IMAPProvider`, `NSEIMAPConnection`) and the send path
/// choose the same way. The certificate check and the TLS 1.2 floor are
/// SwiftMail's defaults (`.fullVerification`, `.tlsv12`), unchanged.
enum MailTransportPolicy {

    /// The IMAP port that speaks TLS from the first byte.
    static let imapImplicitTLSPort = 993

    /// The SMTP submission port that speaks TLS from the first byte.
    static let smtpImplicitTLSPort = 465

    /// The value the IMAP push subscription sends for the idle proxy's
    /// `security` field: implicit TLS. The proxy reads a missing field the
    /// same way, so the subscription says it outright.
    static let pushSubscriptionSecurity = "tls"

    /// The transport for an IMAP connection to `port`.
    static func imapSecurity(port: Int) -> MailTransportSecurity {
        port == imapImplicitTLSPort ? .implicitTLS : .startTLS
    }

    /// The transport for an SMTP connection to `port`.
    static func smtpSecurity(port: Int) -> MailTransportSecurity {
        port == smtpImplicitTLSPort ? .implicitTLS : .startTLS
    }
}
