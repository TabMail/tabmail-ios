/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Wire-shape contract for the BYOK additions to BackendClient. Pins the
// byte-identical guarantee for non-BYOK requests (the non-BYOK wire-shape
// regression guarantee) and the presence/shape of fields for BYOK-routed
// requests / responses.

@Suite("BYOK wire types")
struct BYOKWireTypeTests {

    // ---------- BYOKConfig encoding ----------

    @Test("BYOKConfig with nil tiers encodes as empty object (no null keys)")
    func emptyConfigOmitsNulls() throws {
        let cfg = BYOKConfig()
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "{}")
    }

    @Test("BYOKConfig with only background tier omits interactive key")
    func onlyBackground() throws {
        let cfg = BYOKConfig(
            background: BYOKTierConfig(provider: "openai", api_key: "sk-test", model: "gpt-5.5")
        )
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"background\""))
        #expect(!json.contains("\"interactive\""))
        #expect(json.contains("\"openai\""))
        #expect(json.contains("\"sk-test\""))
    }

    @Test("BYOKConfig with both tiers includes both keys")
    func bothTiers() throws {
        let cfg = BYOKConfig(
            background: BYOKTierConfig(provider: "openai", api_key: "sk-bg", model: "gpt-5.5"),
            interactive: BYOKTierConfig(provider: "anthropic", api_key: "sk-ant-int", model: "claude-opus-4-7")
        )
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"background\""))
        #expect(json.contains("\"interactive\""))
        #expect(json.contains("\"openai\""))
        #expect(json.contains("\"anthropic\""))
    }

    @Test("hasAnyOverride is false for empty config, true with any tier set")
    func hasAnyOverride() {
        #expect(BYOKConfig().hasAnyOverride == false)
        let onlyBg = BYOKConfig(background: BYOKTierConfig(provider: "openai", api_key: "k", model: "m"))
        #expect(onlyBg.hasAnyOverride == true)
        let onlyInt = BYOKConfig(interactive: BYOKTierConfig(provider: "google", api_key: "k", model: "m"))
        #expect(onlyInt.hasAnyOverride == true)
    }

    // ---------- CompletionsRequest wire-shape ----------

    @Test("CompletionsRequest with nil byok OMITS the byok key")
    func nilByokOmitsKey() throws {
        let req = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
            // byok defaulted to nil
        )
        let data = try JSONEncoder().encode(req)
        let json = String(data: data, encoding: .utf8)!
        // Must NOT contain "byok" — emitting "byok": null would not be byte-
        // identical to pre-BYOK clients per the non-BYOK wire-shape regression
        // guarantee.
        #expect(!json.contains("\"byok\""))
    }

    @Test("CompletionsRequest with byok set includes the byok key")
    func byokSetIncludesKey() throws {
        let req = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil,
            byok: BYOKConfig(background: BYOKTierConfig(provider: "anthropic", api_key: "sk-ant-x", model: "claude-haiku-4-5"))
        )
        let data = try JSONEncoder().encode(req)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"byok\""))
        #expect(json.contains("\"background\""))
        #expect(json.contains("\"anthropic\""))
        #expect(json.contains("claude-haiku-4-5"))
    }

    @Test("CompletionsRequest other Optional fields also use encodeIfPresent")
    func otherOptionalsAlsoOmitted() throws {
        // disable_tools / client_timezone / web_search_enabled / conversation_state
        // all use encodeIfPresent — must not appear as null when nil.
        let req = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        let data = try JSONEncoder().encode(req)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"disable_tools\""))
        #expect(!json.contains("\"client_timezone\""))
        #expect(!json.contains("\"web_search_enabled\""))
        #expect(!json.contains("\"conversation_state\""))
    }

    // ---------- CompletionsResponse decoding ----------

    @Test("CompletionsResponse decodes BYOK flags when present")
    func responseDecodesByokFlags() throws {
        let payload = """
        {
          "assistant": "hello",
          "token_usage": { "input_tokens": 10, "output_tokens": 5, "total_tokens": 15 },
          "byok_routed": true,
          "byok_provider": "anthropic",
          "byok_tier": "interactive"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: payload)
        #expect(decoded.byok_routed == true)
        #expect(decoded.byok_provider == "anthropic")
        #expect(decoded.byok_tier == "interactive")
        #expect(decoded.byok_skip_reason == nil)
    }

    @Test("CompletionsResponse decodes skip reason when not routed")
    func responseDecodesSkipReason() throws {
        let payload = """
        {
          "assistant": "hi",
          "token_usage": { "input_tokens": 1, "output_tokens": 1, "total_tokens": 2 },
          "byok_routed": false,
          "byok_skip_reason": "tier_entry_invalid"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: payload)
        #expect(decoded.byok_routed == false)
        #expect(decoded.byok_skip_reason == "tier_entry_invalid")
        #expect(decoded.byok_provider == nil)
    }

    @Test("CompletionsResponse decodes provider-error envelope")
    func responseDecodesErrorEnvelope() throws {
        let payload = """
        {
          "token_usage": { "input_tokens": 0, "output_tokens": 0, "total_tokens": 0 },
          "error_code": "byok_key_rejected",
          "error_detail": "Invalid API key",
          "retry_after_seconds": 30
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: payload)
        #expect(decoded.error_code == "byok_key_rejected")
        #expect(decoded.error_detail == "Invalid API key")
        #expect(decoded.retry_after_seconds == 30)
    }

    @Test("Legacy CompletionsResponse (no BYOK fields) still decodes")
    func legacyResponseDecodes() throws {
        // Non-BYOK wire-shape regression guarantee: pre-BYOK clients receiving
        // pre-BYOK responses must keep working. New optional fields must
        // default to nil on absence.
        let payload = """
        {
          "assistant": "old reply",
          "token_usage": { "input_tokens": 4, "output_tokens": 6, "total_tokens": 10 }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: payload)
        #expect(decoded.assistant == "old reply")
        #expect(decoded.byok_routed == nil)
        #expect(decoded.byok_provider == nil)
        #expect(decoded.error_code == nil)
    }

    // ---------- BYOKModelCatalog decoding ----------

    @Test("BYOKModelCatalog decodes the 3-level shape")
    func catalogDecodes() throws {
        let payload = """
        {
          "openai":    { "background": ["gpt-5.5"], "interactive": ["gpt-5.5", "gpt-5.5-pro"] },
          "anthropic": { "background": ["claude-haiku-4-5"], "interactive": ["claude-opus-4-7"] },
          "google":    { "background": ["gemini-3-flash-preview"], "interactive": ["gemini-3.1-pro-preview"] }
        }
        """.data(using: .utf8)!
        let cat = try JSONDecoder().decode(BYOKModelCatalog.self, from: payload)
        #expect(cat["openai"]?["interactive"]?.contains("gpt-5.5-pro") == true)
        #expect(cat["anthropic"]?["background"] == ["claude-haiku-4-5"])
        #expect(cat["google"]?.keys.count == 2)
    }
}
