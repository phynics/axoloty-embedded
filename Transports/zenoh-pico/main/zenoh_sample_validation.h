// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_SAMPLE_VALIDATION_H
#define AXOLOTY_ZENOH_SAMPLE_VALIDATION_H

#include <stddef.h>

/// Returns true only for a bounded, complete inbound Zenoh sample.
///
/// Carrier mechanics only: this is the byte-bound guard the `zenoh-pico`
/// sample callback runs before it copies an inbound sample into the bounded
/// queue the device side polls. A sample with no key, an oversize key, a
/// negative length, or an oversize payload is rejected instead of truncated
/// or retained. See `docs/zenoh-embedded.md` for the bound rationale.
int axoloty_zenoh_sample_is_valid(
    const void *key, int key_length,
    const void *payload, int payload_length);

#endif
