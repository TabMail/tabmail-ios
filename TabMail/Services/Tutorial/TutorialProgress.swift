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

/// Something a part teaches, done in the real app outside the tutorial. A
/// part counts as done once the person has found every one of its moves on
/// their own (owner 2026-10-25): part 1 needs both a tag tap and a tag change.
enum TutorialDiscovery: String, CaseIterable, Sendable {
    /// Tapped an action tag, which ran its action.
    case tagTap
    /// Changed a tag from the hold menu.
    case retag
    /// Created a template.
    case template
    /// Sent a message in the inbox chat.
    case inboxChat

    var lesson: TutorialLesson {
        switch self {
        case .tagTap, .retag: return .actOnEmail
        case .template: return .reuseReply
        case .inboxChat: return .askAnything
        }
    }
}

/// The sidebar tutorial row: "Tutorial · done of total done", resumes `next`.
/// Once every part is done there is no row; replay is the last sidebar item
/// above Debug and in the debug menu (owner 2026-10-21, 2026-10-26).
struct TutorialRowState: Equatable, Sendable {
    let done: Int
    let total: Int
    let next: TutorialLesson
}

/// Durable tutorial state (UserDefaults, per install): the first-run welcome,
/// which lessons are done, and which of their moves the person found on their
/// own outside it. Never consent flags, never the call budget.
/// An unfinished lesson restarts from its beginning, so no step is stored.
struct TutorialProgress {
    /// Bump when the lessons change enough that earlier completion should not count.
    static let version = 1

    private enum Keys {
        static let version = "tutorial.version"
        static let completedLessons = "tutorial.completedLessons"
        static let discoveries = "tutorial.discoveries"
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
        adoptCurrentVersion()
        var done = completedLessons
        done.insert(lesson)
        defaults.set(done.map(\.rawValue).sorted(), forKey: Keys.completedLessons)
    }

    // MARK: - Found on their own

    var discoveries: Set<TutorialDiscovery> {
        guard defaults.integer(forKey: Keys.version) == Self.version else { return [] }
        let raw = defaults.array(forKey: Keys.discoveries) as? [String] ?? []
        return Set(raw.compactMap(TutorialDiscovery.init(rawValue:)))
    }

    /// Records `discovery`, and completes its part once all of that part's
    /// moves have been found.
    func markDiscovered(_ discovery: TutorialDiscovery) {
        adoptCurrentVersion()
        var found = discoveries
        found.insert(discovery)
        defaults.set(found.map(\.rawValue).sorted(), forKey: Keys.discoveries)
        let lesson = discovery.lesson
        if TutorialDiscovery.allCases.filter({ $0.lesson == lesson }).allSatisfy(found.contains) {
            markCompleted(lesson)
        }
    }

    /// Drops completion and discoveries recorded under an older `version`, so
    /// a write under the current one never revives them.
    private func adoptCurrentVersion() {
        guard defaults.integer(forKey: Keys.version) != Self.version else { return }
        defaults.removeObject(forKey: Keys.completedLessons)
        defaults.removeObject(forKey: Keys.discoveries)
        defaults.set(Self.version, forKey: Keys.version)
    }

    /// nil once every part is done.
    static func rowState(completed done: Set<TutorialLesson>) -> TutorialRowState? {
        let all = TutorialLesson.allCases
        guard let next = all.first(where: { !done.contains($0) }) else { return nil }
        return TutorialRowState(done: all.filter(done.contains).count, total: all.count, next: next)
    }
}
