// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef TEST_ESP_ROM_SYS_H
#define TEST_ESP_ROM_SYS_H
#include <stdint.h>
void esp_rom_output_to_channels(char byte);
int esp_rom_printf(const char *format, ...);
#endif
