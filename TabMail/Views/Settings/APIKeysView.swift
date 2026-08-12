/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Centralized BYOK API-key management. One key per provider, shared across
/// all tiers that route through that provider. Linked from the AI Provider
/// section in TabMailSettings.
///
/// Each provider's section embeds its own end-to-end test runner that walks
/// every model in the BYOK catalog for that provider × applicable smoke
/// profiles per tier — covers compose (date_to_day), summary (time_delta)
/// and agent multi-tool (date_to_day + time_delta sequentially).
///
/// The view is hidden upstream when DemoModeStore.isActive (BYOK is
/// paid-only). We re-check defensively in body to fail closed.
struct APIKeysView: View {
    @State private var demoStore = DemoModeStore.shared
    @State private var catalog: BYOKModelCatalog?

    var body: some View {
        Form {
            if demoStore.isActive {
                Section {
                    Text("API keys aren't available in demo mode. Sign up to bring your own provider keys.")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Intro disclaimer at the top — sets the privacy expectation
                // before the user pastes anything.
                Section {
                    Text("Keys are stored in the iOS Keychain on this device only and never synced to iCloud. They are only relayed through TabMail's servers, never stored at rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Driven by BYOKProviderInfo.allProviders so this list cannot drift from the one
                // AppDataWiper uses to DELETE keys. Order is the declaration order.
                ForEach(BYOKProviderInfo.allProviders, id: \.self) { provider in
                    APIKeyProviderSection(provider: provider, catalog: catalog)
                }
            }
        }
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnTap()
        .task { await loadCatalogIfNeeded() }
    }

    private func loadCatalogIfNeeded() async {
        guard catalog == nil else { return }
        let client = BackendClient()
        if let c = try? await client.fetchBYOKModels() {
            catalog = c
        }
    }
}

// MARK: - Per-provider section

private struct APIKeyProviderSection: View {
    let provider: String
    let catalog: BYOKModelCatalog?

    @State private var apiKey: String = ""
    @State private var revealKey: Bool = false
    @State private var savedIndicator: Bool = false

    var body: some View {
        Section {
            // Status row.
            HStack {
                Image(systemName: savedIndicator ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(savedIndicator ? .green : .orange)
                Text(savedIndicator ? "Key stored" : "No key configured")
                    .foregroundStyle(savedIndicator ? .green : .secondary)
                Spacer()
            }

            if let url = BYOKProviderInfo.keyURL(provider) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Get a key from \(BYOKProviderInfo.displayName(provider))")
                    }
                }
                Text(BYOKProviderInfo.billingSeparationNote(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Test runner — placed ABOVE the key field per design (so you can
            // run the full suite from this section without scrolling, and the
            // results land right above the key you're testing).
            if savedIndicator {
                ProviderTestRunner(provider: provider, catalog: catalog, apiKey: apiKey)
            }

            HStack {
                Group {
                    if revealKey {
                        TextField("API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                }
                Button { revealKey.toggle() } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Button {
                    if let clipboard = UIPasteboard.general.string {
                        apiKey = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
            }
            .onChange(of: apiKey) { _, newValue in
                persist(newValue)
            }

            if savedIndicator {
                Button(role: .destructive) {
                    apiKey = ""
                    KeychainHelper.deleteBYOK(provider: provider)
                    savedIndicator = false
                } label: {
                    Label("Remove key", systemImage: "trash")
                }
            }

            Text(BYOKProviderInfo.zdrDisclaimer(provider))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(BYOKProviderInfo.displayName(provider))
        }
        .onAppear {
            apiKey = KeychainHelper.loadBYOK(provider: provider) ?? ""
            savedIndicator = !apiKey.isEmpty
        }
    }

    private func persist(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteBYOK(provider: provider)
            savedIndicator = false
            // Keychain writes don't fire UserDefaults.didChangeNotification —
            // signal listeners (BYOKTierRows' live-model cache) explicitly.
            NotificationCenter.default.post(name: .byokKeyChanged, object: provider)
        } else {
            do {
                try KeychainHelper.saveBYOK(trimmed, provider: provider)
                savedIndicator = true
                NotificationCenter.default.post(name: .byokKeyChanged, object: provider)
            } catch {
                savedIndicator = false
                if DebugModeManager.isLoggingEnabled() {
                    print("[BYOK] keychain save failed for \(provider): \(error)")
                }
            }
        }
        // Update the inbox usage-throttle banner immediately — adding/removing a
        // BYOK key flips whether the user is on the slow shared queue.
        UsageThrottleStore.shared.refreshKeyState()
    }
}

// MARK: - Provider-scoped test runner

/// Embedded inside each `APIKeyProviderSection`. Tapping "Test API Connectivity"
/// walks every model in `catalog[provider][tier]` for both tiers × the profiles
/// that apply to each tier and runs each smoke sequentially. The UI is
/// deliberately tight:
///
/// - Idle: single row, "Test API Connectivity", shield icon.
/// - Running: same row, spinner + live `done/total` counter.
/// - All passed: green seal + `N/N` badge, NO detail rows.
/// - Some failed: orange shield + `passed/total` badge in red, with ONE-LINE
///   rows below for each failed (model · profile) — collapsed to a brief
///   reason (error_code if set, else first failed stage detail). Tiers,
///   stage breakdowns, and final text live in the report payload only.
///
/// Long-press on the row → standard `.reportConcern(...)` flow (popover →
/// "Report Concern" → category + reason sheet → POST /report-concern with
/// `content_type: byokDiagnostic`). Same reporting infrastructure as the
/// rest of the app's AI report-an-issue surfaces.
///
/// Sequential execution by design — keeps a single key/budget under control
/// and lets the counter tick up. Runs against the live provider using the
/// saved key (read fresh at smoke time).
private struct ProviderTestRunner: View {
    let provider: String
    let catalog: BYOKModelCatalog?
    let apiKey: String

    @State private var isRunning: Bool = false
    @State private var results: [TestKey: BYOKSmokeResult] = [:]
    /// Model IDs the key can access (from /byok/list-models), fetched at the
    /// start of a test run. nil = not yet fetched.
    @State private var availableModels: Set<String>?
    /// Error from the list-models call (e.g. byok_key_rejected), if it failed.
    @State private var modelsError: String?

    /// Identifies one (tier, model, profile) triple in the results dictionary.
    struct TestKey: Hashable {
        let tier: String
        let model: String
        let profile: BYOKSmokeProfile
    }

    /// Tests this runner will execute, derived from the catalog. Recomputed
    /// each render — catalog is stable for the session.
    private var matrix: [TestKey] {
        guard let catalog else { return [] }
        var out: [TestKey] = []
        let tiers = ["background", "interactive"]
        for tier in tiers {
            guard let models = catalog[provider]?[tier], !models.isEmpty else { continue }
            for model in models {
                for profile in BYOKSmokeProfile.allCases where profile.appliesTo(tier: tier) {
                    out.append(TestKey(tier: tier, model: model, profile: profile))
                }
            }
        }
        return out
    }

    private var failedKeys: [TestKey] {
        // Preserve matrix order so failures appear in the order they were run.
        matrix.filter { (results[$0]?.ok ?? true) == false && results[$0] != nil }
    }

    var body: some View {
        if catalog == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading model list…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if matrix.isEmpty {
            Text("No models in the BYOK catalog for this provider.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            runRow
            modelAccessBlock
            ForEach(failedKeys, id: \.self) { key in
                failedRow(key: key, result: results[key]!)
            }
        }
    }

    /// All distinct catalog models for this provider (across tiers) — the set
    /// the smoke could exercise and that the key needs access to.
    private var catalogModels: [String] {
        guard let catalog, let tiers = catalog[provider] else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for tier in ["background", "interactive"] {
            for m in tiers[tier] ?? [] where !seen.contains(m) {
                seen.insert(m); ordered.append(m)
            }
        }
        return ordered
    }

    /// Whether a catalog model is in the key's available set. Shared with the
    /// model-picker merge logic — see `BYOKProviderInfo.isAvailable`.
    private func isAvailable(_ catalogModel: String, in available: Set<String>) -> Bool {
        BYOKProviderInfo.isAvailable(catalogModel, in: available)
    }

    /// Shows which catalog models the key can access, after a test run. This is
    /// the "why does it 404" answer: a ✗ here means the key/account isn't
    /// entitled to that model (the smoke's 404). Only rendered once a run has
    /// populated availableModels or surfaced an error.
    @ViewBuilder
    private var modelAccessBlock: some View {
        if let err = modelsError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text("Couldn't list your key's models: \(err)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if let available = availableModels {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models your key can access")
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                ForEach(catalogModels, id: \.self) { model in
                    let ok = isAvailable(model, in: available)
                    HStack(spacing: 6) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? .green : .red)
                            .font(.caption2)
                        Text(model).font(.caption2)
                        if !ok {
                            Text("not in your account")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    /// Single-action "Test API Connectivity" row. Tap = run immediately.
    /// Long-press → `.reportConcern(...)` modifier opens the report sheet.
    @ViewBuilder
    private var runRow: some View {
        HStack(spacing: 8) {
            statusIcon
            Text("Test API Connectivity")
            Spacer()
            if isRunning || !results.isEmpty {
                counterBadge
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRunning else { return }
            Task { await runAll() }
        }
        .reportConcern(contentType: .byokDiagnostic, content: buildDiagnosticContent())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            ProgressView().controlSize(.small)
        } else if results.isEmpty {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.tint)
        } else if results.values.allSatisfy({ $0.ok }) && results.count == matrix.count {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Live counter: while running, shows `done/total`; after completion,
    /// shows `passed/total` (green when all pass, red otherwise).
    private var counterBadge: some View {
        let total = matrix.count
        let done = results.count
        let passed = results.values.filter { $0.ok }.count
        let label = isRunning ? "\(done)/\(total)" : "\(passed)/\(total)"
        let color: Color = isRunning ? .secondary : (passed == total ? .green : .red)
        return Text(label)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    /// One-line collapsed failure row: model · profile, and a single
    /// brief-reason caption below. Full stage detail goes only into the
    /// report payload, not the UI.
    @ViewBuilder
    private func failedRow(key: TestKey, result: BYOKSmokeResult) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("\(key.model)  ·  \(key.profile.displayName)")
                    .font(.caption)
                Spacer()
            }
            Text(briefReason(for: result))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }

    /// Choose the most informative single line for a failed result. A result is
    /// only `ok=false` because of a FATAL stage or an error_code, so we look at
    /// those — never at the informational tool stages. Priority:
    ///   1. error_code (provider-mapped or transport)
    ///   2. detail / name of the first failed FATAL stage
    ///   3. generic "failed"
    private func briefReason(for r: BYOKSmokeResult) -> String {
        if let code = r.errorCode {
            return code
        }
        let fatalFailures = r.stages.filter { $0.fatal && !$0.ok }
        if let detail = fatalFailures.first(where: { $0.detail?.isEmpty == false })?.detail {
            return detail
        }
        if let name = fatalFailures.first?.name {
            return name
        }
        return "failed"
    }

    @MainActor
    private func runAll() async {
        guard !matrix.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        results.removeAll()
        availableModels = nil
        modelsError = nil

        // Fresh key read at smoke time — picker-shown state could be stale.
        guard let freshKey = KeychainHelper.loadBYOK(provider: provider), !freshKey.isEmpty else {
            return
        }

        let client = BackendClient()

        // Step 1 — list the models the key can actually access. Cheap read-only
        // probe that explains 404s (a smoke failing on a model that's ✗ here is
        // an account-entitlement issue, not a TabMail bug).
        let listing = await client.listBYOKModels(provider: provider, apiKey: freshKey)
        if listing.ok {
            availableModels = Set(listing.models ?? [])
        } else {
            let code = listing.error_code ?? "unknown"
            let detail = listing.error_detail.map { ": \($0)" } ?? ""
            modelsError = "\(code)\(detail)"
        }

        // Step 2 — run the smoke matrix.
        for key in matrix {
            let result = await client.runBYOKSmoke(
                tier: key.tier,
                provider: provider,
                model: key.model,
                apiKey: freshKey,
                profile: key.profile
            )
            results[key] = result
        }
    }

    /// Plain-text payload submitted via the `.byokDiagnostic` Report Concern
    /// flow. Backend `/report-concern` truncates to 5000 chars; we order by
    /// failures-first so the most actionable content survives truncation.
    private func buildDiagnosticContent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let now = ISO8601DateFormatter().string(from: Date())
        let total = matrix.count
        let passed = results.values.filter { $0.ok }.count
        let ran = results.count

        var lines: [String] = []
        lines.append("TabMail BYOK diagnostic — \(BYOKProviderInfo.displayName(provider))")
        lines.append("Generated: \(now)")
        lines.append("App: \(version) (\(build))")
        lines.append("Tests run: \(ran)/\(total)  Passed: \(passed)/\(ran)")
        lines.append("")

        // Key model-access cross-reference — the first thing to check on a 404.
        if let err = modelsError {
            lines.append("Key model access: COULD NOT LIST (\(err))")
            lines.append("")
        } else if let available = availableModels {
            lines.append("Key model access (catalog models):")
            for model in catalogModels {
                lines.append("  \(isAvailable(model, in: available) ? "[+]" : "[-]") \(model)")
            }
            lines.append("")
        }

        // Failures first — these are what triage cares about.
        let failed = matrix.filter { (results[$0]?.ok ?? true) == false && results[$0] != nil }
        if !failed.isEmpty {
            lines.append("══ FAILED (\(failed.count)) ══")
            for key in failed {
                guard let r = results[key] else { continue }
                lines.append("")
                lines.append("• [\(key.tier)] \(key.model) — \(key.profile.displayName)")
                lines.append("  latency: \(r.latencyMs)ms")
                if let routed = r.byokRouted {
                    lines.append("  byok_routed: \(routed)  tier=\(r.byokTier ?? "?")  provider=\(r.byokProvider ?? "?")")
                }
                for stage in r.stages {
                    lines.append("    \(stage.ok ? "[+]" : "[-]") \(stage.name)")
                    if let d = stage.detail, !d.isEmpty {
                        lines.append("        \(d)")
                    }
                }
                if let code = r.errorCode {
                    lines.append("  error_code: \(code)")
                    if let detail = r.errorDetail, !detail.isEmpty {
                        lines.append("  error_detail: \(detail)")
                    }
                }
                if let text = r.finalText, !text.isEmpty {
                    let snippet = String(text.prefix(300))
                    lines.append("  final_text: \(snippet)")
                }
            }
            lines.append("")
        }

        let passedKeys = matrix.filter { results[$0]?.ok == true }
        if !passedKeys.isEmpty {
            lines.append("══ PASSED (\(passedKeys.count)) ══")
            for key in passedKeys {
                guard let r = results[key] else { continue }
                lines.append("  [\(key.tier)] \(key.model) — \(key.profile.displayName) (\(r.latencyMs)ms)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
