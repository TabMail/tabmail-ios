/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The first trailing button owns the full-swipe gesture in every inbox row layout.
struct InboxTrailingSwipeActions: View {
    enum Action: Hashable {
        case archive, trash, deleteDraft

        var title: String {
            switch self {
            case .archive: "Archive"
            case .trash: "Trash"
            case .deleteDraft: "Delete"
            }
        }
    }

    let isDrafts: Bool
    let isArchive: Bool
    let isTrash: Bool
    let archive: () -> Void
    let delete: () -> Void

    var actions: [Action] { isDrafts ? [.deleteDraft] : [.archive, .trash] }

    func perform(_ action: Action) {
        guard actions.contains(action) else { return }
        switch action {
        case .archive: if !isArchive { archive() }
        case .trash: if !isTrash { delete() }
        case .deleteDraft: delete()
        }
    }

    var body: some View {
        ForEach(actions, id: \.self) { action in
            let inert = action == .archive ? isArchive : isTrash
            Button(role: action == .archive || inert ? nil : .destructive) {
                perform(action)
            } label: {
                let symbol = action == .archive ? "archivebox" : "trash"
                if inert {
                    Label {
                        Text(action.title)
                    } icon: {
                        Image(uiImage: UIImage(systemName: symbol)!
                            .withTintColor(.systemGray, renderingMode: .alwaysOriginal))
                    }
                } else {
                    Label(action.title, systemImage: symbol)
                }
            }
            .tint(inert ? Color(.systemGray3) : action == .archive ? Theme.archive : .red)
        }
    }
}
