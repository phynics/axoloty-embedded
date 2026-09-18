# Container builds

How to actually build this firmware, and the five blockers that stop a first
attempt. Every one of them was hit in order, and each produced an error message
that pointed somewhere other than the cause.

There is no `swift`, `cmake`, or `idf.py` on a typical host here. That does not
mean the build is unverifiable. **Check `docker images` before concluding
anything is unverifiable.**

## The toolchain is in a container, not on PATH

| Image | Contents |
|---|---|
| `axoloty-dev:latest` | Swift 6.3.3 and ESP-IDF v5.4 (`idf.py`, `esptool.py`, `riscv32-esp-elf-gcc`) |
| `swift:6.4.0-noble` | Swift 6.4, for the adopt-6.4 epic |
| `swift:6.3-jammy` | the current CI base |

`.devcontainer/image-lock.json` in Axoloty names the reviewed image digest.
Treat that lock the same way as `axoloty-core.lock.json`: the digest decides
what ran.

## The working invocation

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v /path/to/axoloty-embedded:/workspace \
  -v /path/to/axoloty-at-locked-revision:/core \
  -v /path/to/writable/home:/tmp/h \
  -w /workspace \
  -e HOME=/tmp/h \
  -e AXOLOTY_DEVCONTAINER=1 \
  -e AXOLOTY_SOURCE_DIR=/core \
  -e AXOLOTY_STRICT_CORE=1 \
  -e AXOLOTY_SCRATCH=/tmp/h/scratch \
  -e AXOLOTY_PROOF_RUN_ID=<stable-id> \
  axoloty-dev:latest \
  bash -lc 'Profiles/esp32c6-mqtt/build.sh'
```

Every flag above is load-bearing. The five reasons follow.

## 1. `AXOLOTY_DEVCONTAINER=1` is mandatory on Linux

**Symptom:** `error: AXOLOTY_SOURCE_DIR must be the canonical Git checkout root`,
no matter how canonical the checkout is. Hours can go into proving the path is
canonical, because the message names the path.

**Cause:** Axoloty's `AxolotyCheckExecutionContext.swift` selects its execution
context from this variable. Unset on Linux, it picks the host path, and the
tool's internal `git rev-parse --show-toplevel` never runs. The guard that
reports the failure cannot distinguish "git said no" from "git never ran".

`Tools/prepare-core.sh` now fails fast with this explanation instead.

## 2. Linked Git worktrees do not survive a bind mount

**Symptom:** `fatal: not a git repository`, or
`AXOLOTY_SOURCE_DIR is not a Git checkout`.

**Cause:** a linked worktree's `.git` is a *file* containing an absolute path
to the parent repository's git directory. Bind-mount the worktree alone and
that path does not exist in the container.

**Fix:** build from a standalone clone, not a linked worktree.

```bash
git clone --no-hardlinks "$(git -C <repo> rev-parse --git-common-dir)" /tmp/core-sa
git -C /tmp/core-sa checkout --detach <locked-revision>
```

Both repositories are small — tens of megabytes — so this costs nothing.

## 3. Run as your own uid, not root

**Symptom:** `fatal: detected dubious ownership in repository at '/core'`.

**Cause:** the mounts are owned by your host uid and the image defaults to
root, so Git refuses the repository.

Setting `safe.directory` in the container's global Git config fixes an
interactive shell but **not** the Core tool: it runs Git through a sanitized
execution context that does not inherit `GIT_CONFIG_*`. Configuring around this
wastes time.

**Fix:** `--user "$(id -u):$(id -g)"`. The image has a matching user at uid
1000, and Swift and ESP-IDF both work under it. `export.sh` succeeds without a
writable `/opt/esp`.

Pass `-e HOME=` to a writable directory, because that uid may not own `/root`.

## 4. Never reuse a scratch tree across users

**Symptom:** SwiftPM aborts inside llbuild with
`attempt to write a readonly database`, plus a full crash backtrace naming
neither the path nor the cause.

**Cause:** an earlier run as a different user owns `.axoloty/`. A root-owned
scratch tree cannot even be deleted by your uid afterwards — removing it needs
a throwaway root container:

```bash
docker run --rm -v /path/to/parent:/t alpine sh -c 'rm -rf /t/<stale-dir>'
```

**Fix:** set `AXOLOTY_SCRATCH` to a fresh path outside the repository.
`Tools/prepare-core.sh` now checks writability first and says so plainly.

## 5. ESP-IDF's requirements pass does not inherit `-D`

This one is a property of ESP-IDF, and it is the most likely to bite again.

**Symptom:** a CMake variable passed with `-D` on the `idf.py` command line is
empty inside a component `CMakeLists.txt`. The failure surfaces far from the
cause — an empty path becomes a missing file, and the error names the file.

Two instances were found and fixed while first building this firmware:

- `AXOLOTY_PREPARATION_REPORT` was passed only with `-D`, and the requirements
  pass reported `AXOLOTY_PREPARATION_REPORT is required; run
  Tools/prepare-core.sh first` — after `prepare-core.sh` had already succeeded.
- `AXOLOTY_APPLICATION_DIR` and `AXOLOTY_TRANSPORT_DIR` were read as cache
  variables in `Platforms/esp32c6-idf/main/CMakeLists.txt`. Empty, they made
  the corpus generator path `/fixtures/generate-embedded-corpus.mjs`, which
  failed as `Failed to generate Embedded Swift corpus vectors` — a message
  about a generator, caused by a missing selection.

**Cause:** `idf_build_process` expands component requirements in a separate
CMake sub-invocation. Cache variables from the outer command line are not
present there.

**Rule:** any value a component `CMakeLists.txt` needs must be **exported into
the environment**, and read with an `ENV{}` fallback. `-D` alone is not enough.
`cmake/axoloty-source.cmake` has always done this correctly; use it as the
pattern.

```cmake
if(NOT DEFINED SOMETHING OR "${SOMETHING}" STREQUAL "")
    if(DEFINED ENV{SOMETHING} AND NOT "$ENV{SOMETHING}" STREQUAL "")
        set(SOMETHING "$ENV{SOMETHING}")
    endif()
endif()
if(NOT DEFINED SOMETHING OR "${SOMETHING}" STREQUAL "")
    message(FATAL_ERROR "SOMETHING is required; ...")
endif()
```

Fail fast and name the variable. An empty path that travels two layers before
failing costs far more than a guard.

## What a container still cannot do

A container produces a firmware **image**. It cannot flash one.

The `device` tier needs a physical ESP32-C6 on `AXOLOTY_DEVICE_PORT`.
`esptool.py` exists in the image, but with no board attached, `qualify.sh` and
the `embedded-swift-smoke-v2` run stay genuinely unexecuted, and their evidence
records say so. See [evidence.md](./evidence.md).

Do not describe a successful container build as a qualified profile. A build
proves the image compiles against the locked Core. It proves nothing about the
device.
