// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stdint.h>
#include <limits.h>

#include "axoloty_carrier_v1.h"

extern int32_t axoloty_zenoh_v1_supports_last_will(void *, uint32_t *);
extern int32_t axoloty_zenoh_v1_configure_last_will(void *, const uint8_t *, uint32_t,
                                                     const uint8_t *, uint32_t);
extern int32_t axoloty_zenoh_v1_connect(void *, uint32_t);
extern int32_t axoloty_zenoh_v1_subscribe(void *, const uint8_t *, uint32_t, uint32_t);
extern int32_t axoloty_zenoh_v1_unsubscribe(void *, const uint8_t *, uint32_t, uint32_t);
extern int32_t axoloty_zenoh_v1_publish(void *, const uint8_t *, uint32_t,
                                        const uint8_t *, uint32_t);
extern int32_t axoloty_zenoh_v1_poll(void *, uint8_t *, uint32_t, uint32_t *,
                                     uint8_t *, uint32_t, uint32_t *);
extern int32_t axoloty_zenoh_v1_reconnect(void *, uint32_t);
extern int32_t axoloty_zenoh_v1_disconnect(void *);
extern int axoloty_network_copy_topic(unsigned char *, int);
extern int axoloty_network_copy_payload(unsigned char *, int);

static int32_t copy_topic(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *length) {
    (void)context;
    if (buffer == NULL || length == NULL || capacity == 0 || capacity > (uint32_t)INT_MAX)
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    int copied = axoloty_network_copy_topic(buffer, (int)capacity);
    if (copied <= 0) return AXOLOTY_ABI_STATUS_FAILED;
    if ((uint32_t)copied > capacity) return AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL;
    *length = (uint32_t)copied;
    return AXOLOTY_ABI_STATUS_OK;
}

static int32_t copy_payload(void *context, uint8_t *buffer, uint32_t capacity, uint32_t *length) {
    (void)context;
    if (buffer == NULL || length == NULL || capacity > (uint32_t)INT_MAX)
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT;
    int copied = axoloty_network_copy_payload(buffer, (int)capacity);
    if (copied < 0) return AXOLOTY_ABI_STATUS_FAILED;
    if ((uint32_t)copied > capacity) return AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL;
    *length = (uint32_t)copied;
    return AXOLOTY_ABI_STATUS_OK;
}

static const axoloty_carrier_v1 carrier_table = {
    .abi_version = AXOLOTY_CARRIER_ABI_V1,
    .struct_size = (uint32_t)sizeof(axoloty_carrier_v1),
    /* lastWill advertises the query operation, not positive support. */
    .capabilities = AXOLOTY_CARRIER_CAP_LAST_WILL | AXOLOTY_CARRIER_CAP_CONNECT |
        AXOLOTY_CARRIER_CAP_SUBSCRIBE | AXOLOTY_CARRIER_CAP_UNSUBSCRIBE |
        AXOLOTY_CARRIER_CAP_PUBLISH | AXOLOTY_CARRIER_CAP_POLL |
        AXOLOTY_CARRIER_CAP_RECONNECT | AXOLOTY_CARRIER_CAP_DISCONNECT |
        AXOLOTY_CARRIER_CAP_NETWORK_PROBE,
    .context = NULL,
    .supports_last_will = axoloty_zenoh_v1_supports_last_will,
    .configure_last_will = axoloty_zenoh_v1_configure_last_will,
    .connect = axoloty_zenoh_v1_connect,
    .subscribe = axoloty_zenoh_v1_subscribe,
    .unsubscribe = axoloty_zenoh_v1_unsubscribe,
    .publish = axoloty_zenoh_v1_publish,
    .poll_one_event = axoloty_zenoh_v1_poll,
    .wait_for_reconnect = axoloty_zenoh_v1_reconnect,
    .wait_for_loopback = NULL,
    .disconnect = axoloty_zenoh_v1_disconnect,
    .copy_probe_topic = copy_topic,
    .copy_probe_payload = copy_payload,
};

const axoloty_carrier_v1 *axoloty_carrier_get_v1(void) { return &carrier_table; }
