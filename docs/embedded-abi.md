# Embedded application and platform ABI

This guide describes the version 1 C tables, the Swift application entry, and
the manifests that compose an image. It also records which parts of the
application boundary still need implementation work.

## Applications declare one synchronous entry

`@EmbeddedApplication` accepts an `enum` or `struct` used as a namespace. The
namespace declares exactly one `State` as either a nested `struct` or a
`typealias`, and exactly one `static run` function. `run` is synchronous and
has the `EmbeddedApplicationDefinition` signature:

```swift
import EmbeddedCapabilities

@EmbeddedApplication
private enum Indicator {
    typealias State = EmptyApplicationState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        .completed
    }
}
```

The protocol and compiler check the parameter and return types. The macro
reports a diagnostic for a non-enum or non-struct namespace, a missing or
duplicate `State`, a missing or duplicate `run`, an instance `run`, or an
`async run`. The compiler also checks that the declaration conforms to the
protocol, including the exact function signature. The macro takes no
arguments.

`State` may be copyable or noncopyable. The protocol declares
`associatedtype State: ~Copyable`, so a fixed-storage Core value can remain in
the app state. The generated global initializes the concrete state with
`.init()`. Use a supported Swift initializer. The ABI does not define a raw-zero
representation for Swift values.

The macro emits the C entry `axoloty_application_main` with the platform and
carrier table pointers. Its source-level order is:

1. Compare `MemoryLayout<State>.stride` with the manifest's
   `applicationStateBytes`.
2. Validate the required platform and carrier table prefixes.
3. Atomically claim the process's one application entry.
4. Pass the state as `inout` to `run` and map its result to a C status.

An over-budget state returns `-102`; it does not claim entry. An invalid table
returns `-101`; it does not claim entry. The first call that passes both
checks claims entry before the generated function forms the state access.
Later or competing valid calls return `-103` without calling `run`. A `.failed`
result returns `-100` and consumes the claim. The claim never resets. One
process lifetime has one app entry.

`Interop/axoloty_application_entry_v1.c` uses a statically initialized
32-bit integer and a compare-and-exchange operation. Compile-time assertions
require always-lock-free integer atomics and a 32-bit `unsigned int`. A target
that does not meet either requirement fails to compile. The claim protects
the app entry; it does not prove that every global initializer is free of
allocation or concurrency hazards.

The state budget compares only the selected target's `State` stride at entry.
It is a runtime rejection, not a compile-time or link-time size gate. The
state's bytes count whether the linker places them in `.data` or `.bss`. The
budget does not include an initialization guard, other mutable application
globals, other image RAM, or stack.

### Entry status values

Only `axoloty_application_main` returns these application statuses:

| Value | Meaning |
|---:|---|
| `0` | `run` returned `.completed` |
| `-100` | `run` returned `.failed` |
| `-101` | The required v1 ABI tables failed validation |
| `-102` | The state stride exceeds `applicationStateBytes` |
| `-103` | Another valid call already claimed entry |

No Swift error or application-selected integer crosses this C entry.

### Capability operation statuses

The table callbacks use fixed-width `int32_t` statuses from
`Interop/axoloty_abi_status_v1.h`:

| Value | Meaning in the Swift carrier wrapper |
|---:|---|
| `0` | Success |
| `1` | No event (`poll_one_event` only) |
| `2` | Carrier closed. `poll_one_event` returns `.closed`; other callbacks that use the shared status mapper also throw `.closed` if they return this status. |
| `3` | Caller buffer is too small |
| `-1` | Invalid argument |
| `-2` | Operation failed |

The wrapper maps other callback failures to
`EmbeddedCapabilityError.operationFailed`. A selected operation with no
required function throws `.invalidABI`. An operation the app did not select
throws `.capabilityUnavailable` before the wrapper reads its function
pointer.

## Platform and carrier tables use appendable v1 prefixes

`Interop/axoloty_platform_v1.h` and `Interop/axoloty_carrier_v1.h` define
plain C function tables. Each begins with `uint32_t abi_version` and
`uint32_t struct_size`. The required version is `1`. A validator first checks
this 8-byte header, then checks only the capability bits and function fields
required by the app's generated record. It accepts a larger v1 table tail.
Unselected function pointers may be null.

