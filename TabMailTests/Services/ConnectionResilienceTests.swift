/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Direct pins for the production error classifiers used by sync and queue draining.
/// The former reconnect/drain/backfill simulations in this file hand-copied control
/// flow or tested `MockEmailProvider` itself, so they could stay green while production
/// changed. End-to-end queue behavior lives in `AccountManagerQueueDrainTests`.
@Suite("Connection Resilience - Error Classification")
struct ErrorClassificationTests {

    // MARK: - isConnectionError

    @Test("isConnectionError recognizes ProviderError.notConnected")
    func connectionErrorNotConnected() {
        #expect(SyncEngine.isConnectionError(ProviderError.notConnected))
    }

    @Test("isConnectionError recognizes URL transport errors")
    func connectionErrorURLError() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
        ]
        for code in codes {
            #expect(SyncEngine.isConnectionError(URLError(code)))
        }
    }

    @Test("isConnectionError recognizes connection reset text")
    func connectionErrorConnectionReset() {
        let error = NSError(
            domain: "POSIX", code: 54,
            userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes broken pipe")
    func connectionErrorBrokenPipe() {
        let error = NSError(
            domain: "POSIX", code: 32,
            userInfo: [NSLocalizedDescriptionKey: "broken pipe"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes closed-channel text")
    func connectionErrorClosedChannel() {
        let closed = NSError(
            domain: "NIO", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "closed channel"]
        )
        let ioOnClosed = NSError(
            domain: "NIO", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "I/O on closed channel"]
        )
        #expect(SyncEngine.isConnectionError(closed))
        #expect(SyncEngine.isConnectionError(ioOnClosed))
    }

    @Test("isConnectionError recognizes timeout text")
    func connectionErrorTimedOut() {
        let error = NSError(
            domain: "IMAP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation timed out"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes IMAP decoder failures")
    func connectionErrorIMAPDecoder() {
        let error = NSError(
            domain: "IMAP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "IMAPDecoderError: leftover bytes"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes connection-lost command failures")
    func connectionErrorCommandFailed() {
        let error = NSError(
            domain: "IMAP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "command failed: connection lost"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes EPIPE")
    func connectionErrorEPIPE() {
        let error = NSError(
            domain: "POSIX", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "EPIPE: write failed"]
        )
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError rejects message-not-found")
    func connectionErrorRejectsMessageNotFound() {
        #expect(!SyncEngine.isConnectionError(ProviderError.messageNotFound))
    }

    @Test("isConnectionError rejects authentication failure")
    func connectionErrorRejectsAuthFailed() {
        #expect(!SyncEngine.isConnectionError(ProviderError.authenticationFailed))
    }

    @Test("isConnectionError rejects generic errors")
    func connectionErrorRejectsGenericNSError() {
        let error = NSError(
            domain: "example.com", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )
        #expect(!SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError rejects HTTP ProviderError.networkError")
    func connectionErrorRejectsNetworkError() {
        let error = NSError(
            domain: "HTTP", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Internal Server Error"]
        )
        #expect(!SyncEngine.isConnectionError(ProviderError.networkError(underlying: error)))
    }

    // MARK: - isSelectFailedError

    @Test("isSelectFailedError recognizes mailbox selection failure")
    func selectFailedRecognized() {
        let error = NSError(
            domain: "IMAP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Select mailbox failed for folder 'Missing'"]
        )
        #expect(SyncEngine.isSelectFailedError(error))
    }

    @Test("isSelectFailedError rejects connection errors")
    func selectFailedRejectsConnectionError() {
        #expect(!SyncEngine.isSelectFailedError(ProviderError.notConnected))
    }

    @Test("isSelectFailedError rejects generic errors")
    func selectFailedRejectsGeneric() {
        let error = NSError(
            domain: "IMAP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Authentication failed"]
        )
        #expect(!SyncEngine.isSelectFailedError(error))
    }

}
