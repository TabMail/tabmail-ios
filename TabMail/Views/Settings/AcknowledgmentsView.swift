/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let wordListLicense = "The word list (words.txt and languages.json) adapts the sources above and is licensed to you under CC BY-SA 4.0, independent of any App Store terms. Sources, changes and notices: TabMail/Vendor/wordlist/README.md"
    private static let wordListLicenseURL = "https://github.com/TabMail/tabmail-ios/blob/main/TabMail/Vendor/wordlist/README.md"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("TabMail is built with the help of these open source libraries and models. We're grateful to their authors and contributors. Tap one for its license.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(AcknowledgmentEntry.all) { entry in
                        NavigationLink {
                            AcknowledgmentDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(entry.license)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    if let url = URL(string: Self.wordListLicenseURL) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Self.wordListLicense)
                            Link("Word list README", destination: url)
                        }
                    }
                }
            }
            .navigationTitle("Acknowledgments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One credit: the copyright, any line the author asks for, and the license text(s) as published.
struct AcknowledgmentDetailView: View {
    let entry: AcknowledgmentEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.copyright)
                    .font(.subheadline)
                if let note = entry.note {
                    Text(note)
                        .font(.subheadline)
                }
                if let url = URL(string: entry.url) {
                    Link(entry.url, destination: url)
                        .font(.footnote)
                }
                ForEach(entry.texts, id: \.path) { text in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text.title)
                            .font(.headline)
                        Text(AcknowledgmentText.load(text.path))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AcknowledgmentText {
    /// The license file at `path` under the app bundle's resources; empty when it isn't there.
    static func load(_ path: String) -> String {
        guard let root = Bundle.main.resourceURL,
              let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return "" }
        return text
    }
}
