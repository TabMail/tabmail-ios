/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Graph refuses a write to a mailbox over its storage quota with 403 and the error code
/// `ErrorQuotaExceeded`, the status it also gives a missing permission; only the body's code tells
/// them apart (#865). Graph's error resource nests further codes under `innerError`.
@Suite("Graph tells a full mailbox from a missing permission by its error code")
struct GraphAPIMailboxFullTests {
    private static func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("the outer code and every nested innerError code are read, outermost first")
    func readsEveryCode() {
        let nested = Self.body(#"{"error":{"code":"Forbidden","message":"m","innerError":{"code":"ErrorQuotaExceeded","innerError":{"code":"Deeper"}}}}"#)
        #expect(GraphAPI.errorCodes(nested) == ["Forbidden", "ErrorQuotaExceeded", "Deeper"])
        #expect(GraphAPI.errorCodes(Self.body(#"{"error":{"message":"no code"}}"#)).isEmpty)
        #expect(GraphAPI.errorCodes(Self.body("not json")).isEmpty)
        #expect(GraphAPI.errorCodes(nil).isEmpty)
    }

    @Test("a 403 naming ErrorQuotaExceeded, outer or nested, is a full mailbox; another code or status is not")
    func mailboxFull() {
        let outer = Self.body(#"{"error":{"code":"ErrorQuotaExceeded","message":"The mailbox is over its quota."}}"#)
        let nested = Self.body(#"{"error":{"code":"Forbidden","innerError":{"code":"ErrorQuotaExceeded"}}}"#)
        let other = Self.body(#"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#)
        #expect(GraphAPI.isMailboxFull(statusCode: 403, errorBody: outer))
        #expect(GraphAPI.isMailboxFull(statusCode: 403, errorBody: nested))
        #expect(!GraphAPI.isMailboxFull(statusCode: 403, errorBody: other))
        #expect(!GraphAPI.isMailboxFull(statusCode: 403, errorBody: nil))
        #expect(!GraphAPI.isMailboxFull(statusCode: 400, errorBody: outer))
    }
}
