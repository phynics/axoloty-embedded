# Embedded check inventory

Every embedded-related check that exists today, what it proves, and where it
belongs after the Embedded-Swift split ([axoloty#845], planned by
[axoloty#852]). The classification rule is the one in axoloty#852:

> does it need a board or a broker, or does it prove firmware image behavior?
> Then it is ours. Does it prove portable compile, macro portability, Core
> boundedness, protocol parity, or import/module constraints? Then it stays in
> Axoloty and must remain hardware-free.

Dispositions are exactly one of:

| Disposition | Meaning |
|---|---|
| `KEEP/REWRITE IN AXOLOTY` | Proves a portable Core / Embedded-Swift portability property. Stays in `phynics/axoloty`, hardware-free. |
| `MOVE TO AXOLOTY-EMBEDDED` | Proves firmware behavior or device qualification. Belongs in this repository. |
| `SUPERSEDE/DELETE` | Obsolete, or replaced by a check that already exists here. |

`Where it lands` is the target path and capability tier in this repository. A
check that cannot be brought over faithfully is marked **unmigrated** with the
reason. This issue is classification and ownership, not redesign; nothing was
rewritten while moving.

`Confidence` records anything not classified with certainty. No row is allowed
to be quiet about a guess.

## 1. Root `Makefile` embedded target families

Source: `phynics/axoloty` `Makefile` targets and the scripts they invoke.

| Check | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `check-embedded-swift` | `Makefile` → `Tests/Support/checks/check-embedded-swift.sh` | `AxolotyWire` compiles and links under Embedded Swift for `riscv32-none-none-eabi`, and the parser behavior probe passes on the host | KEEP/REWRITE IN AXOLOTY | Stays; hardware-free. Later folded into `check-embedded-core-consumer`, which keeps the link and parser probes; the target was removed in [axoloty#918](https://github.com/phynics/axoloty/pull/918) | certain |
| `check-embedded-swift-linker` | `Makefile` → `axoloty-tool embedded verify` → `Tests/Support/checks/check-embedded-swift-linker.sh` | The ESP32-C6 firmware links Swift `UnicodeDataTables` and the `.got/.got.plt` handling survives ESP-IDF's `sections.ld` | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/check-swift-linker.sh`, tier `build` (no board) | certain |
| `check-static-io-macro-embedded` | `Makefile` alias → `check-embedded-core-consumer` → `check-embedded-swift-core.sh` | The production macro plugin expands a real `StaticIoActor` consumer | KEEP/REWRITE IN AXOLOTY | Stays as `check-embedded-core-consumer`; the alias was removed in [axoloty#918](https://github.com/phynics/axoloty/pull/918) | certain |
| `check-embedded-core-consumer` | `Makefile` → `Tests/Support/checks/check-embedded-swift-core.sh` | All five portable modules plus `_JSONCore` compile and partially link under Embedded Swift with the real macro consumer | KEEP/REWRITE IN AXOLOTY | Stays; hardware-free | certain |
| `embedded-swift-build` | `Makefile` → `axoloty-tool embedded build` → `Tests/Support/embedded/build-embedded-swift.sh` | The Embedded Swift firmware image is produced | MOVE TO AXOLOTY-EMBEDDED | Landed in #1 as `Platforms/esp32c6-idf/tools/build.sh` + `Profiles/esp32c6-mqtt/build.sh`; tier `build` | certain |
| `embedded-swift-flash` | `Makefile` → `Tests/Support/embedded/embedded-swift-smoke.sh` | The firmware is flashed and the `embedded-swift-smoke-v2` JSONL protocol passes on a board | MOVE TO AXOLOTY-EMBEDDED | Landed in #1 as `Profiles/esp32c6-mqtt/qualify.sh` → `Platforms/esp32c6-idf/tools/flash.sh` + `validate-smoke.mjs`; tier `device` | certain |
| `embedded-swift-test` | `Makefile` → `Tests/Support/embedded/embedded-swift-test.sh` | The full deterministic vector corpus runs on a board | MOVE TO AXOLOTY-EMBEDDED | Same as `embedded-swift-flash`: `validate-smoke.mjs` already validates the full 312-case corpus; tier `device` | certain |
| `embedded-swift-reproducible-build` | `Makefile` → `Tests/Support/embedded/embedded-swift-reproducible-build.sh` | Two clean firmware builds produce a bit-identical `axoloty-swift.bin` | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/check-reproducible-build.sh`, tier `build` | certain |
| `embedded-network-test` | `Makefile` → `Tests/Support/embedded/embedded-network-test.sh` | Wi-Fi/MQTT carrier ordering, boundedness, and reconnect on a board | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: needs a board and a role-config build lifecycle that #1 did not carry over (see note A) | certain on disposition; see note A |
| `embedded-agent-test` | `Makefile` → `Tests/Support/embedded/embedded-agent-test.sh` | Two boards complete the agent Advertise→Discover→Resolve→Deadvertise exchange | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: two boards + broker + role-config build lifecycle (note A) | certain |
| `embedded-host-agent-exchange` | new broker-tier check | The real device-smoke application exchanges Advertise→Discover→Resolve→Deadvertise with `EmbeddedHostPeer`, including reconnect and injected last-will delivery | MOVE TO AXOLOTY-EMBEDDED | **Landed**: `Tests/embedded/broker/run-host-agent-exchange.sh` self-provisions `AxolotyTestBroker` on an ephemeral port; an operator `AXOLOTY_MQTT_HOST` remains supported | certain |
| `embedded-coatyjs-test` | `Tests/Support/embedded/embedded-coatyjs-test.sh` | A board interoperates with the pinned CoatyJS reference agent | MOVE TO AXOLOTY-EMBEDDED | **Landed**: `Tests/embedded/run-coatyjs-interop-test.sh` runs the default exchange in each role against the reference agent mounted from `coatyswift-wire-coatyjs:2.4.0`; no npm at test time | certain |
| `embedded-host-test` | `Tests/Support/embedded/embedded-host-test.sh` | A board interoperates with the host Axoloty Swift runtime over a broker | MOVE TO AXOLOTY-EMBEDDED | **Landed**: `Tests/embedded/run-host-interop-test.sh` runs the device against `EmbeddedHostPeer`, built by SwiftPM from the Core revision pinned in `axoloty-core.lock.json`; no Core checkout and no consumer-contract expansion | certain |
| `embedded-last-will-test` | `Makefile` → `Tests/Support/embedded/embedded-last-will-test.sh` | The broker publishes the configured last will after an unexpected device reset | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: two boards + broker + observer + role-config build (note A) | certain |
| `embedded-broker-restart-test` | `Makefile` → `Tests/Support/embedded/embedded-broker-restart-test.sh` | The device reconnects and restores its subscription after a broker restart | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: board + managed Mosquitto + role-config build (note A) | certain |
| `embedded-interop-test` | `Makefile` aggregator | Runs agent/host/CoatyJS/last-will/broker-restart together | MOVE TO AXOLOTY-EMBEDDED | **Landed**: `Tests/embedded/run-interop-suite.sh` runs agent exchange, CoatyJS (both roles), last-will, and host interop (both roles). Broker-restart runs as a separate step because it manages its own broker on the configured port | certain |
| `embedded-toolchain-doctor` / `check-embedded-toolchain` | `Makefile` → `axoloty-tool embedded doctor` → `Tests/Support/checks/check-embedded-toolchain.sh` | ESP-IDF tools are installed and a device node is readable | MOVE TO AXOLOTY-EMBEDDED | Superseded by the `build`/`device` capability gates in `Tools/verify.sh`; the toolchain documentation is imported to `docs/embedded-toolchain.md` | certain |
| `check-embedded-environment` | `Tests/Support/checks/check-embedded-environment.sh` | ESP-IDF activates and exposes `idf.py` and the RISC-V GCC | SUPERSEDE/DELETE | Superseded by `Tools/verify.sh` `build`-tier capability gate | certain |
| `embedded-device-info` | `Tests/Support/embedded/embedded-device-info.sh` | Chip model, MAC, flash size, toolchain versions, and serial identity are recorded | MOVE TO AXOLOTY-EMBEDDED | **Landed** as a diagnostic: `Tests/embedded/run-device-info-test.sh` records the unit through `Platforms/esp32c6-idf/tools/write-device-manifest.mjs`, and the raw log carries the flash id and toolchain versions. It writes no evidence record because it drives no protocol and cannot fail | certain |
| `embedded-device-smoke` | `Makefile` → `Tests/Support/embedded/embedded-device-smoke.sh` | The legacy C smoke image boots and prints `AXOLOTY_SMOKE_OK` | SUPERSEDE/DELETE | Superseded by the Embedded Swift smoke (`embedded-swift-flash` / `qualify.sh`); the C `Embedded/main` app is not part of the migrated product | certain |
| `embedded-reproducible-build` | `Makefile` → `Tests/Support/embedded/embedded-reproducible-build.sh` | The C smoke `axoloty-smoke.bin` rebuilds bit-identically | SUPERSEDE/DELETE | Superseded by `embedded-swift-reproducible-build` (`axoloty-swift.bin`) | certain |
| `check-benchmark-wire-device` | `Tests/Support/checks/check-benchmark-wire-device.sh` | On-device wire benchmark timing and size report | MOVE TO AXOLOTY-EMBEDDED | **Landed**: firmware at `Platforms/esp32c6-idf/benchmark/`, runner `Tests/embedded/run-benchmark-wire-device.sh` | certain |
| `embedded-consumer-proof-{build,flash,validate}` (+ `embedded-external-consumer-*` adapters) | `Makefile` | External-consumer GO proof on a clean sparse Core + firmware archive, ending in a flashed device run | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: a cross-repo release-proof lifecycle that #1 deliberately did not move (note A) | certain on disposition |

## 2. `Tests/Support/embedded/` support scripts

| Check | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `embedded-swift-smoke` harness | `Tests/Support/embedded/embedded-swift-smoke.sh` | Flashes and reads the structured JSONL smoke protocol over serial | MOVE TO AXOLOTY-EMBEDDED | Superseded by `Platforms/esp32c6-idf/tools/flash.sh` + `qualify.sh` (landed in #1) | certain |
| smoke validator | `Tests/Support/embedded/embedded-swift-smoke-validator.mjs` | Validates the smoke/vector JSONL stream | MOVE TO AXOLOTY-EMBEDDED | Landed as `Platforms/esp32c6-idf/tools/validate-smoke.mjs` | certain |
| vector validator | `Tests/Support/embedded/embedded-swift-test-validator.mjs` | Adds the 312-case vector corpus and the zero hot-path allocation budget | MOVE TO AXOLOTY-EMBEDDED | Landed as `createEmbeddedSwiftTestValidator` in `validate-smoke.mjs` | certain |
| network validator | `Tests/Support/embedded/embedded-network-validator.mjs` | Expected `network:*` and corpus set | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated** with the network test (note A) | certain |
| agent validator | `Tests/Support/embedded/embedded-agent-validator.mjs` | Expected `exchange:*` sets for agent/last-will/broker-restart | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated** with its device tests (note A) | certain |
| corpus manifest resolver | `Tests/Support/embedded/embedded-corpus-manifest.mjs` | Resolves the application fixture manifest inside the project | MOVE TO AXOLOTY-EMBEDDED | Superseded by the inline resolver in `validate-smoke.mjs` | certain |
| corpus generator | `Tests/Support/embedded/generate-embedded-corpus.mjs` | Emits the firmware corpus Swift from the application fixtures | MOVE TO AXOLOTY-EMBEDDED | Landed as `Applications/device-smoke-agent/fixtures/generate-embedded-corpus.mjs` | certain |
| network config generator | `Tests/Support/embedded/generate-embedded-network-config.mjs` | Emits the private `axoloty_network_config.h` (SSID/password/host/role/scenario) | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: only the role-based device tests use it (note A) | certain |
| build cache policy | `Tests/Support/embedded/embedded-build-cache.sh` | ESP-IDF incremental/ccache namespacing | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated**: `build.sh` (landed in #1) builds explicitly and does not use a ccache policy | certain |
| pre-split Core resolver | `Tests/Support/embedded/resolve-embedded-core.sh` | Resolves `AXOLOTY_SOURCE_DIR` into package source dirs and a SHA | SUPERSEDE/DELETE | Superseded by `Tools/prepare-core.sh` and its report; must never return to firmware | certain |
| pre-split Core tool prep | `Tests/Support/embedded/prepare-embedded-core-tools.sh` | Builds the macro tool and locates `_JSONCore` in a firmware scratch dir | SUPERSEDE/DELETE | Superseded by the `Tools/prepare-core.sh` report | certain |
| Swift link probe | `Tests/Support/embedded/embedded-swift-link-probe.swift` | Exercises public `AxolotyWire` APIs in the Core RISC-V link check | KEEP/REWRITE IN AXOLOTY | Stays; now compiled by `check-embedded-core-consumer` | certain |
| Swift parser probe | `Tests/Support/embedded/embedded-swift-parser-probe.swift` | Host Embedded-Swift parser behavior | KEEP/REWRITE IN AXOLOTY | Stays | certain |
| host shims | `Tests/Support/embedded/embedded-swift-host-shims.c` | Host shims for the parser probe | KEEP/REWRITE IN AXOLOTY | Stays | certain |
| MQTT host HAL | `Tests/Support/embedded/embedded-mqtt-host-hal.c` | Fake C HAL for the transport seam test | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/mqtt-host-hal.c` | certain |
| MQTT host seam test | `Tests/Support/embedded/embedded-mqtt-host-test.{swift,sh}` | `EmbeddedMQTTClient` enforces operation order and 256/2048 bounds before the HAL | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/mqtt-host-test.swift` + runner, tier `build` | certain |
| runtime identity host test | `Tests/Support/embedded/embedded-runtime-identity-test.c` | Device identity is MAC-derived, stable, override-validated | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/runtime-identity-test.c` + runner, tier `build` | certain |
| shared flags host test | `Tests/Support/embedded/embedded-shared-flags-test.c` | Platform shared flags are atomic across threads | MOVE TO AXOLOTY-EMBEDDED | `Tests/embedded/shared-flags-test.c` + runner, tier `build` | certain |
| serial capture helper | `Tests/Support/lib/serial-tools.mjs` | Non-blocking serial capture used by every device run | MOVE TO AXOLOTY-EMBEDDED | **Unmigrated** with the device tests (note A) | certain |

## 3. Selftests (`Tests/Support/selftests/`)

| Check | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `test-check-embedded-swift.sh` | selftest | The Core compile/link checker passes on good input and rejects untyped `throws` | KEEP/REWRITE IN AXOLOTY | Retired in Core with `check-embedded-swift.sh` | certain |
| `test-check-embedded-swift-core.sh` | selftest | The Core consumer gate passes and fails on a malformed consumer | KEEP/REWRITE IN AXOLOTY | Stays | certain |
| `test-check-embedded-swift-linker.sh` | selftest | The linker probe check fails closed on a bad linker fragment | MOVE TO AXOLOTY-EMBEDDED | With `check-swift-linker.sh` | certain |
| `test-build-embedded-swift.sh` | selftest | The pre-split firmware build wrapper respects Core SHA/dirty identity and CMake edges | MOVE TO AXOLOTY-EMBEDDED | Superseded by the platform build and Core-preparation report | certain |
| `test-embedded-swift-smoke.sh` | selftest | The smoke harness/validator wiring | MOVE TO AXOLOTY-EMBEDDED | Superseded by `flash.sh`/`validate-smoke.mjs` | certain |
| `test-embedded-swift-test.sh` | selftest | The full vector validator wiring | MOVE TO AXOLOTY-EMBEDDED | Superseded by `validate-smoke.mjs` | certain |
| `test-embedded-runtime-identity.sh` | selftest | Compiles and runs the identity host test | MOVE TO AXOLOTY-EMBEDDED | Superseded by the new `runtime-identity` runner | certain |
| `test-embedded-mqtt-client.sh` | selftest | Static source-shape greps plus the MQTT and shared-flags host tests | MOVE TO AXOLOTY-EMBEDDED | Split: host tests become the two new runners; the source-shape greps are covered by `Tools/check-invariants.sh` axis rules | certain |
| `test-embedded-network.sh` | selftest | Network harness wiring | MOVE TO AXOLOTY-EMBEDDED | Unmigrated with the network test (note A) | certain |
| `test-embedded-coatyjs.sh` | selftest | CoatyJS harness wiring | MOVE TO AXOLOTY-EMBEDDED | Unmigrated (note A) | certain |
| `test-check-g3-object-model-evidence.sh` / `test-check-g6-resource-evidence.sh` | selftest | G3/G6 evidence validators | KEEP/REWRITE IN AXOLOTY | Stays with G3/G6 (see note C) | moderate — see note C |

## 4. Evidence producers, spikes, resource measurements

| Check | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `g1-bounded-runtime-host` / `-sanitized` | `Spikes/BoundedPortableRuntime/check-{host,sanitized}.sh` | Portable runtime boundedness: zero allocation growth, saturation, stale-token rejection | KEEP/REWRITE IN AXOLOTY | Stays; hardware-free | certain |
| `g1-bounded-runtime-embedded` | Formerly `Spikes/BoundedPortableRuntime/check-embedded.sh` | Core boundedness cross-build and image growth at capacities 0/1/4/16/64 | RETIRED FROM AXOLOTY | The Core producer was removed in #914; its measurements remain historical in Axoloty. No matching producer was migrated here. | certain |
| `g1-bounded-runtime-device` | Formerly `Spikes/BoundedPortableRuntime/check-device.sh` | Bounded-runtime measurements on an ESP32-C6 | RETIRED FROM AXOLOTY; PRODUCER DEFERRED HERE | The Core producer was removed in #914. Historical runs remain in Axoloty, but this repository has no G1 device producer. | certain |
| `g3-object-model-evidence-host` / `-sanitized` | `Spikes/BoundedObjectModelEvidence/check-{host,sanitized}.sh` | Portable object-model boundedness | KEEP/REWRITE IN AXOLOTY | Stays; hardware-free | certain |
| `g3-object-model-evidence-portable` | `Spikes/BoundedObjectModelEvidence/check-portable.sh` | Portable object-model host evidence without a firmware tree or ESP-IDF | KEEP/REWRITE IN AXOLOTY | Stays as an opt-in portable evidence probe; no canonical tier node | certain |
| `g6-resource-evidence` | `Tests/Support/checks/check-g6-resource-evidence.sh` + `Tests/Support/evidence/validate-g6-resource-evidence.mjs` | Host+device sustained resource budgets at the exact Core commit, with power-cycle runs | MOVE TO AXOLOTY-EMBEDDED (decided; producer deferred) | The device `esp32c6` environment is owned here and must be embedded-swift. Not implemented; the maintainer deferred the producer. Axoloty keeps the validator, policy, and thresholds | certain on ownership |
| `embedded-benchmark` device measurement | `Platforms/esp32c6-idf/benchmark/` + `Tests/embedded/run-benchmark-wire-device.sh` | On-device wire throughput/size | MOVE TO AXOLOTY-EMBEDDED | Landed. `Platforms/*/benchmark/` is exempt from the platform protocol-rule scan because the fixture is not linked into any image | certain |

## 5. Documentation

| Check/document | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `docs/embedded-toolchain.md` | Axoloty `docs/` | ESP32-C6 toolchain pinning, build/flash/monitor workflow, network security posture | MOVE TO AXOLOTY-EMBEDDED | `docs/embedded-toolchain.md`, imported with provenance | certain |
| `docs/embedded-consumer-contract.{json,md}` | Axoloty `docs/` | The Core→firmware source/dependency contract, named by the lock's `consumerContractPath` | KEEP/REWRITE IN AXOLOTY | Stays: it is Core's contract and is referenced by `axoloty-core.lock.json` | certain |
| `docs/embedded-io-endpoints.md` | Axoloty `docs/` | ESP32-C6 profile protocol/endpoint semantics | KEEP/REWRITE IN AXOLOTY | Stays: protocol semantics are Core's | moderate — it describes firmware consumption |
| `docs/embedded-toolchain.md` ownership note | Axoloty `docs/` | Says the toolchain "is migrating" | SUPERSEDE/DELETE | Superseded by the imported copy here; Axoloty's copy must drop the firmware workflow (Axoloty is read-only for this task) | certain |

## Zero silent coverage loss

Brought over and wired in this repository:

| Former Axoloty check | New home | Tier |
|---|---|---|
| `embedded-swift-build` | `Platforms/esp32c6-idf/tools/build.sh` + `Profiles/esp32c6-mqtt/build.sh` (via #1) | `build` |
| `embedded-swift-flash` / `embedded-swift-test` | `Profiles/esp32c6-mqtt/qualify.sh` + `flash.sh` + `validate-smoke.mjs` (via #1) | `device` |
| `test-embedded-runtime-identity.sh` | `Tests/embedded/run-runtime-identity-test.sh` | `build` |
| shared-flags test from `test-embedded-mqtt-client.sh` | `Tests/embedded/run-shared-flags-test.sh` | `build` |
| `embedded-mqtt-host-test` | `Tests/embedded/run-mqtt-host-test.sh` | `build` |
| `check-embedded-swift-linker` | `Tests/embedded/check-swift-linker.sh` | `build` |
| `embedded-swift-reproducible-build` | `Tests/embedded/check-reproducible-build.sh` | `build` |

Unmigrated, named with a reason, so the coverage loss is explicit rather than
silent:

- **Note A — role-config device/broker runs.** `embedded-network-test`,
  `embedded-agent-test`, `embedded-coatyjs-test`, `embedded-host-test`,
  `embedded-last-will-test`, `embedded-broker-restart-test`,
  `embedded-interop-test`, `embedded-device-info`, and the
  `embedded-consumer-proof-*` lifecycle. The pre-split scripts drove the single
  `Embedded/swift` project directly and injected
  `axoloty_network_config.h` into its build tree between configure and build.
  #1 migrated that project into a profile/platform composition whose
  `build.sh` has no scenario/role-config injection point. Re-establishing one
  is a firmware build-lifecycle change (a redesign), which is out of scope for
  an ownership-and-classification issue. They are not hardware-free, so they
  cannot run in CI or in a toolchain-free checkout, and they were not converted
  into file-shape assertions. The firmware support they exercise
  (`CarrierNetworkProbe`, `network_bootstrap.c` scenario bits) **did** move in
  #1. Issue #19 later moved agent-exchange sequencing into
  `Applications/device-smoke-agent/main/AgentExchange.swift` and removed the
  scenario bits from the platform.
- **Note B — device benchmark firmware.** Landed: the C firmware is at
  `Platforms/esp32c6-idf/benchmark/` and its runner at
  `Tests/embedded/run-benchmark-wire-device.sh`. The fixture is exempt from the
  platform protocol-rule scan because it is a measurement, not platform
  integration, and is never linked into a firmware image.
- **Note C — G1/G3/G6 device producers (decided 2026-09-19; producer
  deferred).** Device resource evidence is a firmware artifact owned here and
  must be embedded-swift: Axoloty's G6 validator requires
  `implementation: embedded-swift` and rejects C surrogates, so the on-device
  wire benchmark (`Platforms/esp32c6-idf/benchmark/`, a C port) cannot produce
  it. The device producer is not implemented; the maintainer deferred it.
  Axoloty keeps the hardware-free variants (G1 host/sanitized/embedded, G3
  build-only), the G6 resource policy, thresholds, and
  `validate-g6-resource-evidence.mjs`. Axoloty removes
  `Spikes/BoundedPortableRuntime/Embedded` and `check-device.sh` under
  [axoloty#854](https://github.com/phynics/axoloty/issues/854); the retained
  reviewed results stay quoted in Axoloty's `EVIDENCE.md` as historical Core
  evidence. The device producer is a known follow-up, not a silent gap.

## No committed historical device evidence to import

The reviewed device runs the pre-split documentation refers to lived in
Axoloty's `.testing/embedded/` directory, which is git-ignored (`phynics/axoloty`
`.gitignore` lines 49–56). No machine-readable device evidence record was ever
committed, so there is no record whose original status could be preserved under
`importedFrom`. The embedded *documentation* is imported with provenance; the
absence of an importable evidence record is recorded in
[migration-discoveries.md](./migration-discoveries.md).

## 6. Embedded Zenoh (issue #4)

Source: the Zenoh tickets re-scoped by [axoloty#853], under epic
[axoloty#796]. These are new embedded-owned checks, not file moves; the
already-landed skeleton and the proposed replacement issues are named per row.
The classification rule in section 0 is unchanged: a check that needs a board,
a broker, or proves firmware-image behavior is ours; a portable Core property
stays in Axoloty.

| Check | Where defined today | What it proves | Disposition | Where it lands | Confidence |
|---|---|---|---|---|---|
| `zenoh-host-seam` | New in this repository (`Transports/zenoh-pico/main/EmbeddedZenohClient.swift` + `Tests/embedded/zenoh-host-test.swift`) | The bounded client enforces operation order and the 256/2048 bounds before the carrier C seam | **Landed** (tier `build`). Landed shape; the run is `unexecuted` here because no host compiler is available | `Tests/embedded/run-zenoh-host-test.sh` | certain on shape; run unexecuted |
| zenoh-pico compile and C-only pub/sub | Axoloty #797, embedded half | The pinned `zenoh-pico 1.10.0` compiles for `esp32c6` and a C-only round trip runs | MOVE TO AXOLOTY-EMBEDDED | Proposed **ZP-1**; tiers `build` + `device` | certain on disposition |
| zenoh-pico backend conformance | Axoloty #805, embedded half | The pico backend satisfies the same facade suite as `zenoh-c`, with divergence documented | MOVE TO AXOLOTY-EMBEDDED | Proposed **ZP-2**; tiers `build` + `device` | certain |
| pinned zenoh-pico ESP-IDF component | Axoloty #813 | A pinned `zenoh-pico` builds through `idf.py` with only the required features | MOVE TO AXOLOTY-EMBEDDED | `Platforms/esp32c6-idf/components/zenoh_pico/` (pin and unverified wrapper landed), completed by **ZP-3** | certain |
| zenoh-pico backend of the facade | Axoloty #814 | The pico backend implements the `axoloty_zenoh_*` carrier seam | MOVE TO AXOLOTY-EMBEDDED | `Transports/zenoh-pico/` carrier seam (skeleton) + **ZP-4** | certain |
| `EmbeddedZenohClient` | Axoloty #815 | open/subscribe/publish/poll/unsubscribe/close in the `EmbeddedMQTTClient` style | MOVE TO AXOLOTY-EMBEDDED | `Transports/zenoh-pico/main/EmbeddedZenohClient.swift` (skeleton landed) + **ZP-5** | certain |
| static runtime integration | Axoloty #816 | MQTT Embedded and Zenoh Embedded invoke identical `AxolotyProtocol` code paths | MOVE TO AXOLOTY-EMBEDDED | Proposed **ZP-6**; tier `device` | certain |
| embedded route subscriptions | Axoloty #817 | The two bounded route shapes install over Zenoh and match the host | MOVE TO AXOLOTY-EMBEDDED | Proposed **ZP-7**; tier `device` | certain |
| ESP32-C6 Zenoh hardware qualification | Axoloty #818 | Boot/session/pub-sub/reconnect/saturation/resource gate with enforced thresholds | MOVE TO AXOLOTY-EMBEDDED | Proposed **ZP-8**; tier `device` | certain |

Not done here, named rather than stubbed: the pico backend, the completed
component wrapper, the application carrier seam, embedded route wiring, and any
device or resource run. The exact proposed issue titles and bodies are in
[proposed-issues.md](./proposed-issues.md). The pin and its source are in
[zenoh-embedded.md](./zenoh-embedded.md).

[axoloty#853]: https://github.com/phynics/axoloty/issues/853
[axoloty#796]: https://github.com/phynics/axoloty/issues/796
