/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Restricted mail action controls", .serialized, .processGlobalState)
struct RestrictedMailActionButtonTests {
    @Test("A restricted action cannot present a picker or hide a row")
    func restrictedControlIsInert() {
        var pickerPresented = false
        var rowHidden = false

        let performed = RestrictedMailActionControl.perform(isRestricted: true) {
            pickerPresented = true
            rowHidden = true
        }

        #expect(!performed)
        #expect(!pickerPresented)
        #expect(!rowHidden)
    }

    @Test("An unrestricted action remains available")
    func unrestrictedControlStillActs() {
        var pickerPresented = false

        let performed = RestrictedMailActionControl.perform(isRestricted: false) {
            pickerPresented = true
        }

        #expect(performed)
        #expect(pickerPresented)
    }
}
