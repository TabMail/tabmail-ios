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

/// Dragging the collapsed reply field up opens the TabMail chat panel: while the finger moves the
/// field swells upward under it, and the let-go opens the panel once the swell, or a flick's
/// predicted swell, reaches `ChatViewLayout.fieldDragOpenDistance`; otherwise it settles back.
/// Only a drag that goes more up than sideways swells the field, so a sideways swipe stays a swipe.
enum ChatFieldDrag {
    /// A drag in flight on the field (`ChatFieldPan`): the view resets it with the pill's spring
    /// however the drag ends, a cancelled drag included. `isDragging` is the whole drag (the
    /// interaction freeze and the tip key off it, once per drag); `swell` is how far the field
    /// follows the finger.
    struct Progress: Equatable {
        var isDragging = false
        var swell: CGFloat = 0
    }

    /// The drag's progress as the chat holds it. Read only inside `Swell`, `Watch` and the debug
    /// marker, so a moving finger redraws those modifiers alone and never rebuilds the chat's body
    /// or the reply field under the drag (UI run 2026-11-22: after the let-go the field's text
    /// scrolled to its caret, on the first layout after builds made while the finger moved).
    @MainActor @Observable
    final class Model {
        var progress = Progress()
    }

    /// The swell: on the field's glass (`sign` 1), and taken back out of the layout around it
    /// (`sign` -1), so the field's measured height never moves under a drag.
    struct Swell: ViewModifier {
        let model: Model?
        let sign: CGFloat

        func body(content: Content) -> some View {
            content.padding(.top, sign * (model?.progress.swell ?? 0))
        }
    }

    /// Tells `changed` when a drag begins and when it ends, finished or cancelled.
    struct Watch: ViewModifier {
        let model: Model
        let changed: (Bool) -> Void

        func body(content: Content) -> some View {
            content.onChange(of: model.progress.isDragging) { _, dragging in changed(dragging) }
        }
    }

    /// The drag's progress for a drag of `translation`.
    static func progress(translation: CGSize) -> Progress {
        Progress(isDragging: true, swell: swell(translation: translation))
    }

    /// How far the field swells for a drag of `translation`.
    static func swell(translation: CGSize) -> CGFloat {
        let up = -translation.height
        guard up > 0, up > abs(translation.width) else { return 0 }
        return min(up, ChatViewLayout.fieldDragMaxSwell)
    }

    /// Whether a drag that has travelled `translation` when it first moves is the field's: only one
    /// more up than sideways, the same drag that swells the field, so a sideways drag stays a swipe.
    static func begins(translation: CGSize) -> Bool {
        swell(translation: translation) > 0
    }

    /// Where a drag let go at `velocity` (points per second) would come to rest: its travel plus
    /// `ChatViewLayout.fieldFlickCarry` seconds of travel at that velocity, SwiftUI's own drag
    /// projection.
    static func predictedEnd(translation: CGSize, velocity: CGSize) -> CGSize {
        let carry = ChatViewLayout.fieldFlickCarry
        return CGSize(width: translation.width + velocity.width * carry,
                      height: translation.height + velocity.height * carry)
    }

    /// Whether letting go here opens the panel.
    static func opens(translation: CGSize, predictedEndTranslation: CGSize) -> Bool {
        let predicted = -predictedEndTranslation.height
        let flickedUp = predicted > abs(predictedEndTranslation.width) && predicted >= ChatViewLayout.fieldDragOpenDistance
        return swell(translation: translation) >= ChatViewLayout.fieldDragOpenDistance || flickedUp
    }

    /// The field's share of a drag that started in the focused field's text (mock v15 H2): until
    /// the text first reaches its end it keeps the drag; from there, the rest of the same drag is
    /// the field's, its swell, its open distance and its flick, as for a short draft, until the
    /// finger takes the drag back into the text (`ChatFieldPan.Coordinator.share`; a scroll of the
    /// text the finger did not make keeps the hand-off). Both axes count from that one hand-off
    /// point: `handOff` is the drag's travel, both axes, at the point where the text reached its
    /// end (zero for a drag that started there), nil while the text has the drag. Travel made while
    /// the text had the drag, either way, is not the field's, so it never adds to the field's upward
    /// pull nor turns it sideways. With no hand-off the field gets no travel and no velocity, so a
    /// flick while the text has the drag never opens the panel.
    static func fieldShare(of drag: ChatHorizontalPan.Sample, handOff: CGSize?) -> ChatHorizontalPan.Sample {
        guard let handOff else { return ChatHorizontalPan.Sample(travel: .zero, velocity: .zero) }
        return ChatHorizontalPan.Sample(travel: CGSize(width: drag.travel.width - handOff.width,
                                                       height: drag.travel.height - handOff.height),
                                        velocity: drag.velocity)
    }

    /// The let-go's sample once the finger held still `rested` seconds before it lifted: UIKit's
    /// pan reports at its end the speed of the finger's last move however long it then held still,
    /// so a drag held before the let-go would carry that old speed into the flick prediction and
    /// open the panel. Held still for `ChatViewLayout.fieldFlickRest` or longer, it lets go at rest.
    static func letGo(_ drag: ChatHorizontalPan.Sample, rested: TimeInterval) -> ChatHorizontalPan.Sample {
        guard rested >= ChatViewLayout.fieldFlickRest else { return drag }
        return ChatHorizontalPan.Sample(travel: drag.travel, velocity: .zero)
    }

    /// Whether a let-go with this last sample (`ChatHorizontalPan.Sample`) opens the panel: its
    /// swell, or its predicted swell, reaches the open distance.
    static func opens(letGo drag: ChatHorizontalPan.Sample) -> Bool {
        opens(translation: drag.travel,
              predictedEndTranslation: predictedEnd(translation: drag.travel, velocity: drag.velocity))
    }
}