Keep the existing prefix layout and field meanings stable when extending v1.
Append optional fields. Increase the ABI version for a change that cannot keep
the old prefix and behavior intact. A newer version is rejected by the v1
entry. Keep status values as `int32_t` constants; do not use compiler-sized C
enums at the boundary.

The returned tables and their `context` values must stay immutable and live
for the image. Swift capability wrappers keep pointers only for the
synchronous application call. Callback byte pointers are borrowed for the
callback; wrappers do not retain them. Poll and copy callbacks write into
caller-owned buffers and must not report a length above the supplied capacity
or the manifest limit.

### Platform capability table

The `capabilities` field contains the `AXOLOTY_PLATFORM_CAP_*` bits. The
manifest names below map to those bits and to the required function fields.
The catalog in `Tools/capability_catalog.py` is the source for this mapping.

| Manifest requirement | Capability bit | Required function fields |
|---|---|---|
| `clock.monotonicMicroseconds` | `AXOLOTY_PLATFORM_CAP_CLOCK` | `clock_now_microseconds` |
| `scheduler.delayTicks` | `AXOLOTY_PLATFORM_CAP_DELAY` | `delay_ticks` |
| `device.restart` | `AXOLOTY_PLATFORM_CAP_RESTART` | `restart` |
| `console.write` | `AXOLOTY_PLATFORM_CAP_LOG` | `write_log` |
| `diagnostics.heap` | `AXOLOTY_PLATFORM_CAP_DIAGNOSTICS` | `heap_trace_begin`, `heap_trace_end` |
| `diagnostics.stack` | `AXOLOTY_PLATFORM_CAP_DIAGNOSTICS` | `read_metrics` |
| `network.configuration` | `AXOLOTY_PLATFORM_CAP_NETWORK_CONFIG` | `network_configured`, `network_role`, `network_scenario` |
| `network.bootstrap` | `AXOLOTY_PLATFORM_CAP_NETWORK_BOOTSTRAP` | `network_prepare`, `network_cleanup` |
| `network.reconnect` | `AXOLOTY_PLATFORM_CAP_NETWORK_RECONNECT` | `network_reconnect` |
| `device.displayName` | `AXOLOTY_PLATFORM_CAP_DEVICE_NAME` | `device_display_name` |

`axoloty_platform_metrics_v1` reports free internal heap, minimum free
internal heap, largest internal block, main stack high-water mark, main stack
size, reset reason, and heap-trace allocation count. It is a platform-defined
snapshot, not an allocation proof for the application entry.

`diagnostics.heap` start reports initialization/start failure as
`AXOLOTY_ABI_STATUS_FAILED`. End stops tracing and reads the SDK summary. It
writes the caller's `uint32_t` count only when the summary reports
`HEAP_TRACE_ALL`, no overflow, and a total allocation count that fits the ABI.
It uses `total_allocations`, not the buffered record count. Stop or summary
failure, a wrong summary mode, or a too-wide count returns
`AXOLOTY_ABI_STATUS_FAILED`; overflow returns
`AXOLOTY_ABI_STATUS_TRACE_OVERFLOW` (`-3`). Every failure leaves the output
unchanged. Swift exposes start, stop, and overflow as distinct typed trace
errors. A complete count does not by itself prove that every allocator path
was traced.

### Carrier capability table

The `capabilities` field contains the `AXOLOTY_CARRIER_CAP_*` bits. The
manifest names map to these bits and required function fields:

| Manifest requirement | Capability bit | Required function fields |
|---|---|---|
| `lastWill` | `AXOLOTY_CARRIER_CAP_LAST_WILL` | `supports_last_will`, `configure_last_will` |
| `connect` | `AXOLOTY_CARRIER_CAP_CONNECT` | `connect` |
| `subscribe` | `AXOLOTY_CARRIER_CAP_SUBSCRIBE` | `subscribe` |
| `unsubscribe` | `AXOLOTY_CARRIER_CAP_UNSUBSCRIBE` | `unsubscribe` |
| `publish` | `AXOLOTY_CARRIER_CAP_PUBLISH` | `publish` |
| `poll` | `AXOLOTY_CARRIER_CAP_POLL` | `poll_one_event` |
| `reconnect` | `AXOLOTY_CARRIER_CAP_RECONNECT` | `wait_for_reconnect` |
| `disconnect` | `AXOLOTY_CARRIER_CAP_DISCONNECT` | `disconnect` |
| `networkProbe` | `AXOLOTY_CARRIER_CAP_NETWORK_PROBE` | `copy_probe_topic`, `copy_probe_payload` |

