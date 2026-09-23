// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The ESP32-C6 / ESP-IDF profile supplies the device smoke application's seam.
//
// Every field points at a platform operation declared in `BridgingHeader.h`
// and implemented in this platform. The closures capture nothing, so the
// struct stays allocation-free and the application receives plain C function
// pointers.

@inline(__always)
private func ignoreExchangeMilestone(_: UInt32) {}

/// Builds the seam this platform installs before starting the application.
func esp32c6SmokeSeam() -> DeviceSmokeSeam {
    DeviceSmokeSeam(
        print: { axoloty_print($0) },
        printUInt: { axoloty_print_uint($0, $1) },
        nowMicroseconds: { esp_timer_get_time() },
        delay: { vTaskDelay($0) },
        restart: { esp_restart() },

        freeInternalHeap: { axoloty_free_internal_heap() },
        minFreeInternalHeap: { axoloty_min_free_internal_heap() },
        largestInternalBlock: { axoloty_largest_internal_block() },
        mainStackHighWater: { axoloty_main_stack_high_water() },
        mainStackSize: { axoloty_main_stack_size() },
        resetReason: { axoloty_reset_reason() },
        heapTraceBegin: { axoloty_heap_trace_begin() },
        heapTraceEnd: { axoloty_heap_trace_end() },

        networkConfigured: { axoloty_network_configured() },
        networkRole: { axoloty_network_role() },
        networkScenario: { axoloty_network_scenario() },
        networkPrepare: { axoloty_network_prepare($0) },
        networkReconnect: { axoloty_network_reconnect_wait($0) },
        networkCopyTopic: { axoloty_network_copy_topic($0, $1) },
        networkCopyPayload: { axoloty_network_copy_payload($0, $1) },
        networkCleanup: { axoloty_network_cleanup() },
        carrier: DeviceSmokeCarrierOperations(
            configureLastWill: embeddedExchangeConfigureLastWill,
            connect: embeddedExchangeConnect,
            subscribe: embeddedExchangeSubscribe,
            unsubscribe: embeddedExchangeUnsubscribe,
            publish: embeddedExchangePublish,
            pollOneEvent: embeddedExchangePollOneEvent,
            waitForReconnect: embeddedExchangeWaitForReconnect,
            disconnect: embeddedExchangeDisconnect
        ),
        exchangeMilestone: ignoreExchangeMilestone,
        deviceDisplayName: { axoloty_device_display_name($0, $1) }
    )
}
