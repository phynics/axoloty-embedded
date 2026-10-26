// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef TEST_ESP_HEAP_CAPS_H
#define TEST_ESP_HEAP_CAPS_H
#include <stddef.h>
#define MALLOC_CAP_INTERNAL 0
size_t heap_caps_get_free_size(int caps);
size_t heap_caps_get_minimum_free_size(int caps);
size_t heap_caps_get_largest_free_block(int caps);
#endif
