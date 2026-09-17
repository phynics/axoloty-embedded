# Profiles

## What belongs here

One named `application x platform x transport` selection, built and qualified
as a unit. A profile is declarative: it selects, it does not implement. Logic
under this directory belongs in one of the other three axes.

## Required shape

`Profiles/<name>/profile.json`:

```json
{
  "name": "esp32c6-mqtt",
  "application": "<a directory name under Applications/>",
  "platform": "<a directory name under Platforms/>",
  "transport": "<a directory name under Transports/>",
  "core": { "revision": "<the 40-character SHA from axoloty-core.lock.json>" }
}
```

`transport` is one string. Not a list, not an object.
`Tools/check-invariants.sh` fails on a profile that selects more than one,
because selecting many is where a premature plugin system starts, and the epic
that created this repository refused one explicitly.

The claimed `core.revision` must equal the lock's revision. Raising the lock
means requalifying every profile: compatibility is per profile, never
repository-wide.

## Optional scripts

| File | Called by | Must |
|---|---|---|
| `build.sh` | `Tools/verify.sh --tier build` | produce a firmware image, exit non-zero on failure |
| `qualify.sh` | `Tools/verify.sh --tier device` | flash, run the smoke protocol, and write an evidence record |

Both are executable and take no required arguments. `qualify.sh` reads the
board from `AXOLOTY_DEVICE_PORT` and never guesses it.

## Evidence

A profile claims a Core revision only with device evidence for that revision.
The evidence lives in `docs/evidence/` and follows
[docs/evidence.md](../docs/evidence.md). A claim with no record, or a record
with an invented checksum, is not a claim.
