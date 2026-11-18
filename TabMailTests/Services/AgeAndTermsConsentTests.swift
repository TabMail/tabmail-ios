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
        #expect(Check.classify(Check.answer(for: .declinedSharing)) == .unconfirmed, "declining to share is not a pass")
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

/// The significant update step with Apple's answers given, since Apple's
/// acknowledgment needs a regulated-region account. Invariant: Apple's notice
/// is asked for only where Apple says the age rules apply, and a version is
/// recorded only where they apply (or on the first run); a device where they
/// do not apply, such as one with no Apple Account, is shown nothing and keeps
/// its stored version, so it is asked again once the rules apply.
@Suite("Significant update: Apple's notice only where the rules apply")
@MainActor
struct SignificantUpdateAcknowledgmentTests {
    struct Failure: Error {}

    @MainActor
    final class Calls {
        var regionAsked = 0
        var noticeAsked = 0
        var shown: [String] = []
        var recorded: [String] = []
        /// The order of `show` and `record`, to check the version is recorded after the notice.
        var events: [String] = []
    }

    private func run(
        acknowledged: String?, current: String,
        regulated: Result<Bool, Failure>, required: Result<Bool, Failure> = .success(true),
        showFails: Bool = false
    ) async -> Calls {
        let calls = Calls()
        await AppStoreAgeCheck.acknowledge(
            acknowledged: acknowledged, current: current,
            isRegulated: { calls.regionAsked += 1; return try regulated.get() },
            requiresNotice: { calls.noticeAsked += 1; return try required.get() },
            show: { version in
                calls.events.append("show")
                if showFails { throw Failure() }
                calls.shown.append(version)
            },
            record: { version in calls.events.append("record"); calls.recorded.append(version) }
        )
        return calls
    }

    /// What Apple answered on a device with no Apple Account: the rules do not
    /// apply, yet a notice is listed as required. Showing it there covered the
    /// app with an empty screen that took every tap.
    @Test func whereTheRulesDoNotApplyNothingIsShownAndNothingRecorded() async {
        let calls = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(false), required: .success(true))
        #expect(calls.shown.isEmpty, "no Apple notice where the age rules do not apply")
        #expect(calls.recorded.isEmpty, "the stored version is kept, so the device is asked again later")
    }

    @Test func theSameDeviceOnceTheRulesApplyIsShownTheNoticeThenRecorded() async {
        let before = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(false))
        #expect(before.shown.isEmpty && before.recorded.isEmpty)
        // Nothing was recorded, so the stored version is still "1.7".
        let after = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(true), required: .success(true))
        #expect(after.shown == ["1.8"])
        #expect(after.recorded == ["1.8"])
        #expect(after.events == ["show", "record"], "recorded only after the notice")
    }

    @Test func whereTheRulesApplyButNoNoticeIsRequiredTheVersionIsRecorded() async {
        let calls = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(true), required: .success(false))
        #expect(calls.shown.isEmpty)
        #expect(calls.recorded == ["1.8"])
    }

    @Test func aFailedRegionQuestionShowsAndRecordsNothing() async {
        let calls = await run(acknowledged: "1.7", current: "1.8.0", regulated: .failure(Failure()))
        #expect(calls.shown.isEmpty)
        #expect(calls.recorded.isEmpty)
        #expect(calls.noticeAsked == 0)
    }

    @Test func aFailedNoticeQuestionShowsAndRecordsNothing() async {
        let calls = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(true), required: .failure(Failure()))
        #expect(calls.shown.isEmpty)
        #expect(calls.recorded.isEmpty)
    }

    @Test func aFailedNoticeRecordsNothing() async {
        let calls = await run(acknowledged: "1.7", current: "1.8.0", regulated: .success(true), showFails: true)
        #expect(calls.events == ["show"])
        #expect(calls.recorded.isEmpty, "asked again on the next foreground")
    }

    @Test func theFirstRunOnlyRecordsAndTheSameVersionDoesNothing() async {
        let first = await run(acknowledged: nil, current: "1.8.2", regulated: .success(true))
        #expect(first.recorded == ["1.8"])
        #expect(first.shown.isEmpty && first.regionAsked == 0 && first.noticeAsked == 0)

        let same = await run(acknowledged: "1.8", current: "1.8.2", regulated: .success(true))
        #expect(same.events.isEmpty && same.regionAsked == 0 && same.noticeAsked == 0)

        let notAVersion = await run(acknowledged: "1.7", current: "x", regulated: .success(true))
        #expect(notAVersion.events.isEmpty && notAVersion.regionAsked == 0)
    }
}

