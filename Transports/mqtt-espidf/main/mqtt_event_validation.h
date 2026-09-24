// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_MQTT_EVENT_VALIDATION_H
#define AXOLOTY_MQTT_EVENT_VALIDATION_H

#include <stddef.h>

/// Bytes reserved for one MQTT topic: AxolotyWire's 256-byte topic bound plus
/// a NUL terminator. The platform sizes its carrier buffers from this, so the
/// validator can never admit a topic the buffers cannot hold.
#define AXOLOTY_MQTT_TOPIC_CAPACITY 257

/// Bytes reserved for one MQTT payload: AxolotyWire's 2048-byte payload bound
/// plus a NUL terminator.
#define AXOLOTY_MQTT_PAYLOAD_CAPACITY 2049

/// Returns true only for a bounded, complete MQTT data event.
int axoloty_mqtt_event_data_is_valid(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset);

#endif
