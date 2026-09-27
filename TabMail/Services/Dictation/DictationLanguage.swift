/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The language a dictation is transcribed in, sent with the recording so the backend can pick a
/// speech-to-text model that covers it (backend ADR-024). TabMail Voice uses the keyboard's
/// language; the pill hides the keyboard while dictating, so iOS uses the Settings choice, and
/// automatically the iPhone's language.
enum DictationLanguage {
    /// UserDefaults key of the Settings choice: an ISO-639-1 code, or `automatic`.
    static let settingKey = "dictationLanguage"
    static let automatic = ""

    /// The language to send for a Settings choice: the choice itself, or automatically the first
    /// preferred language. Nil sends none (the backend's default model).
    static func resolve(setting: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        setting == automatic ? code(forPreferredLanguages: preferredLanguages) : setting
    }

    /// The first preferred language reduced to its ISO-639-1 primary subtag (`zh-Hans-CN` → `zh`),
    /// as TabMail Voice's `KeyboardLanguage` reduces the keyboard's. Nil without a two-letter code
    /// (`yue`), which is what the backend accepts.
    static func code(forPreferredLanguages languages: [String]) -> String? {
        guard let first = languages.first,
              let primary = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(),
              primary.count == 2, primary.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return primary
    }

    /// The Settings choice now.
    static func current(defaults: UserDefaults = .standard) -> String? {
        resolve(setting: defaults.string(forKey: settingKey) ?? automatic)
    }

    /// A language's name in the user's own language (`ko` → "Korean").
    static func name(of code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// The languages Settings offers, by name.
    static func choices(locale: Locale = .current) -> [String] {
        DictationConfig.dictationLanguages.sorted {
            name(of: $0, locale: locale).localizedStandardCompare(name(of: $1, locale: locale)) == .orderedAscending
        }
    }
}
