/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ContactResult")
struct ContactResultTests {

    @Test("displayString with name shows Name <email>")
    func displayStringWithName() {
        let contact = ContactResult(name: "Alice", email: "alice@test.com")
        #expect(contact.displayString == "Alice <alice@test.com>")
    }

    @Test("displayString without name shows just email")
    func displayStringWithoutName() {
        let contact = ContactResult(name: "", email: "alice@test.com")
        #expect(contact.displayString == "alice@test.com")
    }

    @Test("id is email")
    func idIsEmail() {
        let contact = ContactResult(name: "Alice", email: "alice@test.com")
        #expect(contact.id == "alice@test.com")
    }
}
