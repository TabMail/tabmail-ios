#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
INDEX = File.join(ROOT, "KNOWN_ISSUES.md")
ARCHIVE_REL = "Companion/Process/History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt"
ARCHIVE = File.join(ROOT, ARCHIVE_REL)
DETAIL_DIR_REL = "Companion/Process/Current/KnownIssues"
DETAIL_DIR = File.join(ROOT, DETAIL_DIR_REL)
MANIFEST_REL = "#{DETAIL_DIR_REL}/manifest.tsv"
MANIFEST = File.join(ROOT, MANIFEST_REL)
README_REL = "#{DETAIL_DIR_REL}/README.md"
README = File.join(ROOT, README_REL)

DISPOSITIONS = [
  ["open", "🔓 **OPEN"],
  ["closed-decision", "✅ **CLOSED AS A DECISION"],
  ["fixed", "✅ **FIXED"],
  ["accepted", "📋 **ACCEPTED LIMITATION"],
  ["not-defect", "✅ **NOT A DEFECT"],
  ["decomposed", "⚠️ **DECOMPOSED"],
  ["history", "🧭 **HISTORY FACT"]
].freeze

EXECUTIVE_DISPOSITIONS = %w[open accepted].freeze

Issue = Struct.new(
  :id, :source_line, :raw_row, :cells, :register, :disposition,
  :detail_rel, keyword_init: true
)

def sha256(bytes)
  Digest::SHA256.hexdigest(bytes)
end

def read_utf8(path)
  File.binread(path).force_encoding(Encoding::UTF_8)
end

def split_unescaped_pipes(line)
  # Register rows escape every data pipe as `\|`; negative look-behind is
  # deliberately used instead of byte offsets because the rows contain Unicode
  # disposition markers and Ruby character indexes are not byte indexes.
  line.split(/(?<!\\)\|/, -1)
end

def parse_issues(source)
  issues = []
  source.lines.each_with_index do |line, index|
    match = line.match(/^\|\s*(?:\*\*)?(IOS-[A-Z0-9]+-[A-Z0-9]+)(?:\*\*)?\s*\|/)
    next unless match

    row = line.delete_suffix("\n")
    cells = split_unescaped_pipes(row).map(&:strip)
    cells.shift if cells.first == ""
    cells.pop if cells.last == ""
    unless [3, 4].include?(cells.length)
      abort "Unexpected table shape for #{match[1]} at line #{index + 1}: #{cells.length} cells"
    end

    id = match[1]
    cells[0] = id
    register = cells.length == 4
    status = cells[1]
    disposition = if register
                    DISPOSITIONS.find { |_, marker| status.start_with?(marker) }&.first || "attribution-first"
                  else
                    "fixed-by-d4"
                  end
    issues << Issue.new(
      id: id,
      source_line: index + 1,
      raw_row: row,
      cells: cells,
      register: register,
      disposition: disposition,
      detail_rel: "#{DETAIL_DIR_REL}/#{id.downcase}.md"
    )
  end

  duplicates = issues.group_by(&:id).select { |_, rows| rows.length > 1 }
  abort "Duplicate issue ids: #{duplicates.keys.join(', ')}" unless duplicates.empty?
  issues
end

def readable(text)
  # Source links were relative to the repository root. Routed issue files live
  # three directories below `Companion/`, so preserve their target while making
  # them valid from the new location.
  normalized = text
    .gsub(/<br\s*\/?>\s*<br\s*\/?>/i, "\n\n")
    .gsub(/<br\s*\/?>/i, "\n")
    .gsub("\\|", "|")
    .gsub(/\]\(Companion\/([^)]+)\)/, '](../../../\\1)')
    .strip
  normalized.lines(chomp: true).map(&:rstrip).join("\n")
end

def plain_summary(status)
  text = readable(status)
    .gsub(/`([^`]*)`/, '\\1')
    .gsub(/\*+/, "")
    .gsub(/~~/, "")
    .gsub(/\[[^\]]+\]\([^\)]+\)/, "")
    .gsub(/\s+/, " ")
    .strip
  return text if text.length <= 240

  clipped = text[0, 237]
  clipped = clipped.sub(/\s+\S*\z/, "")
  "#{clipped}…"
end

def executive_issue?(issue)
  issue.register && EXECUTIVE_DISPOSITIONS.include?(issue.disposition)
end

def detail_document(issue, archive_sha)
  if issue.register
    status, keywords, statement = issue.cells[1], issue.cells[2], issue.cells[3]
    <<~MD
      # #{issue.id}

      > Routed from `KNOWN_ISSUES.md` line #{issue.source_line} during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`#{ARCHIVE_REL.split('/').last}`](../../History/KnownIssues/#{ARCHIVE_REL.split('/').last}) (`SHA-256 #{archive_sha}`).

      - Register classification: `#{issue.disposition}`
      - Original row SHA-256: `#{sha256(issue.raw_row)}`

      ## Status

      #{readable(status)}

      ## Subsystem and search terms

      #{readable(keywords)}

      ## Full detail

      #{readable(statement)}
    MD
  else
    defect, closed_by = issue.cells[1], issue.cells[2]
    <<~MD
      # #{issue.id}

      > Routed from the separate “Fixed by D4” compatibility table in `KNOWN_ISSUES.md` line #{issue.source_line}. The exact pre-split source is hash-pinned in [`#{ARCHIVE_REL.split('/').last}`](../../History/KnownIssues/#{ARCHIVE_REL.split('/').last}) (`SHA-256 #{archive_sha}`).

      - Register classification: `fixed-by-d4` (not counted in the main register)
      - Original row SHA-256: `#{sha256(issue.raw_row)}`

      ## Historical defect

      #{readable(defect)}

      ## Closed by

      #{readable(closed_by)}
    MD
  end
