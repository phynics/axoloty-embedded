// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_CARRIER_SCENARIO_H
#define AXOLOTY_ZENOH_CARRIER_SCENARIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Transport-owned carrier scenario core for the C-only Zenoh qualification.
//
// It drives the façade contract (`axoloty_zenoh.h`) and the transport's own
// counters (`carrier_diagnostics.h`) through the qualification steps: cold
// boot and session lifecycle, bidirectional traffic, router absent then
// present, queue saturation, continuous traffic, maximum and oversized
// payload, clean shutdown, and repeated reconnect. It emits the steps and the
// counter snapshot as JSON Lines through a caller-supplied sink, using the
// transport's bounded reporting shim.
//
// It owns carrier mechanics only. It names no protocol token, imports no Core
// protocol type, and knows nothing about Coaty. The key bytes it carries are
// opaque route bytes: the scenario never interprets them and never derives a
// rule from them.

/// Resource reads a device run reports. A host run names none of them.
typedef enum {
    ZENOH_RESOURCE_FREE_HEAP_BYTES = 0,
    ZENOH_RESOURCE_MIN_FREE_HEAP_BYTES,
    ZENOH_RESOURCE_LARGEST_FREE_BLOCK_BYTES,
    ZENOH_RESOURCE_MAIN_STACK_HIGH_WATER_BYTES,
    ZENOH_RESOURCE_WORKER_STACK_HIGH_WATER_BYTES,
    ZENOH_RESOURCE_STEADY_STATE_ALLOCATIONS,
    ZENOH_RESOURCE_COUNT
} ZenohResourceMetric;

/// Everything the scenario needs from the world it runs in.
///
/// A host run supplies every hook. A device run supplies the ones it can and
/// leaves the rest `NULL`, and the step that needed a missing hook records
/// `unavailable` instead of a pass. That is deliberate: an unobservable step
/// is not a passing one.
typedef struct {
    /// Emits one complete JSON line, without its trailing newline.
    void (*emit_jsonl)(const char *line, uint32_t length, void *context);
    void *emit_context;

    /// Monotonic microseconds, used only to bound a receive wait.
    int64_t (*now_us)(void *context);

    /// Sleeps for a bounded wait between receive attempts.
    void (*delay_ms)(uint32_t milliseconds, void *context);

    /// Delivers a just-published frame back to a live subscriber.
    ///
    /// A host fake has no router, so the host supplies this to model the
    /// router's delivery. A device run links to a real router and leaves it
    /// `NULL`, and the receive path waits on the router instead.
    void (*loopback)(const uint8_t *key, uint32_t key_length, const uint8_t *payload,
                     uint32_t payload_length, void *context);

    /// Drops or restores the router so the scenario can observe both states.
    ///
    /// Returns true when the environment can model the transition. A host
    /// supplies it; a device leaves it `NULL` and records that step
    /// `unavailable`, because forcing router loss on real hardware is an
    /// operator action, not a carrier mechanic.
    bool (*set_router_available)(bool available, void *context);

    /// Arms the next full-queue notification so the drain observes one.
    ///
    /// A host fake drops silently; a real router reports the drop. The host
    /// supplies this to exercise the same received-drop path. A device leaves
    /// it `NULL`.
    void (*arm_queue_full_notification)(void *context);

    /// Reads one resource metric into `out_value`, returning false when the
    /// environment cannot answer. A host returns false for every metric.
    bool (*read_resource)(ZenohResourceMetric metric, uint32_t *out_value, void *context);

    /// Bytes of the built flash image, or 0 when unknown.
    uint32_t flash_image_bytes;

    /// Opaque context passed back to every hook.
    void *context;
} ZenohScenarioEnvironment;

/// Bounded inputs. The scenario never reads past these lengths.
typedef struct {
    /// Borrowed connect endpoint bytes, or `NULL` and 0 to scout. Opaque.
    const uint8_t *connect_endpoint;
    uint32_t connect_endpoint_length;

    /// Borrowed route bytes, carried unchanged. The scenario never interprets
    /// them. Non-empty and at most the façade key limit.
    const uint8_t *key;
    uint32_t key_length;

    /// Open/close cycles for the repeated-reconnect step.
    uint32_t reconnect_cycles;

    /// Publish/receive pairs for the continuous-traffic step.
    uint32_t continuous_frames;
} ZenohScenarioConfig;

/// Runs the whole scenario, emitting one JSON line per step and a final
/// summary line.
///
/// Returns 0 when every step passed and none was unavailable, 1 when any step
/// failed, and 64 when the arguments are rejected. It allocates nothing; its
/// working storage is file-scope and the scenario owns it for the run.
int zenoh_carrier_scenario_run(const ZenohScenarioConfig *config,
                               const ZenohScenarioEnvironment *environment);

#endif
