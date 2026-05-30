/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Renders markdown text with styled email pill chips in chat bubbles.
///
/// For current session messages: resolves `[Email](N)` patterns via ChatIdTranslator,
/// renders pills as styled tappable chips with detail popover on tap.
///
/// For history messages (isHistory=true): uses pre-rendered content. Pills show subjects
/// but are non-interactive (greyed, disabled) — matching TB's `.history-static` behavior.
struct MarkdownChatText: View {
    let content: String
    let isHistory: Bool
    let animate: Bool
    /// Called after each line is revealed during animation. Parent uses this to scroll.
    var onLineRevealed: (() -> Void)?

    @State private var lines: [ContentLine] = []
    @State private var pills: [PillRef] = []
    @State private var pillDetail: EmailPillDetail?
    @State private var contactDetail: ContactPillDetail?
    @State private var eventDetail: EventPillDetail?
    @State private var templateDetail: TemplatePillDetail?
    @State private var dismissedHashes: Set<String> = []
    @State private var revealedLineCount: Int = 0

    /// Tracks content that has already been animated. Prevents re-animation when
    /// LazyVStack recycles views (which resets @State, causing reveal to restart).
    @MainActor private static var animatedContent: Set<String> = []

    /// Cache of parsed lines + pill table, keyed by content string.
    /// Eliminates the async actor hop on LazyVStack recycle — views restore instantly.
    @MainActor private static var parsedLinesCache: [String: (lines: [ContentLine], pills: [PillRef])] = [:]

    init(content: String, isHistory: Bool = false, animate: Bool = false, onLineRevealed: (() -> Void)? = nil) {
        self.content = content
        self.isHistory = isHistory
        self.animate = animate
        self.onLineRevealed = onLineRevealed
    }

    private var shouldAnimate: Bool {
        animate && !Self.animatedContent.contains(content)
    }

