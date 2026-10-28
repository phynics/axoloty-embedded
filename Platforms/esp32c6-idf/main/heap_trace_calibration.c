// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "heap_trace_calibration.h"

#include <stdint.h>
#include <stdlib.h>

#include "esp_heap_caps.h"
#include "esp_heap_trace.h"
#include "esp_rom_sys.h"
#include "axoloty_abi_status_v1.h"

#define AXOLOTY_CALIBRATION_RECORDS 128u
#define AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS (AXOLOTY_CALIBRATION_RECORDS + 1u)
#define AXOLOTY_CALIBRATION_ALLOCATION_SIZE 8u

extern int32_t axoloty_heap_trace_begin(void);
extern int32_t axoloty_heap_trace_end(uint32_t *out_allocations);

static void *overflow_allocations[AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS];
static uintptr_t expected_addresses[AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS];
static int matched_addresses[AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS];
static volatile uintptr_t allocation_use;

static void consume_allocation(void *allocation) __attribute__((noinline));
static void consume_allocation(void *allocation) {
    allocation_use ^= (uintptr_t)allocation;
}

static int read_summary(heap_trace_summary_t *summary) {
    return heap_trace_summary(summary) == ESP_OK;
}

static int inspect_live_addresses(
    size_t expected_count,
    size_t first_expected_index,
    size_t expected_records,
    size_t expected_allocations,
    int expect_overflow,
    size_t *out_matched
) {
    heap_trace_summary_t summary = {0};
    if (!read_summary(&summary) || summary.mode != HEAP_TRACE_ALL ||
        summary.total_allocations != expected_allocations || summary.total_frees != 0u ||
        summary.has_overflowed != (size_t)expect_overflow ||
        summary.count != expected_records || heap_trace_get_count() != expected_records) {
        *out_matched = 0u;
        return 0;
    }
    for (size_t address_index = 0; address_index < expected_count; ++address_index) {
        matched_addresses[address_index] = 0;
    }
    size_t matched = 0u;
    for (size_t record_index = 0; record_index < expected_records; ++record_index) {
        heap_trace_record_t record = {0};
        if (heap_trace_get(record_index, &record) != ESP_OK) return 0u;
        for (size_t address_index = 0; address_index < expected_count; ++address_index) {
            if (record.address != NULL &&
                (uintptr_t)record.address == expected_addresses[first_expected_index + address_index] &&
                matched_addresses[address_index] == 0) {
                matched_addresses[address_index] = 1;
                ++matched;
                break;
            }
        }
    }
    *out_matched = matched;
    return matched == expected_records;
}

static int emit_case(
    const char *case_id,
    const char *path,
    int32_t begin_status,
    int32_t end_status,
    int end_called,
    uint32_t allocations,
    size_t frees,
    size_t overflow,
    int mode_value,
    int summary_valid,
    size_t expected,
    size_t matched,
    size_t records,
    int passed
) {
    esp_rom_printf(
        "AXOLOTY_HEAP_CAL_V1,case=%s,result=%s,path=%s,coverage_complete=0,begin=%d,end=%d,end_called=%u,alloc=%u,frees=%u,overflow=%u,mode=%d,mode_ok=%u,summary=%u,expected=%u,matched=%u,records=%u\n",
        case_id,
        passed ? "PASS" : "FAIL",
        path,
        (int)begin_status,
        (int)end_status,
        (unsigned int)end_called,
        (unsigned int)allocations,
        (unsigned int)frees,
        (unsigned int)overflow,
        mode_value,
        (unsigned int)(summary_valid && mode_value == (int)HEAP_TRACE_ALL),
        (unsigned int)summary_valid,
        (unsigned int)expected,
        (unsigned int)matched,
        (unsigned int)records
    );
    return passed;
}

