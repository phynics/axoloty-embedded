// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "zenoh_sample_validation.h"

// Keep these in sync with `WireBufferConfig` in EmbeddedZenohClient.swift.
#define AXOLOTY_ZENOH_MAX_KEY 257
#define AXOLOTY_ZENOH_MAX_PAYLOAD 2049

int axoloty_zenoh_sample_is_valid(
    const void *key, int key_length,
    const void *payload, int payload_length) {
    if (!key || key_length <= 0 || key_length >= AXOLOTY_ZENOH_MAX_KEY) {
        return 0;
    }
    if (payload_length < 0 || payload_length >= AXOLOTY_ZENOH_MAX_PAYLOAD) {
        return 0;
    }
    // A zero-length payload is a legal Zenoh sample; a null pointer for it is
    // not, because the bounded queue still copies from that address.
    if (!payload && payload_length > 0) {
        return 0;
    }
    return 1;
}
