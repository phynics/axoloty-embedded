# Embedded application entry contract

An application declares one synchronous namespace entry. Swift checks its
`State` and `run` signature through `EmbeddedApplicationDefinition`; the macro
checks declaration shape and generates the neutral C entry.

```swift
import EmbeddedCapabilities

@EmbeddedApplication
private enum Indicator {
    typealias State = IndicatorState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        state.starts &+= 1
        return .completed
    }
}
```

`State` can be a nested value type or a typealias to an externally declared
value type. A stateless app writes `typealias State = EmptyApplicationState`.
The macro exports exactly one `axoloty_application_main` entry per image.
Applications return `.completed` or `.failed(...)`; the shared adapter maps
these outcomes to fixed `Int32` statuses: `0` means completed, `-100` means an
application failure, and `-101` means the shared boundary rejected the ABI
tables. `-103` means a valid entry was already claimed. No Swift error or
app-selected integer status crosses C.

The generated entry stores one concrete `State = .init()` value in ordinary
Swift global storage. It compares the selected target's `MemoryLayout<State>.stride`
with `applicationStateBytes` as a `UInt64` before it accesses that global or
calls `run`. A state that exceeds the budget returns the stable bootstrap status
`-102`; invalid ABI tables still return `-101`, and application failure remains
`-100`. The state budget covers app-state bytes in either `.data` or `.bss`; it
does not account for the global-initialization guard, other image RAM, or stack.
An empty state is checked using the target's actual stride, including any
nonzero stride Swift assigns to a zero-sized type.

This check is a runtime entry rejection, not a build-time or final-image size
gate. It does not claim that initialization is allocation-free, that all
storage placement has been verified in a final linked image, or that entry is
safe for concurrent or repeated calls. The generated global uses Swift's
supported initializer; no raw-zero representation is assumed.

After state-budget and ABI validation succeed, the generated entry calls the
shared C `axoloty_application_entry_claim_v1` helper. That helper owns one
statically initialized 32-bit atomic claim for the process lifetime. It must
be compiled once as shared Interop glue; it is not a header-local latch or
application-owned C source. The first valid caller claims entry before Swift
reads or initializes the state global. Later, recursive, and competing valid
calls return `-103` without reading app state or calling `run`. A budget or ABI
rejection does not claim entry. A `.failed` app result still consumes the
claim. The claim never resets; firmware uses one app entry per process/boot
lifetime. There is no retry, teardown, or reset API.

The helper requires a compile-time proof that 32-bit integer atomics are
always lock-free. A target that cannot meet that requirement fails to compile;
there is no lock-based fallback. This exclusion covers entry into this app,
not every application global initializer in the process.

## Manifest-driven capabilities

`app.json` is the authority for the selected application's required platform
and carrier operations and its topic, payload, and state limits. The composition
checker and requirements generator share the finite catalog in
`Tools/capability_catalog.py`. Before compiling the application, the generator
writes one fixed `EmbeddedRequirements` record into caller-owned build scratch;
the generated file is not checked into application source. A minimal app can
request only `console.write` and leave its carrier requirement list empty while
the profile still selects exactly one transport.

The ESP-IDF profile launcher passes the firmware repository root and selected
profile explicitly to CMake and exports both for the separate requirements
pass. The main component validates the selected profile and generates
`ManifestRequirements.swift` in its CMake build directory before adding that
file and the capability contract sources to the Swift compilation. Profile,
axis manifest, catalog, generator, and ABI header changes trigger CMake
reconfiguration and regenerate the record.

The entry boundary validates both v1 table headers. It checks only the
capability and function prefixes required by that record, accepts larger v1
tails, and rejects unsupported versions. A selected capability needs its ABI
bit and each catalogued function pointer. Unselected functions can be null.
Calling an operation absent from the manifest throws
`EmbeddedCapabilityError.capabilityUnavailable` before reading its function
pointer. Carrier input topic and payload lengths are checked against the same
manifest record before invoking a callback. Returned lengths must fit both the
caller buffer and the declared maximum.

The state budget is propagated in `EmbeddedRequirements`; this unit does not
prove the state object's size or storage placement. The device smoke
application now consumes the generated entry: `main/DeviceSmokeCapabilityBridge.swift`
turns the validated capabilities back into the seam the application already
runs against. The carrier probe stays with the selected transport, which
exports the neutral `runCarrierNetworkProbe` operation; the application names
that operation rather than a carrier, and the transport keeps ownership of its
evidence record names and mechanics.