/// The runner's other two contracts (Codex r1 TC-1, TC-2): an age check still
/// running admits no second one, and only an adult answer leads to the notice.
@Suite("App Store age check: one age check at a time, notice only after an adult answer")
@MainActor
struct AppStoreAgeCheckRunnerGuardTests {
    @MainActor
    final class Calls {
        var checks = 0
        var applied: [AppStoreAgeCheck.Status] = []
        var notices = 0
        var heldCheck: CheckedContinuation<AppStoreAgeCheck.Status, Never>?
    }

    /// TC-1: while an age check is still waiting on the App Store, another
    /// pass (launch, foreground, Try Again) does nothing at all; once it ends,
    /// a later pass runs.
    @Test func aSecondPassWhileTheAgeCheckRunsDoesNothing() async {
        let runner = AppStoreAgeCheck.Runner()
        let calls = Calls()
        let first = Task { @MainActor in
            await runner.pass(
                check: {
                    calls.checks += 1
                    return await withCheckedContinuation { calls.heldCheck = $0 }
                },
                apply: { calls.applied.append($0) },
                acknowledge: { calls.notices += 1 }
            )
        }
        while calls.heldCheck == nil { await Task.yield() }
        #expect(runner.isCheckingAge)

        var secondTouched: [String] = []
        await runner.pass(
            check: { secondTouched.append("check"); return .minor },
            apply: { _ in secondTouched.append("apply") },
            acknowledge: { secondTouched.append("acknowledge") }
        )
        #expect(secondTouched.isEmpty, "no check, answer or notice from a pass made while one is running")
        #expect(calls.checks == 1)
        #expect(calls.applied.isEmpty, "the first answer is not in yet")

        calls.heldCheck?.resume(returning: .unconfirmed)
        await first.value
        #expect(calls.applied == [.unconfirmed])
        #expect(!runner.isCheckingAge)

        await runner.pass(
            check: { calls.checks += 1; return .minor },
            apply: { calls.applied.append($0) },
            acknowledge: { calls.notices += 1 }
        )
        #expect(calls.checks == 2, "a later pass is admitted")
        #expect(calls.applied == [.unconfirmed, .minor])
        #expect(calls.notices == 0)
    }

    /// TC-2: on an idle runner, every answer other than `.allowed` is shown
    /// and leads to no notice; `.allowed` (the control) does.
    @Test(arguments: [
        (AppStoreAgeCheck.Status.minor, false),
        (AppStoreAgeCheck.Status.unconfirmed, false),
        (AppStoreAgeCheck.Status.notChecked, false),
        (AppStoreAgeCheck.Status.allowed, true),
    ])
    func onlyAnAdultAnswerLeadsToTheNotice(status: AppStoreAgeCheck.Status, notice: Bool) async {
        let runner = AppStoreAgeCheck.Runner()
        let calls = Calls()
        await runner.pass(
            check: { calls.checks += 1; return status },
            apply: { calls.applied.append($0) },
            acknowledge: { calls.notices += 1 }
        )
        #expect(calls.applied == [status], "the answer is applied")
        #expect(calls.notices == (notice ? 1 : 0))
        #expect(!runner.isCheckingAge && !runner.isAcknowledging)
    }

    /// RootView's launch and foreground age check must go through the runner,
    /// and the banner's tap through its notice guard. A hosted SwiftUI view
    /// cannot be driven from a unit test, so this reads RootView's source.
    @Test func rootViewDelegatesToTheRunner() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let raw = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/RootView.swift"), encoding: .utf8)
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let start = try #require(text.range(of: "private func checkAppStoreAge() async {"))
        let end = try #require(text[start.upperBound...].range(of: "private func "))
        let body = String(text[start.upperBound..<end.lowerBound])
        #expect(body.contains("await appStoreAgeRunner.pass("), "the age check runs through the runner")
        #expect(body.contains("AppStoreAgeCheck.run(request:"))
        #expect(body.contains("AppStoreAgeCheck.acknowledgeSignificantUpdate()"))
        #expect(!text.contains("isCheckingAppStoreAge"), "no second age-check flag beside the runner's")
        #expect(text.contains("await appStoreAgeRunner.acknowledgeOnly {"), "the banner tap uses the notice guard")
    }
}

/// Apple's notice can stay up and never return (#1010). The in-progress marker
/// carries that across a relaunch: the same version is then offered through a
/// banner, never shown unasked; a new version is shown as usual.
@Suite("Significant update: a notice that never returned")
@MainActor
struct SignificantUpdateStuckNoticeTests {
    /// The UserDefaults the real step uses, held in memory.
    @MainActor
    final class Store {
        var acknowledged: String?
        var inProgress: String?
        var shown: [String] = []
        var stuck: CheckedContinuation<Void, Never>?
    }