The v1 carrier ABI also defines the `AXOLOTY_CARRIER_CAP_LOOPBACK` bit and the
`wait_for_loopback` function pointer. The capability catalog has no manifest
requirement or Swift wrapper operation for loopback. The function pointer can
remain null because no current catalog entry requires it.

### Function masks follow catalog order

The generated `platformFunctions` and `carrierFunctions` values use a
64-bit mask. Bit positions follow the unique field order in
`Tools/capability_catalog.py`, not the capability-bit values. For platform
fields, the order is `clock_now_microseconds`, `delay_ticks`, `restart`,
`write_log`, `heap_trace_begin`, `heap_trace_end`, `read_metrics`,
`network_configured`, `network_role`, `network_scenario`, `network_prepare`,
`network_cleanup`, `network_reconnect`, and `device_display_name`.

For carrier fields, the order is `supports_last_will`, `configure_last_will`,
`connect`, `subscribe`, `unsubscribe`, `publish`, `poll_one_event`,
`wait_for_reconnect`, `disconnect`, `copy_probe_topic`, and
`copy_probe_payload`. The C validators use the same indexes. Update the
catalog, validators, generated requirements, and tests together when a
capability changes.

## Manifests select and bound the composition

A profile selects exactly one `application`, `platform`, and `transport`,
plus the Core revision from `axoloty-core.lock.json`. Each axis manifest uses
`schemaVersion: 1` and a `name` that matches its directory and the profile.

`Applications/<name>/app.json` declares:

| Field | Contract |
|---|---|
| `sources` | A nonempty list of existing `.swift` files. The set of listed paths must equal the app's discovered Swift source inventory. |
| `requirements.platform` | Platform capability names from the finite catalog. |
| `requirements.carrier` | Carrier capability names from the finite catalog. An empty array is valid. |
| `capacities.maxTopicLength` | Positive `UInt32` byte limit. The carrier sizes its fixed storage to it, and it may not exceed the transport's `limits.maxTopicLength`. |
| `capacities.maxPayloadSize` | Positive `UInt32` byte limit. The carrier sizes its fixed storage to it, and it may not exceed the transport's `limits.maxPayloadSize`. |
| `capacities.applicationStateBytes` | Positive `UInt32` state-stride budget. |

`Platforms/<name>/platform.json` lists the platform capabilities it supplies.
`Transports/<name>/transport.json` lists the carrier capabilities it supplies
and declares `limits.maxTopicLength` and `limits.maxPayloadSize`, the fixed
ceilings the transport can carry at all (the wire bound, or the contract of a
library it sits on). Composition fails when the application declares a capacity
above a ceiling.
Capability arrays reject duplicates and names absent from the catalog. A
profile build fails before compilation when a selected axis does not provide
an app requirement, when a manifest is malformed, or when the profile Core
revision differs from the lock.

`Tools/validate-composition.py` reads the manifests and emits one fixed
`EmbeddedApplicationRequirements.current` value into the build directory. It
also writes the application's topic and payload capacities once as the carrier
bounds: `axoloty_carrier_bounds.h` for the carrier's C, `EmbeddedCarrierBounds`
for its Swift, and a CMake file for the zenoh-pico component, which derives
`FRAG_MAX_SIZE` from them. A transport sizes its storage to these and names no
application.
It derives capability bits and function masks from
`Tools/capability_catalog.py` and the C headers. It does not edit application
source. At entry, the Swift boundary validates both tables against that
record. Carrier methods enforce the topic and payload limits before calling
the transport and check callback output lengths against both the caller's
buffer and the manifest limit.

## Keep application code in Swift

