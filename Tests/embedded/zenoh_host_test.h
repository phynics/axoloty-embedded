// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_HOST_TEST_H
#define AXOLOTY_ZENOH_HOST_TEST_H

#include <stdint.h>

enum {
    HOST_ZENOH_FAIL_OPEN = 1 << 0,
    HOST_ZENOH_FAIL_SUBSCRIBE = 1 << 1,
    HOST_ZENOH_FAIL_PUBLISH = 1 << 2,
    HOST_ZENOH_FAIL_POLL = 1 << 3,
    HOST_ZENOH_FAIL_UNSUBSCRIBE = 1 << 4,
    HOST_ZENOH_FAIL_CLOSE = 1 << 5,
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

/// The bounded-sample guard vectors.
int host_zenoh_sample_validation_tests(void);

/// The bounded receive queue, its drop counters, and the handle generations,
/// checked against the real `zenoh_pico_queue` the device links.
int host_zenoh_queue_tests(void);

#endif
