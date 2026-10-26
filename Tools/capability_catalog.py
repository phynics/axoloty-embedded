#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Single source of ABI bits and function fields for manifest capabilities."""

PLATFORM = {
    "clock.monotonicMicroseconds": ("AXOLOTY_PLATFORM_CAP_CLOCK", ("clock_now_microseconds",)),
    "scheduler.delayTicks": ("AXOLOTY_PLATFORM_CAP_DELAY", ("delay_ticks",)),
    "device.restart": ("AXOLOTY_PLATFORM_CAP_RESTART", ("restart",)),
    "console.write": ("AXOLOTY_PLATFORM_CAP_LOG", ("write_log",)),
    "diagnostics.heap": ("AXOLOTY_PLATFORM_CAP_DIAGNOSTICS", ("heap_trace_begin", "heap_trace_end")),
    "diagnostics.stack": ("AXOLOTY_PLATFORM_CAP_DIAGNOSTICS", ("read_metrics",)),
    "network.configuration": ("AXOLOTY_PLATFORM_CAP_NETWORK_CONFIG", ("network_configured", "network_role", "network_scenario")),
    "network.bootstrap": ("AXOLOTY_PLATFORM_CAP_NETWORK_BOOTSTRAP", ("network_prepare", "network_cleanup")),
    "network.reconnect": ("AXOLOTY_PLATFORM_CAP_NETWORK_RECONNECT", ("network_reconnect",)),
    "device.displayName": ("AXOLOTY_PLATFORM_CAP_DEVICE_NAME", ("device_display_name",)),
}

CARRIER = {
    "lastWill": ("AXOLOTY_CARRIER_CAP_LAST_WILL", ("supports_last_will", "configure_last_will")),
    "connect": ("AXOLOTY_CARRIER_CAP_CONNECT", ("connect",)),
    "subscribe": ("AXOLOTY_CARRIER_CAP_SUBSCRIBE", ("subscribe",)),
    "unsubscribe": ("AXOLOTY_CARRIER_CAP_UNSUBSCRIBE", ("unsubscribe",)),
    "publish": ("AXOLOTY_CARRIER_CAP_PUBLISH", ("publish",)),
    "poll": ("AXOLOTY_CARRIER_CAP_POLL", ("poll_one_event",)),
    "reconnect": ("AXOLOTY_CARRIER_CAP_RECONNECT", ("wait_for_reconnect",)),
    "disconnect": ("AXOLOTY_CARRIER_CAP_DISCONNECT", ("disconnect",)),
    "networkProbe": ("AXOLOTY_CARRIER_CAP_NETWORK_PROBE", ("copy_probe_topic", "copy_probe_payload")),
}
