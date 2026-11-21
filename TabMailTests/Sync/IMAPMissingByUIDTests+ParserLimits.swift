/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import NIOCore
import SwiftMail
import Testing
@testable import TabMail

/// The client parser's limits the too-large answers are built against, kept in
/// their own file: these imports name types the other files of the suite also
/// name.
extension IMAPMissingByUIDTests {

    /// One byte more than the literal the app's IMAP client accepts (it uses
    /// SwiftMail's default parser limits): the size of the literal
    /// `FakeIMAPServer.answerNextCommandWithOverLimitLiteral` answers with.
    static let overLimitLiteralBytes = IMAPParserLimits.default.literalSizeLimit + 1

    /// The suite's over-limit answer reaches the client's literal limit, not its
    /// response buffer limit, so this failure is classified here directly, from
    /// the error the client's buffer throws.
    @Test("An answer too large for the client's response buffer calls for a smaller range, as a timeout does")
    func payloadTooLargeCallsForASmallerRange() {
        #expect(UIDWalkCursor.failureCallsForSmallerRange(ByteToMessageDecoderError.PayloadTooLargeError()),
                "a response buffer overflow calls for a smaller range")
    }
}
