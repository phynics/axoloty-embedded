# First initialization stack diagnostics

`first_init_stack.py` is a diagnostic-only prototype. It reads linked ELF,
map, symbol, build-config, and externally supplied disassembly files. It can
check that listed instruction encodings match executable ELF bytes and that
the supplied disassembly covers complete function extents. Those checks do
not decode the instruction bytes or prove that the supplied mnemonic and
operand text describes them. Therefore every report sets `inputEvidenceUnverified`
to true, keeps candidate frame sizes separate from accepted `frameBytes`,
leaves every numeric stack bound null, and returns `UNRESOLVED`. It never
reports `PASS` or proves an executed trace.

Run the synthetic diagnostics with:

```sh
python3 Tools/EmbeddedApplicationMacros/first_init_stack.py --self-test
```

For an artifact diagnostic, supply exact entry, hook, trace begin/end, and
generated State symbol names, plus `build/config.env`. The config must identify
ESP-IDF 5.4.0. Callback records are candidate evidence only. The current
straight-line constant tracker rejects a callback value when any earlier
branch or unconditional transfer could bypass its definition, including
`jal zero`/`jal x0`, zero-link `jalr`, `j`, and `c.j`. It clears caller-saved
values across returning call spellings, including `c.jal`. It does not prove
callback semantics from machine-code decoding.

The build config must be a JSON object with string `IDF_VERSION` equal to
`5.4.0`. A callback contract must be an object with string `elfSha256` and a
`sites` array; each site needs a non-empty `caller`, a `callPc` address string,
and a `callback` object with non-empty `symbol` and `address` string. Optional
`evidencePc` is also an address string. A ROM contract needs integer
`schemaVersion: 1`, string `idfVersion` and `target`, and a `records` array
whose records contain an `address` string. Optional `complete` and
`stackBytes` values must be boolean and a non-negative integer, respectively.
Addresses accept hexadecimal or decimal strings within the ELF32 range.

Invalid or unreadable inputs produce an argparse error without a Python
traceback. Option abbreviations are disabled, so spell `--out` in full. When
`--out` appears more than once, the last value is the effective destination;
earlier output values are ignored. Before invalidating that destination, the
CLI checks it against every supplied input path, including paths from repeated
input options and paths supplied after another malformed option. It rejects
literal, normalized, symlink, and hardlink aliases without changing the input
or any existing output. A tolerant preflight recognizes only exact file-input
options and `--out`, so a later strict-parser error still invalidates a valid,
unaliased last output. An absent value for the final `--out` is ambiguous and
causes no output path to be selected or cleared. `--help` and a successful
`--self-test` do not modify report paths. Successful reports are written
through a temporary file and atomically replace the destination.

The report's `firstInitInterval.addressOrderObserved` records only ascending
call-site addresses. `controlFlowOrderProven` is always false. A branch may
skip a lower-address trace call, so address order is not execution order.
`callGraph`, allocator presence/reachability, and candidate frame sizes are
static observations from unverified disassembly. Allocator reachability always
has incomplete status, and no omission may be interpreted as proof that an
allocator is unreachable.

Caller-supplied ROM records remain unverified without body bytes and trusted,
reviewed provenance. A digest only binds a record to an image. The report
does not accept numeric ROM stack claims. `sourceRevision` is null because
ELF producer provenance is not bound to this analyzer revision;
`analyzerSha256` identifies the analyzer file separately.

Full function-byte coverage, including the largest same-address ELF function
alias, remains a useful input consistency check. It cannot establish decoded
semantics. The prototype does not prove a total stack bound, a lower bound,
trace execution, allocation behavior, or that the tooling closes the embedded
application ABI or its tracking epic. MQTT and Zenoh results are expected to
remain `UNRESOLVED` with null numeric bounds.

These output semantics use schema version 3. Consumers must treat all
candidate fields as unverified diagnostics.

## Exact-artifact initialization proof

`final_init_proof.py` is a separate, narrow proof entry point for the existing
`device-smoke-agent` on ESP32-C6 MQTT and Zenoh. It preserves this diagnostic
CLI and its null accepted bounds. It accepts ELF/ROM files, never supplied
mnemonic text or callback/ROM frame constants.

The proof runner snapshots the selected ELF and the verified rev0 vendor ROM,
then executes the pinned GNU disassembler with `-d -z -M no-aliases,numeric`.
It checks the objdump and nm executable hashes before execution. The default
uses the pinned local container with `--pull=never --network=none --cpus=4`.
`--tool-dir` can instead select the same hash-verified native executables.
The container daemon is unnecessary in native mode. Neither mode downloads
anything. Serialize runs with the same verification lease used for builds.

