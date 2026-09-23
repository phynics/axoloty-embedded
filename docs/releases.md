# Firmware releases

A firmware release is a reproducibility certificate: it says that one profile
built one exact artifact against one exact Axoloty revision, and that the
artifact passed its device qualification. The certificate is a machine-readable
manifest, and it is produced by the tooling, never written by hand.

Compatibility is **per profile**. A release tag names an embedded release — a
set of per-profile certificates — not a repository-wide compatibility claim.

## Version model

`VERSION` at the repository root holds the embedded version:

```text
<Axoloty base version>-embedded.<cycle revision>
```

The embedded version for the ESP32-C6 + MQTT work is `0.8.0-embedded.1`.

- **Base version.** The base is the locked Axoloty release version, `core.version`
  in [`axoloty-core.lock.json`](../axoloty-core.lock.json). The embedded release
  embeds one exact Axoloty revision, so it carries that revision's version.
- **Cycle revision.** The cycle revision is a positive integer. It starts at `1`
  and increments within a cycle.
- **A new Axoloty release starts a new cycle.** Going from Axoloty `0.8.0` to
  `0.8.1` makes the base `0.8.1` and resets the cycle revision to `1`
  (`0.8.1-embedded.1`), even when no firmware source changed. The lock moves, the
  exact Core revision the firmware embeds changes, and the previous certificate
  no longer describes the build. This is why the patch release cannot reuse
  `0.8.0-embedded.N`.
- **A firmware change inside a cycle increments the revision.** `0.8.0-embedded.1`
  becomes `0.8.0-embedded.2`. A revision is never reused, and a certificate is
  never overwritten.
- The lock is what enforces the base. `Tools/prepare-core.sh` refuses a release
  built off the lock, and the `release` invariant rule refuses a `VERSION` whose
  base disagrees with the lock version. The reset to `.1` when the base changes
  is a release-process rule; see the procedure below.

### Git tag spelling

The Git tag is the embedded version with a `v` prefix:

```text
v0.8.0-embedded.1
v0.8.0-embedded.2
v0.8.1-embedded.1
```

The `v` prefix matches Axoloty's own release tags (`v0.8.0`), so the embedded
tag and the Core tag it certifies read as a pair. The tag lives in
`phynics/axoloty-embedded`, so it cannot collide with a Core tag.

The separator is a hyphen, not semver build metadata (`+embedded.1`): build
metadata is ignored in precedence and cannot be ordered, and this cycle must
increment and compare. The hyphen makes the whole string a semver pre-release
of the base version. That is a deliberate cost: the upstream plan fixes the
spelling, and the ordering is worth more here than a strict reading of "this is
not a pre-release of Axoloty".

## Where manifests live

One manifest per profile and embedded version, tracked under:

```text
releases/<profile>/<embedded-version>.json
```

`releases/` holds certificates only. A compatibility-preview manifest is
labelled `preview`, is never published there, and is never validated as a
certificate.

### Revoked certificates

A certificate is immutable. If later validation finds that its provenance is
invalid, add `releases/revocations/<profile>/<embedded-version>.json` rather
than editing the certificate. The revocation names the certificate path and a
specific reason. Default validation then rejects the certificate. Repository
invariants report a valid tracked revocation as skipped without treating the
historical certificate as a current qualification claim.

## Manifest schema

The format is a versioned JSON document with `schemaVersion: 1`, following
[`axoloty-core.lock.json`](../axoloty-core.lock.json) and the evidence records
in [docs/evidence.md](./evidence.md).

