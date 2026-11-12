/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// The calendar oracle generator (ADR-IOS-110). Run through generate.sh, never directly: that
// script checks the tool versions, builds libical-expand and fetches the hash-pinned ical.js.
//
//   node generate.mjs <work dir holding libical-expand and Ical.sys.mjs> <fixtures dir>
//
// For every case in cases.json it builds the calendar text, expands it with libical and with
// Thunderbird's ical.js, checks both engines' UTC offsets against Node's own zone data, compares
// the two normalized occurrence lists, and writes one fixture file per family plus a manifest.
// A disagreement needs a written decision in resolutions.json, or the run fails.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const [workDir, fixturesDir] = process.argv.slice(2);
if (!workDir || !fixturesDir || !process.env.CAL_ORACLE_SYSTEM_TZDATA) {
  throw new Error('usage: generate.sh runs node generate.mjs <work dir> <fixtures dir> with CAL_ORACLE_SYSTEM_TZDATA set');
}

const lock = readJSON(path.join(here, 'oracle-lock.json'));
const corpus = readJSON(path.join(here, 'cases.json'));
const resolutions = readJSON(path.join(here, 'resolutions.json'));
const ICAL = (await import(path.join(workDir, 'Ical.sys.mjs'))).default;
const libicalExpand = path.join(workDir, 'libical-expand');

const Config = {
  // Seconds either side of a window the engines expand, so an occurrence that starts before
  // the window and overlaps it, or a changed one near its edge, is seen by both.
  expansionMargin: 3 * 24 * 60 * 60,
  // A floating or all-day occurrence is compared as a wall time. Every window edge must be at
  // least this far from such an occurrence's start and end, so a device in any zone lists the
  // same set (UTC-12 to UTC+14 is 26 h).
  floatingEdgeMargin: 26 * 60 * 60,
  // The most occurrences ical.js may give one case: a guard against a runaway rule.
  maxIterations: 100000,
  // How many differing occurrences of each engine a disagreement prints.
  diffLines: 8,
};

const SECONDS_PER_DAY = 24 * 60 * 60;

// MARK: - Inputs

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function fail(id, message) {
  throw new Error(`${id}: ${message}`);
}

function epochOf(iso) {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms) || !iso.endsWith('Z')) throw new Error(`not a UTC instant: ${iso}`);
  return ms / 1000;
}

// MARK: - Calendar text

const vtimezoneCache = new Map();

/** libical's VTIMEZONE for an IANA zone, TZID rewritten to the bare name, X-LIC-LOCATION kept. */
function vtimezone(zone) {
  if (!vtimezoneCache.has(zone)) {
    const text = execFileSync(libicalExpand, ['vtimezone', zone], { encoding: 'utf8' });
    const lines = text.split(/\r?\n/).filter((line) => line.length > 0)
      .map((line) => (line.startsWith('TZID:') ? `TZID:${zone}` : line));
    vtimezoneCache.set(zone, lines);
  }
  return vtimezoneCache.get(zone);
}

/** The case's calendar: its own text, or a VCALENDAR built from its VEVENT lines. */
function calendarText(c) {
  if (c.ics) return c.ics.join('\r\n') + '\r\n';
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//example.com//TabMail calendar oracle//EN'];
  for (const zone of c.zones ?? []) lines.push(...vtimezone(zone));
  const uid = `${c.id.replace(/[^A-Za-z0-9]+/g, '-')}@example.com`;
  const vevent = (body) => ['BEGIN:VEVENT', `UID:${uid}`, 'DTSTAMP:20200101T000000Z', ...body, 'END:VEVENT'];
  lines.push(...vevent([`SUMMARY:${c.id}`, ...c.master]));
  for (const override of c.overrides ?? []) lines.push(...vevent([`SUMMARY:${c.id} changed`, ...override]));
  lines.push('END:VCALENDAR');
  return lines.join('\r\n') + '\r\n';
}

// MARK: - Normal form

const pad = (n, width = 2) => String(n).padStart(width, '0');

function wallOfEpoch(seconds) {
  const d = new Date(seconds * 1000);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
}

const utcText = (seconds) => `${wallOfEpoch(seconds)}Z`;
const compact = (text) => text.replace(/[-:]/g, '');

