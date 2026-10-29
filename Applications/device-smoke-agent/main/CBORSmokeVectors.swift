// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// `axoloty/1` smoke vectors for a build whose transport carries CBOR.
//
// A build without `_JSONCore` cannot run the `coaty/3` JSON vectors, so the
// device proves the CBOR codec instead: deterministic encodings, the UUID tag,
// malformed-input rejection, a wire DTO that keeps its object bytes, and one
// Advertise through the shared static runtime on the CBOR codec. Every vector
// uses fixed stack storage and the production Core APIs. The identifiers form
// the expected set of smoke protocol v3 in `Platforms/esp32c6-idf/tools/
// validate-smoke.mjs`; keep the two in step.

#if !canImport(_JSONCore)
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

private func cborCodec() -> WireCodec {
    WireCodec(profile: .axoloty1CBOR)
}

@inline(__always)
private func slice(_ text: StaticString) -> ByteSlice {
    ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
}

/// Reports whether `bytes`, a tuple of `UInt8`, fails CBOR validation.
@inline(__always)
private func cborRejects<T>(_ bytes: T) -> Bool {
    withUnsafeBytes(of: bytes) { raw in
        let reader = cborCodec().reader(
            bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), length: raw.count
        )
        return (try? reader.validate()) == nil
    }
}

/// Runs `body` over a reader of `bytes`, a tuple of `UInt8`.
@inline(__always)
private func withCBORReader<T>(_ bytes: T, _ body: (WireReader) -> Bool) -> Bool {
    withUnsafeBytes(of: bytes) { raw in
        body(cborCodec().reader(
            bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), length: raw.count
        ))
    }
}

/// Compares `count` bytes at `actual` with the bytes of `expected`, a tuple of `UInt8`.
@inline(__always)
private func bytesEqual<T>(_ actual: UnsafePointer<UInt8>, _ count: Int, _ expected: T) -> Bool {
    withUnsafeBytes(of: expected) { want in
        guard want.count == count else { return false }
        for index in 0..<count where actual[index] != want[index] { return false }
        return true
    }
}

/// Encodes one integer and compares it with its deterministic form.
@inline(never)
private func integerVector<T>(
    _ id: StaticString, _ value: Int, _ expected: T, _ record: (StaticString, Bool) -> Void
) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { storage in
        var writer = cborCodec().writer(buffer: storage.baseAddress!, capacity: storage.count)
        let wrote = (try? writer.writeInt(value)) != nil
        record(id, wrote && bytesEqual(UnsafePointer(storage.baseAddress!), writer.position, expected))
    }
}

@inline(never)
private func runIntegerVectors(_ record: (StaticString, Bool) -> Void) {
    integerVector("cbor:writeInt:zero", 0, UInt8(0x00), record)
    integerVector("cbor:writeInt:one", 1, UInt8(0x01), record)
    integerVector("cbor:writeInt:minusOne", -1, UInt8(0x20), record)
    integerVector("cbor:writeInt:23", 23, UInt8(0x17), record)
    integerVector("cbor:writeInt:24", 24, (UInt8(0x18), UInt8(0x18)), record)
    integerVector("cbor:writeInt:255", 255, (UInt8(0x18), UInt8(0xFF)), record)
    integerVector("cbor:writeInt:256", 256, (UInt8(0x19), UInt8(0x01), UInt8(0x00)), record)
    integerVector("cbor:writeInt:65536", 65_536,
                  (UInt8(0x1A), UInt8(0x00), UInt8(0x01), UInt8(0x00), UInt8(0x00)), record)
    integerVector("cbor:writeInt:minus25", -25, (UInt8(0x38), UInt8(0x18)), record)
    // The extremes depend on the target's `Int` width, as the JSON vectors do.
    if MemoryLayout<Int>.size == 4 {
        integerVector("cbor:writeInt:max", Int.max,
                      (UInt8(0x1A), UInt8(0x7F), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF)), record)
        integerVector("cbor:writeInt:min", Int.min,
                      (UInt8(0x3A), UInt8(0x7F), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF)), record)
    } else {
        integerVector("cbor:writeInt:max", Int.max,
                      (UInt8(0x1B), UInt8(0x7F), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF),
                       UInt8(0xFF), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF)), record)
        integerVector("cbor:writeInt:min", Int.min,
                      (UInt8(0x3B), UInt8(0x7F), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF),
                       UInt8(0xFF), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF)), record)
    }
}

/// The map `{"n": 7, "name": "cat"}` in deterministic form: keys sort by length, then bytes.
private typealias ObjectBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private func objectBytes() -> ObjectBytes {
    (0xA2, 0x61, 0x6E, 0x07, 0x64, 0x6E, 0x61, 0x6D, 0x65, 0x63, 0x63, 0x61, 0x74)
}

