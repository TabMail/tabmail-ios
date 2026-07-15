/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SyncField Extended Properties")
struct SyncFieldExtendedTests {

    @Test("All SyncField cases are present")
    func allCasesPresent() {
        let cases = SyncField.allCases
        #expect(cases.count == 6)
        #expect(cases.contains(.composition))
        #expect(cases.contains(.action))
        #expect(cases.contains(.kb))
        #expect(cases.contains(.templates))
        #expect(cases.contains(.disabledReminders))
        #expect(cases.contains(.taskCache))
    }

    @Test("promptFields has exactly 4 elements")
    func promptFieldsCount() {
        #expect(SyncField.promptFields.count == 4)
    }

    @Test("promptFields excludes disabledReminders and taskCache")
    func promptFieldsExcludesNonPromptFields() {
        #expect(!SyncField.promptFields.contains(.disabledReminders))
        #expect(!SyncField.promptFields.contains(.taskCache))
    }

    @Test("promptFields includes all prompt-related cases")
    func promptFieldsContent() {
        let prompt = SyncField.promptFields
        #expect(prompt.contains(.composition))
        #expect(prompt.contains(.action))
        #expect(prompt.contains(.kb))
        #expect(prompt.contains(.templates))
    }

    @Test("displayName values are all unique")
    func displayNamesUnique() {
        let names = SyncField.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test("Specific displayName values match expected strings")
    func specificDisplayNames() {
        #expect(SyncField.composition.displayName == "Composition")
        #expect(SyncField.action.displayName == "Action Rules")
        #expect(SyncField.kb.displayName == "Knowledge Base")
        #expect(SyncField.templates.displayName == "Templates")
        #expect(SyncField.disabledReminders.displayName == "Disabled Reminders")
        #expect(SyncField.taskCache.displayName == "Task Cache")
    }

    @Test("Specific icon values match expected SF Symbol names")
    func specificIcons() {
        #expect(SyncField.composition.icon == "pencil.line")
        #expect(SyncField.action.icon == "tag")
        #expect(SyncField.kb.icon == "book")
        #expect(SyncField.templates.icon == "doc.on.doc")
        #expect(SyncField.disabledReminders.icon == "bell.slash")
        #expect(SyncField.taskCache.icon == "clock.arrow.2.circlepath")
    }

    @Test("icon values are all unique")
    func iconsUnique() {
        let icons = SyncField.allCases.map(\.icon)
        #expect(Set(icons).count == icons.count)
    }

    @Test("SyncField rawValue round-trip for all cases")
    func rawValueRoundTrip() {
        for field in SyncField.allCases {
            let recreated = SyncField(rawValue: field.rawValue)
            #expect(recreated == field)
        }
    }

    @Test("Invalid rawValue returns nil")
    func invalidRawValue() {
        #expect(SyncField(rawValue: "bogus") == nil)
        #expect(SyncField(rawValue: "") == nil)
    }
}

@Suite("AICacheSummary Extended Codable")
struct AICacheSummaryExtendedTests {

    @Test("Round-trip with all fields populated")
    func fullRoundTrip() throws {
        let summary = AICacheSummary(
            blurb: "Meeting tomorrow",
            todos: "Prepare slides",
            detailed: "Detailed summary here",
            reminderDate: "2026-03-15",
            reminderTime: "09:00",
            reminderContent: "Don't forget the meeting"
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.blurb == "Meeting tomorrow")
        #expect(decoded.todos == "Prepare slides")
        #expect(decoded.detailed == "Detailed summary here")
        #expect(decoded.reminderDate == "2026-03-15")
        #expect(decoded.reminderTime == "09:00")
        #expect(decoded.reminderContent == "Don't forget the meeting")
    }

    @Test("Round-trip with only required blurb field")
    func minimalRoundTrip() throws {
        let summary = AICacheSummary(blurb: "Short blurb")
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.blurb == "Short blurb")
        #expect(decoded.todos == nil)
        #expect(decoded.detailed == nil)
        #expect(decoded.reminderDate == nil)
        #expect(decoded.reminderTime == nil)
        #expect(decoded.reminderContent == nil)
    }

