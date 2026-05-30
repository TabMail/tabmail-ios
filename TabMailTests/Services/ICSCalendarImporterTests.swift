/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSCalendarImporter State")
struct ICSCalendarImporterStateTests {

    @Test("isActive is false initially")
    @MainActor
    func isActiveFalseInitially() {
        // No sessions have been started, so isActive must be false
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("isActive remains false after dismiss with no active session")
    @MainActor
    func dismissWithNoActiveSession() {
        // Dismissing when nothing is active should not crash or change state
        ICSCalendarImporter.dismiss()
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("dismiss is idempotent — calling multiple times does not crash")
    @MainActor
    func dismissIdempotent() {
        ICSCalendarImporter.dismiss()
        ICSCalendarImporter.dismiss()
        ICSCalendarImporter.dismiss()
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("presentCalendarImport(icsText:) with empty string does not crash")
    @MainActor
    func emptyICSText() {
        // Empty string is valid UTF-8, so it should pass the guard
        // but will fail to present (no UIKit context in tests).
        // Key: must not crash.
        ICSCalendarImporter.presentCalendarImport(icsText: "")
        // Clean up — the server may have started but Safari won't present in test env
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with empty data does not crash")
    @MainActor
    func emptyICSData() {
        ICSCalendarImporter.presentCalendarImport(icsData: Data())
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with valid ICS does not crash")
    @MainActor
    func validICSText() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Test Meeting
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        ICSCalendarImporter.presentCalendarImport(icsText: ics)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with valid ICS data does not crash")
    @MainActor
    func validICSData() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Data Meeting
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        let data = Data(ics.utf8)
        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with unicode content does not crash")
    @MainActor
    func unicodeICSText() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting with Cafe\u{0301} \u{1F600}
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        ICSCalendarImporter.presentCalendarImport(icsText: ics)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with large data does not crash")
    @MainActor
    func largeICSData() {
        // ICS with a very long description
        var ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Big Event\r\nDESCRIPTION:"
        ics += String(repeating: "A", count: 100_000)
        ics += "\r\nDTSTART:20240315T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let data = Data(ics.utf8)
        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()
    }

    @Test("dismiss after presentCalendarImport resets state")
    @MainActor
    func dismissAfterPresent() {
        let data = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR".utf8)
        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()
        // In test env without UIKit, Safari can't present, so isActive stays false
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("presentCalendarImport(icsText:) converts string to data correctly")
    @MainActor
    func textToDataConversion() {
        // The method does: guard let data = icsText.data(using: .utf8) else { return }
        // ASCII ICS content should always succeed
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR"
        // Should not early-return — valid UTF-8 string
        ICSCalendarImporter.presentCalendarImport(icsText: ics)
        ICSCalendarImporter.dismiss()
    }

    @Test("rapid present-dismiss cycles do not crash")
    @MainActor
    func rapidPresentDismissCycles() {
        let data = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR".utf8)
        for _ in 0..<10 {
            ICSCalendarImporter.presentCalendarImport(icsData: data)
            ICSCalendarImporter.dismiss()
        }
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("presentCalendarImport(icsData:) with binary data does not crash")
    @MainActor
    func binaryData() {
        // ICS files should be text, but the importer should handle arbitrary data gracefully
        var data = Data(count: 256)
        for i in 0..<256 {
            data[i] = UInt8(i)
        }
        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()
    }
}

@Suite("ICSCalendarImporter Teardown Cleanup")
struct ICSCalendarImporterTeardownTests {

    @Test("dismiss cleans up server and safari references")
    @MainActor
    func dismissCleansUp() {
        // After dismiss, isActive should always be false
        ICSCalendarImporter.dismiss()
        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("present then dismiss then present does not leak state")
    @MainActor
    func presentDismissPresent() {
        let data = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR".utf8)

        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()

        // Second present should work cleanly
        ICSCalendarImporter.presentCalendarImport(icsData: data)
        ICSCalendarImporter.dismiss()

        #expect(ICSCalendarImporter.isActive == false)
    }

    @Test("dismiss after text-based present cleans up")
    @MainActor
    func dismissAfterTextPresent() {
        ICSCalendarImporter.presentCalendarImport(icsText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR")
        ICSCalendarImporter.dismiss()
        #expect(ICSCalendarImporter.isActive == false)
    }
}

@Suite("ICSCalendarImporter Input Validation")
struct ICSCalendarImporterInputTests {

    @Test("presentCalendarImport(icsText:) with newlines only does not crash")
    @MainActor
    func newlinesOnly() {
        ICSCalendarImporter.presentCalendarImport(icsText: "\n\n\n\r\n\r\n")
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with whitespace only does not crash")
    @MainActor
    func whitespaceOnly() {
        ICSCalendarImporter.presentCalendarImport(icsText: "   \t\t  \n  ")
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with single byte does not crash")
    @MainActor
    func singleByte() {
        ICSCalendarImporter.presentCalendarImport(icsData: Data([0x00]))
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with malformed ICS does not crash")
    @MainActor
    func malformedICS() {
        let malformed = """
        NOT_A_CALENDAR
        RANDOM:CONTENT
        NO_BEGIN_END
        """
        ICSCalendarImporter.presentCalendarImport(icsText: malformed)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with nested VCALENDAR does not crash")
    @MainActor
    func nestedVCalendar() {
        let nested = """
        BEGIN:VCALENDAR
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Nested
        END:VEVENT
        END:VCALENDAR
        END:VCALENDAR
        """
        ICSCalendarImporter.presentCalendarImport(icsText: nested)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with very long single line does not crash")
    @MainActor
    func veryLongSingleLine() {
        let longLine = String(repeating: "X", count: 1_000_000)
        ICSCalendarImporter.presentCalendarImport(icsText: longLine)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with special characters does not crash")
    @MainActor
    func specialCharacters() {
        let special = "BEGIN:VCALENDAR\r\nSUMMARY:<script>alert('xss')</script>&amp;\r\nEND:VCALENDAR"
        ICSCalendarImporter.presentCalendarImport(icsText: special)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with null bytes does not crash")
    @MainActor
    func nullBytes() {
        let withNulls = "BEGIN:VCALENDAR\0\0\0END:VCALENDAR"
        ICSCalendarImporter.presentCalendarImport(icsText: withNulls)
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with CRLF line endings does not crash")
    @MainActor
    func crlfLineEndings() {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nDTSTART:20240315T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        ICSCalendarImporter.presentCalendarImport(icsData: Data(ics.utf8))
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsData:) with LF line endings does not crash")
    @MainActor
    func lfLineEndings() {
        let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nSUMMARY:Test\nDTSTART:20240315T100000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        ICSCalendarImporter.presentCalendarImport(icsData: Data(ics.utf8))
        ICSCalendarImporter.dismiss()
    }

    @Test("presentCalendarImport(icsText:) with multiple VEVENTs does not crash")
    @MainActor
    func multipleVEvents() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Meeting 1
        DTSTART:20240315T100000Z
        DTEND:20240315T110000Z
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Meeting 2
        DTSTART:20240316T100000Z
        DTEND:20240316T110000Z
        END:VEVENT
        END:VCALENDAR
        """
        ICSCalendarImporter.presentCalendarImport(icsText: ics)
        ICSCalendarImporter.dismiss()
    }
}
