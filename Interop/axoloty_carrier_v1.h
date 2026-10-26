// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_CARRIER_V1_H
#define AXOLOTY_CARRIER_V1_H

#include <stdint.h>
#include <stddef.h>
#include "axoloty_abi_status_v1.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AXOLOTY_CARRIER_ABI_V1 AXOLOTY_ABI_V1

#define AXOLOTY_CARRIER_CAP_LAST_WILL UINT64_C(0x0000000000000001)
#define AXOLOTY_CARRIER_CAP_CONNECT UINT64_C(0x0000000000000002)
#define AXOLOTY_CARRIER_CAP_SUBSCRIBE UINT64_C(0x0000000000000004)
#define AXOLOTY_CARRIER_CAP_UNSUBSCRIBE UINT64_C(0x0000000000000008)
#define AXOLOTY_CARRIER_CAP_PUBLISH UINT64_C(0x0000000000000010)
#define AXOLOTY_CARRIER_CAP_POLL UINT64_C(0x0000000000000020)
#define AXOLOTY_CARRIER_CAP_RECONNECT UINT64_C(0x0000000000000040)
#define AXOLOTY_CARRIER_CAP_DISCONNECT UINT64_C(0x0000000000000080)
#define AXOLOTY_CARRIER_CAP_NETWORK_PROBE UINT64_C(0x0000000000000100)
#define AXOLOTY_CARRIER_CAP_LOOPBACK UINT64_C(0x0000000000000200)

typedef struct axoloty_carrier_v1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t capabilities;
    void *context;

    int32_t (*supports_last_will)(void *context, uint32_t *out_supported);
    int32_t (*configure_last_will)(void *context,
                                   const uint8_t *topic, uint32_t topic_length,
                                   const uint8_t *payload, uint32_t payload_length);
    int32_t (*connect)(void *context, uint32_t deadline_ms);
    int32_t (*subscribe)(void *context, const uint8_t *topic, uint32_t topic_length, uint32_t deadline_ms);
    int32_t (*unsubscribe)(void *context, const uint8_t *topic, uint32_t topic_length, uint32_t deadline_ms);
    int32_t (*publish)(void *context, const uint8_t *topic, uint32_t topic_length,
                       const uint8_t *payload, uint32_t payload_length);
    int32_t (*poll_one_event)(void *context,
                              uint8_t *topic, uint32_t topic_capacity, uint32_t *out_topic_length,
                              uint8_t *payload, uint32_t payload_capacity, uint32_t *out_payload_length);
    int32_t (*wait_for_reconnect)(void *context, uint32_t deadline_ms);
    int32_t (*wait_for_loopback)(void *context, uint32_t deadline_ms);
    int32_t (*disconnect)(void *context);
    int32_t (*copy_probe_topic)(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length);
    int32_t (*copy_probe_payload)(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *out_length);
} axoloty_carrier_v1;

/* The returned table and its context are immutable and live for the image. */
const axoloty_carrier_v1 *axoloty_carrier_get_v1(void);

/* Function mask indices follow the unique field order in capability_catalog.py. */
static inline int axoloty_carrier_v1_validate_requirements(
    const axoloty_carrier_v1 *table, uint64_t required_capabilities,
    uint64_t required_functions
) {
    if (table == NULL || table->abi_version != AXOLOTY_CARRIER_ABI_V1 ||
        table->struct_size < 2u * sizeof(uint32_t)) return 0;
    if (required_capabilities != 0 &&
        table->struct_size < offsetof(axoloty_carrier_v1, capabilities) + sizeof(table->capabilities)) return 0;
    if (required_capabilities != 0 &&
        (table->capabilities & required_capabilities) != required_capabilities) return 0;
    if (required_functions != 0 &&
        table->struct_size < offsetof(axoloty_carrier_v1, context) + sizeof(table->context)) return 0;
#define AXOLOTY_CARRIER_CHECK_FIELD(index, field) \
    if ((required_functions & (UINT64_C(1) << (index))) != 0 && \
        (table->struct_size < offsetof(axoloty_carrier_v1, field) + sizeof(table->field) || \
         table->field == NULL)) return 0
    AXOLOTY_CARRIER_CHECK_FIELD(0, supports_last_will);
    AXOLOTY_CARRIER_CHECK_FIELD(1, configure_last_will);
    AXOLOTY_CARRIER_CHECK_FIELD(2, connect);
    AXOLOTY_CARRIER_CHECK_FIELD(3, subscribe);
    AXOLOTY_CARRIER_CHECK_FIELD(4, unsubscribe);
    AXOLOTY_CARRIER_CHECK_FIELD(5, publish);
    AXOLOTY_CARRIER_CHECK_FIELD(6, poll_one_event);
    AXOLOTY_CARRIER_CHECK_FIELD(7, wait_for_reconnect);
    AXOLOTY_CARRIER_CHECK_FIELD(8, disconnect);
    AXOLOTY_CARRIER_CHECK_FIELD(9, copy_probe_topic);
    AXOLOTY_CARRIER_CHECK_FIELD(10, copy_probe_payload);
#undef AXOLOTY_CARRIER_CHECK_FIELD
    return 1;
}

#ifdef __cplusplus
}
#endif

#endif
