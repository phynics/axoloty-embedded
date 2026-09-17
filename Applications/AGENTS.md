# Applications

## What belongs here

What the firmware does: agent behavior, object-model usage, IO endpoints, and
the decisions that would be the same on any board and over any carrier.

## What does not

An application names no board, SDK, or broker. Not in code, not in a build
file, not in a header. `Tools/check-invariants.sh` fails on `esp32`, `esp-idf`,
`freertos`, `nvs_flash`, `esp_wifi`, `sdkconfig`, `partitions.csv`, `mqtt`, and
`zenoh` anywhere under this directory.

This is not stylistic. The axes are only separable while the application cannot
name the other two; the second board is a rewrite the moment it can.

## How to reach the outside

An application declares what it needs and receives it. Take a function pointer,
a bounded buffer, or a small struct of operations from the profile, and let the
platform or transport supply the implementation. Do not call an SDK symbol and
do not `#if` on a board.

## Core

Import the portable Axoloty modules directly: `AxolotyWire`,
`AxolotyObjectModel`, `AxolotyProtocol`, `AxolotyCoatyModels`,
`AxolotyStaticRuntime`. They are compiled in place from the locked checkout.
Never copy their source here, and never restate a protocol rule that
`AxolotyProtocol` already owns.
