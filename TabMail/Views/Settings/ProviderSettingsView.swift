/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// BYOK Settings UI components, embedded inline within TabMailSettingsView's
/// Form. There is intentionally no wrapper navigation view — the two tier
/// entries (Background / Interactive) sit directly in the parent form so the
/// user doesn't have to drill into a sub-screen for two rows.
///
/// Demo gating is the parent's responsibility (TabMailSettingsView hides the
/// AI Provider sections entirely when `DemoModeStore.shared.isActive`).

// MARK: - Per-tier rows
//
// Renders the BYOK controls for a single tier as a flat row sequence (no
// Section wrapper). Parent embeds two of these inside a single Section
// ("AI Provider") so Background + Interactive sit together.

struct BYOKTierRows: View {
    let tier: String
    /// Picker label shown to the user — "Light" or "Heavy".
    let pickerLabel: String
    /// Short caption explaining what this tier covers. Rendered as a secondary
    /// caption line under the picker.
    let caption: String
    let catalog: BYOKModelCatalog?

    @AppStorage private var providerValue: String
    @State private var modelValue: String = ""
    @State private var hasKey: Bool = false
    /// Live model IDs the user's key can access, per provider (`POST
    /// /byok/list-models`). Cached per provider for this view's lifetime so
    /// switching providers back and forth doesn't refetch. nil entry = not
    /// fetched yet for that provider; empty array = fetched, none available.
    @State private var liveModelsByProvider: [String: [String]] = [:]

    init(tier: String, pickerLabel: String, caption: String, catalog: BYOKModelCatalog?) {
        self.tier = tier
        self.pickerLabel = pickerLabel
        self.caption = caption
        self.catalog = catalog
        self._providerValue = AppStorage(wrappedValue: "tabmail", AIService.byokProviderKey(tier: tier))
    }

