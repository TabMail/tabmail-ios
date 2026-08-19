/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Charts
import StoreKit

struct AccountDashboardView: View {
    @State private var accountInfo: AccountInfo?
    @State private var usageStats: UsageStats?
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Remount-loop diagnostic: @State survives re-renders of the SAME view
    /// identity but is re-seeded on a remount. If the `[Dashboard]` log storm
    /// shows a NEW id per iteration, the whole view is being torn down and
    /// recreated by something above; if the SAME id repeats, the `.task` is
    /// restarting on a stable identity.
    @State private var instanceId = String(UUID().uuidString.prefix(6))
    /// Dedup guard for the unstructured initial load (see `.task` comment).
    @State private var loadInFlight = false
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.scenePhase) private var scenePhase

    private let backend = BackendClient()

    var body: some View {
        // `.task`/`.onAppear` MUST hang on a STABLE node, never directly on
        // `content`: `content` is a @ViewBuilder conditional, and every
        // isLoading/errorMessage branch flip fires disappear/appear on it —
        // cancelling and restarting the plain `.task`. loadData's own state
        // writes flip the branch (isLoading=true on entry, errorMessage on
        // exit), so the task cancelled ITSELF in a self-sustaining ~100Hz
        // storm (on-device 2026-07-08, [Dashboard] id=A9755F log). The ZStack
        // stays in the hierarchy across branch changes, so the load task
        // survives its own spinner/error/content transitions.
        ZStack {
            content
        }
            .background(Palette.previewPaneBg)
            .navigationTitle("TabMail Account")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // The collapsed-split-view navigation transition fires ONE
                // spurious disappear on the freshly-appeared page (on-device
                // 2026-07-08: onAppear → onDisappear with the view still
                // visible, selection passing inbox → nil → account), which
                // cancels a structured `.task` mid-fetch with no re-appear to
                // restart it. Run the load UNSTRUCTURED so the transition
                // can't kill it (same pattern as user-intent actions);
                // `loadInFlight` dedups genuine re-appears.
                guard !loadInFlight else { return }
                loadInFlight = true
                Task { @MainActor in
                    defer { loadInFlight = false }
                    await loadData()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await refreshData() }
                }
            }
            .onAppear {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Dashboard] onAppear id=\(instanceId)")
                }
            }
            .onDisappear {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Dashboard] onDisappear id=\(instanceId)")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(Palette.textMuted)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadData() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // MARK: - Account Mismatch Warning

                if let userId = TabMailAuthService.getSession()?.userId,
                   storeKit.hasAccountMismatch(currentUserId: userId) {
                    Section {
                        AccountMismatchBanner(userEmail: TabMailAuthService.getSession()?.userEmail)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                // MARK: - Plan Section

                Section {
                    // Status banners
                    if let trialBanner = trialBannerCopy {
                        StatusBanner(
                            icon: trialBanner.icon,
                            text: trialBanner.text,
                            color: trialBanner.color
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if let cancellation = accountInfo?.pendingCancellation, cancellation.cancelAt != nil {
                        StatusBanner(
                            icon: "exclamationmark.triangle",
                            text: "Cancels on \(cancellation.cancelAtFormatted ?? cancellation.cancelAt.map { formatTimestamp($0) } ?? "")",
                            color: .orange
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if let downgrade = accountInfo?.pendingDowngrade, let toPlan = downgrade.toPlan {
                        StatusBanner(
                            icon: "arrow.down.circle",
                            text: "Downgrading to \(StoreKitManager.displayPlanName(forTier: toPlan)) on \(downgrade.effectiveAtFormatted ?? downgrade.effectiveAt.map { formatTimestamp($0) } ?? "")",
                            color: .yellow
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    // Account email
                    if let email = TabMailAuthService.getSession()?.userEmail {
                        LabeledContent {
                            Text(email)
                                .foregroundStyle(Palette.textMuted)
                        } label: {
                            Label("Account", systemImage: "envelope")
                                .foregroundStyle(.primary)
                        }
                        .listRowBackground(Palette.boxBg)
                    }

                    // Plan & Status
                    HStack {
                        Label {
                            Text(accountInfo?.planTier.map { StoreKitManager.displayPlanName(forTier: $0) } ?? "None")
                                .foregroundStyle(Palette.textColor)
                        } icon: {
                            Image(systemName: "crown")
                                .foregroundStyle(Palette.textColor)
                        }
                        Spacer()
                        Text(accountInfo?.subscriptionStatus ?? (accountInfo?.hasSubscription == true ? "Active" : "None"))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .listRowBackground(Palette.boxBg)

                    // Renewal
                    LabeledContent {
                        Text(accountInfo?.billingPeriodEnd.map { formatTimestamp($0) } ?? "—")
                            .foregroundStyle(Palette.textMuted)
                    } label: {
                        Label("Renewal", systemImage: "calendar")
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Palette.boxBg)

                    // Quota — Zero (BYOK) and the free trial have no priority AI
                    // budget, so a percentage is meaningless; show N/A instead
                    // (site dashboard precedent). Each plan gets its own caption.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Quota Used", systemImage: "gauge")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(isZeroPlan ? "N/A" : String(format: "%.1f%%", accountInfo?.quotaPercentage ?? 0))
                                .foregroundStyle(Palette.textMuted)
                        }
                        if let zeroBudgetPlan {
                            Text(zeroBudgetPlan.quotaCaption)
                                .font(.caption2)
                                .foregroundStyle(Palette.textMuted)
                        } else {
                            ProgressView(value: min((accountInfo?.quotaPercentage ?? 0) / 100, 1.0))
                                .tint(quotaTint)
                            if let resetLabel = quotaResetLabel {
                                Text(resetLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                    }
                    .listRowBackground(Palette.boxBg)

                    // Change Plan / Subscribe. A free trial counts as active
                    // access but is not a plan the user can change — that
                    // cohort gets the Subscribe call to action.
                    NavigationLink {
                        PlanPickerView()
                    } label: {
                        Label(
                            hasChangeablePlan ? "Change Plan" : "Subscribe",
                            systemImage: hasChangeablePlan ? "arrow.triangle.2.circlepath" : "star"
                        )
                        .foregroundStyle(Palette.accentColor)
                    }
                    .listRowBackground(Palette.boxBg)

                    // Manage existing subscription
                    if accountInfo?.subscriptionProvider == "apple" {
                        Button {
                            Task {
                                guard let windowScene = UIApplication.shared.connectedScenes
                                    .compactMap({ $0 as? UIWindowScene }).first else { return }
                                do {
                                    try await AppStore.showManageSubscriptions(in: windowScene)
                                } catch {
                                    print("[Dashboard] Failed to open subscription management: \(error)")
                                }
                                // Refresh entitlements + account info after sheet closes
                                await refreshData()
                            }
                        } label: {
                            Label("Manage Subscription", systemImage: "apple.logo")
                        }
                        .listRowBackground(Palette.boxBg)
                    }

                    // Sign Out — hidden in demo. The
                    // banner exit is the canonical (and only) demo-exit path;
                    // sign-out from inside demo doesn't make sense.
                    if !DemoModeStore.shared.isActive {
                        Button(role: .destructive) {
                            TabMailAuthService.clearSession()
                            NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
                        } label: {
                            Label("Sign Out of TabMail", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .listRowBackground(Palette.boxBg)
                    }
                }

                // MARK: - Usage Section

                Section {
                    let today = usageStats?.today

                    LabeledContent {
                        Text("\(Int(today?.calls ?? 0))")
                            .foregroundStyle(Palette.textColor)
                    } label: {
                        Label("API Calls", systemImage: "arrow.up.arrow.down")
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Palette.boxBg)

                    LabeledContent {
                        Text(formatNumber(today?.tokensInput ?? 0))
                            .foregroundStyle(Palette.textColor)
                    } label: {
                        Label("Input Tokens", systemImage: "text.cursor")
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Palette.boxBg)

                    LabeledContent {
                        Text(formatNumber(today?.tokensOutput ?? 0))
                            .foregroundStyle(Palette.textColor)
                    } label: {
                        Label("Output Tokens", systemImage: "text.badge.checkmark")
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Palette.boxBg)
                } header: {
                    Text("Usage (24h)")
                }

                // Daily Quota Usage chart
                if let maxCostCents = accountInfo?.dailyQuotaChartDenominator {
                    let padded = paddedDailyStats(usageStats?.dailyStats ?? [])
                    Section {
                        VStack(spacing: 2) {
                            Chart(padded) { day in
                                BarMark(
                                    x: .value("Date", day.date ?? ""),
                                    y: .value("Quota %", (day.costCents / maxCostCents) * 100)
                                )
                                .foregroundStyle(Palette.accentColor)
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .leading) { value in
                                    AxisValueLabel {
                                        if let v = value.as(Double.self) {
                                            Text(String(format: "%.1f%%", v))
                                        }
                                    }
                                    AxisGridLine()
                                }
                            }
                            .frame(height: 160)
                            chartDateLabels(padded)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Palette.boxBg)
                    } header: {
                        Text("Daily Quota Usage — 30 Days (UTC)")
                    }
                }

                // Token Usage chart
                if true {
                    let padded = paddedDailyStats(usageStats?.dailyStats ?? [])
                    Section {
                        VStack(spacing: 2) {
                            Chart(padded) { day in
                                BarMark(
                                    x: .value("Date", day.date ?? ""),
                                    y: .value("Tokens", day.tokensInput)
                                )
                                .foregroundStyle(by: .value("Type", "Input"))

                                BarMark(
                                    x: .value("Date", day.date ?? ""),
                                    y: .value("Tokens", day.tokensOutput)
                                )
                                .foregroundStyle(by: .value("Type", "Output"))
                            }
                            .chartForegroundStyleScale([
                                "Input": Color.blue,
                                "Output": Color.green,
                            ])
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .leading) { value in
                                    AxisValueLabel {
                                        if let v = value.as(Double.self) {
                                            Text(formatNumber(v))
                                        }
                                    }
                                    AxisGridLine()
                                }
                            }
                            .chartLegend(.hidden)
                            .frame(height: 160)
                            chartDateLabels(padded)
                            HStack(spacing: 12) {
                                Label("Input", systemImage: "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Label("Output", systemImage: "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Palette.boxBg)
                    } header: {
                        Text("Token Usage — 30 Days (UTC)")
                    }
                }

                // MARK: - Danger Zone

                Section {
                    NavigationLink {
                        AccountDeletionView()
                    } label: {
                        Label("Delete TabMail Account", systemImage: "person.crop.circle.badge.minus")
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Palette.boxBg)
                } header: {
                    Text("Danger Zone")
                        .foregroundStyle(.red)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await refreshData() }
            .dismissKeyboardOnTap()
        }
    }

    // MARK: - Helpers

    private func loadData() async {
        if DebugModeManager.isLoggingEnabled() {
            print("[Dashboard] loadData START id=\(instanceId)")
        }
        isLoading = true
        errorMessage = nil
        // Clear the spinner unconditionally (same defer pattern as
        // InboxViewModel.performSync's isRefreshing): a `.task` cancelled by
        // navigation churn used to strand isLoading=true forever with no
        // Retry button — the cancellation catches in fetchAll() are the only
        // silent exit paths in this file. If the cancelled load produced no
        // data, surface Retry instead of an empty dashboard.
        defer {
            isLoading = false
            if Task.isCancelled && accountInfo == nil && errorMessage == nil {
                errorMessage = "Loading was interrupted."
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[Dashboard] loadData exit id=\(instanceId) cancelled=\(Task.isCancelled) hasInfo=\(accountInfo != nil) hasStats=\(usageStats != nil) error=\(errorMessage ?? "nil")")
            }
        }
        await fetchAll()
    }

    /// Pull-to-refresh: fetches fresh data without showing full-screen spinner.
    private func refreshData() async {
        await fetchAll()
    }

    private func fetchAll() async {
        // In screenshot mode, use mock data instead of network calls.
        if ScreenshotMode.isActive {
            accountInfo = ScreenshotMode.mockAccountInfo
            usageStats = ScreenshotMode.mockUsageStats
            return
        }

        do {
            let info = try await backend.fetchAccountInfo()
            accountInfo = info
            // This is an authoritative /whoami, so route it through the same
            // single seam the foreground revalidation uses: it opens/closes the
            // gate AND stamps the trial flag, keeping the sidebar copy in step
            // with what the dashboard is showing instead of lagging a foreground.
            AISubscriptionGate.shared.apply(info)
            // Keep the inbox usage-throttle banner fresh when the user opens
            // the dashboard.
            UsageThrottleStore.shared.update(from: info)
        } catch is CancellationError {
            if DebugModeManager.isLoggingEnabled() {
                print("[Dashboard] fetchAccountInfo CANCELLED (CancellationError)")
            }
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            if DebugModeManager.isLoggingEnabled() {
                print("[Dashboard] fetchAccountInfo CANCELLED (URLError.cancelled)")
            }
            return
        } catch BackendError.accountGone {
            print("[Dashboard] Account no longer exists — showing account gone alert")
            NotificationCenter.default.post(name: .tabMailAccountGone, object: nil)
            return
        } catch BackendError.unauthorized {
            // Token refresh may have permanently failed (account deleted)
            let tokenState = await TabMailTokenCoordinator.shared.validToken()
            if case .permanentFailure = tokenState {
                print("[Dashboard] Auth permanently failed — showing account gone alert")
                NotificationCenter.default.post(name: .tabMailAccountGone, object: nil)
                return
            }
            if case .noSession = tokenState {
                print("[Dashboard] No session — showing account gone alert")
                NotificationCenter.default.post(name: .tabMailAccountGone, object: nil)
                return
            }
            print("[Dashboard] fetchAccountInfo unauthorized (transient)")
            if accountInfo == nil {
                errorMessage = "Failed to load account info"
            }
        } catch {
            print("[Dashboard] fetchAccountInfo failed: \(error)")
            if accountInfo == nil {
                errorMessage = "Failed to load account info"
            }
        }

        do {
            usageStats = try await backend.fetchUsageStats()
        } catch is CancellationError {
            if DebugModeManager.isLoggingEnabled() {
                print("[Dashboard] fetchUsageStats CANCELLED (CancellationError)")
            }
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            if DebugModeManager.isLoggingEnabled() {
                print("[Dashboard] fetchUsageStats CANCELLED (URLError.cancelled)")
            }
            return
        } catch {
            print("[Dashboard] fetchUsageStats failed: \(error)")
            if errorMessage == nil && usageStats == nil {
                errorMessage = "Failed to load usage stats"
            }
        }
    }

    /// Whether the account holds a purchased plan that can be switched. A running
    /// free trial reports active access but owns no purchase, so it takes the
    /// Subscribe call to action rather than "Change Plan".
    private var hasChangeablePlan: Bool {
        guard accountInfo?.hasSubscription == true else { return false }
        if case .active = accountInfo?.trialState() { return false }
        return true
    }

    /// Copy for the trial status banner, or `nil` when there is no trial to
    /// describe.
    ///
    /// Deliberately NOT gated on `accountInfo?.trial` being non-nil: the ended
    /// response can carry `"trial": null`, and reading the object first would
    /// make the ended banner disappear on exactly the accounts that need it.
    /// The `.noTrial` arm keeps today's plain "Trial active until <date>" for a
    /// legacy Stripe/Apple card trial, which is a subscription rather than a
    /// signup trial and must render exactly as it always has.
    private var trialBannerCopy: (icon: String, text: String, color: Color)? {
        switch accountInfo?.trialState() {
        case .active(let daysRemaining):
            let unit = daysRemaining == 1 ? "day" : "days"
            return ("clock", "Free trial · \(daysRemaining) \(unit) left", .blue)
        case .ended:
            return ("clock.badge.exclamationmark",
                    "Your free trial has ended — subscribe to continue",
                    .orange)
        default:
            guard let trial = accountInfo?.trial, trial.isTrial else { return nil }
            let suffix = trial.trialEnd.map { " until \(formatTimestamp($0))" } ?? ""
            return ("clock", "Trial active" + suffix, .blue)
        }
    }

    /// The account's zero-priority-budget plan, if it is on one. Internal tier
    /// strings stay "BYOK"/"Trial"; only display maps them to "Zero"/"Free Trial".
    /// `nil` for Basic/Pro/unknown, which do have a budget and a real percentage.
    private var zeroBudgetPlan: ZeroBudgetPlan? {
        ZeroBudgetPlan.forTier(accountInfo?.planTier)
    }

    /// Whether the quota reading should be "N/A" rather than a percentage.
    private var isZeroPlan: Bool { zeroBudgetPlan != nil }

    private var quotaTint: Color {
        let p = accountInfo?.quotaPercentage ?? 0
        if p > 90 { return .red }
        if p > 70 { return .orange }
        return Palette.accentColor
    }

    private var quotaResetLabel: String? {
        guard let end = accountInfo?.billingPeriodEnd else { return nil }
        let resetDate = Date(timeIntervalSince1970: end)
        let days = Calendar.current.dateComponents([.day], from: Date(), to: resetDate).day ?? 0
        if days == 0 { return "Resets today (UTC)" }
        if days == 1 { return "Resets tomorrow (UTC)" }
        if days > 1 { return "Resets in \(days) days (UTC)" }
        return "Quota period ended"
    }

    /// Date labels below chart, aligned with the plot area (leading padding matches Y-axis width).
    private func chartDateLabels(_ padded: [DayStats]) -> some View {
        HStack {
            Text(shortDate(padded.first?.date ?? ""))
            Spacer()
            Text(shortDate(padded.last?.date ?? ""))
        }
        .font(.caption2)
        .foregroundStyle(Palette.textMuted)
        .padding(.leading, 40)
    }

    /// Pad daily stats to always show 30 days, sorted oldest→newest (left→right, today on right).
    private func paddedDailyStats(_ stats: [DayStats]) -> [DayStats] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")

        // Build lookup from existing stats
        var lookup: [String: DayStats] = [:]
        for s in stats { if let d = s.date { lookup[d] = s } }

        // Generate 30 days ending today (UTC)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = Date()
        var result: [DayStats] = []
        for i in (0..<30).reversed() {
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let key = fmt.string(from: day)
            if let existing = lookup[key] {
                result.append(existing)
            } else {
                result.append(DayStats(date: key, calls: 0, tokensInput: 0, tokensOutput: 0, tokensTotal: 0, costCents: 0))
            }
        }
        return result
    }

    /// Format "yyyy-MM-dd" → short display like "Mar 10"
    private func shortDate(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: dateString) else { return dateString }
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        return display.string(from: date)
    }

    private func formatTimestamp(_ unixSeconds: some BinaryInteger) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(Int(unixSeconds)))
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    private func formatTimestamp(_ unixSeconds: Double) -> String {
        let date = Date(timeIntervalSince1970: unixSeconds)
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    private func formatNumber(_ n: Double) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", n / 1_000)
        }
        return "\(Int(n))"
    }
}

// MARK: - Account Mismatch Banner

private struct AccountMismatchBanner: View {
    let userEmail: String?
    @State private var isSubmitting = false
    @State private var showSubmitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Subscription Account Mismatch")
                    .font(.subheadline.bold())
                    .foregroundStyle(Palette.textColor)
            }
            Text("Your App Store account already has an active subscription tied to a different TabMail account. If you wish to migrate your subscription, please contact support.")
                .font(.caption)
                .foregroundStyle(Palette.textMuted)
            Button {
                isSubmitting = true
                Task {
                    let email = userEmail ?? "unknown"
                    await ReportConcernService.report(
                        contentType: .subscriptionMigration,
                        content: "Apple subscription account mismatch — user \(email) requesting migration",
                        category: .other,
                        reason: "User's Apple ID subscription is tied to a different TabMail account"
                    )
                    isSubmitting = false
                    showSubmitted = true
                }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Contact Support")
                }
            }
            .disabled(isSubmitting)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .alert("Support Request Submitted", isPresented: $showSubmitted) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We'll review your migration request and get back to you via email.")
        }
    }
}

