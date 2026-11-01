// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Carrier mechanics for the embedded Zenoh transport, over Core's session
// facade.
//
// This file owns the bounded, synchronous client the device side of the
// transport exposes through the neutral carrier operations the application
// receives: last-will configuration, connect, subscribe, unsubscribe,
// publish, polled receive, reconnect observation, and disconnect. Key and
// payload bytes are borrowed from caller storage, consumed synchronously,
// and never retained. Receive is polled, never pushed: sessions and their
// bounded queues belong to the facade, and this value keeps only opaque
// subscription tokens plus one reusable frame store.
//
// The session itself is Core's `ZenohSession` over the Core-owned facade ABI
// that `zenoh_pico_facade.c` implements on the device. This file adds the
// carrier lifecycle this transport needs around it: one session, up to eight
// concurrent subscriptions in fixed storage, a round-robin poll with a
// retained pending frame so a frame is never lost when caller storage is
// small, and deterministic teardown that never reopens a session behind the
// caller.
//
// Bounds mirror the sibling transport and `AxolotyWire`: a key of at most
// 256 bytes and a payload of at most 2_048 bytes. A zero-length payload is
// legal; a null pointer with a non-zero length is rejected before use.

import AxolotyWire
import AxolotyZenohCore
#if EMBEDDED_ZENOH_HOST_TEST
import ZenohHostTest
#endif

/// Converts one bounded millisecond wait to scheduler ticks without allowing
/// a non-zero wait to turn into a zero-tick busy spin. Rounding up can extend
/// one individual sleep by less than a scheduler tick; the next deadline check
/// always uses the monotonic clock rather than accumulated requested sleeps.
@inline(__always)
func zenohPollingWaitTicks(milliseconds: UInt32, schedulerHz: UInt32) -> UInt32 {
    guard milliseconds > 0, schedulerHz > 0 else { return 0 }
    let product = UInt64(milliseconds) * UInt64(schedulerHz)
    let quotient = product / 1_000
    let rounded = quotient + (product % 1_000 == 0 ? 0 : 1)
    return UInt32(min(max(rounded, 1), UInt64(UInt32.max)))
}

@inline(__always)
private func zenohWaitTicks(milliseconds: UInt32) -> UInt32 {
#if EMBEDDED_ZENOH_HOST_TEST
    zenohPollingWaitTicks(milliseconds: milliseconds,
                          schedulerHz: host_zenoh_scheduler_hz())
#else
    zenohPollingWaitTicks(milliseconds: milliseconds,
                          schedulerHz: axoloty_scheduler_hz())
#endif
}

/// Fixed slots for one carrier session's subscriptions.
///
/// The facade allows up to eight concurrent subscriptions per session. The
/// table below keeps one entry per slot in fixed storage: whether it is in
/// use, the subscribed key bytes for topic-addressed removal, and the opaque
/// facade token. No allocation, no retention of caller pointers.
private struct ZenohCarrierSlot {
    var active = false
    var keyLength = 0
    var key = InlineArray<256, UInt8>(repeating: 0)
    var subscription: ZenohSubscription?
}

/// The richer internal poll result keeps ABI buffer pressure separate from
/// transport errors while the legacy application seam remains Int32-based.
fileprivate enum ZenohCarrierPollOutcome {
    case frame
    case noEvent
    case closed
    case insufficientCapacity
    case failed
}

/// Records one publish outcome in the transport-neutral carrier counters.
///
/// `Core` owns what each `ZenohResult` means; this maps that already-decided
/// verdict onto the counter whose name describes it, and does nothing else.
/// The transport's counters module stays free of result codes for exactly this
/// reason, so a new facade code needs a case here and nowhere else.
@inline(__always)
private func notePublishOutcome(_ result: ZenohResult) {
    _ = carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_ATTEMPTS, 1)
    if result != .success {
        _ = carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_FAILURES, 1)
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
    }
}

/// Records one publish the carrier refused before it reached the transport.
///
/// This is deliberately not a fabricated `ZenohResult`. The carrier rejected
/// the call on its own lifecycle or bounds, so no facade result exists to
/// report, and inventing one would put a value into the counters that Core
/// never produced. It counts as a publish attempt and a publish failure, which
/// is what a caller watching these numbers actually needs to know.
@inline(__always)
private func notePublishRefusedLocally() {
    _ = carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_ATTEMPTS, 1)
    _ = carrier_diagnostics_add(CARRIER_METRIC_PUBLISH_FAILURES, 1)
}

