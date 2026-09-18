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

## Issue #2 — embedded test ownership (`axoloty-embedded#2`)

Findings from classifying and moving the embedded checks. None is fixed here;
the maintainer decides which become their own issues. The full disposition table
is [check-inventory.md](./check-inventory.md).

### 7. The role-config build lifecycle did not move with the firmware

- **Files:** `Tests/Support/embedded/embedded-{network,agent,host,coatyjs,last-will,broker-restart}-test.sh`
  in `phynics/axoloty`, `generate-embedded-network-config.mjs`
- **What I saw:** the pre-split device and broker harnesses wrote
  `axoloty_network_config.h` into the single `Embedded/swift` build tree
  *between* `idf.py set-target` and `idf.py build`, then built role-specific
  images. #1 migrated the firmware into a profile/platform composition whose
  `Platforms/esp32c6-idf/tools/build.sh` has no scenario/role-config injection
  point: it validates Core, copies the platform to a proof root, configures,
  and builds in one invocation.
- **Why out of scope:** adding an injection point is a firmware build-lifecycle
  change, which is a redesign, not a check move. The harnesses are therefore
  **unmigrated** and named `MOVE` in the inventory. The firmware support they
  exercise (`CarrierNetworkProbe`, the `network_bootstrap.c` scenario bits)
  did move with #1.

### 8. No committed historical embedded device evidence exists

- **Files:** `phynics/axoloty` `.gitignore` (`.testing/`), `docs/embedded-toolchain.md`
- **What I saw:** the pre-split documentation refers to reviewed physical
  evidence, but those runs lived in `.testing/embedded/`, which is
  git-ignored. No machine-readable device evidence record was ever committed.
- **Consequence:** there is no record whose original status could be preserved
  under the `importedFrom` shape in `docs/evidence.md`. The embedded
  documentation was imported with provenance; the evidence itself was not
  recoverable. A device claim can only come from a new run here.

### 9. `Tests/Support` is ambiguous between the two repositories

- **File:** `Tools/check-invariants.sh` rule 7b (`private_tokens`)
- **What I saw:** the invariant that forbids firmware from naming Core's
  private tree matches the literal token `Tests/Support`. The pre-split
  harnesses had exactly that path, so importing them unchanged tripped the
  rule. It is impossible for a grep to tell "Core's `Tests/Support`" from "our
  `Tests/Support`".
- **What I did instead of changing the invariant:** the imported harness lives
  at `Tests/embedded/`, which keeps the rule meaningful and unchanged. If a
  future maintainer wants the old path, the rule needs a deliberate refinement
  rather than a loophole.

### 10. CI has no pinned ESP-IDF + Swift image

- **File:** `.github/workflows/ci.yml`
- **What I saw:** the `build` job cannot produce a firmware image on
  `ubuntu-latest`: the pinned `axoloty-dev` image (Swift 6.3, ESP-IDF v5.4,
  RISC-V GCC, `idf_swift`) is not published to a registry this workflow can
  pull. The previous `--require build` would have failed CI for a capability CI
  does not have.
- **What I did:** the job now runs `Tools/verify.sh --tier build` without
  `--require`, so the host firmware checks run and the image build reports
  `UNAVAILABLE`. Publishing the pinned image (or a CI build of it) is a separate
  decision.

### 11. The Axoloty copies of the embedded docs and checks still exist

- **Files:** `phynics/axoloty` `Makefile`, `Tests/Support/embedded/*`,
  `Tests/Support/checks/check-embedded-*`, `docs/embedded-toolchain.md`
- **What I saw:** `phynics/axoloty` is read-only for this task, so the checks
  and documentation that are marked `MOVE` or `SUPERSEDE/DELETE` still exist
  there. The imported copy of `docs/embedded-toolchain.md` now describes this
  repository, but Axoloty's copy still describes the pre-split workflow and
  its `AGENTS.md` still lists `Embedded` as Core-owned.
- **Why out of scope:** deleting from Axoloty must happen in an Axoloty PR, by
  the maintainer, once this ownership change is accepted.

### 12. Two imported host tests needed include-path changes

- **Files:** `Tests/embedded/shared-flags-test.c`, `Tests/embedded/mqtt-host-hal.c`
- **What I saw:** both included firmware headers by the pre-split relative path
  `../../../Embedded/swift/main/...`. The firmware now lives under
  `Platforms/esp32c6-idf/main` and `Transports/mqtt-espidf/main`.
- **What I did:** changed the includes to bare header names and pass `-I` to
  the two firmware directories. This is a path adaptation the check
  demonstrably requires; the test logic is unchanged.
## Issue #3: firmware release provenance

Found while defining the release manifest and compatibility lifecycle. Each is
outside the manifest format; none is fixed here.

## 12. The evidence `device` field holds a serial port, not a board

- **File:** `Platforms/esp32c6-idf/tools/write-device-manifest.mjs`, called from
  `Platforms/esp32c6-idf/tools/flash.sh`
- **What I saw:** `docs/evidence.md` documents `device` as a board, with the
  example `"device": "ESP32-C6-DevKitC-1 v1.2"`. The code records the serial
  port path instead: `flash.sh` passes `${EMBEDDED_DEVICE:-/dev/ttyACM0}` as the
  `device` argument, and `write-device-manifest.mjs` copies it verbatim into
  both `device-manifest.json` and the qualification record. The pre-split code
  in `phynics/axoloty` did the same, so the schema example and the producer have
  disagreed since the migration source.
- **Why out of scope:** changing what `device` means is an evidence-schema
  change. The release manifest therefore takes `board` from the profile's
  declared target instead of the evidence record, and records the tested unit
  separately. Reconcile the documentation or the producer in its own issue.

## 13. The MQTT transport backend has no version of its own

- **File:** `Platforms/esp32c6-idf/dependencies.lock`
- **What I saw:** the transport is ESP-IDF's bundled `mqtt` component, which is
  not a managed component and carries no independent version. The only pinned
  version near it is the ESP-IDF SDK (`idf: 5.4.0`). The release manifest
  records the SDK version as the transport backend version and cites this lock.
  A transport with its own library (for example `zenoh-pico` under #4) has no
  place in this platform dependency lock to declare its version.
- **Why out of scope:** giving each transport an independently pinned backend
  version is a dependency-management change, not a manifest-format change. The
  manifest records what exists today and names its source.

## 14. The Core preparation report does not carry the Axoloty version

- **File:** `Tools/prepare-core.sh`, `docs/core-dependency.md`
- **What I saw:** the preparation report carries the Core commit SHA, dirty
  state, and contract hash, but not `core.version`. A release can take the
  version from the lock because the lock is authoritative for a release. A
  compatibility preview is off-lock by design, so there is no version to name:
  the preview manifest leaves `axoloty.version` null. Reading the Core
  checkout's `VERSION` file directly is not allowed, because Core is reached
  only through the preparation report, and taking an operator-supplied version
  would put an unobserved value in the record.
- **Why out of scope:** adding a version field to the report is an Axoloty
  contract change. The preview path stays honest about what it does not know.

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

