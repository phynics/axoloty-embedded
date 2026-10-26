// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "abi-fixture.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

enum { UNIT_C2_CALLER_COUNT = 16 };

typedef struct {
    pthread_barrier_t *barrier;
    int32_t *result;
} caller_context;

static void *competing_entry(void *opaque) {
    caller_context *context = opaque;
    int barrier_status = pthread_barrier_wait(context->barrier);
    if (barrier_status != 0 && barrier_status != PTHREAD_BARRIER_SERIAL_THREAD) {
        return NULL;
    }
    *context->result = axoloty_application_main(
        unit_b_platform_table(), unit_b_minimal_carrier_table()
    );
    return NULL;
}

int32_t unit_c2_race_entry(int32_t *results, uint32_t count) {
    if (results == NULL || count != UNIT_C2_CALLER_COUNT) {
        return -1;
    }

    pthread_barrier_t barrier;
    pthread_t threads[UNIT_C2_CALLER_COUNT];
    caller_context contexts[UNIT_C2_CALLER_COUNT];
    if (pthread_barrier_init(&barrier, NULL, UNIT_C2_CALLER_COUNT) != 0) {
        return -2;
    }
    for (uint32_t index = 0; index < UNIT_C2_CALLER_COUNT; index += 1) {
        contexts[index].barrier = &barrier;
        contexts[index].result = &results[index];
        if (pthread_create(&threads[index], NULL, competing_entry, &contexts[index]) != 0) {
            abort();
        }
    }
    for (uint32_t index = 0; index < UNIT_C2_CALLER_COUNT; index += 1) {
        if (pthread_join(threads[index], NULL) != 0) {
            abort();
        }
    }
    int destroy_status = pthread_barrier_destroy(&barrier);
    return destroy_status == 0 ? 0 : -3;
}
