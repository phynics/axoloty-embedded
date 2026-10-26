// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_application_entry_v1.h"

/*
 * Use the compiler atomic builtins rather than <stdatomic.h>: the ESP-IDF
 * toolchain's newlib header does not expose the C11 atomic macros, while the
 * GCC/Clang builtins are available on every target this helper compiles for.
 * The static assertion still proves the required lock-free guarantee.
 */
_Static_assert(__GCC_ATOMIC_INT_LOCK_FREE == 2,
               "application entry requires always-lock-free int atomics");
_Static_assert(sizeof(uint32_t) == sizeof(unsigned int),
               "application entry requires 32-bit unsigned int");

static unsigned int application_entry_claimed = 0U;

int32_t axoloty_application_entry_claim_v1(void) {
    unsigned int expected = 0U;
    return __atomic_compare_exchange_n(
        &application_entry_claimed,
        &expected,
        1U,
        0,
        __ATOMIC_ACQ_REL,
        __ATOMIC_RELAXED
    ) ? 1 : 0;
}

/*
 * A transport that has not supplied a version 1 carrier table yet links with
 * this weak default. The shared entry then reports INVALID_ABI instead of
 * failing to link, so an unmigrated profile still builds and fails loudly at
 * startup. A migrated transport provides the strong definition.
 */
__attribute__((weak)) const axoloty_carrier_v1 *axoloty_carrier_get_v1(void) {
    return NULL;
}
