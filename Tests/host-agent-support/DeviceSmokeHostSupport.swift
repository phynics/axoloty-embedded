// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import EmbeddedMQTTClient

public func runDeviceSmokeHostNetworkProbe(
    networkPrepare: @convention(c) (UInt32) -> UInt32,
    networkReconnect: @convention(c) (UInt32) -> UInt32,
    networkCopyTopic: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCopyPayload: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCleanup: @convention(c) () -> UInt32,
    record: (StaticString, Bool) -> Void
) {
    runCarrierNetworkProbe(
        networkPrepare: networkPrepare,
        networkReconnect: networkReconnect,
        networkCopyTopic: networkCopyTopic,
        networkCopyPayload: networkCopyPayload,
        networkCleanup: networkCleanup,
        record: record
    )
}
