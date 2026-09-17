# Migration discoveries

Unrelated defects found while moving the ESP32-C6 + MQTT firmware out of
`phynics/axoloty` into this repository. Each is out of scope for the
behavior-preserving migration. None is fixed here; the maintainer decides which
become their own issues.

## 1. Duplicated network limits in the MQTT event validator

- **File:** `Transports/mqtt-espidf/main/mqtt_event_validation.c`
- **What I saw:** the validator defines its own `NETWORK_MAX_TOPIC` (257) and
  `NETWORK_MAX_PAYLOAD` (2049) macros, which also appear in
  `Platforms/esp32c6-idf/main/network_bootstrap.c`. Two files now own the same
  bound, so a future change to one silently diverges from the other.
- **Why out of scope:** consolidating the bound would change a transport /
  platform interface, which is a design change, not a file move.

## 2. Two implementations of the Swift GOT linker patch

- **File:** `Platforms/esp32c6-idf/main/patch-swift-got.mjs`
- **What I saw:** the JavaScript module reimplements the exact
  discard-rule/replacement logic of `patch-swift-got.cmake`. The ESP-IDF build
  invokes only the CMake script; no build file references the `.mjs` module.
  It appears to exist for a host-side test that did not move with the firmware.
- **Why out of scope:** deciding whether the JavaScript copy is still needed
  requires reviewing the upstream test that used it; removing it is unrelated
  cleanup.

## 3. Stale top-level project comment

- **File:** `Platforms/esp32c6-idf` (moved from `Embedded/swift/CMakeLists.txt`)
- **What I saw:** the original header comment said the project compiles
  "AxolotyWire, AxolotyProtocol, and AxolotyObjectModel", but the components
  also compile AxolotyCoatyModels and AxolotyStaticRuntime. The comment
  understates the real dependency set.
- **Why out of scope:** a documentation correction that does not affect build
  behavior. The rewritten top-level file no longer repeats the claim, but the
  underlying stale wording was not chased through every component.

## 4. Warning policy differs between Core components and the application

- **File:** `Platforms/esp32c6-idf/components/axoloty_static_runtime/CMakeLists.txt`
- **What I saw:** the static-runtime component compiles with
  `-warnings-as-errors`, while the wire, protocol, object-model, and
  coaty-models components and the main application do not. A warning that fails
  one component can pass the next.
- **Why out of scope:** unifying the warning policy is a repository-wide build
  decision, not part of moving the files.

## 5. GO-proof tooling depended on a Core-side extraction marker

- **File:** `Platforms/esp32c6-idf/tools/write-provenance.mjs` and
  `validate-go-proof.mjs`
- **What I saw:** both scripts read `firmware/.axoloty-source-revision`, a
  marker written by the pre-split Core-side proof driver. A standalone
  `axoloty-embedded` checkout never produces that file, so the scripts cannot
  run as moved.
- **Why out of scope:** the marker is an artifact of the old repository
  layout. The migration removes the dependency and records the firmware
  checkout's own Git revision instead, but the wider GO-proof lifecycle
  (evidence naming, replay) may deserve a separate review.

## 6. Generated corpus called the SDK directly

- **File:** `Applications/device-smoke-agent/fixtures/generate-embedded-corpus.mjs`
- **What I saw:** the generator emitted `esp_timer_get_time()` and
  `vTaskDelay()` into application source, so the generated application code
  named the SDK even though `Main.swift` did not.
- **Why out of scope:** the generator's output format is a build concern with
  its own review; the migration routes those two calls through the seam so the
  generated code stays application-neutral, but the generator's broader
  coupling to the platform was not redesigned.

## Provenance

Filtered Git history is not preserved across the split, so the exact source
commit is recorded here as the only link back to Axoloty.

- **Source repository:** `phynics/axoloty`
- **Source commit:** `943116e2d69d0894e7889ccad5979d29bdb9c2a7`
  (branch `feature/1-migrate-esp32-c6-m-7dx`, working tree clean)
- **Source tree:** `Embedded/swift/`
- **Locked Core revision in this repository:**
  `7d0a65287d35af571db88e616d0b5cbb3c9f8625`

The migration source commit is newer than the locked Core revision. That is
expected: the firmware checkout moved from a newer Axoloty `main`-line commit,
while the build still pins the lock's exact revision through
`Tools/prepare-core.sh`. No file under `phynics-axoloty` was modified by this
migration.

