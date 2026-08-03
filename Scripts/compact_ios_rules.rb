#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", __dir__)
MANIFEST = File.join(ROOT, "Companion/Rules/manifest.tsv")
SOURCE_PATH = File.join(ROOT, "CLAUDE.md")
LEGACY_REVISION = "0bcc851"
LEGACY_PATH = "Companion/Process/History/002-original-full-ingestion-protocol-at-0bcc851.md"
LEGACY_MANIFEST = File.join(ROOT, "Companion/Process/History/manifest.tsv")
CURRENT_NOTE_BEGIN = "<!-- COMPANION-CURRENT-NOTE-BEGIN -->"
CURRENT_NOTE_END = "<!-- COMPANION-CURRENT-NOTE-END -->"

ROUTES = {
  "__preamble__" => ["historical", "Companion/Process/History/000-pre-compaction-preamble.md"],
  "Companion Routing (MANDATORY BEFORE EVERY TASK)" => ["historical", "Companion/Process/History/001-pre-compaction-routing.md"],
  "Development Rules" => ["active", "Companion/Rules/Active/development-rules.md"],
  "Cross-Model Audit Workflow — STANDARD (current owner-directed role assignment 2026-07-27)" => ["current", "Companion/Process/Current/audit-workflow.md"],
  "Core Philosophy: Never Drop User Intention" => ["active", "Companion/Rules/Active/never-drop-user-intention.md"],
  "Data Integrity Rules — ABSOLUTE" => ["active", "Companion/Rules/Active/data-integrity.md"],
  "Resilience Rules" => ["active", "Companion/Rules/Active/resilience.md"],
  "Outbox Reliability Rules" => ["active", "Companion/Rules/Active/outbox-reliability.md"],
  "AI Processing Rules" => ["active", "Companion/Rules/Active/ai-processing.md"],
  "SwiftUI Mutation Safety Rules" => ["active", "Companion/Rules/Active/swiftui-mutation-safety.md"],
  "User Interaction Freeze Rule" => ["active", "Companion/Rules/Active/user-interaction-freeze.md"],
  "Keyboard Dismiss Rule" => ["active", "Companion/Rules/Active/keyboard-dismiss.md"],
  "Other notes" => ["current", "Companion/Process/Current/other-notes.md"]
}.freeze

