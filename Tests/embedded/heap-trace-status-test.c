// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "axoloty_abi_status_v1.h"
#include "esp_heap_trace.h"
#include "freertos/FreeRTOS.h"

static int init_status;
static int start_status;
static int stop_status;
static int summary_status;
static heap_trace_summary_t summary;

int heap_trace_init_standalone(heap_trace_record_t *records, size_t count) {
    (void)records;
    (void)count;
    return init_status;
}
int heap_trace_start(heap_trace_mode_t mode) { (void)mode; return start_status; }
int heap_trace_stop(void) { return stop_status; }
int heap_trace_summary(heap_trace_summary_t *out) {
    if (summary_status == ESP_OK) *out = summary;
    return summary_status;
}

int esp_rom_printf(const char *format, ...) { (void)format; return 0; }
unsigned int heap_caps_get_free_size(unsigned int caps) { (void)caps; return 0; }
unsigned int heap_caps_get_minimum_free_size(unsigned int caps) { (void)caps; return 0; }
unsigned int heap_caps_get_largest_free_block(unsigned int caps) { (void)caps; return 0; }
unsigned int esp_reset_reason(void) { return 0; }
void vTaskDelay(TickType_t ticks) { (void)ticks; }
unsigned int uxTaskGetStackHighWaterMark(void *task) { (void)task; return 0; }
long long esp_timer_get_time(void) { return 0; }

int32_t axoloty_heap_trace_begin(void);
int32_t axoloty_heap_trace_end(uint32_t *out_allocations);
int32_t axoloty_platform_heap_trace_begin(void *context);
int32_t axoloty_platform_heap_trace_end(void *context, uint32_t *out_allocations);

static void check(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "heap-trace-status-test: %s\n", message);
        exit(1);
    }
}

static void reset(void) {
    init_status = ESP_OK;
    start_status = ESP_OK;
    stop_status = ESP_OK;
    summary_status = ESP_OK;
    summary = (heap_trace_summary_t){
        .mode = HEAP_TRACE_ALL,
        .total_allocations = 0,
        .count = 0,
        .has_overflowed = 0,
    };
}

int main(void) {
    uint32_t count;

    reset();
    check(axoloty_platform_heap_trace_begin(NULL) == AXOLOTY_ABI_STATUS_OK, "trace starts");
    check(axoloty_platform_heap_trace_end(NULL, NULL) == AXOLOTY_ABI_STATUS_INVALID_ARGUMENT,
          "null output rejected");

    count = 77;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_OK && count == 0,
          "successful zero count is preserved");

    summary.total_allocations = 19;
    summary.count = 3;
    count = 77;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_OK && count == 19,
          "total allocations are independent of buffered record count");

    init_status = ESP_FAIL;
    check(axoloty_platform_heap_trace_begin(NULL) == AXOLOTY_ABI_STATUS_FAILED, "init failure reported");
    reset();
    start_status = ESP_FAIL;
    check(axoloty_platform_heap_trace_begin(NULL) == AXOLOTY_ABI_STATUS_FAILED, "start failure reported");

    reset();
    count = 77;
    stop_status = ESP_FAIL;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_FAILED && count == 77,
          "stop failure leaves output untouched");
    reset();
    count = 77;
    summary_status = ESP_FAIL;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_FAILED && count == 77,
          "summary failure leaves output untouched");
    reset();
    count = 77;
    summary.has_overflowed = 1;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_TRACE_OVERFLOW && count == 77,
          "overflow is distinct and leaves output untouched");
    reset();
    count = 77;
    summary.mode = HEAP_TRACE_LEAKS;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_FAILED && count == 77,
          "wrong summary mode rejected");
#if SIZE_MAX > UINT32_MAX
    reset();
    count = 77;
    summary.total_allocations = (size_t)UINT32_MAX + 1u;
    check(axoloty_platform_heap_trace_end(NULL, &count) == AXOLOTY_ABI_STATUS_FAILED && count == 77,
          "count wider than the ABI is rejected without changing output");
#endif

    puts("heap-trace-status-test: PASS");
    return 0;
}