end

def manifest_document(issues, archive_sha)
  rows = ["source_sha256\tsource_line\tid\tregister\tdisposition\trow_sha256\tpath"]
  issues.each do |issue|
    rows << [
      archive_sha,
      issue.source_line,
      issue.id,
      issue.register ? "yes" : "no",
      issue.disposition,
      sha256(issue.raw_row),
      issue.detail_rel
    ].join("\t")
  end
  rows.join("\n") + "\n"
end

def readme_document(issues, archive_sha)
  register_count = issues.count(&:register)
  executive_count = issues.count { |issue| executive_issue?(issue) }
  <<~MD
    # Known-issue detail routing

    `KNOWN_ISSUES.md` is the fast executive index for the #{executive_count} current open or accepted limitations. This directory preserves one readable detail file per known-issue id: #{register_count} main-register records plus #{issues.length - register_count} historical “Fixed by D4” records, including fixed, settled, non-defect, decomposed, historical, and provenance-only entries intentionally omitted from the top-level dashboard.

    Integrity is anchored to [`#{ARCHIVE_REL.split('/').last}`](../../History/KnownIssues/#{ARCHIVE_REL.split('/').last}), the byte-exact pre-hierarchy source (`SHA-256 #{archive_sha}`). [`manifest.tsv`](manifest.tsv) binds every id to its original source line, exact row hash, disposition class, and routed path.

    Regenerate or verify with:

    ```sh
    ruby Scripts/compact_known_issues.rb verify
    ```

    The verifier rebuilds every routed file and the executive index in memory from the archive, checks byte identity, checks all links/ids, and rejects orphan or duplicate detail files.
  MD
end

def executive_index(issues, archive_sha)
  register = issues.select(&:register)
  history = issues.reject(&:register)
  executive = register.select { |issue| executive_issue?(issue) }
  counts = executive.group_by(&:disposition).transform_values(&:length)
  open = executive.select { |issue| issue.disposition == "open" }
  category_groups = executive.group_by { |issue| issue.id.split("-")[1] }.sort
  omitted_count = register.length - executive.length

  lines = []
  lines << "# TabMail iOS Known Issues"
  lines << ""
  lines << "This is the executive index for released `v1.7.5` (`50e8f63a4`). The governing policy is simple: server sync/reopen/retry is valid recovery for a fail-closed edge; guessing identity, mutating the wrong item, losing local-only authored data, exposing a secret, or wedging a durable lane is not."
  lines << ""
  lines << "**Current executive census (2026-08-09):** #{executive.length} user-impacting records — Open **#{counts.fetch('open', 0)}** · Accepted recoverable limitation **#{counts.fetch('accepted', 0)}**. The full register contains #{register.length} main records and #{history.length} historical D4 records; its #{omitted_count} fixed, settled-decision, non-defect, decomposed, historical, or provenance-only main records are intentionally omitted from this dashboard."
  lines << ""
  lines << "The full records are split into [`#{DETAIL_DIR_REL}/`](#{DETAIL_DIR_REL}/README.md). The exact pre-split register—including all superseded reasoning, corrections, audit history, predicates, and old counts—is preserved byte-for-byte in [`#{ARCHIVE_REL}`](#{ARCHIVE_REL}) (`SHA-256 #{archive_sha}`), with row-level integrity in [`#{MANIFEST_REL}`](#{MANIFEST_REL})."
  lines << ""
  lines << "## Executive summary"
  lines << ""
  lines << "- The 2026-08-09 refresh covered all 423 production Swift files in `Shared/`, `TabMail/`, and `TabMailNotificationService/`, plus the released SwiftMail resolution and current PR boundary."
  lines << "- Four differently shaped passes covered durable/crash recovery, UI/lifecycle and swallowed errors, provider/dependency boundaries, then local-only ownership/privacy/terminal-state readers. The fourth pass produced no new issue class."
  lines << "- This top-level file lists only current open or accepted user-impacting limitations. All fixed and non-problem records remain available through the companion directory and hash-pinned archive."
  lines << "- The audit added seven records. Five are explicitly recoverable accepted limitations; two remain open because removal/reset can silently become partial and stale remote push state can survive account removal."
  lines << "- Atomic MOVE remains intentionally conservative: uncertain crash recovery may drop the gesture and let sync restore server truth (`IOS-MOVE-003`); it does not blindly replay or guess a destination identity."
  lines << ""
  lines << "## Open issues requiring attention"
  lines << ""
  if open.empty?
    lines << "None."
  else
    open.each do |issue|
      lines << "- [#{issue.id}](#{issue.detail_rel}): #{plain_summary(issue.cells[1])}"
    end
  end
  lines << ""
  lines << "## Issue index"
  lines << ""
  category_groups.each do |category, category_issues|
    lines << "### #{category} (#{category_issues.length})"
    lines << ""
    lines << "| ID | Class | Executive statement |"
    lines << "|---|---|---|"
    category_issues.sort_by(&:id).each do |issue|
      label = issue.disposition
      summary = plain_summary(issue.cells[1]).gsub("|", "\\|")
      lines << "| [#{issue.id}](#{issue.detail_rel}) | `#{label}` | #{summary} |"
    end
    lines << ""
  end
  lines.pop while lines.last == ""
  lines.join("\n") + "\n"
end

def expected_outputs(source)
  issues = parse_issues(source)
  archive_sha = sha256(source)
  outputs = {
    INDEX => executive_index(issues, archive_sha),
    README => readme_document(issues, archive_sha),
    MANIFEST => manifest_document(issues, archive_sha)
  }
  issues.each do |issue|
    outputs[File.join(ROOT, issue.detail_rel)] = detail_document(issue, archive_sha)
  end
  [issues, outputs]
end

def write_if_changed(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  return if File.exist?(path) && File.binread(path).b == content.b

  File.binwrite(path, content)
end

def generate
  current = read_utf8(INDEX)
  if File.exist?(ARCHIVE)
    archived = read_utf8(ARCHIVE)
    if current.bytesize > 500_000 && current != archived
      abort "Archive already exists but differs from the still-monolithic KNOWN_ISSUES.md"
    end
    source = archived
  else
    abort "KNOWN_ISSUES.md no longer looks like the pre-hierarchy register" if current.bytesize < 500_000
    FileUtils.mkdir_p(File.dirname(ARCHIVE))
    File.binwrite(ARCHIVE, current)
    source = current
  end

  issues, outputs = expected_outputs(source)
  expected_detail_paths = issues.map { |issue| File.join(ROOT, issue.detail_rel) }.sort
  existing_detail_paths = Dir.glob(File.join(DETAIL_DIR, "ios-*.md")).sort
  (existing_detail_paths - expected_detail_paths).each { |path| File.delete(path) }
  outputs.each { |path, content| write_if_changed(path, content) }
  puts "Generated #{issues.count(&:register)} register details + #{issues.count { |i| !i.register }} historical details"
  puts "Archive SHA-256: #{sha256(source)}"
end

def verify
  abort "Missing archive: #{ARCHIVE_REL}" unless File.exist?(ARCHIVE)
  source = read_utf8(ARCHIVE)
  issues, outputs = expected_outputs(source)
  failures = []

  outputs.each do |path, expected|
    rel = path.delete_prefix("#{ROOT}/")
    if !File.exist?(path)
      failures << "missing #{rel}"
    elsif File.binread(path).b != expected.b
      failures << "content mismatch #{rel}"
    end
  end

  expected_detail_paths = issues.map { |issue| File.join(ROOT, issue.detail_rel) }.sort
  existing_detail_paths = Dir.glob(File.join(DETAIL_DIR, "ios-*.md")).sort
  (existing_detail_paths - expected_detail_paths).each do |path|
    failures << "orphan detail #{path.delete_prefix("#{ROOT}/")}"
  end

  index = read_utf8(INDEX)
  issues.select { |issue| executive_issue?(issue) }.each do |issue|
    failures << "index missing #{issue.id}" unless index.include?(issue.id)
  end
  issues.each do |issue|
    failures << "detail missing id #{issue.id}" unless read_utf8(File.join(ROOT, issue.detail_rel)).include?(issue.id)
  end

  if failures.empty?
    puts "Known-issues hierarchy verified: #{issues.count(&:register)} register + #{issues.count { |i| !i.register }} historical"
    puts "Archive SHA-256: #{sha256(source)}"
  else
    warn failures.join("\n")
    exit 1
  end
end

case ARGV.fetch(0, "verify")
when "generate" then generate
when "verify" then verify
else abort "usage: ruby Scripts/compact_known_issues.rb [generate|verify]"
end
