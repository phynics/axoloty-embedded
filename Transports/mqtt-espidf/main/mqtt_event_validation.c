// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "mqtt_event_validation.h"

AxolotyMqttEventVerdict axoloty_mqtt_event_classify(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset) {
    // ESP-MQTT reports the topic only in the first event of a message. A later
    // event belongs to a message the first event already decided on.
    if (current_data_offset != 0) return AXOLOTY_MQTT_EVENT_DISCARD;
    if (!topic || topic_length <= 0 || data_length < 0 || total_data_length < 0 ||
        data_length > total_data_length) {
        return AXOLOTY_MQTT_EVENT_DISCARD;
    }
    // The static endpoint has no reassembly buffer. A message beyond the topic
    // or payload bound, or one ESP-MQTT split across events, is dropped whole
    // instead of retaining partial untrusted data.
    if (topic_length >= AXOLOTY_MQTT_TOPIC_CAPACITY || total_data_length >= AXOLOTY_MQTT_PAYLOAD_CAPACITY ||
        data_length != total_data_length) {
        return AXOLOTY_MQTT_EVENT_OVERSIZED;
    }
    // A frame with no payload pointer carries nothing the protocol could read.
    if (!data) return AXOLOTY_MQTT_EVENT_DISCARD;
    return AXOLOTY_MQTT_EVENT_ACCEPT;
}

int axoloty_mqtt_event_data_is_valid(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset) {
    return axoloty_mqtt_event_classify(
        topic, topic_length, data, data_length, total_data_length, current_data_offset
    ) == AXOLOTY_MQTT_EVENT_ACCEPT;
}
