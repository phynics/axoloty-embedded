// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Deliberately synchronous Wi-Fi/MQTT test façade. ESP-MQTT callbacks only
// inspect or copy bounded data while they execute; no callback pointer escapes.

#include "esp_event.h"
#include "esp_mac.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mqtt_client.h"
#include "nvs_flash.h"
#include "runtime_identity.h"
#include "embedded_shared_flags.h"
#include "mqtt_event_validation.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
static const char axoloty_runtime_identity[] = "";
#endif

// The advertised device display name is operator configuration. The tracked
// default names this platform's reference board; an operator may override it
// from axoloty_network_config.h.
#ifndef AXOLOTY_DEVICE_DISPLAY_NAME
#define AXOLOTY_DEVICE_DISPLAY_NAME "ESP32-C6 A"
#endif

#define WIFI_BIT (1U << 0)
#define IP_BIT (1U << 1)
#define WIFI_FAIL_BIT (1U << 2)
#define NETWORK_MAX_TOPIC 257
#define NETWORK_MAX_PAYLOAD 2049
#define NETWORK_SUBSCRIPTION_CAPACITY 4
#define NETWORK_EVENT_CAPACITY 4
#define NETWORK_EVENT_OVERFLOW_BIT (1U << 6)

typedef struct {
    int topic_length;
    int payload_length;
    unsigned char topic[NETWORK_MAX_TOPIC];
    unsigned char payload[NETWORK_MAX_PAYLOAD];
} NetworkCarrierEvent;

static StaticQueue_t network_event_queue_control;
static uint8_t network_event_queue_storage[
    NETWORK_EVENT_CAPACITY * sizeof(NetworkCarrierEvent)];
static QueueHandle_t network_event_queue;
static NetworkCarrierEvent network_event_staging;

unsigned int axoloty_network_cleanup(void);

static EventGroupHandle_t network_events;
static esp_mqtt_client_handle_t mqtt_client;
static AxolotyEmbeddedSharedFlags network_flags;
static char network_topic[NETWORK_MAX_TOPIC];
static char network_payload[NETWORK_MAX_PAYLOAD];
static char network_publish_topic[NETWORK_MAX_TOPIC];
static char network_publish_payload[NETWORK_MAX_PAYLOAD];
static char network_will_topic[NETWORK_MAX_TOPIC];
static char network_will_payload[NETWORK_MAX_PAYLOAD];
static char network_subscriptions[NETWORK_SUBSCRIPTION_CAPACITY][NETWORK_MAX_TOPIC];
static char network_subscriptions_staging[NETWORK_SUBSCRIPTION_CAPACITY][NETWORK_MAX_TOPIC];
static portMUX_TYPE network_subscription_mux = portMUX_INITIALIZER_UNLOCKED;
static char network_uri[128];
static char network_client_id[64];
static size_t network_payload_length;
static int network_will_payload_length;
static int network_will_configured;
static unsigned int network_subscription_count;
static unsigned int network_subscription_ack_count;
static unsigned int network_reconnect_baseline;
static esp_netif_t *network_netif;
static int network_event_loop_ready;
static int network_wifi_initialized;
static int network_wifi_started;
static int network_wifi_handler_registered;
static int network_ip_handler_registered;
static uint32_t network_overall_start;
static unsigned int network_overall_deadline_ms;

static unsigned network_mqtt_bits_load(void) {
    return axoloty_atomic_uint_load(&network_flags.mqtt_bits);
}

static void network_mqtt_bits_store(unsigned bits) {
    axoloty_atomic_uint_store(&network_flags.mqtt_bits, bits);
}

static void network_mqtt_bits_set(unsigned bits) {
    axoloty_atomic_uint_fetch_or(&network_flags.mqtt_bits, bits);
}

static void network_mqtt_bits_clear(unsigned bits) {
    axoloty_atomic_uint_fetch_and(&network_flags.mqtt_bits, ~bits);
}

static unsigned network_connect_count_load(void) {
    return axoloty_atomic_uint_load(&network_flags.network_connect_count);
}

