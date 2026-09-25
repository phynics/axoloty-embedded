// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_HOST_TEST_H
#define AXOLOTY_ZENOH_HOST_TEST_H

#include <stdint.h>

void host_zenoh_reset(void);
void host_zenoh_set_failures(unsigned failures);
unsigned host_zenoh_call_count(unsigned operation);
void host_zenoh_set_sample(
    const unsigned char *key, int key_length,
    const unsigned char *payload, int payload_length);
int host_zenoh_sample_validation_tests(void);

#endif
