/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SwiftMail
@testable import TabMail

/// **The system property: every connection to the user's own mail server is
/// encrypted, and a server that offers no encryption is refused with a sentence
/// that says so, before the password or any mail is sent.**
///
/// Implicit TLS on 993 (IMAP) and 465 (SMTP); every other port connects and
/// requires STARTTLS (`MailTransportPolicy`). The end-to-end cases drive the
/// real `IMAPProvider`, account setup, the Outbox drain and the notification
/// service's one-shot fetch against servers on loopback ports that offer no
/// STARTTLS, and read what reached the wire.
///
/// `.serialized`: the fakes bind listening sockets. `.processGlobalState`:
/// account setup and the Outbox drain use the shared account manager and an
/// installed test database.
@Suite("Mail connections always use an encrypted connection", .serialized, .processGlobalState)
struct MailTransportEncryptionTests {

    /// An error whose rendering is exactly `description`.
    private struct NamedError: Error, CustomStringConvertible {
        let description: String
    }

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

    @Test("Only 993 (IMAP) and 465 (SMTP) are implicit TLS; every other port requires STARTTLS; none is unencrypted")
    func everyPortHasItsTransport() {
        var offending: [String] = []
        for port in 0...65_535 {
            let imap = MailTransportPolicy.imapSecurity(port: port)
            let smtp = MailTransportPolicy.smtpSecurity(port: port)
            if imap != (port == 993 ? .implicitTLS : .startTLS) { offending.append("IMAP \(port): \(imap)") }
            if smtp != (port == 465 ? .implicitTLS : .startTLS) { offending.append("SMTP \(port): \(smtp)") }
        }
        #expect(offending.isEmpty, "\(offending.prefix(5))")
    }

    @Test("The provider's IMAP and SMTP connections take the policy's transport for the standard ports")
    func providerTransportForStandardPorts() {
        func provider(imap: Int, smtp: Int, useTLS: Bool? = nil) -> IMAPProvider {
            IMAPProvider(host: "mail.example.com", port: imap, username: "me@example.com",
                         password: "synthetic-password", smtpHost: "smtp.example.com", smtpPort: smtp, useTLS: useTLS)
        }
        let implicitPorts = provider(imap: 993, smtp: 465)
        let startTLSPorts = provider(imap: 143, smtp: 587)
        #expect(implicitPorts.imapTransportSecurity == .implicitTLS)
        #expect(implicitPorts.smtpTransportSecurity == .implicitTLS)
        #expect(startTLSPorts.imapTransportSecurity == .startTLS)
        #expect(startTLSPorts.smtpTransportSecurity == .startTLS)
        #expect(provider(imap: 143, smtp: 25).smtpTransportSecurity == .startTLS)
        #expect(provider(imap: 993, smtp: 2525).smtpTransportSecurity == .startTLS)
        // Only the plain-TCP test override (`useTLS: false`, DEBUG only) changes it.
        #expect(provider(imap: 993, smtp: 465, useTLS: true).imapTransportSecurity == .implicitTLS)
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

    private static func sentSignIn(_ commands: [String]) -> Bool {
        commands.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") }
    }

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
        #expect(!Self.sentSignIn(commands), "\(commands)")
    }

    @Test("The notification service's fetch connects to a server that offers no STARTTLS, then never logs in")
    func notificationFetchWithoutSTARTTLSSendsNoLogin() async throws {
        let server = FakeIMAPServer(messages: [FakeIMAPServer.makeMessage(uid: 1, rfc822Text: Self.rfc822)])
        try server.start()
        defer { server.stop() }
        // The greeting is held, so the fetch is seen to reach the server before
        // it is refused there (rather than giving up without connecting).
        server.holdGreetings()
        let port = server.port, username = server.username, password = server.password
        let fetch = Task {
            await NSEIMAPConnection.fetch(
                accountId: "encrypted-only-account", host: "127.0.0.1", port: port,
                username: username, password: password,
                rfc822MessageId: "<encrypted-only-1@example.com>") == nil
        }
        var polls = 0
        while server.heldGreetingCount() == 0, polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        let connections = server.heldGreetingCount()
        server.releaseGreetings()
        let gaveNothing = await fetch.value

        #expect(connections == 1, "the fetch never reached the server")
        #expect(gaveNothing)
        let commands = server.recordedCommands()
        #expect(!Self.sentSignIn(commands), "\(commands)")
    }

