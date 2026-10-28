# Linked storage audit

`linked_storage_audit.py` measures a final ELF and its matching linker map. It
does not build firmware, inspect source trees, or claim complete source
ownership. Its output is measurement-only and keeps the exact ELF symbol union
separate from the conservative combined-object debit.

Run it with explicit final artifacts and the object identity exactly as it
appears in linker-map input rows:

```sh
python3 Tools/EmbeddedApplicationMacros/linked_storage_audit.py \
  --elf /path/to/axoloty-swift.elf \
  --map /path/to/axoloty-swift.map \
  --combined-object 'esp-idf/main/libmain.a(AgentExchange.swift.obj)' \
  --profile firmware-mqtt \
  --firmware-source-sha 745388f025dd6120335ebb9fcd8fbc627e9c901d \
  --core-sha f8c201f717e843d7b838ba1d9ff56bd5be729522 \
  --output linked-storage.json
```

The tool supports ELF32/ELF64 RISC-V files with standard section and symbol
tables. It enumerates every `SHF_ALLOC|SHF_WRITE` section, classifies known data,
BSS, reserved/runtime-boundary, and read-only-content sections, and rejects an
unknown writable-section category. It reports nonzero writable symbols, exact
symbol-range union bytes, `.data` and `.bss` section totals, and matching
writable linker-map input contributions. GNU ld section records may put the
input name and its address/size/object on separate lines. Every nonempty
writable ELF output range must match the map and be fully covered by input or
fill ranges; missing rows, gaps, out-of-range inputs, duplicate output headers,
malformed records, unsupported architectures, missing objects, and empty
object contributions fail with status 2. Merged linker inputs may overlap, so
coverage and the combined-object debit count address ranges once. Identical
symbol ranges are reported as aliases and counted once; conflicting symbol
overlaps fail.

The combined-object debit is the sum of its writable input contributions,
including map-recorded padding when present. It replaces the symbol-range
charges for aggregate accounting. Raw symbol names are retained; the default
measurement does not perform source-level ownership inference. A report always
marks source attribution incomplete and leaves storage-budget acceptance,
first-init trace, and stack proof pending. It does not claim that the image
does not allocate.

An app may opt into an explicit inventory join by passing `--inventory`:

```sh
python3 Tools/EmbeddedApplicationMacros/linked_storage_audit.py \
  --elf /path/to/axoloty-swift.elf \
  --map /path/to/axoloty-swift.map \
  --combined-object 'esp-idf/main/libmain.a(AgentExchange.swift.obj)' \
  --inventory Applications/device-smoke-agent/storage-inventory.json \
  --output linked-storage-with-inventory.json
```

The inventory lists logical owners, source references, exact expected raw ELF
names, and an SDK-neutral `expectedMapMember` basename (for example,
`AgentExchange.swift.obj`). The CLI's `--combined-object` retains the full
linker identity. The auditor accepts only explicit archive-member syntax such
as `path/libmain.a(AgentExchange.swift.obj)` or plain object syntax such as
`path/AgentExchange.swift.obj`, then requires both the inventory member and
the unique containing map input's full owner to match. A different archive
containing the same member fails the full-owner check. The report keeps the
logical inventory owner separate from the linker row's `linker_owner`. This
check verifies map containment and object identity; it does not prove source
ownership of bytes in the combined object.

Each source reference declares `sourceKind` as `swift-source` or
`generator-source`. The auditor checks whether the configured name occurs as
bytes in the configured file and reports that as `lexical-source-reference-only`
evidence. It does not parse Swift syntax, establish a declaration or scope, or
prove that the named file produced the ELF symbol. In particular, a generator
file is not a Swift compilation unit. Source coverage is always reported as
`complete: false` and `verified: false`; an inventory-supplied completeness
claim is retained only as an untrusted claim indicator.

The join reports symbol size, section, address range, map input, aliases, and
lazy-control candidates as separate exact identities. Missing, ambiguous, or
wrong-object identities fail the command with structured details. The
inventory is explicit and does not claim that source scanning found every
mutable app global. The conservative combined-object debit remains in force.
This opt-in join adds no budget ceiling and establishes no complete ownership,
heap behavior, or stack bounds. The default CLI and `--selftest` remain
unchanged.

The shared ESP-IDF post-link gate classifies the configured image from the
normalized `AXOLOTY_QUALIFICATION_CARRIER_SCENARIO` value in `CMakeCache.txt`.
A C-only carrier qualification writes a `not-applicable` policy receipt and
does not claim a budget pass. A normal Swift image with no capacity writes a
`not-configured` receipt; minimal apps remain valid. A supplied capacity must
be a positive UInt32. When configured, the gate requires the selected app's
storage inventory and derives the map member from its SDK-neutral
`expectedMapMember`, then enforces the policy before image, provenance, or
release-manifest publication. The full archive owner remains
platform/composition-owned.

The CLI requires `--app-manifest` to be paired with
`--enforce-static-storage-budget`; passing the manifest alone is an error.
For a configured policy, the audit command is:

```sh
python3 Tools/EmbeddedApplicationMacros/linked_storage_audit.py \
  --elf /path/to/axoloty-swift.elf \
  --map /path/to/axoloty-swift.map \
  --combined-object 'esp-idf/main/libmain.a(<selected-inventory-member>)' \
  --profile firmware-mqtt \
  --app-manifest Applications/device-smoke-agent/app.json \
  --enforce-static-storage-budget \
  --output linked-storage-budget.json
```

Enforcement compares the manifest ceiling only with
`aggregate_charged_static_bytes`, which is exactly the conservative
combined-object debit, including its map-recorded padding. It does not sum the
11-symbol inventory union or use whole-image `.bss` alone. The report records
actual bytes, ceiling, signed headroom, and pass status. The manifest field is
optional for other minimal app manifests but, when present, must be a positive
UInt32. Direct enforcement mode requires it and fails closed when it is
missing, malformed, or exceeded. This SDK-neutral app policy does not alter
`applicationStateBytes` or the generated C ABI.

Run focused synthetic cases with:

```sh
python3 Tools/EmbeddedApplicationMacros/linked_storage_audit.py --selftest
```

These synthetic cases also run in `Tools/verify.sh --tier repo` and repository CI. No firmware artifact or toolchain is required for the fixtures.
