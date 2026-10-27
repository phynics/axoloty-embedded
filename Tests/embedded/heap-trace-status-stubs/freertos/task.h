// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef TEST_TASK_H
#define TEST_TASK_H
#include "freertos/FreeRTOS.h"
void vTaskDelay(TickType_t ticks);
unsigned int uxTaskGetStackHighWaterMark(void *task);
#endif
