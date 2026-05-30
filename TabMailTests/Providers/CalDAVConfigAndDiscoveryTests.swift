/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CalDAVConfig Codable and Properties")
struct CalDAVConfigCodableTests {

    @Test("databaseTableName is caldavConfig")
    func tableName() {
        #expect(CalDAVConfig.databaseTableName == "caldavConfig")
    }

    @Test("init generates valid UUID string")
    func validUUID() {
        let config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice"
        )
        #expect(UUID(uuidString: config.id) != nil)
    }

    @Test("createdAt is set to approximately now")
    func createdAtIsRecent() {
        let before = Date()
        let config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice"
        )
        let after = Date()
        #expect(config.createdAt >= before)
        #expect(config.createdAt <= after)
    }

    @Test("Codable round-trip preserves all values")
    func codableRoundTrip() throws {
        var config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice",
            displayName: "Alice"
        )
        config.principalURL = "https://caldav.example.com/principals/alice"
        config.calendarHomeURL = "https://caldav.example.com/calendars/alice"
        config.needsReauth = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CalDAVConfig.self, from: data)

        #expect(decoded.id == config.id)
        #expect(decoded.accountId == config.accountId)
        #expect(decoded.serverURL == config.serverURL)
        #expect(decoded.principalURL == config.principalURL)
        #expect(decoded.calendarHomeURL == config.calendarHomeURL)
        #expect(decoded.username == config.username)
        #expect(decoded.displayName == config.displayName)
        #expect(decoded.needsReauth == config.needsReauth)
        #expect(abs(decoded.createdAt.timeIntervalSince(config.createdAt)) < 1.0)
    }

    @Test("Codable round-trip preserves nil optionals")
    func codableRoundTripNils() throws {
        let config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CalDAVConfig.self, from: data)

        #expect(decoded.principalURL == nil)
        #expect(decoded.calendarHomeURL == nil)
        #expect(decoded.displayName == nil)
    }

    @Test("mutable properties can be updated")
    func mutableProperties() {
        var config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice"
        )
        config.principalURL = "/principals/alice"
        config.calendarHomeURL = "/calendars/alice"
        config.needsReauth = true
        config.displayName = "Updated"

        #expect(config.principalURL == "/principals/alice")
        #expect(config.calendarHomeURL == "/calendars/alice")
        #expect(config.needsReauth == true)
        #expect(config.displayName == "Updated")
    }

    @Test("Identifiable id matches stored id")
    func identifiable() {
        let config = CalDAVConfig(
            accountId: "acc-1",
            serverURL: "https://caldav.example.com",
            username: "alice"
        )
        // Identifiable conformance: id property is the same as the stored id
        let identifiableId: String = config.id
        #expect(!identifiableId.isEmpty)
    }
}

@Suite("CalDAVDiscovery.DiscoveryResult")
struct CalDAVDiscoveryResultTests {

    @Test("DiscoveryResult stores principal and calendar home URLs")
    func storesURLs() {
        let principal = URL(string: "https://caldav.example.com/principals/alice")!
        let home = URL(string: "https://caldav.example.com/calendars/alice")!
        let result = CalDAVDiscovery.DiscoveryResult(
            principalURL: principal,
            calendarHomeURL: home
        )
        #expect(result.principalURL == principal)
        #expect(result.calendarHomeURL == home)
    }

    @Test("DiscoveryResult works with resolved relative URLs")
    func relativeURLs() {
        let base = URL(string: "https://caldav.example.com")!
        let principal = URL(string: "/principals/alice", relativeTo: base)!.absoluteURL
        let home = URL(string: "/calendars/alice", relativeTo: base)!.absoluteURL
        let result = CalDAVDiscovery.DiscoveryResult(
            principalURL: principal,
            calendarHomeURL: home
        )
        #expect(result.principalURL.absoluteString == "https://caldav.example.com/principals/alice")
        #expect(result.calendarHomeURL.absoluteString == "https://caldav.example.com/calendars/alice")
    }
}

@Suite("CalDAVError additional pattern tests")
struct CalDAVErrorPatternTests {

    @Test("all seven cases conform to Error")
    func allCasesConformToError() {
        let cases: [Error] = [
            CalDAVError.authFailed,
            CalDAVError.httpError(401, nil),
            CalDAVError.notFound,
            CalDAVError.preconditionFailed,
            CalDAVError.discoveryFailed("test"),
            CalDAVError.parseError("test"),
            CalDAVError.noWritableCalendar,
        ]
        #expect(cases.count == 7)
        for error in cases {
            #expect(error is CalDAVError)
        }
    }

    @Test("httpError nil data vs non-nil data")
    func httpErrorDataVariants() {
        let withNil = CalDAVError.httpError(500, nil)
        let withData = CalDAVError.httpError(500, Data("error".utf8))

        if case .httpError(let code1, let data1) = withNil {
            #expect(code1 == 500)
            #expect(data1 == nil)
        } else {
            #expect(Bool(false), "Expected httpError")
        }
        if case .httpError(let code2, let data2) = withData {
            #expect(code2 == 500)
            #expect(data2 != nil)
            #expect(String(data: data2!, encoding: .utf8) == "error")
        } else {
            #expect(Bool(false), "Expected httpError")
        }
    }

    @Test("discoveryFailed preserves detailed message")
    func discoveryFailedDetailedMessage() {
        let msg = "No current-user-principal found in PROPFIND response"
        let error = CalDAVError.discoveryFailed(msg)
        if case .discoveryFailed(let extracted) = error {
            #expect(extracted == msg)
        } else {
            #expect(Bool(false), "Expected discoveryFailed")
        }
    }

    @Test("parseError preserves detailed message")
    func parseErrorDetailedMessage() {
        let msg = "Unexpected XML element at line 42"
        let error = CalDAVError.parseError(msg)
        if case .parseError(let extracted) = error {
            #expect(extracted == msg)
        } else {
            #expect(Bool(false), "Expected parseError")
        }
    }

    @Test("httpError carries various status codes")
    func httpErrorStatusCodes() {
        let codes = [400, 401, 403, 404, 500, 502, 503]
        for code in codes {
            let error = CalDAVError.httpError(code, nil)
            if case .httpError(let extracted, _) = error {
                #expect(extracted == code)
            } else {
                #expect(Bool(false), "Expected httpError for code \(code)")
            }
        }
    }
}
