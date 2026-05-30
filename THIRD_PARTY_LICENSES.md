# Third-Party Licenses

TabMail for iOS bundles or depends on the following third-party components.
Each retains its own license; the licenses below are not superseded by this
project's MPL-2.0 license.

---

## Swift package dependencies

### SwiftMail

- **Source:** https://github.com/TabMail/SwiftMail (BSD-2-Clause fork of https://github.com/Cocoanetics/SwiftMail)
- **License:** BSD 2-Clause
- **Author:** Oliver Drobnik (Cocoanetics)
- **Usage:** IMAP/SMTP client used by the main app and the notification service

### SwiftSoup

- **Source:** https://github.com/scinfu/SwiftSoup
- **License:** MIT License
- **Author:** Nabil Chatbi
- **Usage:** HTML parsing/sanitization for message rendering

### GRDB.swift

- **Source:** https://github.com/groue/GRDB.swift
- **License:** MIT License
- **Author:** Gwendal Roué
- **Usage:** SQLite persistence layer (message store, FTS, sync state)

---

## Vendored source

### sqlite-vec

- **Source:** https://github.com/asg017/sqlite-vec
- **License:** Apache License 2.0 OR MIT License (dual-licensed)
- **Author:** Alex Garcia
- **Usage:** SQLite vector-similarity extension, vendored as static C in
  `TabMail/Vendor/sqlite-vec/` and registered per database connection for
  hybrid semantic + keyword search
- **License texts:** vendored in-tree at `TabMail/Vendor/sqlite-vec/LICENSE-APACHE`
  and `TabMail/Vendor/sqlite-vec/LICENSE-MIT`

---

## Bundled model & tokenizer

### all-MiniLM-L6-v2 (Sentence Transformer model)

- **Source:** https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- **License:** Apache License 2.0
- **Authors:** Nils Reimers and the Sentence Transformers team (https://www.sbert.net)
- **Base model:** nreimers/MiniLM-L6-H384-uncased
- **Usage:** On-device sentence embeddings for semantic search. Bundled as a
  Core ML model (`TabMail/Resources/AllMiniLML6v2.mlmodelc`) with its WordPiece
  tokenizer config (`TabMail/Resources/tokenizer.json`), which embeds the
  vocabulary. The model weights are unmodified.

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
(tracked). Exact resolved versions appear in `Package.resolved`, which
Xcode / Swift Package Manager generates on the first package resolve.
