/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the pure-function metadata helpers in ProviderSettingsView.
/// Locks the deep-link URLs and
/// the display-name capitalization so the "Get a key →" button always opens
/// the right console and the picker label always reads "Google" (not
/// "Gemini" — see deviation #2).
@Suite("BYOK provider info helpers")
struct BYOKProviderInfoTests {

    // MARK: - displayName

    @Test func displayNameOpenAI() {
        #expect(BYOKProviderInfo.displayName("openai") == "OpenAI")
    }

    @Test func displayNameAnthropic() {
        #expect(BYOKProviderInfo.displayName("anthropic") == "Anthropic")
    }

    @Test func displayNameGoogle() {
        // Deviation #2 — wire id is "google", display is "Google" (NOT
        // "Gemini" — Gemini is the model family, not the provider).
        #expect(BYOKProviderInfo.displayName("google") == "Google")
    }

    @Test func displayNameTabMailSentinel() {
        #expect(BYOKProviderInfo.displayName("tabmail") == "Tabmail")
    }

    @Test func displayNameUnknownFallsBackToCapitalized() {
        #expect(BYOKProviderInfo.displayName("xyz") == "Xyz")
    }

    // MARK: - keyURL

    @Test func openAIKeyURL() {
        #expect(BYOKProviderInfo.keyURL("openai")?.absoluteString == "https://platform.openai.com/api-keys")
    }

    @Test func anthropicKeyURL() {
        #expect(BYOKProviderInfo.keyURL("anthropic")?.absoluteString == "https://console.anthropic.com/settings/keys")
    }

    @Test func googleKeyURL() {
        #expect(BYOKProviderInfo.keyURL("google")?.absoluteString == "https://aistudio.google.com/app/apikey")
    }

    @Test func tabmailHasNoKeyURL() {
        #expect(BYOKProviderInfo.keyURL("tabmail") == nil)
    }

    // MARK: - ZDR disclaimer

    @Test func openAIDisclaimerCallsOutEnterprise() {
        #expect(BYOKProviderInfo.zdrDisclaimer("openai").contains("enterprise"))
    }

    @Test func anthropicDisclaimerSaysNoTraining() {
        #expect(BYOKProviderInfo.zdrDisclaimer("anthropic").contains("not used for training"))
    }

    @Test func googleDisclaimerWarnsAboutFreeTier() {
        // Google's free-tier API can be used for training.
        let copy = BYOKProviderInfo.zdrDisclaimer("google")
        #expect(copy.contains("paid"))
    }

    @Test func unknownProviderDisclaimerIsEmpty() {
        #expect(BYOKProviderInfo.zdrDisclaimer("xyz") == "")
    }

    // MARK: - billingSeparationNote — provider-specific copy that warns users
    // their consumer subscription doesn't cover API access.

    @Test func openAIBillingNoteMentionsChatGPTPlus() {
        // ChatGPT Plus / Pro are the consumer plans most likely to confuse.
        #expect(BYOKProviderInfo.billingSeparationNote("openai").contains("ChatGPT"))
    }

    @Test func anthropicBillingNoteMentionsClaudeMax() {
        // Claude Max is the high-end consumer plan; users assume it covers API.
        #expect(BYOKProviderInfo.billingSeparationNote("anthropic").contains("Claude"))
    }

    @Test func googleBillingNoteMentionsGemini() {
        #expect(BYOKProviderInfo.billingSeparationNote("google").contains("Gemini"))
    }

    @Test func unknownProviderBillingNoteIsEmpty() {
        #expect(BYOKProviderInfo.billingSeparationNote("xyz") == "")
    }
}

/// Tests for the model-picker merge helpers: `liveIdMatches`, `isAvailable`,
/// and `mergeModels`. These back the two-Section picker ("Recommended" / "All
/// models (from your API key)") so newly released models are selectable
/// without an app update. Config-agnostic per feedback_llm_catalog_config_
/// agnostic_tests — uses placeholder model IDs, never the real catalog.
@Suite("BYOK model merge helpers")
struct BYOKModelMergeTests {

    // MARK: - liveIdMatches

    @Test func liveIdMatchesExactId() {
        #expect(BYOKProviderInfo.liveIdMatches("model-a", recommendedId: "model-a"))
    }

    @Test func liveIdMatchesDatedVariant() {
        #expect(BYOKProviderInfo.liveIdMatches("model-a-20260101", recommendedId: "model-a"))
    }

