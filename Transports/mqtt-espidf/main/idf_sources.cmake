# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Declarative carrier source list for the ESP32-C6 main component.
#
# The platform main component includes this file and compiles exactly these
# sources, so the profile's transport selection reaches the build. This file
# lists sources; it contains no build logic and no protocol rule.
#
# The platform sets AXOLOTY_TRANSPORT_MAIN_DIR before including this file.

set(AXOLOTY_TRANSPORT_SWIFT_SOURCES
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/EmbeddedMQTTClient.swift"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/CarrierNetworkProbe.swift"
)

set(AXOLOTY_TRANSPORT_C_SOURCES
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/mqtt_event_validation.c"
)

# The platform already requires `mqtt` for its network bootstrap; ESP-MQTT is
# its bundled component and carries no independent version.
set(AXOLOTY_TRANSPORT_IDF_REQUIRES "")