COMPACT_CLAUDE = <<~'MARKDOWN'
  # TabMail iOS - Claude Code Rules

  > **STOP. Before answering, read every compact mandatory file below, mechanically search the full routed companion hierarchy, and read every matching document in full. Update the routed detail and its index when durable knowledge changes. This is mandatory for every task.**

  ## Mandatory startup and routing

  Always read these files in full:

  - Global: `../CLAUDE.md`, `../PROJECT_STRUCTURE.md`, `../PROJECT_MEMORY.md`, `../DECISIONS.md`.
  - iOS: `CLAUDE.md`, `PROJECT_STRUCTURE.md`, `PROJECT_MEMORY.md`, `DECISIONS.md`.

  Before planning, editing, reviewing, or answering:

  1. Derive search terms from the request, named files/symbols, subsystem, provider, invariant, failure mode, plans, and ADR IDs.
  2. Run `rg -ni '<terms>' PROJECT_MEMORY.md DECISIONS.md Companion/Memory Companion/Decisions Companion/Process Companion/Rules` plus a code census.
  3. Read every matched routed document completely. Follow related entries governing the same invariant.
  4. Every plan, implementation brief, and review prompt must enumerate its exact required topic, ADR, process, and rule files.
  5. Current entries govern. Preserve superseded/history material in its routed directory. Do not use Markdown `@imports` as a context shortcut.

  ## Always-load release and safety charter

  - The global secret-exposure halt overrides everything. Never inspect or send secret-bearing files to an external reviewer.
  - This is production-critical. Prefer minimal diffs, reuse existing functions, add no fallback without approval, preserve debug code, and resolve every warning.
  - Codex coordinates, authors plans/specs, verifies evidence, and makes the final call. A fresh high-reasoning Codex implementation subagent and a separate builder handle source/test work. Claude Opus is read-only independent review through `$ask-claude` and `$claude-review`. Never push or release.
  - For every fix, search `v1.6.38` first and quote the owning operation's exact sequence. Restore shipped behavior when applicable; author only when the shipped architecture is inapplicable or nonexistent. The release bar is **no worse than v1.6.38**, not “no known defects.”
  - Ask **“instance or class?”** and enumerate the complete invariant class mechanically before fixing a named site.
  - At most **five** plan-vet rounds. Fold confirmed findings into the checklist, freeze the plan, then implement with red-first invariant tests; resolve later uncertainty against code, tests, and exact-diff review.
  - Every audit-found bug gets a test that proves the violated system property red on pre-fix behavior. Run the relevant suite/coverage, build with zero warnings, run an inversion sweep, and review the exact current candidate after every fix round.
  - One confined job per fresh implementation agent; never resume an implementation agent across review rounds. Briefs require self-stall reporting and honest DONE / IN PROGRESS / NOT STARTED state.

  ## Always-load intention invariant

  Persist user intention before acknowledging it, execute it durably, and never silently discard it. A queued operation leaves the queue only for exactly three reasons:

  1. Provider-confirmed success.
  2. A provider-authoritative stale/no-op result; absence, thrown reads, unresolved identity, failed writes, and unknown epochs are retryable, not authoritative.
  3. Annihilation by a newer exact inverse user action, only when the earlier operation is unattempted and the members match exactly.

  A bounded, visible, retryable quarantine is not a discard. Read the full routed invariant and foundational decision for any queue, action, send, Undo, draft, notification, retry, or reconciliation work.

  ## Routed process and rule index

  Search the keywords in every row. When a row matches, read its linked document in full.

  | Status | Keywords / scope | Required detail |
  |---|---|---|
  | Current | audit, regression, release, plan, vet, review, agent, build, test, stall, `v1.6.38`, exact diff | [Audit workflow](Companion/Process/Current/audit-workflow.md) |
  | Current | parallel agents, unrelated build failure | [Other notes](Companion/Process/Current/other-notes.md) |
  | Active | SwiftUI, GRDB, XcodeGen, `project.yml`, secrets configuration, SwiftMail, modularization, reuse | [Development rules](Companion/Rules/Active/development-rules.md) |
  | Active | intention, queue, thrown read, optimistic UI, retries, reconciliation, Undo, action, send, draft, notification | [Never drop user intention](Companion/Rules/Active/never-drop-user-intention.md) |
  | Active | body, attachment, fetch, UID, IMAP stale detection, migration, schema | [Data integrity](Companion/Rules/Active/data-integrity.md) |
  | Active | main thread, connection loss, idempotency, sync, `Mutex`, isolation | [Resilience](Companion/Rules/Active/resilience.md) |
  | Active | Outbox, SMTP, queue send, `sentAt`, double-send | [Outbox reliability](Companion/Rules/Active/outbox-reliability.md) |
  | Active | AI, summary, action, reply, Thunderbird parity, LLM queue | [AI processing](Companion/Rules/Active/ai-processing.md) |
  | Active | SwiftUI, `@Observable`, array mutation, `ForEach`, pagination | [SwiftUI mutation safety](Companion/Rules/Active/swiftui-mutation-safety.md) |
  | Active | swipe, tap, animation, interaction freeze, deferred updates, snippets | [User interaction freeze](Companion/Rules/Active/user-interaction-freeze.md) |
  | Active | keyboard, text input, tap outside, scroll dismissal | [Keyboard dismissal](Companion/Rules/Active/keyboard-dismiss.md) |
  | Historical | pre-rule-compaction preamble after index routing was introduced | [Preserved routed preamble](Companion/Process/History/000-pre-compaction-preamble.md) |
  | Historical | first index-plus-search protocol before second-stage rule compaction | [Preserved routed protocol](Companion/Process/History/001-pre-compaction-routing.md) |
  | Historical | original read-every-companion-file startup protocol at `0bcc851` | [Preserved full-ingestion protocol](Companion/Process/History/002-original-full-ingestion-protocol-at-0bcc851.md) |

  The mechanical source manifest is [`Companion/Rules/manifest.tsv`](Companion/Rules/manifest.tsv). `Scripts/compact_ios_rules.rb verify` reconstructs the pre-compaction `CLAUDE.md` byte-for-byte from these routed documents.
MARKDOWN