/// Counts facade notifications. Drop and oversize reports can each coalesce
/// several rejected frames; they are observations, not exact frame-loss totals.
@inline(__always)
private func notePollOutcome(_ result: ZenohResult) {
    switch result {
    case .queueFull:
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_DROPPED, 1)
    case .frameTooLarge:
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_OVERSIZED, 1)
    case .success, .queueEmpty:
        break
    case .notOpen:
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
    default:
        _ = carrier_diagnostics_add(CARRIER_METRIC_POLL_ERRORS, 1)
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
    }
}

/// Records a session lifecycle outcome.
@inline(__always)
private func noteSessionOpen(_ result: ZenohResult) {
    if result == .success {
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_OPENS, 1)
    } else {
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
    }
}

@inline(__always)
private func noteSessionClose(_ result: ZenohResult) {
    if result == .success {
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_CLOSES, 1)
    } else {
        _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
    }
}

/// Records one failure of a subscription operation.
@inline(__always)
private func noteSubscriptionFailure() {
    _ = carrier_diagnostics_add(CARRIER_METRIC_SESSION_FAILURES, 1)
}

/// Bounded, synchronous Zenoh carrier for the single-session device gate.
///
/// Every byte buffer passed here is consumed synchronously and is never
/// retained. Lifecycle calls must be serialized; the facade registry carries
/// no locks and this value keeps none.
///
/// Carrier outcomes update the fixed C counter set. Readers can take atomic
/// per-field snapshots without changing this value's lifecycle ownership.
/// Key-expression grammar the router enforces.
///
/// A router that is asked to declare a key it cannot parse does not refuse the
/// declaration: `zenohd` 1.10.0 panics and exits, taking every other session
/// with it. The carrier therefore rejects such a key before it leaves the
/// device. The rules follow the key-expression grammar:
/// - no empty chunk, and no leading or trailing separator;
/// - `#` and `?` are forbidden everywhere;
/// - `*` and `**` are wildcards only as a whole chunk, and `$*` is the only
///   in-chunk wildcard; a `$` must be followed by `*`, and `$*` may not repeat
///   back to back.
/// A published key additionally carries no wildcard at all.
enum ZenohKeyExpression {
    /// Whether `key` can be declared as a subscription.
    static func isValidSubscription(_ key: UnsafeRawBufferPointer) -> Bool {
        isValid(key, allowWildcards: true)
    }

    /// Whether `key` can be published to: valid, and wildcard free.
    static func isValidPublication(_ key: UnsafeRawBufferPointer) -> Bool {
        isValid(key, allowWildcards: false)
    }

    private static func isValid(_ key: UnsafeRawBufferPointer, allowWildcards: Bool) -> Bool {
        let count = key.count
        guard count > 0 else { return false }
        var chunkStart = 0
        var index = 0
        while index <= count {
            // The end of the key closes the last chunk like a separator does.
            if index == count || key[index] == 0x2F {
                let length = index - chunkStart
                guard length > 0,
                      chunkIsValid(key, start: chunkStart, length: length, allowWildcards: allowWildcards)
                else { return false }
                chunkStart = index + 1
            }
            index += 1
        }
        return true
    }

    private static func chunkIsValid(
        _ key: UnsafeRawBufferPointer, start: Int, length: Int, allowWildcards: Bool
    ) -> Bool {
        if length == 1 && key[start] == 0x2A { return allowWildcards }
        if length == 2 && key[start] == 0x2A && key[start + 1] == 0x2A { return allowWildcards }
        var index = 0
        var previousWasPair = false
        while index < length {
            switch key[start + index] {
            case 0x23, 0x3F, 0x2A:
                // `#`, `?`, and a `*` that is not the whole chunk or part of `$*`.
                return false
            case 0x24:
                guard allowWildcards, index + 1 < length, key[start + index + 1] == 0x2A,
                      !previousWasPair else { return false }
                previousWasPair = true
                index += 2
                continue
            default:
                previousWasPair = false
            }
            index += 1
        }
        return true
    }
}

