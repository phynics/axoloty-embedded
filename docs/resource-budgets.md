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
| `esp32c6-sensor-node-mqtt` | 836,832 B | 836,912 B | 80 B (all `.flash.rodata`, plus 2 B `.flash.text`) |
| `esp32c6-sensor-node-zenoh` | 734,336 B | 734,400 B | 64 B (all `.flash.rodata`, plus 2 B `.flash.text`) |

Static RAM and `.bss` are identical. The budgets below leave 10 percent, far
more than this difference.

### Per-profile table

Core revision `087bd9bb1bfb563d0347799245ea4dd43e509bc9` for every row.
Sizes in bytes. Measured on one ESP32-C6 (unit MAC 40:4c:ca:ff:fe:4e:52:dc),
Embedded Swift 6.4, ESP-IDF 5.4.

| | Smoke `esp32c6-mqtt` | Smoke `esp32c6-zenoh` | Sensor node MQTT | Sensor node Zenoh |
|---|---|---|---|---|
| Network stack linked | no | no | yes | yes |
| Configuration | default | default | `production` | `production` |
| sdkconfig SHA-256 | not recorded in the budget | not recorded in the budget | `3e14e6acd8df3ff2a35dd6d13aeba1a687787f388a71d0b85765e787e82378bc` | same |
| Image (build budget) | 739,328 | 738,304 | 920,576 | 807,936 |
| Flash text (build budget) | 553,984 | 544,768 | 713,728 | 636,928 |
| Static RAM (build budget) | 180,224 | 174,080 | 171,008 | 154,624 |
| `.bss` (build budget) | 82,944 | 76,800 | 56,320 | 39,936 |
| Image, measured (placeholder) | | | 836,832 | 734,336 |
| Flash text, measured | | | 648,354 | 578,216 |
| Static RAM, measured | | | 155,448 | 140,288 |
| `.bss`, measured | | | 50,339 | 35,675 |
| Minimum free heap, measured (normal, recovery) | | | 264,912, 263,216 | 269,424, 266,076 |
| Minimum free heap floor | | | 236,544 | 238,592 |
| Main stack remaining, measured (normal, recovery) | | | 7,340, 7,340 of 36,864 | 7,592, 7,732 of 36,864 |
| Main stack remaining floor | | | 6,144 | 6,144 |
| Recovery from a 20 s carrier outage | | | session ended 5.3 s after the stop; advertised again 2.2 s after the carrier returned | session ended 2.0 s after the stop; advertised again 0.75 s after the carrier returned |

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
