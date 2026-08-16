/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICSCalendarImporter Add-to-Calendar policy")
struct ICSCalendarImporterAddPolicyTests {

    private func calendar(
        method: String?,
        methodPropertyName: String = "METHOD",
        beginEvent: String = "BEGIN:VEVENT",
        endEvent: String = "END:VEVENT"
    ) -> Data {
        let methodLine = method.map { "\(methodPropertyName):\($0)\n" } ?? ""
        return Data(
            """
            BEGIN:VCALENDAR
            VERSION:2.0
            \(methodLine)\(beginEvent)
            SUMMARY:Policy fixture
            \(endEvent)
            END:VCALENDAR
            """.utf8
        )
    }

    @Test("Response and control methods cannot enter the unsafe system Calendar flow")
    func refusesNonAddITIPMethods() {
        for method in ["REPLY", "REFRESH", "COUNTER", "DECLINECOUNTER", "reply"] {
            let data = calendar(method: method)
            let expected = method.uppercased()
            let parsed = ICSBuilder.parseIncoming(String(decoding: data, as: UTF8.self))
            #expect(parsed?.method == expected, "fixture must exercise METHOD:\(method)")
            #expect(!ICSCalendarImporter.allowsAddToCalendar(data), "METHOD:\(method)")
        }

        for propertyName in ["method", "MeThOd"] {
            let data = calendar(
                method: "DECLINECOUNTER",
                methodPropertyName: propertyName
            )
            let parsed = ICSBuilder.parseIncoming(String(decoding: data, as: UTF8.self))
            #expect(
                parsed?.method == "DECLINECOUNTER",
                "fixture must exercise \(propertyName):DECLINECOUNTER"
            )
            #expect(
                !ICSCalendarImporter.allowsAddToCalendar(data),
                "\(propertyName):DECLINECOUNTER"
            )
        }

        let mixedCaseEvent = calendar(
            method: "DECLINECOUNTER",
            beginEvent: "begin:vevent",
            endEvent: "End:VEvent"
        )
        let parsed = ICSBuilder.parseIncoming(String(decoding: mixedCaseEvent, as: UTF8.self))
        #expect(parsed?.method == "DECLINECOUNTER", "fixture must exercise mixed-case VEVENT")
        #expect(!ICSCalendarImporter.allowsAddToCalendar(mixedCaseEvent))
    }

    @Test("Event-bearing, missing, and unknown methods retain Calendar import")
    func allowsEventBearingAndUnknownMethods() {
        for method in ["REQUEST", "PUBLISH", "ADD", "CANCEL", "X-WHATEVER"] {
            let data = calendar(method: method)
            let expected = method.uppercased()
            let parsed = ICSBuilder.parseIncoming(String(decoding: data, as: UTF8.self))
            #expect(parsed?.method == expected, "fixture must exercise METHOD:\(method)")
            #expect(ICSCalendarImporter.allowsAddToCalendar(data), "METHOD:\(method)")
        }

        let noMethod = calendar(method: nil)
        let parsed = ICSBuilder.parseIncoming(String(decoding: noMethod, as: UTF8.self))
        #expect(parsed?.method == "REQUEST", "missing METHOD must exercise the parser default")
        #expect(ICSCalendarImporter.allowsAddToCalendar(noMethod))
    }

    @Test("Unreadable and non-event payloads fail open")
    func allowsUnreadableAndNonEventPayloads() {
        let fixtures = [
            Data([0xFF, 0xFE, 0xFD]),
            Data("BEGIN:VCALENDAR\nMETHOD:REPLY\nEND:VCALENDAR".utf8),
            Data(),
        ]
        for data in fixtures {
            #expect(ICSCalendarImporter.allowsAddToCalendar(data))
        }
    }

    @Test("METHOD after the first event remains an explicit fail-open residual")
    func allowsMethodAfterEvent() {
        let data = Data(
            """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Late method
            END:VEVENT
            METHOD:REPLY
            END:VCALENDAR
            """.utf8
        )
        let parsed = ICSBuilder.parseIncoming(String(decoding: data, as: UTF8.self))
        #expect(parsed?.method == "REQUEST", "the shared parser stops at the first VEVENT")
        #expect(ICSCalendarImporter.allowsAddToCalendar(data))
    }

    @Test("The attachment tap branches on policy and explains refusal")
    func attachmentTapConsultsPolicyBeforePresentation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TabMail/Views/Message/AttachmentListView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func downloadAndImportICS("))
        let nextFunction = try #require(
            source.range(
                of: "private func downloadAndPreview(",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let functionBody = source[functionStart.lowerBound..<nextFunction.lowerBound]
        let codeLines = functionBody.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        let policySites = codeLines.indices.filter {
            codeLines[$0].contains("ICSCalendarImporter.allowsAddToCalendar(")
        }
        let presentationSites = codeLines.indices.filter {
            codeLines[$0].contains("ICSCalendarImporter.presentCalendarImport(")
        }
        let refusalNoticeSites = codeLines.indices.filter {
            codeLines[$0].contains("scheduling message, so there’s no new event to add")
        }

        #expect(policySites.count == 1, "the tap found \(policySites.count) policy calls")
        #expect(
            presentationSites.count == 1,
            "the tap found \(presentationSites.count) import presentations, so the scan is vacuous"
        )
        #expect(
            refusalNoticeSites.count == 1,
            "the tap found \(refusalNoticeSites.count) user-visible refusal notices"
        )
        if let policySite = policySites.first,
           let presentationSite = presentationSites.first,
           let refusalNoticeSite = refusalNoticeSites.first {
            #expect(
                codeLines[policySite].hasPrefix("if ICSCalendarImporter.allowsAddToCalendar("),
                "the policy result must control a branch rather than being discarded"
            )
            #expect(
                presentationSite == policySite + 1,
                "Calendar presentation must be inside the policy-approved branch"
            )
            #expect(
                refusalNoticeSite == presentationSite + 2,
                "policy refusal must take the visible-message branch"
            )
        }
    }
}

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

