// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_MQTT_EVENT_VALIDATION_H
#define AXOLOTY_MQTT_EVENT_VALIDATION_H

#include <stddef.h>

// The composition writes the selected application's topic and payload bounds.
#include "axoloty_carrier_bounds.h"

#if !defined(AXOLOTY_CARRIER_MAX_TOPIC_BYTES) || !defined(AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES) || \
    AXOLOTY_CARRIER_MAX_TOPIC_BYTES < 1 || AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES < 1
#error "axoloty_carrier_bounds.h must define positive AXOLOTY_CARRIER_MAX_TOPIC_BYTES and AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES"
#endif

/// Bytes reserved for one MQTT topic: the composed topic bound plus a NUL
/// terminator. The carrier sizes its buffers from this, so the validator can
/// never admit a topic the buffers cannot hold.
#define AXOLOTY_MQTT_TOPIC_CAPACITY (AXOLOTY_CARRIER_MAX_TOPIC_BYTES + 1)

/// Bytes reserved for one MQTT payload: the composed payload bound plus a NUL
/// terminator.
#define AXOLOTY_MQTT_PAYLOAD_CAPACITY (AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES + 1)

/// Bytes ESP-MQTT needs to deliver the largest admitted frame in one event: the
/// fixed header (1 byte and up to 4 of remaining length), the topic length (2),
/// the topic, and the payload, at QoS 0, with margin for a packet identifier.
/// A frame that needs more arrives in several events, and the carrier drops it.
#define AXOLOTY_MQTT_PACKET_BUFFER_BYTES \
    (AXOLOTY_CARRIER_MAX_TOPIC_BYTES + AXOLOTY_CARRIER_MAX_PAYLOAD_BYTES + 8)

/// What the carrier does with one inbound ESP-MQTT data event.
typedef enum {
    /// One complete frame within the bounds: queue it.
    AXOLOTY_MQTT_EVENT_ACCEPT = 0,
    /// The first event of a message beyond the topic or payload bound, or split
    /// across events: drop it and count it once.
    AXOLOTY_MQTT_EVENT_OVERSIZED = 1,
    /// A later event of a message already dropped, or an event that carries no
    /// usable topic: drop it. It is not counted again.
    AXOLOTY_MQTT_EVENT_DISCARD = 2,
} AxolotyMqttEventVerdict;

/// Classifies one MQTT data event.
AxolotyMqttEventVerdict axoloty_mqtt_event_classify(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset);

/// Returns true only for a bounded, complete MQTT data event.
int axoloty_mqtt_event_data_is_valid(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset);

#endif
