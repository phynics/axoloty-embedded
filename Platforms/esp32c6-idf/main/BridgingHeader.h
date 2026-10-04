// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Bridging header exposing ESP-IDF C APIs to Embedded Swift.

#include <stdio.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

// Exposes the selected scheduler frequency to the transport's bounded wait
// calculation. Embedded Swift does not import the SDK's config macros.
#ifndef AXOLOTY_TICKS_FROM_MS_DEFINED
#define AXOLOTY_TICKS_FROM_MS_DEFINED
static inline unsigned int axoloty_scheduler_hz(void) {
    return configTICK_RATE_HZ;
}
#endif

// Carrier declarations are owned by the selected transport. The include path
// is supplied by that transport's composition metadata.
#if __has_include("mqtt_carrier.h")
#include "mqtt_carrier.h"
#endif
// The Zenoh carrier seam is the Core-owned facade ABI. The transport supplies
// the include path; the platform names no carrier operation of its own.
#if __has_include("axoloty_zenoh.h")
#include "axoloty_zenoh.h"
#endif
// The Zenoh transport's operator-endpoint helper. Present only when that
// transport is selected; other profiles are unaffected.
#if __has_include("zenoh_endpoint.h")
#include "zenoh_endpoint.h"
#endif
// The transport-neutral carrier diagnostics the selected transport populates
// from its own carrier results. Present only when that transport is selected;
// other profiles are unaffected. It declares counters without facade types.
#if __has_include("carrier_diagnostics.h")
#include "carrier_diagnostics.h"
#endif

// The selected application owns its C-callable device-agent seam.
#if __has_include("static_device_agent.h")
#include "static_device_agent.h"
#endif

// ESP-IDF calls app_main; the optional linker probe is rooted by the platform.
void app_main(void);
#include "../../../Interop/swift_c_interop.h"
int axoloty_unicode_linker_probe(
    const unsigned char * AXOLOTY_NONNULL bytes, int length);

// C helpers for Swift logging (variadic functions like printf are unavailable
// in Embedded Swift).
void axoloty_print(const char *msg);
void axoloty_print_uint(const char *label, unsigned int value);
unsigned int axoloty_free_internal_heap(void);
unsigned int axoloty_min_free_internal_heap(void);
unsigned int axoloty_largest_internal_block(void);
unsigned int axoloty_main_stack_high_water(void);
unsigned int axoloty_main_stack_size(void);
unsigned int axoloty_reset_reason(void);
int axoloty_heap_trace_begin(void);
unsigned int axoloty_heap_trace_end(void);

// Platform-owned Wi-Fi, network deadline, and device configuration operations.
#include "network_bootstrap.h"

// The selected transport may declare its carrier C seam in a header of its
// own. The platform supplies the transport include path; it does not name a
// carrier here. A profile whose transport has no such header is unaffected.
#if __has_include("axoloty_zenoh.h")
#include "axoloty_zenoh.h"
#endif