/** Node's own zone data (ICU), the third witness: the UTC offset of `zone` at an instant. */
function intlOffset(zone, seconds) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(seconds * 1000));
  const get = (type) => Number(parts.find((p) => p.type === type).value);
  const wall = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second')) / 1000;
  return wall - seconds;
}

/**
 * One occurrence in the fixtures' normal form. `start`/`end`/`slot` are epoch seconds: the
 * instant for a zoned or UTC series, the wall time read as UTC for a floating or all-day one.
 */
function normalize(frame, { slot, start, end, status, offset }) {
  const occurrence = { status, moved: start !== slot };
  switch (frame.kind) {
    case 'allDay':
      occurrence.key = compact(wallOfEpoch(slot).slice(0, 10));
      occurrence.start = wallOfEpoch(start).slice(0, 10);
      occurrence.end = wallOfEpoch(end).slice(0, 10);
      break;
    case 'floating':
      occurrence.key = compact(wallOfEpoch(slot));
      occurrence.start = wallOfEpoch(start);
      occurrence.end = wallOfEpoch(end);
      break;
    default:
      occurrence.key = compact(utcText(slot));
      occurrence.start = utcText(start);
      occurrence.end = utcText(end);
      occurrence.wall = wallOfEpoch(start + (frame.kind === 'zoned' ? offset : 0));
      if (frame.kind === 'zoned') occurrence.offset = offset;
  }
  return occurrence;
}

function frameOf(text) {
  if (text === 'allDay' || text === 'floating' || text === 'utc') return { kind: text };
  if (text.startsWith('zoned:')) return { kind: 'zoned', zone: text.slice('zoned:'.length) };
  throw new Error(`unknown frame ${text}`);
}

const frameText = (frame) => (frame.kind === 'zoned' ? `zoned:${frame.zone}` : frame.kind);

/** Whether Node's zone data has an instant whose wall time in `zone` is `wall`. */
function wallExists(zone, wall) {
  const naive = epochOf(`${wall}Z`);
  return [-SECONDS_PER_DAY, SECONDS_PER_DAY].some((shift) => {
    const instant = naive - intlOffset(zone, naive + shift);
    return wallOfEpoch(instant + intlOffset(zone, instant)) === wall;
  });
}

// MARK: - The window

/** RFC 4791 §9.9: an occurrence with a length overlaps when it starts before the window ends and
 * ends after it starts; one with no length, when it starts in the window. */
function overlaps(occ, from, to) {
  if (occ.end > occ.start) return occ.start < to && occ.end > from;
  return occ.start >= from && occ.start < to;
}

function checkFloatingMargin(id, frame, raw, from, to) {
  if (frame.kind !== 'allDay' && frame.kind !== 'floating') return;
  for (const occ of raw) {
    for (const edge of [occ.start, occ.end]) {
      for (const bound of [from, to]) {
        if (Math.abs(edge - bound) < Config.floatingEdgeMargin) {
          fail(id, `a ${frame.kind} occurrence edge ${wallOfEpoch(edge)} is within 26 h of the window edge ${utcText(bound)}`);
        }
      }
    }
  }
}

// MARK: - libical

function libicalSide(c, ics, from, to, through) {
  const out = execFileSync(libicalExpand, [
    'expand', String(from - Config.expansionMargin), String(to + Config.expansionMargin), through.replace(/-/g, ''),
  ], { input: ics, encoding: 'utf8' });
  const lines = out.split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const frame = frameOf(lines.find((l) => l.t === 'frame').frame);

  // libical leaves RECURRENCE-ID to its caller: an override replaces the occurrence its
  // RECURRENCE-ID names, and is listed at its own time (the override's offset is libical's
  // reading of the series zone at that time, which the zone witness checks).
  const raw = lines.filter((l) => l.t === 'occ').map((l) => ({
    slot: l.start, slotDay: slotDayOf(frame, l.start), start: l.start, end: l.end, status: 'confirmed', offset: l.offset ?? 0,
  }));
  const keyOfSlot = (slot) => normalize(frame, { slot, start: slot, end: slot, status: '', offset: 0 }).key;
  for (const o of lines.filter((l) => l.t === 'override')) {
    const index = raw.findIndex((occ) => keyOfSlot(occ.slot) === keyOfSlot(o.rid));
    if (index < 0) continue; // names no occurrence of the series
    raw.splice(index, 1, { ...raw[index], start: o.start, end: o.end, status: o.status, offset: o.offset ?? 0 });
  }
  const ruleDays = lines.filter((l) => l.t === 'ruleDay').map((l) => l.day);
  const ruleDaysUnsupported = lines.some((l) => l.t === 'ruleDaysUnsupported');
  return { frame, raw, ruleDays: ruleDaysUnsupported ? null : ruleDays };
}

