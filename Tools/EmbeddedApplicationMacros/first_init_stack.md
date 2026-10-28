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
