// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const [manifestPath, outputPath] = process.argv.slice(2);
if (!manifestPath || !outputPath) {
  throw new Error("usage: generate-embedded-corpus.mjs MANIFEST OUTPUT");
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const corpusDirectory = path.dirname(manifestPath);
// Test-time corpus selectors. A device matrix (13 wire families x 3 size
// classes) makes the benchmark a mean over every case; selecting one size
// class, or one exact case, splits a metric by payload size. Both are unset in
// normal builds, so the full 39-case corpus is generated.
const sizeFilter = process.env.AXOLOTY_CORPUS_SIZE;
const caseFilter = process.env.AXOLOTY_CORPUS_CASE;
if (sizeFilter && caseFilter) {
  throw new Error("set at most one of AXOLOTY_CORPUS_SIZE and AXOLOTY_CORPUS_CASE");
}
if (sizeFilter) {
  const filtered = manifest.cases.filter(corpusCase => corpusCase.sizeClass === sizeFilter);
  if (filtered.length === 0) throw new Error(`no corpus cases with sizeClass ${sizeFilter}`);
  manifest.cases = filtered;
}
if (caseFilter) {
  const filtered = manifest.cases.filter(corpusCase => corpusCase.id === caseFilter);
  if (filtered.length === 0) throw new Error(`no corpus case with id ${caseFilter}`);
  manifest.cases = filtered;
}
const dtoByFamily = {
  ADV: "AdvertiseWireData", ASC: "AssociateWireData", CHN: "ChannelWireData",
  CLL: "CallWireData", CPL: "CompleteWireData", DAD: "DeadvertiseWireData",
  DSC: "DiscoverWireData", IOV: "IoValueWireData", QRY: "QueryWireData",
  RSV: "ResolveWireData", RTN: "ReturnWireData", RTV: "RetrieveWireData",
  UPD: "UpdateWireData",
};
const eventByFamily = {
  ADV: "advertise", ASC: "associate", CHN: "channel", CLL: "call",
  CPL: "complete", DAD: "deadvertise", DSC: "discover", IOV: "ioValue",
  QRY: "query", RSV: "resolve", RTN: "returnEvent", RTV: "retrieve",
  UPD: "update",
};

function swiftLiteral(value) {
  let result = '"';
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (character === '"') result += '\\"';
    else if (character === "\\") result += "\\\\";
    else if (character === "\n") result += "\\n";
    else if (character === "\r") result += "\\r";
    else if (character === "\t") result += "\\t";
    else if (codePoint < 0x20 || codePoint > 0x7e) result += `\\u{${codePoint.toString(16)}}`;
    else result += character;
  }
  return `${result}"`;
}

const corpusConstants = manifest.cases.map((corpusCase, index) => {
  const payload = fs.readFileSync(path.join(corpusDirectory, corpusCase.payloadFile), "utf8");
  return `private let corpusTopic${index}: StaticString = ${swiftLiteral(corpusCase.topic)}
private let corpusPayload${index}: StaticString = ${swiftLiteral(payload)}`;
}).join("\n");

const invocations = manifest.cases.map((corpusCase, index) => {
  const dto = dtoByFamily[corpusCase.family];
  const event = eventByFamily[corpusCase.family];
  if (!dto || !event) throw new Error(`unsupported corpus family: ${corpusCase.family}`);
  return `    runCorpusCase(
        topicParseId: ${swiftLiteral(`corpus:${corpusCase.id}:topicParse`)},
        decodeId: ${swiftLiteral(`corpus:${corpusCase.id}:dtoDecode`)},
        encodeId: ${swiftLiteral(`corpus:${corpusCase.id}:dtoEncode`)},
        combinedId: ${swiftLiteral(`corpus:${corpusCase.id}:combined`)},
        borrowedId: ${swiftLiteral(`corpus:${corpusCase.id}:borrowed`)},
        topicBuildId: ${swiftLiteral(`corpus:${corpusCase.id}:topicBuild`)},
        topic: corpusTopic${index},
        payload: corpusPayload${index}, eventType: .${event}, dto: ${dto}.self,
        record: record
    )`;
}).join("\n");

