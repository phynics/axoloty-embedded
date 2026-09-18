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

## The "312 cases" figure does not match the validator

Issue #1's pass bar, `docs/embedded-consumer-contract.md`, and the 0.8.0 release
notes all say the smoke run passes **312 deterministic cases**. The validator
does not count to 312 anywhere.

`Platforms/esp32c6-idf/tools/validate-smoke.mjs` decides a pass by matching
observed case IDs against `expectedSmokeTests` (22) and `expectedVectorTests`
(56): **78 unique case IDs**. The literal `312` appears in prose only, never in
the harness, and the pre-split validator counted the same 78.

So this is not a migration defect — the count is unchanged by the move. It is a
pre-existing mismatch between the documented bar and the enforced one. It
matters at sign-off: a hardware run that satisfies the validator proves 78 case
IDs, and recording that as "312/312 passed" would be a claim nothing checked.

Reconcile before anyone signs off a device run: either the prose counts
something else the validator does not enforce (records or stages rather than
case IDs), or one of the two numbers is wrong. Do not assume which.

## What is still unproven

Proving the corpus and the case set is not proving the firmware. These need a
toolchain and a board, and no amount of inspection substitutes:

- that the migrated CMake configures and compiles at all;
- that the `@convention(c)` closure conversions in
  `Platforms/esp32c6-idf/main/Esp32c6SmokeSeam.swift` compile and call correctly;
- that `idf_component_register` accepts the absolute transport source path
  `${AXOLOTY_TRANSPORT_DIR}/main/mqtt_event_validation.c`;
- that the image boots, connects, and passes the smoke protocol on hardware;
- that MQTT last-will, reconnect, and broker-restart behavior survived the move.

Until a board runs them, the migration is well-evidenced in its data and
unproven in its execution. Say it that way; do not round it up.

## Pinned defaults that keep behavior identical

Two constants carry the "behavior-preserving" claim, because the axis rules in
`AGENTS.md` forced their values out of the application:

| Constant | Where | Why it is pinned |
|---|---|---|
| `AXOLOTY_DEVICE_DISPLAY_NAME` = `"ESP32-C6 A"` | `Platforms/esp32c6-idf/main/network_bootstrap.c` | The role-A advertise and resolve payloads embed it. Any other value changes the emitted wire bytes. |
| the subscription wildcard | supplied by the application to `axoloty_agent_test` | It was a hard-coded routing key in platform C. The bytes subscribed must stay the same. |

Changing either changes what the device puts on the wire. Treat both as part of
the protocol surface until a hardware run says otherwise.