    @Test("Decodes from JSON with missing optional keys")
    func decodesPartialJSON() throws {
        let json = #"{"blurb":"Hello"}"#
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: Data(json.utf8))
        #expect(decoded.blurb == "Hello")
        #expect(decoded.todos == nil)
    }

    @Test("Blurb with special characters round-trips correctly")
    func specialCharactersInBlurb() throws {
        let summary = AICacheSummary(blurb: "Line1\nLine2\t\"quoted\" & <html>")
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.blurb == "Line1\nLine2\t\"quoted\" & <html>")
    }

    @Test("Empty string blurb round-trips correctly")
    func emptyBlurb() throws {
        let summary = AICacheSummary(blurb: "")
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.blurb == "")
    }

    @Test("Unicode blurb round-trips correctly")
    func unicodeBlurb() throws {
        let summary = AICacheSummary(blurb: "Rendez-vous demain")
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(AICacheSummary.self, from: data)
        #expect(decoded.blurb == "Rendez-vous demain")
    }
}

@Suite("AICacheResult Extended Codable")
struct AICacheResultExtendedTests {

    @Test("Round-trip with all fields populated")
    func fullRoundTrip() throws {
        let result = AICacheResult(
            summary: AICacheSummary(blurb: "Test"),
            action: "archive",
            reply: "Thank you for your email"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.summary?.blurb == "Test")
        #expect(decoded.action == "archive")
        #expect(decoded.reply == "Thank you for your email")
    }

    @Test("Round-trip with all nil fields")
    func allNilRoundTrip() throws {
        let result = AICacheResult(summary: nil, action: nil, reply: nil)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.summary == nil)
        #expect(decoded.action == nil)
        #expect(decoded.reply == nil)
    }

    @Test("Decodes from empty JSON object")
    func decodesEmptyJSON() throws {
        let json = #"{}"#
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: Data(json.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.action == nil)
        #expect(decoded.reply == nil)
    }

    @Test("Nested summary with reminder fields round-trips")
    func nestedSummaryWithReminders() throws {
        let summary = AICacheSummary(
            blurb: "Urgent",
            todos: "Call back",
            reminderDate: "2026-03-15",
            reminderTime: "14:00",
            reminderContent: "Follow up call"
        )
        let result = AICacheResult(summary: summary, action: "reply", reply: nil)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: data)
        #expect(decoded.summary?.blurb == "Urgent")
        #expect(decoded.summary?.todos == "Call back")
        #expect(decoded.summary?.reminderDate == "2026-03-15")
        #expect(decoded.summary?.reminderTime == "14:00")
        #expect(decoded.summary?.reminderContent == "Follow up call")
        #expect(decoded.action == "reply")
        #expect(decoded.reply == nil)
    }

    @Test("Action-only result decodes correctly")
    func actionOnlyResult() throws {
        let json = #"{"action":"none"}"#
        let decoded = try JSONDecoder().decode(AICacheResult.self, from: Data(json.utf8))
        #expect(decoded.action == "none")
        #expect(decoded.summary == nil)
        #expect(decoded.reply == nil)
    }
}

// MARK: - Transport error redaction

/// URLSession errors carry the failing URL in userInfo, and the DeviceSync
/// WebSocket URL embeds the auth token as a query parameter — interpolating
/// the raw error leaked a live Supabase JWT into the console capture
/// (observed 2026-06-09). Every WS-layer log site must go through
/// `redactedTransportError`.
@Suite("DeviceSync transport error redaction")
struct DeviceSyncErrorRedactionTests {

    @Test("Failing-URL token query never reaches the log string")
    func tokenStrippedFromFailingURL() throws {
        let leakyURL = try #require(
            URL(string: "wss://sync.tabmail.ai/ws?token=eyJhbGciOiJFUzI1NiJ9.SECRET.SIG")
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [
                NSURLErrorFailingURLErrorKey: leakyURL,
                NSLocalizedDescriptionKey: "cancelled \(leakyURL.absoluteString)",
            ]
        )

        let rendered = DeviceSyncService.redactedTransportError(error)

        #expect(!rendered.contains("token="))
        #expect(!rendered.contains("SECRET"))
        #expect(rendered.contains(NSURLErrorDomain))
        #expect(rendered.contains("\(NSURLErrorCancelled)"))
    }

    @Test("Plain errors render domain, code, and description")
    func plainErrorRendered() {
        let error = NSError(
            domain: "TestDomain", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "something broke"]
        )
        let rendered = DeviceSyncService.redactedTransportError(error)
        #expect(rendered == "TestDomain code=42 something broke")
    }
}
