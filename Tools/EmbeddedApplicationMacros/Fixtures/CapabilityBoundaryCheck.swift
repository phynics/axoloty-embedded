// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
enum CapabilityBoundaryCheck {
static func main() {
    guard let capabilities = EmbeddedCapabilities(
        validatingPlatform: unit_b_platform_table(),
        carrier: unit_b_carrier_table(),
        requirements: EmbeddedApplicationRequirements.current
    ) else { fatalError("manifest requirements should validate") }

    var byte: UInt8 = 0x41
    withUnsafePointer(to: &byte) { pointer in
        do {
            try capabilities.platform.writeLog(pointer, length: 1)
        } catch {
            fatalError("required console operation failed")
        }
    }
    guard unit_b_platform_write_count() == 1 else { fatalError("required callback was not called") }

    do {
        _ = try capabilities.platform.nowMicroseconds()
        fatalError("undeclared operation succeeded")
    } catch let error {
        guard case EmbeddedCapabilityError.capabilityUnavailable = error else {
            fatalError("undeclared operation returned the wrong error")
        }
    }

    withUnsafePointer(to: &byte) { pointer in
        do {
            try capabilities.carrier.publish(topic: pointer, topicLength: 5,
                                              payload: pointer, payloadLength: 1)
            fatalError("oversized topic succeeded")
        } catch let error {
            guard case EmbeddedCapabilityError.invalidArgument = error else {
                fatalError("oversized topic returned the wrong error")
            }
        }
    }
    guard unit_b_carrier_publish_count() == 0 else { fatalError("oversized topic reached callback") }

    withUnsafePointer(to: &byte) { pointer in
        do {
            try capabilities.carrier.publish(topic: pointer, topicLength: 1,
                                              payload: pointer, payloadLength: 6)
            fatalError("oversized payload succeeded")
        } catch let error {
            guard case EmbeddedCapabilityError.invalidArgument = error else {
                fatalError("oversized payload returned the wrong error")
            }
        }
    }
    guard unit_b_carrier_publish_count() == 0 else { fatalError("oversized payload reached callback") }

    var topic = [UInt8](repeating: 0, count: 4)
    var payload = [UInt8](repeating: 0, count: 5)
    var topicLength: UInt32 = 0
    var payloadLength: UInt32 = 0
    do {
        _ = try topic.withUnsafeMutableBufferPointer { topicBuffer in
            try payload.withUnsafeMutableBufferPointer { payloadBuffer in
                try capabilities.carrier.pollOneEvent(
                    topic: topicBuffer.baseAddress!, topicCapacity: UInt32(topicBuffer.count), topicLength: &topicLength,
                    payload: payloadBuffer.baseAddress!, payloadCapacity: UInt32(payloadBuffer.count), payloadLength: &payloadLength
                )
            }
        }
        fatalError("invalid output length succeeded")
    } catch let error {
        guard case EmbeddedCapabilityError.invalidABI = error else {
            fatalError("invalid output length returned the wrong error")
        }
    }
}
}
