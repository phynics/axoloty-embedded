// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Transport-neutral carrier diagnostics.
//
// Fixed, saturating, allocation-free counters that answer what the carrier
// actually did. See `carrier_diagnostics.h` for why they are neutral, bounded,
// saturating, and why this module classifies nothing.
//
// This file includes no Zenoh header, no SDK header, and not even the Core-owned
// facade header, so the host seam checks the production counters with no board,
// no zenoh-pico, and no ESP-IDF. Nothing here restates a facade result code or a
// transport bound; the counters are a fixed, named tally and the carrier that
// observes an event decides which tally it belongs to.

#include "carrier_diagnostics.h"

// The firmware target must implement these atomics without an out-of-line
// libatomic dependency. Fail at compile time if a new target cannot.
_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "carrier diagnostics requires lock-free 32-bit atomics");

// The one live counter set. Fixed storage, so there is nothing to allocate and
// nothing to free, and a reader always has a valid snapshot address.
static CarrierDiagnostics carrier_diagnostics_state;

// The counters as one addressable table, so a metric selects a field without
// this module having to name any meaning. The order matches `CarrierMetric`.
#define CARRIER_METRIC_TABLE(X)                        \
    X(CARRIER_METRIC_PUBLISH_ATTEMPTS, publish_attempts)      \
    X(CARRIER_METRIC_PUBLISH_FAILURES, publish_failures)      \
    X(CARRIER_METRIC_FRAMES_RECEIVED, frames_received)        \
    X(CARRIER_METRIC_FRAMES_DROPPED, frames_dropped)          \
    X(CARRIER_METRIC_FRAMES_OVERSIZED, frames_oversized)      \
    X(CARRIER_METRIC_POLL_ERRORS, poll_errors)                \
    X(CARRIER_METRIC_SESSION_OPENS, session_opens)            \
    X(CARRIER_METRIC_SESSION_CLOSES, session_closes)          \
    X(CARRIER_METRIC_SESSION_FAILURES, session_failures)      \
    X(CARRIER_METRIC_RECONNECTS_OBSERVED, reconnects_observed)

#define CARRIER_METRIC_FIELD(metric, field) &carrier_diagnostics_state.field,
static uint32_t *const carrier_metric_fields[CARRIER_METRIC_COUNT] = {
    CARRIER_METRIC_TABLE(CARRIER_METRIC_FIELD)
};
#undef CARRIER_METRIC_FIELD

