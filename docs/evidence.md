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

`tier` is `build` or `device`, and it decides which fields an executed record
must carry. A build runs in the pinned container and has no board; a device run
must name the board and the protocol it drove.

| `tier` | An executed record must name |
|---|---|
| `build` | `firmwareSHA256`, `coreRevision`, `result`, `toolchain` |
| `device` | `firmwareSHA256`, `coreRevision`, `result`, `device`, `protocol` |

Those fields are what make the claim checkable by someone who was not there.
`tier` defaults to `device` when absent, because a device claim is the stricter
one and should never be the accidental default.

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
