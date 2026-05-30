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

struct CalendarPickerView: View {
    @AppStorage(CalendarProviderDispatch.preferredCalendarKey) private var selectedGCalId = ""
    @AppStorage(CalendarProviderDispatch.preferredCalendarAccountKey) private var selectedAccountId = ""
    /// Default duration applied client-side when the agent omits `end_iso`.
    /// Stored as 0 when never set; `defaultEventDurationMinutes` returns the
    /// fallback in that case.
    @AppStorage(CalendarProviderDispatch.defaultEventDurationKey) private var defaultDurationMinutes = 0

    /// Picker presets — user-friendly choices for typical meetings.
    private let durationOptions: [Int] = [15, 30, 45, 60, 90, 120]

    /// Per-account state: calendars loaded, or needing re-auth.
    struct AccountEntry: Identifiable {
        let account: Account
        let provider: any CalendarProvider
        var calendars: [GCalCalendar] = []
        var needsReauth = false
        var errorMessage: String?
        var id: String { account.id }
    }

    @State private var accounts: [AccountEntry] = []
    @State private var loaded = false
    @State private var reauthingAccountId: String?
    /// Trigger re-render when a visibility toggle is flipped. The truth lives
    /// in `CalendarVisibilityStore` (UserDefaults); this counter just nudges
    /// SwiftUI to re-evaluate the per-row bindings.
    @State private var visibilityTick: Int = 0

    private func isWritable(_ cal: GCalCalendar) -> Bool {
        cal.accessRole == "owner" || cal.accessRole == "writer"
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

            if !accounts.isEmpty {
                ForEach(accounts) { entry in
                    if entry.needsReauth {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Calendar Access Required", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Palette.archive)
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
            } else if loaded {
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
            if !accounts.isEmpty {
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
            await loadData()
        }
    }

    private func loadData() async {
        let backends = await CalendarProviderDispatch.resolveAll()
        var entries: [AccountEntry] = []

        for (provider, account) in backends {
            var entry = AccountEntry(account: account, provider: provider)
            do {
                entry.calendars = try await provider.listCalendars()
                print("[CalendarPickerView] \(account.emailAddress): loaded \(entry.calendars.count) calendars (\(entry.calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }.count) writable)")
            } catch GoogleCalendarError.missingScope {
                entry.needsReauth = true
                print("[CalendarPickerView] \(account.emailAddress): Google calendar scope not granted")
            } catch ExchangeCalendarError.missingScope {
                entry.needsReauth = true
                print("[CalendarPickerView] \(account.emailAddress): Exchange calendar scope not granted")
            } catch CalDAVError.authFailed {
                entry.needsReauth = true
                print("[CalendarPickerView] \(account.emailAddress): CalDAV auth failed — needs re-auth")
            } catch {
                entry.errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
                print("[CalendarPickerView] \(account.emailAddress): failed to fetch calendars: \(error)")
            }
            entries.append(entry)
        }

        accounts = entries

        // Auto-select first account's primary writable calendar if no preference stored
        if selectedAccountId.isEmpty || selectedGCalId.isEmpty {
            if let (acct, cal) = firstWritablePrimary(entries) {
                selectedAccountId = acct.id
                selectedGCalId = cal.id
            }
        }

        // Clear stale preference if stored calendar/account no longer exists
        if !selectedGCalId.isEmpty {
            let writableCalIds = entries.flatMap { entry in
                entry.calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }.map(\.id)
            }
            if !writableCalIds.contains(selectedGCalId) {
                if let (acct, cal) = firstWritablePrimary(entries) {
                    selectedAccountId = acct.id
                    selectedGCalId = cal.id
                } else {
                    selectedAccountId = ""
                    selectedGCalId = ""
                }
            }
        }

        loaded = true
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours)h \(rem)m"
    }

    private func firstWritablePrimary(_ entries: [AccountEntry]) -> (Account, GCalCalendar)? {
        for entry in entries where !entry.needsReauth {
            let writable = entry.calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
            if let primary = writable.first(where: { $0.primary == true }) ?? writable.first {
                return (entry.account, primary)
            }
        }
        return nil
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
                // CalDAV re-auth requires user to enter a new app-specific password
                // This is handled by CalendarSetupView / iCloud setup flow
                break
            }
            await loadData()
        } catch {
            print("[CalendarPickerView] Re-auth failed for \(account.emailAddress): \(error)")
        }
    }
}
