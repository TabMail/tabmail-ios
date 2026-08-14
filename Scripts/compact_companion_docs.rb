#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", __dir__)
# v3 descends from the released `v1.6.38` (07a4bb703), not from the `v2final` line whose
# compaction was pinned to `0bcc851`. Compacting against `0bcc851` would produce a companion
# tree describing an implementation that never shipped and is not this branch.
SOURCE_REV = ENV.fetch("COMPANION_SOURCE_REV", "v1.6.38")
COMPANION_ROOT = File.join(ROOT, "Companion")
# Revision-pinned to `v1.6.38:PROJECT_MEMORY.md`: `## Architecture Patterns` is line 144 and the
# next H2 (`## Banner Flash Prevention`) is line 858, so the nested H3 topics end at line 857.
ARCHITECTURE_PATTERN_START_LINE = 144
ARCHITECTURE_PATTERN_END_LINE = 857
CURRENT_NOTE_BEGIN = "<!-- COMPANION-CURRENT-NOTE-BEGIN -->"
CURRENT_NOTE_END = "<!-- COMPANION-CURRENT-NOTE-END -->"
PORTED_MANIFEST = "Companion/Decisions/ported-manifest.tsv"
PORTED_MEMORY_MANIFEST = "Companion/Memory/ported-manifest.tsv"

# `v1.6.38:DECISIONS.md` defines `## ADR-IOS-026` twice: "Proactive Local Notifications" and
# "PendingOperation Uses Stable IDs (rfc822MessageId)". The second occurrence routes as
# `ADR-IOS-026B`, matching both the reference compaction and the v3 working-tree renumbering.
DUPLICATE_ROUTE_SUFFIXES = ("B".."Z").to_a

def git_show_rev(rev, path)
  output, status = Open3.capture2("git", "show", "#{rev}:#{path}", chdir: ROOT)
  abort("git show failed for #{path} at #{rev}") unless status.success?

  output
end

def git_show(path)
  git_show_rev(SOURCE_REV, path)
end

def lines_for(path)
  git_show(path).lines
end

def route_ids(source_ids)
  seen = Hash.new(0)
  source_ids.map do |id|
    seen[id] += 1
    seen[id] == 1 ? id : "#{id}#{DUPLICATE_ROUTE_SUFFIXES.fetch(seen[id] - 2)}"
  end
end

