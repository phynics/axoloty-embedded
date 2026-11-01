// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "application_entry_report.h"

#include <stddef.h>

#include "axoloty_application_entry_v1.h"

static const char *entry_status_name(int32_t status) {
    switch (status) {
        case AXOLOTY_APPLICATION_STATUS_FAILED: return "failed";
        case AXOLOTY_APPLICATION_STATUS_INVALID_ABI: return "invalid-abi";
        case AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED: return "state-budget-exceeded";
        case AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED: return "already-entered";
        case AXOLOTY_APPLICATION_STATUS_TRACE_REQUIREMENTS_MISMATCH: return "trace-requirements-mismatch";
        case AXOLOTY_APPLICATION_STATUS_TRACE_START_FAILED: return "trace-start-failed";
        case AXOLOTY_APPLICATION_STATUS_TRACE_STOP_FAILED: return "trace-stop-failed";
        case AXOLOTY_APPLICATION_STATUS_TRACE_OVERFLOW: return "trace-overflow";
        case AXOLOTY_APPLICATION_STATUS_TRACE_ALLOCATIONS_OBSERVED: return "trace-allocations-observed";
        default: return "unknown";
    }
}

// Appends `text` to `line` while room remains for a terminating newline.
static size_t append_text(char *line, size_t capacity, size_t length, const char *text) {
    while (*text != '\0' && length + 1u < capacity) line[length++] = *text++;
    return length;
}

static size_t append_decimal(char *line, size_t capacity, size_t length, int32_t value) {
    char digits[12];
    size_t count = 0;
    // Widen before negating so INT32_MIN has a magnitude.
    int64_t magnitude = value;
    if (magnitude < 0) {
        length = append_text(line, capacity, length, "-");
        magnitude = -magnitude;
    }
    do {
        digits[count++] = (char)('0' + (int)(magnitude % 10));
        magnitude /= 10;
    } while (magnitude > 0 && count < sizeof(digits));
    while (count > 0 && length + 1u < capacity) line[length++] = digits[--count];
    return length;
}

void axoloty_application_entry_report(const axoloty_platform_v1 *platform, int32_t status) {
    if (status == AXOLOTY_APPLICATION_STATUS_COMPLETED) return;
    if (platform == NULL || platform->write_log == NULL) return;
    char line[96];
    size_t length = 0;
    length = append_text(line, sizeof(line), length, "axoloty:application-entry-failed status=");
    length = append_decimal(line, sizeof(line), length, status);
    length = append_text(line, sizeof(line), length, " name=");
    length = append_text(line, sizeof(line), length, entry_status_name(status));
    line[length++] = '\n';
    (void)platform->write_log(platform->context, (const uint8_t *)line, (uint32_t)length);
}
