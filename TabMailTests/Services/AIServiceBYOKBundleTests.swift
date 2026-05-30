/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Tests for AIService.byokBundle — the synchronous resolver that
// BackendClient.augmentRequestWithDefaults reads to attach a per-tier BYOK
// config onto every outbound completions request.
//
// Storage layout under test:
//   UserDefaults["byok.background.provider"] / .model
//   UserDefaults["byok.interactive.provider"] / .model
//   Keychain (BYOK accessors): account="background" / "interactive"

@Suite("AIService BYOK bundle resolver", .serialized)
struct AIServiceBYOKBundleTests {

    /// Clear all BYOK state so tests can start from a known baseline. Each
    /// test calls this in setUp + tearDown.
    ///
    /// Also clears any lingering demo session — the simulator Keychain
    /// persists across test runs, and AIService.byokBundle returns nil while
    /// a demo session exists (see DemoTokenManager.hasSession defense-in-depth).
    /// If a prior run left a demo JWT, every "expect non-nil bundle" assertion
    /// silently fails.
    static func clearAllBYOK() {
        DemoTokenManager.clearSession()
        for tier in ["background", "interactive"] {
            UserDefaults.standard.removeObject(forKey: AIService.byokProviderKey(tier: tier))
            for provider in ["openai", "anthropic", "google"] {
                UserDefaults.standard.removeObject(forKey: AIService.byokModelKey(tier: tier, provider: provider))
            }
        }
        for provider in ["openai", "anthropic", "google"] {
            KeychainHelper.deleteBYOK(provider: provider)
        }
    }

    @Test("Returns nil when no tier is configured (defaults to TabMail pool)")
    func nilWhenUnconfigured() {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        #expect(AIService.shared.byokBundle == nil)
    }

