/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Synchronization
import Testing
@testable import TabMail

/// A send already past `send(draft:)`'s entry check when its account is
/// removed must not authenticate or submit: the account's credentials and
/// mail stop at removal.
@Suite("IMAP send stops at account removal", .serialized)
struct IMAPSendAfterAccountRemovalTests {
    /// The SMTP step a test session waits in until the test releases it.
    enum HeldStep: String { case connect, authenticate }

    /// SMTP double whose `held` step waits until the test releases it.
    final class HeldConnectSession: SMTPSubmissionSession {
        let events = Mutex<[String]>([])
        let held: HeldStep
        private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let released = Mutex(false)
        let reachedHeldStep: AsyncStream<Void>
        private let reachedContinuation: AsyncStream<Void>.Continuation

        init(held: HeldStep = .connect) {
            self.held = held
            (reachedHeldStep, reachedContinuation) = AsyncStream<Void>.makeStream()
        }

        private func waitIfHeld(_ step: HeldStep) async {
            guard step == held else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = released.withLock { isReleased in
                    if isReleased { return true }
                    gate.withLock { $0 = c }
                    return false
                }
                reachedContinuation.yield()
                if resumeNow { c.resume() }
            }
        }

        func openConnection() async throws {
            events.withLock { $0.append("connect") }
            await waitIfHeld(.connect)
        }

        func release() {
            let waiting = released.withLock { isReleased in
                isReleased = true
                return gate.withLock { g in let v = g; g = nil; return v }
            }
            waiting?.resume()
        }

        func authenticate(username: String, password: String) async throws {
            events.withLock { $0.append("authenticate") }
            await waitIfHeld(.authenticate)
        }

        func submit(_ email: Email) async throws {
            events.withLock { $0.append("submit") }
        }

        func close() async throws {
            events.withLock { $0.append("close") }
        }
    }

    private static func provider() -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: 1, username: "user@example.com", password: "password",
            senderEmail: "user@example.com", smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private static let draft = DraftMessage(
        to: ["recipient@example.com"], subject: "subject", body: "body")

    /// Runs one send held inside `step`; `removeAccount` decides whether the
    /// account is removed before that step is released.
    private static func sendHeld(in step: HeldStep, removeAccount: Bool) async -> (Result<Void, Error>, [String]) {
        let provider = provider()
        let session = HeldConnectSession(held: step)
        provider.setSMTPSessionFactoryForTesting { session }
        let send = Task { _ = try await provider.send(draft: draft) }
        var iterator = session.reachedHeldStep.makeAsyncIterator()
        _ = await iterator.next()
        if removeAccount { await provider.disconnectForAccountRemoval() }
        session.release()
        let result = await send.result
        return (result, session.events.withLock { $0 })
    }

    @Test("A send held in SMTP connect while its account is removed neither authenticates nor submits, and closes the connection")
    func sendHeldInConnectStopsAtAccountRemoval() async {
        let (result, events) = await Self.sendHeld(in: .connect, removeAccount: true)
        #expect(!events.contains("authenticate"), "a removed account authenticated: \(events)")
        #expect(!events.contains("submit"), "a removed account's mail was submitted: \(events)")
        #expect(events.last == "close", "the SMTP connection was left open: \(events)")
        guard case .failure(let error) = result else {
            Issue.record("the send reported success after account removal")
            return
        }
        guard case ProviderError.notConnected = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }

    @Test("Control: a send held in SMTP connect with its account intact authenticates and submits")
    func sendHeldInConnectSendsForALiveAccount() async {
        let (result, events) = await Self.sendHeld(in: .connect, removeAccount: false)
        #expect(events == ["connect", "authenticate", "submit", "close"], "unexpected SMTP steps: \(events)")
        if case .failure(let error) = result { Issue.record("the live send failed: \(error)") }
    }

    @Test("A send held in SMTP authentication while its account is removed authenticates once, never submits, and closes the connection")
    func sendHeldInAuthenticationStopsAtAccountRemoval() async {
        let (result, events) = await Self.sendHeld(in: .authenticate, removeAccount: true)
        #expect(events.contains("authenticate"), "the send never reached authentication: \(events)")
        #expect(!events.contains("submit"), "a removed account's mail was submitted: \(events)")
        #expect(events.last == "close", "the SMTP connection was left open: \(events)")
        guard case .failure(let error) = result else {
            Issue.record("the send reported success after account removal")
            return
        }
        guard case ProviderError.notConnected = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }

    @Test("Control: a send held in SMTP authentication with its account intact submits")
    func sendHeldInAuthenticationSendsForALiveAccount() async {
        let (result, events) = await Self.sendHeld(in: .authenticate, removeAccount: false)
        #expect(events == ["connect", "authenticate", "submit", "close"], "unexpected SMTP steps: \(events)")
        if case .failure(let error) = result { Issue.record("the live send failed: \(error)") }
    }
}
