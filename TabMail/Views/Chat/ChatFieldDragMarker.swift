/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// What a drag on the reply field did to the chat, as an accessibility-only marker for the chat
/// swipe UI tests: XCUITest reads a frame only once the app is idle, well after the swell and its
/// settle, so the app records the newest row's largest vertical move itself, from a drag's start
/// until `watchAfterLetGo` after it lets go, beside whether the user-interaction freeze is held.
/// Active only in debug builds launched with the swipe UI test's argument (`--chat-swipe-ui-test`),
/// as the reply field's focus marker (`chatReplyFieldFocus`); it draws nothing (clear text in the
/// background, so no layout change).
///
/// The label reads `drags=<n> watching=<0|1> base=<0|1> at=<points> move=<points> held=<0|1>
/// frozen=<0|1> tip=<top>:<bottom>|none room=<top>:<bottom>|none field=<points> rise=<points>
/// dims=<n> over=<points> events=<event>,…|none wait=<0|1>`: `base` once the drag's start had the
/// newest row's place,
/// `at` the newest row's last reported top, `held` whether the freeze was still held halfway
/// through the cooldown after the settle (`heldAtSettle`), `frozen` whether it is held now, `tip`
/// the field's drag tip's whole card while it shows (XCUITest sees only its words), `room` the space
/// it must fit in, both in the chat's space; `field` the top of the field's glass on screen, swell
/// included (the open panel's top while it is open), `rise` how far that top rose above where it
/// was at the last drag's start while the finger moved (the swell XCUITest cannot see), `dims`
/// how many taps the open panel's dim has taken, `over` how far the text under the last drag went
/// past its end while the drag moved (the most the field's pan read, negative if the text stayed
/// short of its end; `none` until the pan has read it), `events` what happened to the last drag, in
/// order (`Probe.events`), `wait` whether the
/// drag tip is waiting for room (`TipWait`), then `textAt=<last read>:<at let-go>|none` where the
/// text under the last drag was when the drag last read it and when it let go, `textEnd=<points>|none`
/// where it was when the watch ended, and `textMove=<from>-><to>@+<ms>@<frame>|<frame>…|none` its first
/// move after the let-go, how long after it, with the call stack that made it (`Probe.watchText`; no
/// spaces in any).
///
/// Then, to find why a drag misbehaved: `end=<points>|none maxRead=<points>|none
/// hand=<travel>@<down|move|letgo>|none share=<points>`, the field's pan's own reads of the text
/// under the last drag (its end, the furthest place read while the drag moved, where the rest of the
/// drag became the field's and in which read, the largest upward share the field got);
/// `calls=<name>@+<ms>,…|none callStack=<frame>|…|none builds=<n> textClass=<class>|none`, what
/// the text was asked to do from the let-go until the watch ended (`TextCalls`), the stack of the
/// first such call that scrolls it, how often the reply field's `inputField` was built, and the text
/// view's class; and `pop=<entry>,…|none`, the back swipe since it last began (`PopWatch`).
/// `pan=<event>,…|none` (after `share`) holds `on:<state>`/`off:<state>` when the field's pan was
/// turned on or off during the last drag, and `cancelled` when it was cancelled.
enum ChatFieldDragMarker {
    static let identifier = "chatFieldDragMarker"

    /// On the pill: watches the drag and shows the marker.
    struct Field: ViewModifier {
        let dragging: Bool

        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content.modifier(Shown(dragging: dragging))
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// On each chat row: the newest row reports where its top is.
    struct Row: ViewModifier {
        let isNewest: Bool