    @Test("Returns nil when both tiers explicitly set to 'tabmail' sentinel")
    func nilWhenAllTabMail() {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("tabmail", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("tabmail", forKey: AIService.byokProviderKey(tier: "interactive"))
        #expect(AIService.shared.byokBundle == nil)
    }

    @Test("Returns config with only background when only background is configured")
    func onlyBackgroundConfigured() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("gpt-5.5", forKey: AIService.byokModelKey(tier: "background", provider: "openai"))
        try KeychainHelper.saveBYOK("sk-test-bg", provider: "openai")

        let bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background?.provider == "openai")
        #expect(bundle.background?.model == "gpt-5.5")
        #expect(bundle.background?.api_key == "sk-test-bg")
        #expect(bundle.interactive == nil)
    }

    @Test("Returns nil when provider set but model missing (partial config)")
    func partialConfigSkipped() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("anthropic", forKey: AIService.byokProviderKey(tier: "interactive"))
        // model is intentionally NOT set
        try KeychainHelper.saveBYOK("sk-ant-test", provider: "anthropic")

        // Partial → skipped, bundle empty → nil
        #expect(AIService.shared.byokBundle == nil)
    }

    @Test("Returns nil when key missing in Keychain")
    func missingKeySkipped() {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("google", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("gemini-3-flash-preview", forKey: AIService.byokModelKey(tier: "background", provider: "google"))
        // Keychain deliberately empty
        #expect(AIService.shared.byokBundle == nil)
    }

    @Test("Returns full config with both tiers when both are configured")
    func bothTiersConfigured() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("gpt-5.5", forKey: AIService.byokModelKey(tier: "background", provider: "openai"))
        try KeychainHelper.saveBYOK("sk-bg-key", provider: "openai")

        UserDefaults.standard.set("anthropic", forKey: AIService.byokProviderKey(tier: "interactive"))
        UserDefaults.standard.set("claude-opus-4-7", forKey: AIService.byokModelKey(tier: "interactive", provider: "anthropic"))
        try KeychainHelper.saveBYOK("sk-ant-int-key", provider: "anthropic")

        let bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background?.provider == "openai")
        #expect(bundle.interactive?.provider == "anthropic")
        #expect(bundle.background?.api_key == "sk-bg-key")
        #expect(bundle.interactive?.model == "claude-opus-4-7")
    }

    @Test("Returns nil during a demo session, even with BYOK fully configured")
    func nilDuringDemo() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }

        // Configure BYOK fully so the only path back to nil is the demo gate.
        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("gpt-5.5", forKey: AIService.byokModelKey(tier: "background", provider: "openai"))
        try KeychainHelper.saveBYOK("sk-test", provider: "openai")
        // Sanity: without a demo session, the bundle resolves.
        #expect(AIService.shared.byokBundle != nil)

        // Simulate a demo session by writing a fake JSON envelope at the demo
        // Keychain key. DemoTokenManager.hasSession() only checks for the
        // presence of the key — content doesn't need to be a real session.
        let fakeSession = """
        {"accessToken":"demo-fake","sub":"00000000-0000-4000-8000-44454d4f0000","expiresAt":9999999999}
        """.data(using: .utf8)!
        try KeychainHelper.save(fakeSession, for: "demo_session")
        defer { KeychainHelper.delete(key: "demo_session") }

        // With a demo session present, bundle must be nil.
        #expect(AIService.shared.byokBundle == nil)
    }

    @Test("Mixing 'tabmail' sentinel for one tier returns only the BYOK tier")
    func mixedSentinelAndBYOK() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }
        UserDefaults.standard.set("tabmail", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("google", forKey: AIService.byokProviderKey(tier: "interactive"))
        UserDefaults.standard.set("gemini-3.1-pro-preview", forKey: AIService.byokModelKey(tier: "interactive", provider: "google"))
        try KeychainHelper.saveBYOK("AIzaTestKey-with-correct-length-padding", provider: "google")

        let bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background == nil)
        #expect(bundle.interactive?.provider == "google")
    }

    @Test("Switching active provider picks up the other provider's shared key + per-tier model")
    func switchingProvidersPicksUpOtherProvidersConfig() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }

        // Pre-stage per-provider keys (one each) and per-(tier, provider) models.
        try KeychainHelper.saveBYOK("sk-oai", provider: "openai")
        try KeychainHelper.saveBYOK("sk-ant", provider: "anthropic")
        UserDefaults.standard.set("gpt-5.5", forKey: AIService.byokModelKey(tier: "background", provider: "openai"))
        UserDefaults.standard.set("claude-opus-4-7", forKey: AIService.byokModelKey(tier: "background", provider: "anthropic"))

        // Active provider = OpenAI. Resolver picks OpenAI's shared key + tier model.
        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "background"))
        var bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background?.provider == "openai")
        #expect(bundle.background?.model == "gpt-5.5")
        #expect(bundle.background?.api_key == "sk-oai")

        // Flip → Anthropic. Resolver picks Anthropic's shared key + tier model.
        UserDefaults.standard.set("anthropic", forKey: AIService.byokProviderKey(tier: "background"))
        bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background?.provider == "anthropic")
        #expect(bundle.background?.model == "claude-opus-4-7")
        #expect(bundle.background?.api_key == "sk-ant")
    }

    @Test("One key services BOTH tiers when both route to the same provider")
    func sharedKeyAcrossTiers() throws {
        Self.clearAllBYOK()
        defer { Self.clearAllBYOK() }

        // Single OpenAI key, two different OpenAI models per-tier.
        try KeychainHelper.saveBYOK("sk-shared-oai", provider: "openai")
        UserDefaults.standard.set("gpt-5.4-mini", forKey: AIService.byokModelKey(tier: "background", provider: "openai"))
        UserDefaults.standard.set("gpt-5.5-pro", forKey: AIService.byokModelKey(tier: "interactive", provider: "openai"))

        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "background"))
        UserDefaults.standard.set("openai", forKey: AIService.byokProviderKey(tier: "interactive"))

        let bundle = try #require(AIService.shared.byokBundle)
        #expect(bundle.background?.api_key == "sk-shared-oai")
        #expect(bundle.interactive?.api_key == "sk-shared-oai")
        #expect(bundle.background?.model == "gpt-5.4-mini")
        #expect(bundle.interactive?.model == "gpt-5.5-pro")
    }
}

