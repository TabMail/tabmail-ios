/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// The SMTP steps one `IMAPProvider.send(draft:)` takes, in order. Production
/// is SwiftMail's `SMTPServer`; DEBUG tests install a double through
/// `IMAPProvider.setSMTPSessionFactoryForTesting` to hold a step.
protocol SMTPSubmissionSession: Sendable {
    /// Connect, greeting and TLS.
    func openConnection() async throws
    func authenticate(username: String, password: String) async throws
    func submit(_ email: Email) async throws
    func close() async throws
}

extension SMTPServer: SMTPSubmissionSession {
    func openConnection() async throws { try await connect() }

    func authenticate(username: String, password: String) async throws {
        try await login(username: username, password: password)
    }

    func submit(_ email: Email) async throws { _ = try await sendEmail(email) }

    func close() async throws { try await disconnect() }
}
