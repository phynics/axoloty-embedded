// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Opt-in linker probe. String decoding plus equality deliberately requires
// the Embedded Swift Unicode data tables and reproduces the `.got.plt`
// failure fixed by linker.lf.

@c @implementation public func axoloty_unicode_linker_probe(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int32
) -> Int32 {
    let buffer = UnsafeBufferPointer(start: bytes, count: Int(length))
    let value = String(decoding: buffer, as: UTF8.self)
    return value == "axoloty" ? 1 : 0
}
