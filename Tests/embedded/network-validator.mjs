// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The smoke corpus plus the carrier records a network-configured image emits.
// Selected by the device harness through EMBEDDED_VALIDATOR and
// EMBEDDED_VALIDATOR_FACTORY.

import {
  createEmbeddedSwiftSmokeValidator,
  expectedCborRunId,
  expectedCborSmokeTests,
  expectedEmbeddedSwiftTests,
} from "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs";

export const expectedNetworkTests = new Set([
  ...expectedEmbeddedSwiftTests,
  "network:wifi",
  "network:ip",
  "network:mqttConnect",
  "network:subscribe",
  "network:lastWillConfigured",
  "network:reconnect",
  "network:publish",
  "network:receive",
  "network:disconnect",
  "network:rejectOutOfOrder",
  "network:rejectOversize",
]);

/** Creates the strict validator for the configured network firmware stream. */
export function createEmbeddedNetworkValidator() {
  return createEmbeddedSwiftSmokeValidator(expectedNetworkTests);
}

// The Zenoh probe reports the same transport-neutral steps with two honest
// differences: the broker last-will and the single-client loopback receive
// have no equivalent in its client profile, so it records explicit
// unsupported capabilities instead of the MQTT will/connect/receive cases.
// The strict validator accepts `unsupported` only for these two declared
// case IDs, and their count is separate from passed checks in the summary.
//
// A Zenoh image carries only the `axoloty/1` CBOR profile and links no JSON
// parser, so its stream is smoke protocol v3: the CBOR smoke set plus these
// carrier records, under the v3 run id.
export const expectedZenohNetworkTests = new Set([
  ...expectedCborSmokeTests,
  "network:wifi",
  "network:ip",
  "network:zenohConnect",
  "network:subscribe",
  "network:lastWillUnsupported",
  "network:reconnect",
  "network:publish",
  "network:receiveUnsupported",
  "network:disconnect",
  "network:rejectOutOfOrder",
  "network:rejectOversize",
]);

/** Creates the strict validator for the Zenoh network firmware stream. */
export function createEmbeddedZenohNetworkValidator() {
  return createEmbeddedSwiftSmokeValidator(expectedZenohNetworkTests, new Set([
    "network:lastWillUnsupported",
    "network:receiveUnsupported",
  ]), expectedCborRunId);
}
