// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef AXOLOTY_STUB_ESP_MAC_H
#define AXOLOTY_STUB_ESP_MAC_H
#include <stdint.h>
#include "esp_err.h"
#define ESP_MAC_WIFI_STA 0
esp_err_t esp_read_mac(uint8_t *mac, int type);
#endif
