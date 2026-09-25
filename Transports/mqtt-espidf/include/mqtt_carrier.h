// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_MQTT_CARRIER_H
#define AXOLOTY_MQTT_CARRIER_H

#include "../../../Interop/swift_c_interop.h"

int axoloty_mqtt_configure_last_will(
    const unsigned char * AXOLOTY_NONNULL __counted_by(topic_length) AXOLOTY_C_NOESCAPE topic,
    int topic_length,
    const unsigned char * AXOLOTY_NONNULL __counted_by(payload_length) AXOLOTY_C_NOESCAPE payload,
    int payload_length);
int axoloty_mqtt_connect_wait(unsigned int deadline_ms);
int axoloty_mqtt_subscribe_wait(
    const unsigned char * AXOLOTY_NONNULL __counted_by(topic_length) AXOLOTY_C_NOESCAPE topic,
    int topic_length, unsigned int deadline_ms);
int axoloty_mqtt_unsubscribe(
    const unsigned char * AXOLOTY_NONNULL __counted_by(topic_length) AXOLOTY_C_NOESCAPE topic,
    int topic_length);
int axoloty_mqtt_publish(
    const unsigned char * AXOLOTY_NONNULL __counted_by(topic_length) AXOLOTY_C_NOESCAPE topic,
    int topic_length,
    const unsigned char * AXOLOTY_NONNULL __counted_by(payload_length) AXOLOTY_C_NOESCAPE payload,
    int payload_length);
int axoloty_mqtt_wait_loopback(unsigned int deadline_ms);
int axoloty_mqtt_reconnect_wait(unsigned int deadline_ms);
int axoloty_mqtt_poll_one_event(
    unsigned char * AXOLOTY_NONNULL __counted_by(topic_capacity) AXOLOTY_C_NOESCAPE topic,
    int topic_capacity, int * AXOLOTY_NONNULL topic_length,
    unsigned char * AXOLOTY_NONNULL __counted_by(payload_capacity) AXOLOTY_C_NOESCAPE payload,
    int payload_capacity, int * AXOLOTY_NONNULL payload_length);
int axoloty_mqtt_disconnect(void);

#endif