const topicBenchmarkStatements = manifest.cases.map((corpusCase, index) =>
  `    if TopicView(topicBytes: corpusTopic${index}.utf8Start, length: corpusTopic${index}.utf8CodeUnitCount).eventType == .${eventByFamily[corpusCase.family]} { result &+= 1 }`,
).join("\n");
const decodeBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if (try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index}))) != nil { result &+= 1 }`;
}).join("\n");
const readerBenchmarkStatements = manifest.cases.map((corpusCase, index) =>
  `    if corpusReader(corpusPayload${index}).length >= 0 { result &+= 1 }`,
).join("\n");
const encodeBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if let decoded = try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index})) {
        withCorpusEncodeBuffer { output in
            var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
            if (try? decoded.encode(to: &writer)) != nil { result &+= 1 }
        }
    }`;
}).join("\n");
const combinedBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if TopicView(topicBytes: corpusTopic${index}.utf8Start, length: corpusTopic${index}.utf8CodeUnitCount).eventType == .${eventByFamily[corpusCase.family]} && (try? ${dtoByFamily[corpusCase.family]}(from: corpusReader(corpusPayload${index}))) != nil { result &+= 1 }`;
}).join("\n");
const borrowedBenchmarkStatements = manifest.cases.map((corpusCase, index) => {
  return `    if (try? BorrowedMessage.validated(topicBytes: corpusTopic${index}.utf8Start, topicLength: corpusTopic${index}.utf8CodeUnitCount, payloadBytes: corpusPayload${index}.utf8Start, payloadLength: corpusPayload${index}.utf8CodeUnitCount)) != nil { result &+= 1 }`;
}).join("\n");

// Deterministic `axoloty/1` encoding of each corpus payload, for the build that
// carries CBOR and no JSON parser. It follows the profile rules: shortest-form
// heads, definite lengths, map keys ordered by length and then bytes, and the
// shortest lossless single or double float. The device decodes and re-encodes
// every case before it times anything, so a divergence from the Core codec
// fails the measurement instead of skewing it.
function cborHead(major, argument) {
  const base = major << 5;
  if (argument < 24) return [base | argument];
  if (argument < 0x100) return [base | 24, argument];
  if (argument < 0x10000) return [base | 25, argument >> 8, argument & 0xff];
  if (argument < 0x100000000) {
    return [base | 26, argument >>> 24, (argument >> 16) & 0xff, (argument >> 8) & 0xff, argument & 0xff];
  }
  throw new Error("corpus integers above 32 bits are not supported");
}

function cborEncode(value) {
  if (value === null) return [0xf6];
  if (value === true) return [0xf5];
  if (value === false) return [0xf4];
  if (typeof value === "number") {
    if (Number.isInteger(value)) {
      return value >= 0 ? cborHead(0, value) : cborHead(1, -1 - value);
    }
    const single = Buffer.alloc(4);
    single.writeFloatBE(value);
    if (single.readFloatBE() === value) return [0xfa, ...single];
    const double = Buffer.alloc(8);
    double.writeDoubleBE(value);
    return [0xfb, ...double];
  }
  if (typeof value === "string") {
    const bytes = [...Buffer.from(value, "utf8")];
    return [...cborHead(3, bytes.length), ...bytes];
  }
  if (Array.isArray(value)) {
    return [...cborHead(4, value.length), ...value.flatMap(cborEncode)];
  }
  const members = Object.entries(value).map(([key, member]) => [Buffer.from(key, "utf8"), member]);
  members.sort(([left], [right]) => left.length - right.length || Buffer.compare(left, right));
  return [
    ...cborHead(5, members.length),
    ...members.flatMap(([key, member]) => [...cborHead(3, key.length), ...key, ...cborEncode(member)]),
  ];
}

const cborCorpus = manifest.cases.map(corpusCase => {
  const text = fs.readFileSync(path.join(corpusDirectory, corpusCase.payloadFile), "utf8");
  return Buffer.from(cborEncode(JSON.parse(text)));
});
let cborTotalBytes = 0;
const cborOffsets = cborCorpus.map(bytes => {
  const offset = cborTotalBytes;
  cborTotalBytes += bytes.length;
  return offset;
});

// Swift string literals hold UTF-8, so the CBOR bytes travel as hex text and
// the build decodes them once into zero-backed storage.
const cborConstants = cborCorpus.map((bytes, index) =>
  `private let corpusCBOR${index}: StaticString = "${bytes.toString("hex")}"`,
).join("\n");
const cborLoads = cborCorpus.map((bytes, index) =>
  `    loaded = corpusLoadHex(corpusCBOR${index}, at: ${cborOffsets[index]}) && loaded`,
).join("\n");
const cborDecodeStatements = manifest.cases.map((corpusCase, index) =>
  `    if corpusDecodes(${dtoByFamily[corpusCase.family]}.self, ${cborOffsets[index]}, ${cborCorpus[index].length}) { result &+= 1 }`,
).join("\n");
const cborReaderStatements = manifest.cases.map((corpusCase, index) =>
  `    if corpusReaderBuilds(${cborOffsets[index]}, ${cborCorpus[index].length}) { result &+= 1 }`,
).join("\n");
const cborRoundTripStatements = manifest.cases.map((corpusCase, index) =>
  `    if corpusRoundTrips(${dtoByFamily[corpusCase.family]}.self, ${cborOffsets[index]}, ${cborCorpus[index].length}) { result &+= 1 }`,
).join("\n");

const source = `// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// Generated from Applications/device-smoke-agent/fixtures/manifest.json. Do not edit.