struct ZenohCarrier: ~Copyable {
    /// The facade's fixed per-session subscription capacity.
    static let maximumSubscriptions = 8
    /// Milliseconds between router observations while waiting.
    static let reconnectPollIntervalMS: UInt32 = 20

    /// Clears every carrier counter. Call before starting traffic.
    static func resetDiagnostics() {
        carrier_diagnostics_reset()
    }

    /// The live transport-neutral counters.
    static var diagnostics: CarrierDiagnostics {
        carrier_diagnostics_get()
    }

    /// The subscription gauge: how many declarations the carrier holds now.
    static var activeSubscriptions: UInt32 {
        carrier_diagnostics_get().active_subscriptions
    }

    /// Most declarations held at once since reset. Survives teardown.
    static var activeSubscriptionsPeak: UInt32 {
        carrier_diagnostics_get().active_subscriptions_peak
    }

    /// Serializes the live counters as one bounded JSON object into caller
    /// storage. Returns the byte count, or 0 when the buffer is too small.
    /// A 0 result means "the report did not fit", never "zero counts".
    static func writeDiagnosticsJSON(
        into buffer: UnsafeMutablePointer<CChar>, capacity: Int
    ) -> Int {
        guard capacity > 0 else { return 0 }
        return carrier_diagnostics_write_json(buffer, capacity)
    }

    /// The buffer size `writeDiagnosticsJSON` always needs.
    static var diagnosticsJSONCapacity: Int {
        carrier_diagnostics_json_capacity()
    }

    private enum Phase {
        case idle
        case connected
        case subscribed
        case disconnected
    }

    private var phase = Phase.idle
    private var session = ZenohSession()
    private var connectedRouterObserved = false
    private var routerLossObserved = false
    private var frames = ZenohFrameStorage()
    private var hasPendingFrame = false
    private var pollCursor = 0
    /// The time of the last keep-alive this carrier sent while polling.
    private var lastKeepAliveMS: UInt64 = 0
    private var slot0 = ZenohCarrierSlot()
    private var slot1 = ZenohCarrierSlot()
    private var slot2 = ZenohCarrierSlot()
    private var slot3 = ZenohCarrierSlot()
    private var slot4 = ZenohCarrierSlot()
    private var slot5 = ZenohCarrierSlot()
    private var slot6 = ZenohCarrierSlot()
    private var slot7 = ZenohCarrierSlot()

    init() {}

    private func slotAt(_ index: Int) -> ZenohCarrierSlot {
        switch index {
        case 0: return slot0
        case 1: return slot1
        case 2: return slot2
        case 3: return slot3
        case 4: return slot4
        case 5: return slot5
        case 6: return slot6
        case 7: return slot7
        default: return ZenohCarrierSlot()
        }
    }

    private mutating func setSlotAt(_ index: Int, _ slot: ZenohCarrierSlot) {
        switch index {
        case 0: slot0 = slot
        case 1: slot1 = slot
        case 2: slot2 = slot
        case 3: slot3 = slot
        case 4: slot4 = slot
        case 5: slot5 = slot
        case 6: slot6 = slot
        case 7: slot7 = slot
        default: break
        }
    }

    /// Finds the slot holding an exact key match, if any.
    private func findSlot(keyBytes: UnsafeRawPointer, keyLength: Int) -> Int? {
        for index in 0..<Self.maximumSubscriptions {
            let slot = slotAt(index)
            guard slot.active, slot.keyLength == keyLength else { continue }
            var matches = true
            for offset in 0..<keyLength where slot.key[offset] != keyBytes.load(fromByteOffset: offset, as: UInt8.self) {
                matches = false
                break
            }
            if matches { return index }
        }
        return nil
    }

    private func findFreeSlot() -> Int? {
        for index in 0..<Self.maximumSubscriptions where !slotAt(index).active {
            return index
        }
        return nil
    }

    private func activeSlotCount() -> Int {
        var count = 0
        for index in 0..<Self.maximumSubscriptions where slotAt(index).active {
            count += 1
        }
        return count
    }

    /// Updates the live slot count and its high-water mark.
    private func publishSubscriptionGauge() {
        carrier_diagnostics_set_active_subscriptions(UInt32(activeSlotCount()))
    }

