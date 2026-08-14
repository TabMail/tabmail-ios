/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import CoreText
import CoreGraphics
@testable import TabMail

// MARK: - Attachment FILENAME safety: one predicate, two verdicts
//
// The invariant, stated as a system property rather than as a naming rule:
// **a sender-authored attachment filename is either used VERBATIM as one path
// component, or it is REFUSED — and nothing in between.** No attachment write
// escapes the slot directory it was given, no refused name reaches the
// filesystem or the screen, and a legitimate name is never refused.
//
// This is about `att.filename` — the sender-authored MIME `filename` parameter,
// which reaches both `saveAttachments` implementations, the preview stager and
// every display site unchecked from `AttachmentInfo.filename`. It is NOT about
// `dirName`, whose containment `DraftAttachmentStorage.containedDirURL` already
// owns and `DraftAttachmentFailClosedTests` already pins.
//
// ⚠️ **THIS SUITE ASSERTED A REDUCTION UNTIL 2026-08-12.** The app used to
// TRANSFORM a hostile name into a safe one (strip filter, unassigned filter,
// combining-run cap, length truncation, emptied-stem refill). Five confirmed
// defects across three audit rounds all lived in that machinery, so the owner
// replaced it with `AttachmentFilename.isSafeFileComponent` — a test, not a
// transformation. Every rule below therefore has an ACCEPT case and a REJECT
// case, where the old suite had an input and an expected output.
//
// The RISK MOVED with the design, and the tests move with it: under a reducer
// the danger was a hostile name surviving; under a predicate the danger is a
// LEGITIMATE name being refused, because a false rejection makes a real
// attachment unopenable and unsendable. That is why the accept side of this
// suite is the larger half.
//
// ⚠️ **FIXTURE AXES, enumerated before the matrix rather than after it.** Every
// defect this round retires escaped a large, honest fixture set that varied ONE
// axis exhaustively (1,112,064 fixtures varying *which scalar*, never *how many
// in a run*). Cardinality is not coverage. The axes here are:
//   1. scalar identity — which control / mark / unassigned scalar;
//   2. run length — how many of it in a row, bisected against the real
//      filesystem rather than assumed;
//   3. position — leading, medial, trailing, and after a precomposed base;
//   4. normalisation form — the same word spelled NFC and NFD;
//   5. grapheme-cluster interaction with the characters the STORES add — the
//      `"\(index)_"` prefix in front of a leading mark, and the `".meta"`
//      sidecar behind a trailing `Prepend` scalar;
//   6. total length near the budget, in the unit the filesystem counts in.
// Each test states which of these it varies.

@Suite("Attachment filename safety (predicate, stores, preview stager)")
struct AttachmentFilenameContainmentTests {

    // MARK: - Shared fixtures and helpers

    /// Filenames a sender or provider can put in a MIME `filename` parameter that
    /// this app REFUSES. `photos/img.png` is the ordinary-but-broken case (a mail
    /// client that preserved a relative path); the rest are crafted. `"/"` is the
    /// name that resolves to a DIRECTORY rather than to a file inside it.
    ///
    /// ⚠️ These all SAVED before 2026-08-12, under a transformed name. The old
    /// suite asserted that they saved and round-tripped their bytes; they now
    /// throw, and the user is told. The measured history of which of them threw on
    /// the filesystem PRE-reduction is preserved on
    /// `AttachmentFilename.isSafeFileComponent` — it is not uniform, and
    /// `URL.appendingPathComponent` dropping a TRAILING separator is why.
    private static let refusedNames = [
        "photos/img.png",
        "../../../escaped.txt",
        "/",
        "/etc/passwd",
        "a/b/c/deep.bin",
        // A separator HIDDEN INSIDE A GRAPHEME CLUSTER. Swift `String` iterates
        // extended grapheme clusters, and `U+002F` followed by the combining acute
        // `U+0301` is ONE `Character` that is not equal to `Character("/")` — so a
        // `Character`-wise test does not see it, while the UTF-8 bytes still carry
        // a real `0x2F` the filesystem reads as a separator.
        "..\u{2F}\u{0301}x.pdf",
        // A TRAILING separator, which `URL.appendingPathComponent` DROPS. The
        // outcome probe alone accepts this name; the `U+002F` scalar test is what
        // refuses it, and it must, because the stores use the name verbatim in a
        // STRING context (`"\(index)_\(name)"` and `"\(that).meta"`) where the
        // separator is not dropped at all.
        "invoice.pdf/",
        // A TRAILING NUL. `URL.appendingPathComponent` drops it, so `"..\u{0}"`
        // resolved to the PARENT of the directory it was appended to and `"\u{0}"`
        // collapsed to that directory itself. Refused twice over now — as Cc, and
        // by the outcome probe.
        "..\u{0}",
        "\u{0}",
        ".",
        "..",
        "",
    ]

    /// Names that must be ACCEPTED and used verbatim. The primary risk of this
    /// design is a FALSE REJECTION, so this list is deliberately wide: a refused
    /// legitimate attachment is unopenable and unsendable.
    ///
    /// AXES VARIED: script (Latin, Cyrillic, Greek, Hebrew, Arabic, CJK, Hangul,
    /// Devanagari, Thai, Vietnamese, Tamil, Khmer), normalisation (NFC and NFD
    /// spellings of the same word), sequence-forming mechanisms that are not
    /// combining marks (ZWJ, tag sequences, variation selectors, skin tones,
    /// regional indicators), and ordinary punctuation a human types (spaces,
    /// parentheses, dashes, underscores, dots).
    private static let acceptedNames: [(String, String)] = [
        ("plain", "invoice.pdf"),
        ("spaces, parens and dashes", "Invoice (final) - 2026 v2.pdf"),
        ("leading dot", ".hidden-notes.txt"),
        ("interior dots", "notes ..txt"),
        ("underscores", "year_end_summary.pdf"),
        ("no extension", "README"),
        ("Cyrillic", "счёт-фактура.pdf"),
        ("Greek polytonic, decomposed", "τιμολόγιον ᾅδῃ.pdf".decomposedStringWithCanonicalMapping),
        ("Hebrew", "\u{05D3}\u{05D5}\u{05D7}.pdf"),
        ("Arabic full tashkeel", "بِسْمِ ٱللَّٰهِ.pdf"),
        ("CJK", "\u{6F22}\u{5B57}\u{6587}\u{4EF6}.pdf"),
        ("Korean Hangul", "송장-2026.pdf"),
        ("Devanagari conjunct stack", "क्ष्ण्य.pdf"),
        ("Thai with tone and vowel", "ใบแจ้งหนี้๒๕๖๙.pdf"),
        ("Vietnamese, precomposed", "hóa-đơn-nghiệm.pdf"),
        ("Vietnamese, decomposed", "hóa-đơn-nghiệm.pdf".decomposedStringWithCanonicalMapping),
        ("Tamil", "விலைப்பட்டியல்.pdf"),
        ("Khmer", "វិក្កយបត្រ.pdf"),
        ("Tibetan stack", "བཀྲ་ཤིས་བདེ་ལེགས.pdf"),
        ("Japanese with decomposed dakuten", "がぎぐげご.pdf".decomposedStringWithCanonicalMapping),
        ("IPA stacked diacritics", "t̪ʰa̋ːn̥.pdf"),
        ("Navajo", "łééchąąʼí.pdf"),
        ("ZWJ family emoji", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}report.pdf"),
        ("tag-sequence flag emoji", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}flag.png"),
        ("skin tone plus VS16", "\u{1F44D}\u{1F3FD}\u{2764}\u{FE0F}.pdf"),
        ("regional indicators", "\u{1F1E8}\u{1F1E6}invoice.pdf"),
        ("ideographic variation selector", "\u{845B}\u{E0101}city.pdf"),
        ("ZWNJ in Persian", "\u{0645}\u{06CC}\u{200C}\u{062A}\u{0648}\u{0627}\u{0646}.pdf"),
        ("soft hyphen", "re\u{00AD}port.pdf"),
        ("leading BOM", "\u{FEFF}report.pdf"),
        ("word joiner", "re\u{2060}port.pdf"),
        ("zero-width space", "re\u{200B}port.pdf"),
        // The two names §4 of this round exists for: SAFE by every rule, and each
        // still breaks a `Character`-wise loader. See the two loader tests at the
        // end of this file.
        ("leading combining mark", "\u{0301}foo.pdf"),
        ("trailing Prepend scalar", "invoice\u{0605}"),
        // What the DELETED reducer used to emit. Accepting these is the whole
        // no-migration argument: a draft saved before this round reopens, and
        // re-saves, unchanged.
        ("the old reducer's fallback", "Attachment"),
        ("an old reduced spoof", "reportfdp.exe"),
    ]

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachNameSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Every regular file anywhere beneath `directory`, at any depth.
    private func regularFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// The unit the filesystem actually counts a path component in.
    private func componentUnits(_ s: String) -> Int {
        s.decomposedStringWithCanonicalMapping.utf16.count
    }

