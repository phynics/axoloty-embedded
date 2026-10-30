// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
// Host runner for the transport-owned C-only carrier scenario.
//
// It links the real scenario core, the real bounded report shim, the real
// transport-neutral counters, and the host's façade fake, then prints one JSON
// line per step to stdout. It measures no device resource and reports no
// device result. Its only job is to prove the scenario drives the façade
// contract end to end on a host, so the device run has a known-good reference
// stream to match.

#include "axoloty_zenoh.h"
#include "carrier_diagnostics.h"
#include "zenoh_carrier_scenario.h"
#include "zenoh_host_test.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// These hooks model the router deliveries a real router produces, so the
// scenario exercises the same paths on a host.
//
// AXOLOTY_SCENARIO_DELIVERY=staggered models a real link: a published frame is
// in flight, and one frame lands each time the scenario waits. A step that reads
// the queue before the frames it published have landed fails here every time,
// where on a board it fails only when the timing goes against it.
static unsigned runner_failures;
static uint32_t runner_flash_bytes;

static void emit_line(const char *line, uint32_t length, void *context) {
    (void)context;
    (void)fwrite(line, 1u, length, stdout);
    (void)fputc('\n', stdout);
}

static int64_t runner_now_us(void *context) {
    (void)context;
    return esp_timer_get_time();
}

#define RUNNER_IN_FLIGHT_CAPACITY 8u

typedef struct {
    const uint8_t *key;
    uint32_t key_length;
    uint32_t payload_length;
    uint8_t payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
} RunnerFrame;

static RunnerFrame runner_in_flight[RUNNER_IN_FLIGHT_CAPACITY];
static uint32_t runner_in_flight_head;
static uint32_t runner_in_flight_count;
static bool runner_staggered;

static void runner_land_one(void) {
    if (runner_in_flight_count == 0u) return;
    RunnerFrame *frame = &runner_in_flight[runner_in_flight_head];
    host_zenoh_set_sample(frame->key, (int)frame->key_length, frame->payload, (int)frame->payload_length);
    runner_in_flight_head = (runner_in_flight_head + 1u) % RUNNER_IN_FLIGHT_CAPACITY;
    runner_in_flight_count -= 1u;
}

static void runner_delay_ms(uint32_t milliseconds, void *context) {
    (void)context;
    runner_land_one();
    vTaskDelay(milliseconds * host_zenoh_scheduler_hz() / 1000u);
}

static void runner_loopback(const uint8_t *key, uint32_t key_length, const uint8_t *payload,
                            uint32_t payload_length, void *context) {
    (void)context;
    if (!runner_staggered) {
        host_zenoh_set_sample(key, (int)key_length, payload, (int)payload_length);
        return;
    }
    if (runner_in_flight_count == RUNNER_IN_FLIGHT_CAPACITY) runner_land_one();
    RunnerFrame *frame = &runner_in_flight[(runner_in_flight_head + runner_in_flight_count) % RUNNER_IN_FLIGHT_CAPACITY];
    frame->key = key;
    frame->key_length = key_length;
    frame->payload_length = payload_length;
    memcpy(frame->payload, payload, payload_length);
    runner_in_flight_count += 1u;
}

static bool runner_set_router_available(bool available, void *context) {
    (void)context;
    if (available) {
        runner_failures &= ~(unsigned)HOST_ZENOH_FAIL_ROUTERS;
    } else {
        runner_failures |= (unsigned)HOST_ZENOH_FAIL_ROUTERS;
    }
    host_zenoh_set_failures(runner_failures);
    return true;
}

static bool runner_read_resource(ZenohResourceMetric metric, uint32_t *out_value, void *context) {
    (void)metric;
    (void)out_value;
    (void)context;
    return false;
}

int main(void) {
    host_zenoh_reset();
    runner_failures = 0u;
    runner_flash_bytes = 0u;

    // The gate measures the built image and passes its size here so the
    // summary carries a flash number read from the artifact, not a guess. A
    // bare host run leaves it zero and records that no image was measured.
    const char *delivery = getenv("AXOLOTY_SCENARIO_DELIVERY");
    runner_staggered = delivery != NULL && strcmp(delivery, "staggered") == 0;

    const char *flash = getenv("AXOLOTY_SCENARIO_FLASH_BYTES");
    if (flash != NULL && flash[0] != '\0') {
        runner_flash_bytes = (uint32_t)strtoul(flash, NULL, 10);
    }

    // Opaque route bytes only. The scenario never interprets them and no Core
    // protocol token appears here.
    static const uint8_t key[] = "axoloty/embedded/zenoh/carrier-scenario";

    ZenohScenarioConfig config;
    memset(&config, 0, sizeof(config));
    config.connect_endpoint = NULL;
    config.connect_endpoint_length = 0u;
    config.key = key;
    config.key_length = (uint32_t)(sizeof(key) - 1u);
    config.reconnect_cycles = 5u;
    config.continuous_frames = 8u;

    ZenohScenarioEnvironment environment;
    memset(&environment, 0, sizeof(environment));
    environment.emit_jsonl = emit_line;
    environment.emit_context = NULL;
    environment.now_us = runner_now_us;
    environment.delay_ms = runner_delay_ms;
    environment.loopback = runner_loopback;
    environment.set_router_available = runner_set_router_available;
    environment.read_resource = runner_read_resource;
    environment.flash_image_bytes = runner_flash_bytes;
    environment.context = NULL;

    return zenoh_carrier_scenario_run(&config, &environment);
}
