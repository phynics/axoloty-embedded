// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The smoke corpus plus the carrier records a network-configured image emits.
// Selected by the device harness through EMBEDDED_VALIDATOR and
// EMBEDDED_VALIDATOR_FACTORY.

import {
  createEmbeddedSwiftSmokeValidator,
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