    /// The v1 client profile has no broker last-will, and the host binding
    /// ignores the value for the same reason. Never report success for an
    /// operation the carrier cannot perform.
    func configureLastWill(topic: Span<UInt8>, payload: Span<UInt8>) -> Bool {
        _ = topic
        _ = payload
        return false
    }

    /// Opens one session against the operator-configured router endpoint.
    ///
    /// The endpoint arrives through the transport-owned C helper that reads
    /// the private network configuration; it is borrowed for this call only.
    /// One open attempt is made. The facade bounds it with its acceptance
    /// check, so the deadline is accepted for interface symmetry and the
    /// attempt itself stays bounded by the contract.
    mutating func connect(deadlineMS: UInt32) -> Bool {
        _ = deadlineMS
        // A closed carrier may open a new session: a node that lost its router
        // reconnects without a restart. The close released every declaration.
        guard phase == .idle || phase == .disconnected else { return false }
        var opened = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 513) { buffer in
            guard let base = buffer.baseAddress else { return }
            let endpointLength = axoloty_zenoh_copy_endpoint(base, Int32(buffer.count))
            guard endpointLength > 0 else { return }
            let endpoint = ByteSlice(bytes: base, length: Int(endpointLength))
            let configuration = ZenohConfiguration(
                mode: .client,
                connectEndpoint: endpoint,
                multicastScoutingEnabled: false
            )
            let result = session.open(configuration: configuration)
            opened = result == .success
            noteSessionOpen(result)
        }
        guard opened else {
            // A refused open is a session failure the caller can see and act
            // on, not a silent retry: the carrier stays idle so a retry is
            // safe, and the counter shows it did not succeed the first time.
            return false
        }
        switch session.connectedRouterCount() {
        case .count(let count):
            connectedRouterObserved = count > 0
        case .failure:
            connectedRouterObserved = false
        }
        phase = .connected
        publishSubscriptionGauge()
        return true
    }

    /// Declares one bounded subscription, idempotently.
    ///
    /// Declaring is synchronous, so the deadline is accepted for interface
    /// symmetry and no wait is needed. Subscribing an already-subscribed key
    /// succeeds without declaring twice.
    mutating func subscribe(topic: Span<UInt8>, deadlineMS: UInt32) -> Bool {
        _ = deadlineMS
        guard phase == .connected || phase == .subscribed,
              !topic.isEmpty, topic.count <= ZenohFrameStorage.keyCapacity else {
            noteSubscriptionFailure()
            return false
        }
        let subscribed = topic.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard ZenohKeyExpression.isValidSubscription(raw) else {
                noteSubscriptionFailure()
                return false
            }
            if findSlot(keyBytes: base, keyLength: topic.count) != nil { return true }
            guard let free = findFreeSlot() else {
                noteSubscriptionFailure()
                return false
            }
            let key = ByteSlice(bytes: base.assumingMemoryBound(to: UInt8.self), length: topic.count)
            switch session.subscribe(key: key) {
            case .subscribed(let handle):
                var slot = ZenohCarrierSlot()
                slot.active = true
                slot.keyLength = topic.count
                for offset in 0..<topic.count {
                    slot.key[offset] = base.load(fromByteOffset: offset, as: UInt8.self)
                }
                slot.subscription = handle
                setSlotAt(free, slot)
                phase = .subscribed
                publishSubscriptionGauge()
                return true
            case .result:
                noteSubscriptionFailure()
                return false
            }
        }
        return subscribed
    }

    /// Removes exactly one topic subscription.
    ///
    /// An unknown topic removes nothing and reports failure. A failed removal
    /// keeps its slot so the declaration can be retried or torn down with
    /// the session; the session close releases every declaration regardless.
    mutating func unsubscribe(topic: Span<UInt8>, deadlineMS: UInt32) -> Bool {
        _ = deadlineMS
        guard phase == .subscribed,
              !topic.isEmpty, topic.count <= ZenohFrameStorage.keyCapacity else {
            noteSubscriptionFailure()
            return false
        }
        let removed = topic.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let index = findSlot(keyBytes: base, keyLength: topic.count) else {
                noteSubscriptionFailure()
                return false
            }
            var slot = slotAt(index)
            guard let handle = slot.subscription,
                  session.unsubscribe(handle) == .success else {
                noteSubscriptionFailure()
                return false
            }
            slot = ZenohCarrierSlot()
            setSlotAt(index, slot)
            publishSubscriptionGauge()
            return true
        }
        return removed
    }

    /// Publishes one bounded key and payload.
    ///
    /// The facade copies both synchronously, so the spans do not outlive this
    /// call. A subscription must be active, matching the sibling transport's
    /// lifecycle discipline: no publication before profile interest is
    /// installed.
    func publish(topic: Span<UInt8>, payload: Span<UInt8>) -> Bool {
        guard phase == .subscribed,
              !topic.isEmpty, topic.count <= ZenohFrameStorage.keyCapacity,
              payload.count <= ZenohFrameStorage.payloadCapacity else {
            notePublishRefusedLocally()
            return false
        }
        return topic.withUnsafeBytes { topicRaw in
            guard let topicBase = topicRaw.baseAddress else {
                notePublishRefusedLocally()
                return false
            }
            guard ZenohKeyExpression.isValidPublication(topicRaw) else {
                notePublishRefusedLocally()
                return false
            }
            let key = ByteSlice(bytes: topicBase.assumingMemoryBound(to: UInt8.self), length: topic.count)
            if payload.isEmpty {
                let result = session.publish(key: key, payload: .empty)
                notePublishOutcome(result)
                return result == .success
            }
            return payload.withUnsafeBytes { payloadRaw in
                guard let payloadBase = payloadRaw.baseAddress else {
                    notePublishRefusedLocally()
                    return false
                }
                let value = ByteSlice(bytes: payloadBase.assumingMemoryBound(to: UInt8.self), length: payload.count)
                let result = session.publish(key: key, payload: value)
                notePublishOutcome(result)
                return result == .success
            }
        }
    }

    /// Copies one complete queued frame into caller-owned fixed storage.
    ///
    /// Returns 1 for a frame, 0 when every queue is empty, -1 for an error
    /// or a drop notification, and -2 when the session is closed. A frame
    /// that does not fit caller storage is retained as pending and reported
    /// as -1, so it is never lost; the next call serves it first.
    /// Subscriptions are drained round-robin starting after the last one
    /// that produced a frame.
    mutating func pollOneEvent(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        switch pollOneEventOutcome(
            topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
            payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
        ) {
        case .frame: return 1
        case .noEvent: return 0
        case .closed: return -2
        case .insufficientCapacity, .failed: return -1
        }
    }

    /// How long the carrier lets a polled session stay silent before it sends a
    /// keep-alive itself, in milliseconds.
    ///
    /// The router closes a session that sends nothing for its 10 s lease.
    /// zenoh-pico's keep-alive task is meant to send every third of the lease,
    /// but on a session it reopened after a Wi-Fi loss, an idle device sent
    /// nothing for a full lease and the router closed the session (phynics/
    /// axoloty-embedded#56). Three seconds is that third.
    static let keepAliveIntervalMS: UInt64 = 3_000

    /// Sends a keep-alive when the session has been silent for
    /// ``keepAliveIntervalMS``. Counting routers sends one before it reports
    /// (see `axoloty_zenoh_connected_router_count`), so this reuses the public
    /// facade call and adds nothing to the Core-owned contract.
    private mutating func keepSessionAlive() {
        let nowMS = UInt64(max(0, esp_timer_get_time() / 1_000))
        guard nowMS &- lastKeepAliveMS >= Self.keepAliveIntervalMS else { return }
        lastKeepAliveMS = nowMS
        _ = session.connectedRouterCount()
    }

    /// Polls once and retains the legacy seam's copy-on-read behavior.
    fileprivate mutating func pollOneEventOutcome(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> ZenohCarrierPollOutcome {
        guard topicCapacity > 0, topicCapacity <= Int32(ZenohFrameStorage.keyCapacity),
              payloadCapacity >= 0, payloadCapacity <= Int32(ZenohFrameStorage.payloadCapacity) else { return .failed }
        if phase == .disconnected { return .closed }
        guard phase == .subscribed else { return .failed }
        if hasPendingFrame {
            return copyPendingFrame(
                topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
                payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
            )
        }
        let active = activeSlotCount()
        guard active > 0 else { return .noEvent }
        keepSessionAlive()
        for _ in 0..<Self.maximumSubscriptions {
            pollCursor = (pollCursor + 1) % Self.maximumSubscriptions
            let slot = slotAt(pollCursor)
            guard slot.active, let handle = slot.subscription else { continue }
            switch session.poll(from: handle, into: &frames) {
            case .frame:
                // A frame is not counted as received here: it is counted when
                // it is actually copied out into caller storage, because a
                // frame that does not fit is retained and served on the next
                // call. Counting it on arrival would report a frame the caller
                // has not received.
                hasPendingFrame = true
                return copyPendingFrame(
                    topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
                    payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
                )
            case .result(let result):
                // Count the facade notification before folding it into the seam code.
                notePollOutcome(result)
                switch result {
                case .queueEmpty:
                    continue
                case .notOpen:
                    return .closed
                default:
                    // Drop notifications and transport failures surface as an
                    // error, matching the sibling transport's overflow code.
                    return .failed
                }
            }
        }
        return .noEvent
    }

    /// Copies the retained pending frame when it fits, keeping it otherwise.
    private mutating func copyPendingFrame(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> ZenohCarrierPollOutcome {
        let keyOK = frames.withKeyBytes { key in
            key.withBytes { raw, count in
                guard count > 0, count <= Int(topicCapacity) else { return false }
                for offset in 0..<count {
                    topic[offset] = raw.load(fromByteOffset: offset, as: UInt8.self)
                }
                topicLength.pointee = Int32(count)
                return true
            }
        }
        let payloadOK = frames.withPayloadBytes { value in
            value.withBytes { raw, count in
                guard count >= 0, count <= Int(payloadCapacity) else { return false }
                for offset in 0..<count {
                    payload[offset] = raw.load(fromByteOffset: offset, as: UInt8.self)
                }
                payloadLength.pointee = Int32(count)
                return true
            }
        }
        guard keyOK && payloadOK else { return .insufficientCapacity }
        // The frame has now crossed into caller storage, which is the only
        // point at which "received" is true rather than merely pending.
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1)
        hasPendingFrame = false
        return .frame
    }

    /// Observes router connectivity until the deadline, without touching
    /// session or subscription ownership.
    ///
    /// Success means the open session observes a connected router inside the
    /// deadline. This includes a session that was already usable when the wait
    /// began; the result is a connectivity wait, not recovery evidence. A
    /// closed session fails fast because this operation never reopens it.
    /// Recovery evidence belongs to the caller and requires separately
    /// observing a loss and restoration plus subscriptions and traffic.
    mutating func waitForReconnect(deadlineMS: UInt32) -> Bool {
        guard phase == .subscribed else { return false }
        let startMS = UInt64(max(0, esp_timer_get_time() / 1_000))
        let durationMS = UInt64(deadlineMS)
        let endMS = durationMS > UInt64.max - startMS ? UInt64.max : startMS + durationMS
        switch session.connectedRouterCount() {
        case .count(let routers):
            if routers == 0 {
                if connectedRouterObserved { routerLossObserved = true }
                connectedRouterObserved = false
            } else {
                if routerLossObserved {
                    routerLossObserved = false
                    _ = carrier_diagnostics_add(CARRIER_METRIC_RECONNECTS_OBSERVED, 1)
                }
                connectedRouterObserved = true
                return true
            }
        case .failure(let result):
            if result == .notOpen { return false }
        }
        while true {
            let nowMS = UInt64(max(0, esp_timer_get_time() / 1_000))
            guard nowMS < endMS else { return false }
            let routerResult = session.connectedRouterCount()
            let afterQueryMS = UInt64(max(0, esp_timer_get_time() / 1_000))
            guard afterQueryMS < endMS else { return false }
            switch routerResult {
            case .count(let routers):
                if routers == 0 {
                    if connectedRouterObserved { routerLossObserved = true }
                    connectedRouterObserved = false
                } else {
                    if routerLossObserved {
                        routerLossObserved = false
                        _ = carrier_diagnostics_add(CARRIER_METRIC_RECONNECTS_OBSERVED, 1)
                    }
                    connectedRouterObserved = true
                    return true
                }
            case .failure(let result):
                if result == .notOpen { return false }
            }
            let remainingMS = endMS - afterQueryMS
            let waitMS = UInt32(min(remainingMS, UInt64(Self.reconnectPollIntervalMS)))
            vTaskDelay(zenohWaitTicks(milliseconds: waitMS))
        }
    }

    /// Removes every declaration and closes the session. A closed carrier accepts
    /// a new `connect`; nothing else is accepted until then.
    ///
    /// Unsubscribe failures do not stop teardown: the facade releases every
    /// declaration for every close outcome, so the close is the cleanup.
    mutating func disconnect() -> Bool {
        guard phase == .connected || phase == .subscribed else { return false }
        for index in 0..<Self.maximumSubscriptions {
            var slot = slotAt(index)
            if slot.active, let handle = slot.subscription {
                if session.unsubscribe(handle) == .success {
                    slot = ZenohCarrierSlot()
                    setSlotAt(index, slot)
                } else {
                    noteSubscriptionFailure()
                }
            }
        }
        let result = session.close()
        noteSessionClose(result)
        for index in 0..<Self.maximumSubscriptions {
            setSlotAt(index, ZenohCarrierSlot())
        }
        // Close releases every declaration regardless of its result.
        publishSubscriptionGauge()
        hasPendingFrame = false
        connectedRouterObserved = false
        routerLossObserved = false
        pollCursor = 0
        phase = .disconnected
        return result == .success
    }
}

