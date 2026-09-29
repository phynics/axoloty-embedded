// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_PICO_QUEUE_H
#define AXOLOTY_ZENOH_PICO_QUEUE_H

// Bounded receive state for the `zenoh-pico` backend of the Axoloty Zenoh
// facade.
//
// This module owns the parts of the facade that are pure carrier mechanics: the
// fixed session and subscriber registries, the per-subscription bounded receive
// queue, the drop counters, and the generation token that rejects a callback
// that arrives after its subscriber was removed. It includes no Zenoh header
// and no SDK header, so the host seam can exercise the bounds and the counters
// with no board, no zenoh-pico, and no ESP-IDF.
//
// The `axoloty_zenoh_*` entry points live in `zenoh_pico_facade.c`, which
// translates Zenoh calls into calls on this state. Every result code, bound,
// and queue capacity here is the Core-owned facade contract in
// `axoloty_zenoh.h`; nothing is restated.

#include <stdint.h>

#include "axoloty_zenoh.h"

/// The fixed number of inbound frames held per subscription.
#define ZENOH_PICO_QUEUE_CAPACITY AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY

/// One bounded inbound frame.
///
/// `published` is the per-slot publication flag. A producer claims a write
/// position, fills the slot, and then publishes it; the consumer reads only
/// published slots and clears the flag as it releases them. No lock is
/// involved, and two producers never share a slot because a position is
/// claimed with one compare-and-swap.
typedef struct {
    uint32_t key_length;
    uint32_t payload_length;
    uint32_t published;
    uint8_t key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
    uint8_t payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
} ZenohPicoFrame;

/// One subscription's bounded receive queue and its cumulative counters.
///
/// The counters are cumulative for the lifetime of the queue, and the two
/// report flags carry the pending one-shot poll notifications.
typedef struct {
    uint32_t read_index;
    uint32_t write_index;
    uint32_t dropped;
    uint32_t oversized;
    uint32_t report_full;
    uint32_t report_oversized;
    uint32_t session_index;
    uint32_t subscriber_index;
    uint32_t generation;
    ZenohPicoFrame frames[ZENOH_PICO_QUEUE_CAPACITY];
} ZenohPicoQueue;

/// One subscriber slot of one session.
///
/// A slot is static storage, so its address is never a Zenoh or queue pointer:
/// the opaque handle the facade hands out encodes the session, the slot, and
/// the generation instead of addressing this record.
struct axoloty_zenoh_subscription {
    ZenohPicoQueue *queue;
    uint32_t generation;
    uint32_t active;
    uint32_t in_flight;
    uint32_t session_index;
    uint32_t subscriber_index;
};

/// One fixed session slot.
struct axoloty_zenoh_session {
    uint32_t state;
    uint32_t session_index;
    struct axoloty_zenoh_subscription subscribers[AXOLOTY_ZENOH_MAX_SUBSCRIBERS];
};

/// Returns the registry index of a session handle, or -1 when the pointer does
/// not address one of this process's fixed session slots.
int zenoh_pico_session_index(const axoloty_zenoh_session_t *session);

/// Returns the fixed slot for a registry index, or NULL when out of range.
struct axoloty_zenoh_session *zenoh_pico_session_at(int index);

/// Returns one fixed subscriber slot of a session, or NULL when out of range.
///
/// The slot is only live while it holds a queue; a caller that walks the slots
/// must check that, which `zenoh_pico_subscription_resolve` does for a handle.
struct axoloty_zenoh_subscription *zenoh_pico_session_subscriber(const axoloty_zenoh_session_t *session,
                                                                  int subscriber_index);

/// Marks a free session slot open and returns it, or returns NULL when every
/// slot is occupied.
struct axoloty_zenoh_session *zenoh_pico_session_reserve(void);

/// Returns a session slot to the free pool after its subscribers were removed.
void zenoh_pico_session_release(struct axoloty_zenoh_session *session);

