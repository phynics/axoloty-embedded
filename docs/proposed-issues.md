# Proposed embedded Zenoh issues

These are the issues `phynics/axoloty#853` proposed for
`phynics/axoloty-embedded`. They were not filed separately:
[#8](https://github.com/phynics/axoloty-embedded/issues/8) is the single
implementation and qualification issue and uses ZP-1 … ZP-8 below as its
checklist. Split one out only if #8 grows unmanageable.

Each issue is the embedded-side replacement for the Axoloty-side Zenoh ticket
named in `#853`. The public `axoloty_zenoh_*` facade contract stays defined by
`phynics/axoloty`; these issues implement against it, they do not redefine it.

Sequencing: `ZP-1` (qualification) and `ZP-2` (conformance) gate the pinned
component work; `ZP-3` gates `ZP-4`; `ZP-4` gates `ZP-5`; `ZP-5` gates
`ZP-6` and `ZP-7`; `ZP-6` and `ZP-7` gate `ZP-8`.

## ZP-1 — `[ZENOH] Qualify pinned zenoh-pico against ESP32-C6 embedded toolchain`

Supersedes the embedded half of `phynics/axoloty#797`.

**Outcome.** Prove the pinned `zenoh-pico 1.10.0`
(`96006957fddef401c20c8c2d813c2a630b666974`) compiles and links for
`esp32c6` with the v1 feature profile on the repository's pinned ESP-IDF, and a
C-only publish/subscriber smoke runs on hardware.

**Scope.**

- Compile `zenoh-pico` through the ESP-IDF component wrapper with the feature
  profile and tuning recorded in `docs/dependencies/zenoh.md`.
- A C-only ESP32 publish/subscriber smoke test with no Swift involved.
- Record or confirm the static footprint (flash/`.data`/`.bss`) for this
  repository's build, rather than quoting Axoloty's numbers.
- Reconcile `Platforms/esp32c6-idf/components/zenoh_pico/CMakeLists.txt` against
  a real compile: its generated-header tokens and source list already match the
  pinned tree by inspection, but the feature profile, include order, and
  `esp_driver_uart` dependency are unproven until configured and built.

**Acceptance criteria.**

- `zenoh-pico` builds through `idf.py` for `esp32c6` with only the required
  features enabled.
- A C-only pub/sub round trip runs on an ESP32-C6.
- The matrix entry and observed revision are recorded in the lock.
- An evidence record is written, `passed` or `failed`, with the device, the
  artifact checksum, and the Core revision.

## ZP-2 — `[ZENOH] Run Zenoh backend conformance against zenoh-pico`

Supersedes the embedded half of `phynics/axoloty#805`.

**Outcome.** The Axoloty-owned facade conformance suite runs against the
`zenoh-pico` backend, with no hidden semantic divergence from `zenoh-c`.

**Scope.**

- Run the shared fixture/vector suite against the pico backend, on a host
  `zenoh-pico` build and on the embedded target where feasible.
- Document every behavioral divergence; do not special-case silently.

**Acceptance criteria.**

- The same suite that passes against `zenoh-c` passes against `zenoh-pico`.
- Any divergence is documented in `docs/zenoh-embedded.md`, not hidden.
- The suite is not forked into two contracts.

## ZP-3 — `[ZENOH] Integrate pinned zenoh-pico into ESP32-C6 profile`

Supersedes `phynics/axoloty#813`; `#813` is to be closed `not_planned` /
superseded once this exists.

**Outcome.** The pinned `zenoh-pico` component is integrated through the
existing ESP-IDF/CMake build and selected by the `esp32c6-zenoh` profile.

**Scope.**

- Carry over ESP-IDF integration, TCP/IPv4, client mode, pub/sub.
- Bounded buffer tuning, stack sizing, and documentation.
- Complete the component wrapper and `Tools/prepare-zenoh-pico.sh` flow.

**Acceptance criteria.**

- `zenoh-pico` builds as part of `idf.py build` with only the required features.
- Buffer and stack tuning values are documented with rationale.
- The `esp32c6-zenoh` profile produces an image.

## ZP-4 — `[ZENOH] Implement zenoh-pico backend of Axoloty Zenoh facade`

Supersedes `phynics/axoloty#814`.

**Outcome.** The pico backend implements the device carrier seam
(`axoloty_zenoh_*`) so `EmbeddedZenohClient` compiles and links against
`zenoh-pico`, without changing the public facade contract.

**Scope.**

- Implement `axoloty_zenoh_open`, `axoloty_zenoh_subscribe`,
  `axoloty_zenoh_publish`, `axoloty_zenoh_poll`, `axoloty_zenoh_unsubscribe`,
  `axoloty_zenoh_close` over `zenoh-pico`, using
  `zenoh_sample_validation.c` at the sample boundary.
- Keep the public facade header unchanged.
- Report any pico-specific incompatibility explicitly.

**Acceptance criteria.**

- The public facade ABI is unchanged.
- No silent divergent semantics; incompatibilities are documented.
- `ZP-2` conformance runs against this backend.

## ZP-5 — `[ZENOH] Implement EmbeddedZenohClient`

Supersedes `phynics/axoloty#815`.

**Outcome.** The bounded client lands in `Transports/zenoh-pico/` with the
same shape as `EmbeddedMQTTClient`: open/subscribe/publish/poll/unsubscribe/
close, borrowed buffers, explicit lengths, no Foundation, no implicit
allocation, no callback into Swift.

**Scope.**

- The skeleton is already in this repository
  (`Transports/zenoh-pico/main/EmbeddedZenohClient.swift`) with a host seam
  test. This issue completes it against the real backend and the landed facade
  ABI, then removes the provisional carrier declarations.

**Acceptance criteria.**

- API surface matches `EmbeddedMQTTClient`'s shape closely enough that `ZP-6`
  needs no carrier-specific branching beyond client selection.
- No Foundation dependency; no implicit heap allocation in steady-state.
- The host seam test passes in the `build` tier.

## ZP-6 — `[ZENOH] Wire EmbeddedZenohClient into shared AxolotyProtocol runtime path`

Supersedes `phynics/axoloty#816`.

**Outcome.** Received Zenoh frames feed the shared portable protocol
processor; MQTT Embedded and Zenoh Embedded run identical `AxolotyProtocol`
production code.

**Scope.**

- Generalize the application carrier seam so a transport supplies its carrier
  probe and locator instead of the application naming `runCarrierNetworkProbe`
  and `emitAgentExchange`.
- Wire `EmbeddedZenohClient` frames into the same processor as MQTT Embedded.

**Acceptance criteria.**

- Zenoh Embedded and MQTT Embedded invoke the same `AxolotyProtocol` paths.
- No Zenoh-specific protocol branch anywhere in the static runtime.
- The application names no carrier.

## ZP-7 — `[ZENOH] Install embedded Coaty route interest over Zenoh`

Supersedes `phynics/axoloty#817`.

**Outcome.** The two bounded Coaty route shapes are installed as embedded
Zenoh subscriptions, with key-expression behavior validated as equivalent to
the host's.

**Scope.**

- Install the two route shapes the host uses, as keys, unchanged.
- Confirm `zenoh-pico` key-expression matching is equivalent to `zenoh-c`'s
  for those shapes.

**Acceptance criteria.**

- Both route shapes are installed on the embedded target.
- Matching equivalence is confirmed against the host.

## ZP-8 — `[ZENOH] Qualify ESP32-C6 Zenoh firmware profile`

Supersedes `phynics/axoloty#818`.

**Outcome.** A dedicated Zenoh hardware qualification gate on ESP32-C6,
parallel to the MQTT one, with enforced regression thresholds.

**Scope.** Cold boot, Wi-Fi connect, session open, subscribe, publish,
loopback, bidirectional Axoloty communication, router absent at boot, router
disappears, router returns, Wi-Fi disappears, Wi-Fi returns, reconnect repeated
100 times, continuous traffic, queue saturation, maximum payload, oversized
payload rejection, clean shutdown. Measure flash size, free/minimum heap,
largest free block, main and worker stack high-water marks, and steady-state
allocations.

**Acceptance criteria.**

- No unbounded heap growth across reconnect cycles, no queue corruption, no
  stale subscriptions, no protocol divergence after reconnect, no task leak.
- Regression thresholds fail the build; they are not recorded-only.
- An evidence record names the device, artifact checksum, and Core revision.

## Axoloty-side references, unchanged here

- `#797` keeps the cross-component version matrix, `zenoh-c`, and `zenohd`.
- `#805` keeps the backend-neutral facade contract, shared fixtures, host
  `zenoh-c` conformance, and portable expectations.
- `#814`'s public facade contract remains Axoloty-owned.
- `#819` (diagnostics) and `#820` (docs) ownership stays split as `#853`
  describes.