    /// The longest CANONICAL COMBINING SEQUENCE in `text`, counted the way the
    /// filesystem counts it: on the NFD form, a `ccc == 0` scalar starts a new
    /// sequence at length 1 and every following non-starter extends it.
    private func longestCombiningSequence(_ text: String) -> Int {
        var current = 0
        var worst = 0
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            current = scalar.properties.canonicalCombiningClass == .notReordered ? 1 : current + 1
            worst = max(worst, current)
        }
        return worst
    }

    /// Saves one attachment into a fresh slot and returns what came back out,
    /// asserting the properties every ACCEPTED name shares: the save SUCCEEDS, the
    /// stored component is the sender's name VERBATIM under the index prefix,
    /// everything written is a direct child of the slot, the bytes survive, and the
    /// `.meta` sidecar was still paired with its data file.
    @discardableResult
    private func expectSavesAndReloads(
        filename: String,
        mimeType: String = "application/pdf",
        payload: Data = Data("round-trip-payload".utf8),
        _ label: Comment
    ) throws -> DraftAttachment? {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirName = "slot"
        let attachment = DraftAttachment(filename: filename, mimeType: mimeType, data: payload)

        try DraftAttachmentStorage.saveAttachments([attachment], dirName: dirName, root: root)

        let slot = DraftAttachmentStorage.dirURL(for: dirName, root: root)
        let slotPath = slot.standardizedFileURL.path
        let files = regularFiles(under: slot)
        #expect(files.count == 2, "one attachment must contribute exactly its data file and its sidecar: \(label)")
        for url in files {
            #expect(
                url.standardizedFileURL.deletingLastPathComponent().path == slotPath,
                "an attachment write landed outside its slot directory: \(url.path) — \(label)"
            )
        }
        // VERBATIM: the stored component is the index prefix and nothing else added
        // to the sender's own name. This is the assertion that replaced "the
        // reduction is a no-op for this name"; under a predicate it holds for EVERY
        // accepted name rather than for a subset.
        #expect(
            Set(files.map(\.lastPathComponent)) == ["0_\(filename)", "0_\(filename).meta"],
            "the stored name is not the sender's name verbatim: \(label)"
        )

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName, root: root)
        #expect(loaded.count == 1, label)
        guard let only = loaded.first else { return nil }
        #expect(only.data == payload, label)
        #expect(only.filename == filename, "the name did not survive the round trip: \(label)")
        // The sidecar is located by NAME, derived from the data file the loader
        // ENUMERATED. Getting the declared MIME type back rather than the
        // `application/octet-stream` fallback is the proof that the data file and
        // its sidecar agree on their stem.
        #expect(only.mimeType == mimeType, label)
        return only
    }

    /// The refusal assertion, on all three surfaces at once: the draft store, the
    /// outbox store and the preview stager each throw, and — the half a throw
    /// assertion alone would miss — NOTHING is left on disk.
    private func expectRefusedEverywhere(_ filename: String, _ label: Comment) throws {
        // DRAFT store. The name is checked before the slot directory is created,
        // so a refused set leaves no partial slot behind.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AttachmentFilenameError.self, "the draft store accepted a refused name: \(label)") {
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: filename, mimeType: "application/pdf", data: Data("X".utf8))],
                dirName: "slot", root: root
            )
        }
        #expect(
            regularFiles(under: root).isEmpty,
            "a refused draft attachment left files on disk: \(label)"
        )

        // OUTBOX store — the SEND path. `attachmentsBaseDir` has no root seam, so
        // isolation comes from the message's own unique id.
        let draft = DraftMessage(
            to: ["recipient@example.com"], subject: "refused name", body: "body",
            attachments: [DraftAttachment(filename: filename, mimeType: "application/pdf", data: Data("X".utf8))]
        )
        let outbox = OutboxMessage(accountId: "acct-refused-\(UUID().uuidString)", draft: draft)
        defer { outbox.deleteAttachments() }
        #expect(throws: AttachmentFilenameError.self, "the outbox store accepted a refused name: \(label)") {
            try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
        }
        if let dir = outbox.attachmentsDir {
            #expect(
                !FileManager.default.fileExists(atPath: dir.path),
                "a refused outbox attachment created its slot directory: \(label)"
            )
        }

        // PREVIEW stager — the DOWNLOAD path. The throw happens before
        // `createDirectory`, so not even the staging root exists afterwards.
        let stagingRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        #expect(throws: AttachmentFilenameError.self, "the preview stager accepted a refused name: \(label)") {
            try AttachmentPreviewStager.stage(
                data: Data("BYTES".utf8),
                messageId: "message-refused",
                originalFilename: filename,
                rootDirectory: stagingRoot
            )
        }
        #expect(
            regularFiles(under: stagingRoot).isEmpty,
            "a refused staging attempt wrote bytes: \(label)"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: stagingRoot.appendingPathComponent("TabMailAttachmentPreviews").path
            ),
            "a refused staging attempt created an attempt directory: \(label)"
        )

        // DISPLAY. The row must not show the sender's string.
        #expect(
            AttachmentFilename.displayLabel(filename) == AttachmentFilename.unsupportedLabel,
            "a refused name reached the screen: \(label)"
        )
    }

    // MARK: - The two verdicts, end to end

    /// The invariant: **a refused name is refused on every surface that could use
    /// it, and leaves nothing behind on any of them.**
    ///
    /// AXES VARIED: separator position (leading, interior, trailing, whole-name,
    /// hidden inside a grapheme cluster), dot spellings including the NUL-suffixed
    /// ones `URL.appendingPathComponent` normalises away, and the empty name.
    /// SHAPES THIS FIXTURE CANNOT PRODUCE: anything refused for length, for a
    /// combining run, for an unassigned scalar or for a bidi control — those have
    /// their own rule-attributed tests below.
    @Test("Every crafted filename is refused by both stores, the preview stager and the label")
    func craftedFilenamesAreRefusedEverywhere() throws {
        for name in Self.refusedNames {
            try expectRefusedEverywhere(name, "\(name.debugDescription)")
        }
    }

    /// The invariant: **an accepted name is stored, sent and previewed VERBATIM.**
    ///
    /// This is the half that matters most now: under a predicate, the way to be
    /// wrong is to refuse something real. Every name here goes through the draft
    /// store, the outbox store (the wire path) and the preview stager.
    @Test("Legitimate filenames are accepted and used verbatim by both stores and the stager")
    func legitimateFilenamesAreAcceptedVerbatim() throws {
        let stagingRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let payload = Data("SENDER-AUTHORED-BYTES".utf8)

        for (label, name) in Self.acceptedNames {
            let comment: Comment = "\(label): \(name.debugDescription)"
            #expect(
                AttachmentFilename.isSafeFileComponent(name),
                "a legitimate filename was refused — the attachment is now unopenable: \(comment)"
            )
            #expect(
                AttachmentFilename.displayLabel(name) == name,
                "an accepted name is not shown to the user as itself: \(comment)"
            )

            try expectSavesAndReloads(filename: name, mimeType: "application/pdf", payload: payload, comment)

            // The OUTBOX store — this name goes on the wire as the MIME `filename`
            // parameter of a sent message.
            let draft = DraftMessage(
                to: ["recipient@example.com"], subject: "accepted name", body: "body",
                attachments: [DraftAttachment(filename: name, mimeType: "application/pdf", data: payload)]
            )
            let outbox = OutboxMessage(accountId: "acct-accepted-\(UUID().uuidString)", draft: draft)
            defer { outbox.deleteAttachments() }
            try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
            let sent = try outbox.loadAttachments()
            #expect(sent.count == 1, comment)
            #expect(sent.first?.filename == name, "the outbox would send the wrong filename: \(comment)")
            #expect(sent.first?.data == payload, comment)

            // The PREVIEW stager — the file QuickLook opens is named exactly this.
            let staged = try AttachmentPreviewStager.stage(
                data: payload,
                messageId: "message-accepted",
                originalFilename: name,
                rootDirectory: stagingRoot
            )
            #expect(staged.lastPathComponent == name, "the staged file was renamed: \(comment)")
            #expect((try? Data(contentsOf: staged)) == payload, comment)
        }
    }

    // MARK: - Rule 1: not empty, not a spelling of `.` or `..`

    /// Rule 1, attributed: each name is refused, and the SAME name with one
    /// ordinary character added is accepted — so the refusal is attributable to
    /// the dot-or-empty spelling and to nothing else it happens to contain.
    ///
    /// ⚠️ The rule is asserted as an OUTCOME, not as a list of refused strings. The
    /// old guard refused exactly `"."` and `".."`, and `URL.appendingPathComponent`
    /// DROPS a trailing NUL — so `"..\u{0}"` passed it and resolved to the PARENT
    /// of the directory it was appended to. Adding that spelling to a list would
    /// have been the same mistake one entry longer.
    @Test("Rule 1 — the empty name and every spelling of . or .. is refused")
    func emptyAndDotComponentsAreRefused() {
        for (refused, accepted) in [("", "x"), (".", ".x"), ("..", "..x"), ("...", "...x")] {
            let comment: Comment = "\(refused.debugDescription) vs \(accepted.debugDescription)"
            // `"..."` is NOT a dot component and must be ACCEPTED — the two-sided
            // half, without which "refuse anything made of dots" would pass.
            if refused == "..." {
                #expect(AttachmentFilename.isSafeFileComponent(refused), "three dots is an ordinary name: \(comment)")
            } else {
                #expect(!AttachmentFilename.isSafeFileComponent(refused), "not refused: \(comment)")
            }
            #expect(
                AttachmentFilename.isSafeFileComponent(accepted),
                "the same name plus one ordinary character must be accepted, or the refusal is not attributable to rule 1: \(comment)"
            )
        }
        // The NUL-suffixed spellings the old list-based guard could not express.
        for spelling in ["..\u{0}", "\u{0}", "..\u{0}\u{0}", "\u{0}.."] {
            #expect(
                !AttachmentFilename.isSafeFileComponent(spelling),
                "a NUL-suffixed dot spelling was accepted: \(spelling.debugDescription)"
            )
        }
    }

    // MARK: - Rule 2: no separator, and no nesting below the slot

    /// Rule 2, attributed: removing exactly the `U+002F` scalar flips every one of
    /// these to accepted, so the refusal is the separator's and not the rest of the
    /// name's.
    ///
    /// AXES VARIED: separator position (leading, interior, trailing, doubled,
    /// whole-name) and encoding (bare, and hidden inside a grapheme cluster with a
    /// following combining mark).
    @Test("Rule 2 — a filename containing U+002F is refused, in every position and encoding")
    func separatorBearingNamesAreRefused() {
        let pairs = [
            ("photos/img.png", "photosimg.png"),
            ("/etc/passwd", "etcpasswd"),
            ("a/b/c/deep.bin", "abcdeep.bin"),
            ("invoice.pdf/", "invoice.pdf"),
            ("//invoice.pdf", "invoice.pdf"),
            // The hidden separator: the ONLY difference between these two strings
            // is the `U+002F` scalar inside the first one's leading cluster.
            ("..\u{2F}\u{0301}x.pdf", "..\u{0301}x.pdf"),
        ]
        for (refused, accepted) in pairs {
            let comment: Comment = "\(refused.debugDescription)"
            #expect(!AttachmentFilename.isSafeFileComponent(refused), "a separator-bearing name was accepted: \(comment)")
            #expect(
                AttachmentFilename.isSafeFileComponent(accepted),
                """
                removing only the separator must make \(accepted.debugDescription) acceptable, or the \
                refusal is not attributable to rule 2 — \(comment)
                """
            )
        }
        // The `Character`-vs-scalar property stated directly, because it is the
        // reason the test is over scalars: the hidden separator is not
        // `Character("/")`, so a `Character`-wise implementation sees no separator
        // at all while the filesystem sees a real `0x2F`.
        let hidden = "..\u{2F}\u{0301}x.pdf"
        #expect(!hidden.contains(Character("/")), "fixture check: the separator is no longer hidden in a cluster")
        #expect(hidden.unicodeScalars.contains("/"), "fixture check: the fixture no longer carries a separator scalar")
    }

    /// Both halves of rule 2 are load-bearing and neither implies the other.
    ///
    /// The OUTCOME probe alone accepts `"invoice.pdf/"`, because
    /// `URL.appendingPathComponent` drops a trailing separator — and the stores use
    /// the name verbatim in a STRING context (`"\(index)_\(name)"`, and the sidecar
    /// `"\(that).meta"`) where nothing drops it, so the data file and its sidecar
    /// would name different things. The SCALAR test alone accepts `".."`.
    @Test("Rule 2 — the separator test and the containment probe each refuse what the other accepts")
    func bothHalvesOfTheContainmentRuleAreNeeded() {
        let probe = URL(fileURLWithPath: "/probe", isDirectory: true)
        func probeAccepts(_ name: String) -> Bool {
            probe.appendingPathComponent(name).standardized
                .deletingLastPathComponent().path == probe.standardized.path
        }
        #expect(probeAccepts("invoice.pdf/"), "fixture check: the probe no longer drops a trailing separator")
        #expect(!AttachmentFilename.isSafeFileComponent("invoice.pdf/"))
        #expect(!"..".unicodeScalars.contains("/"), "fixture check")
        #expect(!AttachmentFilename.isSafeFileComponent(".."))
    }

    /// The containment probe is checked against a FIXED base rather than against
    /// the directory the caller will actually use. That is only legitimate under
    /// TWO facts, and this test pins both, because either one alone licenses
    /// nothing:
    ///
    /// 1. the verdict is the same at every base of **depth ≥ 1**; and
    /// 2. the base `isSafeFileComponent` actually uses has depth ≥ 1.
    ///
    /// ⚠️ **This test asserted a STRONGER, FALSE property until 2026-08-12: that
    /// the verdict is base-independent FULL STOP, "which is a property of
    /// `appendingPathComponent` — it transforms the component the same way whatever
    /// the base is."** Both the claim and the mechanism were wrong.
    ///
    /// - The claim: **at the ROOT, `".."`, `"."`, `""`, `"\u{0}"` and `"..\u{0}"`
    ///   all PASS**, and at every depth ≥ 1 they all fail. Measured on this
    ///   toolchain; the old fixture set varied four bases but never depth 0, so it
    ///   could not see this and stayed green on a false invariant.
    /// - The mechanism: the verdict comes from **`.standardized`**, not from
    ///   `appendingPathComponent`. `.standardized` collapses a `..` against the
    ///   base's own **depth** — `/a/..` collapses to `/`, whose parent is `/`, so
    ///   the parent-equality test says "escaped"; `/..` collapses to `/` too, but
    ///   there `deletingLastPathComponent` is a FIXPOINT (`/`'s parent is `/`), so
    ///   the same test says "contained". `appendingPathComponent` is base-oblivious
    ///   exactly as claimed, and that is not the step the verdict turns on.
    ///
    /// **Operational impact at the time of writing is nil** — `isSafeFileComponent`
    /// hardcodes `/probe`, depth 1. The defect is the INVARIANT: a false
    /// base-independence claim is what would license relocating that probe later
    /// and silently disarming rule 1. Fact 2 is asserted BEHAVIOURALLY below rather
    /// than by reading the probe's path, so it stays true through any refactor that
    /// keeps the predicate's contract.
    @Test("The containment verdict is invariant across bases of depth >= 1, and diverges at the root")
    func containmentVerdictIsInvariantBelowTheRootAndDivergesAtIt() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let bases = [
            URL(fileURLWithPath: "/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/ns/attempt", isDirectory: true),
            URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Documents/drafts/slot",
                isDirectory: true),
            FileManager.default.temporaryDirectory.appendingPathComponent("x", isDirectory: true),
        ]
        func readsAsDirectChild(of base: URL, _ name: String) -> Bool {
            base.appendingPathComponent(name).standardized
                .deletingLastPathComponent().path == base.standardized.path
        }
        let escapingNames = ["..", ".", "..\u{0}", "\u{0}", ""]

        // FACT 1a — every ACCEPTED name lands as a direct child of every depth-≥1
        // base, and of the root as well: an ordinary name never depended on depth.
        for (label, name) in Self.acceptedNames {
            for base in bases + [root] {
                #expect(
                    readsAsDirectChild(of: base, name),
                    "\(label) does not land as a direct child of \(base.path)"
                )
            }
        }
        // FACT 1b — two-sided: at depth ≥ 1 the check must be able to say NO, or
        // every line above passes for a verdict that is constantly true.
        for escaping in escapingNames {
            for base in bases {
                #expect(
                    !readsAsDirectChild(of: base, escaping),
                    """
                    \(escaping.debugDescription) appended RAW to \(base.path) must NOT read as a \
                    direct child — otherwise the probe proves nothing
                    """
                )
            }
        }
        // THE KNOWN DIVERGENCE, pinned as an equality so it cannot rot into a
        // silent assumption: at the ROOT the same five names read as CONTAINED.
        for escaping in escapingNames {
            #expect(
                readsAsDirectChild(of: root, escaping),
                """
                \(escaping.debugDescription) at the ROOT is expected to read as a direct child — if \
                this now fails, `.standardized`/`deletingLastPathComponent` changed and the probe's \
                depth requirement should be re-derived, not deleted
                """
            )
        }
        // FACT 2 — the production probe is NOT the root, asserted behaviourally.
        // Fact 1 alone licenses nothing: all five names are CONTAINED at depth 0,
        // so a root probe would make rule 1 vacuous.
        //
        // Only three of the five discriminate. `"\u{0}"` and `"..\u{0}"` carry a
        // NUL, which rule 3 refuses on its own, so they would stay refused under a
        // root probe and prove nothing about the probe's depth. `""`, `"."` and
        // `".."` are refusable by rule 1 ALONE — no `/`, no refused scalar, nothing
        // unassigned, no combining run, inside the budget — so the predicate saying
        // NO to them is only possible if its probe has depth >= 1.
        for onlyRuleOneRefuses in ["", ".", ".."] {
            #expect(
                !AttachmentFilename.isSafeFileComponent(onlyRuleOneRefuses),
                """
                isSafeFileComponent accepted \(onlyRuleOneRefuses.debugDescription), which only rule 1 \
                can refuse — its containment probe has been moved to the filesystem root, where rule 1 \
                cannot refuse anything
                """
            )
        }
    }

    // MARK: - Rule 3: the 79 refused scalars
    //
    // The set is enumerated rather than taken from `CharacterSet.controlCharacters`,
    // which is NOT Unicode category Cc and not Cc ∪ Cf either: swept on this
    // toolchain it holds 24,970 scalars — Cc 65, Cf 170, 97 nonspacing marks, and
    // 24,638 scalars the standard library reports UNASSIGNED. Using it removed
    // ordinary, meaning-bearing scalars from ordinary names (`U+200D` ZWJ flattened
    // `👨‍👩‍👦report.pdf` into three emoji; the tag characters turned the Scotland
    // flag into a plain black flag AT THE SAME CHARACTER COUNT). Under REJECTION
    // the same over-wide set would be worse: every one of those names would now be
    // refused outright rather than mangled. Which is why the two-sided half of this
    // section — the joiners, the word joiner, the soft hyphen and the BOM are
    // ACCEPTED — is not decoration.

    /// Rule 3, attributed and exhaustive: all 79 scalars, each in a name that is
    /// otherwise ordinary, and the same name without it accepted.
    ///
    /// AXES VARIED: scalar identity (all 79), and position (medial for the controls,
    /// LEADING for the directional marks — see the CoreText test for why a
    /// `report`-prefixed fixture cannot see the mark spoof).
    @Test("Rule 3 — every refused scalar makes its name unusable, and only that scalar does")
    func refusedScalarsAreRejected() throws {
        let ranges: [ClosedRange<UInt32>] = [
            0x0000...0x001F, 0x007F...0x009F, 0x061C...0x061C,
            0x200E...0x200F, 0x2028...0x2029, 0x202A...0x202E, 0x2066...0x2069,
        ]
        var swept = 0
        for range in ranges {
            for value in range {
                let scalar = try #require(Unicode.Scalar(value))
                swept += 1
                let comment: Comment = "U+\(String(format: "%04X", value))"
                #expect(
                    !AttachmentFilename.isSafeFileComponent("report\(String(scalar))fdp.exe"),
                    "a refused scalar survived in a medial position: \(comment)"
                )
                #expect(
                    !AttachmentFilename.isSafeFileComponent("\(String(scalar))pdf.exe"),
                    "a refused scalar survived in a leading position: \(comment)"
                )
                #expect(
                    !AttachmentFilename.isSafeFileComponent("invoice.pdf\(String(scalar))"),
                    "a refused scalar survived in a trailing position: \(comment)"
                )
            }
        }
        #expect(swept == 79, "the refused set is no longer 79 scalars — it swept \(swept)")
        // Attribution: the same names without the scalar are ordinary.
        #expect(AttachmentFilename.isSafeFileComponent("reportfdp.exe"))
        #expect(AttachmentFilename.isSafeFileComponent("pdf.exe"))
        #expect(AttachmentFilename.isSafeFileComponent("invoice.pdf"))

        // Two-sided, so the sweep above is a statement about the ENUMERATED scalars
        // and not about "anything invisible": the joiners, the word joiner, the soft
        // hyphen, the BOM and the zero-width space are all ACCEPTED.
        for value in [0x200B, 0x200C, 0x200D, 0x2060, 0x00AD, 0xFEFF] {
            let scalar = try #require(Unicode.Scalar(UInt32(value)))
            let name = "re\(String(scalar))port.pdf"
            #expect(
                AttachmentFilename.isSafeFileComponent(name),
                "an invisible scalar that is NOT on the refused list made a name unusable: U+\(String(format: "%04X", value))"
            )
        }
        // And the grapheme property that motivated keeping them, stated directly.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"
        #expect(family.count == 1, "fixture check: the family emoji is one grapheme cluster")
        #expect(AttachmentFilename.isSafeFileComponent(family + "report.pdf"))
    }

    // MARK: - Rule 4: scalars the FILESYSTEM refuses

    /// Rule 4, attributed and TWO-SIDED IN SITU: each fixture's raw write is
    /// asserted to fail wherever this suite runs, so the refusal is measured here
    /// rather than inherited from a host sweep.
    ///
    /// Measured 2026-08-12 by sweeping every scalar `U+0000...U+10FFFF` as a real
    /// path component on APFS: the refused set is EXACTLY the `unassigned` ones,
    /// 814,730 of them, zero disagreements either way, with `open(2)` raising
    /// `EILSEQ` (errno 92).
    ///
    /// AXES VARIED: plane (BMP, astral, noncharacters, plane 14) and position
    /// (medial and trailing).
    @Test("Rule 4 — a scalar the filesystem refuses makes its name unusable")
    func unassignedScalarsAreRejected() throws {
        let refused: [UInt32] = [0x0378, 0x0380, 0x05EB, 0x2065, 0x2FE0, 0xFFF0, 0xFFFE, 0x1FFFE, 0xE0002, 0x10FFFF]
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for value in refused {
            let scalar = try #require(Unicode.Scalar(value))
            let comment: Comment = "U+\(String(format: "%04X", value))"
            #expect(
                scalar.properties.generalCategory == .unassigned,
                "fixture check: this scalar is no longer unassigned on this toolchain: \(comment)"
            )

            // Non-vacuity, measured HERE: the raw name is genuinely unwritable in
            // this environment, which is what makes refusing it the right answer.
            let raw = "invoice\(String(scalar)).pdf"
            let rawURL = root.appendingPathComponent(raw)
            #expect(
                (try? Data("x".utf8).write(to: rawURL)) == nil,
                "fixture check: the filesystem accepted this name, so it proves nothing: \(comment)"
            )
            try? FileManager.default.removeItem(at: rawURL)

            #expect(!AttachmentFilename.isSafeFileComponent(raw), comment)
            #expect(!AttachmentFilename.isSafeFileComponent("invoice.pdf\(String(scalar))"), comment)
        }
        // Attribution + two-sided: an ASSIGNED scalar from the same neighbourhood is
        // accepted, so this is a statement about what the filesystem refuses and not
        // about "unusual scalars".
        let assigned = try #require(Unicode.Scalar(UInt32(0x0870)))   // Arabic letter, measured writable
        #expect(assigned.properties.generalCategory != .unassigned, "fixture check")
        #expect(AttachmentFilename.isSafeFileComponent("invoice\(String(assigned)).pdf"))
        #expect(AttachmentFilename.isSafeFileComponent("invoice.pdf"))
    }

    // MARK: - Rule 5: combining runs the FILESYSTEM refuses

    /// Rule 5, with the limit RE-BISECTED wherever this suite runs rather than
    /// trusted from a note.
    ///
    /// A path component may not contain a canonical combining sequence longer than
    /// a measured limit, INDEPENDENTLY of the 255-unit length cap: `"invoice" + 32
    /// × U+0301 + "-2026.pdf"` is 48 NFD units against a 230-unit budget and still
    /// fails the write with `EILSEQ`. The length cap never engages first — `200 ×
    /// "a" + 32 marks` is 232 units and fails `EILSEQ`, while `240 × "a" + 31 marks`
    /// is 271 units and fails `ENAMETOOLONG` instead.
    ///
    /// The limit is on the CANONICAL COMBINING CLASS, not on general category
    /// `Mn`/`Mc`/`Me`: every `ccc != 0` scalar swept (`U+0301` 230, `U+0323` 220,
    /// `U+0345` 240, `U+05B0` 10, `U+0E48` 107, `U+3099` 8, `U+0483` 230, `U+0F71`
    /// 129, `U+064B` 27, `U+0655` 220) failed at the same length, while every
    /// `ccc == 0` scalar was unlimited to 60 repetitions INCLUDING the marks
    /// `U+0E31` (Mn), `U+0903` (Mc), `U+093E` (Mc), `U+20DD` (Me) and `U+FE0F` (Mn).
    ///
    /// AXES VARIED: which mark (7 scalars, 7 combining classes, 6 scripts), RUN
    /// LENGTH (bisected, then ±1 around the predicate's own boundary), position
    /// (leading with no starter in front, interior, trailing, after a PRECOMPOSED
    /// base whose own decomposition extends the run), how many runs the name has,
    /// and whether an extension is present.
    @Test("Rule 5 — a combining run the filesystem refuses makes its name unusable")
    func overlongCombiningRunsAreRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        func writes(_ name: String) -> Bool {
            let url = root.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data("x".utf8).write(to: url)) != nil
        }
        func acceptsRun(_ count: Int) -> Bool {
            writes("invoice" + String(repeating: "\u{0301}", count: count) + ".pdf")
        }
        var low = 0
        var high = 4096
        while low < high {
            let mid = (low + high + 1) / 2
            if acceptsRun(mid) { low = mid } else { high = mid - 1 }
        }
        let filesystemRunLimit = low
        #expect(filesystemRunLimit > 0, "the bisection found no usable run at all")
        #expect(
            !acceptsRun(filesystemRunLimit + 1),
            "one mark over the measured limit must be refused, or the limit is not a limit"
        )
        // The two caps are INDEPENDENT: this run is far under the length budget.
        #expect(
            componentUnits("invoice" + String(repeating: "\u{0301}", count: filesystemRunLimit + 1) + ".pdf") < 255,
            "fixture check: the refused name must be refused for its run, not for its length"
        )

        // The predicate's own boundary, bisected the same way, and the margin
        // between the two stated as a comparison rather than as a constant.
        func predicateAcceptsRun(_ count: Int) -> Bool {
            AttachmentFilename.isSafeFileComponent("invoice" + String(repeating: "\u{0301}", count: count) + ".pdf")
        }
        low = 0
        high = 4096
        while low < high {
            let mid = (low + high + 1) / 2
            if predicateAcceptsRun(mid) { low = mid } else { high = mid - 1 }
        }
        // Guarded for the same reason as the length budget below: `predicateRunBudget
        // - 1` feeds `String(repeating:count:)`, which TRAPS on a negative count and
        // takes the whole test process with it. Under the inverted predicate this
        // bisects to 0.
        let predicateRunBudget = low
        #expect(predicateRunBudget > 1, "the predicate accepts no combining run at all")
        guard predicateRunBudget > 1 else { return }
        #expect(
            predicateRunBudget < filesystemRunLimit,
            """
            the predicate accepts runs of \(predicateRunBudget) while the filesystem stops at \
            \(filesystemRunLimit) — the budget must reserve room for the starter a caller's \
            "\\(index)_" prefix puts in front of a LEADING run
            """
        )
        #expect(!predicateAcceptsRun(predicateRunBudget + 1))

        // The tight shape: a LEADING run, wrapped in the widest name any caller
        // derives. This is what the reserved starter is for — the `_` immediately
        // in front of the run occupies one slot of the sequence.
        let leading = String(repeating: "\u{0301}", count: predicateRunBudget) + "invoice.pdf"
        #expect(AttachmentFilename.isSafeFileComponent(leading), "fixture check")
        #expect(
            writes("\(Int.max)_\(leading).meta"),
            "an accepted leading run cannot carry its callers' wrapper: \(leading.debugDescription)"
        )

        let overlong = String(repeating: "\u{0301}", count: filesystemRunLimit + 2)
        let marks: [(String, UInt32)] = [
            ("acute, ccc 230", 0x0301),
            ("dot below, ccc 220", 0x0323),
            ("hebrew sheva, ccc 10", 0x05B0),
            ("arabic fathatan, ccc 27", 0x064B),
            ("tibetan vowel aa, ccc 129", 0x0F71),
            ("kana voiced sound, ccc 8", 0x3099),
            ("thai tone mai ek, ccc 107", 0x0E48),
        ]
        let shapes: [(String, (String) -> String)] = [
            ("interior run, with extension", { "invoice\($0)-2026.pdf" }),
            ("trailing run, after the extension", { "invoice.pdf\($0)" }),
            ("leading run, no starter in front of it", { "\($0)invoice.pdf" }),
            ("no extension at all", { "invoice\($0)" }),
            ("run extending a PRECOMPOSED base", { "caf\u{00E9}\($0).pdf" }),
            ("two separate runs", { "a\($0)b\($0).pdf" }),
        ]
        for (markLabel, value) in marks {
            let scalar = try #require(Unicode.Scalar(value))
            #expect(
                scalar.properties.canonicalCombiningClass != .notReordered,
                "fixture check: this scalar is no longer a non-starter: \(markLabel)"
            )
            let run = String(repeating: String(scalar), count: filesystemRunLimit + 2)
            for (shapeLabel, shape) in shapes {
                let raw = shape(run)
                let comment: Comment = "\(markLabel) / \(shapeLabel)"
                // Non-vacuity, measured HERE: unwritable, and not because of length.
                #expect(!writes(raw), "fixture check: the filesystem accepted this name: \(comment)")
                #expect(componentUnits(raw) < 255, "fixture check: this name is over the LENGTH cap: \(comment)")
                #expect(!AttachmentFilename.isSafeFileComponent(raw), comment)
            }
        }
        #expect(!AttachmentFilename.isSafeFileComponent("invoice\(overlong)-2026.pdf"))

        // NORMALISATION AXIS: a precomposed base contributes its own marks, so the
        // count must run on the NFD form. `U+00E1` + (budget) marks decomposes to
        // `a` + (budget + 1) and must be refused, while the same name one mark
        // shorter is accepted. A predicate that counted literal scalars accepts both.
        let precomposedOverBudget = "caf\u{00E1}" + String(repeating: "\u{0301}", count: predicateRunBudget)
        let precomposedInBudget = "caf\u{00E1}" + String(repeating: "\u{0301}", count: predicateRunBudget - 1)
        #expect(
            !AttachmentFilename.isSafeFileComponent(precomposedOverBudget),
            "a precomposed base must contribute to its run, or the count is not on the NFD form"
        )
        #expect(AttachmentFilename.isSafeFileComponent(precomposedInBudget))
    }

    /// The other side of rule 5: **it may not refuse a name a human wrote.**
    ///
    /// Real orthographic stacks are an order of magnitude under the limit — the
    /// widest sequence anywhere in the fixtures below is 4 scalars, and the widest
    /// run ANY single assigned scalar produces through its own canonical
    /// decomposition is 3 (`U+1F82`). A cap sized for the filesystem must leave
    /// every one of them accepted.
    ///
    /// AXES VARIED: script (21), NFC vs NFD spelling of the same word, and
    /// sequence-forming mechanisms that are NOT combining marks (ZWJ, regional
    /// indicators, tag sequences, variation selectors, skin tones) — which is the
    /// two-sided half of the class test: those are `ccc == 0` and must be unlimited.
    @Test("Rule 5 — legitimate scripts, emoji and diacritics are accepted")
    func legitimateCombiningSequencesAreAccepted() throws {
        let legitimate: [(String, String)] = [
            ("Devanagari conjunct stack", "क्ष्ण्य.pdf"),
            ("Thai with tone and vowel", "ใบแจ้งหนี้๒๕๖๙.pdf"),
            ("Arabic full tashkeel", "بِسْمِ ٱللَّٰهِ.pdf"),
            ("Hebrew points and cantillation", "בְּרֵאשִׁ֖ית.pdf"),
            ("Vietnamese, precomposed", "hóa-đơn-nghiệm.pdf"),
            ("Vietnamese, decomposed", "hóa-đơn-nghiệm.pdf".decomposedStringWithCanonicalMapping),
            ("Tibetan stack", "བཀྲ་ཤིས་བདེ་ལེགས.pdf"),
            ("Korean Hangul", "송장-2026.pdf"),
            ("Japanese with decomposed dakuten", "がぎぐげご.pdf".decomposedStringWithCanonicalMapping),
            ("Greek polytonic, decomposed", "τιμολόγιον ᾅδῃ.pdf".decomposedStringWithCanonicalMapping),
            ("Khmer", "វិក្កយបត្រ.pdf"),
            ("Myanmar", "ငွေတောင်းခံလွှာ.pdf"),
            ("Tamil", "விலைப்பட்டியல்.pdf"),
            ("Telugu", "ఇన్వాయిస్.pdf"),
            ("Malayalam", "ഇൻവോയ്സ്.pdf"),
            ("Sinhala", "ඉන්වොයිසිය.pdf"),
            ("ZWJ family emoji", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}report.pdf"),
            ("tag-sequence flag", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}flag.png"),
            ("skin tone plus VS16", "\u{1F44D}\u{1F3FD}\u{2764}\u{FE0F}.pdf"),
            ("IPA stacked diacritics", "t̪ʰa̋ːn̥.pdf"),
            ("Navajo", "łééchąąʼí.pdf"),
        ]
        for (label, name) in legitimate {
            let comment: Comment = "\(label): \(name.debugDescription)"
            #expect(
                longestCombiningSequence(name) <= 5,
                "fixture check: this name is not an ordinary orthographic stack any more: \(comment)"
            )
            #expect(
                AttachmentFilename.isSafeFileComponent(name),
                "a legitimate orthographic stack was refused: \(comment)"
            )
        }
        // The class half, stated directly: 60 `ccc == 0` marks in a row are fine.
        for value: UInt32 in [0x0E31, 0x0903, 0x093E, 0x20DD, 0xFE0F] {
            let scalar = try #require(Unicode.Scalar(value))
            #expect(
                scalar.properties.canonicalCombiningClass == .notReordered,
                "fixture check: this mark is no longer ccc 0: U+\(String(format: "%04X", value))"
            )
            let name = "a" + String(repeating: String(scalar), count: 60) + ".pdf"
            #expect(
                AttachmentFilename.isSafeFileComponent(name),
                """
                a run of 60 ccc-0 MARKS was refused — the rule is the combining CLASS, not the \
                general category: U+\(String(format: "%04X", value))
                """
            )
        }
    }

    // MARK: - Rule 6: the length budget

    /// Rule 6, with the cap RE-BISECTED wherever this suite runs.
    ///
    /// ⚠️ **THE UNIT IS MEASURED, AND IT IS NEITHER OF THE TWO OBVIOUS GUESSES.** A
    /// path component is accepted iff
    /// `decomposedStringWithCanonicalMapping.utf16.count <= 255`:
    ///   * NOT 255 UTF-8 bytes — 86 × `U+6F22` is 258 bytes and stores fine.
    ///   * NOT 255 `Character`s — 128 × `U+00E9` is 128 characters and 128 UTF-16
    ///     units, yet is REFUSED, because APFS decomposes it to 256 units.
    /// Both wrong units are wrong in the UNSAFE direction. Swept over all 194,528
    /// scalars in `U+0020…U+2FFFF`, `utf8.count` under-counts for 73 of them and
    /// `count` under-counts for 142,832.
    ///
    /// AXES VARIED: total length (bisected, then ±1 around the predicate's own
    /// boundary), and the unit each `Character` costs (ASCII 1, CJK 1, astral emoji
    /// 2, precomposed `é` 2 after decomposition, ZWJ family 11).
    @Test("Rule 6 — the length budget is the filesystem's, measured in NFD UTF-16 units")
    func overlongFilenamesAreRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func accepts(_ count: Int) -> Bool {
            let url = root.appendingPathComponent(String(repeating: "a", count: count))
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data("x".utf8).write(to: url)) != nil
        }
        var low = 1
        var high = 4096
        while low < high {
            let mid = (low + high + 1) / 2
            if accepts(mid) { low = mid } else { high = mid - 1 }
        }
        let filesystemCap = low
        #expect(filesystemCap > 1, "the bisection found no usable cap at all")
        #expect(!accepts(filesystemCap + 1), "one unit over the measured cap must be refused, or the cap is not a cap")

        // The predicate's own boundary.
        var pLow = 0
        var pHigh = 4096
        while pLow < pHigh {
            let mid = (pLow + pHigh + 1) / 2
            if AttachmentFilename.isSafeFileComponent(String(repeating: "a", count: mid)) { pLow = mid } else { pHigh = mid - 1 }
        }
        // ⚠️ GUARDED, and the guard is load-bearing rather than defensive noise.
        // Everything below derives a fixture LENGTH from `budget`, and
        // `String(repeating:count:)` TRAPS on a negative count — a `fatalError`
        // Swift Testing cannot catch, which takes the whole process down and hides
        // every other result in the run. Measured 2026-08-12: with the predicate
        // inverted for the red-first proof, `budget` bisects to 0, `budget - 4`
        // traps, and the suite could not report its own red evidence — xcodebuild
        // simply relaunched the crashed host over and over. A test that cannot fail
        // honestly under inversion is not red-first evidence.
        let budget = pLow
        #expect(budget > 8, "the predicate accepts no usable name at all — every fixture below is degenerate")
        guard budget > 8 else { return }
        #expect(!AttachmentFilename.isSafeFileComponent(String(repeating: "a", count: budget + 1)))

        // THE POINT OF THE BUDGET: what has to fit is the DERIVED name, not the
        // accepted one. `saveAttachments` writes `"\(index)_\(name)"` and a
        // `"\(that).meta"` sidecar, and the index comes from `enumerated()`, so
        // nothing bounds it more tightly than `Int` does.
        let widest = "\(Int.max)_\(String(repeating: "a", count: budget)).meta"
        #expect(
            componentUnits(widest) <= filesystemCap,
            """
            an accepted name leaves no room for the wrapper its callers add: the widest derived \
            name is \(componentUnits(widest)) units and the filesystem caps a component at \(filesystemCap)
            """
        )
        #expect(accepts(componentUnits(widest)), "the widest derived name is not writable on this filesystem")
        // And the reserve is real rather than incidental: a name one unit over the
        // budget would still have fitted the raw component limit.
        #expect(budget < filesystemCap, "the budget reserves nothing for the wrapper")

        // THE UNIT. Each of these is an accepted name at exactly the budget and a
        // refused one at one `Character` more, so a byte-based or `Character`-based
        // implementation is red in one direction or the other.
        let units: [(String, String)] = [
            ("ASCII", "a"),
            ("CJK U+6F22", "\u{6F22}"),
            ("emoji U+1F600", "\u{1F600}"),
            ("precomposed U+00E9", "\u{00E9}"),
            ("decomposed e+U+0301", "e\u{0301}"),
            ("ZWJ family", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"),
        ]
        for (label, unit) in units {
            let cost = componentUnits(unit)
            let fitting = String(repeating: unit, count: budget / cost)
            let overflowing = String(repeating: unit, count: budget / cost + 1)
            let comment: Comment = "\(label), \(cost) NFD units per Character"
            #expect(componentUnits(fitting) <= budget, "fixture check: \(comment)")
            #expect(componentUnits(overflowing) > budget, "fixture check: \(comment)")
            #expect(AttachmentFilename.isSafeFileComponent(fitting), "a name inside the budget was refused: \(comment)")
            #expect(!AttachmentFilename.isSafeFileComponent(overflowing), "a name over the budget was accepted: \(comment)")
            // And the accepted one really does survive a real write with its
            // callers' widest wrapper.
            #expect(accepts(componentUnits("\(Int.max)_\(fitting).meta")), comment)
        }

        // A long-but-legal name goes all the way through the store, so "accepted"
        // is not merely a boolean.
        try expectSavesAndReloads(
            filename: String(repeating: "a", count: budget - 4) + ".pdf",
            "a name exactly at the budget, extension included"
        )
    }

    // MARK: - What a filename RENDERS as, measured through CoreText
    //
    // The tests below assert the user-facing property directly — *what the user
    // reads cannot present itself as a different type than it is* — instead of
    // asserting membership of a scalar in a set. The instrument is CoreText itself,
    // i.e. the real Unicode Bidi Algorithm and the real line breaker, rather than a
    // model of either.

    /// The order a human SEES, read back out of CoreText's own layout: every
    /// glyph's x-position, sorted left to right, mapped back to the UTF-16 offset
    /// it came from. Equal to the logical string exactly when nothing was
    /// reordered.
    ///
    private func visibleOrder(_ text: String) -> String {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return "" }
        var placed: [(CGFloat, Int)] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), &indices)
            for i in 0..<count { placed.append((positions[i].x, Int(indices[i]))) }
        }
        placed.sort { $0.0 < $1.0 }
        let utf16 = Array(text.utf16)
        var out = String.UnicodeScalarView()
        for (_, index) in placed where index >= 0 && index < utf16.count {
            if let scalar = Unicode.Scalar(utf16[index]) { out.append(scalar) }
        }
        return String(out)
    }

    /// How many UTF-16 units the typesetter puts on the FIRST line when the line is
    /// 100,000pt wide. At that width nothing breaks for want of room, so a break
    /// here is a MANDATORY one — which is the thing that can hide the rest of a name
    /// from a `.lineLimit(1)` label.
    private func firstLineUnits(_ text: String) -> Int {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        return CTTypesetterSuggestLineBreak(typesetter, 0, 100_000)
    }

    /// The invariant: **no INVISIBLE scalar can make what the user reads lay out in
    /// an order other than its own, so no invisible scalar can make it read as a
    /// different type than the bytes are.**
    ///
    /// ⚠️ **NOT "a filename cannot render as a different type", which no membership
    /// rule can buy.** The vector survives in ORDINARY VISIBLE LETTERS: measured on
    /// this host through the same `visibleOrder` harness, all 63 visible strong-RTL
    /// letters swept (Hebrew `U+05D0...U+05EA`, Arabic `U+0621...U+063A`,
    /// `U+0641...U+064A`) make `"<X>pdf<X>.exe"` lay out with a rendered extension
    /// different from the stored one. They are letters; refusing them would refuse
    /// every Hebrew and Arabic filename. And the reorder is not a reliable signal
    /// either — the legitimate name `דוח.pdf` lays out as `pdf.חוד` on the same
    /// measurement, which is CORRECT rendering and is what the two-sided case at
    /// the end asserts. The residual risk is bounded, not eliminated.
    ///
    /// ⚠️ EVERY FIXTURE HERE PUTS THE MARK FIRST, and that is the whole point. The
    /// measurement that decided to KEEP `U+200E`/`U+200F`/`U+061C` only ever
    /// inserted them into `report…`, whose leading strong-LTR run fixes the
    /// paragraph direction and makes the swap impossible — so an anchored fixture is
    /// GREEN on the unfixed code and proves nothing. The anchored shape is carried
    /// below as the second half of the same measurement.
    @Test("A leading bidi mark or override cannot make what the user reads claim another type")
    func leadingDirectionalMarksCannotSpoofTheExtension() throws {
        // (name, does the RAW name reorder its runs on this host?)
        let spoofing: [(String, Bool)] = [
            ("\u{200F}pdf\u{200F}.exe", true),      // RLM  — measured VISIBLE exe.pdf
            ("\u{061C}pdf\u{061C}.exe", true),      // ALM  — measured VISIBLE exe.pdf
            ("\u{202E}pdf\u{202E}.exe", true),      // RLO
            ("report\u{202E}fdp.exe", true),        // the known anchored RLO spoof
            // ⚠️ LRM does NOT reorder this fixture (measured: VISIBLE pdf.exe). It
            // is refused because the owner's decision covers the set and because
            // "this mark reorders and that one does not, in this paragraph context"
            // is not a distinction a filename can carry — so it is carried with
            // `reorders: false` rather than being claimed as a spoof it is not.
            ("\u{200E}pdf\u{200E}.exe", false),
            ("report\u{200F}fdp.exe", false),       // anchored RLM — the shape that hid this
        ]
        for (raw, reorders) in spoofing {
            let comment: Comment = "\(raw.debugDescription)"
            // NON-VACUITY, measured rather than assumed: the raw name really does
            // lay out in a different order on this host. If CoreText ever stops
            // reordering it, this fails and the fixture is retired honestly instead
            // of passing for the wrong reason.
            if reorders {
                #expect(
                    visibleOrder(raw) != raw,
                    "fixture check: the raw name no longer reorders, so it proves nothing: \(comment)"
                )
            }
            // The name is refused, so what the user reads is the label…
            #expect(!AttachmentFilename.isSafeFileComponent(raw), comment)
            let shown = AttachmentFilename.displayLabel(raw)
            #expect(shown == AttachmentFilename.unsupportedLabel, comment)
            // …and the label itself lays out in its own order and claims no type.
            #expect(visibleOrder(shown) == shown, "the label renders out of order: \(comment)")
            #expect((shown as NSString).pathExtension.isEmpty, "the label claims a file type: \(comment)")
        }

        // Two-sided: a genuine RTL filename carries no explicit mark, is ACCEPTED
        // and shown as itself, and still orders correctly on its own strong letters.
        let hebrew = "\u{05D3}\u{05D5}\u{05D7}.pdf"
        #expect(AttachmentFilename.isSafeFileComponent(hebrew))
        #expect(AttachmentFilename.displayLabel(hebrew) == hebrew)
        #expect(
            visibleOrder(hebrew) != hebrew,
            "fixture check: a Hebrew name must lay out right-to-left, or it is not testing RTL"
        )
    }

    /// The invariant: **what the user reads occupies ONE line, so a `.lineLimit(1)`
    /// label cannot be showing only part of it.**
    ///
    /// `U+2028`/`U+2029` are the only mandatory-break scalars outside Cc, so before
    /// they joined the refused set `"invoice.pdf\u{2028}.exe"` put `.exe` on a
    /// second line nobody sees.
    @Test("What the user reads cannot hide a second line")
    func shownFilenamesOccupyASingleLine() throws {
        for value in [0x2028, 0x2029, 0x000A, 0x000D, 0x0085, 0x000B, 0x000C] {
            let scalar = try #require(Unicode.Scalar(UInt32(value)))
            let raw = "invoice.pdf\(String(scalar)).exe"
            let comment: Comment = "U+\(String(format: "%04X", value))"

            // Non-vacuity, measured: the raw name really does break early.
            #expect(
                firstLineUnits(raw) < raw.utf16.count,
                "fixture check: this scalar no longer forces a line break: \(comment)"
            )

            #expect(!AttachmentFilename.isSafeFileComponent(raw), comment)
            let shown = AttachmentFilename.displayLabel(raw)
            #expect(
                firstLineUnits(shown) == shown.utf16.count,
                """
                what the user reads still breaks before its end, so a one-line label hides the rest: \
                \(shown.debugDescription) breaks after \(firstLineUnits(shown)) of \
                \(shown.utf16.count) units — \(comment)
                """
            )
        }
        // Two-sided: an ordinary name is shown whole, on one line.
        let ordinary = "invoice.pdf"
        #expect(AttachmentFilename.displayLabel(ordinary) == ordinary)
        #expect(firstLineUnits(ordinary) == ordinary.utf16.count)
    }

    // MARK: - The predicate has to reach the surfaces the user reads and acts on

    /// The invariant: **on every attachment-list, compose-chip and `.eml`-sheet
    /// surface, the name the user reads went through `AttachmentFilename`.**
    ///
    /// ⚠️ **NOT "every display site" — this scan walks three view files.** Two sites
    /// outside them render a RAW attachment filename, neither a regression from this
    /// round: `EmlMarker.embeddedHeadersHtml`, which is CSS-hidden in both view
    /// modes (`EmailHTMLWrapper` emits `.tm-eml-section { display: none !important; }`
    /// in main view and `body.tm-preview-mode .tm-eml-headers { display: none !important; }`
    /// in preview mode — read, not inferred), and `EmlMarker.embeddedHeadersPlainText`,
    /// which is **not** hidden: it emits `--- <filename> ---` into the plain-text
    /// body, its own call site in `IMAPFetchMapping.renderBodyWithEmbeddedHeaders`
    /// states there is "no CSS to apply … users read plain text inline", and
    /// `BodyRenderer` renders that text through `EmailFilter.plainTextToHTML` when
    /// the message has no HTML part. Escaped exactly once, so it is a
    /// rendering-order exposure, not an injection one.
    ///
    /// This is pinned at SOURCE level because the defect is a call site, not a
    /// value: a behavioural assertion on the predicate stays green when someone
    /// writes `Text(attachment.filename)` again. The scan is deliberately over the
    /// CLASS (every filename-rendering call in the attachment views) rather than the
    /// one row a review found — the same site existed four times.
    @Test("Every place an attachment filename reaches the screen renders the checked label")
    func attachmentFilenamesAreRenderedThroughThePredicate() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "TabMail/Views/Message/AttachmentListView.swift",
            "TabMail/Views/Message/EmlAttachmentPreview.swift",
            "TabMail/Views/Compose/ComposeView.swift",
        ]
        // A line that both RENDERS and mentions a filename.
        let renderers = ["Text(", ".navigationTitle("]
        var sites = 0
        for file in files {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(file), encoding: .utf8
            )
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                guard renderers.contains(where: { line.contains($0) }) else { continue }
                guard line.lowercased().contains("filename") else { continue }
                sites += 1
                #expect(
                    line.contains("displayLabel("),
                    """
                    a raw attachment filename reaches the screen at \(file):\(offset + 1) — \
                    \(trimmed). The sender authored that string; render \
                    AttachmentFilename.displayLabel(...) of it instead
                    """
                )
            }
        }
        // Non-vacuity: the scan must actually have found the sites. Four are known
        // (the attachment row, the .eml nested strip, the .eml sheet title and the
        // compose chip); a lower bound rather than an equality so adding a site does
        // not fail the wrong test.
        #expect(sites >= 4, "the source scan matched \(sites) render sites, so it proves nothing")
    }

    /// The invariant: **the label and the ACTION agree.** A row the user is told is
    /// unsupported must also refuse to open, and a row shown under its own name must
    /// open a file with exactly that name.
    ///
    /// This is the property a source scan cannot state: the two decisions are made
    /// in different files, and before this round they were made by two different
    /// copies of the same 60-line reduction.
    @Test("The row label and the download it triggers make the same decision")
    func theLabelAndTheStagedFileAgree() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for raw in ["report\u{202E}fdp.exe", "\u{200F}pdf\u{200F}.exe", "invoice.pdf\u{2028}.exe"] {
            #expect(AttachmentFilename.displayLabel(raw) == AttachmentFilename.unsupportedLabel, "\(raw.debugDescription)")
            #expect(throws: AttachmentFilenameError.self, "\(raw.debugDescription)") {
                try AttachmentPreviewStager.stage(
                    data: Data("BYTES".utf8),
                    messageId: "message-label-agreement",
                    originalFilename: raw,
                    rootDirectory: root
                )
            }
        }
        for name in ["invoice.pdf", "\u{05D3}\u{05D5}\u{05D7}.pdf", "Invoice (final) - 2026.pdf"] {
            let staged = try AttachmentPreviewStager.stage(
                data: Data("BYTES".utf8),
                messageId: "message-label-agreement",
                originalFilename: name,
                rootDirectory: root
            )
            #expect(AttachmentFilename.displayLabel(name) == staged.lastPathComponent,
                    "the label and the staged file disagree: \(name.debugDescription)")
        }
    }

    /// The invariant: **a refusal is REPORTABLE.** The user is told something, and
    /// what they are told names no reason and quotes no name.
    ///
    /// Both halves matter. The message must not say "too long", because length is
    /// one of six rules and a 48-unit name with a long combining run is refused
    /// nowhere near the budget (owner decision, 2026-08-12: one message for all six
    /// rules). And it must not quote the sender's name, because that string is
    /// exactly the one that was refused for being able to misrepresent itself.
    @Test("The refusal error carries a reason-agnostic message that does not quote the name")
    func theRefusalMessageIsReasonAgnostic() throws {
        let hostile = "report\u{202E}fdp.exe"
        let error = AttachmentFilenameError.unsupported(name: hostile)
        let message = error.localizedDescription

        #expect(message == AttachmentFilename.unsupportedMessage)
        #expect(!message.isEmpty)
        #expect(!message.contains(hostile), "the refusal message quotes the sender's name back at the user")
        #expect(!message.contains("report"), "the refusal message quotes part of the sender's name")
        for reasonWord in ["long", "length", "combining", "unassigned", "separator", "slash", "bidi", "control"] {
            #expect(
                !message.lowercased().contains(reasonWord),
                "the refusal message names a reason (\(reasonWord)) — it must be true for all six rules"
            )
        }
        // And the message a store throws is the message the compose view shows: the
        // compose paths interpolate `error.localizedDescription`.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: hostile, mimeType: "application/pdf", data: Data("X".utf8))],
                dirName: "slot", root: root
            )
            Issue.record("the draft store accepted a refused name")
        } catch {
            #expect(error.localizedDescription == AttachmentFilename.unsupportedMessage)
        }
    }

    // MARK: - The two loader fixes are still load-bearing (§4)
    //
    // Refusing hostile names at SAVE time does NOT make the scalar-wise loaders
    // unnecessary. Both names below are SAFE by all six rules — short, assigned,
    // unrefused, run length 1 — and each still defeats a `Character`-wise loader,
    // because the character that merges is one the STORE adds: the `"\(index)_"`
    // prefix in front of a leading combining mark, and the `.` of the `.meta`
    // sidecar behind a trailing `Prepend` scalar. The name that breaks the loader is
    // a name the predicate has no reason to refuse.
    //
    // AXIS THIS COVERS AND NOTHING ELSE DOES: grapheme-cluster interaction with the
    // characters the STORES add, as opposed to with the sender's own.

    /// The 27 ASSIGNED scalars whose grapheme-break property is `Prepend`: each
    /// merges with a FOLLOWING `.` into a single `Character`, so a `Character`-wise
    /// `hasSuffix(".meta")` on `<name><X>.meta` is FALSE. Measured by sweeping every
    /// scalar `U+0000...U+10FFFF` on this toolchain; the list is pinned here rather
    /// than re-swept, and every entry is re-checked in situ where it is used, so a
    /// toolchain that changed the property fails the fixture check instead of
    /// silently emptying the test.
    private static let prependScalars: [UInt32] = [
        0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F,
        0x0890, 0x0891, 0x08E2, 0x0D4E, 0x110BD, 0x110CD, 0x111C2, 0x111C3,
        0x113D1, 0x1193F, 0x11941, 0x11A84, 0x11A85, 0x11A86, 0x11A87, 0x11A88,
        0x11A89, 0x11D46, 0x11F02,
    ]

    /// The invariant: **each store returns exactly the attachments that were saved
    /// to it, and never returns a metadata sidecar's bytes as one of them.**
    ///
    /// `isSidecar` tested `name.hasSuffix(".meta")` and recovered the base with
    /// `dropLast(".meta".count)`, both of which operate on `Character`s. For a data
    /// file `0_invoice\u{0605}` the sidecar `0_invoice\u{0605}.meta` has last five
    /// `Character`s `"\u{0605}."`, `m`, `e`, `t`, `a`, so the suffix test is FALSE,
    /// the sidecar is classified as a DATA file, and `loadAttachments` returns TWO
    /// attachments instead of one. In `OutboxMessage.loadAttachments` — the SEND
    /// path — the mail then goes out with an extra attachment whose bytes are
    /// internal sidecar metadata, which is a direct violation of Outbox Reliability
    /// Rule 5 ("no silent data corruption").
    ///
    /// Pinned on the END STATE (how many attachments come back, and whose bytes they
    /// are) rather than on the suffix test, so an implementation that fixes the
    /// classifier and forgets the guard cannot pass it.
    @Test("A filename ending in a Prepend scalar does not turn its sidecar into an attachment")
    func trailingPrependScalarKeepsTheSidecarOutOfTheAttachmentSet() throws {
        let payload = Data("SENDER-AUTHORED-BYTES".utf8)
        for value in Self.prependScalars {
            let scalar = try #require(Unicode.Scalar(value))
            let comment: Comment = "U+\(String(format: "%04X", value))"
            let filename = "invoice\(String(scalar))"

            // Non-vacuity, measured HERE: this scalar really does defeat the
            // `Character`-wise suffix test on this toolchain.
            #expect(
                !"0_\(filename).meta".hasSuffix(".meta"),
                "fixture check: this scalar no longer merges with the following '.': \(comment)"
            )
            // And it really does reach the loader: the predicate ACCEPTS it, which
            // is the point of §4 — the save-time refusal does not cover this class.
            #expect(
                AttachmentFilename.isSafeFileComponent(filename),
                "fixture check: the predicate now refuses this name: \(comment)"
            )

            // DRAFT store.
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: filename, mimeType: "application/pdf", data: payload)],
                dirName: "slot", root: root
            )
            let loaded = try DraftAttachmentStorage.loadAttachments(dirName: "slot", root: root)
            #expect(
                loaded.count == 1,
                "the draft loader returned \(loaded.count) attachments for one saved file: \(comment)"
            )
            #expect(loaded.map(\.data) == [payload], "a sidecar's bytes were returned as an attachment: \(comment)")
            #expect(loaded.first?.filename == filename, comment)
            #expect(loaded.first?.mimeType == "application/pdf", comment)

            // OUTBOX store — the send path, where the extra attachment leaves the
            // device. `attachmentsBaseDir` has no root seam, so isolation comes from
            // the message's own unique id.
            let draft = DraftMessage(
                to: ["recipient@example.com"],
                subject: "sidecar classification",
                body: "body",
                attachments: [DraftAttachment(filename: filename, mimeType: "application/pdf", data: payload)]
            )
            let outbox = OutboxMessage(accountId: "acct-sidecar-prepend", draft: draft)
            defer { outbox.deleteAttachments() }
            try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
            let sent = try outbox.loadAttachments()
            #expect(
                sent.count == 1,
                "the outbox loader would send \(sent.count) attachments for one saved file: \(comment)"
            )
            #expect(sent.map(\.data) == [payload], "a sidecar's bytes would have been SENT: \(comment)")
            #expect(sent.first?.filename == filename, comment)
            #expect(sent.first?.mimeType == "application/pdf", comment)
        }
    }

    /// The invariant: **an orphaned sidecar FAILS THE LOAD CLOSED** rather than
    /// being loaded as an attachment carrying metadata bytes.
    ///
    /// The `ambiguousMetaFilename` guard tests `hasSuffix(".meta")` too, so it is
    /// defeated by exactly the same scalars as the classifier above and in exactly
    /// the same function. With the data file gone, the sidecar was classified as a
    /// DATA file AND skipped by the guard, so both halves failed together.
    @Test("An orphaned sidecar whose name ends in a Prepend scalar still fails the load closed")
    func orphanedSidecarWithPrependScalarStillFailsClosed() throws {
        let payload = Data("SENDER-AUTHORED-BYTES".utf8)
        for value in Self.prependScalars {
            let scalar = try #require(Unicode.Scalar(value))
            let comment: Comment = "U+\(String(format: "%04X", value))"
            let filename = "invoice\(String(scalar))"

            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: filename, mimeType: "application/pdf", data: payload)],
                dirName: "slot", root: root
            )
            // Lose the data file, leaving its sidecar behind.
            let slot = DraftAttachmentStorage.dirURL(for: "slot", root: root)
            try FileManager.default.removeItem(at: slot.appendingPathComponent("0_\(filename)"))
            #expect(
                FileManager.default.fileExists(atPath: slot.appendingPathComponent("0_\(filename).meta").path),
                "fixture check: the sidecar must still be there: \(comment)"
            )

            #expect(throws: DraftAttachmentLoadError.self, "an orphaned sidecar loaded as an attachment: \(comment)") {
                try DraftAttachmentStorage.loadAttachments(dirName: "slot", root: root)
            }
        }
    }

    /// The invariant: **the name that comes back out of a store is the name that
    /// went in** — the `"<index>_"` prefix the store adds is stripped, and nothing
    /// of the sender's name is stripped with it.
    ///
    /// Both loaders recovered it with
    /// `fullName.contains("_") ? String(fullName.drop(while: { $0 != "_" }).dropFirst()) : fullName`,
    /// which is `Character`-wise. A filename BEGINNING with a combining mark makes
    /// the stored component `0_\u{0301}foo.pdf`, in which `_` and the mark are ONE
    /// `Character`, so two things go wrong for the price of one predicate:
    ///
    /// * `contains("_")` is FALSE, so the whole component including the store's own
    ///   `0_` prefix is handed back as the user's filename — on screen, and on the
    ///   wire as the MIME `filename` parameter of a sent message.
    /// * When the sender's name contains a LATER `_`, `contains("_")` is true and
    ///   `drop(while:)` runs past the merged cluster all the way to the SECOND `_`:
    ///   `\u{0301}foo_bar.pdf` is stored as `0_\u{0301}foo_bar.pdf` and recovered as
    ///   `bar.pdf`. `foo` is silently cut, and the user is shown, and sends, a
    ///   truncated filename.
    ///
    /// Measured by sweeping every scalar `U+0000...U+10FFFF`: **2,619 assigned
    /// scalars** trigger both shapes, and the predicate ACCEPTS every one of them —
    /// they are ordinary combining marks from every script that has them.
    @Test("A filename beginning with a combining mark is recovered whole, without the index prefix")
    func leadingCombiningMarkRecoversTheSendersWholeFilename() throws {
        // AXES VARIED: which leading mark (5 scripts, 5 combining classes); whether
        // the sender's own name contains a later "_" (the cut shape) or not (the
        // retained-prefix shape); and both stores.
        let leadingMarks: [UInt32] = [0x0301, 0x0323, 0x05B0, 0x064B, 0x0E48]
        let tails = ["foo.pdf", "foo_bar.pdf", "_leading-underscore.pdf", "a_b_c.pdf"]
        let payload = Data("SENDER-AUTHORED-BYTES".utf8)

        for value in leadingMarks {
            let scalar = try #require(Unicode.Scalar(value))
            for tail in tails {
                let filename = "\(String(scalar))\(tail)"
                let comment: Comment = "U+\(String(format: "%04X", value)) + \(tail)"

                // Non-vacuity, measured HERE: the mark really does merge with the
                // store's own "_" into one `Character` on this toolchain, so the
                // second `Character` of the stored component is not `"_"`.
                #expect(
                    Array("0_\(filename)")[1] != "_",
                    "fixture check: this scalar no longer merges with the preceding '_': \(comment)"
                )
                // And it really does reach the loader: the predicate ACCEPTS it.
                #expect(
                    AttachmentFilename.isSafeFileComponent(filename),
                    "fixture check: the predicate now refuses this name: \(comment)"
                )

                // DRAFT store.
                let root = try makeTempRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                try DraftAttachmentStorage.saveAttachments(
                    [DraftAttachment(filename: filename, mimeType: "application/pdf", data: payload)],
                    dirName: "slot", root: root
                )
                let loaded = try DraftAttachmentStorage.loadAttachments(dirName: "slot", root: root)
                #expect(loaded.count == 1, comment)
                #expect(
                    loaded.first?.filename == filename,
                    """
                    the draft loader did not recover the sender's filename: got \
                    \(loaded.first?.filename.debugDescription ?? "nil"), expected \
                    \(filename.debugDescription) — \(comment)
                    """
                )

                // OUTBOX store — this name goes on the wire.
                let draft = DraftMessage(
                    to: ["recipient@example.com"],
                    subject: "index prefix recovery",
                    body: "body",
                    attachments: [DraftAttachment(filename: filename, mimeType: "application/pdf", data: payload)]
                )
                let outbox = OutboxMessage(accountId: "acct-index-prefix", draft: draft)
                defer { outbox.deleteAttachments() }
                try OutboxMessage.saveAttachments(draft.attachments, dirName: outbox.id)
                let sent = try outbox.loadAttachments()
                #expect(sent.count == 1, comment)
                #expect(
                    sent.first?.filename == filename,
                    """
                    the outbox loader would send the wrong filename: \
                    \(sent.first?.filename.debugDescription ?? "nil") instead of \
                    \(filename.debugDescription) — \(comment)
                    """
                )
            }
        }

        // Two-sided: an ORDINARY name is still stripped of its prefix, so this is a
        // statement about where the first `_` scalar is and not about giving up on
        // stripping.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try DraftAttachmentStorage.saveAttachments(
            [
                DraftAttachment(filename: "report.pdf", mimeType: "application/pdf", data: payload),
                DraftAttachment(filename: "year_end_summary.pdf", mimeType: "application/pdf", data: payload),
            ],
            dirName: "plain", root: root
        )
        let plain = try DraftAttachmentStorage.loadAttachments(dirName: "plain", root: root)
        #expect(plain.map(\.filename) == ["report.pdf", "year_end_summary.pdf"])
    }

    // MARK: - Refusing one attachment refuses the whole set, and writes nothing

    /// The invariant: **a set containing one refused name stores NOTHING**, so the
    /// caller's cleanup never has to reason about a half-written slot and the user
    /// never ends up with a draft that holds some of their attachments.
    ///
    /// Checked before `createDirectory` rather than per attachment inside the write
    /// loop: refusing mid-loop would leave the earlier attachments on disk under a
    /// directory the caller is about to abandon.
    @Test("One refused attachment refuses the whole save, leaving no partial slot")
    func aRefusedAttachmentRefusesTheWholeSet() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = [
            DraftAttachment(filename: "first.pdf", mimeType: "application/pdf", data: Data("ONE".utf8)),
            DraftAttachment(filename: "photos/img.png", mimeType: "image/png", data: Data("TWO".utf8)),
            DraftAttachment(filename: "third.pdf", mimeType: "application/pdf", data: Data("THREE".utf8)),
        ]
        #expect(throws: AttachmentFilenameError.self) {
            try DraftAttachmentStorage.saveAttachments(attachments, dirName: "slot", root: root)
        }
        #expect(regularFiles(under: root).isEmpty, "a refused set wrote the attachments that came before it")
        #expect(
            !FileManager.default.fileExists(
                atPath: DraftAttachmentStorage.dirURL(for: "slot", root: root).path
            ),
            "a refused set created its slot directory"
        )
        // Two-sided: the same set with the refused name removed saves completely.
        try DraftAttachmentStorage.saveAttachments(
            [attachments[0], attachments[2]], dirName: "slot", root: root
        )
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: "slot", root: root)
        #expect(loaded.map(\.filename) == ["first.pdf", "third.pdf"])
    }
}
