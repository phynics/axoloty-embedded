// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef TEST_NETWORK_BOOTSTRAP_H
#define TEST_NETWORK_BOOTSTRAP_H
#include <stdint.h>
int axoloty_network_configured(void);
uint32_t axoloty_network_role(void);
uint32_t axoloty_network_scenario(void);
uint32_t axoloty_network_prepare(uint32_t deadline_ms);
uint32_t axoloty_network_reconnect_wait(uint32_t deadline_ms);
uint32_t axoloty_network_cleanup(void);
#endif