static unsigned wifi_retry_count_load(void) {
    return axoloty_atomic_uint_load(&network_flags.wifi_retry_count);
}

static int network_forced_wifi_disconnect_load(void) {
    return axoloty_atomic_int_load(&network_flags.forced_wifi_disconnect);
}

static int network_read_station_mac(uint8_t mac[6], void *context) {
    (void)context;
    return esp_read_mac(mac, ESP_MAC_WIFI_STA) == ESP_OK;
}

static int network_prepare_client_id(void) {
    return axoloty_runtime_identity_prepare(
        axoloty_runtime_identity, network_read_station_mac, NULL,
        network_client_id, sizeof(network_client_id));
}
static void network_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == IP_EVENT_STA_GOT_IP) {
        axoloty_atomic_uint_store(&network_flags.wifi_retry_count, 0);
        xEventGroupSetBits(network_events, IP_BIT);
    }
}

static void network_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_START) esp_wifi_connect();
    else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        if (network_forced_wifi_disconnect_load()) {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        } else if (wifi_retry_count_load() < 5U) {
            axoloty_atomic_uint_fetch_add(&network_flags.wifi_retry_count, 1U);
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        }
    }
}

static void network_mqtt_event(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;
    if (event_id == MQTT_EVENT_CONNECTED) {
        unsigned connect_count = axoloty_atomic_uint_fetch_add(
            &network_flags.network_connect_count, 1U) + 1U;
        network_mqtt_bits_set(4U);
        if (connect_count > 1U) {
            __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
            network_mqtt_bits_clear(8U);
            taskENTER_CRITICAL(&network_subscription_mux);
            unsigned subscription_count = __atomic_load_n(
                &network_subscription_count, __ATOMIC_ACQUIRE);
            memcpy(network_subscriptions_staging, network_subscriptions,
                   sizeof(network_subscriptions_staging));
            taskEXIT_CRITICAL(&network_subscription_mux);
            for (unsigned index = 0; index < subscription_count; ++index) {
                esp_mqtt_client_subscribe(mqtt_client, network_subscriptions_staging[index], 0);
            }
        }
    } else if (event_id == MQTT_EVENT_DISCONNECTED) {
        network_mqtt_bits_clear(4U | 8U);
    } else if (event_id == MQTT_EVENT_SUBSCRIBED) {
        unsigned acknowledged = __atomic_fetch_add(
            &network_subscription_ack_count, 1U, __ATOMIC_ACQ_REL) + 1U;
        unsigned subscription_count = __atomic_load_n(
            &network_subscription_count, __ATOMIC_ACQUIRE);
        if (subscription_count > 0U && acknowledged >= subscription_count) {
            network_mqtt_bits_set(8U);
        }
    } else if (event_id == MQTT_EVENT_DATA) {
        // ESP-MQTT may split a PUBLISH across callbacks. This fixed profile has
        // no reassembly buffer, so reject fragments and copy only complete,
        // bounded frames into the queue for Swift to process.
        int valid = axoloty_mqtt_event_data_is_valid(
            event ? event->topic : NULL, event ? event->topic_len : -1,
            event ? event->data : NULL, event ? event->data_len : -1,
            event ? event->total_data_len : -1,
            event ? event->current_data_offset : -1);
        if (!valid) return;

        if (event->topic_len == (int)strlen(network_topic) &&
            event->data_len == (int)network_payload_length &&
            memcmp(event->topic, network_topic, event->topic_len) == 0 &&
            memcmp(event->data, network_payload, event->data_len) == 0) {
            network_mqtt_bits_set(32U);
        }

        network_event_staging.topic_length = event->topic_len;
        network_event_staging.payload_length = event->data_len;
        memcpy(network_event_staging.topic, event->topic,
               (size_t)network_event_staging.topic_length);
        memcpy(network_event_staging.payload, event->data,
               (size_t)network_event_staging.payload_length);
        if (!network_event_queue ||
            xQueueSend(network_event_queue, &network_event_staging, 0) != pdTRUE) {
            network_mqtt_bits_set(NETWORK_EVENT_OVERFLOW_BIT);
        }
    }
}