import AxolotyWire

struct EmbeddedBenchmarkMetrics {
    let topicParseP50ns: UInt32
    let topicParseP95ns: UInt32
    let readerP50ns: UInt32
    let readerP95ns: UInt32
    let dtoDecodeP50ns: UInt32
    let dtoDecodeP95ns: UInt32
    let dtoEncodeP50ns: UInt32
    let dtoEncodeP95ns: UInt32
    let combinedP50ns: UInt32
    let combinedP95ns: UInt32
    let borrowedP50ns: UInt32
    let borrowedP95ns: UInt32
}

#if canImport(_JSONCore)
${corpusConstants}

private var embeddedCorpusParserWorkspace = EmbeddedWireParserWorkspace()
private var embeddedCorpusEncodeBuffer = InlineArray<2_048, UInt8>(repeating: 0)

/// Borrows the parser workspace through its public storage API and checks its
/// defined zeroed storage without changing it or constructing a reader.
/// The encode buffer explicitly repeats zero, so its first declared UInt8
/// element is checked directly. embeddedBenchmarkSink is zero-backed BSS and
/// needs no dynamic first touch.
func initializeEmbeddedGeneratedCorpusStaticState() {
    let parserWorkspaceStartsZero = embeddedCorpusParserWorkspace.withStorage { bytes in
        bytes.count == 2_056 && bytes[0] == 0
    }
    let encodeBufferStartsZero = withUnsafePointer(to: &embeddedCorpusEncodeBuffer) {
        $0.pointee[0] == 0
    }
    precondition(parserWorkspaceStartsZero && encodeBufferStartsZero)
}

@inline(__always)
private func corpusReader(_ payload: StaticString) -> WireReader {
    WireReader(
        bytes: payload.utf8Start,
        length: payload.utf8CodeUnitCount,
        workspace: &embeddedCorpusParserWorkspace
    )
}

@inline(__always)
private func withCorpusEncodeBuffer<R>(
    _ body: (UnsafeMutableBufferPointer<UInt8>) -> R
) -> R {
    withUnsafeMutableBytes(of: &embeddedCorpusEncodeBuffer) { raw in
        body(UnsafeMutableBufferPointer(
            start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
            count: raw.count
        ))
    }
}