def slug(text)
  text
    .downcase
    .gsub(/`([^`]*)`/, '\\1')
    .gsub(/[^a-z0-9]+/, "-")
    .gsub(/\A-+|-+\z/, "")
    .then { |value| value.empty? ? "topic" : value }
    .slice(0, 72)
    .sub(/-+\z/, "")
end

def write_exact(relative_path, body)
  path = File.join(ROOT, relative_path)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, body)
end

def prepend_current_note(relative_path, note)
  path = File.join(ROOT, relative_path)
  original = File.binread(path)
  wrapper = <<~MARKDOWN
    #{CURRENT_NOTE_BEGIN}
    > **Current routing note:** #{note}
    #{CURRENT_NOTE_END}
  MARKDOWN
  File.binwrite(path, wrapper + original)
end

# The routed fragment sequence numbers are source-revision dependent, so notes are attached by
# preserved heading text rather than by a hardcoded file name.
def note_fragment_titled(fragments, title, note)
  match = fragments.select { |item| item[:title] == title }
  abort("expected exactly one routed fragment titled #{title.inspect}") unless match.length == 1

  prepend_current_note(match.first[:path], note)
end

def exact_body(body)
  pattern = /\A#{Regexp.escape(CURRENT_NOTE_BEGIN)}\n.*?\n#{Regexp.escape(CURRENT_NOTE_END)}\n/m
  body.sub(pattern, "")
end

def unique_path(directory, sequence, title, used)
  base = format("%03d-%s", sequence, slug(title))
  candidate = File.join(directory, "#{base}.md")
  suffix = 2
  while used.include?(candidate)
    candidate = File.join(directory, "#{base}-#{suffix}.md")
    suffix += 1
  end
  used << candidate
  candidate
end

def section_start(source_lines, heading_line)
  start_line = heading_line
  start_line -= 1 while start_line > 1 && source_lines[start_line - 2].strip.empty?
  start_line
end

def fragment(relative_path, start_line, end_line, title, status, source_lines)
  body = source_lines[(start_line - 1)..(end_line - 1)].join
  write_exact(relative_path, body)
  {
    path: relative_path,
    start_line: start_line,
    end_line: end_line,
    title: title,
    status: status,
    sha256: Digest::SHA256.hexdigest(body)
  }
end

def markdown_link(fragment, label = nil)
  "[#{label || fragment[:title]}](#{fragment[:path].gsub(" ", "%20")})"
end

# Memory topics that exist only on the mature pre-v3 line and are therefore absent from
# `v1.6.38:PROJECT_MEMORY.md`. Same treatment as the forward-ported ADR bodies: preserved
# byte-for-byte with provenance, excluded from the source-document reconstruction manifest.
# `090` is linked from the ported `Companion/Process/Current/audit-workflow.md`; `092` is the
# ADR-IOS-060 direction topic that live v3 plans route to.
PORTED_MEMORY_PATHS = [
  "Companion/Memory/History/090-historical-intention-journal-fold-at-drain-adr-ios-058-2026-07-11-queue.md",
  "Companion/Memory/Current/092-intention-queue-v2-authoritative-current-direction-adr-ios-060-2026-07-1.md"
].freeze

def port_memory
  rows = ["source_rev\tstatus\tsha256\tpath\ttitle"]
  PORTED_MEMORY_PATHS.each do |relative_path|
    body = git_show_rev(PORTED_SOURCE_REV, relative_path)
    title = exact_body(body)[/^\#{2,3}\s+(.+)$/, 1]&.strip
    abort("ported memory topic has no heading: #{relative_path}") unless title

    status = { "Current" => "current", "History" => "historical" }.fetch(File.basename(File.dirname(relative_path)))
    write_exact(relative_path, body)
    rows << [PORTED_SOURCE_REV, status, Digest::SHA256.hexdigest(body), relative_path, title].join("\t")
  end
  write_exact(PORTED_MEMORY_MANIFEST, rows.join("\n") + "\n")
  puts "ported #{PORTED_MEMORY_PATHS.length} pre-v3 memory topics from #{PORTED_SOURCE_REV}"
end

def ported_memory
  path = File.join(ROOT, PORTED_MEMORY_MANIFEST)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).drop(1).map do |row|
    source_rev, status, sha256, relative_path, title = row.split("\t", 5)
    { source_rev: source_rev, status: status, sha256: sha256, path: relative_path, title: title }
  end
end

def verify_ported_memory
  ported = ported_memory
  return puts("ported memory topics: none recorded") if ported.empty?

  index = File.read(File.join(ROOT, "PROJECT_MEMORY.md"))
  ported.each do |item|
    body = File.binread(File.join(ROOT, item[:path]))
    abort("ported memory hash mismatch: #{item[:path]}") unless Digest::SHA256.hexdigest(body) == item[:sha256]

    expected_directory = { "current" => "Current", "historical" => "History" }.fetch(item[:status])
    actual_directory = File.basename(File.dirname(item[:path]))
    abort("ported memory status differs from route: #{item[:path]}") unless actual_directory == expected_directory

    abort("ported memory topic is not linked exactly once: #{item[:path]}") unless index.scan("(#{item[:path]})").length == 1
  end

  puts "ported memory topics: #{ported.length} forward-ported topics hash-verified, routed by status, and linked once"
end

def generate_memory
  source_lines = lines_for("PROJECT_MEMORY.md")
  headings = source_lines.each_index.each_with_object([]) do |index, result|
    text = source_lines[index]
    # Revision-pinned extraction boundary: only H3s nested under the source's
    # Architecture Patterns H2 become standalone routed topics.
    in_architecture_patterns = index >= (ARCHITECTURE_PATTERN_START_LINE - 1) && index < ARCHITECTURE_PATTERN_END_LINE
    next unless text.match?(/^## /) || (in_architecture_patterns && text.match?(/^### /))

    result << [index + 1, text.sub(/^#+\s+/, "").strip, text.start_with?("### ") ? 3 : 2]
  end

  fragments = []
  used = []
  first_section_start = section_start(source_lines, headings.first.first)
  fragments << fragment(
    "Companion/Memory/History/000-original-project-memory-preamble.md",
    1,
    first_section_start - 1,
    "Original project-memory preamble",
    "historical",
    source_lines
  )

  headings.each_with_index do |(heading_line, title, level), index|
    start_line = section_start(source_lines, heading_line)
    next_heading = headings[index + 1]&.first
    next_start = next_heading ? section_start(source_lines, next_heading) : (source_lines.length + 1)
    end_line = next_start - 1
    status = title.start_with?("HISTORICAL") ? "historical" : "current"
    directory = status == "historical" ? "Companion/Memory/History" : "Companion/Memory/Current"
    sequence = fragments.length
    relative_path = unique_path(directory, sequence, title, used)
    fragments << fragment(relative_path, start_line, end_line, title, status, source_lines).merge(level: level)
  end

  manifest = ["order\tstatus\tsource_lines\tsha256\tpath\ttitle"]
  fragments.each_with_index do |item, index|
    manifest << [
      index,
      item[:status],
      "#{item[:start_line]}-#{item[:end_line]}",
      item[:sha256],
      item[:path],
      item[:title]
    ].join("\t")
  end
  write_exact("Companion/Memory/manifest.tsv", manifest.join("\n") + "\n")

  current = fragments.select { |item| item[:status] == "current" }
  historical = fragments.select { |item| item[:status] == "historical" }
  index = +<<~MARKDOWN
    # TabMail iOS - Project Memory Index

    > **Mandatory current-state router.** Always read this compact index before iOS work. Detailed material is preserved under `Companion/Memory/`; load only the mechanically matched topics in full. For cross-cutting knowledge, also read `../PROJECT_MEMORY.md`.

    **Compacted from:** `#{SOURCE_REV}:PROJECT_MEMORY.md` without semantic rewriting. The ordered extraction manifest and hashes are in [`Companion/Memory/manifest.tsv`](Companion/Memory/manifest.tsv).

    ## Always load-bearing

    - The universal safety and development rules live in `../CLAUDE.md` and `CLAUDE.md`; those rules outrank memory notes.
    - Before planning, editing, or reviewing, search this index and the complete `Companion/` hierarchy for task concepts, subsystem names, symbols, providers, failure modes, and plan terms with `rg -ni`.
    - Read every matched topic, ADR, process, and rule file in full.
    - Plans and review prompts must enumerate the exact topic, ADR, process, and rule files required for their scope.
    - The shipped release is the first architectural reference for every fix; search and quote `v1.6.38` before authoring new behavior.
    - Ask **“instance or class?”** and perform a grep census before changing a named site.
    - Current entries govern. Historical entries preserve evidence but do not override current rules or active ADRs.
    - Do not use Markdown imports as a context shortcut; imported text still consumes startup context.

    ## Routing procedure

    1. Build search terms from the request, named files/symbols, subsystem, provider, invariant, and likely defect class.
    2. Run `rg -ni '<terms>' PROJECT_MEMORY.md DECISIONS.md Companion/Memory Companion/Decisions Companion/Process Companion/Rules` and a code census with `rg`.
    3. Read each matched detailed topic, ADR, process, and rule document completely before acting. Follow links and `Relates` entries when they affect the same invariant.
    4. Record every required routed path in any plan, implementation brief, or review prompt.
    5. Update the relevant detail file and its index row when durable knowledge changes; do not grow this file into an unconditional archive.

    ## Current topics

    Search the topic text below as subsystem keywords. Each link is mandatory when its row matches the task.

    | Topic / search terms | Detail |
    |---|---|
  MARKDOWN
  current.each do |item|
    index << "| #{item[:title].gsub("|", "\\|")} | #{markdown_link(item, "read in full")} |\n"
  end
  index << <<~MARKDOWN

    ## Historical and superseded memory

    These files preserve source history. Read them when a current topic, ADR, plan, or shipped-release comparison points to the older design.

    | Status | Topic / search terms | Detail |
    |---|---|---|
  MARKDOWN
  historical.each do |item|
    index << "| Historical | #{item[:title].gsub("|", "\\|")} | #{markdown_link(item, "read in full")} |\n"
  end

  ported = ported_memory
  unless ported.empty?
    index << <<~MARKDOWN

      ## Forward-ported topics absent from the shipped source

      These topics exist only on the mature pre-v3 line and are therefore not in `#{SOURCE_REV}:PROJECT_MEMORY.md`. v3 forward-ports that work, so the bodies are preserved byte-for-byte with their provenance in [`Companion/Memory/ported-manifest.tsv`](Companion/Memory/ported-manifest.tsv). They are excluded from the source-document reconstruction manifest.

      | Status | Topic / search terms | Detail |
      |---|---|---|
    MARKDOWN
    ported.each do |item|
      index << "| #{item[:status].capitalize} | #{item[:title].gsub("|", "\\|")} | [read in full](#{item[:path]}) |\n"
    end
  end

  write_exact("PROJECT_MEMORY.md", index)
  note_fragment_titled(
    fragments,
    "Outbox — Persistent Offline Send Queue (ADR-IOS-019)",
    "The preserved final reference to the old `CLAUDE.md` heading now routes to `Companion/Rules/Active/outbox-reliability.md`."
  )
  fragments
