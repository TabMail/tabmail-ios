/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

// MARK: - IOS-TLS-002 — the TLS floor must be stated, not swallowed

/// **The system property: a user whose server cannot speak TLS 1.2 is TOLD SO,
/// and their send stops pretending it is still on its way.**
///
/// `IOS-TLS-002` states a requirement — *"the failure must surface as a clear,
/// actionable error naming the TLS floor, never a silent or generic connection
/// failure"* — and both halves of it were unmet: the connect path showed NIOSSL's
/// bridged placeholder, and the send path classified the failure as transient and
/// kept the outbox row `.queued` indefinitely against a server that can never
/// accept it.
///
/// **The fixtures below are OBSERVED, not invented.** Each `describing:` string is
/// the verbatim `String(describing:)` of a real error produced on 2026-08-04 by
/// this app's SwiftMail → NIOSSL → BoringSSL stack in the iOS Simulator, driven
/// against local `openssl s_server` endpoints. Reproduction:
///
/// ```
/// openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 2 -nodes -subj "/CN=127.0.0.1"
/// openssl s_server -accept 9931 -cert c.pem -key k.pem -tls1_1 -cipher 'ALL:@SECLEVEL=0' -quiet
/// openssl s_server -accept 9932 -cert c.pem -key k.pem -tls1_3 -quiet
/// // then IMAPServer(host: "127.0.0.1", port: <p>, useTLS: true).connect()
/// ```
///
/// The `-tls1` (TLS 1.0-only) server produced a byte-identical signature to the
/// `-tls1_1` one, so both below-floor versions are covered by the same case.
///
/// **Both directions are asserted, and the second one is the one that matters
/// more.** Over-recognising is how this fix could hurt someone: labelling a
/// recoverable failure permanent stops a send that would have gone through. So a
/// certificate-verification failure — which arrives wrapped in the SAME
/// `handshakeFailed(…sslError…)` shape — and an ordinary TCP refusal must both come
/// back UNCHANGED and keep their existing retryable classification.
@Suite("TLS floor error surfacing (IOS-TLS-002)")
struct IMAPTLSFloorErrorTests {

    /// Stands in for an error whose rendered form is all the mapper consumes.
    /// `mapTransportSecurityFailure` matches on `String(describing:)` precisely so
    /// a re-wrapped rethrow still carries the signature, so feeding the observed
    /// text is feeding the real input.
    private struct ObservedError: Error, CustomStringConvertible {
        let description: String
    }

    /// TLS 1.1-only AND TLS 1.0-only servers, observed identical.
    private static let belowFloor = ObservedError(description:
        "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436526 error:1000042e:SSL "
        + "routines:OPENSSL_internal:TLSV1_ALERT_PROTOCOL_VERSION at "
        + "/tmp/tabmail-dd/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/ssl/"
        + "tls_record.cc:484]))")

    /// TLS 1.3 server, untrusted self-signed certificate. Same outer shape.
    private static let certVerifyFailed = ObservedError(description:
        "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268435581 error:1000007d:SSL "
        + "routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED at "
        + "/tmp/tabmail-dd/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/ssl/"
        + "handshake.cc:288]))")

    /// Nothing listening on the port.
    private static let connectionRefused = ObservedError(description:
        "Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:9933, "
        + "error: connection reset (error set): Connection refused) (errno: 61))")

    // MARK: - The named, actionable error

    @Test("A below-floor handshake becomes an error that names the TLS floor and the server")
    func belowFloorIsNamed() throws {
        let mapped = IMAPProvider.mapTransportSecurityFailure(
            Self.belowFloor, host: "mail.example.com")

        #expect(mapped as? IMAPTransportSecurityError
                == IMAPTransportSecurityError.tlsFloorNotMet(host: "mail.example.com"))

        // Both renderings the app actually shows a user must carry the floor and
        // the server: `OutboxView` renders `String(describing:)` (stored into
        // `errorMessage`), the connect views render `localizedDescription`.
        let described = String(describing: mapped)
        let localized = mapped.localizedDescription
        #expect(described.contains("TLS 1.2"))
        #expect(described.contains("mail.example.com"))
        #expect(localized.contains("TLS 1.2"))
        #expect(localized.contains("mail.example.com"))

        // …and specifically NOT the opaque bridged placeholder that was reaching
        // the UI before, which is what "never a silent or generic connection
        // failure" forbids.
        #expect(!localized.contains("The operation couldn’t be completed"))
    }

    // MARK: - Non-vacuity: everything else is left alone

    @Test("A certificate-verification failure — same handshake shape — is NOT relabelled as a TLS-floor failure")
    func certificateFailureIsNotRelabelled() throws {
        let mapped = IMAPProvider.mapTransportSecurityFailure(
            Self.certVerifyFailed, host: "mail.example.com")
        #expect(mapped as? IMAPTransportSecurityError == nil)
        #expect(String(describing: mapped) == Self.certVerifyFailed.description)
    }

    @Test("An ordinary refused TCP connection is returned unchanged, not mislabelled permanent")
    func transientConnectFailureIsUnchanged() throws {
        let mapped = IMAPProvider.mapTransportSecurityFailure(
            Self.connectionRefused, host: "mail.example.com")
        #expect(mapped as? IMAPTransportSecurityError == nil)
        #expect(String(describing: mapped) == Self.connectionRefused.description)
    }

    // MARK: - Send-path classification (Outbox Rules 7 / 9)

    /// The row must escalate to `.failed` and hand the user Retry/Discard, instead
    /// of sitting `.queued` forever against a server that cannot accept it.
    @Test("A TLS-floor send failure is permanent, so the outbox row escalates instead of queueing forever")
    func tlsFloorSendFailureIsPermanent() throws {
        let error = IMAPTransportSecurityError.tlsFloorNotMet(host: "smtp.example.com")
        #expect(AccountManager.isTransientSendError(error) == false)
        // Not FATAL either: the bounded 3-attempt escalation is the deliberate
        // hedge, so a misclassification cannot terminate a send on its first try.
        #expect(AccountManager.isFatalSendError(error) == false)
    }

    /// The direction that would cost a user their message: a genuinely transient
    /// SMTP failure must stay transient. `.tlsFailed` in particular still means
    /// "TLS negotiation had a problem", which is not the same claim as "this server
    /// cannot do TLS 1.2" — only the observed floor signature makes that claim.
    @Test("Non-vacuity: ordinary transient SMTP failures stay transient and keep retrying")
    func ordinaryTransientSendErrorsStayTransient() throws {
        #expect(AccountManager.isTransientSendError(SMTPError.connectionFailed("reset")) == true)
        #expect(AccountManager.isTransientSendError(SMTPError.tlsFailed("Server rejected STARTTLS")) == true)
        #expect(AccountManager.isTransientSendError(SMTPError.sendFailed("write failed")) == true)
    }

    /// Rendering guard: the user-facing sentence must never acquire a word the
    /// legacy substring heuristic in `isTransientSendError` treats as transient —
    /// that would requeue the row forever and re-open the defect through the copy
    /// rather than through the code.
    @Test("The user-facing sentence cannot be read back as a transient connection error")
    func messageDoesNotTripTheTransientHeuristic() throws {
        let text = String(describing: IMAPTransportSecurityError.tlsFloorNotMet(host: "mail.example.com"))
        #expect(!text.contains("connection"))
        #expect(!text.contains("Connection"))
        #expect(!text.contains("timeout"))
    }
}
