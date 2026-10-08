# axoloty-embedded

Concrete embedded firmware products built on [Axoloty](https://github.com/phynics/axoloty).

This repository owns firmware composition and physical-device qualification.
Axoloty owns the portable protocol and runtime implementation and proves it
stays Embedded-Swift compatible. The split is tracked by
[epic #845](https://github.com/phynics/axoloty/issues/845).

## Current state

| Profile | Application × platform × transport | Builds | Device qualification |
|---|---|---|---|
| [`esp32c6-mqtt`](./Profiles/esp32c6-mqtt) | device-smoke-agent × ESP32-C6 (ESP-IDF) × ESP-IDF MQTT | yes, reproducibly | **none current**: `0.8.2-embedded.2` is [revoked](./releases/revocations/esp32c6-mqtt) |
| [`esp32c6-zenoh`](./Profiles/esp32c6-zenoh) | device-smoke-agent × ESP32-C6 (ESP-IDF) × zenoh-pico 1.10.0 | yes, reproducibly | not yet run ([#8](https://github.com/phynics/axoloty-embedded/issues/8)) |

Both profiles requalify on hardware against a tagged Core release under the
[finalization plan](https://github.com/phynics/axoloty/issues/796#issuecomment-6047498382).
A profile counts as qualified only through an unrevoked certificate in
[`releases/`](./releases) backed by device-tier evidence in
[`docs/evidence/`](./docs/evidence).

## Ownership boundary

| Here | In [Axoloty](https://github.com/phynics/axoloty) |
|---|---|
| Firmware applications | `AxolotyWire`, `AxolotyObjectModel`, `AxolotyProtocol`, `AxolotyCoatyModels`, `AxolotyStaticRuntime` |
| Board and SDK integration (ESP-IDF today) | Portable protocol semantics and wire format |
| Embedded transport backends | Host transports and shared transport contracts |
| Firmware profiles and releases | The Embedded-Swift compatibility contract and its hardware-free gates |
| Physical-device qualification | Host and static protocol trace parity |

Ordinary Axoloty development needs no checkout of this repository.

Portable source is never copied here. The packages above are compiled in place
from a locked Axoloty checkout.

## Composition model

Firmware is `application x platform x transport`, selected by a profile:

```text
Applications/   what the firmware does
Platforms/      board, SDK, and toolchain integration
Transports/     embedded transport backends
Profiles/       a named application x platform x transport selection
Tools/          repository tooling
docs/           this repository's contracts
```

ESP-IDF is the platform integration that exists first, not a permanent
architectural assumption.

## Exact Core dependency

[`axoloty-core.lock.json`](./axoloty-core.lock.json) names the exact Axoloty
revision this repository builds against. The commit SHA is authoritative. The
tag is set only when that commit is a Core release, and a release certificate
requires one. See
[docs/core-dependency.md](./docs/core-dependency.md).

Prepare Core for a build:

```bash
Tools/prepare-core.sh
```

A clean clone needs no prepared sibling checkout. The script fetches the locked
commit into `.axoloty/` and runs Axoloty's supported
`axoloty-tool embedded consumer prepare` command, writing
`.axoloty/core-preparation.json`.

For coordinated local development against a working Axoloty checkout:

```bash
AXOLOTY_SOURCE_DIR=/absolute/path/to/axoloty Tools/prepare-core.sh
```

Release and CI builds run in strict mode, where a dirty or off-lock local
checkout is an error rather than a warning.

## Related

- [`phynics/axoloty`](https://github.com/phynics/axoloty) — Core: the portable
  packages this firmware compiles, their documentation, and the
  Embedded-Swift compatibility gates
- [Axoloty embedded consumer contract](https://github.com/phynics/axoloty/blob/main/docs/embedded-consumer-contract.md)
- [Axoloty README](https://github.com/phynics/axoloty/blob/main/README.md) and
  [ARCHITECTURE.md](https://github.com/phynics/axoloty/blob/main/ARCHITECTURE.md)
- [Epic #845](https://github.com/phynics/axoloty/issues/845) — the split
- [Epic #796](https://github.com/phynics/axoloty/issues/796) — Zenoh; the
  embedded implementation lands here, host and shared work stays in Axoloty

## License

MIT, matching Axoloty.
