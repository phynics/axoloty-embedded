// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// Host stand-in for the part of ESP-MQTT's client API the carrier uses.
#ifndef AXOLOTY_STUB_MQTT_CLIENT_H
#define AXOLOTY_STUB_MQTT_CLIENT_H
#include <stdint.h>
#include "esp_err.h"
#include "esp_event.h"

typedef enum {
    MQTT_EVENT_ANY = -1,
    MQTT_EVENT_ERROR = 0,
    MQTT_EVENT_CONNECTED,
    MQTT_EVENT_DISCONNECTED,
    MQTT_EVENT_SUBSCRIBED,
    MQTT_EVENT_UNSUBSCRIBED,
    MQTT_EVENT_PUBLISHED,
    MQTT_EVENT_DATA,
} esp_mqtt_event_id_t;

typedef struct {
    esp_mqtt_event_id_t event_id;
    char *data;
    int data_len;
    int total_data_len;
    int current_data_offset;
    char *topic;
    int topic_len;
} esp_mqtt_event_t;
typedef esp_mqtt_event_t *esp_mqtt_event_handle_t;

typedef struct esp_mqtt_client *esp_mqtt_client_handle_t;

typedef struct {
    struct { struct { const char *uri; } address; } broker;
    struct { const char *client_id; } credentials;
    struct {
        struct { const char *topic; const char *msg; int msg_len; int qos; int retain; } last_will;
    } session;
    struct { int size; int out_size; } buffer;
} esp_mqtt_client_config_t;

esp_mqtt_client_handle_t esp_mqtt_client_init(const esp_mqtt_client_config_t *config);
esp_err_t esp_mqtt_client_register_event(esp_mqtt_client_handle_t client, int event,
                                         void (*handler)(void *, esp_event_base_t, int32_t, void *),
                                         void *context);
esp_err_t esp_mqtt_client_start(esp_mqtt_client_handle_t client);
esp_err_t esp_mqtt_client_stop(esp_mqtt_client_handle_t client);
esp_err_t esp_mqtt_client_destroy(esp_mqtt_client_handle_t client);
int esp_mqtt_client_subscribe(esp_mqtt_client_handle_t client, const char *topic, int qos);
int esp_mqtt_client_unsubscribe(esp_mqtt_client_handle_t client, const char *topic);
int esp_mqtt_client_publish(esp_mqtt_client_handle_t client, const char *topic, const char *data,
                            int len, int qos, int retain);
#endif
