// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef TEST_ESP_HEAP_CAPS_H
#define TEST_ESP_HEAP_CAPS_H
#include <stddef.h>
#define MALLOC_CAP_INTERNAL 1
#define MALLOC_CAP_8BIT 2
void *heap_caps_malloc(size_t size, unsigned int caps);
void heap_caps_free(void *allocation);
unsigned int heap_caps_get_free_size(unsigned int caps);
unsigned int heap_caps_get_minimum_free_size(unsigned int caps);
unsigned int heap_caps_get_largest_free_block(unsigned int caps);
#endif
