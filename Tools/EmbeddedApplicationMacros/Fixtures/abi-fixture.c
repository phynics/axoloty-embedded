// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "abi-fixture.h"

static uint32_t platform_write_count;
static uint32_t carrier_publish_count;
static int fixture_context;

static int32_t write_log(void *context, const uint8_t *bytes, uint32_t length) {
    (void)context;
    (void)bytes;
    (void)length;
    platform_write_count += 1;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t publish(void *context, const uint8_t *topic, uint32_t topic_length,
                       const uint8_t *payload, uint32_t payload_length) {
    (void)context;
    (void)topic;
    (void)topic_length;
    (void)payload;
    (void)payload_length;
    carrier_publish_count += 1;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t poll_one_event(void *context, uint8_t *topic, uint32_t topic_capacity,
                              uint32_t *out_topic_length, uint8_t *payload,
                              uint32_t payload_capacity, uint32_t *out_payload_length) {
    (void)context;
    (void)topic;
    (void)payload;
    *out_topic_length = topic_capacity + 1;
    *out_payload_length = payload_capacity;
    return AXOLOTY_ABI_STATUS_OK;
}

static const axoloty_platform_v1 platform_table = {
    .abi_version = AXOLOTY_PLATFORM_ABI_V1,
    .struct_size = sizeof(axoloty_platform_v1),
    .capabilities = AXOLOTY_PLATFORM_CAP_LOG,
    .context = &fixture_context,
    .write_log = write_log,
};

static const axoloty_carrier_v1 carrier_table = {
    .abi_version = AXOLOTY_CARRIER_ABI_V1,
    .struct_size = sizeof(axoloty_carrier_v1),
    .capabilities = AXOLOTY_CARRIER_CAP_PUBLISH | AXOLOTY_CARRIER_CAP_POLL,
    .context = &fixture_context,
    .publish = publish,
    .poll_one_event = poll_one_event,
};

static const axoloty_carrier_v1 minimal_carrier_table = {
    .abi_version = AXOLOTY_CARRIER_ABI_V1,
    .struct_size = sizeof(axoloty_carrier_v1),
    .capabilities = 0,
    .context = &fixture_context,
};

const axoloty_platform_v1 *unit_b_platform_table(void) { return &platform_table; }
const axoloty_carrier_v1 *unit_b_carrier_table(void) { return &carrier_table; }
const axoloty_carrier_v1 *unit_b_minimal_carrier_table(void) { return &minimal_carrier_table; }
uint32_t unit_b_platform_write_count(void) { return platform_write_count; }
uint32_t unit_b_carrier_publish_count(void) { return carrier_publish_count; }
