// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stdint.h>
#include <stddef.h>

#include "axoloty_abi_status_v1.h"

extern int32_t axoloty_heap_trace_begin(void);
extern int32_t axoloty_heap_trace_end(uint32_t *out_allocations);

int32_t axoloty_platform_heap_trace_begin(void *context) {
    (void)context;
    return axoloty_heap_trace_begin();
}

int32_t axoloty_platform_heap_trace_end(void *context, uint32_t *out_allocations) {
    (void)context;
    if (out_allocations == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    return axoloty_heap_trace_end(out_allocations);
}
