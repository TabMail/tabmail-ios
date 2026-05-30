/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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

    func put(url: URL, body: String, etag: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        setAuthHeader(&request)
        request.httpBody = body.data(using: .utf8)
        // CalDAV servers reject PUT with opaque 403/412/etc. and no body —
        // log the ICS we're sending so we can diagnose without smoke-testing
        // the iCloud sandbox blind.
        print("[CalDAV] PUT \(url.path) etag=\(etag ?? "nil") body=\(body.prefix(4000))")
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
