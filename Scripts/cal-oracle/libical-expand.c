/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/*
 * libical-expand: the libical side of the calendar oracle (ADR-IOS-110).
 *
 * A developer tool, run by Scripts/cal-oracle/generate.sh on a developer Mac. It is never
 * linked into the app and never run in CI.
 *
 *   libical-expand vtimezone <IANA zone>
 *       Prints the VTIMEZONE libical builds for the zone (from the system zoneinfo).
 *
 *   libical-expand expand <from epoch> <to epoch> <rule-days through yyyymmdd>
 *       Reads one VCALENDAR on stdin and prints JSON lines:
 *       {"t":"frame", ...}     how the master's DTSTART places its occurrences;
 *       {"t":"occ", ...}       each occurrence libical's icalcomponent_foreach_recurrence
 *                              gives for the master between the two instants (its own
 *                              RRULE, RDATE and EXDATE logic);
 *       {"t":"override", ...}  each VEVENT with a RECURRENCE-ID, read by libical;
 *       {"t":"ruleDay", ...}   each day the RRULE alone gives (icalrecur_iterator), from
 *                              DTSTART through the given day, COUNT and UNTIL applied.
 *
 * libical leaves the merging of RECURRENCE-ID overrides to its caller, so generate.mjs does
 * that with the override lines printed here. Every instant is seconds since the epoch; a
 * floating or all-day value is printed as its wall time read as UTC ("naive" seconds).
 */

#include <libical/ical.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The most rule days one case may ask for: a guard against a runaway rule. */
#define MAX_RULE_DAYS 20000
/* The largest calendar text a case is read from (bytes). */
#define MAX_INPUT (4 * 1024 * 1024)

static void fail(const char *message) {
    fprintf(stderr, "libical-expand: %s\n", message);
    exit(2);
}

static void print_wall(const char *name, struct icaltimetype t) {
    if (t.is_date) {
        printf("\"%s\":\"%04d-%02d-%02d\"", name, t.year, t.month, t.day);
    } else {
        printf("\"%s\":\"%04d-%02d-%02dT%02d:%02d:%02d\"", name, t.year, t.month, t.day, t.hour, t.minute, t.second);
    }
}

/* The instant a value names: a zoned or UTC value as a true instant, a floating or date
 * value as its wall time read as UTC. */
static icaltime_t instant_of(struct icaltimetype t) {
    if (t.zone != NULL && !t.is_date) {
        return icaltime_as_timet_with_zone(t, t.zone);
    }
    struct icaltimetype naive = t;
    naive.zone = NULL;
    return icaltime_as_timet_with_zone(naive, icaltimezone_get_utc_timezone());
}

typedef struct {
    const icaltimezone *zone; /* NULL for floating and all-day */
    int utc;
    int is_date;
} Frame;

static Frame frame_of(struct icaltimetype dtstart) {
    Frame f;
    f.is_date = dtstart.is_date;
    f.utc = !dtstart.is_date && icaltime_is_utc(dtstart);
    f.zone = (dtstart.is_date || f.utc) ? NULL : dtstart.zone;
    return f;
}

static void print_occurrence(icalcomponent *comp, const struct icaltime_span *span, void *data) {
    (void)comp;
    const Frame *f = (const Frame *)data;
    printf("{\"t\":\"occ\",\"start\":%lld,\"end\":%lld", (long long)span->start, (long long)span->end);
    if (f->zone != NULL) {
        icaltimezone *zone = (icaltimezone *)f->zone;
        struct icaltimetype wall = icaltime_from_timet_with_zone(span->start, 0, zone);
        int is_daylight = 0;
        int offset = icaltimezone_get_utc_offset(zone, &wall, &is_daylight);
        printf(",");
        print_wall("wall", wall);
        printf(",\"offset\":%d", offset);
    }
    printf("}\n");
}

static char *read_stdin(void) {
    char *buffer = malloc(MAX_INPUT + 1);
    if (buffer == NULL) fail("out of memory");
    size_t length = fread(buffer, 1, MAX_INPUT, stdin);
    if (length == MAX_INPUT) fail("input too large");
    buffer[length] = '\0';
    return buffer;
}

static int command_vtimezone(const char *location) {
    icaltimezone *zone = icaltimezone_get_builtin_timezone(location);
    if (zone == NULL) fail("unknown zone");
    icalcomponent *component = icaltimezone_get_component(zone);
    if (component == NULL) fail("zone has no VTIMEZONE");
    fputs(icalcomponent_as_ical_string(component), stdout);
    return 0;
}

