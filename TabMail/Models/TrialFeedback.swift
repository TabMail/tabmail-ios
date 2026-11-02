/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

enum TrialFeedbackReason: String, CaseIterable, Identifiable, Sendable {
    case priceValue = "price_value"
    case notEnoughUse = "not_enough_use"
    case missingFeature = "missing_feature"
    case aiReliability = "ai_reliability"
    case existingWorkflow = "existing_workflow"
    case other = "other_or_prefer_not_to_say"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .priceValue: "The price is higher than the value I get."
        case .notEnoughUse: "I haven't used it enough to decide."
        case .missingFeature: "It's missing something I need."
        case .aiReliability: "The AI results aren't reliable enough for me."
        case .existingWorkflow: "I prefer my existing email workflow."
        case .other: "Another reason / prefer not to say."
        }
    }
}

/// One device-level choice, with no account key, answer or submission ID stored.
@MainActor @Observable
final class TrialFeedbackPromptState {
    static let shared = TrialFeedbackPromptState()
    private static let suppressionKey = "trialFeedback.suppressed"
    private let defaults: UserDefaults
    private(set) var isSuppressed: Bool
    private(set) var deferredThisRun = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSuppressed = defaults.bool(forKey: Self.suppressionKey)
    }

    func notNow() { deferredThisRun = true }
    func doNotAskAgain() {
        isSuppressed = true
        defaults.set(true, forKey: Self.suppressionKey)
    }
    func submitted() { doNotAskAgain() }

    #if DEBUG
    /// Native tests restore the shared in-memory choice after exercising the
    /// real inbox. The test scope restores its UserDefaults snapshot separately.
    func restoreTestSnapshot(suppressed: Bool, deferred: Bool) {
        isSuppressed = suppressed
        deferredThisRun = deferred
    }
    #endif
}

protocol TrialFeedbackSubmitting: Sendable {
    func submit(reason: TrialFeedbackReason) async throws
}

/// Ephemeral form state. Only an explicit submit starts a request.
@MainActor @Observable
final class TrialFeedbackFlow {
    var selectedReason: TrialFeedbackReason?
    private(set) var isSubmitting = false
    private(set) var isComplete = false
    private(set) var errorText: String?
    let prompt: TrialFeedbackPromptState
    private let client: any TrialFeedbackSubmitting

    init(prompt: TrialFeedbackPromptState, client: any TrialFeedbackSubmitting = TrialFeedbackClient()) {
        self.prompt = prompt
        self.client = client
    }

    var canSubmit: Bool { selectedReason != nil && !isSubmitting && !isComplete }

    func submit() async {
        guard canSubmit, let reason = selectedReason else { return }
        // Capture the chosen answer before suspension; no account state is read.
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            try await client.submit(reason: reason)
            guard !Task.isCancelled else { return }
            isComplete = true
            selectedReason = nil
            prompt.submitted()
        } catch {
            guard !Task.isCancelled else { return }
            // Delivery may be uncertain; never claim that no counter was written.
            errorText = "We couldn't confirm delivery. You can try again if you'd like."
        }
    }
}
