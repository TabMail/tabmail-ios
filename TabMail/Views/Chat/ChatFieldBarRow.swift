/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The row of every open field bar: [mic] [text] [Send], with the buttons centred on the text's
/// LAST line, so they stay at the bottom as the text grows. The chat's reply field, the opened
/// pill's input bar and the tutorial's copy all draw it, so they read the same values
/// (`ChatViewLayout.field*`).
///
/// Each button lays out at its glyph's width and one line's height; its tap area
/// (`ChatViewLayout.fieldTapSize` tall) reaches past that into its neighbours' room and the field's
/// edge, so the visible spacing does not grow to make room for the tap.
struct ChatFieldBarRow<Mic: View, Field: View, Send: View>: View {
    /// One body line, scaled with the text size: the last line the buttons centre on.
    @ScaledMetric(relativeTo: .body) private var lineHeight = ChatViewLayout.fieldLineHeight
    private let mic: Mic
    private let text: Field
    private let send: Send

    init(@ViewBuilder mic: () -> Mic, @ViewBuilder text: () -> Field, @ViewBuilder send: () -> Send) {
        self.mic = mic()
        self.text = text()
        self.send = send()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: ChatViewLayout.fieldTextGap) {
            mic.modifier(FieldButtonSlot(
                glyphWidth: ChatViewLayout.fieldMicGlyphWidth, tapWidth: ChatViewLayout.fieldMicTapWidth,
                lineHeight: lineHeight))
            text.frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)
            send.modifier(FieldButtonSlot(
                glyphWidth: ChatViewLayout.fieldSendSize, tapWidth: ChatViewLayout.fieldTapSize,
                lineHeight: lineHeight))
        }
        .padding(.leading, ChatViewLayout.fieldMicInset)
        .padding(.trailing, ChatViewLayout.fieldSendInset)
        .padding(.vertical, ChatViewLayout.fieldVerticalPadding)
    }
}

/// A field button laid out at its glyph's width and one line's height, its tap area centred on it.
/// The button's own label is `tapWidth` by `ChatViewLayout.fieldTapSize`.
private struct FieldButtonSlot: ViewModifier {
    let glyphWidth: CGFloat
    let tapWidth: CGFloat
    let lineHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: tapWidth, height: ChatViewLayout.fieldTapSize)
            .padding(.horizontal, -(tapWidth - glyphWidth) / 2)
            .padding(.vertical, -(ChatViewLayout.fieldTapSize - lineHeight) / 2)
    }
}
