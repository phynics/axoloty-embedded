// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Real pinned zenoh-pico key-expression parser check for the application-owned
// route interest shapes. `*` is the one-chunk wildcard; `#` is accepted as a
// literal key chunk, not interpreted as a subtree wildcard.

#include "zenoh-pico.h"

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

    z_view_keyexpr_t two_levels, three_levels, two_level_route, three_level_route;
    assert(z_view_keyexpr_from_str(&two_levels, "coaty/3/axoloty-embedded/*/*") == 0);
    assert(z_view_keyexpr_from_str(&three_levels, "coaty/3/axoloty-embedded/*/*/*") == 0);
    assert(z_view_keyexpr_from_str(&two_level_route, "coaty/3/axoloty-embedded/ADV/source") == 0);
    assert(z_view_keyexpr_from_str(&three_level_route, "coaty/3/axoloty-embedded/DSC/source/correlation") == 0);
    assert(z_keyexpr_intersects(z_loan(two_levels), z_loan(two_level_route)));
    assert(!z_keyexpr_intersects(z_loan(two_levels), z_loan(three_level_route)));
    assert(!z_keyexpr_intersects(z_loan(three_levels), z_loan(two_level_route)));
    assert(z_keyexpr_intersects(z_loan(three_levels), z_loan(three_level_route)));

    char legacy_mqtt_filter[] = "coaty/3/axoloty-embedded/#";
    z_view_keyexpr_t legacy_view;
    z_result_t legacy_result = z_view_keyexpr_from_str(&legacy_view, legacy_mqtt_filter);
    printf("coaty/3/axoloty-embedded/# => accepted as literal (%d)\n", legacy_result);
    assert(legacy_result == 0);
    assert(z_keyexpr_intersects(z_loan(legacy_view), z_loan(legacy_view)));
    assert(!z_keyexpr_intersects(z_loan(legacy_view), z_loan(two_level_route)));
    return 0;
}
