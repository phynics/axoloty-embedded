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

An executed record must name `device`, `firmwareSHA256`, `coreRevision`,
`protocol`, and `result`. Those five fields are what make the claim checkable
by someone who was not there.

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
