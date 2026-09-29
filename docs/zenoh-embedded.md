# Embedded Zenoh ownership

The device side of the Zenoh transport: `zenoh-pico` integration, the embedded
Zenoh client, ESP-IDF backend wiring, embedded route/subscription wiring, and
device resource qualification. Tracked by
[axoloty-embedded#4](https://github.com/phynics/axoloty-embedded/issues/4),
re-scoped for the repository split by
[axoloty#853](https://github.com/phynics/axoloty/issues/853), part of epic
[axoloty#796](https://github.com/phynics/axoloty/issues/796).

## The split

| Concern | Repository | State |
|---|---|---|
| Portable/shared Zenoh contracts, the `axoloty_zenoh_*` facade ABI | `phynics/axoloty` | Landed (`#956`) |
| `AxolotyZenohCore` (Embedded-Swift-safe Swift types over the facade) | `phynics/axoloty` | Not landed |
| `zenoh-c` host backend | `phynics/axoloty` | Not landed |
| `AxolotyZenoh` host runtime transport, host parity | `phynics/axoloty` | Not landed |
| `EmbeddedZenohClient` (bounded device client) | here | Adapted to the facade ABI |
| `zenoh-pico` backend of the facade | here | Landed here (`#814`), compiles and links, not qualified |
| ESP-IDF component wiring for pinned `zenoh-pico` | here | Pin and wrapper landed; the wrapper publishes its platform profile |
| Embedded route/subscription wiring | here | Not landed (proposed) |
| Device/resource qualification | here | Not landed; needs a board (proposed) |

The C seam this repository compiles is Axoloty's:
`Packages/AxolotyZenoh/Sources/CAxolotyZenoh/include/axoloty_zenoh.h` in the
prepared Core checkout, reached through `Tools/prepare-core.sh`. Firmware
implements that ABI and restates none of it. The backend is
`Transports/zenoh-pico/main/zenoh_pico_facade.c`; the bounded receive state is
`zenoh_pico_queue.c`, which includes no Zenoh and no SDK header so the host seam
can check it without a board.

## Pin

`Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json`:

| Field | Value |
|---|---|
| Component | `eclipse-zenoh/zenoh-pico` |
| Version | `1.10.0` |
| Revision | `96006957fddef401c20c8c2d813c2a630b666974` |
| License | `Apache-2.0 OR EPL-2.0` |

The version and revision come from `phynics/axoloty` issue `#797` and its
`docs/dependencies/zenoh.md` (fetched branch `exploration/zenoh`). This
repository did not choose them and cannot verify them here. `#797` records the
`1.10.0` tag as an annotated tag object and gives the commit it points at; the
revision above is that commit. All three Zenoh components (`zenoh`, `zenoh-c`,
`zenoh-pico`) ship as one release train and must move together, so this pin
must move whenever the host `zenoh-c` pin in Axoloty moves.

`Tools/prepare-zenoh-pico.sh` fetches that exact revision into scratch and
writes `zenoh-pico-preparation.json`. The build never fetches; the component
wrapper reads only that report, mirroring `Tools/prepare-core.sh`. The
`esp32c6-zenoh` image build therefore needs `AXOLOTY_ZENOH_PICO_REPORT` in the
environment, and the wrapper fails closed without it.

## The Core contract dependency

The facade header is Core-owned, and the lock is still below it.
`axoloty-core.lock.json` pins `0579663a` (v0.8.2), which predates the facade:
Core PR `#956` (`58edd3ce`) added the header, the portable Swift wrapper, and
the host backend. Nothing here changes the lock.

The Core preparation report at the locked revision has no Zenoh entry, and the
report at `58edd3ce` still does not either: it carries `core`, `swift`,
`portablePackages`, `jsonCore`, and `staticRuntimeMacro`, and no
`zenohCore.facadeHeader`. The report is the supported channel, so
`Platforms/esp32c6-idf/cmake/axoloty-source.cmake` reads `zenohCore.facadeHeader`
and its `facadeHeaderSHA256` when the report carries them, and otherwise
resolves the header inside the prepared checkout at the one Core-relative path
that holds it. The SHA-256 is verified whenever the report publishes one.

Two consequences, both deliberate:

- **The Zenoh image needs a Core revision that carries the header.** Building
  `esp32c6-zenoh` today means preparing an off-lock candidate with
  `AXOLOTY_PREVIEW_CORE_REVISION`, which is explicitly not a compatibility
  claim. The lock moves when Core lands `zenohCore.facadeHeader`.
- **Failing closed is scoped to the selected transport.** The resolver never
  fails a profile that did not select Zenoh, and
  `Transports/zenoh-pico/main/idf_sources.cmake`, which is read only when this
  transport is selected, fails with a message that names the missing Core
  contract. The other profile still builds at the lock.

`Tools/check-invariants.sh` enforces both halves: the resolver must read the
report field, verify the checksum, and publish the include directory, and the
manifest must request it, name the header, and fail closed.

## v1 feature profile and tuning

Carried from `#797`'s qualification, not re-measured here:

- client mode over TCP, publication and subscription only;
- query, queryable, liveliness, matching, advanced publication/subscription,
  scouting, multicast, and peer mode disabled;
- serial, Bluetooth, WebSocket, and TLS links disabled;
- `FRAG_MAX_SIZE` and `BATCH_UNICAST_SIZE` reduced from `4096`/`2048` to
  `1024` each;
- `Z_RUNTIME_MAX_TASKS` reduced from `64` to `8`;
- `esp_driver_uart` required even with serial links disabled.

These are a starting point, not a measured optimum. The qualification issue
sets the final numbers.

The wrapper publishes `ZENOH_ESPIDF`, `ZENOH_C_STANDARD`, and `Z_BUILD_LOG` and
requires `esp_driver_uart` **publicly**, not privately: zenoh-pico's ESP-IDF
platform header selects the platform through those definitions and includes
`driver/uart.h`, so a component that includes a zenoh-pico header needs the
same profile as the compiled library. A private definition compiles the library
and leaves every consumer on `#error "Unknown platform"`.

## Bounds

The facade bounds come from Core and are not restated here. The device client's
own limits mirror the MQTT transport and `AxolotyWire`: a key of at most 256
bytes and a payload of at most 2048 bytes. The constants are duplicated in
`EmbeddedZenohClient.swift` (production reads `AxolotyWire`; the host overlay
restates them), in `zenoh_sample_validation.c`, and in the C guard
`axoloty_zenoh_sample_is_valid` the callback runs, so a future change must move
all of them. A zero-length payload is a legal sample; a null pointer with a
non-zero length is not.

Per subscription, the backend allocates one bounded queue of four frames
(`AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY` frames of a 256-byte key and a 2048-byte
payload) when the subscription is declared and releases it on removal. The
steady state neither allocates nor blocks: the callback copies into that queue
and returns. A full queue drops the newest frame, an oversized frame is dropped
rather than truncated, and both counters are cumulative per subscription.

## zenoh-pico incompatibilities

These are real differences between the facade contract and what pinned
`zenoh-pico 1.10.0` can do. None of them is hidden behind a special case in the
backend; each is visible in the code or in a returned result code.

- **The fixed five-second unicast open is an acceptance check, not a
  cancellation.** The contract bounds a single unicast link open. In this
  feature profile zenoh-pico's stable API compiles out
  `Z_CONFIG_CONNECT_TIMEOUT_KEY` (`Z_FEATURE_UNSTABLE_API` is 0), and the
  compiled bounds are `Z_CONFIG_SOCKET_TIMEOUT` (100 ms) for one link attempt
  and `Z_TRANSPORT_CONNECT_TIMEOUT` (10 s) for the handshake. The backend
  measures `z_open` and closes the session and reports
  `AXOLOTY_ZENOH_TRANSPORT_ERROR` when the call did not return inside the
  deadline, so no session is ever handed back late. It cannot interrupt a call
  that is already blocking.
- **Client mode requires a connect endpoint.** The contract allows a client
  session with no endpoint, relying on Zenoh scouting. zenoh-pico's
  `_z_open_locators_client` fails with `_Z_ERR_CONFIG_LOCATOR_INVALID` when no
  connect locator is configured, and the v1 profile compiles scouting out
  entirely. The backend forwards the configuration unchanged, so such an open
  fails as `AXOLOTY_ZENOH_TRANSPORT_ERROR`. Nothing in the backend special-cases
  it.
- **The connected-router count is 0 or 1.** The contract counts routers through
  a per-router callback. `z_info_routers_zid` is implemented for a unicast
  client transport by walking the single unicast link, so the count is 1 while
  that link is up and 0 otherwise. The backend counts the callback invocations
  exactly as the contract describes, and a router-less peer session reports 0.
- **Multicast scouting is a no-op in this profile.** The contract carries the
  flag. The backend inserts it into the Zenoh configuration, and
  `Z_FEATURE_SCOUTING` and `Z_FEATURE_LINK_UDP_MULTICAST` are 0 in the pinned
  profile, so Zenoh ignores it. The backend does not pretend otherwise.
- **A late callback is rejected by generation, not by Zenoh.** zenoh-pico
  exposes no "wait for callbacks" primitive. The backend deactivates the
  subscriber, undeclares it, and then waits with a bounded spin for the
  callbacks that are already copying before it releases the queue, which is the
  synchronization the contract describes. A callback that Zenoh dispatches after
  the undeclare returns is outside what its API can exclude.

## What builds, and what is still blocked

- `Tools/verify.sh --tier repo` passes.
- `Tests/embedded/run-zenoh-host-test.sh` passes with the prepared Core: it
  compiles the real client, the real validator, and the real bounded queue
  against a host-only fake carrier, and it runs the queue and counter
  conformance, the sample-validator vectors, and the facade contract's
  close/state/foreign-handle behaviour. It needs the Core header
  (`AXOLOTY_ZENOH_FACADE_INCLUDE_DIR` or `AXOLOTY_SOURCE_DIR`) and reports 69
  without it, which is a skip, not a pass.
- The `esp32c6-zenoh` C backend compiles for `esp32c6` against pinned
  `zenoh-pico 1.10.0` with no warnings, and a relocatable link of the backend
  objects against `libzenoh_pico.a` leaves no undefined Zenoh symbol. It
  defines all eleven `axoloty_zenoh_*` entry points.
- **The image does not link.** The Swift application seam is still MQTT-shaped:
  `DeviceSmokeApplication.swift` calls `runCarrierNetworkProbe` and
  `Esp32c6SmokeSeam.swift` wires `embeddedExchangeConfigureLastWill`,
  `embeddedExchangeConnect`, `embeddedExchangeSubscribe`,
  `embeddedExchangeUnsubscribe`, `embeddedExchangePublish`,
  `embeddedExchangePollOneEvent`, `embeddedExchangeWaitForReconnect`, and
  `embeddedExchangeDisconnect`. Only the MQTT transport provides them. Those
  operations are last-will setup, a reconnect check, and a network probe, which
  a Zenoh image has to answer with Zenoh semantics or not at all. That is
  #816/#817 work and is deliberately not attempted here.
- **No device or resource evidence.** None was produced and none was invented.
  See `docs/evidence/esp32c6-zenoh-*.json`.

## Ambiguities and honest gaps

- **The portable Swift wrapper is still Core's to land.** `AxolotyZenohCore`
  will be the Swift side of this ABI. `EmbeddedZenohClient` is the firmware
  overlay the device builds today; when the Core wrapper lands, one of them is
  redundant and the reconciliation is a Core decision, not this repository's.
- **The release manifest does not know the Zenoh backend.**
  `Platforms/esp32c6-idf/tools/write-release-manifest.mjs` maps
  `transport.backend` only for `mqtt-espidf` and reads the backend version from
  the `idf` entry of `dependencies.lock`. A built Zenoh profile would therefore
  record the SDK version as its backend version. That generator is release
  provenance work (`axoloty-embedded#3`) and is left untouched here; the
  concrete gap is recorded so the profile can never be certified on a field no
  producer computes.
- **A profile claims its Core revision only with device evidence.** The Zenoh
  profile's `core.revision` is the lock, which is below the facade. No build in
  this repository can qualify the Zenoh profile at the lock until Core publishes
  `zenohCore.facadeHeader` and the lock is raised.
