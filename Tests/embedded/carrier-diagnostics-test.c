// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Hardware-free conformance for the transport-neutral carrier diagnostics.
//
// These are the properties the device gate depends on and cannot check without
// a debugger. A counter that wraps, that allocates, that reports a truncated
// number, or that accepts an unknown metric looks correct on a device until the
// exact moment it is wrong, so each of those is refused here instead.
//
// The production `carrier_diagnostics.c` is linked, not a copy: a stand-in
// would pass this while the image shipped a different implementation.
//
// Returns 1 when every property holds, 0 otherwise. No board, no Zenoh, no SDK.

#include "carrier_diagnostics.h"

#include <stdio.h>
#include <string.h>
#include <pthread.h>

static int check(int condition, const char *what) {
    if (condition) return 1;
    fprintf(stderr, "carrier diagnostics conformance failed: %s\n", what);
    return 0;
}

static uint32_t parse_field(const char *json, const char *key) {
    // A deliberately small reader. This file must not need a JSON library, and
    // the writer under test is not allowed to emit anything but integers, so
    // finding `"key":` and reading digits to the next comma or brace is
    // sufficient and cannot mask a malformed value.
    char needle[64];
    int written = snprintf(needle, sizeof(needle), "\"%s\":", key);
    if (written < 0 || (size_t)written >= sizeof(needle)) return 0xFFFFFFFFu;
    const char *at = strstr(json, needle);
    if (!at) return 0xFFFFFFFFu;
    at += (size_t)written;
    uint32_t value = 0;
    int digits = 0;
    while (*at >= '0' && *at <= '9') {
        // Refuse a value that cannot fit rather than wrapping it: a wrapped
        // parse would make a too-large number look like a small real one.
        if (value > (UINT32_MAX - (uint32_t)(*at - '0')) / 10u) return 0xFFFFFFFFu;
        value = value * 10u + (uint32_t)(*at - '0');
        ++at;
        ++digits;
    }
    if (digits == 0) return 0xFFFFFFFFu;
    if (*at != ',' && *at != '}') return 0xFFFFFFFFu;
    return value;
}

// A buffer comfortably larger than any realistic report, so the "too small"
// cases below are exercised by shrinking capacity rather than by a hostile
// allocation.
#define REPORT_BUFFER 512

static void *concurrent_writer(void *unused) {
    (void)unused;
    for (unsigned index = 0; index < 50000u; ++index) {
        carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1u);
    }
    return NULL;
}