// MARK: - ical.js

function icaljsFrame(time) {
  if (time.isDate) return { kind: 'allDay' };
  if (time.zone === ICAL.Timezone.utcTimezone) return { kind: 'utc' };
  if (!time.zone || time.zone === ICAL.Timezone.localTimezone) return { kind: 'floating' };
  return { kind: 'zoned', zone: time.zone.tzid };
}

/** An ical.js time as epoch seconds: the instant, or the wall time read as UTC. */
function icaljsSeconds(time, frame) {
  if (frame.kind === 'allDay' || frame.kind === 'floating') {
    return Date.UTC(time.year, time.month - 1, time.day, time.hour, time.minute, time.second) / 1000;
  }
  return time.toUnixTime();
}

/** What the zone witness checks of an ical.js start: its own wall time in its own zone, which
 * Node's zone data must place at the same instant (null for a UTC, floating or all-day start). */
function icaljsWitness(time) {
  if (time.isDate || !time.zone || time.zone === ICAL.Timezone.utcTimezone || time.zone === ICAL.Timezone.localTimezone) {
    return null;
  }
  return { zone: time.zone.tzid, wall: `${time.year}-${pad(time.month)}-${pad(time.day)}T${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}` };
}

/** The case's series as an ical.js event, with its changed occurrences and its zones registered. */
function icaljsEvent(ics) {
  const calendar = new ICAL.Component(ICAL.parse(ics));
  for (const tz of calendar.getAllSubcomponents('vtimezone')) ICAL.TimezoneService.register(tz);
  const vevents = calendar.getAllSubcomponents('vevent');
  const master = vevents.find((v) => !v.hasProperty('recurrence-id'));
  return { master, event: new ICAL.Event(master, { exceptions: vevents.filter((v) => v !== master) }) };
}

function icaljsSide(c, ics, from, to, through) {
  const { master, event } = icaljsEvent(ics);
  const frame = icaljsFrame(event.startDate);
  const zone = frame.kind === 'zoned' ? ICAL.TimezoneService.get(frame.zone) : null;

  const raw = [];
  const iterator = event.iterator();
  for (let n = 0, next = iterator.next(); next; next = iterator.next()) {
    if (++n > Config.maxIterations) fail(c.id, 'ical.js passed the iteration guard');
    const slot = icaljsSeconds(next, frame);
    if (slot > to + Config.expansionMargin) break;
    const details = event.getOccurrenceDetails(next);
    const start = icaljsSeconds(details.startDate, frame);
    const end = icaljsSeconds(details.endDate, frame);
    if (end < from - Config.expansionMargin) continue;
    const status = details.item.component.getFirstPropertyValue('status') === 'CANCELLED' ? 'cancelled' : 'confirmed';
    // The slot's day is the recurrence id's own wall date: ical.js may place a wall time a
    // change skips at another instant, but it names the day the rule gave.
    const slotDay = `${next.year}-${pad(next.month)}-${pad(next.day)}`;
    raw.push({
      slot, slotDay, start, end, status, witness: icaljsWitness(details.startDate),
      offset: zone ? intlOffset(frame.zone, start) : 0,
    });
  }

  let ruleDays = null;
  const rrule = master.getFirstPropertyValue('rrule');
  if (rrule) {
    ruleDays = [];
    const it = rrule.iterator(event.startDate);
    for (let next = it.next(); next; next = it.next()) {
      const day = `${next.year}-${pad(next.month)}-${pad(next.day)}`;
      if (day > through) break;
      if (ruleDays.length >= Config.maxIterations) fail(c.id, 'ical.js rule days passed the guard');
      ruleDays.push(day);
    }
  }
  const start = event.startDate;
  return { frame, raw, ruleDays, dtstartDay: `${start.year}-${pad(start.month)}-${pad(start.day)}` };
}