def source_sections(source)
  source = source.dup.force_encoding(Encoding::UTF_8)
  lines = source.lines
  headings = lines.each_index.each_with_object([]) do |index, result|
    match = lines[index].match(/^## (.+)\n?$/)
    result << [index, match[1]] if match
  end
  abort("no H2 headings found") if headings.empty?

  sections = [["__preamble__", lines[0...headings.first[0]].join]]
  headings.each_with_index do |(start_index, title), index|
    end_index = headings[index + 1]&.first || lines.length
    sections << [title, lines[start_index...end_index].join]
  end
  sections
end

def generate
  abort("refusing to regenerate existing routed rules") if File.exist?(MANIFEST)
  source = File.binread(SOURCE_PATH)
  sections = source_sections(source)
  unless sections.map(&:first) == ROUTES.keys
    abort("unexpected CLAUDE.md headings:\n#{sections.map(&:first).inspect}\nexpected:\n#{ROUTES.keys.inspect}")
  end

  rows = ["order\tstatus\tsha256\tseparator\tpath\theading"]
  sections.each_with_index do |(heading, body), index|
    status, relative_path = ROUTES.fetch(heading)
    separator = index == sections.length - 1 ? "NONE" : "LF"
    stored_body = separator == "LF" ? body.delete_suffix("\n") : body
    abort("expected one structural separator after #{heading}") if separator == "LF" && stored_body == body
    absolute_path = File.join(ROOT, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.binwrite(absolute_path, stored_body)
    rows << [index, status, Digest::SHA256.hexdigest(stored_body), separator, relative_path, heading].join("\t")
  end

  metadata = [
    "# source=CLAUDE.md",
    "# source_base_revision=0bcc851",
    "# source_capture=working tree after the first companion-routing rewrite and owner rules 2h/2i, immediately before second-stage rule compaction",
    "# source_sha256=#{Digest::SHA256.hexdigest(source)}",
    "# source_bytes=#{source.bytesize}",
    "# source_lines=#{source.lines.length}"
  ]
  FileUtils.mkdir_p(File.dirname(MANIFEST))
  File.binwrite(MANIFEST, (metadata + rows).join("\n") + "\n")
  File.binwrite(SOURCE_PATH, COMPACT_CLAUDE)
  puts "compacted CLAUDE.md into #{sections.length} byte-exact routed fragments"
end

def manifest_data
  lines = File.readlines(MANIFEST, chomp: true)
  metadata = lines.take_while { |line| line.start_with?("# ") }.to_h do |line|
    key, value = line.delete_prefix("# ").split("=", 2)
    [key, value]
  end
  header_index = lines.index("order\tstatus\tsha256\tseparator\tpath\theading")
  abort("invalid rule manifest header") unless header_index
  [metadata, lines[(header_index + 1)..]]
end

def exact_body(body)
  pattern = /\A#{Regexp.escape(CURRENT_NOTE_BEGIN)}\n.*?\n#{Regexp.escape(CURRENT_NOTE_END)}\n/m
  body.sub(pattern, "")
end

def verify
  metadata, rows = manifest_data
  reconstructed = +""
  paths = []
  rows.each do |row|
    _order, _status, expected_sha, separator, relative_path, _heading = row.split("\t", 6)
    body = File.binread(File.join(ROOT, relative_path))
    preserved_body = exact_body(body)
    abort("rule fragment hash mismatch: #{relative_path}") unless Digest::SHA256.hexdigest(preserved_body) == expected_sha
    reconstructed << preserved_body
    reconstructed << "\n" if separator == "LF"
    paths << relative_path
  end

  abort("rule reconstruction hash mismatch") unless Digest::SHA256.hexdigest(reconstructed) == metadata.fetch("source_sha256")
  abort("rule reconstruction byte-count mismatch") unless reconstructed.bytesize == metadata.fetch("source_bytes").to_i
  abort("rule reconstruction line-count mismatch") unless reconstructed.lines.length == metadata.fetch("source_lines").to_i

  index = File.read(SOURCE_PATH)
  missing = paths.reject { |path| index.scan("(#{path})").length == 1 }
  abort("rule fragments missing or multiply linked: #{missing.join(", ")}") unless missing.empty?

  verify_legacy_protocol(index)

  puts "reconstructed original CLAUDE.md: #{reconstructed.lines.length} lines, #{reconstructed.bytesize} bytes, byte-identical by SHA-256"
  puts "rule routing: #{paths.length} detailed fragments, each linked exactly once"
end

def legacy_protocol_source
  source, status = Open3.capture2("git", "show", "#{LEGACY_REVISION}:CLAUDE.md", chdir: ROOT)
  abort("could not read #{LEGACY_REVISION}:CLAUDE.md") unless status.success?
  lines = source.lines
  development_index = lines.index { |line| line.start_with?("## Development Rules") }
  abort("legacy development heading not found") unless development_index
  [source, lines[0...development_index].join, development_index]
end

def extract_legacy_protocol
  abort("legacy protocol already extracted") if File.exist?(File.join(ROOT, LEGACY_PATH)) || File.exist?(LEGACY_MANIFEST)
  source, legacy_body, end_line = legacy_protocol_source
  stored_body = legacy_body.delete_suffix("\n")
  abort("legacy protocol has no structural separator") if stored_body == legacy_body
  FileUtils.mkdir_p(File.dirname(File.join(ROOT, LEGACY_PATH)))
  File.binwrite(File.join(ROOT, LEGACY_PATH), stored_body)
  manifest = [
    "revision\tsource\tsource_lines\tsource_sha256\tstored_sha256\tseparator\tpath",
    [LEGACY_REVISION, "CLAUDE.md", "1-#{end_line}", Digest::SHA256.hexdigest(legacy_body), Digest::SHA256.hexdigest(stored_body), "LF", LEGACY_PATH].join("\t")
  ]
  File.binwrite(LEGACY_MANIFEST, manifest.join("\n") + "\n")
  puts "extracted original full-ingestion protocol from #{LEGACY_REVISION}:CLAUDE.md (source #{source.lines.length} lines, #{source.bytesize} bytes)"
end

def verify_legacy_protocol(index)
  _source, expected, end_line = legacy_protocol_source
  row = File.readlines(LEGACY_MANIFEST, chomp: true).fetch(1)
  revision, source_path, source_lines, source_sha, stored_sha, separator, relative_path = row.split("\t", 7)
  abort("legacy manifest provenance mismatch") unless revision == LEGACY_REVISION && source_path == "CLAUDE.md" && source_lines == "1-#{end_line}" && separator == "LF" && relative_path == LEGACY_PATH
  stored = File.binread(File.join(ROOT, relative_path))
  abort("legacy stored hash mismatch") unless Digest::SHA256.hexdigest(stored) == stored_sha
  reconstructed = stored + "\n"
  abort("legacy source hash mismatch") unless Digest::SHA256.hexdigest(reconstructed) == source_sha
  abort("legacy source content mismatch") unless reconstructed == expected.b
  abort("legacy protocol is not linked exactly once") unless index.scan("(#{LEGACY_PATH})").length == 1
  puts "legacy routing: #{LEGACY_REVISION}:CLAUDE.md lines 1-#{end_line} preserved byte-identically and linked once"
end

def normalize_existing_manifest
  lines = File.readlines(MANIFEST, chomp: true)
  old_header_index = lines.index("order\tstatus\tsha256\tpath\theading")
  abort("rule manifest is already normalized or has an unknown format") unless old_header_index
  metadata = lines[0...old_header_index]
  old_rows = lines[(old_header_index + 1)..]
  new_rows = ["order\tstatus\tsha256\tseparator\tpath\theading"]

  old_rows.each_with_index do |row, index|
    order, status, expected_sha, relative_path, heading = row.split("\t", 5)
    body = File.binread(File.join(ROOT, relative_path))
    abort("pre-normalization hash mismatch: #{relative_path}") unless Digest::SHA256.hexdigest(body) == expected_sha
    separator = index == old_rows.length - 1 ? "NONE" : "LF"
    stored_body = separator == "LF" ? body.delete_suffix("\n") : body
    abort("expected structural separator in #{relative_path}") if separator == "LF" && stored_body == body
    File.binwrite(File.join(ROOT, relative_path), stored_body)
    new_rows << [order, status, Digest::SHA256.hexdigest(stored_body), separator, relative_path, heading].join("\t")
  end

  File.binwrite(MANIFEST, (metadata + new_rows).join("\n") + "\n")
  puts "moved #{old_rows.length - 1} inter-section line feeds from fragment EOFs into the reconstruction manifest"
end

case ARGV.fetch(0, "verify")
when "generate" then generate
when "extract-legacy" then extract_legacy_protocol
when "verify" then verify
when "normalize-manifest" then normalize_existing_manifest
else abort("usage: #{File.basename($PROGRAM_NAME)} [generate|extract-legacy|normalize-manifest|verify]")
end
