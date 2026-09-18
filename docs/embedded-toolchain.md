# ESP32-C6 toolchain pinning and workflow

Imported from `phynics/axoloty`. Provenance:

```json
"importedFrom": {
  "repository": "phynics/axoloty",
  "path": "docs/embedded-toolchain.md",
  "revision": "d279cf3315ce7914a6fd6cdad349e72fcd8b549c",
  "originalDate": "2026-09-18"
}
```

The original document described the in-repository workflow before the split
([axoloty#845](https://github.com/phynics/axoloty/issues/845), planned by
[axoloty#852](https://github.com/phynics/axoloty/issues/852)). The toolchain
facts are unchanged. The workflow commands were re-homed to this repository's
entry points; the pre-split `make embedded-*` targets no longer exist here.
Where a device or broker harness has not been migrated yet, the mapping in
[check-inventory.md](./check-inventory.md) names it as **unmigrated**, and no
result is claimed for it.

The ESP32-C6 toolchain is included in the single dev image (`axoloty-dev`).
Embedded Swift cross-compilation works: `AxolotyWire` compiles and runs
on-device, and the portable `AxolotyProtocol` foundation, including its bounded
correlation state, cross-compiles through the companion `axoloty_protocol`
component via the `espressif/idf_swift` component.

## Toolchain pinning

All toolchain components are in the single `Dockerfile` of the Core development
image, which this repository consumes as the pinned build environment:

| Component | Version | Source |
|---|---|---|
| Swift | `6.3` | `swift:6.3-jammy` base image |
| ESP-IDF | `v5.4` (pinned tag) | `git clone --depth 1 --branch v5.4` |
| RISC-V GCC | ESP-IDF v5.4 bundled | installed by `./install.sh esp32c6` |
| OpenOCD | Espressif build, bundled with ESP-IDF | installed by `./install.sh esp32c6` |
| espflash | `3.3.0` | prebuilt binary from `esp-rs/espflash` releases |
| CMake | `3.29.6` (via pip) | required by the ESP-IDF project and `espressif/idf_swift` |
| ccache | 4.5.1-1 | ESP-IDF-supported cross-worktree C/C++ compiler cache |
| SwiftLint | `0.65.0` | prebuilt static binary |

All versions are declared as `ARG`s at the top of the Core `.devcontainer/Dockerfile`
and bumped deliberately. Rebuilding the image is required to change any of them.

## Build / flash / monitor workflow

```sh
Tools/verify.sh --tier build              # build the profile firmware image
Tools/verify.sh --tier device             # flash, run the smoke protocol, write evidence
Profiles/esp32c6-mqtt/build.sh            # one profile build
AXOLOTY_DEVICE_PORT=/dev/ttyACM0 Profiles/esp32c6-mqtt/qualify.sh   # one profile qualification
```

`Tools/verify.sh` is the one entry point. A tier whose capability is absent
reports `UNAVAILABLE`; that is not a pass. Firmware builds go through
`Platforms/esp32c6-idf/tools/build.sh`, reached from
`Profiles/esp32c6-mqtt/build.sh`. Flashing and the smoke protocol go through
`Platforms/esp32c6-idf/tools/flash.sh`, reached from
`Profiles/esp32c6-mqtt/qualify.sh`; the board is named by `AXOLOTY_DEVICE_PORT`
and is never guessed.

Runtime evidence lands in the caller-owned proof workspace under `.axoloty/`
(`EMBEDDED_PROOF_ROOT`, `EMBEDDED_BUILD_DIR`, `EMBEDDED_EVIDENCE_DIR`). The
profile qualification record is written to
`docs/evidence/esp32c6-mqtt-embedded-swift-smoke-v2.json` by `qualify.sh`.

The pre-split `make embedded-swift-flash`, `make embedded-device-smoke`, and
the opt-in physical gates below ran inside the Core Makefile. In this
repository the equivalents are:

| Pre-split target | This repository |
|---|---|
| `make embedded-swift-build` | `Profiles/esp32c6-mqtt/build.sh`, tier `build` |
| `make embedded-swift-flash` / `-test` | `Profiles/esp32c6-mqtt/qualify.sh`, tier `device` |
| `make embedded-reproducible-build` | `Tests/embedded/check-reproducible-build.sh`, tier `build` |
| `make check-embedded-swift-linker` | `Tests/embedded/check-swift-linker.sh`, tier `build` |
| `make check-embedded-swift` / `check-static-io-macro-embedded` | stays in `phynics/axoloty` (hardware-free Core portability) |
| `make embedded-network-test` and the other device/broker gates | **unmigrated**; see [check-inventory.md](./check-inventory.md), note A |
| `make embedded-toolchain-doctor`, `make embedded-device-smoke` | superseded; see [check-inventory.md](./check-inventory.md) |

## Embedded Swift status

Firmware outside the Core repository consumes portable Core source through the
Core-owned
[`docs/embedded-consumer-contract.json`](https://github.com/phynics/axoloty/blob/main/docs/embedded-consumer-contract.json).
The lock file `axoloty-core.lock.json` names the exact Core revision this
repository builds against. Core's root `.build` directory is never a build
input; the only boundary is `Tools/prepare-core.sh` and its report.

Swift 6.3 compiles `AxolotyWire` for `riscv32-none-none-eabi` using
`-enable-experimental-feature Embedded`. The `espressif/idf_swift` ESP-IDF
component (v1.0.1) integrates the Swift compiler into the ESP-IDF build system
via `idf_component_register_swift()`.

The Swift firmware compiles `AxolotyWire` and the `AxolotyProtocol` foundation
as separate Embedded Swift modules and links their components into the
application. Verified on physical ESP32-C6 before the split:
`AXOLOTY_SMOKE_OK` captured, `WireReader.readUUID` and `TopicView.eventType`
work on-device. That historical run is not re-proved by this document; see the
evidence section.

Known limitations:

- `print()` and `String` pull in Unicode normalization runtime symbols that are
  not linked. Use `axoloty_print` (a C wrapper around `esp_rom_printf`) and
  `StaticString` instead.
- Variadic C functions (`printf`, `ESP_LOGI`) are unavailable in Embedded
  Swift. The `log_helper.c` wrapper provides a fixed-signature alternative.

## Embedded network security posture

The network vertical slice uses plaintext MQTT 3.1.1 with QoS 0. It is an
interoperability proof for a trusted local network, not a secure production
deployment. TLS, server-name verification, trust-anchor provisioning, and
client certificates are not enabled. ESP-IDF supports PEM or DER certificate
inputs and certificate bundles, but Axoloty does not yet define a provisioning
or rotation mechanism for embedded trust anchors.

Wi-Fi credentials are accepted only through `AXOLOTY_WIFI_SSID` and
`AXOLOTY_WIFI_PASSWORD`. A harness that needs them must convert them to numeric
byte arrays in an ignored, mode-0600 build header, never on compiler command
lines, and must remove the header after each build or failure. Credentials are
never included in JSONL evidence, and the broker receives no Wi-Fi credential
as an MQTT username or password.

`AXOLOTY_RUNTIME_IDENTITY` is an optional embedded MQTT client identity
override. It may be empty or contain 1–63 ASCII letters, digits, `.`, `_`, or
`-`. When unset or empty, the firmware reads the station MAC on each startup
and uses `axoloty-` followed by its 12 lowercase hexadecimal digits; this
remains stable across restarts and differs between devices with different
station MAC addresses. An invalid override fails configuration generation.

The MQTT callback accepts a message only when the first fragment is also the
complete payload (`current_data_offset == 0` and `data_len == total_data_len`).
The configured 257-byte topic and 2,049-byte payload buffers cover the approved
256-byte topic and 2,048-byte payload limits. The firmware rejects fragmented or
oversized messages before constructing a `BorrowedMessage`.

`EmbeddedMQTTClient` is the transport-local Swift overlay for bounded QoS 0
last-will configuration, connect, subscribe, publish, reconnect/resubscribe,
loopback receipt, and disconnect operations. It enforces operation order and
the 256-byte topic and 2,048-byte payload limits before entering its narrow C
bridge. ESP-MQTT handles and callbacks remain C-owned. The bridge copies input
bytes synchronously into fixed storage. Callback pointers never enter Swift or
survive callback return. The host seam test
`Tests/embedded/run-mqtt-host-test.sh` exercises that API without a
board.

The last-will, broker-restart, two-device agent, CoatyJS, and host
interoperability gates are described in [check-inventory.md](./check-inventory.md).
They need a board and a broker and are not yet migrated.

## Reproducible builds

`Platforms/esp32c6-idf/sdkconfig.defaults` sets
`CONFIG_APP_REPRODUCIBLE_BUILD=y`, which makes ESP-IDF omit non-deterministic
inputs (build timestamps, absolute paths) from the app binary.

To verify:

```sh
Tools/verify.sh --tier build
# or directly:
Tests/embedded/check-reproducible-build.sh
```

The check builds the profile twice from clean, records the SHA-256 of
`axoloty-swift.bin` each time, and fails if the two hashes differ.

## Evidence

A qualification claim is only accepted with an evidence record under
`docs/evidence/` that follows [evidence.md](./evidence.md). The imported
historical documentation refers to reviewed device runs, but those runs lived
in Axoloty's git-ignored `.testing/embedded/` directory and were never
committed, so no machine-readable record could be imported. Re-running the
device gate on a board is what produces a record here.
