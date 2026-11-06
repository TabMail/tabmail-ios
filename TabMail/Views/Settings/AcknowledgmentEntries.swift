/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// One credit on the Acknowledgments screen: who made it, under which license, and the license
/// text(s) shown verbatim when the row is opened (MIT, BSD and Apache-2.0 require the notice and
/// the license text to go with the binary). The texts are files in the bundled `licenses` folder
/// (`TabMail/Vendor/licenses`), or the license files pdf.js already ships in its own folder.
struct AcknowledgmentEntry: Identifiable, Equatable {
    struct LicenseText: Equatable {
        let title: String
        /// Path under the app bundle's resource folder.
        let path: String
    }

    let name: String
    let license: String
    let url: String
    let copyright: String
    /// A line the license or the author asks for next to the credit (an acknowledgment sentence, a
    /// statement of change).
    let note: String?
    let texts: [LicenseText]

    var id: String { name }

    init(name: String, license: String, url: String, copyright: String, note: String? = nil, texts: [LicenseText]) {
        self.name = name
        self.license = license
        self.url = url
        self.copyright = copyright
        self.note = note
        self.texts = texts
    }

    private static func text(_ title: String, _ file: String) -> LicenseText {
        LicenseText(title: title, path: "licenses/\(file).txt")
    }

    static let apacheRuntimeException = "Apache License 2.0 with Runtime Library Exception"

