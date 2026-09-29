// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// `zenoh-pico` backend of the Axoloty Zenoh facade.
//
// This file implements the Core-owned `axoloty_zenoh_*` ABI declared in
// `axoloty_zenoh.h` on top of the pinned `zenoh-pico`. It is carrier mechanics
// only: it moves bounded bytes between the facade contract and Zenoh, and it
// decides nothing about what a key means.
//
// Two rules shape the whole file. No Zenoh-owned or Zenoh-loaned type crosses
// the ABI, and no caller or Zenoh pointer is ever retained: every borrowed
// buffer is copied into Zenoh-owned or facade-owned storage and consumed before
// the call returns. The bounded receive queue, its counters, and the session
// and subscriber registries live in `zenoh_pico_queue.c`, which includes no
// Zenoh and no SDK header so the host seam can check them without a board.
//
// A Zenoh callback runs on a Zenoh task. It claims its generation, copies one
// bounded frame into facade-owned storage, and returns. It never calls Swift,
// never allocates, and never keeps Zenoh memory.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "esp_timer.h"
#include "zenoh-pico.h"

#include "axoloty_zenoh.h"
#include "zenoh_pico_queue.h"
#include "zenoh_sample_validation.h"

// The facade contract bounds a single unicast link open. zenoh-pico's stable
// API exposes no open-timeout configuration key in this feature profile, so
// the deadline is enforced as an acceptance check: an open that did not return
// within it is closed and reported as a transport error, and no session is ever
// handed back after it. See docs/zenoh-embedded.md.
#define ZENOH_PICO_OPEN_DEADLINE_MS 5000u

#define ZENOH_PICO_MAX_ENDPOINT_TEXT (AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES + 1u)

static z_owned_session_t zenoh_pico_open_sessions[AXOLOTY_ZENOH_MAX_SESSIONS];
static z_owned_subscriber_t
    zenoh_pico_declared_subscribers[AXOLOTY_ZENOH_MAX_SUBSCRIBERS][AXOLOTY_ZENOH_MAX_SUBSCRIBERS];

// An endpoint is configuration, not a routing key. It is validated before any
// Zenoh call so a malformed one never reaches the protocol. A zero-length
// endpoint carries no bytes, so its pointer is not read.
static bool endpoint_is_valid(const axoloty_zenoh_config_t *config) {
    if (config->connect_endpoint_length > AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES) return false;
    if (config->connect_endpoint_length == 0u) return true;
    if (!config->connect_endpoint) return false;
    for (uint32_t index = 0; index < config->connect_endpoint_length; ++index) {
        uint8_t byte = config->connect_endpoint[index];
        // Printable ASCII, and neither a quote nor a backslash, which the
        // JSON5 configuration value cannot carry unescaped.
        if (byte < 0x20u || byte > 0x7Eu || byte == '"' || byte == '\\') return false;
    }
    return true;
}

static uint32_t milliseconds_since(int64_t start) {
    return (uint32_t)((esp_timer_get_time() - start) / 1000);
}

static const z_loaned_session_t *session_loan(int session_index) {
    return z_loan(zenoh_pico_open_sessions[session_index]);
}

// Closing a session is the one Zenoh call that takes its loan mutably.
static z_loaned_session_t *session_loan_mutable(int session_index) {
    return z_loan_mut(zenoh_pico_open_sessions[session_index]);
}

// Zenoh invokes this count-only callback once per connected router and never
// concurrently, so a plain counter is enough.
static void count_connected_router(const z_id_t *zid, void *context) {
    (void)zid;
    if (context) ++*(uint32_t *)context;
}

// One bounded inbound sample. The sample is borrowed for the duration of this
// call: the key is read through a view, the payload is copied into a Zenoh-owned
// string, and both are copied into facade-owned queue storage or dropped.
static void receive_sample(z_loaned_sample_t *sample, void *context) {
    ZenohPicoQueue *queue = (ZenohPicoQueue *)context;
    if (!queue || !sample) return;
    struct axoloty_zenoh_session *session = zenoh_pico_session_at((int)queue->session_index);
    if (!session) return;
    struct axoloty_zenoh_subscription *record = &session->subscribers[queue->subscriber_index];
    if (!zenoh_pico_callback_claim(record, queue->generation)) return;

    z_view_string_t key_view;
    const void *key = NULL;
    size_t key_length = 0;
    if (z_keyexpr_as_view_string(z_sample_keyexpr(sample), &key_view) == 0) {
        const z_loaned_string_t *key_string = z_view_string_loan(&key_view);
        key = (const void *)z_string_data(key_string);
        key_length = z_string_len(key_string);
    }

    z_owned_string_t payload_string;
    const void *payload = NULL;
    size_t payload_length = 0;
    bool payload_copied = false;
    if (z_bytes_to_string(z_sample_payload(sample), &payload_string) == 0) {
        const z_loaned_string_t *payload_view = z_string_loan(&payload_string);
        payload = (const void *)z_string_data(payload_view);
        payload_length = z_string_len(payload_view);
        payload_copied = true;
    }

    // The bounded-sample guard is the single admission rule: an empty key, an
    // oversize key, an oversize payload, or a null buffer is dropped rather
    // than truncated.
    if (key_length == 0u || key_length > (size_t)INT32_MAX || payload_length > (size_t)INT32_MAX ||
        !axoloty_zenoh_sample_is_valid(key, (int)key_length, payload, (int)payload_length)) {
        zenoh_pico_queue_note_oversized(queue);
    } else {
        (void)zenoh_pico_queue_admit(queue, key, (uint32_t)key_length, payload, (uint32_t)payload_length);
    }

    if (payload_copied) z_string_drop(z_string_move(&payload_string));
    zenoh_pico_callback_leave(record);
}

