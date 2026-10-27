// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// C helpers for Swift logging and testing on ESP32-C6.
//
// Embedded Swift cannot call variadic C functions (printf, esp_rom_printf,
// ESP_LOGI). These wrappers provide fixed-signature alternatives that Swift
// can call directly through the bridging header.

#include "esp_rom_sys.h"
#include "esp_heap_caps.h"
#include "esp_heap_trace.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include "axoloty_abi_status_v1.h"

void axoloty_print(const char *msg) {
    esp_rom_printf("%s", msg);
}

void axoloty_print_uint(const char *label, unsigned int value) {
    esp_rom_printf("%s%u", label, value);
}

unsigned int axoloty_free_internal_heap(void) {
    return (unsigned int)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
}

unsigned int axoloty_min_free_internal_heap(void) {
    return (unsigned int)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
}

unsigned int axoloty_largest_internal_block(void) {
    return (unsigned int)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
}

unsigned int axoloty_main_stack_high_water(void) {
    return (unsigned int)uxTaskGetStackHighWaterMark(NULL);
}

unsigned int axoloty_main_stack_size(void) {
    return (unsigned int)CONFIG_ESP_MAIN_TASK_STACK_SIZE;
}

unsigned int axoloty_reset_reason(void) {
    return (unsigned int)esp_reset_reason();
}

static heap_trace_record_t axoloty_heap_records[128];

int32_t axoloty_heap_trace_begin(void) {
    if (heap_trace_init_standalone(axoloty_heap_records, 128) != ESP_OK) {
        return AXOLOTY_ABI_STATUS_FAILED;
    }
    return heap_trace_start(HEAP_TRACE_ALL) == ESP_OK
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED;
}

int32_t axoloty_heap_trace_end(uint32_t *out_allocations) {
    if (out_allocations == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    if (heap_trace_stop() != ESP_OK) return AXOLOTY_ABI_STATUS_FAILED;

    heap_trace_summary_t summary;
    if (heap_trace_summary(&summary) != ESP_OK) return AXOLOTY_ABI_STATUS_FAILED;
    if (summary.mode != HEAP_TRACE_ALL) return AXOLOTY_ABI_STATUS_FAILED;
    if (summary.has_overflowed != 0) return AXOLOTY_ABI_STATUS_TRACE_OVERFLOW;
#if SIZE_MAX > UINT32_MAX
    if (summary.total_allocations > UINT32_MAX) return AXOLOTY_ABI_STATUS_FAILED;
#endif

    *out_allocations = (uint32_t)summary.total_allocations;
    return AXOLOTY_ABI_STATUS_OK;
}
