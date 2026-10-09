/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import DeclaredAgeRange
import SwiftUI

/// App Store age assurance (owner 2026-10-08). Where a law makes developers
/// check age through the App Store (Texas SB 2420, Utah, Louisiana, …), Apple
/// says an 18+ rating does not exempt the app: it must ask the Declared Age
/// Range API and act on the answer. TabMail is for adults only, so a minor is
/// refused outright — there is no parental-consent path to support.
///
/// This is an APP-level check, separate from the account-level age and terms
/// screen (`ConsentGateView`): the app also works as a plain mail client
/// without a TabMail account, so the check cannot live in sign-up alone.
/// No age answer is stored; the App Store is asked again at every launch and
/// foreground. Apple documents that the system caches the answer and returns
/// it until the person's next birthday, so the repeat asks do not show its
/// sheet again. Apple's sheet does not run in the Simulator, so tests give
/// `decide` the answers iOS would (owner 2026-10-09).
enum AppStoreAgeCheck {
    enum Status: Equatable {
        /// Not yet asked, or the region question itself failed: asked again on
        /// the next foreground. Never shown as a gate. Owner 2026-10-08: a
        /// failed region question stays open, because Apple does not say when
        /// it fails and blocking would lock out people outside any regulated
        /// region (a declined or failed age answer in one still blocks).
        case notChecked
        /// Outside a regulated region, or the App Store confirms an adult.
        case allowed
        /// The App Store reports someone under the minimum age.
        case minor
        /// A regulated region, but no age range came back (declined or failed).
        case unconfirmed

        /// `.minor` and `.unconfirmed` cover the whole app (`AppStoreAgeGateView`).
        var blocksApp: Bool {
            self == .minor || self == .unconfirmed
        }
    }

    /// The App Store's answer, reduced to what the decision needs.
    enum Answer: Equatable {
        case declined
        case shared(lowerBound: Int?, upperBound: Int?)
    }

    /// Apple: `lowerBound == nil` is below the lowest gate; `upperBound < gate`
    /// is under that age; `lowerBound >= gate` meets it. Regulated regions may
    /// answer with their own legal age bands instead of our gate, so all three
    /// are read rather than one.
    static func classify(_ answer: Answer, minAgeYears: Int = AgeAndTermsConsent.minAgeYears) -> Status {
        switch answer {
        case .declined:
            return .unconfirmed
        case let .shared(lowerBound, upperBound):
            if let upperBound, upperBound < minAgeYears { return .minor }
            guard let lowerBound else { return .minor }
            return lowerBound >= minAgeYears ? .allowed : .unconfirmed
        }
    }

    /// The App Store's response, reduced to an `Answer`. A kind of response
    /// this SDK does not know confirms no age.
    static func answer(for response: AgeRangeService.Response) -> Answer {
        switch response {
        case .declinedSharing:
            return .declined
        case .sharing(let range):
            return .shared(lowerBound: range.lowerBound, upperBound: range.upperBound)
        @unknown default:
            return .declined
        }
    }

    /// Ask the App Store. `request` is SwiftUI's `\.requestAgeRange`.
    @MainActor
    static func run(request: DeclaredAgeRangeAction) async -> Status {
        // `isEligibleForAgeFeatures`, which tells whether the law applies
        // here, needs iOS 26.2, so earlier versions are not asked.
        guard #available(iOS 26.2, *) else { return .allowed }
        // Apple's SwiftUI action is not marked Sendable, but it only presents
        // the system sheet and returns its answer; nothing here shares it.
        nonisolated(unsafe) let request = request
        return await decide(
            isRegulated: { try await isInRegulatedRegion() },
            askAge: { answer(for: try await request(ageGates: AgeAndTermsConsent.minAgeYears)) }
        )
    }

