// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ABI_HOST_FIXTURE_H
#define AXOLOTY_ABI_HOST_FIXTURE_H

#include <stdint.h>
#include "axoloty_application_entry_v1.h"
#include "axoloty_carrier_v1.h"

uint64_t host_smoke_virtual_now(void);
void host_smoke_virtual_delay(uint32_t ticks);
void host_exchange_trace(const char *operation);
void host_mqtt_set_event(const unsigned char *topic, int topic_length,
                         const unsigned char *payload, int payload_length);
const axoloty_carrier_v1 *host_exchange_carrier_get_v1(void);

#endif
