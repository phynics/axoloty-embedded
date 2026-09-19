# Transports/zenoh-pico

The embedded Zenoh transport ([axoloty-embedded#4], re-scoped by
[axoloty#853], part of epic [axoloty#796]). It owns the device side of the
Zenoh transport: the bounded client, the `zenoh-pico` backend, ESP-IDF backend
wiring, embedded route/subscription wiring, and device resource qualification.

Host and shared Zenoh work stays in `phynics/axoloty`: the portable facade
contract, `AxolotyZenohCore`, the `zenoh-c` host backend, the host runtime
transport, and host parity.

## What is here

| File | Owns |
|---|---|
| `main/EmbeddedZenohClient.swift` | The bounded, synchronous, non-allocating client surface: open, subscribe, publish, poll, unsubscribe, close. Borrowed key/payload buffers with explicit lengths, consumed synchronously and never retained. |
| `main/zenoh_carrier.h` | The device carrier C seam the client calls. Carrier mechanics only. |
| `main/zenoh_sample_validation.{h,c}` | The byte-bound guard the `zenoh-pico` sample callback runs before copying an inbound sample into the bounded queue. |
| `main/idf_sources.cmake` | Declarative source list the platform includes. No build logic, no protocol rule. |

The host-only seam test lives at `Tests/embedded/run-zenoh-host-test.sh` and
runs in the `build` tier.

## What is not here yet

These need the `zenoh-pico` dependency or an Axoloty-owned contract that has
not landed, so they are deliberately absent rather than stubbed. They are
proposed as issues in [docs/proposed-issues.md](../../docs/proposed-issues.md).

- **The `zenoh-pico` backend** implementing the `axoloty_zenoh_*` carrier seam
  against the portable facade ABI. The facade ABI itself is Axoloty's
  (`#801`/`#802`/`#803`). Needs the pinned dependency.
- **The ESP-IDF component wrapper** under
  `Platforms/esp32c6-idf/components/zenoh_pico/`. The pin is recorded and the
  wrapper was reconciled against the fetched pinned tree, but it cannot be
  configured or compiled without an ESP-IDF toolchain.
- **The application carrier seam.** `runCarrierNetworkProbe` /
  `emitAgentExchange` in the MQTT transport are MQTT-shaped and the application
  calls them directly. A Zenoh image cannot link until the application seam is
  made transport-neutral and given a carrier locator. That is `#816`/`#817`
  work and is not done here.
- **Device qualification.** Needs a board, a broker, and the backend.

See [docs/zenoh-embedded.md](../../docs/zenoh-embedded.md) for the ownership
split, the pinned revision, and the tuning values.

[axoloty-embedded#4]: https://github.com/phynics/axoloty-embedded/issues/4
[axoloty#853]: https://github.com/phynics/axoloty/issues/853
[axoloty#796]: https://github.com/phynics/axoloty/issues/796
