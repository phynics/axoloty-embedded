// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Operator-configured router endpoint for the embedded Zenoh transport.
//
// The session endpoint is operator configuration, never tracked source. It is
// derived here in C, next to the configuration header, so Swift keeps only
// borrowed bytes: the caller owns the output buffer and nothing is retained.
// The `tcp/<host>:<port>` shape mirrors the host binding default
// (`tcp/127.0.0.1:7447`); the host and port arrive through the same private
// network configuration header the MQTT transport reads.

#include "zenoh_endpoint.h"

#include <stdint.h>
#include <stdio.h>

#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
#endif

int axoloty_zenoh_copy_endpoint(unsigned char *buffer, int capacity) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)buffer;
    (void)capacity;
    return -1;
#else
    if (!buffer || capacity <= 0) return -1;
    int length = snprintf((char *)buffer, (size_t)capacity, "tcp/%s:%u", axoloty_zenoh_host,
                          (unsigned)axoloty_zenoh_port);
    if (length <= 0 || length >= capacity) return -1;
    // The facade validates endpoints before any Zenoh call (printable ASCII,
    // no quote or backslash, at most 512 bytes). Reject here so a malformed
    // operator value fails closed before a session is reserved.
    if (length > 512) return -1;
    for (int index = 0; index < length; ++index) {
        unsigned char byte = buffer[index];
        if (byte < 0x20u || byte > 0x7Eu || byte == '"' || byte == '\\') return -1;
    }
    return length;
#endif
}
