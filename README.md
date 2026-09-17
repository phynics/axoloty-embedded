# axoloty-embedded

Concrete embedded firmware products built on [Axoloty](https://github.com/phynics/axoloty).

This repository owns firmware composition and physical-device qualification.
Axoloty owns the portable protocol and runtime implementation and proves it
stays Embedded-Swift compatible. The split is tracked by
[epic #845](https://github.com/phynics/axoloty/issues/845).

> **Bootstrap state.** The repository layout and the Core dependency contract
> exist. Firmware migration is
> [#848](https://github.com/phynics/axoloty/issues/848) and has not started,
> so no buildable profile lives here yet.

## Ownership boundary

| Here | In Axoloty |
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

The first profile will be ESP32-C6 + MQTT. ESP-IDF is the platform integration
that exists first, not a permanent architectural assumption.

## Exact Core dependency

[`axoloty-core.lock.json`](./axoloty-core.lock.json) names the exact Axoloty
revision this repository builds against. The commit SHA is authoritative; the
version and tag are descriptive. See
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

- [Axoloty embedded consumer contract](https://github.com/phynics/axoloty/blob/main/docs/embedded-consumer-contract.md)
- [Epic #845](https://github.com/phynics/axoloty/issues/845) — the split
- [Epic #796](https://github.com/phynics/axoloty/issues/796) — Zenoh; the
  embedded implementation lands here, host and shared work stays in Axoloty

## License

MIT, matching Axoloty.