// The application owns one synchronous carrier exchange at a time. This
// transport-owned adapter keeps the stateful carrier behind the application's
// carrier function table without making the application import this module.
nonisolated(unsafe) private var applicationExchangeCarrier = ZenohCarrier()

/// Configures the broker last-will. Always reports failure: the v1 client
/// profile this transport implements has no broker last-will, and reporting
/// success would invent evidence for a guarantee the carrier cannot keep.
func embeddedExchangeConfigureLastWill(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    _ = topic
    _ = topicLength
    _ = payload
    _ = payloadLength
    return 0
}

func embeddedExchangeSupportsLastWill() -> Int32 { 0 }

func embeddedExchangeConnect(_ deadlineMS: UInt32) -> Int32 {
    applicationExchangeCarrier.connect(deadlineMS: deadlineMS) ? 1 : 0
}

func embeddedExchangeSubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(ZenohFrameStorage.keyCapacity) else { return 0 }
    return applicationExchangeCarrier.subscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

func embeddedExchangeUnsubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(ZenohFrameStorage.keyCapacity) else { return 0 }
    return applicationExchangeCarrier.unsubscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

func embeddedExchangePublish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(ZenohFrameStorage.keyCapacity),
          payloadLength >= 0, payloadLength <= Int32(ZenohFrameStorage.payloadCapacity) else { return 0 }
    // A zero-length payload borrows nothing; the carrier maps it to its empty
    // value without reading the payload pointer.
    return applicationExchangeCarrier.publish(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)),
        payload: Span(_unsafeStart: payload, count: Int(payloadLength))
    ) ? 1 : 0
}