// MARK: - Comparison

const sortOccurrences = (list) => [...list].sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

/** The day a libical slot falls on in the series' frame (`yyyy-MM-dd`), read through Node's zone
 * data, which the zone witness holds equal to libical's. */
function slotDayOf(frame, slot) {
  const offset = frame.kind === 'zoned' ? intlOffset(frame.zone, slot) : 0;
  return wallOfEpoch(slot + offset).slice(0, 10);
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, canonical(value[k])]));
  }
  return value;
}

const same = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

function diffText(a, b) {
  const left = new Set(a.map((o) => JSON.stringify(canonical(o))));
  const right = new Set(b.map((o) => JSON.stringify(canonical(o))));
  const shown = (list) => (list.length > Config.diffLines ? [...list.slice(0, Config.diffLines), `    … ${list.length - Config.diffLines} more`] : list);
  const onlyLeft = [...left].filter((o) => !right.has(o)).map((o) => `  libical only: ${o}`);
  const onlyRight = [...right].filter((o) => !left.has(o)).map((o) => `  ical.js only: ${o}`);
  return [...shown(onlyLeft), ...shown(onlyRight)].join('\n');
}

/** RFC 5545's printed answer, the third witness for the RFC's own examples. */
function checkRFC(c, expected) {
  if (!c.rfc) return;
  const days = [];
  for (const entry of c.rfc.days) {
    const [first, last] = entry.split('..');
    for (let d = epochOf(`${first}T00:00:00Z`); d <= epochOf(`${last ?? first}T00:00:00Z`); d += SECONDS_PER_DAY) {
      days.push(wallOfEpoch(d).slice(0, 10));
    }
  }
  const got = expected.map((o) => (o.wall ?? o.start).slice(0, 10));
  if (!same(got, days)) fail(c.id, `expected days differ from RFC 5545's printed answer:\n  got ${got.join(' ')}\n  RFC ${days.join(' ')}`);
  for (const o of expected) {
    if ((o.wall ?? o.start).slice(11) !== c.rfc.wall) fail(c.id, `${o.key} is at ${o.wall}, RFC 5545 prints ${c.rfc.wall}`);
  }
}

// MARK: - One case

const usedResolutions = new Set();
// Disagreements with no written decision: all are printed, then the run fails.
const undecided = [];
const disagreements = [];

