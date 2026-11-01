// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// A copying ring queue with FreeRTOS's static-queue API and semantics: a full
// queue rejects the send, and a receive copies one item out.
#ifndef AXOLOTY_STUB_FREERTOS_QUEUE_H
#define AXOLOTY_STUB_FREERTOS_QUEUE_H
#include <stddef.h>
#include <stdint.h>
#include "FreeRTOS.h"

typedef struct {
    uint8_t *storage;
    unsigned length;
    unsigned item_size;
    unsigned head;
    unsigned count;
} StaticQueue_t;
typedef StaticQueue_t *QueueHandle_t;

QueueHandle_t xQueueCreateStatic(unsigned length, unsigned item_size, uint8_t *storage, StaticQueue_t *queue);
BaseType_t xQueueSend(QueueHandle_t queue, const void *item, TickType_t ticks);
BaseType_t xQueueReceive(QueueHandle_t queue, void *item, TickType_t ticks);
BaseType_t xQueueReset(QueueHandle_t queue);
#endif
