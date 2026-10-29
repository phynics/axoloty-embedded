# MQTT qualification against Core v0.10.0, 2026-10-29

The retained runs use Core `087bd9bb1bfb563d0347799245ea4dd43e509bc9`. The table lists observed device checks. Each linked record was checked against its retained validator result, device manifest, build provenance and image SHA-256.

| Check | Result | Device evidence |
|---|---|---|
| network-test | 323 passed, 0 failed | [network-test](esp32c6-mqtt-network-test.json) |
| coatyjs-interop-a | 10 passed, 0 failed | [coatyjs-interop-a](esp32c6-mqtt-coatyjs-interop-a.json) |
| coatyjs-interop-b | 10 passed, 0 failed | [coatyjs-interop-b](esp32c6-mqtt-coatyjs-interop-b.json) |
| host-interop-a | 10 passed, 0 failed | [host-interop-a](esp32c6-mqtt-host-interop-a.json) |
| host-interop-b | 10 passed, 0 failed | [host-interop-b](esp32c6-mqtt-host-interop-b.json) |
| agent-test-a | 10 passed, 0 failed | [agent-test-a](esp32c6-mqtt-agent-test-a.json) |
| agent-test-b | 10 passed, 0 failed | [agent-test-b](esp32c6-mqtt-agent-test-b.json) |
| last-will-b | 8 passed, 0 failed | [last-will-b](esp32c6-mqtt-last-will-b.json) |
| broker-restart-a | 11 passed, 0 failed | [broker-restart-a](esp32c6-mqtt-broker-restart-a.json) |
| broker-restart-b | 11 passed, 0 failed | [broker-restart-b](esp32c6-mqtt-broker-restart-b.json) |

## Reproducibility

Two clean unconfigured MQTT builds from firmware source `cf52c2518451cf9008ba80372976c8edd508b6c6` produced the same 671,616-byte image, SHA-256 `c3e1920645081c22f21fb50c4c36db8b1b66d948ee8fd7da62bf10f7013d2783`. The [build record](esp32c6-mqtt-reproducible-build.json) names that source revision. Configured device scenarios have their own image hashes and are not relabeled as this unconfigured image.

## Failure and correction

The first host-responder run exited zero on the host but failed Resolve and Deadvertise on the device, with 8 passes and 2 failures. The host stopped after Core admitted its final operations, while stop could discard their queued outbound effects. The corrected host waits for its matching Deadvertise broker echo before stopping. The retry passed 10/10. The other board was parked in its bootloader during that isolated retry. Hardware comparison alone therefore does not establish unique causation; the dropped-effect path was also verified in the locked Core source. See [PR #93](https://github.com/phynics/axoloty-embedded/pull/93).

Broker restart ran once and passed 11/11 on each board. This is one observed recovery, not a repeated reliability campaign.

## Evidence and scope

The rerunnable operator audit is `qualification-resume/audit-mqtt-qualification.py` under the retained qualification workspace. Its report SHA-256 is `d07f85d5ad92a1a79b4db1ac000b22afd0c52b10b43784e139088a0931c3fee5`. It verifies ten generated device records, their actual binary hashes, Core and firmware revisions, validator counts, and both clean rebuilds. Raw captures, configured images and private operator configuration remain outside the repository. The original failed capture is retained separately from the passing retry.

The image was `axoloty-embedded-dev`, SHA-256 `9006ed8fa42927aa468ff206a8f4ad3149a2994cb327307ee7752e96ac2bbda2`, with Swift 6.4 and ESP-IDF 5.4. The two authorized ESP32-C6 units have base MAC addresses `40:4C:CA:4E:52:DC` and `40:4C:CA:4D:8C:E8`. Per-run manifests identify which unit ran each role.

This evidence does not qualify Zenoh, certify a release, establish a whole-image stack bound, or prove allocation freedom. In particular, the host-B network run observed `hotPathAllocations: 3`; its pass concerns protocol exchange. Earlier serial smoke and build evidence remain separate records. #73 remains open for its remaining profile requirements, and #79 stays deferred.
