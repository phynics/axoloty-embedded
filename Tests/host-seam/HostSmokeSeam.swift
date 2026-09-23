// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// A host implementation of `DeviceSmokeSeam`.
//
// The device-smoke application is a total function of its seam, so running it
// on a development host needs only a second implementation of the seam. This
// one is backed by host stubs: stdout, a monotonic clock, a real sleep, fixed
// resource values, and a scenario table for the network fields. It is host
// verification infrastructure, not a platform: it lives under `Tests/`, and no
// production source changes to accommodate it.

import AxolotyWire
import AxolotyProtocol
import AxolotyObjectModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Host seam state. `runSmoke` reads these synchronously; the host runner
/// sets them before starting the application.
enum HostSmokeConfiguration {
    /// Non-zero to take the network path. Zero runs the offline corpus.
    nonisolated(unsafe) static var networkConfigured: Int32 = 0
    /// Role and scenario the network seam reports.
    nonisolated(unsafe) static var networkRole: UInt32 = 0
    nonisolated(unsafe) static var networkScenario: UInt32 = 0
    /// Fixed resource values the host reports.
    nonisolated(unsafe) static var freeHeap: UInt32 = 262_144
    nonisolated(unsafe) static var minFreeHeap: UInt32 = 196_608
    nonisolated(unsafe) static var largestBlock: UInt32 = 131_072
    nonisolated(unsafe) static var stackHighWater: UInt32 = 4_096
    nonisolated(unsafe) static var stackSize: UInt32 = 131_072
    nonisolated(unsafe) static var displayName: StaticString = "Host Smoke"
}

@inline(__always)
private func hostPrint(_ message: UnsafePointer<CChar>) {
    fputs(message, stdout)
    fflush(stdout)
}

@inline(__always)
private func hostPrintUInt(_ label: UnsafePointer<CChar>, _ value: UInt32) {
    fputs(label, stdout)
    fputs(String(value), stdout)
    fflush(stdout)
}

@inline(__always)
private func hostNowMicroseconds() -> Int64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_nsec) / 1_000
}

/// Sleeps for `ticks` FreeRTOS ticks. The firmware runs at 1000 Hz, so a tick
/// is one millisecond.
@inline(__always)
private func hostDelay(_ ticks: UInt32) {
    usleep(useconds_t(ticks) * 1_000)
}

/// The application's terminal event. The firmware reboots here; a host cannot
/// reboot, so the event is recorded and the process ends cleanly. The runner
/// judges the run from the emitted records, not from this exit code.
@inline(__always)
private func hostRestart() {
    fputs("{\"host\":\"restart\"}\n", stdout)
    fflush(stdout)
    exit(0)
}

@inline(__always)
private func hostFreeInternalHeap() -> UInt32 { HostSmokeConfiguration.freeHeap }
@inline(__always)
private func hostMinFreeInternalHeap() -> UInt32 { HostSmokeConfiguration.minFreeHeap }
@inline(__always)
private func hostLargestInternalBlock() -> UInt32 { HostSmokeConfiguration.largestBlock }
@inline(__always)
private func hostMainStackHighWater() -> UInt32 { HostSmokeConfiguration.stackHighWater }
@inline(__always)
private func hostMainStackSize() -> UInt32 { HostSmokeConfiguration.stackSize }
@inline(__always)
private func hostResetReason() -> UInt32 { 0 }

@inline(__always)
private func hostHeapTraceBegin() -> Int32 { 1 }
@inline(__always)
private func hostHeapTraceEnd() -> UInt32 { 0 }

