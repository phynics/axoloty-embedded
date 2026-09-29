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
| `main/EmbeddedZenohClient.swift` | The bounded, synchronous, non-allocating client surface: open, subscribe, publish, poll, unsubscribe, close, over the Core facade ABI. Borrowed key/payload buffers with explicit lengths, consumed synchronously and never retained. |
| `main/zenoh_pico_facade.c` | The `zenoh-pico` backend of the Core-owned `axoloty_zenoh_*` ABI. Zenoh calls in, bounded bytes out, no retained pointer. |
| `main/zenoh_pico_queue.{h,c}` | The fixed session and subscriber registries, the bounded receive queue, its drop counters, and the generation token that rejects a late callback. No Zenoh and no SDK header, so the host seam checks it with no board. |
| `main/zenoh_sample_validation.{h,c}` | The byte-bound guard the `zenoh-pico` sample callback runs before copying an inbound sample into the bounded queue. |
| `main/idf_sources.cmake` | Declarative source list the platform includes, and the request for the Core facade include directory. No protocol rule. |

The C seam this transport compiles is Axoloty's, not a local declaration:
`axoloty_zenoh.h` comes from the prepared Core checkout through
`Tools/prepare-core.sh`, and the manifest fails closed when the prepared Core
does not carry it.

The host-only seam test lives at `Tests/embedded/run-zenoh-host-test.sh` and
runs in the `build` tier. It needs the Core facade header and reports a skip
without it.

## What is not here yet

These need a Core-owned contract that has not landed, or a transport-neutral
application seam, so they are deliberately absent rather than stubbed. They are
tracked as [axoloty-embedded#4] and its neighbors.

- **The application carrier seam.** `runCarrierNetworkProbe` /
  `emitAgentExchange` in the MQTT transport are MQTT-shaped and the application
  calls them directly. A Zenoh image cannot link until the application seam is
  made transport-neutral and given a carrier locator. That is `#816`/`#817`
  work and is not done here.
- **Device qualification.** Needs a board, a router, and the backend.
- **A portable Swift wrapper over the facade.** `AxolotyZenohCore` is Core's
  and has not landed; `EmbeddedZenohClient` is the firmware overlay that builds
  today.

See [docs/zenoh-embedded.md](../../docs/zenoh-embedded.md) for the ownership
split, the pinned revision, the Core contract dependency, the documented
`zenoh-pico` incompatibilities, and the tuning values.

[axoloty-embedded#4]: https://github.com/phynics/axoloty-embedded/issues/4
[axoloty#853]: https://github.com/phynics/axoloty/issues/853
[axoloty#796]: https://github.com/phynics/axoloty/issues/796
