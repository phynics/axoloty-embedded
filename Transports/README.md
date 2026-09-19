# Transports

Embedded transport backends that carry protocol frames on a device.

A transport owns carrier mechanics only. Every protocol rule lives in Axoloty's
`AxolotyProtocol`. Embedded Zenoh lands here as `zenoh-pico/`
([epic #796](https://github.com/phynics/axoloty/issues/796),
[re-scope #853](https://github.com/phynics/axoloty/issues/853)); host and
shared Zenoh work stays in Axoloty. See
[zenoh-pico/README.md](./zenoh-pico/README.md) for what has landed and what
needs the dependency.