static int network_deadline(uint32_t start, uint32_t timeout) {
    return (uint32_t)(esp_timer_get_time() / 1000ULL) - start < timeout;
}

static TickType_t network_wait_ticks(uint32_t start, uint32_t timeout, uint32_t maximum_wait_ms) {
    uint32_t elapsed = (uint32_t)(esp_timer_get_time() / 1000ULL) - start;
    if (elapsed >= timeout) return 0;
    uint32_t remaining = timeout - elapsed;
    return pdMS_TO_TICKS(remaining < maximum_wait_ms ? remaining : maximum_wait_ms);
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
    __atomic_store_n(&network_subscription_count, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
    network_will_configured = 0;
    if (!network_event_queue) {
        network_event_queue = xQueueCreateStatic(
            NETWORK_EVENT_CAPACITY, sizeof(NetworkCarrierEvent),
            network_event_queue_storage, &network_event_queue_control);
    } else {
        xQueueReset(network_event_queue);
    }
    if (!network_event_queue) return 0;
    axoloty_atomic_uint_store(&network_flags.wifi_retry_count, 0);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
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
    uint32_t stamp = (uint32_t)(esp_timer_get_time() / 1000ULL);
    int topic_length = snprintf(network_topic, sizeof(network_topic), "axoloty/network/%u", (unsigned)stamp);
    int payload_length = snprintf(network_payload, sizeof(network_payload), "axoloty-network-%u", (unsigned)stamp);
    int uri_length = snprintf(network_uri, sizeof(network_uri), "mqtt://%s:%u", axoloty_mqtt_host,
                               (unsigned)axoloty_mqtt_port);
    if (topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC || payload_length <= 0 ||
        payload_length >= NETWORK_MAX_PAYLOAD || uri_length <= 0 || uri_length >= (int)sizeof(network_uri)) {
        goto network_prepare_failed;
    }
    network_payload_length = (size_t)payload_length;
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
    network_mqtt_bits_clear(4U | 8U);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 1);
    if (esp_wifi_disconnect() != ESP_OK) {
        axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
        return 0;
    }
    EventBits_t disconnected = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT, pdTRUE, pdFALSE,
        network_wait_ticks(start, deadline_ms, 5000));
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
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

int axoloty_network_copy_topic(unsigned char *buffer, int capacity) {
    int length = (int)strlen(network_topic);
    if (!buffer || capacity <= length) return 0;
    memcpy(buffer, network_topic, (size_t)length);
    return length;
}

int axoloty_network_copy_payload(unsigned char *buffer, int capacity) {
    int length = (int)network_payload_length;
    if (!buffer || capacity < length) return 0;
    memcpy(buffer, network_payload, (size_t)length);
    return length;
}

int axoloty_mqtt_configure_last_will(const unsigned char *topic, int topic_length,
                                     const unsigned char *payload, int payload_length) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)payload; (void)payload_length;
    return 0;
#else
    if (!topic || !payload || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC ||
        payload_length < 0 || payload_length >= NETWORK_MAX_PAYLOAD || mqtt_client) return 0;
    memcpy(network_will_topic, topic, (size_t)topic_length);
    network_will_topic[topic_length] = 0;
    memcpy(network_will_payload, payload, (size_t)payload_length);
    network_will_payload[payload_length] = 0;
    network_will_payload_length = payload_length;
    network_will_configured = 1;
    return 1;
#endif
}