        func body(content: Content) -> some View {
            #if DEBUG
            // Attached to every row while the probe is active, so a row that stops being the
            // newest keeps its view state; only the newest one reports.
            if Probe.isActive {
                content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    if isNewest { Probe.shared.newestMoved(to: $0) }
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// On the field's glass, swell included (before `pill(on:)` takes the swell back out of the
    /// layout): reports its top on screen.
    struct Glass: ViewModifier {
        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    Probe.shared.glassMoved(to: $0)
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// The open panel's dim took a tap (debug builds only; nothing in release).
    @MainActor
    static func dimTapped() {
        #if DEBUG
        if Probe.isActive { Probe.shared.dims += 1 }
        #endif
    }

    /// The field's pan read the text under its drag `points` past its end (negative short of it)
    /// (debug builds only; nothing in release).
    @MainActor
    static func textPastEnd(_ points: CGFloat) {
        #if DEBUG
        if Probe.isActive { Probe.shared.textPastEnd(points) }
        #endif
    }

    /// The drag on the field ended: let go (`finished`) or cut off while the finger was still down
    /// (debug builds only; nothing in release).
    @MainActor
    static func dragEnded(finished: Bool) {
        #if DEBUG
        if Probe.isActive { Probe.shared.dragEnded(finished: finished) }
        #endif
    }

    /// The field's pan is about to be set on or off (`enabled`): if that turns it on or off, records
    /// `on:<state>` or `off:<state>` with its state then among the pan's events (`Probe.panEvents`),
    /// so a run shows whether turning it off under a held drag reached a recognizing pan. Reads the
    /// pan only in a debug build the swipe UI tests launch (nothing in release).
    @MainActor
    static func panEnabling(_ pan: UIGestureRecognizer, to enabled: Bool) {
        #if DEBUG
        if Probe.isActive, pan.isEnabled != enabled {
            Probe.shared.notePan("\(enabled ? "on" : "off"):\(name(of: pan.state))")
        }
        #endif
    }

    /// The field's pan moved from state `old` to `new`: records `cancelled` among the pan's events
    /// when it became cancelled (debug builds the swipe UI tests launch only; nothing in release).
    @MainActor
    static func panState(from old: UIGestureRecognizer.State, to new: @autoclosure () -> UIGestureRecognizer.State) {
        #if DEBUG
        if Probe.isActive, old != .cancelled, new() == .cancelled { Probe.shared.notePan("cancelled") }
        #endif
    }

    /// A new touch on the field's pan, over a text whose end is at `end` (nil off a text), the drag
    /// handed to the field from its start when `handedOff` (the text already at its end): starts
    /// the hand-off record of the drag (debug builds only; nothing in release).
    @MainActor
    static func textTouchDown(end: CGFloat?, handedOff: Bool) {
        #if DEBUG
        if Probe.isActive { Probe.shared.textTouchDown(end: end, handedOff: handedOff) }
        #endif
    }

    /// The field's pan read the text under its drag at `offset`, its end at `end`, and gave the field
    /// `share` of upward travel; `handOff` is the drag's vertical travel where the rest became the
    /// field's when it was found in this read, `atLetGo` whether this read is the let-go's (debug
    /// builds only; nothing in release).
    @MainActor
    static func textShared(end: CGFloat, offset: CGFloat, handOff: CGFloat?, share: CGFloat, atLetGo: Bool) {
        #if DEBUG
        if Probe.isActive { Probe.shared.textShared(end: end, offset: offset, handOff: handOff, share: share, atLetGo: atLetGo) }
        #endif
    }

    /// The `inputField` of the chat's reply field was built again (a body evaluation of the view
    /// that holds it): counted after a let-go (debug builds only; nothing in release).
    struct InputFieldBuilt: ViewModifier {
        @MainActor init() {
            #if DEBUG
            if Probe.isActive { Probe.shared.inputFieldBuilt() }
            #endif
        }

        func body(content: Content) -> some View {
            content
        }
    }

    /// The navigation controller's back swipe on the chat (`pop`), for as long as `owner` (the
    /// chat's swipe closer) holds it: records its state changes, when it is turned on or off, and
    /// how its interactive transition ends, to find why a back swipe returned to the chat. A new
    /// owner starts a new record (debug builds only; nothing in release).
    @MainActor
    static func watchPop(_ pop: UIGestureRecognizer?, owner: AnyObject) {
        #if DEBUG
        if Probe.isActive, let pop { Probe.shared.popWatch.watch(pop, for: ObjectIdentifier(owner)) }
        #endif
    }

    /// `owner` lets go of the back swipe (`watchPop`): its watch ends and its record is cleared, so
    /// nothing after it lands in the record (debug builds only; nothing in release).
    @MainActor
    static func unwatchPop(owner: AnyObject) {
        #if DEBUG
        if Probe.isActive { Probe.shared.popWatch.stop(for: ObjectIdentifier(owner)) }
        #endif
    }

    /// The drag on the field let go or was cut off with `text` under it (the focused field's
    /// scrolling text, if any), the text last read at `lastMoved` while the drag moved: records
    /// where the text is now and, for `Probe.watchAfterLetGo`, its first move after that with the
    /// call stack that made it, to find what moves a text the drag left scrolled (debug builds
    /// only; nothing in release).
    @MainActor
    static func textLetGo(_ text: UIScrollView?, lastMoved: CGFloat) {
        #if DEBUG
        if Probe.isActive { Probe.shared.watchText(text, lastMoved: lastMoved) }
        #endif
    }

    /// On the field's drag tip: reports where its whole card is while it shows, and the room it
    /// must fit in (the header's bottom and the field stack's top), all in the chat's space
    /// (`ChatSwipeOpen.space`), so the test compares them in one space in any orientation.
    struct TipCard: ViewModifier {
        let roomTop: CGFloat
        let roomBottom: CGFloat

        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatSwipeOpen.space)) } action: {
                        Probe.shared.tipMoved(to: $0)
                    }
                    .onChange(of: [roomTop, roomBottom], initial: true) { _, room in
                        Probe.shared.tipRoom = room
                    }
                    .onDisappear { Probe.shared.tipMoved(to: nil) }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// On the drag tip's empty stand-in, the child `ViewThatFits` picks when the tip's whole card
    /// has no room: reports that the tip is waiting for room while it shows.
    struct TipWait: ViewModifier {
        func body(content: Content) -> some View {
            #if DEBUG
            if Probe.isActive {
                content
                    .onAppear { Probe.shared.tipWaiting = true }
                    .onDisappear { Probe.shared.tipWaiting = false }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    #if DEBUG
    /// A gesture recognizer state as one word.
    static func name(of state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "state\(state.rawValue)"
        }
    }

    @MainActor @Observable
    final class Probe {
        static let shared = Probe()
        static let isActive = ProcessInfo.processInfo.arguments.contains("--chat-swipe-ui-test")
        /// When after a let-go the freeze is sampled: inside its hold, halfway through the cooldown
        /// that follows the field's settle.
        static var sampleAfterLetGo: Duration { ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown / 2 }
        /// How long after a let-go the move is still recorded: the settle and the cooldown, so the
        /// freeze is released by the end, twice over for margin.
        static var watchAfterLetGo: Duration { (ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown) * 2 }

        private(set) var drags = 0
        private(set) var watching = false
        private(set) var largestMove: CGFloat = 0
        /// Whether the freeze was held at `sampleAfterLetGo` after the last let-go.
        private(set) var heldAtSettle = false
        private var newestMinY: CGFloat?
        private var baseline: CGFloat?
        private var watchToken: UUID?

        /// The drag tip's card while it shows; nil while it does not (a tip TipKit no longer shows
        /// lays out empty). With the room it must fit in, top and bottom.
        private(set) var tipFrame: CGRect?
        var tipRoom: [CGFloat] = []
        /// Whether the tip's empty stand-in shows: the tip is eligible but its whole card has no
        /// room (a tip TipKit does not show lays out empty and fits, so it never picks the stand-in).
        var tipWaiting = false

        func tipMoved(to frame: CGRect?) {
            tipFrame = frame.flatMap { $0.height >= 1 ? $0 : nil }
        }

        /// The field's glass top on screen now, where it was at the last drag's start, and how far
        /// it rose above that while the drag moved.
        private(set) var glassTop: CGFloat?
        private var glassRest: CGFloat?
        private(set) var rise: CGFloat = 0
        private var dragging = false
        var dims = 0
        /// How far the text under the last drag went past its end while it moved (negative if it
        /// stayed short of it); nil until the field's pan has read the text's place.
        private(set) var pastEnd: CGFloat?

        func textPastEnd(_ points: CGFloat) {
            pastEnd = max(pastEnd ?? points, points)
        }

        /// What happened to the last drag, in order: `open` when the armed opening was requested
        /// under it (queued for the main actor; the panel's own opening is observed separately),
        /// then `end` when it was let go or `cut` when it was cut off with the finger still down.
        private(set) var events: [String] = []
        /// Armed by the swipe fixture (`openUnderTheNextDrag`): opens the panel the moment a drag
        /// held on the field has swollen it past the open distance, then disarms.
        @ObservationIgnored private var opensUnderTheDrag: (@MainActor @Sendable () -> Void)?

        /// The next drag on the field that swells it past the open distance runs `open` while the
        /// finger is still down, as the panel opening under a held drag does.
        func openUnderTheNextDrag(_ open: @escaping @MainActor @Sendable () -> Void) {
            opensUnderTheDrag = open
        }

        func dragEnded(finished: Bool) {
            events.append(finished ? "end" : "cut")
        }

        /// What happened to the field's pan itself during the last drag, in order: turned on or off
        /// (`on:<state>`, `off:<state>`), cancelled. Apart from `events`, which the cut-off test
        /// compares whole. Noted unobserved (`panLog`), inside the pan's own update and its state
        /// change, and shown after them (`publishLater`), so a note never updates the marker
        /// inside the update it records.
        private(set) var panEvents: [String] = []
        @ObservationIgnored private var panLog: [String] = []
        private static let panEventLimit = 16

        func notePan(_ event: String) {
            if panLog.count < Self.panEventLimit { panLog.append(event) }
            publishLater()
        }

        /// Shows the pan's and the back swipe's records (`panLog`, `popLog`) once the current
        /// update is done: one pending showing at a time, which shows the records as they are then.
        @ObservationIgnored private var publishPending = false

        private func publishLater() {
            guard !publishPending else { return }
            publishPending = true
            Task { @MainActor in
                self.publishPending = false
                self.panEvents = self.panLog
                self.popEntries = self.popLog
            }
        }

        /// The hand-off record of the last drag over a text (`textTouchDown`, `textShared`): the
        /// text's end, the furthest place the field's pan read while the drag moved, the drag's
        /// vertical travel where the rest became the field's with where that was found (`down`,
        /// `move` or `letgo`), and the largest upward travel the field was given.
        private(set) var panTextEnd: CGFloat?
        private(set) var maxRead: CGFloat?
        private(set) var handOff: String?
        private(set) var largestShare: CGFloat = 0

        func textTouchDown(end: CGFloat?, handedOff: Bool) {
            panTextEnd = end
            maxRead = nil
            handOff = handedOff ? "0.0@down" : nil
            largestShare = 0
        }

        func textShared(end: CGFloat, offset: CGFloat, handOff found: CGFloat?, share: CGFloat, atLetGo: Bool) {
            panTextEnd = end
            if !atLetGo { maxRead = max(maxRead ?? offset, offset) }
            if let found { handOff = String(format: "%.1f@", found) + (atLetGo ? "letgo" : "move") }
            largestShare = max(largestShare, -share)
        }

        /// What the text under the last drag was asked to do from its let-go until the watch ends:
        /// each call as `<name>@+<ms>` (`TextCalls`), the stack of the first call that scrolls it (of
        /// the first call when none does), how often the reply field's `inputField` was built in
        /// that time, and the text view's class. Unobserved, so a call made inside a view update
        /// never updates a view; they show when the watch ends.
        @ObservationIgnored private var textCalls: [String] = []
        @ObservationIgnored private var textCallStack: String?
        @ObservationIgnored private var textCallStackScrolls = false
        @ObservationIgnored private var inputFieldBuilds = 0
        @ObservationIgnored private var callWatchOpen = false
        @ObservationIgnored private var letGoTime: CFTimeInterval = 0
        @ObservationIgnored private var textClass: String?
        /// The most calls kept, and the most stack frames kept for the call that scrolls.
        private static let textCallLimit = 10
        private static let textCallFrames = 40
        private static let millisecondsPerSecond: Double = 1000

        /// Milliseconds since the last let-go over a text.
        private var sinceLetGo: String {
            String(format: "%.0fms", (CACurrentMediaTime() - letGoTime) * Self.millisecondsPerSecond)
        }

        /// The object `receiver` names was asked to do `name` (`scrolls`: a scroll call): noted only
        /// when it is the watched text (`watchText`) and its watch is open.
        func textCall(_ name: String, receiver: ObjectIdentifier, scrolls: Bool) {
            guard callWatchOpen, let watchedText, ObjectIdentifier(watchedText) == receiver else { return }
            if textCalls.count < Self.textCallLimit {
                textCalls.append("\(name)@+\(sinceLetGo)")
            }
            if textCallStack == nil || (scrolls && !textCallStackScrolls) {
                textCallStack = Self.stack(frames: Self.textCallFrames)
                textCallStackScrolls = scrolls
            }
        }

        func inputFieldBuilt() {
            if callWatchOpen { inputFieldBuilds += 1 }
        }

        private func resetTextCalls(open: Bool) {
            textCalls = []
            textCallStack = nil
            textCallStackScrolls = false
            inputFieldBuilds = 0
            callWatchOpen = open
            letGoTime = CACurrentMediaTime()
        }

        /// The back swipe's watch (`watchPop`) and what it saw since the swipe last began, under its
        /// current owner. Noted unobserved (`popLog`), from the swipe's callbacks and the closer's
        /// setup and teardown, and shown after them (`publishLater`).
        let popWatch = PopWatch()
        private(set) var popEntries: [String] = []
        @ObservationIgnored private var popLog: [String] = []
        private static let popEntryLimit = 16

        func notePop(_ entry: String, began: Bool = false) {
            if began { popLog = [] }
            if popLog.count < Self.popEntryLimit { popLog.append(entry) }
            publishLater()
        }

        /// The back swipe's watch changed owner or ended: its record starts empty.
        func clearPop() {
            popLog = []
            publishLater()
        }

        /// The text under the last drag: where it was when the drag last read it and at the
        /// let-go, where it was when the watch ended, and its first move after the let-go with the
        /// stack that made it; nil until a drag over a text lets go (`watchText`).
        private(set) var textAtLetGo: String?
        private(set) var textAtWatchEnd: String?
        private(set) var textMoveAfterLetGo: String?
        @ObservationIgnored private weak var watchedText: UIScrollView?
        @ObservationIgnored private var textWatch: NSKeyValueObservation?
        /// The most stack frames `textMoveAfterLetGo` keeps, the KeyValue machinery left out.
        private static let textMoveFrames = 30

        /// The drag let go with `text` under it, last read at `lastMoved`: notes where it is now and
        /// watches its scroll position until its first move of a point or more, or until the watch
        /// ends (`dragChanged`).
        func watchText(_ text: UIScrollView?, lastMoved: CGFloat) {
            stopTextWatch()
            textMoveAfterLetGo = nil
            textAtWatchEnd = nil
            watchedText = text
            resetTextCalls(open: text != nil)
            textClass = text.map { NSStringFromClass(type(of: $0)) }
            guard let text else {
                textAtLetGo = "none"
                return
            }
            TextCalls.install()
            let from = text.contentOffset.y
            textAtLetGo = String(format: "%.1f:%.1f", lastMoved, from)
            textWatch = text.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                // A scroll view's position changes on the main thread (layout and gesture driven).
                MainActor.assumeIsolated {
                    guard let self, let to = change.newValue?.y, abs(to - from) >= 1 else { return }
                    self.textMoveAfterLetGo = String(format: "%.1f->%.1f@+", from, to) + self.sinceLetGo + "@"
                        + Self.stack(frames: Self.textMoveFrames)
                    self.stopTextWatch()
                }
            }
        }

        private func stopTextWatch() {
            textWatch?.invalidate()
            textWatch = nil
        }

        /// The current call stack as `<module>:<symbol>` frames joined by `|`, spaces replaced, the
        /// observer's own frame and the KeyValue machinery left out, at most `frames` of them.
        static func stack(frames: Int) -> String {
            Thread.callStackSymbols.dropFirst().compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count > 3 else { return nil }
                let symbol = parts.dropFirst(3).joined(separator: " ")
                    .replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression)
                guard !symbol.contains("KeyValue") else { return nil }
                return "\(parts[1]):\(symbol)".replacingOccurrences(of: " ", with: "_")
            }
            .prefix(frames)
            .joined(separator: "|")
        }

        func glassMoved(to minY: CGFloat) {
            glassTop = minY
            guard dragging, let glassRest else { return }
            rise = max(rise, glassRest - minY)
            if rise >= ChatViewLayout.fieldDragOpenDistance, let open = opensUnderTheDrag {
                opensUnderTheDrag = nil
                events.append("open")
                // After this geometry callback, not inside it.
                Task { @MainActor in open() }
            }
        }

        func newestMoved(to minY: CGFloat) {
            newestMinY = minY
            guard watching, let baseline else { return }
            largestMove = max(largestMove, abs(minY - baseline))
        }

        func dragChanged(_ dragging: Bool) {
            self.dragging = dragging
            if dragging {
                drags += 1
                watching = true
                watchToken = nil
                baseline = newestMinY
                largestMove = 0
                heldAtSettle = false
                glassRest = glassTop
                rise = 0
                pastEnd = nil
                events = []
                stopTextWatch()
                watchedText = nil
                textAtLetGo = nil
                textAtWatchEnd = nil
                textMoveAfterLetGo = nil
                resetTextCalls(open: false)
                panLog = []
                panEvents = []
                return
            }
            let token = UUID()
            watchToken = token
            Task { @MainActor in
                try? await Task.sleep(for: Self.sampleAfterLetGo)
                guard self.watchToken == token else { return }
                self.heldAtSettle = PreviewFreezeGate.shared.isFrozen
                try? await Task.sleep(for: Self.watchAfterLetGo - Self.sampleAfterLetGo)
                guard self.watchToken == token else { return }
                self.stopTextWatch()
                self.callWatchOpen = false
                if self.textAtLetGo != nil {
                    self.textAtWatchEnd = self.watchedText.map { String(format: "%.1f", $0.contentOffset.y) } ?? "none"
                }
                self.watching = false
            }
        }

        var label: String {
            let move = String(format: "%.1f", largestMove)
            let at = String(format: "%.1f", newestMinY ?? -1)
            let tip = tipFrame.map { String(format: "%.1f:%.1f", $0.minY, $0.maxY) } ?? "none"
            let room = tipRoom.map { String(format: "%.1f", $0) }.joined(separator: ":")
            return "drags=\(drags) watching=\(watching ? 1 : 0) base=\(baseline == nil ? 0 : 1) at=\(at) move=\(move) held=\(heldAtSettle ? 1 : 0) frozen=\(PreviewFreezeGate.shared.isFrozen ? 1 : 0) tip=\(tip) room=\(room.isEmpty ? "none" : room) field=\(String(format: "%.1f", glassTop ?? -1)) rise=\(String(format: "%.1f", rise)) dims=\(dims) over=\(pastEnd.map { String(format: "%.1f", $0) } ?? "none") events=\(events.isEmpty ? "none" : events.joined(separator: ",")) wait=\(tipWaiting ? 1 : 0) textAt=\(textAtLetGo ?? "none") textEnd=\(textAtWatchEnd ?? "none") textMove=\(textMoveAfterLetGo ?? "none")" + " " + handOffLabel + " " + callsLabel + " pop=\(popEntries.isEmpty ? "none" : popEntries.joined(separator: ","))"
        }

        private var handOffLabel: String {
            let end = panTextEnd.map { String(format: "%.2f", $0) } ?? "none"
            let read = maxRead.map { String(format: "%.2f", $0) } ?? "none"
            return "end=\(end) maxRead=\(read) hand=\(handOff ?? "none") share=\(String(format: "%.1f", largestShare)) pan=\(panEvents.isEmpty ? "none" : panEvents.joined(separator: ","))"
        }

        private var callsLabel: String {
            "calls=\(textCalls.isEmpty ? "none" : textCalls.joined(separator: ",")) callStack=\(textCallStack ?? "none") builds=\(inputFieldBuilds) textClass=\(textClass ?? "none")"
        }
    }

