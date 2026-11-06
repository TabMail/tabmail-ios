# Third-Party Licenses

TabMail for iOS bundles or depends on the following third-party components.
Each retains its own license; the licenses below are not superseded by this
project's MPL-2.0 license.

---

## Swift package dependencies

The license text of each, as published, is bundled in `TabMail/Vendor/licenses/` and shown in the
app under Settings, Acknowledgments.

### SwiftMail

- **Source:** https://github.com/TabMail/SwiftMail (fork of https://github.com/Cocoanetics/SwiftMail)
- **License:** BSD 2-Clause
- **Copyright:** Copyright (c) 2025, Oliver Drobnik
- **Usage:** IMAP/SMTP client used by the main app and the notification service

### SwiftCross

- **Source:** https://github.com/Cocoanetics/SwiftCross (a SwiftMail dependency)
- **License:** MIT License
- **Copyright:** Copyright (c) 2026 Cocoanetics / Oliver Drobnik

### SwiftSoup

- **Source:** https://github.com/scinfu/SwiftSoup
- **License:** MIT License
- **Copyright:** Copyright (c) 2009-2025 Jonathan Hedley; Copyright (c) 2016-2025 Nabil Chatbi (Swift port).
  Includes LRUCache, Copyright (c) 2021 Nick Lockwood (MIT)
- **Usage:** HTML parsing/sanitization for message rendering

### GRDB.swift

- **Source:** https://github.com/groue/GRDB.swift
- **License:** MIT License
- **Copyright:** Copyright (C) 2015-2025 Gwendal Roué. Includes English inflection rules,
  Copyright (c) 2005-2019 David Heinemeier Hansson (MIT)
- **Usage:** SQLite persistence layer (message store, FTS, sync state)

### SwiftNIO, SwiftNIO SSL, SwiftNIO IMAP and Swift Log

- **Source:** https://github.com/apple/swift-nio, https://github.com/apple/swift-nio-ssl,
  https://github.com/apple/swift-nio-imap, https://github.com/apple/swift-log
- **License:** Apache License 2.0, each with its NOTICE
- **Copyright:** The SwiftNIO Project (2017-2020); The SwiftLog Project (2018, 2019). SwiftNIO includes
  "cpp_magic.h" by Thomas Nixon and Jonathan Heathcote (MIT). SwiftNIO IMAP includes fastbase64,
  Copyright (c) 2015-2016 Wojciech Muła, Alfred Klomp, Daniel Lemire (BSD 2-Clause), and stringencoders,
  Copyright (c) 2016 Nick Galbreath (MIT)
- **Usage:** Networking and TLS for the IMAP/SMTP client

### BoringSSL (inside SwiftNIO SSL)

- **Source:** https://boringssl.googlesource.com/boringssl
- **License:** Apache License 2.0 (`TabMail/Vendor/licenses/boringssl.txt`, the LICENSE of the vendored
  revision as published). The BoringSSL revision depends on the SwiftNIO SSL release, which the
  repository pins in `Package.resolved` (2.37.6 and later vendor the Apache-2.0 BoringSSL; earlier releases
  vendored an OpenSSL-lineage one), so the license shown is the one shipped.
- **Copyright:** The BoringSSL Authors (Google)

### Swift Collections and Swift Atomics

- **Source:** https://github.com/apple/swift-collections, https://github.com/apple/swift-atomics
- **License:** Apache License 2.0 with Runtime Library Exception
- **Copyright:** Apple Inc. and the Swift project authors

---

## Vendored source

### sqlite-vec

- **Source:** https://github.com/asg017/sqlite-vec
- **License:** Apache License 2.0 OR MIT License (dual-licensed; used under MIT)
- **Copyright:** Copyright (c) 2024 Alex Garcia
- **Usage:** SQLite vector-similarity extension, vendored as static C in
  `TabMail/Vendor/sqlite-vec/` and registered per database connection for
  hybrid semantic + keyword search
- **License texts:** vendored in-tree at `TabMail/Vendor/sqlite-vec/LICENSE-APACHE`
  and `TabMail/Vendor/sqlite-vec/LICENSE-MIT`

### PDF.js

- **Source:** https://github.com/mozilla/pdf.js — the `pdfjs-dist` 6.3.289 npm release, copied
  unmodified: `legacy/build/pdf.min.mjs`, `legacy/build/pdf.worker.min.mjs`, `cmaps/` and `LICENSE`
