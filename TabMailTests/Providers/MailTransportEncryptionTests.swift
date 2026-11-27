/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// **The system property: every connection to the user's own mail server is
/// encrypted, and a server that offers no encryption is refused with a sentence
/// that says so, before the password or any mail is sent.**
///
/// Implicit TLS on 993 (IMAP) and 465 (SMTP); every other port connects and
/// requires STARTTLS (`MailTransportPolicy`). The end-to-end cases drive the
/// real `IMAPProvider`, the real send path and the notification service's
/// one-shot fetch against servers on loopback ports that offer no STARTTLS, and
/// read what reached the wire.
///
/// `.serialized`: the fakes bind listening sockets.
@Suite("Mail connections always use an encrypted connection", .serialized)
struct MailTransportEncryptionTests {

    // MARK: - The transport for each port

    @Test("IMAP uses implicit TLS on 993 and requires STARTTLS on every other port")
    func imapTransportForEachPort() {
        #expect(MailTransportPolicy.imapSecurity(port: 993) == .implicitTLS)
        for port in [143, 1143, 2143, 465, 587, 25] {
            #expect(MailTransportPolicy.imapSecurity(port: port) == .startTLS, "port \(port)")
        }
    }

    @Test("SMTP uses implicit TLS on 465 and requires STARTTLS on every other port, 25 and 2525 included")
    func smtpTransportForEachPort() {
        #expect(MailTransportPolicy.smtpSecurity(port: 465) == .implicitTLS)
        for port in [587, 25, 2525, 993, 143] {
            #expect(MailTransportPolicy.smtpSecurity(port: port) == .startTLS, "port \(port)")
        }
    }

    @Test("No port gives an unencrypted or port-guessed transport, for IMAP or SMTP")
    func noPortGivesAnUnencryptedTransport() {
        var offending: [String] = []
        for port in 0...65_535 {
            for (service, security) in [("IMAP", MailTransportPolicy.imapSecurity(port: port)),
                                        ("SMTP", MailTransportPolicy.smtpSecurity(port: port))]
            where security != .implicitTLS && security != .startTLS {
                offending.append("\(service) \(port): \(security)")
            }
        }
        #expect(offending.isEmpty, "\(offending.prefix(5))")
    }

    @Test("The IMAP push subscription asks the proxy for implicit TLS")
    func pushSubscriptionAsksForImplicitTLS() {
        #expect(MailTransportPolicy.pushSubscriptionSecurity == "tls")
    }

    // MARK: - End to end: a server that offers no STARTTLS

    private static let rfc822 = """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Hello\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <encrypted-only-1@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Hello.\r

        """

    @Test("IMAP to a server that offers no STARTTLS is refused with the no-encryption sentence, and no LOGIN is sent")
    func imapWithoutSTARTTLSIsRefusedBeforeLogin() async throws {
        let server = FakeIMAPServer(messages: [FakeIMAPServer.makeMessage(uid: 1, rfc822Text: Self.rfc822)])
        try server.start()
        defer { server.stop() }
        // No test override: the transport comes from the port, as in production.
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: MailTransportPolicy.smtpImplicitTLSPort)

        var thrown: Error?
        do { try await provider.connect() } catch { thrown = error }
        try? await provider.disconnect()

