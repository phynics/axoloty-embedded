# Wire parse time on ESP32-C6 under the production build configuration, 2026-11-01

Issue [#63](https://github.com/phynics/axoloty-embedded/issues/63), workstream F8. This is the Swift counterpart of [esp32c6-wire-parse-time.md](esp32c6-wire-parse-time.md), measured with the same benchmark on the same kind of image, but built with the `production` configuration (`Platforms/esp32c6-idf/sdkconfig.production`) instead of the default one. The production configuration changes C optimization from `-Og` to `-Os`, assertions from enabled to silent, and the default log level from info to warning. Swift objects are `-Osize` under both configurations (every Swift compile command in the 85 or 86 recorded per build is `-Osize`), so the Swift code is compiled the same way. Both images run the production `AxolotyWire` codec from Core `087bd9bb1bfb563d0347799245ea4dd43e509bc9` over the same 39 logical payloads (13 wire families) in the smoke application's benchmark corpus. The `sensor-node` production application has no corpus, so this uses the smoke application. It is not a measurement of `sensor-node`.

## Result

Mean time per corpus case, in microseconds, median of three runs per image. Each run reports the p50 and p95 of 30 timed batches, so a figure is a batch mean and not a per-message latency distribution. "Default" is the unmodified `origin/main` smoke image built under the default configuration. "Production" is the smoke image built under the production configuration with the three changes listed under Method. Every row's p50 and p95 differ by at most 0.05 percent within a run, and the three runs of one image agree to within 1 ns on every figure.

### `esp32c6-mqtt`, `coaty/3` JSON

| Step | Default p50 | Default p95 | Production p50 | Production p95 | p50 change | p50 ratio |
|---|---|---|---|---|---|---|
| Reader construction | 117.231 | 117.233 | 119.476 | 119.477 | +2.245 µs | 1.019 |
| DTO decode (reader plus DTO) | 142.629 | 142.631 | 145.402 | 145.403 | +2.773 µs | 1.019 |
| Decode then encode | 184.233 | 184.252 | 186.407 | 186.423 | +2.174 µs | 1.012 |
| Combined | 165.957 | 165.999 | 168.003 | 168.084 | +2.046 µs | 1.012 |
| Topic parse | 9.687 | 9.687 | 9.155 | 9.155 | -0.532 µs | 0.945 |
| Borrowed message | 10.298 | 10.298 | 9.771 | 9.771 | -0.527 µs | 0.949 |

### `esp32c6-zenoh`, `axoloty/1` CBOR

| Step | Default p50 | Default p95 | Production p50 | Production p95 | p50 change | p50 ratio |
|---|---|---|---|---|---|---|
| Reader construction | 62.072 | 62.072 | 62.053 | 62.054 | -0.019 µs | 1.000 |
| DTO decode (reader plus DTO) | 93.500 | 93.501 | 94.382 | 94.383 | +0.882 µs | 1.009 |
| Decode then encode | 123.653 | 123.668 | 123.802 | 123.818 | +0.149 µs | 1.001 |

The CBOR image reports zero for topic parse, combined and borrowed message, which means unmeasured, as in the earlier document.

What this says:

- On the CBOR image the production configuration changes the three timed steps by -0.03 to +0.9 percent.
- On the JSON image the production configuration is 1.2 to 1.9 percent slower on the four codec steps (+2.0 to +2.8 µs) and about 5 percent faster on topic parse and borrowed message (-0.5 µs), the two steps that take about 10 µs.
- The run-to-run spread is 1 ns, so these differences are not noise within one image. They are also small, and the measurement cannot attribute them to a configuration option. There is one build per configuration, and a different build of the same code moves code placement. The earlier document's default-configuration MQTT image (revision `5ab8ce2b`, reader 119.5 µs) differs from today's default-configuration control (reader 117.2 µs) by 1.9 percent, as much as the production-versus-default difference. On the CBOR image the earlier document and today's control agree to 0.1 µs.
- The codec timing under the production configuration is therefore within about 2 percent of the default configuration on this corpus, with a mixed sign. This measurement does not support a claim that the production configuration makes the Swift wire parse faster or slower.

### Control against the 2026-10-31 document

Same-day control (default configuration, `origin/main`, three runs) against the figures in [esp32c6-wire-parse-time.md](esp32c6-wire-parse-time.md), in microseconds:

| Step | JSON, 2026-10-31 | JSON, control | CBOR, 2026-10-31 | CBOR, control |
|---|---|---|---|---|
| Reader construction | 119.5 | 117.2 | 62.1 | 62.1 |
| DTO decode | 144.5 | 142.6 | 93.4 | 93.5 |
| Decode then encode | 186.7 | 184.2 | 123.6 | 123.7 |
| Combined | 167.0 | 166.0 | not measured | not measured |
| Topic parse | 9.7 | 9.7 | not measured | not measured |
| Borrowed message | 10.3 | 10.3 | not measured | not measured |

The control reproduces the earlier CBOR figures and reproduces the JSON figures to within 2 percent. The JSON images differ in firmware revision from the 31 October images (`5ab8ce2b` there, `a7053783` here, same Core), so the 2 percent is a bound on build-to-build movement for the default configuration, not a repeatability figure for one image.

### Memory at the end of the smoke run

Median of three runs, taken from the same completion records. The production images in this table have no network stack and a smaller static footprint than a production application, so these are not budgets.

| Metric | MQTT default | MQTT production | Zenoh default | Zenoh production |
|---|---|---|---|---|
| Free internal heap (B) | 228,204 | 241,504 | 234,420 | 247,752 |
| Minimum free internal heap (B) | 226,148 | 239,448 | 232,364 | 245,696 |
| Largest free internal block (B) | 200,704 | 212,992 | 208,896 | 221,184 |
| Main stack remaining (B) | 2,740 | 2,744 | 96,464 | 96,484 |
| Hot-path allocations | 0 | 0 | 0 | 0 |

The smoke application ran different protocols on the two images (JSON on MQTT, CBOR on Zenoh), so the stack remainders compare each profile only with itself.

## The smoke application fails under the unmodified production configuration

The first attempt built both smoke profiles with `"configuration": "production"` and the production sdkconfig as it stands (the only other changes were the stack size and the removed budgets). Both images flash and print the bootloader log, then print no application output at all. That build also linked the sizing-only placeholder network header, because a production build stages one when no operator header is given. Each image was flashed twice. Each run captured 38 or 39 serial lines, none from the application, and the validator reported `missing boot record`. In one MQTT run the monitor also printed a device-disconnected message, which the other three runs did not. A separate 40 s raw capture after a reset of the MQTT image showed the same: the log ends after the `spi_flash` warning.

The cause is the allocator instrumentation, which `sdkconfig.production` removes (`CONFIG_HEAP_TRACING_OFF=y`). From the source:

- `Applications/device-smoke-agent/main/EmbeddedApplication.swift` declares `@EmbeddedApplication(traceFirstInitialization: true)`. The generated `axoloty_application_main` calls `platform.beginHeapTrace()` before it runs the application and returns a trace status when that throws.
- Without `CONFIG_HEAP_TRACING_STANDALONE`, `axoloty_heap_trace_begin` in `Platforms/esp32c6-idf/main/log_helper.c` returns failure.
- `app_main` discards the status, so the application never runs and prints nothing.

I did not read the returned status on the device. What I observed is that an image identical to the failing Zenoh image except for `CONFIG_HEAP_TRACING_STANDALONE=y` printed the boot record and ran the corpus. That image still failed the validator for a second reason, below, so this was one run and not a qualification.

The second reason: a build with `"configuration": "production"` and no operator header stages the sizing-only placeholder network header, which makes the smoke application run its carrier probe after the corpus. The probe adds eleven `network:*` cases (eight failing, two unsupported, one passing) with the placeholder SSID, and `validate-smoke.mjs` rejects them as unknown case identifiers (`unknown case identifier: network:wifi`). The corpus metrics still appear in the completion record of that run (p50 reader 62.037 µs, DTO decode 94.368 µs, decode then encode 121.602 µs; one run, not part of the tables above, and the encode figure is 1.8 percent below the measured Zenoh image's, which has no network stack).

A smoke application that should run under the production configuration needs the heap trace requirement, or the first-initialization trace, to be conditional on the configuration, and a way to build the smoke image without the placeholder header. Neither is in this change.

## Method

- Firmware revisions. Control: `origin/main` at `a70537837ee5db550bd50f96f61708fc84e5775d`, clean, in a fresh clone. Production: that revision plus a local throwaway commit that was never pushed. Core `087bd9bb1bfb563d0347799245ea4dd43e509bc9` for every image, built through the pinned `axoloty-embedded-dev` container (image `9006ed8fa429`, digest `sha256:95649588463be1f62c2453761c11e191ad29faf839aeaae4c58a317d5f930688`), Swift 6.4, ESP-IDF 5.4.
- The throwaway commit made these changes to the measurement images:
  - `Profiles/esp32c6-mqtt/profile.json` and `Profiles/esp32c6-zenoh/profile.json`: `"configuration": "production"` and `budgets` removed, so the size gate does not interfere.
  - `sdkconfig.production`: `CONFIG_ESP_MAIN_TASK_STACK_SIZE=131072` (production uses 36,864), because the smoke application needs the 128 KiB that the default configuration gives it.
  - `sdkconfig.production`: `CONFIG_HEAP_TRACING_STANDALONE=y` instead of `CONFIG_HEAP_TRACING_OFF=y`, for the reason in the section above.
  - `Platforms/esp32c6-idf/tools/build.sh`: the staged network header placeholder was made optional, and the measured images were built without it, so they link no Wi-Fi or TCP/IP stack and run no carrier probe.
- The measured production images therefore differ from the default images in the settings below and in no others. The stack size, heap tracing and absence of a network header match the default images.
  - C optimization `-Og` to `-Os`, assertions enabled to silent, default log level info to warning.
  - The production configuration's feature removals (`CONFIG_ESP_WIFI_SOFTAP_SUPPORT`, `CONFIG_ESP_WIFI_ENABLE_WPA3_SAE`, `CONFIG_ESP_WIFI_ENTERPRISE_SUPPORT`, `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE`, `CONFIG_MQTT_TRANSPORT_SSL`, `CONFIG_MQTT_TRANSPORT_WEBSOCKET`). I did not check whether any of them reaches the timed Swift passes.
- Images, all built from a clean tree (`dirty: false`):

| Image | Revision | Size (B) | SHA-256 |
|---|---|---|---|
| MQTT default (control) | `a7053783` | 671,632 | `c09f96feabd6bb5c4ed3096d7084ab1bea6d48cf11e486f90dd857120d5db515` |
| MQTT production, measured | throwaway `5b7b308a` | 610,304 | `42934df7dea2fdcd8dc21398d05147f224dca753a12b15ca9584f9f6bcb0a5c3` |
| Zenoh default (control) | `a7053783` | 670,560 | `a2112f9acdbf003b9802d4c55516c95322b0749d1b43789ef278345e80177461` |
| Zenoh production, measured | throwaway `5b7b308a` | 554,800 | `d9ee0b28b7b3114a10954e8d68bbb18f493ca0ffa20dd596b7536905d1bb0731` |
| MQTT, unmodified production configuration (fails) | throwaway `70bfd49b` | 1,115,152 | `6fa0a1387b29774eb368d915356936876323b49dc9e1f44d9da07ccc5ed287d3` |
| Zenoh, unmodified production configuration (fails) | throwaway `70bfd49b` | 847,600 | `8d0ffb09e891410bdc2d2fc247ec1ea1d21bdd7e600f3bf311314cc63bb03d5b` |
| Zenoh, production plus heap tracing, placeholder header | throwaway `5b7b308a` | 848,704 | `3b163cef991c55afcdff3c9110d5f64629c91ab07e02ed7d4873068b1b19e4fe` |

- The sdkconfig SHA-256 recorded in the size reports is `c0ceb580cd73…` for the default images and `37504016dbdc…` for the measured production images.
- Each image was flashed with `Platforms/esp32c6-idf/tools/flash.sh`, the step that `Profiles/<name>/qualify.sh` runs, and its serial smoke protocol was validated by `validate-smoke.mjs`. `qualify.sh` was not used, because its last step writes a qualification record under `docs/evidence/`, and a measurement run must not write one. No file under `docs/evidence/` other than this document was written. Every run re-flashed the board.
- Three runs per combination, 12 measured runs in all (default and production, MQTT and Zenoh). All 12 passed validation: 312 of 312 checks on MQTT and 56 of 56 on Zenoh. The metrics come from the `metrics` object of the completion record in each serial log.
- Timing is the benchmark of the earlier document: 1,000 warm-up passes, the batch size doubles until a batch takes at least 250 ms, the loop overhead is measured and subtracted, 30 samples over the 39-case corpus with no serial I/O inside the timed window. The reported p50 is the 15th and the p95 the 29th of the 30 sorted samples.
- Board: one ESP32-C6 (MAC `40:4c:ca:ff:fe:4e:52:dc`), CPU 160 MHz, flash 80 MHz, 2026-11-01. The control and the production images ran on it the same day.

## Limits

- One board, one build per image, three runs of each. The runs are re-flashes of the same binary, so the 1 ns spread says nothing about build-to-build variation. The comparison with the 31 October document is the only evidence on that, and it shows up to 2 percent.
- This is the smoke corpus, not `sensor-node` and not live traffic. It has no object with a payload above 511 bytes.
- The measured production images are not production images. They keep the 128 KiB main stack and heap tracing of the default configuration, have no network stack, and carry the smoke harness. The unmodified production configuration does not run the smoke application at all (above). Nothing here is a budget.
- The timing is the codec on borrowed, in-memory payloads. It excludes the transport, the receive path of Core's runtime (phynics/axoloty#1061), and any work with the network stack running.
- CBOR payloads come from this repository's encoder, as in the earlier document.
- The image size and static RAM differences between the default and measured images are not analysed here. The size and memory figures that count are in [resource-budgets.md](../resource-budgets.md).
