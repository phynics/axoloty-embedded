// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "zenoh_carrier_report.h"

// Every writer here reserves one byte for the terminator. A write that cannot
// fit sets `overflowed`, and the object can never be ended afterwards, so a
// partial line is refused rather than emitted.

static bool append_char(ZenohCarrierReportSink *sink, char value) {
    if (sink->overflowed) {
        return false;
    }
    if (sink->length + 1u >= sink->capacity) {
        sink->overflowed = true;
        return false;
    }
    sink->buffer[sink->length] = value;
    sink->length += 1u;
    return true;
}

static bool append_text(ZenohCarrierReportSink *sink, const char *text) {
    for (size_t index = 0; text[index] != '\0'; ++index) {
        if (!append_char(sink, text[index])) {
            return false;
        }
    }
    return true;
}

// Keys and step names are compile-time literals, but a `detail` string can
// carry a value. Escape the two characters that could break the object and
// refuse a control character outright: a refused line is honest, a corrupted
// one is not.
static bool append_escaped(ZenohCarrierReportSink *sink, const char *text) {
    for (size_t index = 0; text[index] != '\0'; ++index) {
        unsigned char value = (unsigned char)text[index];
        if (value < 0x20u) {
            sink->overflowed = true;
            return false;
        }
        if (value == (unsigned char)'"' || value == (unsigned char)'\\') {
            if (!append_char(sink, '\\')) {
                return false;
            }
        }
        if (!append_char(sink, (char)value)) {
            return false;
        }
    }
    return true;
}

static bool append_unsigned(ZenohCarrierReportSink *sink, uint32_t value) {
    char digits[10];
    size_t count = 0;
    do {
        digits[count++] = (char)('0' + (value % 10u));
        value /= 10u;
    } while (value != 0u && count < sizeof(digits));
    while (count > 0u) {
        if (!append_char(sink, digits[--count])) {
            return false;
        }
    }
    return true;
}

static bool separator(ZenohCarrierReportSink *sink) {
    if (!sink->first) {
        if (!append_char(sink, ',')) {
            return false;
        }
    }
    sink->first = false;
    return true;
}

static bool key_prefix(ZenohCarrierReportSink *sink, const char *key) {
    if (!separator(sink)) {
        return false;
    }
    return append_char(sink, '"') && append_escaped(sink, key) && append_text(sink, "\":");
}

void zenoh_carrier_report_begin(ZenohCarrierReportSink *sink, char *buffer, size_t capacity) {
    sink->buffer = buffer;
    sink->capacity = capacity;
    sink->length = 0u;
    sink->overflowed = (buffer == NULL) || (capacity == 0u);
    sink->first = true;
    if (!sink->overflowed) {
        (void)append_char(sink, '{');
    }
}

bool zenoh_carrier_report_key_string(ZenohCarrierReportSink *sink, const char *key,
                                     const char *value) {
    if (!key_prefix(sink, key)) {
        return false;
    }
    return append_char(sink, '"') && append_escaped(sink, value) && append_char(sink, '"');
}

bool zenoh_carrier_report_key_unsigned(ZenohCarrierReportSink *sink, const char *key,
                                       uint32_t value) {
    return key_prefix(sink, key) && append_unsigned(sink, value);
}

bool zenoh_carrier_report_key_raw(ZenohCarrierReportSink *sink, const char *key,
                                  const char *raw_json) {
    return key_prefix(sink, key) && append_text(sink, raw_json);
}

size_t zenoh_carrier_report_end(ZenohCarrierReportSink *sink) {
    if (!append_char(sink, '}') || sink->overflowed) {
        return 0u;
    }
    sink->buffer[sink->length] = '\0';
    return sink->length;
}