    /// The navigation controller's back swipe, watched for the marker (`watchPop`) while one swipe
    /// closer owns the watch: each state it moves to since it last began as `<state>@+<ms>`, its
    /// turning on or off as `en:<0|1>@+<ms>@<frame>|…`, and its interactive transition's end as
    /// `ix:c<cancelled 0|1>:p<percent complete>:v<completion velocity>@+<ms>`. The owner's teardown
    /// ends the watch (`stop`): the target and the observation come off the swipe, and the record
    /// is cleared, as it is when a new owner starts one.
    @MainActor
    final class PopWatch: NSObject {
        private weak var pop: UIGestureRecognizer?
        private var owner: ObjectIdentifier?
        /// Counts the watches: a transition's callback that arrives after its watch ended (or a new
        /// one began) records nothing.
        private var generation = 0
        private var enabledWatch: NSKeyValueObservation?
        private var lastState: UIGestureRecognizer.State = .possible
        private var began: CFTimeInterval = CACurrentMediaTime()
        /// The most stack frames kept for a turning on or off.
        private static let enabledFrames = 8
        private static let millisecondsPerSecond: Double = 1000

        private var sinceBegan: String {
            String(format: "%.0fms", (CACurrentMediaTime() - began) * Self.millisecondsPerSecond)
        }