    @Test("Adding an account on a server that offers no STARTTLS is refused with the sentence: no LOGIN, nothing saved")
    func addAccountWithoutSTARTTLSIsRefused() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        let manager = AccountManager.shared
        let previousOverride = manager.imapUseTLSOverride
        manager.setIMAPUseTLSOverrideForTesting(nil) // the production transport
        defer { manager.setIMAPUseTLSOverrideForTesting(previousOverride) }
        let email = "add-\(UUID().uuidString.prefix(8).lowercased())@example.com"

        var thrown: Error?
        do {
            _ = try await manager.addIMAPAccount(
                displayName: "Encrypted only", email: email, username: server.username, password: server.password,
                imapHost: "127.0.0.1", imapPort: server.port,
                smtpHost: "127.0.0.1", smtpPort: MailTransportPolicy.smtpImplicitTLSPort)
        } catch { thrown = error }

        let expected = IMAPTransportSecurityError.noEncryptedConnection(
            host: "127.0.0.1", port: server.port, encryptedPort: MailTransportPolicy.imapImplicitTLSPort)
        #expect(thrown as? IMAPTransportSecurityError == expected, "got \(String(describing: thrown))")
        if let thrown {
            #expect(thrown.userFacingDescription == expected.description)
        }
        let commands = server.recordedCommands()
        #expect(!Self.sentSignIn(commands), "\(commands)")
        let saved = try await pool.read { db in
            try Account.filter(Column("emailAddress") == email).fetchCount(db)
        }
        #expect(saved == 0, "a refused account was saved")
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

    // MARK: - The Outbox