    /// The check, given the App Store's two questions: does the law apply
    /// here, and what age range does the person share. `run` passes Apple's
    /// real calls; tests pass the answers iOS would give, since Apple's age
    /// sheet does not run in the Simulator.
    @MainActor
    static func decide(
        isRegulated: () async throws -> Bool,
        askAge: () async throws -> Answer
    ) async -> Status {
        let regulated: Bool
        do {
            regulated = try await isRegulated()
        } catch {
            BackgroundSyncLogger.logDebug("[AppStoreAgeCheck] Region check failed, asking again on next foreground: \(error)")
            return .notChecked
        }
        guard regulated else { return .allowed }
        do {
            return classify(try await askAge())
        } catch {
            BackgroundSyncLogger.logDebug("[AppStoreAgeCheck] Age range request failed: \(error)")
            return .unconfirmed
        }
    }

    /// What the app shows after a check: a failed region question
    /// (`.notChecked`) keeps the previous answer, anything else replaces it.
    static func shown(previous: Status, checked: Status) -> Status {
        checked == .notChecked ? previous : checked
    }

    /// Off the main actor: `AgeRangeService` is not `Sendable`.
    @available(iOS 26.2, *)
    nonisolated private static func isInRegulatedRegion() async throws -> Bool {
        try await AgeRangeService.shared.isEligibleForAgeFeatures
    }

    // MARK: - Significant updates

    /// Significant app updates (Utah, Louisiana; owner 2026-10-09): every new
    /// major.minor version (1.7 to 1.8) counts as one. Where Apple reports the
    /// law needs it, Apple's acknowledgment is shown once for that version.
    /// Only the last acknowledged version is stored.
    enum SignificantUpdate {
        static let acknowledgedVersionKey = "AppStoreAgeCheck.significantUpdateVersion"

        enum Decision: Equatable {
            /// This version was already handled.
            case nothing
            /// First run of this code: nothing to compare, so remember the version.
            case record
            /// A new major.minor version: ask Apple whether the notice is required.
            case askApple
        }

        /// "1.8.2" is "1.8"; anything without two parts is not a version.
        static func majorMinor(_ version: String) -> String? {
            let parts = version.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            return "\(parts[0]).\(parts[1])"
        }

        /// `acknowledged` is the stored major.minor; `current` the app's version.
        static func decide(acknowledged: String?, current: String) -> Decision {
            guard let current = majorMinor(current) else { return .nothing }
            guard let acknowledged else { return .record }
            return acknowledged == current ? .nothing : .askApple
        }

        static func updateDescription(_ version: String) -> String {
            "TabMail \(version) is a significant update with new features and changes. You can read what\u{2019}s new on TabMail\u{2019}s App Store page."
        }
    }

    /// Show Apple's significant update acknowledgment when a new major.minor
    /// version runs where the law requires it. Called after an `.allowed` age
    /// check. A failure is logged and asked again on the next foreground.
    @MainActor
    static func acknowledgeSignificantUpdate() async {
        guard #available(iOS 26.4, *) else { return }
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let version = SignificantUpdate.majorMinor(current) else { return }
        let defaults = UserDefaults.standard
        switch SignificantUpdate.decide(
            acknowledged: defaults.string(forKey: SignificantUpdate.acknowledgedVersionKey), current: current
        ) {
        case .nothing:
            return
        case .record:
            defaults.set(version, forKey: SignificantUpdate.acknowledgedVersionKey)
        case .askApple:
            do {
                if try await requiresSignificantUpdateNotice() {
                    guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                    try await AgeRangeService.shared.showSignificantUpdateAcknowledgment(
                        in: scene, updateDescription: SignificantUpdate.updateDescription(version))
                }
                defaults.set(version, forKey: SignificantUpdate.acknowledgedVersionKey)
            } catch {
                BackgroundSyncLogger.logDebug("[AppStoreAgeCheck] Significant update acknowledgment failed, asking again on next foreground: \(error)")
            }
        }
    }

    /// Off the main actor: `AgeRangeService` is not `Sendable`.
    @available(iOS 26.4, *)
    nonisolated private static func requiresSignificantUpdateNotice() async throws -> Bool {
        let features = try await AgeRangeService.shared.requiredRegulatoryFeatures
        return features.contains(.significantAppChangeRequiresAdultNotification)
            || features.contains(.significantAppChangeRequiresParentalConsent)
    }
}
