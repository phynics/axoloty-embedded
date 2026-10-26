// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_PLATFORM_V1_H
#define AXOLOTY_PLATFORM_V1_H

#include <stdint.h>
#include <stddef.h>
#include "axoloty_abi_status_v1.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AXOLOTY_PLATFORM_ABI_V1 AXOLOTY_ABI_V1

#define AXOLOTY_PLATFORM_CAP_CLOCK UINT64_C(0x0000000000000001)
#define AXOLOTY_PLATFORM_CAP_DELAY UINT64_C(0x0000000000000002)
#define AXOLOTY_PLATFORM_CAP_RESTART UINT64_C(0x0000000000000004)
#define AXOLOTY_PLATFORM_CAP_LOG UINT64_C(0x0000000000000008)
#define AXOLOTY_PLATFORM_CAP_DIAGNOSTICS UINT64_C(0x0000000000000010)
#define AXOLOTY_PLATFORM_CAP_NETWORK_CONFIG UINT64_C(0x0000000000000020)
#define AXOLOTY_PLATFORM_CAP_NETWORK_BOOTSTRAP UINT64_C(0x0000000000000040)
#define AXOLOTY_PLATFORM_CAP_NETWORK_RECONNECT UINT64_C(0x0000000000000080)
#define AXOLOTY_PLATFORM_CAP_DEVICE_NAME UINT64_C(0x0000000000000100)

typedef struct axoloty_platform_metrics_v1 {
    uint32_t free_internal_heap;
    uint32_t minimum_free_internal_heap;
    uint32_t largest_internal_block;
    uint32_t main_stack_high_water;
    uint32_t main_stack_size;
    uint32_t reset_reason;
    uint32_t heap_trace_allocations;
} axoloty_platform_metrics_v1;

typedef struct axoloty_platform_v1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t capabilities;
    void *context;

    int32_t (*clock_now_microseconds)(void *context, uint64_t *out_value);
    int32_t (*delay_ticks)(void *context, uint32_t ticks);
    int32_t (*restart)(void *context);
    int32_t (*write_log)(void *context, const uint8_t *bytes, uint32_t length);
    int32_t (*read_metrics)(void *context, axoloty_platform_metrics_v1 *out_metrics);
    int32_t (*heap_trace_begin)(void *context);
    int32_t (*heap_trace_end)(void *context, uint32_t *out_allocations);

    int32_t (*network_configured)(void *context, uint32_t *out_configured);
    int32_t (*network_role)(void *context, uint32_t *out_role);
    int32_t (*network_scenario)(void *context, uint32_t *out_scenario);
    int32_t (*network_prepare)(void *context, uint32_t deadline_ms, uint32_t *out_result);
    int32_t (*network_reconnect)(void *context, uint32_t deadline_ms, uint32_t *out_result);
    int32_t (*network_cleanup)(void *context, uint32_t *out_result);
    int32_t (*device_display_name)(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length);
} axoloty_platform_v1;

/* The returned table and its context are immutable and live for the image. */
const axoloty_platform_v1 *axoloty_platform_get_v1(void);

/*
 * Validates the frozen 8-byte header first, then only requirement-covered
 * fields. Function mask indices follow the unique field order in
 * Tools/capability_catalog.py. Never copy a caller table before this check.
 */
static inline int axoloty_platform_v1_validate_requirements(
    const axoloty_platform_v1 *table, uint64_t required_capabilities,
    uint64_t required_functions
) {
    if (table == NULL || table->abi_version != AXOLOTY_PLATFORM_ABI_V1 ||
        table->struct_size < 2u * sizeof(uint32_t)) return 0;
    if (required_capabilities != 0 &&
        table->struct_size < offsetof(axoloty_platform_v1, capabilities) + sizeof(table->capabilities)) return 0;
    if (required_capabilities != 0 &&
        (table->capabilities & required_capabilities) != required_capabilities) return 0;
    if (required_functions != 0 &&
        table->struct_size < offsetof(axoloty_platform_v1, context) + sizeof(table->context)) return 0;
#define AXOLOTY_PLATFORM_CHECK_FIELD(index, field) \
    if ((required_functions & (UINT64_C(1) << (index))) != 0 && \
        (table->struct_size < offsetof(axoloty_platform_v1, field) + sizeof(table->field) || \
         table->field == NULL)) return 0
    AXOLOTY_PLATFORM_CHECK_FIELD(0, clock_now_microseconds);
    AXOLOTY_PLATFORM_CHECK_FIELD(1, delay_ticks);
    AXOLOTY_PLATFORM_CHECK_FIELD(2, restart);
    AXOLOTY_PLATFORM_CHECK_FIELD(3, write_log);
    AXOLOTY_PLATFORM_CHECK_FIELD(4, heap_trace_begin);
    AXOLOTY_PLATFORM_CHECK_FIELD(5, heap_trace_end);
    AXOLOTY_PLATFORM_CHECK_FIELD(6, read_metrics);
    AXOLOTY_PLATFORM_CHECK_FIELD(7, network_configured);
    AXOLOTY_PLATFORM_CHECK_FIELD(8, network_role);
    AXOLOTY_PLATFORM_CHECK_FIELD(9, network_scenario);
    AXOLOTY_PLATFORM_CHECK_FIELD(10, network_prepare);
    AXOLOTY_PLATFORM_CHECK_FIELD(11, network_cleanup);
    AXOLOTY_PLATFORM_CHECK_FIELD(12, network_reconnect);
    AXOLOTY_PLATFORM_CHECK_FIELD(13, device_display_name);
#undef AXOLOTY_PLATFORM_CHECK_FIELD
    return 1;
}

#ifdef __cplusplus
}
#endif

#endif