- **License:** Apache License 2.0 (`TabMail/Vendor/pdfjs/LICENSE`); the CMaps in `cmaps/` are
  BSD-3-Clause (`TabMail/Vendor/pdfjs/cmaps/LICENSE`)
- **Copyright:** Mozilla Foundation; CMaps © Adobe Systems Incorporated
- **Includes core-js** (MIT; Copyright (c) 2013-2025 Denis Pushkarev, 2025-2026 CoreJS Company): the
  polyfills embedded in `pdf.min.mjs` and `pdf.worker.min.mjs`; license text in
  `TabMail/Vendor/licenses/core-js.txt`
- **Usage:** Extracts the text of PDF attachments for the chat agent's `attachment_read_pdf` tool,
  in a hidden web view, vendored in `TabMail/Vendor/pdfjs/`. Text only: no rendering, scripting or
  forms.

---

## Bundled data

### Word list for dictation screen terms

- **Files:** `TabMail/Vendor/wordlist/words.txt` and `languages.json`, bundled as a folder resource; the
  sources, the changes made and the notices are in `TabMail/Vendor/wordlist/README.md`
- **Sources:** FrequencyWords (Hermit Dave; word counts of OpenSubtitles 2018, CC BY-SA 4.0;
  https://github.com/hermitdave/FrequencyWords); OpenSubtitles 2018 through OPUS (P. Lison and
  J. Tiedemann, LREC 2016; https://www.opensubtitles.org); wordfreq (Robyn Speer; Apache License 2.0 code
  whose word normalization and letter tables are used, CC BY-SA 4.0 data; https://github.com/rspeer/wordfreq);
  OpenCC (Apache License 2.0; Traditional to Simplified Chinese through wordfreq's table;
  https://github.com/BYVoid/OpenCC); Unicode CLDR (Unicode License v3; Copyright (c) 1991-2025 Unicode, Inc.;
  https://cldr.unicode.org)
- **License of the files:** CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/), as the sources
  are. The files adapt the sources: filtered, converted to Zipf tenths, merged and sorted. They are
  licensed to you under CC BY-SA 4.0 independent of any App Store terms. The same files are in the public
  repositories of TabMail for iOS and TabMail Voice.
- **Usage:** Decides which words on screen are rare enough to give the speech model as vocabulary

---

## Bundled model & tokenizer

### all-MiniLM-L6-v2 (Sentence Transformer model)

- **Source:** https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- **License:** Apache License 2.0
- **Authors:** Nils Reimers and the Sentence Transformers team (https://www.sbert.net)
- **Base model:** nreimers/MiniLM-L6-H384-uncased, a 6-layer version of microsoft/MiniLM-L12-H384-uncased
  (MIT License, Copyright (c) Microsoft Corporation)
- **Usage:** On-device sentence embeddings for semantic search. Bundled as a
  Core ML model (`TabMail/Resources/AllMiniLML6v2.mlmodelc`) with its WordPiece
  tokenizer config (`TabMail/Resources/tokenizer.json`), which embeds the
  vocabulary. Modified: converted to Core ML with 16-bit floating-point weights, with mean pooling
  and L2 normalization added; the weights are otherwise unchanged.

**Citation:**

```bibtex
@inproceedings{reimers-2019-sentence-bert,
  title = "Sentence-BERT: Sentence Embeddings using Siamese BERT-Networks",
  author = "Reimers, Nils and Gurevych, Iryna",
  booktitle = "Proceedings of the 2019 Conference on Empirical Methods
               in Natural Language Processing",
  month = "11",
  year = "2019",
  publisher = "Association for Computational Linguistics",
  url = "https://arxiv.org/abs/1908.10084",
}
```

The WordPiece vocabulary embedded in `tokenizer.json` derives from Google's BERT
(`bert-base-uncased`, Apache License 2.0).

---

## Test tooling

### SnapshotHelper.swift

- **Source:** https://github.com/fastlane/fastlane (snapshot)
- **License:** MIT License
- **Author:** fastlane / Google LLC
- **Usage:** UI-test screenshot helper in `TabMailScreenshots/`; carries its
  original header and is not relicensed under MPL.

---

For the transitive dependency graph and version constraints, see `project.yml`
(tracked). Exact resolved versions are pinned in the tracked `Package.resolved`
at the repository root.
