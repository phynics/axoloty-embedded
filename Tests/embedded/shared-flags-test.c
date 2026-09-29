// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "embedded_shared_flags.h"

#include <assert.h>
#include <pthread.h>
#include <stddef.h>

enum { Iterations = 100000 };

typedef struct {
    AxolotyAtomicUInt event_bits;
    AxolotyAtomicUInt connection_count;
    AxolotyAtomicUInt retry_count;
    AxolotyAtomicInt disconnecting;
} TestContext;

static void *callback_thread(void *argument) {
    TestContext *context = argument;
    for (unsigned index = 0; index < Iterations; ++index) {
        axoloty_atomic_uint_fetch_or(&context->event_bits, 1U << (index % 8U));
        axoloty_atomic_uint_fetch_add(&context->connection_count, 1U);
        axoloty_atomic_uint_fetch_add(&context->retry_count, 1U);
        axoloty_atomic_int_store(&context->disconnecting, (int)(index & 1U));
    }
    return NULL;
}

static void *main_loop_thread(void *argument) {
    TestContext *context = argument;
    for (unsigned index = 0; index < Iterations; ++index) {
        (void)axoloty_atomic_uint_load(&context->event_bits);
        axoloty_atomic_uint_fetch_and(&context->event_bits, ~(1U << (index % 8U)));
        (void)axoloty_atomic_uint_load(&context->connection_count);
        (void)axoloty_atomic_uint_load(&context->retry_count);
        assert(axoloty_atomic_int_load(&context->disconnecting) >= 0);
    }
    return NULL;
}

int main(void) {
    TestContext context = { 0 };
    pthread_t callback;
    pthread_t main_loop;

    assert(pthread_create(&callback, NULL, callback_thread, &context) == 0);
    assert(pthread_create(&main_loop, NULL, main_loop_thread, &context) == 0);
    assert(pthread_join(callback, NULL) == 0);
    assert(pthread_join(main_loop, NULL) == 0);
    assert(axoloty_atomic_uint_load(&context.connection_count) == Iterations);
    assert(axoloty_atomic_uint_load(&context.retry_count) == Iterations);
    return 0;
}
