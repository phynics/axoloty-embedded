// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Real pinned zenoh-pico key-expression parser check for the application-owned
// route interest shapes. `*` is the one-chunk wildcard; `#` is accepted as a
// literal key chunk, not interpreted as a subtree wildcard.

#include "zenoh-pico/api/constants.h"
#include "zenoh-pico/api/primitives.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *valid[] = {
        "coaty/3/axoloty-embedded/*/*",
        "coaty/3/axoloty-embedded/*/*/*",
    };
    for (size_t index = 0; index < sizeof(valid) / sizeof(valid[0]); ++index) {
        char buffer[128];
        size_t length = strlen(valid[index]);
        assert(length < sizeof(buffer));
        memcpy(buffer, valid[index], length + 1);
        z_view_keyexpr_t view;
        z_result_t result = z_view_keyexpr_from_str(&view, buffer);
        printf("%s => accepted (%d)\n", valid[index], result);
        assert(result == 0);
        assert(length == strlen(valid[index]));
    }

    char legacy_mqtt_filter[] = "coaty/3/axoloty-embedded/#";
    z_view_keyexpr_t legacy_view;
    z_result_t legacy_result = z_view_keyexpr_from_str(&legacy_view, legacy_mqtt_filter);
    printf("coaty/3/axoloty-embedded/# => accepted as literal (%d)\n", legacy_result);
    assert(legacy_result == 0);
    return 0;
}