int axoloty_mqtt_connect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    network_mqtt_bits_store(0);
    axoloty_atomic_uint_store(&network_flags.network_connect_count, 0);
    network_subscription_ack_count = 0;
    xQueueReset(network_event_queue);
    if (!network_prepare_client_id()) return 0;
    esp_mqtt_client_config_t config = { 0 };
    config.broker.address.uri = network_uri;
    config.credentials.client_id = network_client_id;
    if (network_will_configured) {
        config.session.last_will.topic = network_will_topic;
        config.session.last_will.msg = network_will_payload;
        config.session.last_will.msg_len = network_will_payload_length;
        config.session.last_will.qos = 0;
        config.session.last_will.retain = 0;
    }
    mqtt_client = esp_mqtt_client_init(&config);
    if (!mqtt_client) return 0;
    if (esp_mqtt_client_register_event(mqtt_client, ESP_EVENT_ANY_ID, network_mqtt_event, NULL) != ESP_OK ||
        esp_mqtt_client_start(mqtt_client) != ESP_OK) {
        esp_mqtt_client_destroy(mqtt_client);
        mqtt_client = NULL;
        return 0;
    }
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           !(network_mqtt_bits_load() & 4U)) vTaskDelay(pdMS_TO_TICKS(20));
    if (network_mqtt_bits_load() & 4U) {
        network_reconnect_baseline = network_connect_count_load();
        return 1;
    }
    esp_mqtt_client_stop(mqtt_client);
    esp_mqtt_client_destroy(mqtt_client);
    mqtt_client = NULL;
    return 0;
#endif
}

int axoloty_mqtt_subscribe_wait(const unsigned char *topic, int topic_length,
                                unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)deadline_ms;
    return 0;
#else
    if (!mqtt_client || !topic || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC) return 0;
    taskENTER_CRITICAL(&network_subscription_mux);
    unsigned int subscription_count = __atomic_load_n(
        &network_subscription_count, __ATOMIC_ACQUIRE);
    unsigned int index = 0;
    while (index < subscription_count &&
           ((int)strlen(network_subscriptions[index]) != topic_length ||
            memcmp(network_subscriptions[index], topic, (size_t)topic_length) != 0)) ++index;
    if (index == subscription_count) {
        if (subscription_count >= NETWORK_SUBSCRIPTION_CAPACITY) {
            taskEXIT_CRITICAL(&network_subscription_mux);
            return 0;
        }
        memcpy(network_subscriptions[index], topic, (size_t)topic_length);
        network_subscriptions[index][topic_length] = 0;
        __atomic_store_n(&network_subscription_count, subscription_count + 1U, __ATOMIC_RELEASE);
    }
    char *subscription = network_subscriptions[index];
    taskEXIT_CRITICAL(&network_subscription_mux);
    unsigned int prior_acknowledgements = __atomic_load_n(
        &network_subscription_ack_count, __ATOMIC_ACQUIRE);
    network_mqtt_bits_clear(8U);
    if (esp_mqtt_client_subscribe(mqtt_client, subscription, 0) < 0) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           __atomic_load_n(&network_subscription_ack_count, __ATOMIC_ACQUIRE) <= prior_acknowledgements) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return __atomic_load_n(&network_subscription_ack_count, __ATOMIC_ACQUIRE) > prior_acknowledgements;
#endif
}

int axoloty_mqtt_unsubscribe(const unsigned char *topic, int topic_length) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length;
    return 0;
#else
    if (!mqtt_client || !topic || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC) return 0;
    char topic_copy[NETWORK_MAX_TOPIC];
    taskENTER_CRITICAL(&network_subscription_mux);
    unsigned int subscription_count = __atomic_load_n(
        &network_subscription_count, __ATOMIC_ACQUIRE);
    unsigned int index = 0;
    while (index < subscription_count &&
           ((int)strlen(network_subscriptions[index]) != topic_length ||
            memcmp(network_subscriptions[index], topic, (size_t)topic_length) != 0)) ++index;
    if (index == subscription_count) {
        taskEXIT_CRITICAL(&network_subscription_mux);
        return 0;
    }
    memcpy(topic_copy, network_subscriptions[index], NETWORK_MAX_TOPIC);
    taskEXIT_CRITICAL(&network_subscription_mux);
    if (esp_mqtt_client_unsubscribe(mqtt_client, topic_copy) < 0) return 0;
    taskENTER_CRITICAL(&network_subscription_mux);
    subscription_count = __atomic_load_n(&network_subscription_count, __ATOMIC_ACQUIRE);
    for (index = 0; index < subscription_count; ++index) {
        if (strcmp(network_subscriptions[index], topic_copy) != 0) continue;
        for (unsigned int move = index + 1; move < subscription_count; ++move) {
            memcpy(network_subscriptions[move - 1], network_subscriptions[move], NETWORK_MAX_TOPIC);
        }
        memset(network_subscriptions[subscription_count - 1], 0, NETWORK_MAX_TOPIC);
        __atomic_store_n(&network_subscription_count, subscription_count - 1U, __ATOMIC_RELEASE);
        break;
    }
    taskEXIT_CRITICAL(&network_subscription_mux);
    return 1;
