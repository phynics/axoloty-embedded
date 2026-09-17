# Core dependency

This repository builds against one exact Axoloty revision.

## The lock

`axoloty-core.lock.json` has schema version 1:

| Field | Meaning |
|---|---|
| `core.identity` | Expected repository identity |
| `core.url` | Fetch URL |
| `core.version` | Axoloty release version, descriptive |
| `core.tag` | Release tag, descriptive |
| `core.revision` | **Authoritative** 40-character commit SHA |
| `core.revisionFormat` | `git-commit-sha1` |
| `core.consumerContractPath` | Contract path inside the Core checkout |

The commit SHA decides what gets built. When the version and the SHA disagree,
the SHA wins and the lock is wrong; fix the lock.

## Preparation

`Tools/prepare-core.sh` resolves Core and prepares it:

1. Reads the lock and rejects an unknown schema version or a SHA that is not 40
   lowercase hexadecimal characters.
2. Selects a Core checkout, either the locked commit fetched into scratch or a
   local checkout named by `AXOLOTY_SOURCE_DIR`.
3. Runs Axoloty's `axoloty-tool embedded consumer prepare` with caller-owned
   scratch and output paths.
4. Checks the report's schema version and status, and in strict mode its
   reported commit and dirty state.

It writes `<scratch>/core-preparation.json` and prints that path. The report
carries the Core commit and dirty state, the contract SHA-256, the compiler
flags, the five portable source directories in dependency order, the locked
`_JSONCore` revision and source, and the macro executable. Firmware build
systems consume that report and nothing else from Core.

## Environment

| Variable | Meaning |
|---|---|
| `AXOLOTY_SOURCE_DIR` | Absolute path to a local Axoloty checkout. The only supported local override. |
| `AXOLOTY_SCRATCH` | Scratch root. Default `.axoloty` in the repository root. |
| `AXOLOTY_STRICT_CORE` | `1` requires the locked commit and a clean checkout. Defaults to `1` when `CI` is set, `0` otherwise. |

## Clean clone

A clean clone fetches the locked commit itself:

```bash
git clone https://github.com/phynics/axoloty-embedded.git
cd axoloty-embedded
Tools/prepare-core.sh
```

The fetch is a depth-1 fetch of the exact commit, so no full Axoloty history is
downloaded. No sibling checkout is prepared by hand, and no parent directory is
searched.

## Local coordinated development

Point the override at a working Axoloty checkout to test a Core change against
firmware before it merges:

```bash
AXOLOTY_SOURCE_DIR=/absolute/path/to/axoloty Tools/prepare-core.sh
```

Outside strict mode, a dirty or off-lock checkout produces a warning and
proceeds, which is what coordinated development needs. Strict mode refuses it,
so a release or CI build cannot silently consume uncommitted Core changes.

## Raising the lock

1. Merge the Core change in `phynics/axoloty` and let it release, or pick the
   exact commit to move to.
2. Update `core.revision`, and `core.version` and `core.tag` with it.
3. Run `Tools/prepare-core.sh` with `AXOLOTY_STRICT_CORE=1` from a clean tree.
4. Rebuild and requalify every affected profile. Compatibility is per profile:
   a profile claims a Core revision only with device evidence for it.

## Unsupported

These are not part of the boundary, and firmware must not depend on them:

- Axoloty's root `.build` directory.
- Parent-directory checkout discovery.
- Anything under Axoloty's `Tests/`.
- Copying portable Axoloty source into this repository.
