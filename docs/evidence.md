# Evidence

A qualification claim without evidence is not accepted. This file defines what
evidence is and where it lives, so that "it works" always resolves to a record
someone else can check.

## Where

One JSON file per check per profile under `docs/evidence/`:

```text
docs/evidence/<profile>-<check>.json
```

`Tools/check-invariants.sh` validates every file there.

## Schema

```json
{
  "schemaVersion": 1,
  "profile": "esp32c6-mqtt",
  "check": "embedded-swift-smoke-v2",
  "status": "passed",
  "recordedAt": "2026-09-17",
  "device": "ESP32-C6-DevKitC-1 v1.2",
  "firmwareSHA256": "<64 lowercase hex characters of the flashed artifact>",
  "firmwareRevision": "<the 40-character commit SHA in the build provenance>",
  "coreRevision": "<the 40-character Axoloty commit SHA that was built>",
  "protocol": "312 deterministic cases over serial JSON Lines",
  "result": "312/312 passed"
}
```

## Status

`status` is one of three values, and only three:

| Status | Meaning |
|---|---|
| `passed` | It ran, on the named device, and it passed. |
| `failed` | It ran, on the named device, and it did not pass. |
| `unexecuted` | It did not run. `reason` says why. |

## Tier

`tier` is `build`, `component`, or `device`, and it decides which fields an
executed record must carry. A build runs in the pinned container and has no
board; a component check compiles one pinned component without a linkable
firmware image; a device run must name the board and the protocol it drove.

| `tier` | An executed record must name |
|---|---|
| `build` | `firmwareSHA256`, `firmwareRevision`, `coreRevision`, `result`, `toolchain` |
| `component` | `component`, `artifactSHA256`, `coreRevision`, `result`, `toolchain` |
| `device` | `firmwareSHA256`, `coreRevision`, `result`, `device`, `protocol`; a run written by the current harnesses also names `firmwareRevision` |

A `build` record names the firmware source revision it built
(`firmwareRevision`). Nothing in the image carries that revision, so a
checksum alone cannot be traced back to a commit, and a record whose checksum
was refreshed once kept a stale revision unnoticed. Write the value from the
build's `build-provenance.json` `firmware.revision`, and never from `HEAD` at
the time you edit the record.

`firmwareRevision` is a claim about one build, not about the current checkout. A
record stays true after later commits land; what stops being true is the
qualification claim that reads it as "this profile works", and that needs a
device record matching the artifact's `firmwareSHA256`.

A `component` record names the component (`component`, for example
`eclipse-zenoh/zenoh-pico 1.10.0`) and the SHA-256 of the artifact it compiled
(`artifactSHA256`, for example `libzenoh_pico.a`). A component-only check
produces no firmware image, so it carries no `firmwareSHA256`; recording the
library hash in a firmware field would state something the field does not
describe.

Those fields are what make the claim checkable by someone who was not there.
`tier` defaults to `device` when absent, because a device claim is the stricter
one and should never be the accidental default.

## The monitor deadline

`flash.sh` reads the serial stream until the device prints its completion record,
then stops, and gives up after `EMBEDDED_DEADLINE` seconds (default 240). The
result records `monitor.end` (`completed`, `deadline`, or `failed`) and the
seconds the run used. A stream cut off by the deadline fails with
`monitor deadline of N s expired before the device finished: missing ...`, which
is a different statement from a failure the device reported. A passed network
device record carries `monitorDeadlineSeconds` and `monitorElapsedSeconds`, so a
run that needed most of its deadline can be seen as such. The measured needs on
2026-11-01 were 59 s (Zenoh network test) and 125 s (MQTT network test, which
runs the on-device benchmark before its summary).

## Firmware resource comparisons

A build record may include `firmwareSizeBytes`, `previousFirmwareSizeBytes`,
and `firmwareSizeDeltaBytes` when comparing a toolchain change with a prior
build. These values describe the generated image only; they do not prove runtime
heap or stack usage. Put runtime measurements in `runtimeResourceMetrics` with
the board/run details. If no device run occurred, set its status to
`unexecuted`, leave unmeasured values `null`, and give a reason. Never infer
free/minimum heap or stack high-water marks from the image size.

`device` names the **unit that ran**, not the port it was attached to.
`write-device-manifest.mjs` derives it from the probe's chip description and
MAC (for example `ESP32-C6 (QFN40) (revision v0.0), MAC 40:4c:ca:4d:8c:e8`).
A path such as `/dev/ttyACM0` renumbers and identifies nothing; it belongs in
the run log, not in the claim.

