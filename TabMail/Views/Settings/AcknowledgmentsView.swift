/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let libraries: [(name: String, license: String, url: String)] = [
        // Apple — networking & utilities
        ("SwiftNIO", "Apache License 2.0", "https://github.com/apple/swift-nio"),
        ("SwiftNIO SSL", "Apache License 2.0", "https://github.com/apple/swift-nio-ssl"),
        ("SwiftNIO IMAP", "Apache License 2.0", "https://github.com/apple/swift-nio-imap"),
        ("Swift Collections", "Apache License 2.0", "https://github.com/apple/swift-collections"),
        ("Swift Log", "Apache License 2.0", "https://github.com/apple/swift-log"),
        // Database & email
        ("GRDB.swift", "MIT License", "https://github.com/groue/GRDB.swift"),
        ("SwiftMail", "BSD 2-Clause License", "https://github.com/Cocoanetics/SwiftMail"),
        // Parsing & text
        ("SwiftSoup", "MIT License", "https://github.com/scinfu/SwiftSoup"),
        ("ZIPFoundation", "MIT License", "https://github.com/weichsel/ZIPFoundation"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("TabMail is built with the help of these open source libraries. We're grateful to their authors and contributors.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(Self.libraries, id: \.name) { lib in
                        Link(destination: URL(string: lib.url)!) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lib.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(lib.license)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
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
