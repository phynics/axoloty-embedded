// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Reads a `zenohd` log kept for a device run and decides whether the router saw
// the device lose its session and get it back. The device cannot prove that
// itself: on Zenoh `wait_for_reconnect` is a connectivity wait and succeeds on a
// session that never failed. The router is the only party that sees a session
// end, so its log is the evidence. It must be started with debug logging for
// `zenoh_transport` and `zenoh_link_tcp`.

// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;]*m/g;
const ACCEPT = /^(\S+)Z\s+\w+\s+\S+\s+ThreadId\(\d+\)\s+\S*:\s+Accepted TCP connection on \S+: (\S+)$/;
const OPEN = /^(\S+)Z\s+\w+\s+\S+\s+ThreadId\(\d+\)\s+\S*:\s+New transport opened between \S+ and (\S+) - whatami: client/;
const READ_ERROR = /^(\S+)Z\s+\w+\s+\S+\s+ThreadId\(\d+\)\s+\S*:\s+RX task failed: Read error on TCP link \S+ => (\S+): (.*)$/;
const EXPIRED = /^(\S+)Z\s+\w+\s+\S+\s+ThreadId\(\d+\)\s+\S*:\s+RX task failed: tcp\/\S+ => tcp\/([^:]+:\d+):.*expired after (\d+) milliseconds/;
const START = /^(\S+)Z\s+\w+\s+\S+\s+ThreadId\(\d+\)\s+zenohd:\s+zenohd v(\d+\.\d+\.\d+)/;