        func watch(_ pop: UIGestureRecognizer, for owner: ObjectIdentifier) {
            guard owner != self.owner || pop !== self.pop else { return }
            end()
            self.owner = owner
            self.pop = pop
            lastState = pop.state
            pop.addTarget(self, action: #selector(changed(_:)))
            enabledWatch = pop.observe(\.isEnabled, options: [.old, .new]) { [weak self] _, change in
                // A recognizer is turned on or off on the main thread.
                MainActor.assumeIsolated {
                    // Setting the value it already has notifies too: only a change is recorded.
                    guard let self, let on = change.newValue, on != change.oldValue else { return }
                    Probe.shared.notePop("en:\(on ? 1 : 0)@+\(self.sinceBegan)@" + Probe.stack(frames: Self.enabledFrames))
                }
            }
        }

        /// `owner`'s watch ends; a watch another owner holds is left alone.
        func stop(for owner: ObjectIdentifier) {
            guard owner == self.owner else { return }
            end()
        }

        private func end() {
            pop?.removeTarget(self, action: #selector(changed(_:)))
            enabledWatch?.invalidate()
            enabledWatch = nil
            pop = nil
            owner = nil
            generation += 1
            Probe.shared.clearPop()
        }

        @objc private func changed(_ pop: UIGestureRecognizer) {
            guard pop.state != lastState else { return }
            lastState = pop.state
            let isBegan = pop.state == .began
            if isBegan { began = CACurrentMediaTime() }
            Probe.shared.notePop("\(ChatFieldDragMarker.name(of: pop.state))@+\(sinceBegan)", began: isBegan)
            // UIKit's own target ran first and started the interactive pop.
            guard isBegan, let transition = (pop.view?.next as? UINavigationController)?.transitionCoordinator else { return }
            let generation = generation
            transition.notifyWhenInteractionChanges { [weak self] context in
                guard let self, self.generation == generation else { return }
                let entry = String(format: "ix:c%d:p%.2f:v%.2f@+", context.isCancelled ? 1 : 0,
                                   context.percentComplete, context.completionVelocity)
                Probe.shared.notePop(entry + self.sinceBegan)
            }
        }
    }

    /// What the text under the last drag is asked to do after its let-go (`Probe.textCall`):
    /// wrapped once per class, only in debug builds the swipe UI tests launch, and noted only for
    /// the watched text view while its watch is open. Each wrapper notes the call, then calls the
    /// implementation the method had before the wrap, once, with the method's own selector and
    /// every argument unchanged, and returns its result. A class that only inherits a method gets
    /// the wrapper as its own, so no superclass changes.
    @MainActor
    enum TextCalls {
        /// The classes wrapped so far, as `scroll:<class>` and `text:<class>`.
        private static var wrapped: Set<String> = []

        /// Wraps the scroll calls on `scrollView` and the text calls on `textView`: UIKit's own
        /// classes in the app, a test's own classes in the unit tests. Each class once.
        static func install(scrollView: AnyClass = UIScrollView.self, textView: AnyClass = UITextView.self) {
            if wrapped.insert("scroll:" + NSStringFromClass(scrollView)).inserted {
                wrap(scrollView, #selector(UIScrollView.setContentOffset(_:animated:)), pointAndFlag("offset", "offsetAnimated"))
                wrap(scrollView, #selector(UIScrollView.scrollRectToVisible(_:animated:)), rectAndFlag("rect", "rectAnimated"))
            }
            if wrapped.insert("text:" + NSStringFromClass(textView)).inserted {
                wrap(textView, #selector(UITextView.scrollRangeToVisible(_:)), range("rangeToVisible", scrolls: true))
                wrap(textView, #selector(setter: UITextView.selectedTextRange), object("selectedTextRange"))
                wrap(textView, #selector(setter: UITextView.selectedRange), range("selectedRange", scrolls: false))
                wrap(textView, #selector(UITextView.becomeFirstResponder), answer("becomeFirstResponder"))
            }
        }

        /// `selector` on `cls` runs the wrapper `make` builds from the implementation it had and
        /// the selector: set on `cls`'s own method, or added to `cls` when it only inherits it.
        private static func wrap(_ cls: AnyClass, _ selector: Selector, _ make: (IMP, Selector) -> Any) {
            guard let method = class_getInstanceMethod(cls, selector) else { return }
            let wrapper = imp_implementationWithBlock(make(method_getImplementation(method), selector))
            if !class_addMethod(cls, selector, wrapper, method_getTypeEncoding(method)) {
                method_setImplementation(method, wrapper)
            }
        }

        /// The original implementations' C shapes: the receiver, the selector, then the arguments
        /// (`ObjCBool` for Objective-C's `BOOL`).
        private typealias PointAndFlagCall = @convention(c) (AnyObject, Selector, CGPoint, ObjCBool) -> Void
        private typealias RectAndFlagCall = @convention(c) (AnyObject, Selector, CGRect, ObjCBool) -> Void
        private typealias RangeCall = @convention(c) (AnyObject, Selector, NSRange) -> Void
        private typealias ObjectCall = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        private typealias AnswerCall = @convention(c) (AnyObject, Selector) -> ObjCBool

        /// Notes the call `name` on `receiver`. UIKit makes these calls on the main thread; a call
        /// made off it (a unit test host's own code) is passed on unnoted rather than trapping.
        nonisolated private static func note(_ name: String, _ receiver: AnyObject, scrolls: Bool) {
            guard Thread.isMainThread else { return }
            let receiver = ObjectIdentifier(receiver)
            MainActor.assumeIsolated { Probe.shared.textCall(name, receiver: receiver, scrolls: scrolls) }
        }

        nonisolated private static func pointAndFlag(_ name: String, _ animatedName: String) -> (IMP, Selector) -> Any {
            { original, selector in
                let call = unsafeBitCast(original, to: PointAndFlagCall.self)
                let wrapper: @convention(block) (AnyObject, CGPoint, ObjCBool) -> Void = { receiver, point, animated in
                    TextCalls.note(animated.boolValue ? animatedName : name, receiver, scrolls: true)
                    call(receiver, selector, point, animated)
                }
                return wrapper
            }
        }

        nonisolated private static func rectAndFlag(_ name: String, _ animatedName: String) -> (IMP, Selector) -> Any {
            { original, selector in
                let call = unsafeBitCast(original, to: RectAndFlagCall.self)
                let wrapper: @convention(block) (AnyObject, CGRect, ObjCBool) -> Void = { receiver, rect, animated in
                    TextCalls.note(animated.boolValue ? animatedName : name, receiver, scrolls: true)
                    call(receiver, selector, rect, animated)
                }
                return wrapper
            }
        }

        nonisolated private static func range(_ name: String, scrolls: Bool) -> (IMP, Selector) -> Any {
            { original, selector in
                let call = unsafeBitCast(original, to: RangeCall.self)
                let wrapper: @convention(block) (AnyObject, NSRange) -> Void = { receiver, value in
                    TextCalls.note(name, receiver, scrolls: scrolls)
                    call(receiver, selector, value)
                }
                return wrapper
            }
        }

        nonisolated private static func object(_ name: String) -> (IMP, Selector) -> Any {
            { original, selector in
                let call = unsafeBitCast(original, to: ObjectCall.self)
                let wrapper: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, object in
                    TextCalls.note(name, receiver, scrolls: false)
                    call(receiver, selector, object)
                }
                return wrapper
            }
        }

        nonisolated private static func answer(_ name: String) -> (IMP, Selector) -> Any {
            { original, selector in
                let call = unsafeBitCast(original, to: AnswerCall.self)
                let wrapper: @convention(block) (AnyObject) -> ObjCBool = { receiver in
                    TextCalls.note(name, receiver, scrolls: false)
                    return call(receiver, selector)
                }
                return wrapper
            }
        }
    }

    private struct Shown: ViewModifier {
        let dragging: Bool

        func body(content: Content) -> some View {
            content
                .background(
                    Text(Probe.shared.label)
                        .foregroundStyle(.clear)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(ChatFieldDragMarker.identifier))
                .onChange(of: dragging) { _, now in Probe.shared.dragChanged(now) }
        }
    }
    #endif
}

