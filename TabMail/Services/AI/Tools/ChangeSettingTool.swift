/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `change_setting` tool matching TB addon's `change_setting.js`.
/// Allows the agent to toggle user-facing settings (e.g., web search, notifications).
/// Persists changes to UserDefaults. Settings are NOT stored in KB (they sync
/// via UserDefaults/device settings, not KB which syncs across devices).
/// Registered in `ToolRegistry` at app startup.
struct ChangeSettingTool: AgentTool, Sendable {
    let name = "change_setting"

    // Setting definitions: key → config
    private struct SettingDef: Sendable {
        let type: SettingType
        let userDefaultsKey: String
        let min: Int?
        let max: Int?

        enum SettingType: Sendable { case boolean, number }

        init(boolean userDefaultsKey: String) {
            self.type = .boolean
            self.userDefaultsKey = userDefaultsKey
            self.min = nil
            self.max = nil
        }

        init(number userDefaultsKey: String, min: Int, max: Int) {
            self.type = .number
            self.userDefaultsKey = userDefaultsKey
            self.min = min
            self.max = max
        }
    }

    private static let settingDefs: [String: SettingDef] = [
        "privacy.web_search_enabled": SettingDef(
            boolean: AIService.webSearchEnabledKey
        ),
        "notifications.proactive_enabled": SettingDef(
            boolean: ProactiveNotifyService.enabledKey
        ),
        "notifications.new_reminder_window_days": SettingDef(
            number: ProactiveNotifyService.windowDaysKey,
            min: 1, max: 30
        ),
        "notifications.due_reminder_advance_minutes": SettingDef(
            number: ProactiveNotifyService.advanceMinutesKey,
            min: 5, max: 120
        ),
        "task.enabled": SettingDef(
            boolean: "task.enabled"
        ),
        "task.advance_minutes": SettingDef(
            number: "task.advance_minutes",
            min: 1, max: 30
        ),
        "calendar.default_event_duration_minutes": SettingDef(
            number: CalendarProviderDispatch.defaultEventDurationKey,
            min: 5, max: 12 * 60
        ),
    ]

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Demo boundary (ADR-IOS-038): device contacts / real app settings
        // are outside the demo sandbox — block with a relayable error.
        if DemoModeStore.isDemoActive { return DemoToolGuard.blockedMessage }
        guard case .string(let settingKey) = arguments["setting"] else {
            print("[ChangeSettingTool] Missing 'setting' argument")
            return ToolJSON.string(from: ["error": "missing 'setting' argument"])
        }

        guard let def = Self.settingDefs[settingKey] else {
            let valid = Self.settingDefs.keys.sorted().joined(separator: ", ")
            print("[ChangeSettingTool] Unknown setting '\(settingKey)'")
            return ToolJSON.string(from: ["error": "Unknown setting '\(settingKey)'. Valid: \(valid)"])
        }

        let key = def.userDefaultsKey
        let resultJSON: String

        switch def.type {
        case .boolean:
            let boolVal: Bool
            if case .bool(let b) = arguments["value"] {
                boolVal = b
            } else if case .string(let s) = arguments["value"], s == "true" || s == "false" {
                boolVal = (s == "true")
            } else {
                return ToolJSON.string(from: ["error": "Setting '\(settingKey)' requires a boolean value (true/false)."])
            }
            let prev = await MainActor.run { UserDefaults.standard.bool(forKey: key) }
            await MainActor.run {
                UserDefaults.standard.set(boolVal, forKey: key)
                UserDefaults.standard.synchronize()
            }
            print("[ChangeSettingTool] Set \(settingKey) = \(boolVal) (was \(prev))")

            resultJSON = ToolJSON.string(from: [
                "ok": true, "setting": settingKey,
                "value": "\(boolVal)", "previous_value": "\(prev)",
                "note": "Setting saved. Tell the user it has been changed. The new value takes effect starting from the next message.",
            ])

        case .number:
            let num: Int
            if case .int(let i) = arguments["value"] {
                num = i
            } else if case .double(let d) = arguments["value"] {
                num = Int(d)
            } else if case .string(let s) = arguments["value"], let parsed = Int(s) {
                num = parsed
            } else {
                return ToolJSON.string(from: ["error": "Setting '\(settingKey)' requires an integer value."])
            }
            guard let minVal = def.min, let maxVal = def.max, num >= minVal, num <= maxVal else {
                return ToolJSON.string(from: ["error": "Setting '\(settingKey)' must be between \(def.min ?? 0) and \(def.max ?? 0)."])
            }
            let prev = await MainActor.run { UserDefaults.standard.integer(forKey: key) }
            await MainActor.run {
                UserDefaults.standard.set(num, forKey: key)
                UserDefaults.standard.synchronize()
            }
            print("[ChangeSettingTool] Set \(settingKey) = \(num) (was \(prev))")

            resultJSON = ToolJSON.string(from: [
                "ok": true, "setting": settingKey,
                "value": "\(num)", "previous_value": "\(prev)",
                "note": "Setting saved. Tell the user it has been changed. The new value takes effect starting from the next message.",
            ])
        }

        return resultJSON
    }
}