@inline(never)
private func topicBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${topicBenchmarkStatements}
    return result
}

@inline(never)
private func decodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${decodeBenchmarkStatements}
    return result
}

@inline(never)
private func readerBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${readerBenchmarkStatements}
    return result
}

@inline(never)
private func encodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${encodeBenchmarkStatements}
    return result
}

@inline(never)
private func combinedBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${combinedBenchmarkStatements}
    return result
}

@inline(never)
private func borrowedBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${borrowedBenchmarkStatements}
    return result
}

#endif

private var embeddedBenchmarkSink: UInt32 = 0

private func measureCorpusPass(_ pass: () -> UInt32) -> (UInt32, UInt32) {
    for warmupIndex in 0..<1000 {
        embeddedBenchmarkSink &+= pass()
        if warmupIndex & 15 == 15 { deviceSmokeSeam().delay(1) }
    }
    var batch = 1
    while true {
        let start = deviceSmokeSeam().nowMicroseconds()
        for _ in 0..<batch { embeddedBenchmarkSink &+= pass() }
        if deviceSmokeSeam().nowMicroseconds() - start >= 250_000 { break }
        deviceSmokeSeam().delay(1)
        batch &*= 2
    }
    return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 30) { samples in
        for sampleIndex in 0..<30 {
            deviceSmokeSeam().delay(1)
            let overheadStart = deviceSmokeSeam().nowMicroseconds()
            for _ in 0..<batch { embeddedBenchmarkSink &+= 1 }
            let overhead = deviceSmokeSeam().nowMicroseconds() - overheadStart
            let start = deviceSmokeSeam().nowMicroseconds()
            for _ in 0..<batch { embeddedBenchmarkSink &+= pass() }
            let elapsed = deviceSmokeSeam().nowMicroseconds() - start
            let netMicroseconds = elapsed > overhead ? elapsed - overhead : 0
            samples[sampleIndex] = UInt32((netMicroseconds * 1000) / Int64(batch * ${manifest.cases.length}))
        }
        for index in 1..<30 {
            let value = samples[index]
            var insertion = index
            while insertion > 0 && samples[insertion - 1] > value {
                samples[insertion] = samples[insertion - 1]
                insertion -= 1
            }
            samples[insertion] = value
        }
        return (samples[14], samples[28])
    }
}

#if canImport(_JSONCore)
func benchmarkGeneratedCorpus() -> EmbeddedBenchmarkMetrics {
    let topic = measureCorpusPass(topicBenchmarkPass)
    let reader = measureCorpusPass(readerBenchmarkPass)
    let decode = measureCorpusPass(decodeBenchmarkPass)
    let encode = measureCorpusPass(encodeBenchmarkPass)
    let combined = measureCorpusPass(combinedBenchmarkPass)
    let borrowed = measureCorpusPass(borrowedBenchmarkPass)
    return EmbeddedBenchmarkMetrics(
        topicParseP50ns: topic.0, topicParseP95ns: topic.1,
        readerP50ns: reader.0, readerP95ns: reader.1,
        dtoDecodeP50ns: decode.0, dtoDecodeP95ns: decode.1,
        dtoEncodeP50ns: encode.0, dtoEncodeP95ns: encode.1,
        combinedP50ns: combined.0, combinedP95ns: combined.1,
        borrowedP50ns: borrowed.0, borrowedP95ns: borrowed.1
    )
}

@inline(__always)
private func corpusBytesEqual(_ slice: ByteSlice, _ expected: StaticString) -> Bool {
    guard slice.length == expected.utf8CodeUnitCount else { return false }
    for index in 0..<slice.length where slice.byte(at: index) != expected.utf8Start[index] {
        return false
    }
    return true
}