/// Reserves one free subscriber slot of a session, bumps its generation, and
/// hands out the generation-guarded handle for it.
///
/// Returns `AXOLOTY_ZENOH_CAPACITY_EXCEEDED` without changing any occupied
/// slot, and `AXOLOTY_ZENOH_NOT_OPEN` for a session that is not open. The
/// reserved record is handed back as well, because the backend needs its queue
/// and its slot index to declare the Zenoh subscriber.
axoloty_zenoh_result_t zenoh_pico_subscription_reserve(const axoloty_zenoh_session_t *session,
                                                       axoloty_zenoh_subscription_t **out_subscription,
                                                       struct axoloty_zenoh_subscription **out_record);

/// Deactivates a subscriber slot so a callback that was already in flight, or
/// one that Zenoh still has queued, can no longer copy into the queue.
///
/// A backend calls this before it undeclares the Zenoh subscriber, so no
/// callback can start copying after the undeclare returns.
void zenoh_pico_subscription_deactivate(struct axoloty_zenoh_subscription *record);

/// Deactivates a subscriber slot, waits for the callbacks already copying, and
/// releases its queue.
///
/// The generation is left as it is: the slot is inactive, so a stale handle is
/// already rejected, and the next reservation bumps the generation again.
void zenoh_pico_subscription_release(struct axoloty_zenoh_subscription *record);

/// Resolves a subscription handle against a session.
///
/// Returns `AXOLOTY_ZENOH_INVALID_ARGUMENT` for a null, foreign, stale, or
/// already removed handle, and `AXOLOTY_ZENOH_NOT_OPEN` for a closed session.
axoloty_zenoh_result_t zenoh_pico_subscription_resolve(const axoloty_zenoh_session_t *session,
                                                       const axoloty_zenoh_subscription_t *subscription,
                                                       struct axoloty_zenoh_subscription **out_record);

/// Claims a callback invocation for the declaration it was registered for.
///
/// Returns 1 when the callback may copy a frame and must afterwards call
/// `zenoh_pico_callback_leave`, and 0 when the callback belongs to a removed or
/// replaced declaration. The claim is taken before any Zenoh memory is read, so
/// a removed subscriber can wait for it before its queue is released.
int zenoh_pico_callback_claim(struct axoloty_zenoh_subscription *record, uint32_t generation);

/// Releases a claim taken by `zenoh_pico_callback_claim`.
void zenoh_pico_callback_leave(struct axoloty_zenoh_subscription *record);

/// Waits, with a bounded spin, for the callbacks that are copying a frame.
void zenoh_pico_callback_drain(struct axoloty_zenoh_subscription *record);

/// Copies one validated frame into the queue, dropping the newest frame and
/// counting the drop when the queue is full.
int zenoh_pico_queue_admit(ZenohPicoQueue *queue,
                           const void *key, uint32_t key_length,
                           const void *payload, uint32_t payload_length);

/// Counts one frame that the bounded-sample guard rejected and queues the
/// one-shot oversized-frame notification.
void zenoh_pico_queue_note_oversized(ZenohPicoQueue *queue);

/// Copies the oldest complete frame into caller storage.
axoloty_zenoh_result_t zenoh_pico_queue_poll(ZenohPicoQueue *queue,
                                             uint8_t *key, uint32_t key_capacity, uint32_t *out_key_length,
                                             uint8_t *payload, uint32_t payload_capacity,
                                             uint32_t *out_payload_length);

/// Reads the current bounded queue depth.
uint32_t zenoh_pico_queue_depth(const ZenohPicoQueue *queue);

/// Reads the cumulative full-queue drop count.
uint32_t zenoh_pico_queue_dropped(const ZenohPicoQueue *queue);

/// Reads the cumulative oversized-frame count.
uint32_t zenoh_pico_queue_oversized(const ZenohPicoQueue *queue);

#endif
