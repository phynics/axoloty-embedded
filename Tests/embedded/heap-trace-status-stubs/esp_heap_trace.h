// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef TEST_ESP_HEAP_TRACE_H
#define TEST_ESP_HEAP_TRACE_H
#include <stddef.h>
#define ESP_OK 0
#define ESP_FAIL 1
typedef enum { HEAP_TRACE_ALL, HEAP_TRACE_LEAKS } heap_trace_mode_t;
typedef struct { void *address; } heap_trace_record_t;
typedef struct {
    heap_trace_mode_t mode;
    size_t total_allocations;
    size_t total_frees;
    size_t count;
    size_t capacity;
    size_t high_water_mark;
    size_t has_overflowed;
} heap_trace_summary_t;
int heap_trace_init_standalone(heap_trace_record_t *records, size_t count);
int heap_trace_start(heap_trace_mode_t mode);
int heap_trace_stop(void);
int heap_trace_summary(heap_trace_summary_t *summary);
size_t heap_trace_get_count(void);
int heap_trace_get(size_t index, heap_trace_record_t *record);
#define AXOLOTY_TEST_HEAP_TRACE_CAPACITY 128u
#endif