The internal `initialization_interval.py` engine consumes only that controlled
decoding. ELF metadata determines the largest function/alias extent; every
reached body must have complete, byte-matching coverage. A compiler helper
without a symbol is admitted only as a complete executable gap beginning at
the preceding function's end, bounded by the next function or section. An
explicit jump vector is validated separately. Fallthrough beyond either
boundary fails. Unknown indirect targets, dynamic stack adjustments,
unmodeled instructions, missing bytes, unbalanced returns and recursive call
or tail graphs reject the proof.

The engine propagates register constants and private stack facts through CFG
joins. Unknown values remain unknown. It derives the `swift_once` callbacks
from the calling instructions, resolves capability functions through the
linked immutable tables, and follows alternate-link outlined helpers, tails,
ROM vectors and both `memset` computed dispatches. Continuation states remain
separate so a saved ROM link cannot merge with an unrelated dispatch base.
The exact vendor `memcpy` body supplies a data-copy effect summary for capability
construction; its stack and control-flow effects still use its instructions.
Flash-resident tables use the ESP32-C6 immutable flash mapping, including
sections whose linker flags contain `SHF_WRITE`.

The interval covers application entry through trace-end return. It includes
both observer helpers, all initializer callees and returning error paths,
and the frames already live in `vPortTaskWrapper`, `main_task` and `app_main`.
The startup task's machine-code argument establishes the wrapper callback and
task stack request. Setup calls that have returned and later `App.run`/corpus
calls do not contribute simultaneous frames. CFG phase tracking requires
begin before the hook and end after it on returning hook paths. A failed begin
may return before the hook. Exceptional trap/panic exits are listed explicitly;
handler, interrupt and context-switch stacks are outside this synchronous
bound. The proof assumes compiled ABI execution and valid memory. It does not
prove memory safety or termination.

`--sdkconfig` selects the actual generated SDK configuration JSON. Only its
main task stack capacity is published, together with the file digest. The
engine independently evaluates the final `axoloty_main_stack_size` function
and verifies the task creation request. It compares the cumulative upper bound
with that configured capacity. No watermark or extra owner policy supplies a
bound.

The receipt joins the conservative combined-object storage measurement to the
exact ELF/map, checks the ESP image's embedded ELF digest, binds clean producer
provenance to the authoritative Core lock, and compares current product inputs
with the producer's Git revision. Tooling changes can therefore be reviewed
without relabeling the historical firmware producer.

The raw device input must be the unedited capture. Epoch one extends from byte
zero through the next reset boundary or EOF and must contain completion. Every
calibration-prefix row in that epoch is retained, including rows after the
completion record. A truncated first epoch rejects a later PASS. Both the
calibration validator and the full 312-case smoke validator run again. The
per-run receipt binds the raw digest, board, source and image; the board and
Core are cross-checked with the other producer/device records. Raw input bytes
are never rewritten.

Named calibration controls use separate intervals of the production observer.
`coverage_complete=0` remains truthful. Initialization no-heap acceptance uses
the closed initializer graph, absence of reached allocator entries/aliases in
that graph, passing named controls and the successful entry gate before smoke.
It makes no whole-image allocation or complete control-coverage claim. Inventoried application lazy controls and controls reached by the hook are joined to an exact callback
argument or an inline guard read and write in the hook graph. Other lazy
controls in the shared Swift module, including transport startup, are listed
outside this interval. Inventoried
backings are classified separately by linked storage. Generated
State is checked as the current four-byte zero-backed object; its later ordinary
count load is not a dynamic initializer. Incomplete named source ownership does
not invalidate the conservative combined-object storage budget.

Example replay, with paths supplied by the artifact owner:

```sh
python3 Tools/EmbeddedApplicationMacros/final_init_proof.py \
  --profile esp32c6-mqtt \
  --artifacts <build>/linked-artifacts --profile-evidence <build>/evidence \
  --rom-elf <vendor>/esp32c6_rev0_rom.elf \
  --sdkconfig <build>/config/sdkconfig.json \
  --calibration-csv <device>/evidence/calibration-rows.csv \
  --calibration-raw-log <device>/evidence/swift-smoke-log.txt \
  --calibration-device-receipt <calibration-response.json> \
  --device-run-receipt <device>/receipt.json \
  --output-dir <new-proof-directory>
```

Exit zero means the scoped receipt passed. Missing or contradictory evidence
exits nonzero and leaves no accepted receipt or success manifest. Known output
names are invalidated safely before validation, including parser-error paths;
input aliases are rejected first. Repeated output options select only the final
unambiguous directory. Help and self-test preserve output. Foreign files are
preserved and excluded from the manifest. Accepted receipt publication is last,
and failure command logs are retained. Exact commands use a stable output-path
placeholder so replays in different output directories compare byte-for-byte.

Run hardware-free fixtures with:

```sh
python3 Tools/EmbeddedApplicationMacros/final_init_proof.py --self-test
```

The repository tier registers these fixtures alongside the unchanged diagnostic
suite. A receipt for retained artifacts does not qualify a later committed
firmware candidate; its owner must build and validate that candidate separately.
