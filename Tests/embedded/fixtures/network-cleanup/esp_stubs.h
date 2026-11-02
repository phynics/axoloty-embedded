// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// Host stand-ins for the ESP-IDF Wi-Fi, event, netif and FreeRTOS APIs that
// network_bootstrap.c calls. The behaviour lives in network-cleanup-test.c.
#pragma once
#include <stdint.h>
#include <string.h>

typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL (-1)
#define ESP_ERR_NVS_NO_FREE_PAGES 0x1101
#define ESP_ERR_NVS_NEW_VERSION_FOUND 0x1102

typedef const char *esp_event_base_t;
typedef void (*esp_event_handler_t)(void *arg, esp_event_base_t base, int32_t id, void *data);
extern esp_event_base_t WIFI_EVENT;
extern esp_event_base_t IP_EVENT;
#define ESP_EVENT_ANY_ID (-1)
enum { WIFI_EVENT_STA_START = 2, WIFI_EVENT_STA_STOP = 3, WIFI_EVENT_STA_DISCONNECTED = 5, IP_EVENT_STA_GOT_IP = 0 };

typedef struct esp_netif esp_netif_t;
typedef struct { int unused; } wifi_init_config_t;
#define WIFI_INIT_CONFIG_DEFAULT() ((wifi_init_config_t){0})
typedef struct { struct { uint8_t ssid[32]; uint8_t password[64]; struct { int authmode; } threshold; } sta; } wifi_config_t;
typedef struct { uint8_t bssid[6]; } wifi_ap_record_t;
enum { WIFI_AUTH_WPA2_PSK = 3, WIFI_MODE_STA = 1, WIFI_IF_STA = 0, ESP_LOG_ERROR = 1 };

typedef uint32_t EventBits_t;
typedef uint32_t TickType_t;
typedef struct EventGroup *EventGroupHandle_t;
#define pdFALSE 0
#define pdTRUE 1
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
#define ESP_LOGW(tag, ...) stub_log_warning(tag, __VA_ARGS__)

int64_t esp_timer_get_time(void);
void stub_log_warning(const char *tag, const char *format, ...);
void esp_log_level_set(const char *tag, int level);
esp_err_t esp_event_handler_register(esp_event_base_t base, int32_t id, esp_event_handler_t handler, void *arg);
esp_err_t esp_event_handler_unregister(esp_event_base_t base, int32_t id, esp_event_handler_t handler);
esp_err_t esp_event_loop_create_default(void);
esp_err_t esp_event_loop_delete_default(void);
esp_err_t esp_netif_init(void);
esp_netif_t *esp_netif_create_default_wifi_sta(void);
void esp_netif_destroy_default_wifi(void *netif);
esp_err_t esp_wifi_init(const wifi_init_config_t *config);
esp_err_t esp_wifi_deinit(void);
esp_err_t esp_wifi_set_mode(int mode);
esp_err_t esp_wifi_set_config(int interface, wifi_config_t *config);
esp_err_t esp_wifi_start(void);
esp_err_t esp_wifi_stop(void);
esp_err_t esp_wifi_connect(void);
esp_err_t esp_wifi_disconnect(void);
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *record);
esp_err_t nvs_flash_init(void);
esp_err_t nvs_flash_erase(void);
EventGroupHandle_t xEventGroupCreate(void);
void vEventGroupDelete(EventGroupHandle_t group);
EventBits_t xEventGroupSetBits(EventGroupHandle_t group, EventBits_t bits);
EventBits_t xEventGroupClearBits(EventGroupHandle_t group, EventBits_t bits);
EventBits_t xEventGroupWaitBits(EventGroupHandle_t group, EventBits_t bits, int clear, int all, TickType_t ticks);
void vTaskDelay(TickType_t ticks);
