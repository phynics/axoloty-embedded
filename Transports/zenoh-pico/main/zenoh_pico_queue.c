// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "zenoh_pico_queue.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// A handle carries the whole identity of one subscription, so a handle copied
// out of its session, or out of a slot that was reused, is rejected instead of
// addressing a live queue. The subscriber index and the session index each
// take their exact bit width, and the generation takes the rest.
#define ZENOH_PICO_HANDLE_SUBSCRIBER_MASK 0x07u
#define ZENOH_PICO_HANDLE_SESSION_SHIFT 3u
#define ZENOH_PICO_HANDLE_SESSION_MASK 0x03u
#define ZENOH_PICO_HANDLE_GENERATION_SHIFT 5u

_Static_assert(AXOLOTY_ZENOH_MAX_SUBSCRIBERS == 8, "the handle layout assumes eight subscriber slots");
_Static_assert(AXOLOTY_ZENOH_MAX_SESSIONS == 4, "the handle layout assumes four session slots");

// A callback copies at most one bounded frame, so a bounded spin is a bound on
// the wait, not a guess: it ends when the last in-flight callback returns.
#define ZENOH_PICO_DRAIN_SPIN_LIMIT 10000u

static struct axoloty_zenoh_session zenoh_pico_session_slots[AXOLOTY_ZENOH_MAX_SESSIONS];

// The ABI takes a session handle as a const pointer, because a caller must not
// mutate a session through it. The registry owns the slots and validates the
// handle first, so reaching the subscriber array through a const handle is the
// registry's own storage access and not a caller's write.
static struct axoloty_zenoh_subscription *subscribers_of(const axoloty_zenoh_session_t *session) {
    return (struct axoloty_zenoh_subscription *)session->subscribers;
}

