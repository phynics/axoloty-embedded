// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "application_entry_report.h"
#include "axoloty_application_entry_v1.h"

#if AXOLOTY_HEAP_TRACE_CALIBRATION
#include "heap_trace_calibration.h"
#endif

void app_main(void) {
#if AXOLOTY_HEAP_TRACE_CALIBRATION
    if (axoloty_heap_trace_calibration_run() != 0) return;
#endif
    const axoloty_platform_v1 *platform = axoloty_platform_get_v1();
    // The entry returns only when the application ended or never started. Say
    // which, on the platform log: without this line the board is silent after
    // the bootloader and the cause is invisible.
    axoloty_application_entry_report(
        platform,
        axoloty_application_main(platform, axoloty_carrier_get_v1())
    );
}
