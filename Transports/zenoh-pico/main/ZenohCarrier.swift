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

/// Records one receive outcome in the transport-neutral carrier counters.
///
/// A queue-full verdict is a drop and an over-bound verdict is an oversized
/// frame, because that is what Core's own poll results mean. An empty queue is
/// not an event: counting idle polls would make the steady-state numbers
/// meaningless. A closed session is a session failure rather than a receive
/// error, because that is what "the session is not open" reports.
@inline(__always)
private func notePollOutcome(_ result: ZenohResult) {
    switch result {
    case .success:
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1)
    case .queueFull:
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_DROPPED, 1)
    case .frameTooLarge:
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_OVERSIZED, 1)
    case .queueEmpty:
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
/// Every operation also reports its outcome to the transport-neutral carrier
/// counters in `carrier_diagnostics.c`. Each counter records the verdict Core's
/// own result already reached — a queue-full result is counted as a drop, an
/// over-bound result as an oversized frame — so a drop here means exactly what
/// a drop means in `AxolotyZenohCore`, and nothing in the counters module
/// restates what any result code means. Keeping that state in C rather than in
/// this value is deliberate: a Zenoh receive callback runs on a Zenoh-owned
/// task, and one bounded, saturating, atomically updated counter set is
/// readable by the Swift carrier, the C-only qualification runner, and the
/// device gate alike.
struct ZenohCarrier: ~Copyable {
    /// The facade's fixed per-session subscription capacity.
    static let maximumSubscriptions = 8
    /// Milliseconds between router observations while waiting.
    static let reconnectPollIntervalMS: UInt32 = 20

    /// Clears every carrier counter. Boot, and the qualification runner between
    /// phases, so each phase reports against a known zero.
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

    /// The subscription high-water mark: the most declarations ever held at
    /// once. It survives teardown on purpose, which is what makes a
    /// stale-subscription leak visible after the fact.
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

    /// Publishes the subscription gauge after any change to the slot table.
    ///
    /// The gauge is a level, not a tally, so it is set rather than incremented,
    /// and the high-water mark it feeds only ever grows. That is what makes a
    /// stale-subscription leak visible across a long run without keeping a
    /// sample history on a device that has no room for one.
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
        guard phase == .idle else { return false }
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
        guard topicCapacity > 0, topicCapacity <= Int32(ZenohFrameStorage.keyCapacity),
              payloadCapacity >= 0, payloadCapacity <= Int32(ZenohFrameStorage.payloadCapacity) else { return -1 }
        if phase == .disconnected { return -2 }
        guard phase == .subscribed else { return -1 }
        if hasPendingFrame {
            return copyPendingFrame(
                topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
                payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
            )
        }
        let active = activeSlotCount()
        guard active > 0 else { return 0 }
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
                // The verdict is Core's, so it is Core's verdict that is
                // counted: a queue-full result becomes a drop and an
                // over-bound result becomes an oversized frame, before either
                // is folded into the one return code this seam reports.
                notePollOutcome(result)
                switch result {
                case .queueEmpty:
                    continue
                case .notOpen:
                    return -2
                default:
                    // Drop notifications and transport failures surface as an
                    // error, matching the sibling transport's overflow code.
                    return -1
                }
            }
        }
        return 0
    }

    /// Copies the retained pending frame when it fits, keeping it otherwise.
    private mutating func copyPendingFrame(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> Int32 {
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
        guard keyOK && payloadOK else { return -1 }
        // The frame has now crossed into caller storage, which is the only
        // point at which "received" is true rather than merely pending.
        _ = carrier_diagnostics_add(CARRIER_METRIC_FRAMES_RECEIVED, 1)
        hasPendingFrame = false
        return 1
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
            connectedRouterObserved = routers > 0
            if routers > 0 { return true }
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

    /// Removes every declaration and closes the session. Close is terminal.
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
                }
            }
        }
        let result = session.close()
        noteSessionClose(result)
        for index in 0..<Self.maximumSubscriptions {
            setSlotAt(index, ZenohCarrierSlot())
        }
        // Every declaration is released by the close whatever it reported, so
        // the gauge drops to zero. A non-zero gauge after this would be a stale
        // subscription, and the device gate checks exactly that.
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

func embeddedExchangeWaitForReconnect(_ deadlineMS: UInt32) -> Int32 {
    applicationExchangeCarrier.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

func embeddedExchangeDisconnect() -> Int32 {
    applicationExchangeCarrier.disconnect() ? 1 : 0
}

// --- Transport-neutral carrier diagnostics, readable from C -----------------
//
// The counters live in C so the Swift carrier, the C-only pub/sub
// qualification runner, and the device gate all observe one set of numbers.
// These entry points are what the runner and the gate bind; they name a
// counter set and nothing about the carrier behind it.

// Clears every counter. Called at boot and between qualification phases.
func embeddedCarrierDiagnosticsReset() {
    carrier_diagnostics_reset()
}

// Reads the subscription gauge.
func embeddedCarrierDiagnosticsActiveSubscriptions() -> UInt32 {
    carrier_diagnostics_get().active_subscriptions
}

// Reads the subscription high-water mark.
func embeddedCarrierDiagnosticsActiveSubscriptionsPeak() -> UInt32 {
    carrier_diagnostics_get().active_subscriptions_peak
}

/// The buffer `embeddedCarrierDiagnosticsWriteJSON` always needs, including the
/// terminating null. A caller sizes storage from this rather than guessing, so
/// a report can never be silently truncated.
func embeddedCarrierDiagnosticsJSONCapacity() -> UInt32 {
    UInt32(carrier_diagnostics_json_capacity())
}

/// Writes the counters as one bounded JSON object into caller storage.
///
/// Returns the byte count written, or 0 when the buffer is too small. A caller
/// must treat 0 as "the report did not fit", never as a report of zero counts:
/// a truncated metric is not a measurement.
func embeddedCarrierDiagnosticsWriteJSON(
    _ buffer: UnsafeMutablePointer<CChar>, _ capacity: Int32
) -> Int32 {
    guard capacity > 0 else { return 0 }
    return Int32(carrier_diagnostics_write_json(buffer, Int(capacity)))
}
