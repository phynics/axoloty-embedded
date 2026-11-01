// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Hardware-free check that a failed application entry is reported (#131).
//
// It compiles the real platform entry (Esp32c6AppMain.c) and the real reporter,
// and stands in for the three symbols they call: the application dispatcher,
// the platform table, and the carrier table.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "application_entry_report.h"
#include "axoloty_application_entry_v1.h"

void app_main(void);

static char captured[512];
static size_t captured_length;
static unsigned write_calls;
static int32_t next_status;
static unsigned main_calls;

static int32_t capture_log(void *context, const uint8_t *bytes, uint32_t length) {
    (void)context;
    ++write_calls;
    if (captured_length + length >= sizeof(captured)) abort();
    memcpy(captured + captured_length, bytes, length);
    captured_length += length;
    captured[captured_length] = '\0';
    return AXOLOTY_ABI_STATUS_OK;
}

static axoloty_platform_v1 platform = { .write_log = capture_log };

const axoloty_platform_v1 *axoloty_platform_get_v1(void) { return &platform; }
const axoloty_carrier_v1 *axoloty_carrier_get_v1(void) { return NULL; }
int32_t axoloty_application_main(const axoloty_platform_v1 *table, const axoloty_carrier_v1 *carrier) {
    (void)carrier;
    ++main_calls;
    if (table != &platform) abort();
    return next_status;
}

static void reset(void) {
    captured[0] = '\0';
    captured_length = 0;
    write_calls = 0;
}

static void expect_line(int32_t status, const char *expected) {
    reset();
    axoloty_application_entry_report(&platform, status);
    if (write_calls != 1 || strcmp(captured, expected) != 0) {
        fprintf(stderr, "status %d: got \"%s\" in %u writes, expected \"%s\"\n", (int)status, captured, write_calls, expected);
        exit(1);
    }
}

int main(void) {
    expect_line(AXOLOTY_APPLICATION_STATUS_FAILED, "axoloty:application-entry-failed status=-100 name=failed\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_INVALID_ABI, "axoloty:application-entry-failed status=-101 name=invalid-abi\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED, "axoloty:application-entry-failed status=-102 name=state-budget-exceeded\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED, "axoloty:application-entry-failed status=-103 name=already-entered\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_TRACE_REQUIREMENTS_MISMATCH, "axoloty:application-entry-failed status=-104 name=trace-requirements-mismatch\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_TRACE_START_FAILED, "axoloty:application-entry-failed status=-105 name=trace-start-failed\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_TRACE_STOP_FAILED, "axoloty:application-entry-failed status=-106 name=trace-stop-failed\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_TRACE_OVERFLOW, "axoloty:application-entry-failed status=-107 name=trace-overflow\n");
    expect_line(AXOLOTY_APPLICATION_STATUS_TRACE_ALLOCATIONS_OBSERVED, "axoloty:application-entry-failed status=-108 name=trace-allocations-observed\n");
    // A status this table does not name still prints its number.
    expect_line(7, "axoloty:application-entry-failed status=7 name=unknown\n");
    expect_line(INT32_MIN, "axoloty:application-entry-failed status=-2147483648 name=unknown\n");

    // Completion is silent, and so is a table that cannot log.
    reset();
    axoloty_application_entry_report(&platform, AXOLOTY_APPLICATION_STATUS_COMPLETED);
    if (write_calls != 0) { fputs("a completed entry printed a line\n", stderr); return 1; }
    axoloty_application_entry_report(NULL, AXOLOTY_APPLICATION_STATUS_FAILED);
    axoloty_platform_v1 silent = { .write_log = NULL };
    axoloty_application_entry_report(&silent, AXOLOTY_APPLICATION_STATUS_FAILED);
    if (write_calls != 0) { fputs("a table without a log writer printed a line\n", stderr); return 1; }

    // app_main reports what the application entry returned.
    reset();
    next_status = AXOLOTY_APPLICATION_STATUS_TRACE_START_FAILED;
    app_main();
    if (main_calls != 1 || write_calls != 1 ||
        strcmp(captured, "axoloty:application-entry-failed status=-105 name=trace-start-failed\n") != 0) {
        fprintf(stderr, "app_main did not report the entry status: \"%s\"\n", captured);
        return 1;
    }
    reset();
    next_status = AXOLOTY_APPLICATION_STATUS_COMPLETED;
    app_main();
    if (main_calls != 2 || write_calls != 0) { fputs("app_main reported a completed entry\n", stderr); return 1; }

    puts("application entry report tests passed");
    return 0;
}
