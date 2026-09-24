# Handoff: qualifying esp32c6-mqtt on a real board

This runbook was executed for the first time on 2026-09-19 and the profile is
now qualified. Keep it for the next board and for the next lock raise: the
procedure below is unchanged and still takes about twenty minutes.

## Result of the first run (2026-09-19)

| | |
|---|---|
| Unit | ESP32-C6 (QFN40) revision v0.0, MAC `40:4c:ca:4d:8c:e8` |
| Firmware | `7a2780258888c8bd52034d3de6397de38a958cbc09ad6f693c605519d743a8e3`, 749456 bytes |
| Core | Axoloty 0.8.2, `827e598f3d97c5e2e7986d7be4ba1d9a5eac7906` |
| Smoke protocol | `embedded-swift-smoke-v2`, 312/312 case IDs passed over serial JSON Lines |
| Evidence | `docs/evidence/esp32c6-mqtt-embedded-swift-smoke-v2.json` |
| Profile qualification | **qualified** at the build and device tiers |

The smoke run is serial-only: this image carries no compiled network
configuration, so MQTT connect, last-will, reconnect, and broker-restart
behavior are not covered by this run. The role-config device harnesses that
would cover them are still unmigrated (see `docs/check-inventory.md`, note A).

## What is proven at build tier

| | |
|---|---|
| Firmware builds against the locked Core | **yes** — repinned to 0.8.2 and rebuilt; `check-reproducible-build.sh` matched two independent proof roots |
| Image digest | `7a2780258888c8bd52034d3de6397de38a958cbc09ad6f693c605519d743a8e3` (bit-identical to the 0.8.1 build) |
| Image size | 749456 bytes |
| Core revision | `827e598f3d97c5e2e7986d7be4ba1d9a5eac7906` (Axoloty 0.8.2) |
| Toolchain | `axoloty-dev:latest` — Swift 6.3.3, ESP-IDF v5.4 |

## Before you start

**Read [container-builds.md](./container-builds.md) first if anything fails.**
Five environment blockers are catalogued there, every one of which produces an
error message that points somewhere other than the cause. You will save
yourself hours.

You need:

- Docker, and the `axoloty-embedded-dev` image (`docker images` to confirm; build it with `docker build -t axoloty-embedded-dev .devcontainer`)
- An ESP32-C6-DevKitC-1 on a USB port
- Your user in the `dialout` group, or equivalent access to the serial device
- An MQTT broker reachable from the board, for the network portion

**A note on the lock.** This branch pins Axoloty 0.8.2 (`827e598f`). If
`origin/main` has since raised the lock, `Tools/check-invariants.sh` will tell
you so and refuse — that is deliberate, not a bug. Qualify what this branch
pins, or repin and rebuild first. Do not qualify a mismatch.

## Step 0 — a standalone clone, not a worktree

A linked worktree's `.git` is a *file* pointing at the parent repository, and
that path does not exist inside a container. Clone properly:

```bash
git clone https://github.com/phynics/axoloty-embedded.git ~/axemb
git -C ~/axemb checkout orchestrate/embedded-tickets-1-4

git clone https://github.com/phynics/axoloty.git ~/axcore
git -C ~/axcore checkout --detach 827e598f3d97c5e2e7986d7be4ba1d9a5eac7906
```

Both trees must be **clean**. Strict mode refuses a dirty Core, and the
provenance record would be worthless if it did not.

```bash
mkdir -p ~/axhome
```

`~/axhome` is scratch space *outside* both repositories. Never point
`AXOLOTY_SCRATCH` inside a checkout, and never reuse a scratch tree that
another user wrote — see container-builds.md §4 for the memorable failure that
causes.

## Step 1 — find the board

```bash
ls -l /dev/serial/by-id/
```

Use the stable `by-id` path, not `/dev/ttyUSB0`, which renumbers. Export it:

```bash
export PORT=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_XX-XX
```

For the `--device` flag, pass the **resolved node**, not the `by-id` symlink:
the symbolic name contains the MAC's colons, and `docker run --device` parses
colons as its `host:container:mode` separator, so it silently truncates the
path and reports `stat ...: no such file or directory` for the prefix.

```bash
export DEVICE_NODE=$(readlink -f "$PORT")   # e.g. /dev/ttyACM0
```

On a rootless runtime the node may appear inside the container owned by an
unmapped gid, and `--group-add dialout` cannot help because that gid is not
mapped. `podman run --group-add keep-groups` maps the invoking user's
supplementary groups instead, which is how the first run was flashed. Use the
runtime that can open the port; the firmware tooling does not care which.

`flash.sh` reads the chip and **refuses a board that is not an ESP32-C6**. It
never guesses a port.

