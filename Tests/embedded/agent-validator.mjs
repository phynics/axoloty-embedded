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

// The last-will scenario has no Discover/Resolve exchange. The observer must
// see the peer Advertise and then the broker-published Deadvertise after the
// advertiser is reset abnormally.
export const expectedLastWillTests = new Set([
  "exchange:wifi",
  "exchange:ip",
  "exchange:mqttConnect",
  "exchange:subscribe",
  "exchange:reconnect",
  "exchange:advertise",
  "exchange:deadvertise",
  "exchange:disconnect",
]);

// The broker-restart scenario adds a third MQTT connect after the broker is
// stopped and restarted, then runs the full exchange.
export const expectedBrokerRestartTests = new Set([
  "exchange:wifi",
  "exchange:ip",
  "exchange:mqttConnect",
  "exchange:subscribe",
  "exchange:reconnect",
  "exchange:brokerReconnect",
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
