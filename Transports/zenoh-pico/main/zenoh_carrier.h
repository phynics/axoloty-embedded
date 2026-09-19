// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_CARRIER_H
#define AXOLOTY_ZENOH_CARRIER_H

// Device carrier seam for the embedded Zenoh transport.
//
// These are the C operations `EmbeddedZenohClient` calls. Their device
// implementation is the `zenoh-pico` backend of the Axoloty Zenoh facade
// (proposed in docs/proposed-issues.md). They carry bytes only: no function
// here parses a key, decides a route, or knows a Coaty event type.
//
// All buffers are borrowed for the duration of one synchronous call. The
// caller keeps ownership and the carrier never retains a pointer.

#include <stddef.h>

/// Opens a session to the configured locator within the deadline.
int axoloty_zenoh_open(
    const unsigned char *endpoint, int endpoint_length,
    unsigned int deadline_ms);

/// Installs one key-expression subscription within the deadline.
int axoloty_zenoh_subscribe(
    const unsigned char *key, int key_length,
    unsigned int deadline_ms);

/// Publishes one payload on one key expression.
int axoloty_zenoh_publish(
    const unsigned char *key, int key_length,
    const unsigned char *payload, int payload_length);

/// Copies the next inbound sample into caller storage within the deadline.
///
/// Returns non-zero when a sample was copied and both output lengths were
/// written; zero when no bounded sample arrived. The output capacities are
/// never exceeded.
int axoloty_zenoh_poll(
    unsigned char *key, int key_capacity, int *key_length,
    unsigned char *payload, int payload_capacity, int *payload_length,
    unsigned int deadline_ms);

/// Removes the current subscription, keeping the session open.
int axoloty_zenoh_unsubscribe(void);

/// Closes the session.
int axoloty_zenoh_close(void);

#endif
