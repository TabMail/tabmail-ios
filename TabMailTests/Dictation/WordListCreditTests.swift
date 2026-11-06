/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The word list is CC BY-SA 4.0 data adapted from other people's work (ADR-IOS-101): the licenses
/// ask that every source is credited where the app credits its libraries, and that the list's own
/// license is said.
struct WordListCreditTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theAcknowledgmentsScreenCreditsEverySourceOfTheList() throws {
        let screen = try read("TabMail/Views/Settings/AcknowledgmentsView.swift")
        for credit in ["FrequencyWords", "Hermit Dave", "OpenSubtitles 2018", "Lison", "wordfreq", "OpenCC", "Unicode CLDR", "CC BY-SA 4.0", "Vendor/wordlist/README.md"] {
            #expect(screen.contains(credit), "\(credit)")
        }
    }

    @Test func theLicensesFileCreditsThemToo() throws {
        let licenses = try read("THIRD_PARTY_LICENSES.md")
        for credit in ["FrequencyWords", "OpenSubtitles", "wordfreq", "OpenCC", "Unicode CLDR", "CC BY-SA 4.0", "Vendor/wordlist/README.md"] {
            #expect(licenses.contains(credit), "\(credit)")
        }
    }

    /// The README beside the data carries the sources and the license statement the credit points to.
    @Test func theReadmeStatesTheListsLicense() throws {
        let readme = try read("TabMail/Vendor/wordlist/README.md")
        #expect(readme.contains("CC BY-SA 4.0"))
        #expect(readme.contains("creativecommons.org/licenses/by-sa/4.0"))
        #expect(readme.contains("FrequencyWords"))
    }
}