    private func launch(
        _ store: Store, current: String, userAsked: Bool = false,
        show: @escaping (String) async throws -> Void
    ) async -> AppStoreAgeCheck.SignificantUpdate.Outcome {
        await AppStoreAgeCheck.acknowledge(
            acknowledged: store.acknowledged, current: current,
            inProgress: store.inProgress, userAsked: userAsked,
            isRegulated: { true }, requiresNotice: { true },
            show: show,
            record: { store.acknowledged = $0 },
            markInProgress: { store.inProgress = $0 }
        )
    }

    /// Runs a launch whose notice never returns, until the notice is up.
    private func stuckLaunch(_ store: Store, current: String) async -> Task<Void, Never> {
        let task = Task { @MainActor in
            _ = await launch(store, current: current) { version in
                store.shown.append(version)
                await withCheckedContinuation { store.stuck = $0 }
            }
        }
        while store.stuck == nil { await Task.yield() }
        return task
    }

    @Test func aRelaunchAfterAStuckNoticeShowsTheBannerAndNoUnaskedNotice() async {
        let store = Store()
        store.acknowledged = "1.7"
        let first = await stuckLaunch(store, current: "1.8.0")
        #expect(store.inProgress == "1.8", "the marker is set while the notice is up")

        // The next launch reads the same stored values.
        let outcome = await launch(store, current: "1.8.1") { store.shown.append($0) }
        #expect(outcome == .offerBanner(version: "1.8"))
        #expect(store.shown == ["1.8"], "no second unasked notice")
        #expect(store.acknowledged == "1.7", "not recorded as handled")

        // Tapping the banner opens Apple's notice; on return it is recorded.
        let tapped = await launch(store, current: "1.8.1", userAsked: true) { store.shown.append($0) }
        #expect(tapped == .none)
        #expect(store.shown == ["1.8", "1.8"])
        #expect(store.acknowledged == "1.8")
        #expect(store.inProgress == nil, "the marker clears once the notice returns")

        store.stuck?.resume()
        await first.value
    }

    @Test func aNewVersionAfterAStuckNoticeIsShownUnaskedAgain() async {
        let store = Store()
        store.acknowledged = "1.7"
        let first = await stuckLaunch(store, current: "1.8.0")

        let outcome = await launch(store, current: "1.9.0") { store.shown.append($0) }
        #expect(outcome == .none)
        #expect(store.shown == ["1.8", "1.9"], "the older version's marker is ignored")
        #expect(store.acknowledged == "1.9")
        #expect(store.inProgress == nil)

        store.stuck?.resume()
        await first.value
    }

    /// The banner's tap asks whether the age rules still apply before Apple's
    /// notice. Where they no longer do, the marker clears and the banner goes,
    /// with nothing shown and nothing recorded (the #972 rule).
    @Test func aTapWhereTheRulesNoLongerApplyClearsTheMarkerAndShowsNothing() async {
        let store = Store()
        store.acknowledged = "1.7"
        store.inProgress = "1.8"
        var regionAsked = 0
        let outcome = await AppStoreAgeCheck.acknowledge(
            acknowledged: store.acknowledged, current: "1.8.1",
            inProgress: store.inProgress, userAsked: true,
            isRegulated: { regionAsked += 1; return false }, requiresNotice: { true },
            show: { store.shown.append($0) },
            record: { store.acknowledged = $0 },
            markInProgress: { store.inProgress = $0 }
        )
        #expect(regionAsked == 1, "the tap asks the rules question before any notice")
        #expect(outcome == .none, "the banner is removed")
        #expect(store.shown.isEmpty)
        #expect(store.acknowledged == "1.7", "nothing recorded")
        #expect(store.inProgress == nil, "the marker is cleared, so the next launch shows no banner")
    }

    @Test func aFailedNoticeClearsTheMarker() async {
        struct Failure: Error {}
        let store = Store()
        store.acknowledged = "1.7"
        let outcome = await launch(store, current: "1.8.0") { _ in throw Failure() }
        #expect(outcome == .none)
        #expect(store.inProgress == nil, "a notice that returned with an error is asked again unasked")
        #expect(store.acknowledged == "1.7")
    }
}

