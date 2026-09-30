// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_ENDPOINT_H
#define AXOLOTY_ZENOH_ENDPOINT_H

// Copies the operator-configured router endpoint into caller storage.
// Returns the endpoint length, or -1 when no endpoint is configured.
int axoloty_zenoh_copy_endpoint(unsigned char *buffer, int capacity);

#endif
