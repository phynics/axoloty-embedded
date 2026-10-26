// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ABI_FIXTURE_H
#define AXOLOTY_ABI_FIXTURE_H

#include "axoloty_application_entry_v1.h"

const axoloty_platform_v1 *unit_b_platform_table(void);
const axoloty_carrier_v1 *unit_b_carrier_table(void);
const axoloty_carrier_v1 *unit_b_minimal_carrier_table(void);
uint32_t unit_b_platform_write_count(void);
uint32_t unit_b_carrier_publish_count(void);
int32_t unit_c2_race_entry(int32_t *results, uint32_t count);

#endif
