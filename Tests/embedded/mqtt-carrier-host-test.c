// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host check for the MQTT carrier's receive path at the composed bounds.
//
// Compiles the real mqtt_carrier_espidf.c against stand-ins for ESP-MQTT and
// FreeRTOS, drives ESP-MQTT's event callback the way the library does, and polls
// the carrier the way the application does. It proves a frame at the bounds
// arrives intact, a frame one byte over is dropped and counted, a split message
// is dropped once, and in every case the frames behind it still arrive: nothing
// is retained that could block the receive loop.

#include "mqtt_client.h"
#include "mqtt_carrier.h"
#include "mqtt_event_validation.h"
#include "network_bootstrap.h"
#include "freertos/queue.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <stdarg.h>

static unsigned host_log_warnings;

void host_log_warning(const char *tag, const char *format, ...) {
    char line[160];
    va_list arguments;
    (void)tag;
    va_start(arguments, format);
    vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    ++host_log_warnings;
}

// --- ESP-MQTT and FreeRTOS stand-ins --------------------------------------

static void (*registered_handler)(void *, esp_event_base_t, int32_t, void *);
static esp_mqtt_client_config_t captured_config;
static int captured_publish_length;
static int captured_publish_topic_length;
static int64_t host_clock_us;

struct esp_mqtt_client { int unused; };
static struct esp_mqtt_client client_object;

static void dispatch(esp_mqtt_event_id_t id, esp_mqtt_event_t *event) {
    if (registered_handler) registered_handler(NULL, "mqtt", (int32_t)id, event);
}

esp_mqtt_client_handle_t esp_mqtt_client_init(const esp_mqtt_client_config_t *config) {
    captured_config = *config;
    return &client_object;
}
esp_err_t esp_mqtt_client_register_event(esp_mqtt_client_handle_t client, int event,
                                         void (*handler)(void *, esp_event_base_t, int32_t, void *),
                                         void *context) {
    (void)client; (void)event; (void)context;
    registered_handler = handler;
    return ESP_OK;
}
esp_err_t esp_mqtt_client_start(esp_mqtt_client_handle_t client) {
    (void)client;
    esp_mqtt_event_t event = { 0 };
    dispatch(MQTT_EVENT_CONNECTED, &event);
    return ESP_OK;
}
esp_err_t esp_mqtt_client_stop(esp_mqtt_client_handle_t client) { (void)client; return ESP_OK; }
esp_err_t esp_mqtt_client_destroy(esp_mqtt_client_handle_t client) { (void)client; return ESP_OK; }
int esp_mqtt_client_subscribe(esp_mqtt_client_handle_t client, const char *topic, int qos) {
    (void)client; (void)topic; (void)qos;
    esp_mqtt_event_t event = { 0 };
    dispatch(MQTT_EVENT_SUBSCRIBED, &event);
    return 1;
}
int esp_mqtt_client_unsubscribe(esp_mqtt_client_handle_t client, const char *topic) {
    (void)client; (void)topic;
    return 1;
}
int esp_mqtt_client_publish(esp_mqtt_client_handle_t client, const char *topic, const char *data,
                            int len, int qos, int retain) {
    (void)client; (void)data; (void)qos; (void)retain;
    captured_publish_topic_length = (int)strlen(topic);
    captured_publish_length = len;
    return 1;
}
esp_err_t esp_read_mac(uint8_t *mac, int type) {
    (void)type;
    static const uint8_t address[6] = { 0x00, 0x01, 0xab, 0xcd, 0xef, 0xff };
    memcpy(mac, address, sizeof(address));
    return ESP_OK;
}
int64_t esp_timer_get_time(void) { return host_clock_us += 1000; }
void vTaskDelay(TickType_t ticks) { (void)ticks; }
unsigned int axoloty_network_deadline_remaining_ms(void) { return 1000U; }
int axoloty_network_is_active(void) { return 1; }

QueueHandle_t xQueueCreateStatic(unsigned length, unsigned item_size, uint8_t *storage, StaticQueue_t *queue) {
    queue->storage = storage;
    queue->length = length;
    queue->item_size = item_size;
    queue->head = 0;
    queue->count = 0;
    return queue;
}
BaseType_t xQueueSend(QueueHandle_t queue, const void *item, TickType_t ticks) {
    (void)ticks;
    if (queue->count >= queue->length) return pdFALSE;
    memcpy(queue->storage + ((queue->head + queue->count) % queue->length) * queue->item_size, item, queue->item_size);
    ++queue->count;
    return pdTRUE;
}
BaseType_t xQueueReceive(QueueHandle_t queue, void *item, TickType_t ticks) {
    (void)ticks;
    if (queue->count == 0) return pdFALSE;
    memcpy(item, queue->storage + queue->head * queue->item_size, queue->item_size);
    queue->head = (queue->head + 1) % queue->length;
    --queue->count;
    return pdTRUE;
}
BaseType_t xQueueReset(QueueHandle_t queue) {
    queue->head = 0;
    queue->count = 0;
    return pdTRUE;
}

// --- the check --------------------------------------------------------------