static void remove_subscription(const axoloty_zenoh_session_t *session, int subscriber_index) {
    struct axoloty_zenoh_subscription *record = zenoh_pico_session_subscriber(session, subscriber_index);
    if (!record) return;
    int session_index = zenoh_pico_session_index(session);
    // A callback that starts after this point copies nothing, and the ones
    // already copying are waited for before the queue is released.
    zenoh_pico_subscription_deactivate(record);
    (void)z_undeclare_subscriber(z_move(zenoh_pico_declared_subscribers[session_index][subscriber_index]));
    zenoh_pico_subscription_release(record);
}

axoloty_zenoh_result_t axoloty_zenoh_open(const axoloty_zenoh_config_t *config,
                                          axoloty_zenoh_session_t **out_session) {
    if (!out_session) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_session = NULL;
    if (!config) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (config->mode != AXOLOTY_ZENOH_MODE_CLIENT && config->mode != AXOLOTY_ZENOH_MODE_PEER) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!endpoint_is_valid(config)) return AXOLOTY_ZENOH_INVALID_ARGUMENT;

    struct axoloty_zenoh_session *session = zenoh_pico_session_reserve();
    if (!session) return AXOLOTY_ZENOH_CAPACITY_EXCEEDED;
    int session_index = zenoh_pico_session_index(session);

    // The borrowed endpoint is copied into a bounded, terminated buffer here,
    // so no caller pointer reaches Zenoh and none outlives this call.
    char endpoint[ZENOH_PICO_MAX_ENDPOINT_TEXT];
    endpoint[0] = '\0';
    if (config->connect_endpoint_length > 0u) {
        memcpy(endpoint, config->connect_endpoint, config->connect_endpoint_length);
        endpoint[config->connect_endpoint_length] = '\0';
    }

    bool peer = config->mode == AXOLOTY_ZENOH_MODE_PEER;
    z_owned_config_t zenoh_config;
    if (z_config_default(&zenoh_config) < 0) {
        zenoh_pico_session_release(session);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    int inserted = zp_config_insert(z_loan_mut(zenoh_config), Z_CONFIG_MODE_KEY,
                                    peer ? Z_CONFIG_MODE_PEER : Z_CONFIG_MODE_CLIENT);
    if (inserted == 0 && config->connect_endpoint_length > 0u) {
        // A client connects to its endpoint and a peer listens on it, which is
        // how zenoh-pico reads one locator per mode.
        inserted = zp_config_insert(z_loan_mut(zenoh_config),
                                    peer ? Z_CONFIG_LISTEN_KEY : Z_CONFIG_CONNECT_KEY, endpoint);
    }
    if (inserted == 0) {
        inserted = zp_config_insert(z_loan_mut(zenoh_config), Z_CONFIG_MULTICAST_SCOUTING_KEY,
                                    config->multicast_scouting_enabled ? "true" : "false");
    }
    if (inserted < 0) {
        z_drop(z_move(zenoh_config));
        zenoh_pico_session_release(session);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }

    int64_t started = esp_timer_get_time();
    z_owned_session_t zenoh_session;
    if (z_open(&zenoh_session, z_move(zenoh_config), NULL) < 0) {
        zenoh_pico_session_release(session);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    if (milliseconds_since(started) > ZENOH_PICO_OPEN_DEADLINE_MS) {
        z_drop(z_move(zenoh_session));
        zenoh_pico_session_release(session);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }

    zenoh_pico_open_sessions[session_index] = zenoh_session;
    *out_session = session;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_close(axoloty_zenoh_session_t *session) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (session->state != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;

    for (int index = 0; index < AXOLOTY_ZENOH_MAX_SUBSCRIBERS; ++index) {
        if (session->subscribers[index].queue) remove_subscription(session, index);
    }
    int closed = z_close(session_loan_mutable(session_index), NULL);
    // Every release path frees the handle, so a reported close failure still
    // leaves the slot closed.
    z_drop(z_move(zenoh_pico_open_sessions[session_index]));
    zenoh_pico_session_release(session);
    return closed == 0 ? AXOLOTY_ZENOH_OK : AXOLOTY_ZENOH_TRANSPORT_ERROR;
}

axoloty_zenoh_result_t axoloty_zenoh_state(const axoloty_zenoh_session_t *session,
                                           axoloty_zenoh_session_state_t *out_state) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0 || !out_state) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_state = session->state == AXOLOTY_ZENOH_SESSION_OPEN ? AXOLOTY_ZENOH_SESSION_OPEN
                                                              : AXOLOTY_ZENOH_SESSION_CLOSED;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_connected_router_count(const axoloty_zenoh_session_t *session,
                                                            uint32_t *out_count) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_count = 0u;
    if (session->state != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;
    uint32_t count = 0u;
    z_owned_closure_zid_t closure;
    z_closure(&closure, count_connected_router, NULL, &count);
    if (z_info_routers_zid(session_loan(session_index), z_move(closure)) < 0) {
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    *out_count = count;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_publish(const axoloty_zenoh_session_t *session,
                                             const uint8_t *key,
                                             uint32_t key_length,
                                             const uint8_t *payload,
                                             uint32_t payload_length) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (session->state != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;
    if (!key || key_length == 0u || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (payload_length > AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES || (payload_length > 0u && !payload)) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }

    // Both values are Zenoh-owned before Zenoh sees them, so the borrowed
    // caller buffers are never retained.
    z_owned_keyexpr_t zenoh_key;
    if (z_keyexpr_from_substr(&zenoh_key, (const char *)key, (size_t)key_length) < 0) {
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    z_owned_bytes_t zenoh_payload;
    if (payload_length == 0u) {
        z_bytes_empty(&zenoh_payload);
    } else if (z_bytes_copy_from_buf(&zenoh_payload, payload, (size_t)payload_length) < 0) {
        z_drop(z_move(zenoh_key));
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    int published = z_put(session_loan(session_index), z_loan(zenoh_key), z_move(zenoh_payload), NULL);
    z_drop(z_move(zenoh_key));
    return published == 0 ? AXOLOTY_ZENOH_OK : AXOLOTY_ZENOH_TRANSPORT_ERROR;
}

axoloty_zenoh_result_t axoloty_zenoh_subscribe(const axoloty_zenoh_session_t *session,
                                               const uint8_t *key,
                                               uint32_t key_length,
                                               axoloty_zenoh_subscription_t **out_subscription) {
    if (!out_subscription) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_subscription = NULL;
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (session->state != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;
    if (!key || key_length == 0u || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }

    axoloty_zenoh_subscription_t *handle = NULL;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t reserved = zenoh_pico_subscription_reserve(session, &handle, &record);
    if (reserved != AXOLOTY_ZENOH_OK) return reserved;
    int subscriber_index = (int)record->subscriber_index;

    z_owned_keyexpr_t zenoh_key;
    if (z_keyexpr_from_substr(&zenoh_key, (const char *)key, (size_t)key_length) < 0) {
        zenoh_pico_subscription_release(record);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    z_owned_closure_sample_t closure;
    z_closure(&closure, receive_sample, NULL, record->queue);
    int declared = z_declare_subscriber(session_loan(session_index),
                                        &zenoh_pico_declared_subscribers[session_index][subscriber_index],
                                        z_loan(zenoh_key), z_move(closure), NULL);
    z_drop(z_move(zenoh_key));
    if (declared < 0) {
        zenoh_pico_subscription_release(record);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    *out_subscription = handle;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_unsubscribe(const axoloty_zenoh_session_t *session,
                                                 axoloty_zenoh_subscription_t *subscription) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t resolved = zenoh_pico_subscription_resolve(session, subscription, &record);
    if (resolved != AXOLOTY_ZENOH_OK) return resolved;
    remove_subscription(session, (int)record->subscriber_index);
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
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t resolved = zenoh_pico_subscription_resolve(session, subscription, &record);
    if (resolved != AXOLOTY_ZENOH_OK) return resolved;
    if (!key || !out_key_length || !payload || !out_payload_length) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    return zenoh_pico_queue_poll(record->queue, key, key_capacity, out_key_length, payload, payload_capacity,
                                 out_payload_length);
}

axoloty_zenoh_result_t axoloty_zenoh_queue_depth(const axoloty_zenoh_session_t *session,
                                                 const axoloty_zenoh_subscription_t *subscription,
                                                 uint32_t *out_depth) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0 || !out_depth) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t resolved = zenoh_pico_subscription_resolve(session, subscription, &record);
    if (resolved != AXOLOTY_ZENOH_OK) return resolved;
    *out_depth = zenoh_pico_queue_depth(record->queue);
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_dropped_frame_count(const axoloty_zenoh_session_t *session,
                                                         const axoloty_zenoh_subscription_t *subscription,
                                                         uint32_t *out_count) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t resolved = zenoh_pico_subscription_resolve(session, subscription, &record);
    if (resolved != AXOLOTY_ZENOH_OK) return resolved;
    *out_count = zenoh_pico_queue_dropped(record->queue);
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_oversized_frame_count(const axoloty_zenoh_session_t *session,
                                                            const axoloty_zenoh_subscription_t *subscription,
                                                            uint32_t *out_count) {
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0 || !out_count) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    struct axoloty_zenoh_subscription *record = NULL;
    axoloty_zenoh_result_t resolved = zenoh_pico_subscription_resolve(session, subscription, &record);
    if (resolved != AXOLOTY_ZENOH_OK) return resolved;
    *out_count = zenoh_pico_queue_oversized(record->queue);
    return AXOLOTY_ZENOH_OK;
}
