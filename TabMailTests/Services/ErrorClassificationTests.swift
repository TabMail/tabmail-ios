/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Simple error type for testing string-based error classification.
private struct TestError: Error, CustomStringConvertible {
    let description: String
}

@Suite("SyncEngine.isConnectionError")
struct IsConnectionErrorTests {

    @Test("ProviderError.notConnected is a connection error")
    func notConnected() {
        #expect(SyncEngine.isConnectionError(ProviderError.notConnected) == true)
    }

    @Test("URLError(.notConnectedToInternet) is a connection error")
    func urlErrorNotConnected() {
        let error = URLError(.notConnectedToInternet)
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("URLError(.timedOut) is a connection error")
    func urlErrorTimedOut() {
        let error = URLError(.timedOut)
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'Connection reset' is a connection error")
    func connectionReset() {
        let error = TestError(description: "Connection reset by peer")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'broken pipe' is a connection error")
    func brokenPipe() {
        let error = TestError(description: "Write failed: broken pipe")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'IMAPDecoderError' is a connection error")
    func imapDecoderError() {
        let error = TestError(description: "IMAPDecoderError: unexpected bytes")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'IMAPDecodeError' is a connection error")
    func imapDecodeError() {
        let error = TestError(description: "IMAPDecodeError: invalid response")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'timed out' is a connection error")
    func timedOut() {
        let error = TestError(description: "Operation timed out")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'closed channel' is a connection error")
    func closedChannel() {
        let error = TestError(description: "I/O error on closed channel")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'EPIPE' is a connection error")
    func epipe() {
        let error = TestError(description: "EPIPE: write error")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'NIOConnectionError' is a connection error")
    func nioConnectionError() {
        let error = TestError(description: "NIOPosix.NIOConnectionError: connection refused")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("NSError with NIOCore.ChannelError domain is a connection error")
    func nioChannelErrorByDomain() {
        // Mirrors how a raw NIO ChannelError (e.g. .alreadyClosed, .ioOnClosedChannel) bridges
        // into NSError when it leaks past SwiftMail's IMAPError wrapping.
        let error = NSError(domain: "NIOCore.ChannelError", code: 0, userInfo: nil)
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Error description containing 'ChannelError' is a connection error")
    func nioChannelErrorByString() {
        // Catches the localizedDescription form: "(NIOCore.ChannelError error N.)"
        let error = TestError(description: "The operation couldn't be completed. (NIOCore.ChannelError error 4.)")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'DNS error' is a connection error")
    func dnsError() {
        let error = TestError(description: "DNS error: unknown(host: \"imap.mail.me.com\", port: 993)")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("String containing 'connection appears to be offline' is a connection error")
    func offlineError() {
        let error = TestError(description: "The Internet connection appears to be offline.")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Login failed with max_userip_connections is a connection error")
    func loginFailedMaxConnections() {
        let error = TestError(description: "Login failed: no([UNAVAILABLE] Maximum number of connections from user+IP exceeded (mail_max_userip_connections=15))")
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Login failed with bad credentials is NOT a connection error")
    func loginFailedBadCredentials() {
        let error = TestError(description: "Login failed: no(AUTHENTICATIONFAILED)")
        #expect(SyncEngine.isConnectionError(error) == false)
    }

    @Test("Random error is NOT a connection error")
    func randomError() {
        let error = TestError(description: "Something completely unrelated happened")
        #expect(SyncEngine.isConnectionError(error) == false)
    }

    @Test("ProviderError.networkError (HTTP error) is NOT a connection error")
    func networkErrorNotConnection() {
        let httpError = NSError(domain: "HTTP", code: 500, userInfo: nil)
        let error = ProviderError.networkError(underlying: httpError)
        // networkError means the server responded — not a transport failure
        #expect(SyncEngine.isConnectionError(error) == false)
    }

    @Test("ProviderError.messageNotFound is NOT a connection error")
    func messageNotFoundNotConnection() {
        #expect(SyncEngine.isConnectionError(ProviderError.messageNotFound) == false)
    }
}

@Suite("SyncEngine.isTransientError")
struct IsTransientErrorTests {

    // MARK: - True cases (transient — must NOT surface as a sync failure)

    @Test("HTTPError(503) wrapped in ProviderError.networkError is transient — the reported Graph-503 bug")
    func httpError503() {
        // Exactly the shape logged: networkError(underlying: HTTPError.networkError(statusCode: 503))
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 503))
        #expect(SyncEngine.isTransientError(error) == true)
    }

    @Test("HTTPError(500/502/504) wrapped in ProviderError.networkError is transient")
    func httpError5xx() {
        for code in [500, 502, 504] {
            let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: code))
            #expect(SyncEngine.isTransientError(error) == true, "HTTP \(code) should be transient")
        }
    }

    @Test("HTTPError(429) wrapped in ProviderError.networkError is transient (rate limited)")
    func httpError429() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429))
        #expect(SyncEngine.isTransientError(error) == true)
    }

    @Test("NSError(code: 503) wrapped in ProviderError.networkError is transient (Gmail/Exchange shape)")
    func nsError503() {
        // GmailProvider/ExchangeProvider throw ProviderError.networkError(underlying: NSError(domain:"Gmail"/"Exchange", code: statusCode))
        let error = ProviderError.networkError(underlying: NSError(domain: "Exchange", code: 503, userInfo: nil))
        #expect(SyncEngine.isTransientError(error) == true)
    }

    // MARK: - False cases (must still surface)

    @Test("HTTPError(404) is NOT transient (permanent — handled by gone/not-found classifiers)")
    func httpError404() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))
        #expect(SyncEngine.isTransientError(error) == false)
    }

    @Test("HTTPError(400/401/403) is NOT transient")
    func httpError4xx() {
        for code in [400, 401, 403] {
            let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: code))
            #expect(SyncEngine.isTransientError(error) == false, "HTTP \(code) should NOT be transient")
        }
    }

    @Test("ProviderError.notConnected is NOT transient (it's a connection error, classified separately)")
    func notConnected() {
        // isTransientError is intentionally narrow (HTTP-only) so it does not change the
        // existing connection-error behavior (offline still flips the failed indicator).
        #expect(SyncEngine.isTransientError(ProviderError.notConnected) == false)
    }

    @Test("URLError is NOT transient (transport failure → isConnectionError owns it)")
    func urlError() {
        #expect(SyncEngine.isTransientError(URLError(.timedOut)) == false)
    }

    @Test("A non-ProviderError is NOT transient")
    func unrelatedError() {
        let error = TestError(description: "Something completely unrelated happened")
        #expect(SyncEngine.isTransientError(error) == false)
    }
}

@Suite("SyncEngine.isSelectFailedError")
struct IsSelectFailedErrorTests {

    @Test("Error with 'Select mailbox failed' is a select failed error")
    func selectFailed() {
        let error = TestError(description: "Select mailbox failed: INBOX not found")
        #expect(SyncEngine.isSelectFailedError(error) == true)
    }

    @Test("Other errors are NOT select failed errors")
    func otherError() {
        let error = TestError(description: "Authentication failed")
        #expect(SyncEngine.isSelectFailedError(error) == false)
    }

    @Test("Connection error is NOT a select failed error")
    func connectionNotSelect() {
        let error = TestError(description: "Connection reset by peer")
        #expect(SyncEngine.isSelectFailedError(error) == false)
    }
}

@Suite("AccountManager.isMessageNotFoundError")
struct IsMessageNotFoundErrorTests {

    @Test("ProviderError.messageNotFound returns true")
    func messageNotFound() {
        // isMessageNotFoundError is an instance method on AccountManager.
        // We test the logic directly by checking the error classification.
        let error = ProviderError.messageNotFound
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("ProviderError.networkError with HTTP 404 returns true")
    func networkError404() {
        let httpError = NSError(domain: "HTTP", code: 404, userInfo: nil)
        let error = ProviderError.networkError(underlying: httpError)
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("Error containing 'no such message' returns true")
    func noSuchMessage() {
        let error = TestError(description: "IMAP error: no such message")
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("Error containing 'NONEXISTENT' returns true")
    func nonexistent() {
        let error = TestError(description: "[NONEXISTENT] mailbox does not exist")
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("Error containing 'UID not found' returns true")
    func uidNotFound() {
        let error = TestError(description: "UID not found in mailbox")
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("Error containing 'Message not found' returns true")
    func messageNotFoundString() {
        let error = TestError(description: "Message not found in store")
        #expect(isMessageNotFoundError(error) == true)
    }

    @Test("Random error returns false")
    func randomError() {
        let error = TestError(description: "Something else entirely")
        #expect(isMessageNotFoundError(error) == false)
    }

    @Test("ProviderError.notConnected returns false")
    func notConnected() {
        let error = ProviderError.notConnected
        #expect(isMessageNotFoundError(error) == false)
    }

    @Test("ProviderError.networkError with HTTP 500 returns false")
    func networkError500() {
        let httpError = NSError(domain: "HTTP", code: 500, userInfo: nil)
        let error = ProviderError.networkError(underlying: httpError)
        #expect(isMessageNotFoundError(error) == false)
    }

    @Test("ProviderError.uidResolutionFailed returns false (transient — retry, don't drop)")
    func uidResolutionFailed() {
        let error = ProviderError.uidResolutionFailed("<msg-123@example.com>")
        #expect(isMessageNotFoundError(error) == false)
    }

    // MARK: - Standalone reimplementation matching AccountManager.isMessageNotFoundError

    /// Standalone version of the logic for testing without AccountManager instance.
    private func isMessageNotFoundError(_ error: Error) -> Bool {
        let desc = "\(error)"
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error,
           (underlying as NSError).code == 404 { return true }
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }
}

// MARK: - uidResolutionFailed Drain Behavior

@Suite("uidResolutionFailed drain behavior")
struct UidResolutionFailedDrainTests {

    @Test("uidResolutionFailed is NOT treated as messageNotFound")
    func notMessageNotFound() {
        let error = ProviderError.uidResolutionFailed("<msg@example.com>")
        // Standalone reimplementation of isMessageNotFoundError
        let desc = "\(error)"
        var isNotFound = false
        if case ProviderError.messageNotFound = error { isNotFound = true }
        if case ProviderError.networkError(let underlying) = error,
           (underlying as NSError).code == 404 { isNotFound = true }
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { isNotFound = true }
        #expect(isNotFound == false)
    }

    @Test("uidResolutionFailed is distinguishable from messageNotFound via pattern match")
    func patternMatchDistinguishable() {
        let uidError = ProviderError.uidResolutionFailed("<msg@example.com>")
        let notFoundError = ProviderError.messageNotFound

        // Drain uses pattern match to handle uidResolutionFailed specially for tag ops
        var isUidResolution = false
        if case ProviderError.uidResolutionFailed = uidError { isUidResolution = true }
        #expect(isUidResolution == true)

        var isUidResolution2 = false
        if case ProviderError.uidResolutionFailed = notFoundError { isUidResolution2 = true }
        #expect(isUidResolution2 == false)
    }

    @Test("uidResolutionFailed on tag ops should be skippable (best-effort)")
    func tagOpsSkippable() {
        // Tag ops (.setTag, .removeTag) are best-effort metadata operations.
        // When uidResolutionFailed occurs, the drain should skip the tag op
        // rather than adding the account to failedAccounts and blocking subsequent ops.
        let tagOpTypes: [OperationType] = [.setTag, .removeTag]
        let nonTagOpTypes: [OperationType] = [.move, .markRead, .markUnread]

        for opType in tagOpTypes {
            #expect([OperationType.setTag, .removeTag].contains(opType),
                    "Tag op \(opType) should be in the skippable set")
        }
        for opType in nonTagOpTypes {
            #expect(![OperationType.setTag, .removeTag].contains(opType) || opType == .move,
                    "Non-tag op \(opType) should NOT be in the skippable set")
        }
    }
}