#endif
}

int axoloty_mqtt_publish(const unsigned char *topic, int topic_length,
                        const unsigned char *payload, int payload_length) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)payload; (void)payload_length;
    return 0;
#else
    if (!mqtt_client || !topic || !payload || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC ||
        payload_length < 0 || payload_length >= NETWORK_MAX_PAYLOAD) return 0;
    memcpy(network_publish_topic, topic, (size_t)topic_length);
    network_publish_topic[topic_length] = 0;
    memcpy(network_publish_payload, payload, (size_t)payload_length);
    network_publish_payload[payload_length] = 0;
    return esp_mqtt_client_publish(
        mqtt_client, network_publish_topic, network_publish_payload, payload_length, 0, 0) >= 0;
#endif
}

int axoloty_mqtt_wait_loopback(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           !(network_mqtt_bits_load() & 32U)) vTaskDelay(pdMS_TO_TICKS(20));
    return (network_mqtt_bits_load() & 32U) != 0;
#endif
}

int axoloty_mqtt_reconnect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    if (!mqtt_client || !network_events ||
        __atomic_load_n(&network_subscription_count, __ATOMIC_ACQUIRE) == 0U) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    unsigned int expected_connect_count = network_reconnect_baseline + 1U;
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           (network_connect_count_load() < expected_connect_count ||
            !(network_mqtt_bits_load() & 4U) || !(network_mqtt_bits_load() & 8U))) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    int reconnected = (network_mqtt_bits_load() & (4U | 8U)) == (4U | 8U) &&
        network_connect_count_load() >= expected_connect_count;
    if (reconnected) network_reconnect_baseline = expected_connect_count;
    return reconnected;
#endif
}

int axoloty_mqtt_poll_one_event(unsigned char *topic, int topic_capacity,
                                int *topic_length, unsigned char *payload,
                                int payload_capacity, int *payload_length) {
    if (!topic || !topic_length || !payload || !payload_length || topic_capacity <= 0 ||
        payload_capacity < 0 || topic_capacity > NETWORK_MAX_TOPIC ||
        payload_capacity > NETWORK_MAX_PAYLOAD) return -1;
    if (network_mqtt_bits_load() & NETWORK_EVENT_OVERFLOW_BIT) {
        network_mqtt_bits_clear(NETWORK_EVENT_OVERFLOW_BIT);
        return -1;
    }
    if (!(network_mqtt_bits_load() & 4U)) return -2;
    if (!network_event_queue) return -1;
    NetworkCarrierEvent frame;
    if (xQueueReceive(network_event_queue, &frame, 0) != pdTRUE) return 0;
    if (frame.topic_length <= 0 || frame.topic_length > topic_capacity ||
        frame.payload_length < 0 || frame.payload_length > payload_capacity) return -1;
    memcpy(topic, frame.topic, (size_t)frame.topic_length);
    memcpy(payload, frame.payload, (size_t)frame.payload_length);
    *topic_length = frame.topic_length;
    *payload_length = frame.payload_length;
    return 1;
}

int axoloty_mqtt_disconnect(void) {
    if (!mqtt_client) return 1;
    esp_err_t stop = esp_mqtt_client_stop(mqtt_client);
    esp_err_t destroy = esp_mqtt_client_destroy(mqtt_client);
    mqtt_client = NULL;
    return stop == ESP_OK && destroy == ESP_OK;
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
    __atomic_store_n(&network_subscription_count, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
    network_reconnect_baseline = 0;
    network_will_configured = 0;
    if (network_event_queue) xQueueReset(network_event_queue);
    axoloty_atomic_uint_store(&network_flags.network_connect_count, 0);
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
