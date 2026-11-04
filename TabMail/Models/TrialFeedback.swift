/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The one-time, anonymous "what held you back?" sheet shown over the inbox
/// after a card-free signup trial ends without a subscription.
///
/// The copy lives here and nowhere else. The answer is sent as exactly
/// `{version, reason, comment?}`: no account, user, device, token or cookie,
/// so the server cannot link it to anyone.
enum TrialFeedback {
    /// Question version. A reworded question gets a new number so the server
    /// counts its answers separately.
    static let version = 1

    static let navigationTitle = "Your free trial ended"
    static let question = "What held you back?"
    static let commentPlaceholder = "Anything else? (optional)"
    static let sendLabel = "Send"
    static let dismissLabel = "Not now"
    static let footnote = "Anonymous. Not linked to your account."

    /// Longest comment, in Unicode code points: the same measure and number
    /// the server checks (it refuses a longer one rather than cutting it).
    static let commentMaxCodePoints = 500

    /// The inbox row once the trial has ended (`InboxTrialReminder`).
    static let bannerEndedText = "Free trial ended"
    static let bannerFeedbackLabel = "Feedback"
    /// SF Symbol on the inbox row's Feedback button.
    static let bannerFeedbackSymbol = "bubble.left"
    /// The folder-list banner's feedback text button, once the trial ended.
    static let folderListFeedbackLabel = "Not for you? Tell us why"

    /// UserDefaults key: set once the sheet has appeared on this install, so
    /// it opens by itself only once. Not user data, only "already asked".
    static let askedKey = "trial_feedback_asked"

    /// UserDefaults key: set once an answer was SENT on this install; hides
    /// the row's Feedback button. Not now and closing the app leave it unset,
    /// so the user can still answer from the row. Not user data.
    static let sentKey = "trial_feedback_sent"

    /// The choices, in display order. Raw values are the server's reason keys.
    enum Reason: String, CaseIterable, Identifiable, Sendable {
        case tooExpensive = "too_expensive"
        case notUsedEnough = "not_used_enough"
        case missingFeature = "missing_feature"
        case preferOtherApp = "prefer_other_app"
        case somethingElse = "something_else"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tooExpensive: return "Too expensive"
            case .notUsedEnough: return "Didn't use it enough"
            case .missingFeature: return "Missing a feature I need"
            case .preferOtherApp: return "I prefer another app"
            case .somethingElse: return "Something else"
            }
        }
    }

    /// Whether the inbox should present the sheet now: an inbox view, signed
    /// in, not in demo mode, this launch's `/whoami` said the signup trial
    /// ENDED (`.ended` already means no subscription; an active trial or a
    /// subscriber is `.active` or `.noTrial`), not asked yet on this install,
    /// and nothing else presented (it never goes over another sheet; the next
    /// inbox appearance tries again).
    static func shouldPresent(
        isInbox: Bool,
        hasSession: Bool,
        isDemo: Bool,
        trialState: TrialState,
        alreadyAsked: Bool,
        somethingPresented: Bool
    ) -> Bool {
        isInbox && hasSession && !isDemo && trialState == .ended && !alreadyAsked && !somethingPresented
    }

    /// Whether a trial-ended banner (the inbox row's Feedback and the folder
    /// list's "Tell us why") offers feedback: only until an answer was sent.
    static func offersFeedback(sent: Bool) -> Bool {
        !sent
    }

    /// Whether a comment is within the cap, counted as the server counts.
    static func fits(_ comment: String) -> Bool {
        comment.unicodeScalars.count <= commentMaxCodePoints
    }

    private struct Body: Encodable {
        let version: Int
        let reason: String
        let comment: String?
    }

    /// The request for one answer. Built from scratch, so it carries no
    /// Authorization or client headers; cookies are off for it. A blank
    /// comment is left out; any other is sent exactly as typed.
    static func request(for reason: Reason, comment: String) -> URLRequest {
        let isBlank = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var request = URLRequest(url: BackendConfig.trialFeedbackURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Encoding three plain fields cannot fail.
        request.httpBody = try? encoder.encode(Body(version: version, reason: reason.rawValue, comment: isBlank ? nil : comment))
        return request
    }

    /// Send one answer, once. No retry: a lost answer is acceptable. The
    /// debug log says only whether it went; never the answer itself.
    static func send(_ reason: Reason, comment: String, session: URLSession) async {
        do {
            let (_, response) = try await session.data(for: request(for: reason, comment: comment))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            BackgroundSyncLogger.logDebug("[TrialFeedback] sent: HTTP \(status)")
        } catch {
            BackgroundSyncLogger.logDebug("[TrialFeedback] send failed: \((error as? URLError)?.code.rawValue ?? 0)")
        }
    }
}
