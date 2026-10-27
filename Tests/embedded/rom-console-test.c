// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "axoloty_platform_v1.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "network_bootstrap.h"

static uint8_t output[128];
static size_t output_length;
static unsigned format_calls;
static unsigned channel_calls;
static unsigned rejected_format_calls;

/*
 * The supplied ESP-IDF source and C6 link map show the direct channel sink
 * reaches UART0, which is not the selected native USB console. Model that
 * sink as invisible here. The %c formatter records a candidate USB-visible
 * path for this host contract test; it does not prove target ROM behavior.
 */
void esp_rom_output_to_channels(char byte) {
    (void)byte;
    ++channel_calls;
}

int esp_rom_printf(const char *format, ...) {
    if (strcmp(format, "%c") != 0) {
        ++rejected_format_calls;
        return -1;
    }

    va_list arguments;
    va_start(arguments, format);
    const int byte = va_arg(arguments, int);
    va_end(arguments);
    ++format_calls;
    if (output_length >= sizeof(output)) abort();
    output[output_length++] = (uint8_t)byte;
    return 1;
}

static void expect_write(const uint8_t *input, uint32_t length, const uint8_t *expected, size_t expected_length) {
    const size_t before = output_length;
    if (axoloty_platform_get_v1()->write_log(NULL, input, length) != AXOLOTY_ABI_STATUS_OK) abort();
    if (output_length - before != expected_length ||
        (expected_length != 0 && memcmp(output + before, expected, expected_length) != 0)) {
        fprintf(stderr, "write_log output mismatch (got %zu bytes, expected %zu)\n", output_length - before, expected_length);
        abort();
    }
    if (format_calls != output_length || channel_calls != 0 || rejected_format_calls != 0) {
        fputs("write_log did not use one accepted ROM %c call per byte\n", stderr);
        abort();
    }
}

int main(void) {
    static const uint8_t bounded[] = {'o', 'k', '!', 0xA5, 0x5A};
    static const uint8_t percent[] = {'%', 's', '%', '1', '$', 'n'};
    static const uint8_t nul_bytes[] = {'a', 0, 'b'};
    static const uint8_t high_bytes[] = {0x80, 0xFE, 0xFF};
    static const uint8_t combined[] = {'o', 'k', '!', '%', 's', '%', '1', '$', 'n', 'a', 0, 'b', 0x80, 0xFE, 0xFF};
    const uint8_t canary = 0xCC;
    expect_write(bounded, 3, bounded, 3);
    expect_write(percent, sizeof(percent), percent, sizeof(percent));
    expect_write(nul_bytes, sizeof(nul_bytes), nul_bytes, sizeof(nul_bytes));
    expect_write(high_bytes, sizeof(high_bytes), high_bytes, sizeof(high_bytes));
    expect_write(&canary, 0, NULL, 0);
    if (axoloty_platform_get_v1()->write_log(NULL, NULL, 0) != AXOLOTY_ABI_STATUS_OK) abort();
    if (axoloty_platform_get_v1()->write_log(NULL, NULL, 1) != AXOLOTY_ABI_STATUS_INVALID_ARGUMENT) abort();
    if (output_length != sizeof(combined) || memcmp(output, combined, sizeof(combined)) != 0) {
        fputs("write_log repeated-call byte ordering mismatch\n", stderr);
        return 1;
    }
    if (format_calls != output_length || channel_calls != 0 || rejected_format_calls != 0) {
        fputs("write_log did not use one accepted ROM %c call per byte\n", stderr);
        return 1;
    }
    puts("ROM console byte forwarding tests passed");
    return 0;
}

// Stubs for unrelated platform callbacks referenced by the real production translation unit.
size_t heap_caps_get_free_size(int caps) { (void)caps; return 0; }
size_t heap_caps_get_minimum_free_size(int caps) { (void)caps; return 0; }
size_t heap_caps_get_largest_free_block(int caps) { (void)caps; return 0; }
void esp_restart(void) {}
int64_t esp_timer_get_time(void) { return 0; }
void vTaskDelay(TickType_t ticks) { (void)ticks; }
uint32_t axoloty_main_stack_high_water(void) { return 0; }
uint32_t axoloty_main_stack_size(void) { return 0; }
uint32_t axoloty_reset_reason(void) { return 0; }
int32_t axoloty_heap_trace_begin(void) { return AXOLOTY_ABI_STATUS_FAILED; }
int32_t axoloty_heap_trace_end(uint32_t *out_allocations) {
    (void)out_allocations;
    return AXOLOTY_ABI_STATUS_FAILED;
}
int axoloty_device_display_name(uint8_t *buffer, int capacity) { (void)buffer; (void)capacity; return 0; }
int axoloty_network_configured(void) { return 0; }
uint32_t axoloty_network_role(void) { return 0; }
uint32_t axoloty_network_scenario(void) { return 0; }
uint32_t axoloty_network_prepare(uint32_t deadline_ms) { (void)deadline_ms; return 0; }
uint32_t axoloty_network_reconnect_wait(uint32_t deadline_ms) { (void)deadline_ms; return 0; }
uint32_t axoloty_network_cleanup(void) { return 0; }
