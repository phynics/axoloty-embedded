// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// ESP-MQTT carrier implementation. Callbacks only inspect or copy bounded
// data while they execute; no callback pointer escapes.

#include "esp_event.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "mqtt_client.h"
#include "runtime_identity.h"
#include "embedded_shared_flags.h"
#include "network_bootstrap.h"
#include "mqtt_event_validation.h"
#include "mqtt_carrier.h"
#include "freertos/FreeRTOS.h"
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

// Carrier buffers hold exactly what the MQTT validator admits.
#define NETWORK_MAX_TOPIC AXOLOTY_MQTT_TOPIC_CAPACITY
#define NETWORK_MAX_PAYLOAD AXOLOTY_MQTT_PAYLOAD_CAPACITY
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

static esp_mqtt_client_handle_t mqtt_client;
static AxolotyAtomicUInt network_mqtt_bits;
static AxolotyAtomicUInt network_connect_count;
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

static unsigned network_mqtt_bits_load(void) {
    return axoloty_atomic_uint_load(&network_mqtt_bits);
}

static void network_mqtt_bits_store(unsigned bits) {
    axoloty_atomic_uint_store(&network_mqtt_bits, bits);
}

static void network_mqtt_bits_set(unsigned bits) {
    axoloty_atomic_uint_fetch_or(&network_mqtt_bits, bits);
}

static void network_mqtt_bits_clear(unsigned bits) {
    axoloty_atomic_uint_fetch_and(&network_mqtt_bits, ~bits);
}

static unsigned network_connect_count_load(void) {
    return axoloty_atomic_uint_load(&network_connect_count);
}

static void network_reset_mqtt_state(void) {
    __atomic_store_n(&network_subscription_count, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
    network_reconnect_baseline = 0;
    network_will_configured = 0;
    axoloty_atomic_uint_store(&network_connect_count, 0);
    if (network_event_queue) xQueueReset(network_event_queue);
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
static void network_mqtt_event(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;
    if (event_id == MQTT_EVENT_CONNECTED) {
        unsigned connect_count = axoloty_atomic_uint_fetch_add(
            &network_connect_count, 1U) + 1U;
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
    uint32_t stamp = (uint32_t)(esp_timer_get_time() / 1000ULL);
    int topic_length = snprintf(network_topic, sizeof(network_topic), "axoloty/network/%u", (unsigned)stamp);
    int payload_length = snprintf(network_payload, sizeof(network_payload), "axoloty-network-%u", (unsigned)stamp);
    int uri_length = snprintf(network_uri, sizeof(network_uri), "mqtt://%s:%u", axoloty_mqtt_host,
                              (unsigned)axoloty_mqtt_port);
    if (topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC || payload_length <= 0 ||
        payload_length >= NETWORK_MAX_PAYLOAD || uri_length <= 0 || uri_length >= (int)sizeof(network_uri)) {
        return 0;
    }
    network_payload_length = (size_t)payload_length;

    network_mqtt_bits_store(0);
    axoloty_atomic_uint_store(&network_connect_count, 0);
    __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
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
           axoloty_network_deadline_remaining_ms() != 0U &&
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
           axoloty_network_deadline_remaining_ms() != 0U &&
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
           axoloty_network_deadline_remaining_ms() != 0U &&
           !(network_mqtt_bits_load() & 32U)) vTaskDelay(pdMS_TO_TICKS(20));
    return (network_mqtt_bits_load() & 32U) != 0;
#endif
}

int axoloty_mqtt_reconnect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    if (!mqtt_client || !axoloty_network_is_active() ||
        __atomic_load_n(&network_subscription_count, __ATOMIC_ACQUIRE) == 0U) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    unsigned int expected_connect_count = network_reconnect_baseline + 1U;
    while (network_deadline(start, deadline_ms) &&
           axoloty_network_deadline_remaining_ms() != 0U &&
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

void axoloty_transport_network_cleanup(void) {
    network_reset_mqtt_state();
}

int axoloty_transport_network_prepare(void) {
    if (!network_event_queue) {
        network_event_queue = xQueueCreateStatic(
            NETWORK_EVENT_CAPACITY, sizeof(NetworkCarrierEvent),
            network_event_queue_storage, &network_event_queue_control);
    } else {
        xQueueReset(network_event_queue);
    }
    if (!network_event_queue) return 0;
    __atomic_store_n(&network_subscription_count, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&network_subscription_ack_count, 0U, __ATOMIC_RELEASE);
    network_will_configured = 0;
    return 1;
}
