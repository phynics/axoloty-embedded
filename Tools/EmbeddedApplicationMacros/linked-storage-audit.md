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
charges for aggregate accounting. Raw symbol names are retained; generated
state and phase4AgentA/B are identified only by their emitted ELF names. No
demangling or source-level ownership inference is performed. A report always
marks source attribution incomplete and leaves storage-budget acceptance,
first-init trace, and stack proof pending. It does not claim that the image
does not allocate.

Run focused synthetic cases with:

```sh
python3 Tools/EmbeddedApplicationMacros/linked_storage_audit.py --selftest
```

These synthetic cases also run in `Tools/verify.sh --tier repo` and repository CI. No firmware artifact or toolchain is required for the fixtures.