static uint32_t load_u32(const volatile uint32_t *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static void store_u32(volatile uint32_t *value, uint32_t next) {
    __atomic_store_n(value, next, __ATOMIC_RELEASE);
}

static void add_u32(volatile uint32_t *value, uint32_t amount) {
    (void)__atomic_fetch_add(value, amount, __ATOMIC_ACQ_REL);
}

static void sub_u32(volatile uint32_t *value) {
    (void)__atomic_fetch_sub(value, 1u, __ATOMIC_ACQ_REL);
}

static int take_u32(volatile uint32_t *value) {
    return __atomic_exchange_n(value, 0u, __ATOMIC_ACQ_REL) != 0u;
}

static uintptr_t encode_handle(uint32_t session_index, uint32_t subscriber_index, uint32_t generation) {
    return ((uintptr_t)generation << ZENOH_PICO_HANDLE_GENERATION_SHIFT) |
           ((uintptr_t)session_index << ZENOH_PICO_HANDLE_SESSION_SHIFT) | (uintptr_t)subscriber_index;
}

int zenoh_pico_session_index(const axoloty_zenoh_session_t *session) {
    if (!session) return -1;
    for (int index = 0; index < AXOLOTY_ZENOH_MAX_SESSIONS; ++index) {
        if (session == &zenoh_pico_session_slots[index]) return index;
    }
    return -1;
}

struct axoloty_zenoh_session *zenoh_pico_session_at(int index) {
    if (index < 0 || index >= AXOLOTY_ZENOH_MAX_SESSIONS) return NULL;
    return &zenoh_pico_session_slots[index];
}

struct axoloty_zenoh_subscription *zenoh_pico_session_subscriber(const axoloty_zenoh_session_t *session,
                                                                 int subscriber_index) {
    if (!session || zenoh_pico_session_index(session) < 0) return NULL;
    if (subscriber_index < 0 || subscriber_index >= AXOLOTY_ZENOH_MAX_SUBSCRIBERS) return NULL;
    return &subscribers_of(session)[subscriber_index];
}

struct axoloty_zenoh_session *zenoh_pico_session_reserve(void) {
    for (int index = 0; index < AXOLOTY_ZENOH_MAX_SESSIONS; ++index) {
        struct axoloty_zenoh_session *session = &zenoh_pico_session_slots[index];
        if (load_u32(&session->state) == AXOLOTY_ZENOH_SESSION_OPEN) continue;
        store_u32(&session->state, AXOLOTY_ZENOH_SESSION_OPEN);
        session->session_index = (uint32_t)index;
        return session;
    }
    return NULL;
}

void zenoh_pico_session_release(struct axoloty_zenoh_session *session) {
    if (!session) return;
    for (int index = 0; index < AXOLOTY_ZENOH_MAX_SUBSCRIBERS; ++index) {
        if (session->subscribers[index].queue) zenoh_pico_subscription_release(&session->subscribers[index]);
    }
    store_u32(&session->state, AXOLOTY_ZENOH_SESSION_CLOSED);
}

axoloty_zenoh_result_t zenoh_pico_subscription_reserve(const axoloty_zenoh_session_t *session,
                                                       axoloty_zenoh_subscription_t **out_subscription,
                                                       struct axoloty_zenoh_subscription **out_record) {
    if (!session || !out_subscription || !out_record) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_subscription = NULL;
    *out_record = NULL;
    if (load_u32(&session->state) != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;
    for (int index = 0; index < AXOLOTY_ZENOH_MAX_SUBSCRIBERS; ++index) {
        struct axoloty_zenoh_subscription *record = &subscribers_of(session)[index];
        if (record->queue) continue;
        ZenohPicoQueue *queue = calloc(1, sizeof(ZenohPicoQueue));
        if (!queue) return AXOLOTY_ZENOH_TRANSPORT_ERROR;
        uint32_t generation = record->generation + 1u;
        if (generation == 0u) generation = 1u;
        queue->session_index = session->session_index;
        queue->subscriber_index = (uint32_t)index;
        queue->generation = generation;
        record->generation = generation;
        record->session_index = session->session_index;
        record->subscriber_index = (uint32_t)index;
        record->in_flight = 0u;
        store_u32(&record->active, 1u);
        record->queue = queue;
        *out_subscription = (axoloty_zenoh_subscription_t *)encode_handle(
            session->session_index, (uint32_t)index, generation);
        *out_record = record;
        return AXOLOTY_ZENOH_OK;
    }
    return AXOLOTY_ZENOH_CAPACITY_EXCEEDED;
}

void zenoh_pico_subscription_deactivate(struct axoloty_zenoh_subscription *record) {
    if (!record) return;
    store_u32(&record->active, 0u);
}

void zenoh_pico_subscription_release(struct axoloty_zenoh_subscription *record) {
    if (!record) return;
    zenoh_pico_subscription_deactivate(record);
    zenoh_pico_callback_drain(record);
    free(record->queue);
    record->queue = NULL;
}

axoloty_zenoh_result_t zenoh_pico_subscription_resolve(const axoloty_zenoh_session_t *session,
                                                       const axoloty_zenoh_subscription_t *subscription,
                                                       struct axoloty_zenoh_subscription **out_record) {
    if (!session || !subscription || !out_record) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    *out_record = NULL;
    int session_index = zenoh_pico_session_index(session);
    if (session_index < 0) return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    if (load_u32(&session->state) != AXOLOTY_ZENOH_SESSION_OPEN) return AXOLOTY_ZENOH_NOT_OPEN;
    uintptr_t raw = (uintptr_t)subscription;
    uint32_t generation = (uint32_t)(raw >> ZENOH_PICO_HANDLE_GENERATION_SHIFT);
    uint32_t encoded_session = (uint32_t)((raw >> ZENOH_PICO_HANDLE_SESSION_SHIFT) & ZENOH_PICO_HANDLE_SESSION_MASK);
    uint32_t subscriber_index = (uint32_t)(raw & ZENOH_PICO_HANDLE_SUBSCRIBER_MASK);
    if (generation == 0u || (uint32_t)session_index != encoded_session ||
        subscriber_index >= AXOLOTY_ZENOH_MAX_SUBSCRIBERS) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    struct axoloty_zenoh_subscription *record = &subscribers_of(session)[subscriber_index];
    if (!record->queue || load_u32(&record->active) == 0u ||
        load_u32(&record->generation) != generation) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    *out_record = record;
    return AXOLOTY_ZENOH_OK;
}

int zenoh_pico_callback_claim(struct axoloty_zenoh_subscription *record, uint32_t generation) {
    if (!record || !record->queue) return 0;
    if (load_u32(&record->generation) != generation) return 0;
    if (load_u32(&record->active) == 0u) return 0;
    add_u32(&record->in_flight, 1u);
    // Removal waits for the in-flight count and frees the queue, so the claim
    // is only real once it is visible to a removal that already started.
    if (load_u32(&record->generation) != generation || load_u32(&record->active) == 0u) {
        sub_u32(&record->in_flight);
        return 0;
    }
    return 1;
}

void zenoh_pico_callback_leave(struct axoloty_zenoh_subscription *record) {
    if (!record) return;
    sub_u32(&record->in_flight);
}

void zenoh_pico_callback_drain(struct axoloty_zenoh_subscription *record) {
    if (!record) return;
    for (uint32_t spin = 0; spin < ZENOH_PICO_DRAIN_SPIN_LIMIT; ++spin) {
        if (load_u32(&record->in_flight) == 0u) return;
    }
}

int zenoh_pico_queue_admit(ZenohPicoQueue *queue,
                           const void *key, uint32_t key_length,
                           const void *payload, uint32_t payload_length) {
    if (!queue) return 0;
    // A frame that cannot fit the fixed receive bounds is dropped, never
    // truncated, and is counted as oversized exactly as the callback-side
    // sample guard counts it.
    if (!key || key_length == 0u || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES ||
        payload_length > AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES || (payload_length > 0u && !payload)) {
        zenoh_pico_queue_note_oversized(queue);
        return 0;
    }

    uint32_t write = __atomic_load_n(&queue->write_index, __ATOMIC_RELAXED);
    uint32_t read;
    for (;;) {
        read = load_u32(&queue->read_index);
        if (write - read >= ZENOH_PICO_QUEUE_CAPACITY) {
            add_u32(&queue->dropped, 1u);
            store_u32(&queue->report_full, 1u);
            return 0;
        }
        if (__atomic_compare_exchange_n(&queue->write_index, &write, write + 1u, 0,
                                        __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            break;
        }
    }

    ZenohPicoFrame *frame = &queue->frames[write % ZENOH_PICO_QUEUE_CAPACITY];
    memcpy(frame->key, key, key_length);
    if (payload_length > 0u) memcpy(frame->payload, payload, payload_length);
    frame->key_length = key_length;
    frame->payload_length = payload_length;
    store_u32(&frame->published, 1u);
    return 1;
}

void zenoh_pico_queue_note_oversized(ZenohPicoQueue *queue) {
    if (!queue) return;
    add_u32(&queue->oversized, 1u);
    store_u32(&queue->report_oversized, 1u);
}

axoloty_zenoh_result_t zenoh_pico_queue_poll(ZenohPicoQueue *queue,
                                             uint8_t *key, uint32_t key_capacity, uint32_t *out_key_length,
                                             uint8_t *payload, uint32_t payload_capacity,
                                             uint32_t *out_payload_length) {
    if (!queue || !key || !out_key_length || !payload || !out_payload_length) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    uint32_t read = __atomic_load_n(&queue->read_index, __ATOMIC_RELAXED);
    uint32_t write = load_u32(&queue->write_index);
    if (read == write) {
        // The queue is drained, so a pending drop is reported once here.
        if (take_u32(&queue->report_full)) return AXOLOTY_ZENOH_QUEUE_FULL;
        if (take_u32(&queue->report_oversized)) return AXOLOTY_ZENOH_FRAME_TOO_LARGE;
        return AXOLOTY_ZENOH_QUEUE_EMPTY;
    }
    ZenohPicoFrame *frame = &queue->frames[read % ZENOH_PICO_QUEUE_CAPACITY];
    if (load_u32(&frame->published) == 0u) return AXOLOTY_ZENOH_QUEUE_EMPTY;
    if (frame->key_length > key_capacity || frame->payload_length > payload_capacity) {
        // The frame stays queued, so a caller with a large enough buffer still
        // receives it in order.
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    memcpy(key, frame->key, frame->key_length);
    memcpy(payload, frame->payload, frame->payload_length);
    *out_key_length = frame->key_length;
    *out_payload_length = frame->payload_length;
    // Releasing the slot un-publishes it and only then claims the position, so
    // a producer that already claimed the next wrap-around position cannot
    // overwrite a frame the consumer is still reading.
    __atomic_store_n(&frame->published, 0u, __ATOMIC_RELAXED);
    store_u32(&queue->read_index, read + 1u);
    return AXOLOTY_ZENOH_OK;
}

uint32_t zenoh_pico_queue_depth(const ZenohPicoQueue *queue) {
    if (!queue) return 0u;
    uint32_t write = load_u32(&queue->write_index);
    uint32_t read = load_u32(&queue->read_index);
    uint32_t depth = write - read;
    return depth > ZENOH_PICO_QUEUE_CAPACITY ? (uint32_t)ZENOH_PICO_QUEUE_CAPACITY : depth;
}

uint32_t zenoh_pico_queue_dropped(const ZenohPicoQueue *queue) {
    return queue ? load_u32(&queue->dropped) : 0u;
}

uint32_t zenoh_pico_queue_oversized(const ZenohPicoQueue *queue) {
    return queue ? load_u32(&queue->oversized) : 0u;
}
