# Transports

## What belongs here

Carrier mechanics on a device: connecting, subscribing, publishing, receiving,
reconnecting, last-will configuration, and the bounded buffers that carry
bytes. MQTT today; Zenoh (`zenoh-pico`) under [#4](https://github.com/phynics/axoloty-embedded/issues/4).

## What does not

A transport contains no protocol rule. Every routing key, frame boundary,
correlation rule, and profile decision lives in Axoloty's `AxolotyProtocol`.
`Tools/check-invariants.sh` fails on `import AxolotyProtocol`,
`import AxolotyCoatyModels`, `ProtocolProcessor`,
`ProtocolSubscriptionRegistry`, `BorrowedProtocolFrame`,
`InlineProtocolActionSink`, and the literal `coaty/3` under this directory.

A transport that decides what a topic means is a second source of protocol
truth, and no Axoloty test covers it. If you need a rule that does not exist
yet, it is an Axoloty change: open it in `phynics/axoloty`, land it there, then
raise the lock here.

## Shape

Take topic and payload as borrowed byte buffers with explicit lengths. Consume
them synchronously and never retain them. Keep the API bounded and
non-allocating; the device has one stack and no slack.

`AxolotyWire` is available for byte-level buffer limits and codecs. That is the
only Core module a transport should need.
