/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// **The system property: a send to an SMTP server whose STARTTLS upgrade can
/// never succeed ends Failed with Retry/Discard instead of staying queued for
/// good; a server below the TLS 1.2 floor is named; a failure that can clear by
/// itself keeps the send queued with no strike.**
///
/// The servers offer STARTTLS on a loopback port (which `MailTransportPolicy`
/// requires off 465) and then answer it, or the client's first TLS bytes,
/// without completing a handshake, so the pinned SwiftMail's real wording
/// reaches the Outbox drain. Part of `MailTransportEncryptionTests`, so it shares
/// that suite's serialization.
extension MailTransportEncryptionTests {

    private static var queued: String { OutboxStatus.queued.rawValue }
    private static var failed: String { OutboxStatus.failed.rawValue }
    private static let temporaryRefusal = "454 4.7.0 TLS not available due to temporary reason"

    private static func askedForSTARTTLS(_ lines: [String]) -> Int {
        lines.filter { $0.uppercased() == "STARTTLS" }.count
    }

    private static func signedInOrSent(_ lines: [String]) -> Bool {
        lines.contains { $0.uppercased().hasPrefix("AUTH") || $0.uppercased().hasPrefix("MAIL FROM") }
    }

    /// The text the Outbox stores for a failed upgrade: `SMTPError.tlsFailed`'s
    /// description around the pinned SwiftMail's reason.
    private static func stored(_ reason: String) -> String {
        "SMTP TLS failed: STARTTLS upgrade failed: " + reason
    }

    /// The first byte of a TLS handshake record (content type 22).
    private static let tlsHandshakeRecordType: UInt8 = 0x16

    /// How long a test waits for the fake to keep every upgraded connection's bytes.
    private static let upgradeCaptureWaitSeconds = 5.0

    /// After each accepted STARTTLS the client sent only TLS: its bytes begin
    /// with a handshake record and carry no plain-text AUTH or MAIL FROM.
    private static func expectOnlyTLSAfterUpgrade(_ smtp: FakeSMTPServer, connections: Int) async {
        let sessions = await smtp.bytesAfterSTARTTLS(count: connections, within: upgradeCaptureWaitSeconds)
        #expect(sessions.count == connections, "\(sessions.count) upgraded connections")
        for bytes in sessions {
            #expect(bytes.first == tlsHandshakeRecordType, "\(Array(bytes.prefix(8)))")
            let text = String(decoding: bytes, as: UTF8.self).uppercased()
            #expect(!text.contains("AUTH") && !text.contains("MAIL FROM"), "plain-text command after STARTTLS")
        }
    }

    // MARK: - Failures that can never clear take the strikes

