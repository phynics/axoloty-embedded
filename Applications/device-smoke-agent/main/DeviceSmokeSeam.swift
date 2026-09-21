// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The bounded, non-allocating boundary between this application and the
// profile that runs it.
//
// The application owns what the firmware does. It must not name a board, an
// SDK, or a broker, so it receives every outside operation as a function
// pointer here and the selected platform and transport supply the concrete
// implementations. The value is a plain struct of C function pointers: no
// allocation, no retention, and one synchronous call per operation.

/// Operations the running profile supplies to the device smoke application.
public struct DeviceSmokeSeam {
    /// Writes one bounded UTF-8 message to the firmware console.
    var print: @convention(c) (UnsafePointer<CChar>) -> Void
    /// Writes one unsigned value to the firmware console, with a label prefix.
    var printUInt: @convention(c) (UnsafePointer<CChar>, UInt32) -> Void
    /// Monotonic microseconds since boot, for deterministic timing.
    var nowMicroseconds: @convention(c) () -> Int64
    /// Yields for `ticks` scheduler ticks.
    var delay: @convention(c) (UInt32) -> Void
    /// Restarts the device. The platform implementation never returns.
    ///
    /// Call ``DeviceSmokeSeam/restartDevice()`` rather than this pointer, so
    /// the compiler knows control ends.
    var restart: @convention(c) () -> Void

    /// Free internal heap bytes.
    var freeInternalHeap: @convention(c) () -> UInt32
    /// Minimum free internal heap bytes observed since boot.
    var minFreeInternalHeap: @convention(c) () -> UInt32
    /// Largest free internal heap block in bytes.
    var largestInternalBlock: @convention(c) () -> UInt32
    /// Main-task stack high-water mark in bytes.
    var mainStackHighWater: @convention(c) () -> UInt32
    /// Configured main-task stack size in bytes.
    var mainStackSize: @convention(c) () -> UInt32
    /// Reset reason code.
    var resetReason: @convention(c) () -> UInt32
    /// Starts the standalone heap trace. Non-zero on success.
    var heapTraceBegin: @convention(c) () -> Int32
    /// Stops the heap trace and returns the recorded allocation count.
    var heapTraceEnd: @convention(c) () -> UInt32

    /// Non-zero when an operator supplied network and broker configuration.
    var networkConfigured: @convention(c) () -> Int32
    /// Device role selected for the network scenario.
    var networkRole: @convention(c) () -> UInt32
    /// Exchange scenario selected for the network role.
    var networkScenario: @convention(c) () -> UInt32
    /// Brings up the network within the deadline, returning a bit field.
    var networkPrepare: @convention(c) (UInt32) -> UInt32
    /// Copies the prepared carrier topic into caller storage.
    var networkCopyTopic: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32
    /// Copies the prepared carrier payload into caller storage.
    var networkCopyPayload: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32
    /// Tears the network façade down, returning non-zero on success.
    var networkCleanup: @convention(c) () -> UInt32
    /// Runs the bounded agent exchange, returning a result bit field.
    var agentTest: @convention(c) (UInt32, UnsafePointer<UInt8>, Int32) -> UInt32
    /// Copies the operator-configured device display name into caller storage.
    var deviceDisplayName: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32

    public init(
        print: @escaping @convention(c) (UnsafePointer<CChar>) -> Void,
        printUInt: @escaping @convention(c) (UnsafePointer<CChar>, UInt32) -> Void,
        nowMicroseconds: @escaping @convention(c) () -> Int64,
        delay: @escaping @convention(c) (UInt32) -> Void,
        restart: @escaping @convention(c) () -> Void,
        freeInternalHeap: @escaping @convention(c) () -> UInt32,
        minFreeInternalHeap: @escaping @convention(c) () -> UInt32,
        largestInternalBlock: @escaping @convention(c) () -> UInt32,
        mainStackHighWater: @escaping @convention(c) () -> UInt32,
        mainStackSize: @escaping @convention(c) () -> UInt32,
        resetReason: @escaping @convention(c) () -> UInt32,
        heapTraceBegin: @escaping @convention(c) () -> Int32,
        heapTraceEnd: @escaping @convention(c) () -> UInt32,
        networkConfigured: @escaping @convention(c) () -> Int32,
        networkRole: @escaping @convention(c) () -> UInt32,
        networkScenario: @escaping @convention(c) () -> UInt32,
        networkPrepare: @escaping @convention(c) (UInt32) -> UInt32,
        networkCopyTopic: @escaping @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
        networkCopyPayload: @escaping @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
        networkCleanup: @escaping @convention(c) () -> UInt32,
        agentTest: @escaping @convention(c) (UInt32, UnsafePointer<UInt8>, Int32) -> UInt32,
        deviceDisplayName: @escaping @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32
    ) {
        self.print = print
        self.printUInt = printUInt
        self.nowMicroseconds = nowMicroseconds
        self.delay = delay
        self.restart = restart
        self.freeInternalHeap = freeInternalHeap
        self.minFreeInternalHeap = minFreeInternalHeap
        self.largestInternalBlock = largestInternalBlock
        self.mainStackHighWater = mainStackHighWater
        self.mainStackSize = mainStackSize
        self.resetReason = resetReason
        self.heapTraceBegin = heapTraceBegin
        self.heapTraceEnd = heapTraceEnd
        self.networkConfigured = networkConfigured
        self.networkRole = networkRole
        self.networkScenario = networkScenario
        self.networkPrepare = networkPrepare
        self.networkCopyTopic = networkCopyTopic
        self.networkCopyPayload = networkCopyPayload
        self.networkCleanup = networkCleanup
        self.agentTest = agentTest
        self.deviceDisplayName = deviceDisplayName
    }
}

extension DeviceSmokeSeam {
    /// Restarts the device and never returns.
    ///
    /// The platform implementation is a `noreturn` SDK call, but a
    /// `@convention(c)` pointer cannot be declared `Never`-returning, so that
    /// property is lost at the seam. Without it every caller looks like it
    /// falls through and the compiler rejects the missing return.
    ///
    /// This restores it once, here, instead of an unreachable `return` at each
    /// call site. The trap is genuinely unreachable; it exists so the function
    /// can be typed `Never`, and it fails loudly rather than continuing with a
    /// device that was supposed to have reset.
    func restartDevice() -> Never {
        restart()
        fatalError("platform restart returned")
    }
}

/// The seam supplied by the running profile before the application starts.
///
/// A firmware image installs exactly one seam. The value is set once from
/// ``startDeviceSmoke(_:)`` and read synchronously from application entry
/// points that the profile calls back into; it is never accessed from a
/// concurrent context.
nonisolated(unsafe) private var installedDeviceSmokeSeam: DeviceSmokeSeam?

/// Returns the installed seam. The application is only reachable after the
/// profile has installed one.
@inline(__always)
func deviceSmokeSeam() -> DeviceSmokeSeam {
    installedDeviceSmokeSeam!
}

/// Installs the profile-supplied seam.
@inline(__always)
func installDeviceSmokeSeam(_ seam: DeviceSmokeSeam) {
    installedDeviceSmokeSeam = seam
}
