// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The MQTT transport's version 1 carrier table.
//
// The table points at the transport's own synchronous C entry points. Probe
// topic and payload are the scenario-selected bytes the network bootstrap
// prepared, so the neutral ABI never names an MQTT concept.

#include <stdint.h>

#include "axoloty_carrier_v1.h"

extern int32_t axoloty_mqtt_v1_supports_last_will(void *context, uint32_t *supported);
extern int32_t axoloty_mqtt_v1_configure_last_will(
    void *context, const uint8_t *topic, uint32_t topic_length,
    const uint8_t *payload, uint32_t payload_length);
extern int32_t axoloty_mqtt_v1_connect(void *context, uint32_t deadline_ms);
extern int32_t axoloty_mqtt_v1_subscribe(
    void *context, const uint8_t *topic, uint32_t topic_length, uint32_t deadline_ms);
extern int32_t axoloty_mqtt_v1_unsubscribe(
    void *context, const uint8_t *topic, uint32_t topic_length, uint32_t deadline_ms);
extern int32_t axoloty_mqtt_v1_publish(
    void *context, const uint8_t *topic, uint32_t topic_length,
    const uint8_t *payload, uint32_t payload_length);
extern int32_t axoloty_mqtt_v1_poll_one_event(
    void *context, uint8_t *topic, uint32_t topic_capacity, uint32_t *out_topic_length,
    uint8_t *payload, uint32_t payload_capacity, uint32_t *out_payload_length);
extern int32_t axoloty_mqtt_v1_wait_for_reconnect(void *context, uint32_t deadline_ms);
extern int32_t axoloty_mqtt_v1_wait_for_loopback(void *context, uint32_t deadline_ms);
extern int32_t axoloty_mqtt_v1_disconnect(void *context);

extern int axoloty_network_copy_topic(unsigned char *buffer, int capacity);
extern int axoloty_network_copy_payload(unsigned char *buffer, int capacity);

static int32_t copy_probe_topic(
    void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length
) {
    (void)context;
    if (buffer == NULL || out_length == NULL || capacity == 0) {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    }
    if (capacity > (uint32_t)INT32_MAX) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    const int length = axoloty_network_copy_topic(buffer, (int)capacity);
    if (length <= 0) return AXOLOTY_ABI_STATUS_FAILED;
    if ((uint32_t)length > capacity) return AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL;
    *out_length = (uint32_t)length;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t copy_probe_payload(
    void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length
) {
    (void)context;
    if (buffer == NULL || out_length == NULL) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    if (capacity > (uint32_t)INT32_MAX) return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    const int length = axoloty_network_copy_payload(buffer, (int)capacity);
    if (length < 0) return AXOLOTY_ABI_STATUS_FAILED;
    if ((uint32_t)length > capacity) return AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL;
    *out_length = (uint32_t)length;
    return AXOLOTY_ABI_STATUS_OK;
}

static const axoloty_carrier_v1 carrier_table = {
    .abi_version = AXOLOTY_CARRIER_ABI_V1,
    .struct_size = (uint32_t)sizeof(axoloty_carrier_v1),
    .capabilities = AXOLOTY_CARRIER_CAP_LAST_WILL | AXOLOTY_CARRIER_CAP_CONNECT |
        AXOLOTY_CARRIER_CAP_SUBSCRIBE | AXOLOTY_CARRIER_CAP_UNSUBSCRIBE |
        AXOLOTY_CARRIER_CAP_PUBLISH | AXOLOTY_CARRIER_CAP_POLL |
        AXOLOTY_CARRIER_CAP_RECONNECT | AXOLOTY_CARRIER_CAP_DISCONNECT |
        AXOLOTY_CARRIER_CAP_NETWORK_PROBE,
    .context = NULL,
    .supports_last_will = axoloty_mqtt_v1_supports_last_will,
    .configure_last_will = axoloty_mqtt_v1_configure_last_will,
    .connect = axoloty_mqtt_v1_connect,
    .subscribe = axoloty_mqtt_v1_subscribe,
    .unsubscribe = axoloty_mqtt_v1_unsubscribe,
    .publish = axoloty_mqtt_v1_publish,
    .poll_one_event = axoloty_mqtt_v1_poll_one_event,
    .wait_for_reconnect = axoloty_mqtt_v1_wait_for_reconnect,
    .wait_for_loopback = axoloty_mqtt_v1_wait_for_loopback,
    .disconnect = axoloty_mqtt_v1_disconnect,
    .copy_probe_topic = copy_probe_topic,
    .copy_probe_payload = copy_probe_payload,
};

const axoloty_carrier_v1 *axoloty_carrier_get_v1(void) {
    return &carrier_table;
}