    private var visibleLines: [ContentLine] {
        if shouldAnimate {
            return Array(lines.prefix(revealedLineCount))
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleLines) { line in
                Group {
                    if line.segments.isEmpty {
                        Spacer().frame(height: 4)
                    } else {
                        // Each line has exactly one segment (block element or plain text);
                        // pills are encoded as sentinels inside the text and spliced into
                        // chips by the inline renderer at draw time.
                        ForEach(line.segments) { segment in
                            segmentView(segment)
                        }
                    }
                }
            }
        }
        .task(id: content) {
            // Fast path: cached parsed lines (LazyVStack recycle) — instant restore.
            if let cached = Self.parsedLinesCache[content] {
                lines = cached.lines
                pills = cached.pills
                revealedLineCount = cached.lines.count
                return
            }

            let parsed = await resolveAndParse()
            lines = parsed.lines
            pills = parsed.pills
            Self.parsedLinesCache[content] = parsed

            if shouldAnimate {
                await revealLinesProgressively()
                Self.animatedContent.insert(content)
            } else {
                revealedLineCount = lines.count
            }
        }
    }

    /// Reveal lines one at a time. No withAnimation — just set the count.
    /// Calls onLineRevealed every 5 lines + on last line to avoid rapid-fire scrollTo
    /// that causes layout feedback loops in LazyVStack.
    private func revealLinesProgressively() async {
        try? await Task.sleep(for: .milliseconds(100))
        for i in 0..<lines.count {
            guard !Task.isCancelled else { return }
            revealedLineCount = i + 1
            if (i + 1) % 5 == 0 || i == lines.count - 1 {
                onLineRevealed?()
            }
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    // MARK: - Segment Rendering

    @ViewBuilder
    private func segmentView(_ segment: ContentSegment) -> some View {
        switch segment.kind {
        case .text(let text):
            inlineLine(text)

        case .reminder(let hash, let reminderContent):
            reminderCardView(hash: hash, content: reminderContent)

        case .table(let rows):
            tableView(rows: rows)

        case .codeBlock(_, let code):
            codeBlockView(code: code)

        case .header(let level, let text):
            headerView(level: level, text: text)

        case .blockquote(let text):
            blockquoteView(text: text)

        case .listItem(let indent, let ordered, let marker, let text):
            listItemView(indent: indent, ordered: ordered, marker: marker, text: text)
        }
    }

    /// Inline-level renderer used by every block context (plain line, table cell,
    /// header, blockquote, list item, reminder). Runs `splitAtSentinels` to expand
    /// pill sentinels into chips, falls back to a plain `Text` when there are no
    /// pills so we don't pay for FlowLayout in the common case.
    /// `style` is applied to every text run; pill chips have their own styling.
    @ViewBuilder
    private func inlineRuns(
        _ text: String,
        spacing: (h: CGFloat, v: CGFloat) = (2, 4),
        @ViewBuilder style: @escaping (Text) -> some View
    ) -> some View {
        let runs = Self.splitAtSentinels(text, pills: pills)
        if runs.count == 1, case .text(let attr) = runs[0] {
            style(Text(attr))
                .environment(\.openURL, OpenURLAction { url in
                    handleExternalURL(url)
                    return .handled
                })
        } else {
            FlowLayout(hSpacing: spacing.h, vSpacing: spacing.v) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    switch run {
                    case .text(let attr):
                        style(Text(attr))
                            .environment(\.openURL, OpenURLAction { url in
                                handleExternalURL(url)
                                return .handled
                            })
                    case .pill(let ref):
                        pillChip(numericId: ref.numericId, type: ref.type, label: ref.label)
                    }
                }
            }
        }
    }

    /// Plain text line (the catch-all from `parseLine`). Subheadline styling.
    @ViewBuilder
    private func inlineLine(_ text: String) -> some View {
        inlineRuns(text) { t in
            t.font(.subheadline).fontWeight(.regular)
        }
    }

    // MARK: - Table Rendering

    /// Render a markdown table as a simple grid with header styling.
    /// Cells are sentinel-bearing strings; `inlineRuns` splices in any pills.
    @ViewBuilder
    private func tableView(rows: [[String]]) -> some View {
        let colCount = rows.map(\.count).max() ?? 0

        if colCount > 0 {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, cells in
                HStack(spacing: 0) {
                    ForEach(0..<colCount, id: \.self) { colIdx in
                        let cellText = colIdx < cells.count ? cells[colIdx] : ""
                        tableCellView(text: cellText, isHeader: rowIdx == 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if rowIdx == 0 {
                    Divider()
                }
            }
        }
        .background(Palette.buttonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 2)
        }
    }

    /// Render a single table cell. Caption styling, header rows are bold/primary.
    @ViewBuilder
    private func tableCellView(text: String, isHeader: Bool) -> some View {
        inlineRuns(text, spacing: (2, 2)) { t in
            t.font(.caption)
                .fontWeight(isHeader ? .semibold : .regular)
                .foregroundStyle(isHeader ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Code Block (fenced ``` blocks)

    @ViewBuilder
    private func codeBlockView(code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.buttonBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 2)
    }

    // MARK: - Header (ATX # style)

    @ViewBuilder
    private func headerView(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title3.bold()
        case 2: .headline
        case 3: .subheadline.bold()
        default: .subheadline.bold()
        }
        inlineRuns(text) { t in
            t.font(font)
        }
    }

    // MARK: - Blockquote (> text)

    @ViewBuilder
    private func blockquoteView(text: String) -> some View {
        inlineRuns(text) { t in
            t.font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
        }
    }

    // MARK: - List Item (- or 1.)

    @ViewBuilder
    private func listItemView(indent: Int, ordered: Bool, marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(ordered ? marker : "\u{2022}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: ordered ? nil : 10, alignment: .trailing)
            inlineRuns(text) { t in
                t.font(.subheadline).fontWeight(.regular)
            }
        }
        .padding(.leading, CGFloat(indent / 2) * 12)
    }

    // MARK: - Pill Chip (styled like TB's pill)

    @ViewBuilder
    private func pillChip(numericId: Int, type: String, label: String) -> some View {
        Button {
            guard !isHistory else { return }
            Task {
                switch type {
                case "contact":
                    if let detail = await ChatIdTranslator.shared.resolveContactDetail(numericId) {
                        print("[AIChatDebug] Contact pill tapped: numericId=\(numericId) name=\(detail.name)")
                        contactDetail = detail
                    } else {
                        print("[AIChatDebug] Contact pill tapped but could not resolve detail for numericId=\(numericId)")
                    }
                case "event":
                    if let detail = await ChatIdTranslator.shared.resolveEventDetail(numericId) {
                        print("[AIChatDebug] Event pill tapped: numericId=\(numericId) title=\(detail.title.prefix(40))")
                        eventDetail = detail
                    } else {
                        print("[AIChatDebug] Event pill tapped but could not resolve detail for numericId=\(numericId)")
                    }
                case "template":
                    if let detail = await ChatIdTranslator.shared.resolveTemplateDetail(numericId) {
                        print("[AIChatDebug] Template pill tapped: numericId=\(numericId) name=\(detail.name)")
                        templateDetail = detail
                    } else {
                        print("[AIChatDebug] Template pill tapped but could not resolve detail for numericId=\(numericId)")
                    }
                default:
                    if let detail = await ChatIdTranslator.shared.resolveEmailDetail(numericId) {
                        print("[AIChatDebug] Pill tapped: numericId=\(numericId) subject=\(detail.subject.prefix(40))")
                        pillDetail = detail
                    } else {
                        print("[AIChatDebug] Pill tapped but could not resolve detail for numericId=\(numericId)")
                    }
                }
            }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.accent.opacity(isHistory ? 0.06 : 0.12))
                .foregroundStyle(isHistory ? Theme.textSecondary : Theme.accent)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        (isHistory ? Theme.textSecondary : Theme.accent).opacity(0.3),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(isHistory)
        .popover(
            isPresented: Binding(
                get: { pillDetail?.id == numericId },
                set: { if !$0 { pillDetail = nil } }
            )
        ) {
            if let detail = pillDetail {
                EmailPillPopover(detail: detail) {
                    pillDetail = nil
                    NotificationCenter.default.post(
                        name: .emailPillTapped,
                        object: nil,
                        userInfo: ["numericId": detail.id, "realId": detail.realId]
                    )
                }
                .presentationCompactAdaptation(.popover)
            }
        }
        .popover(
            isPresented: Binding(
                get: { contactDetail?.id == numericId },
                set: { if !$0 { contactDetail = nil } }
            )
        ) {
            if let detail = contactDetail {
                ContactPillPopover(detail: detail) { email in
                    contactDetail = nil
                    NotificationCenter.default.post(
                        name: .contactPillComposeTapped,
                        object: nil,
                        userInfo: ["email": email, "name": detail.name]
                    )
                }
                .presentationCompactAdaptation(.popover)
            }
        }
        .popover(
            isPresented: Binding(
                get: { eventDetail?.id == numericId },
                set: { if !$0 { eventDetail = nil } }
            )
        ) {
            if let detail = eventDetail {
                EventPillPopover(detail: detail)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .popover(
            isPresented: Binding(
                get: { templateDetail?.id == numericId },
                set: { if !$0 { templateDetail = nil } }
            )
        ) {
            if let detail = templateDetail {
                TemplatePillPopover(detail: detail) {
                    templateDetail = nil
                    NotificationCenter.default.post(
                        name: .templatePillOpenTapped,
                        object: nil,
                        userInfo: ["templateId": detail.realId, "numericId": detail.id]
                    )
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    // MARK: - Reminder Card (matches TB's .tm-reminder-card)

    @ViewBuilder
    private func reminderCardView(hash: String, content: String) -> some View {
        let isDismissed = dismissedHashes.contains(hash)
        VStack(alignment: .leading, spacing: 4) {
            // Content text (italic, matching TB's .tm-reminder-card-text)
            inlineRuns(content) { t in
                t.font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .strikethrough(isDismissed)
            }

            // Dismiss / unhide button below content
            if !isHistory {
                Button {
                    if isDismissed {
                        // Unhide — re-enable the reminder
                        DisabledRemindersStore.setEnabled(hash: hash, enabled: true)
                        _ = withAnimation(.easeInOut(duration: 0.3)) {
                            dismissedHashes.remove(hash)
                        }
                    } else {
                        // Hide — disable but keep visible as crossed out
                        DisabledRemindersStore.setEnabled(hash: hash, enabled: false)
                        _ = withAnimation(.easeInOut(duration: 0.3)) {
                            dismissedHashes.insert(hash)
                        }
                    }
                } label: {
                    Text(isDismissed ? "unhide reminder" : "don't show again")
                        .font(.caption2)
                        .foregroundStyle(isDismissed ? Theme.accent : Theme.destructive.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Palette.buttonBg)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .reportConcern(contentType: .chatMessage, content: content)
        .opacity(isDismissed ? 0.6 : 1.0)
    }

    // MARK: - Content Resolution

    private func resolveAndParse() async -> (lines: [ContentLine], pills: [PillRef]) {
        let processed: String
        if isHistory {
            // History: content is already pre-rendered (pills have subjects)
            processed = content
        } else if content.contains("tabmail://") {
            // Content already has rendered pills (pre-resolved in sendAgentChat) —
            // skip the redundant actor hop to processResponseForDisplay.
            processed = content
        } else {
            processed = await ChatIdTranslator.shared.processResponseForDisplay(content)
            print("[AIChatDebug] processResponseForDisplay (\(processed.count) chars): \(processed.prefix(200))")
        }
        // Sentinel pre-pass: extract pills BEFORE line classification so the
        // classifier (and its block-level branches) never see tabmail:// links.
        let (sentinelText, pills) = Self.extractPills(processed)
        let lines = Self.parseIntoLines(sentinelText)
        return (lines, pills)
    }

    // MARK: - Sentinel Pill Encoding

    /// Sentinel characters (Unicode private-use area) wrap a pill index in the
    /// text stream so AttributedString markdown sees them as inert characters
    /// while we splice in real pill chips at render time. PUA chars are guaranteed
    /// to never appear in normal LLM output and have no markdown semantics.
    nonisolated private static let sentinelOpen: Character = "\u{E000}"
    nonisolated private static let sentinelClose: Character = "\u{E001}"
    nonisolated(unsafe) private static let sentinelPattern = /\u{E000}(\d+)\u{E001}/

    /// Pre-pass over the rendered LLM response: scan for `[label](tabmail://type/N)`
    /// markdown links produced by `ChatIdTranslator.processResponseForDisplay`,
    /// replace each with `\u{E000}<index>\u{E001}`, and return the table of
    /// `PillRef`s in occurrence order. Runs BEFORE line classification so pills
    /// inside any block context (header/blockquote/list/table cell) are extracted
    /// uniformly — the line classifier never sees a tabmail:// link.
    ///
    /// Match strategy: anchor on the URL suffix `](tabmail://type/N)`, then walk
    /// backward tracking bracket depth to find the opening `[`. A naive
    /// `\[([^\]]+)\]\(...\)` regex stops at the first inner `]` and misses pills
    /// whose label has nested brackets (e.g. Korean banking subjects like
    /// `[NH농협카드]표준 …`).
    nonisolated static func extractPills(_ text: String) -> (text: String, pills: [PillRef]) {
        var pills: [PillRef] = []
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for match in text.matches(of: pillUrlSuffixPattern) {
            let closeIdx = match.range.lowerBound  // position of the `]`
            guard closeIdx >= cursor,
                  let openIdx = matchingOpenBracket(in: text, before: closeIdx, lowerBound: cursor) else {
                // Unbalanced — leave the literal markdown link in place. The
                // safety net in handleExternalURL still absorbs the tap.
                continue
            }
            result.append(contentsOf: text[cursor..<openIdx])
            let label = String(text[text.index(after: openIdx)..<closeIdx])
            let type = String(match.1)
            let numericId = Int(match.2) ?? 0
            let index = pills.count
            pills.append(PillRef(index: index, numericId: numericId, type: type, label: label))
            result.append(sentinelOpen)
            result.append(contentsOf: String(index))
            result.append(sentinelClose)
            cursor = match.range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return (result, pills)
    }

    /// Walk backward from `closeIdx` (a `]`) tracking bracket depth, returning
    /// the index of the matching `[`. Nested `[...]` pairs in the label are
    /// skipped. `lowerBound` is the earliest position to consider — typically
    /// the previous pill's cursor so we don't cross into already-consumed text.
    nonisolated private static func matchingOpenBracket(
        in text: String,
        before closeIdx: String.Index,
        lowerBound: String.Index
    ) -> String.Index? {
        var depth = 1
        var i = closeIdx
        while i > lowerBound {
            i = text.index(before: i)
            switch text[i] {
            case "]": depth += 1
            case "[":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    /// Render-time splice: parse `text` as inline markdown via Apple's
    /// `AttributedString(markdown:)`, then walk the resulting AttributedString
    /// and split at every sentinel character run, interleaving pill references.
    /// Returns a single `.text` element when no sentinels are present so the
    /// caller can render a plain `Text` view without paying for FlowLayout.
    nonisolated static func splitAtSentinels(_ text: String, pills: [PillRef]) -> [InlineRun] {
        guard let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return [.text(AttributedString(text))]
        }
        let raw = String(attr.characters)
        let matches = Array(raw.matches(of: sentinelPattern))
        if matches.isEmpty {
            return [.text(attr)]
        }
        var runs: [InlineRun] = []
        var cursor = raw.startIndex
        for match in matches {
            if cursor < match.range.lowerBound,
               let attrRange = Range(cursor..<match.range.lowerBound, in: attr) {
                runs.append(.text(AttributedString(attr[attrRange])))
            }
            if let idx = Int(match.1), idx < pills.count {
                runs.append(.pill(pills[idx]))
            }
            cursor = match.range.upperBound
        }
        if cursor < raw.endIndex,
           let attrRange = Range(cursor..<raw.endIndex, in: attr) {
            runs.append(.text(AttributedString(attr[attrRange])))
        }
        return runs
    }

    // MARK: - Parsing

    /// URL-suffix anchor for pill links produced by
    /// `ChatIdTranslator.processResponseForDisplay`: `](tabmail://type/numericId)`.
    /// `extractPills` matches on this suffix and walks backward to find the
    /// opening `[`, so labels can contain nested `[...]` pairs.
    nonisolated(unsafe) private static let pillUrlSuffixPattern = /\]\(tabmail:\/\/(\w+)\/(\d+)\)/

    /// Regex matching reminder card markers: `[reminder:HASH] CONTENT`
    nonisolated(unsafe) private static let reminderPattern = /^\[reminder:([^\]]+)\]\s+(.+)/

    /// Regex to detect markdown table separator: `|---|---|` etc.
    nonisolated(unsafe) private static let tableSeparatorPattern = /^\|[\s\-:]+(\|[\s\-:]+)+\|?\s*$/

    /// Regex for fenced code block start: ``` or ~~~ with optional language tag
    nonisolated(unsafe) private static let codeBlockStartPattern = /^(`{3,}|~{3,})(\w*)\s*$/

    /// Regex for ATX headers: up to 3 leading spaces, then 1-6 '#', a space, then text
    nonisolated(unsafe) private static let headerPattern = /^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$/

    /// Regex for blockquote lines: > text
    nonisolated(unsafe) private static let blockquotePattern = /^\s{0,3}>\s?(.*)/

    /// Regex for list items: leading whitespace, then `-`/`*`/`+` or `1.` etc., then space + text
    nonisolated(unsafe) private static let listItemPattern = /^(\s*)([-*+]|\d+[.)]) (.*)$/

    /// Split processed text into lines, detecting block-level markdown elements.
    ///
    /// `nonisolated`: `MarkdownChatText: View` inherits `@MainActor`, which Swift 6
    /// propagates into this static method and its inner `.map` closures. Calling from
    /// a non-MainActor context (e.g. Swift Testing's cooperative queue) then trips
    /// `swift_task_checkIsolatedSwift`. The body is pure text transformation — no
    /// MainActor state is read — so `nonisolated` is safe and lets tests call it.
    nonisolated static func parseIntoLines(_ text: String) -> [ContentLine] {
        let rawLines = text.components(separatedBy: "\n")
        var result: [ContentLine] = []
        var lineId = 0
        var i = 0

        while i < rawLines.count {
            let line = rawLines[i]

            // Fenced code block: ``` or ~~~
            if let fenceMatch = line.wholeMatch(of: codeBlockStartPattern) {
                let fence = String(fenceMatch.1)
                let language = String(fenceMatch.2)
                var codeLines: [String] = []
                i += 1
                while i < rawLines.count {
                    if rawLines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(rawLines[i])
                    i += 1
                }
                result.append(ContentLine(
                    id: lineId,
                    segments: [ContentSegment(id: "l\(lineId)cb", kind: .codeBlock(language: language, code: codeLines.joined(separator: "\n")))]
                ))
                lineId += 1
                continue
            }

            // Table block: line starts with |
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                var tableLines: [String] = []
                while i < rawLines.count && rawLines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    tableLines.append(rawLines[i])
                    i += 1
                }
                var rows: [[String]] = []
                for tl in tableLines {
                    if tl.wholeMatch(of: tableSeparatorPattern) != nil { continue }
                    let cellStrings = tl.components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    guard !cellStrings.isEmpty else { continue }
                    rows.append(cellStrings)
                }
                if !rows.isEmpty {
                    result.append(ContentLine(
                        id: lineId,
                        segments: [ContentSegment(id: "l\(lineId)tbl", kind: .table(rows: rows))]
                    ))
                    lineId += 1
                }
                continue
            }

            // Header: # text
            if let headerMatch = line.wholeMatch(of: headerPattern) {
                let level = headerMatch.1.count
                let text = String(headerMatch.2)
                result.append(ContentLine(
                    id: lineId,
                    segments: [ContentSegment(id: "l\(lineId)h", kind: .header(level: level, text: text))]
                ))
                lineId += 1
                i += 1
                continue
            }

            // Blockquote: > text (group consecutive lines)
            if let bqMatch = line.firstMatch(of: blockquotePattern) {
                var bqContent: [String] = [String(bqMatch.1)]
                i += 1
                while i < rawLines.count, let nextMatch = rawLines[i].firstMatch(of: blockquotePattern) {
                    bqContent.append(String(nextMatch.1))
                    i += 1
                }
                result.append(ContentLine(
                    id: lineId,
                    segments: [ContentSegment(id: "l\(lineId)bq", kind: .blockquote(text: bqContent.joined(separator: "\n")))]
                ))
                lineId += 1
                continue
            }

            // List item: - text or 1. text
            if let listMatch = line.firstMatch(of: listItemPattern) {
                let indent = String(listMatch.1).count
                let marker = String(listMatch.2)
                let text = String(listMatch.3)
                let ordered = marker.last == "." || marker.last == ")"
                result.append(ContentLine(
                    id: lineId,
                    segments: [ContentSegment(id: "l\(lineId)li", kind: .listItem(indent: indent, ordered: ordered, marker: marker, text: text))]
                ))
                lineId += 1
                i += 1
                continue
            }

            // Regular line (text, pills, reminders)
            result.append(ContentLine(id: lineId, segments: parseLine(line, lineIndex: lineId)))
            lineId += 1
            i += 1
        }
        return result
    }

    /// Parse a non-block line: detect the reminder pattern, otherwise return one
    /// `.text` segment carrying the line as-is. Pills (which by this point appear
    /// as `\u{E000}<index>\u{E001}` sentinels) ride along inside the text and are
    /// spliced back into chips at render time.
    nonisolated private static func parseLine(_ line: String, lineIndex: Int) -> [ContentSegment] {
        if line.isEmpty { return [] }

        if let match = line.wholeMatch(of: reminderPattern) {
            let hash = String(match.1)
            let content = String(match.2)
            return [ContentSegment(
                id: "l\(lineIndex)r0",
                kind: .reminder(hash: hash, content: content)
            )]
        }

        return [ContentSegment(id: "l\(lineIndex)t0", kind: .text(line))]
    }

    // MARK: - URL Handling

    private func handleExternalURL(_ url: URL) {
        print("[AIChatDebug] External URL tapped: \(url)")
        // Safety net: pills should be intercepted by the sentinel pipeline before
        // they ever reach AttributedString as a markdown link. If one slips through
        // (e.g., a future block context that bypasses extractPills), absorb it here
        // so we never hand `tabmail://` to UIApplication — which fails with
        // LSApplicationWorkspaceError 115 and confuses the user.
        if url.scheme == "tabmail" {
            print("[AIChatDebug] Absorbed stray tabmail:// URL — pill should have rendered as chip")
            return
        }
        if url.scheme == "mailto", let email = url.absoluteString.dropFirst("mailto:".count).removingPercentEncoding, !email.isEmpty {
            NotificationCenter.default.post(
                name: .contactPillComposeTapped,
                object: nil,
                userInfo: ["email": email, "name": ""]
            )
            return
        }
        guard url.scheme == "http" || url.scheme == "https" else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Data Models

struct ContentLine: Identifiable {
    let id: Int
    let segments: [ContentSegment]
}

struct ContentSegment: Identifiable {
    let id: String
    let kind: SegmentKind

    enum SegmentKind {
        case text(String)
        case reminder(hash: String, content: String)
        case table(rows: [[String]]) // parsed table: rows → cells (each cell is sentinel-bearing text)
        case codeBlock(language: String, code: String)
        case header(level: Int, text: String)
        case blockquote(text: String)
        case listItem(indent: Int, ordered: Bool, marker: String, text: String)
    }
}

/// One pill reference extracted from the rendered markdown stream.
/// `index` is the position in the per-content pills table — that index appears
/// inside `\u{E000}…\u{E001}` sentinels in the text passed to AttributedString.
struct PillRef: Hashable {
    let index: Int
    let numericId: Int
    let type: String  // "email" | "contact" | "event" | "template"
    let label: String
}

/// One run inside a markdown-rendered line: either an AttributedString slice
/// (carrying any inline styling Apple's parser produced) or a pill reference
/// to be rendered as a chip Button.
enum InlineRun {
    case text(AttributedString)
    case pill(PillRef)
}

// MARK: - Email Pill Popover (matches TB tooltip on click)

/// Popover showing email details when a pill is tapped.
/// Matches TB's tooltip: subject, from, to, snippet, and "Open Email" action.
private struct EmailPillPopover: View {
    let detail: EmailPillDetail
    let onOpenEmail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Subject
            Text(detail.subject)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(3)

            // From
            Label {
                Text(detail.from)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "person")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // To
            Label {
                Text(detail.to)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Date
            if let date = detail.date {
                Label {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Snippet
            if let snippet = detail.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }

            Divider()

            // Open Email button
            Button {
                onOpenEmail()
            } label: {
                Label("Open Email", systemImage: "envelope.open")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .tint(Theme.accent)
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 300)
    }
}

// MARK: - Contact Pill Popover (matches TB contact tooltip)

/// Popover showing contact details when a contact pill is tapped.
/// Matches TB's tooltip: name, email addresses, and "Send Email" action.
private struct ContactPillPopover: View {
    let detail: ContactPillDetail
    let onComposeEmail: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name
            Text(detail.name)
                .font(.subheadline)
                .fontWeight(.semibold)

            // Email addresses (up to 4, matching TB)
            ForEach(detail.emails, id: \.self) { email in
                Button {
                    onComposeEmail(email)
                } label: {
                    Label {
                        Text(email)
                            .font(.caption)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "envelope")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            if detail.emails.isEmpty {
                Text("No email addresses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 200, maxWidth: 300)
    }
}

// MARK: - Event Pill Popover

/// Popover showing event details when an event pill is tapped.
/// Displays: time, attendees, recurrence, availability, location.
private struct EventPillPopover: View {
    let detail: EventPillDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(detail.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(3)

            // Time
            if let start = detail.startDate {
                Label {
                    if detail.isAllDay {
                        Text(start, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let end = detail.endDate {
                        Text(Self.formatTimeRange(start: start, end: end))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(start, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Recurrence + Availability badges
            HStack(spacing: 6) {
                if detail.isRecurring {
                    Text(Self.describeRecurrence(detail.recurrenceRule))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.12))
                        .foregroundStyle(Theme.accent)
                        .clipShape(Capsule())
                }
                if detail.availability == "free" {
                    Text("Free")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                } else {
                    Text("Busy")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }

            // Location
            if let location = detail.location, !location.isEmpty {
                Label {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "mappin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Notes / description — carries Zoom/Meet links and agendas.
            // Selectable so the user can copy a meeting link out of the popover.
            if let notes = detail.notes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "doc.plaintext")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Attendees
            if !detail.attendees.isEmpty {
                Label {
                    Text("\(detail.attendees.count) attendee\(detail.attendees.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detail.attendees.prefix(5)) { attendee in
                        HStack(spacing: 4) {
                            Text(Self.statusIcon(attendee.status))
                                .font(.caption2)
                            Text(attendee.name ?? attendee.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if detail.attendees.count > 5 {
                        Text("+\(detail.attendees.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 20)
            }

            // Timezone — surfaced explicitly so the user can confirm the zone
            // even when the abbreviation alone is ambiguous.
            if let tzId = detail.eventTimeZone, !tzId.isEmpty {
                Label {
                    Text(tzId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Calendar name
            if let calName = detail.calendarName, !calName.isEmpty {
                Label {
                    Text(calName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 300)
    }

    /// Render an `RRULE:...` as user-friendly prose ("Repeats weekly",
    /// "Repeats every 2 months") for the popover. Falls back to the generic
    /// "Recurring" badge when the rule is absent or its FREQ isn't recognized.
    private static func describeRecurrence(_ rrule: String?) -> String {
        guard let rrule, !rrule.isEmpty else { return "Recurring" }
        let upper = rrule.uppercased()
        let body = upper.hasPrefix("RRULE:") ? String(upper.dropFirst("RRULE:".count)) : upper
        var freq: String?
        var interval = 1
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "FREQ": freq = String(kv[1])
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            default: break
            }
        }
        let singular: String
        let plural: String
        switch freq {
        case "DAILY": (singular, plural) = ("daily", "days")
        case "WEEKLY": (singular, plural) = ("weekly", "weeks")
        case "MONTHLY": (singular, plural) = ("monthly", "months")
        case "YEARLY": (singular, plural) = ("yearly", "years")
        default: return "Recurring"
        }
        if interval <= 1 { return "Repeats \(singular)" }
        return "Repeats every \(interval) \(plural)"
    }

    private static func formatTimeRange(start: Date, end: Date) -> String {
        let cal = Calendar.current
        let dateFmt = DateFormatter()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        if cal.isDate(start, inSameDayAs: end) {
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .none
            return "\(dateFmt.string(from: start)), \(timeFmt.string(from: start)) – \(timeFmt.string(from: end))"
        } else {
            dateFmt.dateStyle = .short
            dateFmt.timeStyle = .none
            return "\(dateFmt.string(from: start)) \(timeFmt.string(from: start)) – \(dateFmt.string(from: end)) \(timeFmt.string(from: end))"
        }
    }

    private static func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "accepted": return "✓"
        case "declined": return "✗"
        case "tentative": return "?"
        default: return "·"
        }
    }
}

// MARK: - Template Pill Popover

/// Popover shown when a template chip is tapped: name, instruction count,
/// short example-reply preview, and an "Open Template" deep-link button.
private struct TemplatePillPopover: View {
    let detail: TemplatePillDetail
    let onOpenTemplate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(2)

            Label {
                Text("\(detail.instructionCount) instruction\(detail.instructionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "list.bullet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let preview = detail.examplePreview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 2)
            }

            Divider()

            Button {
                onOpenTemplate()
            } label: {
                Label("Open Template", systemImage: "doc.text")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .tint(Theme.accent)
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 300)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when an email pill's "Open Email" is tapped in a chat bubble.
    /// UserInfo contains `numericId: Int` and `realId: String`.
    static let emailPillTapped = Notification.Name("emailPillTapped")

    /// Posted when a contact pill's email is tapped to compose.
    /// UserInfo contains `email: String` and `name: String`.
    static let contactPillComposeTapped = Notification.Name("contactPillComposeTapped")

    /// Posted when a template pill's "Open Template" is tapped in a chat bubble.
    /// UserInfo contains `templateId: String` and `numericId: Int`.
    static let templatePillOpenTapped = Notification.Name("templatePillOpenTapped")
}
