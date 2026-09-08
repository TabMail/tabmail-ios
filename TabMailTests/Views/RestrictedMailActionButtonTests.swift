/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
@testable import TabMail

@Suite("Restricted mail action controls", .serialized, .processGlobalState)
struct RestrictedMailActionButtonTests {
    @Test("A restricted SwiftUI button stores no executable picker or hide action")
    @MainActor
    func restrictedControlIsInert() {
        var pickerPresented = false
        var rowHidden = false
        let button = RestrictedMailActionButton(isRestricted: true) {
            pickerPresented = true
            rowHidden = true
        } label: {
            Text("Move")
        }

        button.action()

        #expect(!pickerPresented)
        #expect(!rowHidden)
    }

    @Test("An unrestricted SwiftUI button retains its action")
    @MainActor
    func unrestrictedControlStillActs() {
        var pickerPresented = false
        let button = RestrictedMailActionButton(isRestricted: false) {
            pickerPresented = true
        } label: {
            Text("Move")
        }

        button.action()

        #expect(pickerPresented)
    }
}
