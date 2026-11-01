// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host side of the largest-frame check: sends a node exact-size and one-byte-over
// frames through the broker or router, and reports what came back. It speaks the
// carrier's own protocol (MQTT 3.1.1, or Zenoh through a small zenoh-c helper)
// directly, because the runtime API a host peer uses never emits a frame it does
// not consider legal.
//
// The probe knows the node's route grammar and the sensor type name, and nothing
// else about the node. Bounds come from the caller, which reads them from the
// application's manifest.
import net from "node:net";
import { spawn } from "node:child_process";
import readline from "node:readline";

const SENSOR_TYPE = "axoloty.sensor.Node";
const NAMESPACE = "axoloty-embedded";
const PROBE_SOURCE = "32400000-0000-4000-8000-0000000000f6";

/** The route prefix and the Discover payload encoding of a wire profile. */
export function wireProfile(name) {
  if (name === "mqtt") return { prefix: "coaty/3", resolveFilter: `coaty/3/${NAMESPACE}/RSV/#`, encoding: "json" };
  if (name === "zenoh") return { prefix: "axoloty/1", resolveFilter: `axoloty/1/${NAMESPACE}/RSV/**`, encoding: "cbor" };
  throw new Error(`unknown wire profile ${name}`);
}

/** A Discover for the sensor type, padded with a second type name to exactly `size` bytes. */
export function discoverPayload(encoding, size) {
  if (encoding === "json") {
    const head = `{"objectTypes":["${SENSOR_TYPE}","`;
    const tail = `"]}`;
    const pad = size - head.length - tail.length;
    if (pad < 0) throw new Error(`a JSON Discover needs at least ${head.length + tail.length} bytes`);
    return Buffer.from(head + "x".repeat(pad) + tail);
  }
  // map(1) { "objectTypes": array(2) [ text(19) type, text(n) padding ] }
  const key = Buffer.from("objectTypes");
  const type = Buffer.from(SENSOR_TYPE);
  const fixed = 1 + 1 + key.length + 1 + 1 + type.length + 3;
  const pad = size - fixed;
  if (pad < 256) throw new Error(`a CBOR Discover padded with a 16-bit string needs at least ${fixed + 256} bytes`);
  return Buffer.concat([
    Buffer.from([0xa1, 0x60 + key.length]), key, Buffer.from([0x82, 0x60 + type.length]), type,
    Buffer.from([0x79, pad >> 8, pad & 0xff]), Buffer.alloc(pad, 0x78),
  ]);
}

/** A Discover that is a sensible request but short, for responsiveness checks. */
export function shortDiscover(encoding) {
  if (encoding === "json") return Buffer.from(`{"objectTypes":["${SENSOR_TYPE}"]}`);
  const type = Buffer.from(SENSOR_TYPE);
  const key = Buffer.from("objectTypes");
  return Buffer.concat([Buffer.from([0xa1, 0x60 + key.length]), key, Buffer.from([0x81, 0x60 + type.length]), type]);
}

function uuid(counter) {
  return `32400000-0000-4000-8000-${counter.toString(16).padStart(12, "0")}`;
}

/** Remaining-length encoding of MQTT. */
function remainingLength(length) {
  const bytes = [];
  do {
    let digit = length % 128;
    length = Math.floor(length / 128);
    if (length > 0) digit |= 0x80;
    bytes.push(digit);
  } while (length > 0);
  return Buffer.from(bytes);
}

function mqttString(text) {
  const bytes = Buffer.from(text);
  const length = Buffer.alloc(2);
  length.writeUInt16BE(bytes.length);
  return Buffer.concat([length, bytes]);
}

/** A bare MQTT 3.1.1 client: connect, subscribe at QoS 0, publish at QoS 0, receive. */
export async function openMqttBus({ host, port, filter, onMessage }) {
  const socket = net.connect({ host, port: Number(port) });
  socket.setNoDelay(true);
  let buffer = Buffer.alloc(0);
  let connected;
  const connack = new Promise(resolve => { connected = resolve; });
  socket.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      let multiplier = 1, value = 0, index = 1, digit;
      do {
        if (index >= buffer.length) return;
        digit = buffer[index++];
        value += (digit & 0x7f) * multiplier;
        multiplier *= 128;
      } while (digit & 0x80);
      if (buffer.length < index + value) return;
      const type = buffer[0] >> 4;
      const body = buffer.subarray(index, index + value);
      buffer = buffer.subarray(index + value);
      if (type === 2) connected();
      if (type === 3) {
        const topicLength = body.readUInt16BE(0);
        onMessage(body.subarray(2, 2 + topicLength).toString(), body.subarray(2 + topicLength));
      }
    }
  });
  const failure = new Promise((_, reject) => socket.on("error", reject));
  const clientId = `f6-probe-${process.pid}`;
  const connect = Buffer.concat([mqttString("MQTT"), Buffer.from([4, 2, 0, 60]), mqttString(clientId)]);
  socket.write(Buffer.concat([Buffer.from([0x10]), remainingLength(connect.length), connect]));
  await Promise.race([connack, failure]);
  const subscribe = Buffer.concat([Buffer.from([0, 1]), mqttString(filter), Buffer.from([0])]);
  socket.write(Buffer.concat([Buffer.from([0x82]), remainingLength(subscribe.length), subscribe]));
  await new Promise(resolve => setTimeout(resolve, 500));
  return {
    publish(topic, payload) {
      const body = Buffer.concat([mqttString(topic), payload]);
      socket.write(Buffer.concat([Buffer.from([0x30]), remainingLength(body.length), body]));
    },
    close() { socket.destroy(); },
  };
}