| Field | Meaning | Where the build gets it |
|---|---|---|
| `schemaVersion` | `1` | format |
| `mode` | `release` or `preview` | the preview environment variable |
| `profile` | Profile name | `Profiles/<name>/profile.json` |
| `application` | Application axis | profile |
| `platform` | Platform axis | profile |
| `board` | Declared target board | profile |
| `transport.name` | Transport axis | profile |
| `transport.backend` | Transport library | platform mapping (`mqtt-espidf` → `esp-idf/mqtt`) |
| `transport.version` | Transport backend version | `Platforms/<platform>/dependencies.lock` |
| `transport.versionSource` | Where that version came from | repository-relative path |
| `compatibility.scope` | `profile` | format |
| `compatibility.status` | `qualified`, `unqualified`, or `preview` | computed from evidence and mode |
| `compatibility.description` | One-line support statement | computed from the fields above |
| `axoloty.version` | Locked Axoloty version | lock (`null` in preview) |
| `axoloty.tag` | Locked Axoloty tag | lock (`null` in preview) |
| `axoloty.sha` | Exact Core commit | Core preparation report, cross-checked against the lock |
| `axoloty.dirty` | Core checkout clean? | Core preparation report |
| `axoloty.contractSha256` | Consumer contract hash | Core preparation report |
| `embedded.version` | Embedded version | `VERSION` |
| `embedded.sha` | Firmware checkout commit | build provenance |
| `embedded.dirty` | Firmware checkout clean? Must be `false` for a release. | build provenance |
| `toolchain.swift` | Observed Swift version | build provenance, from `swift --version` |
| `toolchain.sdk` | Observed SDK version | build provenance, from `idf.py --version` |
| `toolchain.target` | SDK target | build provenance |
| `configurationFingerprint` | SHA-256 of the tracked selection and config inputs | computed from the profile selection, the Core revision, and the hashes of `sdkconfig.defaults`, `partitions.csv`, and `dependencies.lock` |
| `image.path` | Artifact file name | build provenance |
| `image.sha256` | Artifact checksum | build provenance, hashed from the bytes |
| `image.byteCount` | Artifact size | build provenance |
| `resources` | Size report when one exists, else `null` | optional `size.json` beside the artifact |
| `qualification.status` | `qualified` or `unqualified` | computed from evidence |
| `qualification.evidence` | Cited evidence records | every `docs/evidence/` record for the profile |

The `board` field is the declared target board. The qualification evidence
names the unit that was actually used. A certificate carries both.

