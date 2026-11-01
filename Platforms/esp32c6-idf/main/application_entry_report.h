// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_APPLICATION_ENTRY_REPORT_H
#define AXOLOTY_APPLICATION_ENTRY_REPORT_H

#include <stdint.h>

#include "axoloty_platform_v1.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Reports a nonzero `axoloty_application_main` status on the platform log as one
 * fixed line:
 *
 *   axoloty:application-entry-failed status=<decimal> name=<fixed name>
 *
 * The line carries the status number and a fixed name only. It prints nothing
 * for AXOLOTY_APPLICATION_STATUS_COMPLETED, nothing when the platform table has
 * no log writer, and never more than one line.
 */
void axoloty_application_entry_report(const axoloty_platform_v1 *platform, int32_t status);

#ifdef __cplusplus
}
#endif

#endif
