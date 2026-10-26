// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_application_entry_v1.h"

void app_main(void) {
    (void)axoloty_application_main(
        axoloty_platform_get_v1(),
        axoloty_carrier_get_v1()
    );
}
