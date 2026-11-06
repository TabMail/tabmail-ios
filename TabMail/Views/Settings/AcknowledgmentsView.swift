/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    private static let libraries: [(name: String, license: String, url: String, note: String?)] = [
        // Apple — networking & utilities
        ("SwiftNIO", "Apache License 2.0", "https://github.com/apple/swift-nio", nil),
        ("SwiftNIO SSL", "Apache License 2.0", "https://github.com/apple/swift-nio-ssl", nil),
        ("SwiftNIO IMAP", "Apache License 2.0", "https://github.com/apple/swift-nio-imap", nil),
        ("Swift Collections", "Apache License 2.0", "https://github.com/apple/swift-collections", nil),
        ("Swift Log", "Apache License 2.0", "https://github.com/apple/swift-log", nil),
        // Database & email
        ("GRDB.swift", "MIT License", "https://github.com/groue/GRDB.swift", nil),
        ("SwiftMail", "BSD 2-Clause License", "https://github.com/Cocoanetics/SwiftMail", nil),
        // Parsing & text
        ("SwiftSoup", "MIT License", "https://github.com/scinfu/SwiftSoup", nil),
        ("ZIPFoundation", "MIT License", "https://github.com/weichsel/ZIPFoundation", nil),
        ("PDF.js", "Apache License 2.0", "https://github.com/mozilla/pdf.js", nil),
        // The screen-term word list (ADR-IOS-101); the full credits are in its README.
        ("FrequencyWords", "CC BY-SA 4.0", "https://github.com/hermitdave/FrequencyWords",
         "Hermit Dave's word counts of OpenSubtitles 2018, adapted into the word list screen terms are judged by, itself CC BY-SA 4.0"),
        ("OpenSubtitles 2018", "The subtitles FrequencyWords counted", "https://www.opensubtitles.org",
         "Through OPUS: P. Lison and J. Tiedemann, LREC 2016"),
        ("wordfreq", "Apache License 2.0 (code), CC BY-SA 4.0 (data)", "https://github.com/rspeer/wordfreq",
         "Its word normalization and letter tables"),
        ("OpenCC", "Apache License 2.0", "https://github.com/BYVoid/OpenCC",
         "Traditional to Simplified Chinese, through wordfreq's table"),
        ("Unicode CLDR", "Unicode License v3", "https://cldr.unicode.org", "The letters each language is written in"),
    ]

    private static let wordListLicense = "The word list (words.txt and languages.json) adapts the sources above and is licensed to you under CC BY-SA 4.0, independent of any App Store terms. Sources, changes and notices: TabMail/Vendor/wordlist/README.md"
    private static let wordListLicenseURL = "https://github.com/TabMail/tabmail-ios/blob/main/TabMail/Vendor/wordlist/README.md"

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
                                if let note = lib.note {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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
