// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_application_entry_v1.h"

#if AXOLOTY_HEAP_TRACE_CALIBRATION
#include "heap_trace_calibration.h"
#endif

void app_main(void) {
#if AXOLOTY_HEAP_TRACE_CALIBRATION
    if (axoloty_heap_trace_calibration_run() != 0) return;
#endif
    (void)axoloty_application_main(
        axoloty_platform_get_v1(),
        axoloty_carrier_get_v1()
    );
}
