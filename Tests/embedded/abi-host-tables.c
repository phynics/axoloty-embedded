// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host implementation of the version 1 platform table.
//
// The host smoke run executes the application through the real generated ABI
// entry, so it needs a real platform table. Values match the seam-backed host
// harness: a monotonic clock, a real sleep, fixed diagnostics, and no network
// configuration. The terminal restart event ends the process, exactly as the
// seam-backed host harness does.

#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "axoloty_platform_v1.h"

static int32_t host_clock(void *context, uint64_t *out_value) {
    (void)context;
    if (out_value == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return AXOLOTY_ABI_STATUS_FAILED;
    *out_value = (uint64_t)now.tv_sec * UINT64_C(1000000) + (uint64_t)now.tv_nsec / UINT64_C(1000);
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_delay(void *context, uint32_t ticks) {
    (void)context;
    struct timespec remaining;
    remaining.tv_sec = (time_t)(ticks / 1000u);
    remaining.tv_nsec = (long)(ticks % 1000u) * 1000000L;
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) return AXOLOTY_ABI_STATUS_FAILED;
    }
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_restart(void *context) {
    (void)context;
    fputs("{\"host\":\"restart\"}\n", stdout);
    fflush(stdout);
    exit(0);
}

static int32_t host_write_log(void *context, const uint8_t *bytes, uint32_t length) {
    (void)context;
    if (bytes == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    fwrite(bytes, 1, (size_t)length, stdout);
    fflush(stdout);
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_read_metrics(void *context, axoloty_platform_metrics_v1 *out_metrics) {
    (void)context;
    if (out_metrics == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    out_metrics->free_internal_heap = 262144u;
    out_metrics->minimum_free_internal_heap = 196608u;
    out_metrics->largest_internal_block = 131072u;
    out_metrics->main_stack_high_water = 4096u;
    out_metrics->main_stack_size = 131072u;
    out_metrics->reset_reason = 0u;
    out_metrics->heap_trace_allocations = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_heap_trace_begin(void *context) {
    (void)context;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_heap_trace_end(void *context, uint32_t *out_allocations) {
    (void)context;
    if (out_allocations == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_allocations = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_configured(void *context, uint32_t *out_configured) {
    (void)context;
    if (out_configured == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_configured = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_role(void *context, uint32_t *out_role) {
    (void)context;
    if (out_role == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_role = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_scenario(void *context, uint32_t *out_scenario) {
    (void)context;
    if (out_scenario == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_scenario = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_prepare(void *context, uint32_t deadline_ms, uint32_t *out_result) {
    (void)context;
    (void)deadline_ms;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_reconnect(void *context, uint32_t deadline_ms, uint32_t *out_result) {
    (void)context;
    (void)deadline_ms;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = 0u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_network_cleanup(void *context, uint32_t *out_result) {
    (void)context;
    if (out_result == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    *out_result = 1u;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t host_device_display_name(
    void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length
) {
    (void)context;
    static const uint8_t name[] = "Host Smoke";
    const uint32_t length = (uint32_t)(sizeof(name) - 1u);
    if (buffer == NULL || out_length == NULL || capacity < length) {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    }
    for (uint32_t index = 0; index < length; index += 1) buffer[index] = name[index];
    *out_length = length;
    return AXOLOTY_ABI_STATUS_OK;
}

static const axoloty_platform_v1 host_platform_table = {
    .abi_version = AXOLOTY_PLATFORM_ABI_V1,
    .struct_size = (uint32_t)sizeof(axoloty_platform_v1),
    .capabilities = AXOLOTY_PLATFORM_CAP_CLOCK | AXOLOTY_PLATFORM_CAP_DELAY |
        AXOLOTY_PLATFORM_CAP_RESTART | AXOLOTY_PLATFORM_CAP_LOG |
        AXOLOTY_PLATFORM_CAP_DIAGNOSTICS | AXOLOTY_PLATFORM_CAP_NETWORK_CONFIG |
        AXOLOTY_PLATFORM_CAP_NETWORK_BOOTSTRAP | AXOLOTY_PLATFORM_CAP_NETWORK_RECONNECT |
        AXOLOTY_PLATFORM_CAP_DEVICE_NAME,
    .context = NULL,
    .clock_now_microseconds = host_clock,
    .delay_ticks = host_delay,
    .restart = host_restart,
    .write_log = host_write_log,
    .read_metrics = host_read_metrics,
    .heap_trace_begin = host_heap_trace_begin,
    .heap_trace_end = host_heap_trace_end,
    .network_configured = host_network_configured,
    .network_role = host_network_role,
    .network_scenario = host_network_scenario,
    .network_prepare = host_network_prepare,
    .network_reconnect = host_network_reconnect,
    .network_cleanup = host_network_cleanup,
    .device_display_name = host_device_display_name,
};

const axoloty_platform_v1 *axoloty_platform_get_v1(void) {
    return &host_platform_table;
}

// The offline host run never configures a network, so the scenario-selected
// bytes do not exist. The carrier table still links the same entry points the
// firmware build uses.
int axoloty_network_copy_topic(unsigned char *buffer, int capacity) {
    (void)buffer;
    (void)capacity;
    return 0;
}

int axoloty_network_copy_payload(unsigned char *buffer, int capacity) {
    (void)buffer;
    (void)capacity;
    return 0;
}