/// Apple's age sheet does not run in the Simulator (Apple DTS), so these give
/// `AppStoreAgeCheck.decide` the answers iOS would give and check what the app
/// then shows (owner 2026-10-09: simulated answers stand in for a device test).
/// Invariants: outside a regulated region the app opens and Apple is never
/// asked; in one, only a confirmed adult gets in, a minor is blocked, a
/// declined or failed answer blocks with Try Again; a failed region question
/// changes nothing on screen; a foreground after an adult answer shows nothing.
@Suite("App Store age check: a notice that never returns")
@MainActor
struct AppStoreAgeCheckRunnerTests {
    @MainActor
    final class Calls {
        var checks = 0
        var notices = 0
        var applied: [AppStoreAgeCheck.Status] = []
        /// Held so the stuck notice can be released when the test ends.
        var stuck: CheckedContinuation<Void, Never>?
    }

    /// Apple's notice can stay up and never return (issue #972). The next
    /// launch or foreground pass must still ask the App Store for the age.
    @Test func aStuckNoticeDoesNotSkipTheNextAgeCheck() async {
        let runner = AppStoreAgeCheck.Runner()
        let calls = Calls()
        let first = Task { @MainActor in
            await runner.pass(
                check: { calls.checks += 1; return .allowed },
                apply: { calls.applied.append($0) },
                acknowledge: {
                    calls.notices += 1
                    await withCheckedContinuation { calls.stuck = $0 }
                }
            )
        }
        while calls.stuck == nil { await Task.yield() }

        await runner.pass(
            check: { calls.checks += 1; return .minor },
            apply: { calls.applied.append($0) },
            acknowledge: { calls.notices += 1 }
        )

        #expect(calls.checks == 2, "the second pass asks the App Store again while the notice is stuck")
        #expect(calls.applied == [.allowed, .minor], "the second answer is shown")
        #expect(calls.notices == 1, "no second notice while the first is still up")

        calls.stuck?.resume()
        await first.value
        #expect(!runner.isCheckingAge && !runner.isAcknowledging)
    }

    /// While the notice is still up, a pass with an `.allowed` answer does not
    /// start a second one; once it returns, the next pass may.
    @Test func noSecondNoticeWhileOneIsUp() async {
        let runner = AppStoreAgeCheck.Runner()
        let calls = Calls()
        let first = Task { @MainActor in
            await runner.pass(
                check: { calls.checks += 1; return .allowed },
                apply: { calls.applied.append($0) },
                acknowledge: {
                    calls.notices += 1
                    await withCheckedContinuation { calls.stuck = $0 }
                }
            )
        }
        while calls.stuck == nil { await Task.yield() }
        await runner.pass(check: { calls.checks += 1; return .allowed }, apply: { calls.applied.append($0) }, acknowledge: { calls.notices += 1 })
        #expect(calls.checks == 2)
        #expect(calls.notices == 1)

        calls.stuck?.resume()
        await first.value
        await runner.pass(check: { calls.checks += 1; return .allowed }, apply: { calls.applied.append($0) }, acknowledge: { calls.notices += 1 })
        #expect(calls.notices == 2, "a later pass shows the notice again once the first returned")
    }
}

@Suite("App Store age check: simulated App Store answers")
@MainActor
struct AppStoreAgeCheckSimulationTests {
    typealias Check = AppStoreAgeCheck
    private struct AppStoreFailure: Error {}
    /// ADR-034's minimum age, written out so a wrong constant fails here.
    private let minAge = 18

    /// One check as iOS would answer it; `asked` is whether the age sheet was requested.
    private func check(regulated: Result<Bool, Error>, answer: Result<Check.Answer, Error>) async -> (status: Check.Status, asked: Bool) {
        var asked = false
        let status = await Check.decide(
            isRegulated: { try regulated.get() },
            askAge: {
                asked = true
                return try answer.get()
            }
        )
        return (status, asked)
    }

    @Test func outsideARegulatedRegionTheAppOpensAndAppleIsNeverAsked() async {
        let result = await check(regulated: .success(false), answer: .success(.declined))
        #expect(result.status == .allowed)
        #expect(!result.asked, "no age sheet outside a regulated region")
        #expect(!Check.shown(previous: .notChecked, checked: result.status).blocksApp)
    }

    @Test func anAdultTheAppStoreConfirmsGetsIn() async {
        for answer: Check.Answer in [.shared(lowerBound: minAge, upperBound: nil), .shared(lowerBound: minAge + 7, upperBound: nil)] {
            let result = await check(regulated: .success(true), answer: .success(answer))
            #expect(result.asked)
            #expect(result.status == .allowed, "adult: \(answer)")
            #expect(!Check.shown(previous: .notChecked, checked: result.status).blocksApp)
        }
    }

    @Test func aMinorIsBlocked() async {
        for answer: Check.Answer in [
            .shared(lowerBound: nil, upperBound: 12), .shared(lowerBound: 13, upperBound: 15),
            .shared(lowerBound: 16, upperBound: minAge - 1),
        ] {
            let result = await check(regulated: .success(true), answer: .success(answer))
            let shown = Check.shown(previous: .notChecked, checked: result.status)
            #expect(shown == .minor, "minor: \(answer)")
            #expect(shown.blocksApp)
        }
    }

