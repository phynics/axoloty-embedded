# Resource budgets

A profile declares build-stage size budgets in its `profile.json`. The build
measures the linked image, writes `size.json` beside the artifact, and fails
when a metric exceeds its budget. The release manifest carries the report as
`resources`. This implements the build-stage part of
[#63](https://github.com/phynics/axoloty-embedded/issues/63).

## What is measured

`Platforms/esp32c6-idf/tools/write-size-report.mjs` reads the linked ELF with
the toolchain's `size -A`, and the image size from the `.bin`.

| Metric | Meaning |
|---|---|
| `imageBytes` | Size of `axoloty-swift.bin` |
| `flashTextBytes` | `.flash.text` |
| `flashRodataBytes` | `.flash.rodata` and `.flash.appdesc` |
| `iramTextBytes` | `.iram0.text` and its end marker |
| `initializedDataBytes` | `.iram0.data` and `.dram0.data` |
| `dramBssBytes` | `.dram0.bss` and `.noinit` |
| `staticRamBytes` | Instruction RAM, initialized data, and zeroed data together (the "static D/IRAM" figure) |

The padding section `.flash_rodata_dummy` is not flash use and is not counted.
The report also records the application partition size and the headroom left in
it, and names the profile, application, platform, transport, and Core revision
it was measured for. The Core revision comes from the preparation report, and
the image SHA-256 binds the measurement to the exact binary. A missing required
section, malformed table, or invalid budget declaration fails the report.
Optional end-marker, IRAM data, app descriptor, and no-init sections count as
zero when absent.

## What is budgeted

`profile.json` carries `budgets.build` for four metrics: `imageBytes`,
`flashTextBytes`, `staticRamBytes`, and `dramBssBytes`. `budgets.basis` states
what the numbers describe.

**Policy.** A budget is the measured value on the last certified image plus 10
percent, rounded up to the next KiB. The 10 percent leaves room for ordinary
change. A real regression, such as a linked-in dependency, exceeds it and fails
the build. When a budget is raised, the change records why.

**Runtime floors.** `budgets.runtime` holds `minimumFreeHeapBytes` and
`stackRemainingBytes`. Each is a floor, not a ceiling: the measured value (the
lowest across the normal and the recovery run) minus 10 percent, rounded down to
the next KiB. A device run fails when any metrics sample is below a floor.
`Tests/embedded/run-sensor-node.mjs` reads the floors from the profile and judges
every sample, including the ones taken across a carrier outage.

**What the numbers describe.** The `basis` string of every budgeted profile names
what it measured. The two smoke profiles carry budgets for the *smoke harness*
images measured on `0.10.0-embedded.2` with Core `v0.10.0`. They are regression
gates for the harness and are not production budgets: the smoke application
carries test vectors and a benchmark corpus that a production application would
not. The two sensor-node profiles carry the production reference application's
budgets, below.

A numerical threshold does not transfer to another platform, Core revision, or
toolchain. Relocking Core or changing the SDK means measuring again and
resetting the budgets with new evidence.

## What is not covered

- **Configured qualification variants.** The C-only carrier scenario image is
  larger and is reported but not gated, following the static-storage policy
  receipt (`not-applicable`). This is a Zenoh qualification variant, not a
  qualified release artifact. A certificate for a qualified release cannot use
  the exemption; network-configured images are gated. Known limit: the
  validator cannot prove that a `not-applicable` report on an unqualified
  Zenoh manifest came from the C-only image. This does not affect certificates,
  because `--require-qualified` rejects the exemption.
- **Runtime budgets on the smoke profiles.** Minimum free heap and the
  main-stack remainder come from a device run and are not measured at build
  time. The smoke profiles declare none. Only the sensor-node profiles gate them.
- **Stack bounds.** The report does not bound stack use.
- **Performance.** No budget here constrains wire parse or codec time. The
  production configuration's effect on it, measured on the smoke corpus, is in
  [esp32c6-production-parse-time.md](evidence/esp32c6-production-parse-time.md).
  The smoke application does not run under the unmodified production
  configuration, and `sensor-node` has no timing corpus.

## Releases must carry a report

A release of a profile that declares `budgets.build` must carry a size report in
`resources`; the validator rejects `resources: null` for it. Only the four
certificates issued before the report existed are exempt, through a fixed list of
exact `<profile>/<version>` entries in `Tools/validate-release-manifest.py`.

## Reading a report

`size.json` has `enforcement.status` of `passed`, `failed`, `not-applicable`
(a configured variant), or `not-configured` (the profile declares no budgets).
Only `passed`, `not-applicable`, and `not-configured` can appear in a
published certificate; the manifest validator rejects `failed`.

## The production reference application

`Applications/sensor-node` is the production-shaped application: one sensor
object, a periodic reading, a Resolve for Discover, and a metrics line, with a
session loop that reconnects after the carrier goes away. The profiles
`esp32c6-sensor-node-mqtt` and `esp32c6-sensor-node-zenoh` build it with the
`production` configuration (`Platforms/esp32c6-idf/sdkconfig.production`).

### Measure the networked image

A build with no network header links no Wi-Fi or TCP/IP stack. Such an image is
331 KB (MQTT) or 440 KB (Zenoh) and is **not** the footprint of a working node.
This also holds for the smoke profiles: **the smoke harness budgets in the table
below describe images built without a network stack** and must not be read as
the cost of a node that can join a network.

A build of a profile that selects `"configuration": "production"` with no
`AXOLOTY_NETWORK_CONFIG_HEADER` therefore stages a sizing-only placeholder header
(documentation-range address 192.0.2.1, SSID `sizing-only`, port 1883, no secret).
It links the network stack, so the size gate measures the right image. The size
report records `configuration.networkConfigured` and, for a placeholder,
`configuration.networkPlaceholder: true`. The placeholder image is never device
evidence: the device runners always generate a real header, and the evidence
writer refuses an image whose report says placeholder or unconfigured.

The placeholder and the real-credential image differ in constants only:

| Profile | Placeholder image | Real-credential image | Difference |
|---|---|---|---|
| `esp32c6-sensor-node-mqtt` | 837,696 B | 837,760 B | 64 B |
| `esp32c6-sensor-node-zenoh` | 734,944 B | 734,992 B | 48 B |

Static RAM and `.bss` are identical. The budgets below leave 10 percent, far
more than this difference.

### Per-profile table

Core revision `087bd9bb1bfb563d0347799245ea4dd43e509bc9` for every row.
Sizes in bytes. Measured on one ESP32-C6, Embedded Swift 6.4, ESP-IDF 5.4. The sizes and the
runtime figures below come from the second board (MAC 40:4c:ca:ff:fe:4d:8c:e8),
built and run at firmware revision `49f4fccc9d381264f4c88bad7e22c361c443e32d`.
The first board (MAC 40:4c:ca:ff:fe:4e:52:dc) produced the figures in the
earlier version of this page and is no longer named by any record.

| | Smoke `esp32c6-mqtt` | Smoke `esp32c6-zenoh` | Sensor node MQTT | Sensor node Zenoh |
|---|---|---|---|---|
| Network stack linked | no | no | yes | yes |
| Configuration | default | default | `production` | `production` |
| sdkconfig SHA-256 | not recorded in the budget | not recorded in the budget | `3e14e6acd8df3ff2a35dd6d13aeba1a687787f388a71d0b85765e787e82378bc` | same |
| Image (build budget) | 739,328 | 738,304 | 921,600 | 808,960 |
| Flash text (build budget) | 553,984 | 544,768 | 714,752 | 636,928 |
| Static RAM (build budget) | 180,224 | 174,080 | 155,648 | 153,600 |
| `.bss` (build budget) | 82,944 | 76,800 | 39,936 | 38,912 |
| Image, measured (placeholder) | | | 837,696 | 734,944 |
| Flash text, measured (placeholder) | | | 648,956 | 578,690 |
| Static RAM, measured | | | 141,112 | 139,264 |
| `.bss`, measured | | | 36,003 | 34,651 |
| Minimum free heap, measured (normal, one outage) | | | 277,956, 278,304 | 276,672, 275,824 |
| Minimum free heap floor | | | 249,856 | 240,640 |
| Main stack remaining, measured (normal, one outage) | | | 7,308, 7,308 of 36,864 | 7,700, 7,700 of 36,864 |
| Main stack remaining floor | | | 6,144 | 6,144 |
| Recovery from a 20 s carrier outage | | | session ended 5.3 s after the stop; advertised again 2.0 s after the carrier returned | session ended 1.9 s after the stop; advertised again 0.7 s after the carrier returned |
| Six outages in one boot: slowest re-advertise; free heap after the first and the sixth | | | 2.5 s; 283,272 and 283,184 | 2.8 s; 280,528 and 279,900 |
| Firmware SHA-256 (credentialed image) | | | `0ea3173a24c6593aa1aa3854c73a1568233103a6254681da5b968afb7d49e291` | `ac0d88c6f9a83c45f1055c99c48a63abe938ff5fe2cf8bb0135443310f017d2b` |

The smoke columns are build budgets set from the smoke images (see above), not
measurements of the production application. The sensor-node columns repeat the
`profile.json` budgets next to the measurement they came from.

Application state: the `State` of the application is 6,661 B (from `nm` on the
ELF, both profiles), so `applicationStateBytes` is 7,168 (7 KiB).

### Stack: the 16 KB target was evaluated and is not met

[#63](https://github.com/phynics/axoloty-embedded/issues/63) asks for a main
stack of at most 16 KB for the production application. The measurement says the
node needs more. The main task stack is 36 KiB (36,864 B) in
`sdkconfig.production`, which leaves about 7 KB at the measured peak. Peak use by
stage, read by painting the stack (about 0.1 KB of error), on the device runs at
a 32 KiB stack:

| Stage | Peak used (Zenoh) | Peak used (MQTT) |
|---|---|---|
| Application `State` global initialization | 15,000 B | 5,200 B |
| `nvs`, Wi-Fi and network preparation | 22,900 B | 22,900 B |
| First inbound frame inside Core's `runtime.receive` | 29,400 B | 29,800 B |

Reaching 16 KB would need a change to Core's receive path and to the platform's
Wi-Fi bring-up. Neither belongs to this application. The target is evaluated and
not met; the budget is the measured value, not the target.

### Readings use the Channel family

The processor rejects a repeated Advertise of an announced object as a duplicate.
A reading is therefore a Channel publish, not a second Advertise.

### Recovery

Both transports reconnect after the router or broker is stopped for about 20 s
and restarted, without a device restart. The recovery runs show `sensor-node-session-ended`,
then `sensor-node-advertised` again, with readings continuing and no
`sensor-node-restart`. The carrier previously rejected a connect after a close
(Zenoh, MQTT), so the first recovery attempts failed; both transports now accept a
new session after a close. Network cleanup followed by network prepare in the same
boot works. The evidence is in `docs/evidence/<profile>-sensor-node-recovery.json`.

**Repeated outages.** The carrier was also taken down six times in one boot
(`SENSOR_OUTAGE_CYCLES=6`, 20 s each), past the old subscription capacity of 4 in
the MQTT carrier. The node ended its session, advertised again after every
outage with no device restart, and a second host observer completed a Discover
and read three readings after each return. Free heap after each cycle stayed flat
(MQTT 283,272 to 283,184 B; Zenoh 280,528 to 279,900 B), so no leak shows, and the
minimum free heap (278,304 and 272,040 B) and stack remaining (7,308 and
7,700 B) stayed above the floors. The evidence is in
`docs/evidence/<profile>-sensor-node-recovery-cycles.json`. The MQTT carrier now
also resets its will, subscriptions and reconnect baseline on disconnect.
The run script refuses a placeholder or unconfigured image before flashing.

### Other notes

- **F2.** zenoh-pico's `executor.c` reports `sleeping_idx` as possibly
  uninitialized at `-Os`. It is a false positive: the pop that writes it follows
  a non-empty peek. The component CMake keeps the warning and applies
  `-Wno-error=maybe-uninitialized` to that one file.
- **Specialization.** Each production ELF holds one specialization of the
  `StaticRuntime` hot path (`StaticRuntime<2, 512>`) and one of
  `ProtocolProcessor` (`ProtocolProcessor<2>`). Unspecialized generic entry
  points (`<A>`, `<A, B>`) exist beside them. No other capacity appears.
- **Reachability.** From the host used for these runs the board reached the router
  on TCP 1883 but not on 7447. The firewall rule was not read, so the cause is not
  known. An operator picks a port the board can reach.
- **Not covered.** The deferred independence exercises (#79) and the D8/D9
  exercises were not run. The runtime evidence binds to the credentialed image,
  whose SHA-256 differs from the placeholder release image, so a release
  certificate that requires the `sensor-node-runtime` check for the release
  artifact stays unqualified until that binding is decided.

## F6: carrier buffers sized from the application's capacities

Part of [#63](https://github.com/phynics/axoloty-embedded/issues/63). Before F6
each carrier held its frames at the largest bound it could ever carry (256-byte
topic, 2,048-byte payload), whatever the application declared. The sensor node
declares 128 and 512 in `Applications/sensor-node/app.json`.

### What changed

- `Tools/validate-composition.py` writes the application's `maxTopicLength` and
  `maxPayloadSize` once, as a C header, a Swift enum and a CMake file. The MQTT
  and Zenoh carriers size their C and Swift storage to them, and the zenoh-pico
  component derives `FRAG_MAX_SIZE` from them (payload + key + 1 KiB for headers,
  rounded up to a KiB: 4,096 for the smoke bounds, 2,048 for the sensor node).
  `BATCH_UNICAST_SIZE` is unchanged.
- A transport declares `limits` in `transport.json`; configure fails when an
  application capacity exceeds the ceiling. Transports name no application.
- The smoke profiles keep 256 and 2,048. Their images grow or stay: MQTT image
  671,632 to 671,952 B (flash text +168 B, rodata +144 B, from the added event
  classification); Zenoh unchanged at 670,560 B. Both pass their budgets unchanged.
- ESP-MQTT receive and send buffers are sized to the largest legal packet, so a
  legal frame arrives in one event. A message beyond the bounds, or split across
  events, is dropped at its first event, counted once
  (`axoloty_mqtt_oversized_frame_count`) and logged at WARN. The session and the
  frames behind it are unaffected. For Zenoh, a frame beyond the composed bounds
  is dropped in the sample guard before it is queued and counted
  (`framesOversized`); the facade reports it once, the carrier counts it and keeps
  polling, and the session, the subscriptions and the frames behind it are
  unaffected. A peer that sends oversized frames cannot force a reconnect.
- The metrics line carries `readingLastUs`, `readingMaxUs`, `frameLastUs` and
  `frameMaxUs`. They are reported, never budgeted.
- `Tests/embedded/run-largest-frame.sh` proves on a board that the carrier moves
  a payload of exactly 512 bytes and a topic of exactly 128 bytes, and drops one
  byte more of either without losing the next frame. Records:
  `docs/evidence/<profile>-sensor-node-largest-frame.json`. MQTT: both oversize
  frames dropped and counted (2), no session end. Zenoh: the two oversize frames are not
  delivered, the session does not end, and the node answers a short Discover
  afterwards. (The records dated before this change show 2 session ends and 2
  Advertises for Zenoh; they describe the previous behaviour until the
  sensor-node evidence is rerun.)

### Before and after

Placeholder images with the network stack linked, same Core revision and
toolchain. Before is the figures recorded at the previous revision.

| | MQTT before | MQTT after | Zenoh before | Zenoh after |
|---|---|---|---|---|
| Image (placeholder) | 836,864 | 837,696 | 734,368 | 734,944 |
| Image (credentialed) | 836,928 | 837,760 | 734,416 | 734,992 |
| `.bss` | 50,339 | 36,003 | 35,675 | 34,651 |
| Static RAM | 155,448 | 141,112 | 140,288 | 139,264 |

MQTT `.bss` falls by 14,336 B: five event records (four queue slots and the
staging slot) each 1,664 B smaller, three topic/payload pairs (received, publish,
will) each 1,664 B smaller, and two subscription tables 512 B smaller each. Zenoh
`.bss` falls by 1,024 B: eight carrier slots hold a 128-byte key instead of 256.
Each Zenoh subscription's receive queue is also allocated on the heap at four
frames of key plus payload at the composed bounds, 6,656 B less per subscription
(derived from the source, not measured). The breakdown is from the source
constants and `nm`, and the totals match the measured `.bss`.

The sensor-node floors move with the new measurement: the MQTT minimum free heap
floor rises from 236,544 to 249,856 B (lowest measured 277,872 B across the
first pass, minus 10 percent, rounded down to the next KiB). The Zenoh floors and
the stack floors are unchanged by the same rule. The build budgets were recomputed
from the placeholder builds and equal the values in `profile.json`.

### What Core's fixed bound leaves unreduced

The Core-owned `ZenohFrameStorage` that the Swift carrier polls into is 256 bytes
of key and 2,048 bytes of payload whatever the composed bounds are. It is Core's
fixed inline storage and also holds the retained pending frame, so those 2,304 B
of `.bss` are not reduced here. This repository does not change Core.

### Timing

All figures are microseconds on the platform clock, read from the metrics line.
They are reported, not gated. The carrier publish time in both figures includes
the call into the network stack (lwIP, and for Zenoh the zenoh-pico session),
so it measures the node end to end, not the portable code alone. The frame
figure is the time from `runtime.receive` to the Resolve publish returning. A
normal run serves one Resolve, so its frame figure is a single sample; the
outage runs serve two and seven.

| Profile | Reading, last / max | Frame, last / max |
|---|---|---|
| `esp32c6-sensor-node-mqtt` | 3,544 / 5,218 (normal run); largest max over all runs 5,218 | 3,460 / 3,460 (normal run, one sample); largest max over all runs 3,490 |
| `esp32c6-sensor-node-zenoh` | 3,634 / 4,381 (normal run); largest max over all runs 4,893 | 4,043 / 4,043 (normal run, one sample); largest max over all runs 4,677 |

### Evidence notes

- The runtime, recovery, six-outage and largest-frame records for both profiles
  come from one board, the second board (MAC 40:4c:ca:ff:fe:4d:8c:e8), built at
  the firmware commit named above, and every record carries the SHA-256 of the
  image it ran (see the table). A first pass set the floors; a second pass at
  the floored commit produced the records in the repository.
- Five earlier runs failed before any of this. All five stopped at the carrier
  `connect` stage: the board joined Wi-Fi and answered ping but its TCP
  connection to the host on port 1883 timed out, and no SYN reached the host.
  The likely cause is a host firewall reload that removed the rule allowing
  inbound 1883; the rule set was not readable without root, so this is an
  inference. The runs were Zenoh normal, one outage, six outages and
  largest-frame, and MQTT normal. They were rerun unchanged once the port
  opened again, and none of them wrote a record.
- The development container image was missing from the local store and was
  pulled again from `ghcr.io/phynics/axoloty-embedded-dev:swift-6.4`, digest
  `sha256:95649588463be1f62c2453761c11e191ad29faf839aeaae4c58a317d5f930688`.
