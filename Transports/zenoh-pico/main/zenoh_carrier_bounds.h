// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_CARRIER_BOUNDS_H
#define AXOLOTY_ZENOH_CARRIER_BOUNDS_H

// The composed key and payload bounds of this carrier.
//
// The composition writes `axoloty_carrier_bounds.h` from the selected
// application's declared capacities. The carrier sizes its receive storage to
// those. `zenoh_pico_queue.h` proves they fit the Core-owned facade bounds,
// which are not changed here.

#include "axoloty_carrier_bounds.h"

#if !defined(AXOLOTY_CARRIER_MAX_TOPIC_BYTES) || !defined(AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES) || \
    AXOLOTY_CARRIER_MAX_TOPIC_BYTES < 1 || AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES < 1
#error "axoloty_carrier_bounds.h must define positive AXOLOTY_CARRIER_MAX_TOPIC_BYTES and AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES"
#endif

#endif