static int failures;
#define CHECK(condition, message) \
    do { if (!(condition)) { fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); ++failures; } } while (0)

#define TOPIC_BOUND AXOLOTY_CARRIER_MAX_TOPIC_BYTES
#define PAYLOAD_BOUND AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES

static unsigned char topic_buffer[TOPIC_BOUND + 8];
static unsigned char payload_buffer[PAYLOAD_BOUND + 8];

/// A byte pattern with no zero byte, so a C string over it keeps its length.
static unsigned char pattern(unsigned char seed, int index) {
    return (unsigned char)(1 + (seed + index * 7) % 250);
}

static void fill(unsigned char *bytes, int length, unsigned char seed) {
    for (int index = 0; index < length; ++index) bytes[index] = pattern(seed, index);
}

/// Delivers one complete message the way ESP-MQTT does when the packet fits.
static void deliver(int topic_length, int payload_length, unsigned char seed) {
    static char topic[TOPIC_BOUND + 8];
    static char payload[PAYLOAD_BOUND + 8];
    fill((unsigned char *)topic, topic_length, seed);
    fill((unsigned char *)payload, payload_length, (unsigned char)(seed + 1));
    esp_mqtt_event_t event = { .data = payload, .data_len = payload_length, .total_data_len = payload_length,
                               .current_data_offset = 0, .topic = topic, .topic_len = topic_length };
    dispatch(MQTT_EVENT_DATA, &event);
}

/// Polls with the application's buffers: exactly the composed bounds.
static int poll_frame(int *topic_length, int *payload_length) {
    return axoloty_mqtt_poll_one_event(topic_buffer, TOPIC_BOUND, topic_length,
                                       payload_buffer, PAYLOAD_BOUND, payload_length);
}

static int frame_is(int topic_length, int payload_length, unsigned char seed) {
    int got_topic = 0, got_payload = 0;
    if (poll_frame(&got_topic, &got_payload) != 1) return 0;
    if (got_topic != topic_length || got_payload != payload_length) return 0;
    for (int index = 0; index < topic_length; ++index) {
        if (topic_buffer[index] != pattern(seed, index)) return 0;
    }
    for (int index = 0; index < payload_length; ++index) {
        if (payload_buffer[index] != pattern((unsigned char)(seed + 1), index)) return 0;
    }
    return 1;
}

/// The bytes of one QoS 0 PUBLISH on the wire: fixed header, remaining length,
/// topic length, topic, payload.
static int publish_packet_bytes(int topic_length, int payload_length) {
    int remaining = 2 + topic_length + payload_length;
    int remaining_length_bytes = remaining < 128 ? 1 : remaining < 16384 ? 2 : remaining < 2097152 ? 3 : 4;
    return 1 + remaining_length_bytes + remaining;
}

