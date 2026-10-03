// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_HOST_TEST_H
#define AXOLOTY_ZENOH_HOST_TEST_H

#include <stdint.h>

// The real endpoint helper declaration, so the host test binds the same
// signature the firmware image compiles. The C build supplies the header's
// directory; the Swift build receives it through this umbrella.
#include "zenoh_endpoint.h"

enum {
    HOST_ZENOH_FAIL_OPEN = 1 << 0,
    HOST_ZENOH_FAIL_SUBSCRIBE = 1 << 1,
    HOST_ZENOH_FAIL_PUBLISH = 1 << 2,
    HOST_ZENOH_FAIL_POLL = 1 << 3,
    HOST_ZENOH_FAIL_UNSUBSCRIBE = 1 << 4,
    HOST_ZENOH_FAIL_CLOSE = 1 << 5,
    HOST_ZENOH_FAIL_ROUTERS = 1 << 6,
    HOST_ZENOH_FAIL_ROUTER_DROP_AFTER_ONE = 1 << 7,
    HOST_ZENOH_FAIL_ROUTER_DROP_THEN_RESTORE = 1 << 8,
    HOST_ZENOH_FAIL_ROUTER_COUNT_ERROR = 1 << 9,
    HOST_ZENOH_FAIL_ROUTER_DROP_RESTORE_BEFORE_ENTRY = 1 << 10,
    HOST_ZENOH_FAIL_ROUTER_APPEARS_AFTER_DEADLINE = 1 << 11,
};

void host_zenoh_reset(void);
void host_zenoh_set_failures(unsigned failures);
unsigned host_zenoh_call_count(unsigned operation);
unsigned host_zenoh_session_multicast(unsigned session_index);
uint32_t host_zenoh_session_endpoint_length(unsigned session_index);
uint32_t host_zenoh_publish_key_length(void);
uint32_t host_zenoh_publish_payload_length(void);
void host_zenoh_set_sample(
    const unsigned char *key, int key_length,
    const unsigned char *payload, int payload_length);

/// Deterministic platform clock backing the carrier's deadline waits.
/// `vTaskDelay` advances it instead of sleeping at the configured host rate.
int64_t esp_timer_get_time(void);
void vTaskDelay(uint32_t ticks);
int64_t host_zenoh_fake_time_us(void);
uint32_t host_zenoh_router_query_count(void);
uint32_t host_zenoh_scheduler_hz(void);
void host_zenoh_set_scheduler_hz(uint32_t hz);

/// The bounded-sample guard vectors.
int host_zenoh_sample_validation_tests(void);

/// The bounded receive queue, its drop counters, and the handle generations,
/// checked against the real `zenoh_pico_queue` the device links.
int host_zenoh_queue_tests(void);

#endif
