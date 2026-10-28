# ESP32-C6 allocator observer controls

`AXOLOTY_HEAP_TRACE_CALIBRATION=1` adds a platform-local control runner before
the shared application entry. The default is `0`. The option is normalized
and exported to ESP-IDF's requirements sub-invocation, stored in the CMake
cache, and written to `allocator-calibration-config.json` in build evidence.
It cannot be combined with `AXOLOTY_QUALIFICATION_CARRIER_SCENARIO`.

Each control calls the production `axoloty_heap_trace_begin` and
`axoloty_heap_trace_end` helpers for a separate short interval. The runner
does no logging, network setup, or corpus work during an interval. It emits a
versioned `AXOLOTY_HEAP_CAL_V1` CSV record only after the production end helper
returns, followed by a direct SDK summary read for mode, frees, and overflow.
Every record carries `coverage_complete=0` because this matrix does not close
allocator reachability.
After every control succeeds, `app_main` continues into the normal shared
application entry in that same ELF. These controls exercise the same observer;
their intervals are not the production first-initialization interval.

The bounded matrix covers an empty interval, `malloc` followed by `free`, two
`malloc` calls, `heap_caps_malloc` with `MALLOC_CAP_INTERNAL |
MALLOC_CAP_8BIT`, `calloc`, and 129 simultaneously live 8-byte `malloc`
allocations against the production 128-record buffer. The overflow result
must be distinct and leave the output count sentinel unchanged. Allocations
from each path must be non-null and consumed. While each named allocation is
still live, the runner reads the trace summary and records. It checks exact
allocation totals, zero frees, record count, and address matches before
releasing that allocation. After the end helper stops tracing, it checks the
final exact allocation/free totals, status, mode, overflow, and count again. A
freed address therefore cannot be reused by unrelated activity to stand in
for a missed named event. The overflow allocations are freed after tracing
ends, and the static pointer slots are cleared. The overflow control requires
all 129 allocations to succeed, 129 allocations and zero frees, the production
overflow status and sentinel, and the exact 128 records for the last 128
still-live named allocations. It does not claim that all 129 addresses fit in
the 128-record trace.

ESP-IDF 5.4.0 defines `HEAP_TRACE_ALL` as enum value 0. Its
`heap_trace_get` documentation permits reads while tracing; the implementation
copies each record while holding the trace lock. In this mode, a free
increments `total_frees` and fills `freed_by` for a matching address; it does
not remove the record. The host stub also models the SDK's early return from a
free when the record buffer is empty, before `total_frees` changes.

The exact APIs and parameters above are the measured coverage. This does not
establish complete allocator reachability, alias or wrapper coverage, Swift
allocator coverage, the absence of unrelated allocations, or a whole-image
no-heap property. It is not device calibration evidence until the target runs
and its records are retained for the exact ELF and profile.

For a future raw boot capture, preserve the original file and extract every
line containing the calibration prefix without filtering by case or result:

```sh
node Tests/embedded/validate-heap-trace-calibration.mjs \
  --extract-raw boot-capture.log calibration-rows.csv
node Tests/embedded/validate-heap-trace-calibration.mjs calibration-rows.csv
```

Extraction strips any logger text before the prefix, retains every matching
row, and excludes other boot and smoke records from the calibration validator.
A duplicated or malformed calibration row remains in the extracted input and
fails strict validation. Keep `boot-capture.log` unchanged as the raw artifact;
send smoke records to the smoke validator separately.

The `alloc` field is the production end helper's output. Successful end writes
an allocation count bounded by the 128-record observer; every failed end
preserves `UINT32_MAX`. These rules apply even if the later direct summary
read fails. In that case the runner emits `summary=0`, `mode=-1`, and zero
placeholders for frees, overflow, and final records. It retains both the
helper's written count and `matched` from the earlier live inspection. An
overflow end status can likewise precede a failed direct summary. Such rows
are failed controls, accepted only as structurally valid failure evidence with
`--expect-failure`; they cannot establish calibration success.

The hardware-free runner and strict stream validator are exercised by
`Tests/embedded/run-heap-trace-calibration-test.sh` and the `build` tier of
`Tools/verify.sh`, and CI requires that check. Host fault injection checks
failed begin/end/summary, separate helper and final-summary failures, NULL results for each named allocation path, missed
named events masked by unrelated activity, including exact-address reuse after
free, overflow with an early partial failure and with 128 successes followed
by one NULL result, missed overflow, and cleanup on each path. CLI regressions
cover impossible status/mode/count combinations under `--expect-failure`, and
extraction rejects hardlink aliases without changing raw bytes. These checks do
not replace target execution or a profile build.
