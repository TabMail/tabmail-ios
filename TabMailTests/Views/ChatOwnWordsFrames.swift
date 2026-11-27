/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
@testable import TabMail

/// Where the chat shows the user's own words, frame by frame: the window frame of each element
/// VoiceOver reads as "You said: ..." (the user's message bubble, held or writing, the Sending
/// bubble's words, and an email of the user's in a thread), read after every Core Animation commit
/// between `start` and `stop`. Shared by the new email's chat and a thread's chat.
///
/// What it measures is presence in the view tree, as accessibility reads it, once per run-loop pass
/// after Core Animation's commit: an element counts as drawn when its accessibility frame is taller
/// than one point. It reads no pixels, so an element fading in or out counts as drawn for the whole
/// fade, and a change made and undone within one pass is not seen.
@MainActor
final class OwnWordsFrames {
    private let view: UIView
    private var observer: CFRunLoopObserver?
    private(set) var frames: [[CGRect]] = []

    init(view: UIView) {
        self.view = view
    }

    /// Two of the user's bubbles one above the other, apart: the words twice. One turning into the
    /// other shares its place, so the two overlap.
    nonisolated static func showsTwoApart(_ frame: [CGRect]) -> Bool {
        let drawn = frame.filter { $0.height > 1 }
        for (index, one) in drawn.enumerated() {
            for other in drawn[(index + 1)...] where one.maxY <= other.minY || other.maxY <= one.minY {
                return true
            }
        }
        return false
    }

    /// No bubble of the user's is drawn: the words are not on screen in this frame.
    nonisolated static func showsNone(_ frame: [CGRect]) -> Bool {
        !frame.contains { $0.height > 1 }
    }

    func start() {
        record()
        // After Core Animation's own commit observer on the same activities (its order is 2000000).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true, CFIndex.max
        ) { [weak self] _, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.record() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
        record()
    }

    private func record() {
        let own = HostedAccessibility.elements(under: view)
            .filter { $0.accessibilityLabel?.hasPrefix("You said:") == true }
            .map(\.accessibilityFrame)
        frames.append(own)
    }

    /// The frames in order, each run of frames showing the same number of the user's bubbles once,
    /// with its length and its last frame's places.
    var summary: String {
        var runs: [(count: Int, length: Int, last: [CGRect])] = []
        for frame in frames {
            if let run = runs.last, run.count == frame.count {
                runs[runs.count - 1] = (run.count, run.length + 1, frame)
            } else {
                runs.append((frame.count, 1, frame))
            }
        }
        return runs.map { run in
            let places = run.last.map { "\(Int($0.minY))-\(Int($0.maxY))" }.joined(separator: ",")
            return "\(run.count)[\(places)]x\(run.length)"
        }.joined(separator: " -> ")
    }
}
