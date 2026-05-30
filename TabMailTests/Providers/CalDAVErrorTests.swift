/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CalDAVError")
struct CalDAVErrorTests {

    @Test("authFailed is an Error")
    func authFailed() {
        let error: Error = CalDAVError.authFailed
        #expect(error is CalDAVError)
    }

    @Test("httpError carries status code")
    func httpError() {
        let error = CalDAVError.httpError(404, nil)
        if case .httpError(let code, _) = error {
            #expect(code == 404)
        } else {
            #expect(Bool(false), "Expected httpError case")
        }
    }

    @Test("httpError carries response data")
    func httpErrorWithData() {
        let data = Data("Not Found".utf8)
        let error = CalDAVError.httpError(404, data)
        if case .httpError(_, let responseData) = error {
            #expect(responseData == data)
        }
    }

    @Test("notFound is distinct from httpError")
    func notFound() {
        if case .notFound = CalDAVError.notFound {
            // pass
        } else {
            #expect(Bool(false), "Expected notFound case")
        }
    }

    @Test("preconditionFailed for etag conflicts")
    func preconditionFailed() {
        if case .preconditionFailed = CalDAVError.preconditionFailed {
            // pass
        } else {
            #expect(Bool(false), "Expected preconditionFailed case")
        }
    }

    @Test("discoveryFailed carries message")
    func discoveryFailed() {
        let error = CalDAVError.discoveryFailed("No principal URL found")
        if case .discoveryFailed(let msg) = error {
            #expect(msg == "No principal URL found")
        }
    }

    @Test("parseError carries message")
    func parseError() {
        let error = CalDAVError.parseError("Invalid XML")
        if case .parseError(let msg) = error {
            #expect(msg == "Invalid XML")
        }
    }

    @Test("noWritableCalendar")
    func noWritableCalendar() {
        if case .noWritableCalendar = CalDAVError.noWritableCalendar {
            // pass
        } else {
            #expect(Bool(false), "Expected noWritableCalendar case")
        }
    }
}
