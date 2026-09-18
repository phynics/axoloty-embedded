# Platforms

## What belongs here

Board, SDK, and toolchain integration: build-system glue, linker and partition
layout, bring-up, Wi-Fi and network bootstrap, clocks, storage, runtime
identity, flashing, and monitoring.

ESP-IDF on ESP32-C6 is the first platform. It is not a permanent assumption,
and it is not the shape every future platform must take. Do not build a
universal internal build system to hold two platforms that do not exist yet.

## What does not

A platform owns no protocol behavior. `Tools/check-invariants.sh` fails on
`import AxolotyProtocol`, `import AxolotyCoatyModels`, `ProtocolProcessor`,
`ProtocolSubscriptionRegistry`, `BorrowedProtocolFrame`,
`InlineProtocolActionSink`, and the literal `coaty/3` under this directory.

## Core

Reach Core only through `Tools/prepare-core.sh` and the report it writes.
Never search a parent directory, never read Axoloty's root `.build`, and never
read anything under Axoloty's `Tests/`. The build consumes
`core-preparation.json` and nothing else from Core.

## Credentials

Wi-Fi credentials, broker addresses, device paths, and live timing are operator
configuration. They are never tracked. Take them from `sdkconfig` entries or
the environment, and keep the tracked default empty or a named placeholder.