int main(void) {
    static const unsigned char will_topic[] = "coaty/3/will";
    static const unsigned char will_payload[] = "{}";

    CHECK(axoloty_transport_network_prepare() == 1, "prepare");
    CHECK(axoloty_mqtt_configure_last_will(will_topic, (int)sizeof(will_topic) - 1,
                                           will_payload, (int)sizeof(will_payload) - 1) == 1, "will");
    CHECK(axoloty_mqtt_connect_wait(1000) == 1, "connect");
    CHECK(captured_config.buffer.size == AXOLOTY_MQTT_PACKET_BUFFER_BYTES &&
          captured_config.buffer.out_size == AXOLOTY_MQTT_PACKET_BUFFER_BYTES,
          "ESP-MQTT buffers follow the composed bounds");
    // The packet buffer holds the largest legal PUBLISH whole, with margin for a
    // packet identifier and a longer remaining length, so ESP-MQTT delivers it
    // in one event.
    CHECK(publish_packet_bytes(TOPIC_BOUND, PAYLOAD_BOUND) + 2 <= AXOLOTY_MQTT_PACKET_BUFFER_BYTES,
          "the packet buffer holds the largest legal frame");

    unsigned char key[TOPIC_BOUND];
    fill(key, TOPIC_BOUND, 3);
    CHECK(axoloty_mqtt_subscribe_wait(key, TOPIC_BOUND, 1000) == 1, "subscribe at the topic bound");
    CHECK(axoloty_mqtt_subscribe_wait(key, 0, 1000) == 0, "subscribe with no topic");

    // A frame exactly at both bounds arrives intact.
    deliver(TOPIC_BOUND, PAYLOAD_BOUND, 10);
    CHECK(frame_is(TOPIC_BOUND, PAYLOAD_BOUND, 10), "frame at the bounds");
    int topic_length = 0, payload_length = 0;
    CHECK(poll_frame(&topic_length, &payload_length) == 0, "queue empty after the frame");
    CHECK(axoloty_mqtt_oversized_frame_count() == 0 && host_log_warnings == 0, "nothing counted yet");

    // One byte over the topic bound, and one byte over the payload bound, are
    // dropped and counted, and the frame behind each still arrives.
    deliver(TOPIC_BOUND + 1, 8, 20);
    CHECK(poll_frame(&topic_length, &payload_length) == 0, "topic one byte over is not queued");
    CHECK(axoloty_mqtt_oversized_frame_count() == 1, "topic one byte over is counted");
    deliver(8, PAYLOAD_BOUND + 1, 30);
    CHECK(poll_frame(&topic_length, &payload_length) == 0, "payload one byte over is not queued");
    CHECK(axoloty_mqtt_oversized_frame_count() == 2, "payload one byte over is counted");
    deliver(TOPIC_BOUND, PAYLOAD_BOUND, 40);
    CHECK(frame_is(TOPIC_BOUND, PAYLOAD_BOUND, 40), "a frame at the bounds arrives after the drops");

    // A message ESP-MQTT splits across events is dropped once, at its first
    // event. The continuation events carry no topic and are not counted.
    {
        static char payload[PAYLOAD_BOUND + 8];
        static char topic[TOPIC_BOUND];
        fill((unsigned char *)topic, TOPIC_BOUND, 50);
        fill((unsigned char *)payload, PAYLOAD_BOUND, 51);
        int total = PAYLOAD_BOUND + 300;
        esp_mqtt_event_t first = { .data = payload, .data_len = PAYLOAD_BOUND, .total_data_len = total,
                                   .current_data_offset = 0, .topic = topic, .topic_len = TOPIC_BOUND };
        esp_mqtt_event_t rest = { .data = payload, .data_len = 300, .total_data_len = total,
                                  .current_data_offset = PAYLOAD_BOUND, .topic = NULL, .topic_len = 0 };
        dispatch(MQTT_EVENT_DATA, &first);
        dispatch(MQTT_EVENT_DATA, &rest);
        CHECK(poll_frame(&topic_length, &payload_length) == 0, "a split message is not queued");
        CHECK(axoloty_mqtt_oversized_frame_count() == 3, "a split message is counted once");
        // ESP-MQTT may deliver the topic alone first when the payload does not fit.
        esp_mqtt_event_t topic_only = { .data = NULL, .data_len = 0, .total_data_len = total,
                                        .current_data_offset = 0, .topic = topic, .topic_len = TOPIC_BOUND };
        dispatch(MQTT_EVENT_DATA, &topic_only);
        dispatch(MQTT_EVENT_DATA, &rest);
        CHECK(axoloty_mqtt_oversized_frame_count() == 4, "a topic-only first event is counted once");
        deliver(5, 5, 60);
        CHECK(frame_is(5, 5, 60), "the next frame arrives after a split message");
    }

    // A caller whose buffers are smaller than the frame loses that frame, never
    // the loop: the frame is consumed, and the next poll serves the one behind it.
    deliver(TOPIC_BOUND, PAYLOAD_BOUND, 70);
    deliver(4, 4, 80);
    {
        int small_topic = 0, small_payload = 0;
        unsigned char small_topic_buffer[4], small_payload_buffer[4];
        CHECK(axoloty_mqtt_poll_one_event(small_topic_buffer, 4, &small_topic,
                                          small_payload_buffer, 4, &small_payload) == -1,
              "a frame larger than the caller's buffers fails");
    }
    CHECK(frame_is(4, 4, 80), "the frame behind a too-large poll arrives");

    // The carrier refuses to publish beyond the bounds and carries a frame at them.
    {
        static unsigned char over_topic[TOPIC_BOUND + 1];
        static unsigned char over_payload[PAYLOAD_BOUND + 1];
        fill(over_topic, TOPIC_BOUND + 1, 1);
        fill(over_payload, PAYLOAD_BOUND + 1, 2);
        CHECK(axoloty_mqtt_publish(over_topic, TOPIC_BOUND, over_payload, PAYLOAD_BOUND) == 1, "publish at the bounds");
        CHECK(captured_publish_topic_length == TOPIC_BOUND && captured_publish_length == PAYLOAD_BOUND,
              "published lengths at the bounds");
        CHECK(axoloty_mqtt_publish(over_topic, TOPIC_BOUND + 1, over_payload, 1) == 0, "publish topic one byte over");
        CHECK(axoloty_mqtt_publish(over_topic, 1, over_payload, PAYLOAD_BOUND + 1) == 0, "publish payload one byte over");
        CHECK(axoloty_mqtt_subscribe_wait(over_topic, TOPIC_BOUND + 1, 1000) == 0, "subscribe topic one byte over");
    }

    // A full queue raises the overflow notification once, then drains in order.
    for (unsigned index = 0; index < 5; ++index) deliver(3, 3, (unsigned char)(90 + index));
    CHECK(poll_frame(&topic_length, &payload_length) == -1, "overflow is reported");
    CHECK(frame_is(3, 3, 90), "queued frames survive the overflow notification");

    CHECK(host_log_warnings == axoloty_mqtt_oversized_frame_count(), "every drop is logged once");
    CHECK(axoloty_mqtt_disconnect() == 1, "disconnect");

    if (failures != 0) return 1;
    printf("mqtt carrier host test passed at topic %d, payload %d\n", TOPIC_BOUND, PAYLOAD_BOUND);
    return 0;
}
