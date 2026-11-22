/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

/// What the user picked before a compose card opened: the chat's paperclip on a reply
/// (ADR-IOS-114 decision 10). The card adds it once its draft has loaded, through the same steps
/// as its own Photos, Camera and Files buttons, so a photo still loading holds Send, a photo or file
/// that cannot be read is reported, and Close counts it as something written.
enum ComposeAttachmentPick {
    /// The photo library picker's photos and videos (`PhotoLibraryPickerView`), loaded by the card.
    case photos([NSItemProvider])
    /// The camera's photo.
    case camera(UIImage)
    /// The Files picker's files (`FilePickerView`), read by the card.
    case files([URL])
}