    @Test func liveIdDoesNotMatchNonNumericSuffix() {
        // "model-a-pro" isn't a dated variant of "model-a" — a different
        // model that happens to share a prefix (mirrors the gpt-5.5 /
        // gpt-5.5-pro false-positive concern).
        #expect(BYOKProviderInfo.liveIdMatches("model-a-pro", recommendedId: "model-a") == false)
    }

    @Test func liveIdDoesNotMatchUnrelatedId() {
        #expect(BYOKProviderInfo.liveIdMatches("model-b", recommendedId: "model-a") == false)
    }

    @Test func liveIdDoesNotMatchEmptyDatedSuffix() {
        // Trailing "-" with nothing after it isn't a valid dated variant.
        #expect(BYOKProviderInfo.liveIdMatches("model-a-", recommendedId: "model-a") == false)
    }

    // MARK: - isAvailable

    @Test func isAvailableTrueForExactMatch() {
        #expect(BYOKProviderInfo.isAvailable("model-a", in: ["model-a", "model-b"]))
    }

    @Test func isAvailableTrueForDatedVariant() {
        #expect(BYOKProviderInfo.isAvailable("model-a", in: ["model-a-20260101"]))
    }

    @Test func isAvailableFalseWhenAbsent() {
        #expect(BYOKProviderInfo.isAvailable("model-a", in: ["model-b"]) == false)
    }

    // MARK: - mergeModels

    @Test func mergeModelsPreservesRecommendedOrder() {
        let recommended = ["model-c", "model-a", "model-b"]
        let result = BYOKProviderInfo.mergeModels(recommended: recommended, available: [])
        #expect(result.recommended == recommended)
    }

    @Test func mergeModelsEmptyAvailableYieldsNoAdditional() {
        let result = BYOKProviderInfo.mergeModels(recommended: ["model-a"], available: [])
        #expect(result.recommended == ["model-a"])
        #expect(result.additional.isEmpty)
    }

    @Test func mergeModelsEmptyRecommendedPutsAllAvailableIntoAdditional() {
        let result = BYOKProviderInfo.mergeModels(recommended: [], available: ["model-x", "model-y"])
        #expect(result.recommended.isEmpty)
        #expect(result.additional == ["model-x", "model-y"])
    }

    @Test func mergeModelsExcludesExactDuplicateFromAdditional() {
        let result = BYOKProviderInfo.mergeModels(recommended: ["model-a"], available: ["model-a", "model-b"])
        #expect(result.additional == ["model-b"])
    }

    @Test func mergeModelsExcludesDatedVariantFromAdditional() {
        // A dated live id that matches a recommended dateless alias must NOT
        // be duplicated in "All models" — it's already represented by the
        // Recommended entry.
        let result = BYOKProviderInfo.mergeModels(
            recommended: ["model-a"],
            available: ["model-a-20260101", "model-b"]
        )
        #expect(result.additional == ["model-b"])
    }

    @Test func mergeModelsPreservesAvailableOrderForAdditional() {
        let result = BYOKProviderInfo.mergeModels(recommended: [], available: ["model-z", "model-a", "model-m"])
        #expect(result.additional == ["model-z", "model-a", "model-m"])
    }

    @Test func mergeModelsDedupesRepeatedAvailableEntries() {
        let result = BYOKProviderInfo.mergeModels(recommended: [], available: ["model-a", "model-a", "model-b"])
        #expect(result.additional.count == 2)
        guard result.additional.count == 2 else { return }
        #expect(result.additional[0] == "model-a")
        #expect(result.additional[1] == "model-b")
    }

    @Test func mergeModelsBothEmpty() {
        let result = BYOKProviderInfo.mergeModels(recommended: [], available: [])
        #expect(result.recommended.isEmpty)
        #expect(result.additional.isEmpty)
    }
}

/// Pins the cross-file poster/listener contract for the BYOK key-change
/// signal: APIKeysView posts `.byokKeyChanged` after Keychain save/delete
/// (Keychain writes don't fire UserDefaults.didChangeNotification), and
/// BYOKTierRows listens to invalidate its live-model cache and refetch.
@Suite("BYOK key-changed notification")
struct BYOKKeyChangedNotificationTests {

    @Test func notificationNameIsStable() {
        #expect(Notification.Name.byokKeyChanged.rawValue == "byokKeyChanged")
    }

    @Test func notificationCarriesProviderAsObject() {
        // The listener reads `note.object as? String` — pin that a posted
        // notification round-trips the provider string through that cast.
        let note = Notification(name: .byokKeyChanged, object: "openai")
        #expect(note.object as? String == "openai")
    }
}
