// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_STATIC_DEVICE_AGENT_H
#define AXOLOTY_STATIC_DEVICE_AGENT_H

#include "../../../Interop/swift_c_interop.h"

int axoloty_static_agent_expire(int role);
int axoloty_static_agent_copy_actor_route(int role,
    unsigned char * AXOLOTY_NONNULL __counted_by(capacity) AXOLOTY_C_NOESCAPE output,
    int capacity);
int axoloty_static_agent_prepare(int role, int kind,
    unsigned char * AXOLOTY_NONNULL __counted_by(topic_capacity) AXOLOTY_C_NOESCAPE topic_buffer,
    int topic_capacity,
    unsigned char * AXOLOTY_NONNULL __counted_by(payload_capacity) AXOLOTY_C_NOESCAPE payload_buffer,
    int payload_capacity, int * AXOLOTY_NONNULL topic_length, int * AXOLOTY_NONNULL payload_length);
int axoloty_static_agent_receive(int role,
    const unsigned char * AXOLOTY_NONNULL __counted_by(topic_length) AXOLOTY_C_NOESCAPE topic_bytes,
    int topic_length,
    const unsigned char * AXOLOTY_NONNULL __counted_by(payload_length) AXOLOTY_C_NOESCAPE payload_bytes,
    int payload_length,
    unsigned char * AXOLOTY_NONNULL __counted_by(output_topic_capacity) AXOLOTY_C_NOESCAPE output_topic,
    int output_topic_capacity,
    unsigned char * AXOLOTY_NONNULL __counted_by(output_payload_capacity) AXOLOTY_C_NOESCAPE output_payload,
    int output_payload_capacity, int * AXOLOTY_NONNULL output_topic_length, int * AXOLOTY_NONNULL output_payload_length);

#endif
