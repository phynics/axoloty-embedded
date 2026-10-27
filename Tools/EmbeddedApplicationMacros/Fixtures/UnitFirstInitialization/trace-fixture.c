// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_application_entry_v1.h"
#include <string.h>

static char events[16];
static uint32_t event_count;
static int32_t configured_begin_status;
static int32_t configured_end_status;
static uint32_t configured_count;

void first_init_record(int32_t event) {
    if (event_count < sizeof(events) - 1) events[event_count++] = (char)event;
}
void first_init_reset(int32_t begin_status, int32_t end_status, uint32_t count) {
    memset(events, 0, sizeof(events)); event_count = 0;
    configured_begin_status = begin_status;
    configured_end_status = end_status;
    configured_count = count;
}
const char *first_init_log(void) { return events; }

static int32_t begin_trace(void *context) {
    (void)context; first_init_record(66); return configured_begin_status;
}
static int32_t end_trace(void *context, uint32_t *count) {
    (void)context; first_init_record(69);
    if (configured_end_status == AXOLOTY_ABI_STATUS_OK) *count = configured_count;
    return configured_end_status;
}
static const axoloty_platform_v1 platform = {
    .abi_version = AXOLOTY_PLATFORM_ABI_V1,
    .struct_size = sizeof(axoloty_platform_v1),
    .capabilities = AXOLOTY_PLATFORM_CAP_DIAGNOSTICS,
    .heap_trace_begin = begin_trace,
    .heap_trace_end = end_trace,
};
static const axoloty_carrier_v1 carrier = {
    .abi_version = AXOLOTY_CARRIER_ABI_V1,
    .struct_size = sizeof(axoloty_carrier_v1),
};
const axoloty_platform_v1 *first_init_platform(void) { return &platform; }
const axoloty_carrier_v1 *first_init_carrier(void) { return &carrier; }
