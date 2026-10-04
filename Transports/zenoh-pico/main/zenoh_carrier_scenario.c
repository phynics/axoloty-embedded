// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "zenoh_carrier_scenario.h"

#include "axoloty_zenoh.h"
#include "carrier_diagnostics.h"
#include "zenoh_carrier_report.h"

#include <string.h>

// The scenario is single-owner and single-threaded for one run. It holds all
// of its storage here rather than on a device stack, so one run costs a fixed
// amount of static memory and never allocates.

#define SCENARIO_NAME "axoloty-zenoh-carrier"
#define SCENARIO_CARRIER_JSON_CAPACITY 512u
#define SCENARIO_RESOURCES_JSON_CAPACITY 384u
// Bounded waits so a device run cannot hang: a receive attempt waits a few
// milliseconds and gives up after a fixed count.
#define SCENARIO_RECEIVE_ATTEMPTS 64u
#define SCENARIO_RECEIVE_DELAY_MS 5u
// Hard ceilings on the two caller-sized loops. A device run may ask for more
// than a host run, but never unboundedly.
#define SCENARIO_MAX_CONTINUOUS_FRAMES 64u
#define SCENARIO_MAX_RECONNECT_CYCLES 200u

enum {
    STEP_PASS = 0,
    STEP_FAIL = 1,
    STEP_UNAVAILABLE = 2
};

typedef struct {
    axoloty_zenoh_session_t *subscriber;
    axoloty_zenoh_session_t *publisher;
    axoloty_zenoh_subscription_t *subscription;
    const uint8_t *key;
    uint32_t key_length;
    uint32_t steps_total;
    uint32_t steps_passed;
    uint32_t steps_unavailable;
} ScenarioState;

static char scenario_line[ZENOH_CARRIER_REPORT_LINE_CAPACITY];
static char scenario_carrier_json[SCENARIO_CARRIER_JSON_CAPACITY];
static char scenario_resources_json[SCENARIO_RESOURCES_JSON_CAPACITY];
static uint8_t scenario_key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
static uint8_t scenario_payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
static uint8_t scenario_rx_key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
static uint8_t scenario_rx_payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];

static void fill_pattern(uint8_t *buffer, uint32_t length, uint8_t seed) {
    for (uint32_t index = 0; index < length; ++index) {
        buffer[index] = (uint8_t)(seed + (uint8_t)index);
    }
}

static bool matches_pattern(const uint8_t *buffer, uint32_t length, uint8_t seed) {
    for (uint32_t index = 0; index < length; ++index) {
        if (buffer[index] != (uint8_t)(seed + (uint8_t)index)) {
            return false;
        }
    }
    return true;
}

static const char *outcome_name(int outcome) {
    if (outcome == STEP_FAIL) {
        return "fail";
    }
    if (outcome == STEP_UNAVAILABLE) {
        return "unavailable";
    }
    return "pass";
}

static void record(ScenarioState *state, const ZenohScenarioEnvironment *environment,
                   const char *step, int outcome, const char *detail) {
    state->steps_total += 1u;
    if (outcome == STEP_PASS) {
        state->steps_passed += 1u;
    } else if (outcome == STEP_UNAVAILABLE) {
        state->steps_unavailable += 1u;
    }

    ZenohCarrierReportSink sink;
    zenoh_carrier_report_begin(&sink, scenario_line, sizeof(scenario_line));
    (void)zenoh_carrier_report_key_string(&sink, "scenario", SCENARIO_NAME);
    (void)zenoh_carrier_report_key_string(&sink, "step", step);
    (void)zenoh_carrier_report_key_string(&sink, "result", outcome_name(outcome));
    if (detail != NULL) {
        (void)zenoh_carrier_report_key_string(&sink, "detail", detail);
    }
    size_t length = zenoh_carrier_report_end(&sink);
    if (length > 0u && environment->emit_jsonl != NULL) {
        environment->emit_jsonl(scenario_line, (uint32_t)length, environment->emit_context);
    }
}

