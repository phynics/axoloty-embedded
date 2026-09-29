// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_NETWORK_BOOTSTRAP_H
#define AXOLOTY_NETWORK_BOOTSTRAP_H

unsigned int axoloty_network_prepare(unsigned int overall_deadline_ms);
unsigned int axoloty_network_reconnect_wait(unsigned int deadline_ms);
int axoloty_network_is_active(void);
unsigned int axoloty_network_deadline_remaining_ms(void);
unsigned int axoloty_network_cleanup(void);
int axoloty_network_configured(void);
unsigned int axoloty_network_role(void);
unsigned int axoloty_network_scenario(void);
int axoloty_device_display_name(unsigned char *buffer, int capacity);
int axoloty_network_copy_topic(unsigned char *buffer, int capacity);
int axoloty_network_copy_payload(unsigned char *buffer, int capacity);
int axoloty_transport_network_prepare(void);
void axoloty_transport_network_cleanup(void);

#endif