func embeddedExchangePollOneEvent(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    applicationExchangeCarrier.pollOneEvent(
        topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
        payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
    )
}

/// Returns the typed poll result for the v1 ABI adapter. The legacy seam above
/// keeps its historical `1/0/-2/-1` contract for existing callers.
fileprivate func embeddedExchangePollOneEventOutcome(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> ZenohCarrierPollOutcome {
    applicationExchangeCarrier.pollOneEventOutcome(
        topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
        payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
    )
}

func embeddedExchangeWaitForReconnect(_ deadlineMS: UInt32) -> Int32 {
    applicationExchangeCarrier.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

func embeddedExchangeDisconnect() -> Int32 {
    applicationExchangeCarrier.disconnect() ? 1 : 0
}

nonisolated(unsafe) private var emptyCarrierByte: UInt8 = 0

@_cdecl("axoloty_zenoh_v1_supports_last_will")
public func axoloty_zenoh_v1_supports_last_will(
    _ context: UnsafeMutableRawPointer?, _ supported: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = context
    guard let supported else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    supported.pointee = 0
    return AXOLOTY_ABI_STATUS_OK
}

@_cdecl("axoloty_zenoh_v1_configure_last_will")
public func axoloty_zenoh_v1_configure_last_will(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ topicLength: UInt32,
    _ payload: UnsafePointer<UInt8>?, _ payloadLength: UInt32
) -> Int32 {
    _ = context
    guard let topic, let payload, topicLength <= UInt32(Int32.max), payloadLength <= UInt32(Int32.max) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    return embeddedExchangeConfigureLastWill(topic, Int32(topicLength), payload, Int32(payloadLength)) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_zenoh_v1_connect")
public func axoloty_zenoh_v1_connect(_ context: UnsafeMutableRawPointer?, _ deadline: UInt32) -> Int32 {
    _ = context
    return embeddedExchangeConnect(deadline) != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_zenoh_v1_subscribe")
public func axoloty_zenoh_v1_subscribe(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ length: UInt32, _ deadline: UInt32
) -> Int32 {
    _ = context
    guard let topic, length <= UInt32(Int32.max) else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    return embeddedExchangeSubscribe(topic, Int32(length), deadline) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_zenoh_v1_unsubscribe")
public func axoloty_zenoh_v1_unsubscribe(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ length: UInt32, _ deadline: UInt32
) -> Int32 {
    _ = context
    guard let topic, length <= UInt32(Int32.max) else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    return embeddedExchangeUnsubscribe(topic, Int32(length), deadline) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_zenoh_v1_publish")
public func axoloty_zenoh_v1_publish(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ topicLength: UInt32,
    _ payload: UnsafePointer<UInt8>?, _ payloadLength: UInt32
) -> Int32 {
    _ = context
    guard let topic, topicLength <= UInt32(Int32.max), payloadLength <= UInt32(Int32.max),
          (payloadLength == 0 || payload != nil) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    if let payload {
        return embeddedExchangePublish(topic, Int32(topicLength), payload, Int32(payloadLength)) != 0
            ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
    }
    return withUnsafePointer(to: &emptyCarrierByte) { empty in
        embeddedExchangePublish(topic, Int32(topicLength), empty, 0) != 0
            ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
    }
}

@_cdecl("axoloty_zenoh_v1_poll")
public func axoloty_zenoh_v1_poll(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafeMutablePointer<UInt8>?, _ topicCapacity: UInt32,
    _ topicLength: UnsafeMutablePointer<UInt32>?, _ payload: UnsafeMutablePointer<UInt8>?,
    _ payloadCapacity: UInt32, _ payloadLength: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = context
    guard let topic, let topicLength, let payload, let payloadLength,
          topicCapacity <= UInt32(Int32.max), payloadCapacity <= UInt32(Int32.max) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    var copiedTopic: Int32 = 0
    var copiedPayload: Int32 = 0
    switch embeddedExchangePollOneEventOutcome(topic, Int32(topicCapacity), &copiedTopic,
                                                payload, Int32(payloadCapacity), &copiedPayload) {
    case .frame:
        guard copiedTopic > 0, UInt32(copiedTopic) <= topicCapacity,
              copiedPayload >= 0, UInt32(copiedPayload) <= payloadCapacity else {
            return AXOLOTY_ABI_STATUS_FAILED
        }
        topicLength.pointee = UInt32(copiedTopic)
        payloadLength.pointee = UInt32(copiedPayload)
        return AXOLOTY_ABI_STATUS_OK
    case .noEvent: return AXOLOTY_ABI_STATUS_NO_EVENT
    case .closed: return AXOLOTY_ABI_STATUS_CLOSED
    case .insufficientCapacity: return AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL
    case .failed: return AXOLOTY_ABI_STATUS_FAILED
    }
}

@_cdecl("axoloty_zenoh_v1_reconnect")
public func axoloty_zenoh_v1_reconnect(_ context: UnsafeMutableRawPointer?, _ deadline: UInt32) -> Int32 {
    _ = context
    return embeddedExchangeWaitForReconnect(deadline) != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_zenoh_v1_disconnect")
public func axoloty_zenoh_v1_disconnect(_ context: UnsafeMutableRawPointer?) -> Int32 {
    _ = context
    return embeddedExchangeDisconnect() != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}
