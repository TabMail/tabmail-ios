/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import DeclaredAgeRange
import Foundation
import Testing
@testable import TabMail

/// Age and terms screen (owner 2026-10-08). Invariants:
/// - the age rule is the website's `ageInYears` exactly (birthday reached or not),
///   in plain Gregorian years;
/// - an impossible or future date is an input error, never a pass or a fail;
/// - a failed check blocks this device, storing ONLY the block's expiry, which
///   lapses on its own;
/// - the saved agreement carries the outcome only — no date of birth;
/// - the App Store's answer refuses anyone it places under the minimum age, and
///   a refusal covers the whole app.
/// Every date is computed from today. The age rule is called without a
/// calendar, as the screen calls it; `calendar` here only builds the inputs.
@Suite("Age and terms screen: age rule, device block, saved agreement, App Store answer")
struct AgeAndTermsConsentTests {
    private let calendar = Calendar(identifier: .gregorian)
    /// ADR-034's values, written out rather than read from the constants, so a
    /// wrong constant fails here.
    private let minAge = 18
    private let blockDays = 30

    /// The Gregorian birth date exactly `years` years before `today`, plus
    /// `months` months and `days` days.
    private func born(yearsAgo years: Int, plusMonths months: Int = 0, plusDays days: Int = 0, from today: Date = Date()) -> (year: Int, month: Int, day: Int) {
        var date = calendar.date(byAdding: .year, value: -years, to: calendar.startOfDay(for: today))!
        date = calendar.date(byAdding: .month, value: months, to: date)!
        date = calendar.date(byAdding: .day, value: days, to: date)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year!, parts.month!, parts.day!)
    }

    private func evaluate(_ birth: (year: Int, month: Int, day: Int), today: Date = Date()) -> AgeAndTermsConsent.Outcome {
        AgeAndTermsConsent.evaluate(year: birth.year, month: birth.month, day: birth.day, today: today)
    }

    @Test func theMinimumAgeIsReachedOnTheBirthdayAndNotADayBefore() {
        #expect(evaluate(born(yearsAgo: minAge)) == .eligible)
        #expect(evaluate(born(yearsAgo: minAge, plusDays: 1)) == .ineligible)
        #expect(evaluate(born(yearsAgo: minAge + 22)) == .eligible)
        #expect(evaluate(born(yearsAgo: 10)) == .ineligible)
    }

    /// A birthday in a later month of this year has not been reached yet,
    /// whatever the day of the month.
    @Test func theMinimumAgeIsNotReachedAMonthBeforeTheBirthday() throws {
        // From December one month on is next year, so start a month earlier.
        let now = Date()
        let today = calendar.component(.month, from: now) == 12
            ? try #require(calendar.date(byAdding: .month, value: -1, to: now)) : now
        #expect(evaluate(born(yearsAgo: minAge, plusMonths: 1, from: today), today: today) == .ineligible)
        let nextMonth = born(yearsAgo: minAge, plusMonths: 1, from: today)
        #expect(evaluate((nextMonth.year, nextMonth.month, 1), today: today) == .ineligible, "the first of next month")
        #expect(evaluate(born(yearsAgo: minAge, plusMonths: -1, from: today), today: today) == .eligible)
    }

    /// Plain Gregorian years and English month names, like the website.
    @Test func theScreenUsesGregorianYearsAndMonths() {
        #expect(AgeAndTermsConsent.calendar.identifier == .gregorian)
        #expect(evaluate(born(yearsAgo: minAge + 12)) == .eligible)
        #expect(evaluate(born(yearsAgo: minAge - 1, plusMonths: -7)) == .ineligible)
        let years = AgeAndTermsConsent.birthYears(today: Date())
        #expect(years.first == calendar.component(.year, from: Date()))
        #expect(years.count == AgeAndTermsConsent.birthYearsShown + 1)
        #expect(years.contains(born(yearsAgo: minAge + 12).year))
        #expect(AgeAndTermsConsent.monthNames.count == 12)
    }

    @Test func impossibleAndFutureDatesAreInputErrors() {
        let recentYear = calendar.component(.year, from: Date()) - 30
        #expect(AgeAndTermsConsent.evaluate(year: recentYear, month: 2, day: 30, today: Date()) == .invalidDate)
        #expect(AgeAndTermsConsent.evaluate(year: recentYear, month: 4, day: 31, today: Date()) == .invalidDate)
        #expect(AgeAndTermsConsent.evaluate(year: recentYear, month: 13, day: 1, today: Date()) == .invalidDate)
        #expect(evaluate(born(yearsAgo: 0, plusDays: 1)) == .invalidDate)
        #expect(evaluate(born(yearsAgo: 0)) == .ineligible, "born today is a valid date")
    }

    /// Matches the website: a 29 February birthday counts on 1 March in a
    /// common year, not on 28 February.
    @Test func aLeapDayBirthdayCountsFromTheFirstOfMarchInACommonYear() throws {
        let thisYear = calendar.component(.year, from: Date())
        let leapYear = try #require((thisYear - 2 * minAge...thisYear - minAge).last { year in
            calendar.date(from: DateComponents(year: year, month: 2, day: 29)).map {
                calendar.component(.day, from: $0) == 29
            } ?? false
        })
        let birthdayYear = leapYear + minAge
        let feb28 = try #require(calendar.date(from: DateComponents(year: birthdayYear, month: 2, day: 28)))
        let mar1 = try #require(calendar.date(from: DateComponents(year: birthdayYear, month: 3, day: 1)))
        #expect(AgeAndTermsConsent.ageInYears(year: leapYear, month: 2, day: 29, today: feb28) == minAge - 1)
        #expect(AgeAndTermsConsent.ageInYears(year: leapYear, month: 2, day: 29, today: mar1) == minAge)
    }

    @Test func aFailedCheckStoresOnlyTheBlockExpiryAndTheBlockLapses() throws {
        let suite = "age-gate-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let days = TimeInterval(blockDays) * 24 * 60 * 60

        #expect(!AgeAndTermsConsent.isDeviceBlocked(now: now, defaults: defaults))
        AgeAndTermsConsent.blockDevice(now: now, defaults: defaults)
        #expect(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys) == [AgeAndTermsConsent.ineligibleUntilKey],
                "only the expiry time is stored")
        #expect(AgeAndTermsConsent.isDeviceBlocked(now: now.addingTimeInterval(days - 60), defaults: defaults))
        #expect(!AgeAndTermsConsent.isDeviceBlocked(now: now.addingTimeInterval(days + 60), defaults: defaults))
        #expect(defaults.object(forKey: AgeAndTermsConsent.ineligibleUntilKey) == nil, "an expired block is removed")
    }

    /// The screen's check blocks this device on a failure, and only then.
    @Test func onlyAFailedCheckBlocksTheDevice() throws {
        let suite = "age-gate-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        func check(_ birth: (year: Int, month: Int, day: Int)) -> AgeAndTermsConsent.Outcome {
            AgeAndTermsConsent.check(year: birth.year, month: birth.month, day: birth.day, now: now, defaults: defaults)
        }

        #expect(check(born(yearsAgo: minAge, from: now)) == .eligible)
        #expect(check(born(yearsAgo: 0, plusDays: 1, from: now)) == .invalidDate)
        #expect(!AgeAndTermsConsent.isDeviceBlocked(now: now, defaults: defaults), "a pass or an input error does not block")
        #expect(check(born(yearsAgo: minAge, plusDays: 1, from: now)) == .ineligible)
        #expect(AgeAndTermsConsent.isDeviceBlocked(now: now, defaults: defaults), "a failed check blocks this device")
    }

    @Test func theSavedAgreementCarriesTheOutcomeAndNoBirthDate() {
        let metadata = AgeAndTermsConsent.agreementMetadata(at: "stamp")
        for flag in ["confirmed_age_18", "agreed_to_terms", "agreed_to_privacy"] {
            #expect(metadata[flag] as? Bool == true, "\(flag) must be exactly true for the backend gate")
        }
        #expect(metadata["confirmed_age_min_years"] as? Int == minAge)
        #expect(metadata["age_check_method"] as? String == "date_of_birth")
        for stamp in ["confirmed_age_at", "agreed_to_terms_at", "agreed_to_privacy_at"] {
            #expect(metadata[stamp] as? String == "stamp", "\(stamp) records when the screen was passed")
        }
        #expect(metadata["agreed_to_terms_version"] as? String == AgeAndTermsConsent.legalVersion)
        #expect(metadata["agreed_to_privacy_version"] as? String == AgeAndTermsConsent.legalVersion)
        let keys = metadata.keys.joined(separator: " ").lowercased()
        #expect(!keys.contains("birth") && !keys.contains("dob") && !keys.contains("bday"))
        let values = metadata.values.map { "\($0)" }
        let birthYear = String(born(yearsAgo: minAge).year)
        #expect(!values.contains(birthYear))
    }

    @Test func theAppStoreAnswerRefusesEveryoneItPlacesUnderTheMinimumAge() {
        typealias Check = AppStoreAgeCheck
        #expect(Check.classify(.shared(lowerBound: minAge, upperBound: nil)) == .allowed)
        #expect(Check.classify(.shared(lowerBound: minAge + 3, upperBound: nil)) == .allowed)
        // Regulated regions answer with their own legal bands: under 13, 13-15, 16-17.
        #expect(Check.classify(.shared(lowerBound: nil, upperBound: 12)) == .minor)
        #expect(Check.classify(.shared(lowerBound: 13, upperBound: 15)) == .minor)
        #expect(Check.classify(.shared(lowerBound: 16, upperBound: minAge - 1)) == .minor)
        #expect(Check.classify(.shared(lowerBound: nil, upperBound: nil)) == .minor, "below the lowest gate")
        // A band that straddles the minimum age neither confirms an adult nor a minor.
        #expect(Check.classify(.shared(lowerBound: 16, upperBound: nil)) == .unconfirmed)
        #expect(Check.classify(.shared(lowerBound: 16, upperBound: minAge + 2)) == .unconfirmed)
        #expect(Check.classify(.declined) == .unconfirmed)
        #expect(Check.status(for: .declinedSharing) == .unconfirmed, "declining to share is not a pass")
    }

    @Test func aMinorOrAnUnconfirmedAgeCoversTheWholeApp() {
        #expect(AppStoreAgeCheck.Status.minor.blocksApp)
        #expect(AppStoreAgeCheck.Status.unconfirmed.blocksApp)
        #expect(!AppStoreAgeCheck.Status.allowed.blocksApp)
        #expect(!AppStoreAgeCheck.Status.notChecked.blocksApp, "owner 2026-10-08: a failed region question stays open")
    }

    // Owner 2026-10-09: every major.minor bump (1.7 to 1.8) is a significant
    // update; a patch (1.7.1 to 1.7.2) is not.
    @Test func aNewMajorMinorVersionIsASignificantUpdate() {
        typealias Update = AppStoreAgeCheck.SignificantUpdate
        #expect(Update.majorMinor("1.8") == "1.8")
        #expect(Update.majorMinor("1.8.2") == "1.8")
        #expect(Update.majorMinor("2") == nil)
        #expect(Update.decide(acknowledged: "1.7", current: "1.8.0") == .askApple)
        #expect(Update.decide(acknowledged: "1.9", current: "2.0") == .askApple)
        #expect(Update.decide(acknowledged: "1.7", current: "1.7.3") == .nothing, "a patch release is not significant")
        #expect(Update.decide(acknowledged: nil, current: "1.7.3") == .record, "first run: nothing to compare")
        #expect(Update.decide(acknowledged: "1.7", current: "x") == .nothing)
    }

    @Test func theDeletionRequestSendsOnlyARequestId() throws {
        let request = try BillingClient.makeAgeIneligibleDeletionRequest(
            baseURL: URL(string: "https://billing.example.com")!, token: "token-a", requestId: "req-1")
        #expect(request.url?.absoluteString == "https://billing.example.com/account/age-ineligible")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-a")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["request_id": "req-1"])
    }

    /// Owner 2026-10-09: OK on the refusal signs out only after billing has
    /// answered the deletion request. No answer keeps the person on the
    /// refusal, so the next OK sends it again; a definitive refusal signs out,
    /// since asking again would get the same answer.
    @Test func theRefusalSignsOutOnlyOnceBillingHasAnsweredTheDeletion() {
        typealias Consent = AgeAndTermsConsent
        #expect(Consent.deletionHandshake(after: nil) == .signOut, "billing queued the deletion")
        for noAnswer: Error in [
            URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.networkConnectionLost),
            BackendError.requestFailed(statusCode: 0), BackendError.requestFailed(statusCode: 408),
            BackendError.requestFailed(statusCode: 429), BackendError.requestFailed(statusCode: 500),
            BackendError.requestFailed(statusCode: 503),
        ] {
            #expect(Consent.deletionHandshake(after: noAnswer) == .retry, "no answer: \(noAnswer)")
        }
        for refusal: Error in [
            BackendError.requestFailed(statusCode: 400), BackendError.requestFailed(statusCode: 409),
            BackendError.unauthorized,
        ] {
            #expect(Consent.deletionHandshake(after: refusal) == .signOut, "definitive refusal: \(refusal)")
        }
    }
}

