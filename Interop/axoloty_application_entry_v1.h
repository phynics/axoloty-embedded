// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_APPLICATION_ENTRY_V1_H
#define AXOLOTY_APPLICATION_ENTRY_V1_H

#include <stdint.h>
#include "axoloty_platform_v1.h"
#include "axoloty_carrier_v1.h"

/* Stable statuses returned only by axoloty_application_main. */
#define AXOLOTY_APPLICATION_STATUS_COMPLETED ((int32_t)0)
#define AXOLOTY_APPLICATION_STATUS_FAILED ((int32_t)-100)
#define AXOLOTY_APPLICATION_STATUS_INVALID_ABI ((int32_t)-101)
#define AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED ((int32_t)-102)
#define AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED ((int32_t)-103)

#ifdef __cplusplus
extern "C" {
#endif

int32_t axoloty_application_main(
    const axoloty_platform_v1 *platform,
    const axoloty_carrier_v1 *carrier
);

/* Claims the single application entry for this process lifetime. */
int32_t axoloty_application_entry_claim_v1(void);

#ifdef __cplusplus
}
#endif

#endif
