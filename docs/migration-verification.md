# Migration verification

What was actually proved about the #1 firmware migration, how, and what
remains unproven. Written during review, before any board was available.

The migration's hard criteria — a clean-clone build, a flashed image, and the
device smoke run — need a toolchain and an ESP32-C6. Neither existed in the
environment where the migration was done or reviewed, and both are recorded as
`unexecuted` in `docs/evidence/`.

That is not the same as knowing nothing. Two properties were proved mechanically
with nothing but `node` and `python3`.

## 1. The generated corpus is unchanged

`Applications/device-smoke-agent/fixtures/generate-embedded-corpus.mjs` emits
the Swift corpus the smoke image runs. Running the migrated generator and the
pre-split generator and diffing their output:

```bash
node Applications/device-smoke-agent/fixtures/generate-embedded-corpus.mjs \
     Applications/device-smoke-agent/fixtures/manifest.json /tmp/new.swift
node <axoloty>/Embedded/swift/fixtures/generate-embedded-corpus.mjs \
     <axoloty>/Embedded/swift/fixtures/manifest.json /tmp/old.swift
diff /tmp/old.swift /tmp/new.swift
```

Result: 1095 lines each, and 20 differing lines, all of them expected:

- the header comment naming the manifest's new path;
- `vTaskDelay(1)` → `deviceSmokeSeam().delay(1)`;
- `esp_timer_get_time()` → `deviceSmokeSeam().nowMicroseconds()`.

Every wire payload, case identifier, family, and size class is byte-identical.
The seam substitution is the de-boarding the split required, and it is the only
semantic change in the generated corpus.

## 2. The expected smoke case set is unchanged

`Platforms/esp32c6-idf/tools/validate-smoke.mjs` decides a run passed by
comparing observed case IDs against `expectedSmokeTests` and
`expectedVectorTests`. Comparing those sets with the pre-split validator:

| Set | Before | After | Lost | Added |
|---|---|---|---|---|
| `expectedSmokeTests` | 22 | 22 | none | none |
| `expectedVectorTests` | 56 | 56 | none | none |
| Total unique | 78 | 78 | none | none |

No case was dropped and none was invented. `Tools/check-smoke-coverage.sh` now
pins that set by count and digest, so a future change cannot shrink it quietly.
A board cannot catch that kind of loss: a board only runs what it is asked to
run, and a validator that asks for less still reports a clean pass.

## The "312 cases" figure is right (corrected 2026-09-19)

An earlier review compared only `expectedSmokeTests` (22) and
`expectedVectorTests` (56) and concluded the validator enforced 78 case IDs
while the prose claimed 312. That count was incomplete.
`Platforms/esp32c6-idf/tools/validate-smoke.mjs` builds
`expectedEmbeddedSwiftTests` from those two sets **plus every corpus case
crossed with six corpus operations**: 22 + 56 + 39 × 6 = **312**, and that is
the set the device validator enforces.

The first device run (2026-09-19, Axoloty 0.8.2) validated 312/312 case IDs on
an ESP32-C6, matching the documented bar. `Tools/check-smoke-coverage.sh` had
pinned only the two named sets; it now pins all 312 IDs, so the corpus subset
cannot shrink silently either. The evidence record carries the validator's own
count.

## What the device run proved, and what is still unproven

The first device run (2026-09-19, ESP32-C6 QFN40 revision v0.0, MAC
`40:4c:ca:4d:8c:e8`, Axoloty 0.8.2) resolved the execution questions:

- the migrated CMake configures and compiles;
- the `@convention(c)` conversions in
  `Platforms/esp32c6-idf/main/Esp32c6SmokeSeam.swift` compile and call
  correctly, and `idf_component_register` accepts the absolute transport
  source path;
- the image boots and passes the 312-case smoke protocol on hardware;
- the flashed artifact is the reproducible `7a2780…` image at the locked
  revision.

Still unproven, because this image carries no compiled network configuration
and the smoke run is serial-only:

- MQTT connect, last-will, reconnect, and broker-restart behavior;
- the role-config and host-interop harnesses that verify those paths, which
  remain unmigrated (`docs/check-inventory.md`, note A).

Do not round the serial pass up into an MQTT claim.

## Pinned defaults that keep behavior identical

Two constants carry the "behavior-preserving" claim, because the axis rules in
`AGENTS.md` forced their values out of the application:

| Constant | Where | Why it is pinned |
|---|---|---|
| `AXOLOTY_DEVICE_DISPLAY_NAME` = `"ESP32-C6 A"` | `Platforms/esp32c6-idf/main/network_bootstrap.c` | The role-A advertise and resolve payloads embed it. Any other value changes the emitted wire bytes. |
| the subscription wildcard | supplied by the application to `axoloty_agent_test` | It was a hard-coded routing key in platform C. The bytes subscribed must stay the same. |

Changing either changes what the device puts on the wire. Treat both as part of
the protocol surface until a hardware run says otherwise.
