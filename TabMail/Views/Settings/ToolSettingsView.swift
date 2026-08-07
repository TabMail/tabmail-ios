/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
@preconcurrency import Contacts

// MARK: - Contact Container Picker

struct ContactContainerPickerView: View {
    @AppStorage(CNContactStoreHelper.preferredContainerKey) private var selectedId = ""
    @State private var containers: [CNContactStoreHelper.ContactContainer] = []
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Text("Choose which contact account the TabMail AI agent will use when adding new contacts on your behalf.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if permissionDenied {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Contacts Access Required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.archive)
                        Text("Grant access in iOS Settings to choose where new contacts are saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            } else {
                Section {
                    // "System Default" option
                    Button {
                        selectedId = ""
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("System Default")
                                Text("Uses iOS Settings → Contacts → Default Account")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedId.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(containers) { container in
                        Button {
                            selectedId = container.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(container.displayName)
                                        if container.isDefault {
                                            Text("Default")
                                                .font(.caption2)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Palette.buttonBg)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(container.typeLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedId == container.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Save New Contacts To")
                }
            }
        }
        .listRowBackground(Palette.boxBg)
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Contacts")
        .task {
            await loadContainers()
        }
    }

    private func loadContainers() async {
        let granted = await CNContactStoreHelper.requestAccess()
        if !granted {
            permissionDenied = true
            return
        }
        do {
            containers = try CNContactStoreHelper.availableContainers()
            // Clear stale preference if stored container no longer exists
            if !selectedId.isEmpty, !containers.contains(where: { $0.id == selectedId }) {
                selectedId = ""
            }
        } catch {
            print("[ContactContainerPickerView] Failed to load containers: \(error)")
        }
    }
}

// MARK: - Calendar Settings

/// The calendar picker's per-account load state, and the ONE write that can
/// change the stored create-target preference.
///
/// Extracted out of `CalendarPickerView` for the same reason `UserLabelMenuModel`
/// was extracted out of `UserLabelMenuView`: the invariants below are properties
/// of `accounts` *while the load is still running*, and a `View`'s `@State`
/// cannot be observed from a test.
///
/// 🚨 **THE INVARIANT — the stored create-target preference may only be
/// re-resolved against a FULLY resolved entry set.** `resolveSelection` does two
/// things: it auto-selects a default create target when none is stored, and it
/// CLEARS a stored preference whose calendar it cannot find among the writable
/// ones. Run it while any account is still in flight and it wipes a perfectly
/// valid saved choice merely because that account had not answered yet — the
/// exact mirror image of the blank-list bug the incremental publish fixes. The
/// guard therefore lives *inside* `resolveSelection` (it returns `nil` — meaning
/// "change nothing" — unless every entry has `isLoading == false`), not at the
/// call site, so a future caller cannot reintroduce the trap by forgetting to
/// check.
@Observable
@MainActor
final class CalendarPickerModel {
    /// Per-account state: still loading, calendars loaded, failed, or needing re-auth.
    struct AccountEntry: Identifiable {
        let account: Account
        let provider: any CalendarProvider
        var calendars: [GCalCalendar] = []
        /// True from the moment the row is published until THIS account's
        /// `listCalendars()` returns or throws. Drives the per-row spinner and
        /// gates `resolveSelection`.
        var isLoading = true
        var needsReauth = false
        var errorMessage: String?
        var id: String { account.id }
    }

    var accounts: [AccountEntry] = []
    /// True once `resolveAll()` has answered — i.e. once we know how many
    /// accounts there are. This is NOT "every account finished"; that question is
    /// `accounts.allSatisfy { !$0.isLoading }`.
    var loaded = false

    private let defaults: UserDefaults
    private let resolveBackends: @Sendable () async -> [(provider: any CalendarProvider, account: Account)]

    /// The defaulted arguments are the production wiring. Tests inject an
    /// isolated `UserDefaults(suiteName:)` and a stub backend list; a test that
    /// forgot to inject would see zero accounts and fail loudly rather than pass.
    init(
        defaults: UserDefaults = .standard,
        resolveBackends: @escaping @Sendable () async -> [(provider: any CalendarProvider, account: Account)]
            = { await CalendarProviderDispatch.resolveAll() }
    ) {
        self.defaults = defaults
        self.resolveBackends = resolveBackends
    }

    nonisolated static func isWritable(_ cal: GCalCalendar) -> Bool {
        cal.accessRole == "owner" || cal.accessRole == "writer"
    }

    // MARK: - Loading

    /// Publish one row per account immediately, then fill each row in place as
    /// its provider answers.
    ///
    /// This used to be a serial `for` loop with a single publish at the end, so
    /// the screen stayed completely blank for the SUM of every account's network
    /// round trip rather than the max of them — which read as an empty calendar
    /// list on a multi-account device.
    func loadData() async {
        let backends = await resolveBackends()

        // Paint the account rows BEFORE any network call.
        accounts = backends.map { AccountEntry(account: $0.account, provider: $0.provider) }
        loaded = true

        // Fan out, one task per account. Mirrors
        // `CalendarToolHelpers.fetchEventsFromAllCalendars`, which already fans
        // `listCalendars()` out across accounts this way.
        await withTaskGroup(of: (String, LoadOutcome).self) { group in
            for backend in backends {
                let provider = backend.provider
                let accountId = backend.account.id
                let emailAddress = backend.account.emailAddress
                group.addTask {
                    (accountId, await Self.fetchCalendars(provider: provider, emailAddress: emailAddress))
                }
            }
            for await (accountId, outcome) in group {
                // A cancelled run must not write into `accounts`: a restarted
                // `.task` may already have replaced it with a fresh, still-
                // loading set, and clearing those rows' spinners would be a lie.
                if Task.isCancelled { continue }
                guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { continue }
                accounts[idx].calendars = outcome.calendars
                accounts[idx].needsReauth = outcome.needsReauth
                accounts[idx].errorMessage = outcome.errorMessage
                accounts[idx].isLoading = false
            }
        }

        // Selection / stale-clearing runs EXACTLY ONCE, after every account has
        // resolved — including the ones that failed. A cancelled load leaves
        // entries that are no longer loading but never got an answer, so skip it
        // entirely there: the stored choice stays untouched until a real load
        // completes.
        guard !Task.isCancelled else { return }
        applyResolvedSelection()
    }

    /// One account's `listCalendars()` result, in the three shapes the UI renders.
    private struct LoadOutcome: Sendable {
        var calendars: [GCalCalendar] = []
        var needsReauth = false
        var errorMessage: String?
    }

    private nonisolated static func fetchCalendars(
        provider: any CalendarProvider,
        emailAddress: String
    ) async -> LoadOutcome {
        var outcome = LoadOutcome()
        do {
            outcome.calendars = try await provider.listCalendars()
            print("[CalendarPickerView] \(emailAddress): loaded \(outcome.calendars.count) calendars (\(outcome.calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }.count) writable)")
        } catch GoogleCalendarError.missingScope {
            outcome.needsReauth = true
            print("[CalendarPickerView] \(emailAddress): Google calendar scope not granted")
        } catch ExchangeCalendarError.missingScope {
            outcome.needsReauth = true
            print("[CalendarPickerView] \(emailAddress): Exchange calendar scope not granted")
        } catch CalDAVError.authFailed {
            outcome.needsReauth = true
            print("[CalendarPickerView] \(emailAddress): CalDAV auth failed — needs re-auth")
        } catch {
            outcome.errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
            print("[CalendarPickerView] \(emailAddress): failed to fetch calendars: \(error)")
        }
        return outcome
    }

    // MARK: - Create-target preference

    /// Re-resolve the stored create-target preference against the loaded
    /// calendars.
    ///
    /// Returns `nil` — change nothing — when ANY entry is still loading. See the
    /// type comment: this function is also the one that CLEARS a stored
    /// preference, so running it against a partial set destroys valid user state.
    static func resolveSelection(
        entries: [AccountEntry],
        storedAccountId: String,
        storedCalendarId: String
    ) -> (accountId: String, calendarId: String)? {
        guard entries.allSatisfy({ !$0.isLoading }) else { return nil }

        var accountId = storedAccountId
        var calendarId = storedCalendarId

        // Auto-select the first account's primary writable calendar if no
        // preference is stored.
        if accountId.isEmpty || calendarId.isEmpty {
            if let (acct, cal) = firstWritablePrimary(entries) {
                accountId = acct.id
                calendarId = cal.id
            }
        }

        // Clear (or re-point) a stored preference whose calendar no longer
        // exists among the writable ones.
        if !calendarId.isEmpty {
            let writableCalIds = entries.flatMap { entry in
                entry.calendars.filter { isWritable($0) }.map(\.id)
            }
            if !writableCalIds.contains(calendarId) {
                if let (acct, cal) = firstWritablePrimary(entries) {
                    accountId = acct.id
                    calendarId = cal.id
                } else {
                    accountId = ""
                    calendarId = ""
                }
            }
        }

        return (accountId, calendarId)
    }

    static func firstWritablePrimary(_ entries: [AccountEntry]) -> (Account, GCalCalendar)? {
        for entry in entries where !entry.needsReauth {
            let writable = entry.calendars.filter { isWritable($0) }
            if let primary = writable.first(where: { $0.primary == true }) ?? writable.first {
                return (entry.account, primary)
            }
        }
        return nil
    }

    private func applyResolvedSelection() {
        let storedAccountId = defaults.string(forKey: CalendarProviderDispatch.preferredCalendarAccountKey) ?? ""
        let storedCalendarId = defaults.string(forKey: CalendarProviderDispatch.preferredCalendarKey) ?? ""
        guard let resolved = Self.resolveSelection(
            entries: accounts,
            storedAccountId: storedAccountId,
            storedCalendarId: storedCalendarId
        ) else { return }
        // The view reads these two keys through `@AppStorage`, which observes the
        // defaults store — so writing them here re-renders the checkmark.
        if resolved.accountId != storedAccountId {
            defaults.set(resolved.accountId, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        }
        if resolved.calendarId != storedCalendarId {
            defaults.set(resolved.calendarId, forKey: CalendarProviderDispatch.preferredCalendarKey)
        }
    }
}

struct CalendarPickerView: View {
    @AppStorage(CalendarProviderDispatch.preferredCalendarKey) private var selectedGCalId = ""
    @AppStorage(CalendarProviderDispatch.preferredCalendarAccountKey) private var selectedAccountId = ""
    /// Default duration applied client-side when the agent omits `end_iso`.
    /// Stored as 0 when never set; `defaultEventDurationMinutes` returns the
    /// fallback in that case.
    @AppStorage(CalendarProviderDispatch.defaultEventDurationKey) private var defaultDurationMinutes = 0

    /// Picker presets — user-friendly choices for typical meetings.
    private let durationOptions: [Int] = [15, 30, 45, 60, 90, 120]

    /// Load state lives on the model so the incremental publish is observable
    /// from a test. Constructing one is two property assignments — no I/O, no
    /// work — so the throwaway instances `@State` builds on parent re-renders
    /// cost nothing (cf. `InboxViewModelHolder`, where they did not).
    @State private var model = CalendarPickerModel()
    @State private var reauthingAccountId: String?
    /// Trigger re-render when a visibility toggle is flipped. The truth lives
    /// in `CalendarVisibilityStore` (UserDefaults); this counter just nudges
    /// SwiftUI to re-evaluate the per-row bindings.
    @State private var visibilityTick: Int = 0

    private func isWritable(_ cal: GCalCalendar) -> Bool {
        CalendarPickerModel.isWritable(cal)
    }

    private func isDefaultForCreate(_ cal: GCalCalendar, accountId: String) -> Bool {
        selectedGCalId == cal.id && selectedAccountId == accountId
    }

    private func toggleVisibility(_ cal: GCalCalendar, accountId: String) {
        let resolved = CalendarVisibilityStore.isVisible(cal, accountId: accountId)
        let newValue = !resolved
        if newValue == CalendarVisibilityStore.providerDefault(cal) {
            // Match provider default → clear override so we don't store noise.
            CalendarVisibilityStore.setOverride(nil, accountId: accountId, calendarId: cal.id)
        } else {
            CalendarVisibilityStore.setOverride(newValue, accountId: accountId, calendarId: cal.id)
        }
        visibilityTick &+= 1
    }

    @ViewBuilder
    private func visibilityToggle(_ cal: GCalCalendar, accountId: String) -> some View {
        let visible = CalendarVisibilityStore.isVisible(cal, accountId: accountId)
        Button {
            toggleVisibility(cal, accountId: accountId)
        } label: {
            Image(systemName: visible ? "eye" : "eye.slash")
                .foregroundStyle(visible ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(visible ? "Hide from agent" : "Show to agent")
    }

    /// Single row used for every calendar regardless of access role. Visibility
    /// (eye toggle) is the primary affordance; the "Default for create" radio
    /// only fires for writable calendars (read-only ones can't be the create
    /// target since the API would reject inserts).
    @ViewBuilder
    private func calendarRow(_ cal: GCalCalendar, accountId: String) -> some View {
        let visible = CalendarVisibilityStore.isVisible(cal, accountId: accountId)
        let writable = isWritable(cal)
        let isDefault = isDefaultForCreate(cal, accountId: accountId)
        HStack(spacing: 8) {
            visibilityToggle(cal, accountId: accountId)
            Button {
                guard writable else { return }
                selectedGCalId = cal.id
                selectedAccountId = accountId
            } label: {
                HStack(spacing: 8) {
                    if let bg = cal.backgroundColor {
                        Circle()
                            .fill(Color(hex: bg))
                            .frame(width: 12, height: 12)
                            .opacity(writable ? 1.0 : 0.5)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(cal.summary ?? cal.id)
                            .foregroundStyle(writable ? Color.primary : Color.secondary)
                            .fixedSize()
                    }
                    if cal.primary == true {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.buttonBg)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                    if !writable {
                        Text("Read-only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.buttonBg.opacity(0.6))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if isDefault {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .opacity(visible ? 1.0 : 0.5)
                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!writable)
        }
        .id(visibilityTick)
    }

    var body: some View {
        Form {
            Section {
                Text("By default the assistant only sees each account's primary calendar. Tap the eye icon to opt other calendars in (shared, holidays, free/busy, etc.) — hidden ones are never read or searched. Tap a writable row to set where new events get created.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("These choices are saved on this device only. They are not synced to Google / Outlook / iCloud, and not synced to your other TabMail devices — configure each device separately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default event duration", selection: Binding(
                    get: { CalendarProviderDispatch.defaultEventDurationMinutes },
                    set: { defaultDurationMinutes = $0 }
                )) {
                    ForEach(durationOptions, id: \.self) { mins in
                        Text(formatDuration(mins)).tag(mins)
                    }
                }
            } header: {
                Text("Default Duration")
            } footer: {
                Text("Used when the assistant doesn't specify an end time. Applied locally — the assistant never has to compute it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !model.accounts.isEmpty {
                ForEach(model.accounts) { entry in
                    if entry.isLoading {
                        // This account's row paints as soon as we know it exists;
                        // only its calendar list is still in flight. A slow
                        // account no longer holds the whole screen blank.
                        Section {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading calendars…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(entry.account.emailAddress)
                        }
                    } else if entry.needsReauth {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Calendar Access Required", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Palette.archive)
                                // 🚨 THE CONTROL MUST MATCH WHAT THE APP CAN ACTUALLY DO.
                                // This section used to render "Grant Access" for EVERY
                                // provider, but `grantCalendarAccess` only drives an OAuth
                                // refresh — its `.imap / .icloud / .caldav` arm is a bare
                                // `break`. For those accounts the button reloaded the same
                                // failing state and returned, so the user was told what was
                                // wrong, handed a control, and got nothing: a UI that lies
                                // about its own capability. Registered as `IOS-CAL-007`.
                                //
                                // These credentials are app-specific passwords the user holds;
                                // there is no token this app can refresh on their behalf. The
                                // honest surface is the setup flow that already accepts a new
                                // one — the same `CalendarSetupView` this screen links to from
                                // its toolbar and its empty state. Building a bespoke
                                // credential re-entry sheet here is product work and is
                                // deliberately NOT done.
                                if Self.canReauthInPlace(entry.account.provider) {
                                    Text("Re-sign in to grant calendar access.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        Task { await grantCalendarAccess(account: entry.account) }
                                    } label: {
                                        if reauthingAccountId == entry.account.id {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("Grant Access")
                                        }
                                    }
                                    .disabled(reauthingAccountId != nil)
                                } else {
                                    Text("This account signs in with an app-specific password, which TabMail can't renew for you. Add the calendar account again with a new password to restore access.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    NavigationLink("Update Calendar Account") {
                                        CalendarSetupView()
                                    }
                                }
                            }
                        } header: {
                            Text(entry.account.emailAddress)
                        }
                    } else if let errorMsg = entry.errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Could not load calendars")
                                    .foregroundStyle(.secondary)
                                Text(errorMsg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(entry.account.emailAddress)
                        }
                    } else {
                        // Sort: primary first (so the create-target candidate is
                        // at the top), then other writable calendars, then
                        // read-only. Within each tier, alphabetical by name.
                        let sorted = entry.calendars.sorted { a, b in
                            if (a.primary == true) != (b.primary == true) {
                                return a.primary == true
                            }
                            let aWritable = isWritable(a)
                            let bWritable = isWritable(b)
                            if aWritable != bWritable { return aWritable }
                            return (a.summary ?? a.id).localizedCaseInsensitiveCompare(b.summary ?? b.id) == .orderedAscending
                        }
                        Section {
                            ForEach(sorted, id: \.id) { cal in
                                calendarRow(cal, accountId: entry.account.id)
                            }
                        } header: {
                            Text(entry.account.emailAddress)
                        }
                    }
                }
            } else if model.loaded {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Add a calendar account (Gmail, Outlook, iCloud, or CalDAV) to use calendar features.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("Add Calendar") {
                        CalendarSetupView()
                    }
                } header: {
                    Text("Calendar")
                }
            } else {
                // Only visible until `CalendarProviderDispatch.resolveAll()`
                // answers (a local DB read) — the network wait is now per-row.
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
        }
        .listRowBackground(Palette.boxBg)
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Calendar")
        .toolbar {
            if !model.accounts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CalendarSetupView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task {
            await model.loadData()
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours)h \(rem)m"
    }

    /// Whether TabMail can itself re-grant calendar access for this provider.
    ///
    /// True only for the OAuth providers, where `grantCalendarAccess` drives a
    /// real token refresh. The password-based providers authenticate with an
    /// app-specific password the user holds — there is nothing this app can
    /// refresh on their behalf, so the "Grant Access" affordance MUST NOT be
    /// offered for them (`IOS-CAL-007`); the caller renders the setup-flow link
    /// instead. Keep this predicate and `grantCalendarAccess`'s switch in step:
    /// a provider that returns true here and hits the no-op arm there is exactly
    /// the inert button this exists to prevent.
    static func canReauthInPlace(_ provider: AccountProvider) -> Bool {
        switch provider {
        case .gmail, .outlook:
            return true
        case .imap, .icloud, .caldav:
            return false
        }
    }

    private func grantCalendarAccess(account: Account) async {
        reauthingAccountId = account.id
        defer { reauthingAccountId = nil }
        do {
            let manager = AccountManager.shared
            switch account.provider {
            case .gmail:
                try await manager.reauthenticateGmail(for: account)
            case .outlook:
                try await manager.reauthenticateMicrosoft(for: account)
            case .imap, .icloud, .caldav:
                // Unreachable from the calendar section: `canReauthInPlace`
                // returns false for these, so the view renders the
                // `CalendarSetupView` link instead of a button that calls this.
                // Kept for switch exhaustiveness, and deliberately NOT a silent
                // success — see the comment at the call site.
                break
            }
            await model.loadData()
        } catch {
            print("[CalendarPickerView] Re-auth failed for \(account.emailAddress): \(error)")
        }
    }
}
