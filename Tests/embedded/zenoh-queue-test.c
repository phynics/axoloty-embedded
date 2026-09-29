// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host conformance for the bounded receive state the `zenoh-pico` backend
// links: the fixed session and subscriber registries, the bounded queue, the
// drop counters, and the generation token that rejects a late callback.
//
// It runs the real `zenoh_pico_queue.c` with no board, no SDK, and no
// zenoh-pico, so the bounds and the counters are proved where they are decided
// rather than only on a device.

#include "axoloty_zenoh.h"
#include "zenoh_pico_queue.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const char sample_key[] = "inbound/key";
static const char sample_payload[] = "inbound/payload";

// A real object that is not one of the registry's fixed session slots.
static struct axoloty_zenoh_session foreign_session;

static int frames_match(const uint8_t *key, uint32_t key_length,
                        const uint8_t *payload, uint32_t payload_length) {
    if (key_length != (uint32_t)strlen(sample_key) || payload_length != (uint32_t)strlen(sample_payload)) return 0;
    return memcmp(key, sample_key, key_length) == 0 && memcmp(payload, sample_payload, payload_length) == 0;
}

// One inbound frame, as a Zenoh callback would deliver it: claim the
// declaration, copy into facade-owned storage, then release the claim.
static void deliver_frame(struct axoloty_zenoh_subscription *record) {
    if (!zenoh_pico_callback_claim(record, record->generation)) return;
    (void)zenoh_pico_queue_admit(record->queue, sample_key, (uint32_t)strlen(sample_key), sample_payload,
                                 (uint32_t)strlen(sample_payload));
    zenoh_pico_callback_leave(record);
}

static int registry_tests(void) {
    struct axoloty_zenoh_session *sessions[AXOLOTY_ZENOH_MAX_SESSIONS + 1];
    for (int index = 0; index <= AXOLOTY_ZENOH_MAX_SESSIONS; ++index) {
        sessions[index] = zenoh_pico_session_reserve();
        if (index < AXOLOTY_ZENOH_MAX_SESSIONS && !sessions[index]) return 0;
    }
    // The fixed session capacity is exhausted without partial mutation.
    if (sessions[AXOLOTY_ZENOH_MAX_SESSIONS]) return 0;

    // A foreign handle is not a session slot: neither a real address that is
    // not a slot nor an arbitrary pointer value.
    if (zenoh_pico_session_index(&foreign_session) != -1) return 0;
    if (zenoh_pico_session_index((axoloty_zenoh_session_t *)(uintptr_t)0x1234u) != -1) return 0;
    if (zenoh_pico_session_index(NULL) != -1) return 0;
    if (zenoh_pico_session_at(AXOLOTY_ZENOH_MAX_SESSIONS) != NULL) return 0;

    struct axoloty_zenoh_session *session = sessions[0];
    if (zenoh_pico_session_index(session) != 0) return 0;
    if (session->state != AXOLOTY_ZENOH_SESSION_OPEN) return 0;

    axoloty_zenoh_subscription_t *handles[AXOLOTY_ZENOH_MAX_SUBSCRIBERS + 1];
    for (int index = 0; index <= AXOLOTY_ZENOH_MAX_SUBSCRIBERS; ++index) {
        struct axoloty_zenoh_subscription *record = NULL;
        axoloty_zenoh_result_t reserved = zenoh_pico_subscription_reserve(session, &handles[index], &record);
        if (index < AXOLOTY_ZENOH_MAX_SUBSCRIBERS) {
            if (reserved != AXOLOTY_ZENOH_OK || handles[index] == NULL || record == NULL) return 0;
        } else if (reserved != AXOLOTY_ZENOH_CAPACITY_EXCEEDED || handles[index] != NULL) {
            return 0;
        }
    }

    // A handle from another session is foreign, and a null handle is invalid.
    struct axoloty_zenoh_subscription *resolved = NULL;
    if (zenoh_pico_subscription_resolve(sessions[1], handles[0], &resolved) != AXOLOTY_ZENOH_INVALID_ARGUMENT) {
        return 0;
    }
    if (zenoh_pico_subscription_resolve(session, NULL, &resolved) != AXOLOTY_ZENOH_INVALID_ARGUMENT) return 0;
    if (zenoh_pico_subscription_resolve(session, handles[0], &resolved) != AXOLOTY_ZENOH_OK) return 0;
    if (resolved != &session->subscribers[0]) return 0;

    // Removing a subscription rejects its handle afterwards, and a reused slot
    // rejects the stale handle because the generation moved on.
    struct axoloty_zenoh_subscription *stale_source = &session->subscribers[0];
    zenoh_pico_subscription_release(stale_source);
    if (zenoh_pico_subscription_resolve(session, handles[0], &resolved) != AXOLOTY_ZENOH_INVALID_ARGUMENT) return 0;
    if (zenoh_pico_callback_claim(stale_source, stale_source->generation) != 0) return 0;
    axoloty_zenoh_subscription_t *reused = NULL;
    if (zenoh_pico_subscription_reserve(session, &reused, &resolved) != AXOLOTY_ZENOH_OK) return 0;
    if (reused == handles[0]) return 0;
    if (zenoh_pico_subscription_resolve(session, handles[0], &resolved) != AXOLOTY_ZENOH_INVALID_ARGUMENT) return 0;
    zenoh_pico_subscription_release(resolved);

    // Closing a session releases every subscription it still holds.
    for (int index = 1; index < AXOLOTY_ZENOH_MAX_SUBSCRIBERS; ++index) {
        zenoh_pico_subscription_release(&session->subscribers[index]);
    }
    zenoh_pico_session_release(session);
    if (session->state != AXOLOTY_ZENOH_SESSION_CLOSED) return 0;
    if (zenoh_pico_subscription_reserve(session, &reused, &resolved) != AXOLOTY_ZENOH_NOT_OPEN) return 0;
    for (int index = 1; index < AXOLOTY_ZENOH_MAX_SESSIONS; ++index) {
        zenoh_pico_session_release(sessions[index]);
    }
    // A released slot is reusable.
    struct axoloty_zenoh_session *reused_session = zenoh_pico_session_reserve();
    if (!reused_session) return 0;
    zenoh_pico_session_release(reused_session);
    return 1;
}

