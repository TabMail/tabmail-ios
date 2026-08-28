/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Push client unregister URL encoding")
struct PushClientURLTests {
    private let baseURL = URL(string: "https://push.example.com")!

    @Test("A literal plus round-trips through form-style server decoding")
    func literalPlusRoundTrips() {
        let accountEmail = "a+b@example.com"
        let url = PushClient.unregisterDeviceAccountURL(
            baseURL: baseURL,
            deviceId: "device-1",
            accountEmail: accountEmail)

        #expect(formDecodedValue(named: "accountEmail", from: url) == accountEmail)
        #expect(percentEncodedQuery(of: url).contains("accountEmail=a%2Bb@example.com"))
    }

    @Test("A literal space stays distinct from a literal plus")
    func literalSpaceStaysDistinct() {
        let plusURL = PushClient.unregisterDeviceAccountURL(
            baseURL: baseURL,
            deviceId: "device-1",
            accountEmail: "a+b@example.com")
        let spaceURL = PushClient.unregisterDeviceAccountURL(
            baseURL: baseURL,
            deviceId: "device-1",
            accountEmail: "a b@example.com")

        #expect(plusURL != spaceURL)
        #expect(formDecodedValue(named: "accountEmail", from: plusURL) == "a+b@example.com")
        #expect(formDecodedValue(named: "accountEmail", from: spaceURL) == "a b@example.com")
    }

    @Test("A plain address keeps its existing query representation")
    func plainAddressIsUnchanged() {
        let url = PushClient.unregisterDeviceAccountURL(
            baseURL: baseURL,
            deviceId: "device-1",
            accountEmail: "plain@example.com")

        #expect(percentEncodedQuery(of: url) == "deviceId=device-1&accountEmail=plain@example.com")
        #expect(formDecodedValue(named: "accountEmail", from: url) == "plain@example.com")
    }

    private func percentEncodedQuery(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    /// Mirrors the worker's standard application/x-www-form-urlencoded decoding:
    /// bare `+` becomes a space before percent escapes are decoded.
    private func formDecodedValue(named name: String, from url: URL) -> String? {
        let query = percentEncodedQuery(of: url)
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let decodedName = String(pair[0])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            guard decodedName == name else { continue }
            return String(pair[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
        }
        return nil
    }
}