function runCase(c) {
  const ics = calendarText(c);
  const from = epochOf(c.window.from);
  const to = epochOf(c.window.to);
  const throughDay = (frame) => {
    const offset = frame.kind === 'zoned' ? intlOffset(frame.zone, to) : 0;
    return wallOfEpoch(to + offset).slice(0, 10);
  };

  const through = throughDay(icaljsFrame(icaljsEvent(ics).event.startDate));
  const lib = libicalSide(c, ics, from, to, through);
  const js = icaljsSide(c, ics, from, to, through);
  if (frameText(lib.frame) !== frameText(js.frame)) fail(c.id, `frames differ: libical ${frameText(lib.frame)}, ical.js ${frameText(js.frame)}`);
  const frame = lib.frame;
  if (c.frame !== frameText(frame)) fail(c.id, `cases.json says frame ${c.frame}, the engines read ${frameText(frame)}`);
  checkFloatingMargin(c.id, frame, [...lib.raw, ...js.raw].filter((o) => o.end > from - SECONDS_PER_DAY && o.start < to + SECONDS_PER_DAY), from, to);

  // Zone witness. libical: its offset at each of its instants must equal Node's. ical.js: Node
  // must place each of its wall times at the instant ical.js gives, unless Node has no instant
  // for that wall time at all (a time a change skips: where an engine puts it is an expansion
  // question, which the comparison below decides, not a zone-data one).
  if (frame.kind === 'zoned') {
    for (const o of lib.raw) {
      const witness = intlOffset(frame.zone, o.start);
      if (o.offset !== witness) {
        fail(c.id, `zone data differ at ${utcText(o.start)}: libical ${o.offset}, Node ${process.versions.tz} ${witness}. Pick another date or zone.`);
      }
    }
  }
  for (const o of js.raw) {
    if (!o.witness || !wallExists(o.witness.zone, o.witness.wall)) continue;
    const nodeWall = wallOfEpoch(o.start + intlOffset(o.witness.zone, o.start));
    if (nodeWall !== o.witness.wall) {
      fail(c.id, `zone data differ at ${utcText(o.start)}: ical.js reads ${o.witness.wall} in ${o.witness.zone}, Node ${process.versions.tz} ${nodeWall}. Pick another date or zone.`);
    }
  }

  const listed = (side) => side.raw.filter((o) => overlaps(o, from, to));
  const libRaw = listed(lib);
  const jsRaw = listed(js);
  const libList = sortOccurrences(libRaw.map((o) => normalize(frame, o)));
  const jsList = sortOccurrences(jsRaw.map((o) => normalize(frame, o)));

  const entry = {
    id: c.id, why: c.why, references: c.references, ics, window: c.window, frame: frameText(frame),
    expect: c.expect, libical: libList, icaljs: jsList, resolution: null,
  };

  const resolution = resolutions[c.id] ?? null;
  const ruleDaysAgree = !c.ruleDays || same(lib.ruleDays, js.ruleDays);
  if (same(libList, jsList) && ruleDaysAgree) {
    if (resolution) fail(c.id, 'the engines agree now; remove its stale entry from resolutions.json');
    entry.expected = libList;
  } else {
    if (!resolution) {
      undecided.push(`${c.id}: the engines disagree and resolutions.json has no decision:\n${diffText(libList, jsList)}` +
        (ruleDaysAgree ? '' : `\n  rule days: libical ${JSON.stringify(lib.ruleDays)}\n  ical.js ${JSON.stringify(js.ruleDays)}`));
      return entry;
    }
    usedResolutions.add(c.id);
    entry.resolution = canonical(resolution);
    entry.expected = resolve(c, frame, resolution, { libRaw, jsRaw });
    disagreements.push({ id: c.id, ...canonical(resolution) });
  }
  checkRFC(c, entry.expected ?? []);

  if (c.ruleDays) {
    let days = lib.ruleDays;
    if (!ruleDaysAgree) {
      if (!resolution || !['libical', 'icaljs'].includes(resolution.ruleDays)) fail(c.id, 'the rule days disagree; the resolution must name ruleDays: libical or icaljs');
      days = resolution.ruleDays === 'icaljs' ? js.ruleDays : lib.ruleDays;
    } else if (resolution?.ruleDays) {
      fail(c.id, 'the rule days agree; remove ruleDays from its resolution');
    }
    if (!days) fail(c.id, 'ruleDays asked for, but the series has no RRULE libical expands');
    entry.ruleDays = { dtstart: js.dtstartDay, through, days };
  }
  return entry;
}

/** The expected list a written decision gives (null for `excluded`, which asserts nothing):
 * - `follows`: the engine whose occurrences are expected;
 * - `except`: days (the day each occurrence's slot falls on in the series' frame) taken from the
 *   other engine instead;
 * - `lengthFrom`: the engine whose occurrence length (end less start) on the same day is kept,
 *   when the followed engine places the start right and the end wrong. */