static int run_empty_control(void) {
    uint32_t allocations = UINT32_MAX;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    size_t matched = 0u;
    int live_records_valid = 0;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        live_records_valid = inspect_live_addresses(0u, 0u, 0u, 0u, 0, &matched);
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_OK && allocations == 0u &&
        summary_valid && summary.mode == HEAP_TRACE_ALL &&
        summary.total_allocations == 0u && summary.total_frees == 0u && summary.has_overflowed == 0u &&
        live_records_valid && matched == 0u;
    return emit_case("zero", "none", begin_status, end_status, end_called, allocations,
        summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid, 0u, matched,
        summary_valid ? summary.count : 0u, passed);
}

static int run_malloc_free_control(void) {
    uint32_t allocations = UINT32_MAX;
    void *allocation = NULL;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    size_t matched = 0u;
    int allocation_succeeded = 0;
    int live_records_valid = 0;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        allocation = malloc(AXOLOTY_CALIBRATION_ALLOCATION_SIZE);
        allocation_succeeded = allocation != NULL;
        consume_allocation(allocation);
        expected_addresses[0] = (uintptr_t)allocation;
        if (allocation_succeeded) live_records_valid = inspect_live_addresses(1u, 0u, 1u, 1u, 0, &matched);
        if (allocation != NULL) free(allocation);
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_OK && allocation_succeeded && allocations == 1u &&
        summary_valid && summary.mode == HEAP_TRACE_ALL && summary.total_allocations == 1u &&
        summary.total_frees == 1u && summary.has_overflowed == 0u && live_records_valid && matched == 1u;
    return emit_case("malloc_free", "malloc(size=8);free", begin_status,
        end_status, end_called, allocations, summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid, 1u, matched,
        summary_valid ? summary.count : 0u, passed);
}

static int run_multiple_malloc_control(void) {
    uint32_t allocations = UINT32_MAX;
    void *first = NULL;
    void *second = NULL;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    size_t matched = 0u;
    int allocations_succeeded = 0;
    int live_records_valid = 0;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        first = malloc(AXOLOTY_CALIBRATION_ALLOCATION_SIZE);
        second = malloc(AXOLOTY_CALIBRATION_ALLOCATION_SIZE);
        consume_allocation(first);
        consume_allocation(second);
        allocations_succeeded = first != NULL && second != NULL;
        expected_addresses[0] = (uintptr_t)first;
        expected_addresses[1] = (uintptr_t)second;
        if (allocations_succeeded) live_records_valid = inspect_live_addresses(2u, 0u, 2u, 2u, 0, &matched);
        if (first != NULL) free(first);
        if (second != NULL) free(second);
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_OK && allocations_succeeded && allocations == 2u &&
        summary_valid && summary.mode == HEAP_TRACE_ALL && summary.total_allocations == 2u &&
        summary.total_frees == 2u && summary.has_overflowed == 0u && live_records_valid && matched == 2u;
    return emit_case("malloc_multiple", "malloc(size=8)x2;free", begin_status,
        end_status, end_called, allocations, summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid, 2u, matched,
        summary_valid ? summary.count : 0u, passed);
}