private func runCorpusCase<T: WireDecodable & WireEncodable>(
    topicParseId: StaticString,
    decodeId: StaticString,
    encodeId: StaticString,
    combinedId: StaticString,
    borrowedId: StaticString,
    topicBuildId: StaticString,
    topic: StaticString,
    payload: StaticString,
    eventType: WireEventType,
    dto: T.Type,
    record: (StaticString, Bool) -> Void
) {
    let topicView = TopicView(topicBytes: topic.utf8Start, length: topic.utf8CodeUnitCount)
    record(topicParseId, topicView.eventType == eventType)

    let reader = corpusReader(payload)
    guard let decoded = try? T(from: reader) else {
        record(decodeId, false); record(encodeId, false); record(combinedId, false)
        record(borrowedId, false); record(topicBuildId, false)
        return
    }
    record(decodeId, true)

    withCorpusEncodeBuffer { output in
        var writer = WireWriter(buffer: output.baseAddress!, capacity: output.count)
        record(encodeId, (try? decoded.encode(to: &writer)) != nil && writer.position <= 2_048)
    }

    let combined = topicView.eventType == eventType && (try? T(from: reader)) != nil
    record(combinedId, combined)

    let borrowed = try? BorrowedMessage.validated(
        topicBytes: topic.utf8Start, topicLength: topic.utf8CodeUnitCount,
        payloadBytes: payload.utf8Start, payloadLength: payload.utf8CodeUnitCount
    )
    record(
        borrowedId,
        borrowed?.eventType == eventType &&
            borrowed?.reader(workspace: &embeddedCorpusParserWorkspace).length == payload.utf8CodeUnitCount
    )

    var built = false
    if let source = topicView.sourceIdLevel.flatMap(UUID16.init(parsing:)),
       let parsedType = topicView.eventType {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { output in
            var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
            var valid = (try? builder.writePrefix()) != nil
            if valid { valid = (try? builder.writeNamespace("bench")) != nil }
            if valid { valid = (try? builder.writeEventType(parsedType, filter: topicView.eventTypeFilter)) != nil }
            if valid { valid = (try? builder.writeSourceId(source)) != nil }
            if valid, let correlation = topicView.correlationIdLevel.flatMap(UUID16.init(parsing:)) {
                valid = (try? builder.writeCorrelationId(correlation)) != nil
            }
            built = valid && corpusBytesEqual(builder.build(), topic)
        }
    }
    record(topicBuildId, built)
}

func runGeneratedCorpus(_ record: (StaticString, Bool) -> Void) {
${invocations}
}
#else
// The corpus is \`coaty/3\` JSON. A build without the JSON parser carries the
// same logical payloads as deterministic \`axoloty/1\` CBOR instead, so the
// device times its own codec on the same 39 cases. The route-bound metrics
// (topic parse, combined, borrowed) stay zero: the CBOR routes differ from the
// corpus topics, and zero means unmeasured.
${cborConstants}

private var embeddedCorpusCBOR = InlineArray<${cborTotalBytes}, UInt8>(repeating: 0)
private var embeddedCorpusEncodeBuffer = InlineArray<2_048, UInt8>(repeating: 0)

/// Checks the zero-backed storage without changing it, as the JSON corpus does.
func initializeEmbeddedGeneratedCorpusStaticState() {
    let corpusStartsZero = withUnsafePointer(to: &embeddedCorpusCBOR) { $0.pointee[0] == 0 }
    let encodeBufferStartsZero = withUnsafePointer(to: &embeddedCorpusEncodeBuffer) {
        $0.pointee[0] == 0
    }
    precondition(corpusStartsZero && encodeBufferStartsZero)
}

@inline(__always)
private func corpusHexValue(_ character: UInt8) -> UInt8? {
    switch character {
    case 0x30...0x39: return character - 0x30
    case 0x61...0x66: return character - 0x61 + 10
    default: return nil
    }
}

