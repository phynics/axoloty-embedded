// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
#endif

int axoloty_network_configured(void) {
    return AXOLOTY_NETWORK_CONFIGURED;
}
