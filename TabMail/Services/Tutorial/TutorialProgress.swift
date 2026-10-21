/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The three tutorial parts, in order (owner V5, 2026-10-20). The copy says
/// "1 of 3", never "lesson" (owner 2026-10-21).
enum TutorialLesson: Int, CaseIterable, Sendable {
    case actOnEmail = 1
    case reuseReply = 2
    case askAnything = 3

    var title: String {
        switch self {
        case .actOnEmail: return "Act on email"
        case .reuseReply: return "Reuse a reply"
        case .askAnything: return "Ask anything"
        }
    }

    var next: TutorialLesson? { TutorialLesson(rawValue: rawValue + 1) }
}

/// What the sidebar tutorial row shows.
enum TutorialRowState: Equatable, Sendable {
    /// "Tutorial · done of total done", resumes `next`.
    case progress(done: Int, total: Int, next: TutorialLesson)
    /// Every part is done: a plain "Replay tutorial" row.
    case replay
}

/// Durable tutorial state (UserDefaults, per install): the first-run welcome
/// and which lessons are done. Never consent flags, never the call budget.
/// An unfinished lesson restarts from its beginning, so no step is stored.
struct TutorialProgress {
    /// Bump when the lessons change enough that earlier completion should not count.
    static let version = 1

    private enum Keys {
        static let version = "tutorial.version"
        static let completedLessons = "tutorial.completedLessons"
        static let welcomePending = "tutorial.welcomePending"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - First-run welcome

    /// Set by the launch check on a truly fresh install (`hasLaunchedBefore`
    /// unset and no database file). Updated and signed-out installs never get it.
    func markWelcomePending() {
        defaults.set(true, forKey: Keys.welcomePending)
    }

    /// True until the person chooses Start, Skip or Sign in on the welcome.
    /// Survives a force-quit on the welcome itself.
    var isWelcomePending: Bool { defaults.bool(forKey: Keys.welcomePending) }

    func dismissWelcome() {
        defaults.removeObject(forKey: Keys.welcomePending)
    }

    // MARK: - Lesson completion

    var completedLessons: Set<TutorialLesson> {
        guard defaults.integer(forKey: Keys.version) == Self.version else { return [] }
        let raw = defaults.array(forKey: Keys.completedLessons) as? [Int] ?? []
        return Set(raw.compactMap(TutorialLesson.init(rawValue:)))
    }

    func markCompleted(_ lesson: TutorialLesson) {
        var done = completedLessons
        done.insert(lesson)
        defaults.set(Self.version, forKey: Keys.version)
        defaults.set(done.map(\.rawValue).sorted(), forKey: Keys.completedLessons)
    }

    static func rowState(completed done: Set<TutorialLesson>) -> TutorialRowState {
        let all = TutorialLesson.allCases
        guard let next = all.first(where: { !done.contains($0) }) else { return .replay }
        return .progress(done: all.filter(done.contains).count, total: all.count, next: next)
    }
}