    @Test func aDeclinedOrFailedAnswerBlocksAndTryAgainLetsAnAdultIn() async {
        for answer: Result<Check.Answer, Error> in [.success(.declined), .failure(AppStoreFailure())] {
            let first = await check(regulated: .success(true), answer: answer)
            let shown = Check.shown(previous: .notChecked, checked: first.status)
            #expect(shown == .unconfirmed, "the gate that offers Try Again")
            #expect(shown.blocksApp)

            let retry = await check(regulated: .success(true), answer: .success(.shared(lowerBound: minAge, upperBound: nil)))
            #expect(!Check.shown(previous: shown, checked: retry.status).blocksApp, "Try Again with an adult answer opens the app")
        }
    }

    @Test func aFailedRegionQuestionChangesNothingOnScreen() async {
        let result = await check(regulated: .failure(AppStoreFailure()), answer: .success(.declined))
        #expect(result.status == .notChecked)
        #expect(!result.asked)
        for previous: Check.Status in [.notChecked, .allowed, .minor, .unconfirmed] {
            #expect(Check.shown(previous: previous, checked: result.status) == previous, "kept: \(previous)")
        }
    }

    @Test func aForegroundAfterAnAdultAnswerShowsNothing() async {
        let launch = await check(regulated: .success(true), answer: .success(.shared(lowerBound: minAge, upperBound: nil)))
        let afterLaunch = Check.shown(previous: .notChecked, checked: launch.status)
        let foreground = await check(regulated: .success(true), answer: .success(.shared(lowerBound: minAge, upperBound: nil)))
        let afterForeground = Check.shown(previous: afterLaunch, checked: foreground.status)
        #expect(afterForeground == .allowed)
        #expect(!afterForeground.blocksApp)
    }
}

/// The deletion request's real token path (`BillingClient` through
/// `TabMailTokenCoordinator`), network-free: in each state the token lookup
/// fails before any request is built, so neither auth nor billing is
/// contacted. Invariant (owner 2026-10-09): OK on the refusal signs out only
/// once billing has answered. A token that could not be refreshed for now
/// means billing was never asked, so OK must retry; a session that is gone or
/// revoked can never ask, so OK signs out. Uses the app's shared session,
/// hence `.serialized` and `.processGlobalState`; the previous one is restored.
@Suite("Age check refusal: deletion handshake through the real token path", .serialized, .processGlobalState)
@MainActor
struct AgeIneligibleDeletionTokenTests {
    private enum TokenState { case none, revoked, unrefreshable }

    private func install(_ state: TokenState) throws {
        _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
        let expired = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let user: [String: Any] = ["id": "test-user", "email": "user@example.com"]
        let json: [String: Any]
        switch state {
        case .none:
            return
        case .revoked:
            // No refresh token: the session needs signing in again.
            json = ["access_token": "test-access", "refresh_token": "", "expires_at": expired, "user": user]
        case .unrefreshable:
            // An expired session with an empty access token: the token lookup
            // fails as unavailable (transient) before any refresh is tried.
            json = ["access_token": "", "refresh_token": "test-refresh", "expires_at": expired, "user": user]
        }
        _ = try TabMailSessionStore.shared.installNewSession(try JSONSerialization.data(withJSONObject: json))
    }

    private func handshake(for state: TokenState) async throws -> AgeAndTermsConsent.DeletionHandshake {
        let previous = TabMailSessionStore.shared.loadActiveSession()?.data
        defer {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previous { _ = try? TabMailSessionStore.shared.installNewSession(previous) }
        }
        try install(state)
        if case .success = await TabMailTokenCoordinator.shared.validToken() {
            // Never reach billing with a usable token.
            Issue.record("the \(state) fixture produced a usable token")
            return .signOut
        }
        var thrown: Error?
        do {
            try await BillingClient().requestAgeIneligibleDeletion()
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "the request must fail before any network call")
        return AgeAndTermsConsent.deletionHandshake(after: error)
    }

    @Test func aTokenThatCannotBeRefreshedNowMakesOKAskAgain() async throws {
        #expect(try await handshake(for: .unrefreshable) == .retry, "billing was never asked")
    }

    @Test func aRevokedSessionSignsOut() async throws {
        #expect(try await handshake(for: .revoked) == .signOut)
    }

    @Test func noSessionSignsOut() async throws {
        #expect(try await handshake(for: .none) == .signOut)
    }
}