static void note_publish(axoloty_zenoh_result_t result) {
    (void)carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_ATTEMPTS, 1u);
    if (result != AXOLOTY_ZENOH_OK) {
        (void)carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_FAILURES, 1u);
    }
}

static void note_session_failure(void) {
    (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1u);
}

static axoloty_zenoh_result_t poll_once(const ScenarioState *state, uint32_t *out_key_length,
                                        uint32_t *out_payload_length) {
    if (state->subscriber == NULL || state->subscription == NULL) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    return axoloty_zenoh_poll(state->subscriber, state->subscription, scenario_rx_key,
                              (uint32_t)sizeof(scenario_rx_key), out_key_length, scenario_rx_payload,
                              (uint32_t)sizeof(scenario_rx_payload), out_payload_length);
}

// Waits for one frame, verifies it against the published pattern, and returns
// the step outcome. A drop notification fails the receive: the step asked for
// a delivered frame and did not get one.
static int receive_expected(const ScenarioState *state, const ZenohScenarioEnvironment *environment,
                            uint32_t expected_length, uint8_t seed) {
    for (uint32_t attempt = 0; attempt < SCENARIO_RECEIVE_ATTEMPTS; ++attempt) {
        uint32_t key_length = 0u;
        uint32_t payload_length = 0u;
        axoloty_zenoh_result_t result = poll_once(state, &key_length, &payload_length);
        if (result == AXOLOTY_ZENOH_OK) {
            (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1u);
            if (payload_length != expected_length) {
                return STEP_FAIL;
            }
            return matches_pattern(scenario_rx_payload, expected_length, seed) ? STEP_PASS : STEP_FAIL;
        }
        if (result == AXOLOTY_ZENOH_QUEUE_FULL) {
            (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_DROPPED, 1u);
            return STEP_FAIL;
        }
        if (result == AXOLOTY_ZENOH_FRAME_TOO_LARGE) {
            (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_OVERSIZED, 1u);
            return STEP_FAIL;
        }
        if (result == AXOLOTY_ZENOH_QUEUE_EMPTY) {
            if (environment->delay_ms != NULL) {
                environment->delay_ms(SCENARIO_RECEIVE_DELAY_MS, environment->context);
            }
            continue;
        }
        (void)carrier_diagnostics_add(CARRIER_METRIC_POLL_ERRORS, 1u);
        note_session_failure();
        return STEP_FAIL;
    }
    return STEP_FAIL;
}

static void build_config(const ZenohScenarioConfig *config, axoloty_zenoh_config_t *out_config) {
    memset(out_config, 0, sizeof(*out_config));
    out_config->mode = AXOLOTY_ZENOH_MODE_CLIENT;
    out_config->connect_endpoint = config->connect_endpoint;
    out_config->connect_endpoint_length = config->connect_endpoint_length;
    out_config->multicast_scouting_enabled = false;
}

// Splices the resource reads into a bare object, or an honest placeholder when
// the run could not read them. The caller decides what a missing read means;
// this only reports it.
static bool build_resources_json(const ZenohScenarioEnvironment *environment) {
    static const char *const names[ZENOH_RESOURCE_COUNT] = {
        "freeHeapBytes",   "minFreeHeapBytes",   "largestFreeBlockBytes",
        "mainStackHighWaterBytes", "workerStackHighWaterBytes", "steadyStateAllocations",
    };
    bool available = environment->read_resource != NULL;
    ZenohCarrierReportSink sink;
    zenoh_carrier_report_begin(&sink, scenario_resources_json, sizeof(scenario_resources_json));
    for (uint32_t index = 0u; available && index < (uint32_t)ZENOH_RESOURCE_COUNT; ++index) {
        uint32_t value = 0u;
        if (!environment->read_resource((ZenohResourceMetric)index, &value, environment->context)) {
            available = false;
            break;
        }
        (void)zenoh_carrier_report_key_unsigned(&sink, names[index], value);
    }
    if (available && zenoh_carrier_report_end(&sink) > 0u) {
        return true;
    }
    zenoh_carrier_report_begin(&sink, scenario_resources_json, sizeof(scenario_resources_json));
    (void)zenoh_carrier_report_key_string(&sink, "status", "unexecuted");
    (void)zenoh_carrier_report_key_string(&sink, "reason", "the run could not read device resources");
    return zenoh_carrier_report_end(&sink) > 0u;
}

