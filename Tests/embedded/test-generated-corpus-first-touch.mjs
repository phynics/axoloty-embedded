// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function findExecutable(candidates) {
  for (const candidate of candidates) {
    if (candidate.includes(path.sep)) {
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      } catch {
        continue;
      }
    }
    for (const directory of (process.env.PATH ?? "").split(path.delimiter)) {
      const executable = path.join(directory, candidate);
      try {
        fs.accessSync(executable, fs.constants.X_OK);
        return executable;
      } catch {
        continue;
      }
    }
  }
  return undefined;
}

function discoverTool(override, candidates, label) {
  const executable = findExecutable(override ? [override] : candidates);
  if (!executable) {
    const requested = override ? `the ${label} override ${override}` : candidates.join(" or ");
    process.stderr.write(`UNAVAILABLE: required ${label} not found (${requested})\n`);
    process.exitCode = 69;
  }
  return executable;
}

const swiftc = discoverTool(process.env.SWIFTC, ["swiftc"], "Swift compiler");
const objdump = discoverTool(process.env.OBJDUMP, ["riscv32-esp-elf-objdump", "llvm-objdump"], "RISC-V object dumper");
const nm = discoverTool(process.env.NM, ["riscv32-esp-elf-nm", "llvm-nm"], "symbol dumper");
if (process.exitCode === 69) {
  process.exit(69);
}
process.stdout.write(`Using Swift compiler: ${swiftc}\n`);
process.stdout.write(`Using RISC-V object dumper: ${objdump}\n`);
process.stdout.write(`Using symbol dumper: ${nm}\n`);

const fixtureDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-generated-first-touch-"));
const generatedPath = path.join(fixtureDirectory, "GeneratedCorpus.swift");
const fixturePath = path.join(fixtureDirectory, "FirstTouchFixture.swift");
const executablePath = path.join(fixtureDirectory, "first-touch-fixture");
const objectPath = path.join(fixtureDirectory, "first-touch-riscv.o");
const symbolsPath = path.join(fixtureDirectory, "first-touch-riscv-symbols.txt");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: repoRoot, encoding: "utf8", ...options });
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    throw new Error(`${command} ${args.join(" ")} exited ${result.status}`);
  }
  return result.stdout;
}

