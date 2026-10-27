// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stdint.h>

#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "network_bootstrap.h"
#include "axoloty_platform_v1.h"

extern uint32_t axoloty_main_stack_high_water(void);
extern uint32_t axoloty_main_stack_size(void);
extern uint32_t axoloty_reset_reason(void);
extern int32_t axoloty_platform_heap_trace_begin(void *context);
extern int32_t axoloty_platform_heap_trace_end(void *context, uint32_t *out_allocations);
extern int axoloty_device_display_name(uint8_t *buffer, int capacity);

static int32_t platform_clock(void *context, uint64_t *out_value) {
    (void)context;
    if (out_value == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    const int64_t now = esp_timer_get_time();
    if (now < 0) return AXOLOTY_ABI_STATUS_FAILED;
    *out_value = (uint64_t)now;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_delay(void *context, uint32_t ticks) {
    (void)context;
    vTaskDelay((TickType_t)ticks);
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_restart(void *context) {
    (void)context;
    esp_restart();
    return AXOLOTY_ABI_STATUS_FAILED;
}

static int32_t platform_log(void *context, const uint8_t *bytes, uint32_t length) {
    (void)context;
    if (bytes == NULL && length != 0) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    for (uint32_t index = 0; index < length; ++index) {
        esp_rom_printf("%c", (int)bytes[index]);
    }
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_metrics(void *context, axoloty_platform_metrics_v1 *out_metrics) {
    (void)context;
    if (out_metrics == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    out_metrics->free_internal_heap = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    out_metrics->minimum_free_internal_heap = (uint32_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
    out_metrics->largest_internal_block = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    out_metrics->main_stack_high_water = axoloty_main_stack_high_water();
    out_metrics->main_stack_size = axoloty_main_stack_size();
    out_metrics->reset_reason = axoloty_reset_reason();
    out_metrics->heap_trace_allocations = 0;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_configured(void *context, uint32_t *out_value) {
    (void)context;
    if (out_value == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_value = axoloty_network_configured() != 0;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_role(void *context, uint32_t *out_value) {
    (void)context;
    if (out_value == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_value = axoloty_network_role();
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_scenario(void *context, uint32_t *out_value) {
    (void)context;
    if (out_value == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_value = axoloty_network_scenario();
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_prepare(void *context, uint32_t deadline_ms, uint32_t *out_result) {
    (void)context;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = axoloty_network_prepare(deadline_ms);
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_reconnect(void *context, uint32_t deadline_ms, uint32_t *out_result) {
    (void)context;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = axoloty_network_reconnect_wait(deadline_ms);
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_network_cleanup(void *context, uint32_t *out_result) {
    (void)context;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = axoloty_network_cleanup();
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t platform_display_name(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length) {
    (void)context;
    if (buffer == NULL || out_length == NULL || capacity > INT32_MAX) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    const int length = axoloty_device_display_name(buffer, (int)capacity);
    if (length < 0) return AXOLOTY_ABI_STATUS_FAILED;
    *out_length = (uint32_t)length;
    return AXOLOTY_ABI_STATUS_OK;
}

static const axoloty_platform_v1 platform_table = {
    .abi_version = AXOLOTY_PLATFORM_ABI_V1,
    .struct_size = (uint32_t)sizeof(axoloty_platform_v1),
    .capabilities = AXOLOTY_PLATFORM_CAP_CLOCK | AXOLOTY_PLATFORM_CAP_DELAY |
        AXOLOTY_PLATFORM_CAP_RESTART | AXOLOTY_PLATFORM_CAP_LOG |
        AXOLOTY_PLATFORM_CAP_DIAGNOSTICS | AXOLOTY_PLATFORM_CAP_NETWORK_CONFIG |
        AXOLOTY_PLATFORM_CAP_NETWORK_BOOTSTRAP | AXOLOTY_PLATFORM_CAP_NETWORK_RECONNECT |
        AXOLOTY_PLATFORM_CAP_DEVICE_NAME,
    .context = NULL,
    .clock_now_microseconds = platform_clock,
    .delay_ticks = platform_delay,
    .restart = platform_restart,
    .write_log = platform_log,
    .read_metrics = platform_metrics,
    .heap_trace_begin = axoloty_platform_heap_trace_begin,
    .heap_trace_end = axoloty_platform_heap_trace_end,
    .network_configured = platform_network_configured,
    .network_role = platform_network_role,
    .network_scenario = platform_network_scenario,
    .network_prepare = platform_network_prepare,
    .network_reconnect = platform_network_reconnect,
    .network_cleanup = platform_network_cleanup,
    .device_display_name = platform_display_name,
};

const axoloty_platform_v1 *axoloty_platform_get_v1(void) {
    return &platform_table;
}
