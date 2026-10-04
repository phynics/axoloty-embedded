// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_CARRIER_DIAGNOSTICS_H
#define AXOLOTY_CARRIER_DIAGNOSTICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Transport-neutral carrier diagnostics.
//
// These counters answer one question on a device with no debugger and no host:
// what did the carrier actually do. They are deliberately neutral — no Zenoh
// type, no SDK type, no facade result code, and no routing-key rule appears
// here or in `carrier_diagnostics.c`, so a sibling transport adopts the same
// shape unchanged and the device gate reads one set of numbers regardless of
// carrier.
//
// Three properties make the numbers trustworthy rather than decorative:
//
// - **Bounded.** One fixed struct, no allocation, no container, no growth. The
//   device has one stack and no slack, so a counter that could allocate or
//   expand is not a counter this device can afford.
// - **Saturating.** Every increment stops at UINT32_MAX instead of wrapping. A
//   wrapped counter reports a small number after enough events, which reads as
//   healthy traffic; saturation reports "at least this many", which is the only
//   reading a diagnostic can be trusted to carry. This mirrors the bounded
//   receive queue's own saturating add.
// - **Concurrent-safe.** Updates and reads use lock-free 32-bit atomics. Each
//   counter is independent; a snapshot is not a transaction across fields.

/// Bounded carrier diagnostics. Every field is a count since the last reset,
/// except `active_subscriptions` and `active_subscriptions_peak`, which are
/// gauges.
typedef struct {
    /// Publish calls, including calls refused locally before the facade.
    uint32_t publish_attempts;
    /// Publish calls refused locally or by the facade.
    uint32_t publish_failures;
    /// Frames copied out of the receive path into caller storage.
    uint32_t frames_received;
    /// Queue-full notifications observed by polling. Several dropped frames
    /// can coalesce into one notification; this is not an exact loss total.
    uint32_t frames_dropped;
    /// Oversized-frame notifications observed by polling. Several rejected
    /// frames can coalesce into one notification.
    uint32_t frames_oversized;
    /// Facade poll errors other than not-open, drop, oversize, or empty queue.
    uint32_t poll_errors;
    /// Sessions opened successfully.
    uint32_t session_opens;
    /// Sessions closed successfully.
    uint32_t session_closes;
    /// Failed facade open, close, and publish calls, failed subscription
    /// operations including local refusals, and poll errors or not-open results.
    /// Local publish/open/poll refusals and router queries do not add here.
    uint32_t session_failures;
    /// Router loss-to-restoration transitions actually observed.
    uint32_t reconnects_observed;
    /// Subscription gauge and its high-water mark, for stale-subscription and
    /// growth checks across a long run.
    uint32_t active_subscriptions;
    uint32_t active_subscriptions_peak;
} CarrierDiagnostics;

/// One bounded counter. The subscription gauge and its high-water mark are not
/// counters and are not in this list; they are set through
/// ``carrier_diagnostics_set_active_subscriptions``.
typedef enum {
    CARRIER_METRIC_PUBLISH_ATTEMPTS = 0,
    CARRIER_METRIC_PUBLISH_FAILURES,
    CARRIER_METRIC_FRAMES_RECEIVED,
    CARRIER_METRIC_FRAMES_DROPPED,
    CARRIER_METRIC_FRAMES_OVERSIZED,
    CARRIER_METRIC_POLL_ERRORS,
    CARRIER_METRIC_SESSION_OPENS,
    CARRIER_METRIC_SESSION_CLOSES,
    CARRIER_METRIC_SESSION_FAILURES,
    CARRIER_METRIC_RECONNECTS_OBSERVED,
    /// The number of addressable counters. Not itself a counter.
    CARRIER_METRIC_COUNT
} CarrierMetric;

/// The live counter set. Each field is read atomically, so a concurrent writer
/// cannot tear a value. This is a per-field diagnostic snapshot, not one
/// transaction across all fields: related counters can reflect adjacent instants.
CarrierDiagnostics carrier_diagnostics_get(void);

/// Clears every counter and the gauge using atomic stores. Call only when no
/// producer is active; resetting during traffic can discard an update.
void carrier_diagnostics_reset(void);

/// Adds `delta` to one counter, saturating at UINT32_MAX. Returns false for an
/// out-of-range metric, so a caller cannot silently record a phantom
/// measurement and leave it looking like a real one.
bool carrier_diagnostics_add(CarrierMetric metric, uint32_t delta);

/// Reads one counter, or 0 for an out-of-range metric.
uint32_t carrier_diagnostics_get_metric(CarrierMetric metric);

/// Sets the subscription gauge and raises the high-water mark when it grows.
/// The mark only ever grows, so a reader can see whether subscriptions leaked
/// over a long run without keeping a sample history the device cannot afford.
void carrier_diagnostics_set_active_subscriptions(uint32_t active);

/// Writes the counter set as one bounded JSON object into `buffer`, with no
/// trailing newline and no heap allocation. Returns the number of bytes
/// written, not counting the terminating null, or 0 when the buffer is too
/// small. A caller must treat 0 as "the report did not fit", never as a
/// report of zero counts.
size_t carrier_diagnostics_write_json(char *buffer, size_t capacity);

/// A fixed buffer size that always suffices for the JSON, including its null.
size_t carrier_diagnostics_json_capacity(void);

// This module classifies nothing.
//
// It exposes only "add to a counter" and "set this gauge". Deciding *which*
// counter a given event belongs to belongs to the carrier that observes the
// event, and deciding *what an outcome means* belongs to whoever owns the
// contract for that outcome. This header deliberately does not include the
// Core-owned facade header, so a second translation table of facade result
// codes cannot grow up here: a new facade code needs a case added in one place,
// and this module needs no change at all.

#endif