    @Test("A queued send to a STARTTLS server below TLS 1.2: one strike per drain, Failed with the TLS-floor sentence on the third, never sent")
    func belowFloorSTARTTLSSendEndsFailedWithTheFloorSentence() async throws {
        let smtp = FakeSMTPServer(startTLSAnswer: .acceptThenAnswerHandshake(FakeSMTPServer.protocolVersionAlert))
        try smtp.start()
        defer { smtp.stop() }

        let (states, last) = try await Self.drainSend(smtpPort: smtp.port, drains: 3)

        #expect(states == ["\(Self.queued) 1", "\(Self.queued) 2", "\(Self.failed) 3"], "\(states)")
        let row = try #require(last)
        #expect(row.errorMessage == IMAPTransportSecurityError.tlsFloorNotMet(host: "127.0.0.1").description,
                "\(String(describing: row.errorMessage))")
        #expect(row.sentAt == nil, "a refused send was stamped sent")
        let lines = smtp.receivedLines()
        #expect(Self.askedForSTARTTLS(lines) == 3, "\(lines)")
        #expect(!Self.signedInOrSent(lines), "\(lines)")
        await Self.expectOnlyTLSAfterUpgrade(smtp, connections: 3)
    }

    /// Stands in for a certificate that does not verify, which needs a real
    /// certificate to reproduce: the same `handshakeFailed(...)` failure from the
    /// TLS layer, with a different reason.
    @Test("A STARTTLS handshake that fails for another reason takes the strikes and ends Failed with the generic error, as on port 465")
    func failedSTARTTLSHandshakeEndsFailedWithTheGenericError() async throws {
        let smtp = FakeSMTPServer(startTLSAnswer: .acceptThenAnswerHandshake(Array("250 not a TLS record\r\n".utf8)))
        try smtp.start()
        defer { smtp.stop() }

        let (states, last) = try await Self.drainSend(smtpPort: smtp.port, drains: 3)

        #expect(states == ["\(Self.queued) 1", "\(Self.queued) 2", "\(Self.failed) 3"], "\(states)")
        let message = try #require(last?.errorMessage)
        #expect(message.hasPrefix(Self.stored("handshakeFailed(")), "\(message)")
        #expect(message.contains("WRONG_VERSION_NUMBER"), "\(message)")
        #expect(last?.sentAt == nil)
        #expect(!Self.signedInOrSent(smtp.receivedLines()))
        await Self.expectOnlyTLSAfterUpgrade(smtp, connections: 3)
    }

    @Test("A server that hangs up during the STARTTLS handshake costs the send a strike, as on port 465")
    func hangUpDuringSTARTTLSHandshakeTakesAStrike() async throws {
        let smtp = FakeSMTPServer(startTLSAnswer: .acceptThenAnswerHandshake([]))
        try smtp.start()
        defer { smtp.stop() }

        let (states, last) = try await Self.drainSend(smtpPort: smtp.port, drains: 1)

        #expect(states == ["\(Self.queued) 1"], "\(states)")
        let message = try #require(last?.errorMessage)
        #expect(message.hasPrefix(Self.stored("handshakeFailed(")), "\(message)")
        #expect(message.contains("EOF during handshake"), "\(message)")
        #expect(Self.askedForSTARTTLS(smtp.receivedLines()) == 1)
        await Self.expectOnlyTLSAfterUpgrade(smtp, connections: 1)
    }

    // MARK: - Failures that can clear stay queued with no strike

    @Test("Control: a server that refuses STARTTLS for now (454) keeps the send queued with no strike")
    func temporaryRefusalStaysQueued() async throws {
        let smtp = FakeSMTPServer(startTLSAnswer: .refuse(Self.temporaryRefusal))
        try smtp.start()
        defer { smtp.stop() }

        let (states, last) = try await Self.drainSend(smtpPort: smtp.port, drains: 2)

        #expect(states == ["\(Self.queued) 0", "\(Self.queued) 0"], "\(states)")
        #expect(last?.errorMessage == Self.stored("SMTP TLS failed: STARTTLS failed: " + Self.temporaryRefusal),
                "\(String(describing: last?.errorMessage))")
        #expect(Self.askedForSTARTTLS(smtp.receivedLines()) == 2)
    }

    @Test("Control: a server that never answers STARTTLS keeps the send queued with no strike")
    func unansweredSTARTTLSStaysQueued() async throws {
        let smtp = FakeSMTPServer(startTLSAnswer: .silence)
        try smtp.start()
        defer { smtp.stop() }
        let port = smtp.port

        let (states, last) = try await Self.drainSend(smtpPort: port, drains: 1) { provider in
            // The real SwiftMail session with a short STARTTLS wait, so the
            // library's own timeout ends the upgrade.
            provider.setSMTPSessionFactoryForTesting {
                SMTPServer(
                    host: "127.0.0.1", port: port, transportSecurity: .startTLS,
                    connectionTimeouts: SMTPConnectionTimeouts(startTLSResponse: 0.3))
            }
        }

        #expect(states == ["\(Self.queued) 0"], "\(states)")
        #expect(last?.errorMessage == Self.stored("SMTP connection failed: STARTTLS timeout"),
                "\(String(describing: last?.errorMessage))")
    }

    // MARK: - EHLO keywords in any case

    @Test("A server that offers STARTTLS in lower case is upgraded, not refused for offering no encryption")
    func lowercaseSTARTTLSOfferIsUpgraded() async throws {
        let smtp = FakeSMTPServer(
            startTLSAnswer: .acceptThenAnswerHandshake(FakeSMTPServer.protocolVersionAlert), startTLSKeyword: "starttls")
        try smtp.start()
        defer { smtp.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: 1, username: "me@example.com", password: "synthetic-password",
            senderEmail: "me@example.com", smtpHost: "127.0.0.1", smtpPort: smtp.port)

        var thrown: Error?
        do {
            _ = try await provider.send(draft: DraftMessage(to: ["recipient@example.com"], subject: "Hello", body: "Hello."))
        } catch { thrown = error }

        #expect(thrown as? IMAPTransportSecurityError == .tlsFloorNotMet(host: "127.0.0.1"),
                "got \(String(describing: thrown))")
        let lines = smtp.receivedLines()
        #expect(Self.askedForSTARTTLS(lines) == 1, "\(lines)")
        #expect(!Self.signedInOrSent(lines), "\(lines)")
        await Self.expectOnlyTLSAfterUpgrade(smtp, connections: 1)
    }

    // MARK: - The classifier on SwiftMail's exact wording

    /// The EHLO timeout after a completed upgrade needs a real handshake, which
    /// no loopback fake gives without a certificate, so its text is written out
    /// here. SwiftMail's `SMTPStartTLSFailureTests` pins this exact text, and the
    /// 454 and STARTTLS-timeout cases above check the same wrapping, word for
    /// word, through the pinned library.
    @Test("A failed STARTTLS upgrade is transient only when SwiftMail's own SMTP error or a connection problem ended it")
    func startTLSUpgradeFailureClassification() {
        let transient = [
            "STARTTLS upgrade failed: SMTP connection failed: EHLO timeout",
            "STARTTLS upgrade failed: SMTP connection failed: STARTTLS timeout",
            "STARTTLS upgrade failed: SMTP TLS failed: STARTTLS failed: " + Self.temporaryRefusal,
            "STARTTLS upgrade failed: SMTP connection failed: Connection closed",
            // The server closed after accepting STARTTLS, before any TLS byte.
            "STARTTLS upgrade failed: SMTP connection failed: Connection closed before the TLS handshake started",
            "STARTTLS upgrade failed: IOError: Connection reset by peer (errno: 54)",
            // Not an upgrade failure: the bare refusal keeps today's reading.
            "Server rejected STARTTLS",
        ]
        for reason in transient {
            #expect(AccountManager.isTransientSendError(SMTPError.tlsFailed(reason)), "\(reason)")
        }
        let permanent = [
            // The certificate failure measured for IOS-TLS-002, as SwiftMail now reports it.
            "STARTTLS upgrade failed: handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268435581 "
                + "error:1000007d:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED at "
                + "/tmp/tabmail-dd/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/ssl/handshake.cc:288]))",
            "STARTTLS upgrade failed: handshakeFailed(NIOSSL.BoringSSLError.sslError([Error:  EOF during handshake]))",
            // A certificate for another name: the expected host holds the marker words.
            "STARTTLS upgrade failed: " + Self.hostnameMismatch("connection.example.com"),
            "STARTTLS upgrade failed: " + Self.hostnameMismatch("smtp-timeout.example.com"),
        ]
        for reason in permanent {
            #expect(!AccountManager.isTransientSendError(SMTPError.tlsFailed(reason)), "\(reason)")
            #expect(!AccountManager.isFatalSendError(SMTPError.tlsFailed(reason)), "\(reason)")
        }
    }

    /// NIOSSL's text for a certificate that does not name `host`
    /// (`NIOSSLExtraError.failedToValidateHostname(expectedName:)`).
    private static func hostnameMismatch(_ host: String) -> String {
        "NIOSSLExtraError.failedToValidateHostname: Couldn't find \(host) in certificate from peer"
    }

    /// The same error on port 465, where it reaches the Outbox bare.
    private struct BareTransportError: Error, CustomStringConvertible {
        let description: String
    }

    @Test("A certificate for another name takes the strikes on port 465 too, whatever the host is called")
    func hostnameMismatchOnImplicitTLSIsNotTransient() {
        for host in ["connection.example.com", "smtp-timeout.example.com", "Connection.example.com"] {
            let error = BareTransportError(description: Self.hostnameMismatch(host))
            #expect(!AccountManager.isTransientSendError(error), "\(error)")
        }
        // A connection problem still reads as one.
        #expect(AccountManager.isTransientSendError(BareTransportError(description: "IOError: Connection reset by peer (errno: 54)")))
    }
}
