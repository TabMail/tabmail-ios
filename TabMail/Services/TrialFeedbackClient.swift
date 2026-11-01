/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum TrialFeedbackConfig {
    static let version = "trial-v1"
    #if DEBUG
    static let endpoint = URL(string: "https://usage-dev.tabmail.ai/feedback/trial")!
    #else
    static let endpoint = URL(string: "https://usage.tabmail.ai/feedback/trial")!
    #endif
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 20
    static let userAgent = "TabMail Feedback"
}

/// No bearer token, shared API client, cookie jar, credentials, redirect or retry.
struct TrialFeedbackClient: TrialFeedbackSubmitting {
    typealias ConfigureSession = @Sendable (URLSessionConfiguration) -> Void
    private let configureSession: ConfigureSession

    init(configureSession: @escaping ConfigureSession = { _ in }) {
        self.configureSession = configureSession
    }

    enum DeliveryError: Error { case unconfirmed }

    private struct Payload: Encodable {
        let questionnaire_version: String
        let reason: String
    }

    func submit(reason: TrialFeedbackReason) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = TrialFeedbackConfig.requestTimeout
        config.timeoutIntervalForResource = TrialFeedbackConfig.resourceTimeout
        config.httpAdditionalHeaders = [:]
        configureSession(config)
        let session = URLSession(configuration: config, delegate: TrialFeedbackSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: TrialFeedbackConfig.endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // Fixed transport defaults prevent CFNetwork's app/version and language
        // defaults from introducing those dimensions into the feedback request.
        request.setValue(TrialFeedbackConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONEncoder().encode(Payload(questionnaire_version: TrialFeedbackConfig.version, reason: reason.rawValue))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else { throw DeliveryError.unconfirmed }
    }
}

/// A feedback request can validate server trust but must never use a user's
/// stored credentials or forward its answer to another destination.
final class TrialFeedbackSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
