// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The strict per-participant validator for the two-device agent exchange.
// Imported from the pre-split Axoloty support tree during the embedded split.

import { createEmbeddedSwiftSmokeValidator } from "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs";

export const expectedAgentTests = new Set([
  "exchange:wifi",
  "exchange:ip",
  "exchange:mqttConnect",
  "exchange:subscribe",
  "exchange:reconnect",
  "exchange:advertise",
  "exchange:discover",
  "exchange:resolve",
  "exchange:deadvertise",
  "exchange:disconnect",
]);

/** Creates the strict validator for one participant in the two-device exchange. */
export function createEmbeddedAgentValidator(expectedTests = expectedAgentTests) {
  return createEmbeddedSwiftSmokeValidator(expectedTests);
}
