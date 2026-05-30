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
        }
        .onChange(of: providerValue) { _, newValue in
            // Key is shared per-provider; model is per-(tier, provider). Restore
            // any previously-chosen model for this provider; if none, a default
            // is auto-selected below.
            modelValue = UserDefaults.standard.string(forKey: AIService.byokModelKey(tier: tier, provider: newValue)) ?? ""
            refreshHasKey()
            ensureDefaultModel()
        }
        .onChange(of: tierModels) { _, _ in
            // Catalog can arrive after the view appears (loaded async). Pick the
            // default once it's available.
            ensureDefaultModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshHasKey()
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

            if !tierModels.isEmpty {
                Picker("Model", selection: $modelValue) {
                    ForEach(tierModels, id: \.self) { model in
                        Text(model).tag(model)
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
    private var tierModels: [String] {
        catalog?[providerValue]?[tier] ?? []
    }

    private func refreshHasKey() {
        guard providerValue != "tabmail" else { hasKey = false; return }
        hasKey = (KeychainHelper.loadBYOK(provider: providerValue) ?? "").isEmpty == false
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