/** Seconds since midnight UTC for an ISO timestamp such as `2026-10-31T10:57:43.094225`. */
export function secondsOfDay(iso) {
  const match = /T(\d\d):(\d\d):(\d\d(?:\.\d+)?)$/.exec(iso);
  if (!match) throw new Error(`not an ISO timestamp: ${iso}`);
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

/** Parses a router log into client sessions, in the order the router accepted them. */
export function parseRouterLog(text) {
  const sessions = [];
  const byPeer = new Map();
  let version = null;
  const routerStarts = [];
  let lastAccepted = null;
  for (const raw of text.replace(ANSI, "").split("\n")) {
    const line = raw.trim();
    const start = START.exec(line);
    if (start) {
      routerStarts.push(secondsOfDay(start[1]));
      if (version === null) version = start[2];
      continue;
    }
    let match = ACCEPT.exec(line);
    if (match) {
      const session = { peer: match[2], process: routerStarts.length - 1, acceptedAt: secondsOfDay(match[1]), zid: null, openedAt: null, endedAt: null, endReason: null };
      sessions.push(session);
      byPeer.set(session.peer, session);
      lastAccepted = session;
      continue;
    }
    match = OPEN.exec(line);
    if (match) {
      // The accept thread opens one transport at a time, so the open that
      // follows an accept belongs to it.
      if (lastAccepted && lastAccepted.zid === null) {
        lastAccepted.zid = match[2];
        lastAccepted.openedAt = secondsOfDay(match[1]);
      }
      continue;
    }
    match = EXPIRED.exec(line);
    if (match) {
      const session = byPeer.get(match[2]);
      if (session && session.endedAt === null) {
        session.endedAt = secondsOfDay(match[1]);
        session.endReason = "expired";
      }
      continue;
    }
    match = READ_ERROR.exec(line);
    if (match) {
      const session = byPeer.get(match[2]);
      if (session && session.endedAt === null) {
        session.endedAt = secondsOfDay(match[1]);
        session.endReason = /reset by peer/i.test(match[3]) ? "reset" : /early eof/i.test(match[3]) ? "eof" : "error";
      }
    }
  }
  return { version, routerStarts, sessions };
}

/**
 * Decides whether the device lost its session and recovered during a window.
 *
 * `device` is the device's IP address. The window runs in seconds since
 * midnight UTC, from the device's first connect to the end of the host
 * exchange. A pass needs all of: a session of this device ending inside the
 * window by reset or EOF (the loss), a session with the same client ID opening
 * within `maxReturnSeconds` of it (the recovery), no lease expiry after the
 * first loss and before the window ends, and a session still open when the
 * window ends.
 */
export function analyzeRecovery(parsed, { device, windowStart, windowEnd, maxReturnSeconds = 15 }) {
  const reasons = [];
  const mine = parsed.sessions.filter(session =>
    session.openedAt !== null && session.peer.split(":")[0] === device &&
    session.openedAt <= windowEnd && (session.endedAt === null || session.endedAt >= windowStart));
  const losses = mine.filter(session =>
    (session.endReason === "reset" || session.endReason === "eof") &&
    session.endedAt >= windowStart && session.endedAt <= windowEnd);
  const returnSeconds = [];
  if (mine.length === 0) reasons.push("the router saw no session from the device in the window");
  if (losses.length === 0) reasons.push("the router saw no session end by reset or EOF, so no loss was observed");
  for (const loss of losses) {
    const next = mine.find(session => session.zid === loss.zid && session.openedAt >= loss.endedAt);
    if (!next) {
      reasons.push(`no session with client ${loss.zid.slice(0, 8)} returned after the loss at ${loss.endedAt.toFixed(1)}`);
    } else {
      const seconds = next.openedAt - loss.endedAt;
      returnSeconds.push(Number(seconds.toFixed(1)));
      if (seconds > maxReturnSeconds) reasons.push(`the client returned after ${seconds.toFixed(1)} s, over the ${maxReturnSeconds} s bound`);
    }
  }
  const firstLoss = losses.length > 0 ? Math.min(...losses.map(loss => loss.endedAt)) : null;
  const expiries = mine.filter(session =>
    session.endReason === "expired" && firstLoss !== null && session.endedAt >= firstLoss && session.endedAt <= windowEnd);
  if (expiries.length > 0) reasons.push(`${expiries.length} session(s) expired by lease after the loss`);
  const open = mine.filter(session => session.endedAt === null || session.endedAt > windowEnd);
  if (open.length === 0) reasons.push("no device session was open at the end of the window");
  return {
    passed: reasons.length === 0,
    reasons,
    routerVersion: parsed.version,
    losses: losses.length,
    returnSeconds,
    leaseExpiries: expiries.length,
    sessionsSeen: mine.length,
  };
}

/**
 * Decides whether the device got its session back after the router process was
 * restarted. The log holds more than one router process: the first one's last
 * session of this device must have ended with the process, and a session with
 * the same client ID must open on a later process within `maxReturnSeconds`
 * of that process starting. A lease expiry on the later process, or no session
 * open at the end of the window, fails the check.
 */
export function analyzeRouterRestart(parsed, { device, windowStart, windowEnd, maxReturnSeconds = 30 }) {
  const reasons = [];
  const restartAt = parsed.routerStarts.find(time => time > windowStart && time <= windowEnd);
  if (restartAt === undefined) {
    reasons.push("the log shows no router restart in the window");
    return { passed: false, reasons, routerVersion: parsed.version, restarts: 0, returnSeconds: [], leaseExpiries: 0 };
  }
  const mine = parsed.sessions.filter(session => session.openedAt !== null && session.peer.split(":")[0] === device);
  const before = mine.filter(session => session.openedAt < restartAt && session.endReason !== "expired");
  const last = before[before.length - 1];
  if (!last) reasons.push("the device had no session on the first router process");
  const returnSeconds = [];
  if (last) {
    const after = mine.find(session => session.openedAt >= restartAt && session.zid === last.zid);
    if (!after) {
      reasons.push(`no session with client ${last.zid.slice(0, 8)} opened on the restarted router`);
    } else {
      const seconds = after.openedAt - restartAt;
      returnSeconds.push(Number(seconds.toFixed(1)));
      if (seconds > maxReturnSeconds) reasons.push(`the client returned ${seconds.toFixed(1)} s after the restart, over the ${maxReturnSeconds} s bound`);
    }
  }
  const expiries = mine.filter(session =>
    session.openedAt >= restartAt && session.endReason === "expired" && session.endedAt <= windowEnd);
  if (expiries.length > 0) reasons.push(`${expiries.length} session(s) expired by lease after the restart`);
  const open = mine.filter(session =>
    session.openedAt >= restartAt && session.openedAt <= windowEnd && (session.endedAt === null || session.endedAt > windowEnd));
  if (open.length === 0) reasons.push("no device session was open on the restarted router at the end of the window");
  return {
    passed: reasons.length === 0,
    reasons,
    routerVersion: parsed.version,
    restarts: parsed.routerStarts.filter(time => time > windowStart && time <= windowEnd).length,
    returnSeconds,
    leaseExpiries: expiries.length,
  };
}
