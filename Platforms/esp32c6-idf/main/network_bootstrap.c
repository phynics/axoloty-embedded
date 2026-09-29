// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// ESP32-C6 Wi-Fi, NVS, and IP lifecycle. Carrier mechanics are supplied by the
// selected transport.

#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "embedded_shared_flags.h"
#include "network_bootstrap.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include <stdint.h>
#include <string.h>

// Optional selected-transport lifecycle hooks preserve transport-owned state
// boundaries without making the platform depend on a particular carrier.
__attribute__((weak)) int axoloty_transport_network_prepare(void) { return 1; }
__attribute__((weak)) void axoloty_transport_network_cleanup(void) {}

#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
#endif

#ifndef AXOLOTY_DEVICE_DISPLAY_NAME
#define AXOLOTY_DEVICE_DISPLAY_NAME "ESP32-C6 A"
#endif

#define WIFI_BIT (1U << 0)
#define IP_BIT (1U << 1)
#define WIFI_FAIL_BIT (1U << 2)

static EventGroupHandle_t network_events;
static esp_netif_t *network_netif;
static AxolotyAtomicUInt network_wifi_retry_count;
static AxolotyAtomicInt network_forced_wifi_disconnect;
static int network_event_loop_ready;
static int network_wifi_initialized;
static int network_wifi_started;
static int network_wifi_handler_registered;
static int network_ip_handler_registered;
static uint32_t network_overall_start;
static unsigned int network_overall_deadline_ms;

static int network_deadline(uint32_t start, uint32_t timeout) {
    return (uint32_t)(esp_timer_get_time() / 1000ULL) - start < timeout;
}

static TickType_t network_wait_ticks(uint32_t start, uint32_t timeout, uint32_t maximum_wait_ms) {
    uint32_t elapsed = (uint32_t)(esp_timer_get_time() / 1000ULL) - start;
    if (elapsed >= timeout) return 0;
    uint32_t remaining = timeout - elapsed;
    return pdMS_TO_TICKS(remaining < maximum_wait_ms ? remaining : maximum_wait_ms);
}

static void network_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == IP_EVENT_STA_GOT_IP) {
        axoloty_atomic_uint_store(&network_wifi_retry_count, 0);
        xEventGroupSetBits(network_events, IP_BIT);
    }
}

static void network_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_START) esp_wifi_connect();
    else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        if (axoloty_atomic_int_load(&network_forced_wifi_disconnect)) {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        } else if (axoloty_atomic_uint_load(&network_wifi_retry_count) < 5U) {
            axoloty_atomic_uint_fetch_add(&network_wifi_retry_count, 1U);
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        }
    }
}

unsigned int axoloty_network_prepare(unsigned int overall_deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)overall_deadline_ms;
    return 0;
#else
    const uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    network_overall_start = start;
    network_overall_deadline_ms = overall_deadline_ms;
    network_event_loop_ready = 0;
    network_wifi_initialized = 0;
    network_wifi_started = 0;
    network_wifi_handler_registered = 0;
    network_ip_handler_registered = 0;
    axoloty_atomic_uint_store(&network_wifi_retry_count, 0);
    axoloty_atomic_int_store(&network_forced_wifi_disconnect, 0);
    if (!axoloty_transport_network_prepare()) return 0;

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() != ESP_OK) return 0;
        err = nvs_flash_init();
    }
    if (err != ESP_OK || esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return 0;
    network_event_loop_ready = 1;
    network_events = xEventGroupCreate();
    if (!network_events) goto network_prepare_failed;
    network_netif = esp_netif_create_default_wifi_sta();
    if (!network_netif) goto network_prepare_failed;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) goto network_prepare_failed;
    network_wifi_initialized = 1;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event, NULL) != ESP_OK) {
        goto network_prepare_failed;
    }
    network_wifi_handler_registered = 1;
    if (esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event, NULL) != ESP_OK) {
        goto network_prepare_failed;
    }
    network_ip_handler_registered = 1;
    wifi_config_t wifi = { 0 };
    memcpy(wifi.sta.ssid, axoloty_wifi_ssid, axoloty_wifi_ssid_length);
    memcpy(wifi.sta.password, axoloty_wifi_password, axoloty_wifi_password_length);
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_set_config(WIFI_IF_STA, &wifi) != ESP_OK ||
        esp_wifi_start() != ESP_OK) goto network_prepare_failed;
    network_wifi_started = 1;
    EventBits_t bits = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE,
        network_wait_ticks(start, overall_deadline_ms, 30000));
    if ((bits & IP_BIT) == 0 || !network_deadline(start, overall_deadline_ms)) goto network_prepare_failed;
    return 3U;
