# Transports

Embedded transport backends that carry protocol frames on a device.

A transport owns carrier mechanics only. Every protocol rule lives in Axoloty's
`AxolotyProtocol`. Embedded Zenoh will land here, per
[epic #796](https://github.com/phynics/axoloty/issues/796); host and shared
Zenoh work stays in Axoloty.
