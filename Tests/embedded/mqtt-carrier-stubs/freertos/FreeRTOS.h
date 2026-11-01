// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef AXOLOTY_STUB_FREERTOS_H
#define AXOLOTY_STUB_FREERTOS_H
#include <stdint.h>
#define pdTRUE 1
#define pdFALSE 0
#define pdMS_TO_TICKS(ms) (ms)
typedef struct { int unused; } portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED { 0 }
#define taskENTER_CRITICAL(mux) ((void)(mux))
#define taskEXIT_CRITICAL(mux) ((void)(mux))
typedef uint32_t TickType_t;
typedef int BaseType_t;
#endif
