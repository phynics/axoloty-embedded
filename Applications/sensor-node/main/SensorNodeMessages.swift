// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Identity, route shapes, and payload encoding of the sensor node. Every byte
// goes through `AxolotyWire`, so one source serves both wire profiles.

import AxolotyProtocol
import AxolotyWire

/// Fixed identities of this reference image. A fleet would provision them.
enum SensorNodeIdentity {
    static let agent = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01
    ))
    static let object = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02
    ))
    static let namespace: StaticString = "axoloty-embedded"
    static let coreType: StaticString = "CoatyObject"
    static let objectType: StaticString = "axoloty.sensor.Node"
    static let channel: StaticString = "sensor-readings"
}

@inline(__always)
func sensorNodeSlice(_ text: StaticString) -> ByteSlice {
    ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
}

/// The Discover route interest in the selected profile's wildcard grammar.
///
/// The node serves requests and listens for nothing else, so it never spends
/// its small receive buffers on traffic it would ignore.
func sensorNodeDiscoverInterest() -> StaticString {
    #if canImport(_JSONCore)
    return "coaty/3/axoloty-embedded/DSC/+/+"
    #else
    return "axoloty/1/axoloty-embedded/DSC/*/*"
    #endif
}

/// Writes the sensor object into `buffer` and returns its length.
///
/// - Parameter reading: The sequence and value to include, or `nil` for the
///   bare advertised object.
private func writeSensorObject(
    into buffer: UnsafeMutablePointer<UInt8>, capacity: Int,
    name: ByteSlice, reading: (sequence: UInt32, value: Int)?
) -> Int? {
    var writer = WireCodec(profile: sensorNodeWireProfile()).writer(buffer: buffer, capacity: capacity)
    do throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeStringField("coreType", sensorNodeSlice(SensorNodeIdentity.coreType))
        try writer.writeComma()
        try writer.writeUUIDField("objectId", SensorNodeIdentity.object)
        try writer.writeComma()
        try writer.writeStringField("objectType", sensorNodeSlice(SensorNodeIdentity.objectType))
        try writer.writeComma()
        try writer.writeEscapedStringField("name", name)
        if let reading {
            try writer.writeComma()
            try writer.writeIntField("sequence", Int(reading.sequence))
            try writer.writeComma()
            try writer.writeIntField("value", reading.value)
        }
        try writer.endObject()
    } catch {
        return nil
    }
    return writer.position
}

/// The size of the largest legal sensor object in JSON, the larger encoding.
///
/// Every term is a worst case, in bytes:
///
/// - Fixed fields and punctuation: `{"coreType":"CoatyObject","objectId":"<36>",`
///   `"objectType":"axoloty.sensor.Node","name":` and the quotes around the name
///   come to 120.
/// - The name: `SensorNodeTiming.nameCapacity` (48) bytes, each of which the JSON
///   writer may escape to a six-byte `\u00XX`, so 288.
/// - `,"sequence":` is 12, and the largest `UInt32` (4294967295) is 10 digits.
/// - `,"value":` is 9, and the widest `Int` is `-9223372036854775808`, 20.
/// - The closing brace is 1.
///
/// 120 + 288 + 12 + 10 + 9 + 20 + 1 = 460. The earlier 192-byte buffer failed at
/// a 48-byte name with a large reading.
enum SensorObjectBound {
    static let fixedFieldBytes = 120
    static let nameBytes = SensorNodeTiming.nameCapacity * 6
    static let sequenceBytes = 12 + 10
    static let valueBytes = 9 + 20
    static let closingBytes = 1
    static let maximumJSONBytes = fixedFieldBytes + nameBytes + sequenceBytes + valueBytes + closingBytes
}

/// Encodes `{"object": <sensor object>}`, the body of Advertise, Resolve, and
/// Channel, and returns its length.
func encodeSensorObjectPayload(
    into payload: UnsafeMutablePointer<UInt8>, capacity: Int,
    name: ByteSlice, reading: (sequence: UInt32, value: Int)? = nil
) -> Int? {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: SensorObjectBound.maximumJSONBytes) { object -> Int? in
        guard let length = writeSensorObject(
            into: object.baseAddress!, capacity: object.count, name: name, reading: reading
        ) else { return nil }
        var writer = WireCodec(profile: sensorNodeWireProfile()).writer(buffer: payload, capacity: capacity)
        do throws(WireEncodeError) {
            try writer.beginObject()
            try writer.writeRawField("object", ByteSlice(bytes: UnsafePointer(object.baseAddress!), length: length))
            try writer.endObject()
        } catch {
            return nil
        }
        return writer.position
    }
}

/// Encodes `{"objectIds": [<sensor object id>]}`, the last-will Deadvertise
/// body, and returns its length.
func encodeSensorDeadvertisePayload(into payload: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int? {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 48) { ids -> Int? in
        var list = WireCodec(profile: sensorNodeWireProfile()).writer(buffer: ids.baseAddress!, capacity: ids.count)
        var writer = WireCodec(profile: sensorNodeWireProfile()).writer(buffer: payload, capacity: capacity)
        do throws(WireEncodeError) {
            try list.beginArray()
            try list.writeUUIDValue(SensorNodeIdentity.object)
            try list.endArray()
            try writer.beginObject()
            try writer.writeRawField("objectIds", ByteSlice(bytes: UnsafePointer(ids.baseAddress!), length: list.position))
            try writer.endObject()
        } catch {
            return nil
        }
        return writer.position
    }
}

/// Builds the profile route of one outbound frame and returns its length.
func writeSensorRoute(
    into topic: UnsafeMutablePointer<UInt8>, capacity: Int,
    event: WireEventType, filter: ByteSlice?, filterKind: ProtocolEventTypeFilterKind,
    source: UUID16, correlation: UUID16?
) -> Int? {
    var builder = TopicBuilder(buffer: topic, capacity: capacity)
    do throws(WireEncodeError) {
        try builder.writePrefix(sensorNodeWireProfile())
        try builder.writeNamespace(SensorNodeIdentity.namespace)
        try builder.writeEventType(event, filter: filter, filterKind: filterKind == .objectType ? .objectType : .direct)
        try builder.writeSourceId(source)
        if let correlation { try builder.writeCorrelationId(correlation) }
    } catch {
        return nil
    }
    return builder.position
}

/// Reports whether `haystack` holds the bytes of `needle`.
private func sliceContains(_ haystack: ByteSlice, _ needle: StaticString) -> Bool {
    let count = needle.utf8CodeUnitCount
    guard haystack.length >= count else { return false }
    for start in 0...(haystack.length - count) {
        var index = 0
        while index < count, haystack.byte(at: start + index) == needle.utf8Start[index] { index += 1 }
        if index == count { return true }
    }
    return false
}

/// Decides whether a Discover asks for this node's type.
///
/// A byte search over the requested type lists works on both profiles, since
/// each carries a type name as its literal UTF-8. It can match a longer name
/// that contains ours, which is an extra Resolve the requester filters. A
/// Discover by object identifier or external identifier is not answered.
func sensorDiscoverMatches(_ payload: ByteSlice) -> Bool {
    let reader = payload.withBytes { pointer, length in
        WireCodec(profile: sensorNodeWireProfile()).reader(
            bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length
        )
    }
    guard let discover = try? DiscoverWireData(from: reader) else { return false }
    if let types = discover.objectTypes, sliceContains(types, SensorNodeIdentity.objectType) { return true }
    if let types = discover.coreTypes, sliceContains(types, SensorNodeIdentity.coreType) { return true }
    return false
}
