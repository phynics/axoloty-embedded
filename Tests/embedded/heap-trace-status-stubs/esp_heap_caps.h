// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef TEST_ESP_HEAP_CAPS_H
#define TEST_ESP_HEAP_CAPS_H
#define MALLOC_CAP_INTERNAL 1
unsigned int heap_caps_get_free_size(unsigned int caps);
unsigned int heap_caps_get_minimum_free_size(unsigned int caps);
unsigned int heap_caps_get_largest_free_block(unsigned int caps);
#endif
