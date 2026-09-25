// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_MQTT_HOST_TEST_H
#define AXOLOTY_MQTT_HOST_TEST_H

#include <stdint.h>

void host_mqtt_reset(void);
void host_mqtt_set_failures(unsigned failures);
unsigned host_mqtt_call_count(unsigned operation);
unsigned host_mqtt_resubscription_count(void);
void host_mqtt_queue_event(void);
int host_identity_tests(void);
int host_callback_validation_tests(void);

#endif