static int run_internal_heap_caps_control(void) {
    uint32_t allocations = UINT32_MAX;
    void *allocation = NULL;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    size_t matched = 0u;
    int allocation_succeeded = 0;
    int live_records_valid = 0;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        allocation = heap_caps_malloc(AXOLOTY_CALIBRATION_ALLOCATION_SIZE,
            MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        allocation_succeeded = allocation != NULL;
        consume_allocation(allocation);
        expected_addresses[0] = (uintptr_t)allocation;
        if (allocation_succeeded) live_records_valid = inspect_live_addresses(1u, 0u, 1u, 1u, 0, &matched);
        if (allocation != NULL) heap_caps_free(allocation);
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_OK && allocation_succeeded && allocations == 1u &&
        summary_valid && summary.mode == HEAP_TRACE_ALL && summary.total_allocations == 1u &&
        summary.total_frees == 1u && summary.has_overflowed == 0u && live_records_valid && matched == 1u;
    return emit_case("heap_caps_internal", "heap_caps_malloc(size=8;caps=INTERNAL+8BIT);heap_caps_free", begin_status,
        end_status, end_called, allocations, summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid, 1u, matched,
        summary_valid ? summary.count : 0u, passed);
}

static int run_calloc_control(void) {
    uint32_t allocations = UINT32_MAX;
    void *allocation = NULL;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    size_t matched = 0u;
    int allocation_succeeded = 0;
    int live_records_valid = 0;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        allocation = calloc(2u, 4u);
        allocation_succeeded = allocation != NULL;
        consume_allocation(allocation);
        expected_addresses[0] = (uintptr_t)allocation;
        if (allocation_succeeded) live_records_valid = inspect_live_addresses(1u, 0u, 1u, 1u, 0, &matched);
        if (allocation != NULL) free(allocation);
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_OK && allocation_succeeded && allocations == 1u &&
        summary_valid && summary.mode == HEAP_TRACE_ALL && summary.total_allocations == 1u &&
        summary.total_frees == 1u && summary.has_overflowed == 0u && live_records_valid && matched == 1u;
    return emit_case("calloc", "calloc(nmemb=2;size=4);free", begin_status,
        end_status, end_called, allocations, summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid, 1u, matched,
        summary_valid ? summary.count : 0u, passed);
}

static int run_overflow_control(void) {
    uint32_t allocations = UINT32_MAX;
    const int32_t begin_status = axoloty_heap_trace_begin();
    int32_t end_status = AXOLOTY_ABI_STATUS_FAILED;
    int end_called = 0;
    heap_trace_summary_t summary = {0};
    int summary_valid = 0;
    int all_allocations_succeeded = 1;
    int live_records_valid = 0;
    size_t matched = 0u;
    if (begin_status == AXOLOTY_ABI_STATUS_OK) {
        for (size_t index = 0; index < AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS; ++index) {
            overflow_allocations[index] = malloc(AXOLOTY_CALIBRATION_ALLOCATION_SIZE);
            consume_allocation(overflow_allocations[index]);
            expected_addresses[index] = (uintptr_t)overflow_allocations[index];
            if (overflow_allocations[index] == NULL) all_allocations_succeeded = 0;
        }
        if (all_allocations_succeeded) {
            live_records_valid = inspect_live_addresses(AXOLOTY_CALIBRATION_RECORDS, 1u,
                AXOLOTY_CALIBRATION_RECORDS, AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS, 1, &matched);
        }
        end_called = 1;
        end_status = axoloty_heap_trace_end(&allocations);
        summary_valid = read_summary(&summary);
        for (size_t index = 0; index < AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS; ++index) {
            if (overflow_allocations[index] != NULL) free(overflow_allocations[index]);
            overflow_allocations[index] = NULL;
        }
    }
    const int passed = begin_status == AXOLOTY_ABI_STATUS_OK &&
        end_status == AXOLOTY_ABI_STATUS_TRACE_OVERFLOW &&
        allocations == UINT32_MAX && summary_valid && summary.mode == HEAP_TRACE_ALL &&
        all_allocations_succeeded &&
        summary.total_allocations == AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS &&
        summary.total_frees == 0u && summary.count == AXOLOTY_CALIBRATION_RECORDS &&
        summary.has_overflowed != 0u && live_records_valid && matched == AXOLOTY_CALIBRATION_RECORDS;
    return emit_case("overflow", "malloc(size=8)x129;free_after_end", begin_status,
        end_status, end_called, allocations, summary_valid ? summary.total_frees : 0u,
        summary_valid ? summary.has_overflowed : 0u,
        summary_valid ? (int)summary.mode : -1, summary_valid,
        AXOLOTY_CALIBRATION_OVERFLOW_ALLOCS, matched,
        summary_valid ? summary.count : 0u, passed);
}

int axoloty_heap_trace_calibration_run(void) {
    allocation_use = 0;
    int passed = 1;
    passed &= run_empty_control();
    passed &= run_malloc_free_control();
    passed &= run_multiple_malloc_control();
    passed &= run_internal_heap_caps_control();
    passed &= run_calloc_control();
    passed &= run_overflow_control();
    allocation_use = 0;
    return passed ? 0 : 1;
}