end

DECISION_STATUSES = {
  "004" => "superseded",
  "012" => "superseded",
  "016" => "superseded",
  "017" => "superseded",
  # v3 subtraction (D4): durable ops key by native provider id — IMAP `(UIDVALIDITY, UID)`,
  # Gmail/Graph `message.id`. RFC 822 Message-ID is never mutation authority on this branch, so
  # the rfc822-keyed `PendingOperation` decision is preserved as superseded, never deleted.
  "026B" => "superseded",
  "057" => "superseded",
  "059" => "superseded",
  "063" => "deferred"
}.freeze

DECISION_NOTES = {
  "032" => "Partially superseded by 034; Swift stack retained, session-document model replaced",
  "018" => "Active core; queue mechanics amended by 060",
  "024" => "Active confirmation contract; delivery amended by 053",
  "026B" => "Superseded on v3 by the native-provider-id keying rule (D4); preserved for history",
  "030" => "Active compose FIFO; delivery amended by 053",
  "049" => "Active instant-insert path; display compensation amended by 055",
  "057" => "Superseded queue mechanics; replaced by 060",
  "058" => "Active retained invariants; partially superseded by 060",
  "063" => "Deferred follow-up; recorded but not implemented",
  "064" => "Active withdrawal record"
}.freeze

# ADR bodies that exist only on the mature pre-v3 line and are therefore absent from
# `v1.6.38:DECISIONS.md`. v3 forward-ports that work, and live v3 plans route to these exact
# paths, so the bodies are ported byte-for-byte from `PORTED_SOURCE_REV` and recorded in
# `ported-manifest.tsv` instead of being regenerated. They are deliberately excluded from the
# source-document ADR census, which reconstructs `#{SOURCE_REV}:DECISIONS.md` exactly.
PORTED_SOURCE_REV = ENV.fetch("COMPANION_PORTED_SOURCE_REV", "e28dd4edb33cfb77a0d069de48e136f6ad92cd0c")
PORTED_DECISION_PATHS = [
  "Companion/Decisions/Active/adr-ios-058.md",
  "Companion/Decisions/Superseded/adr-ios-059.md",
  "Companion/Decisions/Active/adr-ios-060.md",
  "Companion/Decisions/Active/adr-ios-061.md",
  "Companion/Decisions/Deferred/adr-ios-063.md",
  "Companion/Decisions/Active/adr-ios-064.md",
  "Companion/Decisions/Active/adr-ios-065.md",
  "Companion/Decisions/Active/adr-ios-066.md",
  "Companion/Decisions/Active/adr-ios-067.md"
].freeze