An application declares its synchronous work and the capabilities it needs.
It does not select a board, SDK, carrier, or broker. Application code uses
`EmbeddedCapabilities` methods and caller-owned buffers. It does not call SDK
functions, inspect a board macro, implement a C table, or choose a transport.

The current tree does not yet meet the no-C application acceptance rule.
`Applications/device-smoke-agent` contains
`interop/static_device_agent_interop.c`,
`include/static_device_agent.h`, and `include/module.modulemap`. The current
`Tools/check-invariants.sh` checks application source for board, SDK, and
broker names, but it does not reject C files, headers, or module maps. The
platform invariant also does not yet enforce the no-application-reference
criterion. Treat the pure-Swift authoring rule as the target contract, not as
a claim that every current app satisfies it.

The second app exercise (D8) and second platform exercise (D9) belong to
release validation #79. This guide does not claim either exercise has run.

## Extend a platform without changing application behavior

To add a platform, add a platform directory with a `platform.json`, implement
the required platform table functions in that platform's integration, and
select the platform in a profile. Declare only the capabilities whose
functions the platform supplies. Keep platform code free of protocol rules.
The profile validator checks the app requirements against the platform and
transport manifests before the firmware compile.

The current platform build is ESP-IDF-specific. It reads the selected
application sources and manifest as composition inputs. The requested
SDK-neutral helper `Platforms/common/axoloty-core.cmake` is not present in this
checkout. Core preparation is available only through
`Tools/prepare-core.sh` and its `core-preparation.json` report. Use that
supported boundary; do not read Core's root `.build` or `Tests/`, search a
parent directory, or copy Core source into this repository.

The current extension path can be checked at the repository tier:

```sh
Tools/verify.sh --tier repo
```

The profile build also needs a prepared Core report, the macro plugin, and
the platform toolchain. `Tools/verify.sh --tier repo` does not perform a
firmware build or device qualification.

## Storage evidence and limits

The approved state contract allows zero-backed state in `.bss` and
constant-initialized state in `.data`. The macro checks the declared `State`
stride against the manifest budget, regardless of which section holds those
bytes. It does not include other mutable application globals in that budget.
The current macro uses an ordinary concrete Swift global initialized through
Swift's supported initializer. It does not use a raw-zero representation.

The available target evidence is from relocatable objects. A minimal
noncopyable state with size, stride, and alignment `4 / 4 / 4` appears in
`.data`. The `ProtocolProcessor<16>` state with `5,912 / 5,912 / 4` appears
in `.bss`, with a separate four-byte initialization guard. The manifest
budget is checked at entry; a target object larger than the budget can still
compile.

Host macro fixtures observed that an eight-byte state passes an exact budget,
and that stride eight with budget seven returns `-102` before the fixture's
initializer and `run` counters change. A 5,912-byte state with budget eight
also returned `-102`. Separate host fixtures observed one successful entry,
then `-103`; invalid ABI did not consume the claim, and a 16-thread race had
one winner. These results test host behavior and generated objects.

They do not prove final linked `.data` or `.bss` placement, total initializer
stack use, absence of allocation on every initialization path, or whole-image
RAM use. The smoke app sets `applicationStateBytes` to 8, but that limit covers
only its declared `State` stride. Its two large global phase agents sit outside
that budget. The existing warmed-path heap trace starts after earlier
application work and does not observe first initialization of the generated
state or those globals. The observed processor initializer path includes
Swift's global initialization guard and an unresolved `memset` call. Its stack
use through linked callees remains unknown. Final linked static RAM,
initialization stack, and no-heap evidence remain acceptance work.

## Source references

- `Interop/axoloty_platform_v1.h`
- `Interop/axoloty_carrier_v1.h`
- `Interop/axoloty_abi_status_v1.h`
- `Interop/axoloty_application_entry_v1.h`
- `Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift`
- `Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift`
- `Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift`
- `Sources/EmbeddedCapabilities/EmbeddedRequirements.swift`
- `Tools/EmbeddedApplicationMacros/Sources/EmbeddedApplicationMacroImplementation/EmbeddedApplicationMacro.swift`
- `Tools/capability_catalog.py`
- `Tools/validate-composition.py`