        #expect(thrown as? IMAPTransportSecurityError == .noEncryptedConnection(
            host: "127.0.0.1", port: server.port, encryptedPort: MailTransportPolicy.imapImplicitTLSPort),
            "got \(String(describing: thrown))")
        let commands = server.recordedCommands()
        #expect(!commands.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") },
                "\(commands)")
    }

    @Test("The notification service's fetch never logs in to a server that offers no STARTTLS")
    func notificationFetchWithoutSTARTTLSSendsNoLogin() async throws {
        let server = FakeIMAPServer(messages: [FakeIMAPServer.makeMessage(uid: 1, rfc822Text: Self.rfc822)])
        try server.start()
        defer { server.stop() }

        let result = await NSEIMAPConnection.fetch(
            accountId: "encrypted-only-account", host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            rfc822MessageId: "<encrypted-only-1@example.com>")

        #expect(result == nil)
        let commands = server.recordedCommands()
        #expect(!commands.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") },
                "\(commands)")
    }

    @Test("A send to an SMTP server that offers no STARTTLS is refused with the no-encryption sentence, before AUTH or any mail")
    func sendWithoutSTARTTLSIsRefusedBeforeAuth() async throws {
        let smtp = FakeSMTPServer()
        try smtp.start()
        defer { smtp.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: 1, username: "me@example.com", password: "synthetic-password",
            senderEmail: "me@example.com", smtpHost: "127.0.0.1", smtpPort: smtp.port)

        var thrown: Error?
        do {
            _ = try await provider.send(draft: DraftMessage(
                to: ["recipient@example.com"], subject: "Hello", body: "Hello."))
        } catch { thrown = error }

        #expect(thrown as? IMAPTransportSecurityError == .noEncryptedConnection(
            host: "127.0.0.1", port: smtp.port, encryptedPort: MailTransportPolicy.smtpImplicitTLSPort),
            "got \(String(describing: thrown))")
        let lines = smtp.receivedLines()
        // The fake is reached: the refusal came after EHLO, not from a dead port.
        #expect(lines.contains { $0.uppercased().hasPrefix("EHLO") }, "\(lines)")
        #expect(!lines.contains { $0.uppercased().hasPrefix("AUTH") }, "\(lines)")
        #expect(!lines.contains { $0.uppercased().hasPrefix("MAIL FROM") }, "\(lines)")
        #expect(!lines.contains { $0.contains("synthetic-password") }, "\(lines)")
    }

    // MARK: - The sentence and how the app treats it

    private static let refused = IMAPTransportSecurityError.noEncryptedConnection(
        host: "mail.example.com", port: 143, encryptedPort: 993)

    @Test("The no-encryption sentence names the server, the refused port and the encrypted port, in both renderings")
    func sentenceNamesServerAndPorts() {
        for text in [String(describing: Self.refused), Self.refused.localizedDescription,
                     Self.refused.userFacingDescription] {
            #expect(text.contains("mail.example.com"), "\(text)")
            #expect(text.contains("port 143"), "\(text)")
            #expect(text.contains("port 993"), "\(text)")
            #expect(text.contains("encrypt"), "\(text)")
        }
    }

    @Test("A send the server refuses for lack of encryption ends in Failed after the bounded retries, not queued forever")
    func noEncryptionSendIsPermanent() {
        #expect(AccountManager.isTransientSendError(Self.refused) == false)
        #expect(AccountManager.isFatalSendError(Self.refused) == false)
    }

    @Test("The no-encryption refusal is not read as being offline")
    func noEncryptionIsNotOffline() {
        #expect(SyncEngine.isConnectionError(Self.refused) == false)
        let text = String(describing: Self.refused)
        for word in ["connection", "Connection", "timeout", "timed out", "not connected", "command failed"] {
            #expect(!text.contains(word), "\(word)")
        }
    }

    @Test("A password update against such a server shows the no-encryption sentence; the TLS-floor line is unchanged")
    func passwordUpdateShowsTheSentence() {
        #expect(AccountReauthAlert.passwordUpdateLine(for: Self.refused, host: "mail.example.com")
                == Self.refused.description)
        let floor = IMAPTransportSecurityError.tlsFloorNotMet(host: "mail.example.com")
        #expect(AccountReauthAlert.passwordUpdateLine(for: floor, host: "mail.example.com")
                == AccountReauthAlert.tlsLine(host: "mail.example.com"))
    }

    // MARK: - Source fence: every construction states its transport

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Providers
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
    }

    /// The argument text of every call `name(...)` in `source`, skipping
    /// comment lines and the declaration `func name(`.
    static func callArguments(of name: String, in source: String) -> [String] {
        let text = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: name + "(", range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            let before = text[text.startIndex..<range.lowerBound]
            if before.hasSuffix("func ") { continue }
            if let previous = before.last, previous.isLetter || previous.isNumber || previous == "_" { continue }
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            found.append(String(text[range.upperBound..<index]))
        }
        return found
    }

    /// Every `.swift` file of the app, the shared code and the notification
    /// service extension, by repo-relative path.
    private static func shippedSources() throws -> [(path: String, source: String)] {
        var result: [(String, String)] = []
        for folder in ["TabMail", "Shared", "TabMailNotificationService"] {
            let root = repoRoot.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result.append((folder + "/" + url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return result
    }

    @Test("the call finder itself: it finds a call's arguments and skips comments and declarations")
    func callFinderIsSound() {
        let source = """
            /// IMAPServer(host: "doc", port: 1)
            func IMAPServer(host: String) {}
            let a = IMAPServer(host: h, port: p, transportSecurity: MailTransportPolicy.imapSecurity(port: p))
            let b = FakeIMAPServer(port: 1)
            """
        #expect(Self.callArguments(of: "IMAPServer", in: source)
                == ["host: h, port: p, transportSecurity: MailTransportPolicy.imapSecurity(port: p))"])
    }

    @Test("Every IMAP and SMTP server the app builds states an encrypted transport and none uses the port-guessing init")
    func everyServerStatesItsTransport() throws {
        var sites: [String] = []
        var violations: [String] = []
        for (path, source) in try Self.shippedSources() {
            for name in ["IMAPServer", "SMTPServer"] {
                for arguments in Self.callArguments(of: name, in: source) {
                    sites.append(path)
                    let states = arguments.contains("transportSecurity: MailTransportPolicy.")
                        || (path.hasSuffix("IMAPProvider.swift")
                            && arguments.contains("transportSecurity: imapTransportSecurity"))
                    if !states || arguments.contains("useTLS:") {
                        violations.append("\(path): \(name)(\(arguments.prefix(120))")
                    }
                }
            }
        }
        // Non-vacuity: the provider's IMAP and SMTP sites and the notification
        // service's IMAP site are all found.
        #expect(sites.filter { $0.hasSuffix("IMAPProvider.swift") }.count >= 2, "\(sites)")
        #expect(sites.contains { $0.hasSuffix("NSEIMAPConnection.swift") }, "\(sites)")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("Every IMAP push subscription states its transport")
    func everyPushSubscriptionStatesItsTransport() throws {
        var subscribes = 0
        var payloads = 0
        var violations: [String] = []
        for (path, source) in try Self.shippedSources() {
            for arguments in Self.callArguments(of: "subscribeIMAP", in: source) {
                subscribes += 1
                if !arguments.contains("security: MailTransportPolicy.pushSubscriptionSecurity") {
                    violations.append("\(path): subscribeIMAP(\(arguments.prefix(120))")
                }
            }
            for arguments in Self.callArguments(of: "IMAPCredPayload", in: source) {
                payloads += 1
                // The push client builds the payload from its own required parameter.
                let fromParameter = path.hasSuffix("PushClient.swift") && arguments.contains("security: security")
                if !fromParameter && !arguments.contains("security: MailTransportPolicy.pushSubscriptionSecurity") {
                    violations.append("\(path): IMAPCredPayload(\(arguments.prefix(120))")
                }
            }
        }
        #expect(subscribes >= 1 && payloads >= 2, "subscribe calls \(subscribes), payloads \(payloads)")
        #expect(violations.isEmpty, "\(violations)")
    }
}