/**
 * Judges the encoding labels of the samples the device published. Core labels
 * every sample `application/cbor` and its binding accepts an unlabeled one, so no
 * exchange fails on a missing label; this does (#128). Returns the problems found:
 * none observed, or a sample with another label.
 */
export function judgeSampleEncodings(messages, expected = "application/cbor") {
  const problems = [];
  if (messages.length === 0) problems.push("no device sample was observed, so its encoding label was not checked");
  const wrong = messages.filter(message => message.encoding !== expected);
  if (wrong.length > 0) {
    const labels = [...new Set(wrong.map(message => message.encoding ?? "none"))].join(", ");
    problems.push(`${wrong.length} of ${messages.length} device samples carry the encoding ${labels}, expected ${expected}`);
  }
  return problems;
}

/** A Zenoh client through the zenoh-c helper `zenoh-frame-io`. */
export async function openZenohBus({ helper, endpoint, filter, onMessage }) {
  const child = spawn(helper, [endpoint, filter], { stdio: ["pipe", "pipe", "inherit"] });
  const lines = readline.createInterface({ input: child.stdout });
  let ready;
  const started = new Promise((resolve, reject) => { ready = resolve; child.once("exit", code => reject(new Error(`helper exited ${code}`))); });
  lines.on("line", line => {
    if (line === "ready") ready();
    const match = /^rx (\S+) (\S+) ([0-9a-f]*)$/.exec(line);
    if (match) onMessage(match[1], Buffer.from(match[3], "hex"), match[2]);
  });
  await started;
  await new Promise(resolve => setTimeout(resolve, 500));
  return {
    publish(topic, payload) { child.stdin.write(`put ${topic} ${payload.toString("hex")}\n`); },
    close() { child.stdin.write("quit\n"); child.kill("SIGTERM"); },
  };
}

/**
 * Runs the probe sequence and returns one result per step.
 *
 * Steps, with T and P the topic and payload bounds:
 * 1. a Discover with a P-byte payload, which the node must answer;
 * 2. a T-byte topic with a P-byte payload that is no request, which the node
 *    receives and rejects;
 * 3. a Discover with a P+1-byte payload, which the node must not answer;
 * 4. a Discover on a T+1-byte topic, which the node must not answer;
 * each of 3 and 4 followed by a short Discover until the node answers again.
 */
export async function runFrameProbe({ wire, bounds, bus, messages, log }) {
  const { prefix, encoding } = wireProfile(wire);
  const route = suffix => `${prefix}/${NAMESPACE}/DSC/${PROBE_SOURCE}/${suffix}`;
  const base = route("").length;
  let counter = 0x100;
  const results = [];

  const resolved = correlation => messages.some(message => message.topic.includes("/RSV/") && message.topic.endsWith(`/${correlation}`));
  const waitFor = async (condition, milliseconds) => {
    const limit = Date.now() + milliseconds;
    while (Date.now() < limit) {
      if (condition()) return true;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    return condition();
  };
  const send = (topic, payload) => {
    log(`send topic ${Buffer.byteLength(topic)} bytes, payload ${payload.length} bytes`);
    bus.publish(topic, payload);
  };
  /** Sends short Discovers until the node answers one, to show the loop still runs. */
  const answersAgain = async () => {
    const limit = Date.now() + 90_000;
    while (Date.now() < limit) {
      const correlation = uuid(counter++);
      send(route(correlation), shortDiscover(encoding));
      if (await waitFor(() => resolved(correlation), 3_000)) return true;
    }
    return false;
  };

  // 1. The largest legal Discover.
  {
    const correlation = uuid(counter++);
    const topic = route(correlation);
    const payload = discoverPayload(encoding, bounds.payload);
    send(topic, payload);
    const answered = await waitFor(() => resolved(correlation), 20_000);
    const answer = messages.find(message => message.topic.endsWith(`/${correlation}`));
    results.push({ step: "maxPayloadDiscover", topicBytes: Buffer.byteLength(topic), payloadBytes: payload.length,
      answered, resolveBytes: answer?.payload.length ?? null });
  }
  // 2. A topic of exactly the topic bound, carrying a full-size payload.
  {
    const junk = "e".repeat(bounds.topic - base);
    const topic = route(junk);
    if (Buffer.byteLength(topic) !== bounds.topic) throw new Error(`probe topic is ${Buffer.byteLength(topic)} bytes, not ${bounds.topic}`);
    const payload = Buffer.alloc(bounds.payload, 0x78);
    send(topic, payload);
    await new Promise(resolve => setTimeout(resolve, 3_000));
    results.push({ step: "maxTopicFrame", topicBytes: Buffer.byteLength(topic), payloadBytes: payload.length });
  }
  // 3. One byte over the payload bound.
  {
    const correlation = uuid(counter++);
    const topic = route(correlation);
    const payload = discoverPayload(encoding, bounds.payload + 1);
    send(topic, payload);
    const answered = await waitFor(() => resolved(correlation), 6_000);
    const responsive = await answersAgain();
    results.push({ step: "payloadOneOver", topicBytes: Buffer.byteLength(topic), payloadBytes: payload.length, answered, responsive });
  }
  // 4. One byte over the topic bound.
  {
    const junk = "e".repeat(bounds.topic + 1 - base);
    const topic = route(junk);
    if (Buffer.byteLength(topic) !== bounds.topic + 1) throw new Error("probe topic is not one byte over the bound");
    const payload = shortDiscover(encoding);
    send(topic, payload);
    await new Promise(resolve => setTimeout(resolve, 6_000));
    const responsive = await answersAgain();
    results.push({ step: "topicOneOver", topicBytes: Buffer.byteLength(topic), payloadBytes: payload.length, responsive });
  }
  return results;
}
