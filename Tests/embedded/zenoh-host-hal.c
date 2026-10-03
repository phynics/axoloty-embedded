// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host-only fake carrier for the embedded Zenoh transport seam.
//
// It implements the Core-owned `axoloty_zenoh_*` ABI with deterministic
// counters and canned frames, so the Swift client's operation order, handle
// lifetime, and byte bounds can be tested with no board, no SDK, no broker,
// and no zenoh-pico. It is never part of a firmware image.
//
// The handle values are encoded indices, not pointers into fake structs, so
// this file never defines `struct axoloty_zenoh_session` or
// `struct axoloty_zenoh_subscription`. The real registry that owns those
// definitions is linked into the same test binary, and two different
// definitions of one type in one program is undefined behavior.

#include "axoloty_zenoh.h"
#include "zenoh_host_test.h"
#include "zenoh_sample_validation.h"

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
    FAIL_ROUTERS = 1 << 6,
    FAIL_ROUTER_DROP_AFTER_ONE = 1 << 7,
    FAIL_ROUTER_DROP_THEN_RESTORE = 1 << 8,
    FAIL_ROUTER_COUNT_ERROR = 1 << 9,
    FAIL_ROUTER_DROP_RESTORE_BEFORE_ENTRY = 1 << 10,
    FAIL_ROUTER_APPEARS_AFTER_DEADLINE = 1 << 11,
    // Report a pending drop to the next poll. The real queue sets this when a
    // full queue refuses the newest frame; here it is asked for directly, so
    // the carrier's drop-counter path is observable without racing a producer.
    // These two start at bit 12, not bit 11: bit 11 belongs to the
    // late-router vector, and two vectors sharing a bit would make each test
    // silently drive the other's path instead of the one it names.
    REPORT_QUEUE_FULL = 1 << 12,
    // Report a rejected over-bound frame to the next poll, exactly as the real
    // queue does when its bounded-sample guard refuses a frame.
    REPORT_FRAME_TOO_LARGE = 1 << 13,
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

#define HOST_MAX_SESSIONS 4
#define HOST_MAX_SUBSCRIPTIONS 8
#define HOST_QUEUE_CAPACITY 4

typedef struct {
    uint32_t generation;
    uint32_t depth;
    uint32_t key_length;
    uint32_t payload_length;
    uint8_t key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
    uint8_t payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
} HostSubscription;

static unsigned host_failures;
static unsigned host_calls[CALL_COUNT];
static int host_session_open[HOST_MAX_SESSIONS];
static int host_session_mode[HOST_MAX_SESSIONS];
static uint32_t host_session_endpoint_length[HOST_MAX_SESSIONS];
static uint8_t host_session_endpoint[HOST_MAX_SESSIONS][AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES];
static uint8_t host_session_multicast[HOST_MAX_SESSIONS];
static int host_subscription_live[HOST_MAX_SESSIONS][HOST_MAX_SUBSCRIPTIONS];
static uint32_t host_subscription_generation[HOST_MAX_SESSIONS][HOST_MAX_SUBSCRIPTIONS];
static HostSubscription host_subscriptions[HOST_MAX_SESSIONS][HOST_MAX_SUBSCRIPTIONS];
static uint32_t host_last_publish_key_length;
static uint32_t host_last_publish_payload_length;

// Deterministic platform clock for the carrier's deadline waits. Delaying
// advances the clock instead of sleeping, so timeout tests run instantly and
// repeatably. Reset with host_zenoh_reset.
static int64_t host_fake_time_us;
static int host_router_zero_observed;
static uint32_t host_router_query_count;
static uint32_t host_scheduler_hz = 1000;

void host_zenoh_reset(void) {
    host_failures = 0;
    memset(host_calls, 0, sizeof(host_calls));
    memset(host_session_open, 0, sizeof(host_session_open));
    memset(host_session_mode, 0, sizeof(host_session_mode));
    memset(host_session_endpoint_length, 0, sizeof(host_session_endpoint_length));
    memset(host_session_endpoint, 0, sizeof(host_session_endpoint));
    memset(host_session_multicast, 0, sizeof(host_session_multicast));
    memset(host_subscription_live, 0, sizeof(host_subscription_live));
    memset(host_subscription_generation, 0, sizeof(host_subscription_generation));
    memset(host_subscriptions, 0, sizeof(host_subscriptions));
    host_last_publish_key_length = 0;
    host_last_publish_payload_length = 0;
    host_fake_time_us = 0;
    host_router_zero_observed = 0;
    host_router_query_count = 0;
    host_scheduler_hz = 1000;
}