/// The significant update check stores this version's major.minor on its first
/// run, so the next launch of the same version does nothing, and a repeat run
/// changes nothing. It reads and writes the app's standard defaults, hence
/// `.serialized` and `.processGlobalState`; the previous value is restored.
@Suite("Significant update: the handled version is stored", .serialized, .processGlobalState)
@MainActor
struct SignificantUpdateStorageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)),
        "acknowledgeSignificantUpdate runs on iOS 26.4 and later"))
    func firstRunStoresTheMajorMinorAndARepeatChangesNothing() async throws {
        typealias Update = AppStoreAgeCheck.SignificantUpdate
        let key = Update.acknowledgedVersionKey
        let standard = UserDefaults.standard
        let previous = standard.object(forKey: key)
        defer { if let previous { standard.set(previous, forKey: key) } else { standard.removeObject(forKey: key) } }
        let current = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        let majorMinor = try #require(Update.majorMinor(current))
        standard.removeObject(forKey: key)

        await AppStoreAgeCheck.acknowledgeSignificantUpdate()
        #expect(standard.string(forKey: key) == majorMinor, "the first run records this version's major.minor")
        #expect(Update.decide(acknowledged: standard.string(forKey: key), current: current) == .nothing,
                "what was stored makes the next launch of the same version do nothing")

        await AppStoreAgeCheck.acknowledgeSignificantUpdate()
        #expect(standard.string(forKey: key) == majorMinor, "a repeat run of the same version changes nothing")
    }
}
