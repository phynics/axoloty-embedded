# MQTT device qualification, 2026-10-26

All eight hardware stages passed on clean firmware source
`1aa050a4c59df48c2ddd2a094a72d68ebb3c2f55`, using locked Core
`f8c201f717e843d7b838ba1d9ff56bd5be729522`. Each record below names the
flashed image checksum and the unit that ran it.

| Stage | Observed result | Generated records |
|---|---|---|
| Network | 323/323, including 11 network checks | [Network](esp32c6-mqtt-network-test.json) |
| CoatyJS interoperability | 10/10 in each device role | [A](esp32c6-mqtt-coatyjs-interop-a.json), [B](esp32c6-mqtt-coatyjs-interop-b.json) |
| Axoloty host interoperability | 10/10 in each device role | [A](esp32c6-mqtt-host-interop-a.json), [B](esp32c6-mqtt-host-interop-b.json) |
| Two-board exchange | 10/10 on each board | [A](esp32c6-mqtt-agent-test-a.json), [B](esp32c6-mqtt-agent-test-b.json) |
| Last-will delivery after forced reset | 8/8 on the observing board | [B](esp32c6-mqtt-last-will-b.json) |
| Broker stop, restart, and resumed exchange | 11/11 on each board | [A](esp32c6-mqtt-broker-restart-a.json), [B](esp32c6-mqtt-broker-restart-b.json) |

## Run identity and method

The operator selected the two ESP32-C6 units with USB identity suffixes
`4E:52:DC` and `4D:8C:E8`. Device manifests bind those selections to the chip
descriptions and MAC addresses recorded in the generated evidence.

The run used Swift 6.4 and ESP-IDF 5.4 in pinned development image
`sha256:9006ed8fa42927aa468ff206a8f4ad3149a2994cb327307ee7752e96ac2bbda2`.
CoatyJS used the pinned 2.4.0 reference agent. The Axoloty host peer resolved
the locked Core revision. Firmware builds and hardware stages ran serially.

The production runners were `run-network-test.sh`,
`run-coatyjs-interop-test.sh`, `run-host-interop-test.sh`,
`run-agent-test.sh`, `run-last-will-test.sh`, and
`run-broker-restart-test.sh` under `Tests/embedded/`. Each runner generated
its evidence only after its validator accepted the observed device output.
The parent separately checked firmware checksums against build provenance;
an independent evidence review passed.

The first cached attempt produced unconfigured firmware because adding an
optional private header did not invalidate all cached C objects. A fresh
configured build then passed Wi-Fi and DHCP but timed out connecting to the
broker. After the operator opened temporary LAN-only TCP port 1883, the
network retry and the remaining stages passed. Both earlier failed attempts
remain separate from the passing evidence. For copied build caches in this
run, the parent explicitly removed the bootstrap and MQTT carrier objects
before rebuilding to avoid the known optional-header defect.

## Retained receipts and limits

The operator evidence bundle is
`mqtt-hardware-suite-2026-10-26-public.tar.gz`, SHA-256
`1c7760e14f4a65965b69f176cc23969477f0e199ce0632e7baf3f2be689f40c9`.
It contains generated records, provenance, device manifests, structured
serial records, peer results, and hash inventories. Credential-bearing
firmware and raw Wi-Fi logs remain private. The independent review report
has SHA-256
`e66914d49efa19f0e7c176283b5b07def3dd9ca23418234c15e11591f9fe41d6`.

The network capture contains a complete 323-case pass followed by an
incomplete second sequence. The validator accepts the first completion;
the trailing sequence is excluded from the reported result.

This is one complete MQTT suite. It is not a repeated reliability campaign,
a Zenoh hardware qualification, a release certificate, or evidence for a
later firmware source revision. Zero warmed-path allocations do not prove
allocation freedom during state initialization.

## Remaining epic #62 acceptance

The hardware suite establishes the migrated MQTT application's network and
interoperability behavior. The epic remains open for:

- A second pure Swift application without platform or transport edits.
- A host or simulated platform without application edits.
- Removal of remaining application-owned C, headers, and module maps, and
  enforcement of the application and platform dependency boundary.
- Final linked static-state placement, bounded initialization stack use,
  and allocation freedom during initialization.
- The complete embedded ABI authoring guide and final acceptance matrix.

The approved storage contract permits budgeted `.data` for constant nonzero
state and `.bss` for zero-backed state. The current state-budget check rejects
oversized state at entry; it is not a compile-time or link-time rejection.
