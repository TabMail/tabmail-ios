/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("KBReminderParser")
struct KBReminderParserTests {

    /// Returns a date string YYYY/MM/DD for N days from now (positive = future).
    private func dateString(daysFromNow: Int) -> (slash: String, dash: String) {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: daysFromNow, to: Date())!
        let y = cal.component(.year, from: date)
        let m = String(format: "%02d", cal.component(.month, from: date))
        let d = String(format: "%02d", cal.component(.day, from: date))
        return ("\(y)/\(m)/\(d)", "\(y)-\(m)-\(d)")
    }

    @Test("Parse reminder with date and time")
    func parseWithDateTime() {
        let dt = dateString(daysFromNow: 7)
        let kb = "- [Reminder] Due \(dt.slash) 14:00 [America/Vancouver], Reply to Prof."
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Reply to Prof.")
        #expect(reminders[0].dueDate == dt.dash)
        #expect(reminders[0].dueTime == "14:00")
        #expect(reminders[0].timezone == "America/Vancouver")
    }

    @Test("Parse reminder with date only (no time)")
    func parseDateOnly() {
        let dt = dateString(daysFromNow: 10)
        let kb = "- [Reminder] Due \(dt.slash), Send quarterly report"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Send quarterly report")
        #expect(reminders[0].dueDate == dt.dash)
        #expect(reminders[0].dueTime == nil)
        #expect(reminders[0].timezone == nil)
    }

    @Test("Parse reminder without due date")
    func parseNoDueDate() {
        let kb = "- [Reminder] Always check test results before merging"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Always check test results before merging")
        #expect(reminders[0].dueDate == nil)
    }

    @Test("Parse multiple reminders")
    func parseMultiple() {
        let dt = dateString(daysFromNow: 7)
        let kb = """
        Some KB text here
        - [Reminder] Due \(dt.slash) 10:00, Morning standup
        - [Reminder] Due \(dt.slash) 14:00, Afternoon review
        - [Reminder] Check inbox daily
        Other KB text
        """
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 3)
    }

    @Test("Parse Reminder: format (without brackets)")
    func parseColonFormat() {
        let dt = dateString(daysFromNow: 7)
        let kb = "- Reminder: Due \(dt.slash), Check in with team"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Check in with team")
    }

    @Test("Empty KB text returns empty")
    func emptyKBText() {
        let reminders = KBReminderParser.parse("")
        #expect(reminders.isEmpty)
    }

    @Test("Whitespace-only KB text returns empty")
    func whitespaceOnlyKBText() {
        let reminders = KBReminderParser.parse("   \n  \n  ")
        #expect(reminders.isEmpty)
    }

    @Test("KB text with no reminders returns empty")
    func noReminders() {
        let kb = "- User prefers dark mode\n- Project uses Swift 6"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.isEmpty)
    }

    @Test("Reminders without due date are always active")
    func noDueDateAlwaysActive() {
        let kb = "- [Reminder] Eternal reminder"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Eternal reminder")
    }

    @Test("Future reminder is active")
    func futureReminderActive() {
        let dt = dateString(daysFromNow: 365)
        let kb = "- [Reminder] Due \(dt.slash), Future task"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
    }

    @Test("Very old reminder is filtered out")
    func oldReminderFiltered() {
        let dt = dateString(daysFromNow: -30)
        let kb = "- [Reminder] Due \(dt.slash), Ancient task"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.isEmpty)
    }

    @Test("Reminder due yesterday is still active (within 1 day grace)")
    func yesterdayStillActive() {
        let dt = dateString(daysFromNow: -1)
        let kb = "- [Reminder] Due \(dt.slash), Yesterday's task"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
    }

    @Test("Case insensitive parsing")
    func caseInsensitive() {
        let dt = dateString(daysFromNow: 30)
        let kb = "- [REMINDER] Due \(dt.slash), Caps reminder"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
    }

    @Test("Parse reminder with timezone in brackets")
    func timezoneInBrackets() {
        let dt = dateString(daysFromNow: 90)
        let kb = "- [Reminder] Due \(dt.slash) 09:30 [Europe/London], Call London office"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].timezone == "Europe/London")
        #expect(reminders[0].dueTime == "09:30")
    }

    @Test("Reminder: without due date parses content correctly")
    func colonFormatNoDueDate() {
        let kb = "- Reminder: Don't forget the milk"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Don't forget the milk")
        #expect(reminders[0].dueDate == nil)
    }

    @Test("Today's reminder is active")
    func todayActive() {
        let dt = dateString(daysFromNow: 0)
        let kb = "- [Reminder] Due \(dt.slash), Today's task"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
    }

    @Test("Two days ago reminder is filtered out")
    func twoDaysAgoFiltered() {
        let dt = dateString(daysFromNow: -2)
        let kb = "- [Reminder] Due \(dt.slash), Old task"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.isEmpty)
    }

    @Test("Mixed active and expired reminders")
    func mixedActiveExpired() {
        let dtExpired = dateString(daysFromNow: -30)
        let dtFuture = dateString(daysFromNow: 30)
        let kb = """
        - [Reminder] Due \(dtExpired.slash), Expired task
        - [Reminder] Due \(dtFuture.slash), Future task
        - [Reminder] Always active
        """
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 2)
    }

    @Test("Reminder with date, time, and timezone all present")
    func fullFormat() {
        let dt = dateString(daysFromNow: 120)
        let kb = "- [Reminder] Due \(dt.slash) 08:00 [US/Pacific], Independence Day check"
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].dueDate == dt.dash)
        #expect(reminders[0].dueTime == "08:00")
        #expect(reminders[0].timezone == "US/Pacific")
        #expect(reminders[0].content == "Independence Day check")
    }

    @Test("Non-reminder bullet lines are ignored")
    func nonReminderBullets() {
        let dt = dateString(daysFromNow: 60)
        let kb = """
        - User prefers dark mode.
        - [Reminder] Due \(dt.slash), Actual reminder
        - Another regular KB entry.
        """
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Actual reminder")
    }

    @Test("Reminder content is trimmed")
    func contentTrimmed() {
        let dt = dateString(daysFromNow: 60)
        let kb = "- [Reminder] Due \(dt.slash),   Lots of spaces   "
        let reminders = KBReminderParser.parse(kb)
        #expect(reminders.count == 1)
        guard reminders.count == 1 else { return }
        #expect(reminders[0].content == "Lots of spaces")
    }
}
