# Transports/zenoh-pico

The embedded Zenoh transport ([axoloty-embedded#8], part of the split epic
[axoloty#845]). It owns the device side of the transport: the bounded session
adapter, `zenoh-pico` facade backend, router endpoint helper, carrier-specific
network probe, and ESP-IDF composition metadata. It owns carrier mechanics
only; the application owns protocol behavior and route interest.

Host and shared Zenoh work stays in `phynics/axoloty`: the portable facade
contract, `AxolotyZenohCore`, the `zenoh-c` host backend, host runtime
transport, and host parity.

## What is here

| File | Owns |
|---|---|
| `main/ZenohCarrier.swift` | A bounded, synchronous adapter over Core's `ZenohSession` and `ZenohFrameStorage`: open, up to eight subscriptions, publish, poll, unsubscribe, reconnect observation, and close. Borrowed bytes are consumed synchronously. No callback enters Swift. |
| `main/ZenohNetworkProbe.swift` | Zenoh-specific network probe mechanics. It records broker last-will and single-client loopback receive as explicitly unsupported; it does not emit a pass for either. |
| `main/zenoh_pico_facade.c` | The `zenoh-pico` backend of Core's `axoloty_zenoh_*` ABI. Zenoh calls in, bounded bytes out, no retained caller pointer. |
| `main/zenoh_pico_queue.{h,c}` | Fixed session and subscriber registries, bounded receive queues, drop counters, and generation tokens that reject late callbacks. No Zenoh or SDK header, so host tests check it without a board. |
| `main/zenoh_sample_validation.{h,c}` | Byte-bound guard used before the `zenoh-pico` callback copies a sample into the bounded queue. |
| `main/zenoh_endpoint.{h,c}` | Copies the private operator router host/port configuration into caller storage. It validates the resulting bounded printable endpoint before session open. |
| `main/idf_sources.cmake` | Declarative source list and requests for the prepared Core facade and session modules. It contains no protocol rule. |

The C facade header and `AxolotyZenohCore` sources come from the prepared Core
checkout through `Tools/prepare-core.sh` and its report. The ESP-IDF component
compiles those sources in place; it does not copy Core source. The component
also uses the report-generated module map for the Core-owned `CAxolotyZenoh`
facade module. Both consumers fail closed when the prepared Core does not
publish the required artifacts.

The production host test lives at `Tests/embedded/run-zenoh-host-test.sh` and
runs in the `build` tier. It compiles the same carrier/probe sources and Core
session sources used by the firmware against a deterministic host facade. It
checks operation order, bounds, multiple profile-interest shapes, queue
handling, explicit unsupported results, router polling deadlines, and errors.
It does not build or link `zenoh-pico`.

## Observable profile limits

- The application installs the same two profile-interest shapes as Core's host
  binding: `coaty/3/<namespace>/*/*` and
  `coaty/3/<namespace>/*/*/*`. The application passes them as borrowed key
  expressions; the transport does not interpret them.
- The v1 client profile has no broker last-will. `configureLastWill` returns
  failure and the probe emits `network:lastWillUnsupported`; it does not
  substitute a normal deadvertise for crash semantics.
- The profile disables local delivery of a session's own publications. The
  single-client probe emits `network:receiveUnsupported` rather than claiming
  loopback. The two-participant exchange is where bidirectional delivery is
  checked.
- Reconnect observation polls the real session's router count until the
  supplied deadline. It succeeds when the open session observes a router; it
  does not close or reopen the session. An already-connected observation is
  connectivity, not evidence of recovery. A recovery claim needs an observed
  loss and restoration plus subscriptions and bidirectional traffic on a
  physical device.
- A configured endpoint is `tcp/<host>:<port>`. The network-config generator
  accepts `AXOLOTY_ZENOH_HOST` and `AXOLOTY_ZENOH_PORT` (default port `7447`);
  absent an explicit Zenoh host, the configured host is reused as the router
  address.

Device qualification still needs a physical board and router. No hardware
result is inferred from a host test or image build.

See [docs/zenoh-embedded.md](../../docs/zenoh-embedded.md) for the ownership
split, pinned revision, Core contract, documented `zenoh-pico` differences,
build results, and qualification gaps.

[axoloty-embedded#8]: https://github.com/phynics/axoloty-embedded/issues/8
[axoloty#845]: https://github.com/phynics/axoloty/issues/845