Every field is computed by the code that observed it. Nothing is a literal
result, and a field that no longer has a producer is removed rather than left
in place. See [Every field is computed, never a constant](./evidence.md#every-field-is-computed-never-a-constant).

### Example (not a real record)

The following is an **example only**. Its values are placeholders and none of
them is a real observation. A real record is never committed under
`docs/evidence/`; it is written to `releases/` by `Tools/release.sh`.

```json
{
  "schemaVersion": 1,
  "mode": "release",
  "profile": "<profile>",
  "application": "<application>",
  "platform": "<platform>",
  "board": "<board>",
  "transport": {
    "name": "<transport>",
    "backend": "<backend library>",
    "version": "<backend version>",
    "versionSource": "Platforms/<platform>/dependencies.lock"
  },
  "compatibility": {
    "scope": "profile",
    "status": "qualified",
    "description": "<computed support statement>"
  },
  "axoloty": {
    "version": "<lock version>",
    "tag": "<lock tag>",
    "sha": "<40-character Axoloty commit SHA>",
    "dirty": false,
    "contractSha256": "<64-character contract SHA-256>"
  },
  "embedded": {
    "version": "<base>-embedded.<revision>",
    "sha": "<40-character firmware commit SHA>",
    "dirty": false
  },
  "toolchain": {
    "swift": "<observed Swift version>",
    "sdk": "<observed SDK version>",
    "target": "<target>"
  },
  "configurationFingerprint": "<64-character SHA-256>",
  "image": {
    "path": "axoloty-swift.bin",
    "sha256": "<64-character image SHA-256>",
    "byteCount": 0
  },
  "resources": null,
  "qualification": {
    "status": "qualified",
    "evidence": [
      {
        "path": "docs/evidence/<profile>-<check>.json",
        "check": "<check>",
        "status": "passed",
        "coreRevision": "<40-character Axoloty commit SHA>",
        "firmwareSHA256": "<64-character image SHA-256>"
      }
    ]
  }
}
```

## How a manifest is produced

The build produces it, from what the build observed:

1. `Profiles/<name>/build.sh` selects the axes and delegates to the platform.
2. `Platforms/esp32c6-idf/tools/build.sh` prepares Core through
   `Tools/prepare-core.sh`, builds the image, then writes
   `build-provenance.json` with `write-provenance.mjs`.
3. The same build calls `Platforms/esp32c6-idf/tools/write-release-manifest.sh`,
   which runs `write-release-manifest.mjs`. The generator reads the Core
   preparation report, the build provenance, `profile.json`, the lock, `VERSION`,
   the platform dependency lock, the evidence records, and an optional size
   report. It refuses to run from an unprepared or dirty Core or a failed build.
4. The result is `release-manifest.json` in the build evidence directory.

`write-provenance.mjs` is the existing provenance path; the manifest generator
extends it rather than starting a parallel one.

A build against an off-lock Core checkout that is not an explicit preview is
coordinated local development. It is not a release, so it writes no manifest at
all rather than recording a development build as a certificate. A release path
forces strict preparation, so it can never reach that state.

## How a manifest is validated

`Tools/validate-release-manifest.py` is the validator. It uses only `python3`,
so it runs in the toolchain-free `repo` tier. It cross-checks the manifest
against authoritative sources instead of trusting it:

- the lock decides `axoloty.sha`, `axoloty.version`, and `axoloty.tag` for a
  release;
- `VERSION` decides `embedded.version`, and its base must equal the lock version;
- `Profiles/<profile>/profile.json` decides the application, platform,
  transport, and board;
- `docs/evidence/` decides qualification, and a `qualified` manifest must cite a
  `passed` record whose `coreRevision` and `firmwareSHA256` match this exact
  Core revision and artifact;
- a `preview` manifest must be off-lock, must not assert an Axoloty version, and
  cannot be qualified.

`Tools/check-invariants.sh` runs the validator with `--require-qualified` on
every tracked `releases/*/*.json`, so the format is enforced on every checkout
with no toolchain. It also checks that `VERSION` is well formed and tracks the
locked Axoloty version. `Tools/release.sh` runs the same validator on the
manifest it is about to publish.

A published manifest is immutable. `Tools/release.sh` refuses to overwrite an
existing record.

## Compatibility preview

Normal CI and every release use the locked Core. A dedicated preview mode may
build against an off-lock Axoloty release candidate:

```bash
AXOLOTY_PREVIEW_CORE_REVISION=<40-character candidate SHA> \
    Tools/prepare-core.sh
```

or, for a whole labelled build:

```bash
Tools/release.sh --profile esp32c6-mqtt --preview <40-character candidate SHA>
```

Preview mode is explicit and off by default. The only way to enter it is to set
`AXOLOTY_PREVIEW_CORE_REVISION`; ordinary CI never sets it. Preview preparation
still requires a clean Core checkout and the exact candidate revision, but the
revision is deliberately not the lock's.

A preview manifest records `mode: "preview"`, leaves `axoloty.version` and
`axoloty.tag` null, and sets `compatibility.status` to `preview`. It is a
build result, not a compatibility claim:

- it is never published to `releases/`;
- the invariant rule requires a published manifest to be a qualified release,
  so a preview cannot be tracked there;
- `Profiles/<name>/qualify.sh` refuses to run while
  `AXOLOTY_PREVIEW_CORE_REVISION` is set, so a preview can never be recorded as
  a qualification in `docs/evidence/`;
- it names no Axoloty version or tag. The preparation report carries the commit
  SHA and dirty state, not a version, and this repository never reads a Core
  file outside that report, so a preview has no observed version to record. A
  person who needs the candidate's version states it in the pull request, not
  in the record;
- its description states that it is not a claim.

## Release procedure

```text
Axoloty RC/candidate
  -> compatibility preview (non-authoritative)
Axoloty release
  -> raise the lock and requalify the profile
  -> write the release manifest
  -> tag the embedded release
```

1. Merge the Core change in `phynics/axoloty` and let it release.
2. Raise `axoloty-core.lock.json` to the released revision.
3. Set `VERSION` to `<new base>-embedded.1`, starting a new cycle even if no
   firmware source changed.
4. Point `AXOLOTY_DEVICE_PORT` at the board and run:

   ```bash
   Tools/release.sh --profile esp32c6-mqtt
   ```

   The release path forces strict Core preparation, builds, qualifies the
   image, rewrites the manifest with the qualification, validates it, and
   writes `releases/esp32c6-mqtt/<version>.json`.
5. Review and commit the record, then tag `v<version>`.

The release path does not commit, tag, or push. Compatibility is per profile:
raising the lock requires requalifying every affected profile, and a profile
claims a Core revision only with device evidence for that revision.

## What is not a release

- A build against a dirty or off-lock Core checkout. `Tools/release.sh` forces
  strict preparation, and `Tools/prepare-core.sh` refuses it.
- A build whose `build` or `device` tier reported `SKIP`. A skipped tier is not
  a pass. Record it as `unexecuted` evidence with a reason.
- A compatibility preview.
- A manifest a human edited. The build produces it; the validator rejects a
  record whose checksum, revision, or evidence does not match.