static int queue_tests(void) {
    struct axoloty_zenoh_session *session = zenoh_pico_session_reserve();
    if (!session) return 0;
    axoloty_zenoh_subscription_t *handle = NULL;
    struct axoloty_zenoh_subscription *record = NULL;
    if (zenoh_pico_subscription_reserve(session, &handle, &record) != AXOLOTY_ZENOH_OK) return 0;
    ZenohPicoQueue *queue = record->queue;

    uint8_t key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
    uint8_t payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
    uint32_t key_length = 0;
    uint32_t payload_length = 0;

    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_EMPTY) {
        return 0;
    }
    if (zenoh_pico_queue_depth(queue) != 0) return 0;

    // A frame larger than the caller's output buffer is left queued.
    deliver_frame(record);
    if (zenoh_pico_queue_depth(queue) != 1) return 0;
    if (zenoh_pico_queue_poll(queue, key, 1, &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_INVALID_ARGUMENT) {
        return 0;
    }
    if (zenoh_pico_queue_depth(queue) != 1) return 0;
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, 0, &payload_length) !=
        AXOLOTY_ZENOH_INVALID_ARGUMENT) {
        return 0;
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_OK) {
        return 0;
    }
    if (!frames_match(key, key_length, payload, payload_length)) return 0;
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_EMPTY) {
        return 0;
    }

    // A full queue drops the newest frame and counts the drop.
    for (int index = 0; index < ZENOH_PICO_QUEUE_CAPACITY; ++index) deliver_frame(record);
    if (zenoh_pico_queue_depth(queue) != ZENOH_PICO_QUEUE_CAPACITY) return 0;
    deliver_frame(record);
    if (zenoh_pico_queue_depth(queue) != ZENOH_PICO_QUEUE_CAPACITY) return 0;
    if (zenoh_pico_queue_dropped(queue) != 1) return 0;

    // The queued frames are delivered in order, and only then is the pending
    // full-queue drop reported once.
    for (int index = 0; index < ZENOH_PICO_QUEUE_CAPACITY; ++index) {
        if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
            AXOLOTY_ZENOH_OK) {
            return 0;
        }
        if (!frames_match(key, key_length, payload, payload_length)) return 0;
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_FULL) {
        return 0;
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_EMPTY) {
        return 0;
    }
    if (zenoh_pico_queue_dropped(queue) != 1) return 0;

    // A frame the bounded-sample guard rejected is counted and never truncated.
    (void)zenoh_pico_queue_admit(queue, sample_key, (uint32_t)strlen(sample_key), sample_payload,
                                 (uint32_t)AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES + 1u);
    (void)zenoh_pico_queue_admit(queue, sample_key, 0u, sample_payload, 0u);
    if (zenoh_pico_queue_oversized(queue) != 2) return 0;
    if (zenoh_pico_queue_depth(queue) != 0) return 0;
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_FRAME_TOO_LARGE) {
        return 0;
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_EMPTY) {
        return 0;
    }
    if (zenoh_pico_queue_oversized(queue) != 2) return 0;

    // A full-queue notification is reported before an oversized one while both
    // are pending, and both counters stay cumulative.
    for (int index = 0; index < ZENOH_PICO_QUEUE_CAPACITY; ++index) deliver_frame(record);
    deliver_frame(record);
    zenoh_pico_queue_note_oversized(queue);
    for (int index = 0; index < ZENOH_PICO_QUEUE_CAPACITY; ++index) {
        if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
            AXOLOTY_ZENOH_OK) {
            return 0;
        }
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_QUEUE_FULL) {
        return 0;
    }
    if (zenoh_pico_queue_poll(queue, key, sizeof(key), &key_length, payload, sizeof(payload), &payload_length) !=
        AXOLOTY_ZENOH_FRAME_TOO_LARGE) {
        return 0;
    }
    if (zenoh_pico_queue_dropped(queue) != 2 || zenoh_pico_queue_oversized(queue) != 3) return 0;

    // A callback from a removed declaration copies nothing, and removal waits
    // for the claims that are in flight.
    zenoh_pico_subscription_deactivate(record);
    if (zenoh_pico_callback_claim(record, record->generation) != 0) return 0;
    deliver_frame(record);
    if (zenoh_pico_queue_depth(queue) != 0) return 0;
    if (zenoh_pico_callback_claim(record, record->generation + 1u) != 0) return 0;
    zenoh_pico_callback_drain(record);

    zenoh_pico_subscription_release(record);
    zenoh_pico_session_release(session);
    return 1;
}

int host_zenoh_queue_tests(void) { return registry_tests() && queue_tests(); }