## What a later run does to a tracked record

A record under `docs/evidence/` is the last result that passed. Every harness
writes through `Tests/embedded/evidence-record.mjs`, which applies one rule per
status:

| A run that is | does this to an existing record |
|---|---|
| `passed` | replaces it, and removes `<name>.failed.json` beside it |
| `unexecuted` | nothing: it says nothing about any image. It is withheld to `$AXOLOTY_SCRATCH/withheld-evidence/` (default `.axoloty/`) under a name that carries the time, so no attempt erases another |
| `failed` | keeps a `passed` record and is written beside it as `<name>.failed.json`; it replaces a `failed` or `unexecuted` record |

The failure beside a pass is not a note: the release manifest generator reads
every record of a check, and a `failed` record blocks the check until a run
passes (which removes it) or an operator removes the file after reading it. A
check that passed for image A and failed for image B therefore cannot certify
either. The run still exits nonzero.

## A record names the firmware it ran

Every device run writes `firmwareRevision`, the commit in the build's
`build-provenance.json` `firmware.revision`, beside `firmwareSHA256`. A writer
refuses to record a pass without it. A checksum says which image ran; the revision
says which firmware it came from, and a variant image's checksum can say nothing
else, because the image embeds network configuration or a role.

An `artifact: release` check needs a record naming the exact image being released.
An `artifact: variant` check needs a record whose `firmwareRevision` equals the
certificate's `embedded.sha`. A pass from older firmware, or one that names no
revision, does not qualify: the generator and the validator both say which revision
to rerun at ([releases](releases.md#requalifying)).

The validator reads `docs/evidence/` itself. A manifest must cite each record as
it is, must cite every record of a required check and every failed record, and the
required checks are judged from the records, not from what the manifest says.

## Unexecuted is a legal state

```json
{
  "schemaVersion": 1,
  "profile": "esp32c6-mqtt",
  "check": "embedded-swift-smoke-v2",
  "status": "unexecuted",
  "recordedAt": "2026-09-17",
  "reason": "no ESP32-C6 board and no ESP-IDF toolchain were available in this environment"
}
```

Recording `unexecuted` is the correct, complete outcome when you cannot run a
check. It is not a failure of the change, and it does not need an apology. It
carries the gate forward honestly so that the next person with a board knows
exactly what is outstanding.

Inventing a device name, a checksum, or a pass count is the one thing that
cannot be repaired later, because every downstream release manifest inherits
it. Never write a number you did not read off a run.

## Every field is computed, never a constant

A field in an evidence record states the result of a check. It is written by
the code that ran the check, from what that run observed.

Writing a literal `"passed"` for a check that no longer runs is the same
failure as inventing a checksum, and it is harder to see, because the record
looks complete and the build still goes green. It happened once already: a
firmware validate wrapper dropped a content scan during a refactor but kept
emitting `"privateReferenceScan": "passed"` beside the scan it had removed.

Two rules follow:

- If a check moved, the record must cite where it now runs, and that place must
  actually fail the build when the check fails.
- If a check was deleted, the field goes with it. A record with one fewer field
  is honest. A record with a field nothing computes is not.

When a check becomes a rule in `Tools/check-invariants.sh`, an evidence record
may cite it by name, because `Tools/verify.sh --tier repo` fails closed on it.

## A record names the locked Core revision

An evidence record that names `coreRevision` must name the revision in
[`axoloty-core.lock.json`](../axoloty-core.lock.json). A record for a
superseded revision is stale at best; a `passed` one is a compatibility claim
for a Core the current lock no longer names, and nothing downstream may notice
because the record still looks complete. When the lock moves, regenerate the
record or delete it — do not leave it reading `passed`.
`Tools/check-invariants.sh` enforces this on every checkout, for every status.

Imported evidence is exempt: `importedFrom.revision` records the revision the
run actually happened at, and re-proving it is not import's job.

## Provenance for imported evidence

Evidence imported from `phynics/axoloty` keeps its origin, because filtered Git
history is not preserved across the split:

```json
"importedFrom": {
  "repository": "phynics/axoloty",
  "path": "Tests/Support/embedded/<original path>",
  "revision": "<the 40-character Axoloty commit SHA it was taken from>",
  "originalDate": "<the date of the original run>"
}
```

An imported record keeps the status it originally had. Importing does not
re-prove anything.