## Step 2 — build

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v ~/axemb:/workspace -v ~/axcore:/core -v ~/axhome:/tmp/h \
  -w /workspace \
  -e HOME=/tmp/h \
  -e AXOLOTY_DEVCONTAINER=1 \
  -e AXOLOTY_SOURCE_DIR=/core \
  -e AXOLOTY_STRICT_CORE=1 \
  -e AXOLOTY_SCRATCH=/tmp/h/scratch \
  -e AXOLOTY_PROOF_RUN_ID=device-qual-1 \
  -e CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)" \
  axoloty-embedded-dev \
  bash -lc 'Profiles/esp32c6-mqtt/build.sh'
```

Every flag is load-bearing. Two worth knowing:
`AXOLOTY_DEVCONTAINER=1` is **mandatory on Linux** — without it the Core tool
picks its host path and reports a misleading "canonical Git checkout" error
(§1). `--user` avoids Git's dubious-ownership refusal (§3).

**Then check the digest:**

```bash
sha256sum ~/axhome/scratch/firmware/build/axoloty-swift.bin
```

If it is `7a2780258888c8bd52034d3de6397de38a958cbc09ad6f693c605519d743a8e3`,
you reproduced the build on different hardware — worth reporting either way.
**A mismatch is a finding, not a blocker:** record it and keep going, because
it means something about the build is not as deterministic as believed.

## Step 3 — flash and qualify

Same scratch directory as the build — `qualify.sh` reads the image and
provenance the build wrote, so they must share `AXOLOTY_SCRATCH`.

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --device "$DEVICE_NODE" \
  --group-add "$(getent group dialout | cut -d: -f3)" \
  -v ~/axemb:/workspace -v ~/axcore:/core -v ~/axhome:/tmp/h \
  -w /workspace \
  -e HOME=/tmp/h \
  -e AXOLOTY_DEVCONTAINER=1 \
  -e AXOLOTY_SOURCE_DIR=/core \
  -e AXOLOTY_SCRATCH=/tmp/h/scratch \
  -e AXOLOTY_PROOF_RUN_ID=device-qual-1 \
  -e AXOLOTY_DEVICE_PORT="$DEVICE_NODE" \
  -e AXOLOTY_MQTT_HOST=<broker-host> \
  axoloty-embedded-dev \
  bash -lc 'Profiles/esp32c6-mqtt/qualify.sh'
```

This flashes, runs `embedded-swift-smoke-v2` over serial JSON Lines, validates
the stream, and — **only if the proof passed** — writes
`docs/evidence/esp32c6-mqtt-embedded-swift-smoke-v2.json`.

The script refuses to write qualification evidence from a failed proof, and it
refuses to qualify a compatibility preview at all. Do not work around either
guard. A failed run that records a failure is worth more than a pass you had
to arrange.

## Step 4 — what to send back

```bash
git -C ~/axemb diff -- docs/evidence/
bash ~/axemb/Tools/verify.sh
```

Send:

1. The evidence record `qualify.sh` wrote. Every field in it is computed.
2. The `verify.sh` summary. **`device` should now say PASS rather than SKIP** —
   that single line is the point of the whole exercise.
3. The `sha256sum` from step 2, matching or not.
4. On failure: `~/axhome/scratch/firmware/working-evidence/` entire, plus
   `build.log`. Do not summarise it; the raw evidence is the useful part.

Then a release becomes possible: `Tools/release.sh --profile esp32c6-mqtt`
refuses to produce one from a build whose `build` or `device` tier reported
`SKIP`, so until step 3 passes, there is nothing to release.

## The case count (resolved 2026-09-19)

An earlier review counted `expectedSmokeTests` (22) plus `expectedVectorTests`
(56) and concluded the validator enforced 78 case IDs while the prose claimed
312. That count missed the third contribution: `expectedEmbeddedSwiftTests`
adds every corpus case crossed with six corpus operations, so the enforced set
is 22 + 56 + 39 × 6 = **312**, and that is what the first device run
validated.

`Tools/check-smoke-coverage.sh` used to pin only the two named sets. It now
pins all 312 IDs, so the corpus subset cannot shrink silently either.

`qualify.sh` writes whatever the validator counted — 312/312 on this run. Do
not restate it from prose; copy the number the record carries.

## If it does not boot

`Platforms/esp32c6-idf/` owns flash and monitor tooling; the monitor runs
through a pseudo-terminal so its output is captured rather than lost.

Two known hazards worth checking first:

- **The restart seam.** `@convention(c)` cannot carry a `() -> Never`, so the
  pointer returns `Void` and `DeviceSmokeSeam.restartDevice()` wraps it with a
  `fatalError` the compiler can see. If the device resets in an unexpected
  place, this is the seam to read.
- **The Unicode linker regression.** `Tests/embedded/check-swift-linker.sh`
  exists because of a `UnicodeDataTables`/`.got.plt` failure that manifests at
  link time. If the image links but misbehaves around string handling, run it.

Wi-Fi and broker configuration live in the platform, not the application. No
credential is tracked in this repository — invariant 9 enforces that — so the
board gets them from the platform's configuration path, not from a commit.
