// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Device entry point for the C-only Zenoh carrier scenario.
//
// This file is compiled only when the qualification build sets
// AXOLOTY_QUALIFICATION_CARRIER_SCENARIO. For that build it owns `app_main`
// instead of the shared smoke application, supplies the device hooks the
// scenario can read, and leaves the host-only hooks `NULL` so the steps that
// need them record `unavailable` instead of a pass. The shared smoke and MQTT
// images never compile this file.
//
// It names no protocol token. The key bytes come from the transport's
// transport-neutral network probe route, and the endpoint comes from the same
// operator configuration the smoke network build reads.

#include "zenoh_carrier_scenario.h"
#include "zenoh_endpoint.h"
#include "network_bootstrap.h"

#include <stdint.h>
#include <string.h>

#if AXOLOTY_QUALIFICATION_CARRIER_SCENARIO

#include "esp_heap_caps.h"
#include "esp_image_format.h"
#include "esp_ota_ops.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdio.h>

// The endpoint may reach the facade's 512-byte limit; the route is bounded by
// the facade's key limit. Both are borrowed by the scenario for the whole run,
// so they are static rather than stack.
#define DEVICE_ENDPOINT_CAPACITY 512u
#define DEVICE_KEY_CAPACITY 256u
#define DEVICE_NETWORK_DEADLINE_MS 30000u
#define DEVICE_CONTINUOUS_FRAMES 8u
#define DEVICE_RECONNECT_CYCLES 4u

static void device_emit_jsonl(const char *line, uint32_t length, void *context) {
    (void)context;
    if (line == NULL || length == 0u) {
        return;
    }
    // One write so a captured line is not split by another writer, then a
    // flush so a host capture sees it before the next step.
    (void)fwrite(line, 1u, (size_t)length, stdout);
    (void)fputc('\n', stdout);
    (void)fflush(stdout);
}

static int64_t device_now_us(void *context) {
    (void)context;
    return (int64_t)esp_timer_get_time();
}

static void device_delay_ms(uint32_t milliseconds, void *context) {
    (void)context;
    if (milliseconds == 0u) {
        return;
    }
    vTaskDelay(pdMS_TO_TICKS(milliseconds));
}

// Reads the metrics this platform can answer. The worker stack high-water mark
// and the steady-state allocation count have no readable source here, so the
// read fails and the scenario reports the resources object `unexecuted`
// instead of inventing a number. `NULL` names the calling task, which is the
// task the scenario runs on.
static bool device_read_resource(ZenohResourceMetric metric, uint32_t *out_value, void *context) {
    (void)context;
    if (out_value == NULL) {
        return false;
    }
    switch (metric) {
        case ZENOH_RESOURCE_FREE_HEAP_BYTES:
            *out_value = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
            return true;
        case ZENOH_RESOURCE_MIN_FREE_HEAP_BYTES:
            *out_value = (uint32_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
            return true;
        case ZENOH_RESOURCE_LARGEST_FREE_BLOCK_BYTES:
            *out_value = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
            return true;
        case ZENOH_RESOURCE_MAIN_STACK_HIGH_WATER_BYTES:
            *out_value = (uint32_t)uxTaskGetStackHighWaterMark(NULL);
            return true;
        default:
            return false;
    }
}

// Length of the running image on flash, or 0 when the metadata cannot be read.
// The scenario reports 0 as "unknown"; it is never a measured value.
static uint32_t device_flash_image_bytes(void) {
    const esp_partition_t *partition = esp_ota_get_running_partition();
    if (partition == NULL) {
        return 0u;
    }
    esp_partition_pos_t position;
    position.offset = partition->address;
    position.size = partition->size;
    esp_image_metadata_t metadata;
    if (esp_image_get_metadata(&position, &metadata) != ESP_OK) {
        return 0u;
    }
    return (uint32_t)metadata.image_len;
}

void app_main(void) {
    if (!axoloty_network_configured()) {
        esp_rom_printf("carrier scenario: no network configuration; no router\n");
        return;
    }
    if (axoloty_network_prepare(DEVICE_NETWORK_DEADLINE_MS) == 0u) {
        esp_rom_printf("carrier scenario: the network did not come up in time\n");
        (void)axoloty_network_cleanup();
        return;
    }

    static unsigned char endpoint[DEVICE_ENDPOINT_CAPACITY];
    const int endpoint_length = axoloty_zenoh_copy_endpoint(endpoint, (int)sizeof(endpoint));
    if (endpoint_length <= 0) {
        esp_rom_printf("carrier scenario: no router endpoint is configured\n");
        (void)axoloty_network_cleanup();
        return;
    }
    static unsigned char key[DEVICE_KEY_CAPACITY];
    const int key_length = axoloty_network_copy_topic(key, (int)sizeof(key));
    if (key_length <= 0) {
        esp_rom_printf("carrier scenario: no route bytes are configured\n");
        (void)axoloty_network_cleanup();
        return;
    }

    ZenohScenarioConfig config;
    memset(&config, 0, sizeof(config));
    config.connect_endpoint = endpoint;
    config.connect_endpoint_length = (uint32_t)endpoint_length;
    config.key = key;
    config.key_length = (uint32_t)key_length;
    config.continuous_frames = DEVICE_CONTINUOUS_FRAMES;
    config.reconnect_cycles = DEVICE_RECONNECT_CYCLES;

    ZenohScenarioEnvironment environment;
    memset(&environment, 0, sizeof(environment));
    environment.emit_jsonl = device_emit_jsonl;
    environment.now_us = device_now_us;
    environment.delay_ms = device_delay_ms;
    // A device links to a real router, so it does not model delivery, does not
    // force router loss, and does not synthesize a full-queue notification.
    // Those steps record `unavailable` when the environment cannot drive them.
    environment.loopback = NULL;
    environment.set_router_available = NULL;
    environment.arm_queue_full_notification = NULL;
    environment.read_resource = device_read_resource;
    environment.flash_image_bytes = device_flash_image_bytes();

    const int result = zenoh_carrier_scenario_run(&config, &environment);
    (void)axoloty_network_cleanup();
    if (result == 0) {
        esp_rom_printf("carrier scenario: complete\n");
    } else {
        esp_rom_printf("carrier scenario: incomplete\n");
    }
}

#endif // AXOLOTY_QUALIFICATION_CARRIER_SCENARIO
