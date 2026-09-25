// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "runtime_identity.h"
#include "mqtt_event_validation.h"
#include "mqtt_carrier.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum {
    FAIL_WILL = 1 << 0,
    FAIL_CONNECT = 1 << 1,
    FAIL_SUBSCRIBE = 1 << 2,
    FAIL_PUBLISH = 1 << 3,
    FAIL_LOOPBACK = 1 << 4,
    FAIL_RECONNECT = 1 << 5,
    FAIL_DISCONNECT = 1 << 6,
    FAIL_UNSUBSCRIBE = 1 << 7,
    FAIL_POLL = 1 << 8,
};

static unsigned host_failures;
static unsigned host_calls[9];
static unsigned host_resubscriptions;
static int host_event_ready;

void host_mqtt_reset(void) {
    host_failures = 0;
    memset(host_calls, 0, sizeof(host_calls));
    host_resubscriptions = 0;
    host_event_ready = 0;
}

void host_mqtt_set_failures(unsigned failures) { host_failures = failures; }
unsigned host_mqtt_call_count(unsigned operation) {
    return operation < 9 ? host_calls[operation] : 0;
}
unsigned host_mqtt_resubscription_count(void) { return host_resubscriptions; }
void host_mqtt_queue_event(void) { host_event_ready = 1; }

int axoloty_mqtt_configure_last_will(const unsigned char *topic, int topic_length,
                                     const unsigned char *payload, int payload_length) {
    (void)topic; (void)topic_length; (void)payload; (void)payload_length;
    ++host_calls[0];
    return (host_failures & FAIL_WILL) == 0;
}
int axoloty_mqtt_connect_wait(unsigned deadline_ms) {
    (void)deadline_ms; ++host_calls[1];
    return (host_failures & FAIL_CONNECT) == 0;
}
int axoloty_mqtt_subscribe_wait(const unsigned char *topic, int topic_length, unsigned deadline_ms) {
    (void)topic; (void)topic_length; (void)deadline_ms; ++host_calls[2];
    return (host_failures & FAIL_SUBSCRIBE) == 0;
}
int axoloty_mqtt_unsubscribe(const unsigned char *topic, int topic_length) {
    (void)topic; (void)topic_length; ++host_calls[7];
    return (host_failures & FAIL_UNSUBSCRIBE) == 0;
}
int axoloty_mqtt_publish(const unsigned char *topic, int topic_length,
                        const unsigned char *payload, int payload_length) {
    (void)topic; (void)topic_length; (void)payload; (void)payload_length; ++host_calls[3];
    return (host_failures & FAIL_PUBLISH) == 0;
}
int axoloty_mqtt_wait_loopback(unsigned deadline_ms) {
    (void)deadline_ms; ++host_calls[4];
    return (host_failures & FAIL_LOOPBACK) == 0;
}
int axoloty_mqtt_reconnect_wait(unsigned deadline_ms) {
    (void)deadline_ms; ++host_calls[5];
    if (host_failures & FAIL_RECONNECT) return 0;
    ++host_resubscriptions;
    return 1;
}
int axoloty_mqtt_poll_one_event(unsigned char *topic, int topic_capacity,
                                int *topic_length, unsigned char *payload,
                                int payload_capacity, int *payload_length) {
    static const unsigned char expected_topic[] = "coaty/3/test";
    static const unsigned char expected_payload[] = "{}";
    ++host_calls[8];
    if (host_failures & FAIL_POLL) return -1;
    if (!host_event_ready) return 0;
    host_event_ready = 0;
    if (!topic || !topic_length || !payload || !payload_length ||
        topic_capacity < (int)(sizeof(expected_topic) - 1) ||
        payload_capacity < (int)(sizeof(expected_payload) - 1)) return -1;
    memcpy(topic, expected_topic, sizeof(expected_topic) - 1);
    memcpy(payload, expected_payload, sizeof(expected_payload) - 1);
    *topic_length = (int)(sizeof(expected_topic) - 1);
    *payload_length = (int)(sizeof(expected_payload) - 1);
    return 1;
}
int axoloty_mqtt_disconnect(void) {
    ++host_calls[6];
    return (host_failures & FAIL_DISCONNECT) == 0;
}

static int read_test_mac(uint8_t mac[6], void *context) {
    (void)context;
    const uint8_t expected[6] = { 0x00, 0x01, 0xab, 0xcd, 0xef, 0xff };
    memcpy(mac, expected, sizeof(expected));
    return 1;
}

int host_identity_tests(void) {
    char output[64];
    if (!axoloty_runtime_identity_prepare(
            "site-a-device-01", read_test_mac, NULL, output, sizeof(output)) ||
        strcmp(output, "site-a-device-01") != 0) return 0;
    if (!axoloty_runtime_identity_prepare("", read_test_mac, NULL, output, sizeof(output)) ||
        strcmp(output, "axoloty-0001abcdefff") != 0) return 0;
    if (axoloty_runtime_identity_prepare("bad/name", read_test_mac, NULL, output, sizeof(output))) return 0;
    char small[8];
    return !axoloty_runtime_identity_prepare("too-long-for-buffer", read_test_mac, NULL, small, sizeof(small));
}

int host_callback_validation_tests(void) {
    static const char topic[] = "coaty/3/ns/ADV/source";
    static const char payload[] = "{}";
    if (!axoloty_mqtt_event_data_is_valid(topic, (int)strlen(topic), payload, 2, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(NULL, 1, payload, 2, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, (int)strlen(topic), NULL, 2, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, 0, payload, 2, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, (int)strlen(topic), payload, 1, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, (int)strlen(topic), payload, 1, 2, 1)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, 257, payload, 2, 2, 0)) return 0;
    if (axoloty_mqtt_event_data_is_valid(topic, (int)strlen(topic), payload, 2049, 2049, 0)) return 0;
    return 1;
}
