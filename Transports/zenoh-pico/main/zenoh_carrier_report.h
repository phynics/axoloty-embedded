// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_CARRIER_REPORT_H
#define AXOLOTY_ZENOH_CARRIER_REPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Thin, bounded JSON Lines reporting shim for the C-only carrier scenario.
//
// It is the same shape as the counters' own bounded writer
// (`carrier_diagnostics_write_json`): one fixed caller-owned buffer, every
// append bounds-checked before it writes, and a refusal rather than a
// truncation when the line does not fit. It links no JSON library and
// allocates nothing, so a device with one stack publishes one line per step
// without a heap.
//
// It carries values, not meaning: the caller names every key and supplies
// every value. It classifies nothing, encodes no protocol rule, and does not
// know what a step or a counter is.

/// One fixed line buffer that always suffices for a step line and for the
/// summary line, including the terminator.
#define ZENOH_CARRIER_REPORT_LINE_CAPACITY 1024u

/// A bounded JSON object being built in caller-owned storage.
///
/// The fields are private to `zenoh_carrier_report.c`.
typedef struct {
    char *buffer;
    size_t capacity;
    size_t length;
    bool overflowed;
    bool first;
} ZenohCarrierReportSink;

/// Starts one JSON object in `buffer`. No append before this is valid.
void zenoh_carrier_report_begin(ZenohCarrierReportSink *sink, char *buffer, size_t capacity);

/// Appends `"key":"value"`, escaping the value. Returns false when the line
/// has already overflowed or this append would overflow it.
bool zenoh_carrier_report_key_string(ZenohCarrierReportSink *sink, const char *key,
                                     const char *value);

/// Appends `"key":<unsigned>`. Returns false on overflow.
bool zenoh_carrier_report_key_unsigned(ZenohCarrierReportSink *sink, const char *key,
                                       uint32_t value);

/// Appends `"key":<raw_json>`, copying `raw_json` verbatim. The caller owns
/// well-formedness; this exists to splice a bounded object the caller already
/// built, such as the carrier counter snapshot. Returns false on overflow.
bool zenoh_carrier_report_key_raw(ZenohCarrierReportSink *sink, const char *key,
                                  const char *raw_json);

/// Closes the object and terminates the buffer. Returns the number of bytes
/// written, not counting the terminator, or 0 when the line did not fit. A
/// caller must treat 0 as "no line", never as an empty one.
size_t zenoh_carrier_report_end(ZenohCarrierReportSink *sink);

#endif
