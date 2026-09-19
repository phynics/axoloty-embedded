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
| Portable/shared Zenoh contracts, the `axoloty_zenoh_*` facade ABI | `phynics/axoloty` | Not landed (`#801`/`#802`/`#803`) |
| `AxolotyZenohCore` (Embedded-Swift-safe Swift types over the facade) | `phynics/axoloty` | Not landed |
| `zenoh-c` host backend | `phynics/axoloty` | Not landed |
| `AxolotyZenoh` host runtime transport, host parity | `phynics/axoloty` | Not landed |
| `EmbeddedZenohClient` (bounded device client) | here | Skeleton landed |
| `zenoh-pico` backend of the facade | here | Not landed (proposed) |
| ESP-IDF component wiring for pinned `zenoh-pico` | here | Pin landed; wrapper configures and compiles the pinned tree (proposed) |
| Embedded route/subscription wiring | here | Not landed (proposed) |
| Device/resource qualification | here | Not landed; needs a board (proposed) |

The carrier seam in `Transports/zenoh-pico/main/zenoh_carrier.h` is the device
specialization. It declares the operations `EmbeddedZenohClient` calls. The
public facade ABI is Axoloty's; when `#801`/`#802`/`#803` land, these
declarations are the single place to reconcile.

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
wrapper reads only that report, mirroring `Tools/prepare-core.sh`.

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

## Bounds

`EmbeddedZenohClient` and `zenoh_sample_validation.c` use the same byte bounds
as the MQTT transport and `AxolotyWire`: a key of at most 256 bytes and a
payload of at most 2048 bytes. The constants are duplicated in the client
(production reads `AxolotyWire`; the host overlay restates them) and in the C
guard, so a future change must move both. A zero-length payload is a legal
sample; a null pointer with a non-zero length is not.

## Ambiguities and honest gaps

- **The facade ABI does not exist yet.** The carrier declarations are written
  against the operations the embedded client needs, not against a landed
  header. That is a genuine ambiguity: `#814` cannot implement the backend
  until `#801`/`#802`/`#803` define the portable contract.
- **The application carrier seam is MQTT-shaped.** The application calls
  `runCarrierNetworkProbe` and `emitAgentExchange`, which the MQTT transport
  defines, and the `DeviceSmokeSeam` has no carrier-locator operation. A Zenoh
  image cannot link until that seam is generalized. Generalizing it is `#816`/
  `#817` work. No probe was written for Zenoh because writing one now would be
  a stub with a fabricated endpoint source.
- **The platform network bootstrap still owns MQTT.** `network_bootstrap.c`
  brings up Wi-Fi and ESP-MQTT together. The transport source selection
  (`main/idf_sources.cmake`) composes the Swift carrier surface, but a real
  Zenoh image also needs the platform's Wi-Fi bring-up separated from the
  carrier. That split is a platform change and is flagged, not attempted here.
- **The component wrapper compiles the pinned tree; the profile image does not
  link yet.** With the report from `Tools/prepare-zenoh-pico.sh`, the wrapper
  configured and compiled the pinned `zenoh-pico 1.10.0` sources for
  `esp32c6` in the pinned container: 132 C objects, zero compiler errors,
  `libzenoh_pico.a` produced. Two wrapper assumptions needed fixing, both
  found by that first real build: the revision check used a CMake regex
  syntax (`{40}`) that `MATCHES` does not support, and `CONFIGURE_DEPENDS` is
  invalid in the requirements pass. The image then fails at the two seams
  above, not in this component: `platform/main/network_bootstrap.c` includes
  `mqtt_event_validation.h`, and the application calls
  `runCarrierNetworkProbe`/`emitAgentExchange`, which only the MQTT transport
  defines. Both are #816/#817 work, deliberately not attempted here.
- **No device or resource evidence.** None was produced and none was invented.
  See `docs/evidence/esp32c6-zenoh-*.json`.
- **The release manifest does not know the Zenoh backend.** 
  `Platforms/esp32c6-idf/tools/write-release-manifest.mjs` maps
  `transport.backend` only for `mqtt-espidf` and reads the backend version from
  the `idf` entry of `dependencies.lock`. A built Zenoh profile would therefore
  record the SDK version as its backend version. That generator is release
  provenance work (`axoloty-embedded#3`) and is left untouched here; the
  concrete gap is recorded so the profile can never be certified on a field no
  producer computes.
