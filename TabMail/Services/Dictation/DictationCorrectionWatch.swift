/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Watches the chat pill's input field after a dictation lands in it and learns the user's
/// corrections of it (ADR-IOS-086), as TabMail Voice's `CorrectionWatch` watches the field it
/// pasted into (ADR-DESK-038). Every `interval` for `duration`, it reads the field: each change
/// that stays for one interval is compared with the field as the dictation left it
/// (`DictationCorrections`), and so is the input when it is sent, which may be before an edit has
/// stayed. The words the last comparison teaches are learned when the watch ends, not before: a
/// pause in the middle of an edit ("tabmail" on the way to "TabMail") teaches nothing, though the
/// field is cleared before its last spelling stays. One watch at
/// a time: a new one, `stop` (the next dictation, the pill going away), the send or the end of
/// `duration` ends the last. The field's text never leaves the device; the words learned are only
/// counted in the debug log.
@MainActor
final class DictationCorrectionWatch {
    private struct Session {
        let pasted: String
        /// The field as the dictation left it.
        let before: String
        var previous: String
        let field: @MainActor () -> String
    }

    private let learn: @MainActor ([String]) -> Void
    private let interval: Duration
    private let duration: Duration
    private var session: Session?
    /// What the watch's last comparison teaches.
    private var pending: [String] = []
    private var task: Task<Void, Never>?

    init(
        learn: @escaping @MainActor ([String]) -> Void,
        interval: Duration = DictationConfig.correctionPollInterval,
        duration: Duration = DictationConfig.correctionWatchDuration
    ) {
        self.learn = learn
        self.interval = interval
        self.duration = duration
    }

    var isWatching: Bool { session != nil }

    /// Watches the field `field` reads, into which `pasted` was just appended.
    func watch(pasted: String, field: @escaping @MainActor () -> String) {
        stop()
        let before = field()
        guard !pasted.isEmpty, before.contains(pasted) else { return }
        session = Session(pasted: pasted, before: before, previous: before, field: field)
        let (interval, duration) = (interval, duration)
        task = Task { [weak self] in
            var elapsed = Duration.zero
            while elapsed < duration {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                elapsed += interval
                self.poll()
            }
            guard !Task.isCancelled else { return }
            BackgroundSyncLogger.logDebug("[Dictation] correction watch over")
            self?.stop()
        }
    }

    /// One read of the field, compared: an edit that has stayed since the last read is what the
    /// watch learns, one still changing clears it. Run every `interval`; the tests run it by hand.
    func poll() {
        guard var session else { return }
        let field = session.field()
        settle(session, on: field, held: field == session.previous)
        session.previous = field
        self.session = session
    }

    /// The input as it is sent: compared, and the watch ends.
    func finish(field: String) {
        if let session { settle(session, on: field, held: true) }
        stop()
    }

    /// Ends the watch, learning what its last comparison teaches.
    func stop() {
        task?.cancel()
        task = nil
        session = nil
        let words = pending
        pending = []
        guard !words.isEmpty else { return }
        BackgroundSyncLogger.logDebug("[Dictation] learning \(words.count) word(s)")
        learn(words)
    }

    /// Compares `field` with the field as the dictation left it. A comparison that respells something
    /// new, or has the dictation back as it was (an undo), replaces what an earlier one taught: with
    /// what it teaches once the field has `held` since the last read (or is sent), with nothing while
    /// it is still changing, so a spelling paused on and then changed is never learned. One that
    /// respells nothing (the field cleared, other text, a word half retyped) leaves it.
    private func settle(_ session: Session, on field: String, held: Bool) {
        let words = DictationCorrections.learned(pasted: session.pasted, before: session.before, after: field)
        guard !words.isEmpty || field.contains(session.pasted), words != pending else { return }
        pending = held ? words : []
    }
}