@Suite("ICSCalendarImporter iTIP fingerprint")
struct ICSCalendarImporterFingerprintTests {

    // THE INVARIANT THESE PIN: *a folded value's parsed length equals its unfolded TRUE
    // length.* The fingerprint exists to compare one event's identity across two taps and
    // across the sanitizer, so a number that is really a fold width is worse than no
    // number — it is a corruption signal the payload never carried. RFC 5545 §3.1.

    /// Fold `logicalLine` so no physical line exceeds `width` octets, per RFC 5545 §3.1:
    /// continuation lines begin with a single SPACE, which counts toward the width.
    private static func fold(_ logicalLine: String, width: Int) -> String {
        var remaining = Substring(logicalLine)
        var physical: [String] = []
        var take = width
        while remaining.count > take {
            physical.append(String(remaining.prefix(take)))
            remaining = remaining.dropFirst(take)
            take = width - 1 // the leading fold SPACE occupies one octet
        }
        physical.append(String(remaining))
        return physical.joined(separator: "\r\n ")
    }

    private static func calendar(uid: String, foldWidth: Int) -> Data {
        let body = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            fold("UID:\(uid)", width: foldWidth),
            "SEQUENCE:1",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n") + "\r\n"
        return Data(body.utf8)
    }

    @Test("itipFingerprint reports a folded UID's TRUE length, not the fold width")
    func fingerprintUnfoldsBeforeMeasuringLength() {
        // Synthetic boundary control: one UID folded at 75 octets and re-folded at 74.
        // Both physical widths must still produce the same logical length.
        let uid = String(repeating: "u", count: 120)

        // Non-vacuity: if the fixture were not actually folded, both halves below would
        // pass against the pre-fix code and the test would assert nothing.
        let senderPayload = Self.calendar(uid: uid, foldWidth: 75)
        #expect(String(data: senderPayload, encoding: .utf8)?.contains("\r\n u") == true,
                "fixture is not folded — this test cannot see the defect")

        let atSenderWidth = ICSCalendarImporter.itipFingerprint(senderPayload, label: "raw")
        let atOurWidth = ICSCalendarImporter.itipFingerprint(
            Self.calendar(uid: uid, foldWidth: 74), label: "sanitized")

        #expect(atSenderWidth.contains("(len 120)"),
                "pre-fix this read (len 71) — 75 minus \"UID:\", the SENDER's fold width")
        #expect(atOurWidth.contains("(len 120)"),
                "pre-fix this read (len 70) — 74 minus \"UID:\", OUR fold width")
        // Said the other way round too: neither synthetic fold width may ever be
        // reported as the logical value length.
        #expect(!atSenderWidth.contains("(len 71)"))
        #expect(!atOurWidth.contains("(len 70)"))
    }

    @Test("itipFingerprint unfolds a bare-CR continuation before measuring or counting")
    func fingerprintUnfoldsBareCRContinuations() {
        let uid = String(repeating: "b", count: 90)
        let split = uid.index(uid.startIndex, offsetBy: 45)
        let ics = "BEGIN:VCALENDAR\rMETHOD:REQUEST\rBEGIN:VEVENT\rUID:"
            + uid[..<split] + "\r " + uid[split...]
            + "\rDESCRIPTION:continuation\r ATTENDEE:not-a-property\r"
            + "ATTENDEE:mailto:real@example.com\rEND:VEVENT\rEND:VCALENDAR\r"

        #expect(ics.contains("\r "), "fixture must exercise bare-CR folding")
        let out = ICSCalendarImporter.itipFingerprint(Data(ics.utf8), label: "bare-cr")
        #expect(out.contains("UID=bbbbbbbbbbbb…(len 90)"))
        #expect(out.contains(" ATTENDEE=1"),
                "a folded continuation must not be promoted to a second property")
    }

    @Test("itipFingerprint unfolds before counting, so a continuation cannot forge a property")
    func fingerprintUnfoldsBeforeCounting() {
        // The same ordering defect on the COUNT axis. Trimming each physical line strips
        // the fold SPACE, after which a continuation that happens to begin with a
        // property name is indistinguishable from that property.
        let ics = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:folded-continuation-probe",
            "ATTENDEE;CN=One:mailto:one@example.com",
            "DESCRIPTION:agenda continues on the next physical line —",
            " ATTENDEE:this is description text, not a fourth attendee",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n") + "\r\n"

        // Non-vacuity: the continuation must actually be a continuation.
        #expect(ics.contains("\r\n ATTENDEE:"), "fixture carries no folded continuation")

        let out = ICSCalendarImporter.itipFingerprint(Data(ics.utf8), label: "probe")
        #expect(out.contains(" ATTENDEE=1"), "pre-fix this counted the continuation and read 2")
        #expect(!out.contains(" ATTENDEE=2"))
    }

    @Test("itipFingerprint leaves an unfolded payload's values untouched")
    func fingerprintIsANoOpWithoutFolding() {
        // Negative control: unfolding must not perturb the ordinary case, or the two
        // tests above could pass through a change that mangles every payload equally.
        let ics = [
            "BEGIN:VCALENDAR",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:short-uid-1234",
            "SEQUENCE:19",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n") + "\r\n"

        let out = ICSCalendarImporter.itipFingerprint(Data(ics.utf8), label: "plain")
        #expect(out.contains("METHOD=REPLY"))
        #expect(out.contains("SEQUENCE=19"))
        #expect(out.contains("(len 14)"))
        #expect(out.contains("VEVENT=1"))
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
