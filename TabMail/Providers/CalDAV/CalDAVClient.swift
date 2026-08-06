/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The conditional-request precondition a CalDAV `PUT` carries.
///
/// THREE states, deliberately, because "I have no ETag for this resource" and
/// "this resource must not already exist" are different requests and collapsing
/// them into one optional made a rollback structurally impossible: a revert PUT
/// that meant *overwrite what we just wrote* was sent as assert-absence and so a
/// compliant server answered 412 every single time. An enum makes the illegal
/// combination unrepresentable and forces every call site to say which it means.
enum CalDAVPutPrecondition: Equatable, Sendable {
    /// `If-Match: <etag>` — replace only while the resource still matches.
    case ifMatch(String)
    /// `If-None-Match: *` — CREATE ONLY. RFC 4918 §10.4.2: a compliant server
    /// answers 412 when the resource already exists.
    case ifNoneMatchAny
    /// Neither header — overwrite whatever is currently at the URL. Used where
    /// we are restoring a body we ourselves just replaced.
    case unconditional
}

/// Low-level HTTP client for CalDAV (WebDAV + CalDAV extensions).
/// Handles PROPFIND, REPORT, PUT, DELETE with Basic auth and correct headers.
actor CalDAVClient {
    private let session: URLSession
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
        // URLSession that follows redirects (iCloud redirects to pXX-caldav.icloud.com)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Explicit-session initializer, used by tests to route this client's
    /// requests through a `URLProtocol` fake. Deliberately a SEPARATE
    /// initializer rather than a defaulted parameter on the one above: a
    /// dropped injection must be a compile error, never a silent escape to the
    /// live network.
    init(username: String, password: String, session: URLSession) {
        self.username = username
        self.password = password
        self.session = session
    }

    // MARK: - CalDAV Methods

    func propfind(url: URL, body: String, depth: Int) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        setCommonHeaders(&request, xmlBody: body)
        return try await perform(request)
    }

    func report(url: URL, body: String, depth: Int = 1) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "REPORT"
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        setCommonHeaders(&request, xmlBody: body)
        return try await perform(request)
    }

    func get(url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        return try await perform(request)
    }

    func put(
        url: URL, body: String, precondition: CalDAVPutPrecondition
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .ifMatch(let etag):
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        case .ifNoneMatchAny:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .unconditional:
            break // neither header — see CalDAVPutPrecondition.unconditional
        }
        setAuthHeader(&request)
        request.httpBody = body.data(using: .utf8)
        // CalDAV servers reject PUT with opaque 403/412/etc. and no body —
        // log the ICS we're sending so we can diagnose without smoke-testing
        // the iCloud sandbox blind.
        print("[CalDAV] PUT \(url.path) precondition=\(precondition) body=\(body.prefix(4000))")
        return try await perform(request)
    }

    func delete(url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        setAuthHeader(&request)
        return try await perform(request)
    }

    // MARK: - Private

    private func setCommonHeaders(_ request: inout URLRequest, xmlBody: String) {
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeader(&request)
        request.httpBody = xmlBody.data(using: .utf8)
    }

    private func setAuthHeader(_ request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        if let data = credentials.data(using: .utf8) {
            let base64 = data.base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.httpError(0, nil)
        }

        let code = httpResponse.statusCode
        if code == 401 {
            print("[CalDAV] 401 Unauthorized for \(request.url?.absoluteString ?? "")")
            throw CalDAVError.authFailed
        }
        if code == 404 {
            throw CalDAVError.notFound
        }
        if code == 412 {
            throw CalDAVError.preconditionFailed
        }

        // For non-success codes that aren't specifically handled
        if !(200...299).contains(code) && code != 207 {
            if let body = String(data: data, encoding: .utf8) {
                print("[CalDAV] HTTP \(code) \(request.httpMethod ?? "") \(request.url?.absoluteString ?? ""): \(body.prefix(500))")
            }
            throw CalDAVError.httpError(code, data)
        }

        return (data, httpResponse)
    }
}
