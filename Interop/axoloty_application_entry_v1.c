// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_application_entry_v1.h"

#include <stdatomic.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "application entry requires always-lock-free int atomics");
_Static_assert(sizeof(uint32_t) == sizeof(unsigned int), "application entry requires 32-bit unsigned int");

static _Atomic(unsigned int) application_entry_claimed = 0U;

int32_t axoloty_application_entry_claim_v1(void) {
    unsigned int expected = 0U;
    return atomic_compare_exchange_strong_explicit(
        &application_entry_claimed,
        &expected,
        1U,
        memory_order_acq_rel,
        memory_order_relaxed
    ) ? 1 : 0;
}