@inline(never)
private func runObjectVectors(_ record: (StaticString, Bool) -> Void) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { storage in
        var writer = cborCodec().writer(buffer: storage.baseAddress!, capacity: storage.count)
        var wrote = (try? writer.beginObject()) != nil
        if wrote { wrote = (try? writer.writeIntField("n", 7)) != nil }
        if wrote { wrote = (try? writer.writeStringField("name", slice("cat"))) != nil }
        if wrote { wrote = (try? writer.endObject()) != nil }
        record("cbor:write:object",
               wrote && bytesEqual(UnsafePointer(storage.baseAddress!), writer.position, objectBytes()))
    }
    record("cbor:read:object", withCBORReader(objectBytes()) { reader in
        guard (try? reader.validate()) != nil, reader.readInt("n") == 7,
              let name = reader.readString("name") else { return false }
        return name.equals(slice("cat"))
    })
    record("cbor:read:missing", withCBORReader(objectBytes()) { reader in
        reader.readInt("other") == nil && reader.readString("n") == nil
    })
}

/// Copies `text` into `storage` at `offset` and returns the offset after it.
@inline(__always)
private func append(_ text: StaticString, to storage: UnsafeMutablePointer<UInt8>, at offset: Int) -> Int {
    for index in 0..<text.utf8CodeUnitCount { storage[offset + index] = text.utf8Start[index] }
    return offset + text.utf8CodeUnitCount
}

@inline(never)
private func runUUIDVectors(_ record: (StaticString, Bool) -> Void) {
    let text: StaticString = "11111111-1111-4111-8111-111111111111"
    guard let uuid = UUID16(parsing: slice(text)) else {
        record("cbor:uuid:encodeTag37", false)
        record("cbor:uuid:decodeTag37", false)
        record("cbor:uuid:decodeText", false)
        record("cbor:uuid:rejectWrongLength", false)
        return
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 48) { storage in
        let base = storage.baseAddress!
        var writer = cborCodec().writer(buffer: base, capacity: storage.count)
        var wrote = (try? writer.beginObject()) != nil
        if wrote { wrote = (try? writer.writeUUIDField("objectId", uuid)) != nil }
        if wrote { wrote = (try? writer.endObject()) != nil }
        // map(1), "objectId", tag 37, bytes(16)
        var ok = wrote && writer.position == 29 && base[0] == 0xA1 && base[1] == 0x68
        ok = ok && base[10] == 0xD8 && base[11] == 0x25 && base[12] == 0x50
        var index = 0
        while ok && index < 16 {
            let want: UInt8 = (index == 6) ? 0x41 : (index == 8 ? 0x81 : 0x11)
            ok = base[13 + index] == want
            index += 1
        }
        record("cbor:uuid:encodeTag37", ok)
        let length = writer.position
        record("cbor:uuid:decodeTag37", ok && {
            let reader = cborCodec().reader(bytes: UnsafePointer(base), length: length)
            return (try? reader.validate()) != nil && reader.readUUID("objectId") == uuid
        }())
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 48) { storage in
        let base = storage.baseAddress!
        // map(1), "objectId", text(36) in the canonical hyphenated form.
        base[0] = 0xA1
        base[1] = 0x68
        var offset = append("objectId", to: base, at: 2)
        base[offset] = 0x78
        base[offset + 1] = 0x24
        offset = append(text, to: base, at: offset + 2)
        let reader = cborCodec().reader(bytes: UnsafePointer(base), length: offset)
        record("cbor:uuid:decodeText", (try? reader.validate()) != nil && reader.readUUID("objectId") == uuid)
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 48) { storage in
        let base = storage.baseAddress!
        // tag 37 over a 15-byte string is not a UUID.
        base[0] = 0xA1
        base[1] = 0x68
        var offset = append("objectId", to: base, at: 2)
        base[offset] = 0xD8
        base[offset + 1] = 0x25
        base[offset + 2] = 0x4F
        offset += 3
        for _ in 0..<15 {
            base[offset] = 0x11
            offset += 1
        }
        let reader = cborCodec().reader(bytes: UnsafePointer(base), length: offset)
        record("cbor:uuid:rejectWrongLength", reader.readUUID("objectId") == nil)
    }
}