/// Decodes \`hex\` into the corpus storage at \`offset\`.
@inline(never)
private func corpusLoadHex(_ hex: StaticString, at offset: Int) -> Bool {
    let count = hex.utf8CodeUnitCount / 2
    return withUnsafeMutableBytes(of: &embeddedCorpusCBOR) { raw in
        guard offset + count <= raw.count else { return false }
        for index in 0..<count {
            guard let high = corpusHexValue(hex.utf8Start[2 * index]),
                  let low = corpusHexValue(hex.utf8Start[2 * index + 1]) else { return false }
            raw[offset + index] = high << 4 | low
        }
        return true
    }
}

@inline(__always)
private func withCorpusReader<R>(
    _ offset: Int, _ length: Int, _ body: (WireReader) -> R
) -> R {
    // The mutable form borrows the storage in place; the read-only form copies it.
    withUnsafeMutableBytes(of: &embeddedCorpusCBOR) { raw in
        body(WireCodec(profile: .axoloty1CBOR).reader(
            bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, length: length
        ))
    }
}

@inline(__always)
private func corpusReaderBuilds(_ offset: Int, _ length: Int) -> Bool {
    withCorpusReader(offset, length) { $0.length == length }
}

@inline(__always)
private func corpusDecodes<T: WireDecodable>(_ type: T.Type, _ offset: Int, _ length: Int) -> Bool {
    withCorpusReader(offset, length) { (try? T(from: $0)) != nil }
}

/// Decodes the payload, then encodes the decoded value, like the JSON pass.
@inline(__always)
private func corpusRoundTrips<T: WireDecodable & WireEncodable>(
    _ type: T.Type, _ offset: Int, _ length: Int
) -> Bool {
    withCorpusReader(offset, length) { reader in
        guard let decoded = try? T(from: reader) else { return false }
        return withUnsafeMutableBytes(of: &embeddedCorpusEncodeBuffer) { output in
            var writer = WireCodec(profile: .axoloty1CBOR).writer(
                buffer: output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                capacity: output.count
            )
            return (try? decoded.encode(to: &writer)) != nil
        }
    }
}

@inline(never)
private func decodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${cborDecodeStatements}
    return result
}

@inline(never)
private func readerBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${cborReaderStatements}
    return result
}

@inline(never)
private func encodeBenchmarkPass() -> UInt32 {
    var result: UInt32 = 0
${cborRoundTripStatements}
    return result
}

@inline(never)
private func loadCorpus() -> Bool {
    var loaded = true
${cborLoads}
    return loaded
}

/// Times the CBOR codec over the corpus, or reports zeros when any case fails
/// to load, decode, or re-encode, so a wrong measurement cannot look valid.
func benchmarkGeneratedCorpus() -> EmbeddedBenchmarkMetrics {
    let unmeasured = EmbeddedBenchmarkMetrics(
        topicParseP50ns: 0, topicParseP95ns: 0, readerP50ns: 0, readerP95ns: 0,
        dtoDecodeP50ns: 0, dtoDecodeP95ns: 0, dtoEncodeP50ns: 0, dtoEncodeP95ns: 0,
        combinedP50ns: 0, combinedP95ns: 0, borrowedP50ns: 0, borrowedP95ns: 0
    )
    let cases = UInt32(${manifest.cases.length})
    guard loadCorpus(), decodeBenchmarkPass() == cases, encodeBenchmarkPass() == cases else {
        return unmeasured
    }
    let reader = measureCorpusPass(readerBenchmarkPass)
    let decode = measureCorpusPass(decodeBenchmarkPass)
    let encode = measureCorpusPass(encodeBenchmarkPass)
    return EmbeddedBenchmarkMetrics(
        topicParseP50ns: 0, topicParseP95ns: 0,
        readerP50ns: reader.0, readerP95ns: reader.1,
        dtoDecodeP50ns: decode.0, dtoDecodeP95ns: decode.1,
        dtoEncodeP50ns: encode.0, dtoEncodeP95ns: encode.1,
        combinedP50ns: 0, combinedP95ns: 0, borrowedP50ns: 0, borrowedP95ns: 0
    )
}

func runGeneratedCorpus(_ record: (StaticString, Bool) -> Void) {}
#endif
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, source);
