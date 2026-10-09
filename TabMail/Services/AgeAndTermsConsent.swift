/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The age and terms screen (`ConsentGateView`, owner 2026-10-08). Mirrors the
/// website's `consent.js` + `public-config.js` `consent` block:
///
/// - the person enters a date of birth on a neutral screen; it is compared
///   with the minimum age ON THE DEVICE and never sent or stored — only the
///   outcome is kept (`confirmed_age_18` etc. in Supabase `user_metadata`);
/// - a failed check deletes the new account (`POST /account/age-ineligible`),
///   signs out, and blocks this device for `ineligibleBlockDays`, keeping only
///   the block's expiry time;
/// - push and Device Sync start only after the screen is passed
///   (`isComplete`); the push and device-sync workers enforce the same rule.
enum AgeAndTermsConsent {
    /// Minimum age to use TabMail.
    static let minAgeYears = 18
    /// How many years back the Year list goes.
    static let birthYearsShown = 120
    /// How long a failed check blocks this device from offering the screen again.
    static let ineligibleBlockDays = 30
    /// Legal document version recorded with the agreement — the website's
    /// `public-config.js` `LEGAL_VERSION_ISO`.
    static let legalVersion = "2026-09-29"

    /// The app-wide "passed the age and terms screen" flag (RootView's
    /// `@AppStorage`). Reset on sign-out, restored per user on sign-in.
    static let completedKey = "hasCompletedConsentGate"
    /// Expiry (seconds since 1970) of a failed-check block. The only value a
    /// failed check stores — never the date of birth.
    static let ineligibleUntilKey = "ageCheckIneligibleUntil"

    /// True once this signed-in user has passed the age and terms screen.
    /// Push registration and Device Sync stay off until then.
    static func isComplete(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    /// What a passed screen saves to Supabase `user_metadata` — the same
    /// flags as the website. Only the outcome: no date of birth, no age.
    static func agreementMetadata(at timestamp: String) -> [String: Any] {
        [
            "confirmed_age_18": true,
            "confirmed_age_min_years": minAgeYears,
            "confirmed_age_at": timestamp,
            "age_check_method": "date_of_birth",
            "agreed_to_terms": true,
            "agreed_to_terms_version": legalVersion,
            "agreed_to_terms_at": timestamp,
            "agreed_to_privacy": true,
            "agreed_to_privacy_version": legalVersion,
            "agreed_to_privacy_at": timestamp,
            "consent_source": "ios/consent",
        ]
    }

    // MARK: - Age check

    enum Outcome: Equatable {
        case invalidDate
        case eligible
        case ineligible
    }

    /// Plain Gregorian years, months and days, like the website, whatever
    /// calendar the phone is set to.
    static var calendar: Calendar { Calendar(identifier: .gregorian) }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// The Year menu, newest first: this Gregorian year back `birthYearsShown` years.
    static func birthYears(today: Date) -> [Int] {
        let thisYear = calendar.component(.year, from: today)
        return Array(stride(from: thisYear, through: thisYear - birthYearsShown, by: -1))
    }

    /// Whole years between the birth date and `today`, the website's
    /// `ageInYears` exactly: a birthday not yet reached this year does not
    /// count (so 29 February birthdays turn a year older on 1 March in common
    /// years). `nil` for a date that does not exist or lies in the future.
    static func ageInYears(year: Int, month: Int, day: Int, today: Date) -> Int? {
        let calendar = Self.calendar
        let parts = DateComponents(year: year, month: month, day: day)
        guard let birth = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: birth)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let nowYear = now.year, let nowMonth = now.month, let nowDay = now.day else { return nil }
        guard calendar.startOfDay(for: birth) <= calendar.startOfDay(for: today) else { return nil }
        var age = nowYear - year
        if nowMonth < month || (nowMonth == month && nowDay < day) { age -= 1 }
        return age
    }

    static func evaluate(year: Int, month: Int, day: Int, today: Date) -> Outcome {
        guard let age = ageInYears(year: year, month: month, day: day, today: today) else {
            return .invalidDate
        }
        return age >= minAgeYears ? .eligible : .ineligible
    }

    /// The screen's check: `evaluate`, and a failed check blocks this device
    /// for `ineligibleBlockDays`. The date itself is not kept.
    static func check(year: Int, month: Int, day: Int, now: Date = Date(), defaults: UserDefaults = .standard) -> Outcome {
        let outcome = evaluate(year: year, month: month, day: day, today: now)
        if outcome == .ineligible { blockDevice(now: now, defaults: defaults) }
        return outcome
    }

    // MARK: - Failed-check block

    static func blockDevice(now: Date = Date(), defaults: UserDefaults = .standard) {
        let until = now.addingTimeInterval(TimeInterval(ineligibleBlockDays) * 24 * 60 * 60)
        defaults.set(until.timeIntervalSince1970, forKey: ineligibleUntilKey)
    }

    /// True while a failed check's block is in force. An expired block is
    /// removed, so nothing outlives its purpose.
    static func isDeviceBlocked(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: ineligibleUntilKey) != nil else { return false }
        if now.timeIntervalSince1970 < defaults.double(forKey: ineligibleUntilKey) { return true }
        defaults.removeObject(forKey: ineligibleUntilKey)
        return false
    }

    // MARK: - Deletion handshake

    /// What OK on the refusal does once the deletion request has finished
    /// (owner 2026-10-09: sign out only after billing has answered, so a lost
    /// request cannot leave the account to the 30-day sweep).
    enum DeletionHandshake: Equatable {
        /// Billing queued the deletion, or refused it for good (a 4xx such as
        /// an account that has already consented): sign out.
        case signOut
        /// No answer (connection failure, timeout, 429, 5xx): stay signed in on
        /// the refusal and send the request again on the next OK.
        case retry
    }

    /// `error` is the deletion request's error, nil when billing acknowledged it.
    static func deletionHandshake(after error: Error?) -> DeletionHandshake {
        guard let error else { return .signOut }
        if error is URLError { return .retry }
        if let backend = error as? BackendError, backend.isRetriable { return .retry }
        return .signOut
    }
}