@inline(never)
private func runMalformedVectors(_ record: (StaticString, Bool) -> Void) {
    // indefinite-length map
    record("cbor:malformed:indefinite",
           cborRejects((UInt8(0xBF), UInt8(0x61), UInt8(0x61), UInt8(0x00), UInt8(0xFF))))
    // the integer 0 in the one-byte form
    record("cbor:malformed:nonMinimalInt",
           cborRejects((UInt8(0xA1), UInt8(0x61), UInt8(0x61), UInt8(0x18), UInt8(0x00))))
    record("cbor:malformed:duplicateKey",
           cborRejects((UInt8(0xA2), UInt8(0x61), UInt8(0x61), UInt8(0x00),
                        UInt8(0x61), UInt8(0x61), UInt8(0x01))))
    record("cbor:malformed:truncated", cborRejects((UInt8(0xA1), UInt8(0x61), UInt8(0x61))))
    record("cbor:malformed:trailing",
           cborRejects((UInt8(0xA1), UInt8(0x61), UInt8(0x61), UInt8(0x00), UInt8(0x00))))
    // text(2) holding the invalid UTF-8 sequence C3 28
    record("cbor:malformed:invalidUTF8",
           cborRejects((UInt8(0xA1), UInt8(0x61), UInt8(0x61), UInt8(0x62), UInt8(0xC3), UInt8(0x28))))
    // tag 2 (bignum) is outside the allow-list
    record("cbor:malformed:disallowedTag",
           cborRejects((UInt8(0xA1), UInt8(0x61), UInt8(0x61), UInt8(0xC2), UInt8(0x41), UInt8(0x01))))
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4) { storage in
        let reader = cborCodec().reader(bytes: UnsafePointer(storage.baseAddress!), length: 0)
        record("cbor:malformed:empty", (try? reader.validate()) == nil)
    }
    // 40 nested arrays exceed the bound of 32 levels
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { storage in
        let base = storage.baseAddress!
        base[0] = 0xA1
        base[1] = 0x61
        base[2] = 0x61
        var offset = 3
        for _ in 0..<40 {
            base[offset] = 0x81
            offset += 1
        }
        base[offset] = 0x00
        let reader = cborCodec().reader(bytes: UnsafePointer(base), length: offset + 1)
        record("cbor:malformed:nesting", (try? reader.validate()) == nil)
    }
}

/// Writes the `object` payload of an Advertise: an object with the four required members.
@inline(__always)
private func writeObject(
    _ writer: inout WireWriter, _ uuid: UUID16
) -> Bool {
    var ok = (try? writer.beginObject()) != nil
    if ok { ok = (try? writer.writeStringField("name", slice("sensor"))) != nil }
    if ok { ok = (try? writer.writeStringField("coreType", slice("CoatyObject"))) != nil }
    if ok { ok = (try? writer.writeUUIDField("objectId", uuid)) != nil }
    if ok { ok = (try? writer.writeStringField("objectType", slice("com.example.Sensor"))) != nil }
    if ok { ok = (try? writer.endObject()) != nil }
    return ok
}

@inline(never)
private func runAdvertiseVectors(_ record: (StaticString, Bool) -> Void) {
    guard let uuid = UUID16(parsing: slice("11111111-1111-4111-8111-111111111111")) else {
        record("cbor:dto:advertise", false)
        record("cbor:static:advertise", false)
        return
    }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 192) { objectStorage in
        let objectBase = objectStorage.baseAddress!
        var objectWriter = cborCodec().writer(buffer: objectBase, capacity: objectStorage.count)
        guard writeObject(&objectWriter, uuid) else {
            record("cbor:dto:advertise", false)
            record("cbor:static:advertise", false)
            return
        }
        let objectLength = objectWriter.position
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { payloadStorage in
            let payloadBase = payloadStorage.baseAddress!
            var payloadWriter = cborCodec().writer(buffer: payloadBase, capacity: payloadStorage.count)
            var wrote = (try? payloadWriter.beginObject()) != nil
            if wrote {
                wrote = (try? payloadWriter.writeRawField(
                    "object", ByteSlice(bytes: UnsafePointer(objectBase), length: objectLength)
                )) != nil
            }
            if wrote { wrote = (try? payloadWriter.endObject()) != nil }
            let payloadLength = payloadWriter.position

            // The DTO keeps the object's exact bytes.
            var preserved = false
            if wrote {
                let reader = cborCodec().reader(bytes: UnsafePointer(payloadBase), length: payloadLength)
                if let data = try? AdvertiseWireData(from: reader) {
                    preserved = data.object.length == objectLength && data.object.equals(
                        ByteSlice(bytes: UnsafePointer(objectBase), length: objectLength)
                    )
                }
            }
            record("cbor:dto:advertise", preserved)

            record("cbor:static:advertise", wrote && advertiseThroughStaticRuntime(
                uuid, UnsafePointer(payloadBase), payloadLength
            ))
        }
    }
}

/// Advertises through one static runtime that selected the CBOR codec.
@inline(never)
private func advertiseThroughStaticRuntime(
    _ source: UUID16, _ payload: UnsafePointer<UInt8>, _ length: Int
) -> Bool {
    guard var runtime = try? StaticRuntime<2, 256>(
        registryID: ObjectID(uuid: source), wireCodec: cborCodec()
    ) else { return false }
    guard let operation = try? ProtocolLocalOperation(
        capability: .advertise, sourceID: source,
        payload: ByteSlice(bytes: payload, length: length)
    ) else { return false }
    let outcome = runtime.send(operation)
    let accepted = outcome == .accepted && runtime.state.activeObjects == 1 && runtime.actionCount == 2
    return accepted && runtime.drain { _ in } == 2
}

/// Runs the `axoloty/1` vectors of smoke protocol v3.
@inline(never)
func runCBORSmokeVectors(_ record: (StaticString, Bool) -> Void) {
    runIntegerVectors(record)
    runObjectVectors(record)
    runUUIDVectors(record)
    runMalformedVectors(record)
    runAdvertiseVectors(record)
}
#endif
