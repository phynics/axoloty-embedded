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

The one exception is `esp32c6-idf/benchmark/`. It is a standalone measurement
fixture that mirrors AxolotyWire's JSON scanning in C for on-device timing, it
is not linked into any firmware image, and the invariant exempts its path from
the protocol-rule scan.

## Core

Reach Core only through `Tools/prepare-core.sh` and the report it writes.
Never search a parent directory, never read Axoloty's root `.build`, and never
read anything under Axoloty's `Tests/`. The build consumes
`core-preparation.json` and nothing else from Core.

## Build-system rule that bites

ESP-IDF expands component requirements in a **separate CMake sub-invocation**
that does not inherit `-D` cache variables from the `idf.py` command line. A
component `CMakeLists.txt` that reads `${SOMETHING}` will see it empty there.

Export the value into the environment and read it with an `ENV{}` fallback,
then fail with a `FATAL_ERROR` naming the variable. `cmake/axoloty-source.cmake`
is the pattern to copy.

An empty path does not fail where it is set; it fails later as a missing file,
and the error names the file. Two instances of exactly this cost real time on
the first build of this firmware. See
[docs/container-builds.md](../docs/container-builds.md).

## Credentials

Wi-Fi credentials, broker addresses, device paths, and live timing are operator
configuration. They are never tracked. Take them from `sdkconfig` entries or
the environment, and keep the tracked default empty or a named placeholder.
