/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Global color palette matching the TabMail Thunderbird addon (palette.data.json).
/// All colors in the app should come from here — no hardcoded colors in views.
enum Palette {
    // MARK: - Tag / Action Colors
    static let reply = Color(hex: 0x00A300)
    static let delete = Color(hex: 0xEE1111)
    static let archive = Color(hex: 0xDBA800)
    static let selectionBlue = Color(hex: 0x2D89EF)
    static let untagged = Color(hex: 0x6B7280)
    static let lightBlue = Color(hex: 0xEFF4FF)
    static let cursorIndicator = Color(hex: 0x0078D4)

    // MARK: - Text Colors (adaptive light/dark)
    static let textUnread = Color(.label) // system label adapts
    static let textRead = Color(light: Color(hex: 0x5A6272), dark: Color(hex: 0xD4D7DD))
    static let textMuted = Color(light: Color(hex: 0x6B6B73), dark: Color(hex: 0x8E8E93))

    // MARK: - Theme Colors (adaptive light/dark)
    static let pageBg = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x0E0E10))
    static let previewPaneBg = Color(light: Color(hex: 0xF2F2F7), dark: Color(hex: 0x0E0E10))
    static let pageColor = Color(light: Color(hex: 0x000000), dark: Color(hex: 0xFBFBFE))
    static let boxBg = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1C1E))
    static let boxBgHover = Color(light: Color(hex: 0xEDEDF0), dark: Color(hex: 0x52525E))
    static let buttonBg = Color(light: Color(hex: 0xEDEDF0), dark: Color(hex: 0x2B2A33))
    static let buttonBgHover = Color(light: Color(hex: 0xE0E0E6), dark: Color(hex: 0x52525E))
    static let buttonBgActive = Color(light: Color(hex: 0xD7D7DB), dark: Color(hex: 0x42414D))
    static let buttonColor = Color(light: Color(hex: 0x000000), dark: Color(hex: 0xFBFBFE))
    static let textColor = Color(light: Color(hex: 0x15141A), dark: Color(hex: 0xFBFBFE))
    static let accentColor = Color(light: Color(hex: 0x0060DF), dark: Color(hex: 0x0A84FF))

    // MARK: - Separator
    static let separator = Color(light: Color.black.opacity(0.15), dark: Color.white.opacity(0.15))

    // MARK: - Link
    static let link = Color(light: Color(hex: 0x0060DF), dark: Color(hex: 0x0A84FF))
}

// MARK: - Color Extensions

extension Color {
    /// Create a Color from a hex integer (e.g., 0xFF0000 for red)
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    /// Create a Color from a hex string (e.g., "#FF0000" or "FF0000")
    init(hex str: String) {
        let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt(cleaned, radix: 16) ?? 0
        self.init(hex: value)
    }

    /// Create an adaptive Color that resolves differently in light vs dark mode
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