def port_decisions
  rows = ["source_rev\tstatus\tsha256\tpath\tid\ttitle"]
  PORTED_DECISION_PATHS.each do |relative_path|
    body = git_show_rev(PORTED_SOURCE_REV, relative_path)
    match = exact_body(body).match(/^## (ADR-IOS-\d+[A-Z]?)(?::|\s+[—-])\s*(.*)$/)
    abort("ported body has no ADR heading: #{relative_path}") unless match

    status = { "Active" => "active", "Superseded" => "superseded", "Deferred" => "deferred" }
      .fetch(File.basename(File.dirname(relative_path)))
    write_exact(relative_path, body)
    rows << [PORTED_SOURCE_REV, status, Digest::SHA256.hexdigest(body), relative_path, match[1], match[2].strip].join("\t")
  end
  write_exact(PORTED_MANIFEST, rows.join("\n") + "\n")
  puts "ported #{PORTED_DECISION_PATHS.length} pre-v3 ADR bodies from #{PORTED_SOURCE_REV}"
end

def ported_decisions
  path = File.join(ROOT, PORTED_MANIFEST)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).drop(1).map do |row|
    source_rev, status, sha256, relative_path, id, title = row.split("\t", 6)
    { source_rev: source_rev, status: status, sha256: sha256, path: relative_path, id: id, title: title }
  end
end