    var body: some View {
        // Picker row: title on the left, dropdown on the right (same line),
        // caption description spans the full cell width underneath. Caption
        // is a sibling of the Picker, not part of its label — that keeps the
        // selected-value chevron anchored next to the title.
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: $providerValue) {
                Text("TabMail").tag("tabmail")
                Text("OpenAI").tag("openai")
                Text("Anthropic").tag("anthropic")
                Text("Google").tag("google")
            } label: {
                HStack(spacing: 4) {
                    Text(pickerLabel)
                    if providerValue != "tabmail" && !hasKey {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
            .pickerStyle(.menu)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            modelValue = UserDefaults.standard.string(forKey: AIService.byokModelKey(tier: tier, provider: providerValue)) ?? ""
            refreshHasKey()
            ensureDefaultModel()
            Task { await refreshLiveModelsIfNeeded() }
        }
        .onChange(of: providerValue) { _, newValue in
            // Key is shared per-provider; model is per-(tier, provider). Restore
            // any previously-chosen model for this provider; if none, a default
            // is auto-selected below.
            modelValue = UserDefaults.standard.string(forKey: AIService.byokModelKey(tier: tier, provider: newValue)) ?? ""
            refreshHasKey()
            ensureDefaultModel()
            Task { await refreshLiveModelsIfNeeded() }
        }
        .onChange(of: tierModels) { _, _ in
            // Catalog can arrive after the view appears (loaded async). Pick the
            // default once it's available.
            ensureDefaultModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshHasKey()
            Task { await refreshLiveModelsIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .byokKeyChanged)) { note in
            // A key was saved, rotated, or removed — any cached live list for
            // that provider reflects the OLD key's entitlements. Invalidate it
            // and refetch (fetch is a no-op unless the current provider has a
            // stored key and no cached list).
            if let provider = note.object as? String {
                liveModelsByProvider[provider] = nil
            }
            refreshHasKey()
            Task { await refreshLiveModelsIfNeeded() }
        }

        if providerValue != "tabmail" {
            if !hasKey {
                NavigationLink {
                    APIKeysView()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("API key missing")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            if !mergedModels.recommended.isEmpty || !mergedModels.additional.isEmpty {
                Picker("Model", selection: $modelValue) {
                    if !mergedModels.recommended.isEmpty {
                        Section("Recommended") {
                            ForEach(mergedModels.recommended, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    if !mergedModels.additional.isEmpty {
                        Section("All models (from your API key)") {
                            ForEach(mergedModels.additional, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: modelValue) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: AIService.byokModelKey(tier: tier, provider: providerValue))
                }
            } else if catalog != nil {
                Text("No models available for this tier")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary).font(.footnote)
                }
            }
        }
    }

    /// Catalog models for the current provider + tier (empty if not loaded / none).
    /// This is the "Recommended" list — catalog order preserved, first entry
    /// is the auto-selected default (cheapest-first for Light).
    private var tierModels: [String] {
        catalog?[providerValue]?[tier] ?? []
    }

    /// Live model IDs the current provider's key can access, if fetched.
    private var liveModels: [String] {
        liveModelsByProvider[providerValue] ?? []
    }

    /// Recommended (catalog) + Additional (live-only) models for the picker's
    /// two Sections. See `BYOKProviderInfo.mergeModels`.
    private var mergedModels: (recommended: [String], additional: [String]) {
        BYOKProviderInfo.mergeModels(recommended: tierModels, available: liveModels)
    }

    private func refreshHasKey() {
        guard providerValue != "tabmail" else { hasKey = false; return }
        hasKey = (KeychainHelper.loadBYOK(provider: providerValue) ?? "").isEmpty == false
    }

    /// Fetches the live model list for the current provider via `POST
    /// /byok/list-models`, only when a Keychain key is stored for it and we
    /// haven't already cached a SUCCESSFUL result for this provider this
    /// view's lifetime. Progressive enhancement: on failure, the picker
    /// simply falls back to showing the Recommended section only — failure
    /// is visible in the debug log, not surfaced to the user (this mirrors
    /// the existing catalog-fetch-failure handling in
    /// TabMailSettingsView.loadBYOKCatalogIfNeeded). Failures are NOT cached,
    /// so a later trigger (provider switch, UserDefaults change) retries —
    /// same retry-on-next-trigger behavior as the catalog fetch.
    @MainActor
    private func refreshLiveModelsIfNeeded() async {
        // Capture the provider ONCE at entry. `providerValue` is @AppStorage —
        // if the user switches providers while the fetch is in flight, a
        // re-read after the await would cache THIS fetch's models under the
        // NEW provider's key (and the nil-guard would then permanently block
        // the correct fetch for that provider). Keying the guard, the
        // Keychain read, the request, AND the write-back to the captured
        // value makes the result land in the right slot regardless of what
        // the picker does meanwhile.
        let provider = providerValue
        guard provider != "tabmail" else { return }
        guard liveModelsByProvider[provider] == nil else { return }
        guard let apiKey = KeychainHelper.loadBYOK(provider: provider), !apiKey.isEmpty else { return }

        let result = await BackendClient().listBYOKModels(provider: provider, apiKey: apiKey)
        if result.ok {
            liveModelsByProvider[provider] = result.models ?? []
        } else if DebugModeManager.isLoggingEnabled() {
            print("[BYOK] list-models failed for \(provider): \(result.error_code ?? "?") \(result.error_detail ?? "")")
        }
    }

    /// When a non-TabMail provider is selected but no model is chosen for this
    /// (tier, provider), auto-select the first catalog model and persist it.
    /// Without this, an empty model means `AIService.byokBundle` resolves to nil
    /// and the request SILENTLY falls back to the TabMail pool (the user thinks
    /// they're on their own provider but aren't). The choice is remembered via
    /// UserDefaults, so it persists across launches and provider switches.
    private func ensureDefaultModel() {
        guard providerValue != "tabmail" else { return }
        guard modelValue.isEmpty else { return }
        guard let first = tierModels.first else { return } // catalog not loaded yet
        modelValue = first
        UserDefaults.standard.set(first, forKey: AIService.byokModelKey(tier: tier, provider: providerValue))
    }
}

// MARK: - Per-provider metadata

enum BYOKProviderInfo {
    /// Every provider a BYOK key can be stored for.
    ///
    /// Single source of truth on purpose: BYOK Keychain items are keyed by this raw string, so any
    /// list that enumerates providers for DELETION (see `AppDataWiper`) must not be able to drift from
    /// the list that offers them for ENTRY. A provider present in one list and absent from the other
    /// is a key that can be saved but never wiped.
    static let allProviders = ["openai", "anthropic", "google"]

    static func displayName(_ raw: String) -> String {
        switch raw {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google"
        default: return raw.capitalized
        }
    }

    static func keyURL(_ raw: String) -> URL? {
        switch raw {
        case "openai":    return URL(string: "https://platform.openai.com/api-keys")
        case "anthropic": return URL(string: "https://console.anthropic.com/settings/keys")
        case "google":    return URL(string: "https://aistudio.google.com/app/apikey")
        default: return nil
        }
    }

    /// Heads-up that API billing is separate from the provider's consumer
    /// subscription (ChatGPT Plus, Claude Max, etc.) — easy to assume
    /// otherwise and burn time before figuring out you need to load
    /// developer credits separately.
    static func billingSeparationNote(_ raw: String) -> String {
        switch raw {
        case "openai":
            return "API access uses separate billing from ChatGPT Plus / Pro. Load credits at platform.openai.com."
        case "anthropic":
            return "API access uses separate billing from Claude Pro / Max. Load credits at console.anthropic.com."
        case "google":
            return "API access uses separate billing from Gemini Advanced. Enable billing in Google AI Studio."
        default:
            return ""
        }
    }

    /// True if a live model ID (from a provider's models-list endpoint)
    /// represents the same model as a recommended/catalog ID. Tolerant of
    /// provider ID-format quirks: a provider's live list may return a DATED
    /// canonical ID (e.g. Anthropic's `claude-haiku-4-5-20251001`) while our
    /// catalog uses the dateless alias the request actually sends
    /// (`claude-haiku-4-5`). Treats `<recommendedId>-<digits>` as a match.
    /// The digits-only suffix check avoids false positives like `gpt-5.5`
    /// matching `gpt-5.5-pro`.
    static func liveIdMatches(_ liveId: String, recommendedId: String) -> Bool {
        if liveId == recommendedId { return true }
        let datedPrefix = recommendedId + "-"
        guard liveId.hasPrefix(datedPrefix) else { return false }
        let suffix = liveId.dropFirst(datedPrefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Whether a recommended/catalog model ID is present in a set of live
    /// model IDs the user's key can access — exact match or a dated variant
    /// (see `liveIdMatches`).
    static func isAvailable(_ recommendedModel: String, in available: Set<String>) -> Bool {
        available.contains { liveIdMatches($0, recommendedId: recommendedModel) }
    }

    /// Merges a curated "recommended" model list (catalog order, first =
    /// default) with the full list of models the user's API key can access,
    /// for a two-Section model picker ("Recommended" / "All models (from
    /// your API key)"). `additional` is `available` filtered down to IDs NOT
    /// already covered by a recommended ID (exact or dated-variant match,
    /// see `liveIdMatches`) — so newly released models are selectable
    /// without an app update, without duplicating entries already surfaced
    /// as Recommended. Order of `available` is preserved (the backend
    /// already sorts it); `recommended` is passed through unchanged.
    static func mergeModels(recommended: [String], available: [String]) -> (recommended: [String], additional: [String]) {
        guard !available.isEmpty else { return (recommended, []) }
        var seen = Set<String>()
        var additional: [String] = []
        for liveId in available {
            guard !seen.contains(liveId) else { continue }
            let coveredByRecommended = recommended.contains { liveIdMatches(liveId, recommendedId: $0) }
            guard !coveredByRecommended else { continue }
            seen.insert(liveId)
            additional.append(liveId)
        }
        return (recommended, additional)
    }

    static func zdrDisclaimer(_ raw: String) -> String {
        switch raw {
        case "openai":
            return "Your key and prompts go directly to OpenAI. By default OpenAI doesn't train on API data but keeps 30-day abuse-monitoring logs. True zero retention requires an enterprise agreement."
        case "anthropic":
            return "Your key and prompts go directly to Anthropic. API traffic is not used for training. Logs are retained ~30 days."
        case "google":
            return "Your key and prompts go directly to Google. Only the paid Gemini API tier guarantees no training — free-tier keys may be used to improve Google's models."
        default:
            return ""
        }
    }
}

extension Notification.Name {
    /// Posted by APIKeysView after a BYOK API key is saved, rotated, or
    /// removed in the Keychain. Keychain writes do NOT fire
    /// `UserDefaults.didChangeNotification`, so caches keyed on the key's
    /// entitlements (the live model list in BYOKTierRows) need this explicit
    /// signal to invalidate and refetch. `object` carries the provider
    /// string ("openai" | "anthropic" | "google").
    static let byokKeyChanged = Notification.Name("byokKeyChanged")
}