// Saturating atomic increment.
//
// A compare-and-swap loop rather than `__atomic_fetch_add`: a fetch-add wraps at
// UINT32_MAX, and a wrapped counter reads as a small healthy number after a long
// run. Saturation reads as "at least this many", which is the only reading a
// diagnostic can be trusted to carry. The loop retries only on a genuinely
// concurrent update, so an uncontended increment is one CAS.
//
// `relaxed` is the correct ordering. Each counter is an independent tally, not
// a synchronisation mechanism: a reader that interleaves two updates sees two
// valid values, never a torn one.
static void saturating_add(uint32_t *field, uint32_t amount) {
    if (amount == 0u) return;
    uint32_t current = __atomic_load_n(field, __ATOMIC_RELAXED);
    for (;;) {
        uint32_t next = current > UINT32_MAX - amount ? UINT32_MAX : current + amount;
        if (__atomic_compare_exchange_n(field, &current, next, 1,
                                        __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            return;
        }
        // A failed exchange reloaded `current`; retry from it.
    }
}

CarrierDiagnostics carrier_diagnostics_get(void) {
    CarrierDiagnostics snapshot;
#define CARRIER_LOAD(metric, field) \
    snapshot.field = __atomic_load_n(&carrier_diagnostics_state.field, __ATOMIC_RELAXED);
    CARRIER_METRIC_TABLE(CARRIER_LOAD)
#undef CARRIER_LOAD
    snapshot.active_subscriptions = __atomic_load_n(
        &carrier_diagnostics_state.active_subscriptions, __ATOMIC_RELAXED);
    snapshot.active_subscriptions_peak = __atomic_load_n(
        &carrier_diagnostics_state.active_subscriptions_peak, __ATOMIC_RELAXED);
    return snapshot;
}

void carrier_diagnostics_reset(void) {
#define CARRIER_CLEAR(metric, field) \
    __atomic_store_n(&carrier_diagnostics_state.field, 0u, __ATOMIC_RELAXED);
    CARRIER_METRIC_TABLE(CARRIER_CLEAR)
#undef CARRIER_CLEAR
    __atomic_store_n(&carrier_diagnostics_state.active_subscriptions, 0u, __ATOMIC_RELAXED);
    __atomic_store_n(&carrier_diagnostics_state.active_subscriptions_peak, 0u, __ATOMIC_RELAXED);
}

static bool metric_is_known(CarrierMetric metric) {
    return (int)metric >= 0 && (int)metric < (int)CARRIER_METRIC_COUNT;
}

bool carrier_diagnostics_add(CarrierMetric metric, uint32_t delta) {
    if (!metric_is_known(metric)) return false;
    saturating_add(carrier_metric_fields[(int)metric], delta);
    return true;
}

uint32_t carrier_diagnostics_get_metric(CarrierMetric metric) {
    if (!metric_is_known(metric)) return 0u;
    return __atomic_load_n(carrier_metric_fields[(int)metric], __ATOMIC_RELAXED);
}

void carrier_diagnostics_set_active_subscriptions(uint32_t active) {
    __atomic_store_n(&carrier_diagnostics_state.active_subscriptions, active, __ATOMIC_RELAXED);
    uint32_t peak = __atomic_load_n(&carrier_diagnostics_state.active_subscriptions_peak,
                                    __ATOMIC_RELAXED);
    while (active > peak) {
        if (__atomic_compare_exchange_n(&carrier_diagnostics_state.active_subscriptions_peak,
                                        &peak, active, 1,
                                        __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            break;
        }
    }
}

// --- Bounded JSON writer ---------------------------------------------------
//
// A serial reporter can use these numbers without linking a JSON library.
// Nothing here allocates, and every append is bounds-checked before it writes.

typedef struct {
    char *buffer;
    size_t capacity;
    size_t length;
    bool overflowed;
} JsonSink;

static void sink_append(JsonSink *sink, const char *text) {
    size_t remaining = sink->overflowed ? 0u : sink->capacity - sink->length;
    size_t index = 0;
    while (text[index] != '\0') {
        if (index + 1u >= remaining) {
            // Refuse rather than truncate. A half-written number is not a
            // measurement, and a silent truncation is worse than no report.
            sink->overflowed = true;
            sink->length = 0u;
            return;
        }
        sink->buffer[sink->length] = text[index];
        sink->length += 1u;
        index += 1;
    }
}

static void sink_append_unsigned(JsonSink *sink, uint32_t value) {
    char digits[10];
    size_t count = 0;
    if (value == 0u) {
        digits[count] = '0';
        count += 1;
    }
    while (value > 0u && count < sizeof(digits)) {
        digits[count] = (char)('0' + (value % 10u));
        count += 1;
        value /= 10u;
    }
    char text[11];
    for (size_t index = 0; index < count; ++index) text[index] = digits[count - 1u - index];
    text[count] = '\0';
    sink_append(sink, text);
}

// The exact key spelling, kept as named pieces so `json_capacity` and the
// writer below cannot drift apart: both read the same strings.
#define CARRIER_JSON_PUBLISH_ATTEMPTS "{\"publishAttempts\":"
#define CARRIER_JSON_PUBLISH_FAILURES "\"publishFailures\":"
#define CARRIER_JSON_FRAMES_RECEIVED "\"framesReceived\":"
#define CARRIER_JSON_FRAMES_DROPPED "\"framesDropped\":"
#define CARRIER_JSON_FRAMES_OVERSIZED "\"framesOversized\":"
#define CARRIER_JSON_POLL_ERRORS "\"pollErrors\":"
#define CARRIER_JSON_SESSION_OPENS "\"sessionOpens\":"
#define CARRIER_JSON_SESSION_CLOSES "\"sessionCloses\":"
#define CARRIER_JSON_SESSION_FAILURES "\"sessionFailures\":"
#define CARRIER_JSON_RECONNECTS "\"reconnectsObserved\":"
#define CARRIER_JSON_ACTIVE "\"activeSubscriptions\":"
#define CARRIER_JSON_ACTIVE_PEAK "\"activeSubscriptionsPeak\":"
#define CARRIER_JSON_CLOSE "}"

#define CARRIER_JSON_KEYS                                                    \
    (sizeof(CARRIER_JSON_PUBLISH_ATTEMPTS) - 1u) + (sizeof(CARRIER_JSON_PUBLISH_FAILURES) - 1u) + \
    (sizeof(CARRIER_JSON_FRAMES_RECEIVED) - 1u) + (sizeof(CARRIER_JSON_FRAMES_DROPPED) - 1u) +    \
    (sizeof(CARRIER_JSON_FRAMES_OVERSIZED) - 1u) + (sizeof(CARRIER_JSON_POLL_ERRORS) - 1u) +      \
    (sizeof(CARRIER_JSON_SESSION_OPENS) - 1u) + (sizeof(CARRIER_JSON_SESSION_CLOSES) - 1u) +      \
    (sizeof(CARRIER_JSON_SESSION_FAILURES) - 1u) + (sizeof(CARRIER_JSON_RECONNECTS) - 1u) +       \
    (sizeof(CARRIER_JSON_ACTIVE) - 1u) + (sizeof(CARRIER_JSON_ACTIVE_PEAK) - 1u)

// Every counter can reach UINT32_MAX, which is ten decimal digits, so this
// bound holds for any value the counters can hold.
#define CARRIER_JSON_FIELDS (12u * 10u)
#define CARRIER_JSON_COMMAS 11u

size_t carrier_diagnostics_json_capacity(void) {
    return CARRIER_JSON_KEYS + CARRIER_JSON_COMMAS + CARRIER_JSON_FIELDS
        + sizeof(CARRIER_JSON_CLOSE);
}

size_t carrier_diagnostics_write_json(char *buffer, size_t capacity) {
    if (!buffer || capacity < carrier_diagnostics_json_capacity()) return 0u;

    CarrierDiagnostics snapshot = carrier_diagnostics_get();
    JsonSink sink = { buffer, capacity, 0u, false };

    sink_append(&sink, CARRIER_JSON_PUBLISH_ATTEMPTS);
    sink_append_unsigned(&sink, snapshot.publish_attempts);
    sink_append(&sink, "," CARRIER_JSON_PUBLISH_FAILURES);
    sink_append_unsigned(&sink, snapshot.publish_failures);
    sink_append(&sink, "," CARRIER_JSON_FRAMES_RECEIVED);
    sink_append_unsigned(&sink, snapshot.frames_received);
    sink_append(&sink, "," CARRIER_JSON_FRAMES_DROPPED);
    sink_append_unsigned(&sink, snapshot.frames_dropped);
    sink_append(&sink, "," CARRIER_JSON_FRAMES_OVERSIZED);
    sink_append_unsigned(&sink, snapshot.frames_oversized);
    sink_append(&sink, "," CARRIER_JSON_POLL_ERRORS);
    sink_append_unsigned(&sink, snapshot.poll_errors);
    sink_append(&sink, "," CARRIER_JSON_SESSION_OPENS);
    sink_append_unsigned(&sink, snapshot.session_opens);
    sink_append(&sink, "," CARRIER_JSON_SESSION_CLOSES);
    sink_append_unsigned(&sink, snapshot.session_closes);
    sink_append(&sink, "," CARRIER_JSON_SESSION_FAILURES);
    sink_append_unsigned(&sink, snapshot.session_failures);
    sink_append(&sink, "," CARRIER_JSON_RECONNECTS);
    sink_append_unsigned(&sink, snapshot.reconnects_observed);
    sink_append(&sink, "," CARRIER_JSON_ACTIVE);
    sink_append_unsigned(&sink, snapshot.active_subscriptions);
    sink_append(&sink, "," CARRIER_JSON_ACTIVE_PEAK);
    sink_append_unsigned(&sink, snapshot.active_subscriptions_peak);
    sink_append(&sink, CARRIER_JSON_CLOSE);

    if (sink.overflowed) return 0u;
    buffer[sink.length] = '\0';
    return sink.length;
}