int host_carrier_diagnostics_tests(void) {
    char report[REPORT_BUFFER];

    // --- Bounded: the reported capacity is finite and actually sufficient.
    size_t needed = carrier_diagnostics_json_capacity();
    if (!check(needed > 0u && needed < sizeof(report),
               "the required capacity is finite and fits a bounded buffer")) return 0;

    // --- Reset produces an all-zero report, so each qualification phase
    //     starts from a known zero rather than from inherited history.
    carrier_diagnostics_reset();
    if (!check(carrier_diagnostics_json_capacity() == needed,
               "capacity does not depend on the counter values")) return 0;
    size_t written = carrier_diagnostics_write_json(report, sizeof(report));
    if (!check(written > 0u && written < needed, "a zero report writes within the bound")) return 0;
    if (!check(strstr(report, "{\"publishAttempts\":0,\"publishFailures\":0,\"framesReceived\":0,"
                              "\"framesDropped\":0,\"framesOversized\":0,\"pollErrors\":0,"
                              "\"sessionOpens\":0,\"sessionCloses\":0,\"sessionFailures\":0,"
                              "\"reconnectsObserved\":0,\"activeSubscriptions\":0,"
                              "\"activeSubscriptionsPeak\":0}") == report,
               "the reset report is exactly the zero report")) return 0;

    // --- A zero-length report must not be mistaken for a zero-valued one.
    if (!check(carrier_diagnostics_write_json(report, 0u) == 0u,
               "a zero capacity reports 'did not fit'")) return 0;
    if (!check(carrier_diagnostics_write_json(NULL, sizeof(report)) == 0u,
               "a null buffer reports 'did not fit'")) return 0;
    for (size_t capacity = 1u; capacity < needed; ++capacity) {
        if (!check(carrier_diagnostics_write_json(report, capacity) == 0u,
                   "an undersized buffer reports 'did not fit' rather than truncating")) {
            return 0;
        }
    }

    // --- Every counter is independently addressable and readable.
    static const CarrierMetric metrics[CARRIER_METRIC_COUNT] = {
        CARRIER_METRIC_PUBLISH_ATTEMPTS,     CARRIER_METRIC_PUBLISH_FAILURES,
        CARRIER_METRIC_FRAMES_RECEIVED,      CARRIER_METRIC_FRAMES_DROPPED,
        CARRIER_METRIC_FRAMES_OVERSIZED,     CARRIER_METRIC_POLL_ERRORS,
        CARRIER_METRIC_SESSION_OPENS,        CARRIER_METRIC_SESSION_CLOSES,
        CARRIER_METRIC_SESSION_FAILURES,     CARRIER_METRIC_RECONNECTS_OBSERVED,
    };
    for (int index = 0; index < CARRIER_METRIC_COUNT; ++index) {
        if (!check(carrier_diagnostics_add(metrics[index], 1u),
                   "every declared metric accepts an update")) return 0;
    }
    for (int index = 0; index < CARRIER_METRIC_COUNT; ++index) {
        if (!check(carrier_diagnostics_get_metric(metrics[index]) == 1u,
                   "every declared metric reads back what was added")) return 0;
    }

    // --- An unknown metric is refused rather than silently discarded, so a
    //     caller bug cannot create a metric nobody reads and nobody sees.
    if (!check(!carrier_diagnostics_add((CarrierMetric)CARRIER_METRIC_COUNT, 1u),
               "a metric past the last one is refused")) return 0;
    if (!check(!carrier_diagnostics_add((CarrierMetric)-1, 1u),
               "a negative metric is refused")) return 0;
    if (!check(!carrier_diagnostics_add((CarrierMetric)0x7FFFFFFFu, 1u),
               "an absurd metric is refused")) return 0;

    // --- A zero delta is a no-op, so "record nothing" never invents an event.
    carrier_diagnostics_reset();
    carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 0u);
    if (!check(carrier_diagnostics_get_metric(CARRIER_METRIC_FRAMES_RECEIVED) == 0u,
               "a zero delta records nothing")) return 0;

    // --- Saturating, not wrapping. This is the property that separates "at
    //     least this many events" from "a small healthy number", and it only
    //     shows up after 2^32 events, which no device run will ever reach.
    carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, UINT32_MAX);
    carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, 1u);
    if (!check(carrier_diagnostics_get_metric(CARRIER_METRIC_SESSION_OPENS) == UINT32_MAX,
               "a counter saturates at its maximum instead of wrapping to zero")) return 0;
    carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, UINT32_MAX);
    if (!check(carrier_diagnostics_get_metric(CARRIER_METRIC_SESSION_OPENS) == UINT32_MAX,
               "a saturated counter stays saturated")) return 0;

    // --- The gauge is a level and the high-water mark only grows, so a
    //     stale-subscription leak is visible without a sample history.
    carrier_diagnostics_reset();
    carrier_diagnostics_set_active_subscriptions(3u);
    carrier_diagnostics_set_active_subscriptions(1u);
    CarrierDiagnostics gauges = carrier_diagnostics_get();
    if (!check(gauges.active_subscriptions == 1u,
               "the gauge follows the current level down")) return 0;
    if (!check(gauges.active_subscriptions_peak == 3u,
               "the high-water mark remembers the highest level seen")) return 0;
    carrier_diagnostics_set_active_subscriptions(2u);
    if (!check(carrier_diagnostics_get().active_subscriptions_peak == 3u,
               "the high-water mark never falls")) return 0;
    carrier_diagnostics_set_active_subscriptions(8u);
    if (!check(carrier_diagnostics_get().active_subscriptions_peak == 8u,
               "the high-water mark rises again on a new high")) return 0;

    // --- The report names every counter, and the named values are the counted
    //     values. A field that is silently absent reads as a zero measurement.
    carrier_diagnostics_reset();
    for (int index = 0; index < CARRIER_METRIC_COUNT; ++index) {
        carrier_diagnostics_add(metrics[index], (uint32_t)(index + 1));
    }
    carrier_diagnostics_set_active_subscriptions(4u);
    written = carrier_diagnostics_write_json(report, sizeof(report));
    if (!check(written > 0u, "a populated report writes")) return 0;
    static const char *const names[CARRIER_METRIC_COUNT] = {
        "publishAttempts", "publishFailures", "framesReceived", "framesDropped",
        "framesOversized", "pollErrors", "sessionOpens", "sessionCloses",
        "sessionFailures", "reconnectsObserved",
    };
    for (int index = 0; index < CARRIER_METRIC_COUNT; ++index) {
        if (!check(parse_field(report, names[index]) == (uint32_t)(index + 1),
                   "the report carries each counter's counted value")) return 0;
        if (!check(carrier_diagnostics_get_metric(metrics[index]) == (uint32_t)(index + 1),
                   "the counter itself holds the counted value")) return 0;
    }
    if (!check(parse_field(report, "activeSubscriptions") == 4u,
               "the report carries the subscription gauge")) return 0;
    if (!check(parse_field(report, "activeSubscriptionsPeak") == 4u,
               "the report carries the subscription high-water mark")) return 0;

    // --- A saturated counter still reports its true value in full decimal,
    //     which is what a reader needs in order to notice the saturation.
    carrier_diagnostics_reset();
    carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, UINT32_MAX);
    written = carrier_diagnostics_write_json(report, sizeof(report));
    if (!check(written > 0u, "a saturated report still fits the bound")) return 0;
    if (!check(parse_field(report, "framesReceived") == UINT32_MAX,
                "a saturated counter is reported in full, not abbreviated")) return 0;

    // All fields at their maximum must fit exactly, leaving only the null byte.
    for (int index = 0; index < CARRIER_METRIC_COUNT; ++index) {
        carrier_diagnostics_add(metrics[index], UINT32_MAX);
    }
    carrier_diagnostics_set_active_subscriptions(UINT32_MAX);
    memset(report, 'x', sizeof(report));
    written = carrier_diagnostics_write_json(report, needed);
    if (!check(written + 1u == needed, "the maximum report fills the exact capacity")) return 0;
    if (!check(report[needed] == 'x', "the writer stays within caller capacity")) return 0;

    // The report is one terminated JSON object with no trailing newline.
    if (!check(report[written] == '\0', "the report is terminated")) return 0;
    if (!check(strchr(report, '\n') == NULL, "the report carries no newline")) return 0;
    if (!check(report[0] == '{' && report[written - 1u] == '}',
                "the report is one JSON object")) return 0;

    // Two writers and a snapshot reader share the production atomic storage.
    carrier_diagnostics_reset();
    pthread_t writers[2];
    if (!check(pthread_create(&writers[0], NULL, concurrent_writer, NULL) == 0,
               "start first concurrent writer")) return 0;
    if (pthread_create(&writers[1], NULL, concurrent_writer, NULL) != 0) {
        pthread_join(writers[0], NULL);
        return check(0, "start second concurrent writer");
    }
    uint32_t previous = 0;
    int valid_snapshots = 1;
    for (unsigned index = 0; index < 10000u; ++index) {
        uint32_t current = carrier_diagnostics_get().frames_received;
        if (current < previous || current > 100000u) valid_snapshots = 0;
        previous = current;
    }
    pthread_join(writers[0], NULL);
    pthread_join(writers[1], NULL);
    if (!check(valid_snapshots, "concurrent snapshots never tear or go backwards")) return 0;
    if (!check(carrier_diagnostics_get().frames_received == 100000u,
               "concurrent increments lose no updates")) return 0;

    carrier_diagnostics_reset();
    return 1;
}