    /// The credits, in the order they are shown. Each license text is the file as published by the
    /// project (its NOTICE after it where it has one), not a rewrite.
    static let all: [AcknowledgmentEntry] = [
        AcknowledgmentEntry(
            name: "SwiftMail (TabMail fork)", license: "BSD 2-Clause License",
            url: "https://github.com/TabMail/SwiftMail",
            copyright: "Copyright (c) 2025, Oliver Drobnik. All rights reserved. Forked from https://github.com/Cocoanetics/SwiftMail",
            texts: [text("License", "swiftmail")]),
        AcknowledgmentEntry(
            name: "SwiftCross", license: "MIT License", url: "https://github.com/Cocoanetics/SwiftCross",
            copyright: "Copyright (c) 2026 Cocoanetics / Oliver Drobnik",
            texts: [text("License", "swiftcross")]),
        AcknowledgmentEntry(
            name: "SwiftSoup", license: "MIT License", url: "https://github.com/scinfu/SwiftSoup",
            copyright: "Copyright (c) 2009-2025 Jonathan Hedley; Copyright (c) 2016-2025 Nabil Chatbi (Swift port). Includes LRUCache, Copyright (c) 2021 Nick Lockwood (MIT).",
            texts: [text("License", "swiftsoup"), text("LRUCache license", "lrucache")]),
        AcknowledgmentEntry(
            name: "GRDB.swift", license: "MIT License", url: "https://github.com/groue/GRDB.swift",
            copyright: "Copyright (C) 2015-2025 Gwendal Roué. Includes English inflection rules, Copyright (c) 2005-2019 David Heinemeier Hansson (MIT).",
            texts: [text("License", "grdb"), text("English inflections license", "rails-inflections")]),
        AcknowledgmentEntry(
            name: "SwiftNIO", license: "Apache License 2.0", url: "https://github.com/apple/swift-nio",
            copyright: "Copyright 2017, 2018 The SwiftNIO Project. Includes \"cpp_magic.h\" by Thomas Nixon and Jonathan Heathcote (MIT).",
            texts: [text("License and notice", "swift-nio"), text("cpp_magic.h license", "cpp-magic")]),
        AcknowledgmentEntry(
            name: "SwiftNIO SSL", license: "Apache License 2.0", url: "https://github.com/apple/swift-nio-ssl",
            copyright: "Copyright 2017, 2018 The SwiftNIO Project",
            texts: [text("License and notice", "swift-nio-ssl")]),
        AcknowledgmentEntry(
            name: "BoringSSL (in SwiftNIO SSL)", license: "Apache License 2.0",
            url: "https://boringssl.googlesource.com/boringssl",
            copyright: "Copyright The BoringSSL Authors (Google). The revision SwiftNIO SSL 2.37.6 vendors, pinned by the repository's Package.resolved.",
            texts: [text("License", "boringssl")]),
        AcknowledgmentEntry(
            name: "SwiftNIO IMAP", license: "Apache License 2.0", url: "https://github.com/apple/swift-nio-imap",
            copyright: "Copyright 2020 The SwiftNIO Project. Includes fastbase64, Copyright (c) 2015-2016 Wojciech Muła, Alfred Klomp, Daniel Lemire (BSD 2-Clause), and stringencoders, Copyright (c) 2016 Nick Galbreath (MIT).",
            texts: [text("License and notice", "swift-nio-imap"), text("fastbase64 license", "fastbase64"), text("stringencoders license", "stringencoders")]),
        AcknowledgmentEntry(
            name: "Swift Log", license: "Apache License 2.0", url: "https://github.com/apple/swift-log",
            copyright: "Copyright 2018, 2019 The SwiftLog Project",
            texts: [text("License and notice", "swift-log")]),
        AcknowledgmentEntry(
            name: "Swift Collections", license: apacheRuntimeException, url: "https://github.com/apple/swift-collections",
            copyright: "Copyright (c) Apple Inc. and the Swift project authors",
            texts: [text("License", "swift-collections")]),
        AcknowledgmentEntry(
            name: "Swift Atomics", license: apacheRuntimeException, url: "https://github.com/apple/swift-atomics",
            copyright: "Copyright (c) Apple Inc. and the Swift project authors",
            texts: [text("License", "swift-atomics")]),
        AcknowledgmentEntry(
            name: "sqlite-vec", license: "MIT License (dual-licensed MIT or Apache 2.0, used under MIT)",
            url: "https://github.com/asg017/sqlite-vec", copyright: "Copyright (c) 2024 Alex Garcia",
            texts: [text("License", "sqlite-vec")]),
        AcknowledgmentEntry(
            name: "PDF.js", license: "Apache License 2.0", url: "https://github.com/mozilla/pdf.js",
            copyright: "Copyright Mozilla Foundation. Includes core-js, Copyright (c) 2013-2025 Denis Pushkarev; Copyright (c) 2025-2026 CoreJS Company (MIT).",
            texts: [LicenseText(title: "License", path: "pdfjs/LICENSE"), text("core-js license", "core-js")]),
        AcknowledgmentEntry(
            name: "PDF.js CMaps", license: "BSD 3-Clause License",
            url: "https://github.com/mozilla/pdf.js/tree/master/external/bcmaps",
            copyright: "Copyright 1990-2009 Adobe Systems Incorporated. All rights reserved.",
            texts: [LicenseText(title: "License", path: "pdfjs/cmaps/LICENSE")]),
        AcknowledgmentEntry(
            name: "all-MiniLM-L6-v2", license: "Apache License 2.0",
            url: "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2",
            copyright: "Nils Reimers and the Sentence Transformers contributors",
            note: "Modified: converted to Core ML with 16-bit floating-point weights, with mean pooling and L2 normalization added.",
            texts: [text("License", "apache-2.0")]),
        AcknowledgmentEntry(
            name: "MiniLM (base model of all-MiniLM-L6-v2)", license: "MIT License",
            url: "https://huggingface.co/microsoft/MiniLM-L12-H384-uncased",
            copyright: "Copyright (c) Microsoft Corporation",
            texts: [text("License", "minilm-base")]),
        AcknowledgmentEntry(
            name: "BERT WordPiece vocabulary", license: "Apache License 2.0", url: "https://github.com/google-research/bert",
            copyright: "Google",
            texts: [text("License", "apache-2.0")]),
        // The screen-term word list (ADR-IOS-101); its README, bundled with the list, holds the full credits and notices.
        AcknowledgmentEntry(
            name: "FrequencyWords", license: "CC BY-SA 4.0", url: "https://github.com/hermitdave/FrequencyWords",
            copyright: "Hermit Dave",
            note: "Word counts of OpenSubtitles 2018, adapted into the word list screen terms are judged by, itself licensed CC BY-SA 4.0.",
            texts: [LicenseText(title: "Sources, changes and notices", path: "wordlist/README.md")]),
        AcknowledgmentEntry(
            name: "OpenSubtitles 2018", license: "The subtitles FrequencyWords counted", url: "https://www.opensubtitles.org",
            copyright: "P. Lison and J. Tiedemann, through OPUS (LREC 2016)",
            texts: [LicenseText(title: "Sources, changes and notices", path: "wordlist/README.md")]),
        AcknowledgmentEntry(
            name: "wordfreq", license: "Apache License 2.0 (code), CC BY-SA 4.0 (data)", url: "https://github.com/rspeer/wordfreq",
            copyright: "Robyn Speer",
            note: "Its word normalization and letter tables.",
            texts: [text("License", "apache-2.0"), LicenseText(title: "Sources, changes and notices", path: "wordlist/README.md")]),
        AcknowledgmentEntry(
            name: "OpenCC", license: "Apache License 2.0", url: "https://github.com/BYVoid/OpenCC",
            copyright: "Carbo Kuo and the OpenCC contributors",
            note: "Traditional to Simplified Chinese, through wordfreq's table.",
            texts: [text("License", "apache-2.0"), LicenseText(title: "Sources, changes and notices", path: "wordlist/README.md")]),
        AcknowledgmentEntry(
            name: "Unicode CLDR", license: "Unicode License v3", url: "https://cldr.unicode.org",
            copyright: "Copyright (c) 2015-2024 Unicode, Inc.",
            note: "The letters each language is written in.",
            texts: [LicenseText(title: "Sources, changes and notices", path: "wordlist/README.md")]),
    ]
}
