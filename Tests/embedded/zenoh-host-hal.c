// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host-only fake carrier for the embedded Zenoh transport seam.
//
// It implements the `axoloty_zenoh_*` C operations with deterministic
// counters and a single canned inbound sample, so the Swift client's operation
// order and byte bounds can be tested with no board, no SDK, no broker, and no
// zenoh-pico. It is never part of a firmware image.

#include "zenoh_sample_validation.h"
#include "zenoh_carrier.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum {
    FAIL_OPEN = 1 << 0,
    FAIL_SUBSCRIBE = 1 << 1,
    FAIL_PUBLISH = 1 << 2,
    FAIL_POLL = 1 << 3,
    FAIL_UNSUBSCRIBE = 1 << 4,
    FAIL_CLOSE = 1 << 5,
};

enum {
    CALL_OPEN = 0,
    CALL_SUBSCRIBE = 1,
    CALL_PUBLISH = 2,
    CALL_POLL = 3,
    CALL_UNSUBSCRIBE = 4,
    CALL_CLOSE = 5,
    CALL_COUNT = 6,
};

static unsigned host_failures;
static unsigned host_calls[CALL_COUNT];
static unsigned char host_sample_key[256];
static unsigned char host_sample_payload[2048];
static int host_sample_key_length;
static int host_sample_payload_length;
static int host_sample_present;

void host_zenoh_reset(void) {
    host_failures = 0;
    memset(host_calls, 0, sizeof(host_calls));
    host_sample_key_length = 0;
    host_sample_payload_length = 0;
    host_sample_present = 0;
}

void host_zenoh_set_failures(unsigned failures) { host_failures = failures; }

unsigned host_zenoh_call_count(unsigned operation) {
    return operation < (unsigned)CALL_COUNT ? host_calls[operation] : 0;
}

void host_zenoh_set_sample(
    const unsigned char *key, int key_length,
    const unsigned char *payload, int payload_length) {
    if (!key || key_length <= 0 || key_length > (int)sizeof(host_sample_key) ||
        payload_length < 0 || payload_length > (int)sizeof(host_sample_payload) ||
        (payload_length > 0 && !payload)) {
        return;
    }
    memcpy(host_sample_key, key, (size_t)key_length);
    host_sample_key_length = key_length;
    if (payload_length > 0) {
        memcpy(host_sample_payload, payload, (size_t)payload_length);
    }
    host_sample_payload_length = payload_length;
    host_sample_present = 1;
}

int axoloty_zenoh_open(
    const unsigned char *endpoint, int endpoint_length,
    unsigned int deadline_ms) {
    (void)endpoint; (void)endpoint_length; (void)deadline_ms;
    ++host_calls[CALL_OPEN];
    return (host_failures & FAIL_OPEN) == 0;
}

int axoloty_zenoh_subscribe(
    const unsigned char *key, int key_length,
    unsigned int deadline_ms) {
    (void)key; (void)key_length; (void)deadline_ms;
    ++host_calls[CALL_SUBSCRIBE];
    return (host_failures & FAIL_SUBSCRIBE) == 0;
}

int axoloty_zenoh_publish(
    const unsigned char *key, int key_length,
    const unsigned char *payload, int payload_length) {
    (void)key; (void)key_length; (void)payload; (void)payload_length;
    ++host_calls[CALL_PUBLISH];
    return (host_failures & FAIL_PUBLISH) == 0;
}

int axoloty_zenoh_poll(
    unsigned char *key, int key_capacity, int *key_length,
    unsigned char *payload, int payload_capacity, int *payload_length,
    unsigned int deadline_ms) {
    (void)deadline_ms;
    ++host_calls[CALL_POLL];
    if ((host_failures & FAIL_POLL) != 0 || !host_sample_present ||
        !key || key_capacity < host_sample_key_length || !key_length ||
        !payload_length || payload_capacity < host_sample_payload_length) {
        return 0;
    }
    memcpy(key, host_sample_key, (size_t)host_sample_key_length);
    *key_length = host_sample_key_length;
    if (host_sample_payload_length > 0) {
        memcpy(payload, host_sample_payload, (size_t)host_sample_payload_length);
    }
    *payload_length = host_sample_payload_length;
    host_sample_present = 0;
    return 1;
}

int axoloty_zenoh_unsubscribe(void) {
    ++host_calls[CALL_UNSUBSCRIBE];
    return (host_failures & FAIL_UNSUBSCRIBE) == 0;
}

int axoloty_zenoh_close(void) {
    ++host_calls[CALL_CLOSE];
    return (host_failures & FAIL_CLOSE) == 0;
}

int host_zenoh_sample_validation_tests(void) {
    static const char key[] = "sample/key";
    static const char payload[] = "sample/payload";
    if (!axoloty_zenoh_sample_is_valid(key, (int)strlen(key), payload, (int)strlen(payload))) return 0;
    if (axoloty_zenoh_sample_is_valid(NULL, 1, payload, 1)) return 0;
    if (axoloty_zenoh_sample_is_valid(key, 0, payload, 1)) return 0;
    if (!axoloty_zenoh_sample_is_valid(key, 256, payload, 0)) return 0;
    if (axoloty_zenoh_sample_is_valid(key, 257, payload, 0)) return 0;
    if (!axoloty_zenoh_sample_is_valid(key, (int)strlen(key), NULL, 0)) return 0;
    if (!axoloty_zenoh_sample_is_valid(key, (int)strlen(key), payload, 2048)) return 0;
    if (axoloty_zenoh_sample_is_valid(key, (int)strlen(key), payload, 2049)) return 0;
    if (axoloty_zenoh_sample_is_valid(key, (int)strlen(key), NULL, 2)) return 0;
    return 1;
}