@inline(__always)
private func hostNetworkConfigured() -> Int32 { HostSmokeConfiguration.networkConfigured }
@inline(__always)
private func hostNetworkRole() -> UInt32 { HostSmokeConfiguration.networkRole }
@inline(__always)
private func hostNetworkScenario() -> UInt32 { HostSmokeConfiguration.networkScenario }
@inline(__always)
private func hostNetworkPrepare(_ deadline: UInt32) -> UInt32 { _ = deadline; return 0 }
@inline(__always)
private func hostNetworkReconnect(_ deadline: UInt32) -> UInt32 { _ = deadline; return 0 }
@inline(__always)
private func hostNetworkCopyTopic(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    _ = buffer; _ = capacity; return 0
}
@inline(__always)
private func hostNetworkCopyPayload(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    _ = buffer; _ = capacity; return 0
}
@inline(__always)
private func hostNetworkCleanup() -> UInt32 { 1 }
@inline(__always)
private func hostCarrierConfigureLastWill(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 { _ = topic; _ = topicLength; _ = payload; _ = payloadLength; return 0 }
@inline(__always)
private func hostCarrierConnect(_ deadline: UInt32) -> Int32 { _ = deadline; return 0 }
@inline(__always)
private func hostCarrierSubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadline: UInt32
) -> Int32 { _ = topic; _ = topicLength; _ = deadline; return 0 }
@inline(__always)
private func hostCarrierUnsubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadline: UInt32
) -> Int32 { _ = topic; _ = topicLength; _ = deadline; return 0 }
@inline(__always)
private func hostCarrierPublish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 { _ = topic; _ = topicLength; _ = payload; _ = payloadLength; return 0 }
@inline(__always)
private func hostCarrierPollOneEvent(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    _ = topic; _ = topicCapacity; _ = topicLength
    _ = payload; _ = payloadCapacity; _ = payloadLength
    return -1
}
@inline(__always)
private func hostCarrierWaitForReconnect(_ deadline: UInt32) -> Int32 { _ = deadline; return 0 }
@inline(__always)
private func hostCarrierDisconnect() -> Int32 { 0 }
@inline(__always)
private func hostExchangeMilestone(_: UInt32) {}

@inline(__always)
private func hostDeviceDisplayName(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    let name = HostSmokeConfiguration.displayName
    guard capacity > Int32(name.utf8CodeUnitCount) else { return -1 }
    for index in 0..<name.utf8CodeUnitCount { buffer[index] = name.utf8Start[index] }
    return Int32(name.utf8CodeUnitCount)
}

/// The seam a host run installs.
func hostSmokeSeam() -> DeviceSmokeSeam {
    DeviceSmokeSeam(
        print: hostPrint,
        printUInt: hostPrintUInt,
        nowMicroseconds: hostNowMicroseconds,
        delay: hostDelay,
        restart: hostRestart,
        freeInternalHeap: hostFreeInternalHeap,
        minFreeInternalHeap: hostMinFreeInternalHeap,
        largestInternalBlock: hostLargestInternalBlock,
        mainStackHighWater: hostMainStackHighWater,
        mainStackSize: hostMainStackSize,
        resetReason: hostResetReason,
        heapTraceBegin: hostHeapTraceBegin,
        heapTraceEnd: hostHeapTraceEnd,
        networkConfigured: hostNetworkConfigured,
        networkRole: hostNetworkRole,
        networkScenario: hostNetworkScenario,
        networkPrepare: hostNetworkPrepare,
        networkReconnect: hostNetworkReconnect,
        networkCopyTopic: hostNetworkCopyTopic,
        networkCopyPayload: hostNetworkCopyPayload,
        networkCleanup: hostNetworkCleanup,
        carrier: DeviceSmokeCarrierOperations(
            configureLastWill: hostCarrierConfigureLastWill,
            connect: hostCarrierConnect,
            subscribe: hostCarrierSubscribe,
            unsubscribe: hostCarrierUnsubscribe,
            publish: hostCarrierPublish,
            pollOneEvent: hostCarrierPollOneEvent,
            waitForReconnect: hostCarrierWaitForReconnect,
            disconnect: hostCarrierDisconnect
        ),
        exchangeMilestone: hostExchangeMilestone,
        deviceDisplayName: hostDeviceDisplayName
    )
}
