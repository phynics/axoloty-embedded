// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_heap_trace.h"

extern int axoloty_heap_trace_calibration_run(void);
void *__real_malloc(size_t size);
void __real_free(void *allocation);
void *__real_calloc(size_t count, size_t size);

#define HOST_RECORD_CAPACITY 128u
#define HOST_LIVE_CAPACITY 512u
static int trace_active;
static size_t traced_allocations;
static size_t traced_frees;
static size_t record_count;
static void *records[HOST_RECORD_CAPACITY];
static int trace_overflow;
static const char *failure_mode;
static int address_reuse_counterexample_complete;
static void *missed_calloc_address;
static size_t malloc_calls;
static size_t stopped_summary_reads;
static void *live_allocations[HOST_LIVE_CAPACITY];
static size_t live_count;

static int fails(const char *name) {
    return failure_mode != NULL && strcmp(failure_mode, name) == 0;
}

static void track_live(void *allocation) {
    if (allocation != NULL && live_count < HOST_LIVE_CAPACITY) live_allocations[live_count++] = allocation;
}

static void untrack_live(void *allocation) {
    if (allocation == NULL) return;
    for (size_t index = 0; index < live_count; ++index) {
        if (live_allocations[index] == allocation) {
            live_allocations[index] = live_allocations[--live_count];
            return;
        }
    }
}

static void observe_allocation(void *allocation) {
    if (!trace_active || allocation == NULL) return;
    ++traced_allocations;
    if (record_count == HOST_RECORD_CAPACITY) {
        memmove(records, records + 1, (HOST_RECORD_CAPACITY - 1u) * sizeof(records[0]));
        --record_count;
        trace_overflow = 1;
    }
    records[record_count++] = allocation;
}

static void observe_unrelated_activity(void) {
    void *unrelated = __real_malloc(24u);
    track_live(unrelated);
    observe_allocation(unrelated);
    if (unrelated != NULL) {
        if (record_count != 0u) ++traced_frees;
        untrack_live(unrelated);
        __real_free(unrelated);
    }
}

void *__wrap_malloc(size_t size) {
    ++malloc_calls;
    if ((fails("null_malloc") && size == 8u) ||
        (fails("null_overflow_partial") && size == 8u && malloc_calls >= 4u) ||
        (fails("null_overflow_near_capacity") && size == 8u && malloc_calls == 129u)) return NULL;
    void *allocation = __real_malloc(size);
    track_live(allocation);
    if (trace_active && fails("miss_malloc_unrelated") && size == 8u) {
        observe_unrelated_activity();
    } else {
        observe_allocation(allocation);
    }
    return allocation;
}

void *__wrap_calloc(size_t count, size_t size) {
    if (fails("null_calloc")) return NULL;
    void *allocation = __real_calloc(count, size);
    track_live(allocation);
    if (trace_active && fails("miss_calloc_reuse")) {
        missed_calloc_address = allocation;
        return allocation;
    }
    if (trace_active && fails("miss_calloc_unrelated")) observe_unrelated_activity();
    else observe_allocation(allocation);
    return allocation;
}

void __wrap_free(void *allocation) {
    const int reuse_missed_calloc = trace_active && allocation != NULL &&
        fails("miss_calloc_reuse") && allocation == missed_calloc_address;
    if (trace_active && allocation != NULL && record_count != 0u) ++traced_frees;
    untrack_live(allocation);
    __real_free(allocation);
    if (reuse_missed_calloc) {
        missed_calloc_address = NULL;
        void *reused = __real_malloc(8u);
        if (reused != allocation) {
            fprintf(stderr, "heap-trace-calibration-host: allocator did not reuse the freed calloc address\n");
            if (reused != NULL) __real_free(reused);
            return;
        }
        track_live(reused);
        observe_allocation(reused);
        if (record_count != 0u) ++traced_frees;
        untrack_live(reused);
        __real_free(reused);
        address_reuse_counterexample_complete = 1;
    }
}

void *heap_caps_malloc(size_t size, unsigned int caps) {
    (void)caps;
    if (fails("null_heap_caps")) return NULL;
    void *allocation = __real_malloc(size);
    track_live(allocation);
    if (trace_active && fails("miss_heap_caps_unrelated")) observe_unrelated_activity();
    else observe_allocation(allocation);
    return allocation;
}

void heap_caps_free(void *allocation) { __wrap_free(allocation); }

int heap_trace_init_standalone(heap_trace_record_t *buffer, size_t capacity) {
    (void)buffer;
    (void)capacity;
    trace_active = 0;
    traced_allocations = 0;
    traced_frees = 0;
    record_count = 0;
    trace_overflow = 0;
    malloc_calls = 0;
    stopped_summary_reads = 0;
    memset(records, 0, sizeof(records));
    return fails("begin") ? ESP_FAIL : ESP_OK;
}

int heap_trace_start(heap_trace_mode_t mode) {
    (void)mode;
    if (fails("begin")) return ESP_FAIL;
    trace_active = 1;
    return ESP_OK;
}

int heap_trace_stop(void) {
    trace_active = 0;
    return fails("end") ? ESP_FAIL : ESP_OK;
}

size_t heap_trace_get_count(void) { return record_count; }

int heap_trace_get(size_t index, heap_trace_record_t *out) {
    if (out == NULL || index >= record_count) return ESP_FAIL;
    out->address = records[index];
    return ESP_OK;
}

int heap_trace_summary(heap_trace_summary_t *out) {
    if (!trace_active) {
        ++stopped_summary_reads;
        if ((fails("helper_summary") && stopped_summary_reads == 1u) ||
            (fails("final_summary") && stopped_summary_reads == 2u)) return ESP_FAIL;
    }
    if (fails("summary")) return ESP_FAIL;
    *out = (heap_trace_summary_t){
        .mode = HEAP_TRACE_ALL,
        .total_allocations = traced_allocations,
        .total_frees = traced_frees,
        .count = record_count,
        .capacity = HOST_RECORD_CAPACITY,
        .high_water_mark = record_count,
        .has_overflowed = fails("miss_overflow") ? 0u : (size_t)trace_overflow,
    };
    return ESP_OK;
}

int esp_rom_printf(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    const int result = vprintf(format, arguments);
    va_end(arguments);
    return result;
}

int main(int argc, char **argv) {
    failure_mode = argc > 1 ? argv[1] : NULL;
    const int result = axoloty_heap_trace_calibration_run();
    if (fails("miss_calloc_reuse") && !address_reuse_counterexample_complete) {
        fprintf(stderr, "heap-trace-calibration-host: address-reuse counterexample was not constructed\n");
        return 98;
    }
    if (live_count != 0u) {
        fprintf(stderr, "heap-trace-calibration-host: cleanup failed: %zu allocations remain\n", live_count);
        return 99;
    }
    fprintf(stderr, "heap-trace-calibration-host: cleanup PASS\n");
    return result;
}