void host_zenoh_set_failures(unsigned failures) { host_failures = failures; }

int64_t esp_timer_get_time(void) { return host_fake_time_us; }

void vTaskDelay(uint32_t ticks) {
    host_fake_time_us += (int64_t)ticks * 1000000 / host_scheduler_hz;
}

int64_t host_zenoh_fake_time_us(void) { return host_fake_time_us; }
uint32_t host_zenoh_router_query_count(void) { return host_router_query_count; }

uint32_t host_zenoh_scheduler_hz(void) { return host_scheduler_hz; }

void host_zenoh_set_scheduler_hz(uint32_t hz) {
    host_scheduler_hz = hz == 0 ? 1 : hz;
    host_fake_time_us = 0;
}

unsigned host_zenoh_call_count(unsigned operation) {
    return operation < (unsigned)CALL_COUNT ? host_calls[operation] : 0;
}

unsigned host_zenoh_session_multicast(unsigned session_index) {
    return session_index < HOST_MAX_SESSIONS ? host_session_multicast[session_index] : 0;
}

uint32_t host_zenoh_session_endpoint_length(unsigned session_index) {
    return session_index < HOST_MAX_SESSIONS ? host_session_endpoint_length[session_index] : 0;
}

uint32_t host_zenoh_publish_key_length(void) { return host_last_publish_key_length; }

uint32_t host_zenoh_publish_payload_length(void) { return host_last_publish_payload_length; }

static int decode_session(const axoloty_zenoh_session_t *session) {
    uintptr_t raw = (uintptr_t)session;
    if (raw == 0 || raw > HOST_MAX_SESSIONS) return -1;
    return (int)raw - 1;
}

static int decode_subscription(const axoloty_zenoh_session_t *session,
                               const axoloty_zenoh_subscription_t *subscription,
                               uint32_t *out_generation) {
    int session_index = decode_session(session);
    if (session_index < 0) return -1;
    uintptr_t raw = (uintptr_t)subscription;
    uint32_t generation = (uint32_t)(raw >> 16);
    uint32_t index = (uint32_t)((raw >> 8) & 0xFFu);
    if (generation == 0u || index == 0u || index > HOST_MAX_SUBSCRIPTIONS) return -1;
    if (!host_subscription_live[session_index][index - 1] ||
        host_subscription_generation[session_index][index - 1] != generation) {
        return -1;
    }
    *out_generation = generation;
    return (int)index - 1;
}

static void host_zenoh_push(HostSubscription *subscription, const void *key, uint32_t key_length,
                            const void *payload, uint32_t payload_length) {
    if (subscription->depth >= HOST_QUEUE_CAPACITY) return;
    memcpy(subscription->key, key, key_length);
    if (payload_length > 0) memcpy(subscription->payload, payload, payload_length);
    subscription->key_length = key_length;
    subscription->payload_length = payload_length;
    subscription->depth += 1;
}

