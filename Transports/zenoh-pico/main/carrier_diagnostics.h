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
// - **Concurrent-safe, and written from two task contexts.** The carrier task
//   records publishes, session outcomes, and reconnect observations; a receive
//   callback runs on a carrier-owned task. Both touch these fields, so every
//   update is one atomic operation.

/// Bounded carrier diagnostics. Every field is a count since the last reset,
/// except `active_subscriptions` and `active_subscriptions_peak`, which are
/// gauges.
typedef struct {
    /// Publications the carrier handed to its transport.
    uint32_t publish_attempts;
    /// The subset of those the transport refused.
    uint32_t publish_failures;
    /// Frames copied out of the receive path into caller storage.
    uint32_t frames_received;
    /// Frames the carrier's receive path reported as dropped.
    uint32_t frames_dropped;
    /// Frames the carrier's receive path rejected as exceeding its bound.
    uint32_t frames_oversized;
    /// Receive attempts that failed for a reason other than a drop, an
    /// oversize frame, or an empty queue.
    uint32_t poll_errors;
    /// Sessions opened successfully.
    uint32_t session_opens;
    /// Sessions closed successfully.
    uint32_t session_closes;
    /// Every failed session or subscription operation the carrier saw.
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

// The single process-wide counter set. It is fixed storage, so there is
// nothing to allocate and nothing to free.
extern CarrierDiagnostics carrier_diagnostics_state;

/// The live counter set. A concurrent writer may be mid-update, which is
/// acceptable for a diagnostic snapshot: every field is naturally aligned and
/// updated with a single atomic word operation, so a reader sees a valid value
/// and never a torn one.
CarrierDiagnostics carrier_diagnostics_get(void);

/// Clears every counter and the gauge. Used at boot and by the qualification
/// runner between phases, so each phase reports against a known zero.
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

/// The buffer size `carrier_diagnostics_write_json` always needs, including the
/// terminating null. Lets a caller size storage once instead of guessing.
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