static int command_expand(const char *from_text, const char *to_text, const char *through_text) {
    icaltime_t from = (icaltime_t)strtoll(from_text, NULL, 10);
    icaltime_t to = (icaltime_t)strtoll(to_text, NULL, 10);
    struct icaltimetype through = icaltime_from_string(through_text);
    if (icaltime_is_null_time(through)) fail("bad rule-days end");

    char *text = read_stdin();
    icalcomponent *calendar = icalparser_parse_string(text);
    if (calendar == NULL) fail("unreadable calendar");

    icalcomponent *master = NULL;
    for (icalcomponent *c = icalcomponent_get_first_component(calendar, ICAL_VEVENT_COMPONENT); c != NULL;
         c = icalcomponent_get_next_component(calendar, ICAL_VEVENT_COMPONENT)) {
        if (icalcomponent_get_first_property(c, ICAL_RECURRENCEID_PROPERTY) == NULL) {
            if (master != NULL) fail("more than one master VEVENT");
            master = c;
        }
    }
    if (master == NULL) fail("no master VEVENT");

    struct icaltimetype dtstart = icalcomponent_get_dtstart(master);
    if (icaltime_is_null_time(dtstart)) fail("unreadable DTSTART");
    Frame frame = frame_of(dtstart);
    if (!frame.is_date && !frame.utc) {
        icalproperty *p = icalcomponent_get_first_property(master, ICAL_DTSTART_PROPERTY);
        icalparameter *tzid = icalproperty_get_first_parameter(p, ICAL_TZID_PARAMETER);
        if (tzid != NULL && frame.zone == NULL) fail("DTSTART names a TZID libical can't resolve");
    }
    printf("{\"t\":\"frame\",\"frame\":");
    if (frame.is_date) {
        printf("\"allDay\"");
    } else if (frame.utc) {
        printf("\"utc\"");
    } else if (frame.zone != NULL) {
        printf("\"zoned:%s\"", icaltimezone_get_tzid((icaltimezone *)frame.zone));
    } else {
        printf("\"floating\"");
    }
    printf("}\n");

    struct icaltimetype range_start = icaltime_from_timet_with_zone(from, 0, icaltimezone_get_utc_timezone());
    struct icaltimetype range_end = icaltime_from_timet_with_zone(to, 0, icaltimezone_get_utc_timezone());
    icalcomponent_foreach_recurrence(master, range_start, range_end, print_occurrence, &frame);

    for (icalcomponent *c = icalcomponent_get_first_component(calendar, ICAL_VEVENT_COMPONENT); c != NULL;
         c = icalcomponent_get_next_component(calendar, ICAL_VEVENT_COMPONENT)) {
        if (c == master) continue;
        struct icaltimetype rid = icalcomponent_get_recurrenceid(c);
        struct icaltimetype start = icalcomponent_get_dtstart(c);
        struct icaltimetype end = icalcomponent_get_dtend(c);
        if (icaltime_is_null_time(rid) || icaltime_is_null_time(start)) fail("unreadable override");
        printf("{\"t\":\"override\",\"rid\":%lld,\"ridIsDate\":%s,\"start\":%lld,\"end\":%lld,\"status\":\"%s\"",
               (long long)instant_of(rid), rid.is_date ? "true" : "false",
               (long long)instant_of(start),
               (long long)(icaltime_is_null_time(end) ? instant_of(start) : instant_of(end)),
               icalcomponent_get_status(c) == ICAL_STATUS_CANCELLED ? "cancelled" : "confirmed");
        if (frame.zone != NULL) {
            /* The series zone's offset at the override's own start, for the zone witness. */
            icaltimezone *zone = (icaltimezone *)frame.zone;
            struct icaltimetype wall = icaltime_from_timet_with_zone(instant_of(start), 0, zone);
            int is_daylight = 0;
            int offset = icaltimezone_get_utc_offset(zone, &wall, &is_daylight);
            printf(",");
            print_wall("wall", wall);
            printf(",\"offset\":%d", offset);
        }
        printf("}\n");
    }

    icalproperty *rrule = icalcomponent_get_first_property(master, ICAL_RRULE_PROPERTY);
    if (rrule != NULL) {
        struct icalrecurrencetype *recur = icalproperty_get_rrule(rrule);
        icalrecur_iterator *it = icalrecur_iterator_new(recur, dtstart);
        if (it == NULL) {
            printf("{\"t\":\"ruleDaysUnsupported\"}\n");
        } else {
            int count = 0;
            for (struct icaltimetype next = icalrecur_iterator_next(it); !icaltime_is_null_time(next);
                 next = icalrecur_iterator_next(it)) {
                if (icaltime_compare_date_only(next, through) > 0) break;
                if (++count > MAX_RULE_DAYS) fail("rule days past the guard");
                printf("{\"t\":\"ruleDay\",\"day\":\"%04d-%02d-%02d\"}\n", next.year, next.month, next.day);
            }
            icalrecur_iterator_free(it);
        }
    }

    icalcomponent_free(calendar);
    free(text);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "vtimezone") == 0) return command_vtimezone(argv[2]);
    if (argc == 5 && strcmp(argv[1], "expand") == 0) return command_expand(argv[2], argv[3], argv[4]);
    fail("usage: libical-expand vtimezone <zone> | expand <from> <to> <through yyyymmdd>");
    return 2;
}