def generate_decisions
  source_lines = lines_for("DECISIONS.md")
  adr_headings = source_lines.each_index.each_with_object([]) do |index, result|
    match = source_lines[index].match(/^## (ADR-IOS-(\d+[A-Z]?))(?::|\s+[—-])\s*(.*)$/)
    next unless match

    result << [index + 1, match[1], match[2], match[3].strip]
  end
  routes = route_ids(adr_headings.map { |item| item[1] })
  template_heading = source_lines.index { |line| line.start_with?("## Template for New Decisions") } + 1
  section_starts = (adr_headings.map(&:first) + [template_heading]).to_h do |heading_line|
    [heading_line, section_start(source_lines, heading_line)]
  end
  boundaries = section_starts.values.sort + [source_lines.length + 1]
  used = []
  fragments = []
  fragments << fragment(
    "Companion/Decisions/foundational-principle.md",
    1,
    section_starts.fetch(adr_headings.first.first) - 1,
    "Foundational principle: never drop user intention",
    "active",
    source_lines
  )

  adr_headings.each_with_index do |(heading_line, _full_id, _short_id, title), position|
    route_full_id = routes.fetch(position)
    route_short_id = route_full_id.delete_prefix("ADR-IOS-")
    start_line = section_starts.fetch(heading_line)
    end_line = boundaries.find { |line| line > start_line } - 1
    status = DECISION_STATUSES.fetch(route_short_id, "active")
    directory = case status
                when "superseded" then "Companion/Decisions/Superseded"
                when "deferred" then "Companion/Decisions/Deferred"
                else "Companion/Decisions/Active"
                end
    relative_path = File.join(directory, "#{route_full_id.downcase}.md")
    abort("duplicate path #{relative_path}") if used.include?(relative_path)

    used << relative_path
    fragments << fragment(relative_path, start_line, end_line, "#{route_full_id}: #{title}", status, source_lines).merge(
      id: route_full_id,
      short_id: route_short_id,
      decision_title: title
    )
  end

  template_start = section_starts.fetch(template_heading)
  template_end = boundaries.find { |line| line > template_start } - 1
  fragments << fragment(
    "Companion/Decisions/Templates/new-decision-template.md",
    template_start,
    template_end,
    "Template for new decisions",
    "template",
    source_lines
  )
  fragments.sort_by! { |item| item[:start_line] }

  manifest = ["order\tstatus\tsource_lines\tsha256\tpath\ttitle"]
  fragments.each_with_index do |item, index|
    manifest << [
      index,
      item[:status],
      "#{item[:start_line]}-#{item[:end_line]}",
      item[:sha256],
      item[:path],
      item[:title]
    ].join("\t")
  end
  write_exact("Companion/Decisions/manifest.tsv", manifest.join("\n") + "\n")

  adrs = fragments.select { |item| item[:id] }
  index = +<<~MARKDOWN
    # TabMail iOS - Active Decision Index

    > **Mandatory ADR router.** Always read this compact catalog before iOS work. Every ADR body is preserved under `Companion/Decisions/`; mechanically search and read all matching ADRs in full before proposing or implementing behavior. For cross-cutting decisions, also read `../DECISIONS.md`.

    **Compacted from:** `#{SOURCE_REV}:DECISIONS.md` without semantic rewriting. The ordered extraction manifest and hashes are in [`Companion/Decisions/manifest.tsv`](Companion/Decisions/manifest.tsv).

    ## Always load-bearing decision law

    - **Never drop user intention.** Persist before acknowledging; execute durably; remove queued work only after confirmed success, a provably stale/no-op result, or annihilation by a newer exact inverse user action.
    - **Remote state wins on genuine conflict**, but absence or a transient read failure is not proof that the user's intent is stale.
    - **Treat all instances equally.** Local and remote TabMail actions participate in the same state model.
    - **Never silently discard user work.** Failed work remains visible or retryable unless completion or staleness is proven.
    - Read the exact preserved wording in [`Foundational principle`](Companion/Decisions/foundational-principle.md) whenever the task touches queues, optimistic UI, retries, reconciliation, Undo, Outbox, drafts, or notifications.

    ## Required routing

    1. Search this index and the complete `Companion/` hierarchy with task concepts, subsystem names, symbols, providers, invariants, and every ADR identifier found in code or plans.
    2. Read every matched ADR, memory, process, and rule file completely before acting; follow related documents when they govern the same invariant.
    3. Current entries govern. `Superseded` and `Deferred` entries are evidence and constraints, not current implementation authority.
    4. Plans, implementation briefs, and review prompts must enumerate every exact routed path required for their scope.
    5. New or amended decisions update one detailed ADR file and its catalog row. Keep this mandatory index compact.

    ## ADR catalog

    The decision title is also the keyword set for routing. Status notes call out partial amendments that a directory name alone cannot express.

    | ADR | Status | Decision / keywords | Detail |
    |---|---|---|---|
  MARKDOWN
  adrs.each do |item|
    note = DECISION_NOTES.fetch(item[:short_id], item[:status].capitalize)
    index << "| #{item[:id]} | #{note.gsub("|", "\\|")} | #{item[:decision_title].gsub("|", "\\|")} | #{markdown_link(item, "read in full")} |\n"
  end

  ported = ported_decisions
  unless ported.empty?
    index << <<~MARKDOWN

      ## Forward-ported decisions absent from the shipped source

      These ADR bodies exist only on the mature pre-v3 line and are therefore not in `#{SOURCE_REV}:DECISIONS.md`. v3 forward-ports that work, so the bodies are preserved byte-for-byte with their provenance in [`Companion/Decisions/ported-manifest.tsv`](Companion/Decisions/ported-manifest.tsv). They are excluded from the source-document reconstruction manifest and census.

      | ADR | Status | Decision / keywords | Detail |
      |---|---|---|---|
    MARKDOWN
    ported.each do |item|
      note = DECISION_NOTES.fetch(item[:id].delete_prefix("ADR-IOS-"), item[:status].capitalize)
      index << "| #{item[:id]} | #{note.gsub("|", "\\|")} | #{item[:title].gsub("|", "\\|")} | [read in full](#{item[:path]}) |\n"
    end
  end

  index << <<~MARKDOWN

    ## Numbering and non-ADR material

    - Unused/reserved numeric slots: 033, 035, and 048. Slot 048 was intentionally skipped after a reverted prototype; its history is preserved in the 049 detail.
    - `#{SOURCE_REV}:DECISIONS.md` defines `ADR-IOS-026` twice. The second definition (`PendingOperation Uses Stable IDs (rfc822MessageId)`) routes as **ADR-IOS-026B**, preserving the reference renumbering and the v3 working-tree heading.
    - [`New-decision template`](Companion/Decisions/Templates/new-decision-template.md) is preserved source material and is excluded from the ADR census.
  MARKDOWN

  write_exact("DECISIONS.md", index)
  note_fragment_titled(
    fragments,
    "ADR-IOS-018: Persistent Offline Action Queue",
    "The preserved RFC-identity amendment below was itself amended by ADR-IOS-060's hybrid-identity decision: current cold full-local-miss notification admission may retain a scoped transport-ID token member. Read ADR-IOS-060 before applying ADR-IOS-018 to notification routing."
  )
  note_fragment_titled(
    fragments,
    "ADR-IOS-026B: PendingOperation Uses Stable IDs (rfc822MessageId)",
    "**Superseded on v3.** Durable operations key by the native provider id: IMAP `(UIDVALIDITY, UID)`, Gmail/Graph `message.id`. RFC 822 Message-ID is never mutation authority on this branch. Preserved as evidence for the identity history; do not implement from it. (Routing notes are ASCII-only: the wrapper is prepended to a byte-preserved fragment.)"
  )
  fragments
end

def write_readme(memory_fragments, decision_fragments)
  ported = ported_decisions
  body = <<~MARKDOWN
    # iOS Companion Document Hierarchy

    The mandatory root files `CLAUDE.md`, `PROJECT_MEMORY.md`, and `DECISIONS.md` are compact routing indexes. Detailed source material lives here and remains mechanically searchable with `rg`.

    ## Preservation record

    - Source revision: `#{SOURCE_REV}`
    - Original `PROJECT_MEMORY.md`: #{git_show("PROJECT_MEMORY.md").lines.length} lines, #{git_show("PROJECT_MEMORY.md").bytesize} bytes
    - Original `DECISIONS.md`: #{git_show("DECISIONS.md").lines.length} lines, #{git_show("DECISIONS.md").bytesize} bytes
    - Memory fragments: #{memory_fragments.length}
    - Decision fragments (including foundation and template): #{decision_fragments.length}
    - Forward-ported decision bodies absent from `#{SOURCE_REV}`: #{ported.length} (see `Companion/Decisions/ported-manifest.tsv`)
    - Forward-ported memory topics absent from `#{SOURCE_REV}`: #{ported_memory.length} (see `Companion/Memory/ported-manifest.tsv`)

    `Scripts/compact_companion_docs.rb verify` reconstructs both source documents in original order from the manifests, verifies every fragment hash, checks ADR-definition/index uniqueness, confirms every detailed memory topic is linked, validates local Markdown links, and checks every repository `Companion/…md` pointer. The explicitly delimited current-routing notes in three detail files are index wrappers: verification removes only those wrappers before comparing the preserved source bodies. The forward-ported ADR bodies are hash-verified against `ported-manifest.tsv` and excluded from the source-document census, because they are not part of `#{SOURCE_REV}:DECISIONS.md`. The process/rule hierarchy is generated and byte-verified separately by `Scripts/compact_ios_rules.rb`.

    ## Maintenance

    Search the mandatory indexes and the complete hierarchy before acting. Read every matched topic, ADR, process, or rule in full. Preserve stable ADR identifiers. Put superseded or historical material in its routed directory rather than deleting it. Do not move the same material into unconditional rule files or Markdown imports.

    `generate` is the one-time, revision-pinned extraction command for this compaction and destructively rebuilds `Companion/` from `#{SOURCE_REV}`. Do not run it after the compaction lands. `verify` is the landing proof against that source revision, not a permanent ban on later documented amendments; future knowledge updates edit the routed detail and compact index normally.
  MARKDOWN
  write_exact("Companion/README.md", body)
end

def verify_manifest(source_path, manifest_path)
  source = git_show(source_path).b
  rows = File.readlines(File.join(ROOT, manifest_path), chomp: true).drop(1)
  reconstructed = +""
  rows.each do |row|
    _order, _status, source_lines, expected_sha, relative_path, _title = row.split("\t", 6)
    body = File.binread(File.join(ROOT, relative_path))
    preserved_body = exact_body(body)
    actual_sha = Digest::SHA256.hexdigest(preserved_body)
    abort("hash mismatch: #{relative_path}") unless actual_sha == expected_sha

    start_line, end_line = source_lines.split("-").map(&:to_i)
    expected = source.lines[(start_line - 1)..(end_line - 1)].join
    abort("source-range mismatch: #{relative_path}") unless preserved_body == expected

    reconstructed << preserved_body
  end
  abort("reconstruction mismatch: #{source_path}") unless reconstructed == source

  puts "reconstructed #{source_path}: #{source.lines.length} lines, #{source.bytesize} bytes, byte-identical"
end

def verify_ported_decisions
  ported = ported_decisions
  return puts("ported decisions: none recorded") if ported.empty?

  index = File.read(File.join(ROOT, "DECISIONS.md"))
  ported.each do |item|
    body = File.binread(File.join(ROOT, item[:path]))
    abort("ported decision hash mismatch: #{item[:path]}") unless Digest::SHA256.hexdigest(body) == item[:sha256]

    body_ids = exact_body(body).scan(/^## (ADR-IOS-\d+[A-Z]?)/).flatten
    abort("ported decision does not define #{item[:id]}: #{item[:path]}") unless body_ids == [item[:id]]

    expected_directory = { "active" => "Active", "superseded" => "Superseded", "deferred" => "Deferred" }.fetch(item[:status])
    actual_directory = File.basename(File.dirname(item[:path]))
    abort("ported decision status differs from route for #{item[:id]}: #{item[:path]}") unless actual_directory == expected_directory

    abort("ported decision is not linked exactly once: #{item[:path]}") unless index.scan("(#{item[:path]})").length == 1
  end
  abort("ported decision IDs are not unique") unless ported.map { |item| item[:id] }.uniq.length == ported.length

  puts "ported decisions: #{ported.length} forward-ported ADR bodies hash-verified, routed by status, and linked once"
end

def verify_adr_census
  source_ids = git_show("DECISIONS.md").scan(/^## (ADR-IOS-\d+[A-Z]?)/).flatten
  source_route_ids = route_ids(source_ids)
  ported_paths = ported_decisions.map { |item| File.join(ROOT, item[:path]) }
  detail_ids = (Dir.glob(File.join(COMPANION_ROOT, "Decisions", "{Active,Superseded,Deferred}", "*.md")) - ported_paths)
    .flat_map { |path| File.read(path).scan(/^## (ADR-IOS-\d+[A-Z]?)/).flatten }
  index = File.read(File.join(ROOT, "DECISIONS.md"))
  index_ids = index.scan(/^\| (ADR-IOS-\d+[A-Z]?) \|/).flatten - ported_decisions.map { |item| item[:id] }
  abort("source ADR route identifiers are not unique") unless source_route_ids.uniq.length == source_route_ids.length
  abort("detail ADR census differs from source") unless detail_ids.sort == source_ids.sort
  abort("index ADR census differs from source") unless index_ids.sort == source_route_ids.sort

  manifest_pairs = File.readlines(File.join(ROOT, "Companion/Decisions/manifest.tsv"), chomp: true).drop(1).map do |row|
    _order, status, _source_lines, _sha, path, title = row.split("\t", 6)
    route_id = title[/\A(ADR-IOS-\d+[A-Z]?):/, 1]
    next unless route_id

    position = source_route_ids.index(route_id)
    abort("ADR manifest route #{route_id} is not a source route identifier") unless position

    body_ids = exact_body(File.binread(File.join(ROOT, path))).scan(/^## (ADR-IOS-\d+[A-Z]?)/).flatten
    abort("ADR manifest route does not define #{source_ids.fetch(position)}: #{path}") unless body_ids == [source_ids.fetch(position)]

    short_id = route_id.delete_prefix("ADR-IOS-")
    expected_status = DECISION_STATUSES.fetch(short_id, "active")
    abort("ADR manifest status differs from decision status for #{route_id}") unless status == expected_status

    expected_directory = { "active" => "Active", "superseded" => "Superseded", "deferred" => "Deferred" }.fetch(status)
    actual_directory = File.basename(File.dirname(path))
    abort("ADR manifest status differs from route for #{route_id}: #{path}") unless actual_directory == expected_directory

    [route_id, path]
  end.compact
  abort("ADR manifest IDs are not unique") unless manifest_pairs.map(&:first).uniq.length == manifest_pairs.length
  manifest_routes = manifest_pairs.to_h
  index_routes = index.scan(/^\| (ADR-IOS-\d+[A-Z]?) \|.*\| \[read in full\]\(([^)]+)\) \|$/).to_h
  ported_decisions.each { |item| index_routes.delete(item[:id]) }
  abort("ADR index routes differ from manifest") unless index_routes == manifest_routes
  abort("ADR manifest routes are not unique") unless manifest_routes.values.uniq.length == manifest_routes.length

  puts "ADR census: #{source_ids.length} source definitions (#{source_route_ids.uniq.length} unique routes), each once in detail and once in index, with exact manifest routes"
end

def verify_memory_links
  index = File.read(File.join(ROOT, "PROJECT_MEMORY.md"))
  rows = File.readlines(File.join(ROOT, "Companion/Memory/manifest.tsv"), chomp: true).drop(1).map do |row|
    _order, status, _source_lines, _sha, path, title = row.split("\t", 6)
    body = exact_body(File.binread(File.join(ROOT, path)))
    body_title = body[/^\#{2,3}\s+(.+)$/, 1]&.strip
    abort("memory manifest title differs from routed heading: #{path}") if body_title && body_title != title.b

    expected_directory = { "current" => "Current", "historical" => "History" }.fetch(status)
    actual_directory = File.basename(File.dirname(path))
    abort("memory manifest status differs from route: #{path}") unless actual_directory == expected_directory

    escaped_title = title.gsub("|", "\\|")
    expected_row = if status == "historical"
                     "| Historical | #{escaped_title} | [read in full](#{path}) |"
                   else
                     "| #{escaped_title} | [read in full](#{path}) |"
                   end
    abort("memory index route differs from manifest: #{path}") unless index.lines.count { |line| line.chomp == expected_row } == 1

    path
  end

  puts "memory routing: #{rows.length} detailed fragments, each title bound to exactly one manifest route and index row"
end

def verify_markdown_links
  markdown_files = [
    File.join(ROOT, "CLAUDE.md"),
    File.join(ROOT, "PROJECT_STRUCTURE.md"),
    File.join(ROOT, "PROJECT_MEMORY.md"),
    File.join(ROOT, "DECISIONS.md"),
    *Dir.glob(File.join(COMPANION_ROOT, "**", "*.md"))
  ]
  broken = []
  markdown_files.each do |path|
    body = File.read(path)
      .gsub(/^```.*?^```\s*$/m, "")
      .gsub(/`[^`\n]+`/, "")
    body.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |target|
      next if target.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|#)}i)

      relative = target.split("#", 2).first.gsub("%20", " ")
      next if relative.empty?

      resolved = File.expand_path(relative, File.dirname(path))
      broken << "#{path.delete_prefix(ROOT + "/")}: #{target}" unless File.exist?(resolved)
    end
  end
  abort("broken Markdown links:\n#{broken.join("\n")}") unless broken.empty?

  puts "Markdown links: all #{markdown_files.length} mandatory/hierarchy files checked, no missing local targets"
end

def verify_repository_companion_references
  output, status = Open3.capture2("git", "ls-files", "--cached", "--others", "--exclude-standard", chdir: ROOT)
  abort("git ls-files failed") unless status.success?

  missing = []
  checked = 0
  plan_paths = Dir.glob(File.join(ROOT, "PLAN_*.md")).map { |path| path.delete_prefix(ROOT + "/") }
  (output.lines(chomp: true) + plan_paths).uniq.each do |relative_path|
    path = File.join(ROOT, relative_path)
    next unless File.file?(path)
    next unless relative_path.match?(/\.(?:md|swift|html|rb|sh|ya?ml)\z/)

    body = File.binread(path)
    # A `../Companion/…` reference names the MONOREPO-ROOT companion tree, not this subproject's.
    # Matching from `Companion/` onwards discarded that prefix and resolved every such pointer
    # against ROOT, so a CORRECT root-tree reference was reported broken and aborted the whole
    # verifier (MIS-IOS-009 records this against the mistake file that hit it first). Honour the
    # prefix and resolve against the parent directory instead.
    body.scan(%r{(?:\.\./)?Companion/(?:Memory|Decisions|Process|Rules|Mistakes)/[^\s`'"\])>]+\.md}).uniq.each do |target|
      checked += 1
      base = target.start_with?("../") ? File.dirname(ROOT) : ROOT
      missing << "#{relative_path}: #{target}" unless File.file?(File.join(base, target.delete_prefix("../")))
    end
  end
  abort("broken repository companion references:\n#{missing.join("\n")}") unless missing.empty?

  puts "repository companion references: #{checked} routed pointers checked, all targets exist"
end

# Per-file budgets in BYTES for the mandatory-load files. These are the same numbers as
# `.claude/skills/companion-compact/measure.sh`; that script lives outside this repository, so the
# budgets are duplicated here deliberately and `verify_indexes_are_indexes` runs it when present.
INDEX_BUDGETS = {
  "CLAUDE.md" => 30_000,
  "PROJECT_STRUCTURE.md" => 8_000,
  "PROJECT_MEMORY.md" => 25_000,
  "DECISIONS.md" => 25_000,
  "MISTAKES.md" => 12_000
}.freeze
INDEX_SCOPE_BUDGET = 100_000
# A routed body at least this large, found verbatim in a mandatory-load file, is an un-routed
# duplicate. Shorter fragments (a bare section heading, a two-line table) can legitimately appear
# in both the index and its routed detail.
INLINE_DUPLICATE_MIN_BYTES = 1_000
MEASURE_SCRIPT = "../.claude/skills/companion-compact/measure.sh"

# The failure this check exists for: the `v1.6.38` compaction extracted every fragment into
# `Companion/` but never replaced the mandatory-load files with indexes, so both copies existed for
# two months. `verify` could not see it: it reconstructs fragments against `SOURCE_REV` and never
# looks at the working-tree index. This check looks at the working tree.
def verify_indexes_are_indexes
  violations = []
  indexes = {}
  scope_bytes = 0
  INDEX_BUDGETS.each do |name, budget|
    path = File.join(ROOT, name)
    next unless File.exist?(path)

    body = File.binread(path)
    indexes[name] = body
    scope_bytes += body.bytesize
    next unless body.bytesize > budget

    violations << format(
      "%s is %d B, over its %d B budget by %d%%",
      name, body.bytesize, budget, (body.bytesize - budget) * 100 / budget
    )
  end
  if scope_bytes > INDEX_SCOPE_BUDGET
    violations << format("scope total is %d B, over the %d B budget", scope_bytes, INDEX_SCOPE_BUDGET)
  end

  duplicates = 0
  Dir.glob(File.join(COMPANION_ROOT, "**", "*.md")).sort.each do |fragment_path|
    body = exact_body(File.binread(fragment_path))
    next if body.bytesize < INLINE_DUPLICATE_MIN_BYTES

    relative = fragment_path.delete_prefix(ROOT + "/")
    indexes.each do |name, index_body|
      next unless index_body.include?(body)

      duplicates += 1
      violations << "#{name} holds the verbatim body of #{relative} (#{body.bytesize} B): route it and leave a linked index row"
    end
  end

  measure = File.expand_path(MEASURE_SCRIPT, ROOT)
  if File.executable?(measure)
    output, = Open3.capture2e(measure, File.basename(ROOT), chdir: File.dirname(ROOT))
    output.lines.grep(/OVER|VERDICT|scope total|\[scope total\]/).each { |line| puts "  measure.sh | #{line.rstrip}" }
  else
    puts "  measure.sh | not present at #{MEASURE_SCRIPT} (private tooling); budgets checked natively"
  end

  unless violations.empty?
    abort("mandatory-load files are not indexes (#{duplicates} un-routed duplicate bodies):\n- #{violations.join("\n- ")}")
  end

  puts "index discipline: #{indexes.length} mandatory-load files within budget (#{scope_bytes} B total), no routed body duplicated inline"
end

command = ARGV.fetch(0, "verify")
case command
when "generate"
  if File.exist?(File.join(COMPANION_ROOT, "Rules", "manifest.tsv"))
    abort("refusing to remove the landed process/rule hierarchy; the revision-pinned generation phase is closed")
  end
  if Dir.exist?(COMPANION_ROOT) && ENV["FORCE_COMPANION_REGEN"] != "1"
    abort("refusing to replace existing Companion/; set FORCE_COMPANION_REGEN=1 only for the one-time revision-pinned rebuild")
  end
  FileUtils.rm_rf(COMPANION_ROOT)
  port_memory
  memory_fragments = generate_memory
  port_decisions
  decision_fragments = generate_decisions
  write_readme(memory_fragments, decision_fragments)
  puts "generated #{memory_fragments.length} memory fragments and #{decision_fragments.length} decision fragments"
when "verify"
  verify_manifest("PROJECT_MEMORY.md", "Companion/Memory/manifest.tsv")
  verify_manifest("DECISIONS.md", "Companion/Decisions/manifest.tsv")
  verify_adr_census
  verify_ported_decisions
  verify_memory_links
  verify_ported_memory
  verify_markdown_links
  verify_repository_companion_references
  verify_indexes_are_indexes
when "verify-indexes"
  verify_indexes_are_indexes
else
  abort("usage: #{File.basename($PROGRAM_NAME)} [generate|verify|verify-indexes]")
end