try {
  const generator = "Applications/device-smoke-agent/fixtures/generate-embedded-corpus.mjs";
  const manifest = "Applications/device-smoke-agent/fixtures/manifest.json";
  run("node", [generator, manifest, generatedPath]);
  const generated = fs.readFileSync(generatedPath, "utf8");
  assert.match(generated, /private var embeddedCorpusParserWorkspace = EmbeddedWireParserWorkspace\(\)/);
  assert.match(generated, /private var embeddedCorpusEncodeBuffer = InlineArray<2_048, UInt8>\(repeating: 0\)/);
  assert.match(generated, /private var embeddedBenchmarkSink: UInt32 = 0/);

  const hookMatch = generated.match(/func initializeEmbeddedGeneratedCorpusStaticState\(\) \{[\s\S]*?\n\}/);
  assert.ok(hookMatch, "production generated corpus first-touch hook is missing");
  assert.match(hookMatch[0], /embeddedCorpusParserWorkspace\.withStorage \{ bytes in/);
  assert.match(hookMatch[0], /bytes\.count == 2_056 && bytes\[0\] == 0/);
  assert.doesNotMatch(hookMatch[0], /WireReader|withUnsafeMutableBytes|embeddedBenchmarkSink/);
  const application = fs.readFileSync(path.join(repoRoot, "Applications/device-smoke-agent/main/EmbeddedApplication.swift"), "utf8");
  assert.match(application, /static func initializeStaticState\(\) \{[\s\S]*?initializeEmbeddedGeneratedCorpusStaticState\(\)[\s\S]*?initializeEmbeddedConstructedSchemaStaticState\(\)/);

  const schemaSource = fs.readFileSync(path.join(repoRoot, "Applications/device-smoke-agent/main/ObjectModelModuleConsumer.swift"), "utf8");
  const schemaHook = schemaSource.match(/func initializeEmbeddedConstructedSchemaStaticState\(\) \{[\s\S]*?\n\}/)?.[0] ?? "";
  assert.ok(schemaHook, "same-file constructed-schema first-touch helper is missing");
  assert.match(schemaHook, /precondition\(EmbeddedConstructedSchema\.schema\.fieldCount == 0\)/);

  const fixture = `
private nonisolated(unsafe) var fixtureInitializations: UInt8 = 0
private nonisolated(unsafe) var fixtureSchemaInitializations: UInt8 = 0
private nonisolated(unsafe) var fixtureHookActive = false

struct EmbeddedWireParserWorkspace {
    private var storage = InlineArray<2_056, UInt8>(repeating: 0)
    init() {
        precondition(fixtureHookActive)
        fixtureInitializations &+= 1
    }
    mutating func withStorage<R>(_ body: (UnsafeMutableBufferPointer<UInt8>) -> R) -> R {
        withUnsafeMutableBytes(of: &storage) { raw in
            body(UnsafeMutableBufferPointer(
                start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                count: raw.count
            ))
        }
    }
}

struct FixtureSchema {
    let fieldCount: UInt8
    let payload: InlineArray<555, UInt8>
}

private func makeFixtureSchema() -> FixtureSchema {
    precondition(fixtureHookActive)
    fixtureSchemaInitializations &+= 1
    return FixtureSchema(fieldCount: 0, payload: InlineArray(repeating: 0))
}

enum EmbeddedConstructedSchema {
    static let schema = makeFixtureSchema()
}

private var embeddedCorpusParserWorkspace = EmbeddedWireParserWorkspace()
struct EncodeBufferFixture {
    var firstByte: UInt8 = 0
    subscript(index: Int) -> UInt8 {
        get { precondition(index == 0); return firstByte }
        set { precondition(index == 0); firstByte = newValue }
    }
}
private var embeddedCorpusEncodeBuffer = EncodeBufferFixture()

${hookMatch[0]}

${schemaHook}

#if HOST_FIXTURE
@main
struct FirstTouchFixture {
    static func main() {
        precondition(fixtureInitializations == 0 && fixtureSchemaInitializations == 0)
        fixtureHookActive = true
        initializeEmbeddedGeneratedCorpusStaticState()
        initializeEmbeddedConstructedSchemaStaticState()
        fixtureHookActive = false
        precondition(fixtureInitializations == 1)
        precondition(fixtureSchemaInitializations == 1)
        precondition(embeddedCorpusEncodeBuffer[0] == 0)
        print("PASS: generated workspace storage and constructed schema first initialize inside the hook")
    }
}
#else
@_cdecl("generated_corpus_first_touch_entry")
public func generatedCorpusFirstTouchEntry() {
    initializeEmbeddedGeneratedCorpusStaticState()
    initializeEmbeddedConstructedSchemaStaticState()
}
#endif
`;
  fs.writeFileSync(fixturePath, fixture);

  run(swiftc, ["-Osize", "-parse-as-library", "-DHOST_FIXTURE", "-module-name", "GeneratedCorpusFirstTouchFixture", fixturePath, "-o", executablePath]);
  process.stdout.write(run(executablePath, []));

  run(swiftc, [
    "-target", "riscv32-none-none-eabi",
    "-enable-experimental-feature", "Embedded",
    "-enable-experimental-feature", "Lifetimes",
    "-Osize", "-wmo", "-parse-as-library",
    "-Xfrontend", "-enable-single-module-llvm-emission",
    "-Xfrontend", "-function-sections", "-emit-object",
    "-module-name", "GeneratedCorpusFirstTouch",
    fixturePath, "-o", objectPath,
  ]);
  const disassembly = run(objdump, ["-dr", objectPath]);
  const symbols = run(nm, ["-S", "-a", objectPath]);
  const disassemblyPath = path.join(fixtureDirectory, "riscv-disassembly.txt");
  fs.writeFileSync(disassemblyPath, disassembly);
  fs.writeFileSync(symbolsPath, symbols);
  if (process.env.FIRST_TOUCH_EVIDENCE_DIR) {
    fs.mkdirSync(process.env.FIRST_TOUCH_EVIDENCE_DIR, { recursive: true });
    for (const file of [generatedPath, fixturePath, executablePath, objectPath, disassemblyPath, symbolsPath]) {
      fs.copyFileSync(file, path.join(process.env.FIRST_TOUCH_EVIDENCE_DIR, path.basename(file)));
    }
  }

  const entry = disassembly.match(/<generated_corpus_first_touch_entry>:[\s\S]*?(?=\n\n|$)/)?.[0] ?? "";
  assert.ok(entry, "optimized RISC-V object has no generated first-touch entry symbol");
  assert.match(entry, /R_RISCV_CALL(?:_PLT)?\s+.*generatedbcD5Entry/,
    "optimized RISC-V C entry no longer reaches the generated Swift first-touch entry");
  const parserStorage = symbols.match(/\bB\s+\$e[^\s]*embeddedB15ParserWorkspace[^\s]*vp/);
  assert.ok(parserStorage, "optimized RISC-V fixture has no zero-backed parser workspace storage");
  assert.match(symbols, /embeddedB15ParserWorkspace[^\n]*_Wz/,
    "observable parser fixture has no dynamic first-initialization guard");
  assert.match(symbols, /EmbeddedConstructedSchemaO6schema_Wz/,
    "observable schema fixture has no dynamic first-initialization guard");
  assert.match(symbols, /\bB\s+\$e[^\s]*embeddedB12EncodeBuffer[^\s]*vp/,
    "optimized RISC-V fixture has no zero-backed encode storage symbol");
  assert.doesNotMatch(symbols, /embeddedB12EncodeBuffer.*_Wz/,
    "fixture no longer models encode storage as valid zero-backed static data");

  const firstTouch = disassembly.match(/Disassembly of section [^\n]*generatedbcD5Entry[^\n]*:\n[\s\S]*?(?=\nDisassembly of section |$)/)?.[0] ?? "";
  assert.ok(firstTouch, "optimized RISC-V object has no retained Swift first-touch entry section");
  const frame = firstTouch.match(/addi\s+sp,\s*sp,\s*-(\d+)/);
  assert.ok(!frame || Number(frame[1]) < 128, `first-touch fixture has a large frame (${frame?.[1]} bytes)`);
  assert.match(firstTouch, /\blbu\b/, "optimized first-touch entry has no consumed scalar projection");
  process.stdout.write(`RISC-V optimized object: ${objectPath}\n`);
  process.stdout.write(`RISC-V disassembly: ${disassemblyPath}\n`);
} finally {
  if (process.env.KEEP_FIRST_TOUCH_FIXTURE !== "1") {
    fs.rmSync(fixtureDirectory, { recursive: true, force: true });
  } else {
    process.stdout.write(`fixture directory retained: ${fixtureDirectory}\n`);
  }
}
