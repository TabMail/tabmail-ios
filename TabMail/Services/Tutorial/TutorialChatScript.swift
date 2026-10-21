/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The guided tutorial's chat answers (owner 2026-10-21: scripted, no AI).
/// Each answer is written here and produced on the device. The template one
/// shows the real Create card (`TemplateCreateTool`) and saves on Create; the
/// flight one cites Jordan's seeded email so its pill opens the original.
@MainActor
enum TutorialChatScript {
    static let templateName = "Event RSVP"
    static let templateInstructions = [
        "Confirm you will attend.",
        "Say what you will do before any deadline in the invitation.",
        "Keep it to one or two sentences.",
    ]

    /// The answer to `prompt`, as the agent's reply text (`[Email](N)` refs
    /// are resolved for display by the chat, like an AI reply's).
    /// `practiceReply`: the practice reply as written, the template's example.
    static func answer(
        _ prompt: TutorialCoordinator.ChatPrompt, practiceReply: String?, invocation: ToolInvocation
    ) async -> String {
        switch prompt {
        case .makeTemplate: return await makeTemplate(example: practiceReply ?? "", invocation: invocation)
        case .flights: return await flights()
        case .whatCanYouDo: return capabilities
        }
    }

    private static func makeTemplate(example: String, invocation: ToolInvocation) async -> String {
        do {
            _ = try await TemplateCreateTool().execute(
                arguments: [
                    "name": .string(templateName),
                    "instructions": .array(templateInstructions.map { .string($0) }),
                    "example_reply": .string(example),
                ],
                invocation: invocation)
            return "Saved. The template \"\(templateName)\" follows the reply you just sent, "
                + "so it can be used when you reply to similar invitations."
        } catch {
            return "No template made. Tap Send to try again."
        }
    }

    private static func flights() async -> String {
        let headerId = MessageIdentity.headerId(
            accountId: DemoSeed.demoAccountId, folderPath: "INBOX",
            messageId: DemoSeed.TutorialFixture.jordanFlights)
        let ref = await ChatIdTranslator.shared.toNumericId(headerId)
        return flightsAnswer(emailRef: ref)
    }

    /// The times must match Jordan's seeded email (`TutorialFixtureTests`).
    nonisolated static func flightsAnswer(emailRef: Int) -> String {
        "Jordan suggested a 5pm or a 6:30pm departure, both about $240 round trip. "
            + "The earlier one gets you in sooner; the later one has better seats. [Email](\(emailRef))"
    }

    static let capabilities = """
        Here is some of what I can do:
        - Find past email and sum it up
        - Draft replies, and make templates from the good ones
        - Put events on your calendar and invite people
        - Find a time you are free to meet
        - Set reminders
        - Remember your preferences

        In your own inbox, just ask.
        """
}
