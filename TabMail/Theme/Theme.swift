/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Semantic theme aliases built on top of Palette.
/// Views should use Theme.* for semantic meaning, Palette.* for raw colors.
enum Theme {
    // MARK: - Accent & Actions
    static let accent = Palette.accentColor
    static let destructive = Palette.delete
    static let archive = Palette.archive
    static let reply = Palette.reply

    // MARK: - Message List
    static let unreadDot = Palette.accentColor
    static let textUnread = Palette.textUnread
    static let textRead = Palette.textRead
    static let flagged = Color.orange

    // MARK: - Surfaces
    static let pageBg = Palette.pageBg
    static let cardBackground = Palette.boxBg
    static let triageBackground = Palette.previewPaneBg
    static let buttonBg = Palette.buttonBg

    // MARK: - Text
    static let textPrimary = Palette.textColor
    static let textSecondary = Palette.textMuted

    // MARK: - Error
    static let errorBg = Palette.delete.opacity(0.15)
    static let errorFg = Palette.delete

    // MARK: - Action Tag Colors
    /// Solid tag color for labels/badges
    static func tagColor(_ tag: ActionTag) -> Color {
        switch tag {
        case .reply:   return Palette.reply
        case .none:    return Palette.selectionBlue
        case .archive: return Palette.archive
        case .delete:  return Palette.delete
        }
    }

    /// Subtle background tint for triage rows (matches TB addon opacity scheme)
    static func tagTint(_ tag: ActionTag) -> Color {
        tagColor(tag).opacity(0.10)
    }

    /// Darker tint for selected triage rows
    static func tagTintSelected(_ tag: ActionTag) -> Color {
        tagColor(tag).opacity(0.35)
    }
}