    /// Queue one ready send (no undo hold) for an account whose SMTP server is
    /// `127.0.0.1:smtpPort`, run `drains` Outbox drains, and return the row's
    /// status and strike count after each, and the row at the end.
    private static func drainSend(smtpPort: Int, drains: Int) async throws -> (states: [String], row: OutboxMessage?) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        let account = try FolderEpochTestFixture.makeAccount(
            id: "outbox-\(UUID().uuidString.prefix(8).lowercased())", provider: .imap, pool: pool)
        var message = OutboxMessage(
            accountId: account.id, draft: DraftMessage(to: ["recipient@example.com"], subject: "Hello", body: "Hello."))
        message.holdUntil = Date().addingTimeInterval(-60)
        let seeded = message
        try await pool.write { db in try seeded.insert(db) }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: 1, username: account.emailAddress, password: "synthetic-password",
            senderEmail: account.emailAddress, smtpHost: "127.0.0.1", smtpPort: smtpPort)
        var states: [String] = []
        var row: OutboxMessage?
        try await TestProviderRegistry.withRegisteredProvider(accountId: account.id, provider: provider) {
            for _ in 0..<drains {
                try #require(await OutboxDrainLatch.waitForClear(), "an earlier drain still owns the outbox")
                await AccountManager.shared.drainOutbox()
                row = try await pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
                states.append("\(row?.status ?? "missing") \(row?.retryCount ?? -1)")
            }
        }
        try #require(await OutboxDrainLatch.waitForClear(), "the last drain never let the outbox go")
        return (states, row)
    }

    @Test("A queued send to a server that offers no STARTTLS: one strike per drain, Failed with the sentence on the third, never sent")
    func outboxSendEndsFailedWithTheSentence() async throws {
        let smtp = FakeSMTPServer()
        try smtp.start()
        defer { smtp.stop() }

        let (states, last) = try await Self.drainSend(smtpPort: smtp.port, drains: 3)

        let queued = OutboxStatus.queued.rawValue, failed = OutboxStatus.failed.rawValue
        #expect(states == ["\(queued) 1", "\(queued) 2", "\(failed) 3"], "\(states)")
        let row = try #require(last)
        #expect(row.errorMessage == IMAPTransportSecurityError.noEncryptedConnection(
            host: "127.0.0.1", port: smtp.port, encryptedPort: MailTransportPolicy.smtpImplicitTLSPort).description)
        #expect(row.sentAt == nil, "a refused send was stamped sent")
        let lines = smtp.receivedLines()
        #expect(lines.filter { $0.uppercased().hasPrefix("EHLO") }.count == 3, "\(lines)")
        #expect(!lines.contains { $0.uppercased().hasPrefix("AUTH") || $0.uppercased().hasPrefix("MAIL FROM") },
                "\(lines)")
    }

    @Test("Control: a send whose server cannot be reached stays queued with no strike")
    func outboxUnreachableServerStaysQueued() async throws {
        // Nothing listens on port 1: the connection itself fails, a passing problem.
        let (states, last) = try await Self.drainSend(smtpPort: 1, drains: 1)
        #expect(states == ["\(OutboxStatus.queued.rawValue) 0"], "\(states)")
        #expect(last?.sentAt == nil)
    }

    // MARK: - Recognising the refusal

    private static let refused = IMAPTransportSecurityError.noEncryptedConnection(
        host: "mail.example.com", port: 143, encryptedPort: 993)

    @Test("Only SwiftMail's own no-STARTTLS refusal, word for word, becomes the sentence; a server's reply with the same words does not")
    func onlyTheLibraryRefusalIsRecognised() {
        func mapped(_ error: Error) -> IMAPTransportSecurityError? {
            IMAPProvider.mapTransportSecurityFailure(
                error, host: "mail.example.com", port: 143, encryptedPort: 993) as? IMAPTransportSecurityError
        }
        #expect(mapped(IMAPError.connectionFailed("Server did not advertise STARTTLS on port 143")) == Self.refused)
        #expect(mapped(SMTPError.tlsFailed("STARTTLS required but not advertised by server")) == Self.refused)
        let lookalikes: [any Error] = [
            // Another port's refusal is not this connection's.
            IMAPError.connectionFailed("Server did not advertise STARTTLS on port 1143"),
            // A server's own text, carried by the same cases or by others.
            IMAPError.connectionFailed("Server rejected connection: did not advertise STARTTLS"),
            IMAPError.commandFailed("Server did not advertise STARTTLS on port 143"),
            SMTPError.connectionFailed("STARTTLS required but not advertised by server"),
            SMTPError.tlsFailed("STARTTLS upgrade failed: STARTTLS required but not advertised by server"),
            SMTPError.commandFailed("STARTTLS required but not advertised by server"),
            NamedError(description: "Server did not advertise STARTTLS on port 143"),
        ]
        for error in lookalikes {
            #expect(mapped(error) == nil, "\(error)")
        }
    }

    // MARK: - The sentence and how the app treats it

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

    @Test("A refusal whose server name contains a network-error word is still not read as being offline")
    func serverNameNeverMakesTheRefusalLookOffline() {
        let hosts = ["ChannelError.example.com", "EPIPE.example.com", "NIOConnectionError.example.com",
                     "IMAPDecoderError.example.com"]
        for host in hosts {
            let refusals = [IMAPTransportSecurityError.noEncryptedConnection(host: host, port: 143, encryptedPort: 993),
                            IMAPTransportSecurityError.tlsFloorNotMet(host: host)]
            for refusal in refusals {
                #expect(SyncEngine.isConnectionError(refusal) == false, "\(refusal)")
                #expect(AccountManager.isTransientSendError(refusal) == false, "\(refusal)")
            }
        }
        // Control: the same words in any other error still read as a network problem.
        #expect(SyncEngine.isConnectionError(NamedError(description: "ChannelError.example.com")))
    }

    @Test("The inbox banner shows its fixed encryption line for either refusal, never the server's name")
    func bannerLineForTheRefusal() {
        let floor = IMAPTransportSecurityError.tlsFloorNotMet(host: "mail.example.com")
        #expect(InboxErrorBanner.text(for: Self.refused) == InboxErrorBanner.encryptionMessage)
        #expect(InboxErrorBanner.text(for: floor) == InboxErrorBanner.encryptionMessage)
        #expect(InboxErrorBanner.allLines.contains(InboxErrorBanner.encryptionMessage))
        #expect(!InboxErrorBanner.encryptionMessage.contains("mail.example.com"))
        #expect(InboxErrorBanner.countsAsFailure(Self.refused, accountMarkedSignInNeeded: false))
        // Control: any other failure keeps the generic line.
        #expect(InboxErrorBanner.text(for: NamedError(description: "unexpected")) == InboxErrorBanner.genericMessage)
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
        var result: [(path: String, source: String)] = []
        for folder in ["TabMail", "Shared", "TabMailNotificationService"] {
            let root = repoRoot.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                result.append((path: folder + "/" + url.lastPathComponent, source: source))
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

    /// The transport each construction may pass: the policy for its own
    /// protocol, or a named property or parameter that carries it (pinned by
    /// `providerTransportForStandardPorts` and the notification service checks).
    private static func statesItsTransport(_ name: String, _ arguments: String, path: String) -> Bool {
        if arguments.contains("useTLS:") { return false }
        switch name {
        case "IMAPServer":
            return arguments.contains("transportSecurity: MailTransportPolicy.imapSecurity(port: ")
                || (path.hasSuffix("IMAPProvider.swift") && arguments.contains("transportSecurity: imapTransportSecurity"))
                || (path.hasSuffix("NSEIMAPConnection.swift") && arguments.contains("transportSecurity: transportSecurity"))
        default:
            return arguments.contains("transportSecurity: MailTransportPolicy.smtpSecurity(port: ")
                || (path.hasSuffix("IMAPProvider.swift") && arguments.contains("transportSecurity: smtpTransportSecurity"))
        }
    }

    @Test("Every IMAP and SMTP server the app builds takes its own protocol's encrypted transport, never the port-guessing init")
    func everyServerStatesItsTransport() throws {
        var sites: [String] = []
        var violations: [String] = []
        var notificationSource = ""
        for (path, source) in try Self.shippedSources() {
            if path.hasSuffix("NSEIMAPConnection.swift") { notificationSource = source }
            for name in ["IMAPServer", "SMTPServer"] {
                for arguments in Self.callArguments(of: name, in: source) {
                    sites.append("\(path) \(name)")
                    if !Self.statesItsTransport(name, arguments, path: path) {
                        violations.append("\(path): \(name)(\(arguments.prefix(120))")
                    }
                }
            }
        }
        // Non-vacuity: the provider's IMAP and SMTP sites and the notification
        // service's IMAP site are all found.
        #expect(sites.contains("TabMail/IMAPProvider.swift IMAPServer"), "\(sites)")
        #expect(sites.contains("TabMail/IMAPProvider.swift SMTPServer"), "\(sites)")
        #expect(sites.contains("TabMailNotificationService/NSEIMAPConnection.swift IMAPServer"), "\(sites)")
        #expect(violations.isEmpty, "\(violations)")
        // The notification service's shipped fetch hands its server the IMAP policy.
        #expect(notificationSource.contains("transportSecurity: MailTransportPolicy.imapSecurity(port: port))"))
    }

    @Test("Every IMAP push subscription payload asks for exactly the implicit-TLS transport")
    func everyPushPayloadStatesItsTransport() throws {
        var payloads: [String] = []
        var violations: [String] = []
        for (path, source) in try Self.shippedSources() {
            for arguments in Self.callArguments(of: "IMAPCredPayload", in: source) {
                payloads.append(path)
                // The whole `security:` argument, which is the last one.
                let security = arguments.components(separatedBy: "security:").last.map {
                    $0.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !arguments.contains("security:") || security != "MailTransportPolicy.pushSubscriptionSecurity" {
                    violations.append("\(path): IMAPCredPayload(\(arguments.prefix(160))")
                }
            }
        }
        #expect(payloads.contains("TabMail/PushClient.swift"), "\(payloads)")
        #expect(payloads.contains("TabMailNotificationService/NotificationService.swift"), "\(payloads)")
        #expect(violations.isEmpty, "\(violations)")
    }
}