network_prepare_failed:
    axoloty_network_cleanup();
    return 0;
#endif
}

unsigned int axoloty_network_reconnect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    if (!network_wifi_started || !network_events) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    xEventGroupClearBits(network_events, WIFI_FAIL_BIT | IP_BIT);
    axoloty_atomic_int_store(&network_forced_wifi_disconnect, 1);
    if (esp_wifi_disconnect() != ESP_OK) {
        axoloty_atomic_int_store(&network_forced_wifi_disconnect, 0);
        return 0;
    }
    EventBits_t disconnected = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT, pdTRUE, pdFALSE,
        network_wait_ticks(start, deadline_ms, 5000));
    axoloty_atomic_int_store(&network_forced_wifi_disconnect, 0);
    if (!(disconnected & WIFI_FAIL_BIT)) return 0;
    vTaskDelay(pdMS_TO_TICKS(500));
    if (esp_wifi_connect() != ESP_OK) return 0;
    EventBits_t connected = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE,
        network_wait_ticks(start, deadline_ms, 30000));
    if (!(connected & IP_BIT) || !network_deadline(start, deadline_ms) ||
        !network_deadline(network_overall_start, network_overall_deadline_ms)) return 0;
    return 3U;
#endif
}

int axoloty_network_is_active(void) {
    return network_events != NULL;
}

unsigned int axoloty_network_deadline_remaining_ms(void) {
    if (!network_events) return 0;
    uint32_t now = (uint32_t)(esp_timer_get_time() / 1000ULL);
    uint32_t elapsed = now - network_overall_start;
    if (elapsed >= network_overall_deadline_ms) return 0;
    return network_overall_deadline_ms - elapsed;
}

// A selected transport may override these optional probe-data operations.
// Profiles without a network probe keep the platform seam linkable.
__attribute__((weak)) int axoloty_network_copy_topic(unsigned char *buffer, int capacity) {
    (void)buffer;
    (void)capacity;
    return 0;
}

__attribute__((weak)) int axoloty_network_copy_payload(unsigned char *buffer, int capacity) {
    (void)buffer;
    (void)capacity;
    return 0;
}

unsigned int axoloty_network_cleanup(void) {
#if !AXOLOTY_NETWORK_CONFIGURED
    return 0;
#else
    if (network_wifi_handler_registered) {
        esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event);
    }
    if (network_ip_handler_registered) {
        esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event);
    }
    esp_err_t disconnect = !network_wifi_started || esp_wifi_disconnect() == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t stop = !network_wifi_started || esp_wifi_stop() == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t deinit = !network_wifi_initialized || esp_wifi_deinit() == ESP_OK ? ESP_OK : ESP_FAIL;
    if (network_netif) esp_netif_destroy_default_wifi(network_netif);
    network_netif = NULL;
    if (network_event_loop_ready) esp_event_loop_delete_default();
    if (network_events) vEventGroupDelete(network_events);
    network_events = NULL;
    network_event_loop_ready = 0;
    network_wifi_initialized = 0;
    network_wifi_started = 0;
    network_wifi_handler_registered = 0;
    network_ip_handler_registered = 0;
    axoloty_atomic_uint_store(&network_wifi_retry_count, 0);
    axoloty_atomic_int_store(&network_forced_wifi_disconnect, 0);
    axoloty_transport_network_cleanup();
    return disconnect == ESP_OK && stop == ESP_OK && deinit == ESP_OK;
#endif
}

int axoloty_network_configured(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return 1;
#else
    return 0;
#endif
}

unsigned int axoloty_network_role(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return axoloty_device_role;
#else
    return 0;
#endif
}

unsigned int axoloty_network_scenario(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return axoloty_agent_scenario;
#else
    return 0;
#endif
}

// Copies the operator-configured device display name into caller storage and
// returns its length. The application builds its advertised object from these
// bytes, so a board name never appears in application source.
int axoloty_device_display_name(unsigned char *buffer, int capacity) {
    const char *name = AXOLOTY_DEVICE_DISPLAY_NAME;
    size_t length = strlen(name);
    if (!buffer || capacity <= (int)length) return -1;
    memcpy(buffer, name, length);
    return (int)length;
}