function resolve(c, frame, resolution, sides) {
  const engines = { libical: 'lib', icaljs: 'js' };
  if (!resolution.why || !Array.isArray(resolution.references) || resolution.references.length === 0) {
    fail(c.id, 'a resolution needs a why and at least one reference');
  }
  if (resolution.follows === 'excluded') {
    if (!resolution.issue) fail(c.id, 'an excluded case needs an issue link');
    return null;
  }
  if (!(resolution.follows in engines)) fail(c.id, `unknown follows ${resolution.follows}`);
  const except = resolution.except ?? {};
  const byDay = (raw) => {
    const map = new Map();
    for (const r of raw) {
      if (!map.has(r.slotDay)) map.set(r.slotDay, []);
      map.get(r.slotDay).push(r);
    }
    return map;
  };
  const days = { lib: byDay(sides.libRaw), js: byDay(sides.jsRaw) };
  const normalized = (list) => sortOccurrences((list ?? []).map((r) => normalize(frame, r)));
  for (const [day, engine] of Object.entries(except)) {
    if (!(engine in engines)) fail(c.id, `unknown engine ${engine} for ${day}`);
    if (engine === resolution.follows) fail(c.id, `except names ${day} for the engine the case follows`);
    if (same(normalized(days.lib.get(day)), normalized(days.js.get(day)))) fail(c.id, `the engines agree on ${day}; remove it from except`);
  }
  if (resolution.lengthFrom !== undefined && !(resolution.lengthFrom in engines)) fail(c.id, `unknown lengthFrom ${resolution.lengthFrom}`);

  const allDays = [...new Set([...days.lib.keys(), ...days.js.keys()])].sort();
  const out = [];
  let lengthChanged = false;
  for (const day of allDays) {
    const picked = days[engines[except[day] ?? resolution.follows]].get(day) ?? [];
    const lengths = resolution.lengthFrom ? days[engines[resolution.lengthFrom]].get(day) ?? [] : null;
    for (const r of picked) {
      let end = r.end;
      if (lengths) {
        if (picked.length !== 1 || lengths.length !== 1) fail(c.id, `lengthFrom needs one occurrence on ${day} from each engine`);
        end = r.start + (lengths[0].end - lengths[0].start);
        lengthChanged ||= end !== r.end;
      }
      out.push(normalize(frame, { ...r, end }));
    }
  }
  if (resolution.lengthFrom && !lengthChanged) fail(c.id, 'lengthFrom changes no occurrence; remove it');
  return sortOccurrences(out);
}

// MARK: - Output

function writeJSON(file, value) {
  const text = JSON.stringify(canonical(value), null, 2) + '\n';
  fs.writeFileSync(file, text);
  return createHash('sha256').update(text).digest('hex');
}

const oracles = {
  libical: {
    version: lock.libical.version, build: lock.libical.build,
    tzdata: `${lock.libical.tzdata} ${process.env.CAL_ORACLE_SYSTEM_TZDATA}`,
  },
  icaljs: { source: `comm-central ${lock.icaljs.revision} ${lock.icaljs.path}`, sha256: lock.icaljs.sha256 },
};
const zoneWitness = { node: process.versions.node, icuTzdata: process.versions.tz };
const generator = { version: lock.generator.version, command: 'Scripts/cal-oracle/generate.sh' };

const families = new Map();
for (const c of corpus.cases) {
  if (!corpus.families[c.family]) fail(c.id, `unknown family ${c.family}`);
  if (!families.has(c.family)) families.set(c.family, []);
  families.get(c.family).push(runCase(c));
}
if (undecided.length > 0) {
  console.error(undecided.join('\n\n'));
  console.error(`\n${undecided.length} disagreement(s) need a decision in resolutions.json; nothing written.`);
  process.exit(1);
}
for (const id of Object.keys(resolutions)) {
  if (!usedResolutions.has(id)) throw new Error(`${id}: resolutions.json names a case that does not disagree or does not exist`);
}

fs.mkdirSync(fixturesDir, { recursive: true });
const files = [];
for (const [family, cases] of families) {
  const file = `cal-oracle-${family}.json`;
  const sha256 = writeJSON(path.join(fixturesDir, file), {
    schema: 1, family, about: corpus.families[family], generator, oracles, zoneWitness, cases,
  });
  files.push({ file, family, cases: cases.length, sha256 });
}
writeJSON(path.join(fixturesDir, 'cal-oracle-manifest.json'), {
  schema: 1, generator, oracles, zoneWitness, files, disagreements,
  datesNote: 'Fixture dates are fixed and run from 1896 to 2019 (every DTSTAMP is 2020-01-01), under the testing-rules exception for dates far in the past (2020 and earlier). The engines do not run at test time, so their answers cannot be relative to today.',
});
console.log(`wrote ${files.length} family file(s), ${files.reduce((n, f) => n + f.cases, 0)} case(s), ${disagreements.length} disagreement(s)`);