int zenoh_carrier_scenario_run(const ZenohScenarioConfig *config,
                               const ZenohScenarioEnvironment *environment) {
    if (config == NULL || environment == NULL || environment->emit_jsonl == NULL) {
        return 64;
    }
    if (config->key == NULL || config->key_length == 0u ||
        config->key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return 64;
    }

    ScenarioState state;
    memset(&state, 0, sizeof(state));
    memcpy(scenario_key, config->key, config->key_length);
    state.key = scenario_key;
    state.key_length = config->key_length;

    axoloty_zenoh_config_t zenoh_config;
    build_config(config, &zenoh_config);

    carrier_diagnostics_reset();

    // 1. Cold boot: the first session opens with no prior facade state.
    // 2. Session lifecycle: the handle reports the open state.
    axoloty_zenoh_result_t open_result = axoloty_zenoh_open(&zenoh_config, &state.subscriber);
    if (open_result == AXOLOTY_ZENOH_OK) {
        (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, 1u);
        record(&state, environment, "cold_boot", STEP_PASS, "first session opened");
    } else {
        note_session_failure();
        record(&state, environment, "cold_boot", STEP_FAIL, "the first open did not return OK");
        goto summary;
    }

    {
        axoloty_zenoh_session_state_t session_state = AXOLOTY_ZENOH_SESSION_CLOSED;
        if (axoloty_zenoh_state(state.subscriber, &session_state) == AXOLOTY_ZENOH_OK &&
            session_state == AXOLOTY_ZENOH_SESSION_OPEN) {
            record(&state, environment, "session_state", STEP_PASS, "the handle reports open");
        } else {
            record(&state, environment, "session_state", STEP_FAIL, "the handle does not report open");
        }
    }

    // 3. A second session so traffic has two endpoints.
    open_result = axoloty_zenoh_open(&zenoh_config, &state.publisher);
    if (open_result == AXOLOTY_ZENOH_OK) {
        (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, 1u);
        record(&state, environment, "open_publisher", STEP_PASS, "second session opened");
    } else {
        note_session_failure();
        record(&state, environment, "open_publisher", STEP_FAIL, "the second open did not return OK");
        goto summary;
    }

    // 4. One subscriber on the first session.
    axoloty_zenoh_result_t subscribe_result =
        axoloty_zenoh_subscribe(state.subscriber, state.key, state.key_length, &state.subscription);
    if (subscribe_result == AXOLOTY_ZENOH_OK) {
        carrier_diagnostics_set_active_subscriptions(1u);
        record(&state, environment, "subscribe", STEP_PASS, "one subscription declared");
    } else {
        note_session_failure();
        record(&state, environment, "subscribe", STEP_FAIL, "the subscription was not declared");
        goto summary;
    }

    // 5. Bidirectional traffic: publish on the second session, receive on the
    // first, so both endpoints carry the frame.
    {
        uint32_t payload_length = 16u;
        fill_pattern(scenario_payload, payload_length, 0x3cu);
        axoloty_zenoh_result_t publish_result = axoloty_zenoh_publish(
            state.publisher, state.key, state.key_length, scenario_payload, payload_length);
        note_publish(publish_result);
        if (publish_result != AXOLOTY_ZENOH_OK) {
            record(&state, environment, "bidirectional_traffic", STEP_FAIL, "the publish was refused");
        } else {
            if (environment->loopback != NULL) {
                environment->loopback(state.key, state.key_length, scenario_payload, payload_length,
                                      environment->context);
            }
            int outcome = receive_expected(&state, environment, payload_length, 0x3cu);
            record(&state, environment, "bidirectional_traffic", outcome,
                   outcome == STEP_PASS ? "frame crossed both sessions" : "frame did not arrive intact");
        }
    }

    // 6. Router absent then present. The count is always read; the transition
    // needs the environment to model router loss, which a host can and a bare
    // device run cannot.
    {
        uint32_t router_count = 0u;
        axoloty_zenoh_result_t router_result =
            axoloty_zenoh_connected_router_count(state.subscriber, &router_count);
        if (router_result != AXOLOTY_ZENOH_OK) {
            note_session_failure();
            record(&state, environment, "router_lifecycle", STEP_FAIL, "the router count was not read");
        } else {
            record(&state, environment, "router_lifecycle", STEP_PASS, "the router count was read");
        }

        if (router_result == AXOLOTY_ZENOH_OK && environment->set_router_available != NULL) {
            bool absent = false;
            bool present = false;
            (void)environment->set_router_available(false, environment->context);
            uint32_t zero = 1u;
            if (axoloty_zenoh_connected_router_count(state.subscriber, &zero) == AXOLOTY_ZENOH_OK &&
                zero == 0u) {
                absent = true;
            }
            (void)environment->set_router_available(true, environment->context);
            uint32_t restored = 0u;
            if (axoloty_zenoh_connected_router_count(state.subscriber, &restored) == AXOLOTY_ZENOH_OK &&
                restored > 0u) {
                present = true;
            }
            if (absent && present) {
                (void)carrier_diagnostics_add(CARRIER_METRIC_RECONNECTS_OBSERVED, 1u);
                record(&state, environment, "router_absent_then_present", STEP_PASS,
                       "loss and restoration both observed");
            } else {
                record(&state, environment, "router_absent_then_present", STEP_FAIL,
                       "the transition was not both observed");
            }
        } else {
            record(&state, environment, "router_absent_then_present", STEP_UNAVAILABLE,
                   "the run cannot drop and restore the router");
        }
    }

    // 7. Queue saturation: offer more than the queue holds, then drain. The
    // admitted frames arrive; the rest are reported as a drop notification.
    {
        if (environment->arm_queue_full_notification != NULL) {
            environment->arm_queue_full_notification(environment->context);
        }
        uint32_t offered = AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY + 2u;
        uint32_t payload_length = 8u;
        fill_pattern(scenario_payload, payload_length, 0x5au);
        for (uint32_t index = 0u; index < offered; ++index) {
            axoloty_zenoh_result_t publish_result = axoloty_zenoh_publish(
                state.publisher, state.key, state.key_length, scenario_payload, payload_length);
            note_publish(publish_result);
            if (publish_result == AXOLOTY_ZENOH_OK && environment->loopback != NULL) {
                environment->loopback(state.key, state.key_length, scenario_payload, payload_length,
                                      environment->context);
            }
        }

        uint32_t depth = 0u;
        axoloty_zenoh_result_t depth_result =
            axoloty_zenoh_queue_depth(state.subscriber, state.subscription, &depth);
        uint32_t received = 0u;
        uint32_t drops = 0u;
        bool errored = depth_result != AXOLOTY_ZENOH_OK;
        for (uint32_t index = 0u; index < offered && !errored; ++index) {
            uint32_t key_length = 0u;
            uint32_t received_length = 0u;
            axoloty_zenoh_result_t result = poll_once(&state, &key_length, &received_length);
            if (result == AXOLOTY_ZENOH_OK) {
                received += 1u;
                (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1u);
                continue;
            }
            if (result == AXOLOTY_ZENOH_QUEUE_FULL) {
                drops += 1u;
                (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_DROPPED, 1u);
                break;
            }
            if (result == AXOLOTY_ZENOH_QUEUE_EMPTY) {
                break;
            }
            if (result == AXOLOTY_ZENOH_FRAME_TOO_LARGE) {
                (void)carrier_diagnostics_add(CARRIER_METRIC_FRAMES_OVERSIZED, 1u);
            } else {
                (void)carrier_diagnostics_add(CARRIER_METRIC_POLL_ERRORS, 1u);
                note_session_failure();
            }
            errored = true;
        }
        (void)received;
        if (errored) {
            record(&state, environment, "queue_saturation", STEP_FAIL, "the drain did not complete");
        } else if (drops > 0u) {
            record(&state, environment, "queue_saturation", STEP_PASS,
                   "the drain observed a full-queue notification");
        } else {
            record(&state, environment, "queue_saturation", STEP_PASS,
                   "the queue drained without a drop notification");
        }
    }

    // 8. Continuous traffic: repeated publish/receive pairs.
    {
        uint32_t frames = config->continuous_frames == 0u ? 1u : config->continuous_frames;
        if (frames > SCENARIO_MAX_CONTINUOUS_FRAMES) {
            frames = SCENARIO_MAX_CONTINUOUS_FRAMES;
        }
        bool all_ok = true;
        for (uint32_t index = 0u; index < frames; ++index) {
            uint32_t payload_length = 4u + (index % 16u);
            uint8_t seed = (uint8_t)(0x10u + (uint8_t)index);
            fill_pattern(scenario_payload, payload_length, seed);
            axoloty_zenoh_result_t publish_result = axoloty_zenoh_publish(
                state.publisher, state.key, state.key_length, scenario_payload, payload_length);
            note_publish(publish_result);
            if (publish_result != AXOLOTY_ZENOH_OK) {
                all_ok = false;
                break;
            }
            if (environment->loopback != NULL) {
                environment->loopback(state.key, state.key_length, scenario_payload, payload_length,
                                      environment->context);
            }
            if (receive_expected(&state, environment, payload_length, seed) != STEP_PASS) {
                all_ok = false;
                break;
            }
        }
        record(&state, environment, "continuous_traffic", all_ok ? STEP_PASS : STEP_FAIL,
               all_ok ? "every pair arrived intact" : "a pair did not arrive intact");
    }

    // 9. Maximum payload: exactly the façade limit succeeds.
    {
        uint32_t payload_length = AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES;
        fill_pattern(scenario_payload, payload_length, 0xa5u);
        axoloty_zenoh_result_t publish_result = axoloty_zenoh_publish(
            state.publisher, state.key, state.key_length, scenario_payload, payload_length);
        note_publish(publish_result);
        int outcome = STEP_FAIL;
        if (publish_result == AXOLOTY_ZENOH_OK) {
            if (environment->loopback != NULL) {
                environment->loopback(state.key, state.key_length, scenario_payload, payload_length,
                                      environment->context);
            }
            outcome = receive_expected(&state, environment, payload_length, 0xa5u);
        }
        record(&state, environment, "maximum_payload", outcome,
               outcome == STEP_PASS ? "the limit payload crossed intact" : "the limit payload was lost");
    }

    // 10. Oversized payload: one byte over the limit is refused locally, with
    // no diagnostics failure recorded, because the refusal is the expectation.
    {
        uint32_t payload_length = AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES + 1u;
        fill_pattern(scenario_payload, AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES, 0x11u);
        axoloty_zenoh_result_t publish_result = axoloty_zenoh_publish(
            state.publisher, state.key, state.key_length, scenario_payload, payload_length);
        bool refused = publish_result == AXOLOTY_ZENOH_INVALID_ARGUMENT;
        record(&state, environment, "oversized_payload", refused ? STEP_PASS : STEP_FAIL,
               refused ? "the oversized publish was refused" : "the oversized publish was not refused");
    }

    // 11. Clean shutdown: remove the subscription, then close both sessions.
    {
        bool clean = true;
        if (axoloty_zenoh_unsubscribe(state.subscriber, state.subscription) == AXOLOTY_ZENOH_OK) {
            carrier_diagnostics_set_active_subscriptions(0u);
        } else {
            clean = false;
            note_session_failure();
        }
        if (axoloty_zenoh_close(state.publisher) == AXOLOTY_ZENOH_OK) {
            (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_CLOSES, 1u);
        } else {
            clean = false;
            note_session_failure();
        }
        if (axoloty_zenoh_close(state.subscriber) == AXOLOTY_ZENOH_OK) {
            (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_CLOSES, 1u);
        } else {
            clean = false;
            note_session_failure();
        }
        axoloty_zenoh_session_state_t session_state = AXOLOTY_ZENOH_SESSION_OPEN;
        if (axoloty_zenoh_state(state.subscriber, &session_state) == AXOLOTY_ZENOH_OK &&
            session_state != AXOLOTY_ZENOH_SESSION_CLOSED) {
            clean = false;
        }
        record(&state, environment, "clean_shutdown", clean ? STEP_PASS : STEP_FAIL,
               clean ? "subscription removed and both sessions closed" : "shutdown was not clean");
        state.subscription = NULL;
        state.publisher = NULL;
        state.subscriber = NULL;
    }

    // 12. Repeated reconnect: open and close one session many times.
    {
        uint32_t cycles = config->reconnect_cycles == 0u ? 1u : config->reconnect_cycles;
        if (cycles > SCENARIO_MAX_RECONNECT_CYCLES) {
            cycles = SCENARIO_MAX_RECONNECT_CYCLES;
        }
        bool all_ok = true;
        for (uint32_t index = 0u; index < cycles; ++index) {
            axoloty_zenoh_session_t *session = NULL;
            if (axoloty_zenoh_open(&zenoh_config, &session) != AXOLOTY_ZENOH_OK) {
                note_session_failure();
                all_ok = false;
                break;
            }
            (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, 1u);
            if (axoloty_zenoh_close(session) != AXOLOTY_ZENOH_OK) {
                note_session_failure();
                all_ok = false;
                break;
            }
            (void)carrier_diagnostics_add(CARRIER_METRIC_SESSION_CLOSES, 1u);
        }
        record(&state, environment, "repeated_reconnect", all_ok ? STEP_PASS : STEP_FAIL,
               all_ok ? "every open and close succeeded" : "a reconnect cycle did not complete");
    }

summary:;
    uint32_t failed =
        state.steps_total - state.steps_passed - state.steps_unavailable;
    const char *result = failed == 0u ? "pass" : "fail";
    ZenohCarrierReportSink sink;
    zenoh_carrier_report_begin(&sink, scenario_line, sizeof(scenario_line));
    (void)zenoh_carrier_report_key_string(&sink, "scenario", SCENARIO_NAME);
    (void)zenoh_carrier_report_key_string(&sink, "step", "summary");
    (void)zenoh_carrier_report_key_string(&sink, "result", result);
    (void)zenoh_carrier_report_key_unsigned(&sink, "steps", state.steps_total);
    (void)zenoh_carrier_report_key_unsigned(&sink, "passed", state.steps_passed);
    (void)zenoh_carrier_report_key_unsigned(&sink, "unavailable", state.steps_unavailable);
    (void)zenoh_carrier_report_key_unsigned(&sink, "failed", failed);
    (void)zenoh_carrier_report_key_unsigned(&sink, "flashImageBytes",
                                             environment->flash_image_bytes);

    // The counter object is the transport's own bounded writer. When it does
    // not fit, the summary says so rather than reporting a zero count.
    if (carrier_diagnostics_write_json(scenario_carrier_json, sizeof(scenario_carrier_json)) > 0u) {
        (void)zenoh_carrier_report_key_raw(&sink, "carrier", scenario_carrier_json);
    } else {
        (void)zenoh_carrier_report_key_raw(&sink, "carrier", "{\"status\":\"unavailable\"}");
    }
    if (build_resources_json(environment)) {
        (void)zenoh_carrier_report_key_raw(&sink, "resources", scenario_resources_json);
    } else {
        (void)zenoh_carrier_report_key_raw(&sink, "resources", "{\"status\":\"unavailable\"}");
    }

    size_t length = zenoh_carrier_report_end(&sink);
    if (length > 0u) {
        environment->emit_jsonl(scenario_line, (uint32_t)length, environment->emit_context);
    }
    return failed == 0u ? 0 : 1;
}