axoloty_zenoh_result_t axoloty_zenoh_open(const axoloty_zenoh_config_t *config,
                                          axoloty_zenoh_session_t **out_session) {
    ++host_calls[CALL_OPEN];
    if (!out_session) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_session = NULL;
    if (!config) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (config->mode != AXOLOTY_ZENOH_MODE_CLIENT && config->mode != AXOLOTY_ZENOH_MODE_PEER) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (config->connect_endpoint_length > AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES ||
        (config->connect_endpoint_length > 0u && !config->connect_endpoint)) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    for (uint32_t index = 0; index < config->connect_endpoint_length; ++index) {
        uint8_t byte = config->connect_endpoint[index];
        if (byte < 0x20u || byte > 0x7Eu || byte == '"' || byte == '\\') return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if ((host_failures & FAIL_OPEN) != 0) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    for (int index = 0; index < HOST_MAX_SESSIONS; ++index) {
        if (host_session_open[index]) continue;
        host_session_open[index] = 1;
        host_session_mode[index] = (int)config->mode;
        host_session_multicast[index] = config->multicast_scouting_enabled ? 1u : 0u;
        host_session_endpoint_length[index] = config->connect_endpoint_length;
        if (config->connect_endpoint_length > 0) {
            memcpy(host_session_endpoint[index], config->connect_endpoint, config->connect_endpoint_length);
        }
        *out_session = (axoloty_zenoh_session_t *)(uintptr_t)(index + 1);
        return AXOLOTY_ZENOH_OK;
    }
    return AXOLOTY_ZENOH_CAPACITY_EXCEEDED;
}

axoloty_zenoh_result_t axoloty_zenoh_close(axoloty_zenoh_session_t *session) {
    ++host_calls[CALL_CLOSE];
    int session_index = decode_session(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (!host_session_open[session_index]) return AXOLOTY_ZENOH_NOT_OPEN;
    host_session_open[session_index] = 0;
    if ((host_failures & FAIL_CLOSE) != 0) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_state(const axoloty_zenoh_session_t *session,
                                           axoloty_zenoh_session_state_t *out_state) {
    int session_index = decode_session(session);
    if (session_index < 0 || !out_state) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_state = host_session_open[session_index] ? AXOLOTY_ZENOH_SESSION_OPEN : AXOLOTY_ZENOH_SESSION_CLOSED;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_connected_router_count(const axoloty_zenoh_session_t *session,
                                                            uint32_t *out_count) {
    int session_index = decode_session(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_count = 0;
    if (!host_session_open[session_index]) return AXOLOTY_ZENOH_NOT_OPEN;
    if ((host_failures & FAIL_ROUTER_DROP_THEN_RESTORE) != 0) {
        ++host_router_query_count;
        if (host_router_query_count == 1u) {
            *out_count = 1u;
        } else if (host_router_query_count == 2u) {
            host_router_zero_observed = 1;
        } else {
            *out_count = 1u;
        }
        return AXOLOTY_ZENOH_OK;
    }
    if ((host_failures & FAIL_ROUTER_COUNT_ERROR) != 0) {
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    if ((host_failures & FAIL_ROUTER_DROP_RESTORE_BEFORE_ENTRY) != 0) {
        host_router_zero_observed = 1;
        *out_count = 1;
        return AXOLOTY_ZENOH_OK;
    }
    if ((host_failures & FAIL_ROUTER_APPEARS_AFTER_DEADLINE) != 0) {
        if (host_fake_time_us >= 25000) *out_count = 1;
        else host_router_zero_observed = 1;
        ++host_router_query_count;
        return AXOLOTY_ZENOH_OK;
    }
    if ((host_failures & FAIL_ROUTERS) != 0) {
        host_router_zero_observed = 1;
        return AXOLOTY_ZENOH_OK;
    }
    if ((host_failures & FAIL_ROUTER_DROP_AFTER_ONE) != 0 && !host_router_zero_observed) {
        *out_count = 1;
        return AXOLOTY_ZENOH_OK;
    }
    *out_count = host_session_open[session_index] ? 1u : 0u;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_publish(const axoloty_zenoh_session_t *session,
                                             const uint8_t *key,
                                             uint32_t key_length,
                                             const uint8_t *payload,
                                             uint32_t payload_length) {
    ++host_calls[CALL_PUBLISH];
    int session_index = decode_session(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (!host_session_open[session_index]) return AXOLOTY_ZENOH_NOT_OPEN;
    if (!key || key_length == 0u || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (payload_length > AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES || (payload_length > 0u && !payload)) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    host_last_publish_key_length = key_length;
    host_last_publish_payload_length = payload_length;
    return (host_failures & FAIL_PUBLISH) != 0 ? AXOLOTY_ZENOH_TRANSPORT_ERROR : AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_subscribe(const axoloty_zenoh_session_t *session,
                                               const uint8_t *key,
                                               uint32_t key_length,
                                               axoloty_zenoh_subscription_t **out_subscription) {
    ++host_calls[CALL_SUBSCRIBE];
    if (!out_subscription) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_subscription = NULL;
    int session_index = decode_session(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (!host_session_open[session_index]) return AXOLOTY_ZENOH_NOT_OPEN;
    if (!key || key_length == 0u || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if ((host_failures & FAIL_SUBSCRIBE) != 0) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    for (int index = 0; index < HOST_MAX_SUBSCRIPTIONS; ++index) {
        if (host_subscription_live[session_index][index]) continue;
        host_subscription_live[session_index][index] = 1;
        host_subscription_generation[session_index][index] += 1u;
        if (host_subscription_generation[session_index][index] == 0u) {
            host_subscription_generation[session_index][index] = 1u;
        }
        memset(&host_subscriptions[session_index][index], 0, sizeof(HostSubscription));
        *out_subscription = (axoloty_zenoh_subscription_t *)(uintptr_t)(
            ((uintptr_t)host_subscription_generation[session_index][index] << 16) | ((uintptr_t)(index + 1) << 8));
        return AXOLOTY_ZENOH_OK;
    }
    return AXOLOTY_ZENOH_CAPACITY_EXCEEDED;
}

axoloty_zenoh_result_t axoloty_zenoh_unsubscribe(const axoloty_zenoh_session_t *session,
                                                 axoloty_zenoh_subscription_t *subscription) {
    ++host_calls[CALL_UNSUBSCRIBE];
    int session_index = decode_session(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    uint32_t generation = 0;
    int index = decode_subscription(session, subscription, &generation);
    if (index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if ((host_failures & FAIL_UNSUBSCRIBE) != 0) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    host_subscription_live[session_index][index] = 0;
    memset(&host_subscriptions[session_index][index], 0, sizeof(HostSubscription));
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_poll(const axoloty_zenoh_session_t *session,
                                          const axoloty_zenoh_subscription_t *subscription,
                                          uint8_t *key,
                                          uint32_t key_capacity,
                                          uint32_t *out_key_length,
                                          uint8_t *payload,
                                          uint32_t payload_capacity,
                                          uint32_t *out_payload_length) {
    ++host_calls[CALL_POLL];
    int session_index = decode_session(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    uint32_t generation = 0;
    int index = decode_subscription(session, subscription, &generation);
    if (index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (!key || !out_key_length || !payload || !out_payload_length) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    HostSubscription *state = &host_subscriptions[session_index][index];
    // The real queue reports a pending drop or oversize once, on the first
    // poll that finds the queue drained, and then goes quiet again. Mirroring
    // that exactly is what makes the carrier's counter test meaningful: a
    // counter that counted the notification instead of the event would look
    // right here and wrong on the device.
    if ((host_failures & REPORT_QUEUE_FULL) != 0) {
        host_failures &= ~(unsigned)REPORT_QUEUE_FULL;
        return AXOLOTY_ZENOH_QUEUE_FULL;
    }
    if ((host_failures & REPORT_FRAME_TOO_LARGE) != 0) {
        host_failures &= ~(unsigned)REPORT_FRAME_TOO_LARGE;
        return AXOLOTY_ZENOH_FRAME_TOO_LARGE;
    }
    if (state->depth == 0) return AXOLOTY_ZENOH_QUEUE_EMPTY;
    if (state->key_length > key_capacity || state->payload_length > payload_capacity) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if ((host_failures & FAIL_POLL) != 0) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    memcpy(key, state->key, state->key_length);
    memcpy(payload, state->payload, state->payload_length);
    *out_key_length = state->key_length;
    *out_payload_length = state->payload_length;
    state->depth -= 1;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_queue_depth(const axoloty_zenoh_session_t *session,
                                                 const axoloty_zenoh_subscription_t *subscription,
                                                 uint32_t *out_depth) {
    int session_index = decode_session(session);
    if (session_index < 0 || !out_depth) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    uint32_t generation = 0;
    int index = decode_subscription(session, subscription, &generation);
    if (index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_depth = host_subscriptions[session_index][index].depth;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_dropped_frame_count(const axoloty_zenoh_session_t *session,
                                                         const axoloty_zenoh_subscription_t *subscription,
                                                         uint32_t *out_count) {
    int session_index = decode_session(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    uint32_t generation = 0;
    int index = decode_subscription(session, subscription, &generation);
    if (index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_count = 0;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_oversized_frame_count(const axoloty_zenoh_session_t *session,
                                                            const axoloty_zenoh_subscription_t *subscription,
                                                            uint32_t *out_count) {
    int session_index = decode_session(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    uint32_t generation = 0;
    int index = decode_subscription(session, subscription, &generation);
    if (index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_count = 0;
    return AXOLOTY_ZENOH_OK;
}

void host_zenoh_set_sample(const unsigned char *key, int key_length,
                           const unsigned char *payload, int payload_length) {
    for (int session = 0; session < HOST_MAX_SESSIONS; ++session) {
        for (int index = 0; index < HOST_MAX_SUBSCRIPTIONS; ++index) {
            if (!host_subscription_live[session][index]) continue;
            host_zenoh_push(&host_subscriptions[session][index], key, (uint32_t)key_length, payload,
                            (uint32_t)payload_length);
            return;
        }
    }
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
